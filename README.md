# rocm-axiio: A ROCm Library for Accelerator-Initiated IO

## Introduction

This repository contains the source code for a ROCm library that provides
an API for Accelerator-Initiated IO (AxIIO) for AMD GPU `__device__` code.

This library enables AMD GPUs to perform **direct I/O operations** to hardware devices (NVMe SSDs, RDMA NICs, SDMA engines) without CPU intervention, achieving sub-microsecond latencies.

This library targets a number of devices which we refer to as end-points. The
list of supported devices we can issue IO too is given in the
[endpoints](./endpoints) sub-folder.

## Quick Reference

### Build and Run (3 Steps)

```bash
# 1. Install ROCm (if not already installed)
sudo apt install rocm-hip-sdk rocminfo libcli11-dev

# 2. Build
make all

# 3. Run with GPU + NVMe
export HSA_FORCE_FINE_GRAIN_PCIE=1
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 -n 100 --verbose
```

### Key Command Line Arguments

| Use Case | Command |
|----------|---------|
| **Test with real NVMe** | `sudo ./bin/axiio-tester -e nvme-ep --device /dev/nvme0` |
| **CPU-only mode** | `sudo ./bin/axiio-tester -e nvme-ep --device /dev/nvme0 --cpu-only` |
| **Use kernel module** | `sudo ./bin/axiio-tester -e nvme-ep --device /dev/nvme0 --kernel-module` |
| **Performance test** | `sudo ./bin/axiio-tester -e nvme-ep --device /dev/nvme0 -n 10000 --histogram` |
| **List endpoints** | `./bin/axiio-tester -e` |
| **Emulated test** | `./bin/axiio-tester -n 100 --verbose` |

### VM Testing (With GPU Passthrough, Real + Emulated NVMe)

If you're testing in a VM environment with GPU passthrough and multiple
NVMe devices, use the automated testing scripts:

```bash
# Interactive menu (easiest)
./quick-test.sh

# Automated build and test
./build-and-test.sh --test real --nvme /dev/nvme0 --iterations 100

# Simple clean build
./clean-build.sh
```

See **[VM_TESTING_GUIDE.md](VM_TESTING_GUIDE.md)** for complete VM
testing documentation.

## Table of Contents

- [Introduction](#introduction)
- [Quick Reference](#quick-reference)
  - [VM Testing](#vm-testing-with-gpu-passthrough-real--emulated-nvme)
- [Endpoints](#endpoints)
- [Prerequisites](#prerequisites)
  - [Installing ROCm](#installing-rocm)
  - [Environment Variables](#environment-variables-for-radeon-gpus)
- [Building](#building)
- [Testing](#testing)
- [Running with GPU Against Real NVMe SSD](#running-with-gpu-against-real-nvme-ssd)
  - [Three Methods](#three-methods-for-gpu-nvme-io)
  - [Command Line Arguments](#command-line-arguments-reference)
  - [Complete Usage Examples](#complete-usage-examples)
  - [Troubleshooting](#troubleshooting-gpu-nvme-issues)
- [Additional Information](#additional-useful-information)

## Endpoints

Endpoints define the hardware interfaces and protocols for different IO devices.
Each endpoint provides its own queue entry formats and IO semantics.

### Available Endpoints

- **test-ep** - Test endpoint for development and testing
  - Located in `endpoints/test-ep/`
  - Magic ID: `0xF0`
  - Used for validating the AxIIO framework

- **nvme-ep** - NVMe endpoint 
  - Located in `endpoints/nvme-ep/`
  - Magic ID: `0xF1`
  - Implements NVMe command submission (SQE) and completion (CQE) handling
  - Supports Read, Write, and Flush commands
  - Definitions based on Linux kernel NVMe headers and NVMe specification

### Listing Available Endpoints

To see all available endpoints:

```bash
./bin/axiio-tester --list-endpoints
# or
./bin/axiio-tester -e
```

Output:
```
Available endpoints:
  test-ep - Test endpoint for development/testing
  nvme-ep - NVMe endpoint for NVM Express command simulation
  sdma-ep - AMD SDMA Engine endpoint
  rdma-ep - RDMA endpoint for InfiniBand/RoCE

All endpoints are built into the binary.
```

### Selecting an Endpoint at Runtime

**All endpoints are now built automatically** and selected at runtime using the `--endpoint` or `-e` flag:

```bash
# Use test endpoint (default)
./bin/axiio-tester -n 100

# Use NVMe endpoint
./bin/axiio-tester --endpoint nvme-ep -n 100

# Use NVMe endpoint with real hardware
sudo ./bin/axiio-tester -e nvme-ep --device /dev/nvme0

# View endpoint-specific options
./bin/axiio-tester -e nvme-ep --help
```

The build system compiles all endpoints and uses static dispatch to route operations to the correct endpoint at runtime.

### Adding a New Endpoint

To add a new endpoint to the system:

1. **Create endpoint directory**: `mkdir endpoints/my-ep`

2. **Create header file** `endpoints/my-ep/my-ep.h`:
   - Define a unique magic ID (e.g., `MY_EP_MAGIC_ID 0xF2`)
   - Define queue entry sizes and structures
   - Conditionally define `sqeType_s` and `cqeType_s` based on
     `AXIIO_ENDPOINT_MYEP`

3. **Create implementation** `endpoints/my-ep/my-ep.hip`:
   - Include your endpoint header
   - Include `axiio-endpoints.h`
   - Implement all required functions: `sqeRead`, `cqeRead`, `sqeWrite`,
     `cqeWrite`, `sqePoll`, `cqePoll`, `cqeGenFromSqe`
   - Implement `axiioEndPoint::emulateEndpoint` and
     `axiioEndPoint::driveEndpoint`

4. **Update Makefile**:
   - Add `my-ep` to `VALID_ENDPOINTS`
   - Add include path: `-I$(ENDPOINTS_DIR)/my-ep`
   - Add conditional: `else ifeq ($(ENDPOINT),my-ep)`
     with `override CXXFLAGS += -DAXIIO_ENDPOINT_MYEP`

5. **Update include/axiio-endpoints.h**:
   - Add `#elif defined(AXIIO_ENDPOINT_MYEP)` case to include your header

6. **Update tester** `tester/axiio-tester.hip`:
   - Add description to `--list-endpoints` output

7. **Update README.md**: Document your new endpoint

### NVMe Endpoint Reference Headers

The `nvme-ep` endpoint definitions are based on the official Linux kernel NVMe headers.
To download the latest kernel headers for reference:

```bash
make fetch-nvme-headers
```

This will download:
- `include/external/linux-nvme.h` - Main NVMe definitions
- `include/external/linux-nvme_ioctl.h` - IOCTL structures

These headers are for reference only and are not directly compiled. The `nvme-ep` 
implementation uses simplified, clean structures suitable for GPU code while maintaining
compatibility with the NVMe specification.

To remove downloaded headers:
```bash
make clean-external
```

**Note**: The external headers are git-ignored and can be regenerated at any time.

## Tools

The [tools](./tools) directory contains a number of tools that are (add more
content here).

## Prerequisites

### System Requirements

- **ROCm installation** with `hipcc` compiler (version 5.0 or later recommended)
- **rocminfo** utility (recommended for automatic GPU architecture detection)
- **libcli11-dev** - Command line parser library for C++11
- **AMD GPU** (Radeon RX series or MI-series accelerator)
- **NVMe SSD** (for real hardware testing)

### Installing ROCm

If ROCm is not installed on your system, install it using the following steps:

#### For Native Linux

```bash
# Add ROCm repository (for Ubuntu/Debian)
wget https://repo.radeon.com/rocm/rocm.gpg.key -O - | gpg --dearmor | sudo tee /etc/apt/keyrings/rocm.gpg > /dev/null

# For Ubuntu 24.04 (Noble)
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/6.2 noble main" | sudo tee /etc/apt/sources.list.d/rocm.list

# For Ubuntu 22.04 (Jammy)
# echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/6.2 jammy main" | sudo tee /etc/apt/sources.list.d/rocm.list

# Update and install ROCm
sudo apt update
sudo apt install rocm-hip-sdk rocminfo libcli11-dev

# Verify installation
which hipcc
hipcc --version
```

#### For WSL2 (Windows Subsystem for Linux)

**WSL2 requires special setup.** See the comprehensive guide: **[WSL_INSTALLATION.md](WSL_INSTALLATION.md)**

Quick summary for WSL2:
```bash
# Set repository priority (required for WSL)
cat << 'EOF' | sudo tee /etc/apt/preferences.d/rocm-pin-600
Package: *
Pin: release o=repo.radeon.com
Pin-Priority: 600
EOF

# Install ROCm and dependencies
sudo apt update
sudo apt install rocm-hip-sdk rocminfo libcli11-dev g++ libstdc++-14-dev

# Build with explicit GPU architecture (required in WSL)
make OFFLOAD_ARCH=gfx1100 all  # Adjust for your GPU
```

For other Linux distributions, see the [official ROCm installation guide](https://rocm.docs.amd.com/projects/install-on-linux/en/latest/).

### Installing Other Prerequisites

You can check and install all prerequisites automatically:

```bash
make check-deps
```

Or install them manually:

```bash
# Ubuntu/Debian
sudo apt-get install -y libcli11-dev rocminfo

# Check ROCm installation
which hipcc
```

### Environment Variables for Radeon GPUs

**IMPORTANT**: On consumer Radeon GPUs (RX series), you **must** set the following
environment variable before running any tests:

```bash
export HSA_FORCE_FINE_GRAIN_PCIE=1
```

This enables fine-grained memory coherence which is required for GPU-to-CPU
memory visibility. Without this setting, the GPU will encounter page faults
when accessing host memory.

**Note**: On MI-series accelerators (MI300X, etc.), this is typically not required
as fine-grained memory is available by default.

To make this permanent, add it to your `~/.bashrc`:

```bash
echo 'export HSA_FORCE_FINE_GRAIN_PCIE=1' >> ~/.bashrc
source ~/.bashrc
```

## Building

### Quick Start

**Note**: The build system now compiles **all endpoints** automatically (test-ep, nvme-ep, sdma-ep, rdma-ep) and uses dynamic dispatch at runtime. You no longer need to specify a single endpoint at build time.

If `rocminfo` is not installed, the build system will fall back to hipcc's
default GPU architecture detection.

### Building with Make

Simply run:

```bash
make all
```

This will:
- Build all available endpoints (test-ep, nvme-ep, sdma-ep, rdma-ep)
- Generate endpoint registry and dispatch code
- Download required external headers (RDMA, NVMe reference)
- Create `lib/librocm-axiio.a` library
- Build `bin/axiio-tester` executable

The Makefile will automatically detect your GPU architecture and display it
during the build. You can also specify a target architecture manually:

```bash
make OFFLOAD_ARCH=gfx1100 all
```

### Build Configuration Options

```bash
# GPU-direct mode is always used (CPU-hybrid mode removed)

# Build for specific GPU architecture
make OFFLOAD_ARCH=gfx90a all

# Build for specific GPU (REQUIRED in WSL2)
make OFFLOAD_ARCH=gfx1100 all  # RX 7000 series (RDNA3)
make OFFLOAD_ARCH=gfx1030 all  # RX 6000 series (RDNA2)
make OFFLOAD_ARCH=gfx942 all   # MI300 series

# Build with parallel jobs
make -j$(nproc) all

# Clean and rebuild
make clean
make all
```

**Note for WSL2 Users**: You MUST specify `OFFLOAD_ARCH` explicitly because GPU auto-detection doesn't work in WSL. See [WSL_INSTALLATION.md](WSL_INSTALLATION.md) for architecture codes.

### Manual Build Steps

The following steps can be used for manual builds (example with test-ep):

```bash
# Compile endpoint
hipcc --offload-arch=native -xhip -c endpoints/test-ep/test-ep.hip \
  -o test-ep.o -fgpu-rdc -I include/ -I endpoints/test-ep \
  -DAXIIO_ENDPOINT_NAME=\"test-ep\" -DAXIIO_ENDPOINT_TEST

# Compile helper
hipcc --offload-arch=native -xhip -c common/helper.hip \
  -o helper.o -fgpu-rdc -I include/ -I endpoints/test-ep

# Create library
ar rcsD lib/librocm-axiio.a test-ep.o helper.o

# Compile tester
hipcc -c tester/axiio-tester.hip -fgpu-rdc -I include/ \
  -I endpoints/test-ep -DAXIIO_ENDPOINT_NAME=\"test-ep\" \
  -DAXIIO_ENDPOINT_TEST

# Link final binary
hipcc axiio-tester.o lib/librocm-axiio.a -o bin/axiio-tester -fgpu-rdc

# Disassemble library (optional)
unbuffer /opt/rocm/lib/llvm/bin/llvm-objdump --demangle \
  --disassemble-all lib/librocm-axiio.a | less -R
```

For nvme-ep, replace `test-ep` with `nvme-ep` and `AXIIO_ENDPOINT_TEST`
with `AXIIO_ENDPOINT_NVME`.

## Testing

The project includes comprehensive testing infrastructure with automatic GPU
error detection.

### Running Tests

All tests automatically set the required environment variables and monitor
for GPU errors in dmesg. If a GPU page fault or error is detected, the test
will fail with diagnostic information.

```bash
# Run basic test (128 iterations)
make test

# Run quick fuzz test
make test-quick

# Run medium fuzz test (1000 iterations)
make test-medium

# Run large fuzz test (10000 iterations)
make test-large

# Run huge fuzz test (100000 iterations)
make test-huge

# Run verbose test with detailed output
make test-verbose

# Run test with performance histogram
make test-histogram

# Run all standard fuzz tests
make test-fuzz

# Run comprehensive test suite
make test-all
```

### Manual Testing with Error Detection

You can also run tests manually using the monitoring script:

```bash
# Run with custom arguments
./scripts/test-with-dmesg-monitor.sh -n 500 --verbose

# Set custom timeout (default 30s)
TIMEOUT=60 ./scripts/test-with-dmesg-monitor.sh -n 1000

# Run without environment checks
CHECK_ENV=0 ./scripts/test-with-dmesg-monitor.sh -n 128
```

The monitoring script will:
- Check that HSA_FORCE_FINE_GRAIN_PCIE is set
- Record the current dmesg state
- Run the test with a timeout
- Check for new GPU errors in dmesg
- Provide diagnostic suggestions if errors are detected

### Troubleshooting Test Failures

If tests fail with GPU page faults:

1. **Verify environment variable**: Ensure `HSA_FORCE_FINE_GRAIN_PCIE=1` is set
2. **Check memory allocation**: The code should use `hipHostMallocCoherent`
3. **Clear old errors**: Run `sudo dmesg -c` to clear old kernel messages
4. **Check GPU info**: Run `rocminfo` to verify GPU is detected correctly
5. **Update ROCm**: Ensure you have a compatible ROCm version

### Testing with Real NVMe Hardware

The `axiio-tester` supports testing with real NVMe hardware by directly mapping
physical memory addresses of NVMe queues and doorbells. This enables testing
GPU-to-NVMe interactions without emulation.

#### Prerequisites

- Root privileges or `CAP_SYS_RAWIO` capability
- Access to `/dev/mem` (may require `iomem=relaxed` kernel parameter)
- NVMe device (physical or QEMU-emulated)
- NVMe queue addresses (doorbell, SQ base, CQ base)

#### Quick Start

```bash
# Discover NVMe addresses
sudo ./scripts/discover-nvme-addresses.sh

# Run test with real hardware
sudo ./bin/axiio-tester -e nvme-ep \
  --doorbell 0xfeb01000 \
  --sq-base 0xfeb10000 \
  --cq-base 0xfeb20000 \
  --sq-size 4096 \
  --cq-size 4096 \
  --iterations 10 \
  --verbose
```

#### Testing with QEMU

```bash
# Run automated QEMU setup script
sudo ./scripts/test-nvme-qemu.sh
```

#### Documentation

See comprehensive documentation:
- [`docs/NVME_HARDWARE_TESTING.md`](docs/NVME_HARDWARE_TESTING.md) - Complete guide
- [`docs/NVME_TESTING_SUMMARY.md`](docs/NVME_TESTING_SUMMARY.md) - Implementation details

#### Safety Warnings

⚠️ **Direct hardware access can crash your system or corrupt data!**

- Test in QEMU first before real hardware
- Verify all addresses are correct
- Use on test systems only
- Have backups
- Monitor system logs (`dmesg`)

## Running with GPU Against Real NVMe SSD

This section provides comprehensive instructions for running `axiio-tester` with an AMD GPU performing direct I/O operations to a real NVMe SSD.

### Quick Start

The simplest way to run with real NVMe hardware:

```bash
# Set required environment variable (for Radeon GPUs)
export HSA_FORCE_FINE_GRAIN_PCIE=1

# Run with automatic device setup
sudo ./bin/axiio-tester -e nvme-ep \
  --device /dev/nvme0 \
  --iterations 100 \
  --verbose
```

### Three Methods for GPU-NVMe I/O

#### Method 1: Kernel Module Integration (Recommended)

**Best for**: Production use, stability, and true GPU-direct I/O

The kernel module (`/dev/nvme-axiio`) provides DMA-safe memory and proper queue management.

```bash
export HSA_FORCE_FINE_GRAIN_PCIE=1

sudo ./bin/axiio-tester -e nvme-ep \
  --device /dev/nvme0 \
  --kernel-module \
  --queue-id 63 \
  --iterations 100 \
  --transfer-size 4096 \
  --lba-range-gib 1 \
  --access-pattern random \
  --nsid 1 \
  --verbose
```

**Features**:
- HSA memory locking for GPU-direct doorbell writes
- Proper DMA addresses for NVMe controller
- Avoids conflicts with kernel NVMe driver
- TRUE GPU-direct I/O (no CPU intervention)

#### Method 2: Direct Device Access (Lightweight)

**Best for**: Testing, debugging, quick experiments

Direct device access with automatic address discovery.

```bash
export HSA_FORCE_FINE_GRAIN_PCIE=1

sudo ./bin/axiio-tester -e nvme-ep \
  --device /dev/nvme0 \
  --iterations 100 \
  --transfer-size 4096 \
  --lba-range-gib 1 \
  --access-pattern random \
  --nsid 1 \
  --verbose
```

**Features**:
- Automatic queue creation via ioctl
- No kernel module required
- Lightweight queue management
- May use CPU-hybrid mode for doorbell

#### Method 3: CPU-Only Mode (No GPU Atomics)

**Best for**: Systems without PCIe atomics, debugging GPU issues

CPU generates NVMe commands; GPU is optional.

```bash
sudo ./bin/axiio-tester \
  --nvme-device /dev/nvme0 \
  --cpu-only \
  --iterations 100 \
  --transfer-size 4096 \
  --lba-range-gib 1 \
  --access-pattern sequential \
  --nvme-nsid 1 \
  --verbose
```

**Features**:
- No PCIe atomics required
- Works on any system with NVMe
- Useful for benchmarking CPU vs GPU

### Command Line Arguments Reference

#### Essential Arguments

#### Global Options

| Argument | Description | Example | Default |
|----------|-------------|---------|---------|
| `-n, --iterations` | Number of I/O operations | `100` | 128 |
| `-v, --verbose` | Enable detailed output | flag | false |
| `-i, --info` | Print GPU information | flag | false |
| `--histogram` | Generate performance histogram | flag | false |
| `-e, --endpoint` | Select endpoint or list available | `nvme-ep`, `test-ep` | test-ep |
| `-m, --memory` | Memory type | `host`, `device` | host |
| `--submit-queue-len` | Submission queue length | `1024` | 1024 |
| `--complete-queue-len` | Completion queue length | `512` | 512 |
| `--skip-atomics-check` | Skip PCIe atomics check | flag | false |

#### NVMe Endpoint Options (use with `-e nvme-ep`)

| Argument | Description | Example | Default |
|----------|-------------|---------|---------|
| `--device` | Path to NVMe device | `/dev/nvme0` | - |
| `--kernel-module` | Use `/dev/nvme-axiio` kernel module | flag | false |
| `--queue-id` | Queue ID (high IDs avoid kernel conflicts) | `63` | 63 |
| `--nsid` | NVMe namespace ID | `1` | 1 |
| `--block-size` | NVMe block size | `512`, `4096` | 512 |
| `--transfer-size` | Transfer size in bytes | `4096` | 4096 |
| `--lba-range-gib` | LBA range to test in GiB | `10` | 1 |
| `--access-pattern` | Access pattern | `random`, `sequential` | random |
| `--cpu-only` | CPU command generation (no GPU atomics) | flag | false |
| `--use-data-buffers` | Enable data buffer testing | flag | false |
| `--data-buffer-size` | Data buffer size in bytes | `1048576` | 1MB |
| `--test-pattern` | Data pattern | `random`, `zeros`, `ones`, `sequential`, `block_id` | sequential |

#### Output Control

| Argument | Description | Example | Default |
|----------|-------------|---------|---------|
| `--histogram` | Generate performance histogram | flag | false |
| `-e, --endpoint` | Select endpoint or list available | `nvme-ep`, `test-ep` | test-ep |
| `-m, --memory` | Memory type | `host`, `device` | host |

### Complete Usage Examples

#### Example 1: Basic Functionality Test

```bash
export HSA_FORCE_FINE_GRAIN_PCIE=1

sudo ./bin/axiio-tester -e nvme-ep \
  --device /dev/nvme0 \
  -n 10 \
  --verbose
```

#### Example 2: Performance Testing with Histogram

```bash
export HSA_FORCE_FINE_GRAIN_PCIE=1

sudo ./bin/axiio-tester -e nvme-ep \
  --device /dev/nvme0 \
  --iterations 10000 \
  --transfer-size 8192 \
  --lba-range-gib 10 \
  --access-pattern random \
  --histogram
```

#### Example 3: Data Integrity Testing

```bash
export HSA_FORCE_FINE_GRAIN_PCIE=1

sudo ./bin/axiio-tester -e nvme-ep \
  --device /dev/nvme0 \
  --use-data-buffers \
  --data-buffer-size 1048576 \
  --block-size 512 \
  --test-pattern random \
  --iterations 1000 \
  --verbose
```

#### Example 4: Sequential I/O Benchmark

```bash
export HSA_FORCE_FINE_GRAIN_PCIE=1

sudo ./bin/axiio-tester -e nvme-ep \
  --device /dev/nvme0 \
  --transfer-size 131072 \
  --access-pattern sequential \
  --lba-range-gib 100 \
  --iterations 5000 \
  --histogram
```

#### Example 5: Testing with Kernel Module (GPU-Direct)

```bash
export HSA_FORCE_FINE_GRAIN_PCIE=1

# Load kernel module first (if available)
sudo modprobe nvme-axiio

sudo ./bin/axiio-tester -e nvme-ep \
  --device /dev/nvme0 \
  --kernel-module \
  --queue-id 63 \
  --iterations 1000 \
  --transfer-size 4096 \
  --verbose
```

### Identifying Your NVMe Device

To find available NVMe devices:

```bash
# List all NVMe devices
ls -l /dev/nvme*

# Get detailed NVMe information
sudo nvme list

# Check device capacity and namespace
lsblk -o NAME,SIZE,TYPE,MODEL | grep nvme

# View NVMe device information
sudo nvme id-ctrl /dev/nvme0

# List namespaces
sudo nvme list-ns /dev/nvme0
```

### Testing Progression (Recommended Order)

Start with these steps to verify functionality:

```bash
# 1. List available endpoints
./bin/axiio-tester -e

# 2. Test basic functionality (emulated, no hardware)
./bin/axiio-tester -n 10 --verbose

# 3. Test with CPU-only mode (validates NVMe access)
sudo ./bin/axiio-tester -e nvme-ep --device /dev/nvme0 --cpu-only -n 10 --verbose

# 4. Test with GPU (requires PCIe atomics)
export HSA_FORCE_FINE_GRAIN_PCIE=1
sudo ./bin/axiio-tester -e nvme-ep --device /dev/nvme0 -n 100 --verbose

# 5. Performance benchmarking
sudo ./bin/axiio-tester -e nvme-ep --device /dev/nvme0 -n 10000 --histogram
```

### GPU Doorbell Mode

The build system always uses GPU-direct mode (CPU-hybrid mode removed):

GPU writes directly to NVMe doorbell registers:
- **Latency**: < 1 microsecond per batch
- **Performance**: Maximum throughput
- **Requirements**: HSA memory locking, kernel module support, exclusive mode

```bash
# Build with GPU-direct mode (always enabled)
make all
```

**Note**: If GPU-direct mode is not available (e.g., HSA initialization fails or kernel module is not in exclusive mode), the program will fail with a clear error message. CPU-hybrid mode has been removed to simplify the codebase.

### Important Notes

1. **Root Privileges**: Required for direct hardware access (`sudo` or `CAP_SYS_RAWIO`)
2. **Environment Variable**: Must set `HSA_FORCE_FINE_GRAIN_PCIE=1` for Radeon GPUs
3. **Queue IDs**: Use high queue IDs (50-65) to avoid kernel driver conflicts
4. **PCIe Atomics**: Required for GPU mode; use `--cpu-only` if unavailable
5. **Data Safety**: Test on non-production drives or backup data first

### Troubleshooting GPU-NVMe Issues

#### Issue: "PCIe atomics not enabled"

```bash
# Solution 1: Use CPU-only mode
sudo ./bin/axiio-tester -e nvme-ep --device /dev/nvme0 --cpu-only

# Solution 2: Enable PCIe atomics in BIOS/VM settings
# (Requires system configuration changes)
```

#### Issue: "Failed to map doorbell"

```bash
# Check if kernel module is loaded
lsmod | grep nvme

# Try direct device access without kernel module
sudo ./bin/axiio-tester -e nvme-ep --device /dev/nvme0 --verbose
```

#### Issue: "Queue creation failed"

```bash
# Try a different queue ID
sudo ./bin/axiio-tester -e nvme-ep --device /dev/nvme0 --queue-id 50

# Or use auto-detection (default behavior)
sudo ./bin/axiio-tester -e nvme-ep --device /dev/nvme0
```

#### Issue: GPU page faults

```bash
# Verify environment variable
echo $HSA_FORCE_FINE_GRAIN_PCIE

# Set if not already set
export HSA_FORCE_FINE_GRAIN_PCIE=1

# Check dmesg for errors
sudo dmesg | tail -50
```

### Performance Expectations

Typical performance numbers on modern hardware:

| Configuration | IOPS | Latency | Notes |
|--------------|------|---------|-------|
| GPU-Direct (kernel module) | 1M+ | < 1 μs | True GPU-direct |
| CPU-Hybrid | 500K+ | ~1-2 μs | CPU doorbell overhead |
| CPU-Only | 100K+ | ~5-10 μs | No GPU involvement |

*Actual performance depends on NVMe drive, GPU, and system configuration.*

## Additional Useful Information

On MI300X, the host allocation should be always `UNCACHED`. I think a
`__threadfence()` should work for MI300X. However it has been seen that
`__threadfence_system()` is needed on Radeon GPUs.

I learned last week the hard way again that you do not have fine-grain memory
on Radeon GPUs unless you set `HSA_FORCE_FINE_GRAIN_PCIE=1`.

Coarse-grained memory basically means that a change at a memory location might
only become visible to the CPU once the kernel finishes. Fine-grained means
that changes to memory should be visible 'immediately' (with immediately being
obviously the wrong term, but basically not just at the end of the kernel
runtime). So its about visibility and cache coherence. As is often the case
there is a good [Confluence page][ref-mem-grain] by Joseph Greathouse on this
topic! It definitely impacts device memory. The part that I am unsure is
whether it impacts things like `hipHostMalloc()`'d memory, which is host
memory but managed by ROCr, I don't know whether similar rules apply to it as
well.

`hipHostMalloc()` comes in two flavors. One is pinned and the other is
pageable/migratable. The pinned version is almost always what we will want in
rocm-axiio because we do not want to have the delay that happens if a device
tries to access an unmapped page-able memory page. Because that results in an
XNACK and associated PTE updates. That would be more useful for very large VMAs
which the __device__ code is going to access randomly and sporadically.

The last 2 weeks of my pain have stemmed from two things:

If __device__ code does a store to host memory what is needed to ensure that a
process running on a host cpu core can see the store? The answer here is
(I think) hipHostMalloc(), volatile pragmas (on the host) and
`__threadfence_system()` (on the device).

If __host__ code does a store to host memory what is needed to ensure that a
process running on a GPU core can see the store? Here the answer is (I think)
just hipHostMalloc(). The hipHostMalloc() ensures the memory if flagged as
uncached and so any CPU process writes to that VMA become visible at the system
level. I think. I am adding all this to the top-level README for now till we
get a nice clean scriptable way to ensuring these rules are applied at the
system level and vary depending on the GPU and endpoint(s) used.

[ref-mem-grain]: https://amd.atlassian.net/wiki/spaces/AMDGPU/pages/777526553/Cache+coherence+summary+by+Joseph+Greathouse
