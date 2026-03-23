/*
 * ROCm ERNIC Ethernet Driver - Exported API for RDMA driver
 *
 * Copyright (C) 2025 Advanced Micro Devices, Inc.
 * SPDX-License-Identifier: Dual BSD/GPL
 */

#ifndef __ROCM_ERNIC_ETH_H__
#define __ROCM_ERNIC_ETH_H__

#include <linux/netdevice.h>
#include <linux/pci.h>
#include <linux/dma-mapping.h>

/* Ethernet descriptor format (matches server side) */
struct rocm_ernic_eth_desc {
    u64 addr;    /* Buffer address (DMA) */
    u16 length;  /* Buffer length */
    u8 status;   /* Status flags */
    u8 cmd;      /* Command flags */
    u16 vlan;    /* VLAN tag */
    u8 cso;      /* Checksum offset */
    u8 css;      /* Checksum start */
    u16 special; /* Special fields */
} __packed;

/* TX descriptor ring */
#define ROCM_ERNIC_ETH_TX_RING_SIZE 64
struct rocm_ernic_eth_tx_ring {
    struct rocm_ernic_eth_desc *desc; /* Descriptor ring */
    dma_addr_t desc_dma;              /* DMA address of descriptor ring */
    void **buffers;                   /* Packet buffer pointers */
    dma_addr_t *buffer_dma;           /* DMA addresses of buffers */
    u32 head;                         /* Head pointer (server reads) */
    u32 tail;                         /* Tail pointer (driver writes) */
    u32 size;                         /* Ring size */
};

/* RX descriptor ring */
#define ROCM_ERNIC_ETH_RX_RING_SIZE   64
#define ROCM_ERNIC_ETH_RX_BUFFER_SIZE 2048
struct rocm_ernic_eth_rx_ring {
    struct rocm_ernic_eth_desc *desc; /* Descriptor ring */
    dma_addr_t desc_dma;              /* DMA address of descriptor ring */
    void **buffers;                   /* Packet buffer pointers */
    dma_addr_t *buffer_dma;           /* DMA addresses of buffers */
    u32 head;                         /* Head pointer (driver reads) */
    u32 tail;                         /* Tail pointer (server writes) */
    u32 size;                         /* Ring size */
};

/* Ethernet driver context structure */
struct rocm_ernic_eth_dev {
    struct pci_dev *pdev;
    void __iomem *regs;
    struct net_device *netdev;
    struct list_head list;
    /* TX descriptor ring */
    struct rocm_ernic_eth_tx_ring tx_ring;
    /* RX descriptor ring */
    struct rocm_ernic_eth_rx_ring rx_ring;
    /* Private data for Ethernet driver */
    void *priv;
};

/* Exported API for RDMA driver */
struct rocm_ernic_eth_dev *rocm_ernic_eth_get_dev(struct pci_dev *pdev);
struct net_device *rocm_ernic_eth_get_netdev(struct pci_dev *pdev);
void __iomem *rocm_ernic_eth_get_regs(struct pci_dev *pdev);
struct pci_dev *rocm_ernic_eth_get_pdev(struct rocm_ernic_eth_dev *eth_dev);
void rocm_ernic_eth_handle_rx_interrupt(struct pci_dev *pdev);

#endif /* __ROCM_ERNIC_ETH_H__ */
