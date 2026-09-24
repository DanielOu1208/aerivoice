#!/usr/bin/env python3
"""Inspect an actual DMG without opening Finder or launching/installing its app."""
import argparse
import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

from ds_store import DSStore

spec = importlib.util.spec_from_file_location('dmg', Path(__file__).with_name('build-dmg.py'))
dmg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dmg)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify(app, image):
    app = Path(app).resolve()
    image = Path(image).resolve()
    with tempfile.TemporaryDirectory(prefix='aerivoice-dmg-inspect-') as directory:
        mount = Path(directory) / 'volume'
        attached = subprocess.run(['hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint',
                                   str(mount), '-plist', str(image)], check=True, capture_output=True)
        entities = plistlib.loads(attached.stdout)['system-entities']
        device = next(entity['dev-entry'] for entity in entities if entity.get('mount-point'))
        try:
            visible = {path.name for path in mount.iterdir() if not path.name.startswith('.')}
            require(visible == {app.name, 'Applications'}, 'Unexpected visible files in DMG')
            require((mount / 'Applications').is_symlink()
                    and os.readlink(mount / 'Applications') == '/Applications',
                    'Applications shortcut must point to /Applications')
            require(dmg.bundle_manifest(app) == dmg.bundle_manifest(mount / app.name),
                    'Archived app bytes, permissions, or symlinks differ from source')
            with DSStore.open(str(mount / '.DS_Store'), 'r') as metadata:
                window = metadata['.']['bwsp']
                require(not any(window[key] for key in ('ShowToolbar', 'ShowSidebar', 'ShowStatusBar')),
                        'Installer window chrome is not hidden')
                require(metadata['.']['icvp']['backgroundType'] == 2, 'Missing artwork reference')
                expected = dmg.settings(app, mount / '.background.tiff')
                for name, location in expected['icon_locations'].items():
                    require(metadata[name]['Iloc'] == location, f'Incorrect position for {name}')
            background = mount / '.background.tiff'
            require(background.is_file(), 'Missing combined Retina background')
            # A real code signature must survive the packaging boundary unchanged.
            if dmg.has_bundle_signature(app):
                dmg.verify_signature(app)
                dmg.verify_signature(mount / app.name)
            print(f'DMG layout and app integrity verified: {image}')
        finally:
            detached = subprocess.run(['hdiutil', 'detach', device], capture_output=True)
            if detached.returncode:
                subprocess.run(['hdiutil', 'detach', '-force', device], check=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True)
    parser.add_argument('--dmg', required=True)
    args = parser.parse_args()
    verify(args.app, args.dmg)
