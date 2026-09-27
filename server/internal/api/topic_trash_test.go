package api_test

import (
	"fmt"
	"testing"

	"github.com/google/uuid"
)

func TestDeletingTopicPreservesPhysicalChildrenAndPublishesMoves(t *testing.T) {
	f := newSyncFixture(t)
	topic, child, folder, nested, prior := uuid.NewString(), uuid.NewString(), uuid.NewString(), uuid.NewString(), uuid.NewString()
	f.op("createFolder", topic, 0, map[string]any{"parentId": f.root, "name": "研究专题", "metadata": map[string]any{"category": "topic"}}, nil)
	// This is the last state known to a deleting/older client. The children below
	// arrive afterwards and must be protected by the server, without client moves.
	stale := snapshotOf(t, f.decode(get(t, f.url+"/api/v1/objects/"+topic, f.token, f.epoch), 200))
	f.note(uuid.NewString(), "paper.md", "keep existing parent document", nil)
	f.op("createMarkdown", child, 0, map[string]any{"parentId": topic, "name": "Paper.md", "markdownSource": "new child", "metadata": map[string]any{"topicIDs": []string{topic}}}, nil)
	f.op("createFolder", folder, 0, map[string]any{"parentId": topic, "name": "章节"}, nil)
	f.op("createMarkdown", nested, 0, map[string]any{"parentId": folder, "name": "chapter.md", "markdownSource": "nested source"}, nil)
	f.op("createMarkdown", prior, 0, map[string]any{"parentId": topic, "name": "already-deleted.md", "markdownSource": "earlier trash"}, nil)
	f.op("trash", prior, 0, map[string]any{}, nil)
	priorBefore := snapshotOf(t, f.decode(get(t, f.url+"/api/v1/objects/"+prior, f.token, f.epoch), 200))
	meta := f.decode(get(t, f.url+"/api/v1/meta", f.token, f.epoch), 200)
	beforeSeq := meta["latestSeq"].(string)
	result, opID, wire := f.op("trash", topic, 1, stale, nil)
	if snapshotOf(t, result)["state"] != "trashed" {
		t.Fatal("topic not trashed")
	}
	for id, expected := range map[string]struct{ parent, name, revision string }{
		child: {f.root, "Paper_1.md", "2"}, folder: {f.root, "章节", "2"}, nested: {folder, "chapter.md", "1"},
	} {
		snapshot := snapshotOf(t, f.decode(get(t, f.url+"/api/v1/objects/"+id, f.token, f.epoch), 200))
		if snapshot["state"] != "active" || snapshot["parentId"] != expected.parent || snapshot["name"] != expected.name || snapshot["revision"] != expected.revision || snapshot["purgeAt"] != nil {
			t.Fatalf("child was lost or not rehomed correctly: %#v", snapshot)
		}
	}
	priorAfter := snapshotOf(t, f.decode(get(t, f.url+"/api/v1/objects/"+prior, f.token, f.epoch), 200))
	if priorAfter["revision"] != priorBefore["revision"] || priorAfter["trashBatchId"] != priorBefore["trashBatchId"] {
		t.Fatal("topic deletion changed an independently deleted child")
	}
	changes := f.decode(get(t, f.url+"/api/v1/sync/changes?after="+beforeSeq, f.token, f.epoch), 200)["changes"].([]any)
	if len(changes) != 1 {
		t.Fatalf("want one atomic event, got %d", len(changes))
	}
	objects := changes[0].(map[string]any)["objects"].([]any)
	seen := map[string]bool{}
	for _, value := range objects {
		seen[value.(map[string]any)["id"].(string)] = true
	}
	if len(seen) != 3 || !seen[topic] || !seen[child] || !seen[folder] {
		t.Fatalf("incremental event omitted moved objects: %#v", seen)
	}
	// A lost response replays the same receipt; it must not move or rename again.
	replay := f.decode(post(t, f.url+"/api/v1/sync/operations", wire, f.token, f.epoch, opID), 200)
	if replay["changeSeq"] != result["changeSeq"] || replay["replayed"] != true {
		t.Fatal("topic operation did not replay")
	}
	// An offline child's body edit based on the pre-move revision must retain its
	// rescued parent/name, rather than moving the document into the deleted topic.
	f.op("updateDocument", child, 1, map[string]any{"markdownSource": "offline edit"}, nil)
	updated := snapshotOf(t, f.decode(get(t, f.url+"/api/v1/objects/"+child, f.token, f.epoch), 200))
	if updated["parentId"] != f.root || updated["markdownSource"] != "offline edit" {
		t.Fatalf("offline edit lost rescued placement: %#v", updated)
	}
}

func TestOrdinaryFolderTrashStillIncludesNestedTopics(t *testing.T) {
	f := newSyncFixture(t)
	outer, topic, child := uuid.NewString(), uuid.NewString(), uuid.NewString()
	f.op("createFolder", outer, 0, map[string]any{"parentId": f.root, "name": "physical folder"}, nil)
	f.op("createFolder", topic, 0, map[string]any{"parentId": outer, "name": "nested topic", "metadata": map[string]any{"category": "topic"}}, nil)
	f.op("createMarkdown", child, 0, map[string]any{"parentId": topic, "name": "note.md", "markdownSource": "content"}, nil)
	result, _, _ := f.op("trash", outer, 0, map[string]any{}, nil)
	batch := snapshotOf(t, result)["trashBatchId"]
	for _, id := range []string{topic, child} {
		snapshot := snapshotOf(t, f.decode(get(t, fmt.Sprintf("%s/api/v1/objects/%s", f.url, id), f.token, f.epoch), 200))
		if snapshot["state"] != "trashed" || snapshot["trashBatchId"] != batch {
			t.Fatalf("ordinary recursive trash changed: %#v", snapshot)
		}
	}
}
