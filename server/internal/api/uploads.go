package api

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"tokenlibrary/internal/store"
)

const uploadChunkSize = 1048576

func (s *Server) writeGuard(c *gin.Context) {
	if !s.S.Writes.TryRLock() {
		maintenance, err := s.S.Ready(c)
		code, message, retryAfter := "BUSY", "short write contention", "1"
		if err != nil {
			code, message = "UNAVAILABLE", "database"
		} else if maintenance {
			code, message, retryAfter = "MAINTENANCE", "cloud writes paused", "30"
		}
		c.Header("Retry-After", retryAfter)
		c.AbortWithStatusJSON(503, errBody(c, code, message, true))
		return
	}
	defer s.S.Writes.RUnlock()
	maintenance, err := s.S.Ready(c)
	if err != nil {
		c.Header("Retry-After", "1")
		c.AbortWithStatusJSON(503, errBody(c, "UNAVAILABLE", "database", true))
		return
	}
	if maintenance {
		c.Header("Retry-After", "30")
		c.AbortWithStatusJSON(503, errBody(c, "MAINTENANCE", "cloud writes paused", true))
		return
	}
	c.Next()
}

func (s *Server) createUpload(c *gin.Context) {
	var req struct {
		BlobID string `json:"blobId"`
		Size   int64  `json:"size"`
		SHA256 string `json:"sha256"`
		Mime   string `json:"mime"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(422, errBody(c, "VALIDATION", "body", false))
		return
	}
	bid, err := uuid.Parse(req.BlobID)
	if err != nil {
		c.JSON(422, errBody(c, "VALIDATION", "blobId", false))
		return
	}
	hash, err := hex.DecodeString(req.SHA256)
	if err != nil || len(hash) != 32 {
		c.JSON(422, errBody(c, "VALIDATION", "sha256", false))
		return
	}
	maxSize := int64(50_000_000)
	if strings.HasPrefix(req.Mime, "image/") {
		maxSize = 20_000_000
	}
	if req.Size <= 0 || req.Size > maxSize {
		c.JSON(413, errBody(c, "TOO_LARGE", "size must be positive and within the file limit", false))
		return
	}
	if req.Mime == "" || len(req.Mime) > 128 || strings.ContainsAny(req.Mime, "\r\n") {
		c.JSON(422, errBody(c, "VALIDATION", "mime", false))
		return
	}
	tx, err := s.S.Pool.Begin(c)
	if err != nil {
		c.JSON(503, errBody(c, "UNAVAILABLE", "database", true))
		return
	}
	defer tx.Rollback(c)
	// Serialize creation/recovery against another request with the same blob ID.
	if _, err = tx.Exec(c, `SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, bid.String()); err != nil {
		c.JSON(500, errBody(c, "INTERNAL", "upload lock", false))
		return
	}
	var state string
	var oldHash []byte
	var oldSize int64
	var oldMime string
	err = tx.QueryRow(c, `SELECT state,sha256,size,mime FROM blobs WHERE id=$1 AND library_id=$2`, bid, s.S.LibID).Scan(&state, &oldHash, &oldSize, &oldMime)
	if err == nil {
		if oldSize != req.Size || !bytes.Equal(oldHash, hash) || oldMime != req.Mime {
			c.JSON(409, errBody(c, "IDEMPOTENCY_MISMATCH", "blobId belongs to different bytes", false))
			return
		}
	} else if errors.Is(err, pgx.ErrNoRows) {
		if _, err = tx.Exec(c, `INSERT INTO blobs(id,library_id,sha256,size,mime,state) VALUES($1,$2,$3,$4,$5,'staging')`, bid, s.S.LibID, hash, req.Size, req.Mime); err != nil {
			c.JSON(409, errBody(c, "EXISTS", "blob", false))
			return
		}
	} else {
		c.JSON(503, errBody(c, "UNAVAILABLE", "blob", true))
		return
	}
	sess := c.MustGet("session").(sessionInfo)
	var uid uuid.UUID
	var expires time.Time
	var uploadState string
	err = tx.QueryRow(c, `SELECT id,expires_at,state FROM uploads WHERE blob_id=$1 AND library_id=$2 AND epoch=$3 AND owner_id=$4 AND (expires_at>now() OR state='complete') ORDER BY expires_at DESC LIMIT 1`, bid, s.S.LibID, s.S.Epoch, sess.DeviceID).Scan(&uid, &expires, &uploadState)
	if errors.Is(err, pgx.ErrNoRows) {
		uid = uuid.New()
		expires = time.Now().UTC().Add(24 * time.Hour)
		uploadState = "open"
		if state == "ready" {
			uploadState = "complete"
		}
		if _, err = tx.Exec(c, `INSERT INTO uploads(id,library_id,epoch,owner_kind,owner_id,blob_id,expected_size,expected_hash,mime,state,expires_at) VALUES($1,$2,$3,'device',$4,$5,$6,$7,$8,$9,$10)`, uid, s.S.LibID, s.S.Epoch, sess.DeviceID, bid, req.Size, hash, req.Mime, uploadState, expires); err != nil {
			c.JSON(500, errBody(c, "INTERNAL", "upload", false))
			return
		}
	} else if err != nil {
		c.JSON(503, errBody(c, "UNAVAILABLE", "upload", true))
		return
	}
	if err = tx.Commit(c); err != nil {
		c.JSON(503, errBody(c, "UNAVAILABLE", "upload commit", true))
		return
	}
	c.JSON(200, gin.H{"data": gin.H{"uploadId": uid.String(), "blobId": bid.String(), "state": uploadState, "chunkSize": uploadChunkSize, "expiresAt": expires.UTC().Format(time.RFC3339Nano)}, "requestId": reqID(c)})
}

type uploadRecord struct {
	ID, Blob    uuid.UUID
	Size        int64
	Hash        []byte
	Mime, State string
	Expires     time.Time
}

func (s *Server) loadUpload(c *gin.Context, tx pgx.Tx, id uuid.UUID, lock bool) (uploadRecord, bool) {
	u := uploadRecord{ID: id}
	sess := c.MustGet("session").(sessionInfo)
	query := `SELECT blob_id,expected_size,expected_hash,mime,state,expires_at FROM uploads WHERE id=$1 AND library_id=$2 AND epoch=$3 AND owner_id=$4`
	if lock {
		query += " FOR UPDATE"
	}
	err := tx.QueryRow(c, query, id, s.S.LibID, s.S.Epoch, sess.DeviceID).Scan(&u.Blob, &u.Size, &u.Hash, &u.Mime, &u.State, &u.Expires)
	if err != nil {
		c.JSON(404, errBody(c, "NOT_FOUND", "upload", false))
		return u, false
	}
	if u.State != "complete" && !u.Expires.After(time.Now()) {
		c.JSON(410, errBody(c, "UPLOAD_EXPIRED", "restart upload", false))
		return u, false
	}
	return u, true
}

func (s *Server) getUpload(c *gin.Context) {
	id, err := uuid.Parse(c.Param("id"))
	if err != nil {
		c.JSON(404, errBody(c, "NOT_FOUND", "upload", false))
		return
	}
	tx, err := s.S.Pool.Begin(c)
	if err != nil {
		c.JSON(503, errBody(c, "UNAVAILABLE", "database", true))
		return
	}
	defer tx.Rollback(c)
	u, ok := s.loadUpload(c, tx, id, false)
	if !ok {
		return
	}
	rows, err := tx.Query(c, `SELECT chunk_index FROM upload_chunks WHERE upload_id=$1 ORDER BY chunk_index`, id)
	if err != nil {
		c.JSON(503, errBody(c, "UNAVAILABLE", "chunks", true))
		return
	}
	defer rows.Close()
	indices := []int{}
	for rows.Next() {
		var idx int
		if err = rows.Scan(&idx); err != nil {
			c.JSON(500, errBody(c, "INTERNAL", "chunk", false))
			return
		}
		indices = append(indices, idx)
	}
	if err = rows.Err(); err != nil {
		c.JSON(500, errBody(c, "INTERNAL", "chunks", false))
		return
	}
	c.JSON(200, gin.H{"data": gin.H{"uploadId": id.String(), "blobId": u.Blob.String(), "state": u.State, "chunks": indices, "chunkSize": uploadChunkSize, "expiresAt": u.Expires.UTC().Format(time.RFC3339Nano)}, "requestId": reqID(c)})
}

func (s *Server) putChunk(c *gin.Context) {
	id, err := uuid.Parse(c.Param("id"))
	if err != nil {
		c.JSON(404, errBody(c, "NOT_FOUND", "upload", false))
		return
	}
	idx, err := strconv.Atoi(c.Param("index"))
	if err != nil || idx < 0 {
		c.JSON(422, errBody(c, "VALIDATION", "chunk index", false))
		return
	}
	tx, err := s.S.Pool.Begin(c)
	if err != nil {
		c.JSON(503, errBody(c, "UNAVAILABLE", "database", true))
		return
	}
	defer tx.Rollback(c)
	u, ok := s.loadUpload(c, tx, id, true)
	if !ok {
		return
	}
	if u.State != "open" {
		c.JSON(409, errBody(c, "UPLOAD_COMPLETE", "upload already complete", false))
		return
	}
	expected := int64(uploadChunkSize)
	remaining := u.Size - int64(idx)*uploadChunkSize
	if remaining <= 0 {
		c.JSON(422, errBody(c, "VALIDATION", "chunk index out of range", false))
		return
	}
	if remaining < expected {
		expected = remaining
	}
	body, err := io.ReadAll(io.LimitReader(c.Request.Body, expected+1))
	if err != nil || int64(len(body)) != expected {
		c.JSON(422, errBody(c, "VALIDATION", "chunk size", false))
		return
	}
	sum := sha256.Sum256(body)
	if want := c.GetHeader("X-Chunk-SHA256"); want != "" && !strings.EqualFold(want, hex.EncodeToString(sum[:])) {
		c.JSON(409, errBody(c, "HASH_MISMATCH", "chunk", false))
		return
	}
	p := store.StagingPath(s.Cfg.DataRoot, id, idx)
	if err = os.MkdirAll(filepath.Dir(p), 0750); err != nil {
		c.JSON(500, errBody(c, "INTERNAL", "staging directory", false))
		return
	}
	if err = os.WriteFile(p+".tmp", body, 0640); err != nil {
		c.JSON(500, errBody(c, "INTERNAL", "chunk write", false))
		return
	}
	if err = os.Rename(p+".tmp", p); err != nil {
		c.JSON(500, errBody(c, "INTERNAL", "chunk publish", false))
		return
	}
	if _, err = tx.Exec(c, `INSERT INTO upload_chunks(upload_id,chunk_index,size,sha256,relative_path) VALUES($1,$2,$3,$4,$5) ON CONFLICT(upload_id,chunk_index) DO UPDATE SET size=EXCLUDED.size,sha256=EXCLUDED.sha256,relative_path=EXCLUDED.relative_path`, id, idx, len(body), sum[:], p); err != nil {
		c.JSON(500, errBody(c, "INTERNAL", "chunk record", false))
		return
	}
	if err = tx.Commit(c); err != nil {
		c.JSON(503, errBody(c, "UNAVAILABLE", "chunk commit", true))
		return
	}
	c.JSON(200, gin.H{"data": gin.H{"index": idx}, "requestId": reqID(c)})
}

func (s *Server) completeUpload(c *gin.Context) {
	id, err := uuid.Parse(c.Param("id"))
	if err != nil {
		c.JSON(404, errBody(c, "NOT_FOUND", "upload", false))
		return
	}
	tx, err := s.S.Pool.Begin(c)
	if err != nil {
		c.JSON(503, errBody(c, "UNAVAILABLE", "database", true))
		return
	}
	defer tx.Rollback(c)
	u, ok := s.loadUpload(c, tx, id, true)
	if !ok {
		return
	}
	if u.State == "complete" {
		c.JSON(200, gin.H{"data": gin.H{"blobId": u.Blob.String(), "state": "ready"}, "requestId": reqID(c)})
		return
	}
	rows, err := tx.Query(c, `SELECT chunk_index,relative_path FROM upload_chunks WHERE upload_id=$1 ORDER BY chunk_index`, id)
	if err != nil {
		c.JSON(503, errBody(c, "UNAVAILABLE", "chunks", true))
		return
	}
	paths := []string{}
	for rows.Next() {
		var idx int
		var path string
		if err = rows.Scan(&idx, &path); err != nil {
			rows.Close()
			c.JSON(500, errBody(c, "INTERNAL", "chunk", false))
			return
		}
		if idx != len(paths) {
			rows.Close()
			c.JSON(422, errBody(c, "VALIDATION", "missing chunk", false))
			return
		}
		paths = append(paths, path)
	}
	rows.Close()
	if err = rows.Err(); err != nil {
		c.JSON(500, errBody(c, "INTERNAL", "chunks", false))
		return
	}
	if int64(len(paths)) != (u.Size+uploadChunkSize-1)/uploadChunkSize {
		c.JSON(422, errBody(c, "VALIDATION", "missing chunk", false))
		return
	}
	dst := store.BlobPath(s.Cfg.DataRoot, u.Blob)
	if err = os.MkdirAll(filepath.Dir(dst), 0750); err != nil {
		c.JSON(500, errBody(c, "INTERNAL", "blob directory", false))
		return
	}
	f, err := os.CreateTemp(filepath.Dir(dst), ".upload-*")
	if err != nil {
		c.JSON(500, errBody(c, "INTERNAL", "blob staging", false))
		return
	}
	defer os.Remove(f.Name())
	defer f.Close()
	if err = f.Chmod(0640); err != nil {
		c.JSON(500, errBody(c, "INTERNAL", "blob mode", false))
		return
	}
	hash := sha256.New()
	written := int64(0)
	for _, path := range paths {
		if err = c.Request.Context().Err(); err != nil {
			return
		}
		part, err := os.Open(path)
		if err != nil {
			c.JSON(422, errBody(c, "VALIDATION", "missing chunk file", false))
			return
		}
		n, err := io.Copy(io.MultiWriter(f, hash), part)
		part.Close()
		written += n
		if err != nil {
			c.JSON(500, errBody(c, "INTERNAL", "blob assembly", false))
			return
		}
	}
	if written != u.Size || !bytes.Equal(hash.Sum(nil), u.Hash) {
		c.JSON(422, errBody(c, "HASH_MISMATCH", "blob size or sha256", false))
		return
	}
	if err = f.Sync(); err != nil {
		c.JSON(500, errBody(c, "INTERNAL", "blob sync", false))
		return
	}
	if err = f.Close(); err != nil {
		c.JSON(500, errBody(c, "INTERNAL", "blob close", false))
		return
	}
	if err = os.Rename(f.Name(), dst); err != nil {
		c.JSON(500, errBody(c, "INTERNAL", "blob publish", false))
		return
	}
	if _, err = tx.Exec(c, `UPDATE blobs SET state='ready' WHERE id=$1`, u.Blob); err != nil {
		c.JSON(500, errBody(c, "INTERNAL", "blob record", false))
		return
	}
	if _, err = tx.Exec(c, `UPDATE uploads SET state='complete' WHERE id=$1`, id); err != nil {
		c.JSON(500, errBody(c, "INTERNAL", "upload record", false))
		return
	}
	if err = tx.Commit(c); err != nil {
		c.JSON(503, errBody(c, "UNAVAILABLE", "upload commit", true))
		return
	}
	_ = os.RemoveAll(filepath.Join(s.Cfg.DataRoot, "files", "staging", id.String()))
	c.JSON(200, gin.H{"data": gin.H{"blobId": u.Blob.String(), "state": "ready", "sha256": hex.EncodeToString(u.Hash), "size": u.Size}, "requestId": reqID(c)})
}

func (s *Server) getBlob(c *gin.Context) {
	id, err := uuid.Parse(c.Param("id"))
	if err != nil {
		c.JSON(404, errBody(c, "NOT_FOUND", "blob", false))
		return
	}
	var state, mime string
	var hash []byte
	err = s.S.Pool.QueryRow(c, `SELECT state,sha256,mime FROM blobs WHERE id=$1 AND library_id=$2`, id, s.S.LibID).Scan(&state, &hash, &mime)
	if err != nil || state != "ready" {
		c.JSON(404, errBody(c, "NOT_FOUND", "blob", false))
		return
	}
	c.Header("ETag", fmt.Sprintf(`"%s"`, hex.EncodeToString(hash)))
	c.Header("X-Content-SHA256", hex.EncodeToString(hash))
	c.Header("Accept-Ranges", "bytes")
	c.Header("Content-Type", mime)
	c.Header("X-Content-Type-Options", "nosniff")
	http.ServeFile(c.Writer, c.Request, store.BlobPath(s.Cfg.DataRoot, id))
}
