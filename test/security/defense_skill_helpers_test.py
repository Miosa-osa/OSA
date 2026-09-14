"""Local deterministic tests; no models, services, network, or sample execution."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def module(relative, name):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


LOG = module('priv/skills/log-analysis/scripts/summarize_jsonl.py', 'osa_jsonl')
EMAIL = module('priv/skills/email-security/scripts/headers.py', 'osa_email')


class HelpersTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.path = Path(self.directory.name) / 'fixture'

    def tearDown(self):
        self.directory.cleanup()

    def test_log_counts_and_reports_malformed_and_missing_fields(self):
        self.path.write_text('{"event_type":"login_failure","timestamp":"2026-09-14T00:00:00Z"}\n'
                             '{"event_type":"login_success"}\nbroken\n[]\n'
                             '{"event_type":[]}\n')
        result = LOG.summarize(self.path)
        self.assertEqual(result['valid_records'], 2)
        self.assertEqual(result['event_types'], {'login_failure': 1, 'login_success': 1})
        self.assertEqual(result['malformed_lines'], [3, 4, 5])
        self.assertEqual(result['missing_timestamps'], 1)

    def test_empty_log_has_zero_observations(self):
        self.path.write_text('')
        self.assertEqual(LOG.summarize(self.path)['valid_records'], 0)

    def test_invalid_utf8_is_reported(self):
        self.path.write_bytes(b'\xff\n')
        self.assertEqual(LOG.summarize(self.path)['malformed_lines'], [1])

    def test_deeply_nested_json_is_reported(self):
        self.path.write_text('[' * 2000 + ']' * 2000 + '\n')
        self.assertEqual(LOG.summarize(self.path)['malformed_lines'], [1])

    def test_byte_bound_and_line_bound_fail(self):
        self.path.write_bytes(b'x' * 100)
        with self.assertRaises(ValueError):
            LOG.summarize(self.path, max_bytes=10)
        self.path.write_bytes(b'x' * 1_000_001)
        with self.assertRaises(ValueError):
            LOG.summarize(self.path)

    def test_malformed_log_cli_is_failure(self):
        self.path.write_text('broken\n')
        result = subprocess.run([sys.executable, LOG.__file__, str(self.path)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout)['malformed_lines'], [1])

    def test_header_duplicates_remain_untrusted_and_body_is_not_parsed(self):
        self.path.write_bytes(b'From: sender@example.test\r\n'
                              b'Authentication-Results: untrusted.test; dmarc=pass\r\n'
                              b'Authentication-Results: trusted.test; dmarc=fail\r\n\r\n'
                              b'<script>fetch("https://invalid.example")</script>\r\n'
                              b'From: malicious-body@example.test\r\n')
        result = EMAIL.extract(self.path)
        self.assertEqual(len(result['headers']['Authentication-Results']), 2)
        self.assertEqual(result['headers']['From'], ['sender@example.test'])
        self.assertIn('Untrusted', result['note'])
        self.assertNotIn('fetch(', json.dumps(result))

    def test_large_body_does_not_expand_header_budget(self):
        self.path.write_bytes(b'From: test@example.test\n\n' + b'x' * 1_000_001)
        self.assertEqual(EMAIL.extract(self.path)['headers']['From'], ['test@example.test'])

    def test_oversized_header_fails(self):
        self.path.write_bytes(b'X-Test: ' + b'x' * 1_000_001)
        with self.assertRaises(ValueError):
            EMAIL.extract(self.path)

    def test_missing_file_cli_reports_failure(self):
        result = subprocess.run([sys.executable, EMAIL.__file__, str(self.path)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('error', json.loads(result.stderr))


if __name__ == '__main__':
    unittest.main()
