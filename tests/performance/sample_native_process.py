#!/usr/bin/env python3
"""Read CPU/RSS for one explicitly selected verification app; never drive its UI."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import platform
import statistics
import subprocess
import time


def cpu_seconds(value):
    days = 0
    if '-' in value:
        day, value = value.split('-', 1)
        days = int(day)
    parts = value.split(':')
    if len(parts) not in (2, 3):
        raise ValueError('Unexpected process CPU time: ' + value)
    total = float(parts[-1]) + 60 * int(parts[-2])
    if len(parts) == 3:
        total += 3600 * int(parts[-3])
    return days * 86400 + total


def parse_process(line):
    # Darwin lstart has exactly five fields under the forced C locale. comm is
    # last, so an executable path containing spaces remains one field.
    parts = line.strip().split(maxsplit=9)
    if len(parts) != 10:
        raise ValueError('Process disappeared or ps returned an unexpected row')
    return {'pid': int(parts[0]), 'cpuSeconds': cpu_seconds(parts[1]),
            'rssBytes': int(parts[2]) * 1024, 'state': parts[3],
            'started': ' '.join(parts[4:9]), 'executable': parts[9]}


def process(pid):
    result = subprocess.run(['/bin/ps', '-ww', '-p', str(pid), '-o',
                             'pid=,time=,rss=,state=,lstart=,comm='],
                            capture_output=True, text=True,
                            env={**os.environ, 'LC_ALL': 'C'}, timeout=5)
    if result.returncode or not result.stdout.strip():
        return None
    return parse_process(result.stdout)


def verification_bundle(executable):
    path = Path(executable).resolve(strict=True)
    bundle = next((p for p in path.parents if p.suffix == '.app'), None)
    if bundle is None:
        raise ValueError('Expected an executable inside a verification .app')
    info_path = bundle / 'Contents' / 'Info.plist'
    if not info_path.exists():
        info_path = bundle / 'Info.plist'  # iOS Simulator layout
    info = plistlib.loads(info_path.read_bytes())
    bundle_id = info.get('CFBundleIdentifier', '')
    prefix = 'app.tokenlibrary.verification.'
    if bundle_id != 'app.tokenlibrary.verification' and not (bundle_id.startswith(prefix) and len(bundle_id) > len(prefix)):
        raise ValueError('Refusing a non-verification application')
    return path, bundle_id


def percentile(values, p):
    return sorted(values)[max(0, math.ceil(len(values) * p) - 1)] if values else None


def summarize(samples, markers):
    rss = [s['rssBytes'] for s in samples]
    cpu = [s['intervalCPUPercent'] for s in samples if s['intervalCPUPercent'] is not None]
    phases = []
    for marker in markers:
        # A separately invoked marker process may have a different monotonic
        # epoch. Preserve its raw fields, but align phases by the shared wall
        # clock. Resource deltas still use only the sampler's monotonic clock.
        use_wall_clock = 'wallTime' in marker and all('wallTime' in s for s in samples)
        key = 'wallTime' if use_wall_clock else 'monotonicNS'
        phases.append({**marker, 'alignment': key, 'nearbySample': next((i for i, s in enumerate(samples)
                      if s[key] >= marker[key]), None)})
    return {'samples': len(samples), 'sampledRSSMaxBytes': max(rss) if rss else None,
            'sampledRSSP95Bytes': percentile(rss, .95),
            'intervalCPUMedianPercent': statistics.median(cpu) if cpu else None,
            'intervalCPUP95Percent': percentile(cpu, .95), 'markers': phases,
            'limits': ['RSS is sampled resident memory, not physical footprint or a guaranteed peak.',
                       'CPU percent is process CPU-time delta / monotonic elapsed time; multicore can exceed 100%.',
                       'WebKit child processes and WindowServer are not included in this PID.',
                       'Manual markers label journeys; their duration is not frame time or exact UI-response latency.',
                       'Simulator process measurements are not iPhone hardware measurements.']}


def phase_report(samples, markers):
    """Label resource samples in operator windows, without inferring UI latency."""
    windows, opened = [], {}
    for marker in sorted(markers, key=lambda item: item['wallTime']):
        label, event = marker['label'], marker['event']
        if event == 'begin':
            if label in opened:
                windows.append((opened.pop(label), marker, 'restarted-without-end'))
            opened[label] = marker
        elif event == 'end' and label in opened:
            windows.append((opened.pop(label), marker, 'complete'))
    if samples:
        windows.extend((start, {'wallTime': samples[-1]['wallTime']}, 'open-at-last-sample')
                       for start in opened.values())
    result = []
    for begin, end, status in sorted(windows, key=lambda item: item[0]['wallTime']):
        points = [sample for sample in samples
                  if begin['wallTime'] <= sample['wallTime'] < end['wallTime']]
        # An interval CPU value spans the previous and current sample. Exclude
        # the first point so that it cannot include work before the phase.
        cpu = [point['intervalCPUPercent'] for point in points[1:]
               if point['intervalCPUPercent'] is not None]
        rss = [point['rssBytes'] for point in points]
        result.append({'label': begin['label'], 'status': status,
                       'beginWallTime': begin['wallTime'], 'endWallTime': end['wallTime'],
                       'operatorWindowSeconds': end['wallTime'] - begin['wallTime'],
                       'sampleCount': len(points), 'cpuIntervalCount': len(cpu),
                       'sampledRSSMinBytes': min(rss) if rss else None,
                       'sampledRSSMaxBytes': max(rss) if rss else None,
                       'sampledRSSEndBytes': rss[-1] if rss else None,
                       'intervalCPUMedianPercent': statistics.median(cpu) if cpu else None,
                       'intervalCPUP95Percent': percentile(cpu, .95)})
    return result


def read_json_lines(path):
    records, incomplete = [], 0
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            incomplete += 1
    return records, incomplete


def report(args):
    output = Path(args.output).resolve()
    manifest = json.loads((output / 'manifest.json').read_text())
    samples, sample_errors = read_json_lines(output / 'samples.jsonl')
    markers, marker_errors = read_json_lines(output / 'markers.jsonl')
    result = {**summarize(samples, markers), 'manifest': manifest,
              'phases': phase_report(samples, markers),
              'reportCreatedWallTime': time.time(),
              'ignoredIncompleteLines': {'samples': sample_errors, 'markers': marker_errors},
              'analysisSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
    # Preserve raw capture output, including summaries produced by a sampler
    # already running when the analysis tool was updated.
    (output / 'report.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, ensure_ascii=False))


def sample(args):
    if platform.system() != 'Darwin':
        raise ValueError('This sampler uses Darwin ps output')
    if not 0.2 <= args.interval <= 5 or not 0 < args.duration <= 3600:
        raise ValueError('Use interval 0.2...5 seconds and duration 0...3600 seconds')
    executable, bundle_id = verification_bundle(args.executable)
    initial = process(args.pid)
    if initial is None or Path(initial['executable']).resolve() != executable:
        raise ValueError('PID does not belong to the exact expected executable')
    output = Path(args.output).resolve()
    if output.exists():
        raise ValueError('Output directory already exists; choose a new run')
    output.mkdir(parents=True)
    (output / 'markers.jsonl').touch()
    manifest = {'pid': args.pid, 'executable': str(executable), 'bundleID': bundle_id,
                'processStarted': initial['started'], 'intervalSeconds': args.interval,
                'requestedDurationSeconds': args.duration, 'host': platform.platform(),
                'logicalCPUs': os.cpu_count(), 'executableSHA256': hashlib.sha256(executable.read_bytes()).hexdigest(),
                'readOnlyProcessInspection': True, 'guiAutomation': False}
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps({'sampling': args.pid, 'output': str(output)}, ensure_ascii=False), flush=True)
    samples, reason = [], 'duration-complete'
    started, deadline = time.monotonic(), time.monotonic() + args.duration
    previous = None
    try:
        with (output / 'samples.jsonl').open('w') as handle:
            while True:
                before = time.monotonic_ns()
                current = process(args.pid)
                after = time.monotonic_ns()
                if current is None:
                    reason = 'process-exited'
                    break
                if current['started'] != initial['started'] or Path(current['executable']).resolve() != executable:
                    reason = 'process-identity-changed'
                    break
                current.update(monotonicNS=(before + after) // 2, wallTime=time.time(),
                               inspectionMS=(after - before) / 1_000_000, intervalCPUPercent=None)
                if previous is not None:
                    elapsed = (current['monotonicNS'] - previous['monotonicNS']) / 1e9
                    current['intervalCPUPercent'] = 100 * max(0, current['cpuSeconds'] - previous['cpuSeconds']) / elapsed
                samples.append(current)
                handle.write(json.dumps(current) + '\n')
                handle.flush()
                previous = current
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                time.sleep(min(args.interval, remaining))
    except KeyboardInterrupt:
        reason = 'sampler-interrupted'
    markers = []
    for line in (output / 'markers.jsonl').read_text().splitlines():
        try:
            markers.append(json.loads(line))
        except json.JSONDecodeError:
            reason += '; incomplete-marker-line'
    summary = {**summarize(samples, markers), 'stopReason': reason, 'elapsedSeconds': time.monotonic() - started}
    (output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, ensure_ascii=False), flush=True)


def mark(args):
    output = Path(args.output).resolve()
    if not (output / 'manifest.json').exists():
        raise ValueError('No sampler manifest at the given output directory')
    wall_time, process_monotonic = time.time(), time.monotonic_ns()
    anchor = None
    sample_path = output / 'samples.jsonl'
    if sample_path.exists():
        with sample_path.open() as handle:
            first = handle.readline()
        if first.strip():
            anchor = json.loads(first)
    # Also make new marker monotonic fields comparable to older sampler builds
    # that are already running. Their final summary is rechecked by wall time.
    mapped = (anchor['monotonicNS'] + round((wall_time - anchor['wallTime']) * 1e9)) if anchor else None
    record = {'label': args.label, 'event': args.event, 'monotonicNS': mapped,
              'processMonotonicNS': process_monotonic, 'wallTime': wall_time,
              'clockAlignment': 'wallTime to first sampler timestamp' if anchor else 'awaiting first sampler timestamp'}
    with (output / 'markers.jsonl').open('a') as handle:
        handle.write(json.dumps(record, ensure_ascii=False) + '\n')
    print(json.dumps(record, ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    capture = commands.add_parser('sample')
    capture.add_argument('--pid', type=int, required=True)
    capture.add_argument('--executable', required=True)
    capture.add_argument('--output', required=True)
    capture.add_argument('--duration', type=float, default=60)
    capture.add_argument('--interval', type=float, default=1)
    capture.set_defaults(run=sample)
    marker = commands.add_parser('mark')
    marker.add_argument('--output', required=True)
    marker.add_argument('--label', required=True)
    marker.add_argument('--event', choices=['begin', 'end', 'checkpoint'], default='checkpoint')
    marker.set_defaults(run=mark)
    analysis = commands.add_parser('report')
    analysis.add_argument('--output', required=True)
    analysis.set_defaults(run=report)
    args = parser.parse_args()
    args.run(args)


if __name__ == '__main__':
    main()
