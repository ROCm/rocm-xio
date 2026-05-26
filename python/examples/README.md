# ROCm-XIO Python Examples

This directory contains Python examples demonstrating the rocm-xio SDMA endpoint Python bindings.

## Requirements

- AMD Instinct GPUs (MI300X, MI250X, etc.) with XGMI/Infinity Fabric
- ROCm 6.0+
- PyTorch nightly (for symmetric memory support)
- rocm-xio Python bindings installed

## Installation

### 1. Build and install rocm-xio

```bash
cd /path/to/rocm-xio
mkdir build && cd build
cmake -DXIO_BUILD_PYTHON=ON ..
make
sudo make install
```

### 2. Install PyTorch nightly (for symmetric memory)

```bash
pip install --pre torch --index-url https://download.pytorch.org/whl/nightly/rocm6.2
```

## Examples

### sdma_p2p_symmetric.py

**Host-initiated** GPU-to-GPU P2P data transfer using PyTorch symmetric memory and SDMA.

### sdma_p2p_device_triggered.py

**Device-triggered** GPU-to-GPU P2P data transfer where GPU kernels drive the communication.

**What it demonstrates:**
- Allocating PyTorch tensors with symmetric memory (accessible from all GPUs)
- Using host-initiated SDMA transfers from Python
- Host-side synchronization via `sdma.quiet()` (blocks until transfer completes)
- Integration of PyTorch distributed with rocm-xio

**Usage:**

```bash
# Basic usage (2 GPUs)
torchrun --nproc-per-node=2 sdma_p2p_symmetric.py

# With data verification
torchrun --nproc-per-node=2 sdma_p2p_symmetric.py --verify

# Custom transfer size
torchrun --nproc-per-node=2 sdma_p2p_symmetric.py --size 16384
```

**Options:**
- `--size N`: Transfer size in bytes (default: 4096)
- `--verify`: Verify data after transfer

---

### sdma_p2p_device_triggered.py (Device-Triggered)

**What it demonstrates:**
- GPU kernels trigger and control SDMA transfers via flags
- Device-initiated SDMA pattern (lower latency than host-initiated)
- Triton kernel integration with rocm-xio
- GPU-side polling and data processing

**Usage:**

```bash
# Basic usage (2 GPUs)
torchrun --nproc-per-node=2 sdma_p2p_device_triggered.py

# With data verification
torchrun --nproc-per-node=2 sdma_p2p_device_triggered.py --verify

# Custom transfer size
torchrun --nproc-per-node=2 sdma_p2p_device_triggered.py --size 16384
```

**Options:**
- `--size N`: Transfer size in bytes (default: 4096)
- `--verify`: Verify data after transfer

**Example output:**

```
GPU 0: AMD Instinct MI300X
GPU 1: AMD Instinct MI300X
Transfer size: 4096 bytes
Verify: True

[Rank 0] Data tensor at: 0x7f8b40000000
[Rank 0] Peer data tensor (rank 1) at: 0x7f8b50000000
[Rank 0] Trigger flag at: 0x7f8b40002000

[Rank 0] Setting up SDMA wait_flag_then_put...
[Rank 0] Launching GPU 0 kernel (fill=42.0)...
[Rank 0] SDMA transfer complete
[Rank 1] Launching GPU 1 kernel (add +1)...
[Rank 1] Kernel complete
[Rank 1] Data verification: PASS

SUCCESS: Device-triggered SDMA P2P transfer completed!
```

---

## Host-Initiated Example Output

**Example output:**

```
GPU 0: AMD Instinct MI300X
GPU 1: AMD Instinct MI300X
Transfer size: 4096 bytes
Verify: True

[Rank 0] Data tensor at: 0x7f8b40000000
[Rank 0] Peer data tensor (rank 1) at: 0x7f8b50000000

[Rank 0] Initiating SDMA transfer to Rank 1...
[Rank 0] Transfer complete
[Rank 1] Data verification: PASS

SUCCESS: PyTorch symmetric memory + SDMA P2P transfer completed!
```

## Comparison of Examples

### Host-Initiated (`sdma_p2p_symmetric.py`)
- Simpler implementation (no GPU kernels needed)
- Host calls `sdma.put()` and `sdma.quiet()` to control transfers
- Host blocks in `quiet()` until transfer completes
- Good for prototyping and simple use cases
- Higher latency (CPU involvement)

### Device-Triggered (`sdma_p2p_device_triggered.py`)
- GPU kernels trigger SDMA via flags (`wait_flag_then_put`)
- Lower latency (GPU directly controls timing)
- Triton kernels for GPU-side logic
- GPU 1 polls for completion and processes data in-kernel
- Better demonstrates device-initiated SDMA patterns
- More complex but closer to production performance

### C++ HIP Examples (`examples/sdma-ep-p2p/`)
- Fully device-initiated (GPU kernels call SDMA device functions)
- Lowest latency (no host involvement after setup)
- Requires HIP kernel development
- Best for production performance-critical code

## Troubleshooting

**Error: `xio.sdma_ep module not found`**

Ensure rocm-xio Python bindings are installed:
```bash
cd /path/to/rocm-xio/build
sudo make install
```

**Error: `Must be run with torchrun`**

The example requires PyTorch distributed initialization. Always launch with:
```bash
torchrun --nproc-per-node=N script.py
```

**Error: `Need at least 2 GPUs`**

The P2P example requires at least 2 AMD GPUs with XGMI connectivity. Check GPU visibility:
```bash
rocm-smi --showbus
```

**Data mismatch**

If data verification fails:
1. Check XGMI connectivity with `rocm-smi --showtopo`
2. Verify peer access is enabled (symmetric memory handles this automatically)
3. Try adding `torch.cuda.synchronize()` before the SDMA transfer

## Further Reading

- [PyTorch Symmetric Memory Documentation](https://pytorch.org/docs/main/distributed.html#torch.distributed._symmetric_memory)
- [ROCm-XIO Documentation](../../docs/)
- [SDMA Endpoint API Reference](../../docs/reference/api.rst)
