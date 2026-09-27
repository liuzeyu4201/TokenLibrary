package api_test

import (
	"context"
	"fmt"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/google/uuid"
	"tokenlibrary/internal/api"
	"tokenlibrary/internal/authn"
	"tokenlibrary/internal/jobs"
)

func TestSessionIdleExpiryRenewalLogoutAndCredentialRevocation(t *testing.T) {
	f := newSyncFixture(t)
	ctx := context.Background()
	hash := authn.SHA256Bytes(f.token)
	setLast := func(interval string) {
		t.Helper()
		if _, err := f.s.Pool.Exec(ctx, `UPDATE sessions SET last_seen_at=now()-$2::interval WHERE token_hash=$1`, hash, interval); err != nil {
			t.Fatal(err)
		}
	}
	var last time.Time
	setLast("89 days 23 hours")
	f.decode(get(t, f.url+"/api/v1/meta", f.token, f.epoch), 200)
	if err := f.s.Pool.QueryRow(ctx, `SELECT last_seen_at FROM sessions WHERE token_hash=$1`, hash).Scan(&last); err != nil {
		t.Fatal(err)
	}
	if time.Since(last) > time.Minute {
		t.Fatal("active request did not renew 90 day idle session")
	}
	setLast("90 days 1 second")
	f.decode(get(t, f.url+"/api/v1/meta", f.token, f.epoch), 401)
	if err := f.s.Pool.QueryRow(ctx, `SELECT last_seen_at FROM sessions WHERE token_hash=$1`, hash).Scan(&last); err != nil {
		t.Fatal(err)
	}
	if time.Since(last) < 90*24*time.Hour {
		t.Fatal("expired session was renewed")
	}

	login := func(base string) string {
		t.Helper()
		body := fmt.Sprintf(`{"username":"token","password":"local-dev-pass","deviceId":%q}`, uuid.NewString())
		return f.decode(post(t, base+"/api/v1/auth/login", body, "", "", ""), 200)["sessionToken"].(string)
	}
	a, b := login(f.url), login(f.url)
	if f.decode(post(t, f.url+"/api/v1/auth/logout", "{}", a, f.epoch, ""), 200)["loggedOut"] != true {
		t.Fatal("logout did not confirm revocation")
	}
	f.decode(get(t, f.url+"/api/v1/meta", a, f.epoch), 401)
	f.decode(get(t, f.url+"/api/v1/meta", b, f.epoch), 200)
	var revoked bool
	if err := f.s.Pool.QueryRow(ctx, `SELECT revoked_at IS NOT NULL FROM sessions WHERE token_hash=$1`, authn.SHA256Bytes(a)).Scan(&revoked); err != nil || !revoked {
		t.Fatalf("revocation not durable: %v", err)
	}

	// A configuration credential generation change rejects every prior session,
	// including when a new router starts against an already open database store.
	cfg := f.s.Cfg
	cfg.CredentialGen++
	restarted := httptest.NewServer(api.New(cfg, f.s, &jobs.Runner{S: f.s}))
	defer restarted.Close()
	f.decode(get(t, restarted.URL+"/api/v1/meta", b, f.epoch), 401)
	newToken := login(restarted.URL)
	f.decode(get(t, restarted.URL+"/api/v1/meta", newToken, f.epoch), 200)
}

func TestUploadTokenRotationAndDisableAreIndependentFromClientSession(t *testing.T) {
	f := newSyncFixture(t)
	cfg := f.s.Cfg
	newUploadToken := "isolated-new-upload-token-for-rotation-test"
	cfg.UploadTokenHash = authn.SHA256Bytes(newUploadToken)
	rotated := httptest.NewServer(api.New(cfg, f.s, &jobs.Runner{S: f.s}))
	defer rotated.Close()
	f.decode(importRaw(t, rotated.URL, "local-upload-token-32-bytes-min!!", f.epoch, "old.md", "old"), 401)
	res := importRaw(t, rotated.URL, newUploadToken, f.epoch, "new.md", "new")
	f.decode(res, 201)
	f.decode(get(t, rotated.URL+"/api/v1/meta", newUploadToken, f.epoch), 401)
	f.decode(get(t, rotated.URL+"/api/v1/meta", f.token, f.epoch), 200)
	cfg.UploadTokenEnabled = false
	disabled := httptest.NewServer(api.New(cfg, f.s, &jobs.Runner{S: f.s}))
	defer disabled.Close()
	f.decode(importRaw(t, disabled.URL, newUploadToken, f.epoch, "disabled.md", "content"), 403)
	f.decode(get(t, disabled.URL+"/api/v1/meta", f.token, f.epoch), 200)
}

func TestSessionWriteFailuresNeverReportRenewalOrLogoutSuccess(t *testing.T) {
	f := newSyncFixture(t)
	ctx := context.Background()
	// Inject a database write failure only in this disposable fixture. Reads
	// remain available, reproducing the old ignored renewal/logout Exec errors.
	if _, err := f.s.Pool.Exec(ctx, `CREATE FUNCTION reject_session_write() RETURNS trigger LANGUAGE plpgsql AS $$
	BEGIN RAISE EXCEPTION 'isolated session write failure'; END $$;
	CREATE TRIGGER session_write_failure BEFORE UPDATE ON sessions FOR EACH ROW EXECUTE FUNCTION reject_session_write()`); err != nil {
		t.Fatal(err)
	}
	f.decode(get(t, f.url+"/api/v1/meta", f.token, f.epoch), 503)
	if _, err := f.s.Pool.Exec(ctx, `DROP TRIGGER session_write_failure ON sessions;
	CREATE TRIGGER session_write_failure BEFORE UPDATE OF revoked_at ON sessions FOR EACH ROW EXECUTE FUNCTION reject_session_write()`); err != nil {
		t.Fatal(err)
	}
	f.decode(post(t, f.url+"/api/v1/auth/logout", "{}", f.token, f.epoch, ""), 503)
	// The unsuccessful revocation is visible as failure; the server has not lied
	// that the credential is gone, and a caller can retry after storage recovery.
	f.decode(get(t, f.url+"/api/v1/meta", f.token, f.epoch), 200)
	if _, err := f.s.Pool.Exec(ctx, `DROP TRIGGER session_write_failure ON sessions`); err != nil {
		t.Fatal(err)
	}
	f.decode(post(t, f.url+"/api/v1/auth/logout", "{}", f.token, f.epoch, ""), 200)
	f.decode(get(t, f.url+"/api/v1/meta", f.token, f.epoch), 401)
}
