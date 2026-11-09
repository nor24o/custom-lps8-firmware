import json
import os
import tempfile
import time
import unittest
from unittest.mock import patch

import bobcat_lora_bridge as bridge


class PipelineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.profile_path = os.path.join(self.temp.name, 'profiles.json')
        with open(self.profile_path, 'w') as f:
            json.dump({'profiles': [{'id': 'test', 'type_id': {'value': 'CAFE'},
                       'serial_id': {'offset': 2, 'length': 4},
                       'counter': {'offset': 6, 'length': 1}}]}, f)
        self.patcher = patch.multiple(bridge, PROFILES_PATH=self.profile_path,
            UNKNOWN_JSON=os.path.join(self.temp.name, 'unknown.json'))
        self.patcher.start()
        self.addCleanup(self.patcher.stop)
        bridge.g_unknown.clear()

    def test_unknown_registry_rotation(self):
        with patch.object(bridge.g_tracker, 'concentrators', {}):
            for index in range(300):
                bridge.remember_unknown(str(index), {'device_id': str(index)})
            bridge.remember_unknown('0', {'device_id': '0'})
            bridge.remember_unknown('300', {'device_id': '300'})
            self.assertEqual(len(bridge.g_unknown), 300)
            self.assertIn('0', bridge.g_unknown)
            self.assertNotIn('1', bridge.g_unknown)

    def test_frequency_join_and_best_gateway(self):
        out = []
        with patch.object(bridge, 'load_config', return_value={'pipeline': {'dedup_window_ms': 50}}):
            dedup = bridge.TTNDeduplicator(window_s=.05, on_joined_callback=out.append)
            try:
                raw = bytes.fromhex('CAFE0102030407')
                for gw, freq, snr in [('one',868.1,1), ('two',868.1,8), ('two',868.3,4)]:
                    dedup.ingest_packet(raw, raw.hex().upper(), freq, 'SF7BW125', -90, snr,
                        gw, gw, '127.0.0.1', 5555, 'test', {'size':len(raw), 'freq':freq})
                time.sleep(.12)
                self.assertEqual(len(out), 1)
                self.assertEqual(len(out[0]['gateways']), 3)
                self.assertEqual(out[0]['best_gateway']['snr'], 8)
            finally:
                dedup.running = False
                dedup.flush_thread.join(timeout=1)

    def test_unrecognized_is_not_forwarded(self):
        entry = {'raw_bytes': b'bad', 'raw_hex': '626164', 'freq':868.1, 'datr':'SF7BW125',
                 'gateways':[{'gateway_id':'test'}], 'best_gateway':{'rssi':-90,'snr':1}, 'raw_pkt':{}}
        with patch.object(bridge, 'push_live_joined_packet') as live, patch.object(bridge, 'emit_udp_json') as output:
            bridge.on_joined_packet(entry)
            self.assertEqual(live.call_args.args[0]['status'], 'unrecognized')
            output.assert_not_called()

    def test_no_counter_does_not_merge_separate_transmissions(self):
        with open(self.profile_path, 'w') as f:
            json.dump({'profiles':[{'id':'legacy','type_id':{'value':'AA0B'}}]}, f)
        out = []
        with patch.object(bridge, 'load_config', return_value={'pipeline': {'dedup_window_ms': 50}}):
            dedup = bridge.TTNDeduplicator(on_joined_callback=out.append)
            try:
                for tmst in (1000, 2000):
                    dedup.ingest_packet(b'\xaa\x0b', 'AA0B', 868.1, 'SF7BW125', -90, 1,
                        'one', 'one', '127.0.0.1', 5555, 'test', {'tmst':tmst})
                time.sleep(.12)
                self.assertEqual(len(out), 2)
            finally:
                dedup.running = False
                dedup.flush_thread.join(timeout=1)

    def test_unknown_forwarded_once_without_persistent_enrollment(self):
        raw = bytes.fromhex('CAFE0102030407')
        gateway = {'gateway_id':'test', 'gateway_name':'test', 'gateway_ip':'127.0.0.1',
                   'gateway_port':5555, 'protocol':'test', 'rssi':-90, 'snr':5}
        entry = {'raw_bytes':raw, 'raw_hex':raw.hex().upper(), 'freq':868.1, 'datr':'SF7BW125',
                 'gateways':[gateway], 'best_gateway':gateway, 'raw_pkt':{}}
        with patch.object(bridge, 'load_config', return_value={'pipeline': {'ha_telemetry_enabled':False}}), \
             patch.object(bridge, 'is_node_registered', return_value=False), \
             patch.object(bridge, 'execute_decoder', return_value=('test','test',{'temperature':20})), \
             patch.object(bridge, 'push_live_joined_packet'), \
             patch.object(bridge.g_tracker, 'record_uplink'), \
             patch.object(bridge, 'record_to_databases') as database, \
             patch.object(bridge, 'emit_udp_json') as output:
            bridge.on_joined_packet(entry)
            self.assertEqual(output.call_count, 1)
            self.assertEqual(output.call_args.args[0]['registration_status'], 'unknown')
            self.assertEqual(output.call_args.args[0]['node_id'], 'CAFE-01020304')
            database.assert_not_called()
            self.assertIn('CAFE-01020304', bridge.g_unknown)


if __name__ == '__main__':
    unittest.main()
