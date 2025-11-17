# AMD P2P QEMU Testing Instructions

## What We Fixed

### Critical Bug: Wrong Capability Signature
**Problem:** AMD implementation used "AP2" (0x41 0x50 0x32) instead of standard "P2P" (0x50 0x32 0x50)

**Impact:** Guest drivers wouldn't recognize AMD devices for P2P communication

**Fix Applied:** Changed signature from "AP2" → "P2P" in `/home/stebates/Projects/qemu/hw/vfio/pci-quirks.c`

**Status:** ✅ Fixed, rebuilt, and installed

---

## Files Created

1. **`verify-p2p-capability.sh`** - Comprehensive verification script (run INSIDE VM)
   - Scans for P2P capability
   - Decodes signature and clique ID
   - Color-coded output for easy reading
   - Works with or without root (better with root)

2. **`test-amd-p2p-capability.sh`** - VM launch script (run on HOST)
   - Launches VM with GPU passthrough
   - Injects P2P capability with clique ID 1
   - Shows instructions for verification

3. **`P2P_SIGNATURE_ANALYSIS.md`** - Technical deep-dive
   - Why "P2P" must be universal
   - How guest drivers use the capability
   - Examples of cross-vendor P2P

4. **`QEMU_PATCH_COMPARISON.md`** - Side-by-side comparison
   - AMD vs NVIDIA implementation
   - What we fixed and why

---

## Testing Steps

### Step 1: Launch the VM (on HOST)

```bash
cd /home/stebates/Projects/rocm-axiio/gda-experiments
./test-amd-p2p-capability.sh
```

This will:
- Use QEMU 10.1.2 with AMD P2P patch
- Pass through GPU (0000:10:00.0) with clique ID 1
- Inject "P2P" capability at offset 0xC8 or 0xD4

### Step 2: Verify Capability (INSIDE VM)

#### Quick Check (no root needed):
```bash
lspci -vvv | grep -A 5 'Vendor Specific'
```

#### Comprehensive Verification (with root):
Copy the verification script into the VM and run it:

```bash
# Option A: If you can transfer files
scp verify-p2p-capability.sh vm-guest:~/
ssh vm-guest
sudo ./verify-p2p-capability.sh

# Option B: If networking not configured
# Paste the script content manually or use virtfs/shared folder
```

#### Manual Verification:
```bash
# Find GPU address
GPU_ADDR=$(lspci | grep -i AMD | head -1 | cut -d' ' -f1)

# Read capability at offset 0xC8 (8 bytes)
sudo setpci -s $GPU_ADDR c8.8
```

**Expected Output:**
```
09 00 08 50 32 50 08 00
│  │  │  └──┴──┴── 'P2P' signature (0x50='P', 0x32='2', 0x50='P')
│  │  └────────── Length: 8 bytes
│  └───────────── Next capability: 0 (end)
└──────────────── Cap ID: 0x09 (Vendor-Specific)

Byte 6: 0x08 = 00001000 binary
        ││││└┴┴─ Version: 000 (0)
        └┴┴┴──── Clique ID: 0001 (1)
```

**Wrong Output (old bug):**
```
09 00 08 41 50 32 08 00
         └──┴──┴── 'AP2' (WRONG!)
```

---

## What to Look For

### ✅ Success Indicators
- Capability ID: `0x09` (Vendor-Specific)
- Signature: `50 32 50` ('P2P')
- Clique byte: `08` (for clique ID 1)
- Verification script shows: "✓✓✓ P2P SIGNATURE VERIFIED! ✓✓✓"

### ❌ Failure Indicators
- No vendor-specific capability found
- Signature is `41 50 32` ('AP2' - old bug)
- Capability at neither 0xC8 nor 0xD4
- Verification script shows errors

---

## Troubleshooting

### Issue: No capability found
**Causes:**
- QEMU not started with `x-amd-gpudirect-clique` parameter
- Wrong QEMU binary (not the patched version)
- GPU not passed through correctly

**Check:**
```bash
# On host, verify QEMU command line includes:
ps aux | grep qemu | grep amd-gpudirect-clique
```

### Issue: Wrong signature (AP2 instead of P2P)
**Causes:**
- Using old QEMU build before signature fix
- QEMU not rebuilt after patch

**Fix:**
```bash
cd /home/stebates/Projects/qemu/build
make -j$(nproc)
sudo make install
```

### Issue: setpci shows all zeros (00 00 00 00 00 00 00 00)
**Causes:**
- Capability at different offset
- PCI config space not accessible

**Try:**
```bash
# Try both offsets
sudo setpci -s $GPU_ADDR c8.8
sudo setpci -s $GPU_ADDR d4.8

# Dump full config space to find it
sudo lspci -xxx -s $GPU_ADDR | less
```

---

## Expected Results

### Successful P2P Injection
```
========================================
SUCCESS! P2P Capability Properly Injected!
========================================

Summary:
  ✓ Vendor-specific capability found
  ✓ Signature: 'P2P' (0x50 0x32 0x50) - CORRECT!
  ✓ Clique ID: 1
  ✓ Guest drivers will recognize this device for P2P
```

### What This Enables
- AMD GPU recognized for P2P DMA
- Can be grouped with other devices (NVMe, NICs) in same clique
- Can be grouped with NVIDIA GPUs (cross-vendor P2P)
- Standard guest drivers work (no patches needed)

---

## Next Steps After Verification

### If Test Succeeds ✅
1. Test with multiple devices in same clique:
   ```bash
   -device vfio-pci,host=10:00.0,x-amd-gpudirect-clique=1 \  # GPU
   -device vfio-pci,host=c2:00.0,x-amd-gpudirect-clique=1    # NVMe
   ```

2. Test with different cliques (should NOT enable P2P):
   ```bash
   -device vfio-pci,host=10:00.0,x-amd-gpudirect-clique=1 \  # Clique 1
   -device vfio-pci,host=c2:00.0,x-amd-gpudirect-clique=2    # Clique 2
   ```

3. Test cross-vendor P2P (AMD + NVIDIA):
   ```bash
   -device vfio-pci,host=10:00.0,x-amd-gpudirect-clique=1 \     # AMD GPU
   -device vfio-pci,host=05:00.0,x-nvidia-gpudirect-clique=1   # NVIDIA GPU
   ```

4. Implement actual P2P DMA in NVMe GDA code

### If Test Fails ❌
1. Review QEMU error output
2. Check `dmesg` on host for VFIO errors
3. Verify GPU bound to vfio-pci driver
4. Ensure IOMMU groups are correct
5. Try bare-metal testing (no VM)

---

## Reference Commands

### Host (before starting VM)
```bash
# Verify GPU bound to vfio-pci
lspci -k -s 10:00.0

# Check IOMMU groups
find /sys/kernel/iommu_groups/ -name "0000:10:00.0"

# Verify QEMU binary
/opt/qemu-10.1.2-amd-p2p/bin/qemu-system-x86_64 --version
```

### Guest (after VM boots)
```bash
# Find GPU
lspci | grep -i "AMD\|ATI\|Display"

# Show full device info
lspci -vvv -s $(lspci | grep AMD | head -1 | cut -d' ' -f1)

# Check for P2P capability
GPU=$(lspci | grep AMD | head -1 | cut -d' ' -f1)
sudo setpci -s $GPU c8.8

# Run comprehensive verification
sudo ./verify-p2p-capability.sh
```

---

## Documentation

- **Technical Details:** `P2P_SIGNATURE_ANALYSIS.md`
- **Code Comparison:** `QEMU_PATCH_COMPARISON.md`
- **VFIO Issues:** `BREAKTHROUGH_VFIO_ISOLATION.md`
- **Build Log:** `AMD_P2P_QEMU_PATCH_STATUS.md`

---

## Summary

**What works:**
- ✅ AMD P2P QEMU patch with corrected "P2P" signature
- ✅ QEMU built and installed
- ✅ Verification tools created

**What's tested:**
- ⏳ P2P capability injection (ready to test)
- ⏳ Guest driver recognition (ready to test)
- ⏳ Cross-vendor P2P (ready to test)

**What's next:**
- Test capability injection in VM
- Verify correct "P2P" signature
- Enable actual P2P DMA in NVMe GDA code

