package api

import (
	"encoding/json"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

func (s *Server) changes(c *gin.Context) {
	after, err := strconv.ParseInt(c.DefaultQuery("after", "0"), 10, 64)
	if err != nil || after < 0 {
		c.JSON(422, errBody(c, "VALIDATION", "after", false))
		return
	}
	if ep := c.GetHeader("X-Library-Epoch"); ep != "" && ep != s.S.Epoch.String() {
		c.JSON(409, errBody(c, "EPOCH_CHANGED", "epoch", false))
		return
	}
	tx, err := s.S.Pool.BeginTx(c, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		c.JSON(503, errBody(c, "UNAVAILABLE", "database", true))
		return
	}
	defer tx.Rollback(c)
	var latest int64
	if err = tx.QueryRow(c, `SELECT change_seq FROM libraries WHERE id=$1`, s.S.LibID).Scan(&latest); err != nil {
		c.JSON(503, errBody(c, "UNAVAILABLE", "database", true))
		return
	}
	if after > latest {
		c.JSON(409, errBody(c, "CURSOR_INVALID", "start a new snapshot", false))
		return
	}
	limit := pageLimit(c)
	rows, err := tx.Query(c, `SELECT seq,event_manifest FROM (
		SELECT seq,event_manifest FROM changes WHERE library_id=$1 AND epoch=$2 AND seq>$3 AND seq<=$4
		UNION ALL
		SELECT purge_seq AS seq,jsonb_build_object('objects','[]'::jsonb,'deletedIds',jsonb_agg(object_id::text ORDER BY object_id))
		FROM tombstones t WHERE library_id=$1 AND purge_seq>$3 AND purge_seq<=$4
		AND NOT EXISTS(SELECT 1 FROM changes c WHERE c.library_id=$1 AND c.epoch=$2 AND c.seq=t.purge_seq)
		GROUP BY purge_seq
	) events ORDER BY seq LIMIT $5`, s.S.LibID, s.S.Epoch, after, latest, limit+1)
	if err != nil {
		c.JSON(503, errBody(c, "UNAVAILABLE", "changes", true))
		return
	}
	type event struct {
		seq      int64
		manifest map[string]any
	}
	events := []event{}
	for rows.Next() {
		var ev event
		var raw []byte
		if err = rows.Scan(&ev.seq, &raw); err != nil {
			rows.Close()
			c.JSON(500, errBody(c, "INTERNAL", "changes", false))
			return
		}
		if err = json.Unmarshal(raw, &ev.manifest); err != nil {
			rows.Close()
			c.JSON(500, errBody(c, "INTERNAL", "manifest", false))
			return
		}
		events = append(events, ev)
	}
	rows.Close()
	if err = rows.Err(); err != nil {
		c.JSON(500, errBody(c, "INTERNAL", "changes", false))
		return
	}
	more := len(events) > limit
	if more {
		events = events[:limit]
	}
	items := []gin.H{}
	next := after
	for _, ev := range events {
		objects := []any{}
		deleted := []string{}
		if ids, ok := ev.manifest["deletedIds"].([]any); ok {
			for _, raw := range ids {
				if id, ok := raw.(string); ok {
					deleted = append(deleted, id)
				}
			}
		}
		if listed, ok := ev.manifest["objects"].([]any); ok {
			for _, raw := range listed {
				item, ok := raw.(map[string]any)
				if !ok {
					continue
				}
				id, err := uuid.Parse(stringValue(item["id"]))
				if err != nil {
					c.JSON(500, errBody(c, "INTERNAL", "object reference", false))
					return
				}
				var purgeAt *time.Time
				err = tx.QueryRow(c, `SELECT purge_at FROM objects WHERE id=$1 AND library_id=$2`, id, s.S.LibID).Scan(&purgeAt)
				if err == pgx.ErrNoRows || purgeAt != nil && !purgeAt.After(time.Now()) {
					deleted = append(deleted, id.String())
					continue
				}
				if err != nil {
					c.JSON(503, errBody(c, "UNAVAILABLE", "object", true))
					return
				}
				if _, ok := item["snapshot"].(map[string]any); !ok {
					snap, err := s.E.LoadPublic(c, tx, id)
					if err != nil {
						c.JSON(500, errBody(c, "INTERNAL", "object", false))
						return
					}
					item["snapshot"] = snap
					item["revision"] = snap["revision"]
				}
				objects = append(objects, item)
			}
		}
		ev.manifest["objects"] = objects
		ev.manifest["deletedIds"] = deleted
		items = append(items, gin.H{"seq": strconv.FormatInt(ev.seq, 10), "manifest": ev.manifest, "objects": objects, "deletedIds": deleted})
		next = ev.seq
	}
	// Old databases can contain sequence gaps (e.g. historical purge operations).
	if !more {
		next = latest
	}
	c.JSON(200, gin.H{"data": gin.H{"changes": items, "nextCursor": strconv.FormatInt(next, 10), "hasMore": more, "latestSeq": strconv.FormatInt(latest, 10), "epoch": s.S.Epoch.String()}, "requestId": reqID(c)})
}

func stringValue(v any) string { s, _ := v.(string); return s }
