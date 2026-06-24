obj-m += qnap8528.o

KERNEL_DIR ?= /lib/modules/$(shell uname -r)/build
#CFLAGS_qnap8528.o := -DDEBUG

all:
	@echo "============================================"
	@echo " If you are not me or a developer ignore;"
	@echo " REMEMBER: All configuration entries with a"
	@echo " MB code only should be at the end of the"
	@echo " configuration array to avoid mixed models"
	@echo "============================================"
	$(MAKE) -C $(KERNEL_DIR) M=$$PWD modules

clean:
	$(MAKE) -C $(KERNEL_DIR) M=$$PWD clean
