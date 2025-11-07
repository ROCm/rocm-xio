# AMD GPUDirect P2P Patch for QEMU

## What This Does

Creates an AMD equivalent of NVIDIA's GPUDirect P2P clique support in QEMU.

### The Concept

Devices assigned the same "clique ID" are marked as P2P-capable:

```bash
-device vfio-pci,host=10:00.0,x-amd-gpudirect-clique=1   # AMD GPU
-device vfio-pci,host=c2:00.0,x-amd-gpudirect-clique=1   # NVMe
```

Both devices get a vendor-specific PCI capability that indicates they're in clique 1.

## How It Works

### 1. Vendor Capability Added to PCI Config Space

```
Offset 0xC8 or 0xD4:
+--------+--------+--------+--------+
| 'A'    | len(8) | next   | VendID |
+--------+--------+--------+--------+
| ClqID  |     'AP2'       | Rsvd   |
+--------+-----------------+--------+
```

- Signature: **"AP2"** (AMD Peer-to-Peer)
- Clique ID: 0-15 (4 bits, encoded at bit position 3-6)
- Modeled after NVIDIA's "P2P" signature

### 2. Guest Kernel Can Read This

Guest OS (or drivers) can:
1. Read PCI config space
2. Find the vendor capability
3. See which clique each device belongs to
4. Enable P2P DMA between devices in same clique

### 3. QEMU Manages IOMMU Mappings

When devices are in the same clique, QEMU/VFIO:
- Puts them in same IOMMU container
- Maps each device's BARs for P2P access
- Allows direct device-to-device DMA

## Files Modified

1. **`hw/vfio/pci-quirks.c`**
   - Add `vfio_add_amd_gpudirect_cap()`
   - Add property get/set functions
   - Call from `vfio_add_virt_caps()`

2. **`hw/vfio/pci.c`**
   - Add `amd_gpudirect_clique` field initialization
   - Add command-line property definition
   - Add property description

3. **`hw/vfio/pci.h`**
   - Add `amd_gpudirect_clique` field to `VFIOPCIDevice`
   - Export `qdev_prop_amd_gpudirect_clique`

## Important Notes

### This Is a Software Hint

The patch adds a **capability that the guest can read**, but:
- ❌ Doesn't automatically enable P2P (needs guest support)
- ❌ Doesn't modify IOMMU mappings by itself
- ✅ Provides information to guest OS/drivers
- ✅ Matches NVIDIA's approach

### Guest Support Needed

For P2P to actually work, the guest needs:
1. AMD GPU driver that understands this capability
2. NVMe driver that understands this capability
3. Or kernel P2P infrastructure that reads it
4. Or our nvme_gda driver modified to check it

### ROCm/amdgpu Support

Current AMD drivers **don't look for this capability**!

This would require either:
- Patches to amdgpu kernel driver
- Or our nvme_gda driver checking for it
- Or userspace library detecting it

## Will This Actually Work?

### Short Answer: Partially

**What it does:**
✅ Adds the capability to PCI config space
✅ Allows QEMU to group devices
✅ Provides P2P hint to guest

**What it doesn't do:**
❌ Automatically enable P2P DMA
❌ Work with current AMD drivers
❌ Bypass IOMMU restrictions

### For Full P2P Support

Would still need:
1. ✅ This patch (hardware/QEMU level)
2. ❌ Guest kernel support (read capability)
3. ❌ AMD driver support (act on capability)
4. ❌ Or our custom driver to handle it

## Applying the Patch

### Option 1: Automated Script

```bash
cd /home/stebates/Projects/rocm-axiio/gda-experiments
sudo ./apply-amd-p2p-patch.sh
```

This will:
1. Apply patch to QEMU source
2. Build QEMU
3. Install to `/opt/qemu-10.1.2-amd-p2p`

### Option 2: Manual

```bash
cd /home/stebates/Projects/qemu
patch -p1 < /home/stebates/Projects/rocm-axiio/gda-experiments/qemu-amd-p2p.patch
./configure --prefix=/opt/qemu-10.1.2-amd-p2p --target-list=x86_64-softmmu
make -j$(nproc)
sudo make install
```

## Using the Patched QEMU

```bash
/opt/qemu-10.1.2-amd-p2p/bin/qemu-system-x86_64 \
  -machine q35,accel=kvm \
  -device vfio-pci,host=10:00.0,x-amd-gpudirect-clique=1 \
  -device vfio-pci,host=c2:00.0,x-amd-gpudirect-clique=1 \
  ...
```

Both devices now have the AP2P capability!

## Verifying It Works

### In the Guest VM

```bash
# Check GPU PCI config
sudo lspci -vvv -s 10:00.0 | grep -A20 "Capabilities:"

# Should see vendor-specific capability at 0xC8 or 0xD4
# With data: 41 50 32 (hex for "AP2")

# Check NVMe too
sudo lspci -vvv -s c2:00.0 | grep -A20 "Capabilities:"
```

### Reading the Capability

```c
// In guest kernel or our driver
uint8_t cap_ptr = pci_find_capability(pdev, PCI_CAP_ID_VNDR);
while (cap_ptr) {
    uint8_t sig[4];
    pci_read_config_dword(pdev, cap_ptr + 4, (u32*)sig);
    
    if (sig[0] == 'A' && sig[1] == 'P' && sig[2] == '2') {
        // Found AMD P2P capability!
        uint8_t clique = (sig[3] >> 3) & 0xF;
        printk("Device in AMD P2P clique: %d\n", clique);
    }
    
    cap_ptr = pci_find_next_capability(pdev, cap_ptr, PCI_CAP_ID_VNDR);
}
```

## Next Steps If Using This Patch

1. **Apply and build QEMU** ✅
2. **Test VM boot** - verify capability appears ✅
3. **Modify nvme_gda driver** - read AP2P capability
4. **Implement P2P logic** - if same clique, enable P2P
5. **Test GPU→NVMe access** - should work!

## Alternative: Bare Metal Testing

**Remember:** Testing on bare metal (no VM) is simpler:
- No VFIO complications
- No QEMU patches needed
- AMD P2P works natively
- Just need amdgpu + nvme_gda drivers

The patch is interesting but bare metal testing is **much easier** and will prove our code works!

## Bottom Line

**This patch:**
- ✅ Technically correct
- ✅ Follows NVIDIA's pattern
- ✅ Adds proper capability
- ⚠️ Needs guest driver support
- ⚠️ Still complex for our use case

**Recommendation:**
1. Test on bare metal first (simple, should work)
2. If VM testing needed, apply this patch
3. Modify nvme_gda to read AP2P capability
4. Then test GPU→NVMe P2P in VM

The patch is ready if you want to pursue the VM approach!

