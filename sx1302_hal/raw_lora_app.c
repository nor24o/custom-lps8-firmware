#define _GNU_SOURCE
#define _DEFAULT_SOURCE
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
#include <netdb.h>
#include <errno.h>
#include <pthread.h>
#include "libloragw/inc/loragw_hal.h"
#include "libloragw/inc/loragw_sx1302.h"
#include "libtools/inc/parson.h"
#include "libtools/inc/base64.h"

// --- POLYFILL FOR OPENWRT MUSL LIBC ---
#ifndef __GLIBC__
static void *qsort_arg = NULL;
static int (*qsort_cmp)(const void *, const void *, void *) = NULL;

static int qsort_wrapper(const void *a, const void *b) {
    return qsort_cmp(a, b, qsort_arg);
}

void qsort_r(void *base, size_t nmemb, size_t size,
             int (*compar)(const void *, const void *, void *), void *arg) {
    qsort_arg = arg;
    qsort_cmp = compar;
    qsort(base, nmemb, size, qsort_wrapper);
}
#endif
// --------------------------------------

// === BUILD IDENTITY ===
#define ENGINE_VERSION "2.0"
#define LINK_VERSION   2
#if defined(__mips__)
#define GATEWAY_MODEL  "dragino-lps8"
#else
#define GATEWAY_MODEL  "bobcat-300"
#endif

// === FIXED CONSTANTS (not user-configurable) ===
#define CONFIG_PATH   "/etc/lora/config.json"
#define TX_QUEUE_SIZE  32
// ================================================

// === RUNTIME CONFIGURATION ===
typedef struct {
    // Network
    char     target_ip[64];
    uint16_t port_up;
    uint16_t port_down;
    uint16_t status_port;           // TCP status server port (0 = disabled)
    int      heartbeat_interval_s;
    char     link_key[65];          // shared key with the hub; empty until paired
    // Hardware
    char     spi_path[64];
    char     reset_gpio[8];
    char     pa_gpio[64];           // GPIO for external PA/LNA switch: numeric sysfs GPIO ("17") or LED name ("dragino2:red:wan")
    bool     pa_gpio_active_high;   // true = HIGH enables TX; false (default) = LOW enables TX
    uint8_t  clksrc;
    bool     lorawan_public;
    bool     full_duplex;
    // Radio chain config
    char     rf0_type[16];          // "SX1250", "SX1255", "SX1257"
    char     rf1_type[16];
    bool     rf0_single_input;
    bool     rf1_single_input;
    bool     rf0_tx_enable;
    bool     rf1_tx_enable;
    uint32_t rf0_freq;
    float    rf0_rssi_offset;
    uint32_t rf1_freq;
    float    rf1_rssi_offset;
    // Channel plan (8 multiSF channels)
    int32_t  chan_if[8];            // IF offsets in Hz relative to radio center freq
    uint8_t  chan_radio[8];         // radio index (0 or 1) per channel
    // LoRa std channel (channel index 8)
    bool     chan_lora_std_enable;
    uint8_t  chan_lora_std_radio;
    int32_t  chan_lora_std_if;
    int      chan_lora_std_bw;      // bandwidth in kHz (125 / 250 / 500)
    uint8_t  chan_lora_std_sf;      // spreading factor (5-12)
    // FSK channel (channel index 9)
    bool     chan_fsk_enable;
    uint8_t  chan_fsk_radio;
    int32_t  chan_fsk_if;
    int      chan_fsk_bw;           // bandwidth in kHz
    uint32_t chan_fsk_datarate;     // data rate in bps
    // TX
    struct lgw_tx_gain_lut_s tx_gain_lut;
    uint32_t tx_default_freq;
    uint8_t  tx_default_sf;
    int8_t   tx_default_power;
    uint8_t  tx_default_rfch;
    char     tx_default_coderate[8]; // "4/5", "4/6", "4/7", "4/8"
    int      tx_default_bandwidth;   // 125, 250, or 500 kHz
    uint8_t  tx_default_preamble;
    bool     tx_default_invert;
    int      tx_free_timeout_ms;
    // LEDs
    char     led_rx[64];
    char     led_tx[64];
    // Optional HAL Features
    uint8_t  sf_mask;                     // multi-SF demodulator bitmask (0x01=SF5..0x80=SF12, default 0xFF)
    bool     mcu_health_check;            // periodic sx1302_update() health check (default true)
    bool     temp_monitor_enable;         // periodic lgw_get_temperature() telemetry (default true)
    bool     ext_rx_metadata;             // extended RX metadata (snr_min/max, crc, ftime) (default true)
    bool     ftime_enable;                // fine timestamping enable (SX1303 only, default false)
    bool     chan_lora_std_implicit_hdr;  // implicit header mode on LoRa std channel 8 (default false)
    uint8_t  chan_lora_std_implicit_len;  // implicit payload length on channel 8 (default 0)
    bool     chan_lora_std_implicit_crc;  // implicit CRC enable on channel 8 (default false)
    char     chan_lora_std_implicit_cr[8];// implicit coderate on channel 8 ("4/5".."4/8")
    uint8_t  chan_fsk_sync_size;          // FSK sync word size in bytes (1..8, default 3)
    uint64_t chan_fsk_sync_word;          // FSK sync word (default 0xC194C1)
} app_config_t;

static app_config_t g_cfg;

// === HELPER CONVERSIONS ===

static lgw_radio_type_t str_to_radio_type(const char *s) {
    if (s && strcmp(s, "SX1255") == 0) return LGW_RADIO_TYPE_SX1255;
    if (s && strcmp(s, "SX1257") == 0) return LGW_RADIO_TYPE_SX1257;
    return LGW_RADIO_TYPE_SX1250;
}

static uint8_t bw_khz_to_enum(int bw_khz) {
    if (bw_khz == 250) return BW_250KHZ;
    if (bw_khz == 500) return BW_500KHZ;
    return BW_125KHZ;
}

static uint8_t str_to_coderate(const char *s) {
    if (!s) return CR_LORA_4_5;
    if (strcmp(s, "4/6") == 0) return CR_LORA_4_6;
    if (strcmp(s, "4/7") == 0) return CR_LORA_4_7;
    if (strcmp(s, "4/8") == 0) return CR_LORA_4_8;
    return CR_LORA_4_5;
}

// ==========================

static void load_config(const char *path) {
    // Built-in defaults
    strncpy(g_cfg.target_ip,             "192.168.1.8",    sizeof(g_cfg.target_ip)   - 1);
    g_cfg.port_up                = 5555;
    g_cfg.port_down              = 5556;
    g_cfg.status_port            = 5557;
    g_cfg.heartbeat_interval_s   = 10;
    g_cfg.link_key[0]            = '\0';
    strncpy(g_cfg.spi_path,              "/dev/spidev1.0", sizeof(g_cfg.spi_path)    - 1);
    strncpy(g_cfg.reset_gpio,            "23",             sizeof(g_cfg.reset_gpio)  - 1);
    g_cfg.pa_gpio[0]             = '\0';
    g_cfg.pa_gpio_active_high    = false;
    g_cfg.clksrc                 = 0;
    g_cfg.lorawan_public         = false;
    g_cfg.full_duplex            = false;
    strncpy(g_cfg.rf0_type,              "SX1250",         sizeof(g_cfg.rf0_type)    - 1);
    strncpy(g_cfg.rf1_type,              "SX1250",         sizeof(g_cfg.rf1_type)    - 1);
    g_cfg.rf0_single_input       = false;
    g_cfg.rf1_single_input       = false;
    g_cfg.rf0_tx_enable          = true;
    g_cfg.rf1_tx_enable          = false;
    g_cfg.rf0_freq               = 867500000;
    g_cfg.rf0_rssi_offset        = -215.4f;
    g_cfg.rf1_freq               = 868500000;
    g_cfg.rf1_rssi_offset        = -215.4f;
    // Default 8-channel plan: 5 channels on RF0, 3 on RF1
    static const int32_t DEF_IF[8]    = {-400000, -200000, 0, 200000, 400000, -400000, -200000, 0};
    static const uint8_t DEF_RADIO[8] = {0, 0, 0, 0, 0, 1, 1, 1};
    for (int i = 0; i < 8; i++) {
        g_cfg.chan_if[i]    = DEF_IF[i];
        g_cfg.chan_radio[i] = DEF_RADIO[i];
    }
    g_cfg.chan_lora_std_enable   = false;
    g_cfg.chan_lora_std_radio    = 0;
    g_cfg.chan_lora_std_if       = 0;
    g_cfg.chan_lora_std_bw       = 250;
    g_cfg.chan_lora_std_sf       = 7;
    g_cfg.chan_fsk_enable        = false;
    g_cfg.chan_fsk_radio         = 0;
    g_cfg.chan_fsk_if            = 0;
    g_cfg.chan_fsk_bw            = 125;
    g_cfg.chan_fsk_datarate      = 50000;
    memset(&g_cfg.tx_gain_lut, 0, sizeof(g_cfg.tx_gain_lut));
    g_cfg.tx_default_freq        = 868100000;
    g_cfg.tx_default_sf          = 7;
    g_cfg.tx_default_power       = 14;
    g_cfg.tx_default_rfch        = 0;
    strncpy(g_cfg.tx_default_coderate, "4/5", sizeof(g_cfg.tx_default_coderate) - 1);
    g_cfg.tx_default_bandwidth   = 125;
    g_cfg.tx_default_preamble    = 8;
    g_cfg.tx_default_invert      = true;
    g_cfg.tx_free_timeout_ms     = 2000;
    g_cfg.led_rx[0]              = '\0';
    g_cfg.led_tx[0]              = '\0';
    g_cfg.sf_mask                    = LGW_MULTI_SF_EN; // 0xFF (SF5..SF12 all enabled)
    g_cfg.mcu_health_check           = true;
    g_cfg.temp_monitor_enable        = true;
    g_cfg.ext_rx_metadata            = true;
    g_cfg.ftime_enable               = false;
    g_cfg.chan_lora_std_implicit_hdr = false;
    g_cfg.chan_lora_std_implicit_len = 0;
    g_cfg.chan_lora_std_implicit_crc = false;
    strncpy(g_cfg.chan_lora_std_implicit_cr, "4/5", sizeof(g_cfg.chan_lora_std_implicit_cr) - 1);
    g_cfg.chan_fsk_sync_size         = 3;
    g_cfg.chan_fsk_sync_word         = 0xC194C1ULL;

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
#define CFG_INT(key, dst) \
    if ((val = json_object_get_value(obj, key)) && json_value_get_type(val) == JSONNumber) \
        dst = (int)json_value_get_number(val);
#define CFG_I32(key, dst) \
    if ((val = json_object_get_value(obj, key)) && json_value_get_type(val) == JSONNumber) \
        dst = (int32_t)json_value_get_number(val);
#define CFG_U16(key, dst) \
    if ((val = json_object_get_value(obj, key)) && json_value_get_type(val) == JSONNumber) \
        dst = (uint16_t)json_value_get_number(val);
#define CFG_U8(key, dst) \
    if ((val = json_object_get_value(obj, key)) && json_value_get_type(val) == JSONNumber) \
        dst = (uint8_t)json_value_get_number(val);
#define CFG_I8(key, dst) \
    if ((val = json_object_get_value(obj, key)) && json_value_get_type(val) == JSONNumber) \
        dst = (int8_t)json_value_get_number(val);
#define CFG_FLOAT(key, dst) \
    if ((val = json_object_get_value(obj, key)) && json_value_get_type(val) == JSONNumber) \
        dst = (float)json_value_get_number(val);
#define CFG_BOOL(key, dst) \
    if ((val = json_object_get_value(obj, key)) && json_value_get_type(val) == JSONBoolean) \
        dst = (json_value_get_boolean(val) != 0);

    // Network
    CFG_STR  ("target_ip",            g_cfg.target_ip)
    CFG_STR  ("link_key",             g_cfg.link_key)
    CFG_U16  ("port_up",              g_cfg.port_up)
    CFG_U16  ("port_down",            g_cfg.port_down)
    CFG_U16  ("status_port",          g_cfg.status_port)
    CFG_INT  ("heartbeat_interval_s", g_cfg.heartbeat_interval_s)
    // Hardware
    CFG_STR  ("spi_path",             g_cfg.spi_path)
    CFG_STR  ("reset_gpio",           g_cfg.reset_gpio)
    CFG_STR  ("pa_gpio",              g_cfg.pa_gpio)
    CFG_BOOL ("pa_gpio_active_high",  g_cfg.pa_gpio_active_high)
    CFG_INT  ("clksrc",               g_cfg.clksrc)
    CFG_BOOL ("full_duplex",          g_cfg.full_duplex)
    // Radio chains
    CFG_STR  ("rf0_type",             g_cfg.rf0_type)
    CFG_STR  ("rf1_type",             g_cfg.rf1_type)
    CFG_BOOL ("rf0_single_input",     g_cfg.rf0_single_input)
    CFG_BOOL ("rf1_single_input",     g_cfg.rf1_single_input)
    CFG_BOOL ("rf0_tx_enable",        g_cfg.rf0_tx_enable)
    CFG_BOOL ("rf1_tx_enable",        g_cfg.rf1_tx_enable)
    CFG_U32  ("rf0_freq",             g_cfg.rf0_freq)
    CFG_FLOAT("rf0_rssi_offset",      g_cfg.rf0_rssi_offset)
    CFG_U32  ("rf1_freq",             g_cfg.rf1_freq)
    CFG_FLOAT("rf1_rssi_offset",      g_cfg.rf1_rssi_offset)

    // sync_word string -> lorawan_public bool
    if ((str = json_object_get_string(obj, "sync_word"))) {
        if (strcmp(str, "public") == 0)       g_cfg.lorawan_public = true;
        else if (strcmp(str, "private") == 0) g_cfg.lorawan_public = false;
        else printf("[CFG] sync_word '%s' unknown — using private(0x12).\n", str);
    }

    // Channel IF offsets array
    JSON_Array *if_arr = json_object_get_array(obj, "chan_if");
    if (if_arr) {
        size_t n = json_array_get_count(if_arr);
        if (n > 8) n = 8;
        for (size_t i = 0; i < n; i++)
            g_cfg.chan_if[i] = (int32_t)json_array_get_number(if_arr, i);
    }

    // Channel radio assignments array
    JSON_Array *radio_arr = json_object_get_array(obj, "chan_radio");
    if (radio_arr) {
        size_t n = json_array_get_count(radio_arr);
        if (n > 8) n = 8;
        for (size_t i = 0; i < n; i++)
            g_cfg.chan_radio[i] = (uint8_t)json_array_get_number(radio_arr, i);
    }

    // LoRa std channel (channel index 8)
    CFG_BOOL ("chan_lora_std_enable", g_cfg.chan_lora_std_enable)
    CFG_U8   ("chan_lora_std_radio",  g_cfg.chan_lora_std_radio)
    CFG_I32  ("chan_lora_std_if",     g_cfg.chan_lora_std_if)
    CFG_INT  ("chan_lora_std_bw",     g_cfg.chan_lora_std_bw)
    CFG_U8   ("chan_lora_std_sf",     g_cfg.chan_lora_std_sf)

    // FSK channel (channel index 9)
    CFG_BOOL ("chan_fsk_enable",   g_cfg.chan_fsk_enable)
    CFG_U8   ("chan_fsk_radio",    g_cfg.chan_fsk_radio)
    CFG_I32  ("chan_fsk_if",       g_cfg.chan_fsk_if)
    CFG_INT  ("chan_fsk_bw",       g_cfg.chan_fsk_bw)
    CFG_U32  ("chan_fsk_datarate", g_cfg.chan_fsk_datarate)

    // TX
    CFG_U32  ("tx_default_freq",      g_cfg.tx_default_freq)
    CFG_INT  ("tx_default_sf",        g_cfg.tx_default_sf)
    CFG_I8   ("tx_default_power",     g_cfg.tx_default_power)
    CFG_U8   ("tx_default_rfch",      g_cfg.tx_default_rfch)
    CFG_STR  ("tx_default_coderate",  g_cfg.tx_default_coderate)
    CFG_INT  ("tx_default_bandwidth", g_cfg.tx_default_bandwidth)
    CFG_U8   ("tx_default_preamble",  g_cfg.tx_default_preamble)
    CFG_BOOL ("tx_default_invert",    g_cfg.tx_default_invert)
    CFG_INT  ("tx_free_timeout_ms",   g_cfg.tx_free_timeout_ms)

    // TX gain LUT (supports sx1250 fields pwr_idx/pa_gain and sx125x fields dac_gain/mix_gain/dig_gain)
    JSON_Array *lut_arr = json_object_get_array(obj, "tx_gain_lut");
    if (lut_arr) {
        size_t lut_n = json_array_get_count(lut_arr);
        if (lut_n > TX_GAIN_LUT_SIZE_MAX) lut_n = TX_GAIN_LUT_SIZE_MAX;
        g_cfg.tx_gain_lut.size = (uint8_t)lut_n;
        for (size_t i = 0; i < lut_n; i++) {
            JSON_Object *e = json_array_get_object(lut_arr, i);
            if (!e) continue;
            g_cfg.tx_gain_lut.lut[i].rf_power = (int8_t) json_object_get_number(e, "rf_power");
            g_cfg.tx_gain_lut.lut[i].pa_gain  = (uint8_t)json_object_get_number(e, "pa_gain");
            g_cfg.tx_gain_lut.lut[i].pwr_idx  = (uint8_t)json_object_get_number(e, "pwr_idx");
            g_cfg.tx_gain_lut.lut[i].dac_gain = (uint8_t)json_object_get_number(e, "dac_gain");
            g_cfg.tx_gain_lut.lut[i].mix_gain = (uint8_t)json_object_get_number(e, "mix_gain");
            g_cfg.tx_gain_lut.lut[i].dig_gain = (uint8_t)json_object_get_number(e, "dig_gain");
        }
    }

    // LEDs
    CFG_STR  ("led_rx", g_cfg.led_rx)
    CFG_STR  ("led_tx", g_cfg.led_tx)

    // Optional HAL Features
    CFG_U8   ("sf_mask",                    g_cfg.sf_mask)
    CFG_BOOL ("mcu_health_check",           g_cfg.mcu_health_check)
    CFG_BOOL ("temp_monitor_enable",        g_cfg.temp_monitor_enable)
    CFG_BOOL ("ext_rx_metadata",            g_cfg.ext_rx_metadata)
    CFG_BOOL ("ftime_enable",               g_cfg.ftime_enable)
    CFG_BOOL ("chan_lora_std_implicit_hdr", g_cfg.chan_lora_std_implicit_hdr)
    CFG_U8   ("chan_lora_std_implicit_len", g_cfg.chan_lora_std_implicit_len)
    CFG_BOOL ("chan_lora_std_implicit_crc", g_cfg.chan_lora_std_implicit_crc)
    CFG_STR  ("chan_lora_std_implicit_cr",  g_cfg.chan_lora_std_implicit_cr)
    CFG_U8   ("chan_fsk_sync_size",         g_cfg.chan_fsk_sync_size)
    if ((val = json_object_get_value(obj, "chan_fsk_sync_word")) && json_value_get_type(val) == JSONNumber)
        g_cfg.chan_fsk_sync_word = (uint64_t)json_value_get_number(val);

#undef CFG_STR
#undef CFG_U32
#undef CFG_INT
#undef CFG_I32
#undef CFG_U16
#undef CFG_U8
#undef CFG_I8
#undef CFG_FLOAT
#undef CFG_BOOL

    json_value_free(root);

    printf("[CFG] Loaded '%s'\n"
           "      target=%s  up=%u  down=%u  status_port=%u  hb=%ds\n"
           "      spi=%s  rst_gpio=%s  pa_gpio=%s  clksrc=%u\n"
           "      sync=%s  full_duplex=%s\n"
           "      rf0: %s %.3fMHz offset=%.1f tx=%s single=%s\n"
           "      rf1: %s %.3fMHz offset=%.1f tx=%s single=%s\n"
           "      lut=%u entries\n"
           "      tx_default: %.3fMHz SF%u BW%d CR%s %ddBm rfch%u preamble=%u invert=%s\n"
           "      tx_timeout=%dms  led_rx='%s'  led_tx='%s'\n",
           path,
           g_cfg.target_ip, g_cfg.port_up, g_cfg.port_down, g_cfg.status_port, g_cfg.heartbeat_interval_s,
           g_cfg.spi_path, g_cfg.reset_gpio,
           g_cfg.pa_gpio[0] ? g_cfg.pa_gpio : "(disabled)", g_cfg.clksrc,
           g_cfg.lorawan_public ? "public(0x34)" : "private(0x12)",
           g_cfg.full_duplex ? "yes" : "no",
           g_cfg.rf0_type, g_cfg.rf0_freq / 1e6, g_cfg.rf0_rssi_offset,
           g_cfg.rf0_tx_enable ? "yes" : "no", g_cfg.rf0_single_input ? "yes" : "no",
           g_cfg.rf1_type, g_cfg.rf1_freq / 1e6, g_cfg.rf1_rssi_offset,
           g_cfg.rf1_tx_enable ? "yes" : "no", g_cfg.rf1_single_input ? "yes" : "no",
           g_cfg.tx_gain_lut.size,
           g_cfg.tx_default_freq / 1e6, g_cfg.tx_default_sf, g_cfg.tx_default_bandwidth,
           g_cfg.tx_default_coderate, g_cfg.tx_default_power,
           g_cfg.tx_default_rfch, g_cfg.tx_default_preamble,
           g_cfg.tx_default_invert ? "yes" : "no",
           g_cfg.tx_free_timeout_ms, g_cfg.led_rx, g_cfg.led_tx);
}

// === PA/LNA CONTROL ===
// pa_gpio LOW/off  = transmit mode (PA enabled, LNA bypassed)
// pa_gpio HIGH/on  = receive mode  (PA off, LNA active)
//
// Two formats supported in config:
//   numeric sysfs GPIO  — e.g. "17"             → /sys/class/gpio/gpio17/value
//   OpenWrt LED name    — e.g. "dragino2:red:wan" → /sys/class/leds/.../brightness

static int  g_pa_gpio_fd  = -1;
static bool g_pa_is_led   = false;

// LED name if string contains ':' or starts with a non-digit
static bool pa_detect_led(const char *s) {
    return s[0] && (strchr(s, ':') != NULL || !(s[0] >= '0' && s[0] <= '9'));
}

static void pa_gpio_init(void) {
    if (!g_cfg.pa_gpio[0]) return;
    const char *name = g_cfg.pa_gpio;
    char path[128];
    int fd;

    g_pa_is_led = pa_detect_led(name);

    if (g_pa_is_led) {
        // Claim LED: disable kernel trigger so we can drive it manually
        snprintf(path, sizeof(path), "/sys/class/leds/%s/trigger", name);
        fd = open(path, O_WRONLY);
        if (fd >= 0) { write(fd, "none", 4); close(fd); }

        snprintf(path, sizeof(path), "/sys/class/leds/%s/brightness", name);
        g_pa_gpio_fd = open(path, O_WRONLY);
        if (g_pa_gpio_fd < 0) {
            printf("[PA] Failed to open LED '%s' — PA control disabled.\n", name);
            return;
        }
        write(g_pa_gpio_fd, g_cfg.pa_gpio_active_high ? "0" : "255", g_cfg.pa_gpio_active_high ? 1 : 3); // idle = RX
        printf("[PA] LED '%s': PA switch active (TX=%s, RX=%s).\n", name,
               g_cfg.pa_gpio_active_high ? "on/HIGH" : "off/LOW",
               g_cfg.pa_gpio_active_high ? "off/LOW" : "on/HIGH");
    } else {
        // Numeric sysfs GPIO
        fd = open("/sys/class/gpio/export", O_WRONLY);
        if (fd >= 0) { write(fd, name, strlen(name)); close(fd); }
        usleep(100000);

        snprintf(path, sizeof(path), "/sys/class/gpio/gpio%s/direction", name);
        fd = open(path, O_WRONLY);
        if (fd >= 0) { write(fd, "out", 3); close(fd); }
        usleep(50000);

        snprintf(path, sizeof(path), "/sys/class/gpio/gpio%s/value", name);
        g_pa_gpio_fd = open(path, O_WRONLY);
        if (g_pa_gpio_fd < 0) {
            printf("[PA] Failed to open GPIO %s — PA control disabled.\n", name);
            return;
        }
        write(g_pa_gpio_fd, g_cfg.pa_gpio_active_high ? "0" : "1", 1); // idle = RX
        printf("[PA] GPIO %s: PA switch active (TX=%s, RX=%s).\n", name,
               g_cfg.pa_gpio_active_high ? "HIGH" : "LOW",
               g_cfg.pa_gpio_active_high ? "LOW"  : "HIGH");
    }
}

static void pa_set(int tx) {
    if (g_pa_gpio_fd < 0) return;
    int assert = g_cfg.pa_gpio_active_high ? tx : !tx;
    if (g_pa_is_led)
        write(g_pa_gpio_fd, assert ? "255" : "0", assert ? 3 : 1);
    else
        write(g_pa_gpio_fd, assert ? "1" : "0", 1);
}

static void pa_gpio_cleanup(void) {
    if (g_pa_gpio_fd < 0) return;
    pa_set(0);      // ensure RX mode on shutdown
    close(g_pa_gpio_fd);
    g_pa_gpio_fd = -1;
}
// ======================

#define PKT_TYPE_HEARTBEAT 0x02
#define PKT_TYPE_BOOT      0x03

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
    uint32_t rf0_freq;
    uint32_t rf1_freq;
};

struct __attribute__((packed)) boot_pkt {
    uint8_t  pkt_type;
    uint64_t gateway_eui;
    char     hal_version[32];
};

static int sock_up, sock_down;
static struct sockaddr_in dest_addr;
static uint64_t g_gateway_eui = 0;
static time_t   g_start_time;
static uint32_t g_uplink_seq = 0;
static uint8_t  g_sync_word   = 0x12;
static uint32_t g_rf0_freq    = 0;
static uint32_t g_rf1_freq    = 0;
static float    g_temperature_c = 0.0f;
static bool     g_temp_valid    = false;

static pthread_mutex_t stats_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t hal_mutex   = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t sock_mutex  = PTHREAD_MUTEX_INITIALIZER;
static bool            g_net_ok    = true;
static volatile int    g_consec_err = 0;
static uint32_t stat_rx_count      = 0;
static uint32_t stat_tx_count      = 0;
static uint32_t stat_crc_err       = 0;
static uint32_t stat_tx_err        = 0;
static uint32_t stat_tx_queue_drop = 0;

static uint32_t next_uplink_seq(void) {
    return __sync_add_and_fetch(&g_uplink_seq, 1);
}

static volatile sig_atomic_t g_quit        = 0;
static volatile sig_atomic_t g_quit_signal = 0;

static volatile int g_led_rx_blink = 0;
static volatile int g_led_tx_blink = 0;

typedef struct {
    struct lgw_pkt_tx_s pkt;
    char                id[40];     // request_id, empty when the sender wants no answer
    struct sockaddr_in  src;
} tx_item_t;

typedef struct {
    tx_item_t entries[TX_QUEUE_SIZE];
    int     head;
    int     count;
    pthread_mutex_t mutex;
    pthread_cond_t  not_empty;
} tx_queue_t;

static tx_queue_t txq;

static void txq_init(tx_queue_t *q) {
    memset(q, 0, sizeof(*q));
    pthread_mutex_init(&q->mutex, NULL);
    pthread_cond_init(&q->not_empty, NULL);
}

static bool txq_push(tx_queue_t *q, const tx_item_t *pkt) {
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

static bool txq_pop(tx_queue_t *q, tx_item_t *pkt) {
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

static int txq_count(tx_queue_t *q) {
    pthread_mutex_lock(&q->mutex);
    int c = q->count;
    pthread_mutex_unlock(&q->mutex);
    return c;
}

static void sig_handler(int signo) {
    g_quit_signal = signo;
    g_quit = 1;
}

static void reset_sx1302(void) {
    if (access("/usr/local/bin/reset_lgw.sh", X_OK) == 0) {
        printf("[RESET] Running /usr/local/bin/reset_lgw.sh start...\n");
        system("/usr/local/bin/reset_lgw.sh start");
        return;
    }
    int  fd;
    char path[64];
    const char *gpio = g_cfg.reset_gpio;
    printf("Toggling SX1302 reset (GPIO %s)...\n", gpio);

    fd = open("/sys/class/gpio/export", O_WRONLY);
    if (fd >= 0) { write(fd, gpio, strlen(gpio)); close(fd); }
    usleep(100000);

    snprintf(path, sizeof(path), "/sys/class/gpio/gpio%s/direction", gpio);
    fd = open(path, O_WRONLY);
    if (fd >= 0) { write(fd, "out", 3); close(fd); }
    usleep(100000);

    // Pulse: assert then release — leave as output=0 (running state)
    snprintf(path, sizeof(path), "/sys/class/gpio/gpio%s/value", gpio);
    fd = open(path, O_WRONLY);
    if (fd >= 0) {
        write(fd, "1", 1); usleep(100000);
        write(fd, "0", 1); usleep(100000);
        close(fd);
    }

    printf("Hardware reset complete.\n");
}

static void resolve_dest_addr(void) {
    memset(&dest_addr, 0, sizeof(dest_addr));
    dest_addr.sin_family = AF_INET;
    dest_addr.sin_port   = htons(g_cfg.port_up);

    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family   = AF_INET;
    hints.ai_socktype = SOCK_DGRAM;
    if (getaddrinfo(g_cfg.target_ip, NULL, &hints, &res) == 0 && res) {
        struct sockaddr_in *sin = (struct sockaddr_in *)res->ai_addr;
        dest_addr.sin_addr = sin->sin_addr;
        freeaddrinfo(res);
    } else {
        dest_addr.sin_addr.s_addr = inet_addr(g_cfg.target_ip);
    }
}

static void send_uplink(const void *buf, size_t len) {
    pthread_mutex_lock(&sock_mutex);
    if (sock_up < 0) {
        sock_up = socket(AF_INET, SOCK_DGRAM, 0);
        resolve_dest_addr();
    }
    ssize_t sent = -1;
    if (sock_up >= 0) {
        sent = sendto(sock_up, buf, len, 0,
                      (const struct sockaddr *)&dest_addr, sizeof(dest_addr));
#if !defined(__mips__)   // the hub runs on the Bobcat itself
        if (dest_addr.sin_addr.s_addr != htonl(INADDR_LOOPBACK)) {
            struct sockaddr_in loop_addr;
            memset(&loop_addr, 0, sizeof(loop_addr));
            loop_addr.sin_family = AF_INET;
            loop_addr.sin_port = htons(g_cfg.port_up);
            loop_addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            sendto(sock_up, buf, len, 0, (const struct sockaddr *)&loop_addr, sizeof(loop_addr));
        }
#endif
    }
    if (sent < 0) {
        if (g_net_ok) {
            printf("[NET] Uplink sendto(%s:%u) failed (%s) — reconnecting socket...\n",
                   g_cfg.target_ip, g_cfg.port_up, strerror(errno));
            g_net_ok = false;
        }
        if (sock_up >= 0) close(sock_up);
        sock_up = socket(AF_INET, SOCK_DGRAM, 0);
        resolve_dest_addr();
        if (sock_up >= 0) {
            sent = sendto(sock_up, buf, len, 0,
                          (const struct sockaddr *)&dest_addr, sizeof(dest_addr));
        }
    }
    if (sent >= 0 && !g_net_ok) {
        g_net_ok = true;
        printf("[NET] Uplink connection to %s:%u recovered.\n",
               g_cfg.target_ip, g_cfg.port_up);
    }
    pthread_mutex_unlock(&sock_mutex);
}

// === GATEWAY <-> HUB LINK ===
// Uplinks and status carry a sequence number and are acknowledged by the hub;
// anything unacknowledged is sent again for about 12 seconds. Commands from
// the hub are signed: "L2:<nonce>:<hmac>:<json>", where the nonce is one this
// engine published recently, so a captured command cannot be replayed.

static const uint32_t SHA_K[64] = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
};

typedef struct {
    uint32_t h[8];
    uint64_t total;
    uint8_t  buf[64];
    size_t   n;
} sha256_ctx;

#define SHA_ROR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))

static void sha256_block(uint32_t *h, const uint8_t *p) {
    uint32_t w[64];
    for (int i = 0; i < 16; i++)
        w[i] = ((uint32_t)p[i*4] << 24) | ((uint32_t)p[i*4+1] << 16) | ((uint32_t)p[i*4+2] << 8) | p[i*4+3];
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = SHA_ROR(w[i-15], 7) ^ SHA_ROR(w[i-15], 18) ^ (w[i-15] >> 3);
        uint32_t s1 = SHA_ROR(w[i-2], 17) ^ SHA_ROR(w[i-2], 19) ^ (w[i-2] >> 10);
        w[i] = w[i-16] + s0 + w[i-7] + s1;
    }
    uint32_t a=h[0], b=h[1], c=h[2], d=h[3], e=h[4], f=h[5], g=h[6], hh=h[7];
    for (int i = 0; i < 64; i++) {
        uint32_t t1 = hh + (SHA_ROR(e,6) ^ SHA_ROR(e,11) ^ SHA_ROR(e,25)) + ((e & f) ^ (~e & g)) + SHA_K[i] + w[i];
        uint32_t t2 = (SHA_ROR(a,2) ^ SHA_ROR(a,13) ^ SHA_ROR(a,22)) + ((a & b) ^ (a & c) ^ (b & c));
        hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
    }
    h[0]+=a; h[1]+=b; h[2]+=c; h[3]+=d; h[4]+=e; h[5]+=f; h[6]+=g; h[7]+=hh;
}

static void sha256_init(sha256_ctx *c) {
    static const uint32_t iv[8] = {0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19};
    memcpy(c->h, iv, sizeof(iv));
    c->total = 0;
    c->n = 0;
}

static void sha256_update(sha256_ctx *c, const uint8_t *p, size_t len) {
    c->total += len;
    while (len) {
        size_t k = 64 - c->n;
        if (k > len) k = len;
        memcpy(c->buf + c->n, p, k);
        c->n += k; p += k; len -= k;
        if (c->n == 64) { sha256_block(c->h, c->buf); c->n = 0; }
    }
}

static void sha256_final(sha256_ctx *c, uint8_t out[32]) {
    uint64_t bits = c->total * 8;
    uint8_t  pad = 0x80, zero = 0, lenb[8];
    sha256_update(c, &pad, 1);
    while (c->n != 56) sha256_update(c, &zero, 1);
    for (int i = 0; i < 8; i++) lenb[i] = (uint8_t)(bits >> (56 - 8*i));
    sha256_update(c, lenb, 8);
    for (int i = 0; i < 8; i++) {
        out[i*4]   = (uint8_t)(c->h[i] >> 24);
        out[i*4+1] = (uint8_t)(c->h[i] >> 16);
        out[i*4+2] = (uint8_t)(c->h[i] >> 8);
        out[i*4+3] = (uint8_t)(c->h[i]);
    }
}

#define LINK_SLOTS     32
#define LINK_MAX_LEN   1600
#define LINK_MAX_TRIES 6

typedef struct {
    bool     used;
    uint32_t seq;
    uint16_t len;
    uint8_t  tries;
    uint64_t next_ms;
    char     buf[LINK_MAX_LEN];
} link_slot_t;

static link_slot_t     g_link[LINK_SLOTS];
static pthread_mutex_t link_mutex  = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t nonce_mutex = PTHREAD_MUTEX_INITIALIZER;
static volatile bool   g_link_peer = false;   // the hub has acknowledged us
static uint32_t        g_boot_id   = 0;
static uint32_t        g_nonces[3] = {0, 0, 0};
static const char     *g_cfg_path  = CONFIG_PATH;
static uint32_t stat_link_acks = 0, stat_link_retx = 0, stat_link_lost = 0, stat_auth_rej = 0;

static uint64_t mono_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000ULL + (uint64_t)(ts.tv_nsec / 1000000L);
}

static uint32_t random_u32(void) {
    uint32_t v = 0;
    int fd = open("/dev/urandom", O_RDONLY);
    if (fd >= 0) {
        if (read(fd, &v, sizeof(v)) != sizeof(v)) v = 0;
        close(fd);
    }
    return v ? v : (uint32_t)time(NULL) ^ (uint32_t)mono_ms();
}

static void nonce_rotate(void) {
    uint32_t v = random_u32();
    pthread_mutex_lock(&nonce_mutex);
    g_nonces[2] = g_nonces[1];
    g_nonces[1] = g_nonces[0];
    g_nonces[0] = v;
    pthread_mutex_unlock(&nonce_mutex);
}

static uint32_t nonce_current(void) {
    pthread_mutex_lock(&nonce_mutex);
    uint32_t v = g_nonces[0];
    pthread_mutex_unlock(&nonce_mutex);
    return v;
}

static bool nonce_known(uint32_t v) {
    pthread_mutex_lock(&nonce_mutex);
    bool ok = v != 0 && (v == g_nonces[0] || v == g_nonces[1] || v == g_nonces[2]);
    pthread_mutex_unlock(&nonce_mutex);
    return ok;
}

static void send_reliable(const char *buf, size_t len, uint32_t seq) {
    send_uplink(buf, len);
    if (len > LINK_MAX_LEN) return;
    pthread_mutex_lock(&link_mutex);
    link_slot_t *s = &g_link[seq % LINK_SLOTS];
    if (s->used && g_link_peer) stat_link_lost++;
    s->used = true;
    s->seq = seq;
    s->len = (uint16_t)len;
    s->tries = 0;
    s->next_ms = mono_ms() + 200;
    memcpy(s->buf, buf, len);
    pthread_mutex_unlock(&link_mutex);
}

static void *thread_link(void *arg) {
    (void)arg;
    char rx[256];
    printf("[LINK] Thread started (protocol %d).\n", LINK_VERSION);
    while (!g_quit) {
        for (;;) {
            pthread_mutex_lock(&sock_mutex);
            int n = (sock_up >= 0) ? (int)recv(sock_up, rx, sizeof(rx) - 1, MSG_DONTWAIT) : -1;
            pthread_mutex_unlock(&sock_mutex);
            if (n <= 0) break;
            rx[n] = '\0';
            const char *q = strstr(rx, "\"seq\":");
            if (!strstr(rx, "\"msg_type\":\"ack\"") || !q) continue;
            uint32_t seq = (uint32_t)strtoul(q + 6, NULL, 10);
            pthread_mutex_lock(&link_mutex);
            link_slot_t *s = &g_link[seq % LINK_SLOTS];
            if (s->used && s->seq == seq) s->used = false;
            if (!g_link_peer) printf("[LINK] Hub is acknowledging packets.\n");
            g_link_peer = true;
            stat_link_acks++;
            pthread_mutex_unlock(&link_mutex);
        }
        uint64_t now = mono_ms();
        pthread_mutex_lock(&link_mutex);
        for (int i = 0; i < LINK_SLOTS; i++) {
            link_slot_t *s = &g_link[i];
            if (!s->used || now < s->next_ms) continue;
            if (!g_link_peer) { s->used = false; continue; }   // nothing acknowledges yet
            if (s->tries >= LINK_MAX_TRIES) {
                s->used = false;
                stat_link_lost++;
                continue;
            }
            send_uplink(s->buf, s->len);
            s->tries++;
            s->next_ms = now + (200ULL << s->tries);
            stat_link_retx++;
        }
        pthread_mutex_unlock(&link_mutex);
        usleep(20000);
    }
    printf("[LINK] Thread exiting.\n");
    return NULL;
}

static void send_gateway_status_json(void) {
    char json_status[1500];
    uint32_t uptime_s = (uint32_t)(time(NULL) - g_start_time);
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    uint64_t ts_ms = (uint64_t)ts.tv_sec * 1000ULL + (uint64_t)(ts.tv_nsec / 1000000L);
    uint32_t seq = next_uplink_seq();
    pthread_mutex_lock(&stats_mutex);
    uint32_t rx = stat_rx_count;
    uint32_t tx = stat_tx_count;
    uint32_t crc = stat_crc_err;
    uint32_t tx_err = stat_tx_err;
    uint32_t q_drop = stat_tx_queue_drop;
    pthread_mutex_unlock(&stats_mutex);

    int len = snprintf(json_status, sizeof(json_status),
        "{\"v\":%d,\"msg_type\":\"gateway_status\","
        "\"gateway_id\":\"%016llX\",\"seq\":%u,\"boot\":%u,\"ts_ms\":%llu,"
        "\"gateway_status\":{"
        "\"eui\":\"%016llX\","
        "\"gateway_id\":\"%016llX\","
        "\"hal_version\":\"%s\","
        "\"uptime_s\":%u,"
        "\"sync_word\":\"%s\","
        "\"rf0_freq\":%u,"
        "\"rf1_freq\":%u,"
        "\"tx_power\":%d,"
        "\"rx\":%u,\"tx\":%u,\"crc_err\":%u,\"tx_err\":%u,"
        "\"q_depth\":%d,\"q_drop\":%u,"
        "\"temp_c\":%.1f,"
        "\"target_ip\":\"%s\","
        "\"port_up\":%u,"
        "\"port_down\":%u,"
        "\"status_port\":%u,"
        "\"link\":%d,\"auth\":%s,\"nonce\":\"%08x\","
        "\"model\":\"%s\",\"engine\":\"%s\","
        "\"link_retx\":%u,\"link_lost\":%u,\"auth_rej\":%u"
        "}}",
        LINK_VERSION,
        (unsigned long long)g_gateway_eui,
        (unsigned)seq,
        (unsigned)g_boot_id,
        (unsigned long long)ts_ms,
        (unsigned long long)g_gateway_eui,
        (unsigned long long)g_gateway_eui,
        lgw_version_info(),
        uptime_s,
        (g_sync_word == 0x34) ? "public" : "private",
        g_rf0_freq, g_rf1_freq,
        g_cfg.tx_default_power,
        rx, tx, crc, tx_err,
        txq_count(&txq), q_drop,
        g_temperature_c,
        g_cfg.target_ip,
        (unsigned)g_cfg.port_up,
        (unsigned)g_cfg.port_down,
        (unsigned)g_cfg.status_port,
        LINK_VERSION, g_cfg.link_key[0] ? "true" : "false", nonce_current(),
        GATEWAY_MODEL, ENGINE_VERSION,
        stat_link_retx, stat_link_lost, stat_auth_rej);

    if (len > 0 && len < (int)sizeof(json_status)) {
        send_reliable(json_status, (size_t)len, seq);
    }
}

static int configure_and_start_sx1302(void) {
    struct lgw_conf_board_s  boardconf;
    struct lgw_conf_rxrf_s   rfconf;
    struct lgw_conf_rxif_s   ifconf;
    struct lgw_conf_demod_s  demodconf;
    struct lgw_tx_gain_lut_s txlut;

    if (access(g_cfg.spi_path, F_OK) != 0) {
        system("/etc/init.d/spi_init start >/dev/null 2>&1");
        usleep(200000);
    }

    reset_sx1302();

    memset(&boardconf, 0, sizeof(boardconf));
    boardconf.lorawan_public = g_cfg.lorawan_public;
    boardconf.clksrc         = g_cfg.clksrc;
    boardconf.full_duplex    = g_cfg.full_duplex;
    boardconf.com_type       = LGW_COM_SPI;
    strncpy(boardconf.com_path, g_cfg.spi_path, sizeof(boardconf.com_path) - 1);
    lgw_board_setconf(&boardconf);
    g_sync_word = g_cfg.lorawan_public ? 0x34 : 0x12;

    memset(&txlut, 0, sizeof(txlut));
    if (g_cfg.tx_gain_lut.size > 0) {
        txlut = g_cfg.tx_gain_lut;
    } else {
        txlut.size = 2;
        txlut.lut[0].rf_power = 14; txlut.lut[0].pa_gain = 0; txlut.lut[0].pwr_idx = 21;
        txlut.lut[1].rf_power = 27; txlut.lut[1].pa_gain = 1; txlut.lut[1].pwr_idx = 22;
    }
    if (g_cfg.rf0_tx_enable) lgw_txgain_setconf(0, &txlut);
    if (g_cfg.rf1_tx_enable) lgw_txgain_setconf(1, &txlut);

    memset(&rfconf, 0, sizeof(rfconf));
    rfconf.enable            = true;
    rfconf.type              = str_to_radio_type(g_cfg.rf0_type);
    rfconf.single_input_mode = g_cfg.rf0_single_input;
    rfconf.tx_enable         = g_cfg.rf0_tx_enable;
    rfconf.freq_hz           = g_cfg.rf0_freq;
    rfconf.rssi_offset       = g_cfg.rf0_rssi_offset;
    g_rf0_freq               = rfconf.freq_hz;
    lgw_rxrf_setconf(0, &rfconf);

    rfconf.type              = str_to_radio_type(g_cfg.rf1_type);
    rfconf.single_input_mode = g_cfg.rf1_single_input;
    rfconf.tx_enable         = g_cfg.rf1_tx_enable;
    rfconf.freq_hz           = g_cfg.rf1_freq;
    rfconf.rssi_offset       = g_cfg.rf1_rssi_offset;
    g_rf1_freq               = rfconf.freq_hz;
    lgw_rxrf_setconf(1, &rfconf);

    memset(&ifconf, 0, sizeof(ifconf));
    ifconf.enable = true;
    for (int i = 0; i < 8; i++) {
        ifconf.rf_chain = g_cfg.chan_radio[i];
        ifconf.freq_hz  = g_cfg.chan_if[i];
        lgw_rxif_setconf(i, &ifconf);
    }

    memset(&ifconf, 0, sizeof(ifconf));
    ifconf.enable                  = g_cfg.chan_lora_std_enable;
    ifconf.rf_chain                = g_cfg.chan_lora_std_radio;
    ifconf.freq_hz                 = g_cfg.chan_lora_std_if;
    ifconf.bandwidth               = bw_khz_to_enum(g_cfg.chan_lora_std_bw);
    ifconf.datarate                = g_cfg.chan_lora_std_sf;
    ifconf.implicit_hdr            = g_cfg.chan_lora_std_implicit_hdr;
    ifconf.implicit_payload_length = g_cfg.chan_lora_std_implicit_len;
    ifconf.implicit_crc_en         = g_cfg.chan_lora_std_implicit_crc;
    ifconf.implicit_coderate       = str_to_coderate(g_cfg.chan_lora_std_implicit_cr);
    lgw_rxif_setconf(8, &ifconf);

    memset(&ifconf, 0, sizeof(ifconf));
    ifconf.enable         = g_cfg.chan_fsk_enable;
    ifconf.rf_chain       = g_cfg.chan_fsk_radio;
    ifconf.freq_hz        = g_cfg.chan_fsk_if;
    ifconf.bandwidth      = bw_khz_to_enum(g_cfg.chan_fsk_bw);
    ifconf.datarate       = g_cfg.chan_fsk_datarate;
    ifconf.sync_word_size = g_cfg.chan_fsk_sync_size;
    ifconf.sync_word      = g_cfg.chan_fsk_sync_word;
    lgw_rxif_setconf(9, &ifconf);

    memset(&demodconf, 0, sizeof(demodconf));
    demodconf.multisf_datarate = g_cfg.sf_mask ? g_cfg.sf_mask : LGW_MULTI_SF_EN;
    lgw_demod_setconf(&demodconf);

    if (g_cfg.ftime_enable) {
        struct lgw_conf_ftime_s ftimeconf;
        memset(&ftimeconf, 0, sizeof(ftimeconf));
        ftimeconf.enable = true;
        ftimeconf.mode   = LGW_FTIME_MODE_ALL_SF;
        lgw_ftime_setconf(&ftimeconf);
    }

    return lgw_start();
}

// === LIVE RX PACKET RING BUFFER FOR LUCI ===
#define RX_HIST_MAX 25
typedef struct {
    char     time_hms[16];
    uint32_t tmst;
    uint8_t  chan;
    uint8_t  rfch;
    double   freq_mhz;
    char     datr[16];
    char     codr[8];
    float    rssis;
    float    rssic;
    float    snr;
    float    snr_min;
    float    snr_max;
    int32_t  foff;
    uint16_t size;
    uint16_t crc;
    char     status[12];
    char     hex[514];
    char     b64[360];
} rx_hist_entry_t;

static rx_hist_entry_t g_rx_hist[RX_HIST_MAX];
static int             g_rx_hist_head  = 0;
static int             g_rx_hist_count = 0;
static pthread_mutex_t rx_hist_mutex   = PTHREAD_MUTEX_INITIALIZER;

static void record_rx_packet(const struct lgw_pkt_rx_s *p, const char *hms,
                             const char *datr_str, const char *codr_str,
                             const char *crc_str, const char *b64_str) {
    pthread_mutex_lock(&rx_hist_mutex);
    rx_hist_entry_t *e = &g_rx_hist[g_rx_hist_head];
    memset(e, 0, sizeof(*e));
    strncpy(e->time_hms, hms, sizeof(e->time_hms) - 1);
    e->tmst     = p->count_us;
    e->chan     = p->if_chain;
    e->rfch     = p->rf_chain;
    e->freq_mhz = p->freq_hz / 1e6;
    strncpy(e->datr, datr_str, sizeof(e->datr) - 1);
    strncpy(e->codr, codr_str, sizeof(e->codr) - 1);
    e->rssis    = p->rssis;
    e->rssic    = p->rssic;
    e->snr      = p->snr;
    e->snr_min  = p->snr_min;
    e->snr_max  = p->snr_max;
    e->foff     = p->freq_offset;
    e->size     = p->size;
    e->crc      = p->crc;
    strncpy(e->status, crc_str, sizeof(e->status) - 1);
    strncpy(e->b64, b64_str, sizeof(e->b64) - 1);

    int hex_bytes = p->size > 255 ? 255 : p->size;
    for (int k = 0; k < hex_bytes; k++) {
        snprintf(e->hex + (k * 2), 3, "%02X", p->payload[k]);
    }
    e->hex[hex_bytes * 2] = '\0';

    g_rx_hist_head = (g_rx_hist_head + 1) % RX_HIST_MAX;
    if (g_rx_hist_count < RX_HIST_MAX) g_rx_hist_count++;

    FILE *fp = fopen("/tmp/lora_packets.json.tmp", "w");
    if (fp) {
        fprintf(fp, "[");
        for (int i = 0; i < g_rx_hist_count; i++) {
            int idx = (g_rx_hist_head - 1 - i + RX_HIST_MAX) % RX_HIST_MAX;
            rx_hist_entry_t *it = &g_rx_hist[idx];
            fprintf(fp,
                "%s{\"time\":\"%s\",\"tmst\":%u,\"chan\":%u,\"rfch\":%u,"
                "\"freq\":\"%.4f\",\"datr\":\"%s\",\"codr\":\"%s\","
                "\"rssi\":%.1f,\"rssic\":%.1f,\"snr\":%.1f,"
                "\"snr_min\":%.1f,\"snr_max\":%.1f,\"foff\":%d,"
                "\"size\":%u,\"crc\":%u,\"status\":\"%s\","
                "\"hex\":\"%s\",\"b64\":\"%s\"}",
                (i > 0) ? "," : "",
                it->time_hms, it->tmst, (unsigned)it->chan, (unsigned)it->rfch,
                it->freq_mhz, it->datr, it->codr,
                it->rssis, it->rssic, it->snr,
                it->snr_min, it->snr_max, (int)it->foff,
                (unsigned)it->size, (unsigned)it->crc, it->status,
                it->hex, it->b64);
        }
        fprintf(fp, "]\n");
        fclose(fp);
        rename("/tmp/lora_packets.json.tmp", "/tmp/lora_packets.json");
    }
    pthread_mutex_unlock(&rx_hist_mutex);
}

static bool wait_tx_free(uint8_t rf_chain, int timeout_ms) {
    uint8_t tx_status;
    for (int waited = 0; waited < timeout_ms; waited++) {
        pthread_mutex_lock(&hal_mutex);
        lgw_status(rf_chain, TX_STATUS, &tx_status);
        pthread_mutex_unlock(&hal_mutex);
        if (tx_status == TX_FREE)
            return true;
        usleep(1000);
    }
    return false;
}

static void *thread_rx_loop(void *arg) {
    (void)arg;
    struct lgw_pkt_rx_s rxpkt[16];
    char json_buf[1536];
    char b64[400];
    g_consec_err = 0;

    printf("[RX] Thread started.\n");

    while (!g_quit) {
        pthread_mutex_lock(&hal_mutex);
        int nb_pkt = lgw_receive(16, rxpkt);
        pthread_mutex_unlock(&hal_mutex);

        if (nb_pkt == LGW_HAL_ERROR) {
            g_consec_err++;
            printf("[RX] lgw_receive() error (%d/10) — retrying.\n", g_consec_err);
            if (g_consec_err >= 10) {
                printf("[WATCHDOG] 10 consecutive HAL errors — resetting SX1302 concentrator...\n");
                pthread_mutex_lock(&hal_mutex);
                lgw_stop();
                usleep(200000);
                int r = configure_and_start_sx1302();
                pthread_mutex_unlock(&hal_mutex);
                if (r == LGW_HAL_SUCCESS) {
                    printf("[WATCHDOG] SX1302 concentrator recovered and resumed!\n");
                    g_consec_err = 0;
                } else {
                    printf("[WATCHDOG] SX1302 recovery failed — requesting full daemon restart.\n");
                    g_quit = 1;
                    break;
                }
            }
            usleep(100000);
            continue;
        }
        g_consec_err = 0;

        for (int i = 0; i < nb_pkt; i++) {
            struct lgw_pkt_rx_s *p = &rxpkt[i];
            struct timespec ts;
            clock_gettime(CLOCK_REALTIME, &ts);
            char time_str[28];
            char hms_str[16];
            struct tm *tm_info = gmtime(&ts.tv_sec);
            strftime(time_str, sizeof(time_str), "%Y-%m-%dT%H:%M:%S", tm_info);
            strftime(hms_str,  sizeof(hms_str),  "%H:%M:%S",          tm_info);

            bin_to_b64(p->payload, (int)p->size, b64, (int)sizeof(b64));

            const char *modu_str;
            char datr_str[16];
            const char *codr_str = "";
            if (p->modulation == MOD_LORA) {
                modu_str = "LORA";
                int bw_khz = (p->bandwidth == BW_125KHZ) ? 125 :
                             (p->bandwidth == BW_250KHZ)  ? 250 : 500;
                snprintf(datr_str, sizeof(datr_str), "SF%uBW%d", p->datarate, bw_khz);
                switch (p->coderate) {
                    case CR_LORA_4_5: codr_str = "4/5"; break;
                    case CR_LORA_4_6: codr_str = "4/6"; break;
                    case CR_LORA_4_7: codr_str = "4/7"; break;
                    case CR_LORA_4_8: codr_str = "4/8"; break;
                    default:          codr_str = "";    break;
                }
            } else {
                modu_str = "FSK";
                snprintf(datr_str, sizeof(datr_str), "%u", p->datarate);
            }

            int stat_val = (p->status == STAT_CRC_OK)  ?  1 :
                           (p->status == STAT_CRC_BAD) ? -1 : 0;

            char ext_buf[160] = "";
            if (g_cfg.ext_rx_metadata) {
                if (p->ftime_received) {
                    snprintf(ext_buf, sizeof(ext_buf),
                        ",\"snr_min\":%.1f,\"snr_max\":%.1f,\"crc\":%u,\"ftime\":%u",
                        p->snr_min, p->snr_max, (unsigned)p->crc, p->ftime);
                } else {
                    snprintf(ext_buf, sizeof(ext_buf),
                        ",\"snr_min\":%.1f,\"snr_max\":%.1f,\"crc\":%u",
                        p->snr_min, p->snr_max, (unsigned)p->crc);
                }
            }

            uint32_t uplink_seq = next_uplink_seq();
            uint64_t uplink_ts_ms = (uint64_t)ts.tv_sec * 1000ULL + (uint64_t)(ts.tv_nsec / 1000000L);
            int json_len = snprintf(json_buf, sizeof(json_buf),
                "{\"v\":2,\"msg_type\":\"uplink\","
                "\"gateway_id\":\"%016llX\",\"seq\":%u,\"boot\":%u,\"ts_ms\":%llu,"
                "\"rxpk\":[{"
                "\"tmst\":%u,"
                "\"time\":\"%s.%06ldZ\","
                "\"chan\":%u,"
                "\"rfch\":%u,"
                "\"freq\":%.6f,"
                "\"mid\":%u,"
                "\"stat\":%d,"
                "\"modu\":\"%s\","
                "\"datr\":\"%s\","
                "\"codr\":\"%s\","
                "\"rssis\":%.1f,"
                "\"lsnr\":%.1f,"
                "\"foff\":%d,"
                "\"rssi\":%.1f%s,"
                "\"size\":%u,"
                "\"data\":\"%s\""
                "}]}",
                (unsigned long long)g_gateway_eui, (unsigned)uplink_seq,
                (unsigned)g_boot_id,
                (unsigned long long)uplink_ts_ms,
                p->count_us, time_str, (long)(ts.tv_nsec / 1000),
                (unsigned)p->if_chain, (unsigned)p->rf_chain,
                p->freq_hz / 1e6, (unsigned)p->modem_id, stat_val,
                modu_str, datr_str, codr_str, p->rssis, p->snr, p->freq_offset,
                p->rssic, ext_buf, (unsigned)p->size, b64);

            if (json_len > 0 && json_len < (int)sizeof(json_buf))
                send_reliable(json_buf, (size_t)json_len, uplink_seq);

            pthread_mutex_lock(&stats_mutex);
            stat_rx_count++;
            if (p->status == STAT_CRC_BAD) stat_crc_err++;
            pthread_mutex_unlock(&stats_mutex);
            g_led_rx_blink = 1;

            const char *crc_str = (p->status == STAT_CRC_OK)  ? "CRC_OK"  :
                                  (p->status == STAT_CRC_BAD) ? "CRC_BAD" : "NO_CRC";
            record_rx_packet(p, hms_str, datr_str, codr_str, crc_str, b64);
            printf("[RX] %u bytes | %s | %.4f MHz | RSSI %.1f dBm | SNR %.1f dB | %s\n",
                   p->size, datr_str, p->freq_hz / 1e6, p->rssis, p->snr, crc_str);
        }

        if (nb_pkt == 0)
            usleep(5000);
    }

    printf("[RX] Thread exiting.\n");
    return NULL;
}

static void link_reply(const char *text, const struct sockaddr_in *src, socklen_t slen) {
    sendto(sock_down, text, strlen(text), 0, (const struct sockaddr *)src, slen);
}

static void send_tx_ack(const char *id, const char *status, const struct sockaddr_in *src) {
    if (!id || !id[0]) return;
    char m[240];
    snprintf(m, sizeof(m), "{\"v\":%d,\"msg_type\":\"tx_ack\",\"gateway_id\":\"%016llX\",\"request_id\":\"%s\",\"status\":\"%s\"}",
             LINK_VERSION, (unsigned long long)g_gateway_eui, id, status);
    link_reply(m, src, sizeof(*src));
}

// Remembers recent request ids, so a repeated command runs only once.
static bool seen_request(const char *id) {
    static char seen[16][40];
    static int  next = 0;
    for (int i = 0; i < 16; i++)
        if (strcmp(seen[i], id) == 0) return true;
    strncpy(seen[next], id, sizeof(seen[next]) - 1);
    seen[next][sizeof(seen[next]) - 1] = '\0';
    next = (next + 1) % 16;
    return false;
}

static void link_auth_required(const struct sockaddr_in *src, socklen_t slen) {
    char m[160];
    snprintf(m, sizeof(m), "{\"v\":%d,\"msg_type\":\"auth_required\",\"gateway_id\":\"%016llX\",\"nonce\":\"%08x\"}",
             LINK_VERSION, (unsigned long long)g_gateway_eui, nonce_current());
    link_reply(m, src, slen);
}

// Checks a datagram from the hub. On success *text points at its JSON.
static bool link_accept(char **text, const struct sockaddr_in *src, socklen_t slen) {
    char *p = *text;
    bool  keyed = g_cfg.link_key[0] != '\0';
    if (strncmp(p, "L2:", 3) != 0) {
        if (keyed) {
            stat_auth_rej++;
            link_auth_required(src, slen);
            return false;
        }
        return true;
    }
    if (strlen(p) < 78 || p[11] != ':' || p[76] != ':') return false;
    if (keyed) {
        uint8_t mac[32];
        char    want[65];
        sha256_ctx c;
        uint8_t k[64] = {0}, ipad[64], opad[64], inner[32];
        size_t  klen = strlen(g_cfg.link_key);
        if (klen > 64) klen = 64;
        memcpy(k, g_cfg.link_key, klen);
        for (int i = 0; i < 64; i++) { ipad[i] = k[i] ^ 0x36; opad[i] = k[i] ^ 0x5c; }
        sha256_init(&c);
        sha256_update(&c, ipad, 64);
        sha256_update(&c, (const uint8_t *)(p + 3), 9);          // "<nonce>:"
        sha256_update(&c, (const uint8_t *)(p + 77), strlen(p + 77));
        sha256_final(&c, inner);
        sha256_init(&c);
        sha256_update(&c, opad, 64);
        sha256_update(&c, inner, 32);
        sha256_final(&c, mac);
        for (int i = 0; i < 32; i++) snprintf(want + i*2, 3, "%02x", mac[i]);
        uint8_t diff = 0;
        for (int i = 0; i < 64; i++) diff |= (uint8_t)(want[i] ^ p[12 + i]);
        if (diff) {
            stat_auth_rej++;
            printf("[LINK] Rejected a command with a wrong signature.\n");
            link_auth_required(src, slen);
            return false;
        }
        char nonce_txt[9];
        memcpy(nonce_txt, p + 3, 8);
        nonce_txt[8] = '\0';
        if (!nonce_known((uint32_t)strtoul(nonce_txt, NULL, 16))) {
            link_auth_required(src, slen);   // correct key, stale nonce: the hub retries
            return false;
        }
    }
    *text = p + 77;
    return true;
}

static bool config_write(const JSON_Value *v) {
    char tmp[256];
    snprintf(tmp, sizeof(tmp), "%s.tmp", g_cfg_path);
    if (json_serialize_to_file_pretty(v, tmp) != JSONSuccess || rename(tmp, g_cfg_path) != 0) {
        printf("[CONFIG-IN] Atomic config write failed: %s\n", strerror(errno));
        return false;
    }
    return true;
}

static void handle_get_config(JSON_Object *obj, const char *rid, const struct sockaddr_in *src, socklen_t slen) {
    char head[640];
    snprintf(head, sizeof(head),
        "{\"v\":%d,\"msg_type\":\"config_resp\",\"gateway_id\":\"%016llX\",\"request_id\":\"%s\","
        "\"rf0_freq\":%u,\"rf1_freq\":%u,\"sync_word\":\"%s\",\"tx_power\":%d,\"target_ip\":\"%s\","
        "\"port_up\":%u,\"port_down\":%u,\"status_port\":%u,\"link\":%d,\"model\":\"%s\",\"engine\":\"%s\"",
        LINK_VERSION, (unsigned long long)g_gateway_eui, rid ? rid : "",
        g_rf0_freq, g_rf1_freq, (g_sync_word == 0x34) ? "public" : "private",
        g_cfg.tx_default_power, g_cfg.target_ip,
        g_cfg.port_up, g_cfg.port_down, g_cfg.status_port, LINK_VERSION, GATEWAY_MODEL, ENGINE_VERSION);

    char *file = NULL;
    if (json_object_get_boolean(obj, "full") == 1) {
        JSON_Value *f = json_parse_file(g_cfg_path);
        if (f) {
            json_object_remove(json_value_get_object(f), "link_key");
            file = json_serialize_to_string(f);
            json_value_free(f);
        }
    }
    size_t need = strlen(head) + (file ? strlen(file) : 0) + 16;
    char  *msg  = malloc(need);
    if (msg) {
        if (file) snprintf(msg, need, "%s,\"config\":%s}", head, file);
        else      snprintf(msg, need, "%s}", head);
        link_reply(msg, src, slen);
        free(msg);
    }
    if (file) json_free_serialized_string(file);
}

static void config_ack(const char *rid, const char *status, const char *message, const struct sockaddr_in *src, socklen_t slen) {
    char ack[512];
    snprintf(ack, sizeof(ack),
        "{\"v\":%d,\"msg_type\":\"config_ack\",\"gateway_id\":\"%016llX\",\"request_id\":\"%s\",\"status\":\"%s\",\"message\":\"%s\","
        "\"rf0_freq\":%u,\"rf1_freq\":%u,\"sync_word\":\"%s\",\"tx_power\":%d}",
        LINK_VERSION, (unsigned long long)g_gateway_eui, rid ? rid : "", status, message,
        g_rf0_freq, g_rf1_freq, (g_sync_word == 0x34) ? "public" : "private", g_cfg.tx_default_power);
    link_reply(ack, src, slen);
}

// Merges the given settings into the config file and restarts the radio. If
// the radio will not start with them, the previous settings are put back, so
// a bad push can never strand a remote gateway.
static void handle_set_config(JSON_Object *obj, const char *rid, const struct sockaddr_in *src, socklen_t slen) {
    JSON_Object *in = json_object_get_object(obj, "config");
    if (!in) return;
    if (rid && seen_request(rid)) return;
    JSON_Value *fval = json_parse_file(g_cfg_path);
    if (!fval) {
        config_ack(rid, "error", "The config file on the gateway cannot be read", src, slen);
        return;
    }
    JSON_Value  *prev = json_value_deep_copy(fval);
    JSON_Object *fobj = json_value_get_object(fval);
    for (size_t i = 0; i < json_object_get_count(in); i++) {
        const char *name = json_object_get_name(in, i);
        if (strcmp(name, "link_key") == 0) continue;
        json_object_set_value(fobj, name, json_value_deep_copy(json_object_get_value(in, name)));
    }
    if (!config_write(fval)) {
        json_value_free(fval);
        json_value_free(prev);
        config_ack(rid, "error", "The config file on the gateway cannot be written", src, slen);
        return;
    }
    json_value_free(fval);

    uint16_t old_down = g_cfg.port_down, old_status = g_cfg.status_port;
    printf("[CONFIG-IN] Remote configuration saved. Reinitializing SX1302 in-process...\n");
    pthread_mutex_lock(&hal_mutex);
    lgw_stop();
    usleep(200000);
    load_config(g_cfg_path);
    int r = configure_and_start_sx1302();
    bool restored = false;
    if (r != LGW_HAL_SUCCESS && prev && config_write(prev)) {
        printf("[CONFIG-IN] The radio rejected the new settings. Restoring the previous ones.\n");
        lgw_stop();
        usleep(200000);
        load_config(g_cfg_path);
        r = configure_and_start_sx1302();
        restored = true;
    }
    pthread_mutex_unlock(&hal_mutex);
    if (prev) json_value_free(prev);

    pthread_mutex_lock(&sock_mutex);
    resolve_dest_addr();
    pthread_mutex_unlock(&sock_mutex);

    if (restored) {
        config_ack(rid, "error", "The radio rejected these settings. The previous settings were restored", src, slen);
    } else if (r != LGW_HAL_SUCCESS) {
        config_ack(rid, "error", "Failed to restart SX1302 HAL", src, slen);
    } else {
        config_ack(rid, "ok", "SX1302 reconfigured and restarted in-process", src, slen);
    }
    send_gateway_status_json();
    if (g_cfg.port_down != old_down || g_cfg.status_port != old_status) {
        printf("[CONFIG-IN] Network ports changed. Restarting the engine.\n");
        g_quit = 1;
    }
}

// Stores the key shared with the hub. An unpaired engine accepts it from the
// hub that manages it; afterwards only a signed command can change it.
static void handle_set_link_key(JSON_Object *obj, const char *rid, const struct sockaddr_in *src, socklen_t slen) {
    const char *key = json_object_get_string(obj, "key");
    size_t klen = key ? strlen(key) : 0;
    if (klen < 16 || klen >= sizeof(g_cfg.link_key)) {
        config_ack(rid, "error", "Invalid link key", src, slen);
        return;
    }
    JSON_Value *fval = json_parse_file(g_cfg_path);
    if (!fval) {
        config_ack(rid, "error", "The config file on the gateway cannot be read", src, slen);
        return;
    }
    json_object_set_string(json_value_get_object(fval), "link_key", key);
    bool ok = config_write(fval);
    json_value_free(fval);
    if (ok) {
        strncpy(g_cfg.link_key, key, sizeof(g_cfg.link_key) - 1);
        printf("[LINK] Paired with the hub.\n");
    }
    config_ack(rid, ok ? "ok" : "error", ok ? "Paired" : "Cannot save the link key", src, slen);
    send_gateway_status_json();
}

static void *thread_tx_recv(void *arg) {
    (void)arg;
    char pc_buf[8192];
    struct sockaddr_in src_addr;
    socklen_t src_len = sizeof(src_addr);
    struct lgw_pkt_tx_s txpkt;

    struct timeval tv = {1, 0};
    setsockopt(sock_down, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    printf("[TX-RECV] Thread started (JSON Mode).\n");

    while (!g_quit) {
        int n = recvfrom(sock_down, pc_buf, sizeof(pc_buf) - 1, 0,
                         (struct sockaddr *)&src_addr, &src_len);
        if (n <= 0)
            continue;

        pc_buf[n] = '\0';

        char *msg_text = pc_buf;
        if (!link_accept(&msg_text, &src_addr, src_len))
            continue;

        JSON_Value *root_val = json_parse_string(msg_text);
        if (!root_val) {
            printf("[TX-RECV] Ignored non-JSON or corrupted packet.\n");
            continue;
        }

        JSON_Object *obj = json_value_get_object(root_val);
        if (!obj) {
            json_value_free(root_val);
            continue;
        }

        memset(&txpkt, 0, sizeof(txpkt));
        JSON_Value *val;

        // --- COMMANDS FROM THE HUB ---
        const char *cmd = json_object_get_string(obj, "cmd");
        const char *request_id = json_object_get_string(obj, "request_id");
        if (cmd) {
            if (strcmp(cmd, "get_config") == 0)        handle_get_config(obj, request_id, &src_addr, src_len);
            else if (strcmp(cmd, "set_config") == 0)   handle_set_config(obj, request_id, &src_addr, src_len);
            else if (strcmp(cmd, "set_link_key") == 0) handle_set_link_key(obj, request_id, &src_addr, src_len);
            json_value_free(root_val);
            continue;
        }

        // Optional TX abort command: {"abort": true, "rfch": 0}
        if ((val = json_object_get_value(obj, "abort")) &&
            json_value_get_type(val) == JSONBoolean &&
            json_value_get_boolean(val)) {
            uint8_t rfch = g_cfg.tx_default_rfch;
            if ((val = json_object_get_value(obj, "rfch")) && json_value_get_type(val) == JSONNumber)
                rfch = (uint8_t)json_value_get_number(val);
            pthread_mutex_lock(&hal_mutex);
            int r = lgw_abort_tx(rfch);
            pthread_mutex_unlock(&hal_mutex);
            pa_set(0);
            printf("[TX-RECV] Aborted TX on chain %u (res=%d).\n", rfch, r);
            send_tx_ack(request_id, "aborted", &src_addr);
            json_value_free(root_val);
            continue;
        }

        if (request_id && seen_request(request_id)) {   // a retry of a packet we already have
            send_tx_ack(request_id, "queued", &src_addr);
            json_value_free(root_val);
            continue;
        }

        bool imme = true;
        if ((val = json_object_get_value(obj, "imme")) && json_value_get_type(val) == JSONBoolean)
            imme = (json_value_get_boolean(val) != 0);

        // Hardware timestamped Class A/B downlink ("tmst" in us)
        if ((val = json_object_get_value(obj, "tmst")) && json_value_get_type(val) == JSONNumber) {
            txpkt.count_us = (uint32_t)json_value_get_number(val);
            if (!json_object_get_value(obj, "imme"))
                imme = false;
        }

        const char *tx_mode_str = json_object_get_string(obj, "tx_mode");
        if (tx_mode_str && strcmp(tx_mode_str, "on_gps") == 0)
            txpkt.tx_mode = ON_GPS;
        else
            txpkt.tx_mode = imme ? IMMEDIATE : TIMESTAMPED;

        if ((val = json_object_get_value(obj, "freq")) && json_value_get_type(val) == JSONNumber)
            txpkt.freq_hz = (uint32_t)(json_value_get_number(val) * 1e6 + 0.5);
        else
            txpkt.freq_hz = g_cfg.tx_default_freq;

        if ((val = json_object_get_value(obj, "rfch")) && json_value_get_type(val) == JSONNumber)
            txpkt.rf_chain = (uint8_t)json_value_get_number(val);
        else
            txpkt.rf_chain = g_cfg.tx_default_rfch;

        if ((val = json_object_get_value(obj, "powe")) && json_value_get_type(val) == JSONNumber)
            txpkt.rf_power = (int8_t)json_value_get_number(val);
        else
            txpkt.rf_power = g_cfg.tx_default_power;

        const char *modu = json_object_get_string(obj, "modu");
        if (modu && strcmp(modu, "FSK") == 0)     txpkt.modulation = MOD_FSK;
        else if (modu && strcmp(modu, "CW") == 0) txpkt.modulation = MOD_CW;
        else                                      txpkt.modulation = MOD_LORA;

        const char *datr = json_object_get_string(obj, "datr");
        if (datr) {
            if (txpkt.modulation == MOD_LORA) {
                unsigned int sf = g_cfg.tx_default_sf;
                if (sscanf(datr, "SF%u", &sf) == 1)
                    txpkt.datarate = sf;
                else
                    txpkt.datarate = g_cfg.tx_default_sf;

                if      (strstr(datr, "BW125")) txpkt.bandwidth = BW_125KHZ;
                else if (strstr(datr, "BW250")) txpkt.bandwidth = BW_250KHZ;
                else if (strstr(datr, "BW500")) txpkt.bandwidth = BW_500KHZ;
                else                            txpkt.bandwidth = bw_khz_to_enum(g_cfg.tx_default_bandwidth);
            } else {
                txpkt.datarate = (uint32_t)atoi(datr);
                txpkt.bandwidth = bw_khz_to_enum(g_cfg.tx_default_bandwidth);
            }
        } else {
            txpkt.datarate  = g_cfg.tx_default_sf;
            txpkt.bandwidth = bw_khz_to_enum(g_cfg.tx_default_bandwidth);
        }

        const char *codr = json_object_get_string(obj, "codr");
        txpkt.coderate = codr ? str_to_coderate(codr)
                               : str_to_coderate(g_cfg.tx_default_coderate);

        if ((val = json_object_get_value(obj, "ipol")) && json_value_get_type(val) == JSONBoolean)
            txpkt.invert_pol = (json_value_get_boolean(val) != 0);
        else
            txpkt.invert_pol = g_cfg.tx_default_invert;

        if ((val = json_object_get_value(obj, "ncrc")) && json_value_get_type(val) == JSONBoolean)
            txpkt.no_crc = (json_value_get_boolean(val) != 0);
        else
            txpkt.no_crc = false;

        if ((val = json_object_get_value(obj, "prea")) && json_value_get_type(val) == JSONNumber)
            txpkt.preamble = (uint16_t)json_value_get_number(val);
        else
            txpkt.preamble = g_cfg.tx_default_preamble;

        if ((val = json_object_get_value(obj, "nhdr")) && json_value_get_type(val) == JSONBoolean)
            txpkt.no_header = (json_value_get_boolean(val) != 0);
        else
            txpkt.no_header = false;

        if ((val = json_object_get_value(obj, "f_dev")) && json_value_get_type(val) == JSONNumber)
            txpkt.f_dev = (uint8_t)json_value_get_number(val);
        else if (txpkt.modulation == MOD_FSK)
            txpkt.f_dev = 25;

        if ((val = json_object_get_value(obj, "f_off")) && json_value_get_type(val) == JSONNumber)
            txpkt.freq_offset = (int8_t)json_value_get_number(val);

        const char *b64_data = json_object_get_string(obj, "data");
        if (b64_data) {
            int decoded_len = b64_to_bin(b64_data, strlen(b64_data),
                                         txpkt.payload, sizeof(txpkt.payload));
            if (decoded_len < 0) {
                printf("[TX-RECV] Base64 decoding failed for: %s\n", b64_data);
                send_tx_ack(request_id, "bad_payload", &src_addr);
                json_value_free(root_val);
                continue;
            }
            txpkt.size = (uint16_t)decoded_len;
        } else if (txpkt.modulation == MOD_CW) {
            txpkt.size = 0;
        } else {
            printf("[TX-RECV] Missing payload field 'data'\n");
            send_tx_ack(request_id, "bad_payload", &src_addr);
            json_value_free(root_val);
            continue;
        }

        tx_item_t item;
        memset(&item, 0, sizeof(item));
        item.pkt = txpkt;
        item.src = src_addr;
        if (request_id) strncpy(item.id, request_id, sizeof(item.id) - 1);
        json_value_free(root_val);

        if (!txq_push(&txq, &item)) {
            printf("[TX-RECV] Queue full (%d slots) — packet discarded.\n", TX_QUEUE_SIZE);
            pthread_mutex_lock(&stats_mutex);
            stat_tx_queue_drop++;
            pthread_mutex_unlock(&stats_mutex);
            send_tx_ack(item.id, "full", &item.src);
        } else {
            send_tx_ack(item.id, "queued", &item.src);
            printf("[TX-RECV] Queued %u bytes | SF%u | %u Hz (depth now %d).\n",
                   txpkt.size, txpkt.datarate, txpkt.freq_hz, txq_count(&txq));
        }
    }

    printf("[TX-RECV] Thread exiting.\n");
    return NULL;
}

static void *thread_tx_dispatch(void *arg) {
    (void)arg;
    tx_item_t item;

    printf("[TX-DISPATCH] Thread started.\n");

    while (txq_pop(&txq, &item)) {
        struct lgw_pkt_tx_s txpkt = item.pkt;
        uint32_t toa_ms = (txpkt.modulation == MOD_CW) ? 0 : lgw_time_on_air(&txpkt);

        if (!wait_tx_free(txpkt.rf_chain, g_cfg.tx_free_timeout_ms)) {
            printf("[TX-DISPATCH] Timeout waiting for TX_FREE on chain %u.\n", txpkt.rf_chain);
            pthread_mutex_lock(&stats_mutex);
            stat_tx_err++;
            pthread_mutex_unlock(&stats_mutex);
            send_tx_ack(item.id, "busy", &item.src);
            continue;
        }

        pa_set(1);      // PA/LNA switch → TX mode (HIGH)

        pthread_mutex_lock(&hal_mutex);
        int ret = lgw_send(&txpkt);
        pthread_mutex_unlock(&hal_mutex);

        if (ret == LGW_HAL_SUCCESS && txpkt.modulation != MOD_CW) {
            // Wait for actual over-air transmission to finish before releasing PA
            wait_tx_free(txpkt.rf_chain, (int)toa_ms + 500);
            pa_set(0);  // PA/LNA switch → RX mode (LOW)
        } else if (ret != LGW_HAL_SUCCESS) {
            pa_set(0);
        }

        pthread_mutex_lock(&stats_mutex);
        if (ret != LGW_HAL_SUCCESS) {
            stat_tx_err++;
            printf("[TX-DISPATCH] lgw_send() failed.\n");
        } else {
            stat_tx_count++;
            g_led_tx_blink = 1;
            printf("[TX-DISPATCH] Sent %u bytes | SF%u | %u Hz | %d dBm | ToA %u ms\n",
                   txpkt.size, txpkt.datarate, txpkt.freq_hz, txpkt.rf_power, toa_ms);
        }
        pthread_mutex_unlock(&stats_mutex);
        send_tx_ack(item.id, ret == LGW_HAL_SUCCESS ? "sent" : "failed", &item.src);
    }

    printf("[TX-DISPATCH] Thread exiting.\n");
    return NULL;
}

static void *thread_heartbeat(void *arg) {
    (void)arg;
    printf("[HB] Thread started. Interval: %d s.\n", g_cfg.heartbeat_interval_s);

    while (!g_quit) {
        for (int s = 0; s < g_cfg.heartbeat_interval_s && !g_quit; s++)
            sleep(1);
        if (g_quit) break;

        if (g_cfg.mcu_health_check || g_cfg.temp_monitor_enable) {
            pthread_mutex_lock(&hal_mutex);
            if (g_cfg.mcu_health_check) {
                sx1302_update();
            }
            if (g_cfg.temp_monitor_enable) {
                float t = 0.0f;
                if (lgw_get_temperature(&t) == LGW_HAL_SUCCESS) {
                    g_temperature_c = t;
                    g_temp_valid    = true;
                }
            }
            pthread_mutex_unlock(&hal_mutex);
        }

        struct heartbeat_pkt hb;
        hb.pkt_type    = PKT_TYPE_HEARTBEAT;
        hb.gateway_eui = g_gateway_eui;
        hb.uptime_s    = (uint32_t)(time(NULL) - g_start_time);

        pthread_mutex_lock(&stats_mutex);
        hb.rx_count       = stat_rx_count;
        hb.tx_count       = stat_tx_count;
        hb.crc_err_count  = stat_crc_err;
        hb.tx_err_count   = stat_tx_err;
        hb.tx_queue_drop  = stat_tx_queue_drop;
        pthread_mutex_unlock(&stats_mutex);

        hb.tx_queue_depth = (uint8_t)txq_count(&txq);
        hb.sync_word      = g_sync_word;
        hb.rf0_freq       = g_rf0_freq;
        hb.rf1_freq       = g_rf1_freq;

        nonce_rotate();
        send_gateway_status_json();

        printf("[HB] uptime=%us rx=%u tx=%u crc_err=%u tx_err=%u q=%u q_drop=%u temp=%.1fC\n",
               hb.uptime_s, hb.rx_count, hb.tx_count,
               hb.crc_err_count, hb.tx_err_count,
               hb.tx_queue_depth, hb.tx_queue_drop, g_temperature_c);
    }

    printf("[HB] Thread exiting.\n");
    return NULL;
}

// Physical Wiring on Bobcat 300 G285:
// RED   = /sys/class/leds/red:status   (GPIO4_A2)
// GREEN = /sys/class/leds/blue:status  (GPIO4_A0)
// BLUE  = /sys/class/leds/green:status (GPIO4_A1)

#define SYSFS_LED_RED   "/sys/class/leds/red:status"
#define SYSFS_LED_GREEN "/sys/class/leds/blue:status"
#define SYSFS_LED_BLUE  "/sys/class/leds/green:status"

static void rgb_set(int r, int g, int b) {
    int fd;
    fd = open(SYSFS_LED_RED "/brightness", O_WRONLY);
    if (fd >= 0) { write(fd, r ? "1" : "0", 1); close(fd); }
    fd = open(SYSFS_LED_GREEN "/brightness", O_WRONLY);
    if (fd >= 0) { write(fd, g ? "1" : "0", 1); close(fd); }
    fd = open(SYSFS_LED_BLUE "/brightness", O_WRONLY);
    if (fd >= 0) { write(fd, b ? "1" : "0", 1); close(fd); }
}

static void rgb_claim_all(void) {
    int fd;
    fd = open(SYSFS_LED_RED "/trigger", O_WRONLY);
    if (fd >= 0) { write(fd, "none", 4); close(fd); }
    fd = open(SYSFS_LED_GREEN "/trigger", O_WRONLY);
    if (fd >= 0) { write(fd, "none", 4); close(fd); }
    fd = open(SYSFS_LED_BLUE "/trigger", O_WRONLY);
    if (fd >= 0) { write(fd, "none", 4); close(fd); }
    rgb_set(0, 0, 0);
}

static bool g_rgb_leds = false;

static void led_claim(const char *name) {
    if (g_rgb_leds) { rgb_claim_all(); return; }
    if (!name || !name[0]) return;
    char path[128];
    snprintf(path, sizeof(path), "/sys/class/leds/%s/trigger", name);
    int fd = open(path, O_WRONLY);
    if (fd < 0) return;
    write(fd, "none", 4);
    close(fd);
}

static int led_set(const char *name, int on) {
    if (g_rgb_leds) return 1;
    if (!name || !name[0]) return 0;
    char path[128];
    snprintf(path, sizeof(path), "/sys/class/leds/%s/brightness", name);
    int fd = open(path, O_WRONLY);
    if (fd < 0) return 0;
    write(fd, on ? "255" : "0", on ? 3 : 1);
    close(fd);
    return 1;
}

static void *thread_led(void *arg) {
    (void)arg;
    if (!g_rgb_leds) {
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
    rgb_claim_all();

    int rx_timer_ms = 0;
    int tx_timer_ms = 0;
    int hb_tick_ms  = 0;
    const int HB_PERIOD_MS = 1200; // 1.2s per complete heartbeat cycle

    printf("[LED] Industrial RGB State Machine started (Green=Heartbeat, Blue=TX, Red=RX).\n");

    while (!g_quit) {
        // Trigger pulses from RX and TX threads
        if (g_led_rx_blink) {
            g_led_rx_blink = 0;
            rx_timer_ms = 120; // RED flash for 120ms
        }
        if (g_led_tx_blink) {
            g_led_tx_blink = 0;
            tx_timer_ms = 180; // BLUE flash for 180ms
        }

        // Priority 1: Broken / Error States
        if (g_consec_err > 0) {
            // Concentrator error: Fast flashing RED (100ms on, 100ms off)
            bool red_on = ((hb_tick_ms % 200) < 100);
            rgb_set(red_on ? 1 : 0, 0, 0);
        }
        else if (!g_net_ok) {
            // Network destination unreachable / socket fail: Flashing YELLOW (Red + Green)
            bool yel_on = ((hb_tick_ms % 400) < 200);
            rgb_set(yel_on ? 1 : 0, yel_on ? 1 : 0, 0);
        }
        // Priority 2: TX Active -> Pure BLUE
        else if (tx_timer_ms > 0) {
            rgb_set(0, 0, 1); // Blue on, Red off, Green off
            tx_timer_ms -= 20;
        }
        // Priority 3: RX Active -> Pure RED
        else if (rx_timer_ms > 0) {
            rgb_set(1, 0, 0); // Red on, Green off, Blue off
            rx_timer_ms -= 20;
        }
        // Priority 4: Normal Healthy Idle -> GREEN HEARTBEAT
        else {
            // Natural biological double-pulse heartbeat:
            // 0..80ms: ON
            // 80..220ms: OFF
            // 220..300ms: ON
            // 300..1200ms: OFF
            int phase = hb_tick_ms % HB_PERIOD_MS;
            bool green_on = (phase < 80) || (phase >= 220 && phase < 300);
            rgb_set(0, green_on ? 1 : 0, 0);
        }

        usleep(20000); // 20ms resolution
        hb_tick_ms = (hb_tick_ms + 20) % HB_PERIOD_MS;
    }

    // On shutdown, turn off all LEDs
    rgb_set(0, 0, 0);
    return NULL;
}

static void *thread_status_server(void *arg) {
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
        uint32_t rx     = stat_rx_count;
        uint32_t tx     = stat_tx_count;
        uint32_t crcerr = stat_crc_err;
        uint32_t txerr  = stat_tx_err;
        uint32_t qdrop  = stat_tx_queue_drop;
        pthread_mutex_unlock(&stats_mutex);

        uint32_t inst_cnt_us = 0, trig_cnt_us = 0;
        uint8_t  tx_st = 0, rx_st = 0;
        uint8_t  ch_det[8] = {0};
        pthread_mutex_lock(&hal_mutex);
        lgw_get_instcnt(&inst_cnt_us);
        lgw_get_trigcnt(&trig_cnt_us);
        lgw_status(0, TX_STATUS, &tx_st);
        lgw_status(0, RX_STATUS, &rx_st);
        for (int ch = 0; ch < 8; ch++) {
            ch_det[ch] = sx1302_arb_get_debug_stats_detect((uint8_t)ch);
        }
        pthread_mutex_unlock(&hal_mutex);

        const char *tx_st_str = (tx_st == TX_FREE)      ? "TX_FREE"      :
                                (tx_st == TX_SCHEDULED) ? "TX_SCHEDULED" :
                                (tx_st == TX_EMITTING)  ? "TX_EMITTING"  : "TX_OFF";
        const char *rx_st_str = (rx_st == RX_SUSPENDED) ? "RX_SUSPENDED" : "LISTENING";

        char buf[1100];
        int n = snprintf(buf, sizeof(buf),
            "{\"daemon\":\"raw_lora_app (SX1302 8-CH Concentrator)\","
            "\"eui\":\"%016llX\","
            "\"uptime_s\":%u,"
            "\"rx\":%u,\"tx\":%u,"
            "\"crc_err\":%u,\"tx_err\":%u,"
            "\"q_depth\":%u,\"q_drop\":%u,"
            "\"rf0_mhz\":%.6f,\"rf1_mhz\":%.6f,"
            "\"sync\":\"%s\","
            "\"temp_c\":%.1f,\"temp_ok\":%s,"
            "\"inst_cnt_us\":%u,\"trig_cnt_us\":%u,"
            "\"tx_status\":\"%s\",\"rx_status\":\"%s\","
            "\"sf_mask\":%u,"
            "\"link\":%d,\"auth\":%s,\"link_peer\":%s,\"model\":\"%s\",\"engine\":\"%s\",\"port_down\":%u,"
            "\"link_acks\":%u,\"link_retx\":%u,\"link_lost\":%u,\"auth_rej\":%u,"
            "\"ch_detect\":[%u,%u,%u,%u,%u,%u,%u,%u]}\n",
            (unsigned long long)g_gateway_eui,
            (uint32_t)(time(NULL) - g_start_time),
            rx, tx, crcerr, txerr,
            (uint32_t)txq_count(&txq), qdrop,
            g_rf0_freq / 1e6, g_rf1_freq / 1e6,
            g_sync_word == 0x34 ? "public" : "private",
            g_temperature_c, g_temp_valid ? "true" : "false",
            inst_cnt_us, trig_cnt_us,
            tx_st_str, rx_st_str,
            (unsigned)g_cfg.sf_mask,
            LINK_VERSION, g_cfg.link_key[0] ? "true" : "false", g_link_peer ? "true" : "false",
            GATEWAY_MODEL, ENGINE_VERSION, (unsigned)g_cfg.port_down,
            stat_link_acks, stat_link_retx, stat_link_lost, stat_auth_rej,
            ch_det[0], ch_det[1], ch_det[2], ch_det[3],
            ch_det[4], ch_det[5], ch_det[6], ch_det[7]);
        write(cli_fd, buf, n);
        close(cli_fd);
    }

    close(srv_fd);
    printf("[STATUS] Thread exiting.\n");
    return NULL;
}

int main(int argc, char **argv) {
    struct sockaddr_in local_addr;
    pthread_t rx_tid, tx_recv_tid, tx_dispatch_tid, hb_tid, led_tid, status_tid, link_tid;

    setvbuf(stdout, NULL, _IOLBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);

    signal(SIGINT,  sig_handler);
    signal(SIGTERM, sig_handler);

    const char *cfg_path = CONFIG_PATH;
    for (int i = 1; i < argc; i++) {
        if ((strcmp(argv[i], "-c") == 0 || strcmp(argv[i], "--config") == 0) && (i + 1 < argc)) {
            cfg_path = argv[++i];
        }
    }

    g_cfg_path   = cfg_path;
    g_start_time = time(NULL);
    g_boot_id    = random_u32();
    nonce_rotate();
    txq_init(&txq);

    load_config(cfg_path);

    g_rgb_leds = access(SYSFS_LED_RED "/brightness", F_OK) == 0;

    // Initial hardware claim and boot color (CYAN = initializing)
    rgb_claim_all();
    rgb_set(0, 1, 1);

    printf("SX1302 Forwarder — HAL %s\n", lgw_version_info());
    pa_gpio_init();

    // Sockets
    if ((sock_up = socket(AF_INET, SOCK_DGRAM, 0)) < 0) {
        perror("socket(sock_up)");
        return EXIT_FAILURE;
    }
    resolve_dest_addr();

    if ((sock_down = socket(AF_INET, SOCK_DGRAM, 0)) < 0) {
        perror("socket(sock_down)");
        return EXIT_FAILURE;
    }
    int reuse = 1;
    setsockopt(sock_down, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    memset(&local_addr, 0, sizeof(local_addr));
    local_addr.sin_family      = AF_INET;
    local_addr.sin_port        = htons(g_cfg.port_down);
    local_addr.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(sock_down, (const struct sockaddr *)&local_addr, sizeof(local_addr)) < 0) {
        perror("bind(sock_down)");
        return EXIT_FAILURE;
    }

    if (configure_and_start_sx1302() != LGW_HAL_SUCCESS) {
        printf("ERROR: lgw_start() failed.\n");
        rgb_set(1, 0, 0);
        close(sock_up);
        close(sock_down);
        return EXIT_FAILURE;
    }

    if (lgw_get_eui(&g_gateway_eui) != LGW_HAL_SUCCESS)
        printf("WARNING: Could not read gateway EUI.\n");
    printf("Gateway EUI: %016llX\n", (unsigned long long)g_gateway_eui);

    send_gateway_status_json();

    printf("Concentrator started. Launching threads...\n");

    led_claim(g_cfg.led_rx);
    led_claim(g_cfg.led_tx);
    led_set(g_cfg.led_rx, 0);
    led_set(g_cfg.led_tx, 0);

    pthread_create(&rx_tid,          NULL, thread_rx_loop,       NULL);
    pthread_create(&tx_recv_tid,     NULL, thread_tx_recv,       NULL);
    pthread_create(&tx_dispatch_tid, NULL, thread_tx_dispatch,   NULL);
    pthread_create(&hb_tid,          NULL, thread_heartbeat,     NULL);
    pthread_create(&led_tid,         NULL, thread_led,           NULL);
    pthread_create(&status_tid,      NULL, thread_status_server, NULL);
    pthread_create(&link_tid,        NULL, thread_link,          NULL);

    pthread_join(rx_tid,          NULL);
    pthread_join(tx_recv_tid,     NULL);
    pthread_join(tx_dispatch_tid, NULL);
    pthread_join(hb_tid,          NULL);
    pthread_join(led_tid,         NULL);
    pthread_join(status_tid,      NULL);
    pthread_join(link_tid,        NULL);

    printf("Received signal %d — shutting down.\n", (int)g_quit_signal);
    lgw_abort_tx(0);
    pa_gpio_cleanup();
    lgw_stop();
    close(sock_up);
    close(sock_down);
    printf("Done.\n");
    return EXIT_SUCCESS;
}
