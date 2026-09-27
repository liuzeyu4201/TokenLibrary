package api

import (
	"crypto/sha256"
	"encoding/json"
	"errors"
	"io"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

func pageLimit(c *gin.Context) int {
	n, _ := strconv.Atoi(c.DefaultQuery("limit", "100"))
	if n < 1 || n > 100 {
		n = 100
	}
	return n
}

func (s *Server) createSnapshot(c *gin.Context) {
	var req struct {
		Limit int `json:"limit"`
	}
	if c.Request.Body != nil {
		if err := json.NewDecoder(io.LimitReader(c.Request.Body, 4096)).Decode(&req); err != nil && !errors.Is(err, io.EOF) {
			c.JSON(422, errBody(c, "VALIDATION", "body", false))
			return
		}
	}
	if req.Limit < 1 || req.Limit > 100 {
		req.Limit = 100
	}
	tx, err := s.S.Pool.Begin(c)
	if err != nil {
		c.JSON(503, errBody(c, "UNAVAILABLE", "database", true))
		return
	}
	defer tx.Rollback(c)
	epoch, seq, _, err := s.S.LockLibrary(c, tx)
	if err != nil {
		c.JSON(503, errBody(c, "UNAVAILABLE", "database", true))
		return
	}
	if header := c.GetHeader("X-Library-Epoch"); header != "" && header != epoch.String() {
		c.JSON(409, errBody(c, "EPOCH_CHANGED", "epoch", false))
		return
	}
	id := uuid.New()
	expires := time.Now().UTC().Add(time.Hour)
	if _, err = tx.Exec(c, `INSERT INTO sync_snapshots(id,library_id,epoch,at_seq,expires_at,state) VALUES($1,$2,$3,$4,$5,'ready')`, id, s.S.LibID, epoch, seq, expires); err != nil {
		c.JSON(500, errBody(c, "INTERNAL", "snapshot", false))
		return
	}
	rows, err := tx.Query(c, `SELECT id FROM objects WHERE library_id=$1 AND (purge_at IS NULL OR purge_at>now()) ORDER BY id`, s.S.LibID)
	if err != nil {
		c.JSON(500, errBody(c, "INTERNAL", "objects", false))
		return
	}
	ids := []uuid.UUID{}
	for rows.Next() {
		var oid uuid.UUID
		if err = rows.Scan(&oid); err != nil {
			rows.Close()
			c.JSON(500, errBody(c, "INTERNAL", "objects", false))
			return
		}
		ids = append(ids, oid)
	}
	rows.Close()
	if err = rows.Err(); err != nil {
		c.JSON(500, errBody(c, "INTERNAL", "objects", false))
		return
	}
	for i, oid := range ids {
		snap, err := s.E.LoadPublic(c, tx, oid)
		if err != nil {
			c.JSON(500, errBody(c, "INTERNAL", "object snapshot", false))
			return
		}
		raw, err := json.Marshal(snap)
		if err != nil {
			c.JSON(500, errBody(c, "INTERNAL", "snapshot encoding", false))
			return
		}
		hash := sha256.Sum256(raw)
		rev, _ := strconv.ParseInt(snap["revision"].(string), 10, 64)
		if _, err = tx.Exec(c, `INSERT INTO sync_snapshot_items(snapshot_id,item_id,kind,revision_ref,frozen_content,hash,ordinal) VALUES($1,$2,$3,$4,$5,$6,$7)`, id, oid, snap["kind"], rev, raw, hash[:], i+1); err != nil {
			c.JSON(500, errBody(c, "INTERNAL", "snapshot item", false))
			return
		}
	}
	if err = tx.Commit(c); err != nil {
		c.JSON(503, errBody(c, "UNAVAILABLE", "snapshot commit", true))
		return
	}
	s.snapshotPage(c, id, 0, req.Limit)
}

func (s *Server) getSnapshot(c *gin.Context) {
	id, err := uuid.Parse(c.Param("id"))
	if err != nil {
		c.JSON(404, errBody(c, "NOT_FOUND", "snapshot", false))
		return
	}
	after, err := strconv.ParseInt(c.DefaultQuery("after", "0"), 10, 64)
	if err != nil || after < 0 {
		c.JSON(422, errBody(c, "VALIDATION", "after", false))
		return
	}
	s.snapshotPage(c, id, after, pageLimit(c))
}

func (s *Server) snapshotPage(c *gin.Context, id uuid.UUID, after int64, limit int) {
	var epoch uuid.UUID
	var seq int64
	var expires time.Time
	var state string
	err := s.S.Pool.QueryRow(c, `SELECT epoch,at_seq,expires_at,state FROM sync_snapshots WHERE id=$1 AND library_id=$2`, id, s.S.LibID).Scan(&epoch, &seq, &expires, &state)
	if errors.Is(err, pgx.ErrNoRows) {
		c.JSON(404, errBody(c, "NOT_FOUND", "snapshot", false))
		return
	}
	if err != nil {
		c.JSON(503, errBody(c, "UNAVAILABLE", "snapshot", true))
		return
	}
	if state != "ready" || !expires.After(time.Now()) {
		c.JSON(410, errBody(c, "SNAPSHOT_EXPIRED", "start a new snapshot", false))
		return
	}
	if epoch != s.S.Epoch {
		c.JSON(409, errBody(c, "EPOCH_CHANGED", "epoch", false))
		return
	}
	rows, err := s.S.Pool.Query(c, `SELECT i.ordinal,i.item_id,i.revision_ref,i.frozen_content FROM sync_snapshot_items i JOIN objects o ON o.id=i.item_id WHERE i.snapshot_id=$1 AND i.ordinal>$2 AND (o.purge_at IS NULL OR o.purge_at>now()) ORDER BY i.ordinal LIMIT $3`, id, after, limit+1)
	if err != nil {
		c.JSON(503, errBody(c, "UNAVAILABLE", "snapshot items", true))
		return
	}
	defer rows.Close()
	items := []gin.H{}
	next := after
	more := false
	pageBytes := 0
	for rows.Next() {
		var ordinal, revision int64
		var oid uuid.UUID
		var raw []byte
		if err = rows.Scan(&ordinal, &oid, &revision, &raw); err != nil {
			c.JSON(500, errBody(c, "INTERNAL", "snapshot item", false))
			return
		}
		if len(items) == limit || len(items) > 0 && pageBytes+len(raw) > 16<<20 {
			more = true
			break
		}
		items = append(items, gin.H{"id": oid.String(), "revision": strconv.FormatInt(revision, 10), "snapshot": json.RawMessage(raw)})
		pageBytes += len(raw)
		next = ordinal
	}
	if err = rows.Err(); err != nil {
		c.JSON(500, errBody(c, "INTERNAL", "snapshot item", false))
		return
	}
	c.JSON(200, gin.H{"data": gin.H{"snapshotId": id.String(), "libraryId": s.S.LibID.String(), "rootId": s.S.RootID.String(), "epoch": epoch.String(), "atSeq": strconv.FormatInt(seq, 10), "expiresAt": expires.Format(time.RFC3339Nano), "items": items, "nextCursor": strconv.FormatInt(next, 10), "hasMore": more}, "requestId": reqID(c)})
}
