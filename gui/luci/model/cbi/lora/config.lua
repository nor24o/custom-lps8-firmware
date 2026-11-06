local m, s, o
local uci = require("luci.model.uci").cursor()

m = Map("lora", translate("LoRa Gateway Configuration"),
    translate("Configure your LoRaWAN Concentrator, Network Server connection, and RF parameters. Changes are automatically synchronized to the packet forwarder daemon."))

-- SECTION 1: LoRaWAN Network Server
s = m:section(NamedSection, "general", "lora", translate("Network Server Connection"))
s.anonymous = false
s.addremove = false

o = s:option(Value, "server_address", translate("Server Address"), translate("Hostname or IP address of the LoRaWAN Network Server (e.g., The Things Network, ChirpStack, AWS IoT Core)"))
o.rmempty = false
o.datatype = "host"
o.default = "eu1.cloud.thethings.network"

o = s:option(Value, "serv_port_up", translate("Uplink Port (UDP)"), translate("Standard UDP port for Semtech packet forwarder uplink (default 1700)"))
o.datatype = "port"
o.default = "1700"
o.rmempty = false

o = s:option(Value, "serv_port_down", translate("Downlink Port (UDP)"), translate("Standard UDP port for Semtech packet forwarder downlink (default 1700)"))
o.datatype = "port"
o.default = "1700"
o.rmempty = false

o = s:option(Value, "stat_interval", translate("Stats Push Interval (s)"), translate("Interval in seconds between PUSH_DATA gateway telemetry reports (default 30)"))
o.datatype = "uinteger"
o.default = "30"

-- SECTION 2: Gateway Identification & Hardware
s = m:section(NamedSection, "general", "lora", translate("Gateway Identity & Hardware"))
s.anonymous = false
s.addremove = false

o = s:option(Value, "gateway_id", translate("Gateway EUI"), translate("Unique 16-hex digit EUI-64 identifier registered on your Network Server"))
o.datatype = "rangelength(16,16)"
o.default = "a84041ffff16c21c"
o.rmempty = false

o = s:option(ListValue, "concentrator", translate("Concentrator Model"))
o:value("sx1302", "Dragino LPS8 (SX1302 8-Channel Concentrator)")
o:value("sx1276_lg02", "Dragino LG02 (SX1276 Dual-Channel Transceiver)")
o:value("sx1276_lg01", "Dragino LG01 (SX1276 Single-Channel Transceiver)")
o.default = "sx1302"

o = s:option(ListValue, "interface", translate("Hardware Bus Interface"))
o:value("spi", "SPI (/dev/spidev1.0)")
o:value("usb", "USB (/dev/ttyACM0)")
o.default = "spi"

o = s:option(Value, "reset_gpio", translate("Reset GPIO Pin"), translate("GPIO pin wired to concentrator RESET line (LPS8=23, LG02=23/8)"))
o.datatype = "uinteger"
o.default = "23"

-- SECTION 3: Radio & Frequency Plan
s = m:section(NamedSection, "general", "lora", translate("Radio & Frequency Plan"))
s.anonymous = false
s.addremove = false

o = s:option(ListValue, "region", translate("Frequency Plan / Region"))
o:value("EU868", "Europe 863-870 MHz (EU868)")
o:value("US915", "North America 902-928 MHz (US915)")
o:value("AU915", "Australia 915-928 MHz (AU915)")
o:value("AS923", "Asia 920-925 MHz (AS923)")
o:value("IN865", "India 865-867 MHz (IN865)")
o:value("RU864", "Russia 864-870 MHz (RU864)")
o:value("KR920", "Korea 920-923 MHz (KR920)")
o.default = "EU868"

o = s:option(Value, "tx_power", translate("TX Power (dBm)"), translate("Maximum RF transmission power (0 to 27 dBm)"))
o.datatype = "range(0,27)"
o.default = "26"

o = s:option(ListValue, "syncword", translate("LoRa Sync Word"))
o:value("0x34", "0x34 — Public LoRaWAN (The Things Network, Helium, Senet)")
o:value("0x12", "0x12 — Private LoRa Network")
o.default = "0x34"

function m.on_after_commit(self)
    luci.sys.call("/usr/bin/lora_sync_config.sh >/dev/null 2>&1 &")
end

return m
