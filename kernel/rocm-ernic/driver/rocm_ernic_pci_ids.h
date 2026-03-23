/*
 * PCI IDs for ROCm ERNIC. Must match src/rocm_ernic_server.c
 * (vfu_pci_set_id). AMD vendor ID; device ID 0x8000 for ROCm ERNIC.
 */
#ifndef __ROCM_ERNIC_PCI_IDS_H__
#define __ROCM_ERNIC_PCI_IDS_H__

#define PCI_VENDOR_ID_ROCM_ERNIC 0x1022 /* AMD */
#define PCI_DEVICE_ID_ROCM_ERNIC 0x8000 /* Emulated RDMA */

#endif /* __ROCM_ERNIC_PCI_IDS_H__ */
