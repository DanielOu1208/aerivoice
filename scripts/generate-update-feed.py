#!/usr/bin/env python3
"""Prepare a local, signed Sparkle feed; never publishes or accesses private key data."""
import argparse
import base64
import copy
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
S = '{' + NS + '}'
FEED_URL = 'https://aerivoice.app/updates/appcast.xml'
ASSET_ROOT = 'https://github.com/DanielOu1208/aerivoice/releases/download/'
VERSION = r'[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?'
ET.register_namespace('sparkle', NS)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_feed(path):
    data = Path(path).read_bytes()
    require(b'<!DOCTYPE' not in data and b'<!ENTITY' not in data, 'DTD/entities are forbidden')
    root = ET.fromstring(data)
    require(root.tag == 'rss' and len(root.findall('channel')) == 1, 'Expected one RSS channel')
    items = root.find('channel').findall('item')
    require(items, 'Feed has no release items')
    builds = []
    labels = set()
    for item in items:
        def field(name):
            nodes = item.findall(S + name)
            require(len(nodes) == 1 and nodes[0].text, 'Missing/duplicate ' + name)
            return nodes[0].text
        build = field('version')
        require(re.fullmatch(r'[1-9][0-9]*', build), 'Invalid build number')
        builds.append(int(build))
        label = field('shortVersionString')
        require(re.fullmatch(VERSION, label), 'Invalid release label')
        require(label not in labels, 'Duplicate release label/asset URL')
        labels.add(label)
        require(re.fullmatch(r'[0-9]+\.[0-9]+(?:\.[0-9]+)?', field('minimumSystemVersion')), 'Invalid minimum macOS')
        require(field('hardwareRequirements') == 'arm64', 'Expected arm64 hardware requirement')
        require(item.find(S + 'channel') is None, 'Only the public track is supported')
        require(item.find(S + 'deltas') is None, 'Delta updates are disabled')
        require(item.find(S + 'releaseNotesLink') is None, 'Release notes must be embedded')
        require(item.find('description') is not None, 'Missing embedded release notes')
        enclosures = item.findall('enclosure')
        require(len(enclosures) == 1, 'Expected one full enclosure')
        enclosure = enclosures[0]
        expected = ASSET_ROOT + f'v{label}/AeriVoice-v{label}-arm64.dmg'
        require(enclosure.get('url') == expected, 'Invalid version-specific asset URL')
        require(enclosure.get('type') == 'application/octet-stream', 'Invalid enclosure type')
        require(re.fullmatch(r'[1-9][0-9]*', enclosure.get('length', '')), 'Invalid asset length')
        try:
            signature = base64.b64decode(enclosure.get(S + 'edSignature', ''), validate=True)
        except ValueError as error:
            raise ValueError('Invalid archive signature encoding') from error
        require(len(signature) == 64, 'Missing/invalid archive signature')
    require(builds == sorted(set(builds), reverse=True), 'Builds must be unique and strictly descending')
    return root, items, builds


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def generate(args):
    tools = Path(args.sparkle_bin).resolve()
    for name in ('generate_appcast', 'sign_update', 'generate_keys'):
        require(os.access(tools / name, os.X_OK), 'Missing Sparkle tool: ' + name)
    dmg = Path(args.dmg).resolve()
    notes = Path(args.notes).resolve()
    output = Path(args.output).resolve()
    require(not output.exists(), 'Output already exists; never overwrite a signed candidate')
    require(re.fullmatch(VERSION, args.version), 'Invalid release version')
    require(args.build > 0, 'Build must be positive')
    require(dmg.is_file() and dmg.name == f'AeriVoice-v{args.version}-arm64.dmg', 'Unexpected DMG name')
    require(notes.suffix == '.txt' and notes.read_text().strip(), 'Nonempty .txt release notes required')
    with open(Path(args.app) / 'Contents/Info.plist', 'rb') as handle:
        info = plistlib.load(handle)
    require(info.get('CFBundleVersion') == str(args.build), 'App build does not match')
    require(info.get('CFBundleShortVersionString') == args.version.split('-')[0], 'App marketing version does not match')
    require(info.get('AeriVoiceReleaseVersion') == args.version, 'App release label does not match')
    require(info.get('SUFeedURL') == FEED_URL, 'Unexpected app feed URL')
    for key in ('SURequireSignedFeed', 'SUVerifyUpdateBeforeExtraction', 'SUEnableAutomaticChecks'):
        require(info.get(key) is True, key + ' must be enabled')
    for key in ('SUAllowsAutomaticUpdates', 'SUAutomaticallyUpdate', 'SUEnableSystemProfiling', 'SUEnableJavaScript'):
        require(info.get(key) is False, key + ' must be disabled')
    public_key = info.get('SUPublicEDKey', '')
    require(len(base64.b64decode(public_key, validate=True)) == 32, 'Missing/invalid embedded public key')
    # -p prints only the public key; private key material stays inside Sparkle.
    key = subprocess.check_output([str(tools / 'generate_keys'), '--account', args.account, '-p'], text=True).strip()
    require(key == public_key, 'Keychain signing account does not match the app public key')
    minimum_os = info.get('LSMinimumSystemVersion', '')
    require(re.fullmatch(r'[0-9]+\.[0-9]+(?:\.[0-9]+)?', minimum_os), 'Missing app minimum macOS')
    archs = subprocess.check_output(['lipo', '-archs', str(Path(args.app) / 'Contents/MacOS/AeriVoice')], text=True).strip()
    require(archs == 'arm64', 'App must be arm64 only')
    previous_items = []
    if args.previous:
        run(tools / 'sign_update', '--account', args.account, '--verify', Path(args.previous).resolve())
        _, previous_items, builds = validate_feed(args.previous)
        require(args.build > max(builds), 'New build must exceed every published build')
        require(all(item.findtext(S + 'shortVersionString') != args.version for item in previous_items),
                'Release label was already published; use a new version-specific asset')
    with tempfile.TemporaryDirectory(prefix='aerivoice-appcast-') as directory:
        stage = Path(directory)
        shutil.copy2(dmg, stage / dmg.name)
        shutil.copy2(notes, stage / (dmg.stem + '.txt'))
        feed = stage / 'appcast.xml'
        run(tools / 'generate_appcast', '--account', args.account, '--maximum-deltas', '0',
            '--maximum-versions', '0', '--embed-release-notes', '--download-url-prefix',
            ASSET_ROOT + f'v{args.version}/', '--link', 'https://aerivoice.app', '-o', feed, stage)
        root = ET.parse(feed).getroot()
        channel = root.find('channel')
        require(channel is not None and len(channel.findall('item')) == 1, 'Expected one generated release')
        item = channel.find('item')
        require(item.findtext(S + 'version') == str(args.build), 'Generated DMG build does not match')
        require(item.findtext(S + 'shortVersionString') == args.version.split('-')[0], 'Generated DMG marketing version does not match')
        require(item.findtext(S + 'hardwareRequirements') in (None, 'arm64'), 'Generated DMG architecture does not match')
        require(item.findtext(S + 'minimumSystemVersion') == minimum_os, 'Generated DMG minimum macOS does not match')
        for tag, value in [('title', f'AeriVoice {args.version}'), (S + 'shortVersionString', args.version),
                           (S + 'hardwareRequirements', 'arm64')]:
            node = item.find(tag)
            if node is None:
                node = ET.SubElement(item, tag)
            node.text = value
        enclosure = item.find('enclosure')
        require(enclosure is not None and enclosure.get('length') == str(dmg.stat().st_size), 'Generated asset length does not match')
        run(tools / 'sign_update', '--account', args.account, '--verify', dmg, enclosure.get(S + 'edSignature', ''))
        for previous in previous_items:
            channel.append(copy.deepcopy(previous))
        # All metadata edits happen before signing the final bytes.
        ET.ElementTree(root).write(feed, encoding='utf-8', xml_declaration=True)
        validate_feed(feed)
        run(tools / 'sign_update', '--account', args.account, feed)
        run(tools / 'sign_update', '--account', args.account, '--verify', feed)
        validate_feed(feed)
        output.parent.mkdir(parents=True, exist_ok=True)
        with output.open('xb') as destination:
            destination.write(feed.read_bytes())
    print(f'Signed candidate feed: {output} (not published)')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dmg', required=True)
    parser.add_argument('--app', required=True)
    parser.add_argument('--notes', required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', required=True, type=int)
    parser.add_argument('--sparkle-bin', required=True)
    parser.add_argument('--account', default='com.danielou.AeriVoice.sparkle')
    parser.add_argument('--output', required=True)
    history = parser.add_mutually_exclusive_group(required=True)
    history.add_argument('--previous', help='Previously published, signed appcast (verified before reuse)')
    history.add_argument('--initial-feed', action='store_true', help='Explicit first-ever feed; never use to reset release history')
    args = parser.parse_args()
    try:
        generate(args)
    except (ValueError, OSError, ET.ParseError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Feed generation failed: {error}\n')


if __name__ == '__main__':
    main()
