import hashlib
import json
from pathlib import Path
import struct
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]/'profiles/skd847n'

class PayloadTests(unittest.TestCase):
    def test_payload_hashes_and_no_embedded_binding(self):
        manifest = json.loads((ROOT/'payload/manifest.json').read_text())
        with zipfile.ZipFile(ROOT/'payload/service.jar') as jar:
            self.assertIn(b'local.ont.uuwol.skd847n', jar.read('META-INF/MANIFEST.MF'))
            self.assertFalse(any(n.endswith(('.sn', '.uuplugin_uuid', 'uu.conf')) for n in jar.namelist()))
            for name in ['uuplugin','xuplugin-guardian']:
                self.assertEqual(hashlib.sha256(jar.read('payload/'+name)).hexdigest(), manifest[name])
        for name in ['service.jar','launch-uu']:
            self.assertEqual(hashlib.sha256((ROOT/'payload'/name).read_bytes()).hexdigest(),manifest[name])

    def test_static_native_helper_fixed_target_and_identity(self):
        data=(ROOT/'payload/launch-uu').read_bytes()
        self.assertEqual(data[:6],b'\x7fELF\x02\x01')
        self.assertEqual(struct.unpack_from('<H',data,18)[0],183)
        self.assertEqual(struct.unpack_from('<H',data,56)[0],1)
        self.assertEqual(struct.unpack_from('<I',data,64)[0],1) # PT_LOAD only; no interpreter.
        self.assertIn(b'/usr/data/uu-wol-skd847n\0',data)
        self.assertIn(b'./uu.conf\0',data)
        self.assertNotIn(b'/bin/sh\0',data)
        source=(ROOT/'src/launch-uu.S').read_text()
        self.assertIn('cmp x0, #107',source)
        self.assertIn('mov w0, #0x2000',source)
        self.assertIn('mov x8, #281',source) # execveat on the validated file descriptor.

if __name__=='__main__':unittest.main()
