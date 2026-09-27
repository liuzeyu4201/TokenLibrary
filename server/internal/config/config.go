package config

import (
	"encoding/hex"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	ListenAddr          string
	DatabaseURL         string
	DataRoot            string
	BackupRoot          string
	AdminUsername       string
	AdminPasswordHash   string
	UploadTokenHash     []byte
	UploadTokenEnabled  bool
	PublicBaseURL       string
	BackupTime          string
	BackupTimezone      string
	BackupTimeout       time.Duration
	LogLevel            string
	TestHooks           bool
	SchemaPath          string
	CredentialGen       int
}

func Load() (Config, error) {
	c := Config{
		ListenAddr:     getenv("LISTEN_ADDR", ":8080"),
		DatabaseURL:    os.Getenv("DATABASE_URL"),
		DataRoot:       os.Getenv("DATA_ROOT"),
		BackupRoot:     os.Getenv("BACKUP_ROOT"),
		AdminUsername:  os.Getenv("ADMIN_USERNAME"),
		AdminPasswordHash: os.Getenv("ADMIN_PASSWORD_HASH"),
		PublicBaseURL:  os.Getenv("PUBLIC_BASE_URL"),
		BackupTime:     getenv("BACKUP_TIME", "03:00"),
		BackupTimezone: getenv("BACKUP_TIMEZONE", "Asia/Shanghai"),
		LogLevel:       getenv("LOG_LEVEL", "info"),
		TestHooks:      os.Getenv("TOKENLIBRARY_TEST_HOOKS") == "1",
		SchemaPath:     getenv("SCHEMA_PATH", "schema/initial.sql"),
		CredentialGen:  1,
	}
	to := getenv("BACKUP_TIMEOUT", "20m")
	d, err := time.ParseDuration(to)
	if err != nil {
		d = 20 * time.Minute
	}
	c.BackupTimeout = d
	c.UploadTokenEnabled = getenv("UPLOAD_TOKEN_ENABLED", "true") == "true"
	if h := os.Getenv("UPLOAD_TOKEN_HASH"); h != "" {
		b, err := hex.DecodeString(strings.TrimPrefix(h, "sha256:"))
		if err != nil {
			return c, fmt.Errorf("UPLOAD_TOKEN_HASH: %w", err)
		}
		c.UploadTokenHash = b
	}
	if n := os.Getenv("CREDENTIAL_GENERATION"); n != "" {
		if v, err := strconv.Atoi(n); err == nil {
			c.CredentialGen = v
		}
	}
	if c.DatabaseURL == "" {
		return c, fmt.Errorf("DATABASE_URL required")
	}
	if c.DataRoot == "" || c.BackupRoot == "" {
		return c, fmt.Errorf("DATA_ROOT and BACKUP_ROOT required")
	}
	if c.AdminUsername == "" || c.AdminPasswordHash == "" {
		return c, fmt.Errorf("ADMIN_USERNAME and ADMIN_PASSWORD_HASH required")
	}
	if filepath.Clean(c.DataRoot) == filepath.Clean(c.BackupRoot) {
		return c, fmt.Errorf("DATA_ROOT and BACKUP_ROOT must differ")
	}
	if c.PublicBaseURL != "" {
		u, err := url.Parse(c.PublicBaseURL)
		if err != nil || u.Host == "" {
			return c, fmt.Errorf("PUBLIC_BASE_URL invalid")
		}
	}
	return c, nil
}

func getenv(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}
