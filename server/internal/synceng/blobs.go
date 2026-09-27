package synceng

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

func (e *Engine) validateSnapshot(ctx context.Context, tx pgx.Tx, kind string, snap map[string]any) error {
	metadata, ok := snap["metadata"].(map[string]any)
	if !ok {
		return fmt.Errorf("metadata must be an object")
	}
	raw, err := json.Marshal(metadata)
	if err != nil || len(raw) > 256*1024 {
		return fmt.Errorf("metadata exceeds 256 KiB")
	}
	if kind == "md" {
		body, ok := snap["markdownSource"].(string)
		if !ok || len(body) > 5_000_000 {
			return fmt.Errorf("markdown exceeds 5 MB")
		}
	}
	if kind == "pdf" {
		if id, ok := snap["pdfBlobId"].(string); !ok || id == "" {
			return fmt.Errorf("pdfBlobId required")
		}
	}
	// A repeated ID inside one document is invalid, whereas another document
	// may intentionally retain that ID when recovering or importing a copy.
	annotationIDs := map[uuid.UUID]bool{}
	if annotations, ok := snap["annotations"].([]any); ok {
		for _, raw := range annotations {
			annotation, _ := raw.(map[string]any)
			id, _ := uuid.Parse(fmt.Sprint(annotation["id"]))
			if id == uuid.Nil {
				id, _ = uuid.Parse(fmt.Sprint(annotation["annotationId"]))
			}
			if id == uuid.Nil {
				continue // Preserve the legacy generated-ID behavior.
			}
			if annotationIDs[id] {
				return fmt.Errorf("duplicate annotation ID within document: %s", id)
			}
			annotationIDs[id] = true
		}
	}
	refs, err := snapshotBlobRefs(snap)
	if err != nil {
		return err
	}
	for _, id := range refs {
		var ready bool
		if err := tx.QueryRow(ctx, `SELECT state='ready' FROM blobs WHERE id=$1 AND library_id=$2`, id, e.S.LibID).Scan(&ready); err != nil || !ready {
			return fmt.Errorf("blob %s is not ready", id)
		}
	}
	return nil
}

func snapshotBlobRefs(snap map[string]any) (map[string]uuid.UUID, error) {
	out := map[string]uuid.UUID{}
	add := func(slot string, raw any) error {
		if raw == nil || raw == "" {
			return nil
		}
		s, ok := raw.(string)
		if !ok {
			return fmt.Errorf("invalid blob reference")
		}
		id, err := uuid.Parse(s)
		if err != nil {
			return fmt.Errorf("invalid blob UUID")
		}
		out[slot] = id
		return nil
	}
	if err := add("pdf", snap["pdfBlobId"]); err != nil {
		return nil, err
	}
	if raw, exists := snap["assets"]; exists && raw != nil {
		assets, ok := raw.([]any)
		if !ok {
			return nil, fmt.Errorf("assets must be an array")
		}
		for i, raw := range assets {
			asset, ok := raw.(map[string]any)
			if !ok {
				return nil, fmt.Errorf("invalid asset")
			}
			blob := asset["blobId"]
			if blob == nil {
				blob = asset["id"]
			}
			if blob == nil {
				return nil, fmt.Errorf("asset blobId required")
			}
			if err := add("asset:"+strconv.Itoa(i), blob); err != nil {
				return nil, err
			}
		}
	}
	if anns, ok := snap["annotations"].([]any); ok {
		for i, raw := range anns {
			if ann, ok := raw.(map[string]any); ok {
				if err := add("annotation:"+strconv.Itoa(i), ann["pdfBlobId"]); err != nil {
					return nil, err
				}
			}
		}
	}
	return out, nil
}

func (e *Engine) setBlobRefs(ctx context.Context, tx pgx.Tx, ownerKind string, owner uuid.UUID, snap map[string]any) error {
	refs, err := snapshotBlobRefs(snap)
	if err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM blob_refs WHERE owner_kind=$1 AND owner_id=$2`, ownerKind, owner); err != nil {
		return err
	}
	for slot, id := range refs {
		if _, err := tx.Exec(ctx, `INSERT INTO blob_refs(blob_id,owner_kind,owner_id,slot) VALUES($1,$2,$3,$4)`, id, ownerKind, owner, slot); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE blobs SET unreferenced_at=NULL WHERE id=$1`, id); err != nil {
			return err
		}
	}
	return nil
}
