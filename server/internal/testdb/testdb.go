package testdb

import (
	"context"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"tokenlibrary/internal/authn"
	"tokenlibrary/internal/config"
	"tokenlibrary/internal/store"
)

func Start(t *testing.T) (*store.Store, config.Config) {
	t.Helper()
	port := freePort(t)
	name := fmt.Sprintf("tlpg-%d", port)
	img := "postgres:17"
	cmd := exec.Command("docker", "run", "-d", "--rm", "--name", name,
		"-e", "POSTGRES_PASSWORD=test", "-e", "POSTGRES_USER=tl", "-e", "POSTGRES_DB=tl",
		"-p", fmt.Sprintf("127.0.0.1:%d:5432", port), img)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("docker run postgres: %v %s", err, out)
	}
	t.Cleanup(func() { _ = exec.Command("docker", "rm", "-f", name).Run() })
	url := fmt.Sprintf("postgres://tl:test@127.0.0.1:%d/tl?sslmode=disable", port)
	deadline := time.Now().Add(40 * time.Second)
	for {
		if time.Now().After(deadline) {
			t.Fatal("postgres not ready")
		}
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		s, err := tryConnect(ctx, t, url)
		cancel()
		if err == nil {
			return s, s.Cfg
		}
		time.Sleep(400 * time.Millisecond)
	}
}

func tryConnect(ctx context.Context, t *testing.T, url string) (*store.Store, error) {
	root := t.TempDir()
	schema := schemaPath(t)
	cfg := config.Config{
		ListenAddr:        ":0",
		DatabaseURL:       url,
		DataRoot:          filepath.Join(root, "data"),
		BackupRoot:        filepath.Join(root, "backup"),
		AdminUsername:     "token",
		AdminPasswordHash: authn.HashPassword("local-dev-pass"),
		UploadTokenHash:   authn.SHA256Bytes("local-upload-token-32-bytes-min!!"),
		UploadTokenEnabled: true,
		PublicBaseURL:     "http://127.0.0.1:8080",
		BackupTime:        "03:00",
		BackupTimezone:    "Asia/Shanghai",
		BackupTimeout:     20 * time.Minute,
		TestHooks:         true,
		SchemaPath:        schema,
		CredentialGen:     1,
	}
	_ = os.MkdirAll(cfg.DataRoot, 0755)
	_ = os.MkdirAll(cfg.BackupRoot, 0755)
	return store.Connect(ctx, cfg)
}

func schemaPath(t *testing.T) string {
	t.Helper()
	wd, _ := os.Getwd()
	for p := wd; p != "/"; p = filepath.Dir(p) {
		cand := filepath.Join(p, "schema", "initial.sql")
		if _, err := os.Stat(cand); err == nil {
			return cand
		}
		cand = filepath.Join(p, "server", "schema", "initial.sql")
		if _, err := os.Stat(cand); err == nil {
			return cand
		}
	}
	t.Fatal("schema not found")
	return ""
}

func freePort(t *testing.T) int {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}

func Must(_ *testing.T, err error) {
	if err != nil {
		panic(err)
	}
}

func Contains(s, sub string) bool { return strings.Contains(s, sub) }
