package jobs

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"io"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"
	"tokenlibrary/internal/store"
)

type BackupFile struct {
	Path   string `json:"path"`
	Size   int64  `json:"size"`
	SHA256 string `json:"sha256"`
	BlobID string `json:"blobId,omitempty"`
}
type Manifest struct {
	Version           int          `json:"version"`
	BackupID          string       `json:"backupId"`
	LibraryID         string       `json:"libraryId"`
	Epoch             string       `json:"epoch"`
	SchemaFingerprint string       `json:"schemaFingerprint"`
	PostgresMajor     int          `json:"postgresMajor"`
	SnapshotAt        time.Time    `json:"snapshotAt"`
	ExpiresAt         time.Time    `json:"expiresAt"`
	EarliestPurgeAt   *time.Time   `json:"earliestPurgeAt,omitempty"`
	Files             []BackupFile `json:"files"`
}

func createBackup(ctx context.Context, s *store.Store) (err error) {
	if err = ValidateRoots(s.Cfg.DataRoot, s.Cfg.BackupRoot); err != nil {
		return err
	}
	var space syscall.Statfs_t
	if err = syscall.Statfs(s.Cfg.BackupRoot, &space); err != nil {
		return err
	}
	if uint64(space.Bavail)*uint64(space.Bsize) < 1<<30 {
		return errors.New("backup volume has less than 1 GiB available")
	}
	major, err := databaseMajor(ctx, s.Pool)
	if err != nil {
		return err
	}
	if err = checkToolMajor(ctx, "pg_dump", major); err != nil {
		return err
	}
	if err = checkToolMajor(ctx, "pg_restore", major); err != nil {
		return err
	}
	id := uuid.New()
	at := time.Now().UTC()
	m := Manifest{Version: 1, BackupID: id.String(), LibraryID: s.LibID.String(), Epoch: s.Epoch.String(), SchemaFingerprint: s.FP, PostgresMajor: major, SnapshotAt: at, ExpiresAt: at.Add(7 * 24 * time.Hour), Files: []BackupFile{}}
	if err = s.Pool.QueryRow(ctx, `SELECT min(purge_at) FROM objects WHERE library_id=$1 AND state='trashed'`, s.LibID).Scan(&m.EarliestPurgeAt); err != nil {
		return err
	}
	partial := filepath.Join(s.Cfg.BackupRoot, ".partial-"+id.String())
	published := filepath.Join(s.Cfg.BackupRoot, id.String())
	if err = os.Mkdir(partial, 0750); err != nil {
		return err
	}
	defer func() {
		if err != nil {
			_ = os.RemoveAll(partial)
			_ = os.RemoveAll(published)
		}
	}()
	dump := filepath.Join(partial, "db.dump")
	if err = runPG(ctx, "pg_dump", s.Cfg.DatabaseURL, "--format=custom", "--no-owner", "--no-acl", "--file", dump); err != nil {
		return err
	}
	if err = runPG(ctx, "pg_restore", "", "--list", dump); err != nil {
		return fmt.Errorf("dump catalog validation: %w", err)
	}
	if err = syncDirectory(dump); err != nil {
		return err
	}
	record, err := inspectFile(ctx, dump, "db.dump")
	if err != nil {
		return err
	}
	m.Files = append(m.Files, record)
	// Include current, historical, conflict and annotation references; completed but unattached uploads are not documents.
	rows, err := s.Pool.Query(ctx, `SELECT id,sha256,size FROM blobs b WHERE library_id=$1 AND state='ready' AND (EXISTS(SELECT 1 FROM blob_refs WHERE blob_id=b.id) OR EXISTS(SELECT 1 FROM documents WHERE pdf_blob_id=b.id) OR EXISTS(SELECT 1 FROM annotations WHERE pdf_blob_id=b.id)) ORDER BY id`, s.LibID)
	if err != nil {
		return err
	}
	type source struct {
		id   uuid.UUID
		hash []byte
		size int64
	}
	files := []source{}
	for rows.Next() {
		var f source
		if err = rows.Scan(&f.id, &f.hash, &f.size); err != nil {
			rows.Close()
			return err
		}
		files = append(files, f)
	}
	rows.Close()
	if err = rows.Err(); err != nil {
		return err
	}
	for _, f := range files {
		relative := filepath.ToSlash(filepath.Join("files", f.id.String()[:2], f.id.String()))
		copied, err := copyChecked(ctx, store.BlobPath(s.Cfg.DataRoot, f.id), filepath.Join(partial, filepath.FromSlash(relative)), relative)
		if err != nil {
			return err
		}
		if copied.Size != f.size || copied.SHA256 != hex.EncodeToString(f.hash) {
			return fmt.Errorf("blob integrity mismatch: %s", f.id)
		}
		copied.BlobID = f.id.String()
		m.Files = append(m.Files, copied)
	}
	if m.EarliestPurgeAt != nil && !m.EarliestPurgeAt.After(time.Now()) {
		return errors.New("trash expired during backup; retry after retention")
	}
	if err = ctx.Err(); err != nil {
		return err
	}
	raw, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return err
	}
	sum := sha256.Sum256(raw)
	if err = writeDurable(filepath.Join(partial, "manifest.json"), raw); err != nil {
		return err
	}
	if err = writeDurable(filepath.Join(partial, "manifest.sha256"), []byte(hex.EncodeToString(sum[:])+"\n")); err != nil {
		return err
	}
	if _, err = verifyBackup(ctx, partial, time.Now(), true); err != nil {
		return err
	}
	if m.EarliestPurgeAt != nil && !m.EarliestPurgeAt.After(time.Now()) {
		return errors.New("trash expired while verifying backup")
	}
	if err = syncTreeDirectories(partial); err != nil {
		return err
	}
	if err = os.Rename(partial, published); err != nil {
		return err
	}
	if err = syncDirectory(s.Cfg.BackupRoot); err != nil {
		return err
	}
	_, err = s.Pool.Exec(ctx, `INSERT INTO backups(id,snapshot_at,expires_at,path,manifest_hash,state,verified_at) VALUES($1,$2,$3,$4,$5,'success',now())`, id, m.SnapshotAt, m.ExpiresAt, published, sum[:])
	return err
}

// VerifyBackup refuses expired, incomplete, changed or path-escaping archives before restore touches a target.
func VerifyBackup(ctx context.Context, dir string, now time.Time) (Manifest, error) {
	return verifyBackup(ctx, dir, now, false)
}
func verifyBackup(ctx context.Context, dir string, now time.Time, staging bool) (Manifest, error) {
	var m Manifest
	if !staging && strings.HasPrefix(filepath.Base(filepath.Clean(dir)), ".partial-") {
		return m, errors.New("backup has not been published")
	}
	for _, path := range []string{dir, filepath.Join(dir, "manifest.json"), filepath.Join(dir, "manifest.sha256")} {
		if err := rejectSymlinkPath(dir, path); err != nil {
			return m, err
		}
	}
	raw, err := os.ReadFile(filepath.Join(dir, "manifest.json"))
	if err != nil {
		return m, err
	}
	checksum, err := os.ReadFile(filepath.Join(dir, "manifest.sha256"))
	if err != nil {
		return m, err
	}
	sum := sha256.Sum256(raw)
	if strings.TrimSpace(string(checksum)) != hex.EncodeToString(sum[:]) {
		return m, errors.New("manifest checksum mismatch")
	}
	if err = json.Unmarshal(raw, &m); err != nil {
		return m, err
	}
	if m.Version != 1 || m.PostgresMajor < 10 || !m.ExpiresAt.After(now) || m.SnapshotAt.IsZero() || !m.ExpiresAt.Equal(m.SnapshotAt.Add(7*24*time.Hour)) {
		return m, errors.New("unsupported or expired backup")
	}
	for _, id := range []string{m.BackupID, m.LibraryID, m.Epoch} {
		if _, err := uuid.Parse(id); err != nil {
			return m, errors.New("invalid backup identity")
		}
	}
	seen := map[string]bool{}
	for _, f := range m.Files {
		if err := ctx.Err(); err != nil {
			return m, err
		}
		if seen[f.Path] || !validBackupPath(f) {
			return m, errors.New("invalid or duplicate manifest path")
		}
		seen[f.Path] = true
		path := filepath.Join(dir, filepath.FromSlash(f.Path))
		if err := rejectSymlinkPath(dir, path); err != nil {
			return m, err
		}
		actual, err := inspectFile(ctx, path, f.Path)
		if err != nil {
			return m, err
		}
		if actual.Size != f.Size || actual.SHA256 != f.SHA256 {
			return m, fmt.Errorf("backup file checksum mismatch: %s", f.Path)
		}
	}
	if !seen["db.dump"] {
		return m, errors.New("backup database dump missing")
	}
	return m, nil
}

func validBackupPath(f BackupFile) bool {
	if f.Path == "db.dump" {
		return f.BlobID == ""
	}
	id, err := uuid.Parse(f.BlobID)
	if err != nil {
		return false
	}
	return f.Path == "files/"+id.String()[:2]+"/"+id.String()
}
func ValidateRoots(data, backup string) error {
	a, err := filepath.Abs(data)
	if err != nil {
		return err
	}
	b, err := filepath.Abs(backup)
	if err != nil {
		return err
	}
	if data == "" || backup == "" || !filepath.IsAbs(data) || !filepath.IsAbs(backup) || a == string(filepath.Separator) || b == string(filepath.Separator) {
		return errors.New("data and backup roots must be non-root absolute paths")
	}
	if a == b || strings.HasPrefix(a, b+string(filepath.Separator)) || strings.HasPrefix(b, a+string(filepath.Separator)) {
		return errors.New("data and backup roots must not overlap")
	}
	realRoots := make([]string, 0, 2)
	for _, p := range []string{a, b} {
		real, err := filepath.EvalSymlinks(p)
		if err != nil {
			return err
		}
		systemAlias := runtime.GOOS == "darwin" && (strings.HasPrefix(p, "/var/") || strings.HasPrefix(p, "/tmp/")) && real == "/private"+p
		if real != p && !systemAlias {
			return fmt.Errorf("root contains a symlink: %s", p)
		}
		realRoots = append(realRoots, real)
	}
	if realRoots[0] == realRoots[1] || strings.HasPrefix(realRoots[0], realRoots[1]+string(filepath.Separator)) || strings.HasPrefix(realRoots[1], realRoots[0]+string(filepath.Separator)) {
		return errors.New("resolved data and backup roots must not overlap")
	}
	return nil
}
func rejectSymlinkPath(root, path string) error {
	rel, err := filepath.Rel(root, path)
	if err != nil || strings.HasPrefix(rel, "..") || filepath.IsAbs(rel) {
		return errors.New("path escapes backup")
	}
	current := root
	for _, part := range append([]string{""}, strings.Split(rel, string(filepath.Separator))...) {
		current = filepath.Join(current, part)
		info, err := os.Lstat(current)
		if err != nil {
			return err
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return errors.New("symlink in backup path")
		}
	}
	return nil
}
func databaseMajor(ctx context.Context, pool *pgxpool.Pool) (int, error) {
	var version int
	err := pool.QueryRow(ctx, `SELECT current_setting('server_version_num')::int`).Scan(&version)
	return version / 10000, err
}

var versionPattern = regexp.MustCompile(`\b(\d+)\.\d+`)

func checkToolMajor(ctx context.Context, name string, want int) error {
	out, err := exec.CommandContext(ctx, name, "--version").Output()
	if err != nil {
		return fmt.Errorf("%s unavailable: %w", name, err)
	}
	match := versionPattern.FindStringSubmatch(string(out))
	if len(match) < 2 {
		return fmt.Errorf("cannot identify %s version", name)
	}
	major, _ := strconv.Atoi(match[1])
	if major != want {
		return fmt.Errorf("%s major %d does not match PostgreSQL %d", name, major, want)
	}
	return nil
}
func runPG(ctx context.Context, tool, databaseURL string, args ...string) error {
	cmd := exec.CommandContext(ctx, tool, args...)
	cmd.Env = append(os.Environ(), "PGCONNECT_TIMEOUT=10")
	if databaseURL != "" {
		u, err := url.Parse(databaseURL)
		if err != nil || u.Hostname() == "" || (u.Scheme != "postgres" && u.Scheme != "postgresql") {
			return errors.New("PostgreSQL backup requires a postgres:// connection URL")
		}
		cmd.Env = append(cmd.Env, "PGHOST="+u.Hostname(), "PGDATABASE="+strings.TrimPrefix(u.Path, "/"))
		port := u.Port()
		if port == "" {
			port = "5432"
		}
		cmd.Env = append(cmd.Env, "PGPORT="+port)
		if u.User != nil {
			cmd.Env = append(cmd.Env, "PGUSER="+u.User.Username())
			if password, ok := u.User.Password(); ok {
				cmd.Env = append(cmd.Env, "PGPASSWORD="+password)
			}
		}
		if mode := u.Query().Get("sslmode"); mode != "" {
			cmd.Env = append(cmd.Env, "PGSSLMODE="+mode)
		}
	}
	var diagnostic bytes.Buffer
	cmd.Stderr = &diagnostic
	// Database credentials stay in the child environment; sanitize any connection diagnostics.
	if err := cmd.Run(); err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		message := strings.TrimSpace(diagnostic.String())
		if databaseURL != "" {
			message = strings.ReplaceAll(message, databaseURL, "[database]")
			if u, parseErr := url.Parse(databaseURL); parseErr == nil && u.User != nil {
				if password, exists := u.User.Password(); exists && password != "" {
					message = strings.ReplaceAll(message, password, "[redacted]")
					message = strings.ReplaceAll(message, url.QueryEscape(password), "[redacted]")
				}
			}
		}
		if len(message) > 700 {
			message = message[:700]
		}
		return fmt.Errorf("%s failed: %w: %s", tool, err, message)
	}
	return nil
}
func inspectFile(ctx context.Context, path, relative string) (BackupFile, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return BackupFile{}, err
	}
	if !info.Mode().IsRegular() {
		return BackupFile{}, errors.New("backup source is not a regular file")
	}
	file, err := os.Open(path)
	if err != nil {
		return BackupFile{}, err
	}
	defer file.Close()
	hash := sha256.New()
	size, err := io.Copy(hash, &contextReader{ctx: ctx, reader: file})
	if err != nil {
		return BackupFile{}, err
	}
	return BackupFile{Path: relative, Size: size, SHA256: hex.EncodeToString(hash.Sum(nil))}, nil
}

type contextReader struct {
	ctx    context.Context
	reader io.Reader
}

func (r *contextReader) Read(p []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	return r.reader.Read(p)
}
func copyChecked(ctx context.Context, src, dst, relative string) (BackupFile, error) {
	info, err := os.Lstat(src)
	if err != nil {
		return BackupFile{}, err
	}
	if !info.Mode().IsRegular() {
		return BackupFile{}, errors.New("source is not a regular file")
	}
	if err = os.MkdirAll(filepath.Dir(dst), 0750); err != nil {
		return BackupFile{}, err
	}
	in, err := os.Open(src)
	if err != nil {
		return BackupFile{}, err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0640)
	if err != nil {
		return BackupFile{}, err
	}
	hash := sha256.New()
	n, copyErr := io.Copy(io.MultiWriter(out, hash), &contextReader{ctx: ctx, reader: in})
	syncErr := out.Sync()
	closeErr := out.Close()
	if err = errors.Join(copyErr, syncErr, closeErr); err != nil {
		return BackupFile{}, err
	}
	return BackupFile{Path: relative, Size: n, SHA256: hex.EncodeToString(hash.Sum(nil))}, syncDirectory(filepath.Dir(dst))
}
func writeDurable(path string, data []byte) error {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0640)
	if err != nil {
		return err
	}
	_, writeErr := f.Write(data)
	syncErr := f.Sync()
	closeErr := f.Close()
	return errors.Join(writeErr, syncErr, closeErr)
}
func syncDirectory(path string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	return f.Sync()
}

func syncTreeDirectories(root string) error {
	var directories []string
	err := filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() {
			directories = append(directories, path)
		}
		return nil
	})
	if err != nil {
		return err
	}
	for i := len(directories) - 1; i >= 0; i-- {
		if err := syncDirectory(directories[i]); err != nil {
			return err
		}
	}
	return nil
}
