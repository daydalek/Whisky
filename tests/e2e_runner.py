#!/usr/bin/env python3
"""
E2E Test Runner for Whisky 32-bit WoW64 Unity Graphics & Crash Prevention.
Executes Tier 1 (Feature), Tier 2 (Boundary), Tier 3 (Cross-Feature), and Tier 4 (Real-World) tests.
"""

import sys
import os
import argparse
import time
import json
from typing import List

# Ensure repository root is in python path
REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if REPO_ROOT not in sys.path:
    sys.path.insert(0, REPO_ROOT)

from tests.common import TestResult, kill_wineserver, DEFAULT_WINE_PREFIX, DEFAULT_WINE_LOADER
from tests.tier1_feature_coverage import run_tier1
from tests.tier2_boundary_corner import run_tier2
from tests.tier3_cross_feature import run_tier3
from tests.tier4_real_world import run_tier4

# ANSI Colors
GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
BLUE = "\033[94m"
CYAN = "\033[96m"
BOLD = "\033[1m"
RESET = "\033[0m"


def print_banner():
    print(f"{BOLD}{BLUE}======================================================================{RESET}")
    print(f"{BOLD}{CYAN}   Whisky 32-bit WoW64 Unity Graphics & Crash Prevention E2E Suite    {RESET}")
    print(f"{BOLD}{BLUE}======================================================================{RESET}")
    print(f"Bottle Prefix : {DEFAULT_WINE_PREFIX}")
    print(f"Wine Loader   : {DEFAULT_WINE_LOADER}")
    print("----------------------------------------------------------------------\n")


def print_result_row(result: TestResult, verbose: bool = False):
    status_str = f"{GREEN}[PASS]{RESET}" if result.passed else f"{RED}[FAIL]{RESET}"
    duration_str = f"({result.duration_sec:.2f}s)"
    tier_str = f"Tier {result.tier}"
    print(f"{status_str} {BOLD}{result.test_id:<5}{RESET} [{tier_str}] {result.name:<38} {duration_str}")
    if not result.passed or verbose:
        prefix = "       └─ "
        print(f"{prefix}{YELLOW if result.passed else RED}{result.message}{RESET}")
        if verbose and result.details:
            print(f"          Details: {result.details}")


def main():
    parser = argparse.ArgumentParser(
        description="Run Whisky 32-bit WoW64 Unity E2E Test Suite (Dual Track Methodology)"
    )
    parser.add_argument("--tier", type=int, choices=[1, 2, 3, 4], help="Run a specific test tier (1, 2, 3, or 4)")
    parser.add_argument("--all", action="store_true", help="Run all test tiers sequentially (Tiers 1 to 4)")
    parser.add_argument("-v", "--verbose", action="store_true", help="Enable verbose test diagnostics")
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")

    args = parser.parse_args()

    if not args.tier and not args.all:
        args.all = True  # Default to running all tiers

    if not args.json:
        print_banner()

    # Pre-test hygiene: kill lingering wineserver
    kill_wineserver()

    results: List[TestResult] = []
    start_total = time.time()

    tiers_to_run = []
    if args.tier:
        tiers_to_run = [args.tier]
    else:
        tiers_to_run = [1, 2, 3, 4]

    tier_runners = {
        1: ("Tier 1: Feature Coverage", run_tier1),
        2: ("Tier 2: Boundary & Corner Cases", run_tier2),
        3: ("Tier 3: Cross-Feature Combinations", run_tier3),
        4: ("Tier 4: Real-World Application Scenarios", run_tier4),
    }

    for tier_num in tiers_to_run:
        tier_title, runner_fn = tier_runners[tier_num]
        if not args.json:
            print(f"{BOLD}Running {tier_title}...{RESET}")
        tier_results = runner_fn()
        for res in tier_results:
            results.append(res)
            if not args.json:
                print_result_row(res, verbose=args.verbose)
        if not args.json:
            print()

    total_duration = time.time() - start_total
    total_passed = sum(1 for r in results if r.passed)
    total_failed = sum(1 for r in results if not r.passed)
    total_tests = len(results)

    # Post-test hygiene
    kill_wineserver()

    if args.json:
        output_data = {
            "summary": {
                "total": total_tests,
                "passed": total_passed,
                "failed": total_failed,
                "duration_sec": round(total_duration, 3),
                "success": total_failed == 0,
            },
            "results": [r.to_dict() for r in results],
        }
        print(json.dumps(output_data, indent=2))
        sys.exit(0 if total_failed == 0 else 1)

    # Print Summary Table
    print(f"{BOLD}{BLUE}======================================================================{RESET}")
    print(f"{BOLD}                        E2E Execution Summary                         {RESET}")
    print(f"{BOLD}{BLUE}======================================================================{RESET}")
    print(f"Total Tests Run : {total_tests}")
    print(f"Passed          : {GREEN}{total_passed}{RESET}")
    print(f"Failed          : {RED if total_failed > 0 else GREEN}{total_failed}{RESET}")
    print(f"Total Duration  : {total_duration:.2f}s")
    print(f"Final Verdict   : {GREEN + 'PASSED' if total_failed == 0 else RED + 'FAILED'}{RESET}")
    print(f"{BOLD}{BLUE}======================================================================{RESET}\n")

    sys.exit(0 if total_failed == 0 else 1)


if __name__ == "__main__":
    main()
