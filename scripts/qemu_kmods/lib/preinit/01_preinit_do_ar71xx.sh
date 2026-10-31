#!/bin/sh

do_ar71xx() {
	mkdir -p /tmp/sysinfo
	echo "dragino2" > /tmp/sysinfo/board_name
	echo "Dragino 2 (MS14)" > /tmp/sysinfo/model
}

boot_hook_add preinit_main do_ar71xx
