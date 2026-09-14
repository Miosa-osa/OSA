#!/usr/bin/env python3
"""Read bounded EML headers without rendering content or fetching remote data."""
import argparse
import email.policy
from email.parser import BytesHeaderParser
import json
import sys


def extract(path):
    with open(path, 'rb') as stream:
        raw = stream.read(1_000_001)
    boundary = raw.find(b'\r\n\r\n')
    if boundary < 0:
        boundary = raw.find(b'\n\n')
    if boundary < 0 and len(raw) > 1_000_000:
        raise ValueError('header exceeds 1 MB limit')
    header = raw[:boundary] if boundary >= 0 else raw
    message = BytesHeaderParser(policy=email.policy.default).parsebytes(header + b'\r\n\r\n')
    names = ('From', 'To', 'Reply-To', 'Return-Path', 'Date', 'Message-ID',
             'Authentication-Results', 'Received', 'DKIM-Signature')
    return {'headers': {name: [str(value) for value in message.get_all(name, [])] for name in names},
            'defects': [type(defect).__name__ for defect in message.defects],
            'note': 'Untrusted reported headers; no authentication or attachment execution performed.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('path')
    args = parser.parse_args()
    try:
        print(json.dumps(extract(args.path), indent=2))
    except (OSError, ValueError) as error:
        print(json.dumps({'error': str(error)}), file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
