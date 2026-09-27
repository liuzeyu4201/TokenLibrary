import importlib.util
import os
from pathlib import Path
import plistlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('sampler', Path(__file__).with_name('sample_native_process.py'))
sampler = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sampler)


class NativeSamplerTests(unittest.TestCase):
    def test_cpu_clock_units_and_long_runs(self):
        self.assertEqual(sampler.cpu_seconds('00:01.25'), 1.25)
        self.assertEqual(sampler.cpu_seconds('12:03.50'), 723.5)
        self.assertEqual(sampler.cpu_seconds('02:03:04.50'), 7384.5)
        self.assertEqual(sampler.cpu_seconds('2-02:03:04.50'), 180184.5)
        with self.assertRaises(ValueError):
            sampler.cpu_seconds('invalid')

    def test_darwin_process_row_preserves_executable_spaces(self):
        row = sampler.parse_process(' 123 00:01.25 2048 S Sun Sep 27 01:30:00 2026 /private/tmp/One App.app/Contents/MacOS/TokenLibrary')
        self.assertEqual(row['rssBytes'], 2 * 1024 * 1024)
        self.assertEqual(row['cpuSeconds'], 1.25)
        self.assertEqual(row['started'], 'Sun Sep 27 01:30:00 2026')
        self.assertEqual(row['executable'], '/private/tmp/One App.app/Contents/MacOS/TokenLibrary')
        with self.assertRaises(ValueError):
            sampler.parse_process('')

    def test_only_verification_bundle_is_accepted_without_launching_it(self):
        with tempfile.TemporaryDirectory() as temp:
            contents = Path(temp) / 'Synthetic.app' / 'Contents'
            executable = contents / 'MacOS' / 'TokenLibrary'
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b'fixture; never executed')
            info = contents / 'Info.plist'
            for bundle_id in ['app.tokenlibrary.verification', 'app.tokenlibrary.verification.performance']:
                info.write_bytes(plistlib.dumps({'CFBundleIdentifier': bundle_id}))
                self.assertEqual(sampler.verification_bundle(executable)[1], bundle_id)
            for bundle_id in ['app.tokenlibrary.macos', 'app.tokenlibrary.verification-other', 'app.tokenlibrary.verification.']:
                info.write_bytes(plistlib.dumps({'CFBundleIdentifier': bundle_id}))
                with self.assertRaises(ValueError):
                    sampler.verification_bundle(executable)

    def test_live_ps_reads_only_own_non_gui_process(self):
        row = sampler.process(os.getpid())
        self.assertEqual(row['pid'], os.getpid())
        self.assertGreater(row['rssBytes'], 0)
        self.assertGreaterEqual(row['cpuSeconds'], 0)
        self.assertTrue(Path(row['executable']).is_absolute())

    def test_resource_summary_does_not_label_markers_as_ui_latency(self):
        samples = [{'rssBytes': n * 1024, 'intervalCPUPercent': None if n == 1 else n * 10, 'monotonicNS': n * 1_000} for n in range(1, 21)]
        result = sampler.summarize(samples, [{'label': 'search', 'event': 'begin', 'monotonicNS': 2_001}])
        self.assertEqual(result['sampledRSSMaxBytes'], 20 * 1024)
        self.assertEqual(result['sampledRSSP95Bytes'], 19 * 1024)
        self.assertEqual(result['markers'][0]['nearbySample'], 2)
        self.assertNotIn('uiLatencyP95', result)

    def test_markers_from_a_different_monotonic_epoch_align_by_wall_time(self):
        samples = [{'rssBytes': 1024, 'intervalCPUPercent': 0, 'monotonicNS': (i + 1) * 1_000_000_000,
                    'wallTime': 100 + i} for i in range(3)]
        # The marker subprocess started later and its monotonic clock is only
        # 5ms old. Using that raw value would incorrectly pick the first sample.
        result = sampler.summarize(samples, [{'label': 'search', 'event': 'begin',
                  'monotonicNS': 5_000_000, 'wallTime': 101.25}])
        self.assertEqual(result['markers'][0]['nearbySample'], 2)
        self.assertEqual(result['markers'][0]['alignment'], 'wallTime')

    def test_phase_cpu_excludes_interval_before_begin_and_marks_open_window(self):
        samples = [{'rssBytes': i * 1024, 'intervalCPUPercent': [None, 100, 20, 0][i],
                    'monotonicNS': i, 'wallTime': 100 + i} for i in range(4)]
        phases = sampler.phase_report(samples, [
            {'label': 'search', 'event': 'begin', 'wallTime': 100.5},
            {'label': 'search', 'event': 'end', 'wallTime': 102.5},
            {'label': 'idle', 'event': 'begin', 'wallTime': 102.5}])
        self.assertEqual(phases[0]['sampleCount'], 2)
        self.assertEqual(phases[0]['cpuIntervalCount'], 1)
        self.assertEqual(phases[0]['intervalCPUP95Percent'], 20)
        self.assertEqual(phases[0]['sampledRSSMaxBytes'], 2048)
        self.assertEqual(phases[1]['status'], 'open-at-last-sample')
        self.assertEqual(phases[1]['cpuIntervalCount'], 0)

    def test_partial_jsonl_is_reported_without_discarding_valid_records(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'samples.jsonl'
            path.write_text('{"value": 1}\n{"value":')
            records, incomplete = sampler.read_json_lines(path)
            self.assertEqual(records, [{'value': 1}])
            self.assertEqual(incomplete, 1)


if __name__ == '__main__':
    unittest.main()
