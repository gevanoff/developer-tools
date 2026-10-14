"""Read-only Kindle import, verified EPUB export, and explicit folder publication."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import unquote
import xml.etree.ElementTree as ET
import zipfile

FORMATS = {'.kfx', '.azw', '.azw3', '.mobi', '.epub'}
FONT_ALGORITHMS = {'http://www.idpf.org/2008/embedding',
                   'http://ns.adobe.com/pdf/enc#RC'}


def digest(path):
    with Path(path).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix('.tmp')
    temp.write_text(json.dumps(value, indent=2, ensure_ascii=False), encoding='utf-8')
    os.replace(temp, path)


def books(source):
    """Only primary files; never import the components inside .sdr separately."""
    return sorted(p for p in source.rglob('*') if p.is_file()
                  and p.suffix.lower() in FORMATS
                  and not any(part.lower().endswith('.sdr') for part in p.relative_to(source).parts)
                  and not p.is_symlink())


def components(book):
    result = [book]
    sidecar = book.with_suffix('.sdr')
    if sidecar.is_dir():
        result += sorted(p for p in sidecar.rglob('*') if p.is_file())
    extra = book.with_suffix('.azw6')
    if extra.is_file():
        result.append(extra)
    for p in result:
        if p.is_symlink() or not p.resolve().is_relative_to(book.parent.resolve()):
            raise ValueError('Book component escapes its source directory')
    return result


def fingerprint(book):
    h = hashlib.sha256()
    for p in components(book):
        h.update(str(p.relative_to(book.parent)).encode('utf-8'))
        h.update(bytes.fromhex(digest(p)))
    return h.hexdigest()


def resource(base, href):
    name = unquote(href.split('#')[0])
    if not name or '\\' in name or ':' in name:
        raise ValueError('Invalid EPUB resource path')
    path = PurePosixPath(base) / name
    # Resolve ../ within the archive without extracting anything.
    parts = []
    for part in path.parts:
        if part == '..':
            if not parts:
                raise ValueError('EPUB path escapes archive')
            parts.pop()
        elif part == '/':
            raise ValueError('Absolute EPUB resource path')
        elif part != '.':
            parts.append(part)
    return '/'.join(parts)


def validate_epub(path):
    """Structural validation, not a claim of visual fidelity or EPUBCheck compliance."""
    with zipfile.ZipFile(path) as z:
        if len(z.namelist()) != len(set(z.namelist())):
            raise ValueError('Duplicate EPUB archive members')
        if z.testzip() is not None or z.read('mimetype') != b'application/epub+zip':
            raise ValueError('Invalid EPUB ZIP/mimetype')
        if 'META-INF/encryption.xml' in z.namelist():
            enc = ET.fromstring(z.read('META-INF/encryption.xml'))
            methods = enc.findall('.//{*}EncryptionMethod')
            if not methods or any(m.get('Algorithm') not in FONT_ALGORITHMS for m in methods):
                raise ValueError('EPUB still contains encrypted resources')
        container = ET.fromstring(z.read('META-INF/container.xml'))
        rootfile = container.find('.//{*}rootfile')
        if rootfile is None:
            raise ValueError('EPUB has no package document')
        opf_path = resource('', rootfile.attrib['full-path'])
        opf = ET.fromstring(z.read(opf_path))
        manifest = {i.attrib['id']: i for i in opf.findall('./{*}manifest/{*}item')}
        spine = opf.findall('./{*}spine/{*}itemref')
        if not spine:
            raise ValueError('EPUB has no reading order')
        for entry in manifest.values():
            target = resource(str(PurePosixPath(opf_path).parent), entry.attrib['href'])
            if target not in z.namelist():
                raise ValueError('Missing EPUB resource: ' + target)
            if target.endswith('.unknown') or z.read(target) == b'\xa0\xa0\xa0\xa0':
                raise ValueError('Unresolved Kindle image placeholder: ' + target)
        for entry in spine:
            item = manifest.get(entry.attrib['idref'])
            if item is None:
                raise ValueError('Missing EPUB spine item')
            chapter_path = resource(str(PurePosixPath(opf_path).parent), item.attrib['href'])
            chapter = ET.fromstring(z.read(chapter_path))
            for node in chapter.iter():
                if node.tag.rsplit('}', 1)[-1] in ('img', 'image'):
                    href = node.get('src') or node.get('href') or node.get('{http://www.w3.org/1999/xlink}href')
                    if href and not href.startswith('data:'):
                        image_path = resource(str(PurePosixPath(chapter_path).parent), href)
                        if image_path not in z.namelist():
                            raise ValueError('Missing page image: ' + image_path)
        title = opf.find('.//{*}metadata/{*}title')
        author = opf.find('.//{*}metadata/{*}creator')
        return {'title': title.text if title is not None else Path(path).stem,
                'author': author.text if author is not None else '', 'spine_items': len(spine)}


def safe_name(value):
    name = re.sub(r'[<>:"/\\|?*\x00-\x1f]', '_', value).strip(' .')[:120]
    return name or 'Book'


def copy_new(source, target):
    """Never overwrite. Publish only a fully written file."""
    target = Path(target)
    if target.exists():
        if digest(source) == digest(target):
            return False
        raise FileExistsError('Different file already exists: ' + str(target))
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix='.epub-', suffix='.tmp', dir=target.parent)
    os.close(fd)
    temp = Path(temp_name)
    try:
        shutil.copyfile(source, temp)
        if digest(temp) != digest(source):
            raise ValueError('Copy verification failed')
        if os.name == 'nt':
            os.rename(temp, target)  # Windows rename refuses an existing target
        else:
            os.link(temp, target)  # equivalent no-overwrite publication on POSIX
    finally:
        temp.unlink(missing_ok=True)
    return True


def execute(args, env, log, serials):
    try:
        proc = subprocess.run([str(a) for a in args], env=env, capture_output=True,
                              encoding='utf-8', errors='replace', timeout=600)
        output = proc.stdout + proc.stderr
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError('Calibre exceeded the 10 minute limit') from exc
    for serial in serials:
        output = output.replace(serial, '[DEVICE SERIAL]')
    with log.open('a', encoding='utf-8') as f:
        f.write(output + '\n')
    if proc.returncode:
        raise RuntimeError('Calibre failed; see ' + str(log))


def convert(args):
    source, state = args.source.resolve(), args.state.resolve()
    config = args.calibre_config.resolve()
    if not source.is_dir() or not config.is_dir():
        raise ValueError('Source and configured Calibre profile must exist')
    if state.is_relative_to(source) or source.is_relative_to(state):
        raise ValueError('State and source directories must be separate')
    if os.name == 'nt' and len(str(state / ('x' * 8) / 'library')) >= 75:
        raise ValueError('Use a shorter state path: Calibre requires library paths under 75 characters')
    calibre = args.calibre_dir.resolve()
    for exe in ('calibredb.exe', 'ebook-convert.exe'):
        if not (calibre / exe).is_file():
            raise ValueError('Missing Calibre executable: ' + exe)
    selected = [b for b in books(source) if args.match.lower() in b.name.lower()]
    # Built-in reference files and personal messages are not purchased reading books.
    selected = [b for b in selected if not any(s in b.name.lower() for s in
                ('kindle_users_guide', 'dictionary', 'personal letter'))]
    if args.limit:
        selected = selected[:args.limit]
    if not selected:
        raise ValueError('No matching books found')
    state.mkdir(parents=True, exist_ok=True)
    lock = state / 'run.lock'
    with lock.open('x') as f:
        f.write(str(os.getpid()))
    try:
        report_path = state / 'manifest.json'
        report = json.loads(report_path.read_text(encoding='utf-8')) if report_path.exists() else {'books': {}}
        env = dict(os.environ, CALIBRE_CONFIG_DIRECTORY=str(config))
        prefs_path = config / 'plugins' / 'dedrm.json'
        prefs = json.loads(prefs_path.read_text(encoding='utf-8')) if prefs_path.exists() else {}
        serials = prefs.get('serials', [])
        failures = 0
        for book in selected:
            key = str(book.relative_to(source))
            print('Processing: ' + book.name, flush=True)
            try:
                fp = fingerprint(book)
                previous = report['books'].get(key, {})
                previous_epub = state / previous.get('epub', '__missing__')
                if (previous.get('fingerprint') == fp and previous.get('status') == 'ready'
                        and previous_epub.is_file() and previous_epub.resolve().is_relative_to(state)
                        and digest(previous_epub) == previous.get('sha256')):
                    try:
                        validate_epub(previous_epub)
                    except (ValueError, KeyError, zipfile.BadZipFile, ET.ParseError):
                        pass  # A stricter validator may invalidate an older result.
                    else:
                        print('  Already verified; skipped.', flush=True)
                        continue
                job = Path(tempfile.mkdtemp(prefix='', dir=state))
                snapshot = job / 'originals'
                snapshot.mkdir()
                for part in components(book):
                    target = snapshot / part.relative_to(book.parent)
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(part, target)
                if fingerprint(snapshot / book.name) != fp or fingerprint(book) != fp:
                    raise ValueError('Source changed during snapshot; retry after download completes')
                log = job / 'conversion.log'
                if book.suffix.lower() == '.epub':
                    candidate = snapshot / book.name
                else:
                    library = job / 'library'
                    execute([calibre / 'calibredb.exe', 'add', snapshot / book.name,
                             '--with-library', library], env, log, serials)
                    imported = [p for p in library.rglob('*') if p.suffix.lower() in FORMATS]
                    if len(imported) != 1:
                        raise ValueError('Import did not produce one readable book (DRM or incomplete KFX); see ' + str(log))
                    candidate = job / 'converted.epub'
                    execute([calibre / 'ebook-convert.exe', imported[0], candidate,
                             '--output-profile', 'tablet'], env, log, serials)
                    azw6 = list(snapshot.rglob('*.azw6'))
                    with zipfile.ZipFile(candidate) as archive:
                        placeholders = any(n.endswith('.unknown') for n in archive.namelist())
                    if placeholders and len(azw6) == 1:
                        repaired = job / 'restored.epub'
                        execute([calibre / 'calibre-debug.exe', '-e',
                                 Path(__file__).with_name('restore_azw6.py'), '--',
                                 azw6[0], candidate, repaired], env, log, serials)
                        candidate = repaired
                meta = validate_epub(candidate)
                content_hash = digest(candidate)
                name = safe_name((meta['title'] or book.stem) + ' - ' + (meta['author'] or 'Unknown'))
                output = state / 'epubs' / (name + ' [' + content_hash[:12] + '].epub')
                copy_new(candidate, output)
                report['books'][key] = dict(meta, status='ready', fingerprint=fp,
                    epub=str(output.relative_to(state)), sha256=content_hash,
                    log=str(log.relative_to(state)))
                print('  Ready: ' + output.name, flush=True)
            except (OSError, ValueError, RuntimeError, KeyError, zipfile.BadZipFile, ET.ParseError) as exc:
                failures += 1
                report['books'][key] = {'status': 'failed', 'error': str(exc)}
                print('  FAILED: ' + str(exc), flush=True)
            atomic_json(report_path, report)
        return 1 if failures else 0
    finally:
        lock.unlink(missing_ok=True)


def publish(args):
    state = args.state.resolve()
    dest = args.destination.resolve()
    if not dest.is_dir():
        raise ValueError('Destination must be an existing folder')
    if dest.is_relative_to(state) or state.is_relative_to(dest):
        raise ValueError('Destination and state directories must be separate')
    report = json.loads((state / 'manifest.json').read_text(encoding='utf-8'))
    ready = [entry for entry in report['books'].values() if entry.get('status') == 'ready']
    if not ready:
        raise ValueError('No verified EPUBs to publish')
    for entry in ready:
        epub = (state / entry['epub']).resolve()
        if not epub.is_relative_to(state) or digest(epub) != entry['sha256']:
            raise ValueError('Output has changed; refusing publication')
        validate_epub(epub)
    for entry in ready:
        epub = state / entry['epub']
        added = copy_new(epub, dest / epub.name)
        print(('Copied: ' if added else 'Already present: ') + epub.name)
    print('Local copy verified. Cloud sync and reader display require separate verification.')
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    scan = commands.add_parser('scan', help='List primary book files without changing them')
    scan.add_argument('--source', type=Path, required=True)
    run = commands.add_parser('convert', help='Snapshot and convert; never upload')
    run.add_argument('--source', type=Path, required=True)
    run.add_argument('--state', type=Path, required=True)
    run.add_argument('--calibre-config', type=Path, required=True)
    run.add_argument('--calibre-dir', type=Path, default=Path('C:/Program Files/Calibre2'))
    run.add_argument('--match', default='')
    run.add_argument('--limit', type=int, default=0)
    pub = commands.add_parser('publish', help='Copy verified EPUBs into an existing local sync folder')
    pub.add_argument('--state', type=Path, required=True)
    pub.add_argument('--destination', type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == 'scan':
            if not args.source.is_dir():
                raise ValueError('Source directory does not exist')
            for book in books(args.source):
                print(book.relative_to(args.source))
            return 0
        if args.command == 'convert':
            if args.limit < 0:
                raise ValueError('Limit must be nonnegative')
            return convert(args)
        return publish(args)
    except (OSError, ValueError, RuntimeError, KeyError, zipfile.BadZipFile, ET.ParseError) as exc:
        print('ERROR: ' + str(exc), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
