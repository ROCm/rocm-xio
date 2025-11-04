# Makefile for NVMe AXIIO Kernel Module

obj-m += nvme_axiio.o

# Kernel build directory
KERNEL_DIR ?= /lib/modules/$(shell uname -r)/build

# Module source directory
PWD := $(shell pwd)

all:
	$(MAKE) -C $(KERNEL_DIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KERNEL_DIR) M=$(PWD) clean

install:
	$(MAKE) -C $(KERNEL_DIR) M=$(PWD) modules_install
	depmod -a

load:
	sudo insmod nvme_axiio.ko

unload:
	sudo rmmod nvme_axiio

reload: unload load

test:
	@echo "Testing module load..."
	@sudo insmod nvme_axiio.ko || true
	@sleep 1
	@ls -la /dev/nvme-axiio
	@dmesg | tail -20
	@sudo rmmod nvme_axiio || true

.PHONY: all clean install load unload reload test

