"""Offline feed-policy tests: synthetic signatures only, no Keychain or network."""
import base64
import importlib.util
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location('feed', Path(__file__).parents[1] / 'generate-update-feed.py')
feed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(feed)


class FeedPolicyTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / 'appcast.xml'
        self.root = ET.Element('rss', {'version': '2.0'})
        self.channel = ET.SubElement(self.root, 'channel')
        self.item = self.add_item(12, '0.1.0-beta.12')

    def add_item(self, build, label):
        item = ET.SubElement(self.channel, 'item')
        for tag, text in [('version', str(build)), ('shortVersionString', label),
                          ('minimumSystemVersion', '26.0'), ('hardwareRequirements', 'arm64')]:
            ET.SubElement(item, feed.S + tag).text = text
        ET.SubElement(item, 'description').text = 'Release notes <with literal markup>.'
        ET.SubElement(item, 'enclosure', {
            'url': feed.ASSET_ROOT + f'v{label}/AeriVoice-v{label}-arm64.dmg',
            'type': 'application/octet-stream', 'length': '100',
            feed.S + 'edSignature': base64.b64encode(bytes(64)).decode()})
        return item

    def validate(self):
        ET.ElementTree(self.root).write(self.path, encoding='utf-8')
        return feed.validate_feed(self.path)

    def test_beta_labels_and_history_are_preserved(self):
        self.add_item(11, '0.1.0-beta.11')
        _, items, builds = self.validate()
        self.assertEqual(builds, [12, 11])
        self.assertEqual(items[0].findtext(feed.S + 'shortVersionString'), '0.1.0-beta.12')
        self.assertEqual(items[0].findtext('description'), 'Release notes <with literal markup>.')

    def test_duplicate_or_ascending_builds_rejected(self):
        for build in (12, 13):
            with self.subTest(build=build):
                added = self.add_item(build, '0.1.0-beta.11')
                with self.assertRaisesRegex(ValueError, 'strictly descending'):
                    self.validate()
                self.channel.remove(added)

    def test_nonpositive_and_nonnumeric_builds_rejected(self):
        for value in ('0', '-1', '1.2', '01'):
            with self.subTest(value=value):
                self.item.find(feed.S + 'version').text = value
                with self.assertRaisesRegex(ValueError, 'build number'):
                    self.validate()

    def test_bad_asset_urls_rejected(self):
        for url in ('http://example.com/a.dmg', feed.ASSET_ROOT + 'latest/a.dmg',
                    feed.ASSET_ROOT + 'v0.1.0-beta.11/AeriVoice-v0.1.0-beta.11-arm64.dmg'):
            with self.subTest(url=url):
                self.item.find('enclosure').set('url', url)
                with self.assertRaisesRegex(ValueError, 'asset URL'):
                    self.validate()

    def test_bad_architecture_rejected(self):
        self.item.find(feed.S + 'hardwareRequirements').text = 'x86_64'
        with self.assertRaisesRegex(ValueError, 'arm64'):
            self.validate()

    def test_missing_system_requirement_rejected(self):
        self.item.remove(self.item.find(feed.S + 'minimumSystemVersion'))
        with self.assertRaisesRegex(ValueError, 'minimumSystemVersion'):
            self.validate()

    def test_invalid_signature_rejected(self):
        for value in ('', 'invalid', base64.b64encode(bytes(32)).decode()):
            with self.subTest(value=value):
                self.item.find('enclosure').set(feed.S + 'edSignature', value)
                with self.assertRaises(ValueError):
                    self.validate()

    def test_external_notes_channels_and_deltas_rejected(self):
        for tag in ('releaseNotesLink', 'channel', 'deltas'):
            with self.subTest(tag=tag):
                node = ET.SubElement(self.item, feed.S + tag)
                with self.assertRaises(ValueError):
                    self.validate()
                self.item.remove(node)

    def test_duplicate_metadata_rejected(self):
        ET.SubElement(self.item, feed.S + 'version').text = '13'
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            self.validate()

    def test_dtd_rejected(self):
        self.path.write_text('<!DOCTYPE rss><rss><channel/></rss>')
        with self.assertRaisesRegex(ValueError, 'DTD'):
            feed.validate_feed(self.path)


if __name__ == '__main__':
    unittest.main()
