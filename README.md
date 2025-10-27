# rocm-axiio: A ROCm Library for Accelerator-Initiated IO

## Introduction

This repository contains the source code for a ROCm library that
provides an API for Accelerator-Initiated IO (AxIIO) for AMD GPU
__device__ code.

This library targets a number of devices which we refer to as
end-points. The list of supported devices we can issue IO too is given
in the [endpoints](./endpoints) sub-folder.

## Tools

The [tools](./tools) directory contains a number of tools that are

## Manual Build Steps

The following steps seem to work. So, for now, I am recording them here while I
sort out the cmake issues.

```bash
hipcc --offload-arch=native -xhip -c endpoints/test-ep/test-ep.hip -o test-ep.o -fgpu-rdc -I include/
hipcc -c tester/axiio-tester.hip -fgpu-rdc -I include/
ar rcsD lib/librocm-axiio.a test-ep.o
hipcc axiio-tester.o lib/librocm-axiio.a -o bin/axiio-tester -fgpu-rdc
unbuffer /opt/rocm-7.0.2/lib/llvm/bin/llvm-objdump --demangle --disassemble-all lib/librocm-axiio.a | less -R
```

## Additional Useful Information

On MI300X, the host allocation should be always `UNCACHED`. I think a 
`__threadfence()` should work for MI300X.
 
I learned last week the hard way again that you do not have fine-grain memory
on Radeon GPUs unless you set `HSA_FORCE_FINE_GRAIN_PCIE=1`.

 