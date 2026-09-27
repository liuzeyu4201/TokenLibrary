#!/usr/bin/env python3
"""Finite loopback-only readiness fixture. Never reads login bodies or stores credentials."""
import argparse, datetime as dt, hmac, http.server, json, os, secrets, signal, socket, threading, time, urllib.error, urllib.request, uuid
from pathlib import Path

MODES={'healthy','protocol426','html'}
def now(): return dt.datetime.now().astimezone().isoformat()
def write(path,value):
    path.write_text(json.dumps(value,ensure_ascii=False,indent=2));path.chmod(0o600)
class Mode:
    def __init__(self,clock=time.monotonic):self.mode='healthy';self.until=0;self.clock=clock;self.lock=threading.Lock()
    def state(self):
        with self.lock:
            if self.mode!='healthy' and self.clock()>=self.until:self.mode='healthy';self.until=0
            return {'mode':self.mode,'remainingSeconds':max(0,self.until-self.clock()) if self.mode!='healthy' else 0}
    def change(self,expected,value,ttl):
        if value not in MODES or not isinstance(ttl,int) or isinstance(ttl,bool) or not 1<=ttl<=240:raise ValueError('invalid mode or TTL')
        current=self.state()
        with self.lock:
            if current['mode']!=expected:raise ValueError('expected mode mismatch')
            self.mode=value;self.until=self.clock()+ttl if value!='healthy' else 0
        return self.state()

def serve(args):
    out=args.output.resolve()
    if not out.name.startswith('tokenlibrary-connection-errors-') or out.exists():raise SystemExit('new dedicated temporary output required')
    if not (str(out).startswith('/private/tmp/') or str(out).startswith('/tmp/')) or not 60<=args.ttl<=3600:raise SystemExit('temporary path and bounded TTL required')
    out.mkdir(mode=0o700);control=Mode();run_id=str(uuid.uuid4());key=secrets.token_urlsafe(32);start=time.monotonic();expires=start+args.ttl
    event_lock=threading.Lock();events=[]
    def log(method,route,status,mode):
        # No raw path/query, headers, body, username/password, or exception text.
        row={'at':now(),'method':method if method in ['GET','POST','HEAD'] else 'OTHER','route':route,'status':status,'mode':mode}
        with event_lock:
            events.append(row)
            with (out/'requests.jsonl').open('a') as f:f.write(json.dumps(row)+'\n')
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version='HTTP/1.1'
        def log_message(self,*_args):pass
        def send(self,status,value,ctype='application/json',route='other'):
            mode=control.state()['mode'];raw=value if isinstance(value,bytes) else json.dumps(value).encode()
            self.send_response(status);self.send_header('Content-Type',ctype);self.send_header('Content-Length',str(len(raw)));self.send_header('Cache-Control','no-store');self.send_header('Connection','close');self.end_headers();self.close_connection=True
            try:self.wfile.write(raw)
            except (BrokenPipeError,ConnectionResetError):pass
            log(self.command,route,status,mode)
        def do_GET(self):
            if self.path=='/__fixture/status':return self.send(200,{'runId':run_id,**control.state(),'lifetimeRemainingSeconds':max(0,expires-time.monotonic())},route='status')
            if self.path!='/health/ready':return self.send(404,{'error':{'code':'NOT_FOUND'}},route='other')
            mode=control.state()['mode']
            if mode=='protocol426':return self.send(426,{'error':{'code':'PROTOCOL_UNSUPPORTED','message':'Synthetic readiness protocol mismatch','retryable':False}},route='health')
            if mode=='html':return self.send(200,b'<!doctype html><title>Synthetic non-JSON readiness</title><p>Fixture only.</p>','text/html; charset=utf-8',route='health')
            return self.send(200,{'ready':True,'maintenance':False},route='health')
        def do_POST(self):
            if self.path!='/__fixture/control':
                # In particular, never consume /auth/login request bodies.
                return self.send(405,{'error':{'code':'TEST_CONNECTION_ONLY','message':'This fixture does not accept logins or account data.','retryable':False}},route='login-rejected' if self.path=='/api/v1/auth/login' else 'post-rejected')
            if not hmac.compare_digest(self.headers.get('X-Fixture-Control',''),key):return self.send(403,{'error':{'code':'CONTROL_DENIED'}},route='control')
            try:
                n=int(self.headers.get('Content-Length','0'))
                if not 1<=n<=1024:raise ValueError()
                value=json.loads(self.rfile.read(n))
                if value.get('runId')!=run_id:raise ValueError()
                result=control.change(value['expectedMode'],value['mode'],value.get('ttlSeconds',240))
            except (ValueError,KeyError,TypeError):return self.send(409,{'error':{'code':'CONTROL_GUARD'}},route='control')
            write(out/'last-control.json',{'at':now(),'runId':run_id,**result})
            return self.send(200,{'runId':run_id,**result},route='control')
        def do_HEAD(self):self.send(405,{},route='head-rejected')
    server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler);server.daemon_threads=True
    refused=socket.socket();refused.bind(('127.0.0.1',0));refused_port=refused.getsockname()[1];refused.close() # macOS bound-but-not-listening times out; verify the closed port immediately before native use.
    origin='http://127.0.0.1:'+str(server.server_address[1]);refused_origin='http://127.0.0.1:'+str(refused_port)
    deadline=(dt.datetime.now().astimezone()+dt.timedelta(seconds=args.ttl)).isoformat()
    owner={'runId':run_id,'controlKey':key,'origin':origin,'refusedOrigin':refused_origin,'pid':os.getpid(),'output':str(out),'automaticRetirementAt':deadline,'script':str(Path(__file__).resolve())};write(out/'owner.json',owner)
    manifest={k:v for k,v in owner.items() if k!='controlKey'};manifest.update(mode='healthy',routes={'GET /health/ready':'healthy initially; guarded 426 or 200 HTML only when explicitly selected','POST /api/v1/auth/login':'405 before reading body; no account/session backend'},logs='only time, method enum, route enum, status, mode; no headers/query/body')
    write(out/'manifest.json',manifest)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    def stop(_sig,_frame):raise KeyboardInterrupt
    signal.signal(signal.SIGTERM,stop);signal.signal(signal.SIGINT,stop)
    print('READY '+json.dumps(manifest,ensure_ascii=False),flush=True)
    try:
        while time.monotonic()<expires:control.state();time.sleep(.25)
    except KeyboardInterrupt:pass
    finally:
        server.shutdown();server.server_close();refused.close();write(out/'retired.json',{'at':now(),'pid':os.getpid(),'scope':'only owned HTTP server; refused port was already closed','requests':len(events)});print('RETIRED '+str(out),flush=True)

def remote(args):
    p=args.owner.resolve();owner=json.loads(p.read_text())
    if not p.parent.name.startswith('tokenlibrary-connection-errors-') or owner['output']!=str(p.parent) or owner['origin']!=args.expected_origin or not owner['origin'].startswith('http://127.0.0.1:'):raise SystemExit('owner/origin guard mismatch')
    req=urllib.request.Request(owner['origin']+'/__fixture/status')
    with urllib.request.urlopen(req,timeout=2) as r:status=json.load(r)
    if status['runId']!=owner['runId']:raise SystemExit('run identity mismatch')
    if args.action=='status':print(json.dumps(status));return
    value={'runId':owner['runId'],'expectedMode':args.expected_mode,'mode':args.mode,'ttlSeconds':args.fault_ttl}
    req=urllib.request.Request(owner['origin']+'/__fixture/control',data=json.dumps(value).encode(),headers={'Content-Type':'application/json','X-Fixture-Control':owner['controlKey']},method='POST')
    with urllib.request.urlopen(req,timeout=2) as r:print(r.read().decode())

def selftest():
    current=[0.0];m=Mode(lambda:current[0]);assert m.state()['mode']=='healthy';m.change('healthy','html',1);current[0]=1.01;assert m.state()['mode']=='healthy'
    for expected,value,ttl in [('html','protocol426',10),('healthy','x',2),('healthy','html',241),('healthy','html',True)]:
        try:m.change(expected,value,ttl);raise AssertionError('guard accepted')
        except ValueError:pass
    sock=socket.socket();sock.bind(('127.0.0.1',0));address=sock.getsockname();sock.close()
    try:
        try:socket.create_connection(address,timeout=1);raise AssertionError('non-listening port connected')
        except ConnectionRefusedError:pass
    finally:sock.close()
    print('PASS mode expiry, expected-state guard, valid enum, 240s cap, integer TTL, closed-port refusal')
if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);sub=parser.add_subparsers(dest='action',required=True)
    run=sub.add_parser('serve');run.add_argument('--output',type=Path,required=True);run.add_argument('--ttl',type=int,default=1800)
    sub.add_parser('selftest')
    for action in ['status','control']:
        p=sub.add_parser(action);p.add_argument('--owner',type=Path,required=True);p.add_argument('--expected-origin',required=True)
        if action=='control':p.add_argument('--expected-mode',choices=sorted(MODES),required=True);p.add_argument('--mode',choices=sorted(MODES),required=True);p.add_argument('--fault-ttl',type=int,default=240)
    args=parser.parse_args()
    if args.action=='serve':serve(args)
    elif args.action=='selftest':selftest()
    else:remote(args)
