# Out-of-tree build of the vfu-dma module.
#
#   make                 build against the running kernel
#   make KDIR=<path>     build against another kernel's build tree
#   sudo make install    install and run depmod
#
# SPDX-License-Identifier: GPL-2.0-or-later

obj-m += vfu-dma.o

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

install: all
	$(MAKE) -C $(KDIR) M=$(PWD) modules_install
	depmod -a
	@echo "vfu-dma module installed"
	@echo "Load with: sudo modprobe vfu-dma (it binds to the ringer, 1de0:0002)"
