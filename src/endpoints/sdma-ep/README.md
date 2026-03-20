# SDMA Endpoint

## Overview

The SDMA (System DMA) endpoint enables GPU-initiated DMA transfers using
AMD's hardware SDMA engines. SDMA engines are specialized DMA controllers
on AMD GPUs that can perform memory-to-memory transfers, including peer-to-peer
(P2P) GPU transfers, without CPU intervention.

## Hardware Requirements

- **AMD MI300X** (CDNA3 / gfx942) -- default build (pre-OSS7
  SDMA packets)
- **AMD MI350X** (CDNA4 / gfx950) and later -- OSS7.0 SDMA
  packets, auto-detected from `OFFLOAD_ARCH`
- **ROCm 6.0+** with hsakmt library support
- **P2P mode**: Multi-GPU system and XGMI/Infinity Fabric for
  GPU-to-GPU
- **Single-GPU mode** (`--to-host`): One GPU; destination is pinned
  host memory

## Implementation

The sdma-ep implementation is based on the **anvil library** from AMD's
RAD team (commit 6df07028). The anvil library provides low-level hardware
queue management for SDMA engines via the hsakmt (HSA Kernel Mode Driver
Thunk) interface.

### Components

- **sdma-ep.hip**: XIO endpoint interface implementation (uses anvil);
  nominal SQE/CQE sizes for the registry are defined in xio-endpoint.hip
- **anvil.hpp / anvil.hip**: Host-side SDMA queue management and
  initialization
- **anvil_device.hpp**: Device-side SDMA queue primitives for GPU kernels
- **sdma_opcodes.h**: Shared SDMA opcode and sub-opcode constants
  for all generations; OSS7.0 sub-opcodes gated by `XIO_SDMA_OSS7`
- **sdma_pkt_struct.h**: Pre-OSS7 (MI300X) SDMA packet structures
- **sdma_pkt_struct_mi4.h**: OSS7.0 packet structures, gated by
  `XIO_SDMA_OSS7` (see [OSS7.0 Support](#oss70-support))
- **sdma-packet.h**: OSS7.0 SDMA field-level macro definitions
  (auto-generated from the MAS; reference for struct generation)

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
- **P2P mode**: Requires at least two GPUs. Use `--to-host` for
  single-GPU testing (destination is pinned host memory).
- **Privileged operations**: Requires hsakmt library which interfaces
  with the kernel driver (KFD).

## Testing

SDMA endpoint testing requires real hardware.

**Transfer size:** Default is 4KB per iteration. Use `-s` /
`--transfer-size` for larger moves. The value is in bytes; you can use
a number or a suffix: `4k`, `1M`, `2G`. Suffixes are **power-of-2** (binary):
k = 1024, M = 1024², G = 1024³ (i.e. KiB, MiB, GiB), not SI (power-of-10).
Value must be a multiple of 4.

**Single-GPU (no P2P):** Use `--to-host` so the destination is pinned
host memory. Only one GPU is required:

```bash
# Single GPU: SDMA from device to pinned host memory
sudo ./build/xio-tester sdma-ep --to-host -n 10 -v

# With data validation (LFSR pattern; seed advances per iteration)
sudo ./build/xio-tester sdma-ep --to-host --verify -n 10 -v

# Larger transfer: 1MB per iteration
sudo ./build/xio-tester sdma-ep --to-host -n 8 -s 1048576 --verify
```

**P2P (two GPUs):** Default mode copies from GPU 0 to GPU 1. Use
`--src-gpu` and `--dst-gpu` to choose HIP device IDs. Use `--verify`
to validate the destination buffer after transfer:

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

The reference **shader_sdma** bench (RAD) sweeps transfer sizes from
1KB to 1GB (`--minCopySize` / `--maxCopySize`, doubling each step). sdma-ep
uses a single transfer size per run; use `-s` to test specific sizes (e.g.
4K default, 1M, 64M).

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
- **Signal-only**: Atomic increment on a completion counter
  (SDMA_OP_ATOMIC); used today with putWithSignal.
- **Write linear**: Write from embedded packet data
  (SDMA_OP_WRITE_LINEAR).

### Confirming XGMI traffic with counters

On P2P runs you can try to confirm data movement over XGMI by reading
**XGMI read/write counters** before and after the test.

**1. AMD SMI**

If [AMD SMI][amdsmi-docs] is installed (e.g. with ROCm):

```bash
# XGMI metrics for all GPUs (read/write data per link)
amd-smi xgmi -m -g all
```

Sample once before and once after; the **delta** (after - before) is the
traffic in that interval. The XGMI traffic counters are **not resettable**
(only XGMI *error* counts: `sudo amd-smi reset --xgmierr -g all`). If
display is in **TB**, use a large run (e.g. `-n 1000 -s 100M` = 100 GB)
to see a visible delta, or try `--json` / `--csv` for higher precision.

**If the counter does not increment:** On some systems and driver versions,
the XGMI read/write values reported by amd-smi may **not** include SDMA P2P
traffic (they can be tied to other engines or paths). So a non-incrementing
counter does not prove that data is not moving over XGMI. In that case rely
on: (1) **LFSR verification** (`--verify`) -- confirms the correct data
reached the destination; (2) **P2P topology** --
`hipDeviceCanAccessPeer` and anvil's use of the SDMA-to-XGMI path; (3)
**timing** -- sub-millisecond averages for large transfers are consistent
with XGMI bandwidth, not host bounce.

**2. ROCm Systems Profiler (time series)**

For a trace over time (e.g. to correlate with your run), use
[ROCm Systems Profiler][rocprof-docs] with AMD SMI metrics:

```bash
export ROCPROFSYS_USE_AMD_SMI=true
export ROCPROFSYS_AMD_SMI_METRICS=busy,temp,power,mem_usage,xgmi,pcie
rocprof-sys-sample -- ./build/xio-tester sdma-ep -n 8 -s 1M --verify
```

Open the generated Perfetto trace; the XGMI Read Data and XGMI Write
Data tracks show traffic over time. Only available on multi-GPU systems
with XGMI links; otherwise values are N/A.

## OSS7.0 Support

The sdma-ep supports OSS7.0 SDMA packet formats used by CDNA4
(MI350X / gfx950) and later architectures. The correct packet
generation is **auto-detected** from `OFFLOAD_ARCH` at CMake
configure time.

### Architecture-Based Auto-Detection

CMake detects the GPU architecture from `OFFLOAD_ARCH` (which
is itself auto-detected via `rocminfo` or specified manually)
and enables OSS7.0 packets for architectures in the
`_SDMA_OSS7_TARGETS` list:

```bash
# Auto-detected: gfx950 enables OSS7.0 automatically
cmake -B build -DOFFLOAD_ARCH=gfx950

# Manual override for cross-compilation or pre-silicon
cmake -B build -DXIO_SDMA_OSS7=ON
```

When `XIO_SDMA_OSS7` is enabled (auto or manual), the build
defines `XIO_SDMA_OSS7=1` for all sdma-ep sources. The
default (pre-OSS7) build targets MI300X hardware.

### OSS7.0 Packet Types

The following OSS7.0 packet structs are defined in
`sdma_pkt_struct_mi4.h`:

| Struct | DWORDs | Description |
|--------|--------|-------------|
| `SDMA_PKT_COPY_LINEAR_PHY_MI4` | 8 | Physical linear copy with scope, mtype, and temporal hints |
| `SDMA_PKT_COPY_LINEAR_WAIT_SIGNAL_MI4` | 19 | Combined copy + poll-wait + atomic-signal in one packet |
| `SDMA_PKT_WRITE_LINEAR_MI4` | 5 | Linear write with cache attributes |
| `SDMA_PKT_FENCE_MI4` | 4 | Fence with mtype, scope, and temporal hints |
| `SDMA_PKT_FENCE_64B_MI4` | 5 | 64-bit fence (8-byte aligned addresses) |
| `SDMA_PKT_CONSTANT_FILL_MI4` | 5 | Constant fill with cache attributes |
| `SDMA_PKT_POLL_MEM_64B_MI4` | 8 | 64-bit poll memory with cache policy |

Struct names retain the `_MI4` suffix from the hardware MAS.

### Key Optimization: Combined Copy + Signal

On MI300X (pre-OSS7), a copy-with-signal requires **two
packets** in the SDMA ring: a `COPY_LINEAR` (7 DWORDs)
followed by an `ATOMIC` (8 DWORDs) for the signal increment.

On OSS7.0, the `COPY_LINEAR_WAIT_SIGNAL_MI4` packet fuses
both operations into a **single 19-DWORD packet**. The
`put_signal` and `put_signal_counter` helpers in
`anvil_device.hpp` automatically use this fused path when
`XIO_SDMA_OSS7` is enabled, eliminating a separate
reserve/place/submit cycle for the signal.

### Cache and Scope Fields

OSS7.0 packets expose additional cache-control fields not
present on pre-OSS7 hardware:

- **scope** -- coherence scope (device, system, etc.)
- **mtype** -- memory type for cache routing
- **temporal_hint** -- temporal locality hint for the cache
  hierarchy
- **sys / snp / gpa / gcc** -- system, snoop, GPA, and GCC
  flags for fine-grained cache control

These are zero-initialized by the default packet creation
helpers. Callers that need non-default cache behaviour can
set the fields on the returned struct before placing the
packet.

### Source of Truth

The struct definitions in `sdma_pkt_struct_mi4.h` are
derived from the field-level macros in `sdma-packet.h`,
which was auto-generated from the OSS7.0 SDMA MAS
(`OSS_70-sDMA_MAS.md`). The macro header is kept as the
canonical reference; regenerating the structs should
re-derive bit layouts from the `_offset`, `_mask`, and
`_shift` macros.

## References

- AMD SDMA specifications (OSS7.0 MAS)
- ROCm hsakmt documentation
- Anvil library (RAD team, commit 6df07028)
- MI300X OAM topology documentation

[amdsmi-docs]: https://rocm.docs.amd.com/projects/amdsmi/en/latest/
[rocprof-docs]: https://rocm.docs.amd.com/projects/rocprofiler-systems/
