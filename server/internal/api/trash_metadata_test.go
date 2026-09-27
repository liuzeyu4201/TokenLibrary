package api_test

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/google/uuid"
)

func TestTrashedMetadataPreservesRetentionAndRelations(t *testing.T) {
	f := newSyncFixture(t)
	folder, child, active := uuid.NewString(), uuid.NewString(), uuid.NewString()
	f.op("createFolder", folder, 0, map[string]any{"name": "deleted sources", "parentId": f.root}, nil)
	f.note(active, "active.md", "active body", map[string]any{"relatedIDs": []string{child}})
	f.op("createMarkdown", child, 0, map[string]any{"name": "child.md", "parentId": folder, "markdownSource": "retained source", "metadata": map[string]any{"relatedIDs": []string{active}, "title": "keep title"}}, nil)
	f.op("trash", folder, 0, map[string]any{}, nil)
	read := func(id string) map[string]any {
		return snapshotOf(t, f.decode(get(t, f.url+"/api/v1/objects/"+id, f.token, f.epoch), 200))
	}
	retention := func() string {
		var value string
		err := f.s.Pool.QueryRow(context.Background(), `SELECT json_build_array(parent_id,original_parent_id,deleted_at,purge_at,trash_batch_id)::text FROM objects WHERE id=$1`, child).Scan(&value)
		if err != nil {
			t.Fatal(err)
		}
		return value
	}
	before := read(child)
	beforeRetention := retention()
	f.op("updateDocument", active, 1, map[string]any{"metadata": map[string]any{"relatedIDs": []string{}}}, nil)
	// The client sends the public snapshot's original parent, although both
	// that parent and the child are now in the recycle bin.
	desired := read(child)
	desired["metadata"].(map[string]any)["relatedIDs"] = []any{}
	result, operation, wire := f.op("updateDocument", child, 2, desired, nil)
	after := read(child)
	if after["state"] != "trashed" || after["parentId"] != folder || after["name"] != "child.md" || after["markdownSource"] != "retained source" || after["purgeAt"] != before["purgeAt"] || after["trashBatchId"] != before["trashBatchId"] {
		t.Fatalf("metadata cleanup changed deleted material: %#v", after)
	}
	if retention() != beforeRetention {
		t.Fatal("metadata cleanup changed physical parent or retention")
	}
	metadata := after["metadata"].(map[string]any)
	if len(metadata["relatedIDs"].([]any)) != 0 || metadata["title"] != "keep title" {
		t.Fatalf("cleanup lost metadata: %#v", metadata)
	}
	replay := f.decode(post(t, f.url+"/api/v1/sync/operations", wire, f.token, f.epoch, operation), 200)
	if replay["replayed"] != true || replay["changeSeq"] != result["changeSeq"] {
		t.Fatal("cleanup was not idempotent")
	}
	// Omitting parentId must also preserve the public original parent.
	f.op("updateDocument", child, 3, map[string]any{"metadata": map[string]any{"relatedIDs": []any{}, "title": "new title"}}, nil)
	if read(child)["parentId"] != folder || retention() != beforeRetention {
		t.Fatal("metadata-only update changed trash identity")
	}
	f.op("restore", folder, 0, map[string]any{}, nil)
	for _, id := range []string{child, active} {
		snapshot := read(id)
		if snapshot["state"] != "active" || len(snapshot["metadata"].(map[string]any)["relatedIDs"].([]any)) != 0 {
			t.Fatalf("restore revived removed relationship: %#v", snapshot)
		}
	}
}

func TestTrashedMetadataCannotMoveRenameOrRestore(t *testing.T) {
	f := newSyncFixture(t)
	folder, child := uuid.NewString(), uuid.NewString()
	f.op("createFolder", folder, 0, map[string]any{"name": "deleted folder", "parentId": f.root}, nil)
	f.op("createMarkdown", child, 0, map[string]any{"name": "source.md", "parentId": folder, "markdownSource": "keep"}, nil)
	f.op("trash", folder, 0, map[string]any{}, nil)
	for _, tc := range []struct {
		action  string
		desired map[string]any
	}{
		{"move", map[string]any{"parentId": f.root}},
		{"rename", map[string]any{"name": "changed.md"}},
		{"updateDocument", map[string]any{"parentId": f.root}},
		{"updateDocument", map[string]any{"name": "changed.md"}},
		{"updateDocument", map[string]any{"parentId": "invalid"}},
	} {
		op := uuid.NewString()
		raw, _ := json.Marshal(map[string]any{"protocolVersion": 1, "operationId": op, "epoch": f.epoch, "deviceId": f.device, "objectId": child, "action": tc.action, "base": map[string]any{"source": "revision", "revision": 2}, "desiredSnapshot": tc.desired})
		f.decode(post(t, f.url+"/api/v1/sync/operations", string(raw), f.token, f.epoch, op), 422)
	}
	// A desired active state must not bypass the dedicated restore operation.
	f.op("updateDocument", child, 2, map[string]any{"state": "active", "parentId": folder, "metadata": map[string]any{"relatedIDs": []any{}}}, nil)
	snapshot := snapshotOf(t, f.decode(get(t, f.url+"/api/v1/objects/"+child, f.token, f.epoch), 200))
	if snapshot["state"] != "trashed" || snapshot["parentId"] != folder || snapshot["name"] != "source.md" || snapshot["purgeAt"] == nil {
		t.Fatalf("metadata edit restored or moved deleted material: %#v", snapshot)
	}
}
