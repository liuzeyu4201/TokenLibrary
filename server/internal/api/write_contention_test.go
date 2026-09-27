package api_test

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"testing"
	"time"

	"github.com/google/uuid"
	"tokenlibrary/internal/jobs"
)

func assertWriteUnavailable(t *testing.T, response *http.Response, code, retryAfter string) {
	t.Helper()
	body := read(t, response)
	var envelope struct {
		Error struct {
			Code      string `json:"code"`
			Retryable bool   `json:"retryable"`
		} `json:"error"`
	}
	if err := json.Unmarshal([]byte(body), &envelope); err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != 503 || envelope.Error.Code != code || !envelope.Error.Retryable ||
		response.Header.Get("Retry-After") != retryAfter {
		t.Fatalf("want retryable %s/%ss, got %d headers=%v body=%s", code, retryAfter, response.StatusCode, response.Header, body)
	}
}

func TestRetentionContentionRetriesWithoutDuplicatingOperation(t *testing.T) {
	f := newSyncFixture(t)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	// Hold a real PostgreSQL row lock so the actual retention job pauses while
	// owning Writes. No sleeps guess how long cleanup happens to take.
	tx, err := f.s.Pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(context.Background())
	if _, err := tx.Exec(ctx, "SELECT id FROM libraries WHERE id=$1 FOR UPDATE", f.s.LibID); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { _, err := jobs.PurgeExpired(ctx, f.s); done <- err }()
	ticker := time.NewTicker(time.Millisecond)
	defer ticker.Stop()
	for {
		if !f.s.Writes.TryRLock() {
			break
		}
		f.s.Writes.RUnlock()
		select {
		case err := <-done:
			t.Fatalf("retention ended before the lock probe: %v", err)
		case <-ctx.Done():
			t.Fatal("retention never acquired its write lock")
		case <-ticker.C:
		}
	}
	objectID, operationID := uuid.NewString(), uuid.NewString()
	raw := fmt.Sprintf(`{"protocolVersion":1,"operationId":%q,"epoch":%q,"deviceId":%q,"objectId":%q,"action":"createMarkdown","desiredSnapshot":{"name":"short-busy.md","parentId":%q,"markdownSource":"preserve once"}}`,
		operationID, f.epoch, f.device, objectID, f.root)
	assertWriteUnavailable(t, post(t, f.url+"/api/v1/sync/operations", raw, f.token, f.epoch, operationID), "BUSY", "1")
	assertWriteUnavailable(t, post(t, f.url+"/api/v1/uploads", "{}", f.token, f.epoch, ""), "BUSY", "1")
	assertWriteUnavailable(t, post(t, f.url+"/api/v1/uploads/"+uuid.NewString()+"/complete", "{}", f.token, f.epoch, ""), "BUSY", "1")
	assertWriteUnavailable(t, post(t, f.url+"/api/v1/imports", "{}", "local-upload-token-32-bytes-min!!", f.epoch, uuid.NewString()), "BUSY", "1")
	if err := tx.Rollback(ctx); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-ctx.Done():
		t.Fatal("retention did not finish")
	}
	f.decode(post(t, f.url+"/api/v1/sync/operations", raw, f.token, f.epoch, operationID), 201)
	replay := f.decode(post(t, f.url+"/api/v1/sync/operations", raw, f.token, f.epoch, operationID), 201)
	if replay["replayed"] != true {
		t.Fatal("the recovered operation must still be idempotent")
	}
	var objects, receipts int
	if err := f.s.Pool.QueryRow(ctx, "SELECT (SELECT count(*) FROM objects WHERE id=$1),(SELECT count(*) FROM operations WHERE operation_id=$2)", objectID, operationID).Scan(&objects, &receipts); err != nil || objects != 1 || receipts != 1 {
		t.Fatalf("duplicate or missing data after retry: objects=%d receipts=%d err=%v", objects, receipts, err)
	}
}

func TestBackupMaintenanceKeepsLongRetryAfterWithAndWithoutWriteLock(t *testing.T) {
	f := newSyncFixture(t)
	if err := f.s.SetMaintenance(context.Background(), true); err != nil {
		t.Fatal(err)
	}
	defer f.s.SetMaintenance(context.Background(), false)
	for _, locked := range []bool{false, true} {
		func() {
			if locked {
				f.s.Writes.Lock()
				defer f.s.Writes.Unlock()
			}
			assertWriteUnavailable(t, post(t, f.url+"/api/v1/sync/operations", "{}", f.token, f.epoch, ""), "MAINTENANCE", "30")
			assertWriteUnavailable(t, post(t, f.url+"/api/v1/uploads", "{}", f.token, f.epoch, ""), "MAINTENANCE", "30")
		}()
	}
}
