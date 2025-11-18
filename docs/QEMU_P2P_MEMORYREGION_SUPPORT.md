# QEMU P2P MemoryRegion Support for GPU-Initiated NVMe I/O

## Overview

This document describes the implementation of GPU-to-NVMe direct memory access
(P2P) in QEMU for emulated NVMe devices, enabling GPU-initiated NVMe I/O
operations with proper data visibility and integrity.

## Architecture

### Problem Statement

Previously, QEMU allocated its own memory buffers and mapped them to IOVA for
GPU access, while the guest kernel module allocated separate DMA-coherent memory
and mapped it to userspace. These were two entirely separate physical memory
regions, causing GPU writes to QEMU's IOVA-mapped buffer to not be visible to
the CPU/kernel module's buffer, and vice-versa.

### Solution: QEMU Provides Buffers as Guest RAM

The architectural decision was made for QEMU to allocate the memory buffers
(SQE, CQE, doorbell) and expose them as guest RAM using QEMU's `MemoryRegion`
API. This ensures that both QEMU (via HVA) and the guest kernel module (via GPA
mapped to userspace) operate on the *same physical memory*.

## Implementation Details

### QEMU Changes

#### MemoryRegion Creation

In `nvme_p2p_init`, QEMU now:

1. **Allocates host memory** for SQE, CQE, and doorbell buffers using
   `qemu_memalign`
2. **Initializes MemoryRegion objects** using `memory_region_init_ram_ptr` from
   the allocated host memory
3. **Assigns high Guest Physical Addresses (GPAs)** to these regions (starting
   at `0x1000000000ULL` = 64GB) to avoid conflicts with normal guest memory
4. **Adds MemoryRegions to guest system memory** using
   `memory_region_add_subregion(get_system_memory(), ...)`
5. **Maps buffers to IOVA** for GPU access (existing functionality)

#### GPA Fields in P2P IOVA Info

The `NvmeP2PIovaInfo` structure now includes:
- `sqe_gpa`: Guest physical address of SQE buffer
- `cqe_gpa`: Guest physical address of CQE buffer
- `doorbell_gpa`: Guest physical address of doorbell buffer

These GPAs are returned to the guest kernel module via vendor command 0xC0.

#### MemoryRegion Cleanup

`nvme_p2p_cleanup` properly:
- Unrefs MemoryRegion subregions
- Deletes subregions from guest system memory
- Frees allocated host memory

### Kernel Module Changes

#### QEMU GPA Detection

The kernel module checks if QEMU-provided GPAs are available:
- Queries P2P IOVA info via vendor command 0xC0
- If `queue_iova.sqe_gpa != 0`, uses QEMU's GPA addresses
- Otherwise, falls back to DMA allocation (for real hardware)

#### Memory Mapping

For QEMU GPA buffers:
- Uses `remap_pfn_range` with GPA converted to PFN (`gpa >> PAGE_SHIFT`)
- Uses normal page protection (not write-combine) for RAM-backed MemoryRegions
- Sets `VM_PFNMAP | VM_DONTEXPAND | VM_DONTDUMP` flags

For DMA-allocated buffers (fallback):
- Uses `dma_mmap_coherent` as before

#### Cleanup

The kernel module checks if buffers are QEMU GPAs (`dma_addr >= 0x1000000000ULL`):
- QEMU GPA buffers: No cleanup needed (QEMU manages them)
- DMA buffers: Uses `dma_free_coherent` as before

## Data Flow

### Write Path

1. GPU generates NVMe write commands in SQE buffer (via IOVA)
2. GPU writes are visible to QEMU (same host memory via HVA)
3. GPU rings doorbell (via IOVA)
4. QEMU doorbell forwarding detects write and forwards to emulated NVMe
5. QEMU processes NVMe commands and performs DMA to data buffers
6. Data is written to emulated NVMe storage

### Read Path

1. GPU generates NVMe read commands in SQE buffer (via IOVA)
2. GPU rings doorbell (via IOVA)
3. QEMU processes NVMe commands and performs DMA from data buffers
4. Data is read from emulated NVMe storage into completion queue
5. GPU reads completion entries from CQE buffer (via IOVA)
6. Read data is available in userspace-mapped buffers

## Testing

### Test Program: `test-nvme-write-read-verify.cpp`

A comprehensive test program that:

1. **Writes random data patterns** to first 512 LBAs (0-511)
   - Uses deterministic LFSR sequence for data generation
   - GPU generates NVMe write commands
   - Verifies writes are processed by QEMU

2. **Reads back from random LBAs** in range 0-511
   - Selects 100 random LBAs
   - GPU generates NVMe read commands
   - Verifies reads are processed by QEMU

3. **Verifies data integrity**
   - Regenerates expected data using same LFSR sequence
   - Compares read data with expected data byte-by-byte
   - Reports any mismatches

### Test Results

- ✅ Successfully wrote 512 LBAs with random data patterns
- ✅ Successfully read back 100 random LBAs
- ✅ All 51,200 bytes verified successfully (zero mismatches)
- ✅ Confirms GPU-initiated NVMe I/O works end-to-end with data integrity

## Benefits

1. **Unified Memory Model**: QEMU and guest kernel module operate on same
   physical memory
2. **Data Visibility**: GPU writes are immediately visible to QEMU and CPU
3. **Data Integrity**: Verified end-to-end with zero mismatches
4. **Backward Compatible**: Falls back to DMA allocation for real hardware
5. **Proper Cleanup**: MemoryRegions are properly managed by QEMU

## Files Modified

### QEMU
- `hw/nvme/nvme-p2p.c`: MemoryRegion creation and management
- `hw/nvme/nvme-p2p.h`: Added GPA fields to `NvmeP2PState` and `NvmeP2PIovaInfo`
- `hw/nvme/nvme.h`: Added MemoryRegion fields to p2p struct
- `hw/nvme/ctrl.c`: Returns GPA fields via vendor command 0xC0
- `hw/nvme/trace-events`: Fixed trace formatting

### Kernel Module
- `kernel-module/nvme_axiio.c`: QEMU GPA detection and mapping
- `kernel-module/nvme_p2p_iova.h`: Added GPA fields matching QEMU structure

### Test Programs
- `tester/test-nvme-write-read-verify.cpp`: Comprehensive test with verification

## References

- QEMU MemoryRegion API: `include/exec/memory.h`
- NVMe Specification: Queue model and doorbell protocol
- Linux Kernel: `remap_pfn_range` for GPA mapping
- AMD ROCm: HSA runtime for GPU memory locking

## Future Work

1. Support for multiple queues with separate MemoryRegions
2. Dynamic GPA allocation to avoid conflicts
3. Performance optimization for large transfers
4. Support for other emulated storage devices

---

*Last Updated: December 2024*
*Implementation Version: 1.0*


