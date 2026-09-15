obj-m += rocm-xio.o

# Shared ioctl definitions with userspace (src/include/rocm-xio-uapi.h)
ccflags-y += -I$(src)/../../src/include

# Detect whether request_queue uses hctx_table (xarray, upstream ~6.14+) or
# queue_hw_ctx (array, older kernels and some distro trees).
HCTX_TABLE_EXISTS := $(shell grep -c "hctx_table" \
  /lib/modules/$(shell uname -r)/build/include/linux/blkdev.h 2>/dev/null)
ifeq ($(HCTX_TABLE_EXISTS),0)
ccflags-y += -DROCM_XIO_NO_HCTX_TABLE
endif

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)

# Ensure vmlinux symlink exists for BTF generation
# BTF is available at /sys/kernel/btf/vmlinux at runtime
VMLINUX := $(KDIR)/vmlinux
VMLINUX_BTF := /sys/kernel/btf/vmlinux

all: check-vmlinux
	$(MAKE) -C $(KDIR) M=$(PWD) modules

check-vmlinux:
	@if [ ! -f $(VMLINUX) ] && [ -f $(VMLINUX_BTF) ]; then \
		echo "Creating symlink $(VMLINUX) -> $(VMLINUX_BTF) for BTF generation"; \
		sudo ln -sf $(VMLINUX_BTF) $(VMLINUX) 2>/dev/null || \
		echo "Warning: Could not create vmlinux symlink (may need sudo). BTF generation may be skipped."; \
	fi

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

install: all
	$(MAKE) -C $(KDIR) M=$(PWD) modules_install
	depmod -a
	@echo "rocm-xio module installed"
	@echo "Load with: sudo modprobe rocm-xio"
	@echo "Create device node: sudo mknod /dev/rocm-xio c $(shell grep rocm-xio /proc/devices | awk '{print $$1}') 0"
	@echo "Set permissions: sudo chmod 666 /dev/rocm-xio"

.PHONY: all clean install

