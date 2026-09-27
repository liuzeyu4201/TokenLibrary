package api_test

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/gorilla/websocket"

	"tokenlibrary/internal/api"
	"tokenlibrary/internal/authn"
	"tokenlibrary/internal/jobs"
	"tokenlibrary/internal/store"
	"tokenlibrary/internal/testdb"
)

func TestSimpleMarkdownUpdate(t *testing.T) {
	st, cfg := testdb.Start(t)
	defer st.Close()
	r := api.New(cfg, st, &jobs.Runner{S: st})
	ts := httptest.NewServer(r)
	defer ts.Close()
	dev := uuid.NewString()
	res := post(t, ts.URL+"/api/v1/auth/login", fmt.Sprintf(`{"username":"token","password":"local-dev-pass","deviceId":%q,"deviceName":"t","platform":"mac"}`, dev), "", "", "")
	raw := read(t, res)
	var login struct {
		Data struct {
			SessionToken string `json:"sessionToken"`
			Epoch        string `json:"epoch"`
			RootID       string `json:"rootId"`
			DeviceID     string `json:"deviceId"`
		} `json:"data"`
	}
	mustJSON(t, raw, &login)
	mdID := uuid.NewString()
	oid := uuid.NewString()
	payload := fmt.Sprintf(`{"protocolVersion":1,"operationId":%q,"epoch":%q,"deviceId":%q,"objectId":%q,"action":"createMarkdown","desiredSnapshot":{"name":"a.md","parentId":%q,"markdownSource":"one"}}`,
		oid, login.Data.Epoch, login.Data.DeviceID, mdID, login.Data.RootID)
	res = post(t, ts.URL+"/api/v1/sync/operations", payload, login.Data.SessionToken, login.Data.Epoch, oid)
	if res.StatusCode != 201 {
		t.Fatalf("create %d %s", res.StatusCode, read(t, res))
	}
	_ = read(t, res)
	oid = uuid.NewString()
	payload = fmt.Sprintf(`{"protocolVersion":1,"operationId":%q,"epoch":%q,"deviceId":%q,"objectId":%q,"action":"updateDocument","base":{"source":"revision","revision":1},"desiredSnapshot":{"name":"a.md","parentId":%q,"markdownSource":"two"}}`,
		oid, login.Data.Epoch, login.Data.DeviceID, mdID, login.Data.RootID)
	res = post(t, ts.URL+"/api/v1/sync/operations", payload, login.Data.SessionToken, login.Data.Epoch, oid)
	out := read(t, res)
	if res.StatusCode != 200 {
		t.Fatalf("update %d %s", res.StatusCode, out)
	}
}

func TestMermaidEdit(t *testing.T) {
	st, cfg := testdb.Start(t)
	defer st.Close()
	r := api.New(cfg, st, &jobs.Runner{S: st})
	ts := httptest.NewServer(r)
	defer ts.Close()
	dev := uuid.NewString()
	res := post(t, ts.URL+"/api/v1/auth/login", fmt.Sprintf(`{"username":"token","password":"local-dev-pass","deviceId":%q,"deviceName":"t","platform":"mac"}`, dev), "", "", "")
	var login struct {
		Data struct {
			SessionToken, Epoch, RootID, DeviceID string
		} `json:"data"`
	}
	mustJSON(t, read(t, res), &login)
	src := "# 三方合并\n\n```mermaid\ngraph TD\n  A-->B\n```\n\n行内 $n+1$\n\n$$a+b$$\n"
	mdID := uuid.NewString()
	oid := uuid.NewString()
	payload := fmt.Sprintf(`{"protocolVersion":1,"operationId":%q,"epoch":%q,"deviceId":%q,"objectId":%q,"action":"createMarkdown","desiredSnapshot":{"name":"m.md","parentId":%q,"markdownSource":%s}}`,
		oid, login.Data.Epoch, login.Data.DeviceID, mdID, login.Data.RootID, jsonStr(src))
	res = post(t, ts.URL+"/api/v1/sync/operations", payload, login.Data.SessionToken, login.Data.Epoch, oid)
	if res.StatusCode != 201 {
		t.Fatalf("create %d %s", res.StatusCode, read(t, res))
	}
	_ = read(t, res)
	left := strings.Replace(src, "A-->B", "A-->L", 1)
	oid = uuid.NewString()
	payload = fmt.Sprintf(`{"protocolVersion":1,"operationId":%q,"epoch":%q,"deviceId":%q,"objectId":%q,"action":"updateDocument","base":{"source":"revision","revision":1},"desiredSnapshot":{"name":"m.md","parentId":%q,"markdownSource":%s}}`,
		oid, login.Data.Epoch, login.Data.DeviceID, mdID, login.Data.RootID, jsonStr(left))
	res = post(t, ts.URL+"/api/v1/sync/operations", payload, login.Data.SessionToken, login.Data.Epoch, oid)
	out := read(t, res)
	if res.StatusCode != 200 {
		t.Fatalf("update %d %s", res.StatusCode, out)
	}
}

func TestServerFlows(t *testing.T) {
	st, cfg := testdb.Start(t)
	defer st.Close()
	r := api.New(cfg, st, &jobs.Runner{S: st})
	ts := httptest.NewServer(r)
	defer ts.Close()

	// health
	res := get(t, ts.URL+"/health/ready", "", "")
	if res.StatusCode != 200 {
		t.Fatalf("ready %d", res.StatusCode)
	}
	body := read(t, res)
	if !strings.Contains(body, `"ready":true`) {
		t.Fatalf("ready body %s", body)
	}

	// login
	dev := uuid.NewString()
	loginBody := fmt.Sprintf(`{"username":"token","password":"local-dev-pass","deviceId":%q,"deviceName":"test","platform":"mac"}`, dev)
	res = post(t, ts.URL+"/api/v1/auth/login", loginBody, "", "", "")
	if res.StatusCode != 200 {
		t.Fatalf("login %d %s", res.StatusCode, read(t, res))
	}
	var login struct {
		Data struct {
			SessionToken string `json:"sessionToken"`
			LibraryID    string `json:"libraryId"`
			Epoch        string `json:"epoch"`
			RootID       string `json:"rootId"`
			DeviceID     string `json:"deviceId"`
		} `json:"data"`
	}
	mustJSON(t, read(t, res), &login)
	tok, epoch, root, device := login.Data.SessionToken, login.Data.Epoch, login.Data.RootID, login.Data.DeviceID
	if tok == "" || epoch == "" {
		t.Fatal("empty login")
	}

	// create folder + markdown with mermaid/latex
	folderID := uuid.NewString()
	op := func(action, obj, desired string) (int, string) {
		oid := uuid.NewString()
		payload := fmt.Sprintf(`{"protocolVersion":1,"operationId":%q,"epoch":%q,"deviceId":%q,"objectId":%q,"action":%q,"base":null,"desiredSnapshot":%s}`,
			oid, epoch, device, obj, action, desired)
		res := post(t, ts.URL+"/api/v1/sync/operations", payload, tok, epoch, oid)
		return res.StatusCode, read(t, res)
	}
	code, out := op("createFolder", folderID, fmt.Sprintf(`{"name":"研究","parentId":%q}`, root))
	if code != 201 {
		t.Fatalf("folder %d %s", code, out)
	}
	mdID := uuid.NewString()
	src := "# 三方合并\n\n```mermaid\ngraph TD\n  A-->B\n```\n\n行内 $n+1$\n\n$$a+b$$\n"
	desired := fmt.Sprintf(`{"name":"三方合并规则.md","parentId":%q,"markdownSource":%s}`, folderID, jsonStr(src))
	code, out = op("createMarkdown", mdID, desired)
	if code != 201 {
		t.Fatalf("md %d %s", code, out)
	}

	// second device compatible merge
	dev2 := uuid.NewString()
	res = post(t, ts.URL+"/api/v1/auth/login", fmt.Sprintf(`{"username":"token","password":"local-dev-pass","deviceId":%q,"deviceName":"phone","platform":"ios"}`, dev2), "", "", "")
	var login2 struct {
		Data struct {
			SessionToken string `json:"sessionToken"`
			DeviceID     string `json:"deviceId"`
		} `json:"data"`
	}
	mustJSON(t, read(t, res), &login2)

	getObj := func() map[string]any {
		res := get(t, ts.URL+"/api/v1/objects/"+mdID, tok, epoch)
		raw := read(t, res)
		var wrap struct {
			Data struct {
				Snapshot json.RawMessage `json:"snapshot"`
			} `json:"data"`
		}
		mustJSON(t, raw, &wrap)
		var m map[string]any
		_ = json.Unmarshal(wrap.Data.Snapshot, &m)
		return m
	}
	cur := getObj()
	rev := fmt.Sprint(cur["revision"])
	localSrc := src + "\nphone paragraph\n"
	remoteSrc := src + "\nmac paragraph\n"
	// phone update
	oid := uuid.NewString()
	payload := fmt.Sprintf(`{"protocolVersion":1,"operationId":%q,"epoch":%q,"deviceId":%q,"objectId":%q,"action":"updateDocument","base":{"source":"revision","revision":%s},"desiredSnapshot":{"name":"三方合并规则.md","parentId":%q,"markdownSource":%s}}`,
		oid, epoch, login2.Data.DeviceID, mdID, rev, folderID, jsonStr(localSrc))
	res = post(t, ts.URL+"/api/v1/sync/operations", payload, login2.Data.SessionToken, epoch, oid)
	if res.StatusCode != 200 {
		t.Fatalf("phone update %d %s", res.StatusCode, read(t, res))
	}
	// mac update based on original rev
	oid = uuid.NewString()
	payload = fmt.Sprintf(`{"protocolVersion":1,"operationId":%q,"epoch":%q,"deviceId":%q,"objectId":%q,"action":"updateDocument","base":{"source":"revision","revision":%s},"desiredSnapshot":{"name":"三方合并规则.md","parentId":%q,"markdownSource":%s}}`,
		oid, epoch, device, mdID, rev, folderID, jsonStr(remoteSrc))
	res = post(t, ts.URL+"/api/v1/sync/operations", payload, tok, epoch, oid)
	out = read(t, res)
	if res.StatusCode != 200 {
		t.Fatalf("mac update %d %s", res.StatusCode, out)
	}
	merged := getObj()
	ms, _ := merged["markdownSource"].(string)
	t.Logf("merge status body=%s source=%q", out, ms)
	if strings.Contains(out, `"status":"conflict"`) {
		t.Fatalf("compatible paragraph adds must auto-merge, got conflict: %s", out)
	}
	if !strings.Contains(ms, "phone paragraph") || !strings.Contains(ms, "mac paragraph") {
		t.Fatalf("merged markdown must keep both sides: %s", ms)
	}

	// mermaid conflict stays unsynced
	cur = getObj()
	rev = fmt.Sprint(cur["revision"])
	baseMD, _ := cur["markdownSource"].(string)
	left := strings.Replace(baseMD, "A-->B", "A-->L", 1)
	right := strings.Replace(baseMD, "A-->B", "A-->R", 1)
	if left == baseMD {
		left = baseMD + "\n```mermaid\ngraph TD\n  X-->L\n```\n"
		right = baseMD + "\n```mermaid\ngraph TD\n  X-->R\n```\n"
	}
	oid = uuid.NewString()
	payload = fmt.Sprintf(`{"protocolVersion":1,"operationId":%q,"epoch":%q,"deviceId":%q,"objectId":%q,"action":"updateDocument","base":{"source":"revision","revision":%s},"desiredSnapshot":{"name":"三方合并规则.md","parentId":%q,"markdownSource":%s}}`,
		oid, epoch, login2.Data.DeviceID, mdID, rev, folderID, jsonStr(left))
	res = post(t, ts.URL+"/api/v1/sync/operations", payload, login2.Data.SessionToken, epoch, oid)
	leftOut := read(t, res)
	if res.StatusCode >= 400 {
		t.Fatalf("mermaid left update %d %s", res.StatusCode, leftOut)
	}
	oid = uuid.NewString()
	payload = fmt.Sprintf(`{"protocolVersion":1,"operationId":%q,"epoch":%q,"deviceId":%q,"objectId":%q,"action":"updateDocument","base":{"source":"revision","revision":%s},"desiredSnapshot":{"name":"三方合并规则.md","parentId":%q,"markdownSource":%s}}`,
		oid, epoch, device, mdID, rev, folderID, jsonStr(right))
	res = post(t, ts.URL+"/api/v1/sync/operations", payload, tok, epoch, oid)
	out = read(t, res)
	if !strings.Contains(out, `"status":"conflict"`) && !strings.Contains(out, "conflict") {
		t.Fatalf("expected conflict: %s", out)
	}

	// trash restore
	trID := uuid.NewString()
	oid = uuid.NewString()
	payload = fmt.Sprintf(`{"protocolVersion":1,"operationId":%q,"epoch":%q,"deviceId":%q,"objectId":%q,"action":"createMarkdown","desiredSnapshot":{"name":"tmp.md","parentId":%q,"markdownSource":"x"}}`,
		oid, epoch, device, trID, folderID)
	res = post(t, ts.URL+"/api/v1/sync/operations", payload, tok, epoch, oid)
	if res.StatusCode != 201 {
		t.Fatalf("tmp md %s", read(t, res))
	}
	oid = uuid.NewString()
	payload = fmt.Sprintf(`{"protocolVersion":1,"operationId":%q,"epoch":%q,"deviceId":%q,"objectId":%q,"action":"trash","desiredSnapshot":{}}`,
		oid, epoch, device, trID)
	res = post(t, ts.URL+"/api/v1/sync/operations", payload, tok, epoch, oid)
	if res.StatusCode != 200 {
		t.Fatalf("trash %s", read(t, res))
	}
	oid = uuid.NewString()
	payload = fmt.Sprintf(`{"protocolVersion":1,"operationId":%q,"epoch":%q,"deviceId":%q,"objectId":%q,"action":"restore","desiredSnapshot":{"parentId":%q}}`,
		oid, epoch, device, trID, folderID)
	res = post(t, ts.URL+"/api/v1/sync/operations", payload, tok, epoch, oid)
	if res.StatusCode != 200 {
		t.Fatalf("restore %s", read(t, res))
	}

	// idempotent retry
	oid = uuid.NewString()
	dup := uuid.NewString()
	payload = fmt.Sprintf(`{"protocolVersion":1,"operationId":%q,"epoch":%q,"deviceId":%q,"objectId":%q,"action":"createMarkdown","desiredSnapshot":{"name":"once.md","parentId":%q,"markdownSource":"a"}}`,
		oid, epoch, device, dup, folderID)
	res = post(t, ts.URL+"/api/v1/sync/operations", payload, tok, epoch, oid)
	if res.StatusCode != 201 {
		t.Fatalf("first %s", read(t, res))
	}
	res = post(t, ts.URL+"/api/v1/sync/operations", payload, tok, epoch, oid)
	out = read(t, res)
	if res.StatusCode != 201 && res.StatusCode != 200 {
		t.Fatalf("replay %d %s", res.StatusCode, out)
	}
	if !strings.Contains(out, `"replayed":true`) {
		t.Fatalf("expected replayed: %s", out)
	}

	// curl import + suffix + bad token
	importFile(t, ts.URL, "local-upload-token-32-bytes-min!!", epoch, "报告.md", "# one\n")
	b2 := importFile(t, ts.URL, "local-upload-token-32-bytes-min!!", epoch, "报告.md", "# two\n")
	if !strings.Contains(b2, "报告_1.md") && !strings.Contains(b2, "_1") {
		t.Fatalf("expected suffix: %s", b2)
	}
	res = importRaw(t, ts.URL, "bad-token", epoch, "x.md", "x")
	if res.StatusCode != 401 {
		t.Fatalf("bad token %d", res.StatusCode)
	}
	// upload token cannot read objects
	res = get(t, ts.URL+"/api/v1/objects/"+mdID, "local-upload-token-32-bytes-min!!", epoch)
	if res.StatusCode != 401 {
		t.Fatalf("upload token must not read objects, got %d %s", res.StatusCode, read(t, res))
	}

	// real backup artifact
	useContainerBackupTools(t, cfg.DatabaseURL)
	res = post(t, ts.URL+"/api/v1/test/backup/run", "{}", tok, epoch, "")
	bout := read(t, res)
	if res.StatusCode != 200 {
		t.Fatalf("backup run %d %s", res.StatusCode, bout)
	}
	if !strings.Contains(bout, `"state":"success"`) {
		t.Fatalf("backup not success: %s", bout)
	}

	// backup pause
	res = post(t, ts.URL+"/api/v1/test/backup/begin", "{}", tok, epoch, "")
	if res.StatusCode != 200 {
		t.Fatalf("backup begin %s", read(t, res))
	}
	oid = uuid.NewString()
	payload = fmt.Sprintf(`{"protocolVersion":1,"operationId":%q,"epoch":%q,"deviceId":%q,"objectId":%q,"action":"createMarkdown","desiredSnapshot":{"name":"paused.md","parentId":%q,"markdownSource":"z"}}`,
		oid, epoch, device, uuid.NewString(), folderID)
	res = post(t, ts.URL+"/api/v1/sync/operations", payload, tok, epoch, oid)
	if res.StatusCode != 503 {
		t.Fatalf("want 503 during backup, got %d %s", res.StatusCode, read(t, res))
	}
	res = post(t, ts.URL+"/api/v1/test/backup/end", "{}", tok, epoch, "")
	if res.StatusCode != 200 {
		t.Fatalf("backup end %s", read(t, res))
	}

	// logout
	res = post(t, ts.URL+"/api/v1/auth/logout", "{}", tok, epoch, "")
	if res.StatusCode != 200 {
		t.Fatalf("logout %s", read(t, res))
	}
}

// The fixture runs PostgreSQL 17 in Docker. Use that container's matching tools,
// independent of the developer machine's PostgreSQL client major version.
func useContainerBackupTools(t *testing.T, databaseURL string) {
	t.Helper()
	u, err := url.Parse(databaseURL)
	if err != nil || u.Port() == "" {
		t.Fatal("invalid isolated PostgreSQL fixture URL")
	}
	container := "tlpg-" + u.Port()
	dir := t.TempDir()
	dump := fmt.Sprintf(`#!/bin/sh
set -eu
if [ "$1" = "--version" ]; then exec docker exec %s pg_dump --version; fi
output=''
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--file" ]; then shift; output="$1"; fi
  shift
done
[ -n "$output" ] || exit 2
exec docker exec %s pg_dump --format=custom --no-owner --no-acl -U tl -d tl > "$output"
`, container, container)
	restore := fmt.Sprintf(`#!/bin/sh
set -eu
if [ "$1" = "--version" ]; then exec docker exec %s pg_restore --version; fi
[ "$1" = "--list" ] || exit 2
exec docker exec -i %s pg_restore --list < "$2"
`, container, container)
	for name, script := range map[string]string{"pg_dump": dump, "pg_restore": restore} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(script), 0700); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
}

func post(t *testing.T, url, body, tok, epoch, idem string) *http.Response {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPost, url, strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	if tok != "" {
		req.Header.Set("Authorization", "Bearer "+tok)
	}
	if epoch != "" {
		req.Header.Set("X-Library-Epoch", epoch)
	}
	if idem != "" {
		req.Header.Set("Idempotency-Key", idem)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	return res
}

func get(t *testing.T, url, tok, epoch string) *http.Response {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, url, nil)
	if tok != "" {
		req.Header.Set("Authorization", "Bearer "+tok)
	}
	if epoch != "" {
		req.Header.Set("X-Library-Epoch", epoch)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	return res
}

func read(t *testing.T, res *http.Response) string {
	t.Helper()
	b, err := io.ReadAll(res.Body)
	res.Body.Close()
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func mustJSON(t *testing.T, s string, v any) {
	t.Helper()
	if err := json.Unmarshal([]byte(s), v); err != nil {
		t.Fatalf("json %v %s", err, s)
	}
}

func jsonStr(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}

func importFile(t *testing.T, base, tok, epoch, name, content string) string {
	t.Helper()
	res := importRaw(t, base, tok, epoch, name, content)
	b := read(t, res)
	if res.StatusCode != 201 && res.StatusCode != 200 {
		t.Fatalf("import %d %s", res.StatusCode, b)
	}
	return b
}

func TestServerContractGaps(t *testing.T) {
	st, cfg := testdb.Start(t)
	defer st.Close()
	ts := httptest.NewServer(api.New(cfg, st, &jobs.Runner{S: st}))
	defer ts.Close()
	dev := uuid.NewString()
	loginBody := fmt.Sprintf(`{"username":"token","password":"wrong-password","deviceId":%q,"deviceName":"t","platform":"mac"}`, dev)
	for i := 0; i < authn.LoginFailureLimit; i++ {
		res := post(t, ts.URL+"/api/v1/auth/login", loginBody, "", "", "")
		if res.StatusCode != 401 {
			t.Fatalf("failure %d: %d %s", i+1, res.StatusCode, read(t, res))
		}
		_ = read(t, res)
	}
	res := post(t, ts.URL+"/api/v1/auth/login", loginBody, "", "", "")
	limited := read(t, res)
	if res.StatusCode != 429 || !strings.Contains(limited, "RATE_LIMITED") {
		t.Fatalf("excess login %d %s", res.StatusCode, limited)
	}

	ok := post(t, ts.URL+"/api/v1/auth/login", fmt.Sprintf(`{"username":"token","password":"local-dev-pass","deviceId":%q,"deviceName":"t","platform":"other"}`, uuid.NewString()), "", "", "")
	if ok.StatusCode != 429 {
		t.Fatalf("limited address still accepted a password: %d %s", ok.StatusCode, read(t, ok))
	}
	_ = read(t, ok)

	other := post(t, ts.URL+"/api/v1/auth/login", fmt.Sprintf(`{"username":"token","password":"local-dev-pass","deviceId":%q,"deviceName":"t","platform":"mac"}`, uuid.NewString()), "", "", "")
	// httptest shares one client address, so the successful login is also limited.
	if other.StatusCode != 429 {
		t.Fatalf("same address: %d %s", other.StatusCode, read(t, other))
	}
	_ = read(t, other)

	fresh, freshCfg := testdb.Start(t)
	defer fresh.Close()
	freshTS := httptest.NewServer(api.New(freshCfg, fresh, &jobs.Runner{S: fresh}))
	defer freshTS.Close()
	session := post(t, freshTS.URL+"/api/v1/auth/login", fmt.Sprintf(`{"username":"token","password":"local-dev-pass","deviceId":%q,"deviceName":"t","platform":"mac"}`, uuid.NewString()), "", "", "")
	var login struct {
		Data struct{ SessionToken, Epoch string } `json:"data"`
	}
	mustJSON(t, read(t, session), &login)

	original := []byte("%PDF-1.4\n1 0 obj << /Type /Catalog >> endobj\ntrailer << /Root 1 0 R /Encrypt 2 0 R >>\n2 0 obj << /Filter /Standard >> endobj\n%%EOF\n")
	sum := sha256.Sum256(original)
	blobID := uuid.New()
	if _, err := fresh.Pool.Exec(t.Context(), `INSERT INTO blobs(id,library_id,sha256,size,mime,state,password_required) VALUES($1,$2,$3,$4,'application/pdf','unavailable',false)`, blobID, fresh.LibID, sum[:], len(original)); err != nil {
		t.Fatal(err)
	}
	bad := postBytes(t, freshTS.URL+"/api/v1/blobs/"+blobID.String()+"/repair", []byte("different-bytes"), login.Data.SessionToken, login.Data.Epoch)
	if bad.StatusCode != 422 {
		t.Fatalf("mismatched repair %d %s", bad.StatusCode, read(t, bad))
	}
	_ = read(t, bad)
	var state string
	if err := fresh.Pool.QueryRow(t.Context(), `SELECT state FROM blobs WHERE id=$1`, blobID).Scan(&state); err != nil || state != "unavailable" {
		t.Fatalf("mismatch changed state %s %v", state, err)
	}
	good := postBytes(t, freshTS.URL+"/api/v1/blobs/"+blobID.String()+"/repair", original, login.Data.SessionToken, login.Data.Epoch)
	if good.StatusCode != 200 {
		t.Fatalf("matching repair %d %s", good.StatusCode, read(t, good))
	}
	_ = read(t, good)
	if err := fresh.Pool.QueryRow(t.Context(), `SELECT state FROM blobs WHERE id=$1`, blobID).Scan(&state); err != nil || state != "ready" {
		t.Fatalf("repaired state %s %v", state, err)
	}
	got, err := os.ReadFile(store.BlobPath(freshCfg.DataRoot, blobID))
	if err != nil || !bytes.Equal(got, original) {
		t.Fatalf("repaired bytes %v %q", err, got)
	}

	locked := []byte("%PDF-1.4\ntrailer << /Encrypt 9 0 R >>\n%%EOF\n")
	hash := sha256.Sum256(locked)
	blob := uuid.NewString()
	uploadBody := fmt.Sprintf(`{"blobId":%q,"size":%d,"sha256":%q,"mime":"application/pdf"}`, blob, len(locked), hex.EncodeToString(hash[:]))
	created := post(t, freshTS.URL+"/api/v1/uploads", uploadBody, login.Data.SessionToken, login.Data.Epoch, "")
	var upload struct {
		Data struct {
			UploadID string `json:"uploadId"`
		} `json:"data"`
	}
	mustJSON(t, read(t, created), &upload)
	chunk := putBytes(t, freshTS.URL+"/api/v1/uploads/"+upload.Data.UploadID+"/chunks/0", locked, login.Data.SessionToken, login.Data.Epoch)
	if chunk.StatusCode != 200 {
		t.Fatalf("chunk %d %s", chunk.StatusCode, read(t, chunk))
	}
	_ = read(t, chunk)
	done := post(t, freshTS.URL+"/api/v1/uploads/"+upload.Data.UploadID+"/complete", `{}`, login.Data.SessionToken, login.Data.Epoch, "")
	if done.StatusCode != 200 {
		t.Fatalf("complete %d %s", done.StatusCode, read(t, done))
	}
	_ = read(t, done)
	var passwordRequired bool
	if err := fresh.Pool.QueryRow(t.Context(), `SELECT password_required FROM blobs WHERE id=$1`, blob).Scan(&passwordRequired); err != nil || !passwordRequired {
		t.Fatalf("password_required=%v err=%v", passwordRequired, err)
	}
}

func postBytes(t *testing.T, url string, body []byte, tok, epoch string) *http.Response {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPost, url, bytes.NewReader(body))
	if tok != "" {
		req.Header.Set("Authorization", "Bearer "+tok)
	}
	if epoch != "" {
		req.Header.Set("X-Library-Epoch", epoch)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	return res
}

func putBytes(t *testing.T, url string, body []byte, tok, epoch string) *http.Response {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPut, url, bytes.NewReader(body))
	if tok != "" {
		req.Header.Set("Authorization", "Bearer "+tok)
	}
	if epoch != "" {
		req.Header.Set("X-Library-Epoch", epoch)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	return res
}

func TestLoginLimitUsesTheConnectionPeer(t *testing.T) {
	st, cfg := testdb.Start(t)
	defer st.Close()
	if len(cfg.TrustedProxyCIDRs) != 0 {
		t.Fatal("default config must not trust forwarded client addresses")
	}
	ts := httptest.NewServer(api.New(cfg, st, &jobs.Runner{S: st}))
	defer ts.Close()
	body := fmt.Sprintf(`{"username":"token","password":"wrong-password","deviceId":%q,"deviceName":"t","platform":"mac"}`, uuid.NewString())
	for i := 0; i < authn.LoginFailureLimit; i++ {
		req, err := http.NewRequest(http.MethodPost, ts.URL+"/api/v1/auth/login", strings.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("X-Forwarded-For", fmt.Sprintf("203.0.113.%d", i+1))
		req.Header.Set("X-Real-IP", fmt.Sprintf("198.51.100.%d", i+1))
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		got := read(t, res)
		if res.StatusCode != 401 {
			t.Fatalf("forwarded failure %d: %d %s", i+1, res.StatusCode, got)
		}
	}
	req, err := http.NewRequest(http.MethodPost, ts.URL+"/api/v1/auth/login", strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Forwarded-For", "203.0.113.200")
	req.Header.Set("X-Real-IP", "198.51.100.200")
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	limited := read(t, res)
	if res.StatusCode != 429 || !strings.Contains(limited, "RATE_LIMITED") {
		t.Fatalf("rotated forwarding headers escaped the peer limit: %d %s", res.StatusCode, limited)
	}
}

func TestChangesAvailableDoesNotReplaceHTTPPull(t *testing.T) {
	st, cfg := testdb.Start(t)
	defer st.Close()
	ts := httptest.NewServer(api.New(cfg, st, &jobs.Runner{S: st}))
	defer ts.Close()
	res := post(t, ts.URL+"/api/v1/auth/login", fmt.Sprintf(`{"username":"token","password":"local-dev-pass","deviceId":%q,"deviceName":"t","platform":"mac"}`, uuid.NewString()), "", "", "")
	var login struct {
		Data struct {
			SessionToken, Epoch, RootID, DeviceID string
		} `json:"data"`
	}
	mustJSON(t, read(t, res), &login)
	header := http.Header{}
	header.Set("Authorization", "Bearer "+login.Data.SessionToken)
	header.Set("X-Library-Epoch", login.Data.Epoch)
	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/api/v1/ws"
	conn, _, err := websocket.DefaultDialer.Dial(wsURL, header)
	if err != nil {
		t.Fatal(err)
	}
	create := func(name, source string) {
		t.Helper()
		id := uuid.NewString()
		op := uuid.NewString()
		payload := fmt.Sprintf(`{"protocolVersion":1,"operationId":%q,"epoch":%q,"deviceId":%q,"objectId":%q,"action":"createMarkdown","desiredSnapshot":{"name":%q,"parentId":%q,"markdownSource":%q}}`,
			op, login.Data.Epoch, login.Data.DeviceID, id, name, login.Data.RootID, source)
		res := post(t, ts.URL+"/api/v1/sync/operations", payload, login.Data.SessionToken, login.Data.Epoch, op)
		if res.StatusCode != 201 {
			t.Fatalf("create %s %d %s", name, res.StatusCode, read(t, res))
		}
		_ = read(t, res)
	}
	create("first.md", "first")
	var note struct {
		Type           string `json:"type"`
		Epoch          string `json:"epoch"`
		LatestSequence int64  `json:"latestSequence"`
	}
	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	if err = conn.ReadJSON(&note); err != nil {
		t.Fatal(err)
	}
	if note.Type != "changes_available" || note.Epoch != login.Data.Epoch || note.LatestSequence < 1 {
		t.Fatalf("notification: %+v", note)
	}
	pong := make(chan struct{}, 1)
	conn.SetPongHandler(func(string) error {
		pong <- struct{}{}
		return nil
	})
	if err = conn.WriteControl(websocket.PingMessage, []byte("ping"), time.Now().Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	go func() { _, _, _ = conn.ReadMessage() }()
	select {
	case <-pong:
	case <-time.After(5 * time.Second):
		t.Fatal("server did not pong")
	}
	_ = conn.Close()

	again, _, err := websocket.DefaultDialer.Dial(wsURL, header)
	if err != nil {
		t.Fatal(err)
	}
	create("second.md", "second-after-reconnect")
	_ = again.SetReadDeadline(time.Now().Add(5 * time.Second))
	if err = again.ReadJSON(&note); err != nil {
		t.Fatal(err)
	}
	if note.Type != "changes_available" || note.LatestSequence < 2 {
		t.Fatalf("reconnect notification: %+v", note)
	}
	_ = again.Close()
	create("third.md", "third-while-socket-down")
	pulled := get(t, ts.URL+"/api/v1/sync/changes?after=0", login.Data.SessionToken, login.Data.Epoch)
	body := read(t, pulled)
	if pulled.StatusCode != 200 || !strings.Contains(body, "third-while-socket-down") {
		t.Fatalf("http pull after dropped notification %d %s", pulled.StatusCode, body)
	}
}

func TestUploadTokenImportStatus(t *testing.T) {
	st, cfg := testdb.Start(t)
	defer st.Close()
	ts := httptest.NewServer(api.New(cfg, st, &jobs.Runner{S: st}))
	defer ts.Close()
	uploadTok := "local-upload-token-32-bytes-min!!"
	dev := uuid.NewString()
	res := post(t, ts.URL+"/api/v1/auth/login", fmt.Sprintf(`{"username":"token","password":"local-dev-pass","deviceId":%q,"deviceName":"t","platform":"mac"}`, dev), "", "", "")
	var login struct {
		Data struct {
			SessionToken, Epoch, RootID, DeviceID string
		} `json:"data"`
	}
	mustJSON(t, read(t, res), &login)
	secret := "session-only-snapshot-" + uuid.NewString()
	sessionOp := uuid.NewString()
	sessionObj := uuid.NewString()
	payload := fmt.Sprintf(`{"protocolVersion":1,"operationId":%q,"epoch":%q,"deviceId":%q,"objectId":%q,"action":"createMarkdown","desiredSnapshot":{"name":"private.md","parentId":%q,"markdownSource":%s}}`,
		sessionOp, login.Data.Epoch, login.Data.DeviceID, sessionObj, login.Data.RootID, jsonStr(secret))
	res = post(t, ts.URL+"/api/v1/sync/operations", payload, login.Data.SessionToken, login.Data.Epoch, sessionOp)
	if res.StatusCode != 201 {
		t.Fatalf("session create %d %s", res.StatusCode, read(t, res))
	}
	_ = read(t, res)

	res = get(t, ts.URL+"/api/v1/objects/"+sessionObj, uploadTok, login.Data.Epoch)
	if res.StatusCode != 401 {
		t.Fatalf("upload token object read %d %s", res.StatusCode, read(t, res))
	}
	_ = read(t, res)

	res = get(t, ts.URL+"/api/v1/imports/"+sessionOp, uploadTok, login.Data.Epoch)
	stolen := read(t, res)
	if res.StatusCode != 404 {
		t.Fatalf("upload token must not read a session operation, got %d %s", res.StatusCode, stolen)
	}
	if strings.Contains(stolen, secret) {
		t.Fatalf("session snapshot leaked: %s", stolen)
	}

	ownName := "upload-" + uuid.NewString()[:8] + ".md"
	ownBody := importFile(t, ts.URL, uploadTok, login.Data.Epoch, ownName, "# imported\n")
	var imported struct {
		Data struct {
			OperationID string `json:"operationId"`
		} `json:"data"`
	}
	mustJSON(t, ownBody, &imported)
	if imported.Data.OperationID == "" {
		t.Fatalf("import response missing operationId: %s", ownBody)
	}
	res = get(t, ts.URL+"/api/v1/imports/"+imported.Data.OperationID, uploadTok, login.Data.Epoch)
	statusBody := read(t, res)
	if res.StatusCode != 200 {
		t.Fatalf("own import status %d %s", res.StatusCode, statusBody)
	}
	if strings.Contains(statusBody, secret) || strings.Contains(statusBody, "snapshot") || strings.Contains(statusBody, "markdownSource") {
		t.Fatalf("import status returned a document snapshot: %s", statusBody)
	}
	for _, want := range []string{imported.Data.OperationID, ownName, `"status"`} {
		if !strings.Contains(statusBody, want) {
			t.Fatalf("import status missing %s in %s", want, statusBody)
		}
	}
}

func importRaw(t *testing.T, base, tok, epoch, name, content string) *http.Response {
	t.Helper()
	var buf bytes.Buffer
	w := multipart.NewWriter(&buf)
	fw, _ := w.CreateFormFile("file", name)
	_, _ = fw.Write([]byte(content))
	_ = w.Close()
	req, _ := http.NewRequest(http.MethodPost, base+"/api/v1/imports", &buf)
	req.Header.Set("Content-Type", w.FormDataContentType())
	req.Header.Set("Authorization", "Bearer "+tok)
	req.Header.Set("X-Library-Epoch", epoch)
	req.Header.Set("Idempotency-Key", uuid.NewString())
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	return res
}
