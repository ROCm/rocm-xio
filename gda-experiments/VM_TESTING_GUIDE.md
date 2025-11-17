# VM Testing Guide for GDA Experiments

This guide explains how to test the NVMe GDA implementation in your ROCm VM with both emulated and real NVMe devices.

## VM Environment Setup

### Prerequisites Checklist

```bash
# Check ROCm installation
rocminfo | grep "Name:" | head -5

# Check HIP
hipcc --version

# Check kernel version
uname -r

# Check NVMe devices
lspci | grep -i nvme
nvme list

# Check GPU
rocm-smi

# Check kernel headers
ls /lib/modules/$(uname -r)/build
```

## Testing Strategy

We'll test in three phases:
1. **Phase 1**: Emulated NVMe doorbell mapping
2. **Phase 2**: Real NVMe doorbell access (read-only)
3. **Phase 3**: Full I/O operations (if safe)

---

## Phase 1: Testing with Emulated NVMe

Your emulated NVMe environment is perfect for initial testing!

### Step 1: Build Everything

```bash
cd ~/Projects/rocm-axiio/gda-experiments/nvme-gda

# Build kernel driver
cd nvme_gda_driver
make clean
make

# Check if built successfully
ls -lh nvme_gda.ko

# Build userspace
cd ..
mkdir -p build && cd build
cmake ..
make -j$(nproc)

# Verify test programs built
ls -lh test_basic_doorbell test_gpu_io
```

### Step 2: Setup Emulated NVMe

```bash
# Check your emulated NVMe setup
# (Adjust based on your existing emulated NVMe configuration)

# List available NVMe devices
ls -l /dev/nvme*

# Get PCI address of emulated device
lspci -nn | grep -i nvme
# Example output: 00:04.0 Non-Volatile memory controller [0108]: ...

# Note the PCI address for next step
```

### Step 3: Load Driver (Emulated Mode)

```bash
cd ~/Projects/rocm-axiio/gda-experiments/nvme-gda/nvme_gda_driver

# Load driver with your emulated NVMe PCI address
# Replace 0000:00:04.0 with your actual address
sudo insmod nvme_gda.ko nvme_pci_dev=0000:00:04.0

# Check if loaded
lsmod | grep nvme_gda

# Check kernel messages
dmesg | tail -30

# Verify device created
ls -l /dev/nvme_gda0

# If device doesn't exist, create it manually
# MAJOR=$(awk '$2=="nvme_gda" {print $1}' /proc/devices)
# sudo mknod /dev/nvme_gda0 c $MAJOR 0
# sudo chmod 666 /dev/nvme_gda0
```

### Step 4: Run Basic Tests

```bash
cd ~/Projects/rocm-axiio/gda-experiments/nvme-gda/build

# Test 1: Basic doorbell access
echo "=== Test 1: Basic Doorbell Access ==="
./test_basic_doorbell

# Expected: Should map doorbells and test GPU access
# Look for: "✓ SUCCESS: GPU successfully rang the doorbell!"
```

### Step 5: Analyze Results

```bash
# Check kernel logs
dmesg | grep -E "(nvme_gda|GDA)" | tail -20

# If errors, check:
# 1. BAR0 mapping successful?
# 2. Doorbell stride detected?
# 3. Queue creation worked?
```

---

## Phase 2: Testing with Real NVMe (Read-Only)

**⚠️ CAUTION**: Start with read-only operations on real hardware!

### Step 1: Identify Safe Test Area

```bash
# List NVMe namespaces
sudo nvme list

# Get namespace info
sudo nvme id-ns /dev/nvme0n1 -H

# Identify a safe LBA range (far from used space)
# Good starting point: LBA 0x100000 (1M blocks in)

# Check used space
df -h | grep nvme
```

### Step 2: Load Driver on Real NVMe

```bash
# Get real NVMe PCI address
lspci -nn | grep -i "non-volatile"
# Example: 01:00.0 Non-Volatile memory controller [0108]: Samsung ...

# IMPORTANT: Backup before proceeding!
# This driver will bypass the normal nvme.ko driver

# Load driver
sudo insmod nvme_gda.ko nvme_pci_dev=0000:01:00.0

# Verify
ls -l /dev/nvme_gda0
dmesg | tail -20
```

### Step 3: Test Read-Only Operations

```bash
cd ~/Projects/rocm-axiio/gda-experiments/nvme-gda/build

# Test basic doorbell (safe, no I/O)
./test_basic_doorbell /dev/nvme_gda0

# For full I/O test, use READ-ONLY first
# Modify test_gpu_io.hip to skip writes initially
# Or specify a safe LBA range far from data

# Run with safe LBA (e.g., 0x100000)
# ./test_gpu_io /dev/nvme_gda0 1 0x100000
```

---

## Phase 3: Full I/O Testing (Advanced)

**⚠️ EXTREME CAUTION**: Only after read-only tests pass!

### Preparation

```bash
# Create a test namespace or use a spare NVMe
# OR use a small partition at the end of the device

# Example: Use last 1GB of device for testing
# Calculate: Total_LBAs - (1GB / block_size)

# Get block size
sudo nvme id-ns /dev/nvme0n1 | grep "lbaf"
# Typical: 512 bytes or 4096 bytes

# Calculate safe start LBA
# For 1TB device with 512B blocks:
# Total LBAs = 1TB / 512B = 2,147,483,648
# Safe start = 2,147,483,648 - (1GB/512B) = 2,145,386,496
```

### Full Test Execution

```bash
# Run full I/O test
./test_gpu_io /dev/nvme_gda0 1 0x100000

# Monitor during test
watch -n 1 'dmesg | tail -20'

# In another terminal
watch -n 1 'cat /sys/block/nvme0n1/stat'
```

---

## Integration with Emulated NVMe Tracing

### Trace GPU Doorbell Rings

Your emulated NVMe setup can now trace GPU-initiated doorbells!

```bash
# Enable NVMe tracing (adjust for your setup)
echo 1 > /sys/kernel/debug/tracing/events/nvme/enable

# Run GDA test
./test_basic_doorbell

# View trace
cat /sys/kernel/debug/tracing/trace | grep -i doorbell

# You should see GPU-initiated doorbell writes!
```

### Compare CPU vs GPU Paths

```bash
# 1. Traditional CPU-initiated I/O
fio --name=cpu_test --filename=/dev/nvme0n1 --rw=read \
    --bs=4k --iodepth=1 --numjobs=1 --time_based --runtime=10

# 2. GPU-initiated I/O
./test_gpu_io /dev/nvme_gda0 1 0x100000

# Compare traces to see the difference!
```

---

## Troubleshooting in VM

### Problem: Driver Won't Load

```bash
# Check if conflicting with nvme.ko
lsmod | grep nvme

# May need to unbind from default driver first
echo "0000:01:00.0" | sudo tee /sys/bus/pci/drivers/nvme/unbind

# Then load our driver
sudo insmod nvme_gda.ko nvme_pci_dev=0000:01:00.0
```

### Problem: GPU Can't Access Doorbells

```bash
# Check PCIe topology
lspci -tv

# Verify GPU and NVMe are visible
rocm-smi
lspci | grep -i nvme

# Check IOMMU
dmesg | grep -i iommu

# May need to disable IOMMU for testing
# Add to /etc/default/grub: GRUB_CMDLINE_LINUX="iommu=off"
# sudo update-grub && sudo reboot
```

### Problem: Permission Denied

```bash
# Ensure device permissions
sudo chmod 666 /dev/nvme_gda0

# Check if user in video/render groups
groups
# Add if needed: sudo usermod -a -G video,render $USER
```

### Problem: Segfault in Test

```bash
# Run with debugging
gdb ./test_basic_doorbell
(gdb) run
(gdb) bt  # backtrace when it crashes

# Check HSA initialization
export HSA_ENABLE_DEBUG=1
./test_basic_doorbell
```

---

## Performance Testing

### Latency Measurement

```bash
# Create a benchmark script
cat > bench_latency.sh << 'EOF'
#!/bin/bash
echo "CPU-mediated I/O:"
sudo nvme read /dev/nvme0n1 -s 0x1000 -c 0 -z 512 2>&1 | grep -i time

echo "GPU-direct I/O:"
./test_gpu_io /dev/nvme_gda0 1 0x1000 2>&1 | grep -i time
EOF

chmod +x bench_latency.sh
./bench_latency.sh
```

### Bandwidth Measurement

```bash
# Test with larger transfers
# Modify test_gpu_io.hip to transfer more blocks
# Compare with fio or dd

# CPU baseline
dd if=/dev/nvme0n1 of=/dev/null bs=4k count=10000 iflag=direct

# GPU (modify test to match transfer size)
./test_gpu_io /dev/nvme_gda0 1 0x1000
```

---

## VM-Specific Considerations

### Nested Virtualization

If running in a VM:

```bash
# Check if nested virt enabled
cat /sys/module/kvm_amd/parameters/nested  # AMD
cat /sys/module/kvm_intel/parameters/nested  # Intel

# Should be "Y" or "1"
```

### GPU Passthrough

For proper PCIe P2P:

```bash
# Verify GPU is passed through
lspci -nnk | grep -A 3 VGA

# Check if vfio-pci is used
lsmod | grep vfio
```

### Emulated vs Real Device

```bash
# Detect device type
sudo nvme id-ctrl /dev/nvme0 | grep -i "model\|serial"

# Emulated devices often have QEMU identifiers
```

---

## Data Collection for Analysis

### Trace Collection

```bash
# Collect comprehensive trace
sudo trace-cmd record -e nvme -e block -e amdgpu \
    ./test_gpu_io /dev/nvme_gda0 1 0x1000

# Analyze
trace-cmd report > gda_trace.txt
```

### Performance Counters

```bash
# Collect performance stats
sudo perf stat -e cycles,instructions,cache-misses,LLC-loads,LLC-load-misses \
    ./test_gpu_io /dev/nvme_gda0 1 0x1000
```

### System State

```bash
# Before test
rocm-smi > rocm_before.txt
cat /sys/block/nvme0n1/stat > nvme_before.txt

# Run test
./test_gpu_io /dev/nvme_gda0 1 0x1000

# After test
rocm-smi > rocm_after.txt
cat /sys/block/nvme0n1/stat > nvme_after.txt

# Analyze differences
diff rocm_before.txt rocm_after.txt
```

---

## Safety Checklist

Before any real hardware testing:

- [ ] Backed up important data
- [ ] Tested on emulated NVMe first
- [ ] Verified safe LBA ranges
- [ ] Using test/scratch namespace
- [ ] Kernel logs monitored
- [ ] Ready to force reboot if needed
- [ ] Understood the risks

---

## Next Steps

After successful testing:

1. **Document Results**: Create `TEST_RESULTS.md`
2. **Integrate with Tracing**: Add GDA hooks to existing trace tools
3. **Optimize**: Tune queue sizes, batch operations
4. **Extend**: Support multiple queues, multiple devices
5. **Productionize**: Add error handling, security

---

## Quick Reference Commands

```bash
# Load driver
sudo insmod nvme_gda.ko nvme_pci_dev=0000:XX:XX.X

# Unload driver
sudo rmmod nvme_gda

# Run basic test
./test_basic_doorbell /dev/nvme_gda0

# Run full I/O test
./test_gpu_io /dev/nvme_gda0 1 0x100000

# Check logs
dmesg | grep -i gda

# Monitor GPU
watch rocm-smi

# Monitor NVMe
watch 'cat /sys/block/nvme0n1/stat'
```

---

## Getting Help

If issues arise:
1. Check `QUICKSTART.md` for common problems
2. Review `GDA_DOORBELL_ANALYSIS.md` for technical details
3. Compare with MLX5 implementation in `rocSHMEM/`
4. Check kernel logs: `dmesg | grep -E "(nvme_gda|error)"`
5. Verify PCIe topology: `lspci -tv`

Good luck testing! 🚀


