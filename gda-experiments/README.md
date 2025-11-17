# GDA Experiments

This directory contains experimental code for GPU Direct Access (GDA) research and testing.

## Contents

This directory includes various proof-of-concept implementations and test programs for:

- **GPU-to-NVMe doorbell access** - Direct GPU writes to NVMe doorbell registers
- **VFIO/IOMMU P2P mappings** - Setting up peer-to-peer device mappings
- **HSA memory pool experiments** - Testing HSA memory allocation strategies
- **QEMU/VM P2P testing** - GPU-NVMe interactions in virtualized environments
- **DMA buffer testing** - Various DMA buffer allocation and mapping approaches

## Purpose

These experiments informed the development of the main `rocm-axiio` library, particularly:

- The NVMe endpoint implementation (`endpoints/nvme-ep/`)
- Kernel module design (`kernel-module/`)
- CPU-hybrid vs GPU-direct doorbell modes
- HSA memory locking strategies

## Building

Most experiments are standalone C/C++/HIP files that can be built individually:

```bash
# Example: Build a doorbell test
hipcc test_gpu_doorbell_simple.hip -o test_gpu_doorbell -I../include

# Example: Build a VFIO test (needs VFIO headers)
gcc vfio_p2p_setup.c -o vfio_p2p_setup
```

## Note

These are research artifacts and may not be production-ready. For stable functionality, use the main library and `axiio-tester` application.

## nvme-gda Subdirectory

The `nvme-gda/` subdirectory contains a kernel driver prototype for NVMe GPU Direct Access. This work was integrated into the main `kernel-module/` directory.

