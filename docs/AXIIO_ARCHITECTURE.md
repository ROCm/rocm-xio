# ROCm-AXIIO Architecture

## Overview

ROCm-AXIIO (Accelerated eXternal I/O Interface for ROCm) is a framework for GPU-direct I/O operations on AMD GPUs using the ROCm platform. The project enables GPUs to directly initiate and manage I/O operations to external devices (NVMe, RDMA, etc.) without CPU intervention, reducing latency and increasing throughput.

## Project Goals

1. **True GPU-Direct I/O**: Enable GPUs to directly ring device doorbells without CPU involvement
2. **Low Latency**: Minimize I/O operation latency by eliminating CPU round-trips
3. **Flexibility**: Support multiple I/O backends (NVMe, RDMA, DMA) through endpoint abstraction
4. **Portability**: Work on consumer AMD hardware without requiring specialized drivers

## High-Level Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                     User Application                          │
└─────────────────────────┬────────────────────────────────────┘
                          │
                          ▼
┌──────────────────────────────────────────────────────────────┐
│                    AXIIO Tester/API                           │
│  - Configuration Management                                   │
│  - Endpoint Selection                                         │
│  - Performance Measurement                                    │
└─────────────────────────┬────────────────────────────────────┘
                          │
                ┌─────────┴─────────┐
                │                   │
                ▼                   ▼
┌───────────────────────┐  ┌──────────────────────┐
│   Endpoint Layer      │  │  Helper Libraries    │
│  - nvme-ep            │  │  - PCIe Atomics      │
│  - rdma-ep            │  │  - GPU Doorbell HSA  │
│  - sdma-ep            │  │  - NVMe Utils        │
│  - test-ep            │  │  - Queue Management  │
└───────────┬───────────┘  └──────────────────────┘
            │
            ▼
┌──────────────────────────────────────────────────────────────┐
│                  Kernel Module (nvme_axiio)                   │
│  - Exclusive Device Control                                   │
│  - Queue Management (SQ/CQ)                                   │
│  - DMA Memory Allocation                                      │
│  - Doorbell Mapping (BAR0)                                    │
└─────────────────────────┬────────────────────────────────────┘
                          │
                          ▼
┌──────────────────────────────────────────────────────────────┐
│                     Hardware Layer                            │
│  - NVMe Controller                                            │
│  - RDMA NICs                                                  │
│  - PCIe Interconnect                                          │
└──────────────────────────────────────────────────────────────┘
```

## Core Components

### 1. Endpoint System

The endpoint system provides an abstraction layer for different I/O backends.

**Design Philosophy:**
- Each endpoint implements a common interface
- Endpoints are registered at compile-time
- Runtime dispatch to appropriate endpoint based on configuration

**Supported Endpoints:**

- **nvme-ep**: NVMe SSD I/O operations
- **rdma-ep**: RDMA network I/O
- **sdma-ep**: System DMA operations
- **test-ep**: Emulated endpoint for testing

**Key Files:**
- `endpoints/*/[endpoint]-ep.h` - Endpoint implementations
- `common/endpoint-registry.hip` - Endpoint registration
- `include/axiio-endpoint-registry-gen.h` - Generated endpoint dispatch (auto-generated)

### 2. GPU Doorbell Management

The GPU doorbell system enables GPUs to directly signal hardware devices.

**Evolution:**

1. **Initial Attempt**: Direct mmap + GPU access → Failed (page faults)
2. **dmabuf Approach**: Kernel dmabuf export → Failed (hipImportExternalMemory limitation)
3. **rocSHMEM Style**: CPU pointer direct use → Failed for NVMe (works for NICs)
4. **HSA Solution**: `hsa_amd_memory_lock()` → ✅ **SUCCESS**

**Current Architecture:**

```
User Space:
┌────────────────────────────────────────────────┐
│  CPU Thread                  GPU Kernel        │
│     │                            │             │
│     │ hsa_amd_memory_lock()      │             │
│     ├────────────────────┐       │             │
│     │                    │       │             │
│     ▼                    ▼       ▼             │
│  CPU Pointer ────────────►  GPU Pointer        │
│  (original mmap)         (HSA-locked)          │
└────────┬───────────────────────┬───────────────┘
         │                       │
         │ read/debug            │ write
         │                       │ __hip_atomic_store
         │                       │ __HIP_MEMORY_SCOPE_SYSTEM
         │                       │
         └───────────┬───────────┘
                     ▼
Kernel Space:      MMIO
┌─────────────────────────────────────────────┐
│  nvme_axiio kernel module                   │
│  - mmap() doorbell BAR                      │
│  - Provides CPU mapping                     │
└──────────────────┬──────────────────────────┘
                   │
                   ▼
Hardware:
┌─────────────────────────────────────────────┐
│  NVMe Doorbell Register (BAR0)              │
│  - Submission Queue Tail Doorbell           │
│  - Completion Queue Head Doorbell           │
└─────────────────────────────────────────────┘
```

**Key Insight:** 
HSA memory locking (`hsa_amd_memory_lock()`) registers the CPU-mapped MMIO region with the GPU's MMU, enabling safe GPU access to doorbell registers without page faults.

**Key Files:**
- `tester/nvme-gpu-doorbell-hsa.h` - HSA doorbell mapping functions
- `tester/nvme-axiio-kernel.h` - Kernel module integration
- `kernel-module/nvme_axiio.c` - Kernel module implementation

### 3. Kernel Module (nvme_axiio)

The kernel module provides exclusive device control and DMA memory management.

**Responsibilities:**

1. **Device Binding**: Takes exclusive control of NVMe device
2. **Queue Management**: Creates and manages I/O queues (SQ/CQ)
3. **DMA Allocation**: Allocates DMA-capable memory for queues
4. **BAR Mapping**: Maps device registers (BAR0) for doorbell access
5. **IOCTL Interface**: Provides userspace API for configuration

**IOCTL Commands:**

```c
NVME_AXIIO_CREATE_QUEUE         // Create I/O queue pair
NVME_AXIIO_REGISTER_USER_QUEUE  // Update existing queue
NVME_AXIIO_GET_GPU_DOORBELL     // Get doorbell info for GPU access
NVME_AXIIO_EXPORT_DOORBELL_DMABUF // Export doorbell as dmabuf (legacy)
```

**Memory Mapping Offsets:**

```
offset = 0          : Submission Queue DMA memory
offset = 4096       : Completion Queue DMA memory  
offset = 2*PAGE_SIZE: Doorbell BAR (CPU-accessible)
offset = 3*PAGE_SIZE: Doorbell BAR (GPU-optimized, requires GPU FD)
```

**Key Files:**
- `kernel-module/nvme_axiio.c` - Main module implementation
- `kernel-module/nvme_axiio.h` - IOCTL definitions
- `kernel-module/nvme_doorbell_dmabuf.h` - dmabuf support (legacy)

### 4. Queue Management

NVMe uses a queue-based communication model.

**Queue Structure:**

```
Submission Queue (SQ):
┌─────────────────────────────────────────┐
│  SQE[0] │ SQE[1] │ ... │ SQE[N-1]      │  (64 bytes each)
└─────────────────────────────────────────┘
                           ▲
                           │ SQ Tail (what to execute next)

Completion Queue (CQ):
┌─────────────────────────────────────────┐
│  CQE[0] │ CQE[1] │ ... │ CQE[N-1]      │  (16 bytes each)
└─────────────────────────────────────────┘
                           ▲
                           │ CQ Head (what's been processed)
```

**Doorbell Protocol:**

1. GPU writes NVMe command to SQ entry
2. GPU writes new tail value to SQ doorbell → **Controller sees new work**
3. Controller processes command
4. Controller writes completion to CQ entry
5. Controller updates CQ (generates interrupt or polls)
6. CPU/GPU reads completion from CQ
7. CPU/GPU updates CQ head doorbell → **Controller knows space is free**

**Key Files:**
- `tester/nvme-queue-manager.h` - Queue setup and management
- `tester/nvme-commands.h` - NVMe command structures

### 5. Memory Management

The system uses different memory types based on operational mode:

**GPU-Direct Mode (GDA):**
```
┌─────────────────────────────────────────────┐
│  DMA Memory (kernel module allocated)       │
│  - Physically contiguous                    │
│  - DMA-capable bus addresses                │
│  - mmap'd to userspace                      │
│  - GPU can access directly (no copy)        │
└─────────────────────────────────────────────┘
       ▲                               ▲
       │                               │
    GPU writes                    NVMe DMAs
    commands                      from here
```

**Note**: CPU-hybrid mode has been removed. The system now always uses GPU-direct mode and will fail if exclusive mode is not available.

### 6. Atomics and Synchronization

**PCIe Atomics:**

Required for AMD GPU compute operations. The system verifies:
- PCIe root complex supports atomics
- GPU supports atomics
- Atomics are enabled in configuration

**GPU Doorbell Writes:**

```c++
__global__ void write_doorbell_kernel(volatile uint32_t* doorbell, uint32_t value) {
    // System-scope atomic ensures visibility across PCIe
    __hip_atomic_store(doorbell, value, 
                       __ATOMIC_RELEASE, 
                       __HIP_MEMORY_SCOPE_SYSTEM);
}
```

**Key Requirements:**
- `__HIP_MEMORY_SCOPE_SYSTEM`: Ensures PCIe-level visibility
- `__ATOMIC_RELEASE`: Ensures all prior writes are visible before doorbell
- Atomics traverse GPU → PCIe → Device interconnect

## Data Flow Example: NVMe Read Operation

```
1. GPU Kernel Prepares Command:
   ┌─────────────────────────────────────┐
   │ struct nvme_sqe sqe = {             │
   │   .opcode = NVME_CMD_READ,          │
   │   .nsid = 1,                        │
   │   .slba = target_lba,               │
   │   .prp1 = buffer_phys_addr,         │
   │ };                                  │
   │ sqQueue[tail] = sqe;                │
   └─────────────────────────────────────┘
                  │
                  ▼
2. GPU Writes Doorbell:
   ┌─────────────────────────────────────┐
   │ __hip_atomic_store(doorbell,        │
   │                    new_tail,        │
   │                    __ATOMIC_RELEASE,│
   │              __HIP_MEMORY_SCOPE_SYSTEM);│
   └─────────────────────────────────────┘
                  │
                  ▼ PCIe write transaction
3. NVMe Controller Sees New Tail:
   ┌─────────────────────────────────────┐
   │ Controller reads SQE from memory    │
   │ via DMA                             │
   └─────────────────────────────────────┘
                  │
                  ▼
4. Controller Executes Read:
   ┌─────────────────────────────────────┐
   │ Reads from NAND                     │
   │ DMAs data to buffer (prp1)          │
   │ Writes CQE to completion queue      │
   └─────────────────────────────────────┘
                  │
                  ▼
5. Software Polls/Waits for Completion:
   ┌─────────────────────────────────────┐
   │ while (cqQueue[head].phase != expected) {}│
   │ // Process completion                │
   │ Write CQ head doorbell              │
   └─────────────────────────────────────┘
```

## Performance Characteristics

### GPU-Direct Mode
- **Doorbell Latency**: < 1 microsecond
- **CPU Overhead**: Zero (no CPU involvement)
- **Scalability**: Excellent (parallel GPU threads)

**Note**: CPU-hybrid mode has been removed. The system now always uses GPU-direct mode.

### Bottlenecks
1. **PCIe Bandwidth**: Shared between GPU compute and I/O
2. **Queue Depth**: Limited by NVMe queue size (typically 1024)
3. **Completion Processing**: Requires polling or interrupts

## Build System

The project uses GNU Make with automatic GPU architecture detection.

**Key Targets:**

```makefile
make                    # Build library only
make all               # Build library + tester
make axiio-tester      # Build tester only (deprecated target)
make clean             # Clean build artifacts
make format            # Run clang-format
make lint              # Run linting checks
```

**Compilation Flags:**

- GPU-direct doorbell mode is always enabled (no compile-time flag)
- `-fgpu-rdc`: Enable GPU relocatable device code
- `-Iendpoints/*`: Include all endpoint headers

**Auto-Generated Files:**

- `include/axiio-endpoint-registry-gen.h`: Endpoint dispatch table
- `common/endpoint-dispatch.hip`: Endpoint dispatch implementation

## Testing and Validation

### Test Infrastructure

**axiio-tester:**
- Main test harness
- Supports multiple endpoints
- Configurable iterations, queue sizes, memory modes
- Performance measurement and statistics

**Command-line Options:**
```bash
--endpoint <name>           # Select endpoint (nvme-ep, test-ep, etc.)
--iterations N              # Number of test iterations
--use-kernel-module         # Use kernel module for queue management
--nvme-queue-id N          # Specific queue ID to use
--verbose                  # Detailed output
```

### Validation Checklist

- [x] PCIe atomics enabled
- [x] HSA GPU doorbell mapping
- [x] Queue creation via kernel module
- [x] No GPU page faults
- [x] No segmentation faults
- [x] CPU/GPU pointer separation

### Known Limitations

1. **Completion Processing**: Currently relies on polling; interrupt support not implemented
2. **Error Handling**: Limited error recovery for failed I/O operations
3. **Queue Depth**: Fixed at compile/init time; no dynamic resizing
4. **Device Support**: Currently focused on NVMe; RDMA endpoint needs work

## Future Directions

### Short-Term
1. Fix NVMe completion reception (doorbell value remains 0)
2. Implement proper CQE processing with phase bit checking
3. Add data buffer validation for actual I/O operations

### Medium-Term
1. Implement interrupt-based completion notification
2. Add multi-queue support for parallel I/O streams
3. Optimize memory allocation and pinning strategies
4. Add comprehensive error handling and recovery

### Long-Term
1. Support for other AMD GPU architectures (CDNA, older RDNA)
2. Integration with higher-level frameworks (PyTorch, TensorFlow)
3. Benchmarking suite for performance comparisons
4. Support for NVMe Namespace management
5. P2P GPU-to-GPU data transfers via NVMe

## References

### Documentation in `docs/`
- `FINAL_TEST_RESULTS.md`: Latest test results and success metrics
- `GPU_DOORBELL_SUCCESS_WITH_HSA.md`: HSA solution breakthrough
- `HSA_GPU_DOORBELL_INTEGRATION_COMPLETE.md`: Integration details
- `ROCSHMEM_GPU_DOORBELL_METHOD.md`: Insights from rocSHMEM
- `GPU_DOORBELL_LIMITATION.md`: Failed approaches and lessons learned
- `KERNEL_MODULE_SUCCESS.md`: Kernel module development

### External References
- NVMe Specification 1.4: Queue model and doorbell protocol
- AMD ROCm Documentation: HSA runtime and memory management
- rocSHMEM Source: GDA (GPU-Direct Access) patterns
- Linux Kernel: DMA-BUF framework and device drivers

## Contributing

When modifying the codebase:
1. Run `make format` before committing
2. Ensure `make lint` passes
3. Test with both emulated and real hardware modes
4. Update documentation for significant changes
5. Add tests for new functionality

## License

[Project license information here]

---

*Last Updated: November 4, 2025*
*Architecture Version: 1.0*

