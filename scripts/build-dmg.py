#!/usr/bin/env python3
"""Package an existing app in the branded DMG. Does not sign, install, or publish."""
import argparse
import hashlib
from importlib.metadata import version
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

ASSETS = Path(__file__).resolve().parent / 'dmg'


def check_tools():
    if sys.version_info < (3, 11):
        raise ValueError('DMG packaging requires Python 3.11 or newer')
    # The lock file is also the source of truth for the required installed versions.
    for line in (ASSETS / 'requirements.txt').read_text().splitlines():
        if not line or line.startswith('#'):
            continue
        package, expected = line.split()[0].split('==')
        if version(package) != expected:
            raise ValueError(f'Install the pinned DMG requirements: {package} must be {expected}')


def bundle_manifest(app):
    """Check copied bytes, executable permissions, and symlink targets, including nested code."""
    result = {}
    for path in sorted(app.rglob('*')):
        name = str(path.relative_to(app))
        if path.is_symlink():
            result[name] = ('symlink', os.readlink(path))
        elif path.is_file():
            with path.open('rb') as stream:
                digest = hashlib.file_digest(stream, 'sha256').hexdigest()
            result[name] = ('file', path.stat().st_mode & 0o777, digest)
        elif path.is_dir():
            result[name] = ('directory',)
    return result


def has_bundle_signature(app):
    signature = subprocess.run(['codesign', '-dvv', str(app)], capture_output=True, text=True)
    # Xcode's unsigned builds have a linker-only Mach-O signature, not a sealed bundle.
    linker_only = ('linker-signed' in signature.stderr
                   and not (app / 'Contents/_CodeSignature').exists())
    return signature.returncode == 0 and not linker_only


def verify_signature(app):
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)


def settings(app, background):
    layout = json.loads((ASSETS / 'layout.json').read_text())
    return {
        'format': 'UDZO', 'filesystem': 'HFS+',
        'files': [str(app)], 'symlinks': {'Applications': '/Applications'},
        'background': str(background),
        'window_rect': ((180, 160), (layout['width'], layout['height'])),
        'default_view': 'icon-view', 'arrange_by': None, 'grid_spacing': 64,
        'icon_size': layout['iconSize'], 'text_size': 13,
        'icon_locations': {app.name: tuple(layout['appIconCenter']),
                           'Applications': tuple(layout['applicationsIconCenter'])},
        'show_toolbar': False, 'show_sidebar': False, 'show_status_bar': False,
        'show_pathbar': False, 'show_tab_view': False,
    }


def build(app, volume, output):
    app = Path(app).resolve()
    # Resolve the parent only: an existing output symlink must never be followed.
    output = Path(output).absolute()
    output = output.parent.resolve() / output.name
    if os.path.lexists(output):
        raise ValueError('Output already exists; choose a fresh DMG path')
    if output.suffix != '.dmg':
        raise ValueError('Output must have a .dmg extension')
    if not volume.strip() or any(char in volume for char in '/:\0\n\r'):
        raise ValueError('Volume name must be a nonempty name, not a path')
    if app.suffix != '.app' or not (app / 'Contents/Info.plist').is_file():
        raise ValueError('Provide an existing .app bundle')
    with (app / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    executable = info.get('CFBundleExecutable', '')
    if not executable or Path(executable).name != executable or not (
        app / 'Contents/MacOS' / executable
    ).is_file():
        raise ValueError('App bundle has no valid executable')
    check_tools()
    from dmgbuild.core import DMGError, build_dmg

    manifest = bundle_manifest(app)
    signed = has_bundle_signature(app)
    if signed:
        verify_signature(app)
    # dmgbuild copies with ditto but does not check its exit status. Validate the
    # mounted copy before accepting it, and retain only this build's device IDs.
    mounts = {}
    copied_app = None

    def progress(event):
        nonlocal copied_app
        if event['type'] == 'command::finished' and event.get('command') == 'hdiutil::attach':
            for entity in event.get('output', {}).get('system-entities', []):
                if entity.get('mount-point'):
                    mounts[entity['dev-entry']] = entity['mount-point']
        if event['type'] == 'command::finished' and event.get('command') == 'hdiutil::detach':
            if event.get('ret') == 0:
                mounts.clear()
        if event['type'] == 'operation::finished' and event.get('operation') == 'file::add':
            copied_app = Path(event['file'])
            if bundle_manifest(copied_app) != manifest:
                raise ValueError('Packaged app differs from the source; refusing incomplete DMG')
        if event['type'] == 'operation::finished' and event.get('operation') == 'dmg::create':
            if copied_app is None:
                raise ValueError('DMG contains no app')
            # Finder flags can invalidate a signed bundle even when its bytes
            # match. Verify after *all* layout and metadata changes are finished.
            if signed:
                verify_signature(copied_app)

    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.aerivoice-dmg-', dir=output.parent) as directory:
        stage = Path(directory)
        subprocess.run(['xcrun', 'swift', str(ASSETS / 'render-background.swift'),
                        str(ASSETS / 'layout.json'), str(stage)], check=True)
        candidate = stage / 'candidate.dmg'
        try:
            build_dmg(str(candidate), volume, settings=settings(app, stage / 'background.png'),
                      callback=progress, detach_retries=5)
        except DMGError as error:
            raise ValueError(str(error)) from error
        finally:
            # A failed sync can bypass dmgbuild's own cleanup. Recheck identity
            # before detaching so a reused device number cannot target another disk.
            if mounts:
                attached = subprocess.run(['hdiutil', 'info', '-plist'], check=True,
                                          capture_output=True)
                for disk in plistlib.loads(attached.stdout).get('images', []):
                    for entity in disk.get('system-entities', []):
                        device = entity.get('dev-entry')
                        if device in mounts and entity.get('mount-point') == mounts[device]:
                            subprocess.run(['hdiutil', 'detach', '-force', device], check=True)
        if bundle_manifest(app) != manifest:
            raise ValueError('Source app changed during packaging; discard this candidate')
        # Atomic publication without replacing a concurrent build's output.
        os.link(candidate, output)
    print(f'Branded DMG: {output} (not signed or published)')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest='action', required=True)
    actions.add_parser('check', help='Verify the pinned packaging tools are installed')
    builder = actions.add_parser('build', help='Package a local preview or release staging app')
    builder.add_argument('--app', required=True)
    builder.add_argument('--volume-name', default='AeriVoice')
    builder.add_argument('--output', required=True)
    args = parser.parse_args()
    try:
        if args.action == 'check':
            check_tools()
        else:
            build(args.app, args.volume_name, args.output)
    except (ValueError, OSError, ImportError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'DMG packaging failed: {error}\n')


if __name__ == '__main__':
    main()
