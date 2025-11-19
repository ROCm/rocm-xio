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

# Installation directory (can be overridden with DESTDIR)
INSTALL_MOD_PATH ?=
INSTALL_MOD_DIR ?= extra

install:
	@echo "Installing nvme_axiio module..."
	$(MAKE) -C $(KERNEL_DIR) M=$(PWD) \
		INSTALL_MOD_PATH=$(INSTALL_MOD_PATH) \
		INSTALL_MOD_DIR=$(INSTALL_MOD_DIR) \
		modules_install
	@if [ -z "$(INSTALL_MOD_PATH)" ]; then \
		echo "Updating module dependencies..."; \
		depmod -a; \
	fi
	@echo "✓ Module installed to /lib/modules/$$(uname -r)/$(INSTALL_MOD_DIR)/"

uninstall:
	@echo "Uninstalling nvme_axiio module..."
	@MODULE_PATH="/lib/modules/$$(uname -r)/$(INSTALL_MOD_DIR)/nvme_axiio.ko"; \
	if [ -f "$$MODULE_PATH" ]; then \
		rm -f "$$MODULE_PATH"; \
		echo "✓ Module removed from $$MODULE_PATH"; \
		depmod -a; \
	else \
		echo "✗ Module not found at $$MODULE_PATH"; \
	fi

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

.PHONY: all clean install uninstall load unload reload test

