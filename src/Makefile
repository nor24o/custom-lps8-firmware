# SX1276 HAL & Packet Forwarders for LG01 / LG02

CC ?= mips-openwrt-linux-musl-gcc
CFLAGS ?= -O2 -Wall

all: lg01_pkt_fwd lg02_pkt_fwd lg02_single_rx_tx simple_spi_rw

lg01_pkt_fwd: base64.o parson.o radio.o jitqueue.o lg01_pkt_fwd.o
	$(CC) $(LDFLAGS) lg01_pkt_fwd.o base64.o parson.o radio.o jitqueue.o -luci -lubox -lrt -ldl -lpthread -o lg01_pkt_fwd

lg02_pkt_fwd: base64.o parson.o radio.o jitqueue.o lg02_pkt_fwd.o
	$(CC) $(LDFLAGS) lg02_pkt_fwd.o base64.o parson.o radio.o jitqueue.o -luci -lubox -lrt -ldl -lpthread -o lg02_pkt_fwd

lg02_single_rx_tx: radio.o lg02_single_rx_tx.o
	$(CC) $(LDFLAGS) radio.o lg02_single_rx_tx.o -lrt -ldl -lpthread -o lg02_single_rx_tx

simple_spi_rw: radio.o simple_spi_rw.o
	$(CC) $(LDFLAGS) radio.o simple_spi_rw.o -lrt -ldl -lpthread -o simple_spi_rw

spirw: simple_spi_rw
	cp simple_spi_rw spirw

lg01_pkt_fwd.o: lg01_pkt_fwd.c
	$(CC) $(CFLAGS) -fPIC -c lg01_pkt_fwd.c

lg02_pkt_fwd.o: lg02_pkt_fwd.c
	$(CC) $(CFLAGS) -fPIC -c lg02_pkt_fwd.c

lg02_single_rx_tx.o: lg02_single_rx_tx.c
	$(CC) $(CFLAGS) -fPIC -c lg02_single_rx_tx.c

simple_spi_rw.o: simple_spi_rw.c
	$(CC) $(CFLAGS) -fPIC -c simple_spi_rw.c

jitqueue.o: jitqueue.c
	$(CC) $(CFLAGS) -fPIC -c jitqueue.c

base64.o: base64.c
	$(CC) $(CFLAGS) -fPIC -c base64.c

parson.o: parson.c
	$(CC) $(CFLAGS) -fPIC -c parson.c

radio.o: radio.c
	$(CC) $(CFLAGS) -fPIC -c radio.c

clean:
	rm -f *.o lg01_pkt_fwd lg02_pkt_fwd lg02_single_rx_tx simple_spi_rw spirw
