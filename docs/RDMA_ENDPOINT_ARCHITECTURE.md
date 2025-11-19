# RDMA Endpoint Architecture

## Overview

The ROCm-AXIIO RDMA endpoint provides GPU-direct RDMA operations for four major vendor implementations:

1. **MLX5** - Mellanox/NVIDIA ConnectX series
2. **BNXT_RE** - Broadcom NetXtreme RDMA Engine
3. **IONIC** - Pensando Ionic RDMA
4. **PVRDMA** - VMware Paravirtualized RDMA

## Key Design Principles

### 1. Unified Doorbell Abstraction

Despite vendor-specific differences in WQE (Work Queue Entry) and CQE (Completion Queue Entry) formats, all vendors use **doorbells** as the fundamental signaling mechanism. This common pattern allows us to implement GPU-direct I/O using a unified approach.

### 2. rocSHMEM GDA Pattern

Our implementation is based on the proven approach from AMD's rocSHMEM GDA (GPU Direct Acceleration) project:

**Key Insight**: Doorbell pointers obtained from `mmap()` can be used **directly** from GPU kernels with system-scope atomics!

```cpp
// From GPU kernel - works for all vendors
__hip_atomic_store(doorbell_ptr, db_val, 
                   __ATOMIC_SEQ_CST, 
                   __HIP_MEMORY_SCOPE_SYSTEM);
```

No HSA memory locking required for NIC doorbells (unlike NVMe).

### 3. Why This Works

- **Unified Virtual Address Space**: AMD GPUs with Large BAR share the same virtual address space as the CPU
- **System-Scope Atomics**: `__HIP_MEMORY_SCOPE_SYSTEM` forces the GPU to route writes through the PCIe interconnect
- **PCIe Peer-to-Peer**: The GPU can write to other PCIe devices' MMIO space directly
- **PCIe Atomics**: AMD GPU compute requires PCIe atomics, which we verify at startup

## Vendor-Specific Implementations

### MLX5 (Mellanox/NVIDIA)

**Doorbell Mechanism**: BlueFlame (BF) registers

```cpp
__device__ void mlx5_ring_doorbell_gpu(
  volatile uint64_t* doorbell_ptr,  // BF register from mmap
  uint64_t db_val,                   // WQE control segment
  uint32_t sq_counter)               // Send Queue counter
```

**Characteristics**:
- 64-bit doorbell writes
- BlueFlame register provides write-combining for efficiency
- doorbell_ptr comes from `mlx5dv_qp.bf.reg`
- Widely used in HPC/AI workloads

**Reference**: `reference/rocshmem-gda/queue_pair_mlx5.cpp`

### BNXT_RE (Broadcom)

**Doorbell Mechanism**: Structured doorbell with queue type encoding

```cpp
__device__ void bnxt_ring_doorbell_gpu(
  volatile uint64_t* doorbell_ptr,
  uint32_t queue_id,      // Queue identifier (20 bits)
  uint32_t queue_type,    // SQ/RQ/CQ type
  uint32_t index)         // Queue tail (24 bits)
```

**Doorbell Format**:
```
Bits [31:0]:  Queue index/tail
Bits [51:32]: Queue ID
Bits [59:56]: Queue type (SQ=0x00, RQ=0x01, CQ=0x04)
```

**Characteristics**:
- Explicit queue type in doorbell
- Supports multiple queue types (Send/Recv/Completion)
- Common in enterprise Ethernet NICs

**Reference**: `reference/rdma-headers/bnxt_re-abi.h`

### IONIC (Pensando)

**Doorbell Mechanism**: Simplified doorbell format

```cpp
__device__ void ionic_ring_doorbell_gpu(
  volatile uint32_t* doorbell_ptr,
  uint32_t qp_id,         // Queue Pair ID (16 bits)
  uint32_t wqe_index)     // WQE index (16 bits)
```

**Doorbell Format**:
```
Bits [15:0]:  WQE index
Bits [31:16]: QP ID
```

**Characteristics**:
- 32-bit doorbell (simpler than MLX5/BNXT)
- Pensando DPU-specific implementation
- Optimized for SmartNIC architectures

**Reference**: `reference/rdma-headers/ionic-abi.h`

### PVRDMA (VMware)

**Doorbell Mechanism**: UAR (User Access Region) with send/recv bits

```cpp
__device__ void pvrdma_ring_doorbell_gpu(
  volatile uint32_t* uar_base,
  uint32_t qp_handle,     // QP handle (24 bits)
  bool is_send)           // Send vs Receive queue
```

**Doorbell Format**:
```
Bits [23:0]:  QP handle
Bit  30:      Send bit (1 = Send Queue)
Bit  31:      Recv bit (1 = Receive Queue)
```

**Characteristics**:
- Paravirtualized RDMA for virtual machines
- UAR-based doorbell (offset 0 for QP, offset 4 for CQ)
- Optimized for VMware virtualization

**Reference**: `reference/rdma-headers/vmw_pvrdma-abi.h`

## RDMA Terminology

RDMA uses different terminology than NVMe/storage:

| Concept | RDMA Term | NVMe Equivalent |
|---------|-----------|-----------------|
| Work request | **WQE** (Work Queue Entry) | SQE (Submission Queue Entry) |
| Queue structure | **QP** (Queue Pair = SQ + RQ) | SQ (Submission Queue) |
| Send operations | **SQ** (Send Queue) | SQ (Submission Queue) |
| Receive operations | **RQ** (Receive Queue) | N/A (NVMe is one-sided) |
| Completion | **CQE** (Completion Queue Entry) | CQE (Completion Queue Entry) |
| Doorbell | **Doorbell** ✓ | **Doorbell** ✓ |

**Key Difference**: RDMA has bidirectional communication (send + receive), while NVMe is one-sided (commands + completions).

## Testing & Emulation

### Emulation Mode

The RDMA endpoint includes a full emulation harness for testing without physical RDMA hardware:

```bash
# Run in emulation mode (default)
./rdma-ep-tester

# Run with actual RDMA hardware
./rdma-ep-tester --hardware
```

**Emulator Features**:
- GPU-based WQE processing (mimics NIC behavior)
- CQE generation with realistic latencies
- Supports all 4 vendors
- Useful for development and CI/CD

### How Emulation Works

1. **Emulator Kernel**: One GPU thread acts as the "NIC", polling for new WQEs
2. **Driver Kernel**: Another GPU thread posts WQEs and polls for CQEs
3. **Communication**: Through shared GPU memory (no actual PCIe transactions)

This allows testing of:
- WQE/CQE format correctness
- Vendor-specific logic
- Queue management
- Operation semantics

## HSA Memory Locking - When Is It Needed?

Based on our NVMe experience, HSA memory locking (`hsa_amd_memory_lock()`) may be needed for:

❌ **NOT needed for RDMA NICs**:
- InfiniBand/RoCE NICs (MLX5, BNXT_RE, IONIC, PVRDMA)
- NIC doorbells work with direct `mmap()` pointer (proven by rocSHMEM)
- System-scope atomics are sufficient

✅ **May be needed for NVMe**:
- NVMe controller doorbells sometimes require HSA registration
- Depends on NVMe controller firmware/implementation
- We use HSA locking in `nvme-ep` for maximum compatibility

**Rule of Thumb**: Use rocSHMEM GDA pattern first (direct mmap pointer). Only add HSA locking if you encounter GPU page faults.

## Performance Characteristics

### Expected Latencies

| Vendor | Typical Doorbell Latency | PCIe Generation | Notes |
|--------|--------------------------|-----------------|-------|
| MLX5 | 200-400 ns | PCIe 4.0/5.0 | BlueFlame optimization |
| BNXT_RE | 300-500 ns | PCIe 3.0/4.0 | Enterprise Ethernet |
| IONIC | 250-450 ns | PCIe 4.0 | SmartNIC architecture |
| PVRDMA | 500-800 ns | PCIe 3.0 | Virtualization overhead |

### Emulation vs Hardware

| Metric | Emulation | Hardware |
|--------|-----------|----------|
| Latency | 40-100 GPU cycles | 200-800 ns |
| Throughput | GPU memory bandwidth | PCIe bandwidth |
| Realism | Functional correctness | Production behavior |

## Building

```bash
cd tester
hipcc rdma-ep-tester.hip -o rdma-ep-tester \
    -I../include \
    -I../endpoints \
    -I../common \
    --offload-arch=gfx1201  # Adjust for your GPU
```

## Requirements

- **GPU**: AMD GPU with PCIe atomics support
- **ROCm**: 5.x or later
- **Hardware** (optional): Any of the 4 supported RDMA NICs
- **Drivers**: ibverbs, rdma-core (for hardware mode)

## Future Work

1. **Multi-QP Support**: Currently single QP, expand to multiple queue pairs
2. **Completion Polling**: Add interrupt-based completion notification
3. **RDMA Read/Write**: Implement full RDMA operation set
4. **Memory Registration**: Integrate with ibverbs for real memory regions
5. **Additional Vendors**: EFA (AWS), cxi (HPE Slingshot), hfi1 (Intel OPA)

## References

### Code References
- `endpoints/rdma-ep/rdma-ep.h` - Core RDMA structures
- `endpoints/rdma-ep/mlx/mlx5-rdma.h` - MLX5 doorbell implementation
- `endpoints/rdma-ep/bnxt/bnxt-rdma.h` - BNXT_RE implementation
- `endpoints/rdma-ep/ionic/ionic-rdma.h` - IONIC implementation
- `endpoints/rdma-ep/pvrdma/pvrdma-rdma.h` - PVRDMA implementation
- `tester/rdma-ep-tester.hip` - Testing harness with emulation

### External References
- **rocSHMEM GDA**: `reference/rocshmem-gda/queue_pair_mlx5.cpp`
- **RDMA Headers**: `reference/rdma-headers/*.h`
- **rdma-core**: https://github.com/linux-rdma/rdma-core
- **rocSHMEM**: https://github.com/ROCm/rocSHMEM

## License

MIT License - See LICENSE file for details

