#!/usr/bin/env python3
"""Prepare/register one new synthetic blob, then arm/publish only on an explicit stage."""
import argparse,json,os,subprocess,tempfile,urllib.request,uuid
from pathlib import Path
from synthetic_service import REPO

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('action',choices=['prepare','publish'])
    p.add_argument('--control',type=Path,required=True);p.add_argument('--expected-origin',required=True);p.add_argument('--publisher',type=Path,required=True)
    p.add_argument('--pdf',type=Path);p.add_argument('--plan',type=Path);p.add_argument('--mode',choices=['503','truncated'],default='503')
    p.add_argument('--ttl',type=int,default=240);p.add_argument('--failures',type=int,default=100)
    args=p.parse_args();control_path=args.control.resolve();owner=json.loads(control_path.read_text());origin=owner['origin'];out=control_path.parent
    if not out.name.startswith('tokenlibrary-attachment-recovery-') or origin!=args.expected_origin or not origin.startswith('http://127.0.0.1:'):p.error('owned origin/path guard mismatch')
    def status():
        with urllib.request.urlopen(origin+'/__fixture/status',timeout=3) as response:return json.load(response)
    def command(path,data):
        req=urllib.request.Request(origin+path,data=json.dumps(data).encode(),headers={'Content-Type':'application/json','X-Fixture-Control':owner['controlKey']},method='POST')
        with urllib.request.urlopen(req,timeout=3) as response:return json.load(response)
    initial=status()
    if initial['runId']!=owner['runId'] or initial['mode']!='healthy':p.error('fixture must match and be healthy before this stage')
    env=os.environ.copy();env.update(TEST_TOKENLIBRARY_USER='e2e',TEST_TOKENLIBRARY_PASSWORD='e2e-password')
    if args.action=='prepare':
        if not args.pdf or not args.pdf.is_file():p.error('explicit synthetic PDF required')
        plan_dir=out/('u5-plan-'+uuid.uuid4().hex[:12])
        subprocess.run([str(args.publisher.resolve()),'prepare',origin,str(plan_dir),str(args.pdf.resolve())],env=env,check=True)
        plan_file=plan_dir/'prepared.json';plan=json.loads(plan_file.read_text())
        result=command('/__fixture/register',{'runId':owner['runId'],'expectedMode':'healthy','target':plan['target']})
        (plan_dir/'registered.json').write_text(json.dumps({'runId':owner['runId'],'mode':result['mode'],'target':plan['target']},indent=2))
        print(json.dumps({'plan':str(plan_file),'objectId':plan['objectId'],'name':plan['name'],'target':plan['target'],'published':False,'faultEnabled':False},ensure_ascii=False,indent=2))
    else:
        if not args.plan:p.error('frozen plan required')
        plan_file=args.plan.resolve()
        if not plan_file.is_relative_to(out) or plan_file.name!='prepared.json':p.error('plan must belong to this fixture')
        plan=json.loads(plan_file.read_text());blob=plan['target']['id'];published=plan_file.parent/'published.json'
        if published.exists():print(published.read_text());return
        if plan['origin']!=origin or initial['allowedTargets'].get(blob)!=plan['target']:p.error('registered target differs from frozen plan')
        result=command('/__fixture/control',{'runId':owner['runId'],'expectedMode':'healthy','mode':args.mode,'blobId':blob,'failures':args.failures,'ttlSeconds':args.ttl,'phase':'native-u5-new-pdf'})
        (plan_file.parent/'armed.json').write_text(json.dumps(result,indent=2))
        try:subprocess.run([str(args.publisher.resolve()),'publish',str(plan_file)],env=env,check=True)
        except BaseException:
            current=status();command('/__fixture/control',{'runId':owner['runId'],'expectedMode':current['mode'],'mode':'healthy','phase':'native-u5-publish-error'});raise
        print(json.dumps({'published':str(published),'origin':origin,'fault':status()},ensure_ascii=False,indent=2))
if __name__=='__main__':main()
