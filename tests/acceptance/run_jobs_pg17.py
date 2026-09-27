#!/usr/bin/env python3
"""Run the three new retention/annotation restore boundaries on isolated PG17.

Cross-compiles the actual Go jobs tests and runs only these three in the already
available postgres:17 image. No host port, existing server or database is used.
The image supplies matching initdb/pg_ctl/pg_dump/pg_restore; temporary clusters
are created by the existing tests as the non-root postgres user.
"""
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import uuid

REPO = Path(__file__).resolve().parents[2]
PATTERN = '^(TestOldAndCompositeAnnotationKeysSurviveBackupRestore|TestRetentionBackupExcludesExpiredCopiesAndRestoresArchivedMedia|TestRestorePurgesTrashThatExpiresAfterTheBackupSnapshot)$'


def main():
    out = Path(tempfile.mkdtemp(prefix='tokenlibrary-jobs-pg17-')).resolve()
    out.chmod(0o755)
    (out / 'internal/jobs').mkdir(parents=True)
    (out / 'schema').mkdir()
    shutil.copyfile(REPO / 'server/schema/initial.sql', out / 'schema/initial.sql')
    info = json.loads(subprocess.check_output(['docker', 'image', 'inspect', 'postgres:17'], text=True))[0]
    arch = info['Architecture']
    if arch not in ['arm64', 'amd64']:
        raise RuntimeError('unsupported explicit test architecture')
    env = os.environ.copy()
    env.update(GOOS='linux', GOARCH=arch, CGO_ENABLED='0', GOCACHE='/tmp/tokenlibrary-server-audit-gocache', GOMODCACHE='/tmp/tokenlibrary-server-audit-gomodcache')
    print('OUTPUT ' + str(out), flush=True)
    with (out / 'build.log').open('w') as log:
        subprocess.run(['go', 'test', '-c', '-o', str(out / 'jobs.test'), './internal/jobs'], cwd=REPO / 'server', env=env, stdout=log, stderr=log, check=True)
    container = 'tl-jobs-pg17-' + uuid.uuid4().hex[:12]
    start = time.monotonic()
    proof = {'startedAt': dt.datetime.now().astimezone().isoformat(), 'output': str(out), 'container': container,
             'imageId': info['Id'], 'architecture': arch, 'testPattern': PATTERN,
             'binarySHA256': hashlib.sha256((out / 'jobs.test').read_bytes()).hexdigest(),
             'schemaSHA256': hashlib.sha256((out / 'schema/initial.sql').read_bytes()).hexdigest(),
             'network': 'none (container loopback only)', 'hostPorts': [], 'user': 'postgres',
             'scope': 'Three existing Go test cases, actual isolated PG17 initdb/dump/restore; no native UI or production deployment.'}
    try:
        with (out / 'test.log').open('w') as log:
            run = subprocess.run(['docker', 'run', '--rm', '--name', container, '--network', 'none', '--read-only',
                '--user', 'postgres', '--tmpfs', '/tmp:rw,exec,mode=1777,size=2g',
                '-v', str(out) + ':/probe:ro', '-w', '/probe/internal/jobs',
                '-e', 'TOKENLIBRARY_JOBS_INTEGRATION=1', '--entrypoint', '/probe/jobs.test',
                'postgres:17', '-test.v', '-test.count=1', '-test.timeout=180s', '-test.run=' + PATTERN],
                stdout=log, stderr=log, timeout=210)
        output = (out / 'test.log').read_text()
        proof.update(exitCode=run.returncode, passed=output.count('--- PASS:'), failed=output.count('--- FAIL:'), skipped=output.count('--- SKIP:'), elapsedSeconds=time.monotonic() - start)
        if run.returncode or proof['passed'] != 3 or proof['failed'] or proof['skipped']:
            raise RuntimeError('PG17 boundary tests did not all pass; inspect test.log')
        print('PASS ' + str(out / 'proof.json'), flush=True)
    finally:
        # The randomly named container belongs only to this invocation. --rm
        # handles normal completion; this exact fallback covers timeout/abort.
        subprocess.run(['docker', 'rm', '-f', container], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        proof['endedAt'] = dt.datetime.now().astimezone().isoformat()
        proof['cleanupOwnedContainerOnly'] = True
        (out / 'proof.json').write_text(json.dumps(proof, ensure_ascii=False, indent=2) + '\n')


if __name__ == '__main__':
    main()
