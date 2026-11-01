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
// --------------------------------------

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
static uint8_t  g_sync_word   = 0x12;
static uint32_t g_rf0_freq    = 0;
static uint32_t g_rf1_freq    = 0;

static pthread_mutex_t stats_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t hal_mutex   = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t sock_mutex  = PTHREAD_MUTEX_INITIALIZER;
static bool            g_net_ok    = true;
static uint32_t stat_rx_count      = 0;
static uint32_t stat_tx_count      = 0;
static uint32_t stat_crc_err       = 0;
static uint32_t stat_tx_err        = 0;
static uint32_t stat_tx_queue_drop = 0;

static volatile sig_atomic_t g_quit        = 0;
static volatile sig_atomic_t g_quit_signal = 0;

static volatile int g_led_rx_blink = 0;
static volatile int g_led_tx_blink = 0;

typedef struct {
    struct lgw_pkt_tx_s entries[TX_QUEUE_SIZE];
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

static bool txq_push(tx_queue_t *q, const struct lgw_pkt_tx_s *pkt) {
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

static bool txq_pop(tx_queue_t *q, struct lgw_pkt_tx_s *pkt) {
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
        struct boot_pkt boot;
        memset(&boot, 0, sizeof(boot));
        boot.pkt_type    = PKT_TYPE_BOOT;
        boot.gateway_eui = g_gateway_eui;
        strncpy(boot.hal_version, lgw_version_info(), sizeof(boot.hal_version) - 1);
        sendto(sock_up, &boot, sizeof(boot), 0,
               (const struct sockaddr *)&dest_addr, sizeof(dest_addr));
    }
    pthread_mutex_unlock(&sock_mutex);
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
    char     hex[68];
    char     b64[360];
} rx_hist_entry_t;

static rx_hist_entry_t g_rx_hist[RX_HIST_MAX];
static int             g_rx_hist_head  = 0;
static int             g_rx_hist_count = 0;
static pthread_mutex_t rx_hist_mutex   = PTHREAD_MUTEX_INITIALIZER;
static float           g_temperature_c = 0.0f;
static bool            g_temp_valid    = false;

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

    int hex_bytes = p->size > 32 ? 32 : p->size;
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
    int consec_err = 0;

    printf("[RX] Thread started.\n");

    while (!g_quit) {
        pthread_mutex_lock(&hal_mutex);
        int nb_pkt = lgw_receive(16, rxpkt);
        pthread_mutex_unlock(&hal_mutex);

        if (nb_pkt == LGW_HAL_ERROR) {
            consec_err++;
            printf("[RX] lgw_receive() error (%d/10) — retrying.\n", consec_err);
            if (consec_err >= 10) {
                printf("[WATCHDOG] 10 consecutive HAL errors — resetting SX1302 concentrator...\n");
                pthread_mutex_lock(&hal_mutex);
                lgw_stop();
                usleep(200000);
                int r = configure_and_start_sx1302();
                pthread_mutex_unlock(&hal_mutex);
                if (r == LGW_HAL_SUCCESS) {
                    printf("[WATCHDOG] SX1302 concentrator recovered and resumed!\n");
                    consec_err = 0;
                } else {
                    printf("[WATCHDOG] SX1302 recovery failed — requesting full daemon restart.\n");
                    g_quit = 1;
                    break;
                }
            }
            usleep(100000);
            continue;
        }
        consec_err = 0;

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

            int json_len = snprintf(json_buf, sizeof(json_buf),
                "{\"rxpk\":[{"
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
                p->count_us, time_str, (long)(ts.tv_nsec / 1000),
                (unsigned)p->if_chain, (unsigned)p->rf_chain,
                p->freq_hz / 1e6, (unsigned)p->modem_id, stat_val,
                modu_str, datr_str, codr_str, p->rssis, p->snr, p->freq_offset,
                p->rssic, ext_buf, (unsigned)p->size, b64);

            send_uplink(json_buf, (size_t)json_len);

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

static void *thread_tx_recv(void *arg) {
    (void)arg;
    char pc_buf[2048];
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

        JSON_Value *root_val = json_parse_string((const char *)pc_buf);
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
                json_value_free(root_val);
                continue;
            }
            txpkt.size = (uint16_t)decoded_len;
        } else if (txpkt.modulation == MOD_CW) {
            txpkt.size = 0;
        } else {
            printf("[TX-RECV] Missing payload field 'data'\n");
            json_value_free(root_val);
            continue;
        }

        json_value_free(root_val);

        if (!txq_push(&txq, &txpkt)) {
            printf("[TX-RECV] Queue full (%d slots) — packet discarded.\n", TX_QUEUE_SIZE);
            pthread_mutex_lock(&stats_mutex);
            stat_tx_queue_drop++;
            pthread_mutex_unlock(&stats_mutex);
        } else {
            printf("[TX-RECV] Queued %u bytes | SF%u | %u Hz (depth now %d).\n",
                   txpkt.size, txpkt.datarate, txpkt.freq_hz, txq_count(&txq));
        }
    }

    printf("[TX-RECV] Thread exiting.\n");
    return NULL;
}

static void *thread_tx_dispatch(void *arg) {
    (void)arg;
    struct lgw_pkt_tx_s txpkt;

    printf("[TX-DISPATCH] Thread started.\n");

    while (txq_pop(&txq, &txpkt)) {
        uint32_t toa_ms = (txpkt.modulation == MOD_CW) ? 0 : lgw_time_on_air(&txpkt);

        if (!wait_tx_free(txpkt.rf_chain, g_cfg.tx_free_timeout_ms)) {
            printf("[TX-DISPATCH] Timeout waiting for TX_FREE on chain %u.\n", txpkt.rf_chain);
            pthread_mutex_lock(&stats_mutex);
            stat_tx_err++;
            pthread_mutex_unlock(&stats_mutex);
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

        send_uplink(&hb, sizeof(hb));

        printf("[HB] uptime=%us rx=%u tx=%u crc_err=%u tx_err=%u q=%u q_drop=%u temp=%.1fC\n",
               hb.uptime_s, hb.rx_count, hb.tx_count,
               hb.crc_err_count, hb.tx_err_count,
               hb.tx_queue_depth, hb.tx_queue_drop, g_temperature_c);
    }

    printf("[HB] Thread exiting.\n");
    return NULL;
}

static void led_claim(const char *name) {
    if (!name || !name[0]) return;
    char path[128];
    snprintf(path, sizeof(path), "/sys/class/leds/%s/trigger", name);
    int fd = open(path, O_WRONLY);
    if (fd < 0) return;
    write(fd, "none", 4);
    close(fd);
}

static int led_set(const char *name, int on) {
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

        char buf[768];
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
            ch_det[0], ch_det[1], ch_det[2], ch_det[3],
            ch_det[4], ch_det[5], ch_det[6], ch_det[7]);
        write(cli_fd, buf, n);
        close(cli_fd);
    }

    close(srv_fd);
    printf("[STATUS] Thread exiting.\n");
    return NULL;
}

int main(void) {
    struct sockaddr_in local_addr;
    pthread_t rx_tid, tx_recv_tid, tx_dispatch_tid, hb_tid, led_tid, status_tid;

    setvbuf(stdout, NULL, _IOLBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);

    signal(SIGINT,  sig_handler);
    signal(SIGTERM, sig_handler);

    g_start_time = time(NULL);
    txq_init(&txq);

    load_config(CONFIG_PATH);

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
        close(sock_up);
        close(sock_down);
        return EXIT_FAILURE;
    }

    if (lgw_get_eui(&g_gateway_eui) != LGW_HAL_SUCCESS)
        printf("WARNING: Could not read gateway EUI.\n");
    printf("Gateway EUI: %016llX\n", (unsigned long long)g_gateway_eui);

    struct boot_pkt boot;
    memset(&boot, 0, sizeof(boot));
    boot.pkt_type    = PKT_TYPE_BOOT;
    boot.gateway_eui = g_gateway_eui;
    strncpy(boot.hal_version, lgw_version_info(), sizeof(boot.hal_version) - 1);
    send_uplink(&boot, sizeof(boot));

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

    pthread_join(rx_tid,          NULL);
    pthread_join(tx_recv_tid,     NULL);
    pthread_join(tx_dispatch_tid, NULL);
    pthread_join(hb_tid,          NULL);
    pthread_join(led_tid,         NULL);
    pthread_join(status_tid,      NULL);

    printf("Received signal %d — shutting down.\n", (int)g_quit_signal);
    lgw_abort_tx(0);
    pa_gpio_cleanup();
    lgw_stop();
    close(sock_up);
    close(sock_down);
    printf("Done.\n");
    return EXIT_SUCCESS;
}
