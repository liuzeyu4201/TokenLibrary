package api

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"tokenlibrary/internal/authn"
	"tokenlibrary/internal/canon"
	"tokenlibrary/internal/config"
	"tokenlibrary/internal/jobs"
	"tokenlibrary/internal/names"
	"tokenlibrary/internal/store"
	"tokenlibrary/internal/synceng"
)

type Server struct {
	Cfg config.Config
	S   *store.Store
	E   *synceng.Engine
	J   *jobs.Runner
}

func New(cfg config.Config, s *store.Store, j *jobs.Runner) *gin.Engine {
	gin.SetMode(gin.ReleaseMode)
	r := gin.New()
	r.Use(gin.Recovery())
	sv := &Server{Cfg: cfg, S: s, E: &synceng.Engine{S: s}, J: j}

	r.GET("/health/live", func(c *gin.Context) { c.JSON(200, gin.H{"ok": true}) })
	r.GET("/health/ready", sv.ready)

	v1 := r.Group("/api/v1")
	v1.POST("/auth/login", sv.login)
	v1.POST("/auth/logout", sv.requireSession, sv.logout)
	v1.GET("/meta", sv.requireSession, sv.meta)
	v1.GET("/sync/changes", sv.requireSession, sv.changes)
	v1.POST("/sync/snapshots", sv.requireSession, sv.writeGuard, sv.createSnapshot)
	v1.GET("/sync/snapshots/:id", sv.requireSession, sv.getSnapshot)
	v1.POST("/sync/operations", sv.requireSession, sv.operations)
	v1.GET("/sync/operations/:operationId", sv.requireSession, sv.getOp)
	v1.GET("/objects/:id", sv.requireSession, sv.getObject)
	v1.GET("/objects/:id/revisions/:revision", sv.requireSession, sv.getRev)
	v1.POST("/sync/tombstones/query", sv.requireSession, sv.tombstones)
	v1.GET("/conflicts/:id", sv.requireSession, sv.getConflict)
	v1.GET("/conflicts", sv.requireSession, sv.listConflicts)
	v1.GET("/conflicts/:id/materials/:role", sv.requireSession, sv.conflictMaterial)
	v1.POST("/uploads", sv.requireSession, sv.writeGuard, sv.createUpload)
	v1.GET("/uploads/:id", sv.requireSession, sv.getUpload)
	v1.PUT("/uploads/:id/chunks/:index", sv.requireSession, sv.writeGuard, sv.putChunk)
	v1.POST("/uploads/:id/complete", sv.requireSession, sv.writeGuard, sv.completeUpload)
	v1.GET("/blobs/:id", sv.requireSession, sv.getBlob)
	v1.GET("/imports/meta", sv.requireUpload, sv.importMeta)
	v1.POST("/imports", sv.requireUpload, sv.writeGuard, sv.importFile)
	v1.GET("/imports/:operationId", sv.requireUpload, sv.importStatus)
	v1.GET("/ws", sv.requireSession, sv.ws)

	if cfg.TestHooks {
		v1.POST("/test/backup/begin", sv.testBackupBegin)
		v1.POST("/test/backup/end", sv.testBackupEnd)
		v1.POST("/test/backup/run", sv.testBackupRun)
		v1.GET("/test/backups", sv.testBackupList)
		v1.POST("/test/purge", sv.testPurge)
	}
	return r
}

func (s *Server) ready(c *gin.Context) {
	ctx := c.Request.Context()
	maint, err := s.S.Ready(ctx)
	if err != nil {
		c.JSON(503, gin.H{"ready": false})
		return
	}
	c.JSON(200, gin.H{"ready": true, "maintenance": maint})
}

type ctxKey string

const (
	ctxSession ctxKey = "session"
	ctxUpload  ctxKey = "upload"
)

type sessionInfo struct {
	ID       uuid.UUID
	DeviceID uuid.UUID
	Token    string
}

func (s *Server) requireSession(c *gin.Context) {
	h := c.GetHeader("Authorization")
	tok := strings.TrimPrefix(h, "Bearer ")
	if tok == "" || tok == h {
		c.AbortWithStatusJSON(401, errBody(c, "UNAUTHORIZED", "login required", false))
		return
	}
	hash := authn.SHA256Bytes(tok)
	var sid, did uuid.UUID
	// Authorize and renew together. A revoked/expired session must never be
	// renewed by a request racing logout, and a failed renewal is not success.
	err := s.S.Pool.QueryRow(c, `UPDATE sessions SET last_seen_at=now()
		WHERE token_hash=$1 AND library_id=$2 AND credential_generation=$3
		AND revoked_at IS NULL AND last_seen_at>=now()-interval '90 days'
		RETURNING id, device_id`, hash, s.S.LibID, s.Cfg.CredentialGen).Scan(&sid, &did)
	if errors.Is(err, pgx.ErrNoRows) {
		c.AbortWithStatusJSON(401, errBody(c, "UNAUTHORIZED", "session", false))
		return
	}
	if err != nil {
		c.AbortWithStatusJSON(503, errBody(c, "UNAVAILABLE", "session renewal unavailable", true))
		return
	}
	_, _ = s.S.Pool.Exec(c, `UPDATE devices SET last_seen_at=now() WHERE id=$1`, did)
	if ep := c.GetHeader("X-Library-Epoch"); ep != "" && c.Request.Method != "GET" {
		if u, err := uuid.Parse(ep); err != nil || u != s.S.Epoch {
			c.AbortWithStatusJSON(409, errBody(c, "EPOCH_CHANGED", "epoch", false))
			return
		}
	}
	c.Set("session", sessionInfo{ID: sid, DeviceID: did, Token: tok})
	c.Next()
}

func (s *Server) requireUpload(c *gin.Context) {
	if !s.Cfg.UploadTokenEnabled || len(s.Cfg.UploadTokenHash) == 0 {
		c.AbortWithStatusJSON(403, errBody(c, "FORBIDDEN", "upload disabled", false))
		return
	}
	h := c.GetHeader("Authorization")
	tok := strings.TrimPrefix(h, "Bearer ")
	if !authn.EqualHash(authn.SHA256Bytes(tok), s.Cfg.UploadTokenHash) {
		c.AbortWithStatusJSON(401, errBody(c, "UNAUTHORIZED", "upload token", false))
		return
	}
	if ep := c.GetHeader("X-Library-Epoch"); ep != "" {
		if u, err := uuid.Parse(ep); err != nil || u != s.S.Epoch {
			c.AbortWithStatusJSON(409, errBody(c, "EPOCH_CHANGED", "epoch", false))
			return
		}
	}
	c.Next()
}

func (s *Server) login(c *gin.Context) {
	var req struct {
		Username   string `json:"username"`
		Password   string `json:"password"`
		DeviceID   string `json:"deviceId"`
		DeviceName string `json:"deviceName"`
		Platform   string `json:"platform"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(422, errBody(c, "VALIDATION", "body", false))
		return
	}
	if req.Username != s.Cfg.AdminUsername || !authn.VerifyPassword(s.Cfg.AdminPasswordHash, req.Password) {
		c.JSON(401, errBody(c, "UNAUTHORIZED", "invalid credentials", false))
		return
	}
	did, err := uuid.Parse(req.DeviceID)
	if err != nil {
		did = uuid.New()
	}
	_, _ = s.S.Pool.Exec(c, `INSERT INTO devices(id, library_id, name, platform) VALUES ($1,$2,$3,$4)
		ON CONFLICT (id) DO UPDATE SET name=EXCLUDED.name, platform=EXCLUDED.platform, last_seen_at=now()`,
		did, s.S.LibID, nz(req.DeviceName, "device"), nz(req.Platform, "unknown"))
	tok := authn.Token()
	sid := uuid.New()
	_, err = s.S.Pool.Exec(c, `INSERT INTO sessions(id, device_id, library_id, token_hash, credential_generation) VALUES ($1,$2,$3,$4,$5)`,
		sid, did, s.S.LibID, authn.SHA256Bytes(tok), s.Cfg.CredentialGen)
	if err != nil {
		c.JSON(500, errBody(c, "INTERNAL", "session", false))
		return
	}
	c.JSON(200, gin.H{"data": gin.H{
		"sessionToken": tok,
		"sessionId":    sid.String(),
		"libraryId":    s.S.LibID.String(),
		"epoch":        s.S.Epoch.String(),
		"rootId":       s.S.RootID.String(),
		"deviceId":     did.String(),
		"expiresAt":    time.Now().UTC().Add(90 * 24 * time.Hour).Format(time.RFC3339Nano),
	}, "requestId": reqID(c)})
}

func (s *Server) logout(c *gin.Context) {
	sess := c.MustGet("session").(sessionInfo)
	if _, err := s.S.Pool.Exec(c, `UPDATE sessions SET revoked_at=now() WHERE id=$1`, sess.ID); err != nil {
		c.JSON(503, errBody(c, "UNAVAILABLE", "session revocation unavailable", true))
		return
	}
	c.JSON(200, gin.H{"data": gin.H{"loggedOut": true}, "requestId": reqID(c)})
}

func (s *Server) meta(c *gin.Context) {
	var seq int64
	var maint bool
	_ = s.S.Pool.QueryRow(c, `SELECT change_seq, maintenance FROM libraries WHERE id=$1`, s.S.LibID).Scan(&seq, &maint)
	c.JSON(200, gin.H{"data": gin.H{
		"libraryId": s.S.LibID.String(), "epoch": s.S.Epoch.String(), "latestSeq": strconv.FormatInt(seq, 10),
		"minAvailableSeq": "0", "rootId": s.S.RootID.String(),
		"limits":      gin.H{"pdfBytes": 50000000, "mdBytes": 5000000, "imageBytes": 20000000},
		"maintenance": maint,
	}, "requestId": reqID(c)})
}

func (s *Server) operations(c *gin.Context) {
	if maint, _ := s.S.Ready(c); maint {
		c.Header("Retry-After", "30")
		c.JSON(503, errBody(c, "MAINTENANCE", "cloud writes paused", true))
		return
	}
	body, err := io.ReadAll(io.LimitReader(c.Request.Body, 32<<20))
	if err != nil {
		c.JSON(422, errBody(c, "VALIDATION", "body", false))
		return
	}
	var env synceng.Envelope
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.UseNumber()
	if err := dec.Decode(&env); err != nil {
		c.JSON(422, errBody(c, "VALIDATION", "json", false))
		return
	}
	if k := c.GetHeader("Idempotency-Key"); k != "" && env.OperationID != "" && !strings.EqualFold(k, env.OperationID) {
		c.JSON(422, errBody(c, "VALIDATION", "Idempotency-Key must match operationId", false))
		return
	}
	if env.OperationID == "" {
		env.OperationID = c.GetHeader("Idempotency-Key")
	}
	sess := c.MustGet("session").(sessionInfo)
	if env.DeviceID == "" {
		env.DeviceID = sess.DeviceID.String()
	}
	if env.Epoch == "" {
		env.Epoch = s.S.Epoch.String()
	}
	if ep := c.GetHeader("X-Library-Epoch"); ep != "" {
		env.Epoch = ep
	}
	res, err := s.E.Apply(c, env, "client", body)
	s.writeOp(c, res, err)
}

func (s *Server) writeOp(c *gin.Context, res synceng.OpResult, err error) {
	if res.HTTP == 503 {
		if res.ErrorCode == "MAINTENANCE" {
			c.Header("Retry-After", "30")
		} else {
			c.Header("Retry-After", "1")
		}
	}
	if res.HTTP >= 400 {
		code := res.ErrorCode
		if code == "" && err != nil {
			code = "ERROR"
		}
		msg := res.ErrorMessage
		if msg == "" && err != nil {
			msg = err.Error()
		}
		c.JSON(res.HTTP, errBody(c, code, msg, res.Retryable))
		return
	}
	conf := []string{}
	for _, id := range res.ConflictIDs {
		conf = append(conf, id.String())
	}
	data := gin.H{
		"operationId": res.OperationID.String(),
		"status":      res.Status,
		"objectId":    res.ObjectID.String(),
		"revision":    strconv.FormatInt(res.Revision, 10),
		"changeSeq":   strconv.FormatInt(res.ChangeSeq, 10),
		"epoch":       s.S.Epoch.String(),
		"conflictIds": conf,
		"receipt":     gin.H{"operationId": res.OperationID.String(), "inputHash": res.ReceiptHash},
		"name":        res.FinalName,
		"parentId":    res.ParentID.String(),
		"replayed":    res.Replayed,
		"snapshot":    res.Snapshot,
	}
	if envOp := c.GetHeader("Idempotency-Key"); envOp != "" {
		data["operationId"] = strings.ToLower(envOp)
		data["receipt"] = gin.H{"operationId": strings.ToLower(envOp), "inputHash": res.ReceiptHash}
	}
	c.JSON(res.HTTP, gin.H{"data": data, "requestId": reqID(c)})
}

func (s *Server) getOp(c *gin.Context) {
	id, err := uuid.Parse(c.Param("operationId"))
	if err != nil {
		c.JSON(404, errBody(c, "NOT_FOUND", "op", false))
		return
	}
	var raw []byte
	var status string
	var objectID uuid.UUID
	err = s.S.Pool.QueryRow(c, `SELECT status, result_json, object_id FROM operations WHERE library_id=$1 AND epoch=$2 AND operation_id=$3`,
		s.S.LibID, s.S.Epoch, id).Scan(&status, &raw, &objectID)
	if err != nil {
		c.JSON(404, errBody(c, "NOT_FOUND", "op", false))
		return
	}
	var gone bool
	err = s.S.Pool.QueryRow(c, `SELECT EXISTS(SELECT 1 FROM tombstones WHERE library_id=$1 AND object_id=$2) OR EXISTS(SELECT 1 FROM objects WHERE library_id=$1 AND id=$2 AND purge_at<=now())`, s.S.LibID, objectID).Scan(&gone)
	if err != nil {
		c.JSON(503, errBody(c, "UNAVAILABLE", "database", true))
		return
	}
	if gone {
		c.JSON(410, errBody(c, "GONE", "expired", false))
		return
	}
	var res synceng.OpResult
	_ = json.Unmarshal(raw, &res)
	c.JSON(200, gin.H{"data": gin.H{"status": status, "operationId": id.String(), "objectId": res.ObjectID.String(), "revision": strconv.FormatInt(res.Revision, 10), "changeSeq": strconv.FormatInt(res.ChangeSeq, 10), "epoch": s.S.Epoch.String(), "snapshot": res.Snapshot, "conflictIds": res.ConflictIDs, "receipt": gin.H{"inputHash": res.ReceiptHash, "operationId": id.String()}}, "requestId": reqID(c)})
}

func (s *Server) getObject(c *gin.Context) {
	id, err := uuid.Parse(c.Param("id"))
	if err != nil {
		c.JSON(404, errBody(c, "NOT_FOUND", "id", false))
		return
	}
	var n int
	_ = s.S.Pool.QueryRow(c, `SELECT 1 FROM tombstones WHERE library_id=$1 AND object_id=$2`, s.S.LibID, id).Scan(&n)
	if n == 1 {
		c.JSON(410, errBody(c, "GONE", "purged", false))
		return
	}
	tx, err := s.S.Pool.Begin(c)
	if err != nil {
		c.JSON(500, errBody(c, "INTERNAL", "tx", false))
		return
	}
	defer tx.Rollback(c)
	obj, err := s.E.LoadPublic(c, tx, id)
	if err != nil {
		if errors.Is(err, synceng.ErrGone) {
			c.JSON(410, errBody(c, "GONE", "expired", false))
			return
		}
		c.JSON(404, errBody(c, "NOT_FOUND", "object", false))
		return
	}
	b, _ := canon.Encode(obj)
	h := sha256.Sum256(b)
	c.JSON(200, gin.H{"data": gin.H{"snapshot": json.RawMessage(b), "hash": hex.EncodeToString(h[:])}, "requestId": reqID(c)})
}

func (s *Server) getRev(c *gin.Context) {
	id, _ := uuid.Parse(c.Param("id"))
	rev, _ := strconv.ParseInt(c.Param("revision"), 10, 64)
	var gone bool
	err := s.S.Pool.QueryRow(c, `SELECT EXISTS(SELECT 1 FROM tombstones WHERE library_id=$1 AND object_id=$2) OR EXISTS(SELECT 1 FROM objects WHERE library_id=$1 AND id=$2 AND purge_at<=now())`, s.S.LibID, id).Scan(&gone)
	if err != nil {
		c.JSON(503, errBody(c, "UNAVAILABLE", "database", true))
		return
	}
	if gone {
		c.JSON(410, errBody(c, "GONE", "expired", false))
		return
	}
	var b []byte
	err = s.S.Pool.QueryRow(c, `SELECT snapshot_bytes FROM revisions WHERE library_id=$1 AND epoch=$2 AND object_id=$3 AND revision=$4`,
		s.S.LibID, s.S.Epoch, id, rev).Scan(&b)
	if err != nil {
		c.JSON(409, errBody(c, "BASE_REQUIRED", "revision missing", false))
		return
	}
	h := sha256.Sum256(b)
	c.JSON(200, gin.H{"data": gin.H{"snapshot": json.RawMessage(b), "hash": hex.EncodeToString(h[:])}, "requestId": reqID(c)})
}

func (s *Server) tombstones(c *gin.Context) {
	var req struct {
		IDs []string `json:"ids"`
	}
	_ = c.BindJSON(&req)
	if len(req.IDs) > 1000 {
		req.IDs = req.IDs[:1000]
	}
	out := []gin.H{}
	for _, sID := range req.IDs {
		id, err := uuid.Parse(sID)
		if err != nil {
			out = append(out, gin.H{"id": sID, "state": "unknown"})
			continue
		}
		var n int
		_ = s.S.Pool.QueryRow(c, `SELECT 1 FROM tombstones WHERE library_id=$1 AND object_id=$2`, s.S.LibID, id).Scan(&n)
		if n == 1 {
			out = append(out, gin.H{"id": sID, "state": "deleted"})
			continue
		}
		_ = s.S.Pool.QueryRow(c, `SELECT 1 FROM objects WHERE id=$1`, id).Scan(&n)
		if n == 1 {
			out = append(out, gin.H{"id": sID, "state": "present"})
		} else {
			out = append(out, gin.H{"id": sID, "state": "unknown"})
		}
	}
	c.JSON(200, gin.H{"data": gin.H{"results": out}, "requestId": reqID(c)})
}

func (s *Server) importMeta(c *gin.Context) {
	c.JSON(200, gin.H{"data": gin.H{
		"libraryId": s.S.LibID.String(), "epoch": s.S.Epoch.String(),
		"limits": gin.H{"pdfBytes": 50000000, "mdBytes": 5000000},
	}, "requestId": reqID(c)})
}

func (s *Server) importFile(c *gin.Context) {
	opID, err := uuid.Parse(c.GetHeader("Idempotency-Key"))
	if err != nil {
		c.JSON(422, errBody(c, "VALIDATION", "Idempotency-Key", false))
		return
	}
	fh, err := c.FormFile("file")
	if err != nil {
		c.JSON(422, errBody(c, "VALIDATION", "file", false))
		return
	}
	kind, mime, ok := names.SplitKindExt(fh.Filename)
	if !ok {
		c.JSON(422, errBody(c, "VALIDATION", "type", false))
		return
	}
	maxSize := int64(50_000_000)
	if kind == "md" {
		maxSize = 5_000_000
	}
	if fh.Size > maxSize {
		c.JSON(413, errBody(c, "TOO_LARGE", "size", false))
		return
	}
	f, err := fh.Open()
	if err != nil {
		c.JSON(500, errBody(c, "INTERNAL", "open", false))
		return
	}
	defer f.Close()
	body, err := io.ReadAll(io.LimitReader(f, maxSize+1))
	if err != nil || int64(len(body)) > maxSize {
		c.JSON(413, errBody(c, "TOO_LARGE", "size", false))
		return
	}
	folderID := s.S.RootID
	if raw := c.PostForm("folderId"); raw != "" {
		folderID, err = uuid.Parse(raw)
		if err != nil {
			c.JSON(422, errBody(c, "VALIDATION", "folderId", false))
			return
		}
	}
	sum := sha256.Sum256(body)
	input, _ := json.Marshal(map[string]any{"filename": fh.Filename, "folderId": folderID.String(), "sha256": hex.EncodeToString(sum[:]), "size": len(body), "kind": kind})
	inputHash := sha256.Sum256(input)
	conn, err := s.S.Pool.Acquire(c)
	if err != nil {
		c.JSON(503, errBody(c, "UNAVAILABLE", "database", true))
		return
	}
	defer conn.Release()
	lockKey := "import:" + opID.String()
	if _, err = conn.Exec(c, `SELECT pg_advisory_lock(hashtextextended($1,0))`, lockKey); err != nil {
		c.JSON(503, errBody(c, "UNAVAILABLE", "import lock", true))
		return
	}
	defer conn.Exec(context.Background(), `SELECT pg_advisory_unlock(hashtextextended($1,0))`, lockKey)
	var existingHash, result []byte
	err = conn.QueryRow(c, `SELECT input_hash,result_json FROM operations WHERE library_id=$1 AND epoch=$2 AND operation_id=$3`, s.S.LibID, s.S.Epoch, opID).Scan(&existingHash, &result)
	if err == nil {
		if !bytes.Equal(existingHash, inputHash[:]) {
			c.JSON(409, errBody(c, "IDEMPOTENCY_MISMATCH", "import bytes or destination changed", false))
			return
		}
		var res synceng.OpResult
		if err = json.Unmarshal(result, &res); err != nil {
			c.JSON(500, errBody(c, "INTERNAL", "receipt", false))
			return
		}
		var gone bool
		if err = conn.QueryRow(c, `SELECT EXISTS(SELECT 1 FROM tombstones WHERE library_id=$1 AND object_id=$2) OR EXISTS(SELECT 1 FROM objects WHERE library_id=$1 AND id=$2 AND purge_at<=now())`, s.S.LibID, res.ObjectID).Scan(&gone); err != nil {
			c.JSON(503, errBody(c, "UNAVAILABLE", "database", true))
			return
		}
		if gone {
			c.JSON(410, errBody(c, "GONE", "expired", false))
			return
		}
		res.Replayed = true
		res.OperationID = opID
		s.writeOp(c, res, nil)
		return
	} else if !errors.Is(err, pgx.ErrNoRows) {
		c.JSON(503, errBody(c, "UNAVAILABLE", "receipt", true))
		return
	}
	objID := uuid.NewSHA1(opID, []byte("import-object"))
	env := synceng.Envelope{ProtocolVersion: 1, OperationID: opID.String(), Epoch: s.S.Epoch.String(), DeviceID: uuid.Nil.String(), ObjectID: objID.String(), DesiredSnapshot: map[string]any{"name": fh.Filename, "parentId": folderID.String(), "autoSuffix": true}}
	if kind == "md" {
		if bytes.Contains(body, []byte{0}) {
			c.JSON(422, errBody(c, "VALIDATION", "nul", false))
			return
		}
		env.Action = "createMarkdown"
		env.DesiredSnapshot["markdownSource"] = string(body)
	} else {
		bid := uuid.NewSHA1(opID, []byte("import-blob"))
		var oldHash []byte
		err = conn.QueryRow(c, `SELECT sha256 FROM blobs WHERE id=$1`, bid).Scan(&oldHash)
		if err == nil && !bytes.Equal(oldHash, sum[:]) {
			c.JSON(409, errBody(c, "IDEMPOTENCY_MISMATCH", "import blob bytes changed", false))
			return
		}
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			c.JSON(503, errBody(c, "UNAVAILABLE", "blob", true))
			return
		}
		dst := store.BlobPath(s.Cfg.DataRoot, bid)
		if err = os.MkdirAll(filepath.Dir(dst), 0750); err != nil {
			c.JSON(500, errBody(c, "INTERNAL", "blob directory", false))
			return
		}
		tmp, err := os.CreateTemp(filepath.Dir(dst), ".import-*")
		if err != nil {
			c.JSON(500, errBody(c, "INTERNAL", "blob temp", false))
			return
		}
		defer os.Remove(tmp.Name())
		if err = tmp.Chmod(0640); err == nil {
			_, err = tmp.Write(body)
		}
		if err == nil {
			err = tmp.Sync()
		}
		closeErr := tmp.Close()
		if err == nil {
			err = closeErr
		}
		if err == nil {
			err = os.Rename(tmp.Name(), dst)
		}
		if err != nil {
			c.JSON(500, errBody(c, "INTERNAL", "blob write", false))
			return
		}
		if _, err = conn.Exec(c, `INSERT INTO blobs(id,library_id,sha256,size,mime,state) VALUES($1,$2,$3,$4,$5,'ready') ON CONFLICT(id) DO UPDATE SET state='ready'`, bid, s.S.LibID, sum[:], len(body), mime); err != nil {
			c.JSON(500, errBody(c, "INTERNAL", "blob record", false))
			return
		}
		env.Action = "createPDF"
		env.DesiredSnapshot["pdfBlobId"] = bid.String()
	}
	res, err := s.E.Apply(c, env, "upload", input)
	if res.HTTP >= 400 {
		s.writeOp(c, res, err)
		return
	}
	c.JSON(201, gin.H{"data": gin.H{"operationId": opID.String(), "objectId": res.ObjectID.String(), "name": res.FinalName, "parentId": res.ParentID.String(), "revision": strconv.FormatInt(res.Revision, 10), "status": res.Status, "snapshot": res.Snapshot}, "requestId": reqID(c)})
}

func (s *Server) importStatus(c *gin.Context) {
	c.Request.URL.Path = "/api/v1/sync/operations/" + c.Param("operationId")
	s.getOp(c)
}

func (s *Server) ws(c *gin.Context) {
	c.JSON(200, gin.H{"data": gin.H{"ok": true, "note": "notifications optional over polling"}, "requestId": reqID(c)})
}

func (s *Server) testBackupBegin(c *gin.Context) {
	_ = s.S.SetMaintenance(c, true)
	c.JSON(200, gin.H{"data": gin.H{"maintenance": true}})
}
func (s *Server) testBackupEnd(c *gin.Context) {
	_ = s.S.SetMaintenance(c, false)
	c.JSON(200, gin.H{"data": gin.H{"maintenance": false}})
}
func (s *Server) testBackupRun(c *gin.Context) {
	if s.J == nil {
		c.JSON(500, errBody(c, "INTERNAL", "jobs", false))
		return
	}
	if err := s.J.RunBackup(c); err != nil {
		c.JSON(500, errBody(c, "INTERNAL", err.Error(), false))
		return
	}
	s.testBackupList(c)
}
func (s *Server) testBackupList(c *gin.Context) {
	rows, err := s.S.Pool.Query(c, `SELECT id, path, state FROM backups ORDER BY snapshot_at DESC LIMIT 5`)
	if err != nil {
		c.JSON(500, errBody(c, "INTERNAL", err.Error(), false))
		return
	}
	defer rows.Close()
	var items []gin.H
	for rows.Next() {
		var id uuid.UUID
		var path, state string
		_ = rows.Scan(&id, &path, &state)
		items = append(items, gin.H{"id": id.String(), "path": path, "state": state})
	}
	if items == nil {
		items = []gin.H{}
	}
	c.JSON(200, gin.H{"data": gin.H{"backups": items}})
}
func (s *Server) testPurge(c *gin.Context) {
	n, err := jobs.PurgeExpired(c, s.S)
	if err != nil {
		c.JSON(500, errBody(c, "INTERNAL", err.Error(), false))
		return
	}
	c.JSON(200, gin.H{"data": gin.H{"purged": n}})
}

func errBody(c *gin.Context, code, msg string, retry bool) gin.H {
	return gin.H{"error": gin.H{"code": code, "message": msg, "retryable": retry}, "requestId": reqID(c)}
}

func reqID(c *gin.Context) string {
	if v := c.GetHeader("X-Request-Id"); v != "" {
		return v
	}
	return uuid.NewString()
}

func nz(s, d string) string {
	if s == "" {
		return d
	}
	return s
}

func (s *Server) unused() {
	_ = context.Background()
	_ = errors.Is
	_ = pgx.ErrNoRows
	_ = jobs.Runner{}
}
