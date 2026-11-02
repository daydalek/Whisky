# End-to-End (E2E) Test Infrastructure Specification: 32-bit WoW64 Unity Graphics & Crash Prevention

## 1. Overview & Dual Track Methodology

This document specifies the architecture, test design, and verification mechanics for the End-to-End (E2E) opaque-box test suite for Whisky running on macOS (Apple Silicon).
The primary objective of this test suite is to independently and definitively verify the resolution of graphics initialization failures and page fault crashes in 32-bit WoW64 Unity applications (specifically *Aokana: Four Rhythms Across the Blue* running Unity 2018.2).

### 1.1 Dual Track Architecture
Under the Dual Track methodology, testing covers two complementary execution routes:
- **Track A (Direct3D 11 Primary Route)**: DXVK 1.10.3 32-bit PE (`d3d11.dll`) paired with Wine builtin fake `dxgi.dll` (`IWineDXGISwapChainFactory`), allocating device memory through Vulkan and MoltenVK.
- **Track B (Native Vulkan Fallback Route)**: Unity's fallback 32-bit experimental Vulkan renderer (`[Vulkan init]`), requesting device memory mappings through `win32u_vkMapMemory2KHR`.

Both tracks converge upon Wine's Unix Vulkan thunk (`dlls/win32u/vulkan.c`). The test suite validates both routes across 4 distinct test tiers, verifying that host memory allocations > 4GB from MoltenVK on 64-bit macOS are aliased into the `< 4GB` virtual address space via Darwin's `mach_vm_remap` under `#ifdef __APPLE__`, eliminating the fatal `VK_ERROR_OUT_OF_HOST_MEMORY` and the resulting `0x00000050` page fault.

```
                  ┌────────────────────────────────────────┐
                  │          Dual Track E2E Suite          │
                  └───────────────────┬────────────────────┘
                                      │
          ┌───────────────────────────┴───────────────────────────┐
          ▼                                                       ▼
┌──────────────────┐                                    ┌──────────────────┐
│ Track A: D3D11   │                                    │ Track B: Vulkan  │
│ (DXVK 1.10.3)    │                                    │ (Native Fallback)│
└─────────┬────────┘                                    └─────────┬────────┘
          │                                                       │
          └───────────────────────────┬───────────────────────────┘
                                      ▼
                      ┌───────────────────────────────┐
                      │    dlls/win32u/vulkan.c       │
                      │  mach_vm_remap 32-bit Aliasing │
                      └───────────────┬───────────────┘
                                      │
            ┌─────────────────────────┼─────────────────────────┐
            ▼                         ▼                         ▼
      [Tier 1: Feature]      [Tier 2: Boundary]        [Tier 3: Handshake]
            │                         │                         │
            └─────────────────────────┼─────────────────────────┘
                                      ▼
                           [Tier 4: Real-World E2E]
                         (Aokana.exe Unity Player)
```

### 1.2 Non-Disruptive Headless Testing Architecture
To guarantee that automated testing never disrupts developer workflow by stealing focus or popping up application GUI windows:
1. **Headless Probes & Static Audits**: Tiers 1–3 utilize standalone C test probes (`tests/probes/test_mach_vm_remap`), Wine CLI commands (`wine64 cmd.exe /c`), and binary interface contract audits (PE exports, Mach symbol linkage, `_mach_vm_remap` binding).
2. **Headless Real-World Batchmode**: Tier 4 executes Unity applications strictly with the `-batchmode` parameter. This suppresses GUI window creation and window server focus stealing entirely, while permitting the graphics pipeline to initialize Direct3D 11 / Vulkan device clients and generate diagnostic `output_log.txt` telemetry.
3. **Rigorous Process Hygiene**: All runners enforce immediate process group cleanup (`pkill -9 -f Aokana.exe` and `wineserver -k`) before and after each run, preventing singleton mutex blocks and orphaned wineserver processes.

---


## 2. 4-Tier Test Suite Specification

### Tier 1: Feature Coverage
Validates the fundamental functional capabilities of the Wine WoW64 graphics stack.

| Test ID | Test Name | Target Component | Description | Authoritative Source of Expected Output |
|---------|-----------|------------------|-------------|-----------------------------------------|
| `T1.1` | `test_wine_loader_wow64_execution` | Wine Loader (`wine64`) | Verifies that the Wine loader correctly boots the 32-bit WoW64 runtime subsystem, initializes `NtCurrentTeb()->WowTebOffset`, and executes 32-bit PE binaries without loader aborts. | Wine Loader Spec; Windows PE32 execution contract; exit code 0. |
| `T1.2` | `test_vulkan_host_memory_remap_feature` | `win32u_vkMapMemory2KHR` | Verifies that when MoltenVK returns a 64-bit host memory pointer (`> 4GB`), Wine's Mach VM remapper successfully aliases it to a `< 4GB` 32-bit pointer and returns `VK_SUCCESS`. Logs must show `Remapped ... to 32-bit address ...` and must NOT contain `does not fit 32-bit pointer`. | `WoW64UnityCrashFix.md` § Interface Contracts (Wine Vulkan ↔ Darwin Mach Kernel); Wine OpenGL precedent `dlls/opengl32/unix_wgl.c`. |
| `T1.3` | `test_d3d11_device_creation_feature` | DXVK 1.10.3 (`d3d11.dll`) | Verifies that DXVK initializes device creation, probes `D3D_FEATURE_LEVEL_11_0`, and `DxvkMemoryAllocator` succeeds without `VK_ERROR_OUT_OF_HOST_MEMORY`. Device creation returns `S_OK`. | DXVK 1.10.3 specification; the original request notes R2; absence of `d3d11: failed to create device and context (80004005)`. |

### Tier 2: Boundary & Corner Cases
Validates memory boundaries, page alignment arithmetic, NULL pointer guards, and cleanup hygiene.

| Test ID | Test Name | Target Component | Description | Authoritative Source of Expected Output |
|---------|-----------|------------------|-------------|-----------------------------------------|
| `T2.1` | `test_low_address_space_limits` | Address Range `< 4GB` | Verifies that pointers returned to 32-bit WoW64 callers are strictly bounded: `0 < (uint32_t)addr <= 0xFFFFFFFF` and `addr >> 32 == 0`. No pointer exceeds 32 bits. | Intel 32-bit linear address space specification; Win32 WoW64 memory architecture. |
| `T2.2` | `test_mach_16kb_page_alignment` | Mach VM Page Alignment | Verifies that Darwin Mach kernel 16KB hardware page alignment (`PAGE_MASK = 0x3FFF`) is correctly applied: `base = host_ptr & ~PAGE_MASK`, `mapping_size = (len + (host_ptr - base) + PAGE_MASK) & ~PAGE_MASK`, and the returned pointer accurately restores the sub-page offset `(char *)memory->vm_map + (host_ptr - base)`. | Darwin Mach VM Subsystem (`<mach/mach_vm.h>`); Apple Silicon 16KB hardware page requirement. |
| `T2.3` | `test_null_check_and_crash_prevention` | Access Violation Guard | Verifies that `*data` is NEVER set to `NULL` (`0x00000000`) on successful allocation, preventing instructions such as `movdqu %xmm0, (%edi)` with `EDI = 0x00000050` from triggering `0xc0000005` page faults. Confirms zero crash dumps containing `Write to location 00000050`. | the original request notes § 1.2 crash dump analysis; Unity 2018.2 engine crash signature. |
| `T2.4` | `test_memory_unmap_free_hygiene` | Memory Free / Unmap Thunks | Verifies that `win32u_vkUnmapMemory2KHR` and `win32u_vkFreeMemory` safely release the 32-bit virtual memory mapping via `NtFreeVirtualMemory` without passing illegal `VK_MEMORY_UNMAP_RESERVE_BIT_EXT` when `map_placed_align == 0`. | Vulkan 1.3 spec § `VK_KHR_map_memory2`; `WoW64UnityCrashFix.md` Feature 2. |

### Tier 3: Cross-Feature Combinations
Validates the interaction and fallback handshakes between heterogeneous graphics layers.

| Test ID | Test Name | Target Component | Description | Authoritative Source of Expected Output |
|---------|-----------|------------------|-------------|-----------------------------------------|
| `T3.1` | `test_dxvk_fake_dxgi_handshake` | DXVK ↔ Wine Fake DXGI | Verifies that DXVK 1.10.3 32-bit interacts with Wine builtin `dxgi.dll` (~360KB) via `IWineDXGISwapChainFactory` (`GUID 53cb4ff0-c25a-4164-a891-0e83db0a7aac`), gracefully tolerates `E_NOINTERFACE` for `IID_IDXGIVkAdapter`, and binds to the Apple Silicon Vulkan adapter. | WhiskyKit `Wine.swift` pairing logic; `WoW64UnityCrashFix.md` § DXVK ↔ Fake DXGI contract. |
| `T3.2` | `test_wined3d_fallback_handling` | Wine Builtin `wined3d` | Verifies execution under Wine builtin `wined3d` (`WINEDLLOVERRIDES="d3d11=b;dxgi=b"`), verifying graceful failure reporting or feature level negotiation without wineserver memory corruption or unhandled segmentation faults. | WineD3D Vulkan adapter spec (`dlls/wined3d/adapter_vk.c`). |
| `T3.3` | `test_moltenvk_external_memory_host_env` | MoltenVK Environment Flag | Verifies that running with `MVK_CONFIG_EXTERNAL_MEMORY_HOST=0` (Whisky standard setting) prevents Apple Silicon GPU driver panic (`kIOGPUCommandBufferCallbackErrorOutOfMemory`) and properly triggers Wine's host memory remapping. | Whisky BottleSettings spec; MoltenVK external memory host configuration patch. |

### Tier 4: Real-World Application Scenarios
Validates complete application execution in the target bottle environment under real-world conditions.

| Test ID | Test Name | Target Component | Description | Authoritative Source of Expected Output |
|---------|-----------|------------------|-------------|-----------------------------------------|
| `T4.1` | `test_aokana_launch_and_engine_init` | `Aokana.exe` (Unity 2018.2) | Launches `Aokana.exe` under full production environment parameters (`DYLD_FALLBACK_LIBRARY_PATH`, `WINEMSYNC=1`, `MVK_CONFIG_EXTERNAL_MEMORY_HOST=0`, `d3d11=n,b;dxgi=n,b`). Verifies Unity engine initialization string (`Initialize engine version: 2018.2.19f1`), and validates complete elimination of `0x00000050` page fault and `80004005` device creation failure. | the original request notes R1; Aokana Unity 2018.2.19f1 engine logs. |
| `T4.2` | `test_window_and_render_loop_startup` | Unity Graphics Client & Window | Verifies that Unity Player creates the graphics device client (`GfxDevice: creating device client; threaded=1`), passes device initialization, and successfully warms up the render loop without triggering crash handlers (`UnityCrashHandler32.exe`). | Unity Engine GfxDevice lifecycle; Whisky runtime process monitor. |
| `T4.3` | `test_clean_process_teardown` | Process & Wine Lifecycle | Verifies clean process termination and wineserver cleanup (`wineserver -k`), ensuring no orphaned wine processes or dangling IPC locks remain on the system. | Wine Server IPC lifecycle; POSIX process clean state. |

---

## 3. Authoritative Output Derivation

Every assertion in this test suite is derived from explicit authoritative specifications:

1. **Unity Engine 2018.2.19f1 Log Signature**:
   - Engine initialization: `Initialize engine version: 2018.2.19f1 (06990f28ba00)`
   - Graphics device client: `GfxDevice: creating device client; threaded=1`
   - *Failure to eliminate*: `d3d11: failed to create device and context (80004005).`
   - *Failure to eliminate*: `Write to location 00000050 caused an access violation.`
2. **DXVK 1.10.3-macOS Trace Signature**:
   - Adapter detection: `info: D3D11CoreCreateDevice: Using feature level D3D_FEATURE_LEVEL_11_0`
   - *Failure to eliminate*: `err: DxvkMemoryAllocator: Mapping memory failed with VK_ERROR_OUT_OF_HOST_MEMORY`
3. **Wine Vulkan WoW64 Remap Trace Signature**:
   - *Success signature*: `Remapped ... Vulkan mapping ... to 32-bit address ...`
   - *Failure to eliminate*: `win32u_vkMapMemory2KHR returned mapping ... does not fit 32-bit pointer`
4. **Crash Dump Artifact Directory**:
   - Path: `$WINEPREFIX/drive_c/users/crossover/AppData/Local/Temp/NekoNyanSoft/Aokana/Crashes/`
   - Assertion: The count of crash folders containing `Write to location 00000050` MUST NOT increase during test execution.

---

## 4. Test Runner Architecture & Execution Protocol

The test suite is structured as follows:
- **Root Directory**: `tests/` (repository root-relative)
- **Shell Runner**: `tests/e2e_runner.sh` (POSIX entrypoint)
- **Python Driver**: `tests/e2e_runner.py` (Structured orchestrator)
- **Shared Utilities**: `tests/common.py` (Wine environment, process monitor, crash analyzer)
- **Test Modules**:
  - `tests/tier1_feature_coverage.py`
  - `tests/tier2_boundary_corner.py`
  - `tests/tier3_cross_feature.py`
  - `tests/tier4_real_world.py`

### 4.1 CLI Commands

```bash
# Run all tiers sequentially
./tests/e2e_runner.sh --all

# Run individual tiers
./tests/e2e_runner.sh --tier 1
./tests/e2e_runner.sh --tier 2
./tests/e2e_runner.sh --tier 3
./tests/e2e_runner.sh --tier 4

# Run with verbose log diagnostics
./tests/e2e_runner.sh --all --verbose

# Run with JSON output report
./tests/e2e_runner.sh --all --json
```

### 4.2 Exit Code Standards
- `0`: All requested test cases PASSED.
- `1`: One or more test cases FAILED.
- `2`: Test runner configuration or environmental error (missing Wine or bottle).
