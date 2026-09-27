package jobs

import (
	"context"
	"errors"
	"fmt"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"os"
	"path/filepath"
	"strings"
	"time"
	"tokenlibrary/internal/config"
	"tokenlibrary/internal/store"
)

// RestoreBackup only accepts an empty database and empty data directory. It never replaces a live library.
// The administrator switches deployment configuration after independent verification succeeds.
func RestoreBackup(ctx context.Context, backupDir string, cfg config.Config) (Manifest, error) {
	m, err := VerifyBackup(ctx, backupDir, time.Now())
	if err != nil {
		return m, err
	}
	raw, err := os.ReadFile(cfg.SchemaPath)
	if err != nil {
		return m, err
	}
	if store.Fingerprint(string(raw)) != m.SchemaFingerprint {
		return m, errors.New("backup schema fingerprint does not match this application")
	}
	if !filepath.IsAbs(cfg.DataRoot) || filepath.Clean(cfg.DataRoot) == string(filepath.Separator) {
		return m, errors.New("restore data root must be a non-root absolute path")
	}
	if err = os.MkdirAll(cfg.DataRoot, 0750); err != nil {
		return m, err
	}
	if err = ValidateRoots(cfg.DataRoot, cfg.BackupRoot); err != nil {
		return m, err
	}
	contents, err := os.ReadDir(cfg.DataRoot)
	if err != nil {
		return m, err
	}
	if len(contents) != 0 {
		return m, errors.New("restore destination directory is not empty")
	}
	sourceAbs, err := filepath.Abs(backupDir)
	if err != nil {
		return m, err
	}
	destAbs, err := filepath.Abs(cfg.DataRoot)
	if err != nil {
		return m, err
	}
	if sourceAbs == destAbs || strings.HasPrefix(destAbs, sourceAbs+string(filepath.Separator)) || strings.HasPrefix(sourceAbs, destAbs+string(filepath.Separator)) {
		return m, errors.New("restore source and destination overlap")
	}
	if err = rejectSymlinkPath(cfg.DataRoot, cfg.DataRoot); err != nil {
		return m, err
	}
	pool, err := pgxpool.New(ctx, cfg.DatabaseURL)
	if err != nil {
		return m, err
	}
	defer pool.Close()
	var tables int
	if err = pool.QueryRow(ctx, `SELECT count(*) FROM information_schema.tables WHERE table_schema='public'`).Scan(&tables); err != nil {
		return m, err
	}
	if tables != 0 {
		return m, errors.New("restore target database is not empty; existing data was not modified")
	}
	major, err := databaseMajor(ctx, pool)
	if err != nil {
		return m, err
	}
	if major != m.PostgresMajor {
		return m, fmt.Errorf("backup PostgreSQL %d does not match target %d", m.PostgresMajor, major)
	}
	if err = checkToolMajor(ctx, "pg_restore", major); err != nil {
		return m, err
	}
	if err = runPG(ctx, "pg_restore", cfg.DatabaseURL, "--exit-on-error", "--single-transaction", "--no-owner", "--no-acl", "--dbname", "", filepath.Join(backupDir, "db.dump")); err != nil {
		return m, err
	}
	// The dump was created in maintenance mode. Preserve that until file and relational verification finishes.
	stage := filepath.Join(cfg.DataRoot, ".restore-"+m.BackupID)
	if err = os.Mkdir(stage, 0750); err != nil {
		return m, err
	}
	defer os.RemoveAll(stage)
	for _, f := range m.Files {
		if f.BlobID == "" {
			continue
		}
		copied, err := copyChecked(ctx, filepath.Join(backupDir, filepath.FromSlash(f.Path)), filepath.Join(stage, filepath.FromSlash(f.Path)), f.Path)
		if err != nil {
			return m, err
		}
		if copied.Size != f.Size || copied.SHA256 != f.SHA256 {
			return m, errors.New("restored file integrity mismatch")
		}
	}
	if err = verifyRestoredReferences(ctx, pool, m); err != nil {
		return m, err
	}
	if err = os.MkdirAll(filepath.Join(cfg.DataRoot, "files"), 0750); err != nil {
		return m, err
	}
	stagedFiles := filepath.Join(stage, "files")
	if _, statErr := os.Stat(stagedFiles); errors.Is(statErr, os.ErrNotExist) {
		if err = os.Mkdir(stagedFiles, 0750); err != nil {
			return m, err
		}
	}
	if err = os.Rename(stagedFiles, filepath.Join(cfg.DataRoot, "files", "objects")); err != nil {
		return m, err
	}
	newEpoch := uuid.New()
	tx, err := pool.Begin(ctx)
	if err != nil {
		return m, err
	}
	defer tx.Rollback(ctx)
	for _, q := range []string{`DELETE FROM sessions`, `DELETE FROM upload_chunks`, `DELETE FROM uploads`, `DELETE FROM sync_snapshot_items`, `DELETE FROM sync_snapshots`, `DELETE FROM operations`, `DELETE FROM jobs`, `DELETE FROM backups`} {
		if _, err = tx.Exec(ctx, q); err != nil {
			return m, err
		}
	}
	// Unattached uploads are not in the manifest. Do not leave a ready row without its bytes.
	if _, err = tx.Exec(ctx, `DELETE FROM blobs b WHERE NOT EXISTS(SELECT 1 FROM blob_refs WHERE blob_id=b.id) AND NOT EXISTS(SELECT 1 FROM documents WHERE pdf_blob_id=b.id) AND NOT EXISTS(SELECT 1 FROM annotations WHERE pdf_blob_id=b.id)`); err != nil {
		return m, err
	}
	if _, err = tx.Exec(ctx, `UPDATE libraries SET epoch=$1,maintenance=true`, newEpoch); err != nil {
		return m, err
	}
	if _, err = tx.Exec(ctx, `UPDATE revisions SET epoch=$1`, newEpoch); err != nil {
		return m, err
	}
	if _, err = tx.Exec(ctx, `UPDATE changes SET epoch=$1`, newEpoch); err != nil {
		return m, err
	}
	if err = tx.Commit(ctx); err != nil {
		return m, err
	}
	// Connect runs the normal incremental migrations and obtains singleton ownership before final cleanup.
	s, err := store.Connect(ctx, cfg)
	if err != nil {
		return m, err
	}
	defer s.Close()
	if _, err = PurgeExpired(ctx, s); err != nil {
		return m, err
	}
	if err = CleanupExpiredBackups(ctx, s, time.Now()); err != nil {
		return m, err
	}
	if err = syncTreeDirectories(cfg.DataRoot); err != nil {
		return m, err
	}
	if err = s.SetMaintenance(ctx, false); err != nil {
		return m, err
	}
	return m, nil
}

func verifyRestoredReferences(ctx context.Context, pool *pgxpool.Pool, m Manifest) error {
	var library, epoch, fingerprint string
	if err := pool.QueryRow(ctx, `SELECT id::text,epoch::text FROM libraries`).Scan(&library, &epoch); err != nil {
		return err
	}
	if library != m.LibraryID || epoch != m.Epoch {
		return errors.New("dump identity differs from manifest")
	}
	if err := pool.QueryRow(ctx, `SELECT fingerprint FROM schema_info`).Scan(&fingerprint); err != nil {
		return err
	}
	if fingerprint != m.SchemaFingerprint {
		return errors.New("restored schema fingerprint differs")
	}
	files := map[string]BackupFile{}
	for _, f := range m.Files {
		if f.BlobID != "" {
			files[f.BlobID] = f
		}
	}
	rows, err := pool.Query(ctx, `SELECT b.id::text,encode(b.sha256,'hex'),b.size FROM blobs b WHERE EXISTS(SELECT 1 FROM blob_refs WHERE blob_id=b.id) OR EXISTS(SELECT 1 FROM documents WHERE pdf_blob_id=b.id) OR EXISTS(SELECT 1 FROM annotations WHERE pdf_blob_id=b.id)`)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var id, hash string
		var size int64
		if err = rows.Scan(&id, &hash, &size); err != nil {
			return err
		}
		f, ok := files[id]
		if !ok || f.SHA256 != hash || f.Size != size {
			return fmt.Errorf("restored blob reference missing or changed: %s", id)
		}
	}
	return rows.Err()
}
