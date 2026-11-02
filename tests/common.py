"""
Common utilities and test harness for Whisky E2E testing.
Provides Wine process management, environment setup, log scraping, and crash inspection.
"""

import os
import sys
import time
import subprocess
import signal
import re
from pathlib import Path
from typing import Dict, List, Optional, Tuple, Any

# Standard Wine & Whisky Paths
DEFAULT_WINE_PREFIX = os.getenv(
    "WINEPREFIX",
    os.path.expanduser(
        "~/Library/Containers/com.franke.Whisky/Bottles/9C6C4CD2-82BE-43E9-81E5-8AF2591EA484"
    ),
)
DEFAULT_WINE_ROOT = os.getenv(
    "WINE_ROOT",
    os.path.expanduser("~/Library/Application Support/com.franke.Whisky/Libraries/Wine"),
)
DEFAULT_WINE_LOADER = os.path.join(DEFAULT_WINE_ROOT, "bin", "wine64")
DEFAULT_WINESERVER = os.path.join(DEFAULT_WINE_ROOT, "bin", "wineserver")
DEFAULT_DYLD_PATH = f"{DEFAULT_WINE_ROOT}/lib:/usr/lib"
DEFAULT_GAME_EXE = os.path.join(
    DEFAULT_WINE_PREFIX,
    "drive_c", "Program Files (x86)", "Steam", "steamapps", "common", "Aokana", "Aokana.exe"
)
DEFAULT_CRASH_DIR = os.path.join(
    DEFAULT_WINE_PREFIX,
    "drive_c", "users", "crossover", "AppData", "Local", "Temp", "NekoNyanSoft", "Aokana", "Crashes"
)
DEFAULT_UNITY_OUTPUT_LOG = os.path.join(
    DEFAULT_WINE_PREFIX,
    "drive_c", "users", "crossover", "AppData", "LocalLow", "NekoNyanSoft", "Aokana", "output_log.txt"
)


def get_unity_output_log() -> str:
    """Reads Unity engine output_log.txt if present."""
    if os.path.exists(DEFAULT_UNITY_OUTPUT_LOG):
        try:
            with open(DEFAULT_UNITY_OUTPUT_LOG, "r", encoding="utf-8", errors="replace") as f:
                return f.read()
        except Exception:
            return ""
    return ""



class TestResult:
    def __init__(
        self,
        test_id: str,
        name: str,
        tier: int,
        passed: bool,
        message: str = "",
        duration_sec: float = 0.0,
        details: Optional[Dict[str, Any]] = None
    ):
        self.test_id = test_id
        self.name = name
        self.tier = tier
        self.passed = passed
        self.message = message
        self.duration_sec = duration_sec
        self.details = details or {}

    def to_dict(self) -> Dict[str, Any]:
        return {
            "test_id": self.test_id,
            "name": self.name,
            "tier": self.tier,
            "passed": self.passed,
            "message": self.message,
            "duration_sec": round(self.duration_sec, 3),
            "details": self.details,
        }


def get_default_env(extra_env: Optional[Dict[str, str]] = None) -> Dict[str, str]:
    """Returns the standard Whisky execution environment variables."""
    env = os.environ.copy()
    env["WINEPREFIX"] = DEFAULT_WINE_PREFIX
    env["WINELOADER"] = DEFAULT_WINE_LOADER
    env["WINESERVER"] = DEFAULT_WINESERVER
    env["DYLD_FALLBACK_LIBRARY_PATH"] = DEFAULT_DYLD_PATH
    env["WINEMSYNC"] = "1"
    env["MVK_CONFIG_EXTERNAL_MEMORY_HOST"] = "0"
    if extra_env:
        env.update(extra_env)
    return env


def kill_wineserver(timeout: float = 5.0) -> None:
    """Kills any running wineserver and child wine processes cleanly."""
    # Kill any lingering game executables
    try:
        subprocess.run(["pkill", "-9", "-f", "Aokana.exe"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass

    if os.path.exists(DEFAULT_WINESERVER):
        try:
            subprocess.run([DEFAULT_WINESERVER, "-k"], timeout=timeout, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass



def get_crash_directories() -> List[str]:
    """Returns sorted list of crash directory names in the bottle."""
    if not os.path.exists(DEFAULT_CRASH_DIR):
        return []
    try:
        return sorted([
            d for d in os.listdir(DEFAULT_CRASH_DIR)
            if os.path.isdir(os.path.join(DEFAULT_CRASH_DIR, d)) and d.startswith("Crash_")
        ])
    except Exception:
        return []


def check_crash_dump_for_null_pagefault(crash_dir_name: str) -> bool:
    """Checks whether a specific crash dump error.log contains the 0x00000050 page fault."""
    error_log = os.path.join(DEFAULT_CRASH_DIR, crash_dir_name, "error.log")
    if not os.path.exists(error_log):
        return False
    try:
        with open(error_log, "r", encoding="utf-8", errors="replace") as f:
            content = f.read()
            return "00000050" in content or "EDI:    0x00000050" in content
    except Exception:
        return False


def run_wine_command(
    args: List[str],
    extra_env: Optional[Dict[str, str]] = None,
    timeout_sec: Optional[float] = 10.0,
    terminate_on_timeout: bool = True
) -> Tuple[int, str, str, bool]:
    """
    Executes a Wine command using the standard bottle environment.
    Returns: (exit_code, stdout_str, stderr_str, timed_out)
    """
    env = get_default_env(extra_env)
    cmd = [DEFAULT_WINE_LOADER] + args
    timed_out = False

    proc = subprocess.Popen(
        cmd,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        errors="replace"
    )

    try:
        stdout, stderr = proc.communicate(timeout=timeout_sec)
        exit_code = proc.returncode
    except subprocess.TimeoutExpired:
        timed_out = True
        if terminate_on_timeout:
            proc.send_signal(signal.SIGINT)
            try:
                stdout, stderr = proc.communicate(timeout=3.0)
            except subprocess.TimeoutExpired:
                proc.kill()
                stdout, stderr = proc.communicate()
            exit_code = proc.returncode if proc.returncode is not None else -1
        else:
            proc.kill()
            stdout, stderr = proc.communicate()
            exit_code = -1

    return exit_code, stdout or "", stderr or "", timed_out


def run_game_with_sampling(
    duration_sec: float = 5.0,
    extra_env: Optional[Dict[str, str]] = None
) -> Tuple[int, str, List[str]]:
    """
    Runs Aokana.exe for `duration_sec`, capturing logs and newly created crash folders.
    Returns: (exit_code, combined_logs, crash_files_created)
    """
    import tempfile
    initial_crashes = set(get_crash_directories())
    
    default_env = get_default_env(extra_env)
    # Disable winedbg interactive prompt if not specified
    if "WINEDLLOVERRIDES" in default_env:
        if "winedbg.exe" not in default_env["WINEDLLOVERRIDES"]:
            default_env["WINEDLLOVERRIDES"] = f"winedbg.exe=d;{default_env['WINEDLLOVERRIDES']}"
    else:
        default_env["WINEDLLOVERRIDES"] = "winedbg.exe=d"

    # Clear any previous unity output log to capture fresh run data
    if os.path.exists(DEFAULT_UNITY_OUTPUT_LOG):
        try:
            os.remove(DEFAULT_UNITY_OUTPUT_LOG)
        except Exception:
            pass

    # Strictly run headlessly with -batchmode to avoid disruptive GUI popups
    cmd = [
        DEFAULT_WINE_LOADER,
        DEFAULT_GAME_EXE,
        "-batchmode",
        "-logFile",
        r"C:\users\crossover\AppData\LocalLow\NekoNyanSoft\Aokana\output_log.txt",
    ]

    with tempfile.NamedTemporaryFile(mode="w+", encoding="utf-8", errors="replace", delete=False) as log_file:

        log_file_path = log_file.name

        proc = subprocess.Popen(
            cmd,
            env=default_env,
            stdout=log_file,
            stderr=subprocess.STDOUT,
            start_new_session=True
        )

        start_time = time.time()
        exit_code = 0

        try:
            while time.time() - start_time < duration_sec:
                if proc.poll() is not None:
                    break
                time.sleep(0.2)

            if proc.poll() is None:
                try:
                    os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
                except Exception:
                    pass
                time.sleep(0.3)
                if proc.poll() is None:
                    try:
                        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
                    except Exception:
                        pass
            exit_code = proc.poll() or 0
        except Exception:
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            except Exception:
                pass
            exit_code = -1

    # Read back collected log content
    try:
        with open(log_file_path, "r", encoding="utf-8", errors="replace") as f:
            combined_log = f.read()
    except Exception:
        combined_log = ""
    finally:
        if os.path.exists(log_file_path):
            os.remove(log_file_path)

    # Allow wineserver to flush crash files and unity logs
    time.sleep(0.3)

    # Append fresh unity engine output log if present
    unity_log = get_unity_output_log()
    if unity_log:
        combined_log = f"{combined_log}\n[Unity Engine Log]\n{unity_log}"

    post_crashes = set(get_crash_directories())
    new_crashes = sorted(list(post_crashes - initial_crashes))

    return exit_code, combined_log, new_crashes


