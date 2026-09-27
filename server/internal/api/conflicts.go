package api

import (
	"encoding/json"
	"strconv"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"tokenlibrary/internal/canon"
)

func (s *Server) listConflicts(c *gin.Context) {
	var object any
	if raw := c.Query("objectId"); raw != "" {
		id, err := uuid.Parse(raw)
		if err != nil {
			c.JSON(422, errBody(c, "VALIDATION", "objectId", false))
			return
		}
		object = id
	}
	rows, err := s.S.Pool.Query(c, `SELECT c.id,c.object_id,c.kind,c.status,c.revision,o.revision FROM conflicts c JOIN objects o ON o.id=c.object_id WHERE o.library_id=$1 AND c.status='open' AND ($2::uuid IS NULL OR c.object_id=$2) AND (o.purge_at IS NULL OR o.purge_at>now()) ORDER BY c.id`, s.S.LibID, object)
	if err != nil {
		c.JSON(503, errBody(c, "UNAVAILABLE", "conflicts", true))
		return
	}
	defer rows.Close()
	items := []gin.H{}
	for rows.Next() {
		var id, obj uuid.UUID
		var kind, status string
		var rev, current int64
		if err = rows.Scan(&id, &obj, &kind, &status, &rev, &current); err != nil {
			c.JSON(500, errBody(c, "INTERNAL", "conflict", false))
			return
		}
		items = append(items, gin.H{"id": id.String(), "objectId": obj.String(), "kind": kind, "status": status, "revision": strconv.FormatInt(rev, 10), "currentRevision": strconv.FormatInt(current, 10)})
	}
	if err = rows.Err(); err != nil {
		c.JSON(500, errBody(c, "INTERNAL", "conflicts", false))
		return
	}
	c.JSON(200, gin.H{"data": gin.H{"conflicts": items}, "requestId": reqID(c)})
}

func (s *Server) getConflict(c *gin.Context) {
	id, err := uuid.Parse(c.Param("id"))
	if err != nil {
		c.JSON(404, errBody(c, "NOT_FOUND", "conflict", false))
		return
	}
	var obj uuid.UUID
	var kind, status string
	var rev, current int64
	err = s.S.Pool.QueryRow(c, `SELECT c.object_id,c.kind,c.status,c.revision,o.revision FROM conflicts c JOIN objects o ON o.id=c.object_id WHERE c.id=$1 AND o.library_id=$2 AND (o.purge_at IS NULL OR o.purge_at>now())`, id, s.S.LibID).Scan(&obj, &kind, &status, &rev, &current)
	if err != nil {
		c.JSON(404, errBody(c, "NOT_FOUND", "conflict", false))
		return
	}
	c.JSON(200, gin.H{"data": gin.H{"id": id.String(), "objectId": obj.String(), "kind": kind, "status": status, "revision": strconv.FormatInt(rev, 10), "currentRevision": strconv.FormatInt(current, 10), "materials": []string{"base", "local", "remote"}}, "requestId": reqID(c)})
}

func (s *Server) conflictMaterial(c *gin.Context) {
	id, err := uuid.Parse(c.Param("id"))
	if err != nil {
		c.JSON(404, errBody(c, "NOT_FOUND", "conflict", false))
		return
	}
	var obj uuid.UUID
	var local, baseRef, remoteRef []byte
	err = s.S.Pool.QueryRow(c, `SELECT c.object_id,c.local_snapshot,c.base_ref,c.remote_ref FROM conflicts c JOIN objects o ON o.id=c.object_id WHERE c.id=$1 AND o.library_id=$2 AND (o.purge_at IS NULL OR o.purge_at>now())`, id, s.S.LibID).Scan(&obj, &local, &baseRef, &remoteRef)
	if err != nil {
		c.JSON(404, errBody(c, "NOT_FOUND", "conflict", false))
		return
	}
	role := c.Param("role")
	raw := local
	if role == "base" || role == "remote" {
		ref := baseRef
		if role == "remote" {
			ref = remoteRef
		}
		m, err := canon.Parse(ref)
		if err != nil {
			c.JSON(500, errBody(c, "INTERNAL", "conflict ref", false))
			return
		}
		rev := canon.GetInt64(m, "revision")
		raw = []byte(`{}`)
		if rev > 0 {
			err = s.S.Pool.QueryRow(c, `SELECT snapshot_bytes FROM revisions WHERE library_id=$1 AND epoch=$2 AND object_id=$3 AND revision=$4`, s.S.LibID, s.S.Epoch, obj, rev).Scan(&raw)
			if err != nil {
				c.JSON(409, errBody(c, "BASE_REQUIRED", "conflict material missing", false))
				return
			}
		}
	} else if role != "local" {
		c.JSON(404, errBody(c, "NOT_FOUND", "role", false))
		return
	}
	c.JSON(200, gin.H{"data": gin.H{"role": role, "bytes": json.RawMessage(raw), "snapshot": json.RawMessage(raw)}, "requestId": reqID(c)})
}
