# ROCm Installation Guide for WSL2

This guide covers installing ROCm on Windows Subsystem for Linux 2 (WSL2) for building rocm-axiio.

## Prerequisites

- **Windows 11** with WSL2 enabled
- **Ubuntu 24.04** (or 22.04) in WSL2
- (Optional) AMD GPU with Windows drivers for actual GPU execution

## Installation Steps

### 1. Add ROCm Repository

```bash
# Download and install ROCm GPG key
wget https://repo.radeon.com/rocm/rocm.gpg.key -O - | gpg --dearmor | sudo tee /etc/apt/keyrings/rocm.gpg > /dev/null

# Add ROCm repository (Ubuntu 24.04 Noble)
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/6.2 noble main" | sudo tee /etc/apt/sources.list.d/rocm.list

# For Ubuntu 22.04 Jammy, use:
# echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/6.2 jammy main" | sudo tee /etc/apt/sources.list.d/rocm.list
```

### 2. Set ROCm Repository Priority

Create apt preferences to prioritize ROCm packages over Ubuntu packages:

```bash
cat << 'EOF' | sudo tee /etc/apt/preferences.d/rocm-pin-600
Package: *
Pin: release o=repo.radeon.com
Pin-Priority: 600
EOF
```

### 3. Update Package Lists

```bash
sudo apt update
```

### 4. Install ROCm and Dependencies

```bash
sudo apt install -y rocm-hip-sdk rocminfo libcli11-dev g++ libstdc++-14-dev
```

### 5. Verify Installation

```bash
# Check hipcc is installed
which hipcc
hipcc --version

# Check rocminfo (will show HSA error in WSL without GPU - this is normal)
which rocminfo
```

Expected output for hipcc:
```
/usr/bin/hipcc
HIP version: 6.2.41133-dd7f95766
AMD clang version 18.0.0git
...
```

### 6. Build rocm-axiio

Since WSL cannot auto-detect GPU architecture, you must specify it explicitly:

```bash
cd /home/stebates/Projects/rocm-axiio

# Clean previous build
make clean

# Build with explicit GPU architecture
# Choose the architecture matching your GPU:
make OFFLOAD_ARCH=gfx1100 all    # For RDNA3 (RX 7000 series)
# OR
make OFFLOAD_ARCH=gfx1030 all    # For RDNA2 (RX 6000 series)
# OR
make OFFLOAD_ARCH=gfx90a all     # For MI200 series
# OR
make OFFLOAD_ARCH=gfx942 all     # For MI300 series
```

### 7. Verify Build

```bash
ls -lh bin/axiio-tester lib/librocm-axiio.a

# Test the binary (list endpoints)
./bin/axiio-tester -e
```

## Common GPU Architectures

| GPU Series | Architecture | OFFLOAD_ARCH Value |
|-----------|--------------|-------------------|
| RX 7900 XT/XTX (RDNA3) | Navi 31 | `gfx1100` |
| RX 7800 XT (RDNA3) | Navi 32 | `gfx1101` |
| RX 7700 XT (RDNA3) | Navi 33 | `gfx1102` |
| RX 6900 XT (RDNA2) | Navi 21 | `gfx1030` |
| RX 6800 (RDNA2) | Navi 21 | `gfx1030` |
| Radeon VII (GCN 5.1) | Vega 20 | `gfx906` |
| MI300X/MI300A | CDNA 3 | `gfx942` |
| MI250X/MI250 | CDNA 2 | `gfx90a` |
| MI210/MI200 | CDNA 2 | `gfx90a` |
| MI100 | CDNA 1 | `gfx908` |

## WSL-Specific Notes

### HSA Initialization Errors

When running in WSL without GPU passthrough, you'll see:

```
Error: hsa_init() failed: 4104
Warning: HSA initialization failed. GPU doorbell will not work.
Continuing anyway (may fall back to CPU-hybrid mode)...
```

**This is normal and expected.** The code is built correctly; GPU functionality requires:
1. AMD GPU hardware
2. AMD GPU driver installed on Windows host
3. GPU passthrough configured in WSL2

### GPU Passthrough (Optional)

To use actual GPU hardware in WSL2:

1. **Install AMD GPU drivers on Windows** (Windows 11 required)
2. **Enable GPU passthrough** - Should work automatically on Windows 11
3. **Verify GPU access in WSL:**
   ```bash
   # This should show GPU info if passthrough is working
   rocminfo
   ```

### Building Without GPU

The code builds successfully in WSL even without GPU hardware. You're compiling for a target architecture that will run on actual hardware later.

## Troubleshooting

### Issue: "Timeout querying rocminfo"

**Cause**: Makefile trying to auto-detect GPU architecture

**Solution**: Always specify `OFFLOAD_ARCH` explicitly:
```bash
make OFFLOAD_ARCH=gfx1100 all
```

### Issue: "cmath file not found"

**Cause**: Missing C++ standard library headers

**Solution**: Install libstdc++-dev:
```bash
sudo apt install -y libstdc++-14-dev g++
```

### Issue: Version conflicts between Ubuntu and ROCm packages

**Cause**: Ubuntu 24.04 includes some ROCm packages that conflict with ROCm 6.2

**Solution**: Set ROCm repository priority (Step 2 above)

### Issue: "rocminfo shows HSA_STATUS_ERROR_OUT_OF_RESOURCES"

**Cause**: No GPU hardware available in WSL

**Solution**: This is normal. The build still works. For actual GPU testing, you need GPU passthrough.

## Testing in WSL

### Emulated Testing (No GPU Required)

```bash
# Test with emulated endpoint
./bin/axiio-tester -n 10 --verbose
```

### CPU-Only Mode (No GPU Required)

If you have an NVMe device accessible in WSL:

```bash
# List NVMe devices
ls -l /dev/nvme*

# Test with CPU-only mode
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 --cpu-only -n 10
```

### GPU Mode (Requires GPU Passthrough)

With GPU passthrough enabled and AMD GPU available:

```bash
export HSA_FORCE_FINE_GRAIN_PCIE=1
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 -n 100 --verbose
```

## Environment Variables

For Radeon GPUs (when GPU is available):

```bash
# Set for current session
export HSA_FORCE_FINE_GRAIN_PCIE=1

# Make permanent
echo 'export HSA_FORCE_FINE_GRAIN_PCIE=1' >> ~/.bashrc
source ~/.bashrc
```

## Summary of WSL-Specific Commands

```bash
# Complete installation from scratch
wget https://repo.radeon.com/rocm/rocm.gpg.key -O - | gpg --dearmor | sudo tee /etc/apt/keyrings/rocm.gpg > /dev/null
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/6.2 noble main" | sudo tee /etc/apt/sources.list.d/rocm.list
cat << 'EOF' | sudo tee /etc/apt/preferences.d/rocm-pin-600
Package: *
Pin: release o=repo.radeon.com
Pin-Priority: 600
EOF
sudo apt update
sudo apt install -y rocm-hip-sdk rocminfo libcli11-dev g++ libstdc++-14-dev

# Build rocm-axiio
cd /home/stebates/Projects/rocm-axiio
make clean
make OFFLOAD_ARCH=gfx1100 all  # Adjust for your GPU

# Test
./bin/axiio-tester -e
./bin/axiio-tester -n 10 --verbose
```

## Additional Resources

- [ROCm Documentation](https://rocm.docs.amd.com/)
- [WSL GPU Support](https://learn.microsoft.com/en-us/windows/wsl/tutorials/gpu-compute)
- [rocm-axiio Main README](README.md)
- [rocm-axiio Quick Start](QUICK_START.md)

