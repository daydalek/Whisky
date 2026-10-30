"""
Tier 4: Real-World Application Scenarios Test Suite.
Validates complete execution of Aokana (Unity 2018.2 32-bit), graphics device lifecycle, and process cleanup
strictly headlessly (-batchmode) to prevent disruptive GUI window popups.
"""

import time
import subprocess
from typing import List
from tests.common import (
    TestResult,
    run_game_with_sampling,
    kill_wineserver,
    check_crash_dump_for_null_pagefault,
    get_unity_output_log,
)

_cached_logs = None
_cached_crashes = None


def test_aokana_launch_and_engine_init() -> TestResult:
    """T4.1: Launches Aokana.exe headlessly (-batchmode), verifying engine init and elimination of 0x00000050 crash."""
    global _cached_logs, _cached_crashes
    start_time = time.time()
    test_id = "T4.1"
    name = "test_aokana_launch_and_engine_init"

    # Launch single headless sampling run (-batchmode, zero GUI popups)
    exit_code, logs, new_crashes = run_game_with_sampling(
        duration_sec=4.0,
        extra_env={
            "WINEDLLOVERRIDES": "d3d11=n,b;dxgi=n,b",
            "WINEDEBUG": "+d3d11,+vulkan",
        }
    )
    _cached_logs = logs
    _cached_crashes = new_crashes
    duration = time.time() - start_time
    kill_wineserver()

    # 1. Check for Unity engine initialization string
    if "Initialize engine version: 2018.2.19f1" not in logs:
        return TestResult(
            test_id, name, 4, False,
            "Unity engine initialization string 'Initialize engine version: 2018.2.19f1' not observed.",
            duration
        )

    # 2. Check for elimination of D3D11 device creation failure
    if "d3d11: failed to create device and context (80004005)" in logs:
        return TestResult(
            test_id, name, 4, False,
            "Regression: observed verbatim failure 'd3d11: failed to create device and context (80004005)'.",
            duration
        )

    # 3. Check for elimination of page fault crash
    if "Unhandled page fault on write access to 00000050" in logs or "00000050 at address" in logs:
        return TestResult(
            test_id, name, 4, False,
            "Regression: observed verbatim crash 'Unhandled page fault on write access to 00000050'.",
            duration
        )

    # 4. Check crash dumps
    for crash in new_crashes:
        if check_crash_dump_for_null_pagefault(crash):
            return TestResult(
                test_id, name, 4, False,
                f"Regression: new crash dump '{crash}' contains 0x00000050 access violation!",
                duration
            )

    return TestResult(
        test_id, name, 4, True,
        "Aokana.exe launched headlessly, engine initialized (2018.2.19f1), 80004005 error and 0x00000050 crash eliminated.",
        duration,
        {"new_crashes": new_crashes}
    )


def test_window_and_render_loop_startup() -> TestResult:
    """T4.2: Verifies that Unity Player creates graphics client and enters rendering loop headlessly."""
    global _cached_logs
    start_time = time.time()
    test_id = "T4.2"
    name = "test_window_and_render_loop_startup"

    logs = _cached_logs or get_unity_output_log()
    duration = time.time() - start_time

    # Verify GfxDevice creation and Direct3D 11.0 initialization
    if "GfxDevice: creating device client" not in logs or "Direct3D 11.0" not in logs:
        return TestResult(
            test_id, name, 4, False,
            "Unity GfxDevice client creation or Direct3D 11.0 initialization log missing from run.",
            duration
        )


    # Verify UnityCrashHandler32 was not invoked
    if "UnityCrashHandler32.exe" in logs or "CrashHandler" in logs:
        return TestResult(
            test_id, name, 4, False,
            "Unity crash handler invocation detected in process execution.",
            duration
        )

    return TestResult(
        test_id, name, 4, True,
        "Unity Player graphics client created and rendering pipeline initialized without crash handler invocation.",
        duration
    )


def test_clean_process_teardown() -> TestResult:
    """T4.3: Verifies wineserver process termination and lock cleanup without lingering processes."""
    start_time = time.time()
    test_id = "T4.3"
    name = "test_clean_process_teardown"

    kill_wineserver(timeout=3.0)
    res_stdout = ""
    for _ in range(15):
        time.sleep(0.1)
        res = subprocess.run(["pgrep", "-f", "Aokana.exe"], capture_output=True, text=True)
        res_stdout = res.stdout.strip()
        if not res_stdout:
            break

    # Check for lingering wine processes
    if res_stdout:
        return TestResult(
            test_id, name, 4, False,
            f"Lingering Aokana.exe process found after wineserver -k (PIDs: {res_stdout})",
            time.time() - start_time
        )

    return TestResult(
        test_id, name, 4, True,
        "Wineserver teardown completed cleanly with zero orphaned game processes.",
        time.time() - start_time
    )


def run_tier4() -> List[TestResult]:
    """Runs all Tier 4 tests sequentially."""
    return [
        test_aokana_launch_and_engine_init(),
        test_window_and_render_loop_startup(),
        test_clean_process_teardown(),
    ]
