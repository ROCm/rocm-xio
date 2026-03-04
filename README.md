# rocm-xio: A ROCm Library for Accelerator-Initiated IO

## Introduction

This repository contains the source code for a ROCm library that provides
an API for Accelerator-Initiated IO (XIO) for AMD GPU `__device__` code.

This library enables AMD GPUs to perform direct IO operations to hardware
devices (NVMe SSDs, RDMA NICs, SDMA engines) without CPU intervention.

This library targets a number of devices which we refer to as endpoints. The
list of supported devices we can issue IO to is given in the
[endpoints](./endpoints) sub-folder.

## Quick Reference

### Dependencies

```bash
# Install required packages
sudo apt install rocm-hip-sdk rocminfo libcli11-dev cmake \
  libdrm-dev libhsa-runtime-dev
```

### Build and Run

```bash
# 1. Configure CMake build
mkdir -p build && cd build
cmake ..

# 2. Build library and tester
cmake --build . --target all

# Output locations:
# - Library: build/lib/librocm-xio.a
# - Tester:  build/bin/xio-tester

# 3. Run with GPU + NVMe
export HSA_FORCE_FINE_GRAIN_PCIE=1
sudo ./build/bin/xio-tester nvme-ep --controller /dev/nvme0 \
  --read-io 50 --write-io 50 --verbose
```

### CMake Configuration Options

```bash
# Specify GPU architecture (auto-detected if not specified)
cmake -DOFFLOAD_ARCH=gfx942:xnack+ ..

# Specify ROCm installation path (default: /opt/rocm)
cmake -DROCM_PATH=/opt/rocm-7.1.0 ..

# Configure and build in one step
cmake --build . --target all
```

### CMake Build Targets

**Primary targets:**
```bash
cmake --build . --target rocm-xio    # Build library only
cmake --build . --target xio-tester   # Build tester only
cmake --build . --target all            # Build library + tester (default)
```

**Code generation targets:**
```bash
cmake --build . --target endpoint-registry-generated
cmake --build . --target nvme-ep-generated
cmake --build . --target rdma-vendor-headers-generated
cmake --build . --target fetch-nvme-headers
cmake --build . --target fetch-rdma-headers
cmake --build . --target fetch-external-headers
```

**Utility targets:**
```bash
cmake --build . --target list           # List supported GPU architectures
cmake --build . --target asm            # Dump library assembly code
cmake --build . --target lint-format    # Check code formatting
cmake --build . --target format         # Fix code formatting
cmake --build . --target lint-spell     # Check spelling in docs
cmake --build . --target lint-all       # Run all linting checks
cmake --build . --target clean-all      # Remove all build artifacts
cmake --build . --target clean-external # Remove external headers
```

### Installation

**Install to default location (typically `/opt/rocm`):**
```bash
cd build
cmake --build . --target install
```

**Install to custom location for testing:**
```bash
cd build
cmake --install . --prefix /tmp/rocm-xio-test

# Test the installation
export CMAKE_PREFIX_PATH=/tmp/rocm-xio-test:$CMAKE_PREFIX_PATH
cd /tmp
cat > test-find-package.cmake << 'EOF'
cmake_minimum_required(VERSION 3.21)
project(test)
find_package(rocm-xio REQUIRED)
message(STATUS "Found rocm-xio version: ${rocm-xio_VERSION}")
message(STATUS "Include dirs: ${ROCM_AXIIO_INCLUDE_DIRS}")
message(STATUS "Libraries: ${ROCM_AXIIO_LIBRARIES}")
EOF
cmake -P test-find-package.cmake
```

**Install with tester executable:**
```bash
cd build
cmake -DINSTALL_TESTER=ON ..
cmake --build . --target install --prefix /tmp/rocm-xio-test
```

### Kernel Module Build

The kernel module (`kernel/rocm-xio/`) uses the standard Linux kernel
build system (Kbuild) and must be built separately:

```bash
# Build kernel module
cd kernel/rocm-xio
make

# Install kernel module
sudo make install

# Load module
sudo modprobe rocm-xio

# Create device node (after loading)
sudo mknod /dev/rocm-xio c $(grep rocm-xio /proc/devices | awk '{print $1}') 0
sudo chmod 666 /dev/rocm-xio
```

**Note:** The kernel module build is independent of the CMake build system
and uses its own Makefile following Linux kernel conventions.

## Build System

This project uses CMake for building userspace code (library and tester).
The build system follows ROCm best practices and patterns from hipFile and
TransferBench.

### Build Output Structure

```
build/
├── bin/
│   └── xio-tester          # Test application
├── lib/
│   └── librocm-xio.a       # Static library
└── CMakeFiles/               # CMake internal files
```

### Key Features

- **HIP compilation**: Uses `hipcc` with `-fgpu-rdc` for relocatable device
  code
- **Device code extraction**: Tester executable links with `hipcc` to extract
  device code from static library
- **Code generation**: Automatic generation of endpoint registry and external
  headers
- **GPU architecture detection**: Auto-detects GPU architecture via `rocminfo`
  or can be specified via `OFFLOAD_ARCH` option

### CMake Requirements

- CMake 3.21 or later
- ROCm HIP SDK
- HSA runtime libraries
- libdrm and libdrm_amdgpu development packages

## Endpoints

Endpoints define the hardware interfaces and protocols for different IO
devices. Each endpoint provides its own queue entry formats and IO semantics.

### **test-ep** - Test endpoint for development and testing
  - Used for validating the XIO framework

### **nvme-ep** - NVMe endpoint
  - Implements NVMe command submission (SQE) and completion (CQE) handling
  - Supports Read and Write commands
  - Definitions based on Linux kernel NVMe headers and NVMe specification

### **sdma-ep** - SDMA (System DMA) endpoint
  - Enables GPU-initiated DMA transfers using AMD SDMA hardware engines
  - Supports peer-to-peer GPU transfers via XGMI/Infinity Fabric
  - Requires MI300X or similar datacenter GPUs with SDMA support

### Listing Available Endpoints

To see all available endpoints:
```bash
./build/bin/xio-tester --list-endpoints
```

### Environment Variables for Radeon GPUs

**IMPORTANT**: On consumer Radeon GPUs (RX series), you **should** set the
following environment variable before running any tests:
```bash
export HSA_FORCE_FINE_GRAIN_PCIE=1
```
This enables fine-grained memory coherence which is required for GPU-to-CPU
memory visibility. Without this setting, the GPU will encounter page faults
when accessing host memory.

**Note**: On MI-series accelerators (MI300X, etc.), this is typically not
required as fine-grained memory is available by default.

## Memory Leak Detection

This project includes support for detecting memory leaks using valgrind and
AddressSanitizer (ASan). Both tools can help identify memory leaks in host-side
code, though they have different strengths and limitations.

### Valgrind Integration

Valgrind is integrated with CMake's CTest framework for automated memory leak
detection.

**Prerequisites:**
```bash
sudo apt-get install valgrind
```

**Using CMake Native Integration (Recommended):**

```bash
# Configure with valgrind support (auto-detected if installed)
cd build && cmake ..

# Run all tests with valgrind memcheck
ctest -T memcheck

# Run specific test with valgrind
ctest -T memcheck -R test-name

# Use convenience target
cmake --build . --target valgrind-check

# View valgrind logs
cat build/Testing/Temporary/MemoryChecker.*.log
```

**Using Standalone Wrapper Script:**

For manual testing outside CTest:

```bash
# Run with standalone wrapper script
./scripts/test/run-valgrind.sh ./build/bin/xio-tester nvme-ep \
  --controller /dev/nvme1

# Use valgrind with run-test script
./run-test --valgrind
```

**Valgrind Configuration:**

- Suppression file: `scripts/test/valgrind-rocm.supp` (suppresses ROCm library
  false positives)
- Logs: `build/valgrind-logs/valgrind_*.log`
- Options can be configured in `CMakeLists.txt` via `MEMORYCHECK_COMMAND_OPTIONS`

**Disable Valgrind Integration:**
```bash
cmake -DENABLE_VALGRIND=OFF ..
```

### AddressSanitizer (ASan)

AddressSanitizer provides faster detection with better C++ support but requires
rebuilding.

**Build with AddressSanitizer:**
```bash
cd build
cmake -DENABLE_ASAN=ON ..
cmake --build .
```

**Run with ASan:**
```bash
# Use wrapper script
./scripts/test/run-asan.sh ./build/bin/xio-tester nvme-ep \
  --controller /dev/nvme1

# Or run directly (ASAN_OPTIONS will be set automatically)
./build/bin/xio-tester nvme-ep --controller /dev/nvme1
```

**ASan Logs:**
- Logs: `build/asan-logs/asan_*.log`
- ASan output is also printed to stderr

### Limitations and Notes

- **GPU Memory**: Neither valgrind nor ASan can directly track GPU device memory
  (`hipMalloc`, HSA allocations). Use `hipMemGetInfo()` or ROCm profiling tools
  to check device memory usage.

- **Performance**: Valgrind is significantly slower (10-50x), so use shorter test
  iterations when running with valgrind.

- **False Positives**: ROCm runtime libraries may show false positives. The
  suppression file (`valgrind-rocm.supp`) filters known issues.

- **ASan vs Valgrind**: ASan requires rebuilding but provides better C++ detection
  and is faster. Valgrind works on existing binaries but is slower.

- **Log Location**: Valgrind logs from CTest are in
  `build/Testing/Temporary/MemoryChecker.*.log`. Standalone wrapper logs are in
  `build/valgrind-logs/`.

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
rocm-xio because we do not want to have the delay that happens if a device
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
