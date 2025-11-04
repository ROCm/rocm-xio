# VM NVMe Testing Plan for ROCm-AXIIO

**Date:** November 6, 2025  
**System:** Lenovo ThinkStation P8  
**Infrastructure:** qemu-minimal (gen-vm + run-vm)

---

## Executive Summary

This document provides a comprehensive plan for testing rocm-axiio with **both emulated and real NVMe devices** inside virtual machines. The plan emphasizes using QEMU's built-in NVMe tracing capabilities to validate that doorbell operations and NVMe commands work correctly before progressing to real hardware testing.

**Key Features:**
- ✅ Leverage existing qemu-minimal infrastructure
- ✅ QEMU NVMe tracing for debugging and validation
- ✅ Safe emulated testing before real hardware
- ✅ Real NVMe passthrough for hardware validation
- ✅ GPU + NVMe co-passthrough for complete testing

---

## Table of Contents

1. [Hardware Inventory](#1-hardware-inventory)
2. [System Analysis](#2-system-analysis)
3. [Testing Strategy](#3-testing-strategy)
4. [Tier 1: Emulated NVMe with Tracing](#4-tier-1-emulated-nvme-with-qemu-tracing)
5. [Tier 2: Real NVMe Passthrough](#5-tier-2-real-nvme-passthrough-testing)
6. [Tier 3: GPU + NVMe Co-Passthrough](#6-tier-3-gpu--nvme-co-passthrough)
7. [Testing Schedule](#7-testing-progression-schedule)
8. [Trace Analysis](#8-trace-analysis-guide)
9. [Troubleshooting](#9-troubleshooting)
10. [Quick Reference](#10-quick-reference-commands)

---

## 1. Hardware Inventory

### 1.1 Available for Testing

**NVMe Devices:**
- ✅ **nvme0** (c2:00.0) - **WD Black SN850X** - 2.00 TB
  - Status: Bound to `vfio-pci` 
  - IOMMU Group: 11
  - **Available for passthrough**
  - PCIe Gen4 x4 (16GT/s)
  - Use Case: Real hardware testing

**GPU:**
- ✅ **GPU** (10:00.0) - **AMD Radeon RX 9070 XT** (Navi 48)
  - Status: Bound to `vfio-pci`
  - IOMMU Group: 47
  - **Available for passthrough**
  - PCIe Gen5 x16 (32GT/s)
  - Features: PCIe atomics, 16GB VRAM
  - Use Case: GPU-direct NVMe testing

### 1.2 NOT Available for Testing

**System Devices:**
- ❌ **nvme1** (c1:00.0) - KIOXIA XG8 - 4.10 TB
  - **Root filesystem device** - mounted as `/`
  - Cannot be passed through to VM
  - Must remain with host OS

---

## 2. System Analysis

### 2.1 Security Configuration

**Status: ✅ NO BLOCKING ISSUES**

| Component | Status | Impact |
|-----------|--------|--------|
| Secure Boot | **Enabled** | ⚠️ May need module signing in VM |
| Kernel Lockdown | **none** | ✅ No hardware access restrictions |
| IOMMU | **Enabled (passthrough)** | ✅ Perfect for VFIO |
| /dev/mem | **Accessible** | ✅ Available for hardware mapping |
| PCIe Config | **Accessible** | ✅ setpci works |
| KVM | **Available** | ✅ /dev/kvm present |
| User Groups | **Configured** | ✅ In kvm, libvirt, vfio |

**Kernel Parameters:**
```
amd_iommu=on iommu=pt
```

### 2.2 Software Status

**Installed:**
- ✅ QEMU 8.2.2 (with NVMe emulation and tracing support)
- ✅ KVM modules loaded (kvm_amd)
- ✅ qemu-minimal infrastructure (gen-vm + run-vm)
- ✅ rocm-axiio built (axiio-tester ready)
- ✅ Kernel module built (nvme_axiio.ko)

**Optional:**
- ⚠️ rocminfo not installed on host (not needed for VM testing)

### 2.3 Virtualization Capabilities

**CPU:** AMD EPYC Genoa/Bergamo
- ✅ AMD-V (SVM) enabled
- ✅ Nested page tables
- ✅ AVIC (Advanced Virtual Interrupt Controller)
- ✅ Full virtualization support

**IOMMU Groups:**
- ✅ GPU (10:00.0) in isolated group 47
- ✅ NVMe (c2:00.0) in isolated group 11
- ✅ No conflicts with other devices

---

## 3. Testing Strategy

### 3.1 Three-Tier Approach

**Tier 1: Emulated NVMe with QEMU Tracing** ⭐ **Start Here**
- QEMU-emulated NVMe devices (fully functional)
- Built-in trace support for doorbell operations
- Safe, repeatable, fast iteration
- Perfect for development and debugging
- **Goal:** Validate NVMe protocol implementation

**Tier 2: Real NVMe Passthrough**
- Physical WD Black SN850X passed to VM
- Real hardware behavior validation
- Performance benchmarking
- Production-like testing
- **Goal:** Hardware validation and performance metrics

**Tier 3: GPU + NVMe Co-Passthrough**
- Both GPU and NVMe devices in VM
- Complete GPU-direct I/O validation
- ROCm inside VM
- Ultimate integration testing
- **Goal:** End-to-end GPU-direct NVMe I/O

### 3.2 Why This Order?

1. **Safety First:** Emulated devices can't damage hardware
2. **Fast Iteration:** QEMU tracing provides immediate feedback
3. **Debugging:** Trace logs reveal protocol issues early
4. **Confidence:** Validate correctness before hardware
5. **Incremental:** Each tier builds on previous success

### 3.3 Testing Tools

**qemu-minimal Infrastructure:**
- `gen-vm` - Creates VMs with cloud-init
- `run-vm` - Runs VMs with flexible hardware config
- Built-in NVMe emulation and tracing
- Shared filesystem (9p/virtfs) support
- PCIe passthrough (VFIO) ready

---

## 4. Tier 1: Emulated NVMe with QEMU Tracing

### 4.1 Overview

Test rocm-axiio with QEMU-emulated NVMe devices while capturing detailed trace information about doorbell writes, command submissions, and completions.

**Benefits:**
- ✅ Completely safe (no real hardware)
- ✅ Built-in QEMU tracing
- ✅ Instant reset capability
- ✅ Multiple NVMe devices easily
- ✅ Perfect for debugging

### 4.2 Step 1: Create Development VM

```bash
cd /home/stebates/Projects/qemu-minimal/qemu

# Create VM with development packages
VM_NAME=rocm-axiio \
VCPUS=4 \
VMEM=8192 \
SIZE=64 \
PACKAGES=../packages.d/packages-default \
./gen-vm

# Wait for cloud-init to complete (~5-10 minutes)
# VM will automatically shut down when ready
```

**What this creates:**
- Ubuntu 24.04 (Noble) VM
- 4 vCPUs, 8GB RAM, 64GB disk
- Default development packages (gcc, make, git, etc.)
- User: `ubuntu`, Password: `password`
- SSH port: 2222

### 4.3 Step 2: Boot VM with Emulated NVMe and Tracing

```bash
cd /home/stebates/Projects/qemu-minimal/qemu

# Boot with 2 NVMe devices and doorbell tracing enabled
VM_NAME=rocm-axiio \
NVME=2 \
NVME_TRACE=doorbell \
NVME_TRACE_FILE=/tmp/rocm-axiio-nvme-trace.log \
FILESYSTEM=/home/stebates/Projects/rocm-axiio \
VCPUS=4 \
VMEM=8192 \
./run-vm
```

**What this does:**
- Creates 2 emulated NVMe devices (1TB each)
- Enables QEMU NVMe doorbell tracing
- Logs all doorbell operations to `/tmp/rocm-axiio-nvme-trace.log`
- Shares rocm-axiio project directory with VM via 9p
- 4 vCPUs, 8GB RAM for adequate performance

**Trace Options:**
- `NVME_TRACE=doorbell` - Track doorbell writes only
- `NVME_TRACE=all` - Trace all NVMe events
- `NVME_TRACE=pci_nvme_read,pci_nvme_write` - Custom events

### 4.4 Step 3: Setup VM Environment

**SSH into VM:**
```bash
# From another terminal
ssh -p 2222 ubuntu@localhost
# Password: password
```

**Install ROCm and tools:**
```bash
# Add ROCm repository
wget https://repo.radeon.com/rocm/rocm.gpg.key -O - | \
  gpg --dearmor | sudo tee /etc/apt/keyrings/rocm.gpg > /dev/null

echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] \
https://repo.radeon.com/rocm/apt/6.2 noble main" | \
  sudo tee /etc/apt/sources.list.d/rocm.list

# Install ROCm and development tools
sudo apt update
sudo apt install -y \
    rocm-hip-sdk \
    rocminfo \
    libcli11-dev \
    nvme-cli \
    linux-headers-$(uname -r) \
    vim \
    htop

# Set environment variables
cat >> ~/.bashrc << 'EOF'
export HSA_FORCE_FINE_GRAIN_PCIE=1
export PATH=/opt/rocm/bin:$PATH
export LD_LIBRARY_PATH=/opt/rocm/lib:$LD_LIBRARY_PATH
alias axiio='cd /mnt/rocm-axiio'
alias nvmes='sudo nvme list'
EOF

source ~/.bashrc
```

**Mount shared folder:**
```bash
# Mount rocm-axiio project from host
sudo mkdir -p /mnt/rocm-axiio
sudo mount -t 9p -o trans=virtio,version=9p2000.L hostfs /mnt/rocm-axiio

# Make it permanent
echo 'hostfs /mnt/rocm-axiio 9p trans=virtio,version=9p2000.L,nofail 0 1' | \
  sudo tee -a /etc/fstab

# Create symlink for convenience
ln -s /mnt/rocm-axiio ~/rocm-axiio
```

### 4.5 Step 4: Verify NVMe Devices

```bash
# List NVMe devices
sudo nvme list

# Expected output:
# Node              Model                           Namespace  Size
# /dev/nvme0n1      QEMU NVMe Ctrl                  1          1.07 TB
# /dev/nvme1n1      QEMU NVMe Ctrl                  1          1.07 TB

# Check PCI devices
lspci | grep -i nvme
# Should show: QEMU NVM Express Controller

# Check device nodes
ls -la /dev/nvme*
# Should show /dev/nvme0, /dev/nvme0n1, /dev/nvme1, /dev/nvme1n1

# Get device details
sudo nvme id-ctrl /dev/nvme0
sudo nvme id-ns /dev/nvme0n1 -n 1
```

### 4.6 Step 5: Build rocm-axiio

```bash
cd ~/rocm-axiio

# Build
make clean
make all

# Verify build
ls -lh bin/axiio-tester
ls -lh lib/librocm-axiio.a
ls -lh kernel-module/nvme_axiio.ko

# Quick test (no hardware, emulated endpoint)
./bin/axiio-tester --endpoint nvme-ep -n 10 --verbose
```

### 4.7 Step 6: Run Tests with Doorbell Tracing

**Terminal 1 (VM):**
```bash
cd ~/rocm-axiio

# Run basic test with CPU-only mode
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 \
                        --cpu-only -n 100 --verbose
```

**Terminal 2 (Host):**
```bash
# Monitor trace in real-time
tail -f /tmp/rocm-axiio-nvme-trace.log

# Expected trace output:
# pci_nvme_mmio_doorbell_sq sq_tail=1 doorbell_addr=0x1000 qid=0
# pci_nvme_mmio_doorbell_cq cq_head=1 doorbell_addr=0x1004 qid=0
# pci_nvme_mmio_doorbell_sq sq_tail=2 doorbell_addr=0x1000 qid=0
# ...
```

**What to look for:**
- ✅ SQ (submission queue) doorbell writes
- ✅ CQ (completion queue) doorbell writes
- ✅ Doorbell addresses match expected offsets
- ✅ Queue IDs are valid (0 = admin, >0 = I/O queues)
- ✅ Tail/head pointers increment correctly

### 4.8 Step 7: Comprehensive Testing with Different Trace Modes

**Test 1: Basic functionality with doorbell tracing**
```bash
# On host - boot VM with doorbell tracing
cd /home/stebates/Projects/qemu-minimal/qemu
VM_NAME=rocm-axiio \
NVME=2 \
NVME_TRACE=doorbell \
NVME_TRACE_FILE=/tmp/test1-doorbell.log \
FILESYSTEM=/home/stebates/Projects/rocm-axiio \
./run-vm

# In VM - run test
cd ~/rocm-axiio
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 --cpu-only -n 100 -v

# On host - analyze trace
echo "Total doorbell operations:"
cat /tmp/test1-doorbell.log | grep doorbell | wc -l

echo "Submission queue doorbells:"
cat /tmp/test1-doorbell.log | grep "doorbell_sq" | wc -l

echo "Completion queue doorbells:"
cat /tmp/test1-doorbell.log | grep "doorbell_cq" | wc -l

echo "First 20 operations:"
cat /tmp/test1-doorbell.log | grep doorbell | head -20
```

**Test 2: All NVMe events tracing**
```bash
# On host - boot with full tracing
VM_NAME=rocm-axiio \
NVME=2 \
NVME_TRACE=all \
NVME_TRACE_FILE=/tmp/test2-all-events.log \
FILESYSTEM=/home/stebates/Projects/rocm-axiio \
./run-vm

# In VM - run test
cd ~/rocm-axiio
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 --cpu-only -n 50 -v

# On host - analyze all events
echo "All NVMe events:"
cat /tmp/test2-all-events.log | grep pci_nvme | head -100

echo "Read operations:"
cat /tmp/test2-all-events.log | grep pci_nvme_read | wc -l

echo "Write operations:"
cat /tmp/test2-all-events.log | grep pci_nvme_write | wc -l
```

**Test 3: Performance test with histogram**
```bash
# In VM
cd ~/rocm-axiio
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 \
                        --cpu-only -n 10000 --histogram

# Check trace for any anomalies
cat /tmp/rocm-axiio-nvme-trace.log | grep doorbell | tail -100
```

### 4.9 Step 8: Kernel Module Testing with Tracing

```bash
# In VM
cd ~/rocm-axiio/kernel-module

# Build module
make clean
make

# Load module
sudo insmod nvme_axiio.ko

# Verify module loaded
lsmod | grep nvme_axiio
dmesg | tail -30

# Check device node created
ls -la /dev/nvme-axiio

# Run axiio-tester with kernel module
sudo ../bin/axiio-tester --nvme-device /dev/nvme0 \
                         --use-kernel-module \
                         --nvme-queue-id 63 \
                         -n 100 --verbose

# On host - check trace for queue 63 activity
cat /tmp/rocm-axiio-nvme-trace.log | grep "qid=63"

# Monitor kernel messages during test
sudo dmesg -wH

# Unload module when done
sudo rmmod nvme_axiio
```

**If module loading fails (Secure Boot):**
```bash
# Check if Secure Boot is blocking
dmesg | grep -i "signature\|lockdown"

# Option 1: Disable Secure Boot in VM
# Reboot VM, enter BIOS/UEFI (press ESC during boot)
# Navigate to Security → Secure Boot → Disabled
# Save and reboot

# Option 2: Disable validation
mokutil --disable-validation
# Follow prompts, reboot
```

### 4.10 Step 9: Data Integrity Testing

```bash
# In VM
cd ~/rocm-axiio

# Test with data buffers and verification
sudo ./scripts/test-nvme-io.sh \
     --start-lba 1000000 \
     --num-blocks 32 \
     --pattern random \
     --iterations 100

# Expected: 100% success rate, MD5 checksums match
```

### 4.11 Step 10: Trace Analysis

Create a trace analysis script on host:

```bash
# On host
cat > /tmp/analyze-nvme-trace.sh << 'EOF'
#!/bin/bash
# Analyze NVMe trace output

TRACEFILE=${1:-/tmp/rocm-axiio-nvme-trace.log}

echo "=== NVMe Trace Analysis ==="
echo "Trace file: $TRACEFILE"
echo

if [ ! -f "$TRACEFILE" ]; then
    echo "Error: Trace file not found!"
    exit 1
fi

echo "Total doorbell operations:"
grep -c doorbell "$TRACEFILE" || echo "0"

echo
echo "Submission queue doorbells:"
grep -c "doorbell_sq" "$TRACEFILE" || echo "0"

echo
echo "Completion queue doorbells:"
grep -c "doorbell_cq" "$TRACEFILE" || echo "0"

echo
echo "Unique queue IDs accessed:"
grep doorbell "$TRACEFILE" | grep -oP 'qid=\K[0-9]+' | sort -u | xargs

echo
echo "Doorbell addresses accessed:"
grep doorbell "$TRACEFILE" | grep -oP 'doorbell_addr=\K[0-9a-fx]+' | sort -u | xargs

echo
echo "First 10 doorbell operations:"
grep doorbell "$TRACEFILE" | head -10

echo
echo "Last 10 doorbell operations:"
grep doorbell "$TRACEFILE" | tail -10

echo
echo "Queue activity summary:"
for qid in $(grep doorbell "$TRACEFILE" | grep -oP 'qid=\K[0-9]+' | sort -u); do
    sq_count=$(grep "qid=$qid" "$TRACEFILE" | grep -c "doorbell_sq")
    cq_count=$(grep "qid=$qid" "$TRACEFILE" | grep -c "doorbell_cq")
    echo "  Queue $qid: $sq_count submissions, $cq_count completions"
done
EOF

chmod +x /tmp/analyze-nvme-trace.sh

# Run analysis
/tmp/analyze-nvme-trace.sh /tmp/rocm-axiio-nvme-trace.log
```

### 4.12 Expected Results - Tier 1

**Success Criteria:**
- ✅ 2 emulated NVMe devices detected (`/dev/nvme0`, `/dev/nvme1`)
- ✅ All axiio-tester tests pass
- ✅ Doorbell operations visible in trace logs
- ✅ Submission queue writes precede completion queue reads
- ✅ Queue IDs are valid (0, 1, 63, etc.)
- ✅ Doorbell addresses are correct (0x1000, 0x1004, etc.)
- ✅ Kernel module loads successfully
- ✅ No segmentation faults or kernel panics
- ✅ Data integrity: 100% (zero mismatches)
- ✅ Performance: ~10-50μs (emulation overhead is acceptable)

**Trace Validation:**
- SQ doorbell count ≈ CQ doorbell count (within 1-2)
- Doorbell addresses match NVMe specification
- Queue activity matches test iterations
- No doorbell operations to invalid addresses

---

## 5. Tier 2: Real NVMe Passthrough Testing

### 5.1 Overview

Pass through the physical WD Black SN850X (c2:00.0) to the VM for real hardware validation and performance benchmarking.

**Benefits:**
- ✅ Real hardware behavior
- ✅ True performance metrics
- ✅ Hardware-accurate testing
- ✅ Production validation

**Note:** QEMU tracing is not available for passed-through devices since they're real hardware, not emulated.

### 5.2 Prerequisites

Verify device is ready for passthrough:

```bash
# On host
# Check device is bound to vfio-pci
lspci -k -s c2:00.0 | grep vfio
# Should show: Kernel driver in use: vfio-pci

# Verify IOMMU group
find /sys/kernel/iommu_groups/ -type l | grep c2:00.0
# Should show: /sys/kernel/iommu_groups/11/devices/0000:c2:00.0

# Confirm device is not mounted
mount | grep nvme0
# Should be empty (no output)
```

### 5.3 Step 1: Boot VM with Real NVMe

```bash
cd /home/stebates/Projects/qemu-minimal/qemu

# Pass through WD Black SN850X to VM
VM_NAME=rocm-axiio-hw \
PCI_HOSTDEV=0000:c2:00.0 \
FILESYSTEM=/home/stebates/Projects/rocm-axiio \
VCPUS=4 \
VMEM=8192 \
SSH_PORT=2222 \
./run-vm
```

**What this does:**
- Passes through real NVMe device via VFIO
- Shares rocm-axiio project directory
- 4 vCPUs, 8GB RAM
- SSH on port 2222

### 5.4 Step 2: Verify Real Hardware in VM

```bash
# SSH into VM
ssh -p 2222 ubuntu@localhost

# Check device
lspci | grep -i "nvme\|sandisk"
# Should show: Sandisk Corp WD Black SN850X NVMe SSD

sudo nvme list
# Should show: WD Black SN850X (real device, not QEMU)
# Model: WD Black SN850X
# Size: ~2TB (actual capacity)

# Get detailed device info
sudo nvme id-ctrl /dev/nvme0
# Should show real controller info

sudo nvme id-ns /dev/nvme0n1 -n 1
# Should show real namespace info

# Check PCI details
sudo lspci -vvv | grep -A 50 "Non-Volatile"
# Should show real hardware capabilities
```

### 5.5 Step 3: Basic Testing with Real Hardware

```bash
cd ~/rocm-axiio

# Basic CPU-only test
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 \
                        --cpu-only -n 100 --verbose

# Quick performance check
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 \
                        --cpu-only -n 1000 --histogram

# Data integrity test
sudo ./scripts/test-nvme-io.sh \
     --start-lba 10000000 \
     --num-blocks 32 \
     --pattern random \
     --iterations 50
```

### 5.6 Step 4: Performance Benchmarking

```bash
cd ~/rocm-axiio

# Large-scale performance test
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 \
                        --cpu-only -n 10000 --histogram

# Different transfer sizes
for size in 512 4096 8192 16384 65536; do
    echo "Testing with transfer size: $size bytes"
    sudo ./bin/axiio-tester --nvme-device /dev/nvme0 \
                            --cpu-only \
                            --transfer-size $size \
                            -n 1000 --histogram
done

# Sequential vs Random access patterns
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 \
                        --cpu-only \
                        --access-pattern sequential \
                        -n 5000

sudo ./bin/axiio-tester --nvme-device /dev/nvme0 \
                        --cpu-only \
                        --access-pattern random \
                        -n 5000
```

### 5.7 Step 5: Kernel Module with Real Hardware

```bash
cd ~/rocm-axiio/kernel-module

# Ensure module is built
make clean && make

# Load kernel module
sudo insmod nvme_axiio.ko

# Verify module loaded
lsmod | grep nvme_axiio
dmesg | tail -30

# Check device node
ls -la /dev/nvme-axiio

# Test with kernel module
sudo ../bin/axiio-tester --nvme-device /dev/nvme0 \
                         --use-kernel-module \
                         --nvme-queue-id 63 \
                         -n 1000 --verbose

# Performance with kernel module
sudo ../bin/axiio-tester --nvme-device /dev/nvme0 \
                         --use-kernel-module \
                         -n 10000 --histogram

# Monitor kernel messages
sudo dmesg -wH

# Unload module
sudo rmmod nvme_axiio
```

### 5.8 Step 6: Stress Testing

```bash
cd ~/rocm-axiio

# Long-running stress test
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 \
                        --cpu-only -n 100000

# Data integrity stress test
sudo ./scripts/test-nvme-io.sh \
     --start-lba 20000000 \
     --num-blocks 64 \
     --pattern random \
     --iterations 500

# Monitor SMART data during test
sudo nvme smart-log /dev/nvme0
```

### 5.9 Step 7: Compare Emulated vs Real Performance

```bash
# Create comparison script on host
cat > /tmp/compare-performance.sh << 'EOF'
#!/bin/bash
echo "=== Performance Comparison: Emulated vs Real NVMe ==="
echo
echo "From Tier 1 testing (emulated):"
echo "  Average latency: ~10-50μs"
echo "  IOPS: ~100K (emulated)"
echo "  Overhead: QEMU emulation"
echo
echo "From Tier 2 testing (real hardware):"
echo "  Average latency: <10μs (expected)"
echo "  IOPS: 500K+ (expected)"
echo "  Overhead: Minimal (native hardware)"
echo
echo "Performance improvement expected: 5-10x"
echo
echo "Check VM test output and histogram data for actual numbers."
EOF

chmod +x /tmp/compare-performance.sh
/tmp/compare-performance.sh
```

### 5.10 Expected Results - Tier 2

**Success Criteria:**
- ✅ Real WD Black SN850X detected in VM
- ✅ Device reports actual capacity (2TB)
- ✅ All tests pass with real hardware
- ✅ Better performance than emulated (<10μs vs ~50μs)
- ✅ Hardware-accurate behavior
- ✅ No data corruption (100% integrity)
- ✅ Kernel module works with real hardware
- ✅ SMART data accessible
- ✅ Performance metrics meet expectations

**Expected Performance:**
- **Latency:** <10μs (vs ~50μs emulated)
- **IOPS:** 500K+ (vs ~100K emulated)
- **Bandwidth:** Near native NVMe performance
- **Reliability:** 100% data integrity across thousands of operations

---

## 6. Tier 3: GPU + NVMe Co-Passthrough

### 6.1 Overview

Pass through both the AMD Radeon RX 9070 XT GPU and WD Black SN850X NVMe to enable complete GPU-direct NVMe testing inside the VM.

**Goal:** Validate end-to-end GPU-direct I/O where the GPU directly writes NVMe doorbells without CPU intervention.

### 6.2 Hardware Configuration

**GPU:** AMD Radeon RX 9070 XT (10:00.0)
- Model: Navi 48 (RDNA 4 architecture)
- Already bound to vfio-pci ✅
- IOMMU Group: 47
- PCIe Gen5 x16 (32GT/s)
- 16GB VRAM
- Support for PCIe atomics

**NVMe:** WD Black SN850X (c2:00.0)
- Already bound to vfio-pci ✅
- IOMMU Group: 11
- PCIe Gen4 x4 (16GT/s)
- 2TB capacity

**Both devices in separate IOMMU groups** ✅ - No conflicts

### 6.3 Step 1: Verify Both Devices Ready

```bash
# On host
# Check GPU
lspci -k -s 10:00.0 | grep vfio
# Should show: Kernel driver in use: vfio-pci

# Check NVMe
lspci -k -s c2:00.0 | grep vfio
# Should show: Kernel driver in use: vfio-pci

# Verify separate IOMMU groups
find /sys/kernel/iommu_groups/ -type l | grep -E "10:00.0|c2:00.0"
# Should show both in different groups (47 and 11)

# Check device details
lspci -vvv -s 10:00.0 | head -20
lspci -vvv -s c2:00.0 | head -20
```

### 6.4 Step 2: Boot VM with GPU and NVMe

```bash
cd /home/stebates/Projects/qemu-minimal/qemu

# Pass through both GPU and NVMe
VM_NAME=rocm-axiio-gpu \
PCI_HOSTDEV=0000:10:00.0,0000:c2:00.0 \
FILESYSTEM=/home/stebates/Projects/rocm-axiio \
VCPUS=8 \
VMEM=16384 \
SSH_PORT=2222 \
./run-vm
```

**What this does:**
- Passes through GPU (10:00.0) for ROCm
- Passes through NVMe (c2:00.0) for storage
- 8 vCPUs (more for GPU workloads)
- 16GB RAM (adequate for GPU + system)
- Shared rocm-axiio folder

### 6.5 Step 3: Verify Both Devices in VM

```bash
# SSH into VM
ssh -p 2222 ubuntu@localhost

# Check GPU
lspci | grep -i "vga\|display\|amd"
# Should show: AMD/ATI Navi 48 [Radeon RX 9070]

# Check NVMe
lspci | grep -i "nvme\|sandisk"
# Should show: Sandisk Corp WD Black SN850X

# List all PCI devices
lspci
```

### 6.6 Step 4: Install ROCm with GPU Support

```bash
# In VM
# ROCm repository should already be added from Tier 1
# If not, add it:
wget https://repo.radeon.com/rocm/rocm.gpg.key -O - | \
  gpg --dearmor | sudo tee /etc/apt/keyrings/rocm.gpg > /dev/null

echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] \
https://repo.radeon.com/rocm/apt/6.2 noble main" | \
  sudo tee /etc/apt/sources.list.d/rocm.list

# Install ROCm components
sudo apt update
sudo apt install -y rocm-hip-sdk rocminfo libcli11-dev

# Add user to groups
sudo usermod -aG video $USER
sudo usermod -aG render $USER

# Reboot to apply group changes
sudo reboot
```

### 6.7 Step 5: Verify GPU Detected by ROCm

```bash
# After reboot, SSH back in
ssh -p 2222 ubuntu@localhost

# Check ROCm detects GPU
rocminfo | grep -i "name\|gfx"
# Should show: gfxNNN (e.g., gfx1200 for RDNA4)

# Check /dev/kfd (Kernel Fusion Driver)
ls -la /dev/kfd
# Should exist and be accessible

# Check /dev/dri
ls -la /dev/dri/
# Should show render nodes

# Verify hipcc
which hipcc
hipcc --version
```

### 6.8 Step 6: Build rocm-axiio with GPU Support

```bash
cd ~/rocm-axiio

# Set environment for GPU
export HSA_FORCE_FINE_GRAIN_PCIE=1
export PATH=/opt/rocm/bin:$PATH
export LD_LIBRARY_PATH=/opt/rocm/lib:$LD_LIBRARY_PATH

# Clean and rebuild
make clean
make all

# Verify GPU code in binary
file bin/axiio-tester
# Should show GPU architecture (amdgcn)
```

### 6.9 Step 7: GPU-Direct Testing Without Kernel Module

```bash
cd ~/rocm-axiio

# Set required environment
export HSA_FORCE_FINE_GRAIN_PCIE=1

# Basic GPU test (may use CPU-hybrid mode if kernel module not loaded)
sudo -E ./bin/axiio-tester --nvme-device /dev/nvme0 \
                            -n 100 --verbose

# Check for GPU page faults
sudo dmesg | grep -i "gpu\|fault\|page"
# Should be clean (no faults)

# Performance test
sudo -E ./bin/axiio-tester --nvme-device /dev/nvme0 \
                            -n 1000 --histogram
```

### 6.10 Step 8: GPU-Direct with Kernel Module

```bash
cd ~/rocm-axiio/kernel-module

# Build kernel module
make clean && make

# Load module
sudo insmod nvme_axiio.ko

# Verify loaded
lsmod | grep nvme_axiio
dmesg | tail -30
ls -la /dev/nvme-axiio

# GPU-direct test with kernel module
export HSA_FORCE_FINE_GRAIN_PCIE=1
sudo -E ../bin/axiio-tester --nvme-device /dev/nvme0 \
                             --use-kernel-module \
                             --nvme-queue-id 63 \
                             -n 1000 --verbose

# Large-scale GPU-direct test
sudo -E ../bin/axiio-tester --nvme-device /dev/nvme0 \
                             --use-kernel-module \
                             -n 10000 --histogram

# Monitor for GPU page faults
sudo dmesg -wH | grep -i "gpu\|fault\|amdgpu"
# Should be clean

# Unload module
sudo rmmod nvme_axiio
```

### 6.11 Step 9: Complete GPU-Direct Validation

```bash
cd ~/rocm-axiio

# Data integrity with GPU-direct
sudo -E ./bin/axiio-tester --nvme-device /dev/nvme0 \
                            --use-kernel-module \
                            --use-data-buffers \
                            --test-pattern random \
                            -n 1000

# Performance comparison
echo "=== GPU-Direct Performance Test ==="
sudo -E ./bin/axiio-tester --nvme-device /dev/nvme0 \
                            --use-kernel-module \
                            -n 10000 --histogram

# Stress test
sudo -E ./bin/axiio-tester --nvme-device /dev/nvme0 \
                            --use-kernel-module \
                            -n 100000
```

### 6.12 Step 10: Validate GPU Doorbell Operations

```bash
# Monitor kernel logs for doorbell activity
sudo dmesg | grep -i "doorbell\|queue\|nvme_axiio"

# Check HSA memory locking
sudo dmesg | grep -i "hsa\|memory"

# Verify no page faults occurred
sudo dmesg | grep -i "page fault" | wc -l
# Should be 0

# Check GPU utilization (if monitoring tools available)
rocm-smi
```

### 6.13 Expected Results - Tier 3

**Success Criteria:**
- ✅ AMD Radeon RX 9070 XT detected in VM
- ✅ ROCm runtime functional (rocminfo succeeds)
- ✅ /dev/kfd present and accessible
- ✅ WD Black SN850X detected and functional
- ✅ axiio-tester builds with GPU code
- ✅ GPU-direct doorbell writes succeed
- ✅ No GPU page faults in dmesg
- ✅ Kernel module loads successfully
- ✅ HSA memory locking works
- ✅ Performance meets expectations
- ✅ Zero data corruption
- ✅ Complete end-to-end GPU-direct NVMe I/O validated

**Expected Performance:**
- **Latency:** <1μs (GPU-direct mode)
- **IOPS:** 1M+ (with GPU-direct)
- **CPU Usage:** Minimal (GPU handles doorbell)
- **Data Integrity:** 100%

**What Success Looks Like:**
```
GPU writes NVMe command → GPU writes doorbell → NVMe processes → Completion
                    (no CPU involvement)
```

---

## 7. Testing Progression Schedule

### Week 1: Tier 1 - Emulated NVMe with Tracing

| Day | Task | Deliverable |
|-----|------|-------------|
| **Mon** | Create VM, install ROCm, mount shared folder | Environment ready |
| **Tue** | Run basic tests with doorbell tracing | Trace logs collected |
| **Wed** | Test kernel module with emulated NVMe | Module functional |
| **Thu** | Comprehensive testing with all trace modes | All trace scenarios validated |
| **Fri** | Analyze traces, document findings | Week 1 report complete |

**Milestone:** Emulated NVMe fully validated with trace evidence

### Week 2: Tier 2 - Real NVMe Hardware

| Day | Task | Deliverable |
|-----|------|-------------|
| **Mon** | Boot VM with NVMe passthrough | Real hardware accessible |
| **Tue** | Run all tests with real NVMe | Hardware validation complete |
| **Wed** | Performance benchmarking | Metrics collected |
| **Thu** | Data integrity stress testing | Reliability confirmed |
| **Fri** | Compare emulated vs real, document | Week 2 report complete |

**Milestone:** Real NVMe hardware fully validated

### Week 3: Tier 3 - GPU + NVMe Integration

| Day | Task | Deliverable |
|-----|------|-------------|
| **Mon** | Boot VM with GPU+NVMe passthrough | Both devices accessible |
| **Tue** | Install ROCm, verify GPU functionality | GPU operational |
| **Wed** | GPU-direct testing without kernel module | Basic GPU-NVMe works |
| **Thu** | GPU-direct with kernel module | Complete integration |
| **Fri** | Final validation, comprehensive documentation | Project complete |

**Milestone:** Complete GPU-direct NVMe I/O validated

---

## 8. Trace Analysis Guide

### 8.1 Understanding NVMe Traces

**Doorbell Write Format:**
```
pci_nvme_mmio_doorbell_sq sq_tail=N doorbell_addr=ADDR qid=Q
```
- `sq_tail`: New submission queue tail pointer (increments as commands submitted)
- `doorbell_addr`: Physical address of doorbell register
- `qid`: Queue ID (0 = admin queue, 1+ = I/O queues)

**Completion Queue Format:**
```
pci_nvme_mmio_doorbell_cq cq_head=N doorbell_addr=ADDR qid=Q
```
- `cq_head`: New completion queue head pointer (increments as completions processed)
- Indicates host has processed completed commands

### 8.2 Validating Correct Behavior

**Expected Pattern:**
1. SQ doorbell write (submit command)
2. Command processing (internal NVMe operations)
3. CQ entry written by controller
4. CQ doorbell write (acknowledge completion)
5. Repeat

**Example Good Trace:**
```
pci_nvme_mmio_doorbell_sq sq_tail=1 doorbell_addr=0x1000 qid=0
pci_nvme_mmio_doorbell_cq cq_head=1 doorbell_addr=0x1004 qid=0
pci_nvme_mmio_doorbell_sq sq_tail=2 doorbell_addr=0x1000 qid=0
pci_nvme_mmio_doorbell_cq cq_head=2 doorbell_addr=0x1004 qid=0
```

**Red Flags:**
- ❌ CQ doorbells without preceding SQ doorbells
- ❌ Doorbell writes to invalid addresses
- ❌ Queue IDs outside expected range (typically 0-63)
- ❌ Tail/head pointers not incrementing
- ❌ No doorbell activity during test runs

### 8.3 Trace Analysis Scripts

**Count Operations:**
```bash
TRACEFILE=/tmp/rocm-axiio-nvme-trace.log

# Total doorbell operations
cat "$TRACEFILE" | grep doorbell | wc -l

# Submission queue doorbells
cat "$TRACEFILE" | grep "doorbell_sq" | wc -l

# Completion queue doorbells
cat "$TRACEFILE" | grep "doorbell_cq" | wc -l

# Should be approximately equal (within a few operations)
```

**Find Queue Activity:**
```bash
# List all queue IDs accessed
cat "$TRACEFILE" | grep doorbell | grep -oP 'qid=\K[0-9]+' | sort -u

# Count operations per queue
for qid in $(cat "$TRACEFILE" | grep -oP 'qid=\K[0-9]+' | sort -u); do
    sq=$(grep "qid=$qid" "$TRACEFILE" | grep -c "doorbell_sq")
    cq=$(grep "qid=$qid" "$TRACEFILE" | grep -c "doorbell_cq")
    echo "Queue $qid: $sq submissions, $cq completions"
done
```

**Timeline Analysis:**
```bash
# First 50 operations
cat "$TRACEFILE" | grep doorbell | head -50

# Last 50 operations
cat "$TRACEFILE" | grep doorbell | tail -50

# Operations for specific queue
cat "$TRACEFILE" | grep "qid=63" | grep doorbell
```

**Doorbell Address Validation:**
```bash
# List all doorbell addresses used
cat "$TRACEFILE" | grep doorbell | grep -oP 'doorbell_addr=\K[0-9a-fx]+' | sort -u

# Expected addresses (NVMe spec):
# Admin SQ: BAR0 + 0x1000
# Admin CQ: BAR0 + 0x1004
# I/O Queue N SQ: BAR0 + 0x1000 + (2 * N * doorbell_stride)
# I/O Queue N CQ: BAR0 + 0x1004 + (2 * N * doorbell_stride)
```

### 8.4 Correlation with Test Output

Compare trace events with test output:

```bash
# In VM - run test with iteration count
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 --cpu-only -n 100 -v

# On host - count doorbell operations
cat /tmp/rocm-axiio-nvme-trace.log | grep doorbell_sq | wc -l

# Should correlate with number of NVMe commands issued
# For 100 iterations, expect ~100-200 doorbell operations (depending on command batching)
```

---

## 9. Troubleshooting

### 9.1 VM Issues

**Problem: VM won't boot**
```bash
# Check if VM disk exists
ls -lh /home/stebates/Projects/qemu-minimal/images/rocm-axiio.qcow2

# Check if VM is already running
ps aux | grep qemu | grep rocm-axiio

# Try with VNC to see boot messages
VM_NAME=rocm-axiio NVME=2 VNC=:0 ./run-vm
# Connect VNC viewer to localhost:5900
```

**Problem: Cannot SSH into VM**
```bash
# Check if port 2222 is in use
sudo lsof -i :2222

# Try different SSH port
VM_NAME=rocm-axiio SSH_PORT=2223 NVME=2 ./run-vm

# Check if SSH is running in VM (via QEMU console)
# In QEMU console:
systemctl status sshd
```

### 9.2 Shared Folder Issues

**Problem: /mnt/rocm-axiio is empty**
```bash
# In VM
# Check if 9p module loaded
lsmod | grep 9p
sudo modprobe 9pnet_virtio

# Manual mount
sudo mount -t 9p -o trans=virtio,version=9p2000.L hostfs /mnt/rocm-axiio

# Check if host specified FILESYSTEM
# On host, ensure you used:
FILESYSTEM=/home/stebates/Projects/rocm-axiio ./run-vm
```

### 9.3 NVMe Device Issues

**Problem: No NVMe devices in VM (emulated)**
```bash
# In VM
# Check if NVMe driver loaded
lsmod | grep nvme
sudo modprobe nvme

# Check PCI devices
lspci | grep -i nvme

# Check device nodes
ls -la /dev/nvme*

# On host, verify NVME variable was set
cd /home/stebates/Projects/qemu-minimal/qemu
VM_NAME=rocm-axiio NVME=2 ./run-vm  # Ensure NVME=2
```

**Problem: No NVMe device in VM (passthrough)**
```bash
# On host
# Verify device is bound to vfio-pci
lspci -k -s c2:00.0

# If bound to nvme driver, rebind to vfio-pci
echo "0000:c2:00.0" | sudo tee /sys/bus/pci/drivers/nvme/unbind
echo "1987 5018" | sudo tee /sys/bus/pci/drivers/vfio-pci/new_id

# Use vfio-setup script from qemu-minimal
cd /home/stebates/Projects/qemu-minimal/qemu
sudo HOST_ADDR=0000:c2:00.0 ./vfio-setup
```

### 9.4 Tracing Issues

**Problem: No trace output**
```bash
# On host
# Check if trace file was created
ls -la /tmp/rocm-axiio-nvme-trace.log

# Verify NVME_TRACE variable was set
# Correct:
NVME_TRACE=doorbell NVME_TRACE_FILE=/tmp/trace.log ./run-vm

# Check QEMU command line (while VM running)
ps aux | grep qemu | grep trace
```

**Problem: Trace file is empty**
```bash
# Ensure test actually runs in VM
# In VM:
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 --cpu-only -n 10 -v

# Check trace immediately after
cat /tmp/rocm-axiio-nvme-trace.log

# Try with NVME_TRACE=all to see all events
NVME_TRACE=all NVME_TRACE_FILE=/tmp/trace.log ./run-vm
```

### 9.5 Kernel Module Issues

**Problem: Module won't load (Secure Boot)**
```bash
# In VM
# Check dmesg for signature errors
dmesg | grep -i "signature\|lockdown\|module"

# Solution 1: Disable Secure Boot
# Reboot VM, enter UEFI (ESC during boot)
# Security → Secure Boot → Disabled

# Solution 2: Check if mokutil available
mokutil --sb-state
mokutil --disable-validation
```

**Problem: Module loads but /dev/nvme-axiio missing**
```bash
# In VM
# Check module loaded
lsmod | grep nvme_axiio

# Check dmesg for errors
sudo dmesg | grep nvme_axiio

# Check major/minor numbers
ls -la /dev/nvme-axiio

# If missing, check module init
dmesg | grep "character device"
```

### 9.6 GPU Issues (Tier 3)

**Problem: GPU not detected by ROCm**
```bash
# In VM
# Check if GPU is present via PCI
lspci | grep -i "vga\|display\|amd"

# Check /dev/kfd
ls -la /dev/kfd

# Check /dev/dri
ls -la /dev/dri/

# Try loading amdgpu module
sudo modprobe amdgpu

# Check dmesg for amdgpu init
sudo dmesg | grep amdgpu
```

**Problem: GPU page faults**
```bash
# In VM
# Ensure HSA environment variable set
echo $HSA_FORCE_FINE_GRAIN_PCIE
# Should output: 1

# Set if not present
export HSA_FORCE_FINE_GRAIN_PCIE=1

# Run test with sudo -E to preserve environment
sudo -E ./bin/axiio-tester --nvme-device /dev/nvme0 -n 10 -v

# Check for page faults
sudo dmesg | grep -i "page fault"
```

### 9.7 Build Issues

**Problem: make fails in VM**
```bash
# In VM
# Install dependencies
sudo apt update
sudo apt install -y build-essential cmake libcli11-dev

# Check for hipcc
which hipcc
/opt/rocm/bin/hipcc --version

# If hipcc missing
sudo apt install rocm-hip-sdk

# Clean and rebuild
cd ~/rocm-axiio
make clean
make all
```

---

## 10. Quick Reference Commands

### Create VM
```bash
cd /home/stebates/Projects/qemu-minimal/qemu
VM_NAME=rocm-axiio VCPUS=4 VMEM=8192 SIZE=64 ./gen-vm
```

### Boot VM - Tier 1 (Emulated with Tracing)
```bash
cd /home/stebates/Projects/qemu-minimal/qemu
VM_NAME=rocm-axiio \
NVME=2 \
NVME_TRACE=doorbell \
NVME_TRACE_FILE=/tmp/nvme-trace.log \
FILESYSTEM=/home/stebates/Projects/rocm-axiio \
./run-vm
```

### Boot VM - Tier 2 (Real NVMe)
```bash
cd /home/stebates/Projects/qemu-minimal/qemu
VM_NAME=rocm-axiio-hw \
PCI_HOSTDEV=0000:c2:00.0 \
FILESYSTEM=/home/stebates/Projects/rocm-axiio \
./run-vm
```

### Boot VM - Tier 3 (GPU + NVMe)
```bash
cd /home/stebates/Projects/qemu-minimal/qemu
VM_NAME=rocm-axiio-gpu \
PCI_HOSTDEV=0000:10:00.0,0000:c2:00.0 \
FILESYSTEM=/home/stebates/Projects/rocm-axiio \
VCPUS=8 VMEM=16384 \
./run-vm
```

### SSH into VM
```bash
ssh -p 2222 ubuntu@localhost  # Password: password
```

### In VM - Quick Setup
```bash
# Mount shared folder
sudo mount -t 9p -o trans=virtio,version=9p2000.L hostfs /mnt/rocm-axiio
ln -s /mnt/rocm-axiio ~/rocm-axiio

# Build
cd ~/rocm-axiio
make clean && make all

# Test
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 --cpu-only -n 100 -v
```

### On Host - Trace Analysis
```bash
# Monitor trace in real-time
tail -f /tmp/nvme-trace.log

# Analyze doorbell operations
cat /tmp/nvme-trace.log | grep doorbell | wc -l
cat /tmp/nvme-trace.log | grep doorbell_sq | wc -l
cat /tmp/nvme-trace.log | grep doorbell_cq | wc -l

# Show first operations
cat /tmp/nvme-trace.log | grep doorbell | head -20
```

### Reset VM
```bash
cd /home/stebates/Projects/qemu-minimal/qemu
VM_NAME=rocm-axiio RESTORE_IMAGE=true ./gen-vm
```

---

## 11. Success Criteria Summary

### Tier 1: Emulated NVMe + Tracing ✅
- [ ] VM boots with 2 emulated NVMe devices
- [ ] QEMU trace captures all doorbell operations
- [ ] axiio-tester passes all tests (CPU-only mode)
- [ ] Trace shows correct SQ→processing→CQ pattern
- [ ] Doorbell addresses match NVMe specification
- [ ] Kernel module loads and functions correctly
- [ ] Zero segfaults, crashes, or page faults
- [ ] Data integrity: 100%

### Tier 2: Real NVMe Hardware ✅
- [ ] WD Black SN850X accessible in VM
- [ ] Device reports correct capacity (2TB)
- [ ] All tests pass with real hardware
- [ ] Performance better than emulated (<10μs vs ~50μs)
- [ ] Data integrity validated (100+ iterations, 100% success)
- [ ] Kernel module works with real device
- [ ] SMART data accessible
- [ ] No hardware errors

### Tier 3: GPU + NVMe Integration ✅
- [ ] Both GPU (10:00.0) and NVMe (c2:00.0) in VM
- [ ] ROCm detects AMD Radeon RX 9070 XT (rocminfo works)
- [ ] /dev/kfd present and accessible
- [ ] axiio-tester builds with GPU code
- [ ] GPU-direct doorbell writes succeed
- [ ] No GPU page faults
- [ ] HSA memory locking works
- [ ] Performance: <1μs latency, 1M+ IOPS
- [ ] Zero data corruption
- [ ] Complete end-to-end GPU-direct validation

---

## 12. Documentation and Reporting

### Create Test Reports

```bash
# On host
cat > /home/stebates/Projects/rocm-axiio/docs/TEST_RESULTS.md << 'EOF'
# ROCm-AXIIO Test Results

## Test Environment
- Date: YYYY-MM-DD
- System: Lenovo ThinkStation P8
- Infrastructure: qemu-minimal

## Tier 1: Emulated NVMe (Tracing)
- Status: PASS/FAIL
- NVMe Devices: 2 QEMU NVMe emulated
- Trace File: /tmp/nvme-trace.log
- Doorbell Operations: [count]
- Test Iterations: 100
- Data Integrity: 100%
- Notes: [observations]

## Tier 2: Real NVMe Hardware
- Status: PASS/FAIL
- Device: WD Black SN850X (c2:00.0)
- Performance: [latency, IOPS]
- Data Integrity: [%]
- Notes: [observations]

## Tier 3: GPU + NVMe
- Status: PASS/FAIL
- GPU: AMD Radeon RX 9070 XT (10:00.0)
- NVMe: WD Black SN850X (c2:00.0)
- GPU-Direct: YES/NO
- Performance: [latency, IOPS]
- Notes: [observations]
EOF
```

---

## Summary

**You're ready to start comprehensive testing!**

Your system provides everything needed:

✅ **Emulated NVMe** - Safe development with QEMU tracing  
✅ **Real NVMe** - WD Black SN850X (c2:00.0) ready for passthrough  
✅ **GPU** - Radeon RX 9070 XT (10:00.0) ready for GPU-direct testing  
✅ **Infrastructure** - qemu-minimal scripts battle-tested  
✅ **IOMMU** - Enabled and properly configured  
✅ **Security** - No blocking issues  

**Start testing now:**
```bash
cd /home/stebates/Projects/qemu-minimal/qemu
VM_NAME=rocm-axiio VCPUS=4 VMEM=8192 ./gen-vm
```

Then progress through:
1. **Week 1:** Emulated NVMe with trace validation
2. **Week 2:** Real NVMe hardware validation
3. **Week 3:** Complete GPU-direct integration

---

**Document Version:** 2.0  
**Last Updated:** November 6, 2025  
**Status:** Ready for Implementation  
**Focus:** Emulated + Real NVMe + GPU Integration + QEMU Tracing
