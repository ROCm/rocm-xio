# SPDX-License-Identifier: GPL-2.0
#
# Out-of-tree Makefile for bnxt_re with uapi extensions
# (Direct Verbs).
#
# The bnxt_re driver normally lives in-tree at
# drivers/infiniband/hw/bnxt_re/. This Makefile builds
# it out-of-tree against installed kernel headers, with
# the v11 uapi-extension patches applied.
#
# The source files are populated by setup-bnxt-re-dkms.sh
# into this directory.

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)

# --- module object list ---
# Upstream bnxt_re objects + uapi.o from v11 patches
obj-m += bnxt_re.o
bnxt_re-y := main.o ib_verbs.o \
	     qplib_res.o qplib_rcfw.o \
	     qplib_sp.o qplib_fp.o hw_counters.o \
	     debugfs.o uapi.o

# Prepend our include/ to LINUXINCLUDE so that the
# patched <rdma/bnxt_re-abi.h> is found before the
# stock kernel header.
LINUXINCLUDE := -I $(M)/include $(LINUXINCLUDE)

# The in-tree Makefile uses -I $(srctree)/drivers/net/
# ethernet/broadcom/bnxt. Out-of-tree we bundle those
# headers locally.
ccflags-y := -I $(M)/include/bnxt

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
	@echo "bnxt_re (DV) module installed."
	@echo "  sudo modprobe -r bnxt_re  # unload stock"
	@echo "  sudo modprobe bnxt_re     # load DV version"

.PHONY: all clean install check-vmlinux
