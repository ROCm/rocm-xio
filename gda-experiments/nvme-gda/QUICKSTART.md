# NVMe GDA Quick Start Guide

## System Requirements

- AMD GPU with ROCm support
- Linux kernel 5.4+
- ROCm 5.0+ installed
- NVMe SSD
- Root access for kernel module loading

## Build and Install

### 1. Build Kernel Driver

```bash
cd nvme_gda_driver
make

# Find your NVMe device
lspci -nn | grep -i nvme
# Example output: 01:00.0 Non-Volatile memory controller [0108]: Samsung ...

# Load driver (replace with your PCI address)
sudo insmod nvme_gda.ko nvme_pci_dev=0000:01:00.0

# Verify device created
ls -l /dev/nvme_gda0

# Check kernel log
dmesg | tail -20
```

### 2. Build Userspace Library and Tests

```bash
cd ..
mkdir build && cd build
cmake ..
make -j$(nproc)
```

## Running Tests

### Test 1: Basic Doorbell Ring

This test verifies the GPU can access and write to NVMe doorbell registers:

```bash
./test_basic_doorbell
```

**Expected Output:**
```
NVMe GDA Device Info:
  BAR0: 0xf7400000 (size: 0x4000)
  Doorbell stride: 0
  Max queue entries: 4096
...
GPU: Old doorbell value: 0, New value: 1
✓ SUCCESS: GPU successfully rang the doorbell!
```

### Test 2: Full GPU I/O

This test performs actual NVMe read/write operations from GPU:

```bash
# Basic test (uses namespace 1, LBA 0x1000)
./test_gpu_io

# Custom parameters
./test_gpu_io /dev/nvme_gda0 1 0x2000
```

**Parameters:**
- Arg 1: Device path (default: `/dev/nvme_gda0`)
- Arg 2: Namespace ID (default: `1`)
- Arg 3: Start LBA (default: `0x1000`)

**Expected Output:**
```
=== GPU Write Test ===
GPU thread 0: Writing LBA 4096
GPU thread 1: Writing LBA 4097
...
Write results: 8/8 successful

=== GPU Read Test ===
GPU thread 0: Reading LBA 4096
...
Read results: 8/8 successful

=== Data Verification ===
Verification: 8/8 blocks correct

✓ ALL TESTS PASSED!
```

## Troubleshooting

### Driver Load Fails

**Problem:** `insmod: ERROR: could not insert module`

**Solutions:**
1. Check dmesg: `dmesg | tail -20`
2. Verify PCI address: `lspci -nn | grep -i nvme`
3. Check if another driver is using the device:
   ```bash
   lsmod | grep nvme
   # If nvme.ko is loaded, you may need to unbind it
   ```

### No /dev/nvme_gda0 Device

**Problem:** Device node not created

**Solutions:**
1. Check module loaded: `lsmod | grep nvme_gda`
2. Check kernel messages: `dmesg | grep nvme_gda`
3. Manually create device (if needed):
   ```bash
   MAJOR=$(awk '$2=="nvme_gda" {print $1}' /proc/devices)
   sudo mknod /dev/nvme_gda0 c $MAJOR 0
   sudo chmod 666 /dev/nvme_gda0
   ```

### GPU Can't Access Doorbell

**Problem:** Test fails with segfault or access error

**Solutions:**
1. **Check PCIe Topology**: GPU and NVMe must be on same PCIe switch
   ```bash
   lspci -tv
   # Look for GPU and NVMe under same root port
   ```

2. **IOMMU Issues**: May need to disable or configure IOMMU
   ```bash
   # Check IOMMU status
   dmesg | grep -i iommu
   
   # Disable IOMMU (TEMPORARY, for testing only)
   # Add to kernel boot parameters: iommu=off
   ```

3. **Memory Mapping**: Verify doorbell mapped correctly
   ```bash
   cat /proc/$(pgrep test_basic)/maps | grep nvme
   ```

### I/O Operations Fail

**Problem:** Commands posted but no completions

**Possible Causes:**
1. **Queue Not Initialized**: Driver creates queues but may not be fully initialized in controller
2. **DMA Address Issues**: NVMe controller can't access GPU memory
3. **Wrong Namespace ID**: Check available namespaces:
   ```bash
   sudo nvme list
   ```

## Advanced Usage

### Enable Tracing

```bash
# Enable ftrace for NVMe
echo 1 > /sys/kernel/debug/tracing/events/nvme/enable

# Run test
./test_gpu_io

# View trace
cat /sys/kernel/debug/tracing/trace
```

### Performance Benchmarking

```bash
# Use larger queue and more threads
# TODO: Create benchmark program

# Monitor NVMe stats
watch -n 1 'cat /sys/block/nvme0n1/stat'
```

### Integration with Existing Code

See `GDA_DOORBELL_ANALYSIS.md` for detailed explanation of the doorbell mechanism
and how to integrate with existing NVMe or storage projects.

## Safety Notes

⚠️ **IMPORTANT** ⚠️

1. **Backup Data**: This is experimental code that directly accesses NVMe hardware
2. **Test LBAs**: Use LBAs in safe regions (e.g., beyond 0x1000)
3. **Namespace Selection**: Ensure you're using a test namespace
4. **System Stability**: May crash system if PCIe topology is incorrect

## Cleaning Up

```bash
# Unload driver
sudo rmmod nvme_gda

# Clean build
cd build && make clean
```

## Next Steps

1. Review `GDA_DOORBELL_ANALYSIS.md` for technical details
2. Compare with MLX5 implementation in `rocSHMEM/src/gda/mlx5/`
3. Adapt for your specific use case (emulated NVMe, etc.)
4. Add your own GPU kernels using the API

## Getting Help

- Check `README.md` for architecture overview
- See `GDA_DOORBELL_ANALYSIS.md` for deep dive
- Review MLX5 GDA code in `rocSHMEM/` for reference patterns

