import json
import struct
from pathlib import Path
import tempfile
from unittest.mock import patch
from types import SimpleNamespace
import unittest
import zipfile

import kindle_transfer as kt
from restore_azw6 import image_records, restore


def epub(path, missing=False, encryption=False, missing_image=False):
    with zipfile.ZipFile(path, 'w') as z:
        z.writestr('mimetype', 'application/epub+zip')
        z.writestr('META-INF/container.xml', '<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>')
        z.writestr('OPS/book.opf', '<package><metadata><title>Test</title><creator>Author</creator></metadata><manifest><item id="c" href="chapter.xhtml"/></manifest><spine><itemref idref="c"/></spine></package>')
        if not missing:
            image = '<img src="absent.jpeg"/>' if missing_image else ''
            z.writestr('OPS/chapter.xhtml', '<html><body><p>A complete sentence.</p>' + image + '</body></html>')
        if encryption:
            z.writestr('META-INF/encryption.xml', '<encryption><EncryptedData><EncryptionMethod Algorithm="AES"/></EncryptedData></encryption>')


class TransferTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='kindle tests ')
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def test_valid_book(self):
        p = self.root / 'A book.epub'
        epub(p)
        self.assertEqual(kt.validate_epub(p)['spine_items'], 1)

    def test_missing_content_rejected(self):
        p = self.root / 'bad.epub'
        epub(p, missing=True)
        with self.assertRaises(ValueError):
            kt.validate_epub(p)

    def test_encryption_rejected(self):
        p = self.root / 'encrypted.epub'
        epub(p, encryption=True)
        with self.assertRaises(ValueError):
            kt.validate_epub(p)

    def test_corruption_rejected(self):
        p = self.root / 'corrupt.epub'
        p.write_bytes(b'not a zip')
        with self.assertRaises(zipfile.BadZipFile):
            kt.validate_epub(p)

    def test_unlisted_missing_page_image_rejected(self):
        p = self.root / 'comic.epub'
        epub(p, missing_image=True)
        with self.assertRaisesRegex(ValueError, 'Missing page image'):
            kt.validate_epub(p)

    def test_azw6_mapping_must_match_resource_indices(self):
        def container(embed_id):
            records = [b'CONT', b'CRES' + struct.pack('>II', 5, 12) + b'II\xbc\x01data',
                       b'kindle:embed:' + embed_id + b'?mime=image/vnd.jxr']
            header = bytearray(78)
            header[60:68] = b'RBINCONT'
            struct.pack_into('>H', header, 76, len(records))
            position = len(header) + len(records) * 8
            for r in records:
                header.extend(struct.pack('>II', position, 0))
                position += len(r)
            return bytes(header) + b''.join(records)
        self.assertEqual(set(image_records(container(b'0001'))), {1})
        with self.assertRaises(ValueError):
            image_records(container(b'0002'))
        with self.assertRaises(ValueError):
            image_records(container(b'0001')[:90])

    def test_companions_and_fingerprints(self):
        p = self.root / 'Book.kfx'
        p.write_bytes(b'primary')
        side = self.root / 'Book.sdr'
        side.mkdir()
        child = side / 'metadata.kfx'
        child.write_bytes(b'component')
        self.assertEqual(kt.books(self.root), [p])
        before = kt.fingerprint(p)
        child.write_bytes(b'changed')
        self.assertNotEqual(before, kt.fingerprint(p))

    def test_publication_repeat_and_conflict(self):
        src, dst = self.root / 'source book.epub', self.root / 'sync folder' / 'book.epub'
        epub(src)
        self.assertTrue(kt.copy_new(src, dst))
        self.assertFalse(kt.copy_new(src, dst))
        original = dst.read_bytes()
        src.write_bytes(b'different')
        with self.assertRaises(FileExistsError):
            kt.copy_new(src, dst)
        self.assertEqual(original, dst.read_bytes())
        self.assertTrue(src.exists())
        self.assertFalse(list(dst.parent.glob('*.tmp')))

    def test_azw6_duplicate_placeholders_rejected(self):
        import sys
        from types import ModuleType
        codec = ModuleType('calibre.utils.img')
        codec.load_jxr_data = lambda data: SimpleNamespace(isNull=lambda: False)
        codec.image_to_data = lambda *args, **kwargs: b'\xff\xd8jpeg'
        source = self.root / 'placeholders.epub'
        with zipfile.ZipFile(source, 'w') as z:
            z.writestr('a/0.unknown', b'\xa0' * 4)
            z.writestr('b/0.unknown', b'\xa0' * 4)
        (self.root / 'unused.azw6').write_bytes(b'dummy')
        with patch.dict(sys.modules, {'calibre': ModuleType('calibre'),
                                      'calibre.utils': ModuleType('calibre.utils'),
                                      'calibre.utils.img': codec}):
            with patch('restore_azw6.image_records', return_value={0: b'a', 1: b'b'}):
                with self.assertRaisesRegex(ValueError, 'Duplicate AZW6 placeholder'):
                    restore(self.root / 'unused.azw6', source, self.root / 'restored.epub')

    def test_paths(self):
        for path in ('../../escape', '/absolute', '//absolute', '%2f%2fabsolute', 'C:/escape', '%2e%2e/%2e%2e/escape'):
            with self.subTest(path=path), self.assertRaises(ValueError):
                kt.resource('OPS', path)
        self.assertEqual(kt.resource('OPS/text', '../image.png'), 'OPS/image.png')

    def test_publish_rejects_tampering_before_copy(self):
        state, destination = self.root / 'state', self.root / 'Drive Books'
        state.mkdir()
        destination.mkdir()
        book = state / 'book.epub'
        epub(book)
        manifest = {'books': {'book': {'status': 'ready', 'epub': 'book.epub',
                                      'sha256': kt.digest(book)}}}
        kt.atomic_json(state / 'manifest.json', manifest)
        book.write_bytes(b'tampered')
        with self.assertRaises(ValueError):
            kt.publish(SimpleNamespace(state=state, destination=destination))
        self.assertEqual(list(destination.iterdir()), [])

    def test_publish_rejects_change_between_preflight_and_copy(self):
        state, destination = self.root / 'state', self.root / 'Drive Books'
        state.mkdir()
        destination.mkdir()
        book = state / 'book.epub'
        epub(book)
        original_sha = kt.digest(book)
        kt.atomic_json(state / 'manifest.json', {'books': {'book': {
            'status': 'ready', 'epub': 'book.epub', 'sha256': original_sha}}})
        real_copy = kt.copy_new
        def mutate_before_copy(source, target, expected_sha256=None):
            source.write_bytes(b'replaced after preflight')
            return real_copy(source, target, expected_sha256)
        with patch.object(kt, 'copy_new', side_effect=mutate_before_copy):
            with self.assertRaisesRegex(ValueError, 'manifest digest mismatch'):
                kt.publish(SimpleNamespace(state=state, destination=destination))
        self.assertEqual(list(destination.iterdir()), [])

    def test_publish_rejects_manifest_escape(self):
        state, destination = self.root / 'state', self.root / 'Drive Books'
        state.mkdir()
        destination.mkdir()
        book = self.root / 'private.epub'
        epub(book)
        kt.atomic_json(state / 'manifest.json', {'books': {'book': {
            'status': 'ready', 'epub': '../private.epub', 'sha256': kt.digest(book)}}})
        with self.assertRaises(ValueError):
            kt.publish(SimpleNamespace(state=state, destination=destination))
        self.assertEqual(list(destination.iterdir()), [])


if __name__ == '__main__':
    unittest.main()
