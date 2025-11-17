# Development and Testing Inside a VM

**Date:** November 6, 2025  
**Objective:** Set up a complete development environment inside a VM for safe rocm-axiio testing

---

## Why Develop Inside a VM?

**Advantages:**
- ✅ **Safety:** Kernel crashes don't affect host system
- ✅ **Isolation:** Test kernel modules without risk
- ✅ **Snapshots:** Save VM state before risky operations
- ✅ **Clean Environment:** Fresh OS for reproducible builds
- ✅ **Parallel Testing:** Run multiple VMs with different configurations
- ✅ **Easy Reset:** Revert to snapshot if something breaks

**Our Approach:**
We'll create a VM with Ubuntu 24.04, install ROCm and build tools, then test rocm-axiio against:
1. **QEMU NVMe emulation** (simplest, always works)
2. **Passed-through real NVMe** (optional, for hardware validation)

---

## Quick Start: 15-Minute Setup

### Step 1: Create VM with Automated Script

```bash
cd /home/stebates/Projects/rocm-axiio
./scripts/create-dev-vm.sh
```

This will:
- Download Ubuntu 24.04 ISO (if needed)
- Create a 50GB VM disk
- Create a 10GB emulated NVMe disk
- Launch VM installer

### Step 2: Boot VM After Installation

```bash
./scripts/boot-dev-vm.sh
```

Access via SSH:
```bash
ssh -p 2222 user@localhost
```

### Step 3: Inside VM - Automated Setup

```bash
# Inside the VM
wget https://raw.githubusercontent.com/.../setup-vm-environment.sh
chmod +x setup-vm-environment.sh
./setup-vm-environment.sh
```

This installs:
- ROCm and HIP compiler
- Build tools (gcc, make, cmake)
- NVMe utilities
- Development libraries

---

## Detailed Setup Guide

### 1. Create Development VM (Host System)

Create `/home/stebates/Projects/rocm-axiio/scripts/create-dev-vm.sh`:

```bash
#!/bin/bash
# Create a development VM for rocm-axiio testing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VM_DIR="$PROJECT_DIR/vm-images"
VM_NAME="rocm-axiio-dev"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=== ROCm-AXIIO Development VM Setup ===${NC}"
echo

# Create directories
mkdir -p "$VM_DIR"
cd "$VM_DIR"

# Check for Ubuntu ISO
UBUNTU_ISO="ubuntu-24.04-server-amd64.iso"
UBUNTU_URL="https://releases.ubuntu.com/24.04/ubuntu-24.04.1-live-server-amd64.iso"

if [ ! -f "$UBUNTU_ISO" ]; then
    echo -e "${YELLOW}Downloading Ubuntu 24.04 ISO (2.6GB)...${NC}"
    echo "This may take 10-20 minutes depending on connection speed"
    wget "$UBUNTU_URL" -O "$UBUNTU_ISO" || {
        echo "Download failed. You can manually download from:"
        echo "  $UBUNTU_URL"
        echo "Place it in: $VM_DIR/$UBUNTU_ISO"
        exit 1
    }
    echo -e "${GREEN}✓ ISO downloaded${NC}"
else
    echo -e "${GREEN}✓ Using existing ISO: $UBUNTU_ISO${NC}"
fi

# Create VM disk (50GB)
VM_DISK="${VM_NAME}.qcow2"
if [ ! -f "$VM_DISK" ]; then
    echo -e "${YELLOW}Creating VM disk (50GB, thin-provisioned)...${NC}"
    qemu-img create -f qcow2 "$VM_DISK" 50G
    echo -e "${GREEN}✓ VM disk created${NC}"
else
    echo -e "${GREEN}✓ Using existing VM disk${NC}"
fi

# Create emulated NVMe disk (10GB)
NVME_DISK="${VM_NAME}-nvme.img"
if [ ! -f "$NVME_DISK" ]; then
    echo -e "${YELLOW}Creating emulated NVMe disk (10GB)...${NC}"
    qemu-img create -f raw "$NVME_DISK" 10G
    echo -e "${GREEN}✓ NVMe disk created${NC}"
else
    echo -e "${GREEN}✓ Using existing NVMe disk${NC}"
fi

# Create cloud-init ISO for automated setup (optional)
CLOUD_INIT_ISO="${VM_NAME}-cloud-init.iso"
if [ ! -f "$CLOUD_INIT_ISO" ]; then
    echo -e "${YELLOW}Creating cloud-init configuration...${NC}"
    
    mkdir -p cloud-init
    
    # meta-data
    cat > cloud-init/meta-data << 'EOF'
instance-id: rocm-axiio-dev-001
local-hostname: rocm-axiio-dev
EOF
    
    # user-data (customize as needed)
    cat > cloud-init/user-data << 'EOF'
#cloud-config
users:
  - name: dev
    groups: sudo, kvm
    shell: /bin/bash
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    ssh_authorized_keys:
      - ssh-rsa AAAAB3... # Add your SSH key here

packages:
  - build-essential
  - git
  - vim
  - wget
  - curl

runcmd:
  - echo "VM initialized" > /tmp/cloud-init-done
EOF
    
    # Create ISO
    if command -v genisoimage &> /dev/null; then
        genisoimage -output "$CLOUD_INIT_ISO" \
                    -volid cidata -joliet -rock \
                    cloud-init/user-data cloud-init/meta-data
        rm -rf cloud-init
        echo -e "${GREEN}✓ Cloud-init ISO created${NC}"
    else
        echo -e "${YELLOW}⚠ genisoimage not found, skipping cloud-init${NC}"
        rm -rf cloud-init
    fi
fi

echo
echo -e "${GREEN}=== VM Setup Complete ===${NC}"
echo
echo "VM Configuration:"
echo "  Name: $VM_NAME"
echo "  Disk: $VM_DISK (50GB)"
echo "  NVMe: $NVME_DISK (10GB)"
echo "  Memory: 8GB"
echo "  CPUs: 4 cores"
echo
echo "Next steps:"
echo "1. Install Ubuntu:"
echo -e "   ${YELLOW}sudo qemu-system-x86_64 \\${NC}"
echo -e "     ${YELLOW}-enable-kvm -cpu host -m 8G -smp 4 \\${NC}"
echo -e "     ${YELLOW}-drive file=$VM_DISK,format=qcow2,if=virtio \\${NC}"
echo -e "     ${YELLOW}-cdrom $UBUNTU_ISO \\${NC}"
echo -e "     ${YELLOW}-boot d \\${NC}"
echo -e "     ${YELLOW}-net nic,model=virtio -net user \\${NC}"
echo -e "     ${YELLOW}-nographic${NC}"
echo
echo "   Or use VNC for graphical installer:"
echo -e "   ${YELLOW}Add: -vnc :0${NC}"
echo -e "   ${YELLOW}Then connect to: localhost:5900${NC}"
echo
echo "2. After installation, boot with:"
echo "   ./scripts/boot-dev-vm.sh"
echo
```

### 2. Boot Script for Development VM

Create `/home/stebates/Projects/rocm-axiio/scripts/boot-dev-vm.sh`:

```bash
#!/bin/bash
# Boot the development VM with NVMe emulation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VM_DIR="$PROJECT_DIR/vm-images"
VM_NAME="rocm-axiio-dev"

VM_DISK="$VM_DIR/${VM_NAME}.qcow2"
NVME_DISK="$VM_DIR/${VM_NAME}-nvme.img"

# Configuration
MEMORY="${VM_MEMORY:-8G}"
CPUS="${VM_CPUS:-4}"
SSH_PORT="${VM_SSH_PORT:-2222}"
VNC_PORT="${VM_VNC_PORT:-0}"  # 0 = :0 = 5900

# Check if VM disk exists
if [ ! -f "$VM_DISK" ]; then
    echo "Error: VM disk not found: $VM_DISK"
    echo "Run ./scripts/create-dev-vm.sh first"
    exit 1
fi

echo "=== Booting ROCm-AXIIO Development VM ==="
echo
echo "Configuration:"
echo "  Memory: $MEMORY"
echo "  CPUs: $CPUS"
echo "  SSH: ssh -p $SSH_PORT dev@localhost"
echo "  Serial console: Ctrl+A, X to quit"
echo

# Build QEMU command
QEMU_CMD=(
    qemu-system-x86_64
    -enable-kvm
    -cpu host
    -m "$MEMORY"
    -smp "$CPUS"
)

# Add main disk
QEMU_CMD+=(
    -drive "file=$VM_DISK,format=qcow2,if=virtio,cache=writeback"
)

# Add emulated NVMe
if [ -f "$NVME_DISK" ]; then
    QEMU_CMD+=(
        -drive "file=$NVME_DISK,if=none,id=nvm0,format=raw"
        -device "nvme,serial=axiiodev001,drive=nvm0"
    )
fi

# Network with SSH port forwarding
QEMU_CMD+=(
    -net nic,model=virtio
    -net "user,hostfwd=tcp::${SSH_PORT}-:22"
)

# Shared folder (host project directory -> guest /mnt/host)
QEMU_CMD+=(
    -virtfs "local,path=$PROJECT_DIR,mount_tag=host0,security_model=passthrough,id=host0"
)

# Display (serial console by default, VNC optional)
if [ -n "${VM_USE_VNC:-}" ]; then
    QEMU_CMD+=(-vnc ":$VNC_PORT")
else
    QEMU_CMD+=(-nographic)
fi

# Execute
echo "Starting VM..."
echo
exec sudo "${QEMU_CMD[@]}"
```

### 3. Inside VM - Environment Setup Script

This script runs **inside the VM** to set up the development environment:

Create `/home/stebates/Projects/rocm-axiio/scripts/vm-guest-setup.sh`:

```bash
#!/bin/bash
# Run this script INSIDE the VM to set up development environment

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}=== ROCm-AXIIO VM Guest Setup ===${NC}"
echo

if [ "$EUID" -eq 0 ]; then
    echo -e "${RED}Error: Do not run as root${NC}"
    echo "Run as regular user (script will use sudo when needed)"
    exit 1
fi

# Update system
echo -e "${YELLOW}[1/6] Updating system packages...${NC}"
sudo apt update
sudo apt upgrade -y

# Install build essentials
echo -e "${YELLOW}[2/6] Installing build tools...${NC}"
sudo apt install -y \
    build-essential \
    cmake \
    git \
    pkg-config \
    libcli11-dev \
    linux-headers-$(uname -r)

# Install NVMe utilities
echo -e "${YELLOW}[3/6] Installing NVMe utilities...${NC}"
sudo apt install -y nvme-cli

# Install ROCm
echo -e "${YELLOW}[4/6] Installing ROCm...${NC}"

# Add ROCm repository
wget https://repo.radeon.com/rocm/rocm.gpg.key -O - | \
    gpg --dearmor | sudo tee /etc/apt/keyrings/rocm.gpg > /dev/null

echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] \
https://repo.radeon.com/rocm/apt/6.2 $(lsb_release -cs) main" | \
    sudo tee /etc/apt/sources.list.d/rocm.list

sudo apt update
sudo apt install -y rocm-hip-sdk rocminfo || {
    echo -e "${YELLOW}⚠ ROCm installation had issues (OK if no GPU)${NC}"
}

# Set environment variables
echo -e "${YELLOW}[5/6] Configuring environment...${NC}"

cat >> ~/.bashrc << 'EOF'

# ROCm-AXIIO environment
export HSA_FORCE_FINE_GRAIN_PCIE=1
export PATH=/opt/rocm/bin:$PATH
export LD_LIBRARY_PATH=/opt/rocm/lib:$LD_LIBRARY_PATH

# Helpful aliases
alias ll='ls -lah'
alias axiio='cd ~/rocm-axiio'
alias build='make clean && make all'
EOF

source ~/.bashrc

# Mount shared folder
echo -e "${YELLOW}[6/6] Setting up shared folder...${NC}"
sudo mkdir -p /mnt/host
cat | sudo tee -a /etc/fstab > /dev/null << 'EOF'
host0 /mnt/host 9p trans=virtio,version=9p2000.L 0 0
EOF
sudo mount -a || echo "Note: Shared folder mount will work after reboot"

# Clone/copy rocm-axiio
echo
echo -e "${YELLOW}Setting up rocm-axiio...${NC}"
if [ -d /mnt/host ]; then
    echo "Creating symlink to host project..."
    ln -sf /mnt/host ~/rocm-axiio
    echo -e "${GREEN}✓ Linked to /mnt/host${NC}"
else
    echo "Host mount not available, clone from repository:"
    echo "  git clone <your-repo-url> ~/rocm-axiio"
fi

echo
echo -e "${GREEN}=== Setup Complete ===${NC}"
echo
echo "Installed:"
echo "  ✓ Build tools (gcc, make, cmake)"
echo "  ✓ NVMe utilities"
echo "  ✓ ROCm runtime"
echo "  ✓ Development libraries"
echo
echo "Next steps:"
echo "1. Reboot (or re-login) to apply environment changes:"
echo "   sudo reboot"
echo
echo "2. After reboot, build rocm-axiio:"
echo "   cd ~/rocm-axiio"
echo "   make all"
echo
echo "3. Check NVMe device:"
echo "   sudo nvme list"
echo "   ls -la /dev/nvme*"
echo
echo "4. Run tests:"
echo "   sudo ./bin/axiio-tester --nvme-device /dev/nvme0 --cpu-only -n 100 --verbose"
echo
```

---

## Working Inside the VM: Complete Workflow

### Daily Development Workflow

**On Host:**
```bash
# Boot VM
cd /home/stebates/Projects/rocm-axiio
./scripts/boot-dev-vm.sh

# In another terminal, SSH into VM
ssh -p 2222 dev@localhost
```

**Inside VM:**
```bash
# Navigate to project (shared from host via 9p)
cd ~/rocm-axiio

# Make changes to code (or edit on host, changes visible in VM)

# Build
make clean
make all

# Run tests with emulated NVMe
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 -n 100 --verbose

# Test kernel module
cd kernel-module
make
sudo insmod nvme_axiio.ko
sudo dmesg | tail -20

# Run with kernel module
sudo ../bin/axiio-tester --nvme-device /dev/nvme0 \
                         --use-kernel-module -n 100 --verbose

# Unload module when done
sudo rmmod nvme_axiio

# Exit VM
exit
```

**On Host (shut down VM):**
```
# In QEMU console: Ctrl+A, X
# Or from SSH: sudo shutdown -h now
```

---

## Testing Scenarios Inside VM

### Scenario 1: Emulated NVMe Testing (Safest)

**Setup:**
- VM has QEMU-emulated NVMe device (10GB raw image)
- No hardware dependencies
- Perfect for development

**Inside VM:**
```bash
# Verify NVMe device
sudo nvme list
# Should show: QEMU NVMe Ctrl

# Identify device
ls -la /dev/nvme*
# Likely: /dev/nvme0, /dev/nvme0n1

# Get device info
sudo nvme id-ctrl /dev/nvme0
sudo nvme id-ns /dev/nvme0n1 -n 1

# Run axiio-tester CPU-only mode
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 \
                        --cpu-only -n 100 --verbose

# Run with emulated endpoint
./bin/axiio-tester --endpoint nvme-ep -n 1000 --verbose

# Performance test
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 \
                        --cpu-only -n 10000 --histogram
```

**Expected Results:**
- ✓ Device detected and accessible
- ✓ All tests pass
- ✓ Latency ~10-50μs (emulation overhead)
- ✓ No data corruption

---

### Scenario 2: Real NVMe Passthrough Testing

**Prerequisites:**
1. One NVMe device (nvme0/c2:00.0) bound to vfio-pci on host
2. Device not used by host OS

**On Host - Bind Device:**
```bash
# Bind WD Black SN850X to vfio-pci
sudo ./scripts/bind-nvme-to-vfio.sh c2:00.0

# Verify
lspci -k -s c2:00.0 | grep vfio
```

**On Host - Boot VM with Passthrough:**
```bash
# Edit boot-dev-vm.sh or create new variant
sudo qemu-system-x86_64 \
  -enable-kvm -cpu host,kvm=off \
  -m 8G -smp 4 \
  -drive file=vm-images/rocm-axiio-dev.qcow2,format=qcow2,if=virtio \
  -device vfio-pci,host=c2:00.0,id=nvme_real \
  -net nic,model=virtio -net user,hostfwd=tcp::2222-:22 \
  -virtfs local,path=$PWD,mount_tag=host0,security_model=passthrough \
  -nographic
```

**Inside VM - Test Real Hardware:**
```bash
# Check device
sudo nvme list
# Should show: Sandisk Corp WD Black SN850X

lspci | grep -i nvme
# Should show real device

# Get actual hardware info
sudo lspci -vvv | grep -A 30 "Non-Volatile memory"

# Run tests with real hardware
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 \
                        --cpu-only -n 100 --verbose

# Data integrity test
sudo ./scripts/test-nvme-io.sh \
     --start-lba 1000000 --num-blocks 16 --iterations 10

# Performance benchmark
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 \
                        --cpu-only -n 10000 --histogram
```

**Expected Results:**
- ✓ Real hardware detected
- ✓ Faster performance (<10μs CPU mode)
- ✓ 100% data integrity
- ✓ Production-like behavior

---

### Scenario 3: Kernel Module Testing

**Inside VM:**
```bash
cd ~/rocm-axiio/kernel-module

# Build module
make clean
make

# Check build
ls -lh nvme_axiio.ko
file nvme_axiio.ko

# Load module
sudo insmod nvme_axiio.ko

# Verify loaded
lsmod | grep nvme_axiio
dmesg | tail -30

# Check device node
ls -la /dev/nvme-axiio

# Run test program
./test_axiio_ioctl

# Run axiio-tester with module
sudo ../bin/axiio-tester --nvme-device /dev/nvme0 \
                         --use-kernel-module \
                         --nvme-queue-id 63 \
                         -n 100 --verbose

# Monitor kernel logs
sudo dmesg -wH &

# Unload when done
sudo rmmod nvme_axiio
```

**Troubleshooting Module Loading:**

If you get "Operation not permitted":
```bash
# Check if Secure Boot is blocking
dmesg | grep -i "lockdown\|signature"

# Option A: Disable Secure Boot in VM
# - Reboot VM
# - Enter BIOS (usually ESC or F2 during boot)
# - Disable Secure Boot
# - Save and boot

# Option B: Use mokutil (if available)
mokutil --disable-validation

# Option C: Sign the module (complex)
# See VM_NVME_TESTING_PLAN.md section 5
```

---

## Snapshot Management

VMs allow you to save state before risky operations!

### Create Snapshot Before Testing

```bash
# On host, shut down VM gracefully
ssh -p 2222 dev@localhost 'sudo shutdown -h now'

# Create snapshot
cd /home/stebates/Projects/rocm-axiio/vm-images
qemu-img snapshot -c before_kernel_module rocm-axiio-dev.qcow2

# List snapshots
qemu-img snapshot -l rocm-axiio-dev.qcow2
```

### Restore Snapshot If Something Breaks

```bash
# Restore to snapshot
cd /home/stebates/Projects/rocm-axiio/vm-images
qemu-img snapshot -a before_kernel_module rocm-axiio-dev.qcow2

# Boot restored VM
cd /home/stebates/Projects/rocm-axiio
./scripts/boot-dev-vm.sh
```

### Useful Snapshot Workflow

```bash
# Before major tests
qemu-img snapshot -c clean_build rocm-axiio-dev.qcow2
qemu-img snapshot -c before_module_test rocm-axiio-dev.qcow2
qemu-img snapshot -c working_state_$(date +%Y%m%d) rocm-axiio-dev.qcow2

# List all snapshots with IDs
qemu-img snapshot -l rocm-axiio-dev.qcow2

# Delete old snapshots
qemu-img snapshot -d snapshot_name rocm-axiio-dev.qcow2
```

---

## Shared Folder Between Host and VM

The 9p virtfs allows live code editing on host with instant availability in VM!

### On Host (edit code):
```bash
cd /home/stebates/Projects/rocm-axiio
vim tester/axiio-tester.hip
# Make changes
```

### In VM (build immediately):
```bash
cd ~/rocm-axiio  # This is linked to /mnt/host
make all
# Changes from host are immediately visible!
```

### Mount Troubleshooting:

If `/mnt/host` is not automatically mounted:
```bash
# Inside VM
sudo mkdir -p /mnt/host
sudo mount -t 9p -o trans=virtio host0 /mnt/host

# Make permanent
echo 'host0 /mnt/host 9p trans=virtio,version=9p2000.L 0 0' | \
  sudo tee -a /etc/fstab
```

---

## Performance Tuning for VM

### Increase VM Resources

Edit `boot-dev-vm.sh` or set environment variables:
```bash
# Use more CPUs
VM_CPUS=8 ./scripts/boot-dev-vm.sh

# Use more memory
VM_MEMORY=16G ./scripts/boot-dev-vm.sh

# Both
VM_CPUS=8 VM_MEMORY=16G ./scripts/boot-dev-vm.sh
```

### Enable Huge Pages (Host)

```bash
# Check current setting
cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages

# Allocate 2GB of huge pages
echo 1024 | sudo tee /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages

# Use in QEMU
# Add to boot script: -mem-path /dev/hugepages -mem-prealloc
```

### CPU Pinning

```bash
# Pin VM CPUs to specific host cores
# Add to boot script:
# -smp 4,sockets=1,cores=4,threads=1
# Then use taskset or cgroups to pin
```

---

## Common Tasks

### Transfer Files to/from VM

**Method 1: Shared folder (recommended)**
```bash
# Files in /home/stebates/Projects/rocm-axiio on host
# Are visible as ~/rocm-axiio in VM
# No copying needed!
```

**Method 2: SCP**
```bash
# Host -> VM
scp -P 2222 file.txt dev@localhost:~/

# VM -> Host
scp -P 2222 dev@localhost:~/results.txt ./
```

**Method 3: Simple HTTP Server**
```bash
# On host
cd /home/stebates/Projects/rocm-axiio
python3 -m http.server 8000

# In VM
wget http://10.0.2.2:8000/file.txt
```

### Check NVMe Device in VM

```bash
# List NVMe controllers
sudo nvme list

# Get detailed info
sudo nvme id-ctrl /dev/nvme0
sudo nvme id-ns /dev/nvme0n1 -n 1

# Check PCI device
lspci | grep -i nvme
sudo lspci -vvv | grep -A 50 "Non-Volatile memory"

# Check device node
ls -la /dev/nvme*
```

### Monitor System During Tests

```bash
# Terminal 1: Run test
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 -n 10000

# Terminal 2: Monitor kernel
sudo dmesg -wH

# Terminal 3: Monitor performance
watch -n 1 'sudo nvme smart-log /dev/nvme0'

# Terminal 4: System stats
htop
```

---

## Testing Checklist

### Initial Setup (One-Time)
- [ ] Create VM with `create-dev-vm.sh`
- [ ] Install Ubuntu in VM
- [ ] Run `vm-guest-setup.sh` inside VM
- [ ] Verify shared folder works
- [ ] Build rocm-axiio successfully
- [ ] Create snapshot "clean_install"

### Daily Development
- [ ] Boot VM with `boot-dev-vm.sh`
- [ ] SSH into VM
- [ ] Pull latest changes (if using git)
- [ ] Build: `make clean && make all`
- [ ] Run basic test
- [ ] Make code changes
- [ ] Rebuild and retest

### Kernel Module Testing
- [ ] Build module: `cd kernel-module && make`
- [ ] Create snapshot before loading
- [ ] Load module: `sudo insmod nvme_axiio.ko`
- [ ] Check dmesg for errors
- [ ] Verify `/dev/nvme-axiio` exists
- [ ] Run axiio-tester with `--use-kernel-module`
- [ ] Unload cleanly: `sudo rmmod nvme_axiio`

### Before Risky Tests
- [ ] Ensure VM is backed up/snapshotted
- [ ] Document current state
- [ ] Have recovery plan ready
- [ ] Test in emulated NVMe first
- [ ] Then test with real hardware

---

## Troubleshooting

### VM Won't Boot

```bash
# Check if VM disk is corrupted
qemu-img check vm-images/rocm-axiio-dev.qcow2

# Try booting with VNC for error messages
VM_USE_VNC=1 ./scripts/boot-dev-vm.sh
# Connect VNC viewer to localhost:5900
```

### Cannot SSH into VM

```bash
# Check if port 2222 is already in use
sudo lsof -i :2222

# Use different port
VM_SSH_PORT=2223 ./scripts/boot-dev-vm.sh

# Check if SSH is running in VM
# (connect via QEMU console)
sudo systemctl status sshd
```

### Shared Folder Not Working

```bash
# Inside VM
sudo mount -t 9p -o trans=virtio,version=9p2000.L host0 /mnt/host

# Check if 9p modules are loaded
lsmod | grep 9p

# Load if missing
sudo modprobe 9pnet_virtio
```

### NVMe Device Not Detected

```bash
# Check QEMU command line
ps aux | grep qemu

# Verify NVMe disk image exists
ls -lh vm-images/rocm-axiio-dev-nvme.img

# Check kernel NVMe driver
lsmod | grep nvme
sudo modprobe nvme
```

### Build Failures

```bash
# Install missing dependencies
sudo apt update
sudo apt install build-essential cmake libcli11-dev

# Check compiler
which hipcc
hipcc --version

# If hipcc missing, reinstall ROCm
sudo apt install --reinstall rocm-hip-sdk
```

---

## Quick Reference

```bash
# === HOST COMMANDS ===

# Create VM
./scripts/create-dev-vm.sh

# Boot VM
./scripts/boot-dev-vm.sh

# SSH into VM
ssh -p 2222 dev@localhost

# Snapshot VM (when VM is shut down)
qemu-img snapshot -c name vm-images/rocm-axiio-dev.qcow2

# === VM COMMANDS ===

# Setup environment (first time only)
./scripts/vm-guest-setup.sh

# Build project
cd ~/rocm-axiio
make clean && make all

# Run tests
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 --cpu-only -n 100 -v

# Load kernel module
cd kernel-module
make
sudo insmod nvme_axiio.ko

# Check status
dmesg | tail -20
lsmod | grep nvme_axiio
ls -la /dev/nvme-axiio

# Unload module
sudo rmmod nvme_axiio
```

---

## Summary

**Working inside a VM provides:**
1. **Safety** - Host system protected from crashes
2. **Flexibility** - Easy snapshots and restore
3. **Reproducibility** - Clean environment
4. **Convenience** - Shared folder with host

**Best practices:**
- Take snapshots before risky operations
- Use shared folder for live code editing
- Test with emulated NVMe first
- Progress to real hardware passthrough only when needed
- Keep kernel module testing contained in VM

**Next Steps:**
1. Run `./scripts/create-dev-vm.sh` on host
2. Install Ubuntu in VM
3. Run `vm-guest-setup.sh` inside VM
4. Start developing and testing!


