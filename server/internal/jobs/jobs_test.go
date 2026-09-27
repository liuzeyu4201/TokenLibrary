package jobs

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"github.com/google/uuid"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
	"tokenlibrary/internal/config"
	"tokenlibrary/internal/store"
)

func TestScheduledTimeCatchesUpLatestDay(t *testing.T) {
	now := time.Date(2026, 9, 26, 20, 0, 0, 0, time.UTC)
	due, err := ScheduledTime(now, "03:00", "Asia/Shanghai")
	if err != nil {
		t.Fatal(err)
	}
	if want := time.Date(2026, 9, 26, 19, 0, 0, 0, time.UTC); !due.Equal(want) {
		t.Fatalf("due=%v want=%v", due, want)
	}
	before := time.Date(2026, 9, 26, 18, 0, 0, 0, time.UTC)
	due, err = ScheduledTime(before, "03:00", "Asia/Shanghai")
	if err != nil || !due.Equal(time.Date(2026, 9, 25, 19, 0, 0, 0, time.UTC)) {
		t.Fatalf("previous due=%v err=%v", due, err)
	}
	if _, err := ScheduledTime(now, "25:90", "Asia/Shanghai"); err == nil {
		t.Fatal("invalid schedule accepted")
	}
}

func TestRootAliasesCannotHideOverlappingDirectories(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS system path aliases")
	}
	root, err := os.MkdirTemp("/tmp", "tl-roots-")
	must(t, err)
	t.Cleanup(func() { _ = os.RemoveAll(root) })
	must(t, os.Mkdir(filepath.Join(root, "backup"), 0700))
	if err := ValidateRoots(root, "/private"+root+"/backup"); err == nil {
		t.Fatal("system alias bypassed root overlap check")
	}
}

func TestVerifyBackupRejectsTamperingExpiredAndSymlinks(t *testing.T) {
	dir := t.TempDir()
	at := time.Now().UTC()
	data := []byte("custom archive fixture")
	sum := sha256.Sum256(data)
	m := Manifest{Version: 1, BackupID: uuid.NewString(), LibraryID: uuid.NewString(), Epoch: uuid.NewString(), PostgresMajor: 18, SnapshotAt: at, ExpiresAt: at.Add(7 * 24 * time.Hour), Files: []BackupFile{{Path: "db.dump", Size: int64(len(data)), SHA256: hex.EncodeToString(sum[:])}}}
	must(t, os.WriteFile(filepath.Join(dir, "db.dump"), data, 0600))
	writeManifest(t, dir, m)
	if _, err := VerifyBackup(context.Background(), dir, at); err != nil {
		t.Fatal(err)
	}
	partial := filepath.Join(t.TempDir(), ".partial-"+m.BackupID)
	must(t, os.Mkdir(partial, 0700))
	must(t, os.WriteFile(filepath.Join(partial, "db.dump"), data, 0600))
	writeManifest(t, partial, m)
	if _, err := VerifyBackup(context.Background(), partial, at); err == nil {
		t.Fatal("unpublished backup accepted")
	}
	if _, err := VerifyBackup(context.Background(), dir, at.Add(7*24*time.Hour)); err == nil {
		t.Fatal("expired backup accepted")
	}
	must(t, os.WriteFile(filepath.Join(dir, "db.dump"), []byte("tampered"), 0600))
	if _, err := VerifyBackup(context.Background(), dir, at); err == nil {
		t.Fatal("changed dump accepted")
	}
	must(t, os.Remove(filepath.Join(dir, "db.dump")))
	outside := filepath.Join(t.TempDir(), "outside")
	must(t, os.WriteFile(outside, data, 0600))
	must(t, os.Symlink(outside, filepath.Join(dir, "db.dump")))
	if _, err := VerifyBackup(context.Background(), dir, at); err == nil {
		t.Fatal("symlink accepted")
	}
}
func writeManifest(t *testing.T, dir string, m Manifest) {
	t.Helper()
	raw, err := json.Marshal(m)
	must(t, err)
	sum := sha256.Sum256(raw)
	must(t, os.WriteFile(filepath.Join(dir, "manifest.json"), raw, 0600))
	must(t, os.WriteFile(filepath.Join(dir, "manifest.sha256"), []byte(hex.EncodeToString(sum[:])), 0600))
}
func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func localPG(t *testing.T) (*store.Store, config.Config, string) {
	t.Helper()
	if os.Getenv("TOKENLIBRARY_JOBS_INTEGRATION") != "1" {
		t.Skip("set TOKENLIBRARY_JOBS_INTEGRATION=1 for isolated PostgreSQL backup/restore tests")
	}
	for _, tool := range []string{"initdb", "pg_ctl", "pg_dump", "pg_restore"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Fatalf("required PostgreSQL tool %s missing", tool)
		}
	}
	root, err := os.MkdirTemp("", "tl-jobs-")
	must(t, err)
	root, err = filepath.EvalSymlinks(root)
	must(t, err)
	t.Cleanup(func() { _ = os.RemoveAll(root) })
	pgdir := filepath.Join(root, "postgres")
	cmd := exec.Command("initdb", "-D", pgdir, "-U", "tl", "--auth=trust", "--no-locale")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("initdb: %v %s", err, out)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	must(t, err)
	port := listener.Addr().(*net.TCPAddr).Port
	_ = listener.Close()
	cmd = exec.Command("pg_ctl", "-D", pgdir, "-l", filepath.Join(root, "postgres.log"), "-o", fmt.Sprintf("-h 127.0.0.1 -p %d -k %s", port, root), "-w", "start")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("pg_ctl start: %v %s", err, out)
	}
	t.Cleanup(func() { _ = exec.Command("pg_ctl", "-D", pgdir, "-m", "immediate", "-w", "stop").Run() })
	cfg := config.Config{DatabaseURL: fmt.Sprintf("postgres://tl@127.0.0.1:%d/postgres?sslmode=disable", port), DataRoot: filepath.Join(root, "data"), BackupRoot: filepath.Join(root, "backups"), SchemaPath: "../../schema/initial.sql", CredentialGen: 1, BackupTime: "03:00", BackupTimezone: "Asia/Shanghai", BackupTimeout: time.Minute}
	s, err := store.Connect(context.Background(), cfg)
	must(t, err)
	t.Cleanup(s.Close)
	return s, cfg, root
}

func seedBlob(t *testing.T, s *store.Store, body string) (uuid.UUID, []byte) {
	t.Helper()
	id := uuid.New()
	data := []byte(body)
	sum := sha256.Sum256(data)
	path := store.BlobPath(s.Cfg.DataRoot, id)
	must(t, os.MkdirAll(filepath.Dir(path), 0750))
	must(t, os.WriteFile(path, data, 0640))
	_, err := s.Pool.Exec(context.Background(), `INSERT INTO blobs(id,library_id,sha256,size,mime,state)VALUES($1,$2,$3,$4,'application/pdf','ready')`, id, s.LibID, sum[:], len(data))
	must(t, err)
	return id, data
}
func seedDocument(t *testing.T, s *store.Store, blob uuid.UUID, expired bool) uuid.UUID {
	t.Helper()
	id := uuid.New()
	state := "active"
	var purge any
	if expired {
		state = "trashed"
		purge = time.Now().Add(-time.Hour)
	}
	_, err := s.Pool.Exec(context.Background(), `INSERT INTO objects(id,library_id,kind,parent_id,name,name_key,revision,state,purge_at)VALUES($1,$2,'pdf',$3,$4,$4,1,$5,$6)`, id, s.LibID, s.RootID, id.String()+".pdf", state, purge)
	must(t, err)
	_, err = s.Pool.Exec(context.Background(), `INSERT INTO documents(object_id,pdf_blob_id)VALUES($1,$2)`, id, blob)
	must(t, err)
	_, err = s.Pool.Exec(context.Background(), `INSERT INTO blob_refs(blob_id,owner_kind,owner_id,slot)VALUES($1,'object',$2,'pdf')`, blob, id)
	must(t, err)
	return id
}

func TestBackupRestoreRoundTripAndEpochReset(t *testing.T) {
	s, cfg, root := localPG(t)
	ctx := context.Background()
	blob, bytes := seedBlob(t, s, "original pdf bytes")
	unattached, _ := seedBlob(t, s, "completed upload without a document")
	doc := seedDocument(t, s, blob, false)
	must(t, (&Runner{S: s}).RunBackup(ctx))
	var dir string
	must(t, s.Pool.QueryRow(ctx, `SELECT path FROM backups WHERE state='success'`).Scan(&dir))
	manifest, err := VerifyBackup(ctx, dir, time.Now())
	must(t, err)
	if len(manifest.Files) != 2 {
		t.Fatalf("files=%d", len(manifest.Files))
	}
	var maintenance bool
	must(t, s.Pool.QueryRow(ctx, `SELECT maintenance FROM libraries`).Scan(&maintenance))
	if maintenance {
		t.Fatal("maintenance remained enabled")
	}
	_, err = s.Pool.Exec(ctx, `CREATE DATABASE restored`)
	must(t, err)
	target := cfg
	target.DatabaseURL = strings.Replace(cfg.DatabaseURL, "/postgres?", "/restored?", 1)
	target.DataRoot = filepath.Join(root, "restored-data")
	_, err = RestoreBackup(ctx, dir, target)
	must(t, err)
	restored, err := store.Connect(ctx, target)
	must(t, err)
	defer restored.Close()
	if restored.LibID != s.LibID || restored.Epoch == s.Epoch {
		t.Fatal("library identity/epoch contract broken")
	}
	var count int
	must(t, restored.Pool.QueryRow(ctx, `SELECT count(*) FROM documents WHERE object_id=$1`, doc).Scan(&count))
	if count != 1 {
		t.Fatal("document missing after restore")
	}
	must(t, restored.Pool.QueryRow(ctx, `SELECT count(*) FROM blobs WHERE id=$1`, unattached).Scan(&count))
	if count != 0 {
		t.Fatal("restore advertised an unattached upload whose bytes were not backed up")
	}
	actual, err := os.ReadFile(store.BlobPath(target.DataRoot, blob))
	must(t, err)
	if string(actual) != string(bytes) {
		t.Fatal("file changed after restore")
	}
	if _, err := RestoreBackup(ctx, dir, target); err == nil {
		t.Fatal("nonempty restore target accepted")
	}
}

func TestBackupFailureAndTimeoutAlwaysReleaseMaintenance(t *testing.T) {
	s, _, _ := localPG(t)
	ctx := context.Background()
	blob, _ := seedBlob(t, s, "bytes")
	_ = seedDocument(t, s, blob, false)
	must(t, os.Remove(store.BlobPath(s.Cfg.DataRoot, blob)))
	if err := (&Runner{S: s}).RunBackup(ctx); err == nil {
		t.Fatal("missing source silently accepted")
	}
	var maintenance bool
	must(t, s.Pool.QueryRow(ctx, `SELECT maintenance FROM libraries`).Scan(&maintenance))
	if maintenance {
		t.Fatal("failed backup kept maintenance")
	}
	var successes int
	must(t, s.Pool.QueryRow(ctx, `SELECT count(*) FROM backups WHERE state='success'`).Scan(&successes))
	if successes != 0 {
		t.Fatal("partial backup published")
	}
	s.Writes.RLock()
	s.Cfg.BackupTimeout = 100 * time.Millisecond
	err := (&Runner{S: s}).RunBackup(ctx)
	s.Writes.RUnlock()
	if err == nil {
		t.Fatal("expected draining timeout")
	}
	must(t, s.Pool.QueryRow(ctx, `SELECT maintenance FROM libraries`).Scan(&maintenance))
	if maintenance {
		t.Fatal("timeout kept maintenance")
	}
	if !s.Writes.TryLock() {
		t.Fatal("write gate was not released")
	}
	s.Writes.Unlock()
}

func TestPurgeCleansSensitiveCopiesAndKeepsSharedBlob(t *testing.T) {
	s, _, _ := localPG(t)
	ctx := context.Background()
	shared, _ := seedBlob(t, s, "shared")
	exclusive, _ := seedBlob(t, s, "exclusive")
	expired := seedDocument(t, s, exclusive, true)
	_ = seedDocument(t, s, shared, false)
	_, err := s.Pool.Exec(ctx, `INSERT INTO blob_refs(blob_id,owner_kind,owner_id,slot)VALUES($1,'revision:1',$2,'asset')`, shared, expired)
	must(t, err)
	_, err = s.Pool.Exec(ctx, `INSERT INTO changes(library_id,epoch,seq,event_manifest)VALUES($1,$2,1,$3::jsonb)`, s.LibID, s.Epoch, fmt.Sprintf(`{"objects":[{"id":%q,"snapshot":{"markdownSource":"private text"}}]}`, expired.String()))
	must(t, err)
	_, err = s.Pool.Exec(ctx, `UPDATE libraries SET change_seq=1`)
	must(t, err)
	op, snapshot := uuid.New(), uuid.New()
	_, err = s.Pool.Exec(ctx, `INSERT INTO operations(library_id,epoch,operation_id,principal_kind,action,object_id,request_hash,input_hash,status,result_json) VALUES($1,$2,$3,'device','updateDocument',$4,'\x00','\x00','applied','{"snapshot":{"markdownSource":"private text"}}')`, s.LibID, s.Epoch, op, expired)
	must(t, err)
	_, err = s.Pool.Exec(ctx, `INSERT INTO sync_snapshots(id,library_id,epoch,at_seq,expires_at,state) VALUES($1,$2,$3,1,now()+interval '1 hour','ready')`, snapshot, s.LibID, s.Epoch)
	must(t, err)
	_, err = s.Pool.Exec(ctx, `INSERT INTO sync_snapshot_items(snapshot_id,item_id,kind,frozen_content) VALUES($1,$2,'object',$3)`, snapshot, expired, []byte("private text"))
	must(t, err)
	n, err := PurgeExpired(ctx, s)
	must(t, err)
	if n != 1 {
		t.Fatalf("purged=%d", n)
	}
	if _, err = os.Stat(store.BlobPath(s.Cfg.DataRoot, exclusive)); !os.IsNotExist(err) {
		t.Fatalf("exclusive blob still present: %v", err)
	}
	if _, err = os.Stat(store.BlobPath(s.Cfg.DataRoot, shared)); err != nil {
		t.Fatal("shared blob removed")
	}
	var raw string
	must(t, s.Pool.QueryRow(ctx, `SELECT event_manifest::text FROM changes WHERE seq=1`).Scan(&raw))
	if strings.Contains(raw, "private text") {
		t.Fatal("historical change kept expired body")
	}
	must(t, s.Pool.QueryRow(ctx, `SELECT result_json::text FROM operations WHERE operation_id=$1`, op).Scan(&raw))
	if strings.Contains(raw, "private text") || !strings.Contains(raw, "gone") {
		t.Fatal("operation receipt retained expired body")
	}
	var count int
	must(t, s.Pool.QueryRow(ctx, `SELECT count(*) FROM sync_snapshot_items WHERE item_id=$1`, expired).Scan(&count))
	if count != 0 {
		t.Fatal("frozen snapshot retained expired body")
	}
	must(t, s.Pool.QueryRow(ctx, `SELECT count(*) FROM tombstones WHERE object_id=$1`, expired).Scan(&count))
	if count != 1 {
		t.Fatal("tombstone missing")
	}
	id := uuid.New()
	old := filepath.Join(s.Cfg.BackupRoot, id.String())
	must(t, os.MkdirAll(old, 0750))
	must(t, os.WriteFile(filepath.Join(old, "data"), []byte("old"), 0600))
	_, err = s.Pool.Exec(ctx, `INSERT INTO backups(id,snapshot_at,expires_at,path,state)VALUES($1,now()-interval '8 days',now()-interval '1 day',$2,'success')`, id, old)
	must(t, err)
	must(t, CleanupExpiredBackups(ctx, s, time.Now()))
	if _, err = os.Stat(old); !os.IsNotExist(err) {
		t.Fatal("expired backup directory survived")
	}
}

func TestRetentionExpiresUploadButKeepsResumableUpload(t *testing.T) {
	s, _, _ := localPG(t)
	ctx := context.Background()
	for _, expired := range []bool{true, false} {
		blob, _ := seedBlob(t, s, fmt.Sprintf("upload-%v", expired))
		id := uuid.New()
		deadline := time.Now().Add(time.Hour)
		if expired {
			deadline = time.Now().Add(-time.Hour)
		}
		_, err := s.Pool.Exec(ctx, `INSERT INTO uploads(id,library_id,epoch,owner_kind,owner_id,blob_id,expected_size,expected_hash,mime,state,expires_at) VALUES($1,$2,$3,'device',$4,$5,1,'\x00','application/pdf','receiving',$6)`, id, s.LibID, s.Epoch, uuid.New(), blob, deadline)
		must(t, err)
		staging := filepath.Join(s.Cfg.DataRoot, "files", "staging", id.String())
		must(t, os.MkdirAll(staging, 0700))
		must(t, os.WriteFile(filepath.Join(staging, "0"), []byte("partial"), 0600))
		if !expired {
			// Another upload for the same bytes has expired. Its cleanup must not erase this live lease.
			_, err = s.Pool.Exec(ctx, `INSERT INTO uploads(id,library_id,epoch,owner_kind,owner_id,blob_id,expected_size,expected_hash,mime,state,expires_at) VALUES($1,$2,$3,'device',$4,$5,1,'\x00','application/pdf','receiving',now()-interval '1 hour')`, uuid.New(), s.LibID, s.Epoch, uuid.New(), blob)
			must(t, err)
		}
		_, err = PurgeExpired(ctx, s)
		must(t, err)
		_, statErr := os.Stat(staging)
		if expired && !os.IsNotExist(statErr) || !expired && statErr != nil {
			t.Fatalf("expired=%v staging error=%v", expired, statErr)
		}
		var count int
		must(t, s.Pool.QueryRow(ctx, `SELECT count(*) FROM uploads WHERE id=$1`, id).Scan(&count))
		if expired && count != 0 || !expired && count != 1 {
			t.Fatalf("expired=%v upload rows=%d", expired, count)
		}
		if !expired {
			if _, err := os.Stat(store.BlobPath(s.Cfg.DataRoot, blob)); err != nil {
				t.Fatalf("valid upload lease lost its blob: %v", err)
			}
		}
	}
}
