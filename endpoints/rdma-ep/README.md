# RDMA Endpoint

GPU-Direct RDMA endpoint supporting 4 major vendors.

## Supported Vendors

1. **MLX5** - Mellanox/NVIDIA ConnectX (InfiniBand/RoCE)
2. **BNXT_RE** - Broadcom NetXtreme RDMA Engine
3. **IONIC** - Pensando Ionic RDMA (SmartNIC)
4. **PVRDMA** - VMware Paravirtualized RDMA

## Directory Structure

```
rdma-ep/
├── rdma-ep.h           # Core RDMA structures (WQE, CQE, QP)
├── rdma-ep.hip         # Implementation and emulation
├── mlx/
│   └── mlx5-rdma.h     # MLX5 doorbell + vendor specifics
├── bnxt/
│   └── bnxt-rdma.h     # BNXT_RE doorbell + vendor specifics
├── ionic/
│   └── ionic-rdma.h    # IONIC doorbell + vendor specifics
├── pvrdma/
│   └── pvrdma-rdma.h   # PVRDMA doorbell + vendor specifics
└── README.md           # This file
```

## Quick Start

### Emulation Mode (No Hardware Required)

```bash
cd ../../tester
make rdma-ep-tester
./rdma-ep-tester
```

### Hardware Mode (Requires RDMA NIC)

```bash
./rdma-ep-tester --hardware
```

## Key Features

- **rocSHMEM GDA Pattern**: Direct GPU doorbell writes using system-scope atomics
- **Vendor Abstraction**: Unified API across 4 different RDMA vendors
- **Emulation Support**: Test without physical RDMA hardware
- **GPU-Direct I/O**: Zero-copy, zero-CPU-overhead RDMA operations

## Doorbell Ringing

All vendors support GPU-direct doorbell ringing:

```cpp
// Example: MLX5
__device__ void ring_mlx5_doorbell(volatile uint64_t* db, uint64_t val) {
  __hip_atomic_store(db, val, __ATOMIC_SEQ_CST, __HIP_MEMORY_SCOPE_SYSTEM);
  __threadfence_system();
}
```

No HSA memory locking needed! (Unlike NVMe, RDMA NICs support this pattern natively)

## Documentation

See [`docs/RDMA_ENDPOINT_ARCHITECTURE.md`](../../docs/RDMA_ENDPOINT_ARCHITECTURE.md) for complete architecture documentation.

## Reference Materials

External references (not committed to repo):
- `../../reference/rocshmem-gda/` - rocSHMEM source code
- `../../reference/rdma-headers/` - RDMA vendor headers

Download with:
```bash
make fetch-rdma-reference  # Downloads rocSHMEM + rdma-core headers
```

## Testing

```bash
# Run all vendor tests
./rdma-ep-tester

# Test specific vendor (in code)
test_rdma_vendor(RDMAVendor::MLX5, "MLX5", use_emulation);
```

## License

MIT License

