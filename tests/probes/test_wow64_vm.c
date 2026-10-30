#include <windows.h>
#include <stdio.h>

int main(void) {
    printf("WOW64 VirtualAlloc Stress Test Started\n");

    /* Test 1: Verify 32-bit pointer limits */
    void *ptr = VirtualAlloc(NULL, 65536, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    if (!ptr) {
        printf("FAILED: initial VirtualAlloc returned NULL\n");
        return 1;
    }
    if ((uintptr_t)ptr > 0xFFFFFFFF) {
        printf("FAILED: pointer 0x%p exceeds 32-bit space!\n", ptr);
        return 2;
    }
    printf("Initial 32-bit allocation succeeded: %p\n", ptr);
    VirtualFree(ptr, 0, MEM_RELEASE);

    /* Test 2: Address space boundary probe: test near 2GB / 4GB boundary */
    void *blocks[2048];
    int count = 0;
    while (count < 2048) {
        void *p = VirtualAlloc(NULL, 1024 * 1024, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
        if (!p) break;
        blocks[count++] = p;
    }
    printf("Allocated %d MB in 32-bit address space before exhaustion\n", count);

    /* Once exhausted, verify VirtualAlloc returns NULL cleanly without crashing */
    void *fail_p = VirtualAlloc(NULL, 1024 * 1024, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    if (fail_p == NULL) {
        printf("VirtualAlloc returned NULL cleanly on exhaustion, GetLastError = %lu\n", GetLastError());
    } else {
        printf("Warning: still had memory, got %p\n", fail_p);
        blocks[count++] = fail_p;
    }

    /* Clean up all allocated blocks */
    for (int i = 0; i < count; i++) {
        VirtualFree(blocks[i], 0, MEM_RELEASE);
    }
    printf("All %d blocks cleanly released via VirtualFree\n", count);
    printf("WOW64 VirtualAlloc Stress Test PASSED\n");
    return 0;
}
