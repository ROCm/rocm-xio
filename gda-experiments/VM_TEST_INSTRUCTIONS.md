# Testing AMD P2P in VM

## VM is Starting

The patched QEMU is now running with:
```bash
-device vfio-pci,host=10:00.0,x-amd-gpudirect-clique=1   # GPU
-device vfio-pci,host=c2:00.0,x-amd-gpudirect-clique=1   # NVMe
```

Both devices should have AMD P2P capability added!

## Next Steps

### 1. Wait for VM to Boot

The VM is booting in the background. Wait for it to be accessible.

### 2. SSH into VM

```bash
# From another terminal:
ssh ubuntu@rocm-axiio
# or
ssh -p 2222 ubuntu@localhost
```

### 3. Check for AMD P2P Capability

Inside the VM:
```bash
cd /mnt/hostfs/gda-experiments
./check-amd-p2p-cap.sh
```

This will show:
- Full PCI capabilities for both devices
- Vendor-specific capabilities
- Look for signature "AP2" in hex dump

### 4. What to Look For

In the output, you should see:

**Vendor Capability Structure:**
```
Offset C8h or D4h:
  09 - Capability ID (vendor-specific)
  08 - Length (8 bytes)
  41 - 'A'
  50 - 'P'  
  32 - '2'
  08 - Clique ID bits (clique 1 = 0x08)
```

### 5. If Capability is Present

✅ **SUCCESS!** The patch works!

Then you can:
- Test GPU doorbell access
- See if P2P actually works in VM
- Compare with bare metal

### 6. If Capability is NOT Present

Possible reasons:
- Devices not actually AMD vendor ID
- Capability conflict in config space
- QEMU not using patched version

Check:
```bash
# In VM:
lspci -nn -s 10:00.0  # Check vendor ID
lspci -nn -s c2:00.0  # Check vendor ID
```

GPU should be `1002:XXXX` (AMD)
NVMe might not be AMD - that's OK, capability only added to AMD devices!

## Expected Behavior

Based on our patch:
- **GPU (AMD)**: Should get AP2 capability ✅
- **NVMe (non-AMD)**: Won't get capability (vendor check fails) ❌

This is actually a problem with our patch - we check for AMD vendor ID!

### Fix if Needed

We might need to modify the patch to:
1. Allow any device in clique (not just AMD)
2. Or create generic P2P capability for all devices
3. Or just test on bare metal instead

## Alternative

If the capability doesn't appear or testing in VM is too complex:

```bash
# Shutdown VM
sudo pkill -f qemu

# Test on bare metal
sudo ./test-on-bare-metal.sh
```

This will actually test GPU→NVMe access without QEMU/VFIO complexity!

