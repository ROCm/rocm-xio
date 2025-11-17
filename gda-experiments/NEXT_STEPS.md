# VM is Running - Next Steps

## VM Status

✅ VM Launched with:
- GPU: AMD Radeon RX 9070 (0000:10:00.0)
- Real NVMe: Sandisk WD Black SN850X (0000:c2:00.0)  
- Emulated NVMe: 1x with NVME_TRACE=all
- Trace file: /tmp/nvme-gda-trace.log
- Mounted: /home/stebates/Projects/rocm-axiio

## Connect to VM

```bash
# SSH into the VM (wait ~30 seconds for boot)
ssh -p 2222 ubuntu@localhost

# Password: (your ubuntu user password)
```

## Inside VM - Run GDA Tests

Once logged in:

```bash
# Mount host filesystem
sudo mkdir -p /mnt/host
sudo mount -t 9p -o trans=virtio,version=9p2000.L hostfs /mnt/host

# Run the automated test script
/mnt/host/gda-experiments/in-vm-gda-test.sh
```

This will:
1. ✅ Build GDA kernel driver
2. ✅ Build userspace library and tests  
3. ✅ Find and unbind emulated NVMe (NOT the real one!)
4. ✅ Load GDA driver
5. ✅ Run doorbell test
6. ✅ Show trace output

## Monitor Trace (from host)

While the VM is running, you can watch the trace in real-time:

```bash
# On host machine
tail -f /tmp/nvme-gda-trace.log
```

## Manual Testing (if preferred)

```bash
# Inside VM
cd /mnt/host/gda-experiments/nvme-gda

# Build driver
cd nvme_gda_driver && make

# Build tests
cd .. && mkdir build && cd build && cmake .. && make

# Find emulated NVMe (QEMU device ID 1b36:0010)
lspci -nn | grep "1b36:0010"
# Example output: 00:03.0 Non-Volatile memory controller [0108]: Red Hat, Inc. QEMU NVM Express Controller [1b36:0010]

# Unbind from nvme (use YOUR device address from above)
echo "0000:00:03.0" | sudo tee /sys/bus/pci/drivers/nvme/unbind

# Load GDA driver  
sudo insmod nvme_gda_driver/nvme_gda.ko nvme_pci_dev=0000:00:03.0

# Create device node if needed
ls /dev/nvme_gda0 || (
  MAJOR=$(awk '$2=="nvme_gda" {print $1}' /proc/devices)
  sudo mknod /dev/nvme_gda0 c $MAJOR 0
  sudo chmod 666 /dev/nvme_gda0
)

# Run test
./test_basic_doorbell /dev/nvme_gda0
```

## Expected Output

```
NVMe GDA Device Info:
  Vendor ID: 0x1b36
  Device ID: 0x0010
  BAR0: 0x...
  Doorbell stride: 0
  
GPU: Old doorbell value: 0, New value: 1
✓ SUCCESS: GPU successfully rang the doorbell!
```

## Check Traces

```bash
# Inside VM or on host
grep doorbell /tmp/nvme-gda-trace.log | tail -20
```

You should see GPU-initiated doorbell writes in the trace!

## Exit VM

From inside VM:
```bash
sudo poweroff
```

Or from host console (if attached):
```
Ctrl-A, then X
```

## Troubleshooting

### Can't SSH
```bash
# Wait longer (VM takes ~30-60 seconds to boot)
# Check if VM is running
ps aux | grep qemu

# Check logs
tail ~/gda-test-vm.log
```

### Can't mount filesystem
```bash
# Try this format
sudo mount -t 9p -o trans=virtio,version=9p2000.L,nofail hostfs /mnt/host
```

### Can't find emulated NVMe
```bash
# List all NVMe devices
lspci -nn | grep -i nvme

# QEMU emulated = 1b36:0010
# Real hardware = different vendor IDs
```

## Success Criteria

✓ Driver loads without errors
✓ /dev/nvme_gda0 created
✓ test_basic_doorbell passes
✓ Trace shows doorbell operations from GPU

## Current Status

🚀 VM is running in background
📝 Logs: ~/gda-test-vm.log
📊 Trace: /tmp/nvme-gda-trace.log

**Ready to test!**

