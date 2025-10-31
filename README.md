# rocm-axiio: A ROCm Library for Accelerator-Initiated IO

## Introduction

This repository contains the source code for a ROCm library that provides
an API for Accelerator-Initiated IO (AxIIO) for AMD GPU `__device__` code.

This library targets a number of devices which we refer to as end-points. The
list of supported devices we can issue IO too is given in the
[endpoints](./endpoints) sub-folder.

## Tools

The [tools](./tools) directory contains a number of tools that are (add more
content here).

## Building

### Prerequisites

- ROCm installation with `hipcc` compiler
- `rocminfo` utility (recommended for automatic GPU architecture detection)

If `rocminfo` is not installed, the build system will fall back to hipcc's
default GPU architecture detection.

### Building with Make

Simply run:

```bash
make all
```

The Makefile will automatically detect your GPU architecture and display it
during the build. You can also specify a target architecture manually:

```bash
make OFFLOAD_ARCH=gfx1100 all
```

### Manual Build Steps

The following steps can also be used for manual builds:

```bash
hipcc --offload-arch=native -xhip -c endpoints/test-ep/test-ep.hip -o test-ep.o -fgpu-rdc -I include/
hipcc -c tester/axiio-tester.hip -fgpu-rdc -I include/
ar rcsD lib/librocm-axiio.a test-ep.o
hipcc axiio-tester.o lib/librocm-axiio.a -o bin/axiio-tester -fgpu-rdc
unbuffer /opt/rocm-7.0.2/lib/llvm/bin/llvm-objdump --demangle --disassemble-all lib/librocm-axiio.a | less -R
```

## Additional Useful Information

On MI300X, the host allocation should be always `UNCACHED`. I think a
`__threadfence()` should work for MI300X. However it has been seen that
`__threadfence_system()` is needed on Radeon GPUs.

I learned last week the hard way again that you do not have fine-grain memory
on Radeon GPUs unless you set `HSA_FORCE_FINE_GRAIN_PCIE=1`.

Coarse-grained memory basically means that a change at a memory location might
only become visible to the CPU once the kernel finishes. Fine-grained means
that changes to memory should be visible 'immediatly' (with immediately being
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
