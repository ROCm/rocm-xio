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
useful in the development of this project.
