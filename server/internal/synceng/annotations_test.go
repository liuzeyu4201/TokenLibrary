package synceng

import "testing"

func TestPDFReplacementPreservesAnnotationBinding(t *testing.T) {
	old := map[string]any{"id": "annotation", "placementState": "attached"}
	snapshot := map[string]any{"kind": "pdf", "pdfBlobId": "new", "annotations": []any{old, map[string]any{"id": "new-annotation", "pdfBlobId": "new"}}}
	bindAnnotations(snapshot, "old")
	annotations := snapshot["annotations"].([]any)
	first := annotations[0].(map[string]any)
	if first["pdfBlobId"] != "old" || first["placementState"] != "needs_review" {
		t.Fatalf("old annotation silently attached to new PDF: %#v", first)
	}
	second := annotations[1].(map[string]any)
	if second["placementState"] != "attached" {
		t.Fatal("new PDF annotation should stay attached")
	}
	if old["pdfBlobId"] != nil || old["placementState"] != "attached" {
		t.Fatal("mutated base annotation during normalization")
	}
}
