# Out-of-tree kernel module Makefile for rocm_ernic
# Usage: make -f Makefile.out-of-tree

# Kernel build directory
KDIR ?= /lib/modules/$(shell uname -r)/build

# Ethernet driver module (rocm_ernic_eth.ko) - single file module
obj-m += rocm_ernic_eth.o

# RDMA driver module (rocm_ernic_rdma.ko) - depends on rocm_ernic_eth
obj-m += rocm_ernic_rdma.o
rocm_ernic_rdma-y := rocm_ernic_cmd.o rocm_ernic_cq.o rocm_ernic_doorbell.o \
                     rocm_ernic_main.o rocm_ernic_misc.o rocm_ernic_mr.o \
                     rocm_ernic_qp.o rocm_ernic_srq.o rocm_ernic_uapi.o \
                     rocm_ernic_verbs.o

# Current directory (where the driver source is)
PWD := $(shell pwd)

# Default target: build the module
all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

# Clean build artifacts
clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

# Install the module (requires root)
install:
	$(MAKE) -C $(KDIR) M=$(PWD) modules_install
	depmod -a

# Load the modules (requires root)
# Note: modprobe will auto-load dependencies via MODULE_SOFTDEP
load:
	modprobe ib_core || true
	modprobe ib_uverbs || true
	insmod rocm_ernic_eth.ko
	insmod rocm_ernic_rdma.ko

# Unload the modules (requires root)
unload:
	rmmod rocm_ernic_rdma || true
	rmmod rocm_ernic_eth || true

# Reload the modules (requires root)
reload: unload load

# Show module info
info:
	modinfo rocm_ernic_eth.ko
	modinfo rocm_ernic_rdma.ko

# Show build configuration
config:
	@echo "Kernel build directory: $(KDIR)"
	@echo "Module directory: $(PWD)"
	@echo "Current kernel: $(shell uname -r)"

.PHONY: all clean install load unload reload info config

