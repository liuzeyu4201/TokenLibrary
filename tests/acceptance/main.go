package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/google/uuid"
)

func main() {
	base := getenv("TOKENLIBRARY_BASE_URL", "http://127.0.0.1:8080")
	user := getenv("ADMIN_USERNAME", "token")
	pass := getenv("ADMIN_PASSWORD", "123")
	uploadTok := getenv("UPLOAD_TOKEN", "local-upload-token-32-bytes-min!!")
	must := func(cond bool, msg string, args ...any) {
		if !cond {
			fmt.Fprintf(os.Stderr, "FAIL: "+msg+"\n", args...)
			os.Exit(1)
		}
	}

	ready := get(base + "/health/ready")
	must(ready.Status == 200 && strings.Contains(ready.Body, `"ready":true`), "health ready: %s", ready.Body)
	fmt.Println("ok health")

	dev := uuid.NewString()
	login := postJSON(base+"/api/v1/auth/login", fmt.Sprintf(`{"username":%q,"password":%q,"deviceId":%q,"deviceName":"flow","platform":"mac"}`, user, pass, dev), "", "", "")
	must(login.Status == 200, "login %d %s", login.Status, login.Body)
	tok := jstr(login.Body, "data", "sessionToken")
	epoch := jstr(login.Body, "data", "epoch")
	root := jstr(login.Body, "data", "rootId")
	device := jstr(login.Body, "data", "deviceId")
	must(tok != "" && epoch != "", "login fields")
	fmt.Println("ok login")

	folder := uuid.NewString()
	r := op(base, tok, epoch, device, "createFolder", folder, fmt.Sprintf(`{"name":%q,"parentId":%q}`, "研究-"+folder[:8], root), nil)
	must(r.Status == 201, "folder %s", r.Body)
	fmt.Println("ok folder")

	png := png1x1()
	imgID := uuid.NewString()
	imgSum := sha256Hex(png)
	up := postJSON(base+"/api/v1/uploads", fmt.Sprintf(`{"blobId":%q,"size":%d,"sha256":%q,"mime":"image/png"}`, imgID, len(png), imgSum), tok, epoch, uuid.NewString())
	must(up.Status == 200, "img upload init %s", up.Body)
	putChunk(base, tok, epoch, jstr(up.Body, "data", "uploadId"), png, imgSum)
	comp := postJSON(base+"/api/v1/uploads/"+jstr(up.Body, "data", "uploadId")+"/complete", `{}`, tok, epoch, uuid.NewString())
	must(comp.Status == 200, "img complete %s", comp.Body)

	md := uuid.NewString()
	src := "# 三方合并\n\n```mermaid\ngraph TD\n A-->B\n```\n\n$n+1$\n\n$$a+b$$\n\n![fig](/api/v1/blobs/" + imgID + ")\n"
	r = op(base, tok, epoch, device, "createMarkdown", md, fmt.Sprintf(`{"name":"三方合并规则.md","parentId":%q,"markdownSource":%s,"assets":[{"blobId":%q}]}`, folder, jraw(src), imgID), nil)
	must(r.Status == 201, "md %s", r.Body)
	got := get(base+"/api/v1/objects/"+md, tok, epoch)
	must(strings.Contains(got.Body, "mermaid") && strings.Contains(got.Body, "/api/v1/blobs/"+imgID), "md snapshot missing image/mermaid: %s", got.Body)
	fmt.Println("ok markdown mermaid latex image")

	pdfBytes := []byte("%PDF-1.4\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF\n")
	blobID := uuid.NewString()
	sum := sha256Hex(pdfBytes)
	up = postJSON(base+"/api/v1/uploads", fmt.Sprintf(`{"blobId":%q,"size":%d,"sha256":%q,"mime":"application/pdf"}`, blobID, len(pdfBytes), sum), tok, epoch, uuid.NewString())
	must(up.Status == 200, "upload init %s", up.Body)
	putChunk(base, tok, epoch, jstr(up.Body, "data", "uploadId"), pdfBytes, sum)
	comp = postJSON(base+"/api/v1/uploads/"+jstr(up.Body, "data", "uploadId")+"/complete", `{}`, tok, epoch, uuid.NewString())
	must(comp.Status == 200, "complete %s", comp.Body)
	pdfID := uuid.NewString()
	ann := fmt.Sprintf(`[{"id":%q,"type":"highlight","pageIndex":0,"geometry":{"x":1,"y":1,"w":2,"h":2},"color":"#FFE08A","text":"这段与实验结论不一致","placementState":"attached"}]`, uuid.NewString())
	r = op(base, tok, epoch, device, "createPDF", pdfID, fmt.Sprintf(`{"name":"RFC9562.pdf","parentId":%q,"pdfBlobId":%q,"annotations":%s}`, folder, blobID, ann), nil)
	must(r.Status == 201, "pdf %s", r.Body)
	pdfObj := get(base+"/api/v1/objects/"+pdfID, tok, epoch)
	must(strings.Contains(pdfObj.Body, "这段与实验结论不一致"), "export snapshot missing annotation: %s", pdfObj.Body)
	blob := get(base+"/api/v1/blobs/"+blobID, tok, epoch)
	must(blob.Status == 200 && strings.Contains(blob.Body, "%PDF"), "pdf bytes %d", blob.Status)
	fmt.Println("ok pdf highlight/comment export bytes")

	mdExport := get(base+"/api/v1/objects/"+md, tok, epoch)
	must(strings.Contains(mdExport.Body, "```mermaid") && strings.Contains(mdExport.Body, "$n+1$"), "md export source %s", mdExport.Body)
	fmt.Println("ok export markdown source")

	dev2 := uuid.NewString()
	login2 := postJSON(base+"/api/v1/auth/login", fmt.Sprintf(`{"username":%q,"password":%q,"deviceId":%q,"deviceName":"phone","platform":"ios"}`, user, pass, dev2), "", "", "")
	tok2 := jstr(login2.Body, "data", "sessionToken")
	dev2id := jstr(login2.Body, "data", "deviceId")
	obj := get(base+"/api/v1/objects/"+md, tok, epoch)
	rev := jnum(obj.Body, "data", "snapshot", "revision")
	left := src + "\nphone paragraph\n"
	right := src + "\nmac paragraph\n"
	r = op(base, tok2, epoch, dev2id, "updateDocument", md, fmt.Sprintf(`{"name":"三方合并规则.md","parentId":%q,"markdownSource":%s}`, folder, jraw(left)), &rev)
	must(r.Status == 200, "phone upd %s", r.Body)
	r = op(base, tok, epoch, device, "updateDocument", md, fmt.Sprintf(`{"name":"三方合并规则.md","parentId":%q,"markdownSource":%s}`, folder, jraw(right)), &rev)
	must(r.Status == 200, "mac upd %s", r.Body)
	must(!strings.Contains(r.Body, `"status":"conflict"`), "compatible adds must not conflict: %s", r.Body)
	merged := get(base+"/api/v1/objects/"+md, tok, epoch)
	must(strings.Contains(merged.Body, "phone paragraph") && strings.Contains(merged.Body, "mac paragraph"), "merged missing both paragraphs: %s", merged.Body)
	fmt.Println("ok two-device compatible merge")

	obj = get(base+"/api/v1/objects/"+md, tok, epoch)
	rev = jnum(obj.Body, "data", "snapshot", "revision")
	ms := jstr(obj.Body, "data", "snapshot", "markdownSource")
	l2 := strings.Replace(ms, "A-->B", "A-->L", 1)
	r2s := strings.Replace(ms, "A-->B", "A-->R", 1)
	if l2 == ms {
		l2 = ms + "\n```mermaid\ngraph TD\nX-->L\n```\n"
		r2s = ms + "\n```mermaid\ngraph TD\nX-->R\n```\n"
	}
	r = op(base, tok2, epoch, dev2id, "updateDocument", md, fmt.Sprintf(`{"name":"三方合并规则.md","parentId":%q,"markdownSource":%s}`, folder, jraw(l2)), &rev)
	must(r.Status < 400, "left %s", r.Body)
	r = op(base, tok, epoch, device, "updateDocument", md, fmt.Sprintf(`{"name":"三方合并规则.md","parentId":%q,"markdownSource":%s}`, folder, jraw(r2s)), &rev)
	must(strings.Contains(r.Body, `"status":"conflict"`), "expected conflict %s", r.Body)
	fmt.Println("ok conflict unsynced")

	tmp := uuid.NewString()
	r = op(base, tok, epoch, device, "createMarkdown", tmp, fmt.Sprintf(`{"name":%q,"parentId":%q,"markdownSource":"x"}`, "tmp-"+tmp[:8]+".md", folder), nil)
	must(r.Status == 201, "tmp %s", r.Body)
	r = op(base, tok, epoch, device, "trash", tmp, `{}`, nil)
	must(r.Status == 200, "trash %s", r.Body)
	r = op(base, tok, epoch, device, "restore", tmp, fmt.Sprintf(`{"parentId":%q}`, folder), nil)
	must(r.Status == 200, "restore %s", r.Body)
	fmt.Println("ok trash/restore")

	offID := uuid.NewString()
	r = op(base, tok, epoch, device, "createMarkdown", offID, fmt.Sprintf(`{"name":%q,"parentId":%q,"markdownSource":"base"}`, "offline-"+offID[:8]+".md", folder), nil)
	must(r.Status == 201, "offline create %s", r.Body)
	offlineBody := "base\noffline-edit-then-sync\n"
	r = op(base, tok, epoch, device, "updateDocument", offID, fmt.Sprintf(`{"name":%q,"parentId":%q,"markdownSource":%s}`, "offline-"+offID[:8]+".md", folder, jraw(offlineBody)), ptr("1"))
	must(r.Status == 200 || r.Status == 201, "offline sync %s", r.Body)
	offGot := get(base+"/api/v1/objects/"+offID, tok, epoch)
	must(strings.Contains(offGot.Body, "offline-edit-then-sync"), "offline content missing: %s", offGot.Body)
	fmt.Println("ok offline-edit-then-sync")

	impName := "报告-" + uuid.NewString()[:8] + ".md"
	imp1 := importFile(base, uploadTok, epoch, impName, "# one")
	must(imp1.Status == 201 || imp1.Status == 200, "import1 %s", imp1.Body)
	imp2 := importFile(base, uploadTok, epoch, impName, "# two")
	must(strings.Contains(imp2.Body, "_1"), "suffix %s", imp2.Body)
	bad := importFile(base, "bad-token", epoch, "x.md", "x")
	must(bad.Status == 401, "bad token %d", bad.Status)
	stolen := get(base+"/api/v1/objects/"+md, uploadTok, epoch)
	must(stolen.Status == 401, "upload token must not read %d %s", stolen.Status, stolen.Body)
	fmt.Println("ok curl import")

	run := postJSON(base+"/api/v1/test/backup/run", "{}", tok, epoch, "")
	must(run.Status == 200, "backup run %s", run.Body)
	must(strings.Contains(run.Body, `"state":"success"`), "backup success %s", run.Body)
	bpath := jstr(run.Body, "data", "backups")
	_ = bpath
	var wrap struct {
		Data struct {
			Backups []struct {
				ID    string `json:"id"`
				Path  string `json:"path"`
				State string `json:"state"`
			} `json:"backups"`
		} `json:"data"`
	}
	_ = json.Unmarshal([]byte(run.Body), &wrap)
	must(len(wrap.Data.Backups) > 0, "no backup rows")
	host := getenv("BACKUP_ROOT", filepath.Join(rootDir(), ".local/backup"))
	dump := filepath.Join(host, wrap.Data.Backups[0].ID, "db.dump")
	if _, err := os.Stat(dump); err != nil {
		dump = filepath.Join(wrap.Data.Backups[0].Path, "db.dump")
	}
	st, err := os.Stat(dump)
	must(err == nil && st.Size() > 0, "missing backup artifact %s (%v)", dump, err)
	fmt.Println("ok real backup artifact", dump)

	beg := postJSON(base+"/api/v1/test/backup/begin", "{}", tok, epoch, "")
	must(beg.Status == 200, "backup begin %s", beg.Body)
	paused := op(base, tok, epoch, device, "createMarkdown", uuid.NewString(), fmt.Sprintf(`{"name":"paused.md","parentId":%q,"markdownSource":"z"}`, folder), nil)
	must(paused.Status == 503, "want 503 got %d %s", paused.Status, paused.Body)
	localDir, _ := os.MkdirTemp("", "tl-local-*")
	cmd := exec.Command("swift", "run", "--package-path", filepath.Join(rootDir(), "clients", "LibraryCore"), "tltool", "local-save", localDir, "saved-during-backup-pause")
	out, err := cmd.CombinedOutput()
	must(err == nil && strings.Contains(string(out), "saved-during-backup-pause"), "local save during backup: %v %s", err, out)
	fmt.Println("ok local save during backup pause")
	end := postJSON(base+"/api/v1/test/backup/end", "{}", tok, epoch, "")
	must(end.Status == 200, "backup end %s", end.Body)
	fmt.Println("ok backup pause 503")

	fmt.Println("BUSINESS FLOW PASSED")
}

func ptr(s string) *string { return &s }

func putChunk(base, tok, epoch, uploadID string, body []byte, sum string) {
	req, _ := http.NewRequest(http.MethodPut, base+"/api/v1/uploads/"+uploadID+"/chunks/0", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+tok)
	req.Header.Set("X-Library-Epoch", epoch)
	req.Header.Set("X-Chunk-SHA256", sum)
	resp, _ := http.DefaultClient.Do(req)
	if resp != nil {
		resp.Body.Close()
	}
}

func png1x1() []byte {
	return []byte{
		0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
		0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
		0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89, 0x00, 0x00, 0x00,
		0x0a, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0x00, 0x01, 0x00, 0x00,
		0x05, 0x00, 0x01, 0x0d, 0x0a, 0x2d, 0xb4, 0x00, 0x00, 0x00, 0x00, 0x49,
		0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
	}
}

func rootDir() string {
	wd, _ := os.Getwd()
	for p := wd; p != "/"; p = filepath.Dir(p) {
		if _, err := os.Stat(filepath.Join(p, "Makefile")); err == nil {
			return p
		}
	}
	return wd
}

type httpRes struct {
	Status int
	Body   string
}

func get(url string, auth ...string) httpRes {
	req, _ := http.NewRequest(http.MethodGet, url, nil)
	if len(auth) > 0 && auth[0] != "" {
		req.Header.Set("Authorization", "Bearer "+auth[0])
	}
	if len(auth) > 1 && auth[1] != "" {
		req.Header.Set("X-Library-Epoch", auth[1])
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return httpRes{Status: 0, Body: err.Error()}
	}
	b, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	return httpRes{Status: resp.StatusCode, Body: string(b)}
}

func postJSON(url, body, tok, epoch, idem string) httpRes {
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
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return httpRes{0, err.Error()}
	}
	b, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	return httpRes{resp.StatusCode, string(b)}
}

func op(base, tok, epoch, device, action, obj, desired string, rev *string) httpRes {
	oid := uuid.NewString()
	basePart := "null"
	if rev != nil {
		basePart = fmt.Sprintf(`{"source":"revision","revision":%s}`, *rev)
	}
	payload := fmt.Sprintf(`{"protocolVersion":1,"operationId":%q,"epoch":%q,"deviceId":%q,"objectId":%q,"action":%q,"base":%s,"desiredSnapshot":%s}`,
		oid, epoch, device, obj, action, basePart, desired)
	return postJSON(base+"/api/v1/sync/operations", payload, tok, epoch, oid)
}

func importFile(base, tok, epoch, name, content string) httpRes {
	var buf bytes.Buffer
	w := multipart.NewWriter(&buf)
	fw, _ := w.CreateFormFile("file", name)
	_, _ = io.WriteString(fw, content)
	_ = w.Close()
	req, _ := http.NewRequest(http.MethodPost, base+"/api/v1/imports", &buf)
	req.Header.Set("Content-Type", w.FormDataContentType())
	req.Header.Set("Authorization", "Bearer "+tok)
	req.Header.Set("X-Library-Epoch", epoch)
	req.Header.Set("Idempotency-Key", uuid.NewString())
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return httpRes{0, err.Error()}
	}
	b, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	return httpRes{resp.StatusCode, string(b)}
}

func jstr(s string, keys ...string) string {
	var cur any
	_ = json.Unmarshal([]byte(s), &cur)
	for _, k := range keys {
		m, _ := cur.(map[string]any)
		if m == nil {
			return ""
		}
		cur = m[k]
	}
	if x, ok := cur.(string); ok {
		return x
	}
	b, _ := json.Marshal(cur)
	return strings.Trim(string(b), `"`)
}

func jnum(s string, keys ...string) string { return jstr(s, keys...) }

func jraw(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}

func getenv(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func sha256Hex(b []byte) string {
	h := sha256.Sum256(b)
	return fmt.Sprintf("%x", h[:])
}
