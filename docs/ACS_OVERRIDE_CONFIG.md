# PCIe ACS Override Configuration for P2P Testing

## Overview

Access Control Services (ACS) is a PCIe feature that controls peer-to-peer
transactions between devices. By default, ACS can prevent P2P transactions even
when devices are in the same IOMMU group. To enable P2P testing with real NVMe
hardware, we disable ACS using the `pcie_acs_override` kernel parameter.

## What Was Changed

### Kernel Boot Parameter Added

Added `pcie_acs_override=downstream,multifunction` to the kernel command line
in `/etc/default/grub`:

```bash
GRUB_CMDLINE_LINUX=" amd_iommu=on iommu=pt pcie_acs_override=downstream,multifunction"
```

### What This Does

- **`pcie_acs_override=downstream`**: Disables ACS validation for downstream
  ports, allowing P2P transactions between devices connected to the same
  downstream port
- **`pcie_acs_override=multifunction`**: Disables ACS validation for
  multifunction devices, allowing P2P between functions on the same device

### Security Implications

⚠️ **WARNING**: Disabling ACS reduces security isolation between devices. This
should only be done on trusted systems for testing purposes. In production,
proper IOMMU groups and ACS should be used.

## Verification

After rebooting, verify the parameter is active:

```bash
cat /proc/cmdline | grep pcie_acs_override
```

Expected output:
```
... pcie_acs_override=downstream,multifunction
```

## Testing P2P with ACS Override

With ACS override enabled:

1. **Devices can perform P2P** even if ACS would normally block it
2. **IOMMU groups may be less restrictive** - devices that couldn't be in the
   same group before might now work together
3. **Real NVMe hardware** can be tested for GPU-to-NVMe P2P without requiring
   ACS-compliant hardware

## Reverting Changes

To revert to default ACS behavior:

1. Edit `/etc/default/grub`:
   ```bash
   sudo nano /etc/default/grub
   ```

2. Remove `pcie_acs_override=downstream,multifunction` from
   `GRUB_CMDLINE_LINUX`

3. Update GRUB:
   ```bash
   sudo update-grub
   ```

4. Reboot

## Related Documentation

- [DMABUF_BAR_MAPPING.md](DMABUF_BAR_MAPPING.md) - dma-buf approach for BAR
  mapping
- [NVME_HARDWARE_TESTING.md](NVME_HARDWARE_TESTING.md) - NVMe hardware testing
  procedures

## References

- Linux kernel documentation: `Documentation/admin-guide/kernel-parameters.txt`
- PCIe ACS specification: PCI Express Base Specification








