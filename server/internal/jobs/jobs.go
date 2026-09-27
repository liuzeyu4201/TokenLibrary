package jobs

import (
	"context"
	"errors"
	"fmt"
	"github.com/google/uuid"
	"log"
	"sync"
	"time"
	"tokenlibrary/internal/store"
)

var ErrBusy = errors.New("maintenance already running")

type Runner struct {
	S  *store.Store
	mu sync.Mutex
}

// Retention runs independently of successful backups. Restart catches up only the latest due day.
func (r *Runner) Loop(ctx context.Context) {
	if err := r.recoverInterrupted(ctx); err != nil {
		log.Printf("jobs recovery: %v", err)
	}
	retentionDone := make(chan struct{})
	go func() {
		defer close(retentionDone)
		ticker := time.NewTicker(30 * time.Second)
		defer ticker.Stop()
		for {
			if _, err := PurgeExpired(ctx, r.S); err != nil && !errors.Is(err, ErrBusy) {
				log.Printf("retention: %v", err)
			}
			if err := CleanupExpiredBackups(ctx, r.S, time.Now()); err != nil {
				log.Printf("backup retention: %v", err)
			}
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			}
		}
	}()
	defer func() { <-retentionDone }()
	t := time.NewTicker(30 * time.Second)
	defer t.Stop()
	for {
		if err := r.maybeBackup(ctx); err != nil && !errors.Is(err, ErrBusy) {
			log.Printf("backup: %v", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}
func (r *Runner) recoverInterrupted(ctx context.Context) error {
	tag, err := r.S.Pool.Exec(ctx, `UPDATE jobs SET state='failed',error_code='INTERRUPTED',error_summary='server restarted during backup',heartbeat_at=now() WHERE type='backup' AND state='running'`)
	if err != nil {
		return err
	}
	if tag.RowsAffected() > 0 {
		return r.S.SetMaintenance(ctx, false)
	}
	return nil
}
func ScheduledTime(now time.Time, hhmm, zone string) (time.Time, error) {
	loc, err := time.LoadLocation(zone)
	if err != nil {
		return time.Time{}, fmt.Errorf("backup timezone: %w", err)
	}
	clock, err := time.Parse("15:04", hhmm)
	if err != nil {
		return time.Time{}, fmt.Errorf("backup time: %w", err)
	}
	local := now.In(loc)
	due := time.Date(local.Year(), local.Month(), local.Day(), clock.Hour(), clock.Minute(), 0, 0, loc)
	if due.After(local) {
		due = due.AddDate(0, 0, -1)
	}
	return due.UTC(), nil
}
func (r *Runner) maybeBackup(ctx context.Context) error {
	due, err := ScheduledTime(time.Now(), r.S.Cfg.BackupTime, r.S.Cfg.BackupTimezone)
	if err != nil {
		return err
	}
	var attempts int
	var success bool
	var last *time.Time
	err = r.S.Pool.QueryRow(ctx, `SELECT count(*),coalesce(bool_or(state='success'),false),max(heartbeat_at) FROM jobs WHERE type='backup' AND scheduled_for=$1`, due).Scan(&attempts, &success, &last)
	if err != nil || success || attempts >= 3 {
		return err
	}
	if attempts > 0 && last != nil {
		delay := 15 * time.Minute
		if attempts > 1 {
			delay = time.Hour
		}
		if time.Now().Before(last.Add(delay)) {
			return nil
		}
	}
	return r.runBackup(ctx, due, attempts+1)
}
func (r *Runner) RunBackup(ctx context.Context) error { return r.runBackup(ctx, time.Now().UTC(), 1) }
func (r *Runner) runBackup(parent context.Context, scheduled time.Time, attempt int) (err error) {
	if !r.mu.TryLock() {
		return ErrBusy
	}
	defer r.mu.Unlock()
	timeout := r.S.Cfg.BackupTimeout
	if timeout <= 0 {
		timeout = 20 * time.Minute
	}
	ctx, cancel := context.WithTimeout(parent, timeout)
	defer cancel()
	jobID := uuid.New()
	_, err = r.S.Pool.Exec(ctx, `INSERT INTO jobs(id,type,scheduled_for,attempt,run_id,state,heartbeat_at) VALUES($1,'backup',$2,$3,$1,'running',now())`, jobID, scheduled, attempt)
	if err != nil {
		return err
	}
	defer func() {
		cleanup, done := context.WithTimeout(context.Background(), 10*time.Second)
		defer done()
		state, summary := "success", ""
		if err != nil {
			state, summary = "failed", err.Error()
			if len(summary) > 1000 {
				summary = summary[:1000]
			}
		}
		_, finishErr := r.S.Pool.Exec(cleanup, `UPDATE jobs SET state=$2,heartbeat_at=now(),error_summary=$3 WHERE id=$1`, jobID, state, summary)
		err = errors.Join(err, finishErr)
	}()
	heartbeatCtx, stopHeartbeat := context.WithCancel(ctx)
	heartbeatDone := make(chan struct{})
	go func() {
		defer close(heartbeatDone)
		ticker := time.NewTicker(15 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-heartbeatCtx.Done():
				return
			case <-ticker.C:
				if _, err := r.S.Pool.Exec(heartbeatCtx, `UPDATE jobs SET heartbeat_at=now() WHERE id=$1 AND state='running'`, jobID); err != nil && heartbeatCtx.Err() == nil {
					log.Printf("backup heartbeat: %v", err)
				}
			}
		}
	}()
	defer func() { stopHeartbeat(); <-heartbeatDone }()
	if err = r.S.SetMaintenance(ctx, true); err != nil {
		return err
	}
	defer func() {
		cleanup, done := context.WithTimeout(context.Background(), 10*time.Second)
		defer done()
		err = errors.Join(err, r.S.SetMaintenance(cleanup, false))
	}()
	lockCtx, stop := context.WithTimeout(ctx, 60*time.Second)
	defer stop()
	if err = waitWriteLock(lockCtx, r.S); err != nil {
		return err
	}
	defer r.S.Writes.Unlock()
	if _, err = purgeExpiredLocked(ctx, r.S); err != nil {
		return err
	}
	if err = CleanupExpiredBackups(ctx, r.S, time.Now()); err != nil {
		return err
	}
	return createBackup(ctx, r.S)
}
func waitWriteLock(ctx context.Context, s *store.Store) error {
	timer := time.NewTicker(25 * time.Millisecond)
	defer timer.Stop()
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		if s.Writes.TryLock() {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-timer.C:
		}
	}
}
