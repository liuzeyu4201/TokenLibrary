package api_test

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/google/uuid"
	"tokenlibrary/internal/api"
	"tokenlibrary/internal/jobs"
	"tokenlibrary/internal/store"
)

func annotationBlob(t *testing.T, f *syncFixture) string {
	t.Helper()
	body := []byte("%PDF-1.4\nsynthetic annotation identity protocol fixture\n%%EOF\n")
	hash := sha256.Sum256(body)
	blob := uuid.NewString()
	upload := f.decode(post(t, f.url+"/api/v1/uploads", fmt.Sprintf(`{"blobId":%q,"size":%d,"sha256":%q,"mime":"application/pdf"}`, blob, len(body), hex.EncodeToString(hash[:])), f.token, f.epoch, ""), 200)
	endpoint := f.url + "/api/v1/uploads/" + upload["uploadId"].(string)
	req, _ := http.NewRequest(http.MethodPut, endpoint+"/chunks/0", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+f.token)
	req.Header.Set("X-Chunk-SHA256", hex.EncodeToString(hash[:]))
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	f.decode(res, 200)
	f.decode(post(t, endpoint+"/complete", `{}`, f.token, f.epoch, ""), 200)
	return blob
}
func annotationRecord(id, blob, text string) map[string]any {
	return map[string]any{"id": id, "type": "comment", "pageIndex": 0, "geometry": map[string]any{"x": 0.1, "y": 0.2, "width": 0.3, "height": 0.1}, "color": "#A9D4FF", "text": text, "pdfBlobId": blob, "placementState": "attached"}
}
func annotationWire(t *testing.T, f *syncFixture, action, id string, base int64, desired map[string]any) (string, string) {
	t.Helper()
	op := uuid.NewString()
	env := map[string]any{"protocolVersion": 1, "operationId": op, "epoch": f.epoch, "deviceId": f.device, "objectId": id, "action": action, "desiredSnapshot": desired}
	if base > 0 {
		env["base"] = map[string]any{"source": "revision", "revision": base}
	}
	raw, err := json.Marshal(env)
	if err != nil {
		t.Fatal(err)
	}
	return op, string(raw)
}
func annotationRows(t *testing.T, s *store.Store) string {
	t.Helper()
	var rows string
	if err := s.Pool.QueryRow(context.Background(), `SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY document_id,id),'[]'::jsonb)::text FROM annotations a`).Scan(&rows); err != nil {
		t.Fatal(err)
	}
	return rows
}
func annotationScalar(t *testing.T, s *store.Store, query string, args ...any) int {
	t.Helper()
	var n int
	if err := s.Pool.QueryRow(context.Background(), query, args...).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}
func annotationSQL(t *testing.T, s *store.Store, sql string) {
	t.Helper()
	if _, err := s.Pool.Exec(context.Background(), sql); err != nil {
		t.Fatal(err)
	}
}

func TestAnnotationIdentityIsScopedToDocument(t *testing.T) {
	f := newSyncFixture(t)
	blob := annotationBlob(t, f)
	id := uuid.NewString()
	a, b := uuid.NewString(), uuid.NewString()
	for i, doc := range []string{a, b} {
		f.op("createPDF", doc, 0, map[string]any{"name": fmt.Sprintf("copy-%d.pdf", i), "parentId": f.root, "pdfBlobId": blob, "annotations": []any{annotationRecord(id, blob, "original")}}, nil)
	}
	if got := annotationScalar(t, f.s, `SELECT count(*) FROM annotations WHERE id=$1`, id); got != 2 {
		t.Fatalf("copies share identity but need independent rows: %d", got)
	}
	f.op("updateDocument", b, 1, map[string]any{"annotations": []any{annotationRecord(id, blob, "copy edit")}}, nil)
	var original string
	if err := f.s.Pool.QueryRow(context.Background(), `SELECT text FROM annotations WHERE document_id=$1 AND id=$2`, a, id).Scan(&original); err != nil || original != "original" {
		t.Fatalf("original changed: %s %v", original, err)
	}
	f.op("updateDocument", b, 2, map[string]any{"annotations": []any{}}, nil)
	if annotationScalar(t, f.s, `SELECT count(*) FROM annotations WHERE document_id=$1 AND id=$2`, a, id) != 1 || annotationScalar(t, f.s, `SELECT count(*) FROM annotations WHERE document_id=$1`, b) != 0 {
		t.Fatal("deleting copy annotation touched original")
	}
}

func TestDuplicateAnnotationInOneDocumentIsRejectedAtomically(t *testing.T) {
	f := newSyncFixture(t)
	blob := annotationBlob(t, f)
	id := uuid.NewString()
	doc := uuid.NewString()
	ann := annotationRecord(id, blob, "unchanged")
	f.op("createPDF", doc, 0, map[string]any{"name": "original.pdf", "parentId": f.root, "pdfBlobId": blob, "annotations": []any{ann}}, nil)
	rows := annotationRows(t, f.s)
	for _, action := range []string{"updateDocument", "createPDF"} {
		target, base := doc, int64(1)
		desired := map[string]any{"annotations": []any{ann, annotationRecord(id, blob, "duplicate")}}
		if action == "createPDF" {
			target = uuid.NewString()
			base = 0
			desired["name"] = "invalid.pdf"
			desired["parentId"] = f.root
			desired["pdfBlobId"] = blob
		}
		op, wire := annotationWire(t, f, action, target, base, desired)
		f.decode(post(t, f.url+"/api/v1/sync/operations", wire, f.token, f.epoch, op), 422)
		if annotationRows(t, f.s) != rows {
			t.Fatal("invalid operation altered annotation rows")
		}
		if action == "createPDF" && annotationScalar(t, f.s, `SELECT count(*) FROM objects WHERE id=$1`, target) != 0 {
			t.Fatal("invalid copy partially created")
		}
	}
	if annotationScalar(t, f.s, `SELECT revision FROM objects WHERE id=$1`, doc) != 1 {
		t.Fatal("invalid update advanced revision")
	}
}

func TestLegacyAnnotationMigrationRetriesFrozenCopyUnchanged(t *testing.T) {
	f := newSyncFixture(t)
	blob := annotationBlob(t, f)
	annID := uuid.NewString()
	original, copyID := uuid.NewString(), uuid.NewString()
	desired := map[string]any{"name": "original.pdf", "parentId": f.root, "pdfBlobId": blob, "annotations": []any{annotationRecord(annID, blob, "preserved")}}
	f.op("createPDF", original, 0, desired, nil)
	// Only this disposable test database is downgraded to reproduce the deployed v2 schema.
	annotationSQL(t, f.s, `ALTER TABLE annotations DROP CONSTRAINT annotations_pkey; ALTER TABLE annotations ADD CONSTRAINT annotations_pkey PRIMARY KEY(id); DELETE FROM app_migrations WHERE version='v3-document-annotation-identity';`)
	originalRows := annotationRows(t, f.s)
	cfg := f.s.Cfg
	lib, epoch, root := f.s.LibID, f.s.Epoch, f.s.RootID
	desired["name"] = "recovered.pdf"
	op, wire := annotationWire(t, f, "createPDF", copyID, 0, desired)
	f.decode(post(t, f.url+"/api/v1/sync/operations", wire, f.token, f.epoch, op), 500)
	if annotationRows(t, f.s) != originalRows || annotationScalar(t, f.s, `SELECT count(*) FROM objects WHERE id=$1`, copyID) != 0 {
		t.Fatal("failed old-schema request partially committed")
	}
	f.s.Close()
	for attempt := 0; attempt < 2; attempt++ {
		s, err := store.Connect(context.Background(), cfg)
		if err != nil {
			t.Fatal(err)
		}
		if s.LibID != lib || s.Epoch != epoch || s.RootID != root {
			t.Fatal("migration changed library identity")
		}
		if annotationRows(t, s) != originalRows {
			t.Fatal("migration changed original annotation")
		}
		if annotationScalar(t, s, `SELECT count(*) FROM app_migrations WHERE version='v3-document-annotation-identity'`) != 1 {
			t.Fatal("feature migration missing")
		}
		if attempt == 0 {
			s.Close()
			continue
		}
		f.s = s
		t.Cleanup(s.Close)
	}
	server := httptest.NewServer(api.New(cfg, f.s, &jobs.Runner{S: f.s}))
	t.Cleanup(server.Close)
	f.url = server.URL
	// Keep the old token, epoch, operation ID, request bytes and annotation ID.
	first := f.decode(post(t, f.url+"/api/v1/sync/operations", wire, f.token, f.epoch, op), 201)
	replay := f.decode(post(t, f.url+"/api/v1/sync/operations", wire, f.token, f.epoch, op), 201)
	if first["replayed"] != false || replay["replayed"] != true {
		t.Fatal("missing replay receipt")
	}
	delete(first, "replayed")
	delete(replay, "replayed")
	a, _ := json.Marshal(first)
	b, _ := json.Marshal(replay)
	if !bytes.Equal(a, b) {
		t.Fatal("fixed request replay differs")
	}
	if annotationScalar(t, f.s, `SELECT count(*) FROM annotations WHERE id=$1`, annID) != 2 || annotationScalar(t, f.s, `SELECT revision FROM objects WHERE id=$1`, copyID) != 1 {
		t.Fatal("copy retry did not commit once")
	}
}
