"""Restore matched AZW6 JPEG-XR pages; run with calibre-debug for its image codec.

Container reference: KevinH's DumpAZW6, MobileRead post 3114050.
Supports one unencrypted RBINCONT resource container with an exact ordered embed
map. Unknown layouts fail closed. No files are extracted from the EPUB archive.
"""
from pathlib import Path, PurePosixPath
import re
import struct
import sys
import xml.etree.ElementTree as ET
import zipfile


def image_records(data):
    if len(data) < 78 or data[60:68] != b'RBINCONT':
        raise ValueError('Not an AZW6 RBINCONT container')
    count = struct.unpack_from('>H', data, 76)[0]
    if 78 + count * 8 > len(data):
        raise ValueError('Truncated AZW6 index')
    offsets = [struct.unpack_from('>I', data, 78 + i * 8)[0] for i in range(count)] + [len(data)]
    if not offsets or offsets[0] < 78 + count * 8 or any(a >= b for a, b in zip(offsets, offsets[1:])):
        raise ValueError('Invalid AZW6 record boundaries')
    records = [data[a:b] for a, b in zip(offsets, offsets[1:])]
    maps = [r for r in records if r.startswith(b'kindle:embed:')]
    if len(maps) != 1:
        raise ValueError('Expected one AZW6 resource map')
    hrefs = maps[0].rstrip(b'\x00').split(b'|')
    ids = []
    for href in hrefs:
        if not href:
            continue
        match = re.fullmatch(rb'kindle:embed:([0-9A-V]+)\?mime=image/vnd.jxr', href)
        if not match:
            raise ValueError('Unsupported AZW6 image mapping')
        ids.append(int(match[1], 32))
    images = {i: r[12:] for i, r in enumerate(records) if r.startswith(b'CRES')
              and len(r) > 16 and r[8:12] == b'\x00\x00\x00\x0c'}
    if list(images) != ids:
        raise ValueError('AZW6 resource indices do not match its embed map')
    if not images or any(not b.startswith(b'II\xbc\x01') for b in images.values()):
        raise ValueError('Unsupported AZW6 image encoding')
    return images


def restore(azw6, source, target):
    from calibre.utils.img import load_jxr_data, image_to_data
    images = image_records(Path(azw6).read_bytes())
    with zipfile.ZipFile(source) as z:
        replacements, payloads = {}, {}
        seen_numbers = set()
        for name in z.namelist():
            if not name.endswith('.unknown'):
                continue
            number = int(PurePosixPath(name).stem)
            if z.read(name) != b'\xa0\xa0\xa0\xa0' or number not in images:
                raise ValueError('EPUB placeholder does not match AZW6: ' + name)
            if number in seen_numbers:
                raise ValueError('Duplicate AZW6 placeholder ID: ' + str(number))
            seen_numbers.add(number)
            dest = str(PurePosixPath(name).with_suffix('.jpeg'))
            if dest in z.namelist():
                raise ValueError('Image filename collision')
            img = load_jxr_data(images[number])
            if img.isNull():
                raise ValueError('JPEG-XR decode failed')
            converted = image_to_data(img, fmt='JPEG', compression_quality=95)
            if not converted.startswith(b'\xff\xd8'):
                raise ValueError('JPEG conversion failed')
            replacements[name] = dest
            payloads[dest] = converted
        if not replacements or seen_numbers != set(images):
            raise ValueError('Incomplete match between AZW6 pages and EPUB placeholders')
        container = ET.fromstring(z.read('META-INF/container.xml'))
        opf_name = container.find('.//{*}rootfile').attrib['full-path']
        with zipfile.ZipFile(target, 'x') as out:
            for info in z.infolist():
                name = info.filename
                if name in replacements:
                    out.writestr(replacements[name], payloads[replacements[name]], compress_type=zipfile.ZIP_DEFLATED)
                    continue
                content = z.read(name)
                if name.endswith(('.html', '.xhtml', '.css', '.opf', '.ncx')):
                    for old, new in replacements.items():
                        content = content.replace(PurePosixPath(old).name.encode(), PurePosixPath(new).name.encode())
                    if name == opf_name:
                        root = ET.fromstring(content)
                        for item in root.findall('./{*}manifest/{*}item'):
                            if PurePosixPath(item.get('href', '')).name in {PurePosixPath(v).name for v in replacements.values()}:
                                item.set('media-type', 'image/jpeg')
                        content = ET.tostring(root, encoding='utf-8', xml_declaration=True)
                out.writestr(info, content)
    print('Restored %d matched page images from AZW6.' % len(replacements))


if __name__ == '__main__':
    restore(*sys.argv[1:])
