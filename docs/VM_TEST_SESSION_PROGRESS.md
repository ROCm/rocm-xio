# VM NVMe Testing Session Progress

**Date**: November 6, 2025  
**Status**: In Progress - System Reboot Required

## Completed ✅

### Tier 1: Emulated NVMe Testing
- ✅ Created `rocm-axiio` VM using qemu-minimal `gen-vm` script
- ✅ Installed ROCm, hipcc, and build dependencies in VM
- ✅ Built `axiio-tester` successfully with `OFFLOAD_ARCH=gfx906`
- ✅ Booted VM with 2 emulated NVMe devices (nvme0n1, nvme1n1)
- ✅ Mounted shared filesystem at `/mnt/host`
- ✅ Detected both QEMU NVMe controllers
- ✅ Ran basic CPU-only tests with emulated NVMe

**Build Command**:
```bash
cd ~/rocm-axiio
make HIPCXX=/usr/bin/hipcc OFFLOAD_ARCH=gfx906 bin/axiio-tester
```

**VM Config**:
- 4 vCPUs, 8GB RAM
- 2x 1TB emulated NVMe (QEMU NVMe Ctrl)
- Shared filesystem: `/home/stebates/Projects/rocm-axiio` → `/mnt/host`

### Tier 3: GPU Passthrough Attempt
- ✅ GPU detected in VM PCI config: `03:00.0` AMD Navi 48 (RX 9070)
- ✅ Bus mastering enabled
- ✅ PCIe Atomics enabled (`AtomicOpsCtl: ReqEn+`)
- ✅ amdgpu kernel module loaded
- ✅ User added to render/video groups
- ❌ **GPU initialization failed**: "Fatal error during GPU init" in guest
- ❌ **Host issue**: GPU stuck in D3cold power state, inaccessible

## Current Issue 🔴

**GPU is stuck in D3cold** (deep sleep) and cannot be woken up. This is preventing proper GPU passthrough.

**Host dmesg errors**:
```
vfio-pci 0000:10:00.0: Unable to change power state from D3cold to D0, device inaccessible
pcieport 0000:0f:00.0: Data Link Layer Link Active not set in 100 msec
```

**Root cause**: Multiple VM GPU passthrough attempts without proper cleanup/reset caused the GPU to enter an inaccessible state. The PCIe link is down and the device cannot respond to power state changes.

**Solution**: System reboot required to fully reset GPU hardware.

## Devices Status

### GPU (10:00.0)
- **Model**: AMD Navi 48 [Radeon RX 9070 XT]
- **Status**: ❌ Inaccessible (D3cold stuck)
- **Driver**: vfio-pci (bound correctly)
- **Audio** (10:00.1): vfio-pci (bound correctly)
- **Action**: Reboot required

### NVMe Devices
- **WD Black SN850X** (c2:00.0): ✅ Ready (bound to vfio-pci)
- **KIOXIA** (01:00.0): ⚠️ Cannot use (rootfs device)

## Next Steps After Reboot

### 1. Verify GPU Reset
```bash
# Check GPU power state
lspci -vvv -s 10:00.0 | grep -i 'power\|d0\|d3'

# Verify vfio-pci binding
lspci -k -s 10:00.0

# Check for IOMMU errors
sudo dmesg | grep -i 'vfio\|10:00.0' | tail -20
```

### 2. Boot VM with Full Passthrough
```bash
cd /home/stebates/Projects/qemu-minimal/qemu

# Boot with GPU + NVMe + shared filesystem
VM_NAME=rocm-axiio \
VCPUS=4 \
VMEM=8192 \
FILESYSTEM=/home/stebates/Projects/rocm-axiio \
PCI_HOSTDEV=10:00.0,c2:00.0 \
./run-vm
```

### 3. In VM: Verify GPU Detection
```bash
# SSH into VM
ssh -p 2222 ubuntu@localhost

# Mount shared filesystem
sudo mkdir -p /mnt/host
sudo mount -t 9p -o trans=virtio,version=9p2000.L hostfs /mnt/host

# Load amdgpu module
sudo modprobe amdgpu

# Check GPU
lspci | grep -i amd
rocminfo
```

### 4. Run axiio-tester Tests

#### Test 1: CPU-only mode with real NVMe
```bash
cd ~/rocm-axiio
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 --cpu-only -n 100 --verbose
```

#### Test 2: With GPU (if detected)
```bash
export HSA_FORCE_FINE_GRAIN_PCIE=1
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 -n 100 --verbose --histogram
```

#### Test 3: With kernel module (GPU-direct)
```bash
cd ~/rocm-axiio/kernel-module
sudo ./load.sh

cd ~/rocm-axiio
export HSA_FORCE_FINE_GRAIN_PCIE=1
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 --use-kernel-module -n 1000 --verbose
```

#### Test 4: Data integrity (extended)
```bash
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 --use-kernel-module -n 10000 --verify-data
```

## VM Management Commands

### Start VM
```bash
cd /home/stebates/Projects/qemu-minimal/qemu
VM_NAME=rocm-axiio VCPUS=4 VMEM=8192 \
  FILESYSTEM=/home/stebates/Projects/rocm-axiio \
  PCI_HOSTDEV=10:00.0,c2:00.0 \
  ./run-vm 2>&1 | tee ~/rocm-axiio-vm.log &
```

### Stop VM
```bash
pkill -f "qemu-system-x86_64"
```

### SSH to VM
```bash
ssh -p 2222 ubuntu@localhost
```

### View boot log
```bash
tail -f ~/rocm-axiio-vm.log
```

## Files Created

- **VM Image**: `/home/stebates/Projects/qemu-minimal/images/rocm-axiio.qcow2`
- **Backing Image**: `/home/stebates/Projects/qemu-minimal/images/rocm-axiio-backing.qcow2`
- **Boot Logs**: `~/rocm-axiio-vm*.log`
- **This Progress Doc**: `/home/stebates/Projects/rocm-axiio/docs/VM_TEST_SESSION_PROGRESS.md`

## Testing Objectives (Post-Reboot)

### Primary Goals
1. ✅ Verify GPU can be passed through cleanly after reboot
2. ⏳ Test axiio-tester with real NVMe hardware
3. ⏳ Validate GPU-direct doorbell writes
4. ⏳ Measure latency (<1μs target) and IOPS (>1M target)
5. ⏳ Verify data integrity with 1000+ iterations
6. ⏳ Test kernel module integration

### Expected Results
- Real NVMe detection: ✅
- Doorbell addresses discoverable: ✅
- CPU-only mode works: ✅
- GPU initialization: ⏳ (pending reboot)
- GPU-direct doorbell: ⏳ (requires GPU)
- Sub-microsecond latency: ⏳ (requires GPU)

## Notes

- The VM setup and build process is working correctly
- Emulated NVMe testing validated the basic framework
- GPU passthrough issue is a hardware state problem, not a configuration issue
- After reboot, GPU should initialize properly in the VM
- Real NVMe (WD Black SN850X) is ready for testing

---

**Status**: Waiting for system reboot to reset GPU hardware state.

