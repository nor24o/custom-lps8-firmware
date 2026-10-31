### Environment constants

ARCH ?=
CROSS_COMPILE ?=
export

### general build targets

.PHONY: all clean install install_conf libtools libloragw packet_forwarder util_net_downlink util_chip_id util_boot util_spectral_scan raw_lora_app

all: libtools libloragw packet_forwarder util_net_downlink util_chip_id util_boot util_spectral_scan raw_lora_app

libtools:
	$(MAKE) all -e -C $@

libloragw: libtools
	$(MAKE) all -e -C $@

packet_forwarder: libloragw
	$(MAKE) all -e -C $@

util_net_downlink: libtools
	$(MAKE) all -e -C $@

util_chip_id: libloragw
	$(MAKE) all -e -C $@

util_boot: libloragw
	$(MAKE) all -e -C $@

util_spectral_scan: libloragw
	$(MAKE) all -e -C $@

raw_lora_app: libloragw libtools
	$(CROSS_COMPILE)gcc -O2 -Wall \
	  -o raw_lora_app raw_lora_app.c libtools/src/parson.c libtools/src/base64.c \
	  -I./libloragw/inc -I./libtools/inc \
	  -L./libloragw -L./libtools \
	  -lloragw -ltinymt32 -lm -lrt -lpthread

clean:
	rm -f raw_lora_app
	$(MAKE) clean -e -C libtools
	$(MAKE) clean -e -C libloragw
	$(MAKE) clean -e -C packet_forwarder
	$(MAKE) clean -e -C util_net_downlink
	$(MAKE) clean -e -C util_chip_id
	$(MAKE) clean -e -C util_boot
	$(MAKE) clean -e -C util_spectral_scan

install:
	$(MAKE) install -e -C libloragw
	$(MAKE) install -e -C packet_forwarder
	$(MAKE) install -e -C util_net_downlink
	$(MAKE) install -e -C util_chip_id
	$(MAKE) install -e -C util_boot
	$(MAKE) install -e -C util_spectral_scan

install_conf:
	$(MAKE) install_conf -e -C packet_forwarder

### EOF
