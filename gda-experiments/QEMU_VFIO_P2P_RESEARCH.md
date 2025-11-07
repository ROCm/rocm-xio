# QEMU/VFIO P2P Research Findings

## Critical Findings from Web Search

### 1. **NVIDIA GPUDirect P2P Clique Support** ✅

QEMU **already has** P2P support for NVIDIA GPUs!

**Configuration:**
```xml
<qemu:commandline>
  <qemu:arg value='-set'/>
  <qemu:arg value='device.hostdev0.x-nv-gpudirect-clique=0'/>
  <qemu:arg value='-set'/>
  <qemu:arg value='device.hostdev1.x-nv-gpudirect-clique=1'/>
  <qemu:arg value='-set'/>
  <qemu:arg value='device.hostdev2.x-nv-gpudirect-clique=1'/>
</qemu:commandline>
```

Devices with the same clique ID can perform P2P DMA!

**For AMD GPUs:** This feature is NVIDIA-specific. AMD equivalent doesn't exist yet.

### 2. **AMD vIOMMU Support (In Development)** 🚧

**Recent patches (May 2025!)** add DMA remapping for VFIO devices with AMD vIOMMU:

```bash
qemu-system-x86_64 \
  -device amd-iommu,intremap=on,dma-remap=on \  # <-- Key option!
  -device vfio-pci,host=10:00.0 \
  -device vfio-pci,host=c2:00.0
```

The `dma-remap=on` property enables guest kernels to provide DMA address translation.

**Status:** Patches proposed but **not merged** yet!

### 3. **IOMMUFD Backend Limitation** ❌

From QEMU docs:
> "PCI p2p DMA is unsupported as IOMMUFD doesn't support mapping hardware PCI BAR region yet."

The newer IOMMUFD backend **cannot** handle P2P because it can't map device BARs.

**Workaround:** Use legacy VFIO Type1 IOMMU (not IOMMUFD).

### 4. **IOMMU Group Requirements** ⚠️

For P2P to work:
- **Devices must be in same IOMMU group**
- Or use special vIOMMU configuration

**Our Problem:**
```
GPU:  IOMMU group 47
NVMe: IOMMU group 11
```

**Different groups = P2P blocked by default!**

## Potential Solutions for AMD GPU + NVMe

### Solution 1: Use AMD vIOMMU (When Available)

Wait for AMD vIOMMU patches to be merged, then:

```bash
qemu-system-x86_64 \
  -machine q35,accel=kvm,kernel-irqchip=split \
  -device amd-iommu,intremap=on,dma-remap=on \
  -device vfio-pci,host=10:00.0 \  # GPU
  -device vfio-pci,host=c2:00.0     # NVMe
```

**Status:** Patches exist but not in mainline QEMU yet.

### Solution 2: Force Same IOMMU Group (Host Config)

On the host, manipulate IOMMU groups:

```bash
# Disable ACS (Access Control Services) override
# This may put more devices in same group

# WARNING: Reduces isolation, security implications!
echo "options vfio_iommu_type1 allow_unsafe_interrupts=1" > /etc/modprobe.d/vfio.conf

# Or use kernel parameter:
# pcie_acs_override=downstream,multifunction
```

**Risks:** Weakens IOMMU isolation, security concerns.

### Solution 3: Check for AMD P2P Clique Support

Search for AMD equivalent of NVIDIA's clique ID:

```bash
# Check QEMU source for AMD-specific options
qemu-system-x86_64 -device vfio-pci,help | grep -i "amd\|p2p\|clique"

# Or check for x-amd-* options
```

**Likelihood:** Probably doesn't exist yet for AMD.

### Solution 4: Custom QEMU Build with Patches

Clone QEMU, apply AMD vIOMMU patches manually:

```bash
git clone https://gitlab.com/qemu-project/qemu.git
cd qemu
git fetch origin refs/changes/XX/XXXXX/Y  # Fetch patch
git cherry-pick FETCH_HEAD
./configure --target-list=x86_64-softmmu
make -j$(nproc)
```

Then use custom QEMU build.

**Effort:** High, but might work!

### Solution 5: Test on Bare Metal (Simplest)

Avoid all VFIO/VM complexity:

```bash
# On host:
# GPU → amdgpu driver
# NVMe → nvme_gda driver
# No VFIO, no IOMMU isolation
# Should work immediately!
```

**Effort:** Low, high success probability.

## Checking Our Current QEMU Version

Let's see what options we have:

```bash
# Check QEMU version
qemu-system-x86_64 --version

# Check available vfio-pci options
qemu-system-x86_64 -device vfio-pci,help

# Check AMD IOMMU options
qemu-system-x86_64 -device amd-iommu,help

# Check if we have P2P related options
qemu-system-x86_64 -device vfio-pci,help 2>&1 | grep -i "p2p\|clique\|peer"
```

## Experimental QEMU Configuration

Let's try some options with our current setup:

```bash
qemu-system-x86_64 \
  -machine q35,accel=kvm,kernel-irqchip=split \
  -device amd-iommu,intremap=on \
  -device vfio-pci,host=10:00.0,id=gpu \
  -device vfio-pci,host=c2:00.0,id=nvme \
  # Try to hint at P2P relationship?
```

## The Core Issue

**From search results:**

1. ✅ NVIDIA has `x-nv-gpudirect-clique` support
2. 🚧 AMD vIOMMU patches exist but not merged
3. ❌ IOMMUFD doesn't support PCI BAR mapping
4. ⚠️ Our devices in different IOMMU groups

**Bottom line:** P2P in VMs with AMD GPUs + NVMe is not well-supported yet!

## Recommendations

### Short Term: Test on Bare Metal

This will:
- ✅ Validate our implementation
- ✅ Prove AMD P2P works outside VM
- ✅ Be much simpler
- ✅ Actually work!

### Medium Term: Monitor QEMU Development

Watch for:
- AMD vIOMMU patches to merge
- IOMMUFD PCI BAR support
- AMD P2P clique support (like NVIDIA)

### Long Term: Contribute Patches

If needed for production:
- Help get AMD vIOMMU patches merged
- Or contribute AMD P2P clique support
- Or work with QEMU community on IOMMUFD

## Next Steps

### 1. Check Our QEMU Version

```bash
/opt/qemu-10.1.2/bin/qemu-system-x86_64 --version
/opt/qemu-10.1.2/bin/qemu-system-x86_64 -device amd-iommu,help
/opt/qemu-10.1.2/bin/qemu-system-x86_64 -device vfio-pci,help | grep -i p2p
```

### 2. Try Experimental Config

Modify `run-gda-test-vm.sh` to add AMD IOMMU options.

### 3. Test on Bare Metal (Recommended)

```bash
sudo ./test-on-bare-metal.sh
```

This will prove our code works!

## Summary

**For VM P2P with AMD:**
- Not well-supported in current QEMU
- AMD vIOMMU patches in development
- Different IOMMU groups are a blocker
- Bare metal testing is the way to go

**The good news:**
- rocSHMEM GDA works on bare metal
- AMD hardware supports P2P
- Just need proper software stack
- VM support is coming (eventually)

