/**
 * ==============================================================================
 * Class C Always-Listening Actuator Node Reference (Relay / Valve)
 * Compatible with Dragino LPS8 (SX1302) & LG01/LG02 (SX1276)
 *
 * Hardware: ESP32 / Arduino + SX1276 (RFM95) or SX1262 + Relay Module
 * Library:  RadioLib (https://github.com/jgromes/RadioLib)
 *
 * Behavior:
 *   1. Powered via mains, 12V DC, or high-capacity battery/solar.
 *   2. Continuously listens on the configured LoRa frequency (Never sleeps).
 *   3. Captures immediate downlinks dispatched by the Dragino gateway.
 *   4. Actuates relay / valve (GPIO) based on payload (e.g. 0x01, 0x01 = ON).
 *   5. Transmits an instant confirmation ACK uplink back to the gateway.
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

// Pinout for ESP32 + SX1276 (RFM95)
#define NSS_PIN           18
#define DIO0_PIN          26
#define RESET_PIN         14
#define DIO1_PIN          33
#define RELAY_PIN         25       // Output to Relay / MOSFET / Solenoid Valve
#define STATUS_LED_PIN    2        // On-board LED indicator

SX1276 radio = new Module(NSS_PIN, DIO0_PIN, RESET_PIN, DIO1_PIN);

// Flags for interrupt-driven reception
volatile bool packet_received = false;

void IRAM_ATTR onRadioInterrupt() {
    packet_received = true;
}

// Node Configuration (2-Byte Unique Node ID)
#define NODE_ID_HIGH      0x56     // 16-bit Node ID: 0x5678 ("5678")
#define NODE_ID_LOW       0x78

// Device Descriptor Byte:
// Upper Nibble (0x3_) = Class C (Mains / Always Listening)
// Lower Nibble (0x_2) = Actuator / Relay
#define DEV_TYPE_CLASS_C_ACTUATOR 0x32

// ACK Packet Structure sent back to Gateway (7 bytes total)
// [0..1: Node ID] [2: Device Type 0x32] [3: Seq] [4: Channel 1 ID] [5: Channel 1 Type 0x01] [6: State 0x01/0x00]
struct __attribute__((packed)) AckPacket {
    uint8_t  node_id[2];     // 2-byte unique node ID (0x56, 0x78)
    uint8_t  device_type;    // 0x32: Class C Actuator
    uint8_t  seq;            // Rolling sequence counter (0..255)
    uint8_t  ch1_id;         // Channel 1 ID (0x01)
    uint8_t  ch1_type;       // Channel 1 Type: 0x01 (Digital state)
    uint8_t  ch1_state;      // 0x00 = OFF, 0x01 = ON
};

static uint8_t ack_sequence = 0;

void setup() {
    Serial.begin(115200);
    delay(200);
    Serial.println("\n[ACTUATOR] Class C Node Starting...");

    pinMode(RELAY_PIN, OUTPUT);
    pinMode(STATUS_LED_PIN, OUTPUT);
    digitalWrite(RELAY_PIN, LOW);
    digitalWrite(STATUS_LED_PIN, LOW);

    // 1. Initialize Radio
    int state = radio.begin(RF_FREQUENCY, RF_BANDWIDTH, RF_SPREADING, RF_CODING_RATE, RF_SYNC_WORD, RF_OUTPUT_POWER);
    if (state != RADIOLIB_ERR_NONE) {
        Serial.printf("[ERROR] Radio init failed, code: %d\n", state);
        while (true) { delay(1000); }
    }

    // 2. Set Interrupt Handler for Asynchronous Packet Detection
    radio.setDio0Action(onRadioInterrupt, RISING);

    // 3. Start Continuous Receive Mode (Class C)
    state = radio.startReceive();
    if (state != RADIOLIB_ERR_NONE) {
        Serial.printf("[ERROR] Failed to start receive mode, code: %d\n", state);
    } else {
        Serial.println("[RX] Continuous Listening Active on 868.100 MHz SF7...");
    }
}

void loop() {
    if (packet_received) {
        packet_received = false;

        uint8_t rx_buf[64];
        int rx_len = radio.getPacketLength();
        int state = radio.readData(rx_buf, rx_len);

        if (state == RADIOLIB_ERR_NONE) {
            float rssi = radio.getRSSI();
            float snr  = radio.getSNR();
            Serial.printf("\n[RX] Downlink Received (%d bytes) | RSSI=%.1f dBm | SNR=%.1f dB\n", rx_len, rssi, snr);
            
            Serial.print("[RX] Payload: ");
            for (int i = 0; i < rx_len; i++) Serial.printf("%02X ", rx_buf[i]);
            Serial.println();

            uint8_t new_state = 0;
            bool valid_command = false;

            // Command Decoding:
            // 1. Addressed Binary Downlink: [NODE_ID_HIGH, NODE_ID_LOW, 0x01, 0x01/0x00]
            if (rx_len >= 4 && rx_buf[0] == NODE_ID_HIGH && rx_buf[1] == NODE_ID_LOW) {
                if (rx_buf[2] == 0x01 && rx_buf[3] == 0x01) {
                    new_state = 1;
                    valid_command = true;
                } else if (rx_buf[2] == 0x01 && rx_buf[3] == 0x00) {
                    new_state = 0;
                    valid_command = true;
                }
            }
            // 2. Direct Binary Downlink: [0x01, 0x01] = ON, [0x01, 0x00] = OFF
            else if (rx_len >= 2 && rx_buf[0] == 0x01 && rx_buf[1] == 0x01) {
                new_state = 1;
                valid_command = true;
            } else if (rx_len >= 2 && rx_buf[0] == 0x01 && rx_buf[1] == 0x00) {
                new_state = 0;
                valid_command = true;
            }

            if (valid_command) {
                digitalWrite(RELAY_PIN, new_state ? HIGH : LOW);
                digitalWrite(STATUS_LED_PIN, new_state ? HIGH : LOW);
                Serial.printf("[ACTUATE] Relay switched -> %s\n", new_state ? "ON" : "OFF");

                // Transmit instant confirmation ACK uplink back to Gateway
                delay(30); // 30ms RX-to-TX turnaround
                ack_sequence++;
                AckPacket ack;
                ack.node_id[0] = NODE_ID_HIGH;
                ack.node_id[1] = NODE_ID_LOW;
                ack.device_type = DEV_TYPE_CLASS_C_ACTUATOR;
                ack.seq = ack_sequence;
                ack.ch1_id = 0x01;
                ack.ch1_type = 0x01; // Digital state
                ack.ch1_state = new_state;

                Serial.printf("[TX] Sending ACK (Node: %02X%02X, Type: 0x%02X, State: %s)...\n",
                              NODE_ID_HIGH, NODE_ID_LOW, DEV_TYPE_CLASS_C_ACTUATOR, new_state ? "ON" : "OFF");
                radio.transmit((uint8_t*)&ack, sizeof(ack));
                Serial.println("[TX] ACK transmission complete.");
            } else {
                Serial.println("[WARN] Unrecognized command payload.");
            }
        }

        // Resume continuous listening immediately
        radio.startReceive();
    }

    delay(10);
}
