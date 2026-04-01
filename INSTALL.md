# Install guide for rocm-xio

## Quick Install Guide

rocm-xio depends on ROCm. Install ROCm and amdgpu-dkms as described in
the [ROCm quick start installation guide][rocm-install].

On Ubuntu 24.04, install the required packages:

```
sudo apt install rocm-hip-sdk rocminfo cmake \
  libdrm-dev libhsa-runtime-dev
```

If you want to build the ``xio-tester`` CLI tool (enabled
by default via ``BUILD_CLIENTS=ON``), also install:

```
sudo apt install libcli11-dev
```

Then build rocm-xio:

```
git clone https://github.com/ROCm/rocm-xio.git
cd rocm-xio
mkdir -p build
cmake -S . -B build
cmake --build build --target all
```

Verify the build by listing available endpoints:

```
./build/xio-tester --list-endpoints
```

Run a quick NVMe test (requires an NVMe device):

```
export HSA_FORCE_FINE_GRAIN_PCIE=1
sudo ./build/xio-tester nvme-ep \
  --controller /dev/nvme0 --read-io 50 --verbose
```

## Building rocm-xio

> [!NOTE]
> rocm-xio is early-access software that has undergone testing on limited
> hardware. It may not work on your system at this time.

Supported hardware:

* rocm-xio should work with the [GPUs that ROCm supports][rocm-gpus]
* Storage is currently limited to local NVMe drives
* rocm-xio has only been tested on AMD CPUs/systems

Supported compilers: amdclang++ (preferred), clang++, g++

Supported platforms: Linux

### Requirements

* CMake 3.21 or later
* ROCm HIP SDK
* HSA runtime libraries
* libdrm and libdrm\_amdgpu development packages

### Configure

| Option | Default | Purpose |
|--------|---------|---------|
| OFFLOAD\_ARCH | (auto) | GPU architecture |
| ROCM\_PATH | /opt/rocm | ROCm installation path |
| BUILD\_CLIENTS | ON | Build xio-tester (requires libcli11-dev) |
| XIO\_BUILD\_DOCS | OFF | Build documentation (Sphinx) |
| XIO\_DOCS\_ONLY | OFF | Docs-only build (no HIP) |
| INSTALL\_TESTER | OFF | Install xio-tester binary |

Sanitizer options (clang only):

| Option | Default | Purpose |
|--------|---------|---------|
| XIO\_USE\_SANITIZERS | OFF | address, leak, undefined |
| XIO\_USE\_THREAD\_SANITIZER | OFF | thread (incompatible with above) |
| XIO\_USE\_INTEGER\_SANITIZER | OFF | integer (clang only) |
| XIO\_USE\_CODE\_COVERAGE | OFF | coverage instrumentation |

### Build

```
cmake --build build
```

### Run tests

```
ctest --test-dir build
```

### Install and package

The default install prefix follows ROCm conventions (`/opt/rocm`).

```
cmake --install build
```

Custom install prefix:

```
cmake --install build --prefix /tmp/rocm-xio-test
```

### Documentation

Build the documentation with Sphinx + Breathe + Doxygen:

```
cmake -S . -B build -DXIO_BUILD_DOCS=ON
cmake --build build --target sphinx-html
```

Output appears in `build/docs/html/index.html`.

For full build details see [docs/building.rst](docs/building.rst).

[rocm-install]: https://rocm.docs.amd.com/projects/install-on-linux/en/latest/install/quick-start.html
[rocm-gpus]: https://rocm.docs.amd.com/projects/install-on-linux/en/latest/reference/system-requirements.html
