#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path
import shutil
import sys
import xml.etree.ElementTree as ET

from framework.runner import CheckFailure, TestRunner


REPO_ROOT = Path(__file__).resolve().parents[1]
BUILD_DIR = REPO_ROOT / "build-test-runner"
ENTRYPOINT_SHELL_FILES = (
    REPO_ROOT / "install.sh",
    REPO_ROOT / "scripts" / "sh" / "installer.sh",
    REPO_ROOT / "scripts" / "sh" / "uninstall_syncpss.sh",
    REPO_ROOT / "tests" / "installer_qa" / "run.sh",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run syncpss repo QA, static checks, and installer harness tests."
    )
    parser.add_argument(
        "--lint-only",
        action="store_true",
        help="Run structure and syntax checks only, without configure/build or scenario harnesses.",
    )
    parser.add_argument(
        "--static-only",
        action="store_true",
        help="Run structure, syntax, and configure/build checks, but skip dynamic scenario harnesses.",
    )
    parser.add_argument(
        "--skip-installer-qa",
        action="store_true",
        help="Skip the installer fake-command QA harness.",
    )
    parser.add_argument(
        "--with-clang-tidy",
        action="store_true",
        help="Enable clang-tidy during the configure/build stage when available.",
    )
    parser.add_argument(
        "--keep-build-dir",
        action="store_true",
        help="Keep the temporary build-test-runner directory after the run finishes.",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Print successful command output as well as failures.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    runner = TestRunner(REPO_ROOT, verbose=args.verbose)

    try:
        bash = runner.require_command("bash")
        powershell = runner.require_command("powershell", "pwsh")

        runner.run_step("Repo QA structure", check_repo_structure)
        runner.run_step("Shell syntax lint", lambda: lint_shell_files(runner, bash))
        runner.run_step("Python helper lint", lint_python_files)
        runner.run_step(
            "PowerShell syntax lint",
            lambda: lint_powershell_files(runner, powershell),
        )
        runner.run_step("Batch entrypoint lint", lint_batch_files)
        runner.run_step("XML manifest lint", lint_xml_files)

        if not args.lint_only:
            runner.run_step(
                "CMake configure",
                lambda: configure_cmake(runner, bash, args.with_clang_tidy),
            )
            runner.run_step("CMake build", lambda: build_cmake(runner, bash))

        if not args.lint_only and not args.static_only and not args.skip_installer_qa:
            runner.run_step("Installer QA harness", lambda: run_installer_qa(runner, bash))
    except CheckFailure:
        runner.print_summary()
        cleanup_build_dir(keep=args.keep_build_dir)
        return 1

    runner.print_summary()
    cleanup_build_dir(keep=args.keep_build_dir)
    return 0


def check_repo_structure() -> str:
    required_paths = (
        REPO_ROOT / "docs" / "QA.md",
        REPO_ROOT / "tests" / "run.py",
        REPO_ROOT / "tests" / "framework" / "__init__.py",
        REPO_ROOT / "tests" / "framework" / "runner.py",
        REPO_ROOT / "tests" / "installer_qa" / "run.sh",
        REPO_ROOT / "scripts" / "run_tests.bat",
        REPO_ROOT / "scripts" / "sh" / "managed_paths.sh",
        REPO_ROOT / "src" / "util" / "validation.hpp",
        REPO_ROOT / "src" / "util" / "validation.cpp",
    )
    missing = [path for path in required_paths if not path.exists()]
    if missing:
        raise CheckFailure(
            "Missing required QA framework paths:\n"
            + "\n".join(f" - {path.relative_to(REPO_ROOT)}" for path in missing)
        )

    qa_doc = read_text(REPO_ROOT / "docs" / "QA.md")
    for marker in ("## Hard Rules", "## Soft Rules", "scripts/run_tests.bat"):
        if marker not in qa_doc:
            raise CheckFailure(f"docs/QA.md is missing required marker: {marker}")

    ensure_text_contains(
        REPO_ROOT / "scripts" / "sh" / "installer.sh",
        "managed_paths.sh",
        "installer must source shared managed path guards",
    )
    ensure_text_contains(
        REPO_ROOT / "scripts" / "sh" / "uninstall_syncpss.sh",
        "managed_paths.sh",
        "uninstaller must source shared managed path guards",
    )
    ensure_text_contains(
        REPO_ROOT / "scripts" / "ps1" / "purge.ps1",
        "managed_paths.sh",
        "purge flow must copy managed_paths.sh alongside uninstall_syncpss.sh",
    )
    ensure_text_contains(
        REPO_ROOT / "scripts" / "ps1" / "purge.ps1",
        "Copy-PurgeHelpersToWslHome",
        "purge flow must use the shared helper staging routine",
    )
    ensure_text_contains(
        REPO_ROOT / "CMakeLists.txt",
        "enable_testing()",
        "CMake must expose repo tests through CTest",
    )
    ensure_text_contains(
        REPO_ROOT / "CMakeLists.txt",
        "installer_qa",
        "CMake must register the installer QA harness",
    )
    ensure_text_contains(
        REPO_ROOT / ".github" / "workflows" / "pr-checks.yml",
        "ctest --test-dir build --output-on-failure",
        "CI must run repo tests through ctest",
    )
    ensure_text_contains(
        REPO_ROOT / "scripts" / "ps1" / "ci.ps1",
        "--local",
        "CI must be able to run installer staging in explicit local mode",
    )
    ensure_text_contains(
        REPO_ROOT / "scripts" / "ps1" / "ci.ps1",
        "--release",
        "CI must be able to run installer staging in explicit release mode",
    )
    ensure_text_contains(
        REPO_ROOT / "scripts" / "ps1" / "build.ps1",
        "managed_paths.sh",
        "Build packaging must include managed_paths.sh for staged installer helpers",
    )
    ensure_text_contains(
        REPO_ROOT / "scripts" / "build.bat",
        "managed_paths.sh",
        "Windows packaging must include managed_paths.sh for staged installer helpers",
    )
    ensure_text_contains(
        REPO_ROOT / "scripts" / "sh" / "installer.sh",
        "VeraCrypt Retry",
        "installer must surface a dedicated VeraCrypt retry prompt for keys container failures",
    )
    ensure_text_contains(
        REPO_ROOT / "scripts" / "sh" / "installer.sh",
        "installer.log",
        "installer must persist installer logs under ~/.syncpss/logs/installer.log",
    )
    ensure_text_contains(
        REPO_ROOT / "scripts" / "sh" / "installer.sh",
        "managed_paths.sh.sha256",
        "installer asset staging must validate managed_paths.sh alongside the install payload",
    )
    ensure_text_contains(
        REPO_ROOT / "src" / "installer" / "linux" / "main_installer.cpp",
        "kManagedPathsScriptAsset",
        "native installer fingerprint verification must include managed_paths.sh",
    )
    ensure_text_contains(
        REPO_ROOT / "src" / "tui" / "detail" / "fingerprint.cpp",
        'install_assets_dir / "managed_paths.sh"',
        "runtime fingerprint verification must include managed_paths.sh",
    )
    ensure_text_contains(
        REPO_ROOT / "src" / "installer" / "win" / "wsl_stage.cpp",
        "wsl-installer.log",
        "Windows WSL bootstrap must persist ~/.syncpss/logs/wsl-installer.log",
    )
    ensure_text_contains(
        REPO_ROOT / "src" / "installer" / "win" / "main.cpp",
        "Press Enter to Run WSL Installer...",
        "interactive Windows installer must pause before launching installer.sh",
    )
    ensure_text_contains(
        REPO_ROOT / "src" / "installer" / "win" / "shortcuts.cpp",
        "syncpss.log",
        "Windows runtime launcher must persist ~/.syncpss/logs/syncpss.log",
    )
    ensure_text_contains(
        REPO_ROOT / "src" / "installer" / "win" / "common.hpp",
        "kPurgePowerShellScriptName",
        "Windows runtime helper constants must include purge.ps1",
    )
    ensure_text_contains(
        REPO_ROOT / "src" / "installer" / "win" / "shortcuts.cpp",
        "purge_syncpss_powershell_contents",
        "Windows runtime helper staging must write purge.ps1 into %USERPROFILE%\\.syncpss",
    )
    ensure_text_contains(
        REPO_ROOT / "src" / "installer" / "win" / "shortcuts.cpp",
        "runtime-helper-dir",
        "Windows purge helper must support deferred runtime-directory cleanup",
    )
    ensure_text_contains(
        REPO_ROOT / "src" / "installer" / "win" / "shortcuts.cpp",
        "$command = @'",
        "Windows runtime launcher must pass a literal bash command to WSL without PowerShell variable interpolation",
    )
    ensure_text_contains(
        REPO_ROOT / "src" / "tui" / "tui_sync.cpp",
        "--purge-windows-shortcut",
        "TUI uninstall handoff must request Windows shortcut cleanup too",
    )
    ensure_text_contains(
        REPO_ROOT / "src" / "tui" / "tui_sync.cpp",
        "SYNCPSS_UNINSTALL_LOG_PATH",
        "TUI uninstall handoff must capture helper failures into a readable uninstall log",
    )
    ensure_text_contains(
        REPO_ROOT / "scripts" / "sh" / "uninstall_syncpss.sh",
        "UNINSTALL_LOG_FILE",
        "uninstall helper must persist a failure log for TUI handoff diagnostics",
    )
    ensure_text_contains(
        REPO_ROOT / "scripts" / "sh" / "uninstall_syncpss.sh",
        "run_windows_purge_helper_if_present",
        "uninstall helper must use the staged Windows purge helper for Start Menu cleanup",
    )

    return "validated 17 repo invariants"


def lint_shell_files(runner: TestRunner, bash: str) -> str:
    shell_files = sorted(
        {
            path
            for path in [REPO_ROOT / "install.sh", *iter_files(REPO_ROOT / "scripts", ".sh"), *iter_files(REPO_ROOT / "tests", ".sh")]
            if path.exists()
        }
    )
    if not shell_files:
        raise CheckFailure("No shell files were found for linting.")

    for path in shell_files:
        first_line = read_text(path).splitlines()[0] if read_text(path).splitlines() else ""
        if not first_line.startswith("#!"):
            raise CheckFailure(f"{path.relative_to(REPO_ROOT)} is missing a shebang.")

        rel_path = path.relative_to(REPO_ROOT).as_posix()
        runner.run_command(
            f"bash -n {rel_path}",
            [bash, "-n", rel_path],
            cwd=REPO_ROOT,
        )

    for entrypoint in ENTRYPOINT_SHELL_FILES:
        text = read_text(entrypoint)
        if "set -euo pipefail" not in text:
            raise CheckFailure(
                f"{entrypoint.relative_to(REPO_ROOT)} must enable 'set -euo pipefail'."
            )

    return f"{len(shell_files)} shell files"


def lint_powershell_files(runner: TestRunner, powershell: str) -> str:
    ps1_files = sorted(iter_files(REPO_ROOT / "scripts", ".ps1"))
    if not ps1_files:
        raise CheckFailure("No PowerShell files were found for linting.")

    parse_command = (
        "$errors = @(); "
        "[void][System.Management.Automation.Language.Parser]::ParseFile("
        "$env:SYNCPSSTEST_TARGET_FILE, [ref]$null, [ref]$errors); "
        "if ($errors.Count -gt 0) { "
        "$errors | ForEach-Object { $_.ToString() }; exit 1 }"
    )

    for path in ps1_files:
        text = read_text(path)
        if "Set-StrictMode -Version Latest" not in text:
            raise CheckFailure(
                f"{path.relative_to(REPO_ROOT)} must enable Set-StrictMode -Version Latest."
            )
        if '$ErrorActionPreference = "Stop"' not in text:
            raise CheckFailure(
                f"{path.relative_to(REPO_ROOT)} must set $ErrorActionPreference = \"Stop\"."
            )
        runner.run_command(
            f"PowerShell parse {path.relative_to(REPO_ROOT).as_posix()}",
            [
                powershell,
                "-NoLogo",
                "-NoProfile",
                "-Command",
                parse_command,
            ],
            cwd=REPO_ROOT,
            env={"SYNCPSSTEST_TARGET_FILE": str(path)},
        )

    return f"{len(ps1_files)} PowerShell files"


def lint_python_files() -> str:
    python_files = sorted(iter_files(REPO_ROOT / "tests", ".py"))
    if not python_files:
        raise CheckFailure("No Python helper files were found for linting.")

    import py_compile

    for path in python_files:
        try:
            py_compile.compile(str(path), doraise=True)
        except py_compile.PyCompileError as exc:
            raise CheckFailure(
                f"{path.relative_to(REPO_ROOT)} failed Python compilation: {exc.msg}"
            ) from exc

    return f"{len(python_files)} Python files"


def lint_batch_files() -> str:
    batch_files = sorted(iter_files(REPO_ROOT / "scripts", ".bat"))
    if not batch_files:
        raise CheckFailure("No batch files were found for linting.")

    for path in batch_files:
        text = read_text(path)
        first_line = first_non_empty_line(text)
        if first_line.lower() != "@echo off":
            raise CheckFailure(
                f"{path.relative_to(REPO_ROOT)} must start with '@echo off'."
            )
        if "setlocal" not in text.lower():
            raise CheckFailure(
                f"{path.relative_to(REPO_ROOT)} must declare setlocal for safer state handling."
            )

    return f"{len(batch_files)} batch files"


def lint_xml_files() -> str:
    xml_files = [REPO_ROOT / "manifest.xml"]
    for path in xml_files:
        try:
            ET.parse(path)
        except ET.ParseError as exc:
            raise CheckFailure(f"{path.relative_to(REPO_ROOT)} is not valid XML: {exc}") from exc
    return f"{len(xml_files)} XML files"


def configure_cmake(runner: TestRunner, bash: str, with_clang_tidy: bool) -> str:
    cleanup_build_dir(keep=False)
    clang_tidy_flag = "ON" if with_clang_tidy else "OFF"
    command = (
        "cmake -S . -B build-test-runner "
        "-DCMAKE_BUILD_TYPE=Debug "
        f"-DSYNCPSS_ENABLE_CLANG_TIDY={clang_tidy_flag}"
    )
    runner.run_command("cmake configure", [bash, "-lc", command], cwd=REPO_ROOT)
    return f"clang-tidy={clang_tidy_flag}"


def build_cmake(runner: TestRunner, bash: str) -> str:
    runner.run_command(
        "cmake build",
        [bash, "-lc", "cmake --build build-test-runner --parallel 2"],
        cwd=REPO_ROOT,
    )
    return "build-test-runner"


def run_installer_qa(runner: TestRunner, bash: str) -> str:
    runner.run_command(
        "installer QA harness",
        [bash, "tests/installer_qa/run.sh"],
        cwd=REPO_ROOT,
    )
    return "tests/installer_qa/run.sh"


def iter_files(base_dir: Path, suffix: str) -> list[Path]:
    if not base_dir.exists():
        return []

    collected: list[Path] = []
    for path in base_dir.rglob(f"*{suffix}"):
        if not path.is_file():
            continue
        if any(part.startswith("build") for part in path.parts):
            continue
        if "bin" in path.parts or ".git" in path.parts:
            continue
        collected.append(path)
    return collected


def ensure_text_contains(path: Path, needle: str, description: str) -> None:
    text = read_text(path)
    if needle not in text:
        raise CheckFailure(f"{description}: missing '{needle}' in {path.relative_to(REPO_ROOT)}")


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def first_non_empty_line(text: str) -> str:
    for line in text.splitlines():
        stripped = line.strip()
        if stripped:
            return stripped
    return ""


def cleanup_build_dir(*, keep: bool) -> None:
    if keep:
        return
    if not BUILD_DIR.exists():
        return
    if BUILD_DIR.parent != REPO_ROOT or not BUILD_DIR.name.startswith("build"):
        raise CheckFailure(
            f"Refusing to remove unexpected build directory outside repo policy: {BUILD_DIR}"
        )
    shutil.rmtree(BUILD_DIR)


if __name__ == "__main__":
    sys.exit(main())
