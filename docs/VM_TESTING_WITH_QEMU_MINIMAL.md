# ROCm-AXIIO Testing with qemu-minimal

**Date:** November 6, 2025  
**System:** Lenovo ThinkStation P8  
**Infrastructure:** Using existing qemu-minimal scripts

---

## Overview

This guide shows how to test rocm-axiio inside a VM using your existing `qemu-minimal` infrastructure. This approach leverages the battle-tested `gen-vm` and `run-vm` scripts you already have.

**Benefits:**
- ✅ Use existing, tested VM infrastructure
- ✅ Built-in NVMe emulation support
- ✅ Native shared filesystem (9p/virtfs)
- ✅ PCIe passthrough ready
- ✅ NVMe tracing for debugging
- ✅ Quick VM resets via backing files

---

## Quick Start (15 Minutes)

### Step 1: Create ROCm-AXIIO Development VM

```bash
cd /home/stebates/Projects/qemu-minimal/qemu

# Create VM with development packages
VM_NAME=rocm-axiio \
VCPUS=4 \
VMEM=8192 \
SIZE=64 \
PACKAGES=../packages.d/packages-default \
./gen-vm
```

This creates a VM with:
- 4 vCPUs, 8GB RAM, 64GB disk
- Ubuntu Noble (24.04)
- Default development packages (build-essential, git, etc.)
- User: `ubuntu`, Password: `password`
- SSH port: 2222

**Wait for VM to complete cloud-init and shut down** (~5-10 minutes)

### Step 2: Boot VM with NVMe and Shared Folder

```bash
cd /home/stebates/Projects/qemu-minimal/qemu

# Boot with 2 NVMe devices and rocm-axiio shared
VM_NAME=rocm-axiio \
NVME=2 \
FILESYSTEM=/home/stebates/Projects/rocm-axiio \
./run-vm
```

### Step 3: Inside VM - Mount Shared Folder and Setup

```bash
# SSH into VM (from another terminal)
ssh -p 2222 ubuntu@localhost
# Password: password

# Mount shared rocm-axiio project
sudo mkdir -p /mnt/rocm-axiio
sudo mount -t 9p -o trans=virtio,version=9p2000.L hostfs /mnt/rocm-axiio

# Make it permanent
echo 'hostfs /mnt/rocm-axiio 9p trans=virtio,version=9p2000.L,nofail 0 1' | \
  sudo tee -a /etc/fstab

# Create symlink for convenience
ln -s /mnt/rocm-axiio ~/rocm-axiio
```

### Step 4: Install ROCm Inside VM

```bash
# Add ROCm repository
wget https://repo.radeon.com/rocm/rocm.gpg.key -O - | \
  gpg --dearmor | sudo tee /etc/apt/keyrings/rocm.gpg > /dev/null

echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] \
https://repo.radeon.com/rocm/apt/6.2 noble main" | \
  sudo tee /etc/apt/sources.list.d/rocm.list

# Install ROCm
sudo apt update
sudo apt install -y rocm-hip-sdk rocminfo libcli11-dev nvme-cli

# Set environment
echo 'export HSA_FORCE_FINE_GRAIN_PCIE=1' >> ~/.bashrc
echo 'export PATH=/opt/rocm/bin:$PATH' >> ~/.bashrc
source ~/.bashrc
```

### Step 5: Build and Test

```bash
# Navigate to project
cd ~/rocm-axiio

# Build
make clean
make all

# Check NVMe devices
sudo nvme list
ls -la /dev/nvme*

# Run basic test
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 --cpu-only -n 100 --verbose
```

---

## Detailed Configuration

### VM Creation Options

Customize your VM with these variables:

```bash
cd /home/stebates/Projects/qemu-minimal/qemu

# Development VM with more resources
VM_NAME=rocm-axiio-dev \
VCPUS=8 \
VMEM=16384 \
SIZE=128 \
PACKAGES=../packages.d/packages-default \
./gen-vm

# Minimal VM for quick testing
VM_NAME=rocm-axiio-minimal \
VCPUS=2 \
VMEM=4096 \
SIZE=32 \
PACKAGES=../packages.d/packages-minimal \
./gen-vm
```

### VM Runtime Options

Configure NVMe devices, shared folders, and more:

```bash
cd /home/stebates/Projects/qemu-minimal/qemu

# 1. Basic run (no extras)
VM_NAME=rocm-axiio ./run-vm

# 2. With 4 NVMe devices
VM_NAME=rocm-axiio NVME=4 ./run-vm

# 3. With shared folder
VM_NAME=rocm-axiio \
FILESYSTEM=/home/stebates/Projects/rocm-axiio \
./run-vm

# 4. Full setup: NVMe + shared folder + more resources
VM_NAME=rocm-axiio \
NVME=2 \
FILESYSTEM=/home/stebates/Projects/rocm-axiio \
VCPUS=8 \
VMEM=16384 \
./run-vm

# 5. With NVMe tracing for debugging
VM_NAME=rocm-axiio \
NVME=2 \
NVME_TRACE=doorbell \
NVME_TRACE_FILE=/tmp/nvme-trace.log \
FILESYSTEM=/home/stebates/Projects/rocm-axiio \
./run-vm

# 6. Different SSH port (for multiple VMs)
VM_NAME=rocm-axiio \
SSH_PORT=2223 \
NVME=2 \
./run-vm
```

---

## Testing Workflows

### Workflow 1: Emulated NVMe Testing (Recommended Start)

**Goal:** Test rocm-axiio with QEMU-emulated NVMe devices

**On Host:**
```bash
cd /home/stebates/Projects/qemu-minimal/qemu

# Boot VM with 2 NVMe devices
VM_NAME=rocm-axiio \
NVME=2 \
FILESYSTEM=/home/stebates/Projects/rocm-axiio \
VCPUS=4 \
VMEM=8192 \
./run-vm
```

**Inside VM:**
```bash
# SSH from another terminal
ssh -p 2222 ubuntu@localhost

# Check NVMe devices
sudo nvme list
# Should show: qemu-minimal-nvme1 and qemu-minimal-nvme2

lspci | grep -i nvme
ls -la /dev/nvme*

# Navigate to project (via shared folder)
cd /mnt/rocm-axiio

# Build
make clean
make all

# Test with CPU-only mode
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 --cpu-only -n 100 --verbose

# Test with emulated endpoint
./bin/axiio-tester --endpoint nvme-ep -n 1000 --verbose

# Performance test
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 --cpu-only -n 10000 --histogram

# Data integrity test
sudo ./scripts/test-nvme-io.sh --start-lba 1000000 --num-blocks 16 --iterations 10
```

**Expected Results:**
- ✅ 2 NVMe devices detected (`/dev/nvme0`, `/dev/nvme1`)
- ✅ All tests pass
- ✅ Latency ~10-50μs (emulation overhead)
- ✅ Zero data corruption

---

### Workflow 2: Kernel Module Testing

**Goal:** Load and test nvme_axiio kernel module in safe VM environment

**Inside VM:**
```bash
cd /mnt/rocm-axiio/kernel-module

# Install kernel headers if not already present
sudo apt install -y linux-headers-$(uname -r)

# Build module
make clean
make

# Load module
sudo insmod nvme_axiio.ko

# Check module loaded
lsmod | grep nvme_axiio
dmesg | tail -30

# Verify device node created
ls -la /dev/nvme-axiio

# Run axiio-tester with kernel module
sudo ../bin/axiio-tester --nvme-device /dev/nvme0 \
                         --use-kernel-module \
                         --nvme-queue-id 63 \
                         -n 100 --verbose

# Monitor kernel messages
sudo dmesg -wH

# Unload module when done
sudo rmmod nvme_axiio
```

**If Module Loading Fails (Secure Boot):**
```bash
# Check if Secure Boot is blocking
dmesg | grep -i "signature\|lockdown"

# Option 1: Disable Secure Boot in VM
# Reboot VM, enter BIOS/UEFI (press ESC during boot)
# Navigate to Security settings
# Disable Secure Boot
# Save and reboot

# Option 2: Disable validation via mokutil
mokutil --disable-validation
# Follow prompts, reboot
```

---

### Workflow 3: NVMe Tracing and Debugging

**Goal:** Capture detailed NVMe doorbell operations for analysis

**On Host:**
```bash
cd /home/stebates/Projects/qemu-minimal/qemu

# Boot with doorbell tracing enabled
VM_NAME=rocm-axiio \
NVME=2 \
NVME_TRACE=doorbell \
NVME_TRACE_FILE=/tmp/rocm-axiio-nvme-trace.log \
FILESYSTEM=/home/stebates/Projects/rocm-axiio \
./run-vm
```

**Inside VM:**
```bash
# Run tests as normal
cd /mnt/rocm-axiio
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 --cpu-only -n 100 --verbose
```

**On Host (in another terminal):**
```bash
# Watch trace in real-time
tail -f /tmp/rocm-axiio-nvme-trace.log

# Analyze after test
cat /tmp/rocm-axiio-nvme-trace.log | grep doorbell
```

**Trace Output Example:**
```
pci_nvme_mmio_doorbell_sq sq_tail=1 dbl_addr=0x1000
pci_nvme_mmio_doorbell_cq cq_head=1 dbl_addr=0x1004
```

---

### Workflow 4: Real NVMe Passthrough Testing

**Goal:** Pass through physical NVMe device to VM for hardware validation

**Prerequisites:**
- One NVMe device not used by host (we have nvme0/c2:00.0 bound to vfio-pci)
- IOMMU enabled ✅ (already confirmed)

**On Host - Setup:**
```bash
# Verify device is bound to vfio-pci
lspci -k -s c2:00.0 | grep vfio
# Should show: Kernel driver in use: vfio-pci

# If not bound, use vfio-setup
cd /home/stebates/Projects/qemu-minimal/qemu
sudo HOST_ADDR=0000:c2:00.0 ./vfio-setup
```

**On Host - Boot VM with Passthrough:**
```bash
cd /home/stebates/Projects/qemu-minimal/qemu

# Pass through WD Black SN850X to VM
VM_NAME=rocm-axiio \
PCI_HOSTDEV=0000:c2:00.0 \
FILESYSTEM=/home/stebates/Projects/rocm-axiio \
VCPUS=4 \
VMEM=8192 \
./run-vm
```

**Inside VM:**
```bash
# Check device appeared
lspci | grep -i nvme
# Should show: Sandisk Corp WD Black SN850X

sudo nvme list
# Should show real hardware, not qemu-minimal-nvme

# Get device info
sudo nvme id-ctrl /dev/nvme0
sudo lspci -vvv | grep -A 50 "Non-Volatile memory"

# Run tests with real hardware
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 \
                        --cpu-only -n 100 --verbose

# Performance benchmark
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 \
                        --cpu-only -n 10000 --histogram

# Data integrity
sudo ./scripts/test-nvme-io.sh \
     --start-lba 10000000 --num-blocks 32 --iterations 100
```

**Expected Results:**
- ✅ Real WD Black SN850X detected
- ✅ Better performance (<10μs vs ~50μs emulated)
- ✅ Hardware-accurate behavior
- ✅ 100% data integrity

---

## Development Workflow

### Live Code Editing (Host → VM)

The shared folder allows seamless development:

**On Host:**
```bash
# Edit code on host with your favorite editor
cd /home/stebates/Projects/rocm-axiio
vim tester/axiio-tester.hip
# Make changes, save
```

**Inside VM:**
```bash
# Changes are immediately visible!
cd /mnt/rocm-axiio
make clean
make all
# Build with your changes

# Test immediately
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 --cpu-only -n 10 -v
```

No file copying needed - the shared folder keeps everything in sync!

### Quick VM Reset

If VM gets corrupted or you want a clean slate:

**On Host:**
```bash
cd /home/stebates/Projects/qemu-minimal/qemu

# Stop VM (Ctrl+A, X in QEMU console)

# Reset VM to clean state (from backing file)
VM_NAME=rocm-axiio RESTORE_IMAGE=true ./gen-vm

# Boot again
VM_NAME=rocm-axiio \
NVME=2 \
FILESYSTEM=/home/stebates/Projects/rocm-axiio \
./run-vm
```

The `RESTORE_IMAGE` mode recreates the VM overlay from the clean backing file in seconds!

---

## Multiple VMs

Run multiple test VMs simultaneously:

```bash
cd /home/stebates/Projects/qemu-minimal/qemu

# VM 1: Development
VM_NAME=rocm-axiio-dev \
SSH_PORT=2222 \
NVME=2 \
FILESYSTEM=/home/stebates/Projects/rocm-axiio \
VCPUS=4 \
VMEM=8192 \
./run-vm &

# VM 2: Performance testing
VM_NAME=rocm-axiio-perf \
SSH_PORT=2223 \
NVME=4 \
NVME_TRACE=doorbell \
VCPUS=8 \
VMEM=16384 \
./run-vm &

# VM 3: Hardware passthrough
VM_NAME=rocm-axiio-hw \
SSH_PORT=2224 \
PCI_HOSTDEV=0000:c2:00.0 \
FILESYSTEM=/home/stebates/Projects/rocm-axiio \
./run-vm &

# Access each VM
ssh -p 2222 ubuntu@localhost  # Dev
ssh -p 2223 ubuntu@localhost  # Perf
ssh -p 2224 ubuntu@localhost  # HW
```

---

## Advanced Configuration

### Custom Package Manifest

Create a custom package manifest for ROCm-AXIIO:

```bash
cd /home/stebates/Projects/qemu-minimal/packages.d

# Create rocm-axiio specific packages
cat > packages-rocm-axiio << 'EOF'
  - build-essential
  - git
  - cmake
  - pkg-config
  - nvme-cli
  - linux-headers-generic
  - vim
  - htop
  - fio
  - wget
  - curl
EOF

# Create VM with these packages
cd ../qemu
VM_NAME=rocm-axiio \
PACKAGES=../packages.d/packages-rocm-axiio \
VCPUS=4 \
VMEM=8192 \
./gen-vm
```

### Automated Setup Script

Create a setup script to run inside VM:

```bash
# On host
cat > /home/stebates/Projects/rocm-axiio/scripts/vm-init-rocm.sh << 'EOF'
#!/bin/bash
# Run this inside VM after first boot

set -e

echo "=== ROCm-AXIIO VM Initialization ==="

# Add ROCm repository
wget https://repo.radeon.com/rocm/rocm.gpg.key -O - | \
  gpg --dearmor | sudo tee /etc/apt/keyrings/rocm.gpg > /dev/null

echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] \
https://repo.radeon.com/rocm/apt/6.2 noble main" | \
  sudo tee /etc/apt/sources.list.d/rocm.list

# Install ROCm and tools
sudo apt update
sudo apt install -y rocm-hip-sdk rocminfo libcli11-dev nvme-cli

# Set environment
cat >> ~/.bashrc << 'BASHRC'
export HSA_FORCE_FINE_GRAIN_PCIE=1
export PATH=/opt/rocm/bin:$PATH
export LD_LIBRARY_PATH=/opt/rocm/lib:$LD_LIBRARY_PATH
alias axiio='cd /mnt/rocm-axiio'
BASHRC

# Mount shared folder
sudo mkdir -p /mnt/rocm-axiio
echo 'hostfs /mnt/rocm-axiio 9p trans=virtio,version=9p2000.L,nofail 0 1' | \
  sudo tee -a /etc/fstab
sudo mount -a

# Create symlink
ln -sf /mnt/rocm-axiio ~/rocm-axiio

echo "✓ Setup complete! Reboot or re-login to apply changes."
EOF

chmod +x /home/stebates/Projects/rocm-axiio/scripts/vm-init-rocm.sh
```

**Inside VM:**
```bash
# Copy and run setup script
cp /mnt/rocm-axiio/scripts/vm-init-rocm.sh ~/
./vm-init-rocm.sh

# Reboot or re-login
exit
ssh -p 2222 ubuntu@localhost
```

---

## Troubleshooting

### Shared Folder Not Mounting

**Problem:** `/mnt/rocm-axiio` is empty or mount fails

**Solution:**
```bash
# Inside VM
sudo mount -t 9p -o trans=virtio,version=9p2000.L hostfs /mnt/rocm-axiio

# Check if module loaded
lsmod | grep 9p
sudo modprobe 9pnet_virtio

# Add to fstab for persistence
echo 'hostfs /mnt/rocm-axiio 9p trans=virtio,version=9p2000.L,nofail 0 1' | \
  sudo tee -a /etc/fstab
```

### NVMe Devices Not Showing

**Problem:** `sudo nvme list` shows nothing

**Solution:**
```bash
# Inside VM
# Check if NVMe driver loaded
lsmod | grep nvme
sudo modprobe nvme

# Check PCI devices
lspci | grep -i "nvme\|non-volatile"

# Check device nodes
ls -la /dev/nvme*
```

**On Host:**
```bash
# Verify NVME variable was set
# Re-run with explicit NVME setting
cd /home/stebates/Projects/qemu-minimal/qemu
VM_NAME=rocm-axiio NVME=2 ./run-vm
```

### Cannot Connect via SSH

**Problem:** `ssh -p 2222 ubuntu@localhost` times out

**Solution:**
```bash
# Check if port is already in use
sudo lsof -i :2222

# Use different port
VM_NAME=rocm-axiio SSH_PORT=2223 NVME=2 ./run-vm

# In QEMU console, check if SSH is running
systemctl status sshd
```

### Build Failures in VM

**Problem:** `make all` fails with missing dependencies

**Solution:**
```bash
# Inside VM
# Install missing packages
sudo apt update
sudo apt install -y build-essential cmake libcli11-dev

# Check for hipcc
which hipcc
/opt/rocm/bin/hipcc --version

# If hipcc missing, install ROCm
sudo apt install rocm-hip-sdk
```

---

## Quick Reference

```bash
# === CREATE VM ===
cd /home/stebates/Projects/qemu-minimal/qemu
VM_NAME=rocm-axiio VCPUS=4 VMEM=8192 SIZE=64 ./gen-vm

# === BOOT VM ===
# Basic
VM_NAME=rocm-axiio ./run-vm

# With NVMe and shared folder
VM_NAME=rocm-axiio NVME=2 \
  FILESYSTEM=/home/stebates/Projects/rocm-axiio ./run-vm

# With NVMe tracing
VM_NAME=rocm-axiio NVME=2 NVME_TRACE=doorbell \
  NVME_TRACE_FILE=/tmp/trace.log ./run-vm

# With PCIe passthrough
VM_NAME=rocm-axiio PCI_HOSTDEV=0000:c2:00.0 \
  FILESYSTEM=/home/stebates/Projects/rocm-axiio ./run-vm

# === ACCESS VM ===
ssh -p 2222 ubuntu@localhost  # Password: password

# === INSIDE VM ===
# Mount shared folder (if not auto-mounted)
sudo mount -t 9p -o trans=virtio,version=9p2000.L hostfs /mnt/rocm-axiio

# Build and test
cd /mnt/rocm-axiio
make clean && make all
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 --cpu-only -n 100 -v

# === RESET VM ===
VM_NAME=rocm-axiio RESTORE_IMAGE=true ./gen-vm
```

---

## Next Steps

### Immediate (Today)

1. **Create VM:**
   ```bash
   cd /home/stebates/Projects/qemu-minimal/qemu
   VM_NAME=rocm-axiio VCPUS=4 VMEM=8192 ./gen-vm
   ```

2. **Wait for cloud-init** (~5-10 minutes for VM to shut down)

3. **Boot VM:**
   ```bash
   VM_NAME=rocm-axiio NVME=2 \
     FILESYSTEM=/home/stebates/Projects/rocm-axiio ./run-vm
   ```

### Week 1: Emulated Testing

- [ ] Create and boot VM
- [ ] Install ROCm inside VM
- [ ] Mount shared folder
- [ ] Build rocm-axiio
- [ ] Run basic CPU-only tests
- [ ] Test kernel module loading
- [ ] Run comprehensive test suite

### Week 2: Hardware Validation

- [ ] Set up NVMe passthrough (c2:00.0)
- [ ] Test with real hardware
- [ ] Performance benchmarking
- [ ] Data integrity validation
- [ ] Compare emulated vs. real performance

### Week 3: Advanced Testing

- [ ] Enable NVMe tracing
- [ ] Analyze doorbell operations
- [ ] Multi-queue testing
- [ ] Stress testing
- [ ] Document findings

---

## Summary

**You're ready to start testing!**

Your existing `qemu-minimal` infrastructure provides everything needed:

✅ **VM creation** - `gen-vm` with cloud-init  
✅ **NVMe emulation** - Built into `run-vm`  
✅ **Shared folders** - 9p virtfs support  
✅ **PCIe passthrough** - VFIO ready  
✅ **NVMe tracing** - Debug support  
✅ **Quick resets** - Backing file approach  

**Start now:**
```bash
cd /home/stebates/Projects/qemu-minimal/qemu
VM_NAME=rocm-axiio VCPUS=4 VMEM=8192 ./gen-vm
```

---

**Document Version:** 1.0  
**Last Updated:** November 6, 2025  
**Infrastructure:** qemu-minimal (gen-vm + run-vm)

