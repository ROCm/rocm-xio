# rocm-axiio: A ROCm Library for Accelerator-Initiated IO

## Introduction

This repository contains the source code for a ROCm library that provides
an API for Accelerator-Initiated IO (AxIIO) for AMD GPU `__device__` code.

This library enables AMD GPUs to perform direct IO operations to hardware
devices (NVMe SSDs, RDMA NICs, SDMA engines) without CPU intervention.

This library targets a number of devices which we refer to as endpoints. The
list of supported devices we can issue IO to is given in the
[endpoints](./endpoints) sub-folder.

## Quick Reference

### Build and Run

```bash
# 1. Install ROCm (if not already installed)
sudo apt install rocm-hip-sdk rocminfo libcli11-dev

# 2. Build
make all

# 3. Run with GPU + NVMe
export HSA_FORCE_FINE_GRAIN_PCIE=1
sudo ./bin/axiio-tester nvme-ep --controller /dev/nvme0 \
  --read-io 50 --write-io 50 --verbose
```

## Endpoints

Endpoints define the hardware interfaces and protocols for different IO
devices. Each endpoint provides its own queue entry formats and IO semantics.

### **test-ep** - Test endpoint for development and testing
  - Used for validating the AxIIO framework

### **nvme-ep** - NVMe endpoint 
  - Implements NVMe command submission (SQE) and completion (CQE) handling
  - Supports Read and Write commands
  - Definitions based on Linux kernel NVMe headers and NVMe specification

### Listing Available Endpoints

To see all available endpoints:
```bash
./bin/axiio-tester --list-endpoints
```

### Environment Variables for Radeon GPUs

**IMPORTANT**: On consumer Radeon GPUs (RX series), you **should** set the
following environment variable before running any tests:
```bash
export HSA_FORCE_FINE_GRAIN_PCIE=1
```
This enables fine-grained memory coherence which is required for GPU-to-CPU
memory visibility. Without this setting, the GPU will encounter page faults
when accessing host memory.

**Note**: On MI-series accelerators (MI300X, etc.), this is typically not
required as fine-grained memory is available by default.

## Additional Useful Information

On MI300X, the host allocation should be always `UNCACHED`. I think a
`__threadfence()` should work for MI300X. However it has been seen that
`__threadfence_system()` is needed on Radeon GPUs.

I learned last week the hard way again that you do not have fine-grain memory
on Radeon GPUs unless you set `HSA_FORCE_FINE_GRAIN_PCIE=1`.

Coarse-grained memory basically means that a change at a memory location might
only become visible to the CPU once the kernel finishes. Fine-grained means
that changes to memory should be visible 'immediately' (with immediately being
obviously the wrong term, but basically not just at the end of the kernel
runtime). So its about visibility and cache coherence. As is often the case
there is a good [Confluence page][ref-mem-grain] by Joseph Greathouse on this
topic! It definitely impacts device memory. The part that I am unsure is
whether it impacts things like `hipHostMalloc()`'d memory, which is host
memory but managed by ROCr, I don't know whether similar rules apply to it as
well.

`hipHostMalloc()` comes in two flavors. One is pinned and the other is
pageable/migratable. The pinned version is almost always what we will want in
rocm-axiio because we do not want to have the delay that happens if a device
tries to access an unmapped page-able memory page. Because that results in an
XNACK and associated PTE updates. That would be more useful for very large VMAs
which the __device__ code is going to access randomly and sporadically.

The last 2 weeks of my pain have stemmed from two things:

If __device__ code does a store to host memory what is needed to ensure that a
process running on a host cpu core can see the store? The answer here is
(I think) hipHostMalloc(), volatile pragmas (on the host) and
`__threadfence_system()` (on the device).

If __host__ code does a store to host memory what is needed to ensure that a
process running on a GPU core can see the store? Here the answer is (I think)
just hipHostMalloc(). The hipHostMalloc() ensures the memory if flagged as
uncached and so any CPU process writes to that VMA become visible at the system
level. I think. I am adding all this to the top-level README for now till we
get a nice clean scriptable way to ensuring these rules are applied at the
system level and vary depending on the GPU and endpoint(s) used.

[ref-mem-grain]: https://amd.atlassian.net/wiki/spaces/AMDGPU/pages/777526553/Cache+coherence+summary+by+Joseph+Greathouse
