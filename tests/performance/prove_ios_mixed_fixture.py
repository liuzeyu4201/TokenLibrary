#!/usr/bin/env python3
"""Read only the separately installed synthetic iOS performance library.

The preparation manifest and simctl container identity must agree. No application
launch, database write, checkpoint, credential access or GUI action is performed.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import plistlib
import sqlite3
import subprocess
import time


BUNDLE = 'app.tokenlibrary.verification.performance.ios'
SIMULATOR = 'CDC55D3E-C4BB-43A3-B3C1-8789492A1D08'


def digest(data):
    return hashlib.sha256(data).hexdigest()


def rows_at(root):
    connection = sqlite3.connect((root / 'library.sqlite').as_uri() + '?mode=ro', uri=True)
    connection.row_factory = sqlite3.Row
    try:
        connection.execute('PRAGMA query_only=ON')
        connection.execute('BEGIN')
        documents = [dict(row) for row in connection.execute('SELECT * FROM working_documents ORDER BY id')]
        media = [dict(row) for row in connection.execute('SELECT * FROM blob_transfers ORDER BY blob_id')]
        state = dict(connection.execute('SELECT key,value FROM sync_state'))
        operations = [dict(row) for row in connection.execute('SELECT operation_id,object_id,action,state,payload FROM pending_operations ORDER BY operation_id')]
        pages = sum(len(json.loads(row[0])) for row in connection.execute('SELECT pages_json FROM pdf_page_text_cache'))
        indexed_pages = connection.execute("SELECT count(*) FROM search_chunks WHERE source LIKE 'pdf:%'").fetchone()[0]
        connection.rollback()
        return documents, media, state, operations, pages, indexed_pages
    finally:
        connection.close()


def prove(preparation, phase):
    started = datetime.now().astimezone().isoformat()
    timer = time.monotonic()
    report = json.loads(preparation.read_text())
    if report['bundleID'] != BUNDLE or report['simulator'] != SIMULATOR:
        raise ValueError('Only the isolated synthetic performance installation is accepted')
    container = Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container', SIMULATOR, BUNDLE, 'data'], text=True).strip()).resolve()
    if container != Path(report['container']).resolve():
        raise ValueError('Container changed; prepare and review a new identity before sampling')
    app = Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container', SIMULATOR, BUNDLE, 'app'], text=True).strip())
    if plistlib.loads((app / 'Info.plist').read_bytes())['CFBundleIdentifier'] != BUNDLE:
        raise ValueError('Unexpected installed bundle')
    root = container / 'Library/Application Support/TokenLibrary'
    if root.resolve() != Path(report['library']).resolve():
        raise ValueError('Unexpected library path')
    source = Path(report['sourceFixture']).resolve(strict=True)
    if not source.is_relative_to(Path('/tmp').resolve()) or not source.name.startswith('TokenLibrary-Mixed1000-'):
        raise ValueError('Expected a separately generated temporary source fixture')
    current, media, state, operations, pages, indexed_pages = rows_at(root)
    original, original_media, _, original_operations, original_pages, original_indexed_pages = rows_at(source)
    if len(current) != 1014 or len(original) != 1014 or len(media) != 201 or original_operations:
        raise ValueError('Unexpected synthetic fixture cardinality or source queue')
    if any(key in state for key in ('server', 'libraryId', 'epoch')):
        raise ValueError('A server-bound library is outside this offline proof')
    old = {row['id']: row for row in original}
    changes, pdf_paths, media_proof = [], [], []
    media_by_id = {row['blob_id']: row for row in media}
    for row in current:
        prior = old[row['id']]
        fields = [field for field in prior if row[field] != prior[field]]
        if fields:
            changes.append({'id': row['id'], 'name': row['name'], 'fields': fields,
                            'beforeHashes': {field: digest(str(prior[field]).encode()) for field in fields},
                            'afterHashes': {field: digest(str(row[field]).encode()) for field in fields},
                            'reading': {key: json.loads(row['metadata_json']).get(key) for key in ('readingPositions', 'readingStatus')}})
        if row['kind'] == 'pdf':
            expected = (root / media_by_id[row['pdf_blob_id']]['local_path']).resolve(strict=True)
            if not expected.is_relative_to(root.resolve()):
                raise ValueError('Attachment escaped the current library')
            pdf_paths.append({'id': row['id'], 'actual': row['pdf_path'], 'expected': str(expected),
                              'matchesCurrentLibrary': Path(row['pdf_path']).resolve() == expected,
                              'revisionUnchanged': row['revision'] == prior['revision']})
    if media != original_media:
        raise ValueError('Media transfer rows changed')
    for row in media:
        path = (root / row['local_path']).resolve(strict=True)
        if Path(row['local_path']).is_absolute() or not path.is_relative_to(root.resolve()):
            raise ValueError('Media escaped the isolated container')
        raw = path.read_bytes()
        actual = digest(raw)
        if len(raw) != row['size'] or actual != row['sha256']:
            raise ValueError('Media content mismatch')
        media_proof.append({'blobID': row['blob_id'], 'path': row['local_path'], 'bytes': len(raw), 'sha256': actual})
    operation_proof = [{key: value for key, value in row.items() if key != 'payload'} |
                       {'payloadSHA256': digest(row['payload'].encode())} for row in operations]
    return {'phase': phase, 'startedAt': started, 'capturedAt': datetime.now().astimezone().isoformat(),
            'readOnly': True, 'preparation': str(preparation), 'bundleID': BUNDLE,
            'container': str(container), 'library': str(root), 'sourceFixture': str(source),
            'objects': len(current), 'indexedPDFPages': indexed_pages, 'originalIndexedPDFPages': original_indexed_pages,
            'cachedPDFPagesIncludingPriorPathIdentities': pages, 'originalCachedPDFPages': original_pages,
            'serverBindingAbsent': True, 'pendingOperations': operation_proof,
            'mediaVerified': len(media_proof), 'mediaBytes': sum(row['bytes'] for row in media_proof),
            'media': media_proof, 'pdfPaths': pdf_paths,
            'pdfPathsMatchingCurrentLibrary': sum(row['matchesCurrentLibrary'] for row in pdf_paths),
            'allRevisionsUnchanged': all(row['revision'] == old[row['id']]['revision'] for row in current),
            'allMarkdownUnchanged': all(row['markdown'] == old[row['id']]['markdown'] for row in current),
            'changesFromGeneratedFixture': changes, 'proofWorkSeconds': time.monotonic() - timer,
            'scope': 'Resource-path migration and synthetic content proof only; no native UI or latency assertion.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--preparation', required=True, type=Path)
    parser.add_argument('--phase', required=True)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() or not output.is_relative_to(Path('/tmp').resolve()):
        parser.error('Choose a new output file in the temporary directory')
    result = prove(args.preparation.resolve(strict=True), args.phase)
    with output.open('x') as handle:
        json.dump(result, handle, ensure_ascii=False, indent=2)
        handle.write('\n')
    print(json.dumps({key: result[key] for key in ('phase', 'capturedAt', 'objects', 'indexedPDFPages',
          'mediaVerified', 'pdfPathsMatchingCurrentLibrary', 'allRevisionsUnchanged',
          'allMarkdownUnchanged', 'proofWorkSeconds')}, ensure_ascii=False))
    print(output)


if __name__ == '__main__':
    main()
