# VM Launch for GDA Testing - Quick Guide

## What's Set Up

Two scripts to automate the entire test:

### 1. `run-gda-test-vm.sh` (Run on HOST)
Launches VM with:
- ✓ QEMU 10.1.2 from /opt/qemu-10.1.2
- ✓ 1 Emulated NVMe with NVME_TRACE=all
- ✓ AMD GPU passthrough (auto-detected)
- ✓ Real NVMe passthrough (auto-detected)
- ✓ gda-experiments directory mounted at /mnt/host
- ✓ Trace output to /tmp/nvme-gda-trace.log

### 2. `in-vm-gda-test.sh` (Run INSIDE VM)
Automated test sequence:
1. Mounts host filesystem
2. Builds GDA kernel driver
3. Builds userspace library and tests
4. Unbinds emulated NVMe from standard driver
5. Loads GDA driver
6. Runs doorbell test
7. Analyzes trace output

## Quick Start

### On Host Machine:

```bash
cd ~/Projects/rocm-axiio/gda-experiments

# Launch VM (auto-detects GPU and NVMe)
./run-gda-test-vm.sh
```

### Inside VM (after boot):

```bash
# One command to run all tests!
/mnt/host/gda-experiments/in-vm-gda-test.sh
```

## Manual Testing (if you want more control)

### Inside VM:

```bash
# Mount host filesystem
sudo mkdir -p /mnt/host
sudo mount -t 9p -o trans=virtio,version=9p2000.L hostfs /mnt/host

# Go to project
cd /mnt/host/gda-experiments/nvme-gda

# Build driver
cd nvme_gda_driver && make

# Build tests
cd .. && mkdir build && cd build && cmake .. && make

# Find emulated NVMe (QEMU device)
lspci -nn | grep "1b36:0010"
# Example: 00:03.0 Non-Volatile memory controller [0108]: Red Hat, Inc. QEMU NVM Express Controller [1b36:0010]

# Unbind from nvme
echo "0000:00:03.0" | sudo tee /sys/bus/pci/drivers/nvme/unbind

# Load GDA driver
sudo insmod nvme_gda_driver/nvme_gda.ko nvme_pci_dev=0000:00:03.0

# Verify device
ls -l /dev/nvme_gda0

# Run test
./build/test_basic_doorbell /dev/nvme_gda0

# Check traces
tail -50 /tmp/nvme-gda-trace.log
```

## Expected Output

### From `test_basic_doorbell`:
```
NVMe GDA Device Info:
  Vendor ID: 0x1b36
  Device ID: 0x0010
  BAR0: 0x... (size: 16384 bytes)
...
GPU: Old doorbell value: 0, New value: 1
✓ SUCCESS: GPU successfully rang the doorbell!
```

### From trace file:
```
pci_nvme_mmio_doorbell_sq: doorbell=0, sqid=1, val=1
pci_nvme_mmio_doorbell_cq: doorbell=0, cqid=1, val=0
...
```

## Troubleshooting

### VM won't start
```bash
# Check if devices can be bound to vfio-pci
lspci -k | grep -A 3 "VGA\|NVMe"

# Manually bind if needed
sudo modprobe vfio-pci
echo "VENDOR DEVICE" | sudo tee /sys/bus/pci/drivers/vfio-pci/new_id
```

### Can't find emulated NVMe in VM
```bash
# List all NVMe
lspci -nn | grep -i nvme

# QEMU emulated NVMe has vendor ID 1b36:0010
# Real hardware has vendor IDs like 144d (Samsung), 15b7 (Sandisk), etc.
```

### Driver won't load
```bash
# Check kernel logs
sudo dmesg | tail -30

# Check if conflicting
lsmod | grep nvme

# Unbind first
echo "0000:XX:XX.X" | sudo tee /sys/bus/pci/drivers/nvme/unbind
```

### No /dev/nvme_gda0
```bash
# Create manually
MAJOR=$(awk '$2=="nvme_gda" {print $1}' /proc/devices)
sudo mknod /dev/nvme_gda0 c $MAJOR 0
sudo chmod 666 /dev/nvme_gda0
```

### Test fails with segfault
```bash
# Check PCIe topology
lspci -tv

# Verify GPU is visible
rocminfo | grep "Name:"

# Check HSA
export HSA_ENABLE_DEBUG=1
```

## What to Look For in Traces

### GPU-Initiated Doorbell Rings

When GPU rings doorbell, you should see:
```
pci_nvme_mmio_doorbell_sq: doorbell ring from GPU thread
```

Compare with CPU-initiated (from standard nvme driver):
```
pci_nvme_mmio_doorbell_sq: doorbell ring from CPU
```

The trace will show the exact same hardware operation, but initiated from different sources!

### Timing Analysis

```bash
# Extract doorbell timings
grep doorbell_sq /tmp/nvme-gda-trace.log | head -20

# Compare GPU vs CPU latency
```

## VM Escape

To exit QEMU:
- Press: `Ctrl-A` then `X`

Or from another terminal:
```bash
sudo pkill qemu-system
```

## Trace File Location

- **Host**: Check if running: `tail -f /tmp/nvme-gda-trace.log`
- **Inside VM**: Same file (if host FS mounted)

The trace file is on the HOST, so it persists after VM shutdown.

## Advanced: Multiple Tests

```bash
# Inside VM, run multiple tests
cd /mnt/host/gda-experiments/nvme-gda/build

# Test 1: Basic doorbell
./test_basic_doorbell /dev/nvme_gda0

# Test 2: Full I/O (if you want to try)
# WARNING: Use safe LBA range!
./test_gpu_io /dev/nvme_gda0 1 0x1000

# Each test will generate traces
```

## Data Collection

After testing:

```bash
# On host
cd ~/Projects/rocm-axiio/gda-experiments

# Copy trace for analysis
cp /tmp/nvme-gda-trace.log ./gda-test-trace-$(date +%Y%m%d-%H%M%S).log

# Analyze
grep -i "doorbell" gda-test-trace-*.log | wc -l
```

## Success Criteria

✓ Driver loads without errors
✓ /dev/nvme_gda0 created
✓ GPU can read/write doorbell register
✓ Trace shows doorbell operations
✓ test_basic_doorbell passes

## Next Steps After Success

1. Run full I/O test
2. Compare trace patterns with CPU-initiated I/O
3. Measure latency differences
4. Integrate with your emulated NVMe tracing work

## Quick Commands

```bash
# Launch VM
./run-gda-test-vm.sh

# In VM, run all tests
/mnt/host/gda-experiments/in-vm-gda-test.sh

# Exit VM
Ctrl-A, then X
```

Good luck! 🚀


