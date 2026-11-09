"""Configurable identification of custom radio packets, independent of decoding."""

import binascii


def normalize_priorities(profiles):
    """Assign each profile a unique priority, moving collisions upward."""
    used = set()
    result = []
    for profile in profiles:
        item = dict(profile)
        priority = item.get("priority", 1)
        if isinstance(priority, bool) or not isinstance(priority, int) or priority < 0:
            raise ValueError("priority must be a non-negative integer")
        while priority in used:
            priority += 1
        item["priority"] = priority
        used.add(priority)
        result.append(item)
    return result


def _field(payload, spec, name):
    if not isinstance(spec, dict):
        raise ValueError("%s field is required" % name)
    offset, length = spec.get("offset"), spec.get("length")
    if (isinstance(offset, bool) or not isinstance(offset, int) or offset < 0 or
            isinstance(length, bool) or not isinstance(length, int) or length < 1):
        raise ValueError("%s requires a non-negative offset and positive length" % name)
    if offset + length > len(payload):
        raise ValueError("packet is too short for %s" % name)
    return payload[offset:offset + length]


def identify_packet(payload, profiles):
    """Return the first matching profile's identity, or None for no match.

    Profile match is exact hexadecimal type bytes at the configured offset.
    An optional counter is returned as an unsigned big-endian integer. Legacy
    profiles may omit serial, in which case the type is their legacy ID.
    A matched but truncated packet raises ValueError instead of falling through.
    """
    for profile in sorted(normalize_priorities(profiles), key=lambda p: p["priority"]):
        if not profile.get("enabled", True):
            continue
        type_spec = profile.get("type_id", {})
        try:
            expected = bytes.fromhex(type_spec.get("value", ""))
        except (TypeError, ValueError, AttributeError):
            raise ValueError("invalid type ID hex")
        if not expected:
            raise ValueError("type ID value cannot be empty")
        offset = type_spec.get("offset", 0)
        if isinstance(offset, bool) or not isinstance(offset, int) or offset < 0:
            raise ValueError("invalid type ID offset")
        if payload[offset:offset + len(expected)] != expected:
            continue
        checksum = profile.get("checksum")
        if checksum:
            if not isinstance(checksum, dict):
                raise ValueError("checksum must be an object")
            actual = _field(payload, checksum, "checksum")
            start = checksum.get("data_offset", 0)
            end = checksum.get("data_end", checksum.get("offset"))
            if (isinstance(start, bool) or not isinstance(start, int) or start < 0 or
                    isinstance(end, bool) or not isinstance(end, int) or end < start or end > len(payload)):
                raise ValueError("invalid checksum data range")
            algorithm = checksum.get("algorithm")
            if algorithm == "crc32" and len(actual) == 4:
                expected_checksum = (binascii.crc32(payload[start:end]) & 0xffffffff).to_bytes(4, "big")
            elif algorithm == "sum8" and len(actual) == 1:
                expected_checksum = bytes([sum(payload[start:end]) & 0xff])
            else:
                raise ValueError("unsupported checksum algorithm or field length")
            if actual != expected_checksum:
                raise ValueError("checksum mismatch")
        serial_spec = profile.get("serial_id")
        serial = _field(payload, serial_spec, "serial_id").hex().upper() if serial_spec else None
        counter_spec = profile.get("counter")
        counter = int.from_bytes(_field(payload, counter_spec, "counter"), "big") if counter_spec else None
        type_id = expected.hex().upper()
        return {"profile_id": profile.get("id"), "priority": profile["priority"],
                "type_id": type_id, "serial_id": serial,
                "decoder_id": profile.get("decoder_id"),
                "device_id": "%s-%s" % (type_id, serial) if serial else type_id,
                "counter": counter}
    return None
