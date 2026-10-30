"""Reproduce the audited static launcher (requires keystone-engine).
Run from any directory: python path/to/src/build_native.py
The output must match the pinned manifest; no device access is performed.
"""
from pathlib import Path
import hashlib
import json
import struct
from keystone import Ks, KS_ARCH_ARM64, KS_MODE_LITTLE_ENDIAN

root = Path(__file__).resolve().parent.parent
source = '\n'.join(line.split('//')[0] for line in (root/'src/launch-uu.S').read_text().splitlines())
code = bytes(Ks(KS_ARCH_ARM64, KS_MODE_LITTLE_ENDIAN).asm(source, addr=0x400080)[0])
ident = b'\x7fELF' + bytes([2, 1, 1, 0]) + bytes(8)
header = struct.pack('<16sHHIQQQIHHHHHH', ident, 2, 183, 1, 0x400080, 64, 0, 0, 64, 56, 1, 0, 0, 0)
segment = struct.pack('<IIQQQQQQ', 1, 5, 0, 0x400000, 0x400000, 128+len(code), 128+len(code), 4096)
blob = header + segment + bytes(8) + code
expected = json.loads((root/'payload/manifest.json').read_text())['launch-uu']
assert hashlib.sha256(blob).hexdigest() == expected, 'Launcher does not match pinned manifest'
assert blob == (root/'payload/launch-uu').read_bytes(), 'Existing launcher differs'
print('STATIC_LAUNCHER_REPRODUCIBLE_OK')
