package api_test

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"tokenlibrary/internal/api"
	"tokenlibrary/internal/jobs"
	"tokenlibrary/internal/store"
	"tokenlibrary/internal/testdb"
)

type syncFixture struct {
	t                               *testing.T
	s                               *store.Store
	url, token, epoch, root, device string
}

func newSyncFixture(t *testing.T) *syncFixture {
	t.Helper()
	s, cfg := testdb.Start(t)
	t.Cleanup(s.Close)
	server := httptest.NewServer(api.New(cfg, s, &jobs.Runner{S: s}))
	t.Cleanup(server.Close)
	f := &syncFixture{t: t, s: s, url: server.URL, device: uuid.NewString()}
	raw := fmt.Sprintf(`{"username":"token","password":"local-dev-pass","deviceId":%q}`, f.device)
	res := post(t, server.URL+"/api/v1/auth/login", raw, "", "", "")
	data := f.decode(res, 200)
	f.token = data["sessionToken"].(string)
	f.epoch = data["epoch"].(string)
	f.root = data["rootId"].(string)
	return f
}
func (f *syncFixture) decode(res *http.Response, want int) map[string]any {
	f.t.Helper()
	raw := read(f.t, res)
	if res.StatusCode != want {
		f.t.Fatalf("want %d got %d: %s", want, res.StatusCode, raw)
	}
	var wrap struct {
		Data map[string]any `json:"data"`
	}
	if err := json.Unmarshal([]byte(raw), &wrap); err != nil {
		f.t.Fatal(err)
	}
	return wrap.Data
}
func (f *syncFixture) op(action, id string, base int64, desired map[string]any, resolution map[string]any) (map[string]any, string, string) {
	f.t.Helper()
	oid := uuid.NewString()
	env := map[string]any{"protocolVersion": 1, "operationId": oid, "epoch": f.epoch, "deviceId": f.device, "objectId": id, "action": action, "desiredSnapshot": desired}
	if base > 0 {
		env["base"] = map[string]any{"source": "revision", "revision": base}
	}
	if resolution != nil {
		env["resolution"] = resolution
	}
	raw, _ := json.Marshal(env)
	res := post(f.t, f.url+"/api/v1/sync/operations", string(raw), f.token, f.epoch, oid)
	want := 200
	if strings.HasPrefix(action, "create") {
		want = 201
	}
	return f.decode(res, want), oid, string(raw)
}
func (f *syncFixture) note(id, name, text string, metadata map[string]any) map[string]any {
	f.t.Helper()
	desired := map[string]any{"name": name, "parentId": f.root, "markdownSource": text}
	if metadata != nil {
		desired["metadata"] = metadata
	}
	data, _, _ := f.op("createMarkdown", id, 0, desired, nil)
	return data
}
func snapshotOf(t *testing.T, data map[string]any) map[string]any {
	t.Helper()
	s, ok := data["snapshot"].(map[string]any)
	if !ok {
		t.Fatalf("missing snapshot: %#v", data)
	}
	return s
}

func TestFrozenSnapshotAndIncrementalChanges(t *testing.T) {
	f := newSyncFixture(t)
	a, b := uuid.NewString(), uuid.NewString()
	f.note(a, "before.md", "before", map[string]any{"type": "book", "reading": map[string]any{"progress": 0.25}})
	page := f.decode(post(t, f.url+"/api/v1/sync/snapshots", `{"limit":1}`, f.token, f.epoch, ""), 200)
	snapshotID, atSeq := page["snapshotId"].(string), page["atSeq"].(string)
	f.op("updateDocument", a, 1, map[string]any{"markdownSource": "after"}, nil)
	f.note(b, "after.md", "new", nil)
	frozen := map[string]map[string]any{}
	for {
		for _, raw := range page["items"].([]any) {
			item := raw.(map[string]any)
			frozen[item["id"].(string)] = item["snapshot"].(map[string]any)
		}
		if !page["hasMore"].(bool) {
			break
		}
		page = f.decode(get(t, f.url+"/api/v1/sync/snapshots/"+snapshotID+"?limit=1&after="+page["nextCursor"].(string), f.token, f.epoch), 200)
	}
	if frozen[a]["markdownSource"] != "before" || frozen[b] != nil {
		t.Fatalf("snapshot changed after creation: %#v", frozen)
	}
	if frozen[a]["metadata"].(map[string]any)["type"] != "book" {
		t.Fatal("metadata missing")
	}
	cursor := atSeq
	latest := map[string]map[string]any{}
	for {
		data := f.decode(get(t, f.url+"/api/v1/sync/changes?limit=1&after="+cursor, f.token, f.epoch), 200)
		for _, raw := range data["changes"].([]any) {
			event := raw.(map[string]any)
			for _, raw := range event["objects"].([]any) {
				item := raw.(map[string]any)
				latest[item["id"].(string)] = item["snapshot"].(map[string]any)
			}
		}
		next := data["nextCursor"].(string)
		if next == cursor && data["hasMore"].(bool) {
			t.Fatal("cursor did not advance")
		}
		cursor = next
		if !data["hasMore"].(bool) {
			break
		}
	}
	if latest[a]["markdownSource"] != "after" || latest[b]["markdownSource"] != "new" {
		t.Fatalf("incremental changes incomplete: %#v", latest)
	}
	if _, err := f.s.Pool.Exec(context.Background(), `UPDATE sync_snapshots SET expires_at=now()-interval '1 second' WHERE id=$1`, snapshotID); err != nil {
		t.Fatal(err)
	}
	res := get(t, f.url+"/api/v1/sync/snapshots/"+snapshotID, f.token, f.epoch)
	defer res.Body.Close()
	if res.StatusCode != 410 {
		t.Fatalf("expired snapshot %d", res.StatusCode)
	}
}

func TestAuthorityReceiptMetadataMergeAndReplay(t *testing.T) {
	f := newSyncFixture(t)
	id := uuid.NewString()
	f.note(id, "merge.md", "alpha\n\nbeta\n", map[string]any{"type": "paper", "reading": map[string]any{"page": 1}, "author": "A"})
	f.op("updateDocument", id, 1, map[string]any{"markdownSource": "alpha\n\nbeta remote\n", "metadata": map[string]any{"type": "paper", "reading": map[string]any{"page": 2}, "author": "A"}}, nil)
	local := map[string]any{"markdownSource": "alpha local\n\nbeta\n", "metadata": map[string]any{"type": "paper", "reading": map[string]any{"page": 1}, "author": "B"}}
	data, oid, wire := f.op("updateDocument", id, 1, local, nil)
	snap := snapshotOf(t, data)
	if data["status"] != "committed" || !strings.Contains(snap["markdownSource"].(string), "beta remote") {
		t.Fatalf("missing authoritative merged body: %#v", data)
	}
	metadata := snap["metadata"].(map[string]any)
	if metadata["author"] != "B" || metadata["reading"].(map[string]any)["page"] != float64(2) {
		t.Fatalf("metadata changes lost: %#v", metadata)
	}
	// A legacy client omits metadata; the existing metadata remains unchanged.
	f.op("updateDocument", id, 3, map[string]any{"markdownSource": "alpha local\n\nbeta remote\n\nnewer"}, nil)
	replayed := f.decode(post(t, f.url+"/api/v1/sync/operations", wire, f.token, f.epoch, oid), 200)
	if replayed["replayed"] != true || snapshotOf(t, replayed)["revision"] != "3" {
		t.Fatalf("receipt was not frozen: %#v", replayed)
	}
	lookup := f.decode(get(t, f.url+"/api/v1/sync/operations/"+oid, f.token, f.epoch), 200)
	if snapshotOf(t, lookup)["revision"] != "3" {
		t.Fatal("receipt lookup lost snapshot")
	}
	current := snapshotOf(t, f.decode(get(t, f.url+"/api/v1/objects/"+id, f.token, f.epoch), 200))
	if current["metadata"].(map[string]any)["author"] != "B" {
		t.Fatal("legacy update erased metadata")
	}
}

func TestConflictMaterialsAndResolution(t *testing.T) {
	f := newSyncFixture(t)
	id := uuid.NewString()
	f.note(id, "conflict.md", "base", nil)
	f.op("updateDocument", id, 1, map[string]any{"markdownSource": "remote"}, nil)
	data, _, _ := f.op("updateDocument", id, 1, map[string]any{"markdownSource": "local"}, nil)
	if data["status"] != "conflict" {
		t.Fatalf("expected conflict: %#v", data)
	}
	cid := data["conflictIds"].([]any)[0].(string)
	for role, want := range map[string]string{"base": "base", "local": "local", "remote": "remote"} {
		material := f.decode(get(t, f.url+"/api/v1/conflicts/"+cid+"/materials/"+role, f.token, f.epoch), 200)
		if snapshotOf(t, material)["markdownSource"] != want {
			t.Fatalf("wrong %s material", role)
		}
	}
	listing := f.decode(get(t, f.url+"/api/v1/conflicts?objectId="+id, f.token, f.epoch), 200)
	if len(listing["conflicts"].([]any)) != 1 {
		t.Fatal("conflict listing")
	}
	resolved, _, _ := f.op("resolveConflicts", id, 0, map[string]any{"markdownSource": "resolved", "metadata": map[string]any{"type": "note"}}, map[string]any{"conflictIds": []string{cid}, "revision": "2"})
	if snapshotOf(t, resolved)["markdownSource"] != "resolved" || len(snapshotOf(t, resolved)["conflictIds"].([]any)) != 0 {
		t.Fatalf("resolution did not commit: %#v", resolved)
	}
}

func TestResumableBlobsAndReferenceIntegrity(t *testing.T) {
	f := newSyncFixture(t)
	blob := uuid.NewString()
	body := bytes.Repeat([]byte("a"), 1048576+7)
	sum := sha256.Sum256(body)
	initBody := fmt.Sprintf(`{"blobId":%q,"size":%d,"sha256":%q,"mime":"application/pdf"}`, blob, len(body), hex.EncodeToString(sum[:]))
	upload := f.decode(post(t, f.url+"/api/v1/uploads", initBody, f.token, f.epoch, ""), 200)
	uid := upload["uploadId"].(string)
	retry := f.decode(post(t, f.url+"/api/v1/uploads", initBody, f.token, f.epoch, ""), 200)
	if retry["uploadId"] != uid {
		t.Fatal("lost upload on repeated init")
	}
	for i, start := 0, 0; start < len(body); i, start = i+1, start+1048576 {
		end := start + 1048576
		if end > len(body) {
			end = len(body)
		}
		chunk := body[start:end]
		hash := sha256.Sum256(chunk)
		req, _ := http.NewRequest(http.MethodPut, f.url+"/api/v1/uploads/"+uid+"/chunks/"+strconv.Itoa(i), bytes.NewReader(chunk))
		req.Header.Set("Authorization", "Bearer "+f.token)
		req.Header.Set("X-Chunk-SHA256", hex.EncodeToString(hash[:]))
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		f.decode(res, 200)
	}
	progress := f.decode(get(t, f.url+"/api/v1/uploads/"+uid, f.token, f.epoch), 200)
	if len(progress["chunks"].([]any)) != 2 {
		t.Fatal("missing acknowledged chunks")
	}
	for i := 0; i < 2; i++ {
		f.decode(post(t, f.url+"/api/v1/uploads/"+uid+"/complete", "{}", f.token, f.epoch, ""), 200)
	}
	id := uuid.NewString()
	f.op("createPDF", id, 0, map[string]any{"name": "paper.pdf", "parentId": f.root, "pdfBlobId": blob, "annotations": []any{}, "metadata": map[string]any{"type": "paper"}}, nil)
	var refs int
	if err := f.s.Pool.QueryRow(context.Background(), `SELECT count(*) FROM blob_refs WHERE blob_id=$1`, blob).Scan(&refs); err != nil || refs < 2 {
		t.Fatalf("refs=%d err=%v", refs, err)
	}
	download := get(t, f.url+"/api/v1/blobs/"+blob, f.token, f.epoch)
	defer download.Body.Close()
	got, err := io.ReadAll(download.Body)
	if err != nil || !bytes.Equal(got, body) || download.Header.Get("X-Content-SHA256") != hex.EncodeToString(sum[:]) {
		t.Fatal("download bytes/hash mismatch")
	}
	// Every blob-writing route respects the backup gate.
	f.s.Writes.Lock()
	blocked := post(t, f.url+"/api/v1/uploads/"+uid+"/complete", "{}", f.token, f.epoch, "")
	f.s.Writes.Unlock()
	defer blocked.Body.Close()
	if blocked.StatusCode != 503 {
		t.Fatal("backup write gate bypassed")
	}
}

func TestImportIdempotencyAndSubtreeTrashRestore(t *testing.T) {
	f := newSyncFixture(t)
	op := uuid.NewString()
	importWithKey := func(content string) *http.Response {
		var buf bytes.Buffer
		writer := multipart.NewWriter(&buf)
		part, err := writer.CreateFormFile("file", "same.md")
		if err != nil {
			t.Fatal(err)
		}
		_, _ = io.WriteString(part, content)
		_ = writer.Close()
		req, _ := http.NewRequest(http.MethodPost, f.url+"/api/v1/imports", &buf)
		req.Header.Set("Content-Type", writer.FormDataContentType())
		req.Header.Set("Authorization", "Bearer local-upload-token-32-bytes-min!!")
		req.Header.Set("Idempotency-Key", op)
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		return res
	}
	first := f.decode(importWithKey("# content"), 201)
	second := f.decode(importWithKey("# content"), 201)
	if first["objectId"] != second["objectId"] {
		t.Fatal("import duplicated")
	}
	bad := importWithKey("different")
	defer bad.Body.Close()
	if bad.StatusCode != 409 {
		t.Fatalf("changed import should fail: %d", bad.StatusCode)
	}
	folder, child := uuid.NewString(), uuid.NewString()
	f.op("createFolder", folder, 0, map[string]any{"name": "folder", "parentId": f.root}, nil)
	f.op("createMarkdown", child, 0, map[string]any{"name": "child.md", "parentId": folder, "markdownSource": "child"}, nil)
	trash, _, _ := f.op("trash", folder, 0, map[string]any{}, nil)
	if snapshotOf(t, trash)["state"] != "trashed" {
		t.Fatal("missing trash receipt")
	}
	c := snapshotOf(t, f.decode(get(t, f.url+"/api/v1/objects/"+child, f.token, f.epoch), 200))
	if c["state"] != "trashed" || c["parentId"] != folder {
		t.Fatal("subtree trash lost parent")
	}
	if c["trashBatchId"] == nil || c["trashBatchId"] != snapshotOf(t, trash)["trashBatchId"] {
		t.Fatal("recursive trash batch absent from public snapshot")
	}
	f.op("restore", folder, 0, map[string]any{}, nil)
	c = snapshotOf(t, f.decode(get(t, f.url+"/api/v1/objects/"+child, f.token, f.epoch), 200))
	if c["state"] != "active" || c["revision"] != "3" || c["trashBatchId"] != nil {
		t.Fatalf("subtree not restored: %#v", c)
	}
}

func TestSubtreeRestoreHonorsDeletionBatchAndSelectedSubtree(t *testing.T) {
	f := newSyncFixture(t)
	outer, nested, leaf, prior := uuid.NewString(), uuid.NewString(), uuid.NewString(), uuid.NewString()
	f.op("createFolder", outer, 0, map[string]any{"name": "outer", "parentId": f.root}, nil)
	f.op("createFolder", nested, 0, map[string]any{"name": "nested", "parentId": outer}, nil)
	f.op("createMarkdown", leaf, 0, map[string]any{"name": "leaf.md", "parentId": nested}, nil)
	f.op("createMarkdown", prior, 0, map[string]any{"name": "prior.md", "parentId": nested}, nil)
	f.op("trash", prior, 0, map[string]any{}, nil)
	f.op("trash", outer, 0, map[string]any{}, nil)
	f.op("restore", nested, 0, map[string]any{}, nil)
	for id, state := range map[string]string{outer: "trashed", prior: "trashed", nested: "active", leaf: "active"} {
		got := snapshotOf(t, f.decode(get(t, f.url+"/api/v1/objects/"+id, f.token, f.epoch), 200))
		if got["state"] != state {
			t.Fatalf("%s state=%v want %s", id, got["state"], state)
		}
		if id == nested && got["parentId"] != f.root {
			t.Fatal("nested restore should fall back to active root")
		}
	}
	f.op("restore", outer, 0, map[string]any{}, nil)
	priorSnapshot := snapshotOf(t, f.decode(get(t, f.url+"/api/v1/objects/"+prior, f.token, f.epoch), 200))
	if priorSnapshot["state"] != "trashed" {
		t.Fatal("independently deleted child restored")
	}
}

func TestOperationValidationAndExpiredHistory(t *testing.T) {
	f := newSyncFixture(t)
	a, b, folder := uuid.NewString(), uuid.NewString(), uuid.NewString()
	_, firstOp, firstRequest := f.op("createMarkdown", a, 0, map[string]any{"name": "a.md", "markdownSource": "a", "parentId": f.root}, nil)
	f.note(b, "b.md", "b", nil)
	f.op("createFolder", folder, 0, map[string]any{"name": "destination", "parentId": f.root}, nil)
	for _, tc := range []struct {
		desired map[string]any
		want    int
	}{
		{map[string]any{"name": "../escape.md"}, 422},
		{map[string]any{"name": "b.md"}, 409},
		{map[string]any{"parentId": "bad-id"}, 422},
	} {
		op := uuid.NewString()
		raw, _ := json.Marshal(map[string]any{"protocolVersion": 1, "operationId": op, "epoch": f.epoch, "deviceId": f.device, "objectId": a, "action": "updateDocument", "base": map[string]any{"source": "revision", "revision": 1}, "desiredSnapshot": tc.desired})
		f.decode(post(t, f.url+"/api/v1/sync/operations", string(raw), f.token, f.epoch, op), tc.want)
	}
	moved, _, _ := f.op("updateDocument", a, 1, map[string]any{"parentId": folder}, nil)
	if snapshotOf(t, moved)["parentId"] != folder {
		t.Fatal("updateDocument dropped move intent")
	}
	f.op("trash", a, 0, map[string]any{}, nil)
	if _, err := f.s.Pool.Exec(context.Background(), `UPDATE objects SET purge_at=now()-interval '1 hour' WHERE id=$1`, a); err != nil {
		t.Fatal(err)
	}
	f.decode(get(t, f.url+"/api/v1/objects/"+a, f.token, f.epoch), 410)
	f.decode(get(t, f.url+"/api/v1/objects/"+a+"/revisions/1", f.token, f.epoch), 410)
	f.decode(get(t, f.url+"/api/v1/sync/operations/"+firstOp, f.token, f.epoch), 410)
	f.decode(post(t, f.url+"/api/v1/sync/operations", firstRequest, f.token, f.epoch, firstOp), 410)
}

func TestOnlyOneServerOwnsDatabase(t *testing.T) {
	f := newSyncFixture(t)
	other, err := store.Connect(context.Background(), f.s.Cfg)
	if err == nil {
		other.Close()
		t.Fatal("second server bypassed maintenance singleton")
	}
	if !strings.Contains(err.Error(), "already owns") {
		t.Fatalf("unexpected singleton error: %v", err)
	}
}

func TestReceiptBaseUsesCommittedRevision(t *testing.T) {
	f := newSyncFixture(t)
	id := uuid.NewString()
	created, receiptID, _ := f.op("createMarkdown", id, 0, map[string]any{"name": "receipt.md", "parentId": f.root, "markdownSource": "alpha\n\nbeta\n"}, nil)
	f.op("updateDocument", id, 1, map[string]any{"markdownSource": "alpha\n\nremote beta\n"}, nil)
	op := uuid.NewString()
	raw, _ := json.Marshal(map[string]any{"protocolVersion": 1, "operationId": op, "epoch": f.epoch, "deviceId": f.device, "objectId": id, "action": "updateDocument", "base": map[string]any{"source": "receipt", "operationId": receiptID, "hash": created["receipt"].(map[string]any)["inputHash"], "snapshotBytes": "{\"markdownSource\":\"untrusted\"}"}, "desiredSnapshot": map[string]any{"markdownSource": "local alpha\n\nbeta\n"}})
	data := f.decode(post(t, f.url+"/api/v1/sync/operations", string(raw), f.token, f.epoch, ""), 200)
	if data["operationId"] != op || data["receipt"].(map[string]any)["operationId"] != op {
		t.Fatal("body operationId lost without optional header")
	}
	text := snapshotOf(t, data)["markdownSource"].(string)
	if data["status"] != "committed" || !strings.Contains(text, "local alpha") || !strings.Contains(text, "remote beta") {
		t.Fatalf("receipt base lost concurrent edit: %#v", data)
	}
}

func TestSnapshotAndChangesAt1000Documents(t *testing.T) {
	f := newSyncFixture(t)
	ids := make([]string, 1000)
	body := strings.Repeat("scale fixture paragraph. ", 43)
	started := time.Now()
	for i := range ids {
		ids[i] = uuid.NewString()
		f.note(ids[i], fmt.Sprintf("material-%04d.md", i), body, map[string]any{"type": []string{"book", "paper", "note"}[i%3], "title": fmt.Sprintf("Material %d", i), "reading": map[string]any{"progress": 0.25}})
	}
	createDuration := time.Since(started)
	started = time.Now()
	page := f.decode(post(t, f.url+"/api/v1/sync/snapshots", `{"limit":100}`, f.token, f.epoch, ""), 200)
	freezeDuration := time.Since(started)
	snapshotID, atSeq := page["snapshotId"].(string), page["atSeq"].(string)
	started = time.Now()
	for _, id := range ids[:100] {
		f.op("updateDocument", id, 1, map[string]any{"markdownSource": "updated\n\n" + body}, nil)
	}
	updateDuration := time.Since(started)
	started = time.Now()
	seen := map[string]bool{}
	pages := 0
	for {
		pages++
		for _, raw := range page["items"].([]any) {
			item := raw.(map[string]any)
			id := item["id"].(string)
			if seen[id] {
				t.Fatalf("duplicate snapshot item %s", id)
			}
			seen[id] = true
			snapshot := item["snapshot"].(map[string]any)
			if id != f.root && (snapshot["markdownSource"] != body || snapshot["revision"] != "1") {
				t.Fatal("1000-item frozen snapshot changed during pagination")
			}
		}
		if !page["hasMore"].(bool) {
			break
		}
		page = f.decode(get(t, f.url+"/api/v1/sync/snapshots/"+snapshotID+"?limit=100&after="+page["nextCursor"].(string), f.token, f.epoch), 200)
	}
	pageDuration := time.Since(started)
	if len(seen) != 1001 || pages != 11 {
		t.Fatalf("snapshot count=%d pages=%d", len(seen), pages)
	}
	started = time.Now()
	after, changePages := atSeq, 0
	changed := map[string]bool{}
	for {
		data := f.decode(get(t, f.url+"/api/v1/sync/changes?after="+after+"&limit=25", f.token, f.epoch), 200)
		changePages++
		for _, raw := range data["changes"].([]any) {
			for _, object := range raw.(map[string]any)["objects"].([]any) {
				item := object.(map[string]any)
				id := item["id"].(string)
				if changed[id] {
					t.Fatal("duplicate incremental object")
				}
				changed[id] = true
				if item["snapshot"].(map[string]any)["revision"] != "2" {
					t.Fatal("incremental revision mismatch")
				}
			}
		}
		after = data["nextCursor"].(string)
		if !data["hasMore"].(bool) {
			break
		}
	}
	changeDuration := time.Since(started)
	if len(changed) != 100 || changePages != 4 || after != "1100" {
		t.Fatalf("changes count=%d pages=%d cursor=%s", len(changed), changePages, after)
	}
	t.Logf("SCALE documents=1000 markdownBytesEach=%d metadataTypes=book,paper,note create=%s freezeFirstPage=%s remainingSnapshotPages=%s snapshotItems=1001 snapshotPages=11 update100=%s changes100=%s changePages=4 finalCursor=%s", len(body), createDuration, freezeDuration, pageDuration, updateDuration, changeDuration, after)
}
