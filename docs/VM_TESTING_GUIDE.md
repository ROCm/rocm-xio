# VM Testing Guide for ROCm AxIIO

This guide provides instructions for building and testing ROCm AxIIO in a
VM environment with GPU passthrough, real NVMe, and emulated NVMe devices.

## Quick Start

### Interactive Menu (Easiest)

```bash
./quick-test.sh
```

This launches an interactive menu with common testing scenarios:
- Clean build
- Test with emulated endpoint
- Test with real NVMe
- Test with emulated NVMe  
- CPU-only testing
- System checks
- Performance benchmarks

### Automated Build Script

The `build-and-test.sh` script provides flexible command-line options:

```bash
# Clean build only
./build-and-test.sh

# Build and test with emulated endpoint
./build-and-test.sh --test emulated

# Build and test with real NVMe
./build-and-test.sh --test real --nvme /dev/nvme0 --iterations 100

# Build and test with emulated NVMe
./build-and-test.sh --test emulated-nvme --nvme /dev/nvme1

# CPU-only mode (no GPU atomics needed)
./build-and-test.sh --test cpu-only --nvme /dev/nvme0 --verbose

# Specify GPU architecture explicitly
./build-and-test.sh --arch gfx1100 --test real --nvme /dev/nvme0

# Skip clean step (faster iteration)
./build-and-test.sh --no-clean --test emulated

# GPU-direct mode is always used (CPU-hybrid mode removed)
```

## VM Environment Setup

### Prerequisites

Your VM should have:

1. **GPU Passthrough (VFIO)**
   - AMD GPU passed through to VM
   - PCIe atomics enabled: `atomics=on` in QEMU/libvirt config

2. **NVMe Devices**
   - Real NVMe SSD (typically `/dev/nvme0`)
   - Emulated NVMe SSD via QEMU (typically `/dev/nvme1`)
   - IOVA mapping support for emulated devices

3. **ROCm Installation**
   ```bash
   # Should already be installed in VM
   which hipcc
   rocminfo
   ```

### Environment Variables

The build scripts automatically set this, but for manual testing:

```bash
export HSA_FORCE_FINE_GRAIN_PCIE=1
```

Make it permanent:
```bash
echo 'export HSA_FORCE_FINE_GRAIN_PCIE=1' >> ~/.bashrc
source ~/.bashrc
```

## Device Detection

### Check Your NVMe Devices

```bash
# List all NVMe devices
ls -l /dev/nvme*

# Get detailed info (requires nvme-cli)
sudo nvme list

# Check device sizes
lsblk | grep nvme
```

Typically in a VM:
- `/dev/nvme0` - Real NVMe SSD (passed through)
- `/dev/nvme1` - Emulated NVMe SSD (QEMU)

### Check GPU Configuration

```bash
# Check GPU detection
rocminfo | grep -i "name\|gfx"

# Check PCIe atomics (must show "ReqEn+")
lspci -vvv | grep -i atomic

# Find GPU PCIe address
lspci | grep -i "amd\|radeon"
```

### Verify PCIe Atomics

The test program includes automatic PCIe atomics checking:

```bash
./bin/axiio-tester -e
```

If atomics are not enabled, you'll see a detailed error message with
fix instructions. The most common fix is to add `atomics=on` to your
VM's GPU passthrough configuration.

## Testing Scenarios

### 1. Emulated Endpoint (No Hardware)

Tests the AxIIO framework without any real hardware.

```bash
./build-and-test.sh --test emulated --iterations 1000 --verbose
```

**Use case**: Quick functionality testing, CI/CD, development

### 2. Real NVMe Testing

Tests GPU-direct I/O to a real NVMe SSD.

```bash
./build-and-test.sh --test real --nvme /dev/nvme0 --iterations 100 \
    --verbose
```

**Use case**: Production testing, performance validation

**Requirements**:
- Root/sudo access
- PCIe atomics enabled
- HSA_FORCE_FINE_GRAIN_PCIE=1

### 3. Emulated NVMe Testing

Tests with QEMU-emulated NVMe device (supports IOVA mapping).

```bash
./build-and-test.sh --test emulated-nvme --nvme /dev/nvme1 \
    --iterations 100 --verbose
```

**Use case**: Development, testing without risking real SSD data

### 4. CPU-Only Mode

CPU generates NVMe commands; GPU is optional.

```bash
./build-and-test.sh --test cpu-only --nvme /dev/nvme0 --iterations 100 \
    --verbose
```

**Use case**: 
- Systems without PCIe atomics
- Debugging GPU issues
- Baseline performance comparison

## Build Options

### GPU Architecture

Auto-detected by default, but can be specified:

```bash
# RX 7000 series (RDNA3)
./build-and-test.sh --arch gfx1100

# RX 6000 series (RDNA2)
./build-and-test.sh --arch gfx1030

# MI300X
./build-and-test.sh --arch gfx942
```

### Doorbell Mode

**GPU-Direct Mode** (always enabled, CPU-hybrid mode removed):
- GPU writes directly to NVMe doorbell registers
- Lowest latency (< 1 μs)
- Requires HSA memory locking and kernel module exclusive mode

**Note**: If GPU-direct mode is not available, the program will fail with a clear error message. CPU-hybrid mode has been removed to simplify the codebase.

## Troubleshooting

### PCIe Atomics Not Enabled

**Symptom**: Test fails with atomics error

**Solution**:
1. Shut down VM
2. Edit VM configuration to add `atomics=on`:
   
   For QEMU command line:
   ```
   -device vfio-pci,host=XX:XX.X,atomics=on
   ```
   
   For libvirt XML:
   ```xml
   <hostdev mode='subsystem' type='pci' managed='yes'>
     <driver>
       <atomics mode='on'/>
     </driver>
   </hostdev>
   ```
3. Restart VM

**Workaround**: Use CPU-only mode
```bash
./build-and-test.sh --test cpu-only --nvme /dev/nvme0
```

### GPU Not Detected

**Check**:
```bash
rocminfo
lspci | grep -i amd
```

**Common causes**:
- GPU not passed through correctly
- VFIO driver not loaded
- Incorrect IOMMU groups

### NVMe Device Access Denied

**Symptom**: Permission denied on `/dev/nvme*`

**Solution**: Tests need root privileges for direct device access
```bash
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 -n 10
```

The build scripts handle this automatically.

### Build Failures

**Check dependencies**:
```bash
which hipcc
which rocminfo
dpkg -l | grep libcli11-dev
```

**Install missing packages**:
```bash
sudo apt install rocm-hip-sdk rocminfo libcli11-dev
```

## Performance Benchmarking

### Quick Benchmark

```bash
./build-and-test.sh --test real --nvme /dev/nvme0 --iterations 10000
```

### Detailed Histogram

```bash
# Build first
./build-and-test.sh

# Run benchmark with histogram
sudo bash -c "export HSA_FORCE_FINE_GRAIN_PCIE=1; \
    ./bin/axiio-tester --nvme-device /dev/nvme0 -n 10000 --histogram"
```

### Compare CPU vs GPU

```bash
# GPU mode
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 -n 10000 --histogram

# CPU mode
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 -n 10000 --histogram \
    --cpu-only
```

## Advanced Testing

### With Kernel Module

If you have the `nvme-axiio` kernel module:

```bash
# Load module
sudo modprobe nvme-axiio

# Test with kernel module support
sudo bash -c "export HSA_FORCE_FINE_GRAIN_PCIE=1; \
    ./bin/axiio-tester --nvme-device /dev/nvme0 --use-kernel-module \
    --nvme-queue-id 63 -n 1000 --verbose"
```

### Data Integrity Testing

```bash
sudo ./bin/axiio-tester \
    --nvme-device /dev/nvme0 \
    --use-data-buffers \
    --data-buffer-size 1048576 \
    --test-pattern random \
    --iterations 1000 \
    --verbose
```

### Different Access Patterns

```bash
# Random I/O
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 \
    --access-pattern random -n 10000

# Sequential I/O
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 \
    --access-pattern sequential -n 10000
```

## Manual Build (Without Scripts)

If you prefer manual control:

```bash
# Clean
make clean

# Build with auto-detected GPU
make -j$(nproc) all

# Build for specific GPU
make OFFLOAD_ARCH=gfx1100 -j$(nproc) all

# Test
export HSA_FORCE_FINE_GRAIN_PCIE=1
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 -n 100 --verbose
```

## Development Workflow

### Fast Iteration

```bash
# First build
./build-and-test.sh

# Make code changes...

# Quick rebuild and test (skip clean)
./build-and-test.sh --no-clean --test emulated

# Or rebuild specific test
./build-and-test.sh --no-clean --test real --nvme /dev/nvme0
```

### Check Code Format

```bash
# Check formatting (matches CI)
make lint

# Auto-fix formatting
make format
```

## CI/CD Integration

The build scripts can be used in CI pipelines:

```bash
# Non-interactive build and test
./build-and-test.sh --test emulated --iterations 1000 2>&1 | tee build.log

# Check exit code
if [ $? -eq 0 ]; then
    echo "Build and test passed"
else
    echo "Build and test failed"
    exit 1
fi
```

## Getting Help

### Script Help

```bash
./build-and-test.sh --help
```

### Test Program Help

```bash
./bin/axiio-tester --help
```

### List Available Endpoints

```bash
./bin/axiio-tester -e
```

## Summary

**Easiest**: Use `./quick-test.sh` for interactive menu

**Flexible**: Use `./build-and-test.sh` with command-line options

**Manual**: Use `make` and `./bin/axiio-tester` directly

All approaches support your VM environment with GPU, real NVMe,
and emulated NVMe testing.






