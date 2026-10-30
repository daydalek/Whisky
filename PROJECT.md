# Project: Whisky 32-bit WoW64 Unity Crash Fix (Aokana)

## Architecture

### Component Hierarchy & Interaction Flow
```
[ Aokana.exe / UnityPlayer.dll (32-bit PE WoW64) ]
   │
   ├─► Primary Route (Line A: D3D11) [SOLVED]:
   │     d3d11.dll (DXVK 1.10.3 32-bit) ──► dxgi.dll (Wine builtin fake DXGI)
   │        │ (IWineDXGISwapChainFactory)
   │        ▼
   │     DxvkMemoryAllocator ──► winevulkan.dll ──► win32u.so (Vulkan thunk)
   │                                                     │
   └─► Fallback Route (Line B: Native Vulkan) [SOLVED]:  │
         Unity Vulkan Backend ───────────────────────────┘
                                                         │
                                                         ▼
                                               win32u_vkMapMemory2KHR
                                                         │
                                     [ #ifdef __APPLE__ mach_vm_remap 32-bit Aliasing ]
                                     [ #else Standard Linux VK_EXT_map_memory_placed ]
                                                         │
                                                         ▼
                                        libMoltenVK.dylib (Metal Translation)
                                                         │
                                                         ▼
                                          Apple Silicon GPU (Metal Driver)
```

### Critical Architecture Constraints
1. **Linux Compatibility & Isolation**: The Wine core (`ge-proton-macos-wine-poc`) is multi-platform and supports Linux builds. Therefore, all Darwin/Mach headers (`<mach/mach.h>`, `<mach/mach_vm.h>`) and Mach VM aliasing logic (`mach_vm_remap`) are strictly encapsulated within `#ifdef __APPLE__` blocks. Existing Linux code paths remain 100% regression-free.
2. **Headless Testing Constraint**: Automated testing MUST NOT repeatedly launch the game GUI window or disrupt user desktop focus. Unit tests, driver interface tests, and boundary checks are strictly headless CLI probes or static analysis.

### Root Cause Analysis & Unifying Theory
1. **Line A (D3D11 0x80004005)**:
   - When running under DXVK 1.10.3 (`d3d11 = native`), DXVK probes Vulkan adapter and selects Feature Level 11_0. During device creation, `DxvkMemoryAllocator` invokes `vkMapMemory` (`win32u_vkMapMemory2KHR`). MoltenVK returns a 64-bit host memory pointer (`0x2156f8000 > 4GB`). Wine's `win32u/vulkan.c` previously rejected pointers above 4GB, unmapped the memory, set `*data = NULL`, and returned `VK_ERROR_OUT_OF_HOST_MEMORY`. This aborted D3D11 device creation, causing Unity to log `d3d11: failed to create device and context (80004005)`.
   - When running under Wine builtin `wined3d`, `adapter_vk.c:2213` hard-requires hardware geometry shaders for Feature Level 10.0+. MoltenVK on Apple Silicon lacks hardware geometry shaders, clamping maximum feature level to 9_3, which Unity rejects with `80004005`.
2. **Line B (Vulkan WoW64 Memory Truncation & 0x00000050 Page Fault)**:
   - When D3D11 device creation failed, Unity fell back to its 32-bit experimental Vulkan renderer (`[Vulkan init]`).
   - Unity called `vkMapMemory`. Because MoltenVK lacks `VK_EXT_map_memory_placed` and `MVK_CONFIG_EXTERNAL_MEMORY_HOST=0` disables external memory import, `win32u_vkMapMemory2KHR` received host mapping `0x21106c000`. Wine unmapped it, set `*data = NULL`, and returned `VK_ERROR_OUT_OF_HOST_MEMORY`.
   - Unity ignored the error code and dereferenced `NULL + 0x50` (`movdqu %xmm0, (%edi)` with `EDI=0x50`), crashing with an unhandled page fault.
3. **Unification & Solution**:
   - Implementing zero-copy 32-bit memory remapping in `dlls/win32u/vulkan.c` under `#ifdef __APPLE__` using Darwin's `mach_vm_remap` (following Wine's own established precedent in `dlls/opengl32/unix_wgl.c`) resolves BOTH Line A (DXVK D3D11 device creation succeeds) and Line B (Vulkan fallback mapping succeeds).
   - In addition, relaxing geometry shader checks in `dlls/wined3d/adapter_vk.c` provides full wined3d D3D 11.0 compatibility on MoltenVK without DXVK.

---

## Feature Inventory

| # | Feature | Description | Milestone | Source | Status |
|---|---------|-------------|-----------|--------|:------:|
| 1 | Vulkan 32-bit Low Address Mapping | Alias >4GB MoltenVK host memory into <4GB virtual address space via `mach_vm_remap` strictly guarded with `#ifdef __APPLE__` in `win32u_vkMapMemory2KHR` | M1 | Survey (Line B) & User Req | **DONE** |
| 2 | Vulkan 32-bit Memory Free/Unmap Hygiene | Properly clean up mapped virtual memory in `win32u_vkUnmapMemory2KHR` and `win32u_vkFreeMemory` without invalid extension flags | M1 | Survey (Line B) | **DONE** |
| 3 | Linux Build Zero-Regression | Ensure all macOS Mach headers/logic are guarded with `#ifdef __APPLE__` and Linux code paths remain intact | M1 | User Req | **DONE** |
| 4 | Fast Incremental Wine Build & Deploy | Compile `win32u.so` in `ge-proton-macos-wine-poc/work/metalfx/build` and hot-deploy to Whisky runtime | M1 | Survey (Env) | **DONE** |
| 5 | DXVK D3D11 32-bit Device Creation | Verify DXVK 1.10.3 initializes D3D_FEATURE_LEVEL_11_0 cleanly when memory mapping succeeds | M2 | Survey (Line A) | **DONE** |
| 6 | WineD3D MoltenVK Feature Level Support | Documented fallback handling and relaxed geometryShader requirements | M2 | Survey (Line A) | **DONE** |
| 7 | End-to-End Headless & Final Verification | Verify elimination of `80004005` and `0x00000050` crash via headless test runner and single silent validation | M3 | Survey (Env) & User Req | **DONE** |
| 8 | Multi-Backend Stability & Audit | Validate under DXVK, wined3d, and native Vulkan with Challenger tests and Forensic Auditor inspection | M3 | Survey / Req | **DONE** |

---

## Milestones

| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|:------:|
| M1 | Wine Vulkan WoW64 Memory Mapping Fix | Implement Darwin `mach_vm_remap` 32-bit memory aliasing under `#ifdef __APPLE__` in `dlls/win32u/vulkan.c`, preserving Linux paths, build `win32u.so`, deploy and verify | none | **DONE** |
| M2 | Direct3D 11 Native & WineD3D Activation | Verify DXVK 32-bit D3D11 activation and patch `wined3d` feature level in `adapter_vk.c` | M1 | **DONE** |
| M3 | End-to-End Verification & Forensic Audit | Headless test runner verification, single quiet game launch check, Challenger verification, Forensic Audit | M1, M2 | **DONE** |

---

## Interface Contracts

### Wine Vulkan ↔ Darwin Mach Kernel
- Function: `mach_vm_remap` (guarded strictly under `#ifdef __APPLE__`)
- Headers: `<mach/mach.h>`, `<mach/mach_vm.h>` (guarded under `#ifdef __APPLE__`)
- Target Task: `mach_task_self()`
- Target Address: Allocated via `NtAllocateVirtualMemory(GetCurrentProcess(), &vm_ptr, zero_bits, &mapping_size, MEM_COMMIT, PAGE_READWRITE)`
- Flags: `VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE`
- Source Task: `mach_task_self()`
- Source Address: Host buffer pointer from MoltenVK (`base = (vm_map_address_t)host_ptr & ~PAGE_MASK`)
- Non-Apple Fallback (`#else`): Retain existing Wine Linux WoW64 handling (`VK_EXT_map_memory_placed` / `VK_ERROR_OUT_OF_HOST_MEMORY`).

### DXVK 1.10.3 ↔ Wine Fake DXGI
- Interface: `IWineDXGISwapChainFactory` (`GUID: 53cb4ff0-c25a-4164-a891-0e83db0a7aac`)
- Agreement: DXVK creates swapchain via Wine's builtin `dxgi.dll`, enabling native macOS window integration while utilizing DXVK's Vulkan translation.

---

## Code Layout

### Source Repositories & Build Trees
- Wine Source Code: `/Users/daydalek/codes/ge-proton-macos-wine-poc/work/metalfx/fresh/sources/wine`
  - Target Vulkan Thunk: `dlls/win32u/vulkan.c`
  - Target WineD3D Feature Level: `dlls/wined3d/adapter_vk.c`
- Wine Build Tree: `/Users/daydalek/codes/ge-proton-macos-wine-poc/work/metalfx/build`
  - Unix Graphics Module: `dlls/win32u/win32u.so`
  - WineD3D Module: `dlls/wined3d/wined3d.so` and `dlls/wined3d/i386-windows/wined3d.dll`
- Whisky Runtime Deployment:
  - Runtime Wine Root: `/Users/daydalek/Library/Application Support/com.franke.Whisky/Libraries/Wine`
  - Active win32u.so: `.../Libraries/Wine/lib/wine/x86_64-unix/win32u.so`
- Target Bottle:
  - Prefix Root: `/Users/daydalek/Library/Containers/com.franke.Whisky/Bottles/9C6C4CD2-82BE-43E9-81E5-8AF2591EA484`
  - Game Executable: `drive_c/Program Files (x86)/Steam/steamapps/common/Aokana/Aokana.exe`
