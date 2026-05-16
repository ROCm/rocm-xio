# SDMA Collective Operations

This directory contains GPU-driven collective communication operations implemented using rocm-xio sdma-endpoint.

## Overview

These implementations demonstrate GPU-driven collective operations where GPU kernels control SDMA transfers between peers, eliminating CPU involvement in the data path.

**Two execution modes:**
- **Device-initiated:** GPU threads directly program SDMA queues at runtime. Each warp issues SDMA commands to a different queue (1 queue per rank).
- **Device-triggered:** Host pre-programs SDMA queues with all transfers before kernel launch. GPU kernel atomically increments a trigger flag to release pre-programmed operations.


## Building

```bash
cd build
cmake ..
make -j
```

You might have to specify the location of the rocm-xio installation using `-DCMAKE_INSTALL_PREFIX`

## Running

### AllGather Example
```bash
# Device-initiated mode
mpirun -n 8 sdma-ep-allgather

# Device-triggered mode
mpirun -n 8 sdma-ep-allgather --device-triggered
```

### AllToAll Example
```bash
# Device-initiated mode
mpirun -n 8 sdma-ep-alltoall

# Device-triggered mode
mpirun -n 8 sdma-ep-alltoall --device-triggered
```

### Common Options
- `-w <warmup>`: Number of warmup iterations (default: 5)
- `-n <iters>`: Number of benchmark iterations (default: 20)
- `--min-bytes <size>`: Minimum transfer size in bytes (default: 4096)
- `--max-bytes <size>`: Maximum transfer size in bytes (default: 256MB)
- `--step-factor <factor>`: Multiplicative step factor between tests (default: 2)
- `--device-triggered`: Use device-triggered mode (default: device-initiated)
- `--no-validate`: Disable result validation
