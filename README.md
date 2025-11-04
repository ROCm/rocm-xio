# rocm-axiio: A ROCm Library for Accelerator-Initiated IO

## Introduction

This repository contains the source code for a ROCm library that provides
an API for Accelerator-Initiated IO (AxIIO) for AMD GPU `__device__` code.

This library targets a number of devices which we refer to as end-points. The
list of supported devices we can issue IO too is given in the
[endpoints](./endpoints) sub-folder.

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

To see all available endpoints and which one is currently compiled:

```bash
./bin/axiio-tester --list-endpoints
```

Output:
```
Available endpoints:
  test-ep - Test endpoint for development/testing
  nvme-ep - NVMe endpoint for NVM Express command simulation
  sdma-ep - AMD SDMA Engine endpoint

Currently compiled endpoint: test-ep

To build with a different endpoint, use:
  make ENDPOINT=<endpoint-name>
```

### Selecting an Endpoint at Build Time

Endpoints are selected at compile time using the `ENDPOINT` Makefile variable.
Only one endpoint can be active per build.

Build with the default endpoint (test-ep):
```bash
make all
```

Build with a specific endpoint:
```bash
make ENDPOINT=nvme-ep all
```

Clean and rebuild with a different endpoint:
```bash
make clean
make ENDPOINT=nvme-ep all
```

When you run the tester, it will display which endpoint is active:
```
Using endpoint: nvme-ep
```

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

### Installing Prerequisites

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

If `rocminfo` is not installed, the build system will fall back to hipcc's
default GPU architecture detection.

### Building with Make

Simply run:

```bash
make all
```

The Makefile will automatically detect your GPU architecture and display it
during the build. You can also specify a target architecture manually:

```bash
make OFFLOAD_ARCH=gfx1100 all
```

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
sudo ./bin/axiio-tester \
  --endpoint nvme-ep \
  --real-hardware \
  --nvme-doorbell 0xfeb01000 \
  --nvme-sq-base 0xfeb10000 \
  --nvme-cq-base 0xfeb20000 \
  --nvme-sq-size 4096 \
  --nvme-cq-size 4096 \
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
