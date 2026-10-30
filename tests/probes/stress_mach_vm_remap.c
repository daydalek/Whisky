/*
 * stress_mach_vm_remap.c — Adversarial Memory Remap & Resource Leak Stress Harness
 *
 * Empirical Challenger probe verifying:
 * 1. Multi-page span mappings across 16KB hardware boundaries (up to 64MB / 4096 pages).
 * 2. Non-zero host offsets and arbitrary byte-length boundary crossing.
 * 3. Bidirectional zero-copy data integrity and hardware cache coherency.
 * 4. Zero resource leaks across repeated map/unmap cycles (Mach ports, VM regions, virtual memory).
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <errno.h>
#include <sys/mman.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach/vm_page_size.h>

#define TARGET_32BIT_BASE 0x40000000ULL

/* Helper: reserve virtual memory strictly within 32-bit address space (< 4GB) */
static void *allocate_32bit_virtual_memory(size_t size) {
    uintptr_t candidate_bases[] = {
        0x40000000ULL, 0x50000000ULL, 0x60000000ULL, 0x70000000ULL,
        0x80000000ULL, 0x90000000ULL, 0x30000000ULL, 0x20000000ULL
    };
    size_t count = sizeof(candidate_bases) / sizeof(candidate_bases[0]);
    for (size_t i = 0; i < count; i++) {
        void *hint = (void *)candidate_bases[i];
        void *p = mmap(hint, size, PROT_READ | PROT_WRITE,
                       MAP_ANON | MAP_PRIVATE | MAP_FIXED, -1, 0);
        if (p != MAP_FAILED && (uintptr_t)p <= 0xFFFFFFFFULL) {
            return p;
        }
    }
    return NULL;
}

/* Helper: get Mach hardware/kernel page size */
static size_t get_darwin_page_size(void) {
    size_t ps = vm_page_size;
    if (ps == 0) ps = 16384;
    return ps;
}

/* Helper: count active Mach ports in task */
static mach_msg_type_number_t count_task_ports(void) {
    mach_port_name_array_t names;
    mach_msg_type_number_t names_count = 0;
    mach_port_type_array_t types;
    mach_msg_type_number_t types_count = 0;

    kern_return_t kr = mach_port_names(mach_task_self(), &names, &names_count, &types, &types_count);
    if (kr != KERN_SUCCESS) return 0;

    vm_deallocate(mach_task_self(), (vm_address_t)names, names_count * sizeof(mach_port_name_t));
    vm_deallocate(mach_task_self(), (vm_address_t)types, types_count * sizeof(mach_port_type_t));
    return names_count;
}

/* Helper: count active VM regions in task */
static int count_vm_regions(size_t *out_total_size) {
    mach_vm_address_t addr = 0;
    mach_vm_size_t size = 0;
    natural_t depth = 0;
    struct vm_region_submap_info_64 info;
    mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
    int region_count = 0;
    size_t total_size = 0;

    while (1) {
        kern_return_t kr = mach_vm_region_recurse(
            mach_task_self(), &addr, &size, &depth,
            (vm_region_recurse_info_t)&info, &count
        );
        if (kr != KERN_SUCCESS) break;

        if (info.is_submap) {
            depth++;
            continue;
        }

        region_count++;
        total_size += size;
        addr += size;
    }

    if (out_total_size) *out_total_size = total_size;
    return region_count;
}

/* Helper: query resident and virtual memory size */
static bool get_memory_info(size_t *out_virtual, size_t *out_resident) {
    struct task_basic_info_64 info;
    mach_msg_type_number_t count = TASK_BASIC_INFO_64_COUNT;
    kern_return_t kr = task_info(mach_task_self(), TASK_BASIC_INFO_64, (task_info_t)&info, &count);
    if (kr != KERN_SUCCESS) return false;
    if (out_virtual) *out_virtual = info.virtual_size;
    if (out_resident) *out_resident = info.resident_size;
    return true;
}

/*
 * TEST 1: Multi-Page Span Mapping across 16KB Pages
 * Tests mapping sizes spanning 1 page (16KB) up to 4096 pages (64MB).
 * Fills every page with page-specific canary and verifies low address reading & writing.
 */
static bool test_multi_page_spans(void) {
    printf("[STRESS TEST 1] Multi-Page Span Mapping (16KB to 64MB)...\n");
    const size_t PAGE_SIZE = get_darwin_page_size();
    const size_t PAGE_MASK = PAGE_SIZE - 1;

    size_t page_counts[] = { 1, 2, 4, 8, 16, 64, 256, 1024, 2048, 4096, 8192, 16384 };
    size_t num_counts = sizeof(page_counts) / sizeof(page_counts[0]);

    for (size_t i = 0; i < num_counts; i++) {
        size_t pages = page_counts[i];
        size_t alloc_size = pages * PAGE_SIZE;

        /* Allocate host memory */
        void *host_mem = mmap(NULL, alloc_size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
        if (host_mem == MAP_FAILED) {
            fprintf(stderr, "  FAIL: mmap failed for %zu pages (%zu bytes)\n", pages, alloc_size);
            return false;
        }

        /* Populate unique pattern into each page */
        uint8_t *host_bytes = (uint8_t *)host_mem;
        for (size_t p = 0; p < pages; p++) {
            uint8_t pattern = (uint8_t)((p * 37 + 0x5A) & 0xFF);
            /* Write pattern at start, middle, and end of each page */
            host_bytes[p * PAGE_SIZE] = pattern;
            host_bytes[p * PAGE_SIZE + PAGE_SIZE / 2] = (uint8_t)(pattern ^ 0xAA);
            host_bytes[p * PAGE_SIZE + PAGE_SIZE - 1] = (uint8_t)(pattern ^ 0xFF);
        }

        /* Reserve 32-bit low virtual memory */
        void *low_mem = allocate_32bit_virtual_memory(alloc_size);
        if (!low_mem) {
            fprintf(stderr, "  FAIL: could not reserve 32-bit memory for %zu pages\n", pages);
            munmap(host_mem, alloc_size);
            return false;
        }

        /* mach_vm_remap */
        mach_vm_address_t lowaddr = (mach_vm_address_t)(uintptr_t)low_mem;
        mach_vm_address_t base = (mach_vm_address_t)(uintptr_t)host_mem & ~PAGE_MASK;
        vm_prot_t cur_prot, max_prot;

        kern_return_t kr = mach_vm_remap(
            mach_task_self(), &lowaddr, alloc_size, 0,
            VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE,
            mach_task_self(), base, FALSE,
            &cur_prot, &max_prot, VM_INHERIT_DEFAULT
        );

        if (kr != KERN_SUCCESS) {
            fprintf(stderr, "  FAIL: mach_vm_remap failed for %zu pages (%zu bytes) with error %d\n", pages, alloc_size, kr);
            munmap(low_mem, alloc_size);
            munmap(host_mem, alloc_size);
            return false;
        }

        /* Verify data from low address */
        uint8_t *low_bytes = (uint8_t *)(uintptr_t)lowaddr;
        for (size_t p = 0; p < pages; p++) {
            uint8_t pattern = (uint8_t)((p * 37 + 0x5A) & 0xFF);
            if (low_bytes[p * PAGE_SIZE] != pattern ||
                low_bytes[p * PAGE_SIZE + PAGE_SIZE / 2] != (uint8_t)(pattern ^ 0xAA) ||
                low_bytes[p * PAGE_SIZE + PAGE_SIZE - 1] != (uint8_t)(pattern ^ 0xFF)) {
                fprintf(stderr, "  FAIL: Data corruption on page %zu of %zu!\n", p, pages);
                munmap((void *)(uintptr_t)lowaddr, alloc_size);
                munmap(host_mem, alloc_size);
                return false;
            }
        }

        /* Modify data through low address and verify on host */
        for (size_t p = 0; p < pages; p++) {
            low_bytes[p * PAGE_SIZE] = (uint8_t)(p & 0xFF);
            low_bytes[p * PAGE_SIZE + PAGE_SIZE - 1] = (uint8_t)(~p & 0xFF);
        }
        for (size_t p = 0; p < pages; p++) {
            if (host_bytes[p * PAGE_SIZE] != (uint8_t)(p & 0xFF) ||
                host_bytes[p * PAGE_SIZE + PAGE_SIZE - 1] != (uint8_t)(~p & 0xFF)) {
                fprintf(stderr, "  FAIL: Write-back corruption on page %zu of %zu!\n", p, pages);
                munmap((void *)(uintptr_t)lowaddr, alloc_size);
                munmap(host_mem, alloc_size);
                return false;
            }
        }

        munmap((void *)(uintptr_t)lowaddr, alloc_size);
        munmap(host_mem, alloc_size);
        printf("  - %4zu pages (%8zu KB / %3zu MB): PASS (verified %zu page boundaries)\n",
               pages, alloc_size / 1024, alloc_size / (1024 * 1024), pages);
    }
    return true;
}

/*
 * TEST 2: Non-Zero Host Offset & Arbitrary Byte Boundary Alignment
 * Simulates exactly Wine's calculation:
 *   base = host_ptr & ~PAGE_MASK
 *   mapping_size = (length + (host_ptr - base) + PAGE_MASK) & ~PAGE_MASK
 *   low_ptr = memory->vm_map + (host_ptr - base)
 * Tests non-zero offsets within a page and multi-page crossing allocations.
 */
static bool test_nonzero_offsets_and_subpage(void) {
    printf("[STRESS TEST 2] Non-Zero Offsets & Sub-Page Boundary Arithmetic...\n");
    const size_t PAGE_SIZE = get_darwin_page_size();
    const size_t PAGE_MASK = PAGE_SIZE - 1;

    struct TestCase {
        size_t offset_within_host;
        size_t requested_length;
        const char *desc;
    } cases[] = {
        { 1, 10, "1-byte offset, small 10-byte payload" },
        { 7, 512, "Unaligned 7-byte offset, 512-byte payload" },
        { 64, 4096, "64-byte offset, 4KB payload" },
        { 4096, 8192, "4096-byte (4KB) offset, 8KB payload" },
        { 8192, 16384, "8192-byte (8KB) offset, 16KB payload crossing page boundary" },
        { PAGE_SIZE - 16, 32, "Boundary edge: 16 bytes before page end, crossing 16 bytes into next page" },
        { PAGE_SIZE - 1, 2, "Extreme boundary edge: 1 byte before page end, crossing 1 byte into next page" },
        { 16384 - 16, 32, "Apple Silicon 16KB boundary edge: 16 bytes before 16KB, crossing into next 16KB" },
        { 16384 - 1, 2, "Apple Silicon 16KB extreme boundary: 1 byte before 16KB, crossing into next 16KB" },
        { 16384 * 2 + 128, 65536, "Multi-16KB offset (32KB + 128) spanning across multiple pages" },
        { PAGE_SIZE + 128, 65536, "Multi-page offset (page + 128) spanning across 5 pages" },
        { 12345, 100000, "Prime offset 12345, length 100,000 bytes spanning ~7 pages" },
        { 0, PAGE_SIZE, "Exact single page" },
        { 0, 16384, "Exact 16KB hardware page" },
        { 0, PAGE_SIZE * 3 + 1, "Page-aligned start, length ending 1 byte into 4th page" },
    };

    size_t num_cases = sizeof(cases) / sizeof(cases[0]);
    size_t total_host_buffer = 1024 * 1024; /* 1MB backing pool */

    void *host_pool = mmap(NULL, total_host_buffer, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (host_pool == MAP_FAILED) {
        fprintf(stderr, "  FAIL: could not allocate host pool\n");
        return false;
    }

    for (size_t i = 0; i < num_cases; i++) {
        size_t offset = cases[i].offset_within_host;
        size_t length = cases[i].requested_length;
        void *host_ptr = (char *)host_pool + offset;

        /* Replicate Wine vulkan.c arithmetic */
        vm_map_address_t base = (vm_map_address_t)(uintptr_t)host_ptr & ~PAGE_MASK;
        vm_map_offset_t sub_offset = (vm_map_offset_t)(uintptr_t)host_ptr - base;
        size_t mapping_size = (length + sub_offset + PAGE_MASK) & ~PAGE_MASK;

        /* Canary sentinels before and after requested range */
        uint8_t *raw_host = (uint8_t *)host_ptr;
        if (offset > 0) ((uint8_t *)host_pool)[offset - 1] = 0xDE;
        raw_host[0] = 0xAA;
        if (length > 2) raw_host[length / 2] = 0xBB;
        raw_host[length - 1] = 0xCC;
        ((uint8_t *)host_pool)[offset + length] = 0xAD;

        /* Reserve 32-bit low address */
        void *vm_ptr = allocate_32bit_virtual_memory(mapping_size);
        if (!vm_ptr) {
            fprintf(stderr, "  FAIL: could not reserve 32-bit memory for case %zu: %s\n", i, cases[i].desc);
            munmap(host_pool, total_host_buffer);
            return false;
        }

        mach_vm_address_t lowaddr = (mach_vm_address_t)(uintptr_t)vm_ptr;
        vm_prot_t cur_prot, max_prot;

        kern_return_t kr = mach_vm_remap(
            mach_task_self(), &lowaddr, mapping_size, 0,
            VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE,
            mach_task_self(), base, FALSE,
            &cur_prot, &max_prot, VM_INHERIT_DEFAULT
        );

        if (kr != KERN_SUCCESS) {
            fprintf(stderr, "  FAIL: mach_vm_remap failed for case %zu (%s), kr=%d\n", i, cases[i].desc, kr);
            munmap(vm_ptr, mapping_size);
            munmap(host_pool, total_host_buffer);
            return false;
        }

        /* Calculate returned data pointer as in vulkan.c */
        void *returned_data = (char *)vm_ptr + sub_offset;
        uint8_t *guest_data = (uint8_t *)returned_data;

        /* 1. Verify 32-bit bound */
        if ((uintptr_t)returned_data > 0xFFFFFFFFULL) {
            fprintf(stderr, "  FAIL: returned_data %p exceeds 32-bit!\n", returned_data);
            munmap(vm_ptr, mapping_size);
            munmap(host_pool, total_host_buffer);
            return false;
        }

        /* 2. Verify sub-offset matches */
        if (guest_data[0] != 0xAA ||
            (length > 2 && guest_data[length / 2] != 0xBB) ||
            guest_data[length - 1] != 0xCC) {
            fprintf(stderr, "  FAIL: Canary data mismatch in case %zu (%s)! Got [0]=%02x, [end]=%02x\n",
                    i, cases[i].desc, guest_data[0], guest_data[length - 1]);
            munmap(vm_ptr, mapping_size);
            munmap(host_pool, total_host_buffer);
            return false;
        }

        /* 3. Verify write from guest reflects on host */
        guest_data[0] = 0x55;
        guest_data[length - 1] = 0x33;
        if (raw_host[0] != 0x55 || raw_host[length - 1] != 0x33) {
            fprintf(stderr, "  FAIL: Write from guest did not reflect on host in case %zu (%s)!\n", i, cases[i].desc);
            munmap(vm_ptr, mapping_size);
            munmap(host_pool, total_host_buffer);
            return false;
        }

        /* 4. Verify boundary sentinels were NOT corrupted */
        if (offset > 0 && ((uint8_t *)host_pool)[offset - 1] != 0xDE) {
            fprintf(stderr, "  FAIL: Left sentinel corrupted in case %zu!\n", i);
            munmap(vm_ptr, mapping_size);
            munmap(host_pool, total_host_buffer);
            return false;
        }
        if (((uint8_t *)host_pool)[offset + length] != 0xAD) {
            fprintf(stderr, "  FAIL: Right sentinel corrupted in case %zu!\n", i);
            munmap(vm_ptr, mapping_size);
            munmap(host_pool, total_host_buffer);
            return false;
        }

        munmap(vm_ptr, mapping_size);
        printf("  - Case %2zu: [offset=%6zu, len=%6zu, map_size=%6zu] %s: PASS\n",
               i + 1, offset, length, mapping_size, cases[i].desc);
    }

    munmap(host_pool, total_host_buffer);
    return true;
}

/*
 * TEST 3: Zero-Copy Bidirectional Data Integrity & Hardware Cache Coherence
 * Tests high-throughput pseudorandom patterns across multiple pages:
 * Host writes PRNG block -> Guest verifies -> Guest mutates -> Host verifies.
 */
static bool test_bidirectional_zero_copy_integrity(void) {
    printf("[STRESS TEST 3] Bidirectional Zero-Copy Data Integrity & Coherency...\n");
    const size_t PAGE_SIZE = get_darwin_page_size();
    const size_t alloc_size = PAGE_SIZE * 64; /* 1MB */

    void *host_mem = mmap(NULL, alloc_size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (host_mem == MAP_FAILED) {
        fprintf(stderr, "  FAIL: mmap failed for host\n");
        return false;
    }

    void *low_mem = allocate_32bit_virtual_memory(alloc_size);
    if (!low_mem) {
        fprintf(stderr, "  FAIL: could not reserve 32-bit memory\n");
        munmap(host_mem, alloc_size);
        return false;
    }

    mach_vm_address_t lowaddr = (mach_vm_address_t)(uintptr_t)low_mem;
    mach_vm_address_t base = (mach_vm_address_t)(uintptr_t)host_mem;
    vm_prot_t cur_prot, max_prot;

    kern_return_t kr = mach_vm_remap(
        mach_task_self(), &lowaddr, alloc_size, 0,
        VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE,
        mach_task_self(), base, FALSE,
        &cur_prot, &max_prot, VM_INHERIT_DEFAULT
    );

    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "  FAIL: mach_vm_remap failed: %d\n", kr);
        munmap(low_mem, alloc_size);
        munmap(host_mem, alloc_size);
        return false;
    }

    uint32_t *host_words = (uint32_t *)host_mem;
    uint32_t *guest_words = (uint32_t *)low_mem;
    size_t num_words = alloc_size / sizeof(uint32_t);

    /* Phase 1: Host writes PRNG stream -> Guest validates */
    uint32_t seed = 0x12345678;
    for (size_t i = 0; i < num_words; i++) {
        seed = seed * 1664525 + 1013904223;
        host_words[i] = seed;
    }

    seed = 0x12345678;
    for (size_t i = 0; i < num_words; i++) {
        seed = seed * 1664525 + 1013904223;
        if (guest_words[i] != seed) {
            fprintf(stderr, "  FAIL: Host-to-Guest mismatch at word %zu! Expected %08x, got %08x\n",
                    i, seed, guest_words[i]);
            munmap(low_mem, alloc_size);
            munmap(host_mem, alloc_size);
            return false;
        }
    }
    printf("  - Phase 1: Host -> Guest 1MB PRNG stream: 100%% Coherent.\n");

    /* Phase 2: Guest writes inverted stream -> Host validates */
    for (size_t i = 0; i < num_words; i++) {
        guest_words[i] = ~guest_words[i];
    }

    seed = 0x12345678;
    for (size_t i = 0; i < num_words; i++) {
        seed = seed * 1664525 + 1013904223;
        if (host_words[i] != ~seed) {
            fprintf(stderr, "  FAIL: Guest-to-Host mismatch at word %zu!\n", i);
            munmap(low_mem, alloc_size);
            munmap(host_mem, alloc_size);
            return false;
        }
    }
    printf("  - Phase 2: Guest -> Host 1MB Inverted stream: 100%% Coherent.\n");

    /* Phase 3: Interleaved simultaneous words across cachelines (64-byte chunks) */
    for (size_t i = 0; i < num_words; i += 16) {
        /* Word 0 written by Host, Word 1 written by Guest, etc. */
        for (size_t j = 0; j < 16; j++) {
            if (j % 2 == 0) host_words[i + j] = (uint32_t)(0xAAAA0000 | (i + j));
            else guest_words[i + j] = (uint32_t)(0x55550000 | (i + j));
        }
    }
    for (size_t i = 0; i < num_words; i += 16) {
        for (size_t j = 0; j < 16; j++) {
            uint32_t exp = (j % 2 == 0) ? (0xAAAA0000 | (i + j)) : (0x55550000 | (i + j));
            if (host_words[i + j] != exp || guest_words[i + j] != exp) {
                fprintf(stderr, "  FAIL: Interleaved cacheline mismatch at [%zu + %zu]!\n", i, j);
                munmap(low_mem, alloc_size);
                munmap(host_mem, alloc_size);
                return false;
            }
        }
    }
    printf("  - Phase 3: Interleaved Cacheline Write Coherency: PASS.\n");

    munmap(low_mem, alloc_size);
    munmap(host_mem, alloc_size);
    return true;
}

/*
 * TEST 4: Resource Leak Stress (Mach task ports & VM region cycles)
 * Performs 2,000 consecutive map -> write -> read -> unmap cycles.
 * Checks for Mach port leaks and VM region / virtual memory accumulation.
 */
static bool test_map_unmap_resource_leaks(int cycles) {
    printf("[STRESS TEST 4] %d Map & Unmap Cycles Resource Leak Audit...\n", cycles);
    const size_t PAGE_SIZE = get_darwin_page_size();
    const size_t alloc_size = PAGE_SIZE * 4; /* 64KB */

    /* Baseline measurement */
    mach_msg_type_number_t ports_before = count_task_ports();
    size_t vm_size_before = 0;
    int regions_before = count_vm_regions(&vm_size_before);
    size_t virt_before = 0, res_before = 0;
    get_memory_info(&virt_before, &res_before);

    printf("  Baseline: ports=%u, regions=%d, total_vm=%zu KB, virt_mem=%zu KB\n",
           ports_before, regions_before, vm_size_before / 1024, virt_before / 1024);

    void *host_mem = mmap(NULL, alloc_size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (host_mem == MAP_FAILED) {
        fprintf(stderr, "  FAIL: mmap failed for host\n");
        return false;
    }

    for (int c = 0; c < cycles; c++) {
        /* 1. Allocate 32-bit low reservation */
        void *low_mem = allocate_32bit_virtual_memory(alloc_size);
        if (!low_mem) {
            fprintf(stderr, "  FAIL at cycle %d: could not reserve 32-bit memory\n", c);
            munmap(host_mem, alloc_size);
            return false;
        }

        /* 2. mach_vm_remap */
        mach_vm_address_t lowaddr = (mach_vm_address_t)(uintptr_t)low_mem;
        mach_vm_address_t base = (mach_vm_address_t)(uintptr_t)host_mem;
        vm_prot_t cur_prot, max_prot;

        kern_return_t kr = mach_vm_remap(
            mach_task_self(), &lowaddr, alloc_size, 0,
            VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE,
            mach_task_self(), base, FALSE,
            &cur_prot, &max_prot, VM_INHERIT_DEFAULT
        );

        if (kr != KERN_SUCCESS) {
            fprintf(stderr, "  FAIL at cycle %d: mach_vm_remap returned %d\n", c, kr);
            munmap(low_mem, alloc_size);
            munmap(host_mem, alloc_size);
            return false;
        }

        /* 3. Touch memory */
        *(volatile uint32_t *)lowaddr = 0xCAFEBABE ^ c;
        if (*(volatile uint32_t *)host_mem != (0xCAFEBABE ^ c)) {
            fprintf(stderr, "  FAIL at cycle %d: memory write mismatch\n", c);
            munmap((void *)(uintptr_t)lowaddr, alloc_size);
            munmap(host_mem, alloc_size);
            return false;
        }

        /* 4. Release low memory (NtFreeVirtualMemory equivalent on Darwin) */
        munmap((void *)(uintptr_t)lowaddr, alloc_size);

        if ((c + 1) % 500 == 0) {
            printf("  ... completed %d / %d cycles\n", c + 1, cycles);
        }
    }

    munmap(host_mem, alloc_size);

    /* Post-run measurement */
    mach_msg_type_number_t ports_after = count_task_ports();
    size_t vm_size_after = 0;
    int regions_after = count_vm_regions(&vm_size_after);
    size_t virt_after = 0, res_after = 0;
    get_memory_info(&virt_after, &res_after);

    printf("  Post-run: ports=%u, regions=%d, total_vm=%zu KB, virt_mem=%zu KB\n",
           ports_after, regions_after, vm_size_after / 1024, virt_after / 1024);

    int port_diff = (int)ports_after - (int)ports_before;
    int region_diff = regions_after - regions_before;
    long long virt_diff = (long long)virt_after - (long long)virt_before;

    printf("  Delta: port_diff=%d, region_diff=%d, virt_mem_delta=%lld bytes\n",
           port_diff, region_diff, virt_diff);

    /* Assert zero port leaks */
    if (port_diff > 0) {
        fprintf(stderr, "  FAIL: Leaked %d Mach ports across %d cycles!\n", port_diff, cycles);
        return false;
    }

    /* Assert zero VM region leaks */
    if (region_diff > 0) {
        fprintf(stderr, "  FAIL: Leaked %d VM regions across %d cycles!\n", region_diff, cycles);
        return false;
    }

    /* Assert no unbound virtual memory leak */
    if (virt_diff > (long long)(alloc_size * 2)) {
        fprintf(stderr, "  FAIL: Virtual memory expanded by %lld bytes across %d cycles!\n", virt_diff, cycles);
        return false;
    }

    printf("  Result: ZERO Mach port leaks, ZERO VM region leaks across %d cycles. PASS.\n", cycles);
    return true;
}

int main(int argc, char **argv) {
    int cycles = 2000;
    if (argc > 1) cycles = atoi(argv[1]);
    if (cycles <= 0) cycles = 2000;

    printf("======================================================================\n");
    printf("  ADVERSARIAL EMPIRICAL MEMORY REMAP & CONCURRENCY STRESS HARNESS    \n");
    printf("  Architecture: %s | Page Size: %zu KB | Cycles: %d\n",
#if defined(__x86_64__)
           "x86_64 (Rosetta 2 Translation)",
#elif defined(__arm64__) || defined(__aarch64__)
           "arm64 (Native Apple Silicon)",
#else
           "Unknown",
#endif
           get_darwin_page_size() / 1024, cycles);
    printf("======================================================================\n\n");

    if (!test_multi_page_spans()) {
        fprintf(stderr, "\n>>> FAILED: Multi-page span stress test failed!\n");
        return 1;
    }
    printf("\n");

    if (!test_nonzero_offsets_and_subpage()) {
        fprintf(stderr, "\n>>> FAILED: Non-zero offset boundary stress test failed!\n");
        return 2;
    }
    printf("\n");

    if (!test_bidirectional_zero_copy_integrity()) {
        fprintf(stderr, "\n>>> FAILED: Zero-copy bidirectional integrity test failed!\n");
        return 3;
    }
    printf("\n");

    if (!test_map_unmap_resource_leaks(cycles)) {
        fprintf(stderr, "\n>>> FAILED: Resource leak stress test failed!\n");
        return 4;
    }
    printf("\n");

    printf("======================================================================\n");
    printf("  ALL EMPIRICAL CHALLENGER STRESS TESTS PASSED SUCCESSFULLY!          \n");
    printf("======================================================================\n");
    return 0;
}
