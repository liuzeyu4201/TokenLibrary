package jobs

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/google/uuid"
	"tokenlibrary/internal/store"
	"tokenlibrary/internal/synceng"
)

func TestOldAndCompositeAnnotationKeysSurviveBackupRestore(t *testing.T) {
	s, cfg, root := localPG(t)
	ctx := context.Background()
	blob := seedMediaBlob(t, s, readableFixturePDF(), "application/pdf")
	annID, first, second := uuid.NewString(), uuid.New(), uuid.New()
	create := func(st *store.Store, id uuid.UUID, name, text string) {
		t.Helper()
		env := synceng.Envelope{ProtocolVersion: 1, OperationID: uuid.NewString(), Epoch: st.Epoch.String(), DeviceID: uuid.NewString(), ObjectID: id.String(), Action: "createPDF", DesiredSnapshot: map[string]any{"parentId": st.RootID.String(), "name": name, "pdfBlobId": blob.String(), "annotations": []any{map[string]any{"id": annID, "type": "comment", "pageIndex": 0, "geometry": map[string]any{"x": 72, "y": 72, "width": 200, "height": 40}, "text": text, "pdfBlobId": blob.String()}}}}
		raw, err := json.Marshal(env)
		must(t, err)
		result, err := (&synceng.Engine{S: st}).Apply(ctx, env, "client", raw)
		must(t, err)
		if result.HTTP != 201 {
			t.Fatalf("copy creation failed: %#v", result)
		}
	}
	rows := func(st *store.Store) string {
		t.Helper()
		var value string
		must(t, st.Pool.QueryRow(ctx, `SELECT jsonb_agg(to_jsonb(a) ORDER BY document_id,id)::text FROM annotations a`).Scan(&value))
		return value
	}
	create(s, first, "original.pdf", "原批注 unchanged")
	// Recreate only this isolated source's old PK before taking a real old-schema dump.
	_, err := s.Pool.Exec(ctx, `ALTER TABLE annotations DROP CONSTRAINT annotations_pkey; ALTER TABLE annotations ADD CONSTRAINT annotations_pkey PRIMARY KEY(id); DELETE FROM app_migrations WHERE version='v3-document-annotation-identity';`)
	must(t, err)
	before := rows(s)
	current := s
	for _, database := range []string{"annotation_old_restored", "annotation_composite_restored"} {
		must(t, (&Runner{S: current}).RunBackup(ctx))
		var backupDir string
		must(t, current.Pool.QueryRow(ctx, `SELECT path FROM backups WHERE state='success' ORDER BY snapshot_at DESC LIMIT 1`).Scan(&backupDir))
		_, err := s.Pool.Exec(ctx, `CREATE DATABASE `+database)
		must(t, err)
		target := cfg
		target.DatabaseURL = strings.Replace(cfg.DatabaseURL, "/postgres?", "/"+database+"?", 1)
		target.DataRoot = filepath.Join(root, database, "data")
		target.BackupRoot = filepath.Join(root, database, "backups")
		must(t, os.MkdirAll(target.BackupRoot, 0700))
		_, err = RestoreBackup(ctx, backupDir, target)
		must(t, err)
		restored, err := store.Connect(ctx, target)
		must(t, err)
		defer restored.Close()
		if restored.LibID != s.LibID || restored.Epoch == current.Epoch {
			t.Fatal("restore identity/epoch contract")
		}
		if got := rows(restored); got != before {
			t.Fatalf("annotation values changed by backup restore: %s != %s", got, before)
		}
		var key string
		must(t, restored.Pool.QueryRow(ctx, `SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid='annotations'::regclass AND contype='p'`).Scan(&key))
		if key != "PRIMARY KEY (document_id, id)" {
			t.Fatalf("old dump was not migrated: %s", key)
		}
		if database == "annotation_old_restored" {
			create(restored, second, "recovered.pdf", "副本独立批注")
			before = rows(restored)
		} else {
			var count int
			must(t, restored.Pool.QueryRow(ctx, `SELECT count(*) FROM annotations WHERE id=$1`, annID).Scan(&count))
			if count != 2 {
				t.Fatalf("composite dump lost annotation copy: %d", count)
			}
		}
		current = restored
	}
}
