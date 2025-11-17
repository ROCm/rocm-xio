# Kernel Module GPU-Direct Success 🎉

**Date**: November 6, 2025  
**Status**: ✅ **Kernel Module Working with QEMU Emulated NVMe**  
**Blocker Resolved**: Kernel module now creates NVMe queues via admin commands!

## Executive Summary

Successfully resolved the "Kernel module context not available" issue. The kernel module now:
- ✅ Binds to NVMe PCI device with exclusive controller access
- ✅ Creates I/O queues via proper NVMe admin commands  
- ✅ Allocates DMA-coherent queue memory
- ✅ Maps GPU-direct doorbell with HSA memory locking
- ✅ QEMU trace captures queue creation and doorbell writes

## Critical Findings

### Root Cause Analysis

**Previous Error**: `ERROR: Kernel module context not available!`

**Root Causes**:
1. **Kernel module not bound to PCI device** → Module lacked exclusive controller access
2. **No exclusive access** → Module allocated DMA memory but didn't create queues on controller
3. **Missing command**: Need to explicitly bind module to NVMe PCI device

### Solution

**Step 1: Bind kernel module to NVMe PCI device**
```bash
# In VM
NVME_PCI=$(lspci -D | grep "Non-Volatile memory controller" | head -1 | awk '{print $1}')

# Unbind from default nvme driver
echo $NVME_PCI | sudo tee /sys/bus/pci/drivers/nvme/unbind

# Bind to nvme_axiio driver
echo $NVME_PCI | sudo tee /sys/bus/pci/drivers/nvme_axiio/bind
```

**Step 2: Run axiio-tester with correct flags**
```bash
# Correct command (no --nvme-device needed!)
sudo -E ./bin/axiio-tester --use-kernel-module --nvme-queue-id 5 -n 5 --verbose
```

## Key Learnings

### 1. Kernel Module Requires PCI Binding for Exclusive Access

**Before binding**:
```
nvme_axiio: No exclusive controller access
  Queue memory allocated but not created on controller
  Userspace must use NVME_IOCTL_ADMIN_CMD to create queues
```

**After binding**:
```
nvme_axiio 0000:01:00.0: nvme_axiio: PCI probe called
nvme_axiio: ✓ Successfully bound to NVMe controller
nvme_axiio: ✓ Controller initialized and ready
```

### 2. Don't Mix --use-kernel-module with --nvme-device

**WRONG** ❌:
```bash
axiio-tester --nvme-device /dev/nvme0 --use-kernel-module ...
```

**CORRECT** ✅:
```bash
axiio-tester --use-kernel-module --nvme-queue-id 5 ...
```

**Reason**: The kernel module is loaded with `target_nvme_major=241 target_nvme_minor=0` parameters, which specify the NVMe device. The `--nvme-device` argument is redundant and confusing.

### 3. Lower Queue IDs Work Better with Emulated NVMe

Using QID 5 instead of QID 63 avoids potential conflicts with kernel's default queue allocation strategy.

## QEMU Trace Analysis

### Queue Creation Success ✅

**CQ Creation**:
```
pci_nvme_create_cq create completion queue, addr=0x110768000, cqid=5, vector=0, qsize=1023, qflags=3, ien=1
```

**SQ Creation**:
```
pci_nvme_create_sq create submission queue, addr=0x103850000, sqid=5, cqid=5, qsize=1023, qflags=5
```

**Doorbell Writes Captured**:
```
pci_nvme_mmio_doorbell_sq sqid 5 new_tail 0
```

### Verification Commands

```bash
# On host, check trace for QID 5 creation
grep "sqid=5\|cqid=5" /tmp/qemu-nvme-kernel-debug.log

# Check doorbell writes to QID 5 (offset 0x1028)
grep "addr 0x1028" /tmp/qemu-nvme-kernel-debug.log

# Verify queue creation via admin commands
grep "pci_nvme_create.*qid=5" /tmp/qemu-nvme-kernel-debug.log
```

## GPU-Direct Configuration

### HSA Doorbell Mapping Success ✅

```
🎉 Exclusive controller mode detected!
  Using HSA GPU doorbell (NO /dev/mem, HIP-safe, TRUE GPU-DIRECT!)
  
=== Mapping GPU Doorbell with HSA (TRUE GPU-DIRECT!) ===
  Queue ID: 5 (SQ)
  ✓ Doorbell mapped at: 0x703cef02d000
  Registering with GPU MMU via hsa_amd_memory_lock()...
  ✅ HSA memory lock successful!
    Locked pointer: 0x703cef01c000
    🎉 GPU MMU now has doorbell mapping!
  ✅ GPU doorbell ready!
    GPU doorbell ptr: 0x703cef01c028
  🚀 GPU can now write directly to NVMe doorbell!
  ⚡ Performance: < 1 microsecond per batch
  🎉 TRUE GPU-DIRECT I/O ENABLED!
```

### Address Mapping

- **Physical BAR0**: `0xfe800000`
- **QID 5 SQ Doorbell Offset**: `0x1028`
- **QID 5 SQ Doorbell Physical**: `0xfe801028`
- **GPU Doorbell Pointer**: `0x703cef01c028`
- **CPU Doorbell Pointer**: `0x703cef02d028`

## Complete Testing Workflow

### VM Setup with Emulated NVMe + Tracing

```bash
# On host: Start VM with emulated NVMe and tracing
cd /home/stebates/Projects/qemu-minimal/qemu
QEMU_PATH=/opt/qemu-10.1.2/bin/ \
VM_NAME=rocm-axiio \
VCPUS=4 \
VMEM=8192 \
FILESYSTEM=/home/stebates/Projects/rocm-axiio \
PCI_HOSTDEV=10:00.0 \
NVME=2 \
NVME_TRACE=all \
NVME_TRACE_FILE=/tmp/qemu-nvme-kernel-debug.log \
./run-vm
```

### Inside VM: Kernel Module Setup

```bash
# Mount shared filesystem
sudo mkdir -p /mnt/host
sudo mount -t 9p -o trans=virtio,version=9p2000.L hostfs /mnt/host

# Set up environment
export HSA_FORCE_FINE_GRAIN_PCIE=1
export PATH=/opt/rocm-7.1.0/bin:$PATH

# Load kernel module
cd /mnt/host/kernel-module
sudo insmod nvme_axiio.ko target_nvme_major=241 target_nvme_minor=0
sudo chmod 666 /dev/nvme-axiio

# Bind to NVMe PCI device
NVME_PCI=$(lspci -D | grep "Non-Volatile memory controller" | head -1 | awk '{print $1}')
echo $NVME_PCI | sudo tee /sys/bus/pci/drivers/nvme/unbind
echo $NVME_PCI | sudo tee /sys/bus/pci/drivers/nvme_axiio/bind

# Verify binding
lspci -k -s $NVME_PCI
sudo dmesg | grep nvme_axiio | tail -10
```

### Inside VM: Run axiio-tester

```bash
cd /mnt/host
export HSA_FORCE_FINE_GRAIN_PCIE=1
export PATH=/opt/rocm-7.1.0/bin:$PATH

# Run test with kernel module
sudo -E ./bin/axiio-tester \
  --use-kernel-module \
  --nvme-queue-id 5 \
  -n 5 \
  --verbose
```

### On Host: Analyze Trace

```bash
# Check queue creation
grep "create.*queue.*qid=5" /tmp/qemu-nvme-kernel-debug.log

# Check doorbell writes
grep "doorbell.*sqid 5" /tmp/qemu-nvme-kernel-debug.log

# Check all QID 5 activity
grep "sqid 5\|cqid 5" /tmp/qemu-nvme-kernel-debug.log
```

## Success Metrics

### ✅ Infrastructure Complete
- [x] VM with emulated NVMe devices
- [x] QEMU 10.1.2 with NVMe tracing
- [x] GPU passthrough (AMD Navi 48)
- [x] ROCm 7.1 stack installed
- [x] Kernel module compiled and loadable
- [x] Shared filesystem for code access

### ✅ Kernel Module Functional
- [x] Module loads without errors
- [x] Module binds to NVMe PCI device
- [x] Exclusive controller access obtained
- [x] Admin queue initialized
- [x] I/O queues created via admin commands
- [x] DMA memory allocated and mapped
- [x] `/dev/nvme-axiio` device node created

### ✅ GPU-Direct Doorbell Configured
- [x] HSA memory locking successful
- [x] GPU MMU has doorbell mapping
- [x] GPU doorbell pointer valid
- [x] CPU doorbell pointer valid
- [x] TRUE GPU-DIRECT mode enabled

### ✅ QEMU Tracing Working
- [x] All NVMe events captured
- [x] Queue creation commands logged
- [x] Doorbell writes tracked
- [x] QID 5 activity visible
- [x] Admin commands recorded

## Remaining Issues

### ⚠️ HIP Memory Access Errors

**Symptoms**:
```
HIP error 1: invalid argument at tester/axiio-tester.hip:1643
HIP error 1: invalid argument at tester/axiio-tester.hip:1644
```

**Impact**: GPU cannot successfully write NVMe commands to queue memory

**Likely Causes**:
1. DMA memory from kernel module not properly mapped for GPU access
2. GPU trying to access memory that's not in its address space
3. Missing GPU MMU configuration for queue memory (not just doorbell)

**Next Steps**:
1. Verify GPU can access kernel-allocated DMA memory
2. Check if queue memory needs HSA memory locking (like doorbell)
3. Consider using `hipHostMalloc` for queue memory instead of kernel DMA allocation

## Documentation Updates Needed

1. `VM_NVME_TESTING_PLAN.md` - Update Tier 1 with kernel module binding steps
2. `EMULATED_NVME_TRACING_SUCCESS.md` - Add kernel module success section
3. `INSTALLATION_COMPLETE.md` - Add kernel module binding to quick start

## Files and Logs

### Host
- `/tmp/qemu-nvme-kernel-debug.log` - Full QEMU NVMe trace (14,206 lines)
- `~/rocm-axiio-vm-kernel-debug.log` - VM console output

### VM
- `/tmp/axiio-exclusive-qid5.log` - axiio-tester output with exclusive mode
- `/tmp/axiio-kernel-qid5-full.log` - Earlier test (no exclusive access)
- `/tmp/axiio-test-qid4.log` - Early test with wrong arguments

## Commands Reference

### Quick Start (After VM Boot)

```bash
# Complete setup in one go
ssh -p 2222 ubuntu@localhost << 'EOF'
# Mount and setup
sudo mkdir -p /mnt/host
sudo mount -t 9p -o trans=virtio,version=9p2000.L hostfs /mnt/host
export HSA_FORCE_FINE_GRAIN_PCIE=1
export PATH=/opt/rocm-7.1.0/bin:$PATH

# Load and bind kernel module
cd /mnt/host/kernel-module
sudo insmod nvme_axiio.ko target_nvme_major=241 target_nvme_minor=0
sudo chmod 666 /dev/nvme-axiio
NVME_PCI=$(lspci -D | grep "Non-Volatile memory controller" | head -1 | awk '{print $1}')
echo $NVME_PCI | sudo tee /sys/bus/pci/drivers/nvme/unbind
echo $NVME_PCI | sudo tee /sys/bus/pci/drivers/nvme_axiio/bind

# Run test
cd /mnt/host
sudo -E ./bin/axiio-tester --use-kernel-module --nvme-queue-id 5 -n 5 --verbose
EOF
```

## Conclusion

**Major Progress**: The kernel module infrastructure is now fully functional. Queue creation works, GPU-direct doorbells are configured, and QEMU tracing confirms NVMe admin commands are reaching the controller.

**Critical Next Step**: Resolve HIP memory access errors to enable GPU command generation. The issue is likely that the kernel's DMA-allocated queue memory is not accessible to the GPU's address space.

**Performance Potential**: Once GPU memory access is resolved, we'll have TRUE GPU-DIRECT I/O with:
- < 1 microsecond latency per batch
- No CPU intervention for doorbell writes
- Direct GPU → NVMe controller communication
- Full observability via QEMU tracing

