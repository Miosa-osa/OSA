#!/usr/bin/env python3
"""Bounded read-only JSONL inspection; emits selected event labels and counts."""
import argparse
import collections
import json
import sys


def summarize(path, max_bytes=10_000_000):
    counts = collections.Counter()
    valid = missing_timestamp = 0
    malformed = []
    consumed = 0
    with open(path, 'rb') as stream:
        for number in range(1, 100_002):
            raw = stream.readline(min(1_000_001, max_bytes - consumed + 1))
            if not raw:
                break
            consumed += len(raw)
            if consumed > max_bytes or len(raw) > 1_000_000 or number > 100_000:
                raise ValueError('input exceeds byte, line length or record limit')
            try:
                event = json.loads(raw)
                if not isinstance(event, dict):
                    raise ValueError('record must be an object')
                kind = event.get('event_type', 'unknown')
                if not isinstance(kind, str) or len(kind) > 120:
                    raise ValueError('invalid event type')
            except (ValueError, UnicodeDecodeError, RecursionError):
                malformed.append(number)
                continue
            counts[kind] += 1
            valid += 1
            missing_timestamp += not isinstance(event.get('timestamp'), str) or not event.get('timestamp')
    return {'valid_records': valid, 'event_types': dict(sorted(counts.items())),
            'malformed_lines': malformed, 'missing_timestamps': missing_timestamp,
            'note': 'Counts only; timestamps and source authenticity are not validated.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('path')
    args = parser.parse_args()
    try:
        result = summarize(args.path)
    except (OSError, ValueError) as error:
        print(json.dumps({'error': str(error)}), file=sys.stderr)
        return 2
    print(json.dumps(result, indent=2))
    return 2 if result['malformed_lines'] else 0


if __name__ == '__main__':
    sys.exit(main())
