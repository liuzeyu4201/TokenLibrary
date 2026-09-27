import copy
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('proof', Path(__file__).with_name('prove_mixed_fixture.py'))
proof = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proof)


class FixtureProofTests(unittest.TestCase):
    def fixture(self):
        return {'objects': [{'id': 'pdf', 'name': 'original.pdf', 'contentSHA256': 'original',
                             'reading': {'page': 0}, 'localGeneration': 0}],
                'media': [{'blobID': 'blob', 'bytes': 2, 'sha256': 'hash'}], 'operationStates': {}}

    def test_reading_change_is_reported_not_silently_accepted(self):
        old = self.fixture()
        new = copy.deepcopy(old)
        new['objects'][0]['reading']['page'] = 7
        new['operationStates'] = {'pending': 1}
        result = proof.compare(old, new)
        self.assertTrue(result['bodyAndOriginalContentUnchanged'])
        self.assertEqual(result['changedObjects'][0]['fields'], ['reading'])
        self.assertEqual(result['queueAfter'], {'pending': 1})

    def test_text_media_and_identity_changes_cannot_pass_as_unchanged(self):
        old = self.fixture()
        new = copy.deepcopy(old)
        new['objects'][0]['contentSHA256'] = 'changed'
        new['media'][0]['sha256'] = 'changed'
        result = proof.compare(old, new)
        self.assertFalse(result['bodyAndOriginalContentUnchanged'])
        self.assertFalse(result['allMediaRecordsAndBytesUnchanged'])
        new['objects'] = []
        self.assertEqual(proof.compare(old, new)['removedIDs'], ['pdf'])

    def test_media_path_cannot_escape_through_absolute_parent_or_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / 'inside').write_bytes(b'synthetic')
            self.assertEqual(proof.contained(root, 'inside'), root / 'inside')
            (root / 'link').symlink_to(root / 'inside')
            for relative in ('../outside', '/etc/hosts', 'link'):
                with self.assertRaises(ValueError):
                    proof.contained(root, relative)

    def test_unrelated_directory_refused_before_database_is_opened(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                proof.prove(Path(directory), 'test')


if __name__ == '__main__':
    unittest.main()
