from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import os
import shutil
import subprocess
import sys
import time


class CheckFailure(RuntimeError):
    """Raised when a test framework check fails."""


@dataclass
class StepResult:
    name: str
    ok: bool
    duration_seconds: float
    detail: str = ""


class TestRunner:
    def __init__(self, repo_root: Path, *, verbose: bool = False) -> None:
        self.repo_root = repo_root
        self.verbose = verbose
        self.results: list[StepResult] = []

    def info(self, message: str) -> None:
        print(f"[INFO] {message}")

    def success(self, message: str) -> None:
        print(f"[PASS] {message}")

    def failure(self, message: str) -> None:
        print(f"[FAIL] {message}", file=sys.stderr)

    def run_step(self, name: str, callback) -> None:
        self.info(name)
        started = time.monotonic()
        try:
            detail = callback() or ""
        except CheckFailure as exc:
            duration = time.monotonic() - started
            self.results.append(
                StepResult(name=name, ok=False, duration_seconds=duration, detail=str(exc))
            )
            self.failure(f"{name}: {exc}")
            raise
        duration = time.monotonic() - started
        self.results.append(
            StepResult(name=name, ok=True, duration_seconds=duration, detail=detail)
        )
        suffix = f" ({detail})" if detail else ""
        self.success(f"{name}{suffix}")

    def require_command(self, *candidates: str) -> str:
        for candidate in candidates:
            resolved = shutil.which(candidate)
            if resolved:
                return resolved
        raise CheckFailure(
            "Missing required command. Expected one of: "
            + ", ".join(candidates)
        )

    def run_command(
        self,
        name: str,
        command: list[str],
        *,
        cwd: Path | None = None,
        env: dict[str, str] | None = None,
    ) -> str:
        merged_env = os.environ.copy()
        if env:
            merged_env.update(env)

        process = subprocess.run(
            command,
            cwd=str(cwd or self.repo_root),
            env=merged_env,
            text=True,
            encoding="utf-8",
            errors="replace",
            capture_output=True,
            check=False,
        )
        if process.returncode != 0:
            raise CheckFailure(
                f"{name} failed with exit code {process.returncode}.\n"
                f"Command: {' '.join(command)}\n"
                f"{self._render_output(process.stdout, process.stderr)}"
            )
        if self.verbose:
            rendered = self._render_output(process.stdout, process.stderr)
            if rendered:
                print(rendered)
        return process.stdout

    def print_summary(self) -> None:
        print("")
        print("Summary")
        for result in self.results:
            status = "PASS" if result.ok else "FAIL"
            suffix = f" - {result.detail}" if result.detail else ""
            print(f"  [{status}] {result.name} ({result.duration_seconds:.2f}s){suffix}")

    @staticmethod
    def _render_output(stdout: str, stderr: str) -> str:
        chunks: list[str] = []
        if stdout.strip():
            chunks.append("stdout:\n" + stdout.strip())
        if stderr.strip():
            chunks.append("stderr:\n" + stderr.strip())
        return "\n".join(chunks)
