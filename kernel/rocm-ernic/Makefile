# SPDX-License-Identifier: GPL-2.0
#
# Out-of-tree Makefile for rocm_ernic with DV
# (Direct Verbs) extensions.
#
# The rocm_ernic driver source lives in the
# rocm-ernic project at driver/. This Makefile
# builds it out-of-tree against installed kernel
# headers, including the new DV uapi source.
#
# The source files are populated by
# setup-rocm-ernic-dv-dkms.sh into this directory.

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)

# --- module object list ---
obj-m += rocm_ernic.o
rocm_ernic-y := rocm_ernic_cmd.o \
		rocm_ernic_cq.o \
		rocm_ernic_doorbell.o \
		rocm_ernic_main.o \
		rocm_ernic_misc.o \
		rocm_ernic_mr.o \
		rocm_ernic_qp.o \
		rocm_ernic_srq.o \
		rocm_ernic_verbs.o \
		rocm_ernic_uapi.o

# Prepend our include/ to LINUXINCLUDE so that the
# DV <rdma/rocm_ernic-abi.h> is found before any
# stock kernel header.
LINUXINCLUDE := -I $(M)/include $(LINUXINCLUDE)

# Ensure vmlinux symlink exists for BTF generation
VMLINUX := $(KDIR)/vmlinux
VMLINUX_BTF := /sys/kernel/btf/vmlinux

all: check-vmlinux
	$(MAKE) -C $(KDIR) M=$(PWD) modules

check-vmlinux:
	@if [ ! -f $(VMLINUX) ] && \
	    [ -f $(VMLINUX_BTF) ]; then \
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
	@echo "rocm_ernic (DV) module installed."
	@echo "  sudo modprobe -r rocm_ernic"
	@echo "  sudo modprobe rocm_ernic"

.PHONY: all clean install check-vmlinux
