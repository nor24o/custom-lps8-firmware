/**
 * ==============================================================================
 * Class A Low-Power Battery Sensor Node Reference
 * Compatible with Dragino LPS8 (SX1302) & LG01/LG02 (SX1276)
 *
 * Hardware: ESP32 / Arduino + SX1276 (RFM95) or SX1262
 * Library:  RadioLib (https://github.com/jgromes/RadioLib)
 *
 * Behavior:
 *   1. Wakes from deep sleep.
 *   2. Reads sensor metrics (e.g. Temperature, Battery Voltage).
 *   3. Transmits LoRa uplink packet with Node ID prefix "AA0B".
 *   4. Enters low-power wait for 1,000 ms (Turnaround Delay).
 *   5. Opens RX1 Receive Window for 500 ms to capture pending downlinks.
 *   6. Executes received commands (if any) and returns to deep sleep.
 * ==============================================================================
 */

#include <RadioLib.h>

// RF Configuration (Must match Gateway config)
#define RF_FREQUENCY      868.100  // MHz
#define RF_BANDWIDTH      125.0    // kHz
#define RF_SPREADING      7        // SF7
#define RF_CODING_RATE    5        // 4/5
#define RF_SYNC_WORD      0x12     // Standard private/public sync word
#define RF_OUTPUT_POWER   14       // dBm

// Turnaround & Window Timings (Class A Standard)
#define RX1_TURNAROUND_MS 1000     // Delay from end-of-TX to start-of-RX
#define RX1_WINDOW_MS     500      // Listen duration
#define SLEEP_INTERVAL_S  60       // Deep sleep interval between sensor readings

// Pinout for ESP32 + SX1276 (RFM95)
#define NSS_PIN           18
#define DIO0_PIN          26
#define RESET_PIN         14
#define DIO1_PIN          33

SX1276 radio = new Module(NSS_PIN, DIO0_PIN, RESET_PIN, DIO1_PIN);

// Sensor Packet Structure (10 bytes total)
// [0..1: Node ID] [2..3: Sequence Number] [4..5: Temperature * 10] [6..7: Voltage (mV)] [8..9: Checksum]
struct __attribute__((packed)) SensorPacket {
    uint8_t  node_id[2];     // 0xAA, 0x0B
    uint16_t seq;            // Packet counter
    int16_t  temp_x10;       // e.g. 245 = 24.5 °C
    uint16_t battery_mv;     // e.g. 3300 = 3.30 V
    uint16_t checksum;
};

RTC_DATA_ATTR uint16_t boot_sequence = 0;

void setup() {
    Serial.begin(115200);
    delay(100);
    Serial.println("\n[NODE] Class A Sensor Waking Up...");

    // 1. Initialize Radio
    int state = radio.begin(RF_FREQUENCY, RF_BANDWIDTH, RF_SPREADING, RF_CODING_RATE, RF_SYNC_WORD, RF_OUTPUT_POWER);
    if (state != RADIOLIB_ERR_NONE) {
        Serial.printf("[ERROR] Radio init failed, code: %d\n", state);
        enterDeepSleep();
    }

    // 2. Sample Telemetry
    boot_sequence++;
    float temp_c = 28.5 + (random(-30, 80) / 10.0); // Simulated or read from DS18B20/SHT31
    uint16_t batt_mv = 3300;                         // Read from ADC voltage divider

    SensorPacket pkt;
    pkt.node_id[0] = 0xAA;
    pkt.node_id[1] = 0x0B;
    pkt.seq = htons(boot_sequence);
    pkt.temp_x10 = htons((int16_t)(temp_c * 10));
    pkt.battery_mv = htons(batt_mv);
    pkt.checksum = htons(0x0FAC);

    Serial.printf("[TX] Sending Uplink #%u: Temp=%.1f°C, Batt=%u mV\n", boot_sequence, temp_c, batt_mv);

    // 3. Transmit Uplink
    state = radio.transmit((uint8_t*)&pkt, sizeof(pkt));
    if (state != RADIOLIB_ERR_NONE) {
        Serial.printf("[ERROR] Transmit failed, code: %d\n", state);
        enterDeepSleep();
    }
    Serial.println("[TX] Uplink complete.");

    // 4. Class A Turnaround Delay (Sleep/Wait 1,000 ms)
    Serial.printf("[RX1] Waiting %u ms turnaround delay...\n", RX1_TURNAROUND_MS);
    delay(RX1_TURNAROUND_MS);

    // 5. Open RX1 Window
    Serial.printf("[RX1] Opening receive window for %u ms...\n", RX1_WINDOW_MS);
    radio.startReceive();
    unsigned long start_listen = millis();
    bool downlink_received = false;

    while (millis() - start_listen < RX1_WINDOW_MS) {
        if (radio.getPacketLength() > 0) {
            uint8_t rx_buf[64];
            int rx_len = radio.getPacketLength();
            state = radio.readData(rx_buf, rx_len);
            if (state == RADIOLIB_ERR_NONE) {
                downlink_received = true;
                Serial.printf("[RX1] Downlink Received (%d bytes)! RSSI=%.1f dBm, SNR=%.1f dB\n",
                              rx_len, radio.getRSSI(), radio.getSNR());
                
                // Process received command
                Serial.print("[RX1] Payload (HEX): ");
                for (int i = 0; i < rx_len; i++) Serial.printf("%02X ", rx_buf[i]);
                Serial.println();

                if (rx_len >= 2 && rx_buf[0] == 0x01 && rx_buf[1] == 0x01) {
                    Serial.println("[COMMAND] Gateway triggered Actuator Activation!");
                }
            }
            break;
        }
        delay(10);
    }

    if (!downlink_received) {
        Serial.println("[RX1] Window closed. No pending downlink.");
    }

    // 6. Return to Deep Sleep
    radio.sleep();
    enterDeepSleep();
}

void enterDeepSleep() {
    Serial.printf("[SLEEP] Entering deep sleep for %u seconds...\n\n", SLEEP_INTERVAL_S);
    esp_sleep_enable_timer_wakeup((uint64_t)SLEEP_INTERVAL_S * 1000000ULL);
    esp_deep_sleep_start();
}

void loop() {
    // Unused in deep sleep architecture
}
