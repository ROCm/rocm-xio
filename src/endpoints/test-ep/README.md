<!-- Copyright (c) Advanced Micro Devices, Inc. All rights reserved.

SPDX-License-Identifier: MIT
-->

# `test-ep`: A Software-Only Test Endpoint

`test-ep` is the rocm-xio endpoint with no hardware behind it. It
implements the same SQE / CQE round-trip protocol that `nvme-ep` and
`rdma-ep` use against silicon, but the "device" is a pool of CPU
polling threads. That makes it the natural smoke endpoint for CI,
for bring-up of any new ordering or doorbell logic, and for
self-testing the rocm-xio timing infrastructure.

For a higher-level discussion of the role this endpoint plays and
the proposed CTest matrix around it, see
[`docs/conceptual/test-ep.rst`][doc-test-ep].

## Modes at a glance

| Mode                                  | What it exercises                                   |
| ------------------------------------- | --------------------------------------------------- |
| `--threads N -n M`                    | N GPU work-items, each posting M SQEs (polling)     |
| `--doorbell Q --threads N -n M`       | Single circular SQ of depth Q, one CPU poller       |
| `--emulate`                           | Replace the GPU kernel with CPU emulation threads   |
| `--verify --seed S` (GPU path)        | LFSR data pattern check on `sqe.data[1..4]`         |
| `--delay D`                           | Negative D = fixed delay, positive D = random [0,D] |
| `--memory-mode M`                     | Bits 0/1 = SQ/CQ host vs device; bit 2 = doorbell   |

`--emulate` requires `--memory-mode 0` (everything in host memory)
and skips `hipInit`. That is the path the GitHub Actions
`test-emulate` job uses, and it is also the path the new
`tests/unit/test-ep/test-ep-launch-cpu-threads` unit test drives
directly.

## Useful one-liners

```bash
# Emulation smoke (no GPU, no NIC, no kernel module)
./build/xio-tester test-ep --emulate -n 32

# Multi-thread emulation
./build/xio-tester test-ep --emulate -n 16 --threads 4

# Doorbell-mode emulation (queue depth >= n * threads)
./build/xio-tester test-ep --emulate -n 8 \
  --threads 4 --doorbell 32

# Real GPU run with LFSR verify
HSA_FORCE_FINE_GRAIN_PCIE=1 \
  ./build/xio-tester test-ep -n 128 --verify --seed 0x1234

# Aggregate timing only, suitable for very large -n
./build/xio-tester test-ep --emulate -n 1000000 --less-timing
```

## Inspecting the kernel

The kernel is a plain HIP `__global__` symbol, so the `llvm-objdump`
recipe from the previous version of this file still works once the
build tree is populated:

```bash
llvm-objdump-18 -st \
  build/CMakeFiles/rocm-xio-objects.dir/test-ep/test-ep.hip.o
```

## Tests

Sources for the HIP rows live under `tests/system/test-ep/`, but CTest tags
them `test-ep` only (plus `cli` for the `xio-tester` smokes). They are not
labeled `system`, so `-L system` does not select them; use `-L test-ep`
(or combine with `cli`) to match `tests/system/test-ep/CMakeLists.txt`.

| Test                                 | Label              | Needs       |
| ------------------------------------ | ------------------ | ----------- |
| `test-ep-config`                     | `unit test-ep`     | CPU         |
| `test-ep-launch-cpu-threads`         | `unit test-ep`     | CPU         |
| `test-ep-emulate`                    | `test-ep`          | HIP runtime |
| `test-ep-emulate-multithread`        | `test-ep`          | HIP runtime |
| `test-ep-emulate-doorbell`           | `test-ep`          | HIP runtime |
| `test-ep-emulate-timing`             | `test-ep`          | HIP runtime |
| `test-ep-emulate-delay`              | `test-ep`          | HIP runtime |
| `test-ep-cli-emulate*`               | `test-ep cli`      | `xio-tester` |

Run them with:

```bash
ctest --test-dir build -L test-ep --output-on-failure
```

<!-- References -->

[doc-test-ep]: ../../../docs/conceptual/test-ep.rst
