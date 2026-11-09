import unittest

from packet_profiles import identify_packet, normalize_priorities


class PacketProfileTests(unittest.TestCase):
    def test_identity_and_counter(self):
        profile = {"id": "cafe", "type_id": {"value": "CAFE"},
                   "serial_id": {"offset": 2, "length": 4},
                   "counter": {"offset": 6, "length": 2}}
        identity = identify_packet(bytes.fromhex("CAFE96B840EB0007"), [profile])
        self.assertEqual(identity["device_id"], "CAFE-96B840EB")
        self.assertEqual(identity["counter"], 7)
        self.assertIsNone(identify_packet(bytes.fromhex("FFFF"), [profile]))
        with self.assertRaises(ValueError):
            identify_packet(bytes.fromhex("CAFE96"), [profile])

    def test_priority_and_legacy(self):
        profiles = [{"id": "first", "priority": 1, "type_id": {"value": "AA0B"}},
                    {"id": "second", "priority": 1, "type_id": {"value": "AA0B"}}]
        self.assertEqual([x["priority"] for x in normalize_priorities(profiles)], [1, 2])
        result = identify_packet(bytes.fromhex("AA0B0001"), profiles)
        self.assertEqual((result["profile_id"], result["device_id"]), ("first", "AA0B"))

    def test_checksum(self):
        profile = {"type_id": {"value": "0102"},
                   "checksum": {"algorithm": "sum8", "offset": 2, "length": 1}}
        self.assertIsNotNone(identify_packet(bytes.fromhex("010203"), [profile]))
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            identify_packet(bytes.fromhex("010204"), [profile])


if __name__ == "__main__":
    unittest.main()
