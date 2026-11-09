#!/usr/bin/python3
"""A local Homebrew double. It changes only fixture JSON and marker files."""
import base64
import json
import os
import re
import sys
import time
from pathlib import Path

root = Path(__file__).parent
os.chdir(root)
args = sys.argv[1:]
with open('commands', 'a') as log:
    log.write(json.dumps(args) + '\n')
packages = json.loads(Path('packages').read_text())
states = json.loads(Path('states').read_text())
if os.getenv('HOMEBREW_NO_REQUIRE_TAP_TRUST'):
    raise SystemExit(70)


def package_path(package):
    folder = 'Casks' if package['type'] == 'cask' else 'Formula'
    return str(root / 'tap' / folder / (package['name'] + '.rb'))


def names():
    return [arg for arg in args[1:] if not arg.startswith('--')]


def chosen():
    requested = names()
    return [p for p in packages if not requested or p['full'] in requested or
            p['name'] in requested or package_path(p) in requested or
            ('homebrew/' + ('cask/' if p['type'] == 'cask' else 'core/') + p['name']) in requested]


if args[0] == 'ruby':
    if Path('slow-inspect').exists():
        time.sleep(1)
    match = re.search(r'JSON.parse\("([A-Za-z0-9+/=]+)"\.unpack1', args[2])
    if not match:
        raise SystemExit(99)
    requests = json.loads(base64.b64decode(match.group(1)))
    rows = []
    for request in requests:
        p = next(p for p in packages if p['type'] + ':' + p['full'] == request['id'])
        rows.append({'id': request['id'], 'state': states[request['id']],
                     'argument': package_path(p), 'reference': Path('reference').read_text()})
    print(json.dumps(rows))
elif args[0] == 'info':
    result = {'formulae': [], 'casks': []}
    for p in chosen():
        changed = Path('updated-' + p['type']).exists()
        version = '2' if changed else '1'
        if p['type'] == 'formula':
            result['formulae'].append({'name': p['name'], 'full_name': p['full'],
                                      'installed': [{'version': version, 'time': 2 if changed else 1}],
                                      'versions': {'stable': '2'}, 'dependencies': []})
        else:
            result['casks'].append({'token': p['name'], 'full_token': p['full'],
                                   'installed': version, 'version': '2'})
    print(json.dumps(result))
elif args[0] == 'upgrade':
    for name in names():
        if name.startswith('vendor/'):
            Path('implicit-write').write_text(name)
            raise SystemExit(71)
    selected = chosen()
    if '--formula' in args:
        selected = [p for p in selected if p['type'] == 'formula']
    if '--cask' in args:
        selected = [p for p in selected if p['type'] == 'cask']
    if '--dry-run' not in args:
        if not Path('execute-fixture').exists():
            raise SystemExit(72)
        kind = 'cask' if '--cask' in args else 'formula'
        if kind == 'cask' and Path('fail-cask').exists():
            raise SystemExit(42)
        Path('updated-' + kind).touch()
        print('fixture batch finished')
    else:
        print('==> Would upgrade ' + str(len(selected)) + ' requested outdated packages:')
        for p in selected:
            print(p['full'] + ' 1 -> 2')
elif args[0] == 'trust':
    Path('trust-started').touch()
    while Path('delay-trust').exists() and not Path('release-trust').exists():
        time.sleep(0.01)
    kind, name = args[1][2:], args[2]
    if Path('fail-second').exists() and name.endswith('/beta'):
        raise SystemExit(13)
    states[kind + ':' + name] = 'package'
    Path('states').write_text(json.dumps(states))
    with open('explicit-writes', 'a') as log:
        log.write(kind + ':' + name + '\n')
elif args == ['help', 'vulns']:
    print('Output --json findings and scan coverage')
elif args == ['vulns', '--json']:
    missed = {p['full']: 'untrusted_tap' for p in packages if states[p['type'] + ':' + p['full']] == 'untrusted'}
    findings = []
    if 'vendor/tools/alpha' not in missed:
        findings = [{'formula': 'vendor/tools/alpha', 'version': '1',
                     'vulnerabilities': [{'id': 'CVE-fixture', 'severity': 'HIGH', 'summary': 'fixture only',
                                          'aliases': [], 'fixed_versions': ['2']}], 'patched': []}]
    report = {'findings': findings, 'checked': len(packages) - len(missed), 'complete': not missed,
              'skipped_formulae': [], 'outdated_without_sbom': [], 'unscanned_formulae': missed}
    Path('scan-started').touch()
    while Path('delay-scan').exists() and not Path('release-scan').exists():
        time.sleep(0.01)
    print(json.dumps(report))
    raise SystemExit(1 if findings or missed else 0)
elif args == ['--caskroom']:
    print(root)
else:
    raise SystemExit(98)
