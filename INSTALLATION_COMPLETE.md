# ROCm Installation Complete ✅

## Installation Summary

**Date**: November 6, 2025  
**System**: Ubuntu 24.04 (Noble) on WSL2  
**ROCm Version**: 6.2.0  
**Status**: ✅ Successfully Installed and Built

## What Was Installed

### ROCm Packages
- ✅ `rocm-hip-sdk` (6.2.0) - HIP development toolkit
- ✅ `rocminfo` (1.0.0.60200) - GPU information tool
- ✅ `hipcc` (1.1.1.60200) - HIP compiler
- ✅ `libcli11-dev` - Command line parser
- ✅ `libstdc++-14-dev` - C++ standard library headers
- ✅ `g++` - GNU C++ compiler

### Installation Location
- **ROCm Base**: `/opt/rocm-6.2.0/`
- **Binaries**: `/usr/bin/hipcc`, `/usr/bin/rocminfo`
- **Libraries**: `/opt/rocm-6.2.0/lib/`

## Build Results

### rocm-axiio Build
- ✅ **Library**: `lib/librocm-axiio.a` (315 KB)
- ✅ **Binary**: `bin/axiio-tester` (679 KB)
- ✅ **Built for**: gfx1100 (RDNA3 architecture)
- ✅ **All Endpoints**: nvme-ep, rdma-ep, sdma-ep, test-ep

### Build Command Used
```bash
make OFFLOAD_ARCH=gfx1100 all
```

## Verification

### Compiler Verification
```bash
$ which hipcc
/usr/bin/hipcc

$ hipcc --version
HIP version: 6.2.41133-dd7f95766
AMD clang version 18.0.0git
Target: x86_64-unknown-linux-gnu
```

### Binary Verification
```bash
$ ./bin/axiio-tester -e
Available endpoints:
  nvme-ep - NVMe endpoint skeleton
  rdma-ep - RDMA endpoint with multi-vendor support
  sdma-ep - AMD SDMA Engine endpoint
  test-ep - Test endpoint for development/testing
```

## WSL-Specific Configuration Applied

1. **Repository Priority Set**: ROCm repo prioritized over Ubuntu repos
   - File: `/etc/apt/preferences.d/rocm-pin-600`
   - Priority: 600 (higher than default 500)

2. **Explicit GPU Architecture**: Required for WSL builds
   - Used: `OFFLOAD_ARCH=gfx1100`
   - Reason: GPU auto-detection doesn't work in WSL

3. **Additional Dependencies**: Installed for ROCm clang compatibility
   - `libstdc++-14-dev` - C++ standard library headers
   - `g++` - GNU C++ compiler

## Known WSL Limitations

### Expected Behaviors

✅ **Build Works**: Code compiles successfully  
✅ **Binary Runs**: Tester executes and lists endpoints  
⚠️ **HSA Init Fails**: Normal in WSL without GPU passthrough

```
Error: hsa_init() failed: 4104
Warning: HSA initialization failed. GPU doorbell will not work.
```

This is **expected and normal** in WSL without GPU hardware access.

### To Use GPU in WSL

Requires:
1. Windows 11 with WSL2
2. AMD GPU with Windows drivers installed
3. GPU passthrough enabled (automatic in Win11)
4. Set environment: `export HSA_FORCE_FINE_GRAIN_PCIE=1`

## Quick Commands

### Rebuild
```bash
cd /home/stebates/Projects/rocm-axiio
make clean
make OFFLOAD_ARCH=gfx1100 all
```

### Test (Emulated - No GPU Required)
```bash
./bin/axiio-tester -n 10 --verbose
```

### Test with NVMe (CPU-Only)
```bash
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 --cpu-only -n 10
```

### Test with GPU (Requires GPU Passthrough)
```bash
export HSA_FORCE_FINE_GRAIN_PCIE=1
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 -n 100 --verbose
```

## Build for Different GPUs

```bash
# RDNA3 (RX 7000 series)
make OFFLOAD_ARCH=gfx1100 all

# RDNA2 (RX 6000 series)
make OFFLOAD_ARCH=gfx1030 all

# CDNA2 (MI200 series)
make OFFLOAD_ARCH=gfx90a all

# CDNA3 (MI300 series)
make OFFLOAD_ARCH=gfx942 all
```

## Documentation

- **Full README**: [README.md](README.md)
- **WSL Guide**: [WSL_INSTALLATION.md](WSL_INSTALLATION.md)
- **Quick Start**: [QUICK_START.md](QUICK_START.md)
- **Update Summary**: [README_UPDATE_SUMMARY.md](README_UPDATE_SUMMARY.md)

## Troubleshooting

### Problem: "Timeout querying rocminfo"
**Solution**: Always use `OFFLOAD_ARCH=gfxXXXX` in WSL

### Problem: "cmath file not found"
**Solution**: Install `libstdc++-14-dev` (already done ✅)

### Problem: Package conflicts
**Solution**: Repository priority set correctly (already done ✅)

## Next Steps

1. **Test emulated mode**: `./bin/axiio-tester -n 10 --verbose`
2. **Check for NVMe devices**: `ls -l /dev/nvme*`
3. **Try CPU-only mode**: If you have NVMe access
4. **Enable GPU passthrough**: For actual GPU testing (requires Windows 11 + AMD GPU)

## System Information

```
OS: Ubuntu 24.04.3 LTS (Noble)
Kernel: 6.6.87.2-microsoft-standard-WSL2
ROCm: 6.2.0
hipcc: 18.0.0git
Build Date: November 6, 2025
Build Host: WSL2
```

## Status: ✅ Ready to Use

The rocm-axiio library is successfully built and ready for:
- ✅ Development and testing (emulated mode)
- ✅ CPU-only NVMe operations
- ⏳ GPU-accelerated operations (requires GPU passthrough setup)

---

For questions or issues, refer to:
- Main documentation: [README.md](README.md)
- WSL-specific guide: [WSL_INSTALLATION.md](WSL_INSTALLATION.md)

