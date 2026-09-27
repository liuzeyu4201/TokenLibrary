package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"time"
	"tokenlibrary/internal/config"
	"tokenlibrary/internal/jobs"
)

func main() {
	if len(os.Args) < 2 {
		fail("usage: library-admin verify|restore --backup DIR [--data-root NEW_EMPTY_DIR --schema FILE]")
	}
	action := os.Args[1]
	flags := flag.NewFlagSet(action, flag.ExitOnError)
	backup := flags.String("backup", "", "backup UUID directory")
	data := flags.String("data-root", "", "new empty data directory; existing data is never overwritten")
	schema := flags.String("schema", "schema/initial.sql", "application schema baseline")
	duration := flags.Duration("timeout", 30*time.Minute, "verification and restore timeout")
	dbEnv := flags.String("database-env", "RESTORE_DATABASE_URL", "environment variable containing an empty target database URL")
	_ = flags.Parse(os.Args[2:])
	if *backup == "" {
		fail("--backup required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), *duration)
	defer cancel()
	switch action {
	case "verify":
		m, err := jobs.VerifyBackup(ctx, *backup, time.Now())
		if err != nil {
			fail(err.Error())
		}
		fmt.Printf("verified backup=%s library=%s expires=%s files=%d\n", m.BackupID, m.LibraryID, m.ExpiresAt.Format(time.RFC3339), len(m.Files))
	case "restore":
		database := os.Getenv(*dbEnv)
		if database == "" || *data == "" {
			fail("--data-root and target database environment variable are required")
		}
		backupRoot := os.Getenv("BACKUP_ROOT")
		if backupRoot == "" {
			fail("BACKUP_ROOT must name the retained backup directory, separate from the new data root")
		}
		cfg := config.Config{DatabaseURL: database, DataRoot: *data, BackupRoot: backupRoot, SchemaPath: *schema, CredentialGen: 1}
		m, err := jobs.RestoreBackup(ctx, *backup, cfg)
		if err != nil {
			fail(err.Error())
		}
		fmt.Printf("restored library=%s from backup=%s into isolated target; new epoch issued and sessions revoked\n", m.LibraryID, m.BackupID)
	default:
		fail("unknown operation; use verify or restore")
	}
}
func fail(message string) { fmt.Fprintln(os.Stderr, message); os.Exit(1) }
