import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("manage", Path(__file__).with_name("manage.py"))
manage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manage)

class DeploymentValidationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.settings = {"DATA_ROOT": str(self.root / "data"), "BACKUP_ROOT": str(self.root / "backup"),
                         "POSTGRES_PASSWORD": "fixture-safe-password", "ADMIN_USERNAME": "fixture",
                         "ADMIN_PASSWORD_HASH": "$argon2id$fixture", "UPLOAD_TOKEN_ENABLED": "false",
                         "PUBLIC_BASE_URL": "http://127.0.0.1:8080"}
    def test_valid_local_and_https_origins(self):
        self.assertEqual(manage.validate(self.settings)[2], "local")
        self.settings.update(DEPLOYMENT="server", PUBLIC_BASE_URL="https://library.example.com", ACME_EMAIL="test@example.com")
        self.assertEqual(manage.validate(self.settings)[2], "server")
    def test_rejects_nested_roots_symlinks_and_source_checkout(self):
        for bad in (self.root / "data" / "nested", Path("/"), manage.ROOT / "data"):
            self.settings["BACKUP_ROOT"] = str(bad)
            with self.assertRaises(ValueError): manage.validate(self.settings)
        link = self.root / "link"
        link.symlink_to(self.root / "data")
        self.settings["BACKUP_ROOT"] = str(self.root / "backup")
        self.settings["DATA_ROOT"] = str(link)
        with self.assertRaises(ValueError): manage.validate(self.settings)
    def test_public_http_and_test_hooks_are_rejected(self):
        self.settings.update(DEPLOYMENT="server", ACME_EMAIL="test@example.com")
        with self.assertRaises(ValueError): manage.validate(self.settings)
        self.settings.update(PUBLIC_BASE_URL="https://library.example.com", TOKENLIBRARY_TEST_HOOKS="1")
        with self.assertRaises(ValueError): manage.validate(self.settings)
    def test_credentials_and_bad_paths_are_not_echoed(self):
        self.settings["POSTGRES_PASSWORD"] = "not@url:safe"
        with self.assertRaises(ValueError) as error: manage.validate(self.settings)
        self.assertNotIn(self.settings["POSTGRES_PASSWORD"], str(error.exception))
    def test_dotenv_is_data_and_quotes_preserve_hash(self):
        marker = self.root / "do-not-create"
        path = self.root / "fixture.env"
        path.write_text(f"ADMIN_PASSWORD_HASH='$argon2id$fixture'\nDATA_ROOT=$(touch {marker})\n")
        settings = manage.read_settings(path)
        self.assertEqual(settings["ADMIN_PASSWORD_HASH"], "$argon2id$fixture")
        self.assertFalse(marker.exists())
    def test_directory_preparation_does_not_chown_existing_tree(self):
        self.settings.update(APP_UID=str(os.getuid()), APP_GID=str(os.getgid()))
        data, backup = Path(self.settings["DATA_ROOT"]), Path(self.settings["BACKUP_ROOT"])
        manage.prepare_directories(data, backup, self.settings, False)
        self.assertTrue((data / "files" / "objects").is_dir())
        self.assertTrue(backup.is_dir())
        self.assertFalse((data / "postgres").exists())
    def test_app_version_must_be_numeric(self):
        self.settings["APP_VERSION"] = "not a version"
        with self.assertRaisesRegex(ValueError, "APP_VERSION"): manage.validate(self.settings)
        self.settings["APP_VERSION"] = "1.0.0"
        self.settings["APP_BUILD"] = "1a"
        with self.assertRaisesRegex(ValueError, "APP_BUILD"): manage.validate(self.settings)
    def test_invalid_timezone_has_actionable_error(self):
        self.settings["BACKUP_TIMEZONE"] = "Not/A-Timezone"
        with self.assertRaisesRegex(ValueError, "BACKUP_TIMEZONE"): manage.validate(self.settings)
    def test_readonly_owned_directory_is_not_reported_writable(self):
        self.settings.update(APP_UID=str(os.getuid()), APP_GID=str(os.getgid()))
        data, backup = Path(self.settings["DATA_ROOT"]), Path(self.settings["BACKUP_ROOT"])
        manage.prepare_directories(data, backup, self.settings, False)
        backup.chmod(0o500)
        self.addCleanup(backup.chmod, 0o700)
        with self.assertRaisesRegex(ValueError, "must be writable"):
            manage.prepare_directories(data, backup, self.settings, False)
    def test_exported_test_hooks_override_even_when_absent_from_dotenv(self):
        path = self.root / "fixture.env"
        path.write_text("DEPLOYMENT=server\n")
        with patch.dict(os.environ, {"TOKENLIBRARY_TEST_HOOKS": "1"}):
            self.assertEqual(manage.read_settings(path)["TOKENLIBRARY_TEST_HOOKS"], "1")
    def test_https_probe_cannot_silently_accept_bad_tls(self):
        with patch.object(manage, "urlopen", side_effect=OSError("certificate verify failed")), patch.object(manage.time, "sleep"), patch.object(manage.time, "monotonic", side_effect=[0, 0, 601]):
            with self.assertRaisesRegex(ValueError, "HTTPS did not become trusted"): manage.wait_https("https://library.example.com")

if __name__ == "__main__": unittest.main()
