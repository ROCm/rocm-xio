# ROCm-AXIIO VM Testing: Complete Setup Guide

**Date:** November 6, 2025  
**System:** Lenovo ThinkStation P8 with AMD EPYC CPU  
**Status:** Ready to Begin

---

## 📋 Overview

This document provides a complete guide for setting up and testing rocm-axiio inside a virtual machine. Working inside a VM provides safety, isolation, and easy recovery through snapshots.

---

## 🎯 Quick Start (30 Minutes)

### Step 1: Create VM Environment (Host)

```bash
cd /home/stebates/Projects/rocm-axiio

# Create VM and download Ubuntu ISO
./scripts/create-dev-vm.sh

# Follow prompts to download Ubuntu 24.04 (2.6GB)
```

### Step 2: Install Ubuntu (Host)

**Option A: Graphical Installer (Recommended)**
```bash
sudo qemu-system-x86_64 \
  -enable-kvm -cpu host -m 8G -smp 4 \
  -drive file=vm-images/rocm-axiio-dev.qcow2,format=qcow2,if=virtio \
  -cdrom vm-images/ubuntu-24.04-server-amd64.iso \
  -boot d \
  -net nic,model=virtio -net user \
  -vnc :0

# Connect VNC viewer to localhost:5900
# Complete Ubuntu installation
```

**Option B: Text Installer**
```bash
sudo qemu-system-x86_64 \
  -enable-kvm -cpu host -m 8G -smp 4 \
  -drive file=vm-images/rocm-axiio-dev.qcow2,format=qcow2,if=virtio \
  -cdrom vm-images/ubuntu-24.04-server-amd64.iso \
  -boot d \
  -net nic,model=virtio -net user \
  -nographic
```

### Step 3: Boot VM and Setup (Host)

```bash
# Boot the VM
./scripts/boot-dev-vm.sh

# In another terminal, SSH into VM
ssh -p 2222 <username>@localhost
```

### Step 4: Install Development Environment (Inside VM)

```bash
# Copy setup script from shared folder
cp /mnt/host/scripts/vm-guest-setup.sh ~/
chmod +x vm-guest-setup.sh

# Run setup (installs ROCm, build tools, NVMe utilities)
./vm-guest-setup.sh

# Reboot to apply changes
sudo reboot
```

### Step 5: Build and Test (Inside VM)

```bash
# SSH back in after reboot
ssh -p 2222 <username>@localhost

# Navigate to project (shared from host)
cd ~/rocm-axiio

# Build
make clean
make all

# Test with emulated NVMe
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 --cpu-only -n 100 --verbose
```

---

## 📚 Documentation

### Main Documents

1. **[DEVELOPMENT_INSIDE_VM.md](docs/DEVELOPMENT_INSIDE_VM.md)**
   - Complete guide for working inside VM
   - Daily development workflow
   - Snapshot management
   - Troubleshooting

2. **[VM_NVME_TESTING_PLAN.md](docs/VM_NVME_TESTING_PLAN.md)**
   - Comprehensive 3-phase testing plan
   - Security analysis
   - NVMe passthrough instructions
   - Success criteria and metrics

### Supporting Documents

- **[README.md](README.md)** - Project overview and build instructions
- **[QUICK_START.md](QUICK_START.md)** - Quick reference for common tasks
- **[docs/AXIIO_ARCHITECTURE.md](docs/AXIIO_ARCHITECTURE.md)** - System architecture

---

## 🔧 Available Scripts

All scripts are in `/home/stebates/Projects/rocm-axiio/scripts/`:

### Host Scripts

- **`create-dev-vm.sh`** - Creates VM environment, downloads ISO, creates disks
- **`boot-dev-vm.sh`** - Boots VM with NVMe emulation and shared folder
- **`bind-nvme-to-vfio.sh`** - Binds NVMe device to vfio-pci for passthrough

### VM Guest Scripts

- **`vm-guest-setup.sh`** - Installs all development tools inside VM
- **`test-nvme-io.sh`** - Comprehensive NVMe I/O testing with data verification
- **`test-with-dmesg-monitor.sh`** - Runs tests with kernel error monitoring

---

## 🖥️ System Analysis Summary

### Hardware Detected

**NVMe Devices:**
- `nvme1` (c1:00.0) - KIOXIA XG8 - 4.10 TB - Available
- `nvme0` (c2:00.0) - WD Black SN850X - 2.00 TB - Bound to vfio-pci

**System:**
- CPU: AMD EPYC Genoa/Bergamo (supports AMD-V/SVM)
- IOMMU: Enabled with passthrough mode
- KVM: Available and working
- Virtualization: Fully functional

### Security Status

✅ **NO BLOCKING ISSUES FOUND**

- Kernel Lockdown: **none** (no restrictions)
- Secure Boot: **enabled** (may need module signing in VM)
- IOMMU: **enabled** (perfect for passthrough)
- /dev/mem: **accessible** (for hardware access)
- PCIe Config: **accessible** (setpci works)
- KVM Device: **accessible** (in kvm group)

### Software Status

- ✅ QEMU 8.2.2 installed
- ✅ KVM modules loaded
- ✅ rocm-axiio built (axiio-tester ready)
- ✅ Kernel module built (nvme_axiio.ko)
- ⚠️ rocminfo not installed (optional)

---

## 🎓 Testing Approaches

### Approach 1: QEMU NVMe Emulation (Recommended)

**Best for:**
- Initial development and testing
- Safe experimentation
- Kernel module testing
- CI/CD integration

**Setup:**
```bash
# Already configured in boot-dev-vm.sh
# VM includes 10GB emulated NVMe device automatically
```

**Inside VM:**
```bash
sudo nvme list  # Should show: QEMU NVMe Ctrl
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 --cpu-only -n 100 -v
```

### Approach 2: Real NVMe Passthrough (Optional)

**Best for:**
- Hardware validation
- Performance benchmarking
- Real-world testing

**Prerequisites:**
- One NVMe device bound to vfio-pci on host
- Device not used by host OS

**Setup on Host:**
```bash
# Bind WD Black SN850X to vfio-pci
sudo ./scripts/bind-nvme-to-vfio.sh c2:00.0

# Boot VM with passthrough
sudo qemu-system-x86_64 \
  -enable-kvm -cpu host,kvm=off -m 8G -smp 4 \
  -drive file=vm-images/rocm-axiio-dev.qcow2,format=qcow2,if=virtio \
  -device vfio-pci,host=c2:00.0,id=nvme_real \
  -net nic,model=virtio -net user,hostfwd=tcp::2222-:22 \
  -virtfs local,path=$PWD,mount_tag=host0,security_model=passthrough \
  -nographic
```

---

## ✅ Testing Checklist

### Initial Setup (One Time)

- [ ] Run `create-dev-vm.sh` on host
- [ ] Download Ubuntu 24.04 ISO
- [ ] Install Ubuntu in VM
- [ ] Boot VM with `boot-dev-vm.sh`
- [ ] Verify SSH access: `ssh -p 2222 <user>@localhost`
- [ ] Run `vm-guest-setup.sh` inside VM
- [ ] Reboot VM
- [ ] Verify shared folder: `ls ~/rocm-axiio`
- [ ] Create snapshot: `qemu-img snapshot -c clean_install vm-images/rocm-axiio-dev.qcow2`

### Build and Basic Testing

- [ ] Build project: `cd ~/rocm-axiio && make clean && make all`
- [ ] Verify NVMe: `sudo nvme list`
- [ ] Run CPU-only test: `sudo ./bin/axiio-tester --nvme-device /dev/nvme0 --cpu-only -n 100 -v`
- [ ] Run emulated test: `./bin/axiio-tester --endpoint nvme-ep -n 1000 -v`
- [ ] Verify no errors in `dmesg`

### Kernel Module Testing

- [ ] Build module: `cd kernel-module && make`
- [ ] Create snapshot before loading
- [ ] Load module: `sudo insmod nvme_axiio.ko`
- [ ] Check dmesg: `sudo dmesg | tail -20`
- [ ] Verify device: `ls -la /dev/nvme-axiio`
- [ ] Run test: `sudo ./bin/axiio-tester --nvme-device /dev/nvme0 --use-kernel-module -n 100 -v`
- [ ] Unload module: `sudo rmmod nvme_axiio`

### Performance Testing

- [ ] Histogram test: `sudo ./bin/axiio-tester --nvme-device /dev/nvme0 --cpu-only -n 10000 --histogram`
- [ ] Data integrity: `sudo ./scripts/test-nvme-io.sh --iterations 100`
- [ ] Stress test: `sudo ./bin/axiio-tester --nvme-device /dev/nvme0 -n 100000`

---

## 🔍 Key Features

### Shared Folder

The VM has access to the host project directory via `/mnt/host`:

```bash
# On host: Edit code
vim /home/stebates/Projects/rocm-axiio/tester/axiio-tester.hip

# In VM: Changes are immediately visible
cd ~/rocm-axiio  # Links to /mnt/host
make all
```

### VM Snapshots

Take snapshots before risky operations:

```bash
# Shut down VM gracefully
ssh -p 2222 <user>@localhost 'sudo shutdown -h now'

# Create snapshot (on host)
cd /home/stebates/Projects/rocm-axiio/vm-images
qemu-img snapshot -c before_test rocm-axiio-dev.qcow2

# List snapshots
qemu-img snapshot -l rocm-axiio-dev.qcow2

# Restore if needed
qemu-img snapshot -a before_test rocm-axiio-dev.qcow2
```

### Resource Configuration

Customize VM resources:

```bash
# Use 16GB RAM and 8 CPUs
VM_MEMORY=16G VM_CPUS=8 ./scripts/boot-dev-vm.sh

# Enable VNC display
VM_USE_VNC=1 ./scripts/boot-dev-vm.sh

# Use different SSH port
VM_SSH_PORT=2223 ./scripts/boot-dev-vm.sh
```

---

## 🐛 Common Issues and Solutions

### Issue: Cannot SSH into VM

```bash
# Check if port is in use
sudo lsof -i :2222

# Use different port
VM_SSH_PORT=2223 ./scripts/boot-dev-vm.sh
```

### Issue: Shared Folder Not Mounted

```bash
# Inside VM
sudo mount -t 9p -o trans=virtio host0 /mnt/host
```

### Issue: NVMe Not Detected

```bash
# Inside VM
lsmod | grep nvme
sudo modprobe nvme

# Check device
sudo nvme list
ls -la /dev/nvme*
```

### Issue: Kernel Module Won't Load

```bash
# Check Secure Boot status
mokutil --sb-state

# If enabled, either:
# 1. Disable Secure Boot in VM BIOS
# 2. Sign the module (see docs/VM_NVME_TESTING_PLAN.md)
```

### Issue: Build Failures

```bash
# Install dependencies
sudo apt install build-essential cmake libcli11-dev

# Check for hipcc
which hipcc
sudo apt install --reinstall rocm-hip-sdk
```

---

## 📊 Expected Results

### Emulated NVMe Testing

- **Latency:** ~10-50μs (emulation overhead)
- **IOPS:** 100K+ for CPU-only mode
- **Data Integrity:** 100% (zero errors)
- **Stability:** No crashes or kernel panics

### Performance Targets

| Mode | IOPS | Latency | Notes |
|------|------|---------|-------|
| CPU-only (emulated) | 100K+ | 10-50μs | Baseline |
| CPU-only (real HW) | 500K+ | <10μs | With passthrough |
| GPU-direct (goal) | 1M+ | <1μs | Ultimate target |

---

## 🚀 Next Steps

1. **Today:** Create VM and install Ubuntu
   ```bash
   ./scripts/create-dev-vm.sh
   # Follow installation prompts
   ```

2. **Day 1:** Set up development environment
   ```bash
   ./scripts/boot-dev-vm.sh
   # Inside VM: run vm-guest-setup.sh
   ```

3. **Day 2:** Build and test
   ```bash
   # Inside VM
   cd ~/rocm-axiio
   make all
   sudo ./bin/axiio-tester --nvme-device /dev/nvme0 --cpu-only -n 100 -v
   ```

4. **Week 1:** Complete emulated NVMe testing
   - Build kernel module
   - Run comprehensive tests
   - Create clean snapshot

5. **Week 2+:** Optional hardware passthrough testing
   - See docs/VM_NVME_TESTING_PLAN.md Phase 2

---

## 📖 Additional Resources

### Internal Documentation
- `/home/stebates/Projects/rocm-axiio/docs/` - All documentation
- `/home/stebates/Projects/rocm-axiio/scripts/` - Helper scripts

### External Resources
- [QEMU Documentation](https://www.qemu.org/docs/master/)
- [Ubuntu Server Guide](https://ubuntu.com/server/docs)
- [ROCm Documentation](https://rocm.docs.amd.com/)
- [NVMe Specification](https://nvmexpress.org/specifications/)

---

## 💡 Tips

1. **Always take snapshots** before loading kernel modules
2. **Use shared folder** for seamless code editing
3. **Start with emulated NVMe** before real hardware
4. **Monitor dmesg** during tests: `sudo dmesg -wH`
5. **Keep VM resources generous** (8GB+ RAM, 4+ CPUs)
6. **Document your results** in docs/VM_TEST_RESULTS.md

---

## ✨ Summary

Your system is **fully ready** for VM-based testing:

✅ Hardware supports virtualization (AMD-V)  
✅ QEMU and KVM installed and working  
✅ No security restrictions blocking testing  
✅ Scripts ready to create and manage VMs  
✅ Project already built on host  
✅ NVMe devices available (one for passthrough)  

**You can begin VM setup immediately with:**
```bash
cd /home/stebates/Projects/rocm-axiio
./scripts/create-dev-vm.sh
```

---

**Document Version:** 1.0  
**Last Updated:** November 6, 2025  
**Status:** Ready for Implementation

