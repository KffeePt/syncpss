#!/usr/bin/env python3
"""Offline bootstrap/CLI regressions using a disposable real GPG signer."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import pty
import re
import select
import shutil
import signal
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
KEY_PATTERN = re.compile(
    r"-----BEGIN PGP PUBLIC KEY BLOCK-----[\s\S]*?-----END PGP PUBLIC KEY BLOCK-----"
)
BINARY: Path | None = None


class BootstrapTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="syncpss-bootstrap-qa-")
        cls.root = Path(cls.temp.name)
        cls.signer = cls.root / "signer"
        cls.signer.mkdir(mode=0o700)
        cls.gpg = ["gpg", "--batch", "--no-options", "--homedir", str(cls.signer)]
        subprocess.run(
            cls.gpg + ["--pinentry-mode", "loopback", "--passphrase", "",
                       "--quick-generate-key", "syncpss disposable QA", "ed25519", "sign", "0"],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
        )
        keys = subprocess.check_output(cls.gpg + ["--with-colons", "--list-keys"], text=True)
        cls.fingerprint = next(line.split(":")[9] for line in keys.splitlines() if line.startswith("fpr:"))
        cls.public_key = subprocess.check_output(cls.gpg + ["--armor", "--export"], text=True).strip()
        cls.bin = cls.root / "bin"
        cls.bin.mkdir()
        curl = cls.bin / "curl"
        curl.write_text(
            "#!/usr/bin/env python3\n"
            "import os, pathlib, shutil, sys\n"
            "a = sys.argv[1:]\n"
            "url = next(x for x in a if x.startswith('https://'))\n"
            "name = url.rsplit('/', 1)[-1]\n"
            "source = pathlib.Path(os.environ['QA_ASSETS']) / name\n"
            "with open(os.environ['QA_DOWNLOADS'], 'a') as f: f.write(url + '\\n')\n"
            "if name == os.environ.get('QA_MISSING'): sys.exit(22)\n"
            "shutil.copyfile(source, a[a.index('-o') + 1])\n",
            encoding="utf-8",
        )
        curl.chmod(0o700)
        original = (ROOT / "install.sh").read_text(encoding="utf-8")
        policy = json.loads((ROOT / "config/signing_policy.json").read_text())
        trusted = policy["gpg"]["active_release_fingerprint"]
        fixture = KEY_PATTERN.sub(lambda _: cls.public_key, original).replace(trusted, cls.fingerprint)
        cls.bootstrap = cls.root / "bootstrap.sh"
        cls.bootstrap.write_text(fixture, encoding="utf-8")

    @classmethod
    def tearDownClass(cls):
        if shutil.which("gpgconf"):
            subprocess.run(["gpgconf", "--homedir", str(cls.signer), "--kill", "gpg-agent"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cls.temp.cleanup()

    def setUp(self):
        self.case = Path(tempfile.mkdtemp(dir=self.root))
        self.assets = self.case / "assets"
        self.assets.mkdir()
        (self.case / "home").mkdir()
        (self.case / "tmp").mkdir()
        self.marker = self.case / "executed"
        self.env = dict(os.environ, HOME=str(self.case / "home"), TMPDIR=str(self.case / "tmp"),
                        PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        SYNCPSS_RELEASE_TAG="v9.8.7", QA_ASSETS=str(self.assets),
                        QA_DOWNLOADS=str(self.case / "downloads"), QA_MARKER=str(self.marker))
        self.write_asset("managed_paths.sh", "qa_companion_loaded=yes\n")
        self.write_asset("uninstall_syncpss.sh", "#!/usr/bin/env bash\nexit 0\n")
        self.write_asset("installer.sh", "#!/usr/bin/env bash\nset -euo pipefail\n"
                         'here="$(cd "$(dirname "$0")" && pwd)"\n'
                         'source "$here/managed_paths.sh"\n'
                         '[ "$qa_companion_loaded" = yes ]\n'
                         '[ -f "$here/uninstall_syncpss.sh" ]\n'
                         '[ "$SYNCPSS_RELEASE_TAG" = v9.8.7 ]\n'
                         'printf "%s\\n" "$@" > "$QA_MARKER"\n'
                         'exit "${QA_CHILD_EXIT:-0}"\n')

    def write_asset(self, name, content):
        asset = self.assets / name
        asset.write_text(content, encoding="utf-8")
        (self.assets / (name + ".sha256")).write_text(
            hashlib.sha256(asset.read_bytes()).hexdigest() + "  " + name + "\n")
        subprocess.run(self.gpg + ["--yes", "--armor", "--detach-sign", str(asset)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

    def run_bootstrap(self, *args):
        result = subprocess.run(["bash", str(self.bootstrap), *args], env=self.env,
                                text=True, capture_output=True, timeout=20)
        self.assertEqual(list((self.case / "tmp").iterdir()), [], "bootstrap temp files leaked")
        return result

    def test_companions_arguments_and_pinned_release(self):
        result = self.run_bootstrap("--release")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.marker.read_text().strip(), "--release")
        urls = (self.case / "downloads").read_text().splitlines()
        self.assertEqual(len(urls), 9)
        self.assertTrue(all("/v9.8.7/" in url for url in urls))
        self.assertEqual(list((self.case / "home").iterdir()), [])

    def test_tamper_with_matching_checksum_is_rejected(self):
        asset = self.assets / "managed_paths.sh"
        asset.write_text("qa_companion_loaded=compromised\n")
        (self.assets / "managed_paths.sh.sha256").write_text(
            hashlib.sha256(asset.read_bytes()).hexdigest() + "  managed_paths.sh\n")
        result = self.run_bootstrap()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("signature verification failed", result.stderr)
        self.assertFalse(self.marker.exists())

    def test_missing_companion_signature_is_rejected(self):
        self.env["QA_MISSING"] = "uninstall_syncpss.sh.asc"
        result = self.run_bootstrap()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.marker.exists())

    def test_child_failure_propagates(self):
        self.env["QA_CHILD_EXIT"] = "23"
        self.assertEqual(self.run_bootstrap().returncode, 23)

    def test_bad_tag_rejected_before_download(self):
        self.env["SYNCPSS_RELEASE_TAG"] = "../../bad"
        self.assertNotEqual(self.run_bootstrap().returncode, 0)
        self.assertFalse((self.case / "downloads").exists())

    def test_help_does_not_download(self):
        self.assertEqual(self.run_bootstrap("--help").returncode, 0)
        self.assertFalse((self.case / "downloads").exists())

    def test_piped_bootstrap_restores_terminal_for_wizard(self):
        self.write_asset("installer.sh", "#!/usr/bin/env bash\nset -euo pipefail\n"
                         'printf "QA_READY\\n"\n'
                         'read -r -t 5 answer\n'
                         '[ "$answer" = "typed-in-terminal" ]\n'
                         'printf "%s\\n" "$@" > "$QA_MARKER"\n')
        child, terminal = pty.fork()
        if child == 0:
            os.execvpe("bash", ["bash", "-c", 'cat -- "$1" | bash -s -- --release',
                                "piped-bootstrap", str(self.bootstrap)], self.env)
        output = b""
        replied = False
        status = None
        try:
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                readable, _, _ = select.select([terminal], [], [], 0.05)
                if readable:
                    try:
                        output += os.read(terminal, 65536)
                    except OSError:
                        pass  # Linux PTYs return EIO when the child closes.
                    if b"QA_READY" in output and not replied:
                        os.write(terminal, b"typed-in-terminal\n")
                        replied = True
                pid, value = os.waitpid(child, os.WNOHANG)
                if pid == child:
                    status = os.waitstatus_to_exitcode(value)
                    break
            self.assertTrue(replied, output.decode(errors="replace"))
            self.assertEqual(status, 0, output.decode(errors="replace"))
            self.assertEqual(self.marker.read_text().strip(), "--release")
            self.assertEqual(list((self.case / "tmp").iterdir()), [])
        finally:
            if status is None:
                os.killpg(child, signal.SIGTERM)
                os.waitpid(child, 0)
            os.close(terminal)

    def test_all_production_keys_parse_and_match_policy(self):
        policy = json.loads((ROOT / "config/signing_policy.json").read_text())
        expected = policy["gpg"]["active_release_fingerprint"]
        for relative in ("install.sh", "scripts/sh/installer.sh",
                         "src/util/release_verification.cpp", "src/installer/win/common.hpp"):
            with self.subTest(file=relative):
                key = KEY_PATTERN.search((ROOT / relative).read_text()).group()
                output = subprocess.check_output(self.gpg + ["--with-colons", "--show-keys"],
                                                 input=key, text=True, stderr=subprocess.PIPE)
                actual = next(line.split(":")[9] for line in output.splitlines() if line.startswith("fpr:"))
                self.assertEqual(actual, expected)


class CliTests(unittest.TestCase):
    def run_cli(self, *args):
        return subprocess.run([str(BINARY), *args], text=True, capture_output=True, timeout=5)

    def test_help_and_version_without_terminal(self):
        for args in (("--help",), ("--version",), ("setup", "--help")):
            result = self.run_cli(*args)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("syncpss", result.stdout)
            self.assertNotIn("\x1b", result.stdout)

    def test_unknown_or_noninteractive_commands_do_not_open_tui(self):
        for args in (("--unknown",), ("doctor", "--wrong"), ("setup",), ("tui",), ()):
            result = self.run_cli(*args)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertEqual(result.stdout, "")

    def test_doctor_has_only_expected_safe_fields(self):
        result = self.run_cli("doctor", "--json")
        self.assertIn(result.returncode, (0, 1))
        report = json.loads(result.stdout)
        self.assertEqual(set(report), {"schema_version", "version", "configured", "dependencies", "ready"})
        self.assertEqual(report["schema_version"], 1)
        self.assertTrue(all(isinstance(value, bool) for value in report["dependencies"].values()))
        self.assertEqual(result.stderr, "")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True, type=Path)
    args = parser.parse_args()
    BINARY = args.binary.resolve(strict=True)
    unittest.main(argv=[__file__], verbosity=2)
