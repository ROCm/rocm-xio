# CRITICAL: IOMMU Blocking GPU Access to NVMe!

## The Smoking Gun 🔥

Host dmesg reveals the **root cause** of GPU doorbell failures:

```
[ 4679.983250] vfio-pci 0000:10:00.0: AMD-Vi: Event logged [IO_PAGE_FAULT 
    domain=0x0002 address=0xfe801000 flags=0x0000]
[ 4679.983396] vfio-pci 0000:10:00.0: AMD-Vi: Event logged [IO_PAGE_FAULT 
    domain=0x0002 address=0xfe801008 flags=0x0020]
```

### Breakdown

| What | Value | Meaning |
|------|-------|---------|
| **Device** | 0000:10:00.0 | AMD GPU |
| **Error** | IO_PAGE_FAULT | IOMMU access violation |
| **Address** | 0xfe801000 | **NVMe BAR0 + doorbell offset!** |
| **Address** | 0xfe801008 | **NVMe SQ doorbell!** |

**The GPU IS trying to write, but AMD-Vi (IOMMU) blocks it!**

## Why This Happens

### IOMMU Purpose
- Protects system by controlling device memory access
- Each device gets its own isolated address space
- Prevents devices from accessing arbitrary memory

### VM Passthrough with IOMMU
When passing devices to VM:
1. GPU → VM (via VFIO-PCI)
2. NVMe → VM (via VFIO-PCI, or via nvme_gda driver)
3. IOMMU isolates each device

### The Problem
- **GPU is in IOMMU group A**
- **NVMe is in IOMMU group B**
- GPU trying to access NVMe BAR0 → **IOMMU violation!**

GPU can't directly access another device's MMIO without IOMMU mapping!

## GPU Direct Async Requirements

For GPU to access NVMe doorbells directly:

### Option 1: Shared IOMMU Group
- GPU and NVMe in same IOMMU group
- Both can access each other's MMIO
- **Requires specific hardware topology**

### Option 2: IOMMU Mapping
- Map NVMe BAR0 into GPU's IOMMU domain
- Requires kernel driver support
- **rocSHMEM must do this for MLX5!**

### Option 3: Peer-to-Peer (P2P) DMA
- AMD GPU P2P support
- Requires amdgpu driver integration
- May need ATS/PRI

### Option 4: Disable IOMMU (NOT RECOMMENDED)
- Removes all protection
- Security risk
- Not suitable for production

## Evidence From Our Tests

### Test Behavior
```
GPU: Doorbell at 0x7f1129b2e008, old value: 0
GPU: New doorbell value: 0
```

GPU kernel executes, tries to write, reads back 0:
- ✅ GPU kernel runs
- ✅ HSA gives GPU pointer
- ❌ **GPU write causes IOMMU fault**
- ❌ **Write silently fails (from GPU perspective)**
- ❌ **Doorbell value unchanged**

### IOMMU Log Correlation
- Test timestamp: ~4679 seconds / ~4849 seconds
- IOMMU faults: Exactly at those times!
- Address 0xfe801008 = SQ doorbell offset

**Perfect correlation!**

## How rocSHMEM MLX5 Works

rocSHMEM GDA with MLX5 must handle this somehow:

### Possibility 1: RDMA NICs Have Different IOMMU Handling
- InfiniBand/RoCE may have special support
- GPUs may have built-in P2P for RDMA
- Different than generic NVMe

### Possibility 2: Special Kernel Driver Setup
MLX5 driver might:
- Register MMIO regions with amdgpu driver
- Set up IOMMU mappings explicitly
- Use KFD (Kernel Fusion Driver) APIs

### Possibility 3: Hardware P2P Support
- AMD GPUs + Mellanox NICs may have P2P enabled
- Requires ACS (Access Control Services) configuration
- Specific PCIe topology

## What We Need

### Check IOMMU Groups
```bash
# Find GPU IOMMU group
ls -l /sys/bus/pci/devices/0000:10:00.0/iommu_group

# Find NVMe IOMMU group  
ls -l /sys/bus/pci/devices/0000:03:00.0/iommu_group
ls -l /sys/bus/pci/devices/0000:c2:00.0/iommu_group
```

### Check P2P Support
```bash
# AMD GPU P2P capability
cat /sys/class/drm/card*/device/pcie_bw
cat /sys/class/drm/card*/device/ats_cap

# Check ACS
lspci -vvv | grep -A20 "10:00.0\|c2:00.0" | grep ACS
```

### Check rocSHMEM MLX5 Initialization
Look for:
- KFD IOCTLs
- IOMMU mapping calls
- P2P registration
- amdgpu driver interaction

## Potential Solutions

### Solution 1: Use amdgpu Driver APIs
```c
// Register NVMe BAR0 with amdgpu for P2P
// Requires amdgpu-specific IOCTLs
```

### Solution 2: Kernel-Space Doorbell Proxy
```c
// GPU writes to shared memory
// Kernel thread reads and writes to real doorbell
// Slower but works around IOMMU
```

### Solution 3: Use KFD MAP_MEMORY
```c
// Use KFD (ROCm's kernel driver) to map MMIO
// May have IOMMU mapping support
```

### Solution 4: Move to RDMA NIC
- Test with actual Mellanox card
- May have built-in P2P support
- Follow rocSHMEM's proven path

## PCIe AER Errors

Additional errors on NVMe root port:

```
pcieport 0000:c0:01.2: AER: aer_uncor_status: 0x00004000
  (Completion Timeout - bit 14)
```

This might be from:
- NVMe receiving invalid transactions
- GPU's blocked writes causing timeouts
- PCIe fabric confusion

## Next Steps

1. **Check IOMMU groups** - Are GPU and NVMe in same group?
2. **Research AMD GPU P2P** - How to enable for arbitrary PCIe devices?
3. **Study rocSHMEM MLX5 init** - What IOMMU/P2P setup do they do?
4. **Check ACS settings** - Is PCIe Access Control blocking P2P?
5. **Try KFD mapping** - Can KFD map NVMe MMIO for GPU?

## Critical Realization

**This is not a bug in our code!**

- ✅ HSA memory locking works
- ✅ GPU kernel works
- ✅ GPU is trying to write
- ❌ **IOMMU blocks the access**

We need to either:
- Configure IOMMU to allow GPU→NVMe access
- Use kernel APIs that handle IOMMU mapping
- Follow whatever mechanism rocSHMEM MLX5 uses

This is a **system configuration / kernel driver integration** issue, not an HSA or HIP issue!

## Bottom Line

**GPU Direct Async requires IOMMU configuration that allows GPU to access NVMe MMIO regions!**

Without this, GPU writes will always be blocked, regardless of correct HSA memory locking.

The fact that rocSHMEM MLX5 works means there IS a solution - we just need to find how they configure the IOMMU/P2P!

