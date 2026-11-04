# ==============================================================================
# Top-level Makefile for Bobcat Miner 300 (G285 / RK3566) Gateway Firmware
# ==============================================================================

.PHONY: all build clean install test

all: build

build:
	$(MAKE) -C sx1302_hal all
	$(MAKE) -C sx1302_hal raw_lora_app

clean:
	$(MAKE) -C sx1302_hal clean

install:
	./install.sh

test:
	./bin/test-lora
	./bin/test-leds
