# NVMe Hardware Testing Guide

This document explains how to test rocm-axiio with real NVMe hardware devices.

## Overview

rocm-axiio supports three modes of NVMe operation:

1. **Emulated Mode** - Software simulation (no hardware required)
2. **Real Hardware Mode** - Direct access to physical NVMe devices
3. **GPU-Direct Mode** - GPU-initiated NVMe I/O with P2P memory access

## Prerequisites

### Hardware Requirements

- **AMD GPU** with ROCm support (recommended: MI series or Radeon Pro)
- **NVMe SSD** (any PCIe NVMe device)
- **PCIe support** for GPU-NVMe P2P (optional, for GPU-direct mode)

### Software Requirements

```bash
# ROCm installation
sudo apt-get install rocm-hip-sdk

# Development tools
sudo apt-get install build-essential libcli11-dev pciutils

# For GPU-direct mode: kernel module
cd kernel-module && make && sudo insmod nvme_axiio.ko
```

## Testing Modes

### 1. Emulated Mode Testing

No special setup required - works out of the box:

```bash
# Build
make all

# Run emulated test
./bin/axiio-tester --endpoint nvme-ep --iterations 10
```

**Output:**
```
🎯 NVMe Endpoint Test (Emulated Mode)
✓ Initialization successful
✓ 10/10 iterations completed
⏱️  Average latency: 125.3 µs
```

### 2. Real Hardware Mode Testing

Requires physical NVMe device and driver unbinding:

#### Step 1: Identify NVMe Device

```bash
# List NVMe devices
lspci -nn | grep -i nvme

# Example output:
# 03:00.0 Non-Volatile memory controller [0108]: Samsung [144d:a80a]
```

#### Step 2: Get Device Information

```bash
# Get PCI address
PCI_ADDR="0000:03:00.0"

# Read NVMe BAR0 (registers)
sudo lspci -vvv -s $PCI_ADDR | grep "Memory at"

# Example: Memory at f7e00000 (64-bit, non-prefetchable) [size=16K]
BAR0_ADDR="0xf7e00000"
```

#### Step 3: Calculate Doorbell Address

```bash
# Read CAP register to get doorbell stride
sudo devmem $BAR0_ADDR 64

# Doorbell address = BAR0 + 0x1000 (standard offset)
DOORBELL_ADDR=$(printf "0x%x" $((BAR0_ADDR + 0x1000)))
```

#### Step 4: Unbind Driver

See [NVME_DRIVER_UNBINDING.md](NVME_DRIVER_UNBINDING.md) for details:

```bash
echo $PCI_ADDR | sudo tee /sys/bus/pci/drivers/nvme/unbind
```

#### Step 5: Run Test

```bash
./bin/axiio-tester --endpoint nvme-ep \
  --real-hardware \
  --pci-address $PCI_ADDR \
  --nvme-doorbell $DOORBELL_ADDR \
  --nvme-cap $(sudo devmem $BAR0_ADDR 64) \
  --iterations 10
```

#### Step 6: Rebind Driver

```bash
echo $PCI_ADDR | sudo tee /sys/bus/pci/drivers/nvme/bind
```

### 3. GPU-Direct Mode Testing

Enables GPU to directly ring NVMe doorbells without CPU intervention:

#### Requirements

- Kernel module loaded: `nvme_axiio.ko`
- HSA runtime for GPU P2P MMIO
- PCIe atomics support (check with `lspci -vvv`)

#### Test GPU-Direct

```bash
# Load kernel module
cd kernel-module
make
sudo insmod nvme_axiio.ko

# Run GPU-direct test
./bin/axiio-tester --endpoint nvme-ep \
  --real-hardware \
  --gpu-direct \
  --pci-address 0000:03:00.0 \
  --iterations 100
```

**Expected Output:**
```
🚀 GPU-Direct NVMe Mode
✓ Kernel module detected
✓ DMA buffer allocated: 0x12345000
✓ GPU doorbell mapping successful
✓ HSA P2P MMIO enabled
⚡ GPU-initiated doorbell rings: 100/100
⏱️  Average latency: 8.2 µs (vs 125µs CPU mode)
```

## Performance Testing

### Throughput Test

```bash
# High iteration count
./bin/axiio-tester --endpoint nvme-ep \
  --real-hardware \
  --iterations 10000 \
  --submit-queue-len 128
```

### Latency Test

```bash
# Single operation latency
./bin/axiio-tester --endpoint nvme-ep \
  --real-hardware \
  --iterations 1000 \
  --submit-queue-len 1
```

### Queue Depth Testing

```bash
# Test different queue sizes
for qd in 1 2 4 8 16 32 64 128; do
  echo "Queue depth: $qd"
  ./bin/axiio-tester --endpoint nvme-ep \
    --real-hardware \
    --submit-queue-len $qd \
    --complete-queue-len $qd \
    --iterations 100
done
```

## Automated Testing Scripts

### Using Test Scripts

```bash
# Local emulated testing
./scripts/test-nvme-local.sh

# QEMU testing
./scripts/test-nvme-qemu.sh

# Real hardware I/O testing
./scripts/test-nvme-io.sh --device /dev/nvme0n1

# Real hardware with custom parameters
./scripts/test-nvme-real-io.sh \
  --pci-address 0000:03:00.0 \
  --iterations 1000
```

## Physical Memory Mapping

For direct hardware access, rocm-axiio uses `/dev/mem`:

### Enable /dev/mem Access

```bash
# Check if accessible
ls -l /dev/mem

# Add user to kmem group (or use sudo)
sudo usermod -a -G kmem $USER
```

### Memory Mapping Process

```c
// Open /dev/mem
int fd = open("/dev/mem", O_RDWR | O_SYNC);

// Map NVMe BAR0
void *bar0 = mmap(NULL, 0x4000, PROT_READ | PROT_WRITE,
                  MAP_SHARED, fd, bar0_phys_addr);

// Access NVMe registers
volatile uint32_t *doorbell = (uint32_t*)((char*)bar0 + 0x1000);
*doorbell = queue_entry_index;  // Ring doorbell!
```

## WSL2 Testing

rocm-axiio supports WSL2 with emulated NVMe:

```bash
# In WSL2
./bin/axiio-tester --endpoint nvme-ep

# QEMU testing in WSL2
./scripts/test-nvme-qemu.sh
```

See [WSL_INSTALLATION.md](../WSL_INSTALLATION.md) for setup details.

## Troubleshooting

### Cannot Access /dev/mem

```bash
# Permission error
sudo chmod 666 /dev/mem  # Temporary, not recommended

# Better: add to kmem group
sudo usermod -a -G kmem $USER
newgrp kmem
```

### PCIe Access Errors

```bash
# Check IOMMU settings
dmesg | grep -i iommu

# May need to disable IOMMU for testing
# Add to kernel parameters: iommu=off
```

### GPU-Direct Not Working

```bash
# Check kernel module
lsmod | grep nvme_axiio

# Check DMA buffer
dmesg | grep axiio

# Verify HSA runtime
rocminfo | grep -A 5 "HSA Runtime"
```

### Doorbell Address Wrong

```bash
# Verify BAR0 address
sudo lspci -vvv -s 0000:03:00.0 | grep "Memory at"

# Read CAP register
sudo devmem <BAR0_ADDR> 64

# Doorbell should be BAR0 + 0x1000
```

## CI/CD Integration

GitHub Actions workflow for automated NVMe testing:

```yaml
- name: Test NVMe endpoint
  run: |
    ./bin/axiio-tester --endpoint nvme-ep --iterations 100
```

See `.github/workflows/test-nvme-axiio.yml` for complete CI configuration.

## Performance Expectations

### Emulated Mode
- **Latency**: 100-200 µs
- **Throughput**: Simulated, no actual I/O
- **Use case**: Development, CI/CD

### Real Hardware (CPU Mode)
- **Latency**: 10-50 µs (depends on SSD)
- **Throughput**: Varies by device
- **Use case**: Validation, benchmarking

### GPU-Direct Mode
- **Latency**: 5-15 µs (lower than CPU!)
- **Throughput**: Full NVMe bandwidth
- **Use case**: Production, GPU-accelerated storage

## Safety and Best Practices

### ⚠️ Important Warnings

1. **Backup Data**: Always backup before hardware testing
2. **Not Boot Drive**: Never test on your boot NVMe
3. **Unmount First**: Ensure no mounted filesystems
4. **Start with Emulation**: Test in emulated mode first
5. **Use QEMU**: Safe alternative to real hardware

### Recommended Workflow

```bash
# 1. Test in emulated mode
./bin/axiio-tester --endpoint nvme-ep

# 2. Test with QEMU
./scripts/test-nvme-qemu.sh

# 3. Only then test real hardware
./scripts/test-nvme-real-io.sh --device /dev/nvme1n1
```

## Advanced Topics

### DMA Buffer Allocation

GPU-direct mode uses kernel module for DMA buffers:

```bash
# Module parameters
sudo modprobe nvme_axiio debug=1

# Check allocated buffers
cat /sys/kernel/debug/nvme_axiio/buffers
```

### IOVA Mappings

For emulated NVMe with GPU access:

```bash
# IOVA mapping allows GPU to access emulated storage
./bin/axiio-tester --endpoint nvme-ep --emulated-with-iova
```

### HSA Memory Locking

Validate P2P memory operations:

```bash
# Enable HSA tracing
HSA_TOOLS_LIB=libhsa-runtime-tools64.so.1 \
  ./bin/axiio-tester --endpoint nvme-ep --gpu-direct
```

## References

- [NVMe Specification](https://nvmexpress.org/specifications/)
- [ROCm Documentation](https://rocm.docs.amd.com/)
- [NVME_DRIVER_UNBINDING.md](NVME_DRIVER_UNBINDING.md)
- [NVME_TESTING_SUMMARY.md](NVME_TESTING_SUMMARY.md)
- [Project README](../README.md)

## Quick Command Reference

```bash
# Emulated test
./bin/axiio-tester --endpoint nvme-ep

# Real hardware test
./bin/axiio-tester --endpoint nvme-ep --real-hardware \
  --pci-address 0000:03:00.0 --nvme-doorbell 0xf7e01000

# GPU-direct test
./bin/axiio-tester --endpoint nvme-ep --gpu-direct \
  --real-hardware --pci-address 0000:03:00.0

# Performance test
./scripts/test-nvme-io.sh --iterations 10000

# QEMU test
./scripts/test-nvme-qemu.sh
```

