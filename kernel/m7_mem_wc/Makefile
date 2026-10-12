obj-m := m7_mem_wc.o

# Built ON the MiSTer (needs its kernel headers): make -C kernel/m7_mem_wc
KDIR ?= /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)
ARCH ?= arm
CROSS_COMPILE ?=

.PHONY: all clean

all:
	$(MAKE) -C $(KDIR) M=$(PWD) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) clean
