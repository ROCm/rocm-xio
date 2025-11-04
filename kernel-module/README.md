# NVMe AXIIO Kernel Module

Custom Linux kernel module for GPU-direct NVMe I/O operations.

## Overview

The `nvme_axiio` kernel module provides a character device (`/dev/nvme-axiio`) that allows userspace applications to create dedicated NVMe I/O queues and map doorbell registers for GPU access. This enables zero-CPU-overhead NVMe doorbell writes via GPU peer-to-peer MMIO.

## Features

- **Dedicated Queue Creation**: Create I/O submission and completion queues isolated from kernel driver
- **DMA-Coherent Memory**: Allocate DMA-coherent memory for queue buffers
- **Doorbell Mapping**: Expose NVMe doorbell registers for GPU P2P access
- **BAR0 Bus Address**: Provide BAR0 bus addresses for GPU memory mapping
- **Automatic Device Discovery**: Find NVMe PCI devices by class code

## IOCTL Interface

### `NVME_AXIIO_CREATE_QUEUE`
Create a dedicated I/O queue pair (submission + completion queue).

**Input:**
- `qid`: Queue ID
- `queue_size`: Number of entries
- `nsid`: Namespace ID

**Output:**
- `sq_dma_addr`: Physical address of submission queue
- `cq_dma_addr`: Physical address of completion queue
- `sq_doorbell_phys`: Physical address of SQ doorbell
- `cq_doorbell_phys`: Physical address of CQ doorbell
- `bar0_phys`: BAR0 physical address
- `bar0_size`: BAR0 size
- `doorbell_stride`: Doorbell stride

### `NVME_AXIIO_MAP_DOORBELL_FOR_GPU`
Get doorbell mapping information for GPU P2P access.

**Input:**
- `queue_id`: Queue ID to map

**Output:**
- `doorbell_bus_addr`: Bus address for GPU P2P access
- `doorbell_phys`: Physical address for CPU access
- `doorbell_offset`: Offset within BAR0
- `bar0_bus_addr`: BAR0 bus address (for GPU mapping)
- `bar0_phys`: BAR0 physical address
- `bar0_size`: BAR0 size

## Build and Install

```bash
# Build the module
make

# Load the module
sudo insmod nvme_axiio.ko

# Verify it loaded
lsmod | grep nvme_axiio
ls -l /dev/nvme-axiio

# View kernel logs
dmesg | tail -20

# Unload the module
sudo rmmod nvme_axiio
```

## Usage Example

See `test_axiio_ioctl.c` for a complete userspace example:

```c
int fd = open("/dev/nvme-axiio", O_RDWR);

struct nvme_axiio_queue_info qinfo = {
    .qid = 63,
    .queue_size = 1024,
    .nsid = 1,
};

// Create queue
ioctl(fd, NVME_AXIIO_CREATE_QUEUE, &qinfo);

// Map queue memory
void *sq = mmap(NULL, qinfo.sq_dma_addr, ..., fd, 0);
void *cq = mmap(NULL, qinfo.cq_dma_addr, ..., fd, PAGE_SIZE);

// Get doorbell for GPU
struct nvme_axiio_doorbell_mapping dbmap = {.queue_id = 63};
ioctl(fd, NVME_AXIIO_MAP_DOORBELL_FOR_GPU, &dbmap);

// Use dbmap.doorbell_bus_addr with HSA for GPU access
```

## GPU Doorbell Access

To enable GPU writes to doorbell registers:

1. Get doorbell bus address via `NVME_AXIIO_MAP_DOORBELL_FOR_GPU`
2. Use HSA `hsa_amd_memory_lock()` to map for GPU:
   ```c
   void *gpu_ptr;
   hsa_amd_memory_lock((void*)dbmap.doorbell_bus_addr, 
                       dbmap.bar0_size,
                       gpu_agent, 0, &gpu_ptr);
   ```
3. GPU kernels can now write to `gpu_ptr`

See `test_gpu_doorbell.cpp` for a complete GPU example.

## Integration with axiio-tester

```bash
# Build axiio-tester with GPU-direct doorbell support
GPU_DIRECT_DOORBELL=1 make all

# Run with GPU-direct doorbell
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 \
                         --memory host \
                         --iterations 100 \
                         --real-hardware
```

## Kernel Module Parameters

Currently, the module uses default parameters. Future versions may expose:
- Target NVMe device selection
- Queue size limits
- Debug verbosity levels

## Architecture

```
Userspace (axiio-tester)
    |
    | ioctl()
    v
/dev/nvme-axiio (Character Device)
    |
    v
nvme_axiio.ko (Kernel Module)
    |
    |-- PCI Device Discovery (NVMe controllers)
    |-- BAR0 Mapping (ioremap)
    |-- DMA Memory Allocation (dma_alloc_coherent)
    |-- Queue Creation (via NVMe admin commands)
    |
    v
NVMe Controller Hardware
    |
    |-- BAR0 (Doorbell Registers)
    |-- DMA (Queue Memory Access)
```

## Troubleshooting

**Module fails to load:**
```bash
# Check kernel logs
dmesg | tail -50

# Verify NVMe devices present
lspci | grep -i nvme

# Check kernel version compatibility
uname -r
```

**No NVMe devices found:**
- Ensure NVMe devices are present: `lspci | grep -i nvme`
- Check PCI class code in dmesg: should be `0x00010802`

**Queue creation fails:**
- Check NVMe controller queue limits: `nvme id-ctrl /dev/nvme0`
- Try a different queue ID (default: QID 1)
- Ensure not conflicting with kernel driver queues

**GPU access fails:**
- Verify HSA runtime is available
- Check IOMMU settings: `dmesg | grep -i iommu`
- Confirm GPU P2P support: AMD Radeon VII or newer

## Files

- `nvme_axiio.h`: IOCTL definitions and data structures
- `nvme_axiio.c`: Kernel module implementation
- `Makefile`: Build system
- `test_axiio_ioctl.c`: Userspace test program
- `test_gpu_doorbell.cpp`: GPU doorbell validation
- `README.md`: This file

## License

Same as rocm-axiio project.

## References

- NVMe Specification 1.4+
- Linux Kernel Module Programming Guide
- HSA Runtime Programmer's Reference Manual
- AMD ROCm Documentation
