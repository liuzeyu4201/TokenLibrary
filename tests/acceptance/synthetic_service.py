"""Owned, disposable PostgreSQL 17 + TokenLibrary fixture (no existing service control)."""
import hashlib
import os
from pathlib import Path
import socket
import subprocess
import time
import urllib.request
import json
import uuid

REPO=Path(__file__).resolve().parents[2]
class SyntheticService:
    def __init__(self, output):
        self.output=Path(output).resolve(); self.container='tl-attachment-'+uuid.uuid4().hex[:12]
        self.app=None; self.container_started=False; self.logs=[]
        self.env=os.environ.copy(); self.env.update(GOCACHE='/tmp/tokenlibrary-server-audit-gocache',GOMODCACHE='/tmp/tokenlibrary-server-audit-gomodcache')
    def start(self):
        log=(self.output/'server-build.log').open('w');self.logs.append(log)
        subprocess.run(['go','build','-o',str(self.output/'tokenlibrary'),'./cmd/tokenlibrary'],cwd=REPO/'server',env=self.env,stdout=log,stderr=log,check=True)
        credential=subprocess.check_output(['go','run','./cmd/hashcred'],cwd=REPO/'server',env=self.env,text=True,input='e2e-password\n')
        self.env.update({key:value.strip("'") for key,value in (line.split('=',1) for line in credential.splitlines())})
        self.env['UPLOAD_TOKEN_HASH']=hashlib.sha256(b'attachment-fixture-upload-only').hexdigest()
        subprocess.run(['docker','run','--rm','-d','--name',self.container,'-e','POSTGRES_USER=tl','-e','POSTGRES_PASSWORD=attachment-test-only','-e','POSTGRES_DB=tl','-p','127.0.0.1::5432','postgres:17'],stdout=subprocess.DEVNULL,check=True)
        self.container_started=True
        pgport=subprocess.check_output(['docker','port',self.container,'5432'],text=True).strip().rsplit(':',1)[1]
        for _ in range(150):
            if subprocess.run(['docker','exec',self.container,'pg_isready','-U','tl','-d','tl'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0:break
            time.sleep(.15)
        else:raise RuntimeError('owned PostgreSQL not ready')
        # Use matching-major dump/list tools so the actual startup backup can complete.
        tools=self.output/'tools';tools.mkdir()
        source='''#!/usr/bin/env python3
import pathlib,subprocess,sys
container=CONTAINER
name=pathlib.Path(sys.argv[0]).name
args=sys.argv[1:]
if args==['--version']:raise SystemExit(subprocess.call(['docker','exec',container,name,'--version']))
if name=='pg_restore' and args[0]=='--list':
    with open(args[1],'rb') as stream:raise SystemExit(subprocess.call(['docker','exec','-i',container,'pg_restore','--list'],stdin=stream))
if name=='pg_dump':
    with open(args[args.index('--file')+1],'wb') as stream:raise SystemExit(subprocess.call(['docker','exec',container,'pg_dump','--format=custom','--no-owner','--no-acl','-U','tl','-d','tl'],stdout=stream))
raise SystemExit('unsupported fixture tool command')
'''.replace('CONTAINER',repr(self.container))
        for name in ['pg_dump','pg_restore']:
            (tools/name).write_text(source);(tools/name).chmod(0o700)
        self.env['PATH']=str(tools)+os.pathsep+self.env['PATH']
        with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
        self.url=f'http://127.0.0.1:{port}'
        self.env.update(DATABASE_URL=f'postgres://tl:attachment-test-only@127.0.0.1:{pgport}/tl?sslmode=disable',DATA_ROOT=str(self.output/'data'),BACKUP_ROOT=str(self.output/'backups'),ADMIN_USERNAME='e2e',LISTEN_ADDR=f'127.0.0.1:{port}',SCHEMA_PATH=str(REPO/'server/schema/initial.sql'),TOKENLIBRARY_TEST_HOOKS='1',UPLOAD_TOKEN_ENABLED='true',BACKUP_TIME='23:59',BACKUP_TIMEZONE='UTC',CREDENTIAL_GENERATION='1',PUBLIC_BASE_URL=self.url)
        log=(self.output/'server.log').open('w');self.logs.append(log)
        self.app=subprocess.Popen([str(self.output/'tokenlibrary')],cwd=REPO/'server',env=self.env,stdout=log,stderr=log)
        for _ in range(200):
            if self.app.poll() is not None:raise RuntimeError('owned server exited; see server.log')
            try:
                with urllib.request.urlopen(self.url+'/health/ready',timeout=1) as response:ready=json.load(response)
                if ready.get('ready') and not ready.get('maintenance'):
                    result=subprocess.check_output(['docker','exec',self.container,'psql','-X','-U','tl','-d','tl','-Atq','-c',"SELECT count(*) FILTER(WHERE state='success'),count(*) FILTER(WHERE state='running') FROM jobs WHERE type='backup'"],text=True).strip()
                    if result.endswith('|0') and int(result.split('|')[0])>0:return
            except OSError:pass
            time.sleep(.15)
        raise RuntimeError('startup catch-up readiness timeout')
    def close(self):
        if self.app is not None and self.app.poll() is None:
            self.app.terminate()
            try:self.app.wait(timeout=8)
            except subprocess.TimeoutExpired:self.app.kill();self.app.wait(timeout=8)
        if self.container_started:
            subprocess.run(['docker','rm','-f',self.container],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        for log in self.logs:log.close()
