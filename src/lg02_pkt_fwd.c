/* lg02_pkt_fwd.c  —  SX1276 dual-radio UDP packet forwarder for LG01/LG02
 *
 * Mirrors raw_lora_app.c (SX1302 version) in structure and wire format but
 * drives two independent SX1276 modules via radio.h:
 *   RX radio  →  /dev/spidev1.0  (Radio1)
 *   TX radio  →  /dev/spidev1.1  (Radio2)
 *
 * Upstream:   JSON  {"rxpk":[{...}]}     → port_up   (one datagram per packet)
 * Downstream: JSON  {imme,freq,datr,...} ← port_down (bound locally)
 * Heartbeat:  binary struct              → port_up   every heartbeat_interval_s
 * Status:     JSON over TCP              on status_port  (0 = disabled)
 *
 * Config:  /etc/lora/config.json   (see config.json.lg02.example)
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <time.h>
#include <sys/time.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <pthread.h>

#include "radio.h"
#include "parson.h"
#include "base64.h"

/* ------------------------------------------------------------------ */
/* Constants                                                           */
/* ------------------------------------------------------------------ */

#define CONFIG_PATH    "/etc/lora/config.json"
#define TX_QUEUE_SIZE  32
#define KEEPALIVE_REC  43200   /* seconds between forced RX-mode resets */

/* ------------------------------------------------------------------ */
/* Runtime configuration                                               */
/* ------------------------------------------------------------------ */

typedef struct {
    /* Network */
    char     target_ip[64];
    uint16_t port_up;
    uint16_t port_down;
    uint16_t status_port;          /* TCP status server port (0 = disabled) */
    int      heartbeat_interval_s;
    char     gateway_id[20];       /* 16-char hex EUI, e.g. "a84041ffff16c21c" */
    /* RX radio  (spidev1.0) */
    uint32_t rx_freq;
    uint8_t  rx_sf;
    uint32_t rx_bw;       /* kHz: 125, 250, 500 */
    uint8_t  rx_cr;       /* 5, 6, 7, 8  → 4/5 … 4/8 */
    uint8_t  rx_prlen;
    uint8_t  rx_syncword;
    /* TX radio  (spidev2.0) */
    uint32_t tx_freq;
    uint8_t  tx_sf;
    uint32_t tx_bw;       /* kHz */
    uint8_t  tx_cr;
    uint8_t  tx_prlen;
    uint8_t  tx_syncword;
    uint8_t  tx_power;    /* dBm (5–20) */
    bool     tx_invert;
    /* LEDs (OpenWrt sysfs name, e.g. "dragino2:red:status", or "" to disable) */
    char     led_rx[64];
    char     led_tx[64];
} app_config_t;

static app_config_t g_cfg;

/* Required by radio.c (declared extern in radio.h) */
int DEBUG_PKT_FWD  = 0;
int DEBUG_JIT      = 0;
int DEBUG_JIT_ERROR= 0;
int DEBUG_TIMERSYNC= 0;
int DEBUG_BEACON   = 0;
int DEBUG_INFO     = 0;
int DEBUG_WARNING  = 0;
int DEBUG_ERROR    = 0;
int DEBUG_GPS      = 0;
int DEBUG_SPI      = 0;
int DEBUG_UCI      = 0;

/* ------------------------------------------------------------------ */
/* Config loading                                                      */
/* ------------------------------------------------------------------ */

static void load_config(const char *path)
{
    /* Built-in defaults */
    strncpy(g_cfg.target_ip,  "192.168.1.8", sizeof(g_cfg.target_ip)  - 1);
    g_cfg.port_up              = 5555;
    g_cfg.port_down            = 5556;
    g_cfg.status_port          = 5557;
    g_cfg.heartbeat_interval_s = 10;
    strncpy(g_cfg.gateway_id, "a84041ffff16c21c", sizeof(g_cfg.gateway_id) - 1);
    g_cfg.rx_freq     = 902320000;
    g_cfg.rx_sf       = 7;
    g_cfg.rx_bw       = 125;
    g_cfg.rx_cr       = 5;
    g_cfg.rx_prlen    = 8;
    g_cfg.rx_syncword = 52;    /* 0x34 LoRaWAN public */
    g_cfg.tx_freq     = 923300000;
    g_cfg.tx_sf       = 9;
    g_cfg.tx_bw       = 125;
    g_cfg.tx_cr       = 5;
    g_cfg.tx_prlen    = 8;
    g_cfg.tx_syncword = 52;
    g_cfg.tx_power    = 16;
    g_cfg.tx_invert   = false;
    g_cfg.led_rx[0]   = '\0';
    g_cfg.led_tx[0]   = '\0';

    JSON_Value *root = json_parse_file(path);
    if (!root) {
        printf("[CFG] '%s' not found — using built-in defaults.\n", path);
        return;
    }
    JSON_Object *obj = json_value_get_object(root);
    const char  *str;
    JSON_Value  *val;

#define CFG_STR(key, dst) \
    if ((str = json_object_get_string(obj, key))) \
        strncpy(dst, str, sizeof(dst) - 1);
#define CFG_U32(key, dst) \
    if ((val = json_object_get_value(obj, key)) && json_value_get_type(val) == JSONNumber) \
        dst = (uint32_t)json_value_get_number(val);
#define CFG_U16(key, dst) \
    if ((val = json_object_get_value(obj, key)) && json_value_get_type(val) == JSONNumber) \
        dst = (uint16_t)json_value_get_number(val);
#define CFG_U8(key, dst) \
    if ((val = json_object_get_value(obj, key)) && json_value_get_type(val) == JSONNumber) \
        dst = (uint8_t)json_value_get_number(val);
#define CFG_INT(key, dst) \
    if ((val = json_object_get_value(obj, key)) && json_value_get_type(val) == JSONNumber) \
        dst = (int)json_value_get_number(val);
#define CFG_BOOL(key, dst) \
    if ((val = json_object_get_value(obj, key)) && json_value_get_type(val) == JSONBoolean) \
        dst = (json_value_get_boolean(val) != 0);

    CFG_STR ("target_ip",            g_cfg.target_ip)
    CFG_U16 ("port_up",              g_cfg.port_up)
    CFG_U16 ("port_down",            g_cfg.port_down)
    CFG_U16 ("status_port",          g_cfg.status_port)
    CFG_INT ("heartbeat_interval_s", g_cfg.heartbeat_interval_s)
    CFG_STR ("gateway_id",           g_cfg.gateway_id)
    CFG_U32 ("rx_freq",              g_cfg.rx_freq)
    CFG_U8  ("rx_sf",                g_cfg.rx_sf)
    CFG_U32 ("rx_bw",                g_cfg.rx_bw)
    CFG_U8  ("rx_cr",                g_cfg.rx_cr)
    CFG_U8  ("rx_prlen",             g_cfg.rx_prlen)
    CFG_U8  ("rx_syncword",          g_cfg.rx_syncword)
    CFG_U32 ("tx_freq",              g_cfg.tx_freq)
    CFG_U8  ("tx_sf",                g_cfg.tx_sf)
    CFG_U32 ("tx_bw",                g_cfg.tx_bw)
    CFG_U8  ("tx_cr",                g_cfg.tx_cr)
    CFG_U8  ("tx_prlen",             g_cfg.tx_prlen)
    CFG_U8  ("tx_syncword",          g_cfg.tx_syncword)
    CFG_U8  ("tx_power",             g_cfg.tx_power)
    CFG_BOOL("tx_invert",            g_cfg.tx_invert)
    CFG_STR ("led_rx",               g_cfg.led_rx)
    CFG_STR ("led_tx",               g_cfg.led_tx)

#undef CFG_STR
#undef CFG_U32
#undef CFG_U16
#undef CFG_U8
#undef CFG_INT
#undef CFG_BOOL

    json_value_free(root);

    printf("[CFG] Loaded '%s'\n"
           "      target=%s  up=%u  down=%u  status=%u  hb=%ds  gw=%s\n"
           "      rx: %.3fMHz SF%u BW%ukHz CR4/%u prlen=%u sync=0x%02x\n"
           "      tx: %.3fMHz SF%u BW%ukHz CR4/%u prlen=%u sync=0x%02x pwr=%udBm invert=%s\n",
           path,
           g_cfg.target_ip, g_cfg.port_up, g_cfg.port_down,
           g_cfg.status_port, g_cfg.heartbeat_interval_s, g_cfg.gateway_id,
           g_cfg.rx_freq / 1e6, g_cfg.rx_sf, g_cfg.rx_bw, g_cfg.rx_cr,
           g_cfg.rx_prlen, g_cfg.rx_syncword,
           g_cfg.tx_freq / 1e6, g_cfg.tx_sf, g_cfg.tx_bw, g_cfg.tx_cr,
           g_cfg.tx_prlen, g_cfg.tx_syncword, g_cfg.tx_power,
           g_cfg.tx_invert ? "yes" : "no");
}

/* ------------------------------------------------------------------ */
/* Binary protocol packets (same structs as raw_lora_app.c)           */
/* ------------------------------------------------------------------ */

#define PKT_TYPE_HEARTBEAT  0x02
#define PKT_TYPE_BOOT       0x03

struct __attribute__((packed)) heartbeat_pkt {
    uint8_t  pkt_type;
    uint64_t gateway_eui;
    uint32_t uptime_s;
    uint32_t rx_count;
    uint32_t tx_count;
    uint32_t crc_err_count;
    uint32_t tx_err_count;
    uint32_t tx_queue_drop;
    uint8_t  tx_queue_depth;
    uint8_t  sync_word;
    uint32_t rf0_freq;     /* rx_freq */
    uint32_t rf1_freq;     /* tx_freq */
};

struct __attribute__((packed)) boot_pkt {
    uint8_t  pkt_type;
    uint64_t gateway_eui;
    char     hal_version[32];
};

/* ------------------------------------------------------------------ */
/* TX queue                                                            */
/* ------------------------------------------------------------------ */

typedef struct {
    struct pkt_tx_s entries[TX_QUEUE_SIZE];
    int             head;
    int             count;
    pthread_mutex_t mutex;
    pthread_cond_t  not_empty;
} tx_queue_t;

static tx_queue_t txq;

static volatile sig_atomic_t g_quit        = 0;
static volatile sig_atomic_t g_quit_signal = 0;

static void txq_init(tx_queue_t *q)
{
    memset(q, 0, sizeof(*q));
    pthread_mutex_init(&q->mutex, NULL);
    pthread_cond_init(&q->not_empty, NULL);
}

static bool txq_push(tx_queue_t *q, const struct pkt_tx_s *pkt)
{
    pthread_mutex_lock(&q->mutex);
    if (q->count >= TX_QUEUE_SIZE) {
        pthread_mutex_unlock(&q->mutex);
        return false;
    }
    int tail = (q->head + q->count) % TX_QUEUE_SIZE;
    q->entries[tail] = *pkt;
    q->count++;
    pthread_cond_signal(&q->not_empty);
    pthread_mutex_unlock(&q->mutex);
    return true;
}

static bool txq_pop(tx_queue_t *q, struct pkt_tx_s *pkt)
{
    pthread_mutex_lock(&q->mutex);
    while (q->count == 0) {
        if (g_quit) {
            pthread_mutex_unlock(&q->mutex);
            return false;
        }
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        ts.tv_sec += 1;
        pthread_cond_timedwait(&q->not_empty, &q->mutex, &ts);
    }
    *pkt = q->entries[q->head];
    q->head = (q->head + 1) % TX_QUEUE_SIZE;
    q->count--;
    pthread_mutex_unlock(&q->mutex);
    return true;
}

static int txq_count(tx_queue_t *q)
{
    pthread_mutex_lock(&q->mutex);
    int c = q->count;
    pthread_mutex_unlock(&q->mutex);
    return c;
}

/* ------------------------------------------------------------------ */
/* Globals                                                             */
/* ------------------------------------------------------------------ */

static int              sock_up, sock_down;
static struct sockaddr_in dest_addr;
static uint64_t         g_gateway_eui = 0;
static time_t           g_start_time;

static radiodev        *rxdev;
static radiodev        *txdev;

static pthread_mutex_t  stats_mutex     = PTHREAD_MUTEX_INITIALIZER;
static uint32_t         stat_rx_count   = 0;
static uint32_t         stat_tx_count   = 0;
static uint32_t         stat_tx_err     = 0;
static uint32_t         stat_tx_qdrop   = 0;

static volatile int     g_led_rx_blink  = 0;
static volatile int     g_led_tx_blink  = 0;

/* ------------------------------------------------------------------ */
/* Helpers                                                             */
/* ------------------------------------------------------------------ */

static uint32_t sf_to_dr(int sf)
{
    switch (sf) {
        case 8:  return DR_LORA_SF8;
        case 9:  return DR_LORA_SF9;
        case 10: return DR_LORA_SF10;
        case 11: return DR_LORA_SF11;
        case 12: return DR_LORA_SF12;
        default: return DR_LORA_SF7;
    }
}

static uint8_t bw_khz_to_enum(uint32_t bw_khz)
{
    if (bw_khz == 500) return BW_500KHZ;
    if (bw_khz == 250) return BW_250KHZ;
    return BW_125KHZ;
}

static uint8_t str_to_cr(const char *s)
{
    if (!s)                                          return CR_LORA_4_5;
    if (strcmp(s, "4/6") == 0 || strcmp(s, "2/3") == 0) return CR_LORA_4_6;
    if (strcmp(s, "4/7") == 0)                      return CR_LORA_4_7;
    if (strcmp(s, "4/8") == 0 || strcmp(s, "1/2") == 0) return CR_LORA_4_8;
    return CR_LORA_4_5;
}

/* cr integer (5-8) → "4/5" string for JSON */
static const char *cr_to_str(uint8_t cr)
{
    switch (cr) {
        case 6: return "4/6";
        case 7: return "4/7";
        case 8: return "4/8";
        default: return "4/5";
    }
}

/* cr integer (5-8) → CR_LORA_4_x enum */
static uint8_t cr_int_to_enum(uint8_t cr)
{
    switch (cr) {
        case 6: return CR_LORA_4_6;
        case 7: return CR_LORA_4_7;
        case 8: return CR_LORA_4_8;
        default: return CR_LORA_4_5;
    }
}

/* ------------------------------------------------------------------ */
/* LED helpers (same as raw_lora_app.c)                               */
/* ------------------------------------------------------------------ */

static void led_claim(const char *name)
{
    if (!name || !name[0]) return;
    char path[128];
    snprintf(path, sizeof(path), "/sys/class/leds/%s/trigger", name);
    int fd = open(path, O_WRONLY);
    if (fd < 0) return;
    write(fd, "none", 4);
    close(fd);
}

static int led_set(const char *name, int on)
{
    if (!name || !name[0]) return 0;
    char path[128];
    snprintf(path, sizeof(path), "/sys/class/leds/%s/brightness", name);
    int fd = open(path, O_WRONLY);
    if (fd < 0) return 0;
    write(fd, on ? "255" : "0", on ? 3 : 1);
    close(fd);
    return 1;
}

/* ------------------------------------------------------------------ */
/* Signal handler                                                      */
/* ------------------------------------------------------------------ */

static void sig_handler(int signo)
{
    g_quit_signal = signo;
    g_quit = 1;
}

/* ------------------------------------------------------------------ */
/* Thread: RX loop                                                     */
/* ------------------------------------------------------------------ */

static void *thread_rx_loop(void *arg)
{
    (void)arg;
    struct pkt_rx_s pktrx;
    char json_buf[1280];
    char b64[400];
    char datr_str[16];
    time_t last_reset = time(NULL);

    printf("[RX] Thread started.\n");
    rxlora(rxdev, RXMODE_SCAN);
    printf("[RX] Listening  SF%u BW%ukHz  %.3fMHz  sync=0x%02x\n",
           rxdev->sf, rxdev->bw / 1000, rxdev->freq / 1e6, rxdev->syncword);

    snprintf(datr_str, sizeof(datr_str), "SF%uBW%u", rxdev->sf, rxdev->bw / 1000);

    while (!g_quit) {
        /* Periodically reset RX mode in case the radio got stuck */
        if ((long)(time(NULL) - last_reset) > KEEPALIVE_REC) {
            last_reset = time(NULL);
            rxlora(rxdev, RXMODE_SCAN);
        }

        if (digitalRead(rxdev->dio[0]) != 1) {
            wait_ms(10);
            continue;
        }

        memset(&pktrx, 0, sizeof(pktrx));
        if (!received(rxdev->spiport, &pktrx))
            continue;

        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        char time_str[28];
        strftime(time_str, sizeof(time_str), "%Y-%m-%dT%H:%M:%S", gmtime(&ts.tv_sec));

        struct timeval now;
        gettimeofday(&now, NULL);
        uint32_t tmst = (uint32_t)(now.tv_sec * 1000000 + now.tv_usec);

        bin_to_b64(pktrx.payload, (int)pktrx.size, b64, (int)sizeof(b64));

        int json_len = snprintf(json_buf, sizeof(json_buf),
            "{\"rxpk\":[{"
            "\"tmst\":%u,"
            "\"time\":\"%s.%06ldZ\","
            "\"chan\":0,"
            "\"rfch\":0,"
            "\"freq\":%.6f,"
            "\"mid\":0,"
            "\"stat\":1,"
            "\"modu\":\"LORA\","
            "\"datr\":\"%s\","
            "\"codr\":\"%s\","
            "\"rssis\":%.1f,"
            "\"lsnr\":%.1f,"
            "\"foff\":0,"
            "\"rssi\":%.1f,"
            "\"size\":%u,"
            "\"data\":\"%s\""
            "}]}",
            tmst, time_str, (long)(ts.tv_nsec / 1000),
            rxdev->freq / 1e6,
            datr_str, cr_to_str(rxdev->cr),
            pktrx.rssi, pktrx.snr, pktrx.rssi,
            (unsigned)pktrx.size, b64);

        sendto(sock_up, json_buf, json_len, 0,
               (const struct sockaddr *)&dest_addr, sizeof(dest_addr));

        pthread_mutex_lock(&stats_mutex);
        stat_rx_count++;
        pthread_mutex_unlock(&stats_mutex);
        g_led_rx_blink = 1;

        printf("[RX] %u bytes  %s  %.4fMHz  RSSI %.1fdBm  SNR %.1fdB\n",
               pktrx.size, datr_str, rxdev->freq / 1e6, pktrx.rssi, pktrx.snr);
    }

    printf("[RX] Thread exiting.\n");
    return NULL;
}

/* ------------------------------------------------------------------ */
/* Thread: receive TX commands from server (JSON UDP on port_down)    */
/* ------------------------------------------------------------------ */

static void *thread_tx_recv(void *arg)
{
    (void)arg;
    char buf[2048];
    struct sockaddr_in src_addr;
    socklen_t src_len = sizeof(src_addr);
    struct pkt_tx_s txpkt;

    struct timeval tv = {1, 0};
    setsockopt(sock_down, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    printf("[TX-RECV] Thread started.\n");

    while (!g_quit) {
        int n = recvfrom(sock_down, buf, sizeof(buf) - 1, 0,
                         (struct sockaddr *)&src_addr, &src_len);
        if (n <= 0)
            continue;

        buf[n] = '\0';

        JSON_Value *root_val = json_parse_string((const char *)buf);
        if (!root_val) {
            printf("[TX-RECV] Ignored non-JSON packet.\n");
            continue;
        }
        JSON_Object *obj = json_value_get_object(root_val);
        if (!obj) {
            json_value_free(root_val);
            continue;
        }

        memset(&txpkt, 0, sizeof(txpkt));
        JSON_Value *val;

        /* TX mode */
        bool imme = true;
        if ((val = json_object_get_value(obj, "imme")) && json_value_get_type(val) == JSONBoolean)
            imme = (json_value_get_boolean(val) != 0);
        txpkt.tx_mode = imme ? IMMEDIATE : TIMESTAMPED;

        /* Frequency (MHz in JSON → Hz in struct) */
        if ((val = json_object_get_value(obj, "freq")) && json_value_get_type(val) == JSONNumber)
            txpkt.freq_hz = (uint32_t)(json_value_get_number(val) * 1e6 + 0.5);
        else
            txpkt.freq_hz = g_cfg.tx_freq;

        /* TX power */
        if ((val = json_object_get_value(obj, "powe")) && json_value_get_type(val) == JSONNumber)
            txpkt.rf_power = (uint8_t)json_value_get_number(val);
        else
            txpkt.rf_power = g_cfg.tx_power;

        /* Datarate / bandwidth from "datr" string "SF7BW125" */
        const char *datr = json_object_get_string(obj, "datr");
        if (datr) {
            unsigned sf_v = g_cfg.tx_sf, bw_v = (unsigned)g_cfg.tx_bw;
            sscanf(datr, "SF%uBW%u", &sf_v, &bw_v);
            txpkt.datarate  = sf_to_dr((int)sf_v);
            txpkt.bandwidth = bw_khz_to_enum(bw_v);
        } else {
            txpkt.datarate  = sf_to_dr(g_cfg.tx_sf);
            txpkt.bandwidth = bw_khz_to_enum(g_cfg.tx_bw);
        }

        /* Coding rate */
        const char *codr = json_object_get_string(obj, "codr");
        txpkt.coderate = codr ? str_to_cr(codr) : cr_int_to_enum(g_cfg.tx_cr);

        /* Polarity inversion */
        if ((val = json_object_get_value(obj, "ipol")) && json_value_get_type(val) == JSONBoolean)
            txpkt.invert_pol = (json_value_get_boolean(val) != 0);
        else
            txpkt.invert_pol = g_cfg.tx_invert;

        /* No-CRC flag */
        if ((val = json_object_get_value(obj, "ncrc")) && json_value_get_type(val) == JSONBoolean)
            txpkt.no_crc = (json_value_get_boolean(val) != 0);

        txpkt.preamble  = 8;
        txpkt.no_header = false;

        /* Payload (base64) */
        const char *b64_data = json_object_get_string(obj, "data");
        if (!b64_data) {
            printf("[TX-RECV] Missing 'data' field — discarded.\n");
            json_value_free(root_val);
            continue;
        }
        int decoded = b64_to_bin(b64_data, strlen(b64_data),
                                 txpkt.payload, sizeof(txpkt.payload));
        if (decoded < 0) {
            printf("[TX-RECV] Base64 decode failed — discarded.\n");
            json_value_free(root_val);
            continue;
        }
        txpkt.size = (uint16_t)decoded;
        json_value_free(root_val);

        if (!txq_push(&txq, &txpkt)) {
            printf("[TX-RECV] Queue full (%d slots) — packet discarded.\n", TX_QUEUE_SIZE);
            pthread_mutex_lock(&stats_mutex);
            stat_tx_qdrop++;
            pthread_mutex_unlock(&stats_mutex);
        } else {
            printf("[TX-RECV] Queued %u bytes  %.3fMHz  (depth %d)\n",
                   txpkt.size, txpkt.freq_hz / 1e6, txq_count(&txq));
        }
    }

    printf("[TX-RECV] Thread exiting.\n");
    return NULL;
}

/* ------------------------------------------------------------------ */
/* Thread: transmit queued packets via SX1276 TX radio                */
/* ------------------------------------------------------------------ */

static void *thread_tx_dispatch(void *arg)
{
    (void)arg;
    struct pkt_tx_s txpkt;

    printf("[TX-DISPATCH] Thread started.\n");

    while (txq_pop(&txq, &txpkt)) {
        /* Reflect per-packet frequency/power back into radiodev so
           txlora() picks up the correct hardware settings.             */
        txdev->freq  = txpkt.freq_hz;
        txdev->power = txpkt.rf_power;
        /* Decode SF bitmask → integer for radiodev.sf */
        int sf_int = (txpkt.datarate == DR_LORA_SF8)  ?  8 :
                     (txpkt.datarate == DR_LORA_SF9)  ?  9 :
                     (txpkt.datarate == DR_LORA_SF10) ? 10 :
                     (txpkt.datarate == DR_LORA_SF11) ? 11 :
                     (txpkt.datarate == DR_LORA_SF12) ? 12 : 7;
        txdev->sf       = (uint8_t)sf_int;
        txdev->bw       = (txpkt.bandwidth == BW_500KHZ) ? 500000 :
                          (txpkt.bandwidth == BW_250KHZ) ? 250000 : 125000;
        txdev->cr       = txpkt.coderate;
        txdev->invertio = (uint8_t)txpkt.invert_pol;

        txlora(txdev, &txpkt);

        pthread_mutex_lock(&stats_mutex);
        stat_tx_count++;
        pthread_mutex_unlock(&stats_mutex);
        g_led_tx_blink = 1;

        printf("[TX-DISPATCH] Sent %u bytes  SF%d  %.3fMHz  %udBm\n",
               txpkt.size, sf_int, txpkt.freq_hz / 1e6, (unsigned)txpkt.rf_power);

        /* Restore default TX radio configuration */
        txdev->freq     = g_cfg.tx_freq;
        txdev->sf       = g_cfg.tx_sf;
        txdev->bw       = (uint32_t)g_cfg.tx_bw * 1000;
        txdev->cr       = g_cfg.tx_cr;
        txdev->power    = g_cfg.tx_power;
        txdev->invertio = (uint8_t)g_cfg.tx_invert;
    }

    printf("[TX-DISPATCH] Thread exiting.\n");
    return NULL;
}

/* ------------------------------------------------------------------ */
/* Thread: heartbeat (same binary format as raw_lora_app.c)           */
/* ------------------------------------------------------------------ */

static void *thread_heartbeat(void *arg)
{
    (void)arg;
    printf("[HB] Thread started. Interval: %d s.\n", g_cfg.heartbeat_interval_s);

    while (!g_quit) {
        for (int s = 0; s < g_cfg.heartbeat_interval_s && !g_quit; s++)
            sleep(1);
        if (g_quit) break;

        struct heartbeat_pkt hb;
        hb.pkt_type   = PKT_TYPE_HEARTBEAT;
        hb.gateway_eui = g_gateway_eui;
        hb.uptime_s   = (uint32_t)(time(NULL) - g_start_time);

        pthread_mutex_lock(&stats_mutex);
        hb.rx_count      = stat_rx_count;
        hb.tx_count      = stat_tx_count;
        hb.crc_err_count = 0;
        hb.tx_err_count  = stat_tx_err;
        hb.tx_queue_drop = stat_tx_qdrop;
        pthread_mutex_unlock(&stats_mutex);

        hb.tx_queue_depth = (uint8_t)txq_count(&txq);
        hb.sync_word      = rxdev->syncword;
        hb.rf0_freq       = rxdev->freq;
        hb.rf1_freq       = txdev->freq;

        sendto(sock_up, &hb, sizeof(hb), 0,
               (const struct sockaddr *)&dest_addr, sizeof(dest_addr));

        printf("[HB] uptime=%us rx=%u tx=%u tx_err=%u q=%u q_drop=%u\n",
               hb.uptime_s, hb.rx_count, hb.tx_count,
               hb.tx_err_count, hb.tx_queue_depth, hb.tx_queue_drop);
    }

    printf("[HB] Thread exiting.\n");
    return NULL;
}

/* ------------------------------------------------------------------ */
/* Thread: LED activity indicators                                     */
/* ------------------------------------------------------------------ */

static void *thread_led(void *arg)
{
    (void)arg;
    while (!g_quit) {
        if (g_led_rx_blink) {
            g_led_rx_blink = 0;
            if (led_set(g_cfg.led_rx, 1)) {
                usleep(80000);
                led_set(g_cfg.led_rx, 0);
            }
        }
        if (g_led_tx_blink) {
            g_led_tx_blink = 0;
            if (led_set(g_cfg.led_tx, 1)) {
                usleep(200000);
                led_set(g_cfg.led_tx, 0);
            }
        }
        usleep(10000);
    }
    led_set(g_cfg.led_rx, 0);
    led_set(g_cfg.led_tx, 0);
    return NULL;
}

/* ------------------------------------------------------------------ */
/* Thread: optional TCP status server on status_port                  */
/* ------------------------------------------------------------------ */

static void *thread_status_server(void *arg)
{
    (void)arg;
    if (!g_cfg.status_port) return NULL;

    int srv_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (srv_fd < 0) { printf("[STATUS] socket() failed.\n"); return NULL; }

    int opt = 1;
    setsockopt(srv_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family      = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port        = htons(g_cfg.status_port);

    if (bind(srv_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0 ||
        listen(srv_fd, 4) < 0) {
        printf("[STATUS] bind/listen failed.\n");
        close(srv_fd);
        return NULL;
    }
    printf("[STATUS] TCP status server on port %u.\n", g_cfg.status_port);

    while (!g_quit) {
        fd_set rfds;
        struct timeval tv = {1, 0};
        FD_ZERO(&rfds);
        FD_SET(srv_fd, &rfds);
        if (select(srv_fd + 1, &rfds, NULL, NULL, &tv) <= 0)
            continue;

        struct sockaddr_in cli;
        socklen_t cli_len = sizeof(cli);
        int cli_fd = accept(srv_fd, (struct sockaddr *)&cli, &cli_len);
        if (cli_fd < 0) continue;

        pthread_mutex_lock(&stats_mutex);
        uint32_t rx    = stat_rx_count;
        uint32_t tx    = stat_tx_count;
        uint32_t txerr = stat_tx_err;
        uint32_t qdrop = stat_tx_qdrop;
        pthread_mutex_unlock(&stats_mutex);

        char buf[512];
        int n = snprintf(buf, sizeof(buf),
            "{\"eui\":\"%016llX\","
            "\"uptime_s\":%u,"
            "\"rx\":%u,\"tx\":%u,"
            "\"tx_err\":%u,"
            "\"q_depth\":%u,\"q_drop\":%u,"
            "\"rx_mhz\":%.6f,\"tx_mhz\":%.6f}\n",
            (unsigned long long)g_gateway_eui,
            (uint32_t)(time(NULL) - g_start_time),
            rx, tx, txerr,
            (uint32_t)txq_count(&txq), qdrop,
            rxdev->freq / 1e6, txdev->freq / 1e6);
        write(cli_fd, buf, n);
        close(cli_fd);
    }

    close(srv_fd);
    printf("[STATUS] Thread exiting.\n");
    return NULL;
}

/* ------------------------------------------------------------------ */
/* main                                                                */
/* ------------------------------------------------------------------ */

int main(void)
{
    struct sockaddr_in local_addr;
    pthread_t rx_tid, tx_recv_tid, tx_dispatch_tid, hb_tid, led_tid, status_tid;

    signal(SIGINT,  sig_handler);
    signal(SIGTERM, sig_handler);

    if (already_running()) {
        printf("ERROR: already running!\n");
        return EXIT_FAILURE;
    }

    g_start_time = time(NULL);
    txq_init(&txq);

    load_config(CONFIG_PATH);

    /* Parse gateway EUI from hex string */
    unsigned long long ull = 0;
    sscanf(g_cfg.gateway_id, "%llx", &ull);
    g_gateway_eui = (uint64_t)ull;

    /* ---- Allocate and configure RX radio (spidev1.0) ---- */
    rxdev = (radiodev *)malloc(sizeof(radiodev));
    if (!rxdev) { perror("malloc rxdev"); return EXIT_FAILURE; }
    memset(rxdev, 0, sizeof(radiodev));
    rxdev->nss      = 15;
    rxdev->rst      = 8;
    rxdev->dio[0]   = 7;
    rxdev->dio[1]   = 6;
    rxdev->dio[2]   = 0;
    {
        int fd = lgw_spi_open(SPI_DEV_RX);
        if (fd < 0) {
            printf("ERROR: failed to open %s\n", SPI_DEV_RX);
            goto clean;
        }
        rxdev->spiport = (uint8_t)fd;
    }
    rxdev->freq     = g_cfg.rx_freq;
    rxdev->sf       = g_cfg.rx_sf;
    rxdev->bw       = (uint32_t)g_cfg.rx_bw * 1000;
    rxdev->cr       = g_cfg.rx_cr;
    rxdev->nocrc    = 0;
    rxdev->prlen    = g_cfg.rx_prlen;
    rxdev->syncword = g_cfg.rx_syncword;
    rxdev->invertio = 0;
    rxdev->power    = 0;
    strncpy(rxdev->desc, "Radio1", sizeof(rxdev->desc) - 1);

    /* ---- Allocate and configure TX radio (spidev2.0) ---- */
    txdev = (radiodev *)malloc(sizeof(radiodev));
    if (!txdev) { perror("malloc txdev"); goto clean; }
    memset(txdev, 0, sizeof(radiodev));
    txdev->nss      = 24;
    txdev->rst      = 23;
    txdev->dio[0]   = 22;
    txdev->dio[1]   = 20;
    txdev->dio[2]   = 0;
    {
        int fd = lgw_spi_open(SPI_DEV_TX);
        if (fd < 0) {
            printf("ERROR: failed to open %s\n", SPI_DEV_TX);
            goto clean;
        }
        txdev->spiport = (uint8_t)fd;
    }
    txdev->freq     = g_cfg.tx_freq;
    txdev->sf       = g_cfg.tx_sf;
    txdev->bw       = (uint32_t)g_cfg.tx_bw * 1000;
    txdev->cr       = g_cfg.tx_cr;
    txdev->nocrc    = 0;
    txdev->prlen    = g_cfg.tx_prlen;
    txdev->syncword = g_cfg.tx_syncword;
    txdev->invertio = (uint8_t)g_cfg.tx_invert;
    txdev->power    = g_cfg.tx_power;
    strncpy(txdev->desc, "Radio2", sizeof(txdev->desc) - 1);

    printf("PIN DUMP RX : spiport=%d  nss=%d  rst=%d  dio0=%d  dio1=%d\n",
           rxdev->spiport, rxdev->nss, rxdev->rst, rxdev->dio[0], rxdev->dio[1]);
    printf("PIN DUMP TX : spiport=%d  nss=%d  rst=%d  dio0=%d  dio1=%d\n",
           txdev->spiport, txdev->nss, txdev->rst, txdev->dio[0], txdev->dio[1]);

    /* ---- Verify RX radio and set up both channels ---- */
    if (!get_radio_version(rxdev)) {
        printf("ERROR: RX radio (SX1276) version check failed.\n");
        goto clean;
    }
    setup_channel(rxdev);
    setup_channel(txdev);

    printf("SX1276 LG02 Forwarder — GW EUI: %016llX\n",
           (unsigned long long)g_gateway_eui);
    printf("RX  %s  spi=%d  %.3fMHz  SF%u  BW%ukHz  0x%02x\n",
           rxdev->desc, rxdev->spiport, rxdev->freq / 1e6,
           rxdev->sf, rxdev->bw / 1000, rxdev->syncword);
    printf("TX  %s  spi=%d  %.3fMHz  SF%u  BW%ukHz  0x%02x  %udBm\n",
           txdev->desc, txdev->spiport, txdev->freq / 1e6,
           txdev->sf, txdev->bw / 1000, txdev->syncword, txdev->power);

    /* ---- Open UDP sockets ---- */
    if ((sock_up = socket(AF_INET, SOCK_DGRAM, 0)) < 0) {
        perror("socket(sock_up)");
        goto clean;
    }
    memset(&dest_addr, 0, sizeof(dest_addr));
    dest_addr.sin_family      = AF_INET;
    dest_addr.sin_port        = htons(g_cfg.port_up);
    dest_addr.sin_addr.s_addr = inet_addr(g_cfg.target_ip);

    if ((sock_down = socket(AF_INET, SOCK_DGRAM, 0)) < 0) {
        perror("socket(sock_down)");
        goto clean;
    }
    memset(&local_addr, 0, sizeof(local_addr));
    local_addr.sin_family      = AF_INET;
    local_addr.sin_port        = htons(g_cfg.port_down);
    local_addr.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(sock_down, (const struct sockaddr *)&local_addr, sizeof(local_addr)) < 0) {
        perror("bind(sock_down)");
        goto clean;
    }

    /* ---- Send boot packet ---- */
    struct boot_pkt boot;
    memset(&boot, 0, sizeof(boot));
    boot.pkt_type    = PKT_TYPE_BOOT;
    boot.gateway_eui = g_gateway_eui;
    strncpy(boot.hal_version, "SX1276 LG02 v1.0", sizeof(boot.hal_version) - 1);
    sendto(sock_up, &boot, sizeof(boot), 0,
           (const struct sockaddr *)&dest_addr, sizeof(dest_addr));

    /* ---- Claim LEDs and launch threads ---- */
    led_claim(g_cfg.led_rx);
    led_claim(g_cfg.led_tx);
    led_set(g_cfg.led_rx, 0);
    led_set(g_cfg.led_tx, 0);

    printf("Launching threads...\n");

    pthread_create(&rx_tid,          NULL, thread_rx_loop,       NULL);
    pthread_create(&tx_recv_tid,     NULL, thread_tx_recv,       NULL);
    pthread_create(&tx_dispatch_tid, NULL, thread_tx_dispatch,   NULL);
    pthread_create(&hb_tid,          NULL, thread_heartbeat,     NULL);
    pthread_create(&led_tid,         NULL, thread_led,           NULL);
    pthread_create(&status_tid,      NULL, thread_status_server, NULL);

    pthread_join(rx_tid,          NULL);
    pthread_join(tx_recv_tid,     NULL);
    pthread_join(tx_dispatch_tid, NULL);
    pthread_join(hb_tid,          NULL);
    pthread_join(led_tid,         NULL);
    pthread_join(status_tid,      NULL);

    printf("Received signal %d — shutting down.\n", (int)g_quit_signal);

clean:
    if (rxdev) { close(rxdev->spiport); free(rxdev); }
    if (txdev) { close(txdev->spiport); free(txdev); }
    if (sock_up   > 0) close(sock_up);
    if (sock_down > 0) close(sock_down);
    printf("Done.\n");
    return EXIT_SUCCESS;
}
