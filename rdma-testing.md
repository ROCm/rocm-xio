# rocSHMEM GDA Integration into rdma-ep

Branch: `dev/thohuber/rocshmem-gda-rdma-ep-integration`

## Summary

This branch replaces the emulation-only RDMA endpoint in rocm-xio with a real
GPU-initiated RDMA implementation derived from ROCm/rocSHMEM's GDA (GPU-Direct
Access) backend. GPU kernels construct WQEs directly in NIC send queues and ring
hardware doorbells with zero CPU involvement in the data path.

Three vendor backends are ported (BNXT, MLX5, IONIC). BNXT (Broadcom Thor 2) is
fully validated on hardware including a 2-node cross-subnet RDMA test.

41 files changed, 8,239 insertions, 2,736 deletions.

## Architecture

```
src/common/                  Shared RDMA infrastructure (namespace rdma_ep)
  ibv-wrapper.hpp/cpp          libibverbs dynamic loading via dlopen
  ibv-core.hpp                 IB verbs type definitions
  rdma-topology.hpp/cpp        NIC-GPU proximity detection
  rdma-numa-wrapper.hpp/cpp    NUMA API wrappers
  endian.hpp                   Big/little-endian conversion for WQEs

src/endpoints/rdma-ep/       RDMA endpoint (namespace rdma_ep)
  vendor-ops.hpp               SpinLock, RmaDescriptor, AmoDescriptor, Provider enum
  gda-backend.hpp/cpp          Backend: IB device setup, QP/CQ creation, state machine
  queue-pair.hpp/hip           QueuePair: GPU-side RDMA ops, compile-time vendor dispatch
  rdma-ep.h/hip                Public API, CLI options, endpoint run function

  bnxt/                        Broadcom Thor 2 (namespace rdma_ep::bnxt::Ops)
    bnxt-provider.hpp            Device structures, DV function table
    bnxt-backend.cpp             dmabuf-based CQ/QP creation, GPU QP init
    bnxt-queue-pair.hip          WQE construction, doorbell, CQ polling, quiet
    bnxt-re-hsi.h, bnxt-re-dv.h Broadcom vendor headers

  mlx5/                        Mellanox ConnectX (namespace rdma_ep::mlx5::Ops)
    mlx5-provider.hpp            BlueFlame WQE structures, doorbell types
    mlx5-queue-pair.hip          Big-endian WQEs, alternating CQ, BlueFlame doorbell
    mlx5dv.h                     Mellanox DV header

  ionic/                       Pensando (namespace rdma_ep::ionic::Ops)
    ionic-provider.hpp           DV function table
    ionic-queue-pair.hip         Reserve/commit SQ, color-bit CQEs, CCQE mode
    ionic-dv.h, ionic-fw.h      Pensando vendor headers
```

### Vendor Namespace Pattern

Each vendor provides the same function names as static methods on an `Ops` class:

```cpp
rdma_ep::bnxt::Ops::post_wqe_rma(QueuePair &qp, ...)
rdma_ep::mlx5::Ops::post_wqe_rma(QueuePair &qp, ...)
rdma_ep::ionic::Ops::post_wqe_rma(QueuePair &qp, ...)
```

QueuePair dispatches at compile time via `#if defined(GDA_BNXT)`.

### Single-Endpoint Model

rocSHMEM creates `(max_contexts + 1) * num_pes` QPs (full SHMEM mesh).
rocm-xio creates 1 QP + 1 CQ per endpoint connection. No MPI dependency.

## Prerequisites

- ROCm 7.0+ with HIP SDK
- AMD MI300X GPU (or compatible)
- Broadcom Thor 2 NIC (for hardware tests)
- `libcli11-dev`, `cmake >= 3.21`, `libdrm-dev`, `libhsa-runtime-dev`

## Build

```bash
git clone git@github.com:ROCm/rocm-xio.git
cd rocm-xio
git checkout dev/thohuber/rocshmem-gda-rdma-ep-integration

cmake -B build -S . -DGDA_BNXT=ON -DBNXT_DV_BUILD_KMOD=ON -DBUILD_TESTING=ON
cmake --build build --target all --parallel
```

sudo LD_LIBRARY_PATH=$(pwd)/build/_deps/bnxt-dv/rdma-core-install/lib \
  ./build/tests/unit/rdma-ep/test-rdma-bnxt-loopback

To enable all three RDMA vendors (MLX5 and IONIC compile but are untested):

```bash
cmake -DGDA_BNXT=ON -DGDA_MLX5=ON -DGDA_IONIC=ON -DBUILD_TESTING=ON ..
```

## Tests

### 1. Unit tests (no hardware required)

```bash
ctest --output-on-failure
```

| Test | What it validates |
|------|-------------------|
| `test-rdma-config` | `RdmaEpConfig` validation, `Provider` enum, name resolution |
| `test-rdma-vendors` | Vendor ID constants, `RmaDescriptor`/`AmoDescriptor` layout |
| `test-rdma-endian` | `byteswap`, `to_be`/`from_be` on host + GPU kernel |

### 2. Single-node loopback RDMA WRITE (requires Thor 2 NIC)

```bash
ctest -R test-rdma-bnxt-loopback --output-on-failure
```

Creates a loopback QP on the local Thor 2, GPU posts an RDMA WRITE (256 bytes),
verifies CQE completion and data correctness. Exercises the full device code path:

```
put_nbi_single → bnxt::Ops::write_rma_wqe → bnxt::Ops::ring_doorbell
  → NIC DMA → bnxt::Ops::quiet_single → host verifies data
```

### 3. Single-node smoke test via xio-tester (requires Thor 2 NIC)

```bash
./xio-tester rdma-ep --loopback --provider bnxt -n 1
```

Validates the full host-side backend: libbnxt_re dlopen, dmabuf CQ/QP creation,
QP state transitions (RESET → INIT → RTR → RTS), doorbell register mapping,
GPU QueuePair initialization.

### 4. Two-node RDMA test (requires 2 nodes with Thor 2 NICs)

From any node with SSH access to both:

```bash
bash tests/unit/rdma-ep/run-2node-test.sh <server-node> <client-node>
```

Example:

```bash
bash tests/unit/rdma-ep/run-2node-test.sh \
  dell300x-ccs-aus-k13-03.cs-aus.dcgpu \
  dell300x-ccs-aus-k13-41.cs-aus.dcgpu
```

Or manually on each node:

```bash
# Node A (server):
./tests/unit/rdma-ep/test-rdma-2node --server --gid-index 3

# Node B (client):
./tests/unit/rdma-ep/test-rdma-2node \
  --client --server-host <server-hostname> --gid-index 3
```

This runs two tests:

| Test | Description |
|------|-------------|
| RDMA WRITE correctness | Client GPU writes 4096 bytes (0xA5 pattern) to server, server verifies all bytes |
| Ping-pong latency | 100 GPU-initiated RDMA round-trips, reports us/iter |

Expected output:

```
--- Test 1: RDMA WRITE Correctness ---
[CLIENT] RDMA WRITE 4096 bytes to server...
[SERVER] PASSED: All 4096 bytes received correctly.
[CLIENT] RDMA WRITE complete.

--- Test 2: Ping-Pong Latency (100 iters) ---
[SERVER] Ping-pong complete.
[CLIENT] 100 round-trips in 16659.6 us = 166.60 us/iter

=== 2-Node RDMA Test [SERVER] PASSED ===
=== 2-Node RDMA Test [CLIENT] PASSED ===
```

## Validation Summary

| What | Test | Hardware | Lines exercised |
|------|------|----------|-----------------|
| Config, structures, endian | `ctest` (3 unit tests) | None | ~300 |
| Host-side backend | `xio-tester rdma-ep --loopback` | Thor 2 | ~1,500 |
| GPU device code (loopback) | `test-rdma-bnxt-loopback` | Thor 2 + MI300X | ~370 |
| Cross-node RDMA + latency | `test-rdma-2node` | 2× Thor 2 + MI300X | ~530 |

## Notes

- **GID index 3** is required for cross-subnet Thor 2 routing (RoCEv2 IPv4-mapped).
- The 2-node test uses TCP over the management network (eno8303) for QP info exchange,
  RDMA over the Thor 2 NIC fabric for data transfer.
- The BNXT device name may differ between nodes (`bnxt_re0` vs `rocep28s0`). The test
  auto-detects the closest NIC to the GPU.
- All code derived from rocSHMEM is annotated with
  `// Derived from ROCm/rocSHMEM src/gda/..., adapted for rocm-xio`.

## Relationship to ROCm/rocSHMEM

The GDA code is derived from `ROCm/rocSHMEM/src/gda/`. Key adaptations:

- Decoupled from rocshmem internals (`HIPAllocator`, `FreeList`, MPI, `constants.hpp`)
- Simplified from full PE mesh to single-endpoint model
- Wrapped in `rdma_ep` namespace with vendor sub-namespaces
- Consolidated ~30-40% duplicated vendor control flow into shared abstractions
