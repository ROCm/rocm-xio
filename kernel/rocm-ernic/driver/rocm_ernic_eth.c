/*
 * ROCm ERNIC Ethernet Driver
 *
 * This module handles PCI device registration and netdev creation.
 * The RDMA driver (rocm_ernic_rdma.ko) depends on this module.
 *
 * Copyright (C) 2025 Advanced Micro Devices, Inc.
 * SPDX-License-Identifier: Dual BSD/GPL
 */

#include <linux/errno.h>
#include <linux/init.h>
#include <linux/module.h>
#include <linux/slab.h>
#include <linux/netdevice.h>
#include <linux/etherdevice.h>
#include <linux/pci.h>
#include <linux/rtnetlink.h>
#include <linux/rcupdate.h>
#include <linux/dma-mapping.h>
#include <linux/skbuff.h>
#include <linux/ip.h>
#include <linux/tcp.h>
#include <linux/if_ether.h>

#include "rocm_ernic_eth.h"
#include "rocm_ernic_pci_ids.h"

#define DRV_NAME_ETH "rocm_ernic_eth"
#define DRV_VERSION  "1.0.1.0-k"

/* Ethernet register offsets (from rocm_ernic_eth.h) */
#define ROCM_ERNIC_ETH_CTL     0x28
#define ROCM_ERNIC_ETH_STATUS  0x2c
#define ROCM_ERNIC_ETH_TX_BAL  0x30
#define ROCM_ERNIC_ETH_TX_BAH  0x34
#define ROCM_ERNIC_ETH_TX_LEN  0x38
#define ROCM_ERNIC_ETH_TX_HEAD 0x3c
#define ROCM_ERNIC_ETH_TX_TAIL 0x40
#define ROCM_ERNIC_ETH_RX_BAL  0x44
#define ROCM_ERNIC_ETH_RX_BAH  0x48
#define ROCM_ERNIC_ETH_RX_LEN  0x4c
#define ROCM_ERNIC_ETH_RX_HEAD 0x50
#define ROCM_ERNIC_ETH_RX_TAIL 0x54
#define ROCM_ERNIC_ETH_ICR     0x58
#define ROCM_ERNIC_ETH_IMR     0x5c
#define ROCM_ERNIC_ETH_MAC0    0x60 /* MAC Address bytes 0-3 (little-endian) */
#define ROCM_ERNIC_ETH_MAC1    0x64 /* MAC Address bytes 4-5 (little-endian) */

/* Ethernet Control Register bits */
#define ROCM_ERNIC_ETH_CTL_ENABLE     (1 << 0)
#define ROCM_ERNIC_ETH_CTL_TX_ENABLE  (1 << 1)
#define ROCM_ERNIC_ETH_CTL_RX_ENABLE  (1 << 2)
#define ROCM_ERNIC_ETH_STATUS_LINK_UP (1 << 0)

/* Ethernet Interrupt Cause bits */
#define ROCM_ERNIC_ETH_ICR_TX_COMPLETE (1 << 0) /* Transmit Complete */
#define ROCM_ERNIC_ETH_ICR_RX_PACKET   (1 << 1) /* Receive Packet */
#define ROCM_ERNIC_ETH_ICR_TX_ERROR    (1 << 2) /* Transmit Error */
#define ROCM_ERNIC_ETH_ICR_RX_ERROR    (1 << 3) /* Receive Error */

/* Descriptor status/command bits */
#define ROCM_ERNIC_ETH_DESC_STATUS_DD (1 << 0)
#define ROCM_ERNIC_ETH_DESC_CMD_EOP   (1 << 3)
#define ROCM_ERNIC_ETH_DESC_CMD_RS    (1 << 0)

/* Allocate RX descriptor ring */
static int rocm_ernic_eth_alloc_rx_ring(struct rocm_ernic_eth_dev *eth_dev)
{
    struct rocm_ernic_eth_rx_ring *ring = &eth_dev->rx_ring;
    size_t desc_size =
        ROCM_ERNIC_ETH_RX_RING_SIZE * sizeof(struct rocm_ernic_eth_desc);
    int i;

    /* Allocate descriptor ring */
    ring->desc = dma_alloc_coherent(&eth_dev->pdev->dev, desc_size,
                                    &ring->desc_dma, GFP_KERNEL);
    if (!ring->desc) {
        return -ENOMEM;
    }

    /* Allocate buffer tracking arrays */
    ring->buffers =
        kcalloc(ROCM_ERNIC_ETH_RX_RING_SIZE, sizeof(void *), GFP_KERNEL);
    ring->buffer_dma =
        kcalloc(ROCM_ERNIC_ETH_RX_RING_SIZE, sizeof(dma_addr_t), GFP_KERNEL);
    if (!ring->buffers || !ring->buffer_dma) {
        dma_free_coherent(&eth_dev->pdev->dev, desc_size, ring->desc,
                          ring->desc_dma);
        kfree(ring->buffers);
        kfree(ring->buffer_dma);
        return -ENOMEM;
    }

    /* Initialize ring and allocate RX buffers */
    memset(ring->desc, 0, desc_size);
    ring->head = 0;
    ring->tail = 0;
    ring->size = ROCM_ERNIC_ETH_RX_RING_SIZE;

    /* Allocate RX buffers for each descriptor */
    for (i = 0; i < ROCM_ERNIC_ETH_RX_RING_SIZE; i++) {
        void *buf = dma_alloc_coherent(&eth_dev->pdev->dev,
                                       ROCM_ERNIC_ETH_RX_BUFFER_SIZE,
                                       &ring->buffer_dma[i], GFP_KERNEL);
        if (!buf) {
            /* Free already allocated buffers */
            while (--i >= 0) {
                dma_free_coherent(&eth_dev->pdev->dev,
                                  ROCM_ERNIC_ETH_RX_BUFFER_SIZE,
                                  ring->buffers[i], ring->buffer_dma[i]);
            }
            dma_free_coherent(&eth_dev->pdev->dev, desc_size, ring->desc,
                              ring->desc_dma);
            kfree(ring->buffers);
            kfree(ring->buffer_dma);
            return -ENOMEM;
        }
        ring->buffers[i] = buf;

        /* Set up descriptor */
        ring->desc[i].addr = ring->buffer_dma[i];
        ring->desc[i].length = ROCM_ERNIC_ETH_RX_BUFFER_SIZE;
        ring->desc[i].status = 0;
        ring->desc[i].cmd = 0;
    }

    /* Set up RX descriptor base and length in registers */
    iowrite32((u32)(ring->desc_dma & 0xFFFFFFFF),
              eth_dev->regs + ROCM_ERNIC_ETH_RX_BAL);
    iowrite32((u32)(ring->desc_dma >> 32),
              eth_dev->regs + ROCM_ERNIC_ETH_RX_BAH);
    iowrite32(ROCM_ERNIC_ETH_RX_RING_SIZE,
              eth_dev->regs + ROCM_ERNIC_ETH_RX_LEN);
    iowrite32(0, eth_dev->regs + ROCM_ERNIC_ETH_RX_HEAD);
    iowrite32(0, eth_dev->regs + ROCM_ERNIC_ETH_RX_TAIL);

    return 0;
}

/* Free RX descriptor ring */
static void rocm_ernic_eth_free_rx_ring(struct rocm_ernic_eth_dev *eth_dev)
{
    struct rocm_ernic_eth_rx_ring *ring = &eth_dev->rx_ring;
    size_t desc_size =
        ROCM_ERNIC_ETH_RX_RING_SIZE * sizeof(struct rocm_ernic_eth_desc);
    int i;

    if (ring->desc) {
        /* Free RX buffers */
        for (i = 0; i < ROCM_ERNIC_ETH_RX_RING_SIZE; i++) {
            if (ring->buffers && ring->buffers[i] && ring->buffer_dma[i]) {
                dma_free_coherent(&eth_dev->pdev->dev,
                                  ROCM_ERNIC_ETH_RX_BUFFER_SIZE,
                                  ring->buffers[i], ring->buffer_dma[i]);
                ring->buffers[i] = NULL;
                ring->buffer_dma[i] = 0;
            }
        }
        dma_free_coherent(&eth_dev->pdev->dev, desc_size, ring->desc,
                          ring->desc_dma);
        ring->desc = NULL;
    }
    kfree(ring->buffers);
    ring->buffers = NULL;
    kfree(ring->buffer_dma);
    ring->buffer_dma = NULL;
}

/* Allocate TX descriptor ring */
static int rocm_ernic_eth_alloc_tx_ring(struct rocm_ernic_eth_dev *eth_dev)
{
    struct rocm_ernic_eth_tx_ring *ring = &eth_dev->tx_ring;
    size_t desc_size =
        ROCM_ERNIC_ETH_TX_RING_SIZE * sizeof(struct rocm_ernic_eth_desc);

    /* Allocate descriptor ring */
    ring->desc = dma_alloc_coherent(&eth_dev->pdev->dev, desc_size,
                                    &ring->desc_dma, GFP_KERNEL);
    if (!ring->desc) {
        return -ENOMEM;
    }

    /* Allocate buffer tracking arrays */
    ring->buffers =
        kcalloc(ROCM_ERNIC_ETH_TX_RING_SIZE, sizeof(void *), GFP_KERNEL);
    ring->buffer_dma =
        kcalloc(ROCM_ERNIC_ETH_TX_RING_SIZE, sizeof(dma_addr_t), GFP_KERNEL);
    if (!ring->buffers || !ring->buffer_dma) {
        dma_free_coherent(&eth_dev->pdev->dev, desc_size, ring->desc,
                          ring->desc_dma);
        kfree(ring->buffers);
        kfree(ring->buffer_dma);
        return -ENOMEM;
    }

    /* Initialize ring */
    memset(ring->desc, 0, desc_size);
    ring->head = 0;
    ring->tail = 0;
    ring->size = ROCM_ERNIC_ETH_TX_RING_SIZE;

    /* Set up TX descriptor base and length in registers */
    iowrite32((u32)(ring->desc_dma & 0xFFFFFFFF),
              eth_dev->regs + ROCM_ERNIC_ETH_TX_BAL);
    iowrite32((u32)(ring->desc_dma >> 32),
              eth_dev->regs + ROCM_ERNIC_ETH_TX_BAH);
    iowrite32(ROCM_ERNIC_ETH_TX_RING_SIZE,
              eth_dev->regs + ROCM_ERNIC_ETH_TX_LEN);
    iowrite32(0, eth_dev->regs + ROCM_ERNIC_ETH_TX_HEAD);
    iowrite32(0, eth_dev->regs + ROCM_ERNIC_ETH_TX_TAIL);

    return 0;
}

/* Free TX descriptor ring */
static void rocm_ernic_eth_free_tx_ring(struct rocm_ernic_eth_dev *eth_dev)
{
    struct rocm_ernic_eth_tx_ring *ring = &eth_dev->tx_ring;
    size_t desc_size =
        ROCM_ERNIC_ETH_TX_RING_SIZE * sizeof(struct rocm_ernic_eth_desc);
    int i;

    if (ring->desc) {
        /* Free any pending buffers */
        for (i = 0; i < ring->size; i++) {
            if (ring->buffers && ring->buffers[i] && ring->buffer_dma[i]) {
                dma_unmap_single(&eth_dev->pdev->dev, ring->buffer_dma[i],
                                 ring->desc[i].length, DMA_TO_DEVICE);
                dev_kfree_skb_any(ring->buffers[i]);
                ring->buffers[i] = NULL;
                ring->buffer_dma[i] = 0;
            }
        }
        dma_free_coherent(&eth_dev->pdev->dev, desc_size, ring->desc,
                          ring->desc_dma);
        ring->desc = NULL;
    }
    kfree(ring->buffers);
    ring->buffers = NULL;
    kfree(ring->buffer_dma);
    ring->buffer_dma = NULL;
}

/* Open handler - enable Ethernet and set carrier on */
static int rocm_ernic_eth_open(struct net_device *ndev)
{
    struct rocm_ernic_eth_dev **ndev_priv = netdev_priv(ndev);
    struct rocm_ernic_eth_dev *eth_dev = *ndev_priv;
    u32 ctl, status;
    int ret;

    if (!eth_dev || !eth_dev->regs) {
        return -ENODEV;
    }

    /* Allocate TX descriptor ring */
    ret = rocm_ernic_eth_alloc_tx_ring(eth_dev);
    if (ret) {
        dev_err(&eth_dev->pdev->dev, "Failed to allocate TX ring\n");
        return ret;
    }

    /* Allocate RX descriptor ring */
    ret = rocm_ernic_eth_alloc_rx_ring(eth_dev);
    if (ret) {
        dev_err(&eth_dev->pdev->dev, "Failed to allocate RX ring\n");
        rocm_ernic_eth_free_tx_ring(eth_dev);
        return ret;
    }

    /* Enable Ethernet RX/TX */
    ctl = ioread32(eth_dev->regs + ROCM_ERNIC_ETH_CTL);
    ctl |= ROCM_ERNIC_ETH_CTL_ENABLE | ROCM_ERNIC_ETH_CTL_RX_ENABLE |
           ROCM_ERNIC_ETH_CTL_TX_ENABLE;
    iowrite32(ctl, eth_dev->regs + ROCM_ERNIC_ETH_CTL);

    /* Enable RX packet interrupts in IMR */
    iowrite32(ROCM_ERNIC_ETH_ICR_RX_PACKET, eth_dev->regs + ROCM_ERNIC_ETH_IMR);
    dev_info(&eth_dev->pdev->dev, "Ethernet IMR enabled for RX packets\n");

    /* For virtual device, always set carrier ON */
    /* STATUS register check is informational but carrier should be ON */
    status = ioread32(eth_dev->regs + ROCM_ERNIC_ETH_STATUS);
    netif_carrier_on(ndev);
    if (status & ROCM_ERNIC_ETH_STATUS_LINK_UP) {
        dev_info(&eth_dev->pdev->dev, "Ethernet link up on %s\n", ndev->name);
    } else {
        dev_dbg(&eth_dev->pdev->dev,
                "Ethernet STATUS register shows link down (virtual device)\n");
    }

    return 0;
}

/* Stop handler - disable Ethernet */
static int rocm_ernic_eth_stop(struct net_device *ndev)
{
    struct rocm_ernic_eth_dev **ndev_priv = netdev_priv(ndev);
    struct rocm_ernic_eth_dev *eth_dev = *ndev_priv;
    u32 ctl;

    if (!eth_dev || !eth_dev->regs) {
        return -ENODEV;
    }

    /* Disable Ethernet RX/TX */
    ctl = ioread32(eth_dev->regs + ROCM_ERNIC_ETH_CTL);
    ctl &= ~(ROCM_ERNIC_ETH_CTL_ENABLE | ROCM_ERNIC_ETH_CTL_RX_ENABLE |
             ROCM_ERNIC_ETH_CTL_TX_ENABLE);
    iowrite32(ctl, eth_dev->regs + ROCM_ERNIC_ETH_CTL);

    /* Disable interrupts in IMR */
    iowrite32(0, eth_dev->regs + ROCM_ERNIC_ETH_IMR);

    /* Free TX and RX rings */
    rocm_ernic_eth_free_tx_ring(eth_dev);
    rocm_ernic_eth_free_rx_ring(eth_dev);

    netif_carrier_off(ndev);

    return 0;
}

/* Process completed TX descriptors */
static void rocm_ernic_eth_process_tx_completions(
    struct rocm_ernic_eth_dev *eth_dev)
{
    struct rocm_ernic_eth_tx_ring *ring = &eth_dev->tx_ring;
    u32 head, tail;
    struct rocm_ernic_eth_desc *desc;

    if (!ring->desc)
        return;

    /* Read head pointer from register (updated by server) */
    head = ioread32(eth_dev->regs + ROCM_ERNIC_ETH_TX_HEAD);
    tail = ring->head;

    /* Process completed descriptors */
    while (head != tail) {
        desc = &ring->desc[tail];

        /* Check if descriptor is done */
        if (desc->status & ROCM_ERNIC_ETH_DESC_STATUS_DD) {
            /* Free skb and unmap DMA */
            if (ring->buffers[tail]) {
                dma_unmap_single(&eth_dev->pdev->dev, ring->buffer_dma[tail],
                                 desc->length, DMA_TO_DEVICE);
                dev_kfree_skb_any(ring->buffers[tail]);
                ring->buffers[tail] = NULL;
            }

            /* Clear descriptor */
            desc->status = 0;
            desc->length = 0;

            /* Advance head */
            tail = (tail + 1) % ring->size;
        } else {
            /* Descriptor not done yet, stop processing */
            break;
        }
    }

    ring->head = tail;
}

/* Process received packets from RX descriptor ring */
static void rocm_ernic_eth_process_rx(struct rocm_ernic_eth_dev *eth_dev)
{
    struct rocm_ernic_eth_rx_ring *ring = &eth_dev->rx_ring;
    u32 head, tail;
    struct rocm_ernic_eth_desc *desc;
    struct sk_buff *skb;
    void *buf;
    dma_addr_t dma_addr;
    u16 pkt_len;

    if (!ring->desc)
        return;

    /* Read tail pointer from register (updated by server) */
    tail = ioread32(eth_dev->regs + ROCM_ERNIC_ETH_RX_TAIL);
    head = ring->head;

    dev_info(&eth_dev->pdev->dev, "RX processing: head=%u tail=%u\n", head,
             tail);

    /* Process received packets */
    while (head != tail) {
        desc = &ring->desc[head];

        /* Check if descriptor has data */
        if (desc->status & ROCM_ERNIC_ETH_DESC_STATUS_DD) {
            pkt_len = desc->length;
            dev_info(&eth_dev->pdev->dev,
                     "RX: Processing descriptor %u: len=%u status=0x%x\n", head,
                     pkt_len, desc->status);
            if (pkt_len > 0 && pkt_len <= ROCM_ERNIC_ETH_RX_BUFFER_SIZE) {
                buf = ring->buffers[head];
                dma_addr = ring->buffer_dma[head];

                /* Validate buffer and DMA address before use */
                if (!buf || !dma_addr) {
                    dev_warn(&eth_dev->pdev->dev,
                             "RX: Invalid buffer at descriptor %u (buf=%p "
                             "dma_addr=%pad)\n",
                             head, buf, &dma_addr);
                    /* Clear descriptor status and advance - buffer will be
                     * re-allocated on next use */
                    desc->status = 0;
                    /* Advance head and continue to next descriptor */
                    head = (head + 1) % ring->size;
                    /* Break out of inner if, but continue while loop */
                    break;
                }

                /* Allocate new skb for received packet */
                skb = netdev_alloc_skb_ip_align(eth_dev->netdev, pkt_len);
                if (skb) {
                    /* Copy packet data from DMA buffer */
                    skb_put_data(skb, buf, pkt_len);

                    /* Set device before eth_type_trans */
                    skb->dev = eth_dev->netdev;

                    /* Check Ethernet header for IP packets before
                     * eth_type_trans */
                    if (pkt_len >= 14) {
                        struct ethhdr *ethh = (struct ethhdr *)skb->data;
                        u16 ethertype = ntohs(ethh->h_proto);

                        dev_info(
                            &eth_dev->pdev->dev,
                            "RX: Ethernet packet: ethertype=0x%04x len=%u\n",
                            ethertype, pkt_len);

                        if (ethertype == ETH_P_IP && pkt_len >= 54) {
                            struct iphdr *iph =
                                (struct iphdr *)(skb->data + 14);
                            dev_info(&eth_dev->pdev->dev,
                                     "RX: IP packet: protocol=%u src=%pI4 "
                                     "dst=%pI4 len=%u\n",
                                     iph->protocol, &iph->saddr, &iph->daddr,
                                     pkt_len);

                            if (iph->protocol == IPPROTO_TCP &&
                                pkt_len >= 34 + 20) {
                                struct tcphdr *tcph =
                                    (struct tcphdr *)(skb->data + 34);
                                u8 tcp_flags = tcph->syn << 1 | tcph->ack |
                                               tcph->fin | (tcph->rst << 2) |
                                               (tcph->psh << 3);
                                dev_info(&eth_dev->pdev->dev,
                                         "RX: TCP packet: %pI4:%u -> %pI4:%u "
                                         "flags=0x%02x seq=%u ack=%u len=%u\n",
                                         &iph->saddr, ntohs(tcph->source),
                                         &iph->daddr, ntohs(tcph->dest),
                                         tcp_flags, ntohl(tcph->seq),
                                         ntohl(tcph->ack_seq), pkt_len);
                            } else if (iph->protocol == IPPROTO_TCP) {
                                dev_warn(&eth_dev->pdev->dev,
                                         "RX: TCP packet too short: "
                                         "protocol=%u len=%u (need >=54)\n",
                                         iph->protocol, pkt_len);
                            }
                        }
                    }

                    skb->protocol = eth_type_trans(skb, eth_dev->netdev);
                    skb->pkt_type = PACKET_HOST; /* Packet is for us */

                    dev_info(&eth_dev->pdev->dev,
                             "RX: Delivering packet to network stack: len=%u "
                             "protocol=0x%04x dev=%s up=%d running=%d\n",
                             pkt_len, ntohs(skb->protocol),
                             eth_dev->netdev->name,
                             netif_running(eth_dev->netdev),
                             netif_carrier_ok(eth_dev->netdev));

                    /* Only deliver if interface is up and running */
                    if (netif_running(eth_dev->netdev)) {
                        /* Deliver to network stack using netif_receive_skb for
                         * better integration with network stack (handles
                         * bridging, VLAN, etc.) */
                        netif_receive_skb(skb);
                    } else {
                        dev_warn(
                            &eth_dev->pdev->dev,
                            "RX: Interface not running, dropping packet\n");
                        dev_kfree_skb_any(skb);
                    }
                } else {
                    dev_warn(&eth_dev->pdev->dev,
                             "RX: Failed to allocate skb for packet len=%u\n",
                             pkt_len);
                }

                /* Re-allocate buffer for this descriptor */
                dma_free_coherent(&eth_dev->pdev->dev,
                                  ROCM_ERNIC_ETH_RX_BUFFER_SIZE, buf, dma_addr);
                buf = dma_alloc_coherent(&eth_dev->pdev->dev,
                                         ROCM_ERNIC_ETH_RX_BUFFER_SIZE,
                                         &dma_addr, GFP_ATOMIC);
                if (buf) {
                    ring->buffers[head] = buf;
                    ring->buffer_dma[head] = dma_addr;
                    desc->addr = dma_addr;
                    desc->length = ROCM_ERNIC_ETH_RX_BUFFER_SIZE;
                } else {
                    dev_warn(&eth_dev->pdev->dev,
                             "RX: Failed to re-allocate buffer for descriptor "
                             "%u\n",
                             head);
                    /* Mark buffer as invalid */
                    ring->buffers[head] = NULL;
                    ring->buffer_dma[head] = 0;
                }

                /* Clear descriptor status */
                desc->status = 0;
            }

            /* Advance head */
            head = (head + 1) % ring->size;
        } else {
            /* Descriptor not ready yet, stop processing */
            break;
        }
    }

    /* Update head pointer and register */
    if (head != ring->head) {
        ring->head = head;
        iowrite32(head, eth_dev->regs + ROCM_ERNIC_ETH_RX_HEAD);
    }
}

/* Transmit handler - queue packet in TX descriptor ring */
static netdev_tx_t rocm_ernic_eth_xmit(struct sk_buff *skb,
                                       struct net_device *ndev)
{
    struct rocm_ernic_eth_dev **ndev_priv = netdev_priv(ndev);
    struct rocm_ernic_eth_dev *eth_dev = *ndev_priv;
    struct rocm_ernic_eth_tx_ring *ring;
    struct rocm_ernic_eth_desc *desc;
    dma_addr_t dma_addr;
    u32 next_tail;
    u32 tail;

    if (!eth_dev || !eth_dev->regs) {
        dev_kfree_skb_any(skb);
        return NETDEV_TX_OK;
    }

    ring = &eth_dev->tx_ring;
    if (!ring->desc) {
        dev_kfree_skb_any(skb);
        return NETDEV_TX_OK;
    }

    /* Process completed TX descriptors only - RX is handled by interrupt */
    rocm_ernic_eth_process_tx_completions(eth_dev);

    /* Check if ring has space */
    tail = ring->tail;
    next_tail = (tail + 1) % ring->size;
    if (next_tail == ring->head) {
        /* Ring full - drop packet */
        dev_kfree_skb_any(skb);
        return NETDEV_TX_BUSY;
    }

    /* Map skb data for DMA */
    dma_addr =
        dma_map_single(&eth_dev->pdev->dev, skb->data, skb->len, DMA_TO_DEVICE);
    if (dma_mapping_error(&eth_dev->pdev->dev, dma_addr)) {
        dev_kfree_skb_any(skb);
        return NETDEV_TX_OK;
    }

    /* Get descriptor */
    desc = &ring->desc[tail];

    /* Store skb for cleanup later */
    ring->buffers[tail] = skb;
    ring->buffer_dma[tail] = dma_addr;

    /* Fill descriptor */
    desc->addr = dma_addr;
    desc->length = skb->len;
    desc->status = 0;
    desc->cmd = ROCM_ERNIC_ETH_DESC_CMD_EOP | ROCM_ERNIC_ETH_DESC_CMD_RS;
    desc->vlan = 0;
    desc->cso = 0;
    desc->css = 0;
    desc->special = 0;

    /* Update tail pointer */
    ring->tail = next_tail;

    /* Write tail register to trigger server processing */
    iowrite32(next_tail, eth_dev->regs + ROCM_ERNIC_ETH_TX_TAIL);

    return NETDEV_TX_OK;
}

/* Minimal netdev_ops */
static const struct net_device_ops rocm_ernic_eth_netdev_ops = {
    .ndo_init = NULL,
    .ndo_uninit = NULL,
    .ndo_open = rocm_ernic_eth_open,
    .ndo_stop = rocm_ernic_eth_stop,
    .ndo_start_xmit = rocm_ernic_eth_xmit,
    .ndo_validate_addr = NULL,
    .ndo_set_mac_address = NULL,
    .ndo_change_mtu = NULL,
    .ndo_get_stats64 = NULL,
};

/* List of Ethernet devices */
static LIST_HEAD(rocm_ernic_eth_dev_list);
static DEFINE_MUTEX(rocm_ernic_eth_dev_list_lock);

static struct net_device *rocm_ernic_eth_create_netdev(
    struct rocm_ernic_eth_dev *eth_dev, const char *name_fmt)
{
    struct net_device *ndev;
    struct rocm_ernic_eth_dev **ndev_priv;
    u8 mac[ETH_ALEN] = {0x02, 0x00, 0x00, 0x00, 0x00, 0x00};
    int ret;

    /* Read MAC address from device registers */
    if (eth_dev->regs) {
        u32 mac0 = ioread32(eth_dev->regs + ROCM_ERNIC_ETH_MAC0);
        u32 mac1 = ioread32(eth_dev->regs + ROCM_ERNIC_ETH_MAC1);

        mac[0] = (u8)(mac0 & 0xff);
        mac[1] = (u8)((mac0 >> 8) & 0xff);
        mac[2] = (u8)((mac0 >> 16) & 0xff);
        mac[3] = (u8)((mac0 >> 24) & 0xff);
        mac[4] = (u8)(mac1 & 0xff);
        mac[5] = (u8)((mac1 >> 8) & 0xff);

        /* Fallback to default if MAC is all zeros or invalid */
        if (mac[0] == 0 && mac[1] == 0 && mac[2] == 0 && mac[3] == 0 &&
            mac[4] == 0 && mac[5] == 0) {
            /* Use default MAC with function number */
            mac[0] = 0x02;
            mac[ETH_ALEN - 1] = PCI_FUNC(eth_dev->pdev->devfn);
        }
    } else {
        /* No regs yet, use default with function number */
        mac[ETH_ALEN - 1] = PCI_FUNC(eth_dev->pdev->devfn);
    }

    /* Allocate netdev with ethernet setup and private data (pointer size) */
    ndev = alloc_netdev(sizeof(struct rocm_ernic_eth_dev *), name_fmt,
                        NET_NAME_ENUM, ether_setup);
    if (!ndev)
        return NULL;

    /* Store eth_dev pointer in netdev private data */
    ndev_priv = netdev_priv(ndev);
    *ndev_priv = eth_dev;

    /* Set MAC address before setting parent device */
    eth_hw_addr_set(ndev, mac);
    ndev->addr_assign_type = NET_ADDR_SET;

    /* Associate netdev with parent PCI device */
    SET_NETDEV_DEV(ndev, &eth_dev->pdev->dev);

    /* Set netdev_ops */
    ndev->netdev_ops = &rocm_ernic_eth_netdev_ops;

    /* Mark as virtual/dummy device */
    ndev->priv_flags |= IFF_NO_QUEUE;
    ndev->priv_flags |= IFF_DISABLE_NETPOLL;

    /* Register the device */
    ret = register_netdev(ndev);
    if (ret) {
        dev_warn(&eth_dev->pdev->dev, "register_netdev failed (%d)\n", ret);
        free_netdev(ndev);
        return NULL;
    }

    /* Set carrier ON immediately for virtual device */
    /* Virtual devices like rocm_ernic don't have physical link detection,
     * so carrier should be ON by default. The STATUS register check is
     * informational but shouldn't block carrier ON for virtual devices. */
    netif_carrier_on(ndev);

    /* Check status register for informational purposes */
    if (eth_dev->regs) {
        u32 status = ioread32(eth_dev->regs + ROCM_ERNIC_ETH_STATUS);
        if (status & ROCM_ERNIC_ETH_STATUS_LINK_UP) {
            dev_info(&eth_dev->pdev->dev,
                     "Ethernet STATUS register confirms link up\n");
        } else {
            dev_dbg(&eth_dev->pdev->dev,
                    "Ethernet STATUS register shows link down (virtual device, "
                    "carrier ON anyway)\n");
        }
    }

    dev_info(&eth_dev->pdev->dev, "registered netdev %s mac %pM\n", ndev->name,
             ndev->dev_addr);

    return ndev;
}

static void rocm_ernic_eth_release_netdev(struct rocm_ernic_eth_dev *eth_dev)
{
    if (!eth_dev->netdev)
        return;

    rtnl_lock();
    if (netif_running(eth_dev->netdev)) {
        dev_close(eth_dev->netdev);
    }
    netif_carrier_off(eth_dev->netdev);
    rtnl_unlock();

    unregister_netdev(eth_dev->netdev);
    free_netdev(eth_dev->netdev);
    eth_dev->netdev = NULL;
}

/* Exported API for RDMA driver */
struct rocm_ernic_eth_dev *rocm_ernic_eth_get_dev(struct pci_dev *pdev)
{
    struct rocm_ernic_eth_dev *eth_dev;

    mutex_lock(&rocm_ernic_eth_dev_list_lock);
    list_for_each_entry(eth_dev, &rocm_ernic_eth_dev_list, list)
    {
        if (eth_dev->pdev == pdev) {
            mutex_unlock(&rocm_ernic_eth_dev_list_lock);
            return eth_dev;
        }
    }
    mutex_unlock(&rocm_ernic_eth_dev_list_lock);
    return NULL;
}
EXPORT_SYMBOL(rocm_ernic_eth_get_dev);

/* Process RX packets - exported for interrupt handler */
void rocm_ernic_eth_handle_rx_interrupt(struct pci_dev *pdev)
{
    struct rocm_ernic_eth_dev *eth_dev = rocm_ernic_eth_get_dev(pdev);
    if (eth_dev) {
        dev_info(&pdev->dev, "Processing RX packets from interrupt handler\n");
        rocm_ernic_eth_process_rx(eth_dev);
    } else {
        dev_warn(&pdev->dev, "Ethernet device not found for RX interrupt\n");
    }
}
EXPORT_SYMBOL(rocm_ernic_eth_handle_rx_interrupt);

struct net_device *rocm_ernic_eth_get_netdev(struct pci_dev *pdev)
{
    struct rocm_ernic_eth_dev *eth_dev = rocm_ernic_eth_get_dev(pdev);
    return eth_dev ? eth_dev->netdev : NULL;
}
EXPORT_SYMBOL(rocm_ernic_eth_get_netdev);

void __iomem *rocm_ernic_eth_get_regs(struct pci_dev *pdev)
{
    struct rocm_ernic_eth_dev *eth_dev = rocm_ernic_eth_get_dev(pdev);
    return eth_dev ? eth_dev->regs : NULL;
}
EXPORT_SYMBOL(rocm_ernic_eth_get_regs);

struct pci_dev *rocm_ernic_eth_get_pdev(struct rocm_ernic_eth_dev *eth_dev)
{
    return eth_dev ? eth_dev->pdev : NULL;
}
EXPORT_SYMBOL(rocm_ernic_eth_get_pdev);

static const struct pci_device_id rocm_ernic_eth_pci_table[] = {
    {
        PCI_DEVICE(PCI_VENDOR_ID_ROCM_ERNIC, PCI_DEVICE_ID_ROCM_ERNIC),
    },
    {0},
};

MODULE_DEVICE_TABLE(pci, rocm_ernic_eth_pci_table);

static int rocm_ernic_eth_pci_probe(struct pci_dev *pdev,
                                    const struct pci_device_id *id)
{
    struct rocm_ernic_eth_dev *eth_dev;
    unsigned long start, len;
    int ret;

    dev_dbg(&pdev->dev, "Ethernet driver probing %s\n", pci_name(pdev));

    eth_dev = kzalloc(sizeof(*eth_dev), GFP_KERNEL);
    if (!eth_dev)
        return -ENOMEM;

    eth_dev->pdev = pdev;
    pci_set_drvdata(pdev, eth_dev);

    ret = pci_enable_device(pdev);
    if (ret) {
        dev_err(&pdev->dev, "cannot enable PCI device\n");
        goto err_free_dev;
    }

    ret = pci_request_regions(pdev, DRV_NAME_ETH);
    if (ret) {
        dev_err(&pdev->dev, "cannot request PCI resources\n");
        goto err_disable_pdev;
    }

    /* Enable 64-Bit DMA */
    ret = dma_set_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(64));
    if (ret) {
        dev_err(&pdev->dev, "dma_set_mask failed\n");
        goto err_free_resource;
    }
    dma_set_max_seg_size(&pdev->dev, UINT_MAX);
    pci_set_master(pdev);

    /* Map register space (BAR1) */
    start = pci_resource_start(pdev, 1);
    len = pci_resource_len(pdev, 1);
    eth_dev->regs = ioremap(start, len);
    if (!eth_dev->regs) {
        dev_err(&pdev->dev, "register mapping failed\n");
        ret = -ENOMEM;
        goto err_free_resource;
    }

    /* Create netdev */
    eth_dev->netdev = rocm_ernic_eth_create_netdev(eth_dev, "rocm_ernic%d");
    if (!eth_dev->netdev) {
        dev_err(&pdev->dev, "failed to create netdev\n");
        ret = -ENODEV;
        goto err_unmap_regs;
    }

    /* Add to device list */
    mutex_lock(&rocm_ernic_eth_dev_list_lock);
    list_add(&eth_dev->list, &rocm_ernic_eth_dev_list);
    mutex_unlock(&rocm_ernic_eth_dev_list_lock);

    dev_info(&pdev->dev, "Ethernet driver initialized (netdev=%s)\n",
             eth_dev->netdev->name);

    return 0;

err_unmap_regs:
    iounmap(eth_dev->regs);
err_free_resource:
    pci_release_regions(pdev);
err_disable_pdev:
    pci_disable_device(pdev);
err_free_dev:
    kfree(eth_dev);
    pci_set_drvdata(pdev, NULL);
    return ret;
}

static void rocm_ernic_eth_pci_remove(struct pci_dev *pdev)
{
    struct rocm_ernic_eth_dev *eth_dev = pci_get_drvdata(pdev);

    if (!eth_dev)
        return;

    dev_info(&pdev->dev, "Ethernet driver removing\n");

    /* Stop the device first to prevent interrupts from accessing freed buffers
     */
    rocm_ernic_eth_stop(eth_dev->netdev);

    /* Wait for RCU grace period */
    synchronize_rcu();
    msleep(50);

    /* Remove from device list */
    mutex_lock(&rocm_ernic_eth_dev_list_lock);
    list_del(&eth_dev->list);
    mutex_unlock(&rocm_ernic_eth_dev_list_lock);

    /* Release netdev */
    rocm_ernic_eth_release_netdev(eth_dev);

    /* Unmap registers */
    if (eth_dev->regs)
        iounmap(eth_dev->regs);

    /* Free PCI resources */
    pci_release_regions(pdev);
    pci_disable_device(pdev);
    pci_set_drvdata(pdev, NULL);

    kfree(eth_dev);
}

static struct pci_driver rocm_ernic_eth_driver = {
    .name = DRV_NAME_ETH,
    .id_table = rocm_ernic_eth_pci_table,
    .probe = rocm_ernic_eth_pci_probe,
    .remove = rocm_ernic_eth_pci_remove,
};

static int __init rocm_ernic_eth_init(void)
{
    return pci_register_driver(&rocm_ernic_eth_driver);
}

static void __exit rocm_ernic_eth_cleanup(void)
{
    pci_unregister_driver(&rocm_ernic_eth_driver);
}

module_init(rocm_ernic_eth_init);
module_exit(rocm_ernic_eth_cleanup);

MODULE_AUTHOR("Advanced Micro Devices, Inc");
MODULE_DESCRIPTION("AMD ROCm ERNIC - Ethernet driver");
MODULE_LICENSE("Dual BSD/GPL");
MODULE_VERSION(DRV_VERSION);
