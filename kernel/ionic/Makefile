# SPDX-License-Identifier: GPL-2.0
#
# Out-of-tree Makefile for ionic + ionic_rdma
# RDMA support.
#
# Builds two modules:
#   ionic.ko      - patched ethernet driver with
#                   RDMA auxiliary device support
#   ionic_rdma.ko - InfiniBand RDMA driver
#
# The source files are populated by
# setup-ionic-rdma-dkms.sh into this directory.

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)

# --- ionic ethernet module ---
obj-m += ionic.o
ionic-y := ionic_bus_pci.o ionic_debugfs.o \
	   ionic_dev.o ionic_devlink.o \
	   ionic_ethtool.o ionic_fw.o \
	   ionic_lif.o ionic_main.o \
	   ionic_rx_filter.o ionic_stats.o \
	   ionic_txrx.o

# Add ionic_aux if it exists (from the patches)
ifneq ($(wildcard $(M)/ionic_aux.c),)
  ionic-y += ionic_aux.o
endif

# Add ionic_phc if it exists
ifneq ($(wildcard $(M)/ionic_phc.c),)
  ionic-y += ionic_phc.o
endif

# --- ionic_rdma InfiniBand module ---
# Use subdir-m so kbuild descends into rdma/
ifneq ($(wildcard $(M)/rdma/ionic_ibdev.c),)
  obj-m += rdma/
endif

ccflags-y := -I$(M)/include

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

install: all
	$(MAKE) -C $(KDIR) M=$(PWD) modules_install
	depmod -a
	@echo ""
	@echo "ionic + ionic_rdma modules installed."
	@echo "  sudo modprobe -r ionic_rdma"
	@echo "  sudo modprobe -r ionic"
	@echo "  sudo modprobe ionic"
	@echo "  sudo modprobe ionic_rdma"

.PHONY: all clean install
