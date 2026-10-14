#!/usr/bin/env python3
"""Verify component isolation and every selection through macOS Installer, without installing."""
import argparse
import hashlib
import itertools
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import xml.etree.ElementTree as ET


def run(*args):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise SystemExit(f'{args[0]} failed ({result.returncode}):\n' + result.stderr.decode(errors='replace'))
    return result.stdout


def check(condition, message):
    if not condition:
        raise SystemExit(message)


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('package', type=Path)
parser.add_argument('--include-aax', action='store_true')
args = parser.parse_args()
package = args.package.resolve(strict=True)
destinations = {
    'au': Path('Library/Audio/Plug-Ins/Components/MoteField.component'),
    'vst3': Path('Library/Audio/Plug-Ins/VST3/MoteField.vst3'),
}
if args.include_aax:
    destinations['aax'] = Path('Library/Application Support/Avid/Audio/Plug-Ins/MoteField.aaxplugin')
formats = list(destinations)
destinations['notices'] = Path('Library/Application Support/Rango Labs/MoteField/Notices')
installer = ['/usr/sbin/installer', '-pkg', str(package), '-target', '/']
report = {'package': str(package), 'sha256': hashlib.sha256(package.read_bytes()).hexdigest(),
          'installed': False, 'components': {}, 'selections': []}
with tempfile.TemporaryDirectory(prefix='motefield-pkg-test-') as directory:
    temporary = Path(directory)
    expanded = temporary / 'expanded'
    run('/usr/sbin/pkgutil', '--expand-full', str(package), str(expanded))
    distribution = ET.parse(expanded / 'Distribution').getroot()
    check(distribution.find('options').get('customize') == 'always', 'Format choices must open automatically')
    check({c.get('id') for c in distribution.findall('choice')} == set(destinations), 'Unexpected choices')
    check({p.name for p in expanded.glob('*.pkg')} == {f'{c}.pkg' for c in destinations}, 'Unexpected packages')
    versions = set()
    for component, destination in destinations.items():
        part = expanded / f'{component}.pkg'
        info = ET.parse(part / 'PackageInfo').getroot()
        identifier = f'com.rangolabs.motefield.pkg.{component}'
        check(info.get('identifier') == identifier, f'{component}: wrong receipt')
        check(info.get('install-location') == '/', f'{component}: wrong install location')
        check(info.get('relocatable') == 'false' and not list(info.findall('relocate/*')), f'{component}: relocatable bundle')
        check(not (part / 'Scripts').exists(), f'{component}: unexpected install scripts')
        versions.add(info.get('version'))
        payload = part / 'Payload'
        files = [p.relative_to(payload) for p in payload.rglob('*') if p.is_file() or p.is_symlink()]
        check(files and all(destination in p.parents for p in files), f'{component}: payload crosses format boundaries')
        if component != 'notices':
            bundle = payload / destination
            run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(bundle))
            run('/usr/bin/lipo', str(bundle / 'Contents/MacOS/MoteField'), '-verify_arch', 'arm64', 'x86_64')
            with (bundle / 'Contents/Info.plist').open('rb') as f:
                check(plistlib.load(f)['CFBundleShortVersionString'] == info.get('version'), f'{component}: wrong version')
        report['components'][component] = {'receipt': identifier, 'destination': '/' + str(destination), 'files': len(files)}
    check(len(versions) == 1, 'Mismatched component versions')
    defaults = plistlib.loads(run(*installer, '-showChoicesXML'))[0]['childItems']
    check({c['choiceIdentifier'] for c in defaults} == set(destinations), 'Installer omitted a choice')
    for choice in defaults:
        component = choice['choiceIdentifier']
        check(choice['choiceIsSelected'] == 1, f'{component}: not selected by default')
        check(choice['choiceIsEnabled'] == (component != 'notices'), f'{component}: incorrect enabled state')
        check(choice['choiceIsVisible'] == (component != 'notices'), f'{component}: incorrect visibility')
        check(len(choice['pathsOfActivePackagesInChoice']) == 1 and
              choice['pathsOfActivePackagesInChoice'][0].endswith(f'#{component}.pkg'), f'{component}: wrong package binding')
    for flags in itertools.product((0, 1), repeat=len(formats)):
        requested = dict(zip(formats, flags))
        changes = temporary / 'choices.plist'
        changes.write_bytes(plistlib.dumps([
            {'choiceIdentifier': c, 'choiceAttribute': 'selected', 'attributeSetting': selected}
            for c, selected in requested.items()
        ]))
        result = plistlib.loads(run(*installer, '-showChoicesAfterApplyingChangesXML', str(changes)))
        selected = {v['choiceIdentifier']: v['attributeSetting'] for v in result if v['choiceAttribute'] == 'selected'}
        expected = {**requested, 'notices': int(any(flags))}
        check(selected == expected, f'Installer changed selection: expected {expected}, got {selected}')
        report['selections'].append([c for c, value in selected.items() if value])
    report['version'] = versions.pop()
    report['result'] = 'passed'
print(json.dumps(report, indent=2))
