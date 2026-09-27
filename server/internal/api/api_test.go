package api_test

import (
	"bytes"
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

	"github.com/google/uuid"

	"tokenlibrary/internal/api"
	"tokenlibrary/internal/jobs"
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
