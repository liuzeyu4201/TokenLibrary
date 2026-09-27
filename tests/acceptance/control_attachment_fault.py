#!/usr/bin/env python3
"""Only control an explicitly owned attachment fixture, never a product server."""
import argparse,json,urllib.request
from pathlib import Path

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--control',type=Path,required=True);p.add_argument('--expected-origin',required=True)
    p.add_argument('--mode',choices=['healthy','503','truncated'],required=True)
    p.add_argument('--expected-mode',choices=['healthy','503','truncated'],required=True)
    p.add_argument('--blob-id');p.add_argument('--failures',type=int,default=3);p.add_argument('--ttl',type=int,default=120)
    args=p.parse_args();path=args.control.resolve()
    if path.name!='owner-control.json' or not path.parent.name.startswith('tokenlibrary-attachment-recovery-'):p.error('owned control file required')
    owner=json.loads(path.read_text());origin=owner['origin']
    if args.expected_origin!=origin or not origin.startswith('http://127.0.0.1:'):p.error('explicit origin mismatch')
    with urllib.request.urlopen(origin+'/__fixture/status',timeout=3) as response:status=json.load(response)
    if status['runId']!=owner['runId']:p.error('fixture identity mismatch')
    command={'runId':owner['runId'],'expectedMode':args.expected_mode,'mode':args.mode,'blobId':args.blob_id,'failures':args.failures,'ttlSeconds':args.ttl,'phase':'native-explicit-control'}
    req=urllib.request.Request(origin+'/__fixture/control',data=json.dumps(command).encode(),headers={'Content-Type':'application/json','X-Fixture-Control':owner['controlKey']},method='POST')
    with urllib.request.urlopen(req,timeout=3) as response:print(json.dumps(json.load(response),indent=2))
if __name__=='__main__':main()
