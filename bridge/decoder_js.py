"""Bounded JavaScript decoding without filesystem, network or Python bindings."""
import json
import sys

sys.path.insert(0, '/opt/lora-python')


def run_script(source, raw_bytes, hex_string, packet=None, condition=False):
    try:
        import quickjs
    except ImportError as exc:
        raise ValueError('JavaScript decoder runtime is not installed') from exc
    if not isinstance(source, str) or len(source) > 65536:
        raise ValueError('JavaScript source must be at most 64 KB')
    context = quickjs.Context()
    context.set_memory_limit(4 * 1024 * 1024)
    context.set_max_stack_size(256 * 1024)
    context.set_time_limit(.05)
    args = ','.join(json.dumps(item, separators=(',', ':')) for item in (list(raw_bytes), hex_string, packet or {}))
    code = 'JSON.stringify((function(bytes,hex,pkt){"use strict";\n' + source + '\n})(' + args + '))'
    try:
        result = context.eval(code)
        if not isinstance(result, str) or len(result) > 65536:
            raise ValueError('Decoder must return JSON-compatible data, at most 64 KB')
        decoded = json.loads(result)
        if condition:
            return bool(decoded)
        if not isinstance(decoded, dict):
            raise ValueError('Decoder must return an object')
        return decoded
    except Exception as exc:
        raise ValueError('JavaScript: ' + str(exc)[:350]) from exc
