#!/usr/bin/env python3
"""Verify public deployment bytes and root/404 HTTP behavior over validated TLS."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import hashlib
import json
import re
import sys
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
base = sys.argv[1].rstrip('/')
if not base.startswith('https://'):
    raise SystemExit('A public HTTPS origin is required')

def digest(data):
    return hashlib.sha256(data).hexdigest()

def fetch(route):
    with tempfile.TemporaryDirectory(prefix='coddle-http-') as directory:
        body = Path(directory) / 'body'
        headers = Path(directory) / 'headers'
        completed = subprocess.run(['curl', '-sS', '--fail-with-body', '--location', '--max-time', '30',
            '--output', str(body), '--dump-header', str(headers), '--write-out', '%{json}', base + route],
            capture_output=True, text=True)
        metadata = json.loads(completed.stdout)
        if completed.returncode not in (0, 22):
            raise RuntimeError(f"HTTP probe failed for {route}: curl exit {completed.returncode}")
        header_blocks = headers.read_text().strip().split('\n\n')
        header_map = dict(line.split(':', 1) for line in header_blocks[-1].splitlines()[1:] if ':' in line)
        return body.read_bytes(), metadata, {k.lower(): v.strip() for k,v in header_map.items()}

def check(path):
    route = '/' if path.name == 'index.html' else '/' + path.relative_to(root / 'public').as_posix()
    data, metadata, headers = fetch(route)
    original = path.read_bytes()
    exact = data == original
    stripped = re.sub(rb'<script defer src="https://static\.cloudflareinsights\.com/beacon\.min\.js[^>]*></script>\s*', b'', data)
    normalized = stripped.replace(b'\r\n', b'\n').strip() == original.replace(b'\r\n', b'\n').strip()
    return {'path': route, 'status': metadata['http_code'], 'finalUrl': metadata['url_effective'],
            'bytes': len(data), 'sha256': digest(data), 'localSha256': digest(original),
            'exactBytes': exact, 'edgeAnalyticsOnly': not exact and normalized,
            'tlsVerifyResult': metadata['ssl_verify_result'],
            'contentType': headers.get('content-type'),
            'csp': headers.get('content-security-policy') if route == '/' else None}

files = [p for p in sorted((root / 'public').rglob('*')) if p.is_file() and not p.name.startswith('_') and p.name != '404.html']
with ThreadPoolExecutor(max_workers=4) as pool:
    results = list(pool.map(check, files))
not_found = fetch('/coddle-acceptance-missing-page')[1]['http_code']
passed = all(r['status'] == 200 and r['tlsVerifyResult'] == 0 and (r['exactBytes'] or r['edgeAnalyticsOnly']) for r in results) and not_found == 404
report = {'baseUrl': base, 'tlsVerified': True, 'files': results, 'notFoundStatus': not_found, 'passed': passed}
print(json.dumps(report, indent=2))
raise SystemExit(0 if passed else 1)
