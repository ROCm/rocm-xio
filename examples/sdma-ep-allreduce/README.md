# SDMA AllReduce Benchmark

MPI-based allreduce benchmark using local reduction + SDMA allgather, equivalent to the `allreduce9` kernel pattern.

## Algorithm

1. **Local Reduction**: Each rank reduces its assigned chunk by summing contributions from all peers using P2P memory reads
2. **AllGather via SDMA**: Each rank uses SDMA to distribute its reduced chunk to all peers

This is a reduce-scatter followed by allgather pattern, similar to ring allreduce but using SDMA for the gather phase.

## Requirements

- N AMD GPUs with XGMI/Infinity Fabric P2P connectivity
- MPI (OpenMPI, MPICH, etc.)
- Root access (`/dev/kfd` requires privileges)

## Build

From the rocm-xio build directory:

```bash
cmake --build . --target sdma-ep-allreduce
```

## Usage

```bash
# Device-initiated (GPU kernel drives SDMA)
mpirun -np <N> sudo ./examples/sdma-ep-allreduce/sdma-ep-allreduce [-w warmup] [-n iters]

# Host-initiated (CPU drives SDMA)
mpirun -np <N> sudo ./examples/sdma-ep-allreduce/sdma-ep-allreduce --host-initiated [-w warmup] [-n iters]
```

### Options

- `-w <warmup>`: Number of warmup iterations (default: 5)
- `-n <iters>`: Number of measured iterations (default: 20)
- `--host-initiated`: Use CPU-driven SDMA instead of GPU kernel

### Example

```bash
# 8 GPUs, 10 warmup, 50 measurement iterations
mpirun -np 8 sudo ./examples/sdma-ep-allreduce/sdma-ep-allreduce -w 10 -n 50
```

## Output

The benchmark sweeps power-of-2 sizes from 4 KB to 16 MB and prints a table:

```
# SDMA AllReduce Benchmark
# Ranks: 8, Mode: device-initiated
# Warmup: 5, Iterations: 20
#
#  Size(KB)    Time(us)  BusBW(GB/s)  AlgBW(GB/s)
#--------------------------------------------------
        4       12.50       22.40        2.80
        8       15.30       36.60        4.58
       16       18.20       61.54        7.69
      ...
```

- **Size**: Total buffer size across all ranks
- **Time**: Average latency per allreduce operation (microseconds)
- **BusBW**: Bus bandwidth (total data movement across all links)
- **AlgBW**: Algorithm bandwidth (total data size / time)

## Comparison to allreduce9

This benchmark is inspired by the `allreduce9` kernel which uses:
- Memory channels for local reduction (P2P reads)
- DMA channels for allgather (SDMA writes)

The XIO version uses:
- Direct P2P memory reads for reduction (same concept as memory channels)
- `sdma_ep` API for allgather (equivalent to DMA channels)
