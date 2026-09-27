package merge

import "testing"

func TestMetadataMergeIndependentNestedFields(t *testing.T) {
	base := map[string]any{"type": "paper", "reading": map[string]any{"page": 1, "progress": 0.1}, "source": "A"}
	local := map[string]any{"type": "paper", "reading": map[string]any{"page": 2, "progress": 0.1}, "source": "A"}
	remote := map[string]any{"type": "paper", "reading": map[string]any{"page": 1, "progress": 0.5}, "source": "B"}
	value, conflict := MergeMetadata(base, local, remote)
	if conflict {
		t.Fatal("independent fields conflicted")
	}
	got := value.(map[string]any)
	reading := got["reading"].(map[string]any)
	if reading["page"] != 2 || reading["progress"] != 0.5 || got["source"] != "B" {
		t.Fatalf("lost metadata: %#v", got)
	}
}

func TestMetadataConflictingFieldAndDeletion(t *testing.T) {
	base := map[string]any{"title": "base", "removed": "x"}
	local := map[string]any{"title": "left"}
	remote := map[string]any{"title": "right", "removed": "x"}
	value, conflict := MergeMetadata(base, local, remote)
	if !conflict {
		t.Fatal("different edits to title must conflict")
	}
	if _, exists := value.(map[string]any)["removed"]; exists {
		t.Fatal("uncontested deletion was lost")
	}
}

func TestMarkdownSingleSideEditPreservesBytes(t *testing.T) {
	for _, source := range []string{"without newline", "with newline\n", "\n\ntext\n\n"} {
		got, conflict, err := MergeMarkdown("old", source, "old")
		if err != nil || conflict || got != source {
			t.Fatalf("source modified: %q -> %q", source, got)
		}
	}
}

func TestMetadataNullIsDistinctFromDeletion(t *testing.T) {
	base := map[string]any{"key": "old", "other": "old"}
	local := map[string]any{"key": nil, "other": "old"}
	remote := map[string]any{"key": "old", "other": "new"}
	value, conflict := MergeMetadata(base, local, remote)
	got := value.(map[string]any)
	if _, present := got["key"]; !present || got["key"] != nil || conflict {
		t.Fatalf("explicit null lost: %#v conflict=%v", got, conflict)
	}
	_, conflict = MergeMetadata(base, map[string]any{"other": "old"}, local)
	if !conflict {
		t.Fatal("deletion against explicit null must conflict")
	}
}

func TestAnnotationDeleteAgainstEditConflicts(t *testing.T) {
	base := []any{map[string]any{"id": "one", "text": "before"}}
	edited := []any{map[string]any{"id": "one", "text": "after"}}
	for _, pair := range [][2]any{{[]any{}, edited}, {edited, []any{}}} {
		_, conflict := mergeAnnotations(base, pair[0], pair[1])
		if !conflict {
			t.Fatal("concurrent annotation deletion/edit was silently accepted")
		}
	}
	got, conflict := mergeAnnotations(base, []any{}, base)
	if conflict || len(got.([]any)) != 0 {
		t.Fatal("uncontested annotation delete failed")
	}
}

func TestMetadataIndependentReadingPositionsAndExcerpts(t *testing.T) {
	base := map[string]any{"readingPositions": []any{}, "excerpts": []any{}}
	local := map[string]any{"readingPositions": []any{map[string]any{"deviceID": "mac", "pageIndex": 4}}, "excerpts": []any{map[string]any{"id": "left", "text": "left quote"}}}
	remote := map[string]any{"readingPositions": []any{map[string]any{"deviceID": "phone", "pageIndex": 8}}, "excerpts": []any{map[string]any{"id": "right", "text": "right quote"}}}
	value, conflict := MergeMetadata(base, local, remote)
	got := value.(map[string]any)
	if conflict || len(got["readingPositions"].([]any)) != 2 || len(got["excerpts"].([]any)) != 2 {
		t.Fatalf("independent records lost: %#v conflict=%v", got, conflict)
	}
	base = map[string]any{"readingPositions": []any{map[string]any{"deviceID": "mac", "pageIndex": 1}}}
	local = map[string]any{"readingPositions": []any{map[string]any{"deviceID": "mac", "pageIndex": 4}}}
	remote = map[string]any{"readingPositions": []any{map[string]any{"deviceID": "mac", "pageIndex": 8}}}
	_, conflict = MergeMetadata(base, local, remote)
	if !conflict {
		t.Fatal("same device competing page changes must conflict")
	}
	_, conflict = MergeMetadata(base, map[string]any{"readingPositions": []any{}}, local)
	if !conflict {
		t.Fatal("record deletion against edit must conflict")
	}
}
