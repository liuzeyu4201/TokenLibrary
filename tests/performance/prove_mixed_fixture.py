#!/usr/bin/env python3
"""Read-only content proof for a generated temporary Mixed1000 fixture.

No SQL write, checkpoint, FTS query, application launch, networking or credential
access. Output must be outside the fixture and must not exist. Run outside a GUI
latency sampling interval: hashing media creates measurable local I/O.
"""
import argparse
from collections import Counter
from datetime import datetime
import hashlib
import json
from pathlib import Path
import sqlite3
import time


def sha_file(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def canonical(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False,
                                    separators=(',', ':')).encode()).hexdigest()


def contained(root, relative):
    candidate = root / relative
    if Path(relative).is_absolute() or '..' in Path(relative).parts:
        raise ValueError('Media path must be relative and contained')
    resolved = candidate.resolve(strict=True)
    if not resolved.is_relative_to(root) or candidate.is_symlink():
        raise ValueError('Media must remain within the fixture; symlinks refused')
    return resolved


def compare(before, current):
    old = {x['id']: x for x in before['objects']}
    new = {x['id']: x for x in current['objects']}
    changes = []
    for oid in sorted(old.keys() & new.keys()):
        changed = [key for key in old[oid] if old[oid][key] != new[oid].get(key)]
        if changed:
            changes.append({'id': oid, 'name': new[oid]['name'], 'fields': changed,
                            'before': {k: old[oid][k] for k in changed},
                            'after': {k: new[oid][k] for k in changed}})
    previous_files = {x['blobID']: x for x in before['media']}
    current_files = {x['blobID']: x for x in current['media']}
    return {'addedIDs': sorted(new.keys() - old.keys()),
            'removedIDs': sorted(old.keys() - new.keys()), 'changedObjects': changes,
            'allMediaRecordsAndBytesUnchanged': previous_files == current_files,
            'bodyAndOriginalContentUnchanged': (old.keys() == new.keys() and all(
                old[k]['contentSHA256'] == new[k]['contentSHA256'] for k in old)),
            'queueBefore': before['operationStates'], 'queueAfter': current['operationStates'],
            'note': 'Reading fields and queue changes are reported, not silently accepted. No cleanup is performed.'}


def prove(root, phase, baseline=None):
    started = datetime.now().astimezone().isoformat()
    started_ns = time.monotonic_ns()
    root = root.resolve(strict=True)
    if not root.is_relative_to(Path('/tmp').resolve()) or not root.name.startswith('TokenLibrary-Mixed1000-'):
        raise ValueError('Only an explicitly named temporary Mixed1000 fixture is accepted')
    manifest_path = contained(root, 'performance-manifest.json')
    manifest = json.loads(manifest_path.read_text())
    if (manifest['documents'], manifest['markdown'], manifest['pdf'], len(manifest['media'])) != (1000, 800, 200, 201):
        raise ValueError('Unexpected fixture manifest')
    db = contained(root, 'library.sqlite')
    c = sqlite3.connect(db.as_uri() + '?mode=ro', uri=True)
    c.row_factory = sqlite3.Row
    try:
        c.execute('PRAGMA query_only=ON')
        c.execute('BEGIN')
        state = dict(c.execute('SELECT key,value FROM sync_state'))
        if any(k in state for k in ('server', 'libraryId', 'epoch')):
            raise ValueError('Connected libraries are outside this offline fixture proof')
        rows = [dict(row) for row in c.execute('SELECT * FROM working_documents ORDER BY id')]
        transfers = [dict(row) for row in c.execute('SELECT * FROM blob_transfers ORDER BY blob_id')]
        pending = [dict(row) for row in c.execute('SELECT operation_id,object_id,action,state,payload FROM pending_operations ORDER BY operation_id')]
        counts = dict(Counter(row['kind'] for row in rows))
        table_counts = {table: c.execute('SELECT count(*) FROM ' + table).fetchone()[0] for table in
                        ('remote_documents', 'sync_conflicts', 'editor_drafts', 'search_chunks', 'search_index_state', 'pdf_page_text_cache')}
        logical_hash = canonical(rows)
        c.rollback()
    finally:
        c.close()
    if counts != {'folder': 14, 'md': 800, 'pdf': 200} or len(transfers) != 201:
        raise ValueError('Fixture cardinality changed; preserve evidence and inspect before claiming unchanged')
    transfers_by_id = {r['blob_id']: r for r in transfers}
    media = []
    for record in manifest['media']:
        path = contained(root, record['path'])
        transfer = transfers_by_id[record['blobID']]
        size, digest = path.stat().st_size, sha_file(path)
        if size != record['bytes'] or digest != record['sha256'] or size != transfer['size'] or digest != transfer['sha256']:
            raise ValueError('Media bytes/size/hash mismatch for ' + record['blobID'])
        if transfer['local_path'] != record['path']:
            raise ValueError('Transfer path no longer matches the generated fixture')
        media.append({'blobID': record['blobID'], 'path': record['path'], 'bytes': size, 'sha256': digest, 'mime': transfer['mime']})
    objects = []
    for row in rows:
        metadata = json.loads(row['metadata_json'])
        reading = {k: metadata.pop(k, None) for k in ('readingPositions', 'readingStatus')}
        content = {k: row[k] for k in ('id', 'kind', 'name', 'parent_id', 'state', 'purge_at', 'markdown', 'pdf_blob_id', 'trash_batch_id')}
        content.update(metadata=metadata, assets=json.loads(row['assets_json']), annotations=json.loads(row['annotations_json']))
        if row['kind'] == 'pdf':
            pdf_path = Path(row['pdf_path']).resolve(strict=True)
            if not pdf_path.is_relative_to(root) or pdf_path != contained(root, transfers_by_id[row['pdf_blob_id']]['local_path']):
                raise ValueError('PDF path is not the registered local fixture media')
        objects.append({'id': row['id'], 'kind': row['kind'], 'name': row['name'],
                        'parentID': row['parent_id'], 'revision': row['revision'], 'state': row['state'],
                        'localGeneration': row['local_generation'], 'status': row['status'], 'updatedAt': row['updated_at'],
                        'markdownSHA256': hashlib.sha256(row['markdown'].encode()).hexdigest(),
                        'contentSHA256': canonical(content), 'reading': reading})
    operations = [{'operationID': r['operation_id'], 'objectID': r['object_id'], 'action': r['action'], 'state': r['state'],
                   'payloadSHA256': hashlib.sha256(r['payload'].encode()).hexdigest()} for r in pending]
    op_states = dict(Counter(r['state'] for r in pending))
    result = {'startedAt': started, 'capturedAt': datetime.now().astimezone().isoformat(), 'phase': phase,
              'readOnly': True, 'fixture': str(root), 'database': str(db), 'manifestSHA256': sha_file(manifest_path),
              'originalDatabaseSHA256': manifest['databaseSHA256'], 'databasePhysicalSHA256AtEnd': sha_file(db),
              'logicalWorkingRowsSHA256': logical_hash, 'counts': counts, 'documents': counts['md'] + counts['pdf'],
              'objectsTotal': len(rows), 'allActive': all(x['state'] == 'active' for x in rows),
              'serverBindingAbsent': True, 'tableCounts': table_counts, 'operationStates': op_states,
              'sendableCount': sum(v for k, v in op_states.items() if k in ('pending', 'awaiting_remote', 'needs_edit')),
              'operations': operations, 'mediaVerified': len(media), 'mediaBytes': sum(x['bytes'] for x in media),
              'media': sorted(media, key=lambda x: x['blobID']), 'objects': objects,
              'scope': 'SQLite read transaction and actual file hashing. Physical DB hash is supplemental under WAL; semantic content and reading fields are separate. No UI timing, GUI launch or first-index measurement.'}
    if baseline:
        before = json.loads(baseline.read_text())
        if before['manifestSHA256'] != result['manifestSHA256']:
            raise ValueError('Baseline has a different fixture manifest')
        result['baseline'] = str(baseline.resolve())
        result['comparison'] = compare(before, result)
    result['proofWorkSeconds'] = (time.monotonic_ns() - started_ns) / 1e9
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixture', required=True, type=Path)
    parser.add_argument('--phase', required=True, help='Actual state, e.g. after-launch-before-pdf; not an assumed before-GUI label')
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--baseline', type=Path)
    args = parser.parse_args()
    root = args.fixture.resolve(strict=True)
    destination = args.output.resolve()
    if destination.is_relative_to(root) or destination.exists():
        parser.error('Output must be a new file outside the fixture')
    result = prove(root, args.phase, args.baseline)
    with destination.open('x') as stream:
        json.dump(result, stream, ensure_ascii=False, indent=2)
        stream.write('\n')
    print(json.dumps({k: result[k] for k in ('phase', 'startedAt', 'capturedAt', 'objectsTotal', 'documents', 'mediaVerified', 'mediaBytes', 'operationStates', 'sendableCount', 'proofWorkSeconds')}, ensure_ascii=False))
    print(destination)


if __name__ == '__main__':
    main()
