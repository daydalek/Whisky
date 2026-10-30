/*
 * Standalone Headless Mach VM Remap Test Probe
 * Verifies that Darwin's mach_vm_remap successfully aliases high (>4GB) host virtual memory
 * into the <4GB 32-bit address space using VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>

int main(void) {
    size_t page_size = vm_page_size;
    if (page_size == 0) page_size = 16384;
    size_t alloc_size = page_size * 2;

    /* 1. Allocate high host memory (> 4GB) */
    void *host_mem = mmap(NULL, alloc_size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (host_mem == MAP_FAILED) {
        fprintf(stderr, "mmap failed for host memory\n");
        return 1;
    }

    /* Write test canary to host memory */
    const char *canary = "WHISKY_MAPPING_VERIFIED_OK";
    strcpy((char *)host_mem, canary);

    /* 2. Allocate 32-bit low virtual address (< 4GB, e.g. 0x50000000) */
    void *target_hint = (void *)0x50000000;
    void *low_mem = mmap(target_hint, alloc_size, PROT_READ | PROT_WRITE,
                         MAP_ANON | MAP_PRIVATE | MAP_FIXED, -1, 0);
    if (low_mem == MAP_FAILED) {
        /* Fallback to any low memory in 32-bit space */
        target_hint = (void *)0x60000000;
        low_mem = mmap(target_hint, alloc_size, PROT_READ | PROT_WRITE,
                       MAP_ANON | MAP_PRIVATE | MAP_FIXED, -1, 0);
        if (low_mem == MAP_FAILED) {
            fprintf(stderr, "mmap failed for low address reservation\n");
            munmap(host_mem, alloc_size);
            return 2;
        }
    }

    /* Verify low_mem is strictly within 32-bit space */
    if ((uintptr_t)low_mem > 0xFFFFFFFF) {
        fprintf(stderr, "Target memory %p is not in 32-bit space\n", low_mem);
        munmap(low_mem, alloc_size);
        munmap(host_mem, alloc_size);
        return 3;
    }

    /* 3. Perform mach_vm_remap with VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE */
    mach_vm_address_t lowaddr = (mach_vm_address_t)low_mem;
    mach_vm_address_t base = (mach_vm_address_t)host_mem & ~(page_size - 1);
    vm_prot_t cur_prot, max_prot;

    kern_return_t kr = mach_vm_remap(
        mach_task_self(),
        &lowaddr,
        alloc_size,
        0,
        VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE,
        mach_task_self(),
        base,
        FALSE,
        &cur_prot,
        &max_prot,
        VM_INHERIT_DEFAULT
    );

    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "mach_vm_remap failed: %d\n", kr);
        munmap(low_mem, alloc_size);
        munmap(host_mem, alloc_size);
        return 4;
    }

    /* 4. Validate canary data across alias */
    if (strcmp((const char *)low_mem, canary) != 0) {
        fprintf(stderr, "Canary mismatch in remapped memory! Got: '%s'\n", (const char *)low_mem);
        munmap(low_mem, alloc_size);
        munmap(host_mem, alloc_size);
        return 5;
    }

    /* 5. Validate zero-copy hardware coherence: write to alias and verify on host */
    const char *reply = "ZERO_COPY_SHARED_COHERENT";
    strcpy((char *)low_mem, reply);
    if (strcmp((const char *)host_mem, reply) != 0) {
        fprintf(stderr, "Zero-copy coherence failure: host memory did not receive write from alias!\n");
        munmap(low_mem, alloc_size);
        munmap(host_mem, alloc_size);
        return 6;
    }

    printf("REMAP_PROBE_SUCCESS: host=%p low=%p (0x%lx) canary_verified\n",
           host_mem, low_mem, (uintptr_t)low_mem);

    munmap(low_mem, alloc_size);
    munmap(host_mem, alloc_size);
    return 0;
}
