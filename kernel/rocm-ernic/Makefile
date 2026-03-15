# SPDX-License-Identifier: GPL-2.0
#
# Out-of-tree Makefile for rocm_ernic_eth + rocm_ernic_rdma
#
# Builds two modules (matching upstream rocm-ernic driver/Makefile):
#   rocm_ernic_eth.ko  - ethernet driver (single file)
#   rocm_ernic_rdma.ko - RDMA driver
#
# Source populated by setup-rocm-ernic-eth-rdma-dkms.sh

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)

# --- rocm_ernic_eth ethernet module (single file) ---
obj-m += rocm_ernic_eth.o

# --- rocm_ernic_rdma RDMA module ---
obj-m += rocm_ernic_rdma.o
rocm_ernic_rdma-y := rocm_ernic_cmd.o rocm_ernic_cq.o \
	rocm_ernic_doorbell.o rocm_ernic_main.o \
	rocm_ernic_misc.o rocm_ernic_mr.o rocm_ernic_qp.o \
	rocm_ernic_srq.o rocm_ernic_verbs.o rocm_ernic_uapi.o

# Include path for ABI header
ccflags-y := -I$(M)/include

# Prepend include/ for <rdma/rocm_ernic-abi.h> etc.
LINUXINCLUDE := -I$(M)/include $(LINUXINCLUDE)

# Ensure vmlinux symlink exists for BTF generation
VMLINUX := $(KDIR)/vmlinux
VMLINUX_BTF := /sys/kernel/btf/vmlinux

all: check-vmlinux
	$(MAKE) -C $(KDIR) M=$(PWD) modules

check-vmlinux:
	@if [ ! -f $(VMLINUX) ] && [ -f $(VMLINUX_BTF) ]; then \
		echo "Creating vmlinux symlink for BTF"; \
		sudo ln -sf $(VMLINUX_BTF) $(VMLINUX) \
		  2>/dev/null || \
		echo "Warning: Could not create vmlinux" \
		  "symlink. BTF may be skipped."; \
	fi

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

install: all
	$(MAKE) -C $(KDIR) M=$(PWD) modules_install
	depmod -a
	@echo ""
	@echo "rocm_ernic_eth + rocm_ernic_rdma installed."
	@echo "  sudo modprobe rocm_ernic_eth"
	@echo "  sudo modprobe rocm_ernic_rdma"
	@echo "  (unload in reverse order)"

.PHONY: all clean install check-vmlinux
