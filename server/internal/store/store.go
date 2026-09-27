package store

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"tokenlibrary/internal/config"
)

const SchemaFingerprintEnv = "SCHEMA_FINGERPRINT"

type Store struct {
	// Writes coordinates all document/blob mutations with a consistent backup.
	// Normal writes use TryRLock; backup and destructive maintenance hold Lock.
	Writes      sync.RWMutex
	singleton   *pgxpool.Conn
	singletonMu sync.Mutex
	Pool        *pgxpool.Pool
	Cfg         config.Config
	FP          string
	LibID       uuid.UUID
	Epoch       uuid.UUID
	RootID      uuid.UUID
}

func Fingerprint(sql string) string {
	sum := sha256.Sum256([]byte(normalizeSQL(sql)))
	return hex.EncodeToString(sum[:])
}

func normalizeSQL(s string) string {
	s = strings.ReplaceAll(s, "\r\n", "\n")
	return s
}

func Connect(ctx context.Context, cfg config.Config) (*Store, error) {
	poolCfg, err := pgxpool.ParseConfig(cfg.DatabaseURL)
	if err != nil {
		return nil, err
	}
	poolCfg.MaxConns = 10
	pool, err := pgxpool.NewWithConfig(ctx, poolCfg)
	if err != nil {
		return nil, err
	}
	s := &Store{Pool: pool, Cfg: cfg}
	s.singleton, err = pool.Acquire(ctx)
	if err != nil {
		pool.Close()
		return nil, err
	}
	var exclusive bool
	if err = s.singleton.QueryRow(ctx, `SELECT pg_try_advisory_lock(847301591)`).Scan(&exclusive); err != nil || !exclusive {
		s.Close()
		if err != nil {
			return nil, err
		}
		return nil, fmt.Errorf("another TokenLibrary server already owns this database")
	}
	raw, err := os.ReadFile(cfg.SchemaPath)
	if err != nil {
		s.Close()
		return nil, fmt.Errorf("schema: %w", err)
	}
	s.FP = Fingerprint(string(raw))
	if err := s.ensureSchema(ctx, string(raw)); err != nil {
		s.Close()
		return nil, err
	}
	if err := s.ensureLibrary(ctx); err != nil {
		s.Close()
		return nil, err
	}
	if err := s.ensureFeatures(ctx); err != nil {
		s.Close()
		return nil, err
	}
	for _, d := range []string{
		filepath.Join(cfg.DataRoot, "files", "objects"),
		filepath.Join(cfg.DataRoot, "files", "staging"),
		filepath.Join(cfg.DataRoot, "runtime", "app"),
		cfg.BackupRoot,
	} {
		if err := os.MkdirAll(d, 0750); err != nil {
			s.Close()
			return nil, err
		}
	}
	return s, nil
}

func (s *Store) Close() {
	s.singletonMu.Lock()
	if s.singleton != nil {
		s.singleton.Release()
		s.singleton = nil
	}
	s.singletonMu.Unlock()
	s.Pool.Close()
}

func (s *Store) ensureSchema(ctx context.Context, ddl string) error {
	var exists bool
	err := s.Pool.QueryRow(ctx, `SELECT EXISTS (
		SELECT 1 FROM information_schema.tables WHERE table_name='schema_info')`).Scan(&exists)
	if err != nil {
		return err
	}
	if !exists {
		tx, err := s.Pool.Begin(ctx)
		if err != nil {
			return err
		}
		defer tx.Rollback(ctx)
		if _, err := tx.Exec(ctx, ddl); err != nil {
			return fmt.Errorf("init ddl: %w", err)
		}
		if _, err := tx.Exec(ctx, `INSERT INTO schema_info(fingerprint, initialized_at) VALUES ($1, now())`, s.FP); err != nil {
			return err
		}
		return tx.Commit(ctx)
	}
	var fp string
	if err := s.Pool.QueryRow(ctx, `SELECT fingerprint FROM schema_info LIMIT 1`).Scan(&fp); err != nil {
		return err
	}
	if fp != s.FP {
		return fmt.Errorf("schema fingerprint mismatch: have %s want %s", fp, s.FP)
	}
	return nil
}

func (s *Store) ensureLibrary(ctx context.Context) error {
	var id, epoch, root uuid.UUID
	err := s.Pool.QueryRow(ctx, `SELECT id, epoch, root_id FROM libraries LIMIT 1`).Scan(&id, &epoch, &root)
	if errors.Is(err, pgx.ErrNoRows) {
		id = uuid.New()
		epoch = uuid.New()
		root = uuid.New()
		tx, err := s.Pool.Begin(ctx)
		if err != nil {
			return err
		}
		defer tx.Rollback(ctx)
		if _, err := tx.Exec(ctx, `INSERT INTO libraries(id, epoch, root_id, change_seq, credential_generation) VALUES ($1,$2,$3,0,$4)`,
			id, epoch, root, s.Cfg.CredentialGen); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO objects(id, library_id, kind, parent_id, name, name_key, revision, state, updated_seq)
			VALUES ($1,$2,'folder',NULL,'Library','library',1,'active',0)`, root, id); err != nil {
			return err
		}
		if err := tx.Commit(ctx); err != nil {
			return err
		}
		s.LibID, s.Epoch, s.RootID = id, epoch, root
		return nil
	}
	if err != nil {
		return err
	}
	s.LibID, s.Epoch, s.RootID = id, epoch, root
	if _, err := s.Pool.Exec(ctx, `UPDATE libraries SET credential_generation=$1 WHERE id=$2 AND credential_generation <> $1`,
		s.Cfg.CredentialGen, id); err == nil {
		_, _ = s.Pool.Exec(ctx, `UPDATE sessions SET revoked_at=now() WHERE library_id=$1 AND credential_generation <> $2 AND revoked_at IS NULL`,
			id, s.Cfg.CredentialGen)
	}
	return nil
}

func (s *Store) Ready(ctx context.Context) (maintenance bool, err error) {
	s.singletonMu.Lock()
	if s.singleton != nil {
		err = s.singleton.Conn().Ping(ctx)
	} else {
		err = fmt.Errorf("single instance lock unavailable")
	}
	s.singletonMu.Unlock()
	if err != nil {
		return false, err
	}
	if err := s.Pool.Ping(ctx); err != nil {
		return false, err
	}
	var fp string
	if err := s.Pool.QueryRow(ctx, `SELECT fingerprint FROM schema_info LIMIT 1`).Scan(&fp); err != nil {
		return false, err
	}
	if fp != s.FP {
		return false, fmt.Errorf("schema mismatch")
	}
	err = s.Pool.QueryRow(ctx, `SELECT maintenance FROM libraries WHERE id=$1`, s.LibID).Scan(&maintenance)
	return maintenance, err
}

func (s *Store) SetMaintenance(ctx context.Context, on bool) error {
	_, err := s.Pool.Exec(ctx, `UPDATE libraries SET maintenance=$1 WHERE id=$2`, on, s.LibID)
	return err
}

func (s *Store) LockLibrary(ctx context.Context, tx pgx.Tx) (epoch uuid.UUID, seq int64, maint bool, err error) {
	err = tx.QueryRow(ctx, `SELECT epoch, change_seq, maintenance FROM libraries WHERE id=$1 FOR UPDATE`, s.LibID).
		Scan(&epoch, &seq, &maint)
	return
}

func BlobPath(root string, id uuid.UUID) string {
	s := id.String()
	return filepath.Join(root, "files", "objects", s[:2], s)
}

func StagingPath(root string, uploadID uuid.UUID, index int) string {
	return filepath.Join(root, "files", "staging", uploadID.String(), fmt.Sprintf("%d.part", index))
}

func MustUUID(s string) (uuid.UUID, error) {
	return uuid.Parse(strings.ToLower(strings.TrimSpace(s)))
}

func NowUTC() time.Time { return time.Now().UTC() }
