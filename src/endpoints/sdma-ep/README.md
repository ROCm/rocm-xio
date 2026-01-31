# SDMA Endpoint

## Overview

The SDMA (System DMA) endpoint enables GPU-initiated DMA transfers using
AMD's hardware SDMA engines. SDMA engines are specialized DMA controllers
on AMD GPUs that can perform memory-to-memory transfers, including
peer-to-peer (P2P) GPU transfers, without CPU intervention.

## Hardware Requirements

- **AMD MI300X** or similar datacenter GPU with SDMA hardware support
- **ROCm 6.0+** with hsakmt library support
- **P2P mode**: Multi-GPU system and XGMI/Infinity Fabric for GPU-to-GPU
- **Single-GPU mode** (`--to-host`): One GPU; destination is pinned host memory

## Implementation

The sdma-ep implementation is based on the **anvil library** from AMD's RAD
team (commit 6df07028). The anvil library provides low-level hardware queue
management for SDMA engines via the hsakmt (HSA Kernel Mode Driver Thunk)
interface.

### Components

- **sdma-ep.hip**: XIO endpoint interface implementation (uses anvil);
  nominal SQE/CQE sizes for the registry are defined in xio-endpoint.hip
- **anvil.hpp / anvil.hip**: Host-side SDMA queue management and
  initialization
- **anvil_device.hpp**: Device-side SDMA queue primitives for GPU kernels
- **sdma_pkt_struct.h**: AMD SDMA packet structures and opcodes (source of
  truth for hardware packet layout)

### SDMA Operations

The anvil library provides device-side functions for SDMA operations:

- `anvil::put(handle, dst, src, size)` - DMA copy operation
- `anvil::signal(handle, signal_addr)` - Atomic signal increment
- `anvil::putWithSignal(handle, dst, src, size, signal)` - Copy with
completion signal

## Usage

### Initialization

```cpp
// Initialize anvil library (once per process)
anvil::AnvilLib::getInstance().init();

// Connect two GPUs for SDMA transfers
bool success = anvil::AnvilLib::getInstance().connect(
    srcDeviceId,
    dstDeviceId,
    numChannels  // Number of SDMA channels to allocate
);
```

### Device-Side SDMA Operations

```cpp
__global__ void myKernel(anvil::SdmaQueueDeviceHandle* handle) {
    void* src = ...;
    void* dst = ...;
    size_t size = 4096;

    // Perform DMA transfer using SDMA engine
    anvil::put(*handle, dst, src, size);

    // Or with completion signaling
    uint64_t* signal_addr = ...;
    anvil::putWithSignal(*handle, dst, src, size, signal_addr);
}
```

## Limitations

- **Hardware-only**: Emulation mode is not supported. SDMA operations
require real AMD GPU hardware with SDMA engines.
- **P2P mode**: Requires at least two GPUs. Use `--to-host` for single-GPU
testing (destination is pinned host memory).
- **Privileged operations**: Requires hsakmt library which interfaces with
the kernel driver (KFD).

## Testing

SDMA endpoint testing requires real hardware.

**Transfer size:** Default is 4KB per iteration. Use `-s` / `--transfer-size`
for larger moves. The value is in bytes; you can use a number or a suffix:
`4k`, `1M`, `2G`. Suffixes are **power-of-2** (binary): k = 1024, M = 1024²,
G = 1024³ (i.e. KiB, MiB, GiB), not SI (power-of-10). Value must be a multiple of 4.

**Single-GPU (no P2P):** Use `--to-host` so the destination is pinned host
memory. Only one GPU is required:

```bash
# Single GPU: SDMA from device to pinned host memory
sudo ./build/xio-tester sdma-ep --to-host -n 10 -v

# With data validation (LFSR pattern; seed advances per iteration)
sudo ./build/xio-tester sdma-ep --to-host --verify -n 10 -v

# Larger transfer: 1MB per iteration
sudo ./build/xio-tester sdma-ep --to-host -n 8 -s 1048576 --verify
```

**P2P (two GPUs):** Default mode copies from GPU 0 to GPU 1. Use `--src-gpu`
and `--dst-gpu` to choose HIP device IDs. Use `--verify` to validate the
destination buffer after transfer:

```bash
# Two GPUs: P2P transfer (default GPU 0 -> GPU 1)
sudo ./build/xio-tester sdma-ep -n 100 -t 1 -v

# With verification
sudo ./build/xio-tester sdma-ep --verify -n 100 -v

# Specify source and destination GPUs
sudo ./build/xio-tester sdma-ep --src-gpu 0 --dst-gpu 1 -n 100 -v

# P2P with 1MB per iteration
sudo ./build/xio-tester sdma-ep --src-gpu 0 --dst-gpu 1 -n 8 -s 1048576 --verify
```

The reference **shader_sdma** bench (RAD) sweeps transfer sizes from 1KB to
1GB (`--minCopySize` / `--maxCopySize`, doubling each step). sdma-ep uses a
single transfer size per run; use `-s` to test specific sizes (e.g. 4K
default, 1M, 64M).

Note: The CI workflow does not test sdma-ep as it requires specific hardware
and cannot run in emulation mode.

### SDMA modes tested and possible extensions

The tester fills the source buffer with a 32-bit LFSR pattern; the seed
advances per iteration so each transfer chunk is a distinct, verifiable
segment. With `--verify`, the destination is checked against this LFSR
sequence. Copy linear (device/host to device/host) is exercised with
optional completion signaling. Other SDMA operations supported by the packet
definitions and anvil device helpers could be added as test modes:

- **Copy linear** (current): `put` / `putWithSignal` (COPY_LINEAR).
- **Const fill**: Fill a buffer with a constant (SDMA_OP_CONST_FILL).
- **Fence**: Ordering between operations (SDMA_OP_FENCE); anvil has
  `CreateFencePacket`.
- **Signal-only**: Atomic increment on a completion counter (SDMA_OP_ATOMIC);
  used today with putWithSignal.
- **Write linear**: Write from embedded packet data (SDMA_OP_WRITE_LINEAR).

### Confirming XGMI traffic with counters

On P2P runs you can try to confirm data movement over XGMI by reading
**XGMI read/write counters** before and after the test.

**1. AMD SMI**

If [AMD SMI](https://rocm.docs.amd.com/projects/amdsmi/en/latest/) is
installed (e.g. with ROCm):

```bash
# XGMI metrics for all GPUs (read/write data per link)
amd-smi xgmi -m -g all
```

Sample once before and once after; the **delta** (after − before) is the
traffic in that interval. The XGMI traffic counters are **not resettable**
(only XGMI *error* counts: `sudo amd-smi reset --xgmierr -g all`). If
display is in **TB**, use a large run (e.g. `-n 1000 -s 100M` = 100 GB) to
see a visible delta, or try `--json` / `--csv` for higher precision.

**If the counter does not increment:** On some systems and driver versions,
the XGMI read/write values reported by amd-smi may **not** include SDMA P2P
traffic (they can be tied to other engines or paths). So a non-incrementing
counter does not prove that data is not moving over XGMI. In that case rely
on: (1) **LFSR verification** (`--verify`) — confirms the correct data
reached the destination; (2) **P2P topology** — `hipDeviceCanAccessPeer` and
anvil’s use of the SDMA→XGMI path; (3) **timing** — sub-millisecond averages
for large transfers are consistent with XGMI bandwidth, not host bounce.

**2. ROCm Systems Profiler (time series)**

For a trace over time (e.g. to correlate with your run), use [ROCm Systems
Profiler](https://rocm.docs.amd.com/projects/rocprofiler-systems/) with AMD
SMI metrics:

```bash
export ROCPROFSYS_USE_AMD_SMI=true
export ROCPROFSYS_AMD_SMI_METRICS=busy,temp,power,mem_usage,xgmi,pcie
rocprof-sys-sample -- ./build/xio-tester sdma-ep -n 8 -s 1M --verify
```

Open the generated Perfetto trace; the XGMI Read Data and XGMI Write Data
tracks show traffic over time. Only available on multi-GPU systems with
XGMI links; otherwise values are N/A.

## References

- AMD SDMA specifications
- ROCm hsakmt documentation
- Anvil library (RAD team, commit 6df07028)
- MI300X OAM topology documentation
