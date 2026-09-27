#!/usr/bin/env python3
"""Replace only an owned fixture's proxy; preserve backend/PG and original lease."""
import argparse,datetime as dt,json,os,signal,socket,subprocess,threading,time,urllib.request
from pathlib import Path
from verify_attachment_recovery import FaultControl,make_handler,write,now
import http.server

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--control',required=True,type=Path);p.add_argument('--expected-supervisor',required=True,type=int)
    a=p.parse_args();control_path=a.control.resolve();owner=json.loads(control_path.read_text());out=control_path.parent
    assert out.name.startswith('tokenlibrary-attachment-recovery-') and owner['output']==str(out)
    assert owner['supervisorPID']==a.expected_supervisor
    command=subprocess.check_output(['ps','-p',str(owner['serverPID']),'-o','command='],text=True).strip()
    assert command==str(out/'tokenlibrary'),'backend process identity mismatch'
    assert owner['origin'].startswith('http://127.0.0.1:') and owner['backendOrigin'].startswith('http://127.0.0.1:')
    with urllib.request.urlopen(owner['backendOrigin']+'/health/ready',timeout=2) as r:ready=json.load(r)
    assert ready['ready'] and not ready['maintenance']
    proof=json.loads((out/'proof.json').read_text());deadline=dt.datetime.fromisoformat(proof['automaticRetirementAt'])
    assert 0<(deadline-dt.datetime.now().astimezone()).total_seconds()<=7200
    control=FaultControl(out);control.run_id=owner['runId'];control.secret=owner['controlKey']
    for target in proof['targets'].values():control.register(target)
    control.phase='proxy-upgrade-healthy'
    proxy=None;owns_backend=False
    def stop(_sig,_frame):raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM,stop);signal.signal(signal.SIGINT,stop)
    write(out/'proxy-upgrade-waiting.json',{'pid':os.getpid(),'oldSupervisor':a.expected_supervisor,'backendPID':owner['serverPID'],'at':now()})
    print('WAITING_FOR_OWNED_PROXY_HANDOFF',flush=True)
    try:
        port=int(owner['origin'].rsplit(':',1)[1])
        for _ in range(300):
            try:proxy=http.server.ThreadingHTTPServer(('127.0.0.1',port),make_handler(owner['backendOrigin'],control));break
            except OSError:time.sleep(.1)
        if proxy is None:raise RuntimeError('same-port takeover timeout')
        owns_backend=True;proxy.daemon_threads=True;threading.Thread(target=proxy.serve_forever,daemon=True).start()
        owner['previousSupervisorPID']=owner['supervisorPID'];owner['supervisorPID']=os.getpid();owner['proxyUpgradedAt']=now()
        write(control_path,owner);control_path.chmod(0o600)
        write(out/'proxy-upgrade-ready.json',{'pid':os.getpid(),'backendPID':owner['serverPID'],'origin':owner['origin'],'runId':control.run_id,'at':now(),'deadline':deadline.isoformat()})
        print('READY '+owner['origin'],flush=True)
        while dt.datetime.now().astimezone()<deadline:
            os.kill(owner['serverPID'],0);time.sleep(1)
    except KeyboardInterrupt:pass
    finally:
        if proxy is not None:proxy.shutdown();proxy.server_close()
        if owns_backend:
            # Re-check exact binary before terminating the adopted, synthetic backend.
            try:
                current=subprocess.check_output(['ps','-p',str(owner['serverPID']),'-o','command='],text=True).strip()
                if current==str(out/'tokenlibrary'):os.kill(owner['serverPID'],signal.SIGTERM)
            except (subprocess.CalledProcessError,ProcessLookupError):pass
            subprocess.run(['docker','rm','-f',owner['container']],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            write(out/'retired.json',{'at':now(),'proxyPID':os.getpid(),'scope':'only this synthetic backend/container'})
            print('RETIRED_OWNED_FIXTURE',flush=True)
if __name__=='__main__':main()
