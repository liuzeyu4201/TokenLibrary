#!/usr/bin/env python3
"""Real Core download failure/retry through a guarded proxy over a NEW PG17 service.
Run with --keep-for-native to retain only this owned fixture for later explicit UI
steps. Faults have a finite request budget and <=240 s TTL. No existing port is
accepted as an upstream, and tokens/authorization headers are never logged.
"""
import argparse
import datetime as dt
import hashlib
import http.server
import json
import os
from pathlib import Path
import secrets
import selectors
import signal
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid
from synthetic_service import REPO, SyntheticService


def now():return dt.datetime.now().astimezone().isoformat()
def digest(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def write(path,value):Path(path).write_text(json.dumps(value,indent=2,ensure_ascii=False)+'\n')

class FaultControl:
    def __init__(self,output):
        self.output=output;self.run_id=str(uuid.uuid4());self.secret=secrets.token_urlsafe(32)
        self.lock=threading.Lock();self.targets={};self.mode='healthy';self.target=None
        self.remaining=0;self.expires=0;self.phase='initial';self.events=[]
    def status_locked(self):
        if self.mode!='healthy' and (time.monotonic()>=self.expires or self.remaining<=0):self.mode='healthy'
        return {'runId':self.run_id,'mode':self.mode,'target':self.target,'remaining':self.remaining,'ttlRemaining':max(0,self.expires-time.monotonic()),'phase':self.phase,'allowedTargets':self.targets}
    def status(self):
        with self.lock:return self.status_locked()
    def register(self,record):
        uuid.UUID(record['id']);assert len(record['sha256'])==64 and 0<record['size']<=50_000_000
        with self.lock:
            if record['id'] in self.targets:raise ValueError('target already registered')
            self.targets[record['id']]=record
    def set(self,command):
        with self.lock:
            status=self.status_locked()
            if command.get('runId')!=self.run_id or command.get('expectedMode')!=status['mode']:raise ValueError('run/mode guard mismatch')
            mode=command.get('mode');target=command.get('blobId')
            if mode not in ['healthy','503','truncated']:raise ValueError('invalid mode')
            if mode!='healthy':
                if target not in self.targets:raise ValueError('target is not an explicitly registered synthetic blob')
                count=command.get('failures');ttl=command.get('ttlSeconds')
                if not isinstance(count,int) or isinstance(count,bool) or not 1<=count<=100:raise ValueError('failure budget must be 1..100')
                if not isinstance(ttl,(int,float)) or not 1<=ttl<=240:raise ValueError('TTL must be 1..240 seconds')
                self.target=target;self.remaining=count;self.expires=time.monotonic()+ttl
            else:self.remaining=0;self.expires=0
            self.mode=mode;self.phase=command.get('phase','native-control')
            result=self.status_locked()
            with (self.output/'controls.jsonl').open('a') as stream:stream.write(json.dumps({'at':now(),'command':command,'result':result})+'\n')
            return result
    def response(self,path,status,headers,body):
        if not path.startswith('/api/v1/blobs/'):return status,headers,body
        blob=path.removeprefix('/api/v1/blobs/')
        with self.lock:
            self.status_locked();mode='healthy';original=len(body)
            if status==200 and blob==self.target and self.mode!='healthy':
                target=self.targets[blob]
                if len(body)!=target['size'] or hashlib.sha256(body).hexdigest()!=target['sha256']:
                    raise ValueError('upstream bytes do not match registered synthetic target')
                mode=self.mode;self.remaining-=1
                if mode=='503':
                    status=503;headers={'Content-Type':'application/json','Retry-After':'1'}
                    body=json.dumps({'error':{'code':'BUSY','message':'isolated fixture download busy','retryable':True}}).encode()
                elif mode=='truncated':body=body[:max(1,len(body)//2)]
            event={'at':now(),'monotonic':time.monotonic(),'phase':self.phase,'blobId':blob,'fault':mode,'status':status,'backendBytes':original,'responseBytes':len(body),'remaining':self.remaining}
            self.events.append(event)
            with (self.output/'requests.jsonl').open('a') as stream:stream.write(json.dumps(event)+'\n')
            return status,headers,body


def make_handler(backend,control):
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version='HTTP/1.1'
        def log_message(self,*args):pass
        def reply(self,status,body,headers=None):
            self.send_response(status)
            for key,value in (headers or {}).items():
                if key.lower() not in ['content-length','transfer-encoding','connection','date','server']:self.send_header(key,value)
            self.send_header('Content-Length',str(len(body)));self.send_header('Connection','close');self.end_headers()
            self.wfile.write(body);self.close_connection=True
        def dispatch(self):
            try:
                length=int(self.headers.get('Content-Length','0'))
                if not 0<=length<=51_000_000:return self.reply(413,b'body too large')
                body=self.rfile.read(length) if length else None
                if self.path=='/__fixture/status' and self.command=='GET':
                    return self.reply(200,json.dumps(control.status()).encode(),{'Content-Type':'application/json'})
                if self.path=='/__fixture/register' and self.command=='POST':
                    if not secrets.compare_digest(self.headers.get('X-Fixture-Control',''),control.secret):return self.reply(403,b'guard required')
                    try:
                        command=json.loads(body or b'{}')
                        if command.get('runId')!=control.run_id or command.get('expectedMode')!='healthy' or control.status()['mode']!='healthy':raise ValueError('registration guard')
                        if len(control.targets)>=12:raise ValueError('fixture target budget')
                        target=command['target'];uuid.UUID(target['objectId'])
                        control.register(target)
                        with (control.output/'registrations.jsonl').open('a') as stream:stream.write(json.dumps({'at':now(),'target':target})+'\n')
                    except (ValueError,TypeError,KeyError,AssertionError):return self.reply(409,b'registration guard rejected')
                    return self.reply(200,json.dumps(control.status()).encode(),{'Content-Type':'application/json'})
                if self.path=='/__fixture/control' and self.command=='POST':
                    if not secrets.compare_digest(self.headers.get('X-Fixture-Control',''),control.secret):return self.reply(403,b'guard required')
                    try:result=control.set(json.loads(body or b'{}'))
                    except (ValueError,TypeError,KeyError):return self.reply(409,b'control guard rejected')
                    return self.reply(200,json.dumps(result).encode(),{'Content-Type':'application/json'})
                if self.path.startswith('/__fixture/'):return self.reply(404,b'unknown fixture control')
                if not self.path.startswith('/') or self.path.startswith('//'):return self.reply(400,b'invalid path')
                headers={key:value for key,value in self.headers.items() if key.lower() not in ['host','content-length','connection','accept-encoding']}
                request=urllib.request.Request(backend+self.path,data=body,headers=headers,method=self.command)
                try:response=urllib.request.urlopen(request,timeout=30)
                except urllib.error.HTTPError as error:response=error
                with response:
                    status=response.status;payload=response.read();response_headers=dict(response.headers.items())
                if self.command=='GET':status,response_headers,payload=control.response(self.path,status,response_headers,payload)
                self.reply(status,payload,response_headers)
            except (BrokenPipeError,ConnectionResetError):pass
            except Exception as error:
                with (control.output/'proxy-errors.log').open('a') as stream:stream.write(now()+' '+type(error).__name__+': '+str(error)+'\n')
                self.reply(502,b'isolated fixture proxy error')
        do_GET=dispatch;do_POST=dispatch;do_PUT=dispatch;do_DELETE=dispatch;do_PATCH=dispatch
    return Handler


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--core-products',required=True,type=Path);parser.add_argument('--fixtures',required=True,type=Path)
    parser.add_argument('--keep-for-native',action='store_true')
    args=parser.parse_args();products=args.core_products.resolve();fixtures=args.fixtures.resolve()
    if products.is_relative_to(REPO/'clients/LibraryCore/.build'):parser.error('freeze Core products outside active .build first')
    for path in [products/'libLibraryCore.a',fixtures/'fixture-diagram.png',fixtures/'research-three-pages.pdf']:
        if not path.is_file():parser.error('missing explicit synthetic fixture/product '+path.name)
    output=Path(tempfile.mkdtemp(prefix='tokenlibrary-attachment-recovery-')).resolve()
    service=SyntheticService(output);control=FaultControl(output);proxy=probe=None;logs=[]
    proof={'startedAt':now(),'output':str(output),'passed':False,'frozenCoreSHA256':digest(products/'libLibraryCore.a'),'scriptSHA256':digest(__file__),'probeSourceSHA256':digest(Path(__file__).with_suffix('.swift'))}
    print('OUTPUT '+str(output),flush=True)
    def interrupted(_signum,_frame):raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM,interrupted);signal.signal(signal.SIGINT,interrupted)
    def wait(expected):
        deadline=time.monotonic()+90
        with selectors.DefaultSelector() as selector:
            selector.register(probe.stdout,selectors.EVENT_READ)
            while time.monotonic()<deadline:
                if not selector.select(timeout=1):
                    if probe.poll() is not None:raise RuntimeError('Core probe exited; see probe.stderr')
                    continue
                line=probe.stdout.readline()
                if not line:raise RuntimeError('Core probe EOF before '+expected)
                probe_log.write(line);probe_log.flush();print('PROBE '+line.strip(),flush=True)
                if line.strip()==expected:return
        raise RuntimeError('Core probe timeout '+expected)
    def tell(value):probe.stdin.write(value+'\n');probe.stdin.flush()
    def arm(target,mode,count,phase,ttl=120):
        control.set({'runId':control.run_id,'expectedMode':control.status()['mode'],'blobId':target,'mode':mode,'failures':count,'ttlSeconds':ttl,'phase':phase})
    def events(phase):return [item for item in control.events if item['phase']==phase]
    try:
        build_log=(output/'probe-build.log').open('w');logs.append(build_log)
        cmd=['swiftc','-parse-as-library',str(Path(__file__).with_suffix('.swift')),'-I',str(products)]
        for include in ['GRDB.swift/Sources/GRDBSQLite','swift-cmark/src/include','swift-cmark/extensions/include','swift-markdown/Sources/CAtomic/include']:cmd+=['-I',str(REPO/'clients/LibraryCore/.build/checkouts'/include)]
        cmd+=['-L',str(products),'-lLibraryCore','-lsqlite3','-o',str(output/'probe')]
        subprocess.run(cmd,stdout=build_log,stderr=build_log,check=True)
        service.start()
        proxy=http.server.ThreadingHTTPServer(('127.0.0.1',0),make_handler(service.url,control))
        proxy.daemon_threads=True;threading.Thread(target=proxy.serve_forever,daemon=True).start()
        origin=f'http://127.0.0.1:{proxy.server_port}'
        owner={'runId':control.run_id,'origin':origin,'backendOrigin':service.url,'supervisorPID':os.getpid(),'serverPID':service.app.pid,'container':service.container,'output':str(output),'controlKey':control.secret}
        owner_path=output/'owner-control.json';write(owner_path,owner);owner_path.chmod(0o600)
        proof.update(origin=origin,backendOrigin=service.url,serverPID=service.app.pid,supervisorPID=os.getpid(),container=service.container,serverSHA256=digest(output/'tokenlibrary'),controlFile=str(owner_path))
        env=os.environ.copy();env.update(TEST_TOKENLIBRARY_USER='e2e',TEST_TOKENLIBRARY_PASSWORD='e2e-password')
        probe_log=(output/'probe.log').open('w');probe_err=(output/'probe.stderr').open('w');logs.extend([probe_log,probe_err])
        clients=output/'clients'
        probe=subprocess.Popen([str(output/'probe'),origin,str(clients),str(fixtures)],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=probe_err,text=True,bufsize=1)
        wait('PDF_TARGET_READY');pdf=json.loads((clients/'pdf-target.json').read_text());control.register(pdf)
        arm(pdf['id'],'503',3,'pdf-exhaust');tell('pdf-503');wait('PDF_503_FAILED')
        failed=events('pdf-exhaust');assert len(failed)==3 and all(item['status']==503 for item in failed)
        assert failed[-1]['monotonic']-failed[0]['monotonic']>=1.9,'Retry-After not respected'
        arm(pdf['id'],'503',2,'pdf-auto-retry');tell('pdf-retry');wait('PDF_RECOVERED')
        recovered=events('pdf-auto-retry');assert [item['status'] for item in recovered]==[503,503,200]
        assert recovered[-1]['monotonic']-recovered[0]['monotonic']>=1.9
        tell('add-image');wait('IMAGE_TARGET_READY');image=json.loads((clients/'image-target.json').read_text());control.register(image)
        arm(image['id'],'truncated',1,'image-truncated');tell('image-truncated');wait('IMAGE_TRUNCATED_FAILED')
        damaged=events('image-truncated');assert len(damaged)==1 and damaged[0]['responseBytes']==image['size']//2 and damaged[0]['status']==200
        arm(image['id'],'healthy',0,'image-retry');tell('image-retry');wait('ATTACHMENT_RECOVERY_PASSED');assert probe.wait(timeout=10)==0
        final_requests=events('image-retry');assert len(final_requests)==1 and final_requests[0]['responseBytes']==image['size']
        # The control boundary cannot arm arbitrary blobs or accept a missing guard.
        req=urllib.request.Request(origin+'/__fixture/control',data=b'{}',method='POST')
        try:urllib.request.urlopen(req,timeout=2);raise AssertionError('unguarded control accepted')
        except urllib.error.HTTPError as error:assert error.code==403
        for invalid in [{'expectedMode':'503','blobId':image['id']},{'expectedMode':'healthy','blobId':str(uuid.uuid4())}]:
            command={'runId':control.run_id,'mode':'503','failures':1,'ttlSeconds':1,**invalid}
            req=urllib.request.Request(origin+'/__fixture/control',data=json.dumps(command).encode(),headers={'X-Fixture-Control':control.secret},method='POST')
            try:urllib.request.urlopen(req,timeout=2);raise AssertionError('invalid control accepted')
            except urllib.error.HTTPError as error:assert error.code==409
        # A real short TTL expires without making a download, leaving bytes/DB untouched.
        arm(image['id'],'503',1,'ttl-check',ttl=1)
        time.sleep(1.05);assert control.status()['mode']=='healthy'
        proof.update(passed=True,completedAt=now(),faultRequests={'pdfExhaustion':failed,'pdfAutomaticRetry':recovered,'imageTruncated':damaged,'imageManualRetry':final_requests},targets=control.targets,negativeGuardsPassed=True,scope='Normal Core retries through bounded per-blob HTTP response fault. Short declared body with unchanged real hash, not TCP/physical disconnection. No GUI evidence.')
        write(output/'proof.json',proof);print('PASS '+str(output/'proof.json'),flush=True)
        if args.keep_for_native:
            proof.update(retainedForNative=True,automaticRetirementAt=(dt.datetime.now().astimezone()+dt.timedelta(hours=2)).isoformat());write(output/'proof.json',proof)
            print('RETAINED '+json.dumps({'origin':origin,'ownerControl':str(owner_path),'automaticRetirementAt':proof['automaticRetirementAt']}),flush=True)
            deadline=time.monotonic()+7200
            while time.monotonic()<deadline:
                if service.app.poll() is not None:raise RuntimeError('owned backend exited while retained')
                time.sleep(1)
    except KeyboardInterrupt:proof['retiredBySignalAt']=now()
    except BaseException as error:proof.update(error=type(error).__name__+': '+str(error),failedAt=now());raise
    finally:
        if probe is not None and probe.poll() is None:
            probe.terminate()
            try:probe.wait(timeout=8)
            except subprocess.TimeoutExpired:probe.kill();probe.wait(timeout=8)
        if proxy is not None:proxy.shutdown();proxy.server_close()
        service.close();proof['cleanedOwnedResourcesAt']=now();write(output/'proof.json',proof)
        for log in logs:log.close()
        print('CLEANED '+str(output),flush=True)
if __name__=='__main__':main()
