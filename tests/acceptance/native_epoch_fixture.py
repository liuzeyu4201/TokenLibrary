#!/usr/bin/env python3
"""Finite, owned PG17 native-UI restore fixture; starts prepared, never auto-restores.

Business seed writes use the normal upload/operation APIs. SQL captures evidence
and creates an empty restore target only. No existing server, app or credential
store is touched. A separate guarded control invocation is required to restore.
"""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import urllib.request
import uuid

from synthetic_service import SyntheticService, REPO
from verify_epoch_restore import SQL


def now():
    return dt.datetime.now().astimezone().isoformat()


def write(path, value):
    path = Path(path)
    temp = path.with_suffix('.writing')
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    temp.replace(path)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def serve(args):
    output = Path(tempfile.mkdtemp(prefix='tokenlibrary-native-epoch-')).resolve()
    service = SyntheticService(output)
    service.container = 'tl-native-epoch-' + uuid.uuid4().hex[:12]
    run_id = str(uuid.uuid4())
    started = time.monotonic()
    state = {'runId': run_id, 'output': str(output), 'startedAt': now(),
             'deadline': (dt.datetime.now().astimezone() + dt.timedelta(seconds=args.ttl)).isoformat(),
             'phase': 'starting', 'restoreRequested': False, 'supervisorPID': os.getpid(),
             'orchestratorSHA256': sha(__file__)}
    token = None
    print('OUTPUT ' + str(output), flush=True)

    def save():
        state['observedAt'] = now()
        state['appPID'] = service.app.pid if service.app else None
        write(output / 'state.json', state)

    def snapshot(label, database='tl'):
        raw = subprocess.check_output(['docker', 'exec', service.container, 'psql', '-X', '-U', 'tl', '-d', database,
                                       '-Atq', '-v', 'ON_ERROR_STOP=1', '-c', SQL], text=True)
        value = json.loads(raw)
        write(output / (label + '.json'), {'observedAt': now(), 'database': database, 'state': value})
        return value

    def api(method, path, body=None, extra=None):
        headers = {'Content-Type': 'application/json'}
        if token:
            headers.update(Authorization='Bearer ' + token, **{'X-Library-Epoch': state['epoch']})
        headers.update(extra or {})
        data = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode() if body is not None else None
        with urllib.request.urlopen(urllib.request.Request(service.url + path, data=data, headers=headers, method=method), timeout=60) as response:
            return json.load(response)['data']

    def operation(doc, action, desired, revision=None):
        op = str(uuid.uuid4())
        wire = {'protocolVersion': 1, 'operationId': op, 'epoch': state['epoch'], 'deviceId': device,
                'objectId': doc, 'action': action, 'desiredSnapshot': desired}
        if revision is not None:
            wire['base'] = {'source': 'revision', 'revision': revision}
        receipt = api('POST', '/api/v1/sync/operations', wire, {'Idempotency-Key': op})
        assert receipt['status'] == 'committed'
        receipts.append({'wire': wire, 'receipt': receipt})
        write(output / 'seed-operations.json', receipts)

    def upload(filename, mime):
        data = (args.fixtures / filename).read_bytes()
        blob = str(uuid.uuid4())
        digest = hashlib.sha256(data).hexdigest()
        result = api('POST', '/api/v1/uploads', {'blobId': blob, 'size': len(data), 'sha256': digest, 'mime': mime})
        endpoint = '/api/v1/uploads/' + result['uploadId']
        api('PUT', endpoint + '/chunks/0', data, {'X-Chunk-SHA256': digest, 'Content-Type': 'application/octet-stream'})
        api('POST', endpoint + '/complete', {})
        return {'blobId': blob, 'path': 'media/' + blob + Path(filename).suffix, 'sha256': digest, 'size': len(data), 'mime': mime}

    def stop_app():
        if service.app and service.app.poll() is None:
            service.app.terminate()
            try:
                service.app.wait(timeout=8)
            except subprocess.TimeoutExpired:
                service.app.kill()
                service.app.wait(timeout=8)

    def start_app(database, data_root, label):
        service.env.update(DATABASE_URL=source_url.replace('/tl?', '/' + database + '?'), DATA_ROOT=str(data_root))
        log = (output / (label + '-server.log')).open('w')
        service.logs.append(log)
        service.app = subprocess.Popen([str(output / 'tokenlibrary')], cwd=REPO / 'server', env=service.env, stdout=log, stderr=log)
        for _ in range(200):
            if service.app.poll() is not None:
                raise RuntimeError('owned server exited: ' + label)
            try:
                with urllib.request.urlopen(service.url + '/health/ready', timeout=1) as response:
                    ready = json.load(response)
                if ready.get('ready') and not ready.get('maintenance'):
                    jobs = subprocess.check_output(['docker', 'exec', service.container, 'psql', '-X', '-U', 'tl', '-d', database,
                        '-Atq', '-c', "SELECT count(*) FILTER(WHERE state='success'),count(*) FILTER(WHERE state='running') FROM jobs WHERE type='backup'"], text=True).strip()
                    if jobs.endswith('|0') and int(jobs.split('|')[0]) > 0:
                        return
            except OSError:
                pass
            time.sleep(.15)
        raise RuntimeError('owned server readiness timeout: ' + label)

    def restore(request):
        expected = {'runId': run_id, 'origin': service.url, 'libraryId': state['libraryId'], 'epoch': state['epoch'],
                    'backupManifestSHA256': state['backupManifestSHA256'], 'action': 'restore', 'expectedPhase': 'prepared'}
        if request != expected or state['phase'] != 'prepared':
            raise RuntimeError('restore guard mismatch')
        before = snapshot('03-source-before-restore')
        assert before['library']['id'] == state['libraryId'] and before['library']['epoch'] == state['epoch']
        assert sha(backup_path / 'manifest.json') == state['backupManifestSHA256']
        state.update(phase='restoring', restoreRequested=True)
        save()
        stop_app()
        try:
            restore_env = service.env.copy()
            restore_env['RESTORE_DATABASE_URL'] = source_url.replace('/tl?', '/restored?')
            with (output / 'restore.log').open('w') as log:
                subprocess.run([str(output / 'library-admin'), 'restore', '--backup', str(backup_path),
                    '--data-root', str(output / 'restored-data'), '--schema', str(REPO / 'server/schema/initial.sql'),
                    '--database-env', 'RESTORE_DATABASE_URL'], env=restore_env, stdout=log, stderr=log, check=True)
            restored = snapshot('04-restored-before-login', 'restored')
            assert restored['library']['id'] == baseline['library']['id'] and restored['library']['root_id'] == baseline['library']['root_id']
            assert restored['library']['epoch'] != baseline['library']['epoch']
            assert restored['objects'] == baseline['objects'] and restored['blobs'] == baseline['blobs']
            assert restored['sessionCount'] == 0 and restored['operationCount'] == 0
            media = []
            for blob in restored['blobs'] or []:
                paths = [output / root / 'files/objects' / blob['id'][:2] / blob['id'] for root in ['data', 'restored-data']]
                assert [sha(path) for path in paths] == [blob['sha256']] * 2
                assert [path.stat().st_size for path in paths] == [blob['size']] * 2
                media.append({'id': blob['id'], 'size': blob['size'], 'sha256': blob['sha256']})
            start_app('restored', output / 'restored-data', 'restored')
            retained = snapshot('05-original-source-retained')
            assert retained == before
            state.update(phase='restored', oldEpoch=state['epoch'], epoch=restored['library']['epoch'],
                         database='restored', dataRoot=str(output / 'restored-data'), restoredAt=now(), media=media,
                         oldSessionsCleared=True, oldReceiptsCleared=True, sourceDatabaseUnchanged=True)
            save()
            print('RESTORED ' + str(output / 'state.json'), flush=True)
        except BaseException:
            stop_app()
            start_app('tl', output / 'data', 'rollback-source')
            state.update(phase='restore-failed-source-restarted', database='tl', dataRoot=str(output / 'data'))
            save()
            raise

    def interrupted(_signum, _frame):
        raise KeyboardInterrupt()

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        service.start()
        source_url = service.env['DATABASE_URL']
        state.update(origin=service.url, container=service.container, database='tl', dataRoot=str(output / 'data'), serverSHA256=sha(output / 'tokenlibrary'))
        save()
        print('HEALTHY ' + service.url, flush=True)
        with (output / 'admin-build.log').open('w') as log:
            subprocess.run(['go', 'build', '-o', str(output / 'library-admin'), './cmd/library-admin'], cwd=REPO / 'server', env=service.env, stdout=log, stderr=log, check=True)
        subprocess.run(['docker', 'exec', service.container, 'createdb', '-U', 'tl', 'restored'], check=True)
        # Keep dump/list/restore on this owned PG17; only the two owned DBs are accepted.
        wrapper = '''#!/usr/bin/env python3
import os,pathlib,subprocess,sys
container=CONTAINER
name=pathlib.Path(sys.argv[0]).name; args=sys.argv[1:]
if args==['--version']:raise SystemExit(subprocess.call(['docker','exec',container,name,'--version']))
if name=='pg_restore' and args[0]=='--list':
 with open(args[1],'rb') as stream:raise SystemExit(subprocess.call(['docker','exec','-i',container,'pg_restore','--list'],stdin=stream))
database=os.environ['PGDATABASE']
if database not in ['tl','restored']:raise SystemExit('unexpected target database')
if name=='pg_dump':
 with open(args[args.index('--file')+1],'wb') as stream:raise SystemExit(subprocess.call(['docker','exec',container,'pg_dump','--format=custom','--no-owner','--no-acl','-U','tl','-d',database],stdout=stream))
if name=='pg_restore':
 with open(args[-1],'rb') as stream:raise SystemExit(subprocess.call(['docker','exec','-i',container,'pg_restore','--exit-on-error','--single-transaction','--no-owner','--no-acl','-U','tl','-d',database],stdin=stream))
raise SystemExit('unsupported owned PostgreSQL command')
'''.replace('CONTAINER', repr(service.container))
        for name in ['pg_dump', 'pg_restore']:
            (output / 'tools' / name).write_text(wrapper)
            (output / 'tools' / name).chmod(0o700)
        device = str(uuid.uuid4())
        session = api('POST', '/api/v1/auth/login', {'username': 'e2e', 'password': 'e2e-password', 'deviceId': device})
        token = session['sessionToken']
        state.update(libraryId=session['libraryId'], epoch=session['epoch'], rootId=session['rootId'])
        receipts = []
        image = upload('fixture-diagram.png', 'image/png')
        pdf = upload('research-three-pages.pdf', 'application/pdf')
        note_id, pdf_id, late_id = (str(uuid.uuid4()) for _ in range(3))
        baseline_body = '# Epoch 原有笔记\n\nEpochBaseline20260927\n\n保存中文与 LF。\n\n![合成研究流程图](' + image['path'] + ')\n'
        metadata = {'version': 1, 'category': 'note', 'inbox': False, 'archived': False}
        operation(note_id, 'createMarkdown', {'name': 'Epoch 原有笔记.md', 'parentId': state['rootId'], 'markdownSource': baseline_body, 'assets': [image], 'metadata': metadata})
        operation(pdf_id, 'createPDF', {'name': 'Epoch 三页研究原件.pdf', 'parentId': state['rootId'], 'pdfBlobId': pdf['blobId'], 'metadata': {'version': 1, 'category': 'paper', 'inbox': False}, 'annotations': []})
        baseline = snapshot('01-backup-baseline')
        backups = api('POST', '/api/v1/test/backup/run', {})['backups']
        backup = next(item for item in backups if item['state'] == 'success')
        backup_path = Path(backup['path']).resolve()
        assert backup_path.is_relative_to(output / 'backups')
        with (output / 'verify-backup.log').open('w') as log:
            subprocess.run([str(output / 'library-admin'), 'verify', '--backup', str(backup_path)], env=service.env, stdout=log, stderr=log, check=True)
        # Advance one existing head and create a second note only after the backup.
        cloud_body = baseline_body + '\nBackupLaterCloudRevision20260927\n'
        operation(note_id, 'updateDocument', {'markdownSource': cloud_body}, 1)
        late_body = '# Epoch 备份后新增\n\nEpochCreatedAfterBackup20260927\n\n这篇资料不在备份中，本机修改应保留。\n'
        operation(late_id, 'createMarkdown', {'name': 'Epoch 备份后新增.md', 'parentId': state['rootId'], 'markdownSource': late_body, 'metadata': metadata})
        api('POST', '/api/v1/auth/logout', {})
        token = None
        advanced = snapshot('02-native-login-baseline')
        assert len(advanced['objects']) == len(baseline['objects']) + 1
        state.update(phase='prepared', backup=backup, backupManifestSHA256=sha(backup_path / 'manifest.json'),
                     baselineNoteId=note_id, afterBackupNoteId=late_id, pdfId=pdf_id,
                     image=image, pdf=pdf, baselineBody=baseline_body, currentBody=cloud_body, afterBackupBody=late_body,
                     publisherLoggedOut=True, restoreRequested=False)
        save()
        print('PREPARED ' + str(output / 'state.json'), flush=True)
        while time.monotonic() - started < args.ttl:
            request_path = output / 'restore-request.json'
            if request_path.exists():
                consumed = output / ('restore-request-consumed-' + str(time.time_ns()) + '.json')
                request_path.rename(consumed)
                try:
                    restore(json.loads(consumed.read_text()))
                except Exception as error:
                    # Rejected control input must not terminate this fixture. A
                    # failed restore has already restarted the original source;
                    # leave it available for inspection instead of cleaning up.
                    state['lastRestoreError'] = type(error).__name__ + ': ' + str(error)
                    save()
                    print('RESTORE_REQUEST_FAILED ' + str(output / 'state.json'), flush=True)
            if service.app.poll() is not None and not state.get('unexpectedExitRecorded'):
                # Preserve PG and original files until the advertised lease
                # ends if startup/rollback itself failed; report, do not erase
                # the incident immediately as part of an exception unwind.
                state.update(unexpectedExitRecorded=True, unexpectedExitCode=service.app.returncode)
                save()
                print('OWNED_APP_EXITED ' + str(output / 'state.json'), flush=True)
            time.sleep(.3)
    except BaseException as error:
        state['error'] = type(error).__name__ + ': ' + str(error)
        raise
    finally:
        service.close()
        state.update(phase='closed', endedAt=now(), cleanupOwnedResourcesOnly=True)
        save()
        print('CLOSED ' + str(output), flush=True)


def control(args):
    directory = args.state.resolve().parent
    state = json.loads(args.state.read_text())
    if args.origin != state.get('origin') or not args.origin.startswith('http://127.0.0.1:') or state.get('phase') != 'prepared':
        raise SystemExit('origin/phase guard mismatch')
    if args.library != state.get('libraryId') or args.epoch != state.get('epoch'):
        raise SystemExit('library/epoch guard mismatch')
    path = directory / 'restore-request.json'
    if path.exists() or state.get('restoreRequested'):
        raise SystemExit('restore already requested')
    request = {k: state[k] for k in ['runId', 'origin', 'libraryId', 'epoch', 'backupManifestSHA256']}
    request.update(action='restore', expectedPhase='prepared')
    # Publish a complete file without replacing an already pending request.
    # The server may poll between open() and json.dump(), so direct writes to
    # the watched name could be consumed before JSON is complete.
    temporary = directory / ('restore-request-staged-' + uuid.uuid4().hex + '.json')
    try:
        with temporary.open('x') as stream:
            json.dump(request, stream)
            stream.flush()
            os.fsync(stream.fileno())
        os.link(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)
    print('REQUESTED ' + str(path))


def maintenance(args):
    """Hold only the current prepared service in maintenance, then end or retire.

    This is deliberately separate from serve: starting the fixture never changes
    readiness, and the parent decides when its native client is ready to edit.
    """
    state_file = args.state.resolve()
    initial = json.loads(state_file.read_text())
    required = ['origin', 'libraryId', 'epoch', 'runId', 'container', 'appPID']
    identity = {key: initial[key] for key in required}
    if initial['phase'] != 'prepared' or args.origin != initial['origin'] or args.library != initial['libraryId'] or args.epoch != initial['epoch']:
        raise SystemExit('maintenance origin/library/epoch/phase guard mismatch')
    if not initial['container'].startswith('tl-native-epoch-') or not initial['origin'].startswith('http://127.0.0.1:'):
        raise SystemExit('not an owned native epoch fixture')
    if not 30 <= args.ttl <= 240:
        raise SystemExit('maintenance TTL must be 30 to 240 seconds')
    out = state_file.parent
    proof = out / ('maintenance-' + str(time.time_ns()) + '.json')
    deadline = time.monotonic() + args.ttl
    record = {'startedAt': now(), 'identity': identity,
              'deadline': (dt.datetime.now().astimezone() + dt.timedelta(seconds=args.ttl)).isoformat()}

    def exact_current():
        current = json.loads(state_file.read_text())
        return current['phase'] == 'prepared' and all(current[key] == value for key, value in identity.items())

    def request(action):
        if not exact_current():
            raise RuntimeError('fixture changed, do not control new process/epoch')
        live = json.loads(subprocess.check_output(['docker', 'exec', identity['container'], 'psql', '-X', '-U', 'tl', '-d', 'tl',
             '-Atq', '-v', 'ON_ERROR_STOP=1', '-c', "BEGIN READ ONLY; SELECT json_build_object('id',id,'epoch',epoch) FROM libraries; COMMIT;"], text=True))
        assert live['id'] == identity['libraryId'] and live['epoch'] == identity['epoch']
        port = identity['origin'].rsplit(':', 1)[1]
        listeners = subprocess.check_output(['lsof', '-nP', '-t', '-iTCP:' + port, '-sTCP:LISTEN'], text=True).split()
        assert set(listeners) == {str(identity['appPID'])}, 'listener identity changed'
        req = urllib.request.Request(identity['origin'] + '/api/v1/test/backup/' + action,
                                     data=b'{}', headers={'Content-Type': 'application/json'}, method='POST')
        with urllib.request.urlopen(req, timeout=5) as response:
            result = json.load(response)
        assert result['data']['maintenance'] == (action == 'begin')
        return result

    marker = out / 'maintenance-end-requested'
    if marker.exists():
        raise SystemExit('old end marker exists; retain evidence and use another action')
    with urllib.request.urlopen(identity['origin'] + '/health/ready', timeout=3) as response:
        ready = json.load(response)
    if not ready.get('ready') or ready.get('maintenance'):
        raise SystemExit('fixture is not healthy; do not take over another maintenance operation')

    def interrupted(_signum, _frame):
        raise KeyboardInterrupt()

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        request('begin')
        record['beginConfirmedAt'] = now()
        write(proof, record)
        print('MAINTENANCE ' + json.dumps({'proof': str(proof), 'deadline': record['deadline'], 'earlyEndMarker': str(marker)}), flush=True)
        while time.monotonic() < deadline and not marker.exists() and exact_current():
            time.sleep(.25)
    finally:
        if exact_current():
            request('end')
            record['endedAt'] = now()
            record['maintenanceEnded'] = True
        else:
            record.update(endedAt=now(), maintenanceEnded=False, skippedBecause='restore started or identity changed; did not touch successor')
        write(proof, record)
        print('MAINTENANCE_CONTROL_FINISHED ' + str(proof), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    start = commands.add_parser('serve')
    start.add_argument('--fixtures', type=Path, required=True)
    start.add_argument('--ttl', type=int, default=3600)
    for name in ['restore', 'maintenance']:
        request = commands.add_parser(name)
        request.add_argument('--state', type=Path, required=True)
        request.add_argument('--origin', required=True)
        request.add_argument('--library', required=True)
        request.add_argument('--epoch', required=True)
        if name == 'maintenance':
            request.add_argument('--ttl', type=int, default=240)
    args = parser.parse_args()
    if args.command == 'serve':
        if not 300 <= args.ttl <= 7200:
            parser.error('TTL must be between 300 and 7200 seconds')
        args.fixtures = args.fixtures.resolve()
        for name in ['fixture-diagram.png', 'research-three-pages.pdf']:
            if not (args.fixtures / name).is_file():
                parser.error('missing explicit synthetic fixture: ' + name)
        serve(args)
    elif args.command == 'restore':
        control(args)
    else:
        maintenance(args)
