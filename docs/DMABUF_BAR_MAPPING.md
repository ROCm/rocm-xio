# GPU-to-NVMe P2P via dma-buf BAR Mapping

## Overview

This document describes the approach for enabling GPU-to-NVMe Peer-to-Peer (P2P)
communication in a QEMU virtualized environment using dma-buf to export PCI
device MMIO regions. This method provides a safe, kernel-supported way to map
NVMe device BARs into a GPU's IOMMU domain for direct device-to-device
communication.

## Problem Statement

To enable GPU Direct Storage (GDS) or GPU Direct Access (GDA) in a virtualized
environment, the GPU needs direct access to NVMe device registers (doorbells)
without involving the CPU or system memory. This requires:

1. **Mapping NVMe BAR0** into the GPU's IOMMU domain so the GPU can access
   NVMe doorbells via DMA
2. **Using the same IOMMU container** for both devices to enable P2P
   transactions
3. **Safe lifetime management** to prevent use-after-free (UAF) vulnerabilities

### Previous Approaches and Limitations

#### Direct BAR Mapping (Attempted)
- **Approach**: Use `mmap()` to get virtual address of NVMe BAR0, then map
  into GPU IOMMU domain using `iommufd_backend_map_dma()`
- **Problem**: iommufd's `IOMMU_IOAS_MAP` ioctl does not support mapping PCI BAR
  regions directly (returns EFAULT - "Bad address")
- **Status**: Not supported by current kernel implementation

#### Legacy VFIO Container
- **Approach**: Use legacy VFIO container API (`VFIO_IOMMU_MAP_DMA`) to map BAR
- **Problem**: Requires devices to be in legacy VFIO container, not iommufd
- **Status**: Works but doesn't support modern iommufd-based setups

## The dma-buf Solution

The dma-buf approach uses kernel patches that enable VFIO PCI devices to export
MMIO regions as dma-buf file descriptors. These FDs can then be safely imported
into iommufd or other subsystems for P2P DMA operations.

### How It Works

1. **Export BAR as dma-buf**: QEMU uses `VFIO_DEVICE_FEATURE_DMA_BUF` ioctl to
   export NVMe BAR0 as a dma-buf file descriptor
2. **Import into iommufd**: The dma-buf FD is imported into the GPU's IOMMU
   domain using `iommufd_backend_map_file_dma()`
3. **Safe lifetime management**: The kernel manages the dma-buf lifecycle,
   automatically revoking access when the VFIO device is closed or reset

### Advantages

- **Kernel-supported**: Uses official kernel APIs designed for this purpose
- **Safe**: Built-in revocation mechanism prevents UAF vulnerabilities
- **Works with iommufd**: Compatible with modern iommufd-based VFIO containers
- **Standardized**: Uses dma-buf, a well-established framework for sharing
  buffers between devices

## Kernel Patches Required

### Patch Series: vfio/pci: Allow MMIO regions to be exported through dma-buf

**Source**: https://patchew.org/linux/20251111-dmabuf-vfio-v8-0-fd9aa5df478f@nvidia.com/

**Status**: v8 (under review, November 2025)

**Patches** (11 total):

1. **01-05**: PCI/P2PDMA refactoring
   - Separates mmap() support from core P2PDMA logic
   - Simplifies bus address mapping API
   - Refactors core P2P functionality
   - Documents DMABUF model

2. **06**: dma-buf: provide phys_vec to scatter-gather mapping routine
   - Adds physical address vector support to dma-buf

3. **07-08**: VFIO infrastructure changes
   - Exports VFIO device registration helpers
   - Shares core device pointer in feature functions

4. **09**: vfio/pci: Enable peer-to-peer DMA transactions by default
   - Enables P2P support automatically

5. **10**: vfio/pci: Add dma-buf export support for MMIO regions
   - **MAIN PATCH** - Adds the dma-buf export functionality
   - New file: `drivers/vfio/pci/vfio_pci_dmabuf.c` (~315 lines)

6. **11**: vfio/nvgrace: Support get_dmabuf_phys
   - NVIDIA Grace GPU specific support

### Kernel Modules Impacted

#### Loadable Modules (Must Rebuild)
- `vfio-pci` / `vfio-pci-core` - Primary impact, adds dma-buf support
- `vfio` (core) - Device registration changes
- `vfio-pci-nvgrace-gpu` (optional) - NVIDIA Grace GPU support

#### Built-in Code (Requires Full Kernel Rebuild)
- PCI P2PDMA subsystem (`drivers/pci/p2pdma.c`)
- DMA-BUF subsystem (`drivers/dma-buf/dma-buf.c`)
- IOMMU subsystem (`drivers/iommu/dma-iommu.c`)
- Block layer (`block/blk-mq-dma.c`)
- Kernel DMA (`kernel/dma/direct.c`)
- HMM (`mm/hmm.c`)

### Configuration Requirements

The patches add a new config option:
```kconfig
config VFIO_PCI_DMABUF
    def_bool y if VFIO_PCI_CORE && PCI_P2PDMA && DMA_SHARED_BUFFER
```

This is automatically enabled if dependencies are met:
- `CONFIG_VFIO_PCI_CORE=y`
- `CONFIG_PCI_P2PDMA=y`
- `CONFIG_DMA_SHARED_BUFFER=y`

## Applying Kernel Patches

### Prerequisites

1. Kernel source matching your running kernel version (e.g., 6.14.0-35)
2. Build tools: `build-essential`, `libncurses-dev`, `bc`, `flex`, `bison`
3. Patches downloaded to `~/Projects/kernel-patches/`

### Steps

1. **Get kernel source**:
   ```bash
   # Option 1: Ubuntu kernel source
   apt-get source linux-source-6.14.0
   
   # Option 2: Clone from kernel.org
   git clone https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
   cd linux
   git checkout v6.14.11  # Match your kernel version
   ```

2. **Apply patches**:
   ```bash
   cd ~/Projects/kernel-patches
   for p in patch-*.patch; do
       patch -p1 < "$p" -d /path/to/kernel/source
   done
   ```

3. **Configure kernel**:
   ```bash
   cd /path/to/kernel/source
   # Use existing config as base
   cp /boot/config-$(uname -r) .config
   make olddefconfig
   # Verify VFIO_PCI_DMABUF is enabled
   grep CONFIG_VFIO_PCI_DMABUF .config
   ```

4. **Build kernel**:
   ```bash
   make -j$(nproc)
   make modules_install
   make install
   ```

5. **Reboot** into new kernel

## QEMU Implementation

### API Overview

The kernel provides a new VFIO device feature:

```c
#define VFIO_DEVICE_FEATURE_DMA_BUF 11

struct vfio_region_dma_range {
    __u64 offset;
    __u64 length;
};

struct vfio_device_feature_dma_buf {
    __u32   region_index;      // BAR region index (0 = BAR0)
    __u32   open_flags;         // O_RDWR, O_CLOEXEC, etc.
    __u32   flags;             // Should be 0
    __u32   nr_ranges;         // Number of P2P DMA ranges
    struct vfio_region_dma_range dma_ranges[];  // offset/length pairs
};
```

### QEMU Code Changes

#### 1. Export NVMe BAR0 as dma-buf

```c
// In vfio-p2p.c or similar
static int vfio_export_nvme_bar0_as_dmabuf(VFIOPCIDevice *nvme_dev, int *dmabuf_fd)
{
    struct vfio_device_feature feature = {
        .argsz = sizeof(feature),
        .flags = VFIO_DEVICE_FEATURE_GET | VFIO_DEVICE_FEATURE_DMA_BUF,
    };
    
    struct vfio_device_feature_dma_buf *dmabuf_feature;
    size_t feature_size = sizeof(*dmabuf_feature) + sizeof(struct vfio_region_dma_range);
    
    dmabuf_feature = g_malloc0(feature_size);
    dmabuf_feature->region_index = 0;  // BAR0
    dmabuf_feature->open_flags = O_RDWR | O_CLOEXEC;
    dmabuf_feature->flags = 0;
    dmabuf_feature->nr_ranges = 1;
    dmabuf_feature->dma_ranges[0].offset = 0;
    dmabuf_feature->dma_ranges[0].length = bar0_size;
    
    feature.data = (__u64)(uintptr_t)dmabuf_feature;
    
    int ret = ioctl(nvme_dev->vbasedev.fd, VFIO_DEVICE_FEATURE, &feature);
    if (ret < 0) {
        error_report("Failed to export BAR0 as dma-buf: %s", strerror(errno));
        g_free(dmabuf_feature);
        return -errno;
    }
    
    *dmabuf_fd = feature.data;  // Kernel returns FD in data field
    g_free(dmabuf_feature);
    return 0;
}
```

#### 2. Import dma-buf into GPU IOMMU Domain

```c
// In vfio-p2p.c
static int vfio_map_dmabuf_to_gpu_iommu(VFIOIOMMUFDContainer *iommufd_container,
                                        int dmabuf_fd,
                                        hwaddr iova,
                                        size_t size)
{
    int ret = iommufd_backend_map_file_dma(
        iommufd_container->be,
        iommufd_container->ioas_id,
        iova,                    // IOVA address for GPU to access
        size,                    // Size of mapping
        dmabuf_fd,              // dma-buf file descriptor
        0,                       // Offset within dma-buf
        false);                  // Read-write
    
    if (ret < 0) {
        error_report("Failed to map dma-buf into GPU IOMMU: %s", strerror(errno));
        return ret;
    }
    
    return 0;
}
```

#### 3. Integration into Device Realization

```c
// In vfio-p2p.c
void vfio_p2p_setup_bar_mapping(VFIOPCIDevice *vdev, Error **errp)
{
    // Detect GPU and NVMe devices (existing code)
    // ...
    
    if (is_gpu_device && nvme_dev) {
        int dmabuf_fd = -1;
        hwaddr bar0_iova = 0xdbe00000;  // Or get from device
        
        // Export NVMe BAR0 as dma-buf
        if (vfio_export_nvme_bar0_as_dmabuf(nvme_dev, &dmabuf_fd) < 0) {
            error_setg(errp, "Failed to export NVMe BAR0 as dma-buf");
            return;
        }
        
        // Import into GPU IOMMU domain
        VFIOIOMMUFDContainer *container = /* get from vdev */;
        if (vfio_map_dmabuf_to_gpu_iommu(container, dmabuf_fd, bar0_iova, bar0_size) < 0) {
            close(dmabuf_fd);
            error_setg(errp, "Failed to map dma-buf into GPU IOMMU");
            return;
        }
        
        error_report("vfio-p2p: ✓ Successfully mapped NVMe BAR0 via dma-buf");
        error_report("  dma-buf FD: %d", dmabuf_fd);
        error_report("  IOVA: 0x%"HWADDR_PRIx, bar0_iova);
        
        // Store dmabuf_fd for cleanup
        // ...
    }
}
```

### Files to Modify

1. **`hw/vfio/vfio-p2p.c`** - Add dma-buf export/import functions
2. **`hw/vfio/pci.h`** - Add fields for dma-buf FD tracking
3. **`hw/vfio/pci.c`** - Call dma-buf setup in device realization

## Testing

### Prerequisites

1. Kernel with dma-buf patches applied and running
2. QEMU with dma-buf support compiled
3. GPU and NVMe devices bound to vfio-pci
4. Both devices in same iommufd container

### Test Steps

1. **Launch VM with iommufd**:
   ```bash
   ./launch-vm  # Should use iommufd=iommufd0 for both devices
   ```

2. **Check QEMU logs** for success messages:
   ```
   vfio-p2p: ✓ Successfully mapped NVMe BAR0 via dma-buf
     dma-buf FD: 42
     IOVA: 0xdbe00000
   ```

3. **Verify in guest**:
   - Check that GPU can access NVMe doorbells
   - Run GPU-based I/O tests
   - Monitor for IOVA faults (should be none)

4. **Check host dmesg**:
   ```bash
   dmesg | grep -i "vfio.*dmabuf\|iova.*fault"
   ```

### Expected Behavior

- **Success**: GPU can directly access NVMe doorbells without CPU involvement
- **No IOVA faults**: Host kernel should not report IOVA translation faults
- **Automatic cleanup**: When VM shuts down, dma-buf mappings are automatically
  revoked

## Comparison with Other Approaches

| Approach | Kernel Support | iommufd Compatible | Safety | Status |
|----------|---------------|-------------------|--------|--------|
| **dma-buf** | ✅ Patches available | ✅ Yes | ✅ Safe revocation | ✅ Recommended |
| Direct BAR mapping | ❌ Not supported | ⚠️ Limited | ⚠️ UAF risk | ❌ Failed |
| Legacy VFIO container | ✅ Supported | ❌ No | ⚠️ Less safe | ⚠️ Works but outdated |

## Troubleshooting

### "VFIO_DEVICE_FEATURE_DMA_BUF not supported"
- **Cause**: Kernel patches not applied or kernel not rebuilt
- **Solution**: Verify patches are applied and kernel is rebuilt

### "Failed to export BAR0 as dma-buf: Invalid argument"
- **Cause**: Device doesn't support dma-buf export or region_index invalid
- **Solution**: Check that device is VFIO PCI device and BAR0 exists

### "Failed to map dma-buf into GPU IOMMU: Bad address"
- **Cause**: IOVA address conflict or invalid range
- **Solution**: Verify IOVA address is not already mapped and is valid

### IOVA faults in host dmesg
- **Cause**: Mapping not successful or wrong IOVA address
- **Solution**: Check QEMU logs for mapping errors, verify IOVA matches guest
  expectations

## References

- **Kernel Patches**: https://patchew.org/linux/20251111-dmabuf-vfio-v8-0-fd9aa5df478f@nvidia.com/
- **VFIO Documentation**: https://www.kernel.org/doc/html/latest/driver-api/vfio.html
- **iommufd Documentation**: https://www.kernel.org/doc/html/latest/userspace-api/iommufd.html
- **dma-buf Documentation**: https://www.kernel.org/doc/html/latest/driver-api/dma-buf.html
- **PCI P2P DMA**: https://docs.kernel.org/driver-api/pci/p2pdma.html

## Future Work

- Support for multiple BAR regions (not just BAR0)
- Automatic IOVA address allocation
- Support for other device types (not just GPU-NVMe)
- Integration with QEMU's device hotplug for dynamic P2P setup








