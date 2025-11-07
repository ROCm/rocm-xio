# Makefile for NVMe GDA Kernel Driver

obj-m += nvme_gda.o

KDIR := /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

install:
	$(MAKE) -C $(KDIR) M=$(PWD) modules_install
	depmod -a

load:
	sudo insmod nvme_gda.ko nvme_pci_dev=$(PCI_DEV)

unload:
	sudo rmmod nvme_gda

.PHONY: all clean install load unload

