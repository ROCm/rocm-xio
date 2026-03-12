# RDMA Endpoint -- GPU-Direct Access (GDA)

GPU-Direct RDMA endpoint supporting 3 major vendors, derived from
ROCm/rocSHMEM's GDA backend and adapted for rocm-xio's endpoint model.

## Supported Vendors

1. **BNXT** (Broadcom Thor 2) -- **primary**, testable locally
2. **MLX5** (Mellanox/NVIDIA ConnectX)
3. **IONIC** (Pensando)

## Architecture

The rdma-ep endpoint uses real InfiniBand verbs to create QPs and CQs, then
GPU code posts WQEs directly to hardware via doorbell registers. This is the
"GPU-initiated communication" (GIN/GDA) pattern.

### Single-Endpoint Model

Unlike rocSHMEM which creates a full-mesh of `(max_contexts + 1) * num_pes`
QPs, rocm-xio uses a simple endpoint model: **1 QP + 1 CQ pair** per
endpoint connection. This simplification removes the MPI dependency,
multi-PE routing, and context multiplexing.

### Vendor Abstraction Layer

The three vendor backends share ~30-40% duplicated control flow (locking,
CQ polling, post-WQE skeleton, quiet/drain). `vendor-ops.hpp` provides
shared abstractions:

- `rdma_ep::SpinLock` -- unified GPU spinlock
- `rdma_ep::RmaDescriptor` / `AmoDescriptor` -- logical descriptors
- `rdma_ep::Provider` enum and name resolution
- Wave/lane helpers (`get_active_lane_mask`, `is_thread_zero_in_wave`)

## Directory Structure

```
rdma-ep/
├── rdma-ep.h               # Public API: RdmaEpConfig, Provider enum
├── rdma-ep.hip             # Endpoint implementation and kernel launch
├── vendor-ops.hpp          # Vendor abstraction layer (shared across vendors)
├── gda-backend.hpp         # GDA backend: IB device, QP/CQ setup
├── gda-backend.cpp         # Backend implementation (single-endpoint model)
├── queue-pair.hpp          # QueuePair class (GPU-side RDMA operations)
├── queue-pair.hip          # QueuePair device code implementation
├── bnxt/                   # BNXT vendor (Phase 5 -- in progress)
├── mlx5/                   # MLX5 vendor (Phase 6 -- pending)
├── ionic/                  # IONIC vendor (Phase 6 -- pending)
└── README.md               # This file
```

### Shared Infrastructure in `src/common/`

The following files provide vendor-agnostic RDMA infrastructure used by
rdma-ep but potentially reusable by other endpoints:

| File | Purpose | Origin |
|------|---------|--------|
| `endian.hpp` | Big/little-endian conversion for WQEs | rocSHMEM `gda/endian.hpp` |
| `ibv-core.hpp` | InfiniBand verbs type definitions | rocSHMEM `gda/ibv_core.hpp` |
| `ibv-wrapper.hpp/cpp` | libibverbs dynamic loading wrapper | rocSHMEM `gda/ibv_wrapper.hpp/cpp` |
| `rdma-topology.hpp/cpp` | NIC-GPU proximity detection | rocSHMEM `gda/topology.hpp/cpp` |
| `rdma-numa-wrapper.hpp/cpp` | NUMA API wrappers | rocSHMEM `gda/numa_wrapper.hpp/cpp` |

All shared code is in the `rdma_ep` namespace.

## Quick Start

### Build with BNXT support (default)

```bash
mkdir -p build && cd build
cmake -DGDA_BNXT=ON ..
cmake --build . --target all
```

### Build with specific vendors

```bash
cmake -DGDA_BNXT=ON -DGDA_MLX5=ON -DGDA_IONIC=OFF ..
```

### Run with loopback (no remote peer needed)

```bash
./xio-tester rdma-ep --provider bnxt --loopback -n 128
```

### Run with specific options

```bash
./xio-tester rdma-ep \
  --provider bnxt \
  --loopback \
  --sq-depth 512 \
  --transfer-size 4096 \
  --gpu-device 0 \
  -n 1000
```

## Relationship to ROCm/rocSHMEM

This code is derived from the GDA (GPU-Direct Access) backend in
[ROCm/rocSHMEM](https://github.com/ROCm/rocSHMEM). Key adaptations:

- **Decoupled** from rocshmem internals (`HIPAllocator`, `FreeList`,
  `constants.hpp`, `util.hpp`) -- uses standard HIP/C++
- **Simplified** from full-mesh PE topology to single-endpoint model
- **Namespace**: all code in `rdma_ep` (not `rocshmem`)
- **No MPI**: connection info via CLI options or loopback mode
- **Vendor abstraction**: consolidated duplicated control flow across vendors

## Testing

The system has Broadcom Thor 2 NICs (`bnxt_re0`, BCM57608) available for
local testing. The loopback mode creates a QP connected to itself, enabling
basic validation of the IB verbs path without a remote peer.

## License

MIT License
