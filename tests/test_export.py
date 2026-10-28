import contextlib
import copy
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import types
import unittest
from unittest import mock
import urllib.error
import urllib.request

SPEC = importlib.util.spec_from_file_location('exporter', Path(__file__).resolve().parents[1] / 'export.py')
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)
ROOT = Path(__file__).resolve().parents[1]


class FakeClient:
    def __init__(self):
        self.pages = []
        self.downloads = 0
        self.account = {'id': '42', 'username': 'alice', 'url': 'https://source.example/@alice'}
        self.posts = [self.post('20', '2020-02-02T12:00:00.123Z', parent='10'),
                      self.post('10', '2020-01-01T12:00:00.000Z')]
        self.posts[0]['media_attachments'] = [{'id': '55', 'type': 'image',
            'url': 'https://cdn.example/photo.png', 'description': 'A picture', 'meta': {}}]

    def post(self, sid, date, parent=None):
        return {'id': sid, 'account': self.account, 'created_at': date, 'content': '<p>Hello</p>',
                'reblog': None, 'visibility': 'public', 'in_reply_to_id': parent,
                'in_reply_to_account_id': '42' if parent else None, 'media_attachments': []}

    def api(self, path, params=None):
        if path.endswith('verify_credentials'):
            return self.account
        if path.endswith('/source'):
            return {'id': path.split('/')[-2], 'text': 'Hello', 'content_type': 'text/plain', 'spoiler_text': ''}
        self.pages.append(params)
        if params.get('max_id') == '10':
            return []
        return copy.deepcopy(self.posts)

    def get(self, url, dest):
        self.downloads += 1
        dest.write_bytes(b'fake-image-bytes')


class ExportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'archive'
        self.args = types.SimpleNamespace(output=str(self.root), source='https://source.example', account='alice')
        self.client = FakeClient()

    def run_export(self):
        with contextlib.redirect_stdout(io.StringIO()):
            return m.export(self.args, self.client)

    def ruby_check(self, expected=0):
        result = subprocess.run(['ruby', str(ROOT / 'import.rb'), '--archive', str(self.root), '--check-archive'],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def test_roundtrip_integrity_and_resume(self):
        manifest = self.run_export()
        self.assertEqual(len(manifest['posts']), 2)
        self.assertEqual(self.client.pages[-1]['max_id'], '10')
        self.ruby_check()
        self.run_export()
        self.assertEqual(self.client.downloads, 1)
        self.ruby_check()

    def test_corrupt_media_downloaded_again(self):
        self.run_export()
        (self.root / 'media/20-55.png').write_bytes(b'corrupt')
        self.ruby_check(1)
        self.run_export()
        self.assertEqual(self.client.downloads, 2)
        self.ruby_check()

    def test_failed_resume_invalidates_complete_manifest(self):
        self.run_export()
        self.client.posts[1] = copy.deepcopy(self.client.posts[0])
        with self.assertRaises(m.MigrationError):
            self.run_export()
        self.assertFalse((self.root / 'manifest.json').exists())
        self.ruby_check(1)

    def test_other_account_cannot_reuse_archive(self):
        self.run_export()
        self.client.account['url'] = 'https://different.example/@alice'
        with self.assertRaises(m.MigrationError):
            self.run_export()

    def test_wrong_token_account(self):
        self.args.account = 'bob'
        with self.assertRaises(m.MigrationError):
            self.run_export()

    def test_tampered_post_rejected(self):
        self.run_export()
        (self.root / 'posts/10.json').write_text('{}')
        self.ruby_check(1)

    def test_manifest_path_traversal_rejected(self):
        self.run_export()
        p = self.root / 'manifest.json'
        manifest = json.loads(p.read_text())
        manifest['files']['../outside'] = {'sha256': 'x', 'size': 0}
        m.atomic_json(p, manifest)
        self.ruby_check(1)

    def test_symlink_escape_rejected(self):
        self.run_export()
        media = self.root / 'media/20-55.png'
        outside = Path(self.temp.name) / 'outside'
        outside.write_bytes(media.read_bytes())
        media.unlink()
        media.symlink_to(outside)
        self.ruby_check(1)

    def test_source_identity_and_manifest_consistency(self):
        self.run_export()
        p = self.root / 'manifest.json'
        manifest = json.loads(p.read_text())
        manifest['source']['account_id'] = '999'
        m.atomic_json(p, manifest)
        self.ruby_check(1)

    def test_empty_account_is_valid(self):
        self.client.posts = []
        manifest = self.run_export()
        self.assertEqual(manifest['posts'], [])
        self.ruby_check()

    def test_development_archive_without_exporter_version_remains_supported(self):
        self.run_export()
        path = self.root / 'manifest.json'
        manifest = json.loads(path.read_text())
        manifest.pop('exporter_version')
        m.atomic_json(path, manifest)
        self.ruby_check()

    def test_standalone_versions_match_release_metadata(self):
        expected = 'gotosocial-to-mastodon ' + (ROOT / 'VERSION').read_text().strip()
        for command in (['python3', str(ROOT / 'export.py'), '--version'],
                        ['ruby', str(ROOT / 'import.rb'), '--version']):
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), expected)

    def test_standalone_help_is_available_without_credentials(self):
        for command in (['python3', str(ROOT / 'export.py'), '--help'],
                        ['ruby', str(ROOT / 'import.rb'), '--help']):
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('--version', result.stdout)

    def test_boosts_excluded(self):
        self.client.posts[0]['reblog'] = {'id': 'external'}
        manifest = self.run_export()
        self.assertEqual(manifest['excluded_boosts'], 1)
        self.assertEqual(manifest['posts'], ['posts/10.json'])
        self.ruby_check()

    def test_safe_id(self):
        for sid in ('../bad', '', None, 'a/b'):
            with self.assertRaises(m.MigrationError):
                m.safe_id(sid)

    def test_redirect_strips_credentials_on_cross_origin(self):
        request = urllib.request.Request('https://source.example/media', headers={'Authorization': 'Bearer secret'})
        redirected = m.Redirects().redirect_request(request, None, 302, 'Found', {}, 'https://cdn.example/media')
        self.assertIsNone(redirected.get_header('Authorization'))

    def test_redirect_keeps_credentials_on_same_origin(self):
        request = urllib.request.Request('https://source.example/media', headers={'Authorization': 'Bearer secret'})
        redirected = m.Redirects().redirect_request(request, None, 302, 'Found', {}, 'https://source.example/file')
        self.assertEqual(redirected.get_header('Authorization'), 'Bearer secret')

    def test_redirect_rejects_downgrade(self):
        request = urllib.request.Request('https://source.example/media')
        with self.assertRaises(m.MigrationError):
            m.Redirects().redirect_request(request, None, 302, 'Found', {}, 'http://source.example/file')

    def test_client_sends_token_only_to_source_origin(self):
        client = m.Client('https://source.example', 'private-token')
        response = mock.MagicMock()
        response.__enter__.return_value = response
        response.read.return_value = b'{}'
        client.opener = mock.Mock()
        client.opener.open.return_value = response
        client.get('https://cdn.example/object')
        self.assertIsNone(client.opener.open.call_args.args[0].get_header('Authorization'))
        client.get('https://source.example/api/v1/test')
        self.assertEqual(client.opener.open.call_args.args[0].get_header('Authorization'), 'Bearer private-token')

    def test_rate_limit_retry(self):
        client = m.Client('https://source.example', 'private-token')
        response = mock.MagicMock()
        response.__enter__.return_value = response
        response.read.return_value = b'{}'
        client.opener = mock.Mock()
        client.opener.open.side_effect = [urllib.error.HTTPError('url', 429, 'rate limited', {'Retry-After': '2'}, None), response]
        with mock.patch.object(m.time, 'sleep') as sleep:
            self.assertEqual(client.get('https://source.example/api/test'), {})
            sleep.assert_called_once_with(2)

    def test_forbidden_is_not_retried(self):
        client = m.Client('https://source.example', 'private-token')
        client.opener = mock.Mock()
        client.opener.open.side_effect = urllib.error.HTTPError('url', 403, 'Forbidden', {}, None)
        with self.assertRaises(m.MigrationError):
            client.get('https://source.example/api/test')
        self.assertEqual(client.opener.open.call_count, 1)


if __name__ == '__main__':
    unittest.main()
