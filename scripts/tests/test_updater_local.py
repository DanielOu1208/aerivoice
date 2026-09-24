"""QA fixture transformations only: no signing, Keychain, server, or app execution."""
import argparse
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location('qa', Path(__file__).parents[1] / 'test-updater-local.py')
qa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qa)


class LocalFixtureTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.feed = self.root / 'valid.xml'
        self.feed.write_text(f'<rss xmlns:sparkle="{qa.S[1:-1]}"><channel><title>QA</title>'
                            '<item><sparkle:version>2</sparkle:version><enclosure '
                            'sparkle:edSignature="original" url="http://127.0.0.1:8769/B.dmg"/>'
                            '</item></channel></rss>')

    def test_feed_tampering_keeps_source_and_changes_content(self):
        original = self.feed.read_bytes()
        target = self.root / 'bad.xml'
        qa.invalid_feed(self.feed, target)
        self.assertEqual(self.feed.read_bytes(), original)
        self.assertIn('INVALID QA', ET.parse(target).findtext('./channel/title'))
        self.assertNotEqual(target.read_bytes(), original)

    def test_archive_tampering_changes_only_archive_signature(self):
        target = self.root / 'bad.xml'
        qa.invalid_archive_feed(self.feed, target, 2)
        item = ET.parse(target).find('./channel/item')
        self.assertEqual(item.findtext(qa.S + 'version'), '2')
        self.assertEqual(item.find('enclosure').get('url'), 'http://127.0.0.1:8769/B.dmg')
        self.assertNotEqual(item.find('enclosure').get(qa.S + 'edSignature'), 'original')
        self.assertEqual(ET.parse(self.feed).find('./channel/item/enclosure').get(qa.S + 'edSignature'), 'original')

    def test_separate_unsigned_archive_updates_url_and_length(self):
        target = self.root / 'both-invalid.xml'
        archive = self.root / 'B-unsigned.dmg'
        archive.write_bytes(b'synthetic unsigned archive')
        qa.invalid_archive_feed(self.feed, target, 2, archive)
        enclosure = ET.parse(target).find('./channel/item/enclosure')
        self.assertEqual(enclosure.get('url'), qa.URL + archive.name)
        self.assertEqual(enclosure.get('length'), str(archive.stat().st_size))
        self.assertEqual(ET.parse(self.feed).find('./channel/item/enclosure').get('url'),
                         'http://127.0.0.1:8769/B.dmg')

    def test_ats_override_does_not_modify_production_plist(self):
        source = self.root / 'production.plist'
        source.write_bytes(plistlib.dumps({'SURequireSignedFeed': True}))
        target = self.root / 'qa.plist'
        qa.create_qa_plist(source, target)
        self.assertNotIn('NSAppTransportSecurity', plistlib.loads(source.read_bytes()))
        self.assertTrue(plistlib.loads(target.read_bytes())['NSAppTransportSecurity']['NSAllowsLocalNetworking'])
        self.assertTrue(plistlib.loads(target.read_bytes())['SURequireSignedFeed'])

    def test_select_copies_exact_bytes(self):
        public = self.root / 'public'
        public.mkdir()
        expected = self.feed.read_bytes()
        (public / 'valid.xml').write_bytes(expected)
        qa.select(argparse.Namespace(output=str(self.root), case='valid'))
        self.assertEqual((public / 'appcast.xml').read_bytes(), expected)
        self.assertFalse((public / 'appcast.xml.tmp').exists())


if __name__ == '__main__':
    unittest.main()
