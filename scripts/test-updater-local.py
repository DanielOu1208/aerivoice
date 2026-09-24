#!/usr/bin/env python3
"""Build isolated local Sparkle QA fixtures. Never installs, launches, or publishes apps."""
import argparse
import base64
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = 'com.danielou.AeriVoice.UpdaterQA'
PRODUCT = 'AeriVoice Update QA'
ACCOUNT = BUNDLE + '.sparkle'
PUBLIC_KEY = 'Xyw1LV9Tqgn9gq67pLcOKbZoUsrM5DZF+S+tnLQETaM='
URL = 'http://127.0.0.1:8769/'
SPARKLE = Path('/tmp/aerivoice-updater-packages/artifacts/sparkle/Sparkle/bin')
S = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
ET.register_namespace('sparkle', S[1:-1])
CASES = ('valid', 'invalid-feed-signature', 'invalid-archive-signature',
         'invalid-archive-both-signatures')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(*args, capture=False):
    result = subprocess.run([str(arg) for arg in args], cwd=ROOT, check=True,
                            text=True, capture_output=capture)
    return result.stdout.strip() if capture else None


def write_plist(path, value):
    with path.open('wb') as stream:
        plistlib.dump(value, stream)


def create_qa_plist(source, target):
    with source.open('rb') as stream:
        info = plistlib.load(stream)
    # Deliberately generated outside the source tree, used only by the QA bundle.
    info['NSAppTransportSecurity'] = {'NSAllowsLocalNetworking': True,
                                      'NSAllowsArbitraryLoads': True}
    write_plist(target, info)


def invalid_archive_feed(source, target, build, archive=None):
    tree = ET.parse(source)
    item = next(item for item in tree.findall('./channel/item')
                if item.findtext(S + 'version') == str(build))
    enclosure = item.find('enclosure')
    enclosure.set(S + 'edSignature', base64.b64encode(bytes(64)).decode())
    if archive is not None:
        enclosure.set('url', URL + archive.name)
        enclosure.set('length', str(archive.stat().st_size))
    tree.write(target, encoding='utf-8', xml_declaration=True)


def invalid_feed(source, target):
    data = source.read_bytes()
    # Edit XML content without updating the embedded feed signature.
    require(b'<title>' in data, 'No title available for feed tampering')
    target.write_bytes(data.replace(b'<title>', b'<title>INVALID QA ', 1))


def tamper_archive(source, target):
    require(source.resolve() != target.resolve(), 'Never modify the valid archive')
    require(source.stat().st_size > 8192, 'Expected a full DMG fixture')
    shutil.copyfile(source, target)
    # Changing covered payload bytes invalidates the existing Developer ID and
    # EdDSA signatures without depending on DMG signature-removal support.
    with target.open('r+b') as stream:
        stream.seek(4096)
        value = stream.read(1)[0]
        stream.seek(4096)
        stream.write(bytes([value ^ 1]))


def verify_rejected(*command):
    result = subprocess.run([str(part) for part in command], cwd=ROOT,
                            text=True, capture_output=True)
    require(result.returncode != 0, 'Deliberately invalid signature unexpectedly verified')


def check_app(app, build, identity, team):
    with (app / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    expected = {'CFBundleIdentifier': BUNDLE, 'CFBundleVersion': str(build),
                'SUPublicEDKey': PUBLIC_KEY, 'SUFeedURL': URL + 'appcast.xml',
                'SURequireSignedFeed': True, 'SUVerifyUpdateBeforeExtraction': True}
    for key, value in expected.items():
        require(info.get(key) == value, f'Unexpected QA app {key}')
    executable = app / 'Contents/MacOS' / info['CFBundleExecutable']
    require(run('lipo', '-archs', executable, capture=True) == 'arm64', 'QA app is not arm64 only')
    result = subprocess.run(['codesign', '-dvvv', str(app)], check=True,
                            text=True, capture_output=True)
    signature = result.stderr
    require('Authority=' + identity in signature, 'QA Developer ID mismatch')
    require('TeamIdentifier=' + team in signature, 'QA team mismatch')
    require('(runtime)' in signature, 'QA hardened runtime missing')
    run('codesign', '--verify', '--deep', '--strict', '--verbose=2', app)
    entitlements = run('codesign', '-d', '--entitlements', ':-', '--xml', app, capture=True)
    values = plistlib.loads(entitlements.encode())
    require(values.get('com.apple.security.device.audio-input') is True, 'QA audio entitlement missing')
    require(values.get('com.apple.security.get-task-allow') is not True, 'QA app allows debugger attachment')


def notarize(path, profile):
    run('xcrun', 'notarytool', 'submit', path, '--keychain-profile', profile, '--wait')


def build(args):
    destination = Path(args.output).resolve()
    require(not destination.exists(), 'Use a fresh output directory; completed fixtures are never overwritten')
    require(args.build_a > 0 and args.build_b > args.build_a, 'Require 0 < build A < build B')
    require(args.identity.startswith('Developer ID Application: '), 'Developer ID Application identity required')
    tools = Path(args.sparkle_bin).resolve()
    for name in ('generate_appcast', 'sign_update', 'generate_keys'):
        require(os.access(tools / name, os.X_OK), 'Missing Sparkle tool ' + name)
    require(run(tools / 'generate_keys', '--account', ACCOUNT, '-p', capture=True) == PUBLIC_KEY,
            'QA Keychain account does not match the fixed QA public key')
    destination.mkdir(parents=True)
    public = destination / 'public'
    public.mkdir()
    configuration = destination / 'QA-Info.plist'
    create_qa_plist(ROOT / 'Config/App-Info.plist', configuration)
    export_options = destination / 'ExportOptions.plist'
    write_plist(export_options, {'method': 'developer-id', 'signingStyle': 'manual',
                                'teamID': args.team, 'signingCertificate': args.identity,
                                'stripSwiftSymbols': False})
    revision = run('git', 'rev-parse', 'HEAD', capture=True)
    dirty = bool(run('git', 'status', '--porcelain', '--untracked-files=normal', capture=True))
    source_revision = revision + ('-dirty' if dirty else '')
    for label, number in [('A', args.build_a), ('B', args.build_b)]:
        directory = destination / label
        directory.mkdir()
        archive = directory / 'AeriVoiceQA.xcarchive'
        export = directory / 'export'
        run('xcodebuild', '-project', 'AeriVoice.xcodeproj', '-scheme', 'AeriVoice',
            '-configuration', args.configuration, '-destination', 'generic/platform=macOS',
            '-archivePath', archive, '-derivedDataPath', destination / 'DerivedData',
            '-clonedSourcePackagesDirPath', args.packages,
            'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=NO', 'AERIVOICE_BUNDLE_IDENTIFIER=' + BUNDLE,
            'AERIVOICE_PRODUCT_NAME=' + PRODUCT, 'MARKETING_VERSION=0.1.0',
            'CURRENT_PROJECT_VERSION=' + str(number), 'AERIVOICE_APP_INFO_FILE=' + str(configuration),
            'AERIVOICE_RELEASE_VERSION=0.1.0-qa.' + label.lower(),
            'AERIVOICE_SOURCE_REVISION=' + source_revision, 'AERIVOICE_UPDATE_FEED_URL=' + URL + 'appcast.xml',
            'AERIVOICE_UPDATE_PUBLIC_KEY=' + PUBLIC_KEY,
            'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) AERIVOICE_APP AERIVOICE_UPDATER_QA',
            'DEVELOPMENT_TEAM=' + args.team, 'CODE_SIGN_STYLE=Manual',
            'CODE_SIGN_IDENTITY=' + args.identity, 'OTHER_CODE_SIGN_FLAGS=--timestamp',
            'ENABLE_HARDENED_RUNTIME=YES', 'CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO', 'archive')
        run('xcodebuild', '-exportArchive', '-archivePath', archive,
            '-exportPath', export, '-exportOptionsPlist', export_options)
        app = export / (PRODUCT + '.app')
        check_app(app, number, args.identity, args.team)
        if not args.no_notary:
            app_zip = directory / 'AeriVoiceQA.zip'
            run('ditto', '-c', '-k', '--keepParent', app, app_zip)
            notarize(app_zip, args.notary_profile)
            run('xcrun', 'stapler', 'staple', app)
            run('xcrun', 'stapler', 'validate', app)
            run('spctl', '--assess', '--type', 'execute', '--verbose=4', app)
        stage = directory / 'dmg-stage'
        stage.mkdir()
        run('ditto', app, stage / app.name)
        dmg = public / f'AeriVoice-QA-{label}-{number}.dmg'
        run('hdiutil', 'create', '-volname', PRODUCT, '-srcfolder', stage, '-format', 'UDZO', dmg)
        run('codesign', '--force', '--timestamp', '--sign', args.identity, dmg)
        if not args.no_notary:
            notarize(dmg, args.notary_profile)
            run('xcrun', 'stapler', 'staple', dmg)
            run('xcrun', 'stapler', 'validate', dmg)
            run('spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', dmg)
        run('codesign', '--verify', '--verbose=2', dmg)
        dmg.with_suffix('.txt').write_text(f'AeriVoice updater QA build {label} ({number}).\nLocal fixture only; never publish.\n')
    valid = public / 'valid.xml'
    run(tools / 'generate_appcast', '--account', ACCOUNT, '--maximum-deltas', '0',
        '--maximum-versions', '0', '--embed-release-notes', '--download-url-prefix', URL,
        '-o', valid, public)
    tree = ET.parse(valid)
    items = tree.findall('./channel/item')
    require({item.findtext(S + 'version') for item in items} == {str(args.build_a), str(args.build_b)},
            'Generated feed must contain exactly QA builds A and B')
    for item in items:
        number = int(item.findtext(S + 'version'))
        label = 'A' if number == args.build_a else 'B'
        item.find('title').text = 'AeriVoice Update QA ' + label
        item.find(S + 'shortVersionString').text = '0.1.0-qa.' + label.lower()
        enclosure = item.find('enclosure')
        dmg = public / f'AeriVoice-QA-{label}-{number}.dmg'
        require(enclosure.get('url') == URL + dmg.name, 'Unexpected QA download URL')
        run(tools / 'sign_update', '--account', ACCOUNT, '--verify', dmg, enclosure.get(S + 'edSignature'))
    tree.write(valid, encoding='utf-8', xml_declaration=True)
    run(tools / 'sign_update', '--account', ACCOUNT, valid)
    run(tools / 'sign_update', '--account', ACCOUNT, '--verify', valid)
    bad_archive = public / 'invalid-archive-signature.xml'
    invalid_archive_feed(valid, bad_archive, args.build_b)
    run(tools / 'sign_update', '--account', ACCOUNT, bad_archive)
    run(tools / 'sign_update', '--account', ACCOUNT, '--verify', bad_archive)
    verify_rejected(tools / 'sign_update', '--account', ACCOUNT, '--verify',
                    public / f'AeriVoice-QA-B-{args.build_b}.dmg', base64.b64encode(bytes(64)).decode())
    # A valid Developer ID signature can provide Sparkle's key-rotation fallback.
    # Tamper only a copy to exercise guaranteed pre-extraction rejection.
    tampered_dmg = public / f'AeriVoice-QA-B-{args.build_b}-tampered.dmg'
    tamper_archive(public / f'AeriVoice-QA-B-{args.build_b}.dmg', tampered_dmg)
    verify_rejected('codesign', '--verify', tampered_dmg)
    both_invalid = public / 'invalid-archive-both-signatures.xml'
    invalid_archive_feed(valid, both_invalid, args.build_b, tampered_dmg)
    run(tools / 'sign_update', '--account', ACCOUNT, both_invalid)
    run(tools / 'sign_update', '--account', ACCOUNT, '--verify', both_invalid)
    verify_rejected(tools / 'sign_update', '--account', ACCOUNT, '--verify',
                    tampered_dmg, base64.b64encode(bytes(64)).decode())
    bad_feed = public / 'invalid-feed-signature.xml'
    invalid_feed(valid, bad_feed)
    verify_rejected(tools / 'sign_update', '--account', ACCOUNT, '--verify', bad_feed)
    shutil.copyfile(valid, public / 'appcast.xml')
    (destination / 'fixture.json').write_text(json.dumps({
        'bundle': BUNDLE, 'product': PRODUCT, 'build_a': args.build_a, 'build_b': args.build_b,
        'configuration': args.configuration, 'notarized': not args.no_notary,
        'revision': revision, 'dirty_at_start': dirty,
        'dirty_at_finish': bool(run('git', 'status', '--porcelain', '--untracked-files=normal', capture=True)),
        'source_revision': source_revision, 'feed': URL + 'appcast.xml', 'cases': CASES}, indent=2) + '\n')
    print(f'QA fixtures ready: {destination}; notarized={not args.no_notary}. No app launched or installed.')


def select(args):
    public = Path(args.output).resolve() / 'public'
    source = public / (args.case + '.xml')
    require(source.is_file(), 'Build the fixture first')
    temporary = public / 'appcast.xml.tmp'
    shutil.copyfile(source, temporary)
    temporary.replace(public / 'appcast.xml')
    print('Selected local QA case: ' + args.case)


class NoCacheHandler(SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Cache-Control', 'no-store')
        super().end_headers()


def serve(args):
    public = Path(args.output).resolve() / 'public'
    require((public / 'appcast.xml').is_file(), 'Build the fixture first')
    handler = partial(NoCacheHandler, directory=str(public))
    with ThreadingHTTPServer(('127.0.0.1', 8769), handler) as server:
        print('Serving QA only at ' + URL, flush=True)
        server.serve_forever()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest='action', required=True)
    builder = actions.add_parser('build', help='Run through aqua-run; signed, notarized by default')
    builder.add_argument('--output', required=True)
    builder.add_argument('--team', required=True)
    builder.add_argument('--identity', required=True)
    builder.add_argument('--build-a', type=int, default=900001)
    builder.add_argument('--build-b', type=int, default=900002)
    builder.add_argument('--configuration', choices=('Debug', 'Release'), default='Release')
    builder.add_argument('--no-notary', action='store_true', help='Iteration only; never final acceptance')
    builder.add_argument('--notary-profile', default='AeriVoiceNotary')
    builder.add_argument('--sparkle-bin', default=str(SPARKLE))
    builder.add_argument('--packages', default='/tmp/aerivoice-updater-packages')
    builder.set_defaults(function=build)
    selector = actions.add_parser('select', help='Atomically select which feed the local server returns')
    selector.add_argument('--output', required=True)
    selector.add_argument('--case', choices=CASES, required=True)
    selector.set_defaults(function=select)
    server = actions.add_parser('serve', help='Foreground localhost-only HTTP server; does not launch apps')
    server.add_argument('--output', required=True)
    server.set_defaults(function=serve)
    args = parser.parse_args()
    try:
        args.function(args)
    except (ValueError, OSError, subprocess.CalledProcessError, ET.ParseError) as error:
        parser.exit(1, f'QA fixture failed: {error}\n')


if __name__ == '__main__':
    main()
