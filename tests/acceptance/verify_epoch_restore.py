#!/usr/bin/env python3
"""Real same-URL restore with two persistent Swift Core clients, in a new owned PG17.
No existing service, container, app, Keychain, or real user directory is touched.
All business writes use normal Core/API paths; SQL only reads evidence and creates
one empty restore database in this script's unique container.
"""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import selectors
import signal
import socket
import subprocess
import tempfile
import time
import urllib.request
import uuid

REPO = Path(__file__).resolve().parents[2]
SQL = """BEGIN READ ONLY;
SELECT json_build_object(
 'library',(SELECT row_to_json(l) FROM (SELECT id,epoch,root_id,change_seq,maintenance FROM libraries) l),
 'objects',(SELECT json_agg(row_to_json(o) ORDER BY id) FROM (SELECT o.*,d.markdown_source,d.pdf_blob_id,convert_from(r.snapshot_bytes,'UTF8')::json AS snapshot FROM objects o LEFT JOIN documents d ON d.object_id=o.id LEFT JOIN revisions r ON r.object_id=o.id AND r.revision=o.revision AND r.epoch=(SELECT epoch FROM libraries)) o),
 'blobs',(SELECT json_agg(json_build_object('id',id,'size',size,'sha256',encode(sha256,'hex'),'state',state) ORDER BY id) FROM blobs),
 'operationCount',(SELECT count(*) FROM operations),
 'sessionCount',(SELECT count(*) FROM sessions),
 'operationIDs',(SELECT coalesce(json_agg(operation_id ORDER BY operation_id),'[]'::json) FROM operations));
COMMIT;"""


def now():
    return dt.datetime.now().astimezone().isoformat()


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write(path, value):
    Path(path).write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--core-products', required=True, type=Path, help='frozen Debug static archive + modules; do not point at an active build')
    parser.add_argument('--fixtures', required=True, type=Path, help='synthetic research-three-pages.pdf and fixture-diagram.png')
    args = parser.parse_args()
    products = args.core_products.resolve()
    fixtures = args.fixtures.resolve()
    if products.is_relative_to(REPO / 'clients/LibraryCore/.build'):
        parser.error('Copy Core products outside the active .build first')
    for path in [products / 'libLibraryCore.a', fixtures / 'research-three-pages.pdf', fixtures / 'fixture-diagram.png']:
        if not path.is_file(): parser.error(f'missing explicit synthetic input: {path.name}')
    output = Path(tempfile.mkdtemp(prefix='tokenlibrary-epoch-restore-')).resolve()
    container = 'tl-epoch-' + uuid.uuid4().hex[:12]
    env = os.environ.copy()
    env.update(GOCACHE='/tmp/tokenlibrary-server-audit-gocache', GOMODCACHE='/tmp/tokenlibrary-server-audit-gomodcache')
    state = {'startedAt': now(), 'output': str(output), 'container': container, 'passed': False,
             'frozenCoreArchive': str(products/'libLibraryCore.a'), 'frozenCoreSHA256': digest(products/'libLibraryCore.a'),
             'swiftProbeSHA256': digest(Path(__file__).with_suffix('.swift')), 'orchestratorSHA256': digest(__file__)}
    app = probe = None
    owned_container = False
    resources = []
    print(f'OUTPUT {output}', flush=True)
    def run(argv, **kwargs):
        return subprocess.run(argv, check=True, **kwargs)
    def sql(database):
        raw = subprocess.check_output(['docker','exec',container,'psql','-X','-U','tl','-d',database,'-Atq','-v','ON_ERROR_STOP=1','-c',SQL], text=True)
        return json.loads(raw)
    def phase(name, database):
        value = {'observedAt': now(), 'database': database, 'state': sql(database)}
        write(output / (name+'.json'), value)
        return value['state']
    def stop_app():
        nonlocal app
        if app is not None and app.poll() is None:
            app.terminate()
            try: app.wait(timeout=8)
            except subprocess.TimeoutExpired: app.kill(); app.wait(timeout=8)
        app = None
    def start_app(database, data_root, label):
        nonlocal app
        env.update(DATABASE_URL=f'postgres://tl:epoch-test-only@127.0.0.1:{pgport}/{database}?sslmode=disable', DATA_ROOT=str(data_root))
        log = (output / (label+'-app.log')).open('w'); resources.append(log)
        app = subprocess.Popen([str(output/'tokenlibrary')], cwd=REPO/'server', env=env, stdout=log, stderr=log)
        for _ in range(150):
            if app.poll() is not None: raise RuntimeError(f'{label} exited; see private app log')
            try:
                with urllib.request.urlopen(base+'/health/ready', timeout=1) as response:
                    readiness = json.load(response)
                    if response.status == 200 and not readiness.get('maintenance', True):
                        # Readiness can be true before startup catch-up obtains maintenance.
                        # Wait for that real job to finish; do not disable or seed scheduler state.
                        jobs = subprocess.check_output(['docker','exec',container,'psql','-X','-U','tl','-d',database,'-Atq','-c',"SELECT count(*) FILTER (WHERE state='success'),count(*) FILTER (WHERE state='running') FROM jobs WHERE type='backup'"],text=True).strip()
                        if jobs.endswith('|0') and int(jobs.split('|')[0]) > 0:
                            print(f'READY {label} pid={app.pid} url={base}', flush=True)
                            return
                        time.sleep(.15)
            except OSError: pass
            time.sleep(.15)
        raise RuntimeError(f'{label} readiness timeout')
    def api(path, body, token=None, epoch=None):
        headers = {'Content-Type':'application/json'}
        if token: headers['Authorization'] = 'Bearer '+token
        if epoch: headers['X-Library-Epoch'] = epoch
        request = urllib.request.Request(base+path, data=json.dumps(body).encode(), headers=headers, method='POST')
        with urllib.request.urlopen(request, timeout=60) as response: return json.load(response)['data']
    def await_probe(expected, timeout=120):
        deadline = time.monotonic()+timeout
        with selectors.DefaultSelector() as selector:
            selector.register(probe.stdout, selectors.EVENT_READ)
            while time.monotonic() < deadline:
                if not selector.select(timeout=min(1, max(0,deadline-time.monotonic()))):
                    if probe.poll() is not None: raise RuntimeError(f'Core probe exited {probe.returncode}; see probe stderr')
                    continue
                line = probe.stdout.readline()
                if not line: raise RuntimeError(f'Core probe EOF before {expected}')
                probe_log.write(line); probe_log.flush()
                print('PROBE '+line.rstrip(), flush=True)
                if line.strip() == expected: return
            raise RuntimeError(f'Core probe timeout waiting for {expected}')
    def tell_probe(message):
        probe.stdin.write(message+'\n'); probe.stdin.flush()
    def interrupted(_signum, _frame): raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM, interrupted); signal.signal(signal.SIGINT, interrupted)
    try:
        build_log = (output/'build.log').open('w'); resources.append(build_log)
        for binary in ['tokenlibrary','library-admin']:
            run(['go','build','-o',str(output/binary),'./cmd/'+binary], cwd=REPO/'server', env=env, stdout=build_log, stderr=build_log)
        state['serverSHA256'] = digest(output/'tokenlibrary')
        cmd = ['swiftc','-parse-as-library',str(Path(__file__).with_suffix('.swift')),'-I',str(products)]
        for include in ['GRDB.swift/Sources/GRDBSQLite','swift-cmark/src/include','swift-cmark/extensions/include','swift-markdown/Sources/CAtomic/include']:
            cmd += ['-I',str(REPO/'clients/LibraryCore/.build/checkouts'/include)]
        cmd += ['-L',str(products),'-lLibraryCore','-lsqlite3','-o',str(output/'probe')]
        run(cmd, stdout=build_log, stderr=build_log)
        cred = subprocess.check_output(['go','run','./cmd/hashcred'],cwd=REPO/'server',env=env,text=True,input='e2e-password\n')
        env.update({key:value.strip("'") for key,value in (line.split('=',1) for line in cred.splitlines())})
        env['UPLOAD_TOKEN_HASH'] = hashlib.sha256(b'epoch-restore-synthetic-upload-only').hexdigest()
        run(['docker','run','--rm','-d','--name',container,'-e','POSTGRES_USER=tl','-e','POSTGRES_PASSWORD=epoch-test-only','-e','POSTGRES_DB=tl','-p','127.0.0.1::5432','postgres:17'],stdout=subprocess.DEVNULL)
        owned_container = True
        pgport = subprocess.check_output(['docker','port',container,'5432'],text=True).strip().rsplit(':',1)[1]
        for _ in range(150):
            if subprocess.run(['docker','exec',container,'pg_isready','-U','tl','-d','tl'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode == 0: break
            time.sleep(.15)
        else: raise RuntimeError('owned PG17 not ready')
        run(['docker','exec',container,'createdb','-U','tl','restored'], stdout=subprocess.DEVNULL)
        tools_dir = output/'tools'; tools_dir.mkdir()
        # Matching-major tools run in our owned PG17. Binary dumps stay on stdin/stdout.
        wrapper = '''#!/usr/bin/env python3
import os,pathlib,subprocess,sys
container=CONTAINER
name=pathlib.Path(sys.argv[0]).name
args=sys.argv[1:]
if args==['--version']:
    raise SystemExit(subprocess.call(['docker','exec',container,name,'--version']))
if name=='pg_restore' and args[0]=='--list':
    with open(args[1],'rb') as stream:
        raise SystemExit(subprocess.call(['docker','exec','-i',container,'pg_restore','--list'],stdin=stream))
database=os.environ['PGDATABASE']
if database not in ['tl','restored']: raise SystemExit('unexpected target database')
if name=='pg_dump':
    target=args[args.index('--file')+1]
    with open(target,'wb') as stream:
        raise SystemExit(subprocess.call(['docker','exec',container,'pg_dump','--format=custom','--no-owner','--no-acl','-U','tl','-d',database],stdout=stream))
if name=='pg_restore':
    with open(args[-1],'rb') as stream:
        raise SystemExit(subprocess.call(['docker','exec','-i',container,'pg_restore','--exit-on-error','--single-transaction','--no-owner','--no-acl','-U','tl','-d',database],stdin=stream))
raise SystemExit('unsupported PostgreSQL tool')
'''.replace('CONTAINER',repr(container))
        for tool in ['pg_dump','pg_restore']:
            (tools_dir/tool).write_text(wrapper); (tools_dir/tool).chmod(0o700)
        env['PATH'] = str(tools_dir)+os.pathsep+env['PATH']
        with socket.socket() as sock:
            sock.bind(('127.0.0.1',0)); port = sock.getsockname()[1]
        base = f'http://127.0.0.1:{port}'
        state['url'] = base
        env.update(BACKUP_ROOT=str(output/'backups'),ADMIN_USERNAME='e2e',LISTEN_ADDR=f'127.0.0.1:{port}',SCHEMA_PATH=str(REPO/'server/schema/initial.sql'),TOKENLIBRARY_TEST_HOOKS='1',UPLOAD_TOKEN_ENABLED='true',BACKUP_TIME='23:59',BACKUP_TIMEZONE='UTC',CREDENTIAL_GENERATION='1',PUBLIC_BASE_URL=base)
        start_app('tl', output/'source-data', 'source')
        probe_env = os.environ.copy(); probe_env.update(TEST_TOKENLIBRARY_USER='e2e',TEST_TOKENLIBRARY_PASSWORD='e2e-password')
        probe_log = (output/'probe.log').open('w'); resources.append(probe_log)
        probe_err = (output/'probe.stderr').open('w'); resources.append(probe_err)
        probe = subprocess.Popen([str(output/'probe'),base,str(output/'clients'),str(fixtures)],env=probe_env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=probe_err,text=True,bufsize=1)
        await_probe('READY_FOR_BACKUP')
        baseline = phase('01-backup-baseline','tl')
        session = api('/api/v1/auth/login',{'username':'e2e','password':'e2e-password','deviceId':str(uuid.uuid4()),'deviceName':'isolated restore control','platform':'test'})
        try: backups = api('/api/v1/test/backup/run',{},session['sessionToken'],session['epoch'])['backups']
        finally: api('/api/v1/auth/logout',{},session['sessionToken'],session['epoch'])
        del session
        backup = next(item for item in backups if item['state']=='success')
        backup_path = Path(backup['path']).resolve()
        if not backup_path.is_relative_to(output/'backups'): raise RuntimeError('backup path escaped owned directory')
        state['backup'] = backup
        manifest = json.loads((backup_path/'manifest.json').read_text()); state['manifest'] = manifest
        run([str(output/'library-admin'),'verify','--backup',str(backup_path)],env=env,stdout=build_log,stderr=build_log)
        print('BACKUP_VERIFIED '+backup['id'],flush=True)
        tell_probe('backup-ok'); await_probe('READY_FOR_RESTORE')
        before_restore = phase('02-advanced-source','tl')
        stop_app()
        restore_env = env.copy(); restore_env['RESTORE_DATABASE_URL'] = f'postgres://tl:epoch-test-only@127.0.0.1:{pgport}/restored?sslmode=disable'
        run([str(output/'library-admin'),'restore','--backup',str(backup_path),'--data-root',str(output/'restored-data'),'--schema',str(REPO/'server/schema/initial.sql'),'--database-env','RESTORE_DATABASE_URL'],env=restore_env,stdout=build_log,stderr=build_log)
        restored = phase('03-restored-before-login','restored')
        assert restored['library']['id']==baseline['library']['id'] and restored['library']['root_id']==baseline['library']['root_id']
        assert restored['library']['epoch']!=baseline['library']['epoch'] and not restored['library']['maintenance']
        assert restored['objects']==baseline['objects'] and restored['blobs']==baseline['blobs'], 'backup content/metadata/media changed on restore'
        assert restored['sessionCount']==0 and restored['operationCount']==0, 'old session/receipt survived restore'
        start_app('restored', output/'restored-data','restored')
        tell_probe('restored'); await_probe('EPOCH_RESTORE_PASSED')
        assert probe.wait(timeout=10)==0
        final = phase('04-final-server','restored')
        original_unchanged = phase('05-original-source-retained','tl')
        assert original_unchanged==before_restore, 'source database was changed by restoration'
        client_final = json.loads((output/'clients/05-final.json').read_text())
        for op in [client_final['oldFrozenA'],client_final['oldFrozenB']]:
            assert op not in final['operationIDs'], 'old frozen operation was replayed into restored server'
        media = []
        for blob in restored['blobs']:
            paths = [output/root/'files/objects'/blob['id'][:2]/blob['id'] for root in ['source-data','restored-data']]
            hashes = [digest(path) for path in paths]
            assert all(path.stat().st_size==blob['size'] for path in paths) and hashes==[blob['sha256']]*2
            media.append({'id':blob['id'],'size':blob['size'],'sha256':blob['sha256'],'sourceAndRestoreIdentical':True})
        state.update(passed=True, endedAt=now(), media=media, sameURL=base, sourceDatabaseUnchanged=True,
                     oldSessionsRejected=2, oldReceiptsCleared=True, oldFrozenOperationsNotReplayed=True,
                     scope='SDK/Core real HTTP + pg_dump/pg_restore. No native UI, Keychain, system scheduler, or full app process restart.')
        print('PASS '+str(output/'proof.json'), flush=True)
    except BaseException as error:
        state.update(error=type(error).__name__+': '+str(error), endedAt=now())
        raise
    finally:
        if probe is not None and probe.poll() is None:
            probe.terminate()
            try: probe.wait(timeout=8)
            except subprocess.TimeoutExpired: probe.kill(); probe.wait(timeout=8)
        stop_app()
        if owned_container:
            cleanup = subprocess.run(['docker','rm','-f',container],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            state['ownedContainerRemoved'] = cleanup.returncode==0
        state['cleanupAt'] = now()
        write(output/'proof.json',state)
        for resource in resources: resource.close()
        print('CLEANED_OWNED_RESOURCES '+str(output),flush=True)

if __name__=='__main__': main()
