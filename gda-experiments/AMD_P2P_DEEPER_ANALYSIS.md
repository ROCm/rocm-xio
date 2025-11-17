# AMD P2P - Deeper Analysis

## What AMD P2P Actually Is

### CONFIG_HSA_AMD_P2P
From kernel documentation:
```
Enables peer-to-peer communication between AMD GPUs over the PCIe bus.
Improves performance of multi-GPU compute applications by allowing GPUs
to access data directly in peer GPUs' memory without intermediate copies.

Requirements:
- Compatible chipsets  
- GPUs with Large Memory BARs
- BARs must expose entire VRAM in PCIe address space
- Within physical address limits of the GPUs
```

**Key Point:** This is for **GPU-to-GPU** communication, not GPU-to-arbitrary-device!

## rocSHMEM Really Only Uses HSA Locking

### No Special IOCTLs
Search results show:
- ❌ No KFD IOCTLs in rocSHMEM GDA code
- ❌ No DRM IOCTLs
- ❌ No special amdgpu calls
- ✅ Only `hsa_amd_memory_lock_to_pool()`

### What `hsa_amd_memory_lock_to_pool()` Does

From HSA specification:
```c
hsa_amd_memory_lock_to_pool(
    void* host_ptr,                  // Host memory to lock
    size_t size,                     // Size to lock
    hsa_agent_t* agents,             // Agents to lock for
    int num_agent,                   // Number of agents
    hsa_amd_memory_pool_t pool,      // Pool to use
    uint32_t flags,                  // Flags  
    void** agent_ptr                 // Output: GPU-accessible pointer
);
```

**Purpose:** Makes host memory GPU-accessible by:
1. Pinning pages in memory
2. Creating GPU page table entries
3. **For MMIO:** Maps physical addresses into GPU's address space

## The Key Question

**If rocSHMEM doesn't do anything special, why does it work for RDMA but not NVMe?**

### Possible Answers

#### 1. Large BAR Requirement

AMD P2P requires "Large Memory BARs" - but this is for GPU VRAM, not NIC MMIO!

Check our system:
```bash
# GPU BAR size
lspci -vv -s 10:00.0 | grep "Memory at"
# Expect: Large BAR if P2P enabled (e.g., 16GB+)

# NVMe BAR size  
lspci -vv -s c2:00.0 | grep "Memory at"
# Expect: Small (16KB typical)
```

#### 2. NIC Firmware/Hardware Support

InfiniBand/RDMA NICs might have:
- Firmware that expects GPU access
- Hardware support for GPU-initiated transactions
- Relaxed address validation
- Different PCIe transaction types

NVMe controllers:
- Not designed for GPU access
- May reject non-CPU transactions
- Strict PCIe compliance

#### 3. PCIe Topology

rocSHMEM might only work when:
- NIC and GPU under same PCIe root complex
- No ACS (Access Control Services) blocking
- Direct P2P path available

Check our topology:
```bash
# Find PCIe root for GPU
lspci -tv | grep -A5 "10:00.0"

# Find PCIe root for NVMe
lspci -tv | grep -A5 "c2:00.0"
```

#### 4. IOMMU Passthrough vs Isolation

The IOMMU page faults we see suggest:
- GPU and NVMe in different IOMMU domains
- No mapping exists for GPU → NVMe

But why would it work for RDMA?

**Hypothesis:** RDMA NICs might be:
- In same IOMMU group as GPU
- Or IOMMU in passthrough mode for that group
- Or NIC driver registers with IOMMU differently

## What We Should Check

### 1. System Configuration

```bash
# IOMMU mode
cat /proc/cmdline | grep iommu

# P2P kernel config
grep CONFIG_HSA_AMD_P2P /boot/config-$(uname -r)

# Check if ACS is disabled (needed for P2P)
lspci -vvv | grep ACSCtl
```

### 2. PCIe Topology

```bash
# Full PCIe tree
lspci -tv

# Check if GPU and NVMe are on same root complex
# Check for PCIe switches between them
```

### 3. IOMMU Groups Detail

```bash
# All devices in GPU's IOMMU group
ls -l /sys/kernel/iommu_groups/47/devices/

# All devices in NVMe's IOMMU group  
ls -l /sys/kernel/iommu_groups/11/devices/

# Are they completely isolated?
```

### 4. Test with IOMMU in Passthrough

```bash
# Boot with iommu=pt (passthrough mode)
# This disables IOMMU isolation
# If this works, confirms IOMMU is the blocker
```

### 5. Check if We Need Actual RDMA NIC

The real test:
- Get a Mellanox/InfiniBand NIC
- Run rocSHMEM GDA
- See if it works
- If yes: confirms NIC hardware matters
- If no: confirms we're missing something else

## Hypothesis Refinement

### Why RDMA NICs Might Work

1. **Hardware P2P Support**
   - NICs designed for GPU Direct
   - Accept transactions from non-CPU agents
   - Less strict PCIe compliance

2. **Firmware Configuration**
   - NIC firmware enables GPU access
   - Special transaction types supported
   - Relaxed ordering, etc.

3. **Driver Integration**
   - libibverbs/Direct Verbs APIs
   - Vendor drivers know about GPUs
   - May configure IOMMU differently

4. **PCIe Topology**
   - NICs typically on same root as GPUs in HPC systems
   - Designed for P2P workloads
   - ACS disabled or configured for P2P

### Why NVMe Doesn't Work

1. **Not Designed for GPU Access**
   - Consumer/enterprise storage
   - CPU-only design assumption
   - Strict PCIe transaction validation

2. **IOMMU Isolation**
   - Storage in different domain for security
   - No P2P path configured
   - Access blocked by design

3. **No GPU Direct Storage Support**
   - NVIDIA has GDS with special NVMe support
   - AMD doesn't (yet?)
   - Would need custom NVMe firmware/driver

## What AMD P2P Really Means

**`CONFIG_HSA_AMD_P2P`** is specifically for:
```
GPU <---Large BAR P2P---> GPU
```

**Not for:**
```
GPU <---???---> Arbitrary PCIe Device
```

For arbitrary devices, you need:
- Device-specific support (like RDMA NICs have)
- Or special kernel infrastructure (like NVIDIA GDS)
- Or relaxed IOMMU (not recommended)

## Conclusion So Far

1. ✅ rocSHMEM only uses HSA locking (no special APIs)
2. ✅ AMD has GPU-to-GPU P2P support
3. ❌ AMD P2P doesn't mean GPU-to-any-device P2P
4. ❓ RDMA NICs likely have hardware/firmware P2P support
5. ❌ NVMe controllers don't have GPU access support
6. ❌ IOMMU blocks our GPU → NVMe path

**Next step:** Check system configuration and confirm IOMMU is the blocker, or test with actual RDMA hardware to see if there's something else we're missing.

