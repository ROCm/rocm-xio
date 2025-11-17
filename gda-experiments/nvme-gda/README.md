# NVMe GPU Direct Async (GDA) Implementation

This is an experimental implementation of GPU Direct Async for NVMe SSDs, inspired by rocSHMEM's MLX5 GDA implementation.

## Overview

This project enables AMD GPUs to directly ring NVMe SSD doorbells without CPU involvement, achieving:
- Zero-copy I/O from GPU memory
- Low latency (no CPU intervention)
- High bandwidth (GPU threads saturate NVMe queues)

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        GPU Kernel                            │
│  - Builds NVMe commands                                     │
│  - Writes to submission queue                               │
│  - Rings doorbell directly (MMIO write)                     │
│  - Polls completion queue                                   │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼ PCIe P2P
┌─────────────────────────────────────────────────────────────┐
│                      NVMe Controller                         │
│  - Doorbell registers (BAR0)                                │
│  - Submission/Completion queues in host memory              │
│  - DMA engine                                               │
└─────────────────────────────────────────────────────────────┘
```

## Components

### 1. Kernel Driver (`nvme_gda_driver/`)
- Exposes NVMe doorbell registers to userspace
- Provides queue setup and management
- Implements character device interface `/dev/nvme_gda0`

### 2. Userspace Library (`lib/`)
- `nvme_gda.h` - Main API
- `nvme_gda.cpp` - Queue management, HSA memory locking
- `nvme_gda_device.hip` - GPU-side doorbell ring functions

### 3. Test Programs (`tests/`)
- `test_basic_doorbell.hip` - Simple doorbell ring test
- `test_gpu_io.hip` - Full GPU-initiated I/O test
- `benchmark.hip` - Performance benchmarking

## Building

### Prerequisites
```bash
# ROCm
sudo apt install rocm-dev

# Kernel headers
sudo apt install linux-headers-$(uname -r)

# Build tools
sudo apt install build-essential cmake
```

### Build Kernel Driver
```bash
cd nvme_gda_driver
make
sudo insmod nvme_gda.ko nvme_pci_dev=0000:01:00.0  # Your NVMe PCI address
```

### Build Library and Tests
```bash
mkdir build && cd build
cmake ..
make
```

## Usage

### Basic Test
```bash
# Load driver
sudo insmod nvme_gda_driver/nvme_gda.ko nvme_pci_dev=0000:01:00.0

# Run test
./build/test_basic_doorbell
```

### GPU I/O Test
```bash
./build/test_gpu_io --device /dev/nvme_gda0 --queue-size 256
```

## API Example

```cpp
#include "nvme_gda.h"

// Initialize
nvme_gda_context* ctx = nvme_gda_init("/dev/nvme_gda0");

// Create GPU-accessible queue
nvme_gda_queue* queue = nvme_gda_create_queue(ctx, 256);

// Launch GPU kernel
hipLaunchKernelGGL(gpu_io_kernel, blocks, threads, 0, 0, queue);

// GPU kernel code
__global__ void gpu_io_kernel(nvme_gda_queue* queue) {
  // Each thread builds NVMe command
  nvme_command cmd = build_read_command(...);
  
  // Post to submission queue
  nvme_gda_post_command(queue, &cmd);
  
  // Ring doorbell from GPU!
  nvme_gda_ring_doorbell(queue);
  
  // Wait for completion
  nvme_gda_wait_completion(queue);
}
```

## Safety and Limitations

⚠️ **EXPERIMENTAL CODE** ⚠️

- Not for production use
- May crash your system
- Can corrupt NVMe data
- Requires careful PCIe topology (GPU and NVMe on same switch)
- Needs IOMMU configuration

## Performance Tips

1. **PCIe Topology**: Place GPU and NVMe on same PCIe switch
2. **Queue Depth**: Use multiple submission queues (one per GPU CU)
3. **Batch Operations**: Amortize doorbell overhead
4. **Memory Pinning**: Pin GPU memory for DMA

## Debugging

```bash
# Enable kernel driver debug output
echo 8 > /proc/sys/kernel/printk

# Monitor NVMe controller
nvme list
nvme id-ctrl /dev/nvme0

# Check PCIe topology
lspci -tv | grep -E "(VGA|NVMe)"

# Verify doorbell mapping
sudo cat /proc/$(pgrep test_basic)/maps | grep nvme_gda
```

## References

- NVMe Specification 1.4
- ROCm Documentation
- rocSHMEM GDA Implementation
- Linux NVMe Driver Source

## License

MIT License (Experimental Research Code)

