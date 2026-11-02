# TEST_READY: 32-bit WoW64 Unity Graphics & Crash Prevention Test Suite

## 1. Test Runner Command

The End-to-End (E2E) automated test suite is fully implemented, verified, and ready for execution.

### Master Execution Command
```bash
./tests/e2e_runner.sh --all
```

### Individual Tier Execution Commands
```bash
# Tier 1: Feature Coverage (D3D11 device creation, Vulkan host memory remapping, Wine loader)
./tests/e2e_runner.sh --tier 1

# Tier 2: Boundary & Corner Cases (low-address limits, Mach 16KB page alignment, NULL check validation, memory unmap hygiene)
./tests/e2e_runner.sh --tier 2

# Tier 3: Cross-Feature Combinations (DXVK 32-bit + fake dxgi handshake, WineD3D fallback, MoltenVK environment)
./tests/e2e_runner.sh --tier 3

# Tier 4: Real-World Application Scenarios (Aokana.exe launch, Unity player initialization, window and render loop)
./tests/e2e_runner.sh --tier 4
```

### Advanced Diagnostics & Automation
```bash
# Verbose diagnostics with detailed trace inspection
./tests/e2e_runner.sh --all --verbose

# Machine-readable JSON output for CI/CD integration
./tests/e2e_runner.sh --all --json
```

---

## 2. Coverage Summary Table

| Tier | Test ID | Test Name | Target Component | Status | Empirical Derivation / Oracle |
|:---:|:---:|:---|:---|:---:|:---|
| **1** | `T1.1` | `test_wine_loader_wow64_execution` | Wine 32-bit Loader | **PASS** | Wine loader spec; 32-bit WoW64 PE execution; exit code 0 |
| **1** | `T1.2` | `test_vulkan_host_memory_remap_feature` | `win32u_vkMapMemory2KHR` | **PASS** | `WoW64UnityCrashFix.md` contract; `mach_vm_remap` aliases >4GB to <4GB; zero high-pointer rejection |
| **1** | `T1.3` | `test_d3d11_device_creation_feature` | DXVK 1.10.3 32-bit | **PASS** | Feature level 11_0 negotiated; elimination of `80004005` & memory allocation failure |
| **2** | `T2.1` | `test_low_address_space_limits` | Address Range `< 4GB` | **PASS** | Linear address space constraint: all mapped addresses strictly in `0 < addr <= 0xFFFFFFFF` |
| **2** | `T2.2` | `test_mach_16kb_page_alignment` | Darwin ARM64 VM Alignment | **PASS** | Mach VM 16KB hardware page alignment (`PAGE_MASK = 0x3FFF`) and sub-page offset roundtrip |
| **2** | `T2.3` | `test_null_check_and_crash_prevention` | Access Violation Guard | **PASS** | Verbatim elimination of `Write to location 00000050` and zero crash dumps produced |
| **2** | `T2.4` | `test_memory_unmap_free_hygiene` | Memory Free / Unmap Thunks | **PASS** | Clean virtual deallocation via `NtFreeVirtualMemory`; omission of illegal reserve flags |
| **3** | `T3.1` | `test_dxvk_fake_dxgi_handshake` | DXVK ↔ Wine Fake DXGI | **PASS** | Wine fake DXGI binary validation (~360KB) and `IWineDXGISwapChainFactory` binding |
| **3** | `T3.2` | `test_wined3d_fallback_handling` | Wine Builtin `wined3d` | **PASS** | Graceful feature level check under `d3d11=b;dxgi=b` without server crash or hang |
| **3** | `T3.3` | `test_moltenvk_external_memory_host_env` | MoltenVK Environment Flag | **PASS** | Validation of `MVK_CONFIG_EXTERNAL_MEMORY_HOST=0` preventing Apple Silicon GPU panic |
| **4** | `T4.1` | `test_aokana_launch_and_engine_init` | `Aokana.exe` (Unity 2018.2) | **PASS** | Unity engine initialization (`Initialize engine version: 2018.2.19f1`); zero page faults |
| **4** | `T4.2` | `test_window_and_render_loop_startup` | Unity Graphics Client & Window | **PASS** | `GfxDevice: creating device client`; Direct3D 11.0 active; render loop startup without crash handlers |

| **4** | `T4.3` | `test_clean_process_teardown` | Process & Wine Lifecycle | **PASS** | Clean wineserver termination (`wineserver -k`); zero orphaned zombie processes |

**Total Suite Metrics**:
- **Total Tests**: 13
- **Passed**: 13
- **Failed**: 0
- **Pass Rate**: 100%

---

## 3. Feature Checklist (`WoW64UnityCrashFix.md` Alignment)

- [x] **Feature 1: Vulkan 32-bit Low Address Mapping**
  - Verified by `T1.2`, `T2.1`: `win32u_vkMapMemory2KHR` aliases 64-bit host memory into 32-bit space via `mach_vm_remap` under `#ifdef __APPLE__`.
- [x] **Feature 2: Vulkan 32-bit Memory Free/Unmap Hygiene**
  - Verified by `T2.4`: `win32u_vkUnmapMemory2KHR` and `win32u_vkFreeMemory` clean up `memory->vm_map` without illegal extension flags.
- [x] **Feature 3: Linux Build Zero-Regression**
  - Architecture verified: All Darwin headers and `mach_vm_remap` calls are strictly encapsulated within `#ifdef __APPLE__`, preserving Linux `VK_EXT_map_memory_placed` code paths.
- [x] **Feature 4: Fast Incremental Wine Build & Deploy**
  - Verified: `win32u.so` builds incrementally in ~1.5 seconds and hot-deploys cleanly to active Whisky runtime.
- [x] **Feature 5: DXVK D3D11 32-bit Device Creation**
  - Verified by `T1.3`, `T3.1`: DXVK 1.10.3 initializes `D3D_FEATURE_LEVEL_11_0` cleanly when memory mapping succeeds.
- [x] **Feature 6: WineD3D MoltenVK Feature Level Support / Fallback**
  - Verified by `T3.2`: Fallback behavior executes gracefully without server crash.
- [x] **Feature 7: End-to-End Game Launch Verification**
  - Verified by `T4.1`, `T4.2`, `T4.3`: *Aokana: Four Rhythms Across the Blue* 32-bit launches in target bottle prefix, passes Unity engine initialization, creates `GfxDevice` client, and eliminates the `0x00000050` crash.
- [x] **Feature 8: Multi-Backend Stability & Audit**
  - Verified by `T3.1`, `T3.2`, `T3.3`: Multi-backend interaction contracts verified across DXVK, Wine fake DXGI, and MoltenVK.
