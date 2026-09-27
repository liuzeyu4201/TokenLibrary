package jobs

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"os"
	"path/filepath"
	"strings"
	"time"
	"tokenlibrary/internal/store"
)

func PurgeExpired(ctx context.Context, s *store.Store) (int, error) {
	if err := ValidateRoots(s.Cfg.DataRoot, s.Cfg.BackupRoot); err != nil {
		return 0, err
	}
	if !s.Writes.TryLock() {
		return 0, ErrBusy
	}
	defer s.Writes.Unlock()
	return purgeExpiredLocked(ctx, s)
}
func purgeExpiredLocked(ctx context.Context, s *store.Store) (int, error) {
	if err := cleanupEphemeral(ctx, s); err != nil {
		return 0, err
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(ctx)
	var epoch uuid.UUID
	var seq int64
	if err = tx.QueryRow(ctx, `SELECT epoch,change_seq FROM libraries WHERE id=$1 FOR UPDATE`, s.LibID).Scan(&epoch, &seq); err != nil {
		return 0, err
	}
	rows, err := tx.Query(ctx, `SELECT id,kind FROM objects WHERE library_id=$1 AND state='trashed' AND purge_at<=now() ORDER BY id`, s.LibID)
	if err != nil {
		return 0, err
	}
	type expiredObject struct {
		id   uuid.UUID
		kind string
	}
	objects := []expiredObject{}
	for rows.Next() {
		var o expiredObject
		if err = rows.Scan(&o.id, &o.kind); err != nil {
			rows.Close()
			return 0, err
		}
		objects = append(objects, o)
	}
	rows.Close()
	if err = rows.Err(); err != nil {
		return 0, err
	}
	for _, o := range objects {
		id := o.id
		statements := []string{
			`UPDATE blobs SET unreferenced_at=now()-interval '2 days' WHERE id IN (SELECT blob_id FROM blob_refs WHERE owner_id=$1 OR owner_kind='conflict' AND owner_id IN(SELECT id FROM conflicts WHERE object_id=$1)) OR id IN(SELECT pdf_blob_id FROM documents WHERE object_id=$1)`,
			`DELETE FROM blob_refs WHERE owner_id=$1 OR owner_kind='conflict' AND owner_id IN(SELECT id FROM conflicts WHERE object_id=$1)`,
			`DELETE FROM conflict_drafts WHERE conflict_id IN(SELECT id FROM conflicts WHERE object_id=$1)`,
			`DELETE FROM conflicts WHERE object_id=$1`,
			`UPDATE sync_snapshots SET state='expired' WHERE id IN(SELECT snapshot_id FROM sync_snapshot_items WHERE item_id=$1)`,
			`DELETE FROM sync_snapshot_items WHERE item_id=$1`,
			`UPDATE operations SET result_json=jsonb_build_object('status','gone','objectId',object_id::text),conflict_ids='[]'::jsonb WHERE object_id=$1`,
			`DELETE FROM annotations WHERE document_id=$1`,
			`DELETE FROM revisions WHERE object_id=$1`,
			`DELETE FROM documents WHERE object_id=$1`,
			`DELETE FROM objects WHERE id=$1`,
		}
		for _, q := range statements {
			if _, err = tx.Exec(ctx, q, id); err != nil {
				return 0, err
			}
		}
		// Preserve cursors while removing expired bodies from old change manifests.
		if _, err = tx.Exec(ctx, `UPDATE changes SET event_manifest=jsonb_set(event_manifest,'{objects}',coalesce((SELECT jsonb_agg(item) FROM jsonb_array_elements(coalesce(event_manifest->'objects','[]'::jsonb)) item WHERE item->>'id'<>$2),'[]'::jsonb)) WHERE library_id=$1 AND event_manifest->'objects' @> jsonb_build_array(jsonb_build_object('id',$2::text))`, s.LibID, id.String()); err != nil {
			return 0, err
		}
		seq++
		if _, err = tx.Exec(ctx, `INSERT INTO tombstones(library_id,object_id,kind,purged_at,purge_seq) VALUES($1,$2,$3,now(),$4) ON CONFLICT(library_id,object_id) DO NOTHING`, s.LibID, id, o.kind, seq); err != nil {
			return 0, err
		}
		manifest, _ := json.Marshal(map[string]any{"objects": []any{}, "deletedIds": []string{id.String()}})
		if _, err = tx.Exec(ctx, `INSERT INTO changes(library_id,epoch,seq,event_manifest) VALUES($1,$2,$3,$4::jsonb)`, s.LibID, epoch, seq, string(manifest)); err != nil {
			return 0, err
		}
	}
	if _, err = tx.Exec(ctx, `UPDATE libraries SET change_seq=$2 WHERE id=$1`, s.LibID, seq); err != nil {
		return 0, err
	}
	if err = tx.Commit(ctx); err != nil {
		return 0, err
	}
	if err = collectBlobs(ctx, s); err != nil {
		return len(objects), err
	}
	return len(objects), nil
}
func collectBlobs(ctx context.Context, s *store.Store) error {
	_, err := s.Pool.Exec(ctx, `UPDATE blobs b SET unreferenced_at=coalesce(unreferenced_at,now()) WHERE library_id=$1 AND NOT EXISTS(SELECT 1 FROM blob_refs WHERE blob_id=b.id) AND NOT EXISTS(SELECT 1 FROM documents WHERE pdf_blob_id=b.id) AND NOT EXISTS(SELECT 1 FROM annotations WHERE pdf_blob_id=b.id) AND NOT EXISTS(SELECT 1 FROM uploads WHERE blob_id=b.id AND expires_at>now())`, s.LibID)
	if err != nil {
		return err
	}
	rows, err := s.Pool.Query(ctx, `UPDATE blobs b SET state='deleting' WHERE library_id=$1 AND (state='deleting' OR unreferenced_at<=now()-interval '1 day') AND NOT EXISTS(SELECT 1 FROM blob_refs WHERE blob_id=b.id) AND NOT EXISTS(SELECT 1 FROM documents WHERE pdf_blob_id=b.id) AND NOT EXISTS(SELECT 1 FROM annotations WHERE pdf_blob_id=b.id) AND NOT EXISTS(SELECT 1 FROM uploads WHERE blob_id=b.id AND expires_at>now()) RETURNING id`, s.LibID)
	if err != nil {
		return err
	}
	ids := []uuid.UUID{}
	for rows.Next() {
		var id uuid.UUID
		if err = rows.Scan(&id); err != nil {
			rows.Close()
			return err
		}
		ids = append(ids, id)
	}
	rows.Close()
	if err = rows.Err(); err != nil {
		return err
	}
	for _, id := range ids {
		if err = os.Remove(store.BlobPath(s.Cfg.DataRoot, id)); err != nil && !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("remove unreferenced blob %s: %w", id, err)
		}
		tx, err := s.Pool.Begin(ctx)
		if err != nil {
			return err
		}
		if err = deleteBlobRows(ctx, tx, id); err == nil {
			err = tx.Commit(ctx)
		} else {
			_ = tx.Rollback(ctx)
		}
		if err != nil {
			return err
		}
	}
	return nil
}
func deleteBlobRows(ctx context.Context, tx pgx.Tx, id uuid.UUID) error {
	for _, q := range []string{`DELETE FROM upload_chunks WHERE upload_id IN(SELECT id FROM uploads WHERE blob_id=$1)`, `DELETE FROM uploads WHERE blob_id=$1`, `DELETE FROM blobs WHERE id=$1 AND state='deleting'`} {
		if _, err := tx.Exec(ctx, q, id); err != nil {
			return err
		}
	}
	return nil
}
func CleanupExpiredBackups(ctx context.Context, s *store.Store, now time.Time) error {
	if err := ValidateRoots(s.Cfg.DataRoot, s.Cfg.BackupRoot); err != nil {
		return err
	}
	rows, err := s.Pool.Query(ctx, `UPDATE backups SET state='expired' WHERE expires_at<=$1 RETURNING id,path`, now)
	if err != nil {
		return err
	}
	type entry struct {
		id   uuid.UUID
		path string
	}
	entries := []entry{}
	for rows.Next() {
		var e entry
		if err = rows.Scan(&e.id, &e.path); err != nil {
			rows.Close()
			return err
		}
		entries = append(entries, e)
	}
	rows.Close()
	if err = rows.Err(); err != nil {
		return err
	}
	for _, e := range entries {
		expected := filepath.Join(s.Cfg.BackupRoot, e.id.String())
		if filepath.Clean(e.path) != filepath.Clean(expected) {
			return fmt.Errorf("unexpected backup path for %s", e.id)
		}
		if err = removeBackupDirectory(expected); err != nil {
			return err
		}
		if _, err = s.Pool.Exec(ctx, `DELETE FROM backups WHERE id=$1 AND state='expired'`, e.id); err != nil {
			return err
		}
	}
	items, err := os.ReadDir(s.Cfg.BackupRoot)
	if err != nil {
		return err
	}
	for _, item := range items {
		if !item.IsDir() {
			continue
		}
		if strings.HasPrefix(item.Name(), ".partial-") {
			if _, err := uuid.Parse(strings.TrimPrefix(item.Name(), ".partial-")); err != nil {
				continue
			}
			info, err := item.Info()
			if err != nil {
				return err
			}
			if !info.ModTime().Add(7 * 24 * time.Hour).After(now) {
				if err := removeBackupDirectory(filepath.Join(s.Cfg.BackupRoot, item.Name())); err != nil {
					return err
				}
			}
			continue
		}
		if _, err := uuid.Parse(item.Name()); err != nil {
			continue
		}
		dir := filepath.Join(s.Cfg.BackupRoot, item.Name())
		raw, err := os.ReadFile(filepath.Join(dir, "manifest.json"))
		if err != nil {
			continue
		}
		var m Manifest
		if json.Unmarshal(raw, &m) == nil && !m.ExpiresAt.IsZero() && !m.ExpiresAt.After(now) {
			if err := removeBackupDirectory(dir); err != nil {
				return err
			}
		}
	}
	return nil
}
func removeBackupDirectory(path string) error {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("backup path is not a regular directory: %s", path)
	}
	return os.RemoveAll(path)
}

func cleanupEphemeral(ctx context.Context, s *store.Store) error {
	rows, err := s.Pool.Query(ctx, `SELECT id FROM uploads WHERE library_id=$1 AND expires_at<=now()`, s.LibID)
	if err != nil {
		return err
	}
	ids := []uuid.UUID{}
	for rows.Next() {
		var id uuid.UUID
		if err = rows.Scan(&id); err != nil {
			rows.Close()
			return err
		}
		ids = append(ids, id)
	}
	rows.Close()
	if err = rows.Err(); err != nil {
		return err
	}
	for _, id := range ids {
		if err = removeBackupDirectory(filepath.Join(s.Cfg.DataRoot, "files", "staging", id.String())); err != nil {
			return err
		}
		tx, err := s.Pool.Begin(ctx)
		if err != nil {
			return err
		}
		for _, q := range []string{`UPDATE blobs SET unreferenced_at=now()-interval '2 days' WHERE id IN(SELECT blob_id FROM uploads WHERE id=$1)`, `DELETE FROM upload_chunks WHERE upload_id=$1`, `DELETE FROM uploads WHERE id=$1`} {
			if _, err = tx.Exec(ctx, q, id); err != nil {
				break
			}
		}
		if err == nil {
			err = tx.Commit(ctx)
		} else {
			_ = tx.Rollback(ctx)
		}
		if err != nil {
			return err
		}
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err = tx.Exec(ctx, `DELETE FROM sync_snapshot_items WHERE snapshot_id IN(SELECT id FROM sync_snapshots WHERE library_id=$1 AND (expires_at<=now() OR state<>'ready'))`, s.LibID); err != nil {
		return err
	}
	if _, err = tx.Exec(ctx, `DELETE FROM sync_snapshots WHERE library_id=$1 AND (expires_at<=now() OR state<>'ready')`, s.LibID); err != nil {
		return err
	}
	return tx.Commit(ctx)
}
