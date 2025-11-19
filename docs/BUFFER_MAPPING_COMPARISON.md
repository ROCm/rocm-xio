# Buffer Mapping Comparison: test-nvme-write-read-verify.cpp vs axiio-tester.hip

## Key Differences

### 1. Buffer Allocation Order

**test-nvme-write-read-verify.cpp**:
- Allocates write buffer FIRST (gets index 0 → offset 4)
- Allocates read buffer SECOND (gets index 1 → offset 5)
- Maps write buffer at `4 * page_size`
- Maps read buffer at `5 * page_size`

**axiio-tester.hip**:
- In read-only mode: Allocates read buffer ONLY (gets index 0 → offset 4)
- In write-only mode: Allocates write buffer ONLY (gets index 0 → offset 4)
- Maps read buffer at `4 * getpagesize()` (read-only mode)
- Maps write buffer at `5 * getpagesize()` (write-only mode) - **WAIT, THIS IS WRONG!**

### 2. Critical Issue Found

In `axiio-tester.hip` line 1487-1490:
```cpp
if (!config->args.readOnlyMode && write_dma_addr != 0) {
  writeBuffer = (uint8_t*)mmap(NULL, config->args.dataBufferSize,
                               PROT_READ | PROT_WRITE, MAP_SHARED,
                               kernel_ctx->axiio_fd, 5 * getpagesize());
```

**Problem**: In write-only mode, write buffer is allocated first (gets index 0), but it's mapped at offset 5!

**Should be**: In write-only mode, write buffer should be mapped at `4 * getpagesize()` (offset 4).

### 3. HSA Locking

**test-nvme-write-read-verify.cpp**:
- Keeps separate pointers: `write_buf` (CPU), `gpu_write_buf` (GPU)
- Keeps separate pointers: `read_buf` (CPU), `gpu_read_buf` (GPU)
- Uses GPU pointers in GPU kernels

**axiio-tester.hip**:
- **Overwrites** the original pointer with HSA-locked pointer:
  ```cpp
  readBuffer = gpu_readBuffer;  // Original pointer lost!
  writeBuffer = gpu_writeBuffer;  // Original pointer lost!
  ```
- This means CPU operations (like memset) might fail if they need the original pointer

### 4. Buffer Mapping Offsets

Kernel module uses allocation order:
- First allocated buffer → index 0 → offset 4
- Second allocated buffer → index 1 → offset 5

**test-nvme-write-read-verify.cpp**: ✅ Correct
- Write buffer allocated first → mapped at offset 4 ✅
- Read buffer allocated second → mapped at offset 5 ✅

**axiio-tester.hip**: ❌ Incorrect in write-only mode
- Read-only mode: Read buffer allocated first → mapped at offset 4 ✅
- Write-only mode: Write buffer allocated first → mapped at offset 5 ❌ **SHOULD BE 4**

## Recommendations

1. **Fix axiio-tester.hip write-only mode**: Map write buffer at offset 4, not 5
2. **Fix axiio-tester.hip HSA locking**: Keep separate CPU/GPU pointers like test program
3. **Consider**: Make buffer mapping order explicit (read always at 4, write always at 5) regardless of allocation order









