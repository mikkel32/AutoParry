#!/usr/bin/env python3
"""Developer-friendly harness runner for AutoParry tests.

This script orchestrates common harness workflows:
- Automatically rebuilds the test place if sources changed.
- Runs the smoke/spec/performance/accuracy suites via run-in-roblox.
- Streams output with rich parsing for pass/fail counters.
- Captures `[ARTIFACT]`, `[PERF]`, and `[ACCURACY]` payloads into
  `tests/artifacts/` for later inspection.
- Emits per-suite logs under `tests/artifacts/logs/`.

Example usage:
    python tests/run_harness.py --suite all
    python tests/run_harness.py --suite spec --force-build
    python tests/run_harness.py --list

The script degrades gracefully when optional tooling (rojo, run-in-roblox)
are missing by providing actionable remediation hints.
"""
from __future__ import annotations

import argparse
import io
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import textwrap
import time
import urllib.request
import zipfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Optional, Sequence, Tuple, Union

ROOT = Path(__file__).resolve().parents[1]
TESTS_DIR = ROOT / "tests"
ARTIFACTS_DIR = TESTS_DIR / "artifacts"
LOG_DIR = ARTIFACTS_DIR / "logs"
PLACE_FILE = TESTS_DIR / "AutoParryHarness.rbxl"
BUILD_SCRIPT = TESTS_DIR / "build-place.sh"
RUN_IN_ROBLOX = "run-in-roblox"
SOURCE_MAP_PATH = TESTS_DIR / "fixtures" / "AutoParrySourceMap.lua"
SOURCE_MAP_SCRIPT = TESTS_DIR / "tools" / "generate_source_map.py"
SPEC_RUNNER_SCRIPT = TESTS_DIR / "tools" / "run_specs.luau"
PERF_BASELINE_PATH = TESTS_DIR / "perf" / "baseline.json"
TOOLS_BIN_DIR = TESTS_DIR / "tools" / "bin"

LUNE_VERSION = "0.10.3"
LUNE_RELEASE_URL = "https://github.com/lune-org/lune/releases/download/v{version}/{asset}"
LUNE_PLATFORM_ASSETS: Dict[Tuple[str, str], str] = {
    ("linux", "x86_64"): "linux-x86_64",
    ("linux", "amd64"): "linux-x86_64",
    ("linux", "aarch64"): "linux-aarch64",
    ("linux", "arm64"): "linux-aarch64",
    ("darwin", "x86_64"): "macos-x86_64",
    ("darwin", "amd64"): "macos-x86_64",
    ("darwin", "aarch64"): "macos-aarch64",
    ("darwin", "arm64"): "macos-aarch64",
    ("windows", "x86_64"): "windows-x86_64",
    ("windows", "amd64"): "windows-x86_64",
    ("windows", "aarch64"): "windows-aarch64",
    ("windows", "arm64"): "windows-aarch64",
}


def _normalise_system(value: str) -> str:
    system = value.lower()
    if system.startswith("linux"):
        return "linux"
    if system.startswith("darwin") or system.startswith("mac"):
        return "darwin"
    if system.startswith("windows") or system.startswith("win"):
        return "windows"
    return system


def _normalise_machine(value: str) -> str:
    machine = value.lower()
    if machine in {"x86_64", "amd64"}:
        return "x86_64"
    if machine in {"arm64", "aarch64"}:
        return "aarch64"
    return machine


def _lune_asset_name() -> Tuple[str, str, str]:
    system = _normalise_system(platform.system())
    machine = _normalise_machine(platform.machine())
    asset_key = (system, machine)
    suffix = LUNE_PLATFORM_ASSETS.get(asset_key)
    if not suffix:
        raise RuntimeError(
            f"unsupported platform for Lune bootstrap: {platform.system()} {platform.machine()}"
        )
    asset = f"lune-{LUNE_VERSION}-{suffix}.zip"
    executable = "lune.exe" if system == "windows" else "lune"
    return asset, executable, system


def _download_lune_binary(destination: Path) -> Path:
    asset, executable_name, system = _lune_asset_name()
    url = LUNE_RELEASE_URL.format(version=LUNE_VERSION, asset=asset)
    destination.mkdir(parents=True, exist_ok=True)
    print(
        f"[run-harness] Downloading Lune {LUNE_VERSION} ({asset}) to {destination.relative_to(ROOT)} …"
    )
    try:
        with urllib.request.urlopen(url) as response:
            payload = response.read()
    except OSError as err:
        raise RuntimeError(f"failed to download {url}: {err}") from err

    try:
        with zipfile.ZipFile(io.BytesIO(payload)) as archive:
            archive.extractall(destination)
    except (OSError, zipfile.BadZipFile) as err:
        raise RuntimeError(f"failed to extract Lune archive: {err}") from err

    executable_path = destination / executable_name
    if not executable_path.exists():
        raise RuntimeError(
            f"Lune archive did not provide expected executable at {executable_path}"
        )

    if system != "windows":
        executable_path.chmod(0o755)

    print(
        f"[run-harness] Installed Lune {LUNE_VERSION} → {executable_path.relative_to(ROOT)}"
    )
    return executable_path


def ensure_lune_cli(preferred: str, *, dry_run: bool = False) -> Optional[str]:
    resolved = shutil.which(preferred)
    if resolved:
        return resolved

    candidate = Path(preferred)
    if candidate.is_file():
        return str(candidate.resolve())

    if dry_run:
        return None

    install_root = TOOLS_BIN_DIR / f"lune-{LUNE_VERSION}"
    executable_name = "lune.exe" if _normalise_system(platform.system()) == "windows" else "lune"
    executable_path = install_root / executable_name
    if executable_path.exists():
        return str(executable_path.resolve())

    return str(_download_lune_binary(install_root).resolve())


@dataclass(frozen=True)
class HarnessContext:
    run_in_roblox: str
    place_file: Path
    spec_engine: str
    lune_executable: Optional[str] = None


@dataclass(frozen=True)
class SuiteConfig:
    description: str
    command_factory: Callable[[HarnessContext], Sequence[str]]
    optional: bool = False
    requires_place: Union[bool, Callable[[HarnessContext], bool]] = False
    repeatable: bool = True
    requires_source_map: Union[bool, Callable[[HarnessContext], bool]] = False


def suite_requires_place(config: SuiteConfig, ctx: HarnessContext) -> bool:
    requirement = config.requires_place
    if callable(requirement):
        return bool(requirement(ctx))
    return bool(requirement)


def suite_requires_source_map(config: SuiteConfig, ctx: HarnessContext) -> bool:
    requirement = config.requires_source_map
    if callable(requirement):
        return bool(requirement(ctx))
    return bool(requirement)


def _roblox_suite(script_path: Path, description: str) -> SuiteConfig:
    script = str(script_path)

    def factory(ctx: HarnessContext) -> Sequence[str]:
        return [ctx.run_in_roblox, "--place", str(ctx.place_file), "--script", script]

    return SuiteConfig(
        description=description,
        command_factory=factory,
        requires_place=True,
        requires_source_map=True,
    )


def _spec_suite() -> SuiteConfig:

    def factory(ctx: HarnessContext) -> Sequence[str]:
        if ctx.spec_engine == "lune":
            exe = ctx.lune_executable or "lune"
            return [exe, "run", str(SPEC_RUNNER_SCRIPT), "--root", str(ROOT)]
        return [
            ctx.run_in_roblox,
            "--place",
            str(ctx.place_file),
            "--script",
            str(TESTS_DIR / "spec.server.lua"),
        ]

    return SuiteConfig(
        description="Comprehensive spec suite (UI snapshot, loader integration, API).",
        command_factory=factory,
        requires_place=lambda ctx: ctx.spec_engine == "roblox",
        requires_source_map=True,
    )


def _cli_suite(
    command: Sequence[str],
    description: str,
    *,
    optional: bool = False,
    repeatable: bool = False,
) -> SuiteConfig:
    frozen_command = tuple(command)

    def factory(_ctx: HarnessContext) -> Sequence[str]:
        return list(frozen_command)

    return SuiteConfig(
        description=description,
        command_factory=factory,
        optional=optional,
        repeatable=repeatable,
    )


SUITES: Dict[str, SuiteConfig] = {
    "format": _cli_suite(
        [
            "stylua",
            "--check",
            str(ROOT / "loader.lua"),
            str(ROOT / "src"),
            str(TESTS_DIR),
        ],
        "Stylua formatting guard across loader, src, and tests.",
        optional=True,
    ),
    "lint": _cli_suite(
        [
            "selene",
            "--config",
            str(ROOT / "selene.toml"),
            str(ROOT / "loader.lua"),
            str(ROOT / "src"),
            str(TESTS_DIR),
        ],
        "Selene linting with the repository standard library overrides.",
        optional=True,
    ),
    "typecheck": _cli_suite(
        [
            "luau-analyze",
            "--definitions",
            str(ROOT / "luau.yml"),
            str(ROOT / "src"),
            str(TESTS_DIR),
        ],
        "Luau static analysis against src/ and tests/ fixtures.",
        optional=True,
    ),
    "smoke": _roblox_suite(
        TESTS_DIR / "init.server.lua",
        "Bootstrap smoke test to ensure the loader mounts correctly.",
    ),
    "spec": _spec_suite(),
    "perf": _roblox_suite(
        TESTS_DIR / "perf" / "heartbeat_benchmark.server.lua",
        "Heartbeat performance benchmark with perf.json artifact output.",
    ),
    "accuracy": _roblox_suite(
        TESTS_DIR / "perf" / "parry_accuracy.server.lua",
        "Deterministic parry accuracy workload with violation reporting.",
    ),
}


SUITE_ALIASES: Dict[str, List[str]] = {
    "all": list(SUITES.keys()),
    "static": ["format", "lint", "typecheck"],
    "roblox": ["smoke", "spec", "perf", "accuracy"],
}

OPTIONAL_DEP_HINTS: Dict[str, str] = {
    "stylua": "Install via https://github.com/JohnnyMorganz/StyLua or `cargo install stylua`.",
    "selene": "Install via https://github.com/Kampfkarren/selene/releases and ensure it is on PATH.",
    "luau-analyze": "Install the Luau CLI (https://github.com/Roblox/luau) and expose `luau-analyze` on PATH.",
    "lune": (
        "The harness can download a portable Lune binary automatically; install manually via "
        "https://lune-org.github.io/docs/ if the bootstrap fails."
    ),
}

ARTIFACT_PATTERNS: Tuple[Tuple[re.Pattern[str], str], ...] = (
    (re.compile(r"^\[ARTIFACT\]\s+(\S+)\s+(.*)$"), "{name}"),
    (re.compile(r"^\[PERF\]\s+(.*)$"), "perf"),
    (re.compile(r"^\[ACCURACY\]\s+(.*)$"), "parry-accuracy"),
)

PASS_PATTERN = re.compile(r"^\[PASS\]\s+(.*)$")
FAIL_PATTERN = re.compile(r"^\[FAIL\]\s+(.*)$")
SUMMARY_PATTERN = re.compile(r"^\[(?:AutoParrySpec|ParryAccuracy|HeartbeatBenchmark)\]\s+(.*)$")


def human_join(items: Sequence[str], fallback: str = "none") -> str:
    if not items:
        return fallback
    if len(items) == 1:
        return items[0]
    return ", ".join(items[:-1]) + f" and {items[-1]}"


def build_display_name(name: str, iteration: int, total: int) -> str:
    return name if total <= 1 else f"{name} (run {iteration}/{total})"


def is_executable_available(executable: str) -> bool:
    if os.path.sep in executable or (os.path.altsep and os.path.altsep in executable):
        return Path(executable).exists()
    return shutil.which(executable) is not None


def load_json_file(path: Path) -> Optional[Any]:
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError):
        return None


def find_latest_source_mtime() -> float:
    """Return the most recent mtime among tracked sources for the harness."""
    tracked_paths: List[Path] = [
        ROOT / "loader.lua",
        TESTS_DIR / "perf" / "config.lua",
        TESTS_DIR / "perf" / "parry_accuracy.config.lua",
        TESTS_DIR / "fixtures" / "ui_snapshot.json",
        TESTS_DIR / "fixtures" / "place.project.json",
        BUILD_SCRIPT,
    ]

    src_root = ROOT / "src"
    for path in src_root.rglob("*.lua"):
        tracked_paths.append(path)

    latest = 0.0
    for path in tracked_paths:
        if not path.exists():
            continue
        try:
            latest = max(latest, path.stat().st_mtime)
        except OSError:
            continue
    return latest


def ensure_source_map(force: bool = False, dry_run: bool = False) -> bool:
    """Regenerate the AutoParry source map when inputs changed."""

    needs_refresh = force or not SOURCE_MAP_PATH.exists()

    if not needs_refresh and SOURCE_MAP_PATH.exists():
        try:
            current_mtime = SOURCE_MAP_PATH.stat().st_mtime
        except OSError:
            current_mtime = 0.0
        needs_refresh = current_mtime < find_latest_source_mtime()

    if not needs_refresh:
        return False

    if dry_run:
        print("[run-harness] Would regenerate AutoParry source map (dry-run enabled)")
        return False

    print("[run-harness] Regenerating AutoParry source map …")
    try:
        subprocess.run(
            [sys.executable, str(SOURCE_MAP_SCRIPT), str(ROOT), str(SOURCE_MAP_PATH)],
            check=True,
        )
    except subprocess.CalledProcessError as exc:
        raise RuntimeError(
            f"Failed to generate source map (exit code {exc.returncode})"
        ) from exc

    return True


def ensure_place(force: bool = False, dry_run: bool = False) -> bool:
    """Rebuild the Rojo place if required.

    Returns True when a rebuild occurred, False otherwise.
    """
    needs_build = force or not PLACE_FILE.exists()

    if not needs_build and PLACE_FILE.exists():
        try:
            place_mtime = PLACE_FILE.stat().st_mtime
        except OSError:
            place_mtime = 0.0
        needs_build = place_mtime < find_latest_source_mtime()

    if not needs_build:
        return False

    if dry_run:
        print("[run-harness] Would rebuild test place (dry-run enabled)")
        return False

    if not shutil.which("python3"):
        raise RuntimeError("python3 is required to rebuild the harness place")

    if not shutil.which("rojo"):
        raise RuntimeError(
            "rojo CLI not found. Install via https://rojo.space/docs/v7/getting-started/"
        )

    print("[run-harness] Rebuilding Rojo test place via tests/build-place.sh …")
    try:
        subprocess.run([str(BUILD_SCRIPT)], check=True)
    except subprocess.CalledProcessError as exc:
        raise RuntimeError(f"Failed to rebuild harness place (exit code {exc.returncode})") from exc

    return True


@dataclass
class SuiteResult:
    name: str
    display_name: str
    iteration: int
    command: Sequence[str]
    returncode: int
    duration: float
    log_path: Optional[Path]
    artifacts: Dict[str, Path] = field(default_factory=dict)
    passed_cases: List[str] = field(default_factory=list)
    failed_cases: List[str] = field(default_factory=list)
    summary_lines: List[str] = field(default_factory=list)
    skipped: bool = False
    optional: bool = False

    @property
    def succeeded(self) -> bool:
        if self.skipped:
            return self.optional
        return self.returncode == 0


class SuiteRunner:
    def __init__(
        self,
        base_name: str,
        iteration: int,
        total_iterations: int,
        command: Sequence[str],
        log_path: Path,
        artifact_dir: Path,
        *,
        optional: bool = False,
    ) -> None:
        self.base_name = base_name
        self.iteration = iteration
        self.total_iterations = total_iterations
        self.display_name = (
            base_name
            if total_iterations <= 1
            else f"{base_name} (run {iteration}/{total_iterations})"
        )
        self.command = list(command)
        self.log_path = log_path
        self.artifact_dir = artifact_dir
        self.optional = optional
        self.artifact_dir.mkdir(parents=True, exist_ok=True)
        self._artifacts: Dict[str, Path] = {}
        self._passed: List[str] = []
        self._failed: List[str] = []
        self._summary: List[str] = []

    def _write_artifact(self, name: str, payload: str) -> None:
        try:
            data = json.loads(payload)
        except json.JSONDecodeError as err:
            print(f"[run-harness] Failed to decode artifact {name}: {err}", file=sys.stderr)
            return

        artifact_path = self.artifact_dir / f"{name}.json"
        try:
            with artifact_path.open("w", encoding="utf-8") as handle:
                json.dump(data, handle, indent=2, sort_keys=True)
                handle.write("\n")
        except OSError as err:
            print(f"[run-harness] Failed to write artifact {artifact_path}: {err}", file=sys.stderr)
            return

        self._artifacts[name] = artifact_path
        print(f"[run-harness] Captured artifact {name} → {artifact_path.relative_to(ROOT)}")

    def _handle_line(self, line: str) -> None:
        stripped = line.strip()
        if not stripped:
            return

        for pattern, name_template in ARTIFACT_PATTERNS:
            match = pattern.match(stripped)
            if match:
                groups = match.groups()
                payload = groups[-1]
                if "{name}" in name_template:
                    artifact_name = name_template.format(name=groups[0])
                    payload = groups[1]
                else:
                    artifact_name = name_template
                self._write_artifact(artifact_name, payload)
                return

        match = PASS_PATTERN.match(stripped)
        if match:
            self._passed.append(match.group(1))
            return

        match = FAIL_PATTERN.match(stripped)
        if match:
            self._failed.append(match.group(1))
            return

        match = SUMMARY_PATTERN.match(stripped)
        if match:
            self._summary.append(match.group(1))

    def run(self, env: Optional[Dict[str, str]] = None) -> SuiteResult:
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        start = time.time()
        print(f"[run-harness] ▶ Running {self.display_name} …")

        with self.log_path.open("w", encoding="utf-8") as log_file:
            try:
                process = subprocess.Popen(
                    self.command,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    env=env,
                )
            except FileNotFoundError as err:
                raise RuntimeError(f"Failed to spawn {self.command[0]}: {err}") from err

            assert process.stdout is not None
            for raw_line in process.stdout:
                log_file.write(raw_line)
                log_file.flush()
                print(raw_line, end="")
                self._handle_line(raw_line)

            process.wait()
            returncode = process.returncode or 0

        duration = time.time() - start
        status = "PASSED" if returncode == 0 else f"FAILED (exit {returncode})"
        artifact_names = human_join(sorted(self._artifacts), "no artifacts")
        print(
            f"[run-harness] ◀ {self.display_name} {status} in {duration:.1f}s — captured {artifact_names}.\n"
        )

        return SuiteResult(
            name=self.base_name,
            display_name=self.display_name,
            iteration=self.iteration,
            command=self.command,
            returncode=returncode,
            duration=duration,
            log_path=self.log_path,
            artifacts=self._artifacts.copy(),
            passed_cases=list(self._passed),
            failed_cases=list(self._failed),
            summary_lines=list(self._summary),
            optional=self.optional,
        )


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    suite_choices = list(SUITES.keys()) + [alias for alias in SUITE_ALIASES if alias not in SUITES]
    parser = argparse.ArgumentParser(
        description="Run the AutoParry Roblox harness with developer-friendly ergonomics.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=textwrap.dedent(
            """Examples:
  python tests/run_harness.py --list
  python tests/run_harness.py --suite spec
  python tests/run_harness.py --suite perf --force-build
  python tests/run_harness.py --suite spec --suite accuracy --keep-artifacts
"""
        ),
    )

    parser.add_argument(
        "--suite",
        action="append",
        dest="suites",
        choices=suite_choices,
        help="One or more suites to run (defaults to 'all').",
    )
    parser.add_argument("--list", action="store_true", help="List available suites and exit.")
    parser.add_argument("--skip-build", action="store_true", help="Skip the place rebuild check.")
    parser.add_argument("--force-build", action="store_true", help="Always rebuild the test place before running.")
    parser.add_argument("--dry-run", action="store_true", help="Print the commands without executing them.")
    parser.add_argument(
        "--keep-artifacts",
        action="store_true",
        help="Preserve existing artifacts instead of clearing before the run.",
    )
    parser.add_argument(
        "--run-in-roblox",
        default=RUN_IN_ROBLOX,
        help="Override the run-in-roblox executable path.",
    )
    parser.add_argument(
        "--lune",
        default="lune",
        help="Override the lune executable for the Luau-based spec runner.",
    )
    parser.add_argument(
        "--spec-engine",
        choices=["auto", "roblox", "lune"],
        default="auto",
        help="Select the execution engine for the spec suite (defaults to auto).",
    )
    parser.add_argument(
        "--env",
        action="append",
        metavar="KEY=VALUE",
        help="Extra environment variables to expose to run-in-roblox.",
    )
    parser.add_argument(
        "--repeat",
        type=int,
        default=1,
        metavar="N",
        help="Repeat Roblox-backed suites N times to detect flakiness (default: 1).",
    )

    return parser.parse_args(argv)


def list_suites() -> None:
    print("Available suites:")
    placeholder_ctx = HarnessContext(
        run_in_roblox=RUN_IN_ROBLOX,
        place_file=PLACE_FILE,
        spec_engine="roblox",
        lune_executable="lune",
    )
    for name, config in SUITES.items():
        kind = "Roblox" if suite_requires_place(config, placeholder_ctx) else "Static"
        print(f"  - {name:10s} [{kind}] {config.description}")
        try:
            command = config.command_factory(placeholder_ctx)
        except Exception:
            command = []
        if suite_requires_place(config, placeholder_ctx) and command:
            try:
                script_index = command.index("--script") + 1
                script_path = Path(command[script_index]).resolve()
                rel = script_path.relative_to(ROOT)
            except (ValueError, IndexError):
                rel = command[-1] if command else "?"
            print(f"      script: {rel}")
        elif command:
            preview = " ".join(command)
            print(f"      command: {preview}")
    if SUITE_ALIASES:
        print("\nSuite groups:")
        for alias, members in SUITE_ALIASES.items():
            print(f"  - {alias:10s} → {', '.join(members)}")


def resolve_suites(selected: Optional[Sequence[str]]) -> List[str]:
    if not selected:
        selected = ["all"]

    expanded: List[str] = []
    for item in selected:
        if item in SUITE_ALIASES:
            expanded.extend(SUITE_ALIASES[item])
        else:
            expanded.append(item)

    resolved: List[str] = []
    seen = set()
    for name in expanded:
        if name not in SUITES or name in seen:
            continue
        seen.add(name)
        resolved.append(name)
    return resolved


def parse_env_overrides(items: Optional[Sequence[str]]) -> Dict[str, str]:
    result: Dict[str, str] = {}
    if not items:
        return result
    for item in items:
        if "=" not in item:
            raise ValueError(f"Invalid --env override '{item}', expected KEY=VALUE")
        key, value = item.split("=", 1)
        result[key] = value
    return result


def clear_artifacts() -> None:
    if not ARTIFACTS_DIR.exists():
        return
    for path in ARTIFACTS_DIR.iterdir():
        try:
            if path.is_dir():
                shutil.rmtree(path)
            else:
                path.unlink()
        except OSError:
            pass


def summarise_perf_result(result: SuiteResult) -> None:
    if result.skipped:
        return

    artifact_path = result.artifacts.get("perf")
    if not artifact_path:
        return

    try:
        with artifact_path.open("r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except (OSError, json.JSONDecodeError) as err:
        result.summary_lines.append(f"perf artifact parse failed: {err}")
        return

    if not isinstance(payload, dict):
        result.summary_lines.append("perf artifact payload not a JSON object")
        return

    summary = payload.get("summary")
    if not isinstance(summary, dict):
        summary = {}

    lines: List[str] = []

    metrics_bits: List[str] = []
    average = summary.get("average")
    p95 = summary.get("p95")
    samples = summary.get("samples")
    if isinstance(average, (int, float)):
        metrics_bits.append(f"mean {average * 1000:.2f} ms")
    if isinstance(p95, (int, float)):
        metrics_bits.append(f"p95 {p95 * 1000:.2f} ms")
    if isinstance(samples, int) and samples > 0:
        metrics_bits.append(f"{samples} samples")
    if metrics_bits:
        lines.append(", ".join(metrics_bits))

    thresholds = payload.get("thresholds")
    if isinstance(thresholds, dict):
        margin_bits: List[str] = []
        threshold_average = thresholds.get("average")
        threshold_p95 = thresholds.get("p95")
        if isinstance(threshold_average, (int, float)) and isinstance(average, (int, float)):
            margin_bits.append(f"avg margin {(threshold_average - average) * 1000:+.2f} ms")
        if isinstance(threshold_p95, (int, float)) and isinstance(p95, (int, float)):
            margin_bits.append(f"p95 margin {(threshold_p95 - p95) * 1000:+.2f} ms")
        if margin_bits:
            lines.append("threshold margins " + ", ".join(margin_bits))

    baseline_payload = load_json_file(PERF_BASELINE_PATH)
    if isinstance(baseline_payload, dict):
        baseline_summary = baseline_payload.get("summary")
        if isinstance(baseline_summary, dict):
            baseline_bits: List[str] = []
            baseline_average = baseline_summary.get("average")
            baseline_p95 = baseline_summary.get("p95")
            if isinstance(baseline_average, (int, float)) and isinstance(average, (int, float)):
                baseline_bits.append(
                    f"Δavg {(average - baseline_average) * 1000:+.2f} ms vs baseline"
                )
            if isinstance(baseline_p95, (int, float)) and isinstance(p95, (int, float)):
                baseline_bits.append(
                    f"Δp95 {(p95 - baseline_p95) * 1000:+.2f} ms vs baseline"
                )
            if baseline_bits:
                lines.append(", ".join(baseline_bits))

    for line in lines:
        if line:
            result.summary_lines.append(line)


def summarise_accuracy_result(result: SuiteResult) -> None:
    if result.skipped:
        return

    artifact_path = result.artifacts.get("parry-accuracy")
    if not artifact_path:
        return

    try:
        with artifact_path.open("r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except (OSError, json.JSONDecodeError) as err:
        result.summary_lines.append(f"accuracy artifact parse failed: {err}")
        return

    if not isinstance(payload, dict):
        result.summary_lines.append("accuracy artifact payload not a JSON object")
        return

    totals = payload.get("totals")
    if not isinstance(totals, dict):
        totals = {}

    metrics_bits: List[str] = []
    accuracy = totals.get("accuracy")
    precision = totals.get("precision")
    false_positives = totals.get("falsePositives")
    missed = totals.get("missed")

    if isinstance(accuracy, (int, float)):
        metrics_bits.append(f"accuracy {accuracy * 100:.2f}%")
    if isinstance(precision, (int, float)):
        metrics_bits.append(f"precision {precision * 100:.2f}%")
    if isinstance(false_positives, int):
        metrics_bits.append(f"{false_positives} false positive(s)")
    if isinstance(missed, int):
        metrics_bits.append(f"{missed} missed")
    if metrics_bits:
        result.summary_lines.append(", ".join(metrics_bits))

    failures = payload.get("failures")
    if isinstance(failures, list) and failures:
        failure_text = "; ".join(str(item) for item in failures)
        result.summary_lines.append(f"Violations: {failure_text}")

    scenarios = payload.get("scenarios")
    if isinstance(scenarios, list):
        scenario_notes: List[str] = []
        for scenario in scenarios:
            if not isinstance(scenario, dict):
                continue
            notes: List[str] = []
            scenario_false = scenario.get("falsePositives")
            scenario_missed = scenario.get("missed")
            if isinstance(scenario_false, int) and scenario_false > 0:
                notes.append(f"{scenario_false} false positive(s)")
            if isinstance(scenario_missed, int) and scenario_missed > 0:
                notes.append(f"{scenario_missed} missed")
            for key in ("frameViolation", "spacingViolation", "targetingViolation"):
                value = scenario.get(key)
                if value:
                    notes.append(str(value))
            if notes:
                scenario_notes.append(f"{scenario.get('name', 'scenario')}: {', '.join(notes)}")
        result.summary_lines.extend(scenario_notes)


SUMMARY_HOOKS: Dict[str, Tuple[Callable[[SuiteResult], None], ...]] = {
    "perf": (summarise_perf_result,),
    "accuracy": (summarise_accuracy_result,),
}


def status_label(result: SuiteResult) -> str:
    if result.skipped and result.optional:
        return "SKIP (optional)"
    if result.skipped:
        return "SKIP"
    if result.returncode == 0:
        return "PASS"
    return f"FAIL (exit {result.returncode})"


def format_single_line(suite_name: str, result: SuiteResult) -> str:
    artifacts = human_join(sorted(result.artifacts), "no artifacts")
    label = status_label(result)
    if result.skipped:
        extra = f" (artifacts: {artifacts})" if artifacts != "no artifacts" else ""
        return f"  - {suite_name:10s} {label}{extra}"
    duration = f"{result.duration:.1f}s"
    return f"  - {suite_name:10s} {label} in {duration} (artifacts: {artifacts})"


def format_result_line(prefix: str, result: SuiteResult) -> str:
    artifacts = human_join(sorted(result.artifacts), "no artifacts")
    label = status_label(result)
    if result.skipped:
        extra = f" (artifacts: {artifacts})" if artifacts != "no artifacts" else ""
        return f"{prefix}{result.display_name}: {label}{extra}"
    return (
        f"{prefix}{result.display_name}: {label} in {result.duration:.1f}s "
        f"(artifacts: {artifacts})"
    )


def format_group_header(suite_name: str, results: Sequence[SuiteResult]) -> str:
    executed = [item for item in results if not item.skipped]
    executed_passes = sum(1 for item in executed if item.returncode == 0)
    executed_fails = len(executed) - executed_passes
    optional_skips = sum(1 for item in results if item.skipped and item.optional)
    required_skips = sum(1 for item in results if item.skipped and not item.optional)

    bits: List[str] = []
    if executed:
        bits.append(f"{executed_passes}/{len(executed)} passes")
        if executed_fails:
            bits.append(f"{executed_fails} fail{'s' if executed_fails != 1 else ''}")
    if required_skips:
        bits.append(f"{required_skips} required skipped")
    if optional_skips:
        bits.append(f"{optional_skips} optional skipped")
    if not bits:
        bits.append("no runs recorded")

    return f"  - {suite_name:10s} {'; '.join(bits)}"


def emit_result_details(result: SuiteResult, indent: str = "      ") -> None:
    for detail in result.summary_lines:
        print(f"{indent}{detail}")
    if result.passed_cases or result.failed_cases:
        print(
            f"{indent}{len(result.passed_cases)} passed, {len(result.failed_cases)} failed test cases"
        )

def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)

    if args.list:
        list_suites()
        return 0

    suites_to_run = resolve_suites(args.suites)
    if not suites_to_run:
        print("[run-harness] No suites matched the provided selectors.")
        return 0

    selected_configs = [SUITES[name] for name in suites_to_run]

    run_in_roblox_available = shutil.which(args.run_in_roblox) is not None
    lune_resolved = shutil.which(args.lune)
    lune_candidate_path = Path(args.lune)
    if lune_resolved:
        lune_available = True
        lune_executable = lune_resolved
    elif lune_candidate_path.is_file():
        lune_available = True
        lune_executable = str(lune_candidate_path.resolve())
    else:
        lune_available = False
        lune_executable = args.lune

    if args.spec_engine == "roblox":
        spec_engine = "roblox"
    elif args.spec_engine == "lune":
        spec_engine = "lune"
    else:
        if run_in_roblox_available:
            spec_engine = "roblox"
        elif lune_available:
            spec_engine = "lune"
        else:
            spec_engine = "lune"

    if spec_engine == "lune":
        if not lune_available:
            try:
                resolved_lune = ensure_lune_cli(args.lune, dry_run=args.dry_run)
            except RuntimeError as err:
                print(f"[run-harness] Failed to set up Lune: {err}", file=sys.stderr)
                return 1
            if resolved_lune:
                lune_executable = resolved_lune
                lune_available = True
        else:
            lune_executable = lune_executable

        if lune_available and not shutil.which(lune_executable):
            executable_path = Path(lune_executable)
            if executable_path.exists():
                lune_executable = str(executable_path.resolve())
            else:
                lune_available = False

    harness_ctx = HarnessContext(
        run_in_roblox=args.run_in_roblox,
        place_file=PLACE_FILE,
        spec_engine=spec_engine,
        lune_executable=lune_executable,
    )

    needs_place = any(suite_requires_place(config, harness_ctx) for config in selected_configs)
    needs_source_map = any(suite_requires_source_map(config, harness_ctx) for config in selected_configs)

    if args.repeat < 1:
        print("[run-harness] --repeat expects a value >= 1", file=sys.stderr)
        return 1

    if args.dry_run:
        print("[run-harness] Dry run enabled — no commands will execute.")

    if not args.keep_artifacts and not args.dry_run:
        clear_artifacts()

    if needs_source_map:
        try:
            ensure_source_map(force=args.force_build, dry_run=args.dry_run)
        except RuntimeError as err:
            print(f"[run-harness] {err}", file=sys.stderr)
            return 1

    if needs_place and not args.skip_build:
        try:
            ensure_place(force=args.force_build, dry_run=args.dry_run)
        except RuntimeError as err:
            print(f"[run-harness] {err}", file=sys.stderr)
            return 1

    env = os.environ.copy()
    if args.env:
        try:
            env.update(parse_env_overrides(args.env))
        except ValueError as err:
            print(f"[run-harness] {err}", file=sys.stderr)
            return 1

    run_in_roblox_exe = args.run_in_roblox
    if needs_place and not shutil.which(run_in_roblox_exe) and not args.dry_run:
        print(
            "[run-harness] run-in-roblox CLI not found. Install from https://github.com/rojo-rbx/run-in-roblox",
            file=sys.stderr,
        )
        return 1

    runs_spec_suite = "spec" in suites_to_run
    if runs_spec_suite and spec_engine == "lune" and not lune_available and not args.dry_run:
        hint = OPTIONAL_DEP_HINTS.get("lune")
        message = "lune CLI not found"
        if hint:
            message = f"{message}. {hint}"
        print(f"[run-harness] {message}", file=sys.stderr)
        return 1

    results_by_suite: Dict[str, List[SuiteResult]] = {}

    for suite_name in suites_to_run:
        config = SUITES[suite_name]
        iterations = args.repeat if (config.repeatable and suite_requires_place(config, harness_ctx)) else 1

        for iteration in range(1, iterations + 1):
            display_name = build_display_name(suite_name, iteration, iterations)
            try:
                command = list(config.command_factory(harness_ctx))
            except Exception as err:
                print(
                    f"[run-harness] Failed to resolve command for {display_name}: {err}",
                    file=sys.stderr,
                )
                results_by_suite.setdefault(suite_name, []).append(
                    SuiteResult(
                        name=suite_name,
                        display_name=display_name,
                        iteration=iteration,
                        command=[],
                        returncode=1,
                        duration=0.0,
                        log_path=None,
                        artifacts={},
                        summary_lines=[f"command resolution failed: {err}"],
                        skipped=True,
                        optional=config.optional,
                    )
                )
                continue

            if args.dry_run:
                print(f"[run-harness] Would run {display_name}:", " ".join(command))
                continue

            if not command:
                results_by_suite.setdefault(suite_name, []).append(
                    SuiteResult(
                        name=suite_name,
                        display_name=display_name,
                        iteration=iteration,
                        command=[],
                        returncode=1,
                        duration=0.0,
                        log_path=None,
                        artifacts={},
                        summary_lines=["no command configured"],
                        skipped=True,
                        optional=config.optional,
                    )
                )
                continue

            executable = command[0]
            if not is_executable_available(executable):
                reason = (
                    f"requires '{executable}' on PATH"
                    if config.optional
                    else f"missing required executable '{executable}'"
                )
                if config.optional:
                    hint = OPTIONAL_DEP_HINTS.get(Path(executable).name)
                    if hint:
                        reason = f"{reason}. {hint}"
                print(f"[run-harness] Skipping {display_name} — {reason}", file=sys.stderr)
                results_by_suite.setdefault(suite_name, []).append(
                    SuiteResult(
                        name=suite_name,
                        display_name=display_name,
                        iteration=iteration,
                        command=command,
                        returncode=0,
                        duration=0.0,
                        log_path=None,
                        artifacts={},
                        summary_lines=[reason],
                        skipped=True,
                        optional=config.optional,
                    )
                )
                continue

            log_name = (
                f"{suite_name}.log" if iterations == 1 else f"{suite_name}-run-{iteration}.log"
            )
            artifact_root = ARTIFACTS_DIR / suite_name
            artifact_dir = (
                artifact_root
                if iterations == 1
                else artifact_root / f"run-{iteration}"
            )
            runner = SuiteRunner(
                suite_name,
                iteration,
                iterations,
                command,
                log_path=LOG_DIR / log_name,
                artifact_dir=artifact_dir,
                optional=config.optional,
            )
            try:
                result = runner.run(env=env)
            except RuntimeError as err:
                print(f"[run-harness] {err}", file=sys.stderr)
                return 1

            for hook in SUMMARY_HOOKS.get(suite_name, ()): 
                try:
                    hook(result)
                except Exception as hook_err:
                    result.summary_lines.append(f"summary hook failed: {hook_err}")

            results_by_suite.setdefault(suite_name, []).append(result)

    if args.dry_run:
        return 0

    if not any(results_by_suite.values()):
        print("[run-harness] No suites were executed.")
        return 0

    print("\nSummary:")
    overall_success = True
    for suite_name in suites_to_run:
        suite_results = results_by_suite.get(suite_name, [])
        if not suite_results:
            print(f"  - {suite_name:10s} not run")
            overall_success = False
            continue

        if len(suite_results) == 1:
            result = suite_results[0]
            print(format_single_line(suite_name, result))
            emit_result_details(result)
            if not result.succeeded:
                overall_success = False
            continue

        print(format_group_header(suite_name, suite_results))
        for result in suite_results:
            print(format_result_line("      ", result))
            emit_result_details(result, indent="        ")
            if not result.succeeded:
                overall_success = False

    return 0 if overall_success else 1


if __name__ == "__main__":
    sys.exit(main())
