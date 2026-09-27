#!/usr/bin/env python3
"""Read-only, immutable phase evidence for the owned native epoch fixture.

Does not access Keychain, session tokens, real configuration, GUI or HTTP writes.
Writes only a new proof outside the explicitly supplied synthetic client root.
"""
import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path
import sqlite3
import subprocess
import uuid

from verify_epoch_restore import SQL


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--state', type=Path, required=True)
    p.add_argument('--client-root', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--baseline', type=Path)
    args = p.parse_args()
    state_file = args.state.resolve()
    state = json.loads(state_file.read_text())
    client = args.client_root.resolve()
    destination = args.output.resolve()
    if not state_file.parent.name.startswith('tokenlibrary-native-epoch-') or not state['container'].startswith('tl-native-epoch-'):
        p.error('explicit owned epoch fixture required')
    if 'TokenLibrary-ConnectionFinal-20260927-' not in str(client) or not str(client).startswith('/private/tmp/'):
        p.error('explicit synthetic ConnectionFinal library required')
    if destination.exists() or destination.is_relative_to(client):
        p.error('new output outside client library required')
    for key in ['libraryId', 'epoch', 'baselineNoteId', 'afterBackupNoteId', 'pdfId']:
        uuid.UUID(state[key])
    if state.get('database') not in ['tl', 'restored']:
        p.error('unknown owned database')
    con = sqlite3.connect((client / 'library.sqlite').as_uri() + '?mode=ro', uri=True)
    con.row_factory = sqlite3.Row
    con.execute('PRAGMA query_only=ON')
    con.execute('BEGIN')
    tables = {}
    for table in ['working_documents', 'remote_documents', 'pending_operations', 'sync_conflicts', 'editor_drafts', 'blob_transfers']:
        tables[table] = [dict(row) for row in con.execute('SELECT * FROM ' + table + ' ORDER BY rowid')]
    ids = {row['id'] for row in tables['working_documents']}
    assert state['baselineNoteId'] in ids and state['pdfId'] in ids, 'wrong client library or initial sync incomplete'
    sync = {row['key']: row['value'] for row in con.execute("SELECT key,value FROM sync_state WHERE key IN ('cursor','epoch','library_id','libraryId','server_origin','serverOrigin') ORDER BY key")}
    con.rollback()
    con.close()
    server = json.loads(subprocess.check_output(['docker', 'exec', state['container'], 'psql', '-X', '-U', 'tl', '-d', state['database'],
        '-Atq', '-v', 'ON_ERROR_STOP=1', '-c', SQL], text=True))
    assert server['library']['id'] == state['libraryId'] and server['library']['epoch'] == state['epoch']
    media = []
    for blob in tables['blob_transfers']:
        path = (client / blob['local_path']).resolve()
        if not path.is_relative_to(client):
            raise RuntimeError('media escaped the synthetic library')
        record = {'blobId': blob['blob_id'], 'path': str(path), 'transferState': blob['state'], 'exists': path.is_file()}
        if path.is_file():
            content = path.read_bytes()
            record.update(size=len(content), sha256=hashlib.sha256(content).hexdigest())
            if blob['state'] == 'complete':
                assert record['size'] == blob['size'] and record['sha256'] == blob['sha256']
        media.append(record)
    sendable = [row['operation_id'] for row in tables['pending_operations'] if row['state'] in ['pending', 'awaiting_remote']]
    bodies = {row['id']: {'revision': row['revision'], 'name': row['name'], 'markdownSHA256': hashlib.sha256(row['markdown'].encode()).hexdigest(),
                        'markdown': row['markdown']} for row in tables['working_documents']}
    proof = {'capturedAt': dt.datetime.now().astimezone().isoformat(), 'clientRoot': str(client), 'fixtureState': state['phase'],
             'origin': state['origin'], 'libraryId': state['libraryId'], 'server': server, 'client': tables, 'sync': sync,
             'bodies': bodies, 'media': media, 'sendableOperationIDs': sendable,
             'scope': 'Read-only SQLite transaction, selected non-secret sync keys, PG snapshot/counts (no session rows), synthetic media hashes.'}
    if args.baseline:
        before = json.loads(args.baseline.read_text())
        old_operations = {row['operation_id']: row for row in before['client']['pending_operations']}
        proof['baselineComparison'] = {'path': str(args.baseline.resolve()), 'sameClientRoot': before['clientRoot'] == proof['clientRoot'],
            'sameObjectIDs': set(before['bodies']) == set(bodies), 'sameMedia': before['media'] == media,
            'changedWorkingIDs': [row['id'] for row in tables['working_documents'] if row not in before['client']['working_documents']],
            'operationWiresUnchanged': {row['operation_id']: row['request_json'] == old_operations[row['operation_id']]['request_json'] for row in tables['pending_operations'] if row['operation_id'] in old_operations},
            'newOperationIDs': [row['operation_id'] for row in tables['pending_operations'] if row['operation_id'] not in old_operations]}
    with destination.open('x') as stream:
        json.dump(proof, stream, ensure_ascii=False, indent=2)
        stream.write('\n')
    print(json.dumps({'proof': str(destination), 'at': proof['capturedAt'], 'phase': state['phase'], 'serverEpoch': server['library']['epoch'],
                      'sendable': len(sendable), 'conflictRows': len(tables['sync_conflicts']), 'editorDraftRows': len(tables['editor_drafts']),
                      'revisions': {key: value['revision'] for key, value in bodies.items()}}, ensure_ascii=False))


if __name__ == '__main__':
    main()
