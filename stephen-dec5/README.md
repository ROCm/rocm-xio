# Simple GPU-CPU Communication Test

This test program demonstrates simple communication between a GPU thread
and a CPU thread using shared host memory.

## Overview

- **GPU thread**: Writes a 64-byte message to host memory containing
  iteration number, GPU wall clock time, and data payload
- **CPU thread**: Polls for GPU messages, processes them, and writes a
  16-byte response containing CPU wall clock time
- **Communication**: Both threads use host-accessible memory allocated
  via `hipHostMalloc` for bidirectional communication
- **Timing**: Both threads record wall clock times in their messages

## Building

```bash
cd stephen-dec5
make
```

The binary will be created at `../bin/simple-test`.

## Running

```bash
../bin/simple-test [iterations]
```

Default is 10 iterations if no argument is provided.

Example:
```bash
../bin/simple-test 100
```

## Output

The program prints the GPU wall clock start time for each iteration,
which can be used to analyze the timing characteristics of the
communication.

## Data Structures

- **GpuToCpuMsg** (64 bytes): Contains magic number, iteration number,
  GPU wall clock time, and 40 bytes of data payload
- **CpuToGpuMsg** (16 bytes): Contains magic number and CPU wall clock
  time

## Synchronization

Both threads use polling with memory barriers to ensure proper
visibility of writes:
- GPU uses `__threadfence_system()` after writing
- CPU uses `__sync_synchronize()` after writing

