package jobs

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"tokenlibrary/internal/config"
	"tokenlibrary/internal/store"
	"tokenlibrary/internal/synceng"
)

// Unlike the separate purge and media roundtrips, this inspects the actual new
// custom dump before restore can clear ephemeral rows and hide a backup leak.
func TestRetentionBackupExcludesExpiredCopiesAndRestoresArchivedMedia(t *testing.T) {
	s, cfg, root := localPG(t)
	ctx := context.Background()
	corpus := seedRetentionCorpus(t, s)
	oldDir, oldManifest := backupRetentionCorpus(t, s)
	oldDump := dumpSQL(t, oldDir)
	oldArchive, readErr := os.ReadFile(filepath.Join(oldDir, "db.dump"))
	must(t, readErr)
	if !containsDumpMarker(oldDump, corpus.marker) || len(oldManifest.Files) != 5 {
		t.Fatal("pre-expiry backup did not contain the intended mixed corpus")
	}
	// Only this test's private DB is aged; no production clock or running
	// service is modified. Ordinary creates, edits, conflict and trash use Engine.
	_, err := s.Pool.Exec(ctx, `UPDATE objects SET purge_at=now()-interval '1 second' WHERE id=ANY($1::uuid[])`, corpus.expired)
	must(t, err)
	newDir, newManifest := backupRetentionCorpus(t, s)
	assertRetentionResult(t, s, corpus, false)
	if len(newManifest.Files) != 3 || newManifest.EarliestPurgeAt != nil {
		t.Fatalf("new backup must contain only dump and 2 retained media: %#v", newManifest)
	}
	for _, f := range newManifest.Files {
		if f.BlobID != "" && corpus.kept[uuid.MustParse(f.BlobID)] == nil {
			t.Fatalf("expired exclusive blob entered new backup: %s", f.BlobID)
		}
	}
	newDump := dumpSQL(t, newDir)
	if containsDumpMarker(newDump, corpus.marker) {
		t.Fatal("new custom dump retained expired text in plaintext or bytea hex")
	}
	// Published old backups are independent copies and remain usable until
	// their own seven-day deadline; source retention must not silently alter one.
	// PG18's textual pg_restore output has a fresh \\restrict key each run;
	// compare the actual immutable custom archive rather than that wrapper.
	got, readErr := os.ReadFile(filepath.Join(oldDir, "db.dump"))
	must(t, readErr)
	if !bytes.Equal(got, oldArchive) {
		t.Fatal("source purge rewrote the older backup")
	}
	_, err = VerifyBackup(ctx, oldDir, oldManifest.ExpiresAt.Add(-time.Nanosecond))
	must(t, err)
	if _, err = VerifyBackup(ctx, oldDir, oldManifest.ExpiresAt); err == nil {
		t.Fatal("old backup remained restorable at its seven-day deadline")
	}
	restored := restoreRetentionCorpus(t, s, cfg, root, newDir, "retention_restored")
	assertRetentionResult(t, restored, corpus, true)
	if !newManifest.ExpiresAt.After(oldManifest.ExpiresAt) {
		t.Fatal("backup ordering fixture is invalid")
	}
	must(t, CleanupExpiredBackups(ctx, s, oldManifest.ExpiresAt))
	if _, err = os.Stat(oldDir); !os.IsNotExist(err) {
		t.Fatalf("expired real backup directory survived: %v", err)
	}
	_, err = VerifyBackup(ctx, newDir, oldManifest.ExpiresAt)
	must(t, err)
	t.Logf("actual custom dumps: before=%d files after=%d; expired objects=%d; restored archived objects=%d; kept media=%d; source copies/old receipts/snapshots purged; 7-day boundary enforced", len(oldManifest.Files), len(newManifest.Files), len(corpus.expired), len(corpus.snapshots), len(corpus.kept))
}

// A valid backup may contain trash whose 30-day deadline passes while the
// server is offline. Exercise RestoreBackup's own final purge after a real
// short clock wait, without modifying/repacking the published archive.
func TestRestorePurgesTrashThatExpiresAfterTheBackupSnapshot(t *testing.T) {
	s, cfg, root := localPG(t)
	ctx := context.Background()
	corpus := seedRetentionCorpus(t, s)
	deadline := time.Now().Add(8 * time.Second)
	_, err := s.Pool.Exec(ctx, `UPDATE objects SET purge_at=$2 WHERE id=ANY($1::uuid[])`, corpus.expired, deadline)
	must(t, err)
	dir, manifest := backupRetentionCorpus(t, s)
	if len(manifest.Files) != 5 || manifest.EarliestPurgeAt == nil || !manifest.EarliestPurgeAt.Before(manifest.ExpiresAt) {
		t.Fatal("missing short-lived trash in the real backup")
	}
	if !containsDumpMarker(dumpSQL(t, dir), corpus.marker) {
		t.Fatal("backup must contain unexpired trash to exercise restore-time purge")
	}
	if remaining := time.Until(deadline) + 50*time.Millisecond; remaining > 0 {
		time.Sleep(remaining)
	}
	// The backup itself has not reached seven days and is still valid. Its
	// expired trash must be removed from the restored DB and copied media.
	_, err = VerifyBackup(ctx, dir, time.Now())
	must(t, err)
	restored := restoreRetentionCorpus(t, s, cfg, root, dir, "expired_at_restore")
	assertRetentionResult(t, restored, corpus, true)
	var sourceTrash int
	must(t, s.Pool.QueryRow(ctx, `SELECT count(*) FROM objects WHERE id=ANY($1::uuid[]) AND state='trashed'`, corpus.expired).Scan(&sourceTrash))
	if sourceTrash != len(corpus.expired) {
		t.Fatal("restore mutated the original source database")
	}
	if !containsDumpMarker(dumpSQL(t, dir), corpus.marker) {
		t.Fatal("restore rewrote its input backup")
	}
	t.Logf("restore after actual deadline: original backup still has %d files; restored %d tombstones, removed 2 exclusive media, kept 2 shared media and %d archived snapshots; source DB untouched", len(manifest.Files), len(corpus.expired), len(corpus.snapshots))
}

type retentionCorpus struct {
	marker    string
	expired   []uuid.UUID
	exclusive []uuid.UUID
	kept      map[uuid.UUID][]byte
	snapshots map[uuid.UUID]string
}

func seedRetentionCorpus(t *testing.T, s *store.Store) retentionCorpus {
	t.Helper()
	ctx := context.Background()
	engine := &synceng.Engine{S: s}
	apply := func(action string, id uuid.UUID, revision int64, desired map[string]any) synceng.OpResult {
		t.Helper()
		env := synceng.Envelope{ProtocolVersion: 1, OperationID: uuid.NewString(), Epoch: s.Epoch.String(), DeviceID: uuid.NewString(), ObjectID: id.String(), Action: action, DesiredSnapshot: desired}
		if revision > 0 {
			env.Base = &synceng.BaseRef{Source: "revision", Revision: revision}
		}
		raw, err := json.Marshal(env)
		must(t, err)
		result, err := engine.Apply(ctx, env, "client", raw)
		must(t, err)
		if result.HTTP >= 400 {
			t.Fatalf("retention fixture operation: %#v", result)
		}
		return result
	}
	pngBytes := func(shade uint8) []byte {
		im := image.NewRGBA(image.Rect(0, 0, 8, 8))
		for y := 0; y < 8; y++ {
			for x := 0; x < 8; x++ {
				im.SetRGBA(x, y, color.RGBA{R: shade, G: uint8(y * 30), B: uint8(x * 30), A: 255})
			}
		}
		var out bytes.Buffer
		must(t, png.Encode(&out, im))
		_, err := png.Decode(bytes.NewReader(out.Bytes()))
		must(t, err)
		return out.Bytes()
	}
	sharedPDFBytes, sharedPNGBytes := readableFixturePDF(), pngBytes(80)
	sharedPDF := seedMediaBlob(t, s, sharedPDFBytes, "application/pdf")
	sharedPNG := seedMediaBlob(t, s, sharedPNGBytes, "image/png")
	exclusivePDF := seedMediaBlob(t, s, readableFixturePDF(), "application/pdf")
	exclusivePNG := seedMediaBlob(t, s, pngBytes(180), "image/png")
	topic, archivePDF, archiveNote := uuid.New(), uuid.New(), uuid.New()
	expiredSharedPDF, expiredExclusivePDF, expiredNote := uuid.New(), uuid.New(), uuid.New()
	marker := "EXPIRED_RETENTION_CONTENT_" + uuid.NewString()
	apply("createFolder", topic, 0, map[string]any{"name": "archived-research", "parentId": s.RootID.String(), "metadata": map[string]any{"category": "topic", "archived": true}})
	apply("createPDF", archivePDF, 0, map[string]any{"name": "archived-paper.pdf", "parentId": s.RootID.String(), "pdfBlobId": sharedPDF.String(),
		"metadata":    map[string]any{"category": "paper", "title": "Retained research", "authors": []string{"Synthetic Author"}, "year": 2026, "doi": "10.0000/retained", "archived": true, "topicIDs": []string{topic.String()}},
		"annotations": []any{map[string]any{"id": uuid.NewString(), "type": "highlight", "pdfBlobId": sharedPDF.String(), "pageIndex": 0, "geometry": map[string]any{"x": 72, "y": 710, "width": 120, "height": 22}, "text": "Reading fixture", "color": "#FFE08A"}}})
	asset := func(id uuid.UUID, name string) map[string]any {
		return map[string]any{"blobId": id.String(), "path": "media/" + name, "mime": "image/png"}
	}
	apply("createMarkdown", archiveNote, 0, map[string]any{"name": "archived-notes.md", "parentId": s.RootID.String(), "markdownSource": "# Retained notes\n\n![figure](media/shared.png)\n",
		"assets": []any{asset(sharedPNG, "shared.png")}, "metadata": map[string]any{"category": "note", "archived": true, "sourceIDs": []string{archivePDF.String()}, "topicIDs": []string{topic.String()}, "excerpts": []any{map[string]any{"id": uuid.NewString(), "sourceID": archivePDF.String(), "quote": "Reading fixture", "comment": "Keep archived research", "pageIndex": 0}}}})
	for i, id := range []uuid.UUID{expiredSharedPDF, expiredExclusivePDF} {
		blob := sharedPDF
		if i == 1 {
			blob = exclusivePDF
		}
		apply("createPDF", id, 0, map[string]any{"name": fmt.Sprintf("expired-%d.pdf", i), "parentId": s.RootID.String(), "pdfBlobId": blob.String(),
			"metadata": map[string]any{"title": marker}, "annotations": []any{map[string]any{"id": uuid.NewString(), "type": "comment", "pdfBlobId": blob.String(), "pageIndex": 0, "geometry": map[string]any{"x": 72, "y": 710, "width": 120, "height": 22}, "text": marker}}})
	}
	text := "# " + marker + "\n\nbase opinion\n\n![shared](media/shared.png)\n![exclusive](media/exclusive.png)\n"
	apply("createMarkdown", expiredNote, 0, map[string]any{"name": "expired-notes.md", "parentId": s.RootID.String(), "markdownSource": text,
		"assets": []any{asset(sharedPNG, "shared.png"), asset(exclusivePNG, "exclusive.png")}})
	apply("updateDocument", expiredNote, 1, map[string]any{"markdownSource": strings.Replace(text, "base opinion", "remote opinion", 1)})
	conflict := apply("updateDocument", expiredNote, 1, map[string]any{"markdownSource": strings.Replace(text, "base opinion", "local opinion", 1)})
	if conflict.Status != "conflict" || len(conflict.ConflictIDs) != 1 {
		t.Fatal("retention fixture did not create its real conflict")
	}
	_, err := s.Pool.Exec(ctx, `INSERT INTO conflict_drafts(id,conflict_id,device_id,revision,body,seen_conflict_revision) VALUES($1,$2,$3,1,$4,1)`, uuid.New(), conflict.ConflictIDs[0], uuid.New(), []byte(marker+" draft"))
	must(t, err)
	for _, id := range []uuid.UUID{expiredSharedPDF, expiredExclusivePDF, expiredNote} {
		apply("trash", id, 0, nil)
	}
	// A still-live frozen page contains both expired-candidate and archived
	// content. Retention must not leave the former in a raw dump.
	snapshot := uuid.New()
	_, err = s.Pool.Exec(ctx, `INSERT INTO sync_snapshots(id,library_id,epoch,at_seq,expires_at,state) SELECT $1,id,epoch,change_seq,now()+interval '1 hour','ready' FROM libraries`, snapshot)
	must(t, err)
	for _, id := range []uuid.UUID{expiredNote, archiveNote} {
		_, err = s.Pool.Exec(ctx, `INSERT INTO sync_snapshot_items(snapshot_id,item_id,kind,frozen_content) VALUES($1,$2,'object',$3)`, snapshot, id, []byte(retentionSnapshot(t, s, id)))
		must(t, err)
	}
	corpus := retentionCorpus{marker: marker, expired: []uuid.UUID{expiredSharedPDF, expiredExclusivePDF, expiredNote}, exclusive: []uuid.UUID{exclusivePDF, exclusivePNG}, kept: map[uuid.UUID][]byte{sharedPDF: sharedPDFBytes, sharedPNG: sharedPNGBytes}, snapshots: map[uuid.UUID]string{}}
	for _, id := range []uuid.UUID{topic, archivePDF, archiveNote} {
		corpus.snapshots[id] = retentionSnapshot(t, s, id)
	}
	return corpus
}

func retentionSnapshot(t *testing.T, s *store.Store, id uuid.UUID) string {
	t.Helper()
	ctx := context.Background()
	tx, err := s.Pool.Begin(ctx)
	must(t, err)
	defer tx.Rollback(ctx)
	snapshot, err := (&synceng.Engine{S: s}).LoadPublic(ctx, tx, id)
	must(t, err)
	raw, err := json.Marshal(snapshot)
	must(t, err)
	return string(raw)
}

func backupRetentionCorpus(t *testing.T, s *store.Store) (string, Manifest) {
	t.Helper()
	ctx := context.Background()
	must(t, (&Runner{S: s}).RunBackup(ctx))
	var dir string
	must(t, s.Pool.QueryRow(ctx, `SELECT path FROM backups WHERE state='success' ORDER BY snapshot_at DESC LIMIT 1`).Scan(&dir))
	manifest, err := VerifyBackup(ctx, dir, time.Now())
	must(t, err)
	return dir, manifest
}

func restoreRetentionCorpus(t *testing.T, s *store.Store, cfg config.Config, root, dir, database string) *store.Store {
	t.Helper()
	ctx := context.Background()
	// Callers supply fixed test identifiers, never user-controlled SQL.
	_, err := s.Pool.Exec(ctx, `CREATE DATABASE `+database)
	must(t, err)
	target := cfg
	target.DatabaseURL = strings.Replace(cfg.DatabaseURL, "/postgres?", "/"+database+"?", 1)
	target.DataRoot = filepath.Join(root, database+"-data")
	_, err = RestoreBackup(ctx, dir, target)
	must(t, err)
	restored, err := store.Connect(ctx, target)
	must(t, err)
	t.Cleanup(restored.Close)
	if restored.LibID != s.LibID || restored.Epoch == s.Epoch {
		t.Fatal("restore changed library identity or kept the old epoch")
	}
	return restored
}

func assertRetentionResult(t *testing.T, s *store.Store, corpus retentionCorpus, restored bool) {
	t.Helper()
	ctx := context.Background()
	for id, expected := range corpus.snapshots {
		if got := retentionSnapshot(t, s, id); got != expected {
			t.Fatalf("archived snapshot changed: %s\nwant %s\ngot %s", id, expected, got)
		}
	}
	for _, table := range []string{"objects", "documents", "revisions", "annotations", "conflicts"} {
		column := map[string]string{"objects": "id", "documents": "object_id", "revisions": "object_id", "annotations": "document_id", "conflicts": "object_id"}[table]
		var count int
		must(t, s.Pool.QueryRow(ctx, `SELECT count(*) FROM `+table+` WHERE `+column+`=ANY($1::uuid[])`, corpus.expired).Scan(&count))
		if count != 0 {
			t.Fatalf("expired rows survived in %s: %d", table, count)
		}
	}
	var tombstones, uniqueSeq, drafts, snapshots int
	must(t, s.Pool.QueryRow(ctx, `SELECT count(*),count(DISTINCT purge_seq) FROM tombstones WHERE object_id=ANY($1::uuid[])`, corpus.expired).Scan(&tombstones, &uniqueSeq))
	if tombstones != len(corpus.expired) || uniqueSeq != tombstones {
		t.Fatal("missing distinct purge tombstones")
	}
	must(t, s.Pool.QueryRow(ctx, `SELECT count(*) FROM conflict_drafts`).Scan(&drafts))
	must(t, s.Pool.QueryRow(ctx, `SELECT count(*) FROM sync_snapshot_items WHERE item_id=ANY($1::uuid[])`, corpus.expired).Scan(&snapshots))
	if drafts != 0 || snapshots != 0 {
		t.Fatal("expired conflict drafts/frozen bodies survived")
	}
	var leakedChanges, badReceipts, receiptCount int
	must(t, s.Pool.QueryRow(ctx, `SELECT count(*) FROM changes WHERE strpos(event_manifest::text,$1)>0`, corpus.marker).Scan(&leakedChanges))
	must(t, s.Pool.QueryRow(ctx, `SELECT count(*),count(*) FILTER(WHERE result_json->>'status'<>'gone' OR strpos(result_json::text,$2)>0) FROM operations WHERE object_id=ANY($1::uuid[])`, corpus.expired, corpus.marker).Scan(&receiptCount, &badReceipts))
	if leakedChanges != 0 || badReceipts != 0 || !restored && receiptCount == 0 {
		t.Fatal("historical change/receipt redaction was not verified")
	}
	for _, id := range corpus.exclusive {
		var count int
		must(t, s.Pool.QueryRow(ctx, `SELECT count(*) FROM blobs WHERE id=$1`, id).Scan(&count))
		if count != 0 {
			t.Fatalf("exclusive blob row survived: %s", id)
		}
		if _, err := os.Stat(store.BlobPath(s.Cfg.DataRoot, id)); !os.IsNotExist(err) {
			t.Fatalf("exclusive blob bytes survived: %s: %v", id, err)
		}
	}
	for id, expected := range corpus.kept {
		actual, err := os.ReadFile(store.BlobPath(s.Cfg.DataRoot, id))
		must(t, err)
		if !bytes.Equal(actual, expected) || sha256.Sum256(actual) != sha256.Sum256(expected) {
			t.Fatalf("shared archived media changed: %s", id)
		}
	}
	if restored {
		for _, table := range []string{"operations", "sync_snapshots", "sync_snapshot_items", "sessions", "uploads"} {
			var count int
			must(t, s.Pool.QueryRow(ctx, `SELECT count(*) FROM `+table).Scan(&count))
			if count != 0 {
				t.Fatalf("restore retained old transient table %s", table)
			}
		}
	}
	var maintenance bool
	must(t, s.Pool.QueryRow(ctx, `SELECT maintenance FROM libraries`).Scan(&maintenance))
	if maintenance {
		t.Fatal("backup/restore left maintenance enabled")
	}
}

func dumpSQL(t *testing.T, dir string) []byte {
	t.Helper()
	cmd := exec.Command("pg_restore", "--file=-", filepath.Join(dir, "db.dump"))
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	raw, err := cmd.Output()
	if err != nil {
		t.Fatalf("inspect custom dump: %v: %s", err, stderr.String())
	}
	return raw
}

func containsDumpMarker(raw []byte, marker string) bool {
	return bytes.Contains(raw, []byte(marker)) || bytes.Contains(bytes.ToLower(raw), []byte(hex.EncodeToString([]byte(marker))))
}
