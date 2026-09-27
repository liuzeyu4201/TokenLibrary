package merge

import "testing"

func TestCompatibleEOFParagraphAdds(t *testing.T) {
	base := "# 三方合并\n\n```mermaid\ngraph TD\n  A-->B\n```\n\n$n+1$\n\n$$a+b$$\n"
	local := base + "\nphone paragraph\n"
	remote := base + "\nmac paragraph\n"
	out, conflict, err := MergeMarkdown(base, local, remote)
	if err != nil {
		t.Fatal(err)
	}
	if conflict {
		t.Fatalf("expected auto merge, got conflict: %s", out)
	}
	if !contains(out, "phone paragraph") || !contains(out, "mac paragraph") {
		t.Fatalf("lost an edit: %s", out)
	}
}

func TestCompatibleParagraphsMerge(t *testing.T) {
	base := "hello\n\nworld\n"
	local := "hello from phone\n\nworld\n"
	remote := "hello\n\nworld from mac\n"
	out, conflict, err := MergeMarkdown(base, local, remote)
	if err != nil {
		t.Fatal(err)
	}
	if conflict {
		t.Fatalf("expected auto merge, got conflict: %s", out)
	}
	if !contains(out, "hello from phone") || !contains(out, "world from mac") {
		t.Fatalf("lost an edit: %s", out)
	}
}

func TestSameLineConflict(t *testing.T) {
	base := "alpha\n"
	local := "alpha-local\n"
	remote := "alpha-remote\n"
	out, conflict, err := MergeMarkdown(base, local, remote)
	if err != nil {
		t.Fatal(err)
	}
	if !conflict {
		t.Fatalf("expected conflict, got: %s", out)
	}
}

func TestMermaidWholeBlockConflict(t *testing.T) {
	base := "intro\n\n```mermaid\ngraph TD\n  A-->B\n```\n"
	local := "intro\n\n```mermaid\ngraph TD\n  A-->C\n```\n"
	remote := "intro\n\n```mermaid\ngraph TD\n  A-->D\n```\n"
	_, conflict, err := MergeMarkdown(base, local, remote)
	if err != nil {
		t.Fatal(err)
	}
	if !conflict {
		t.Fatal("expected mermaid block conflict")
	}
}

func TestFormulaBlockConflict(t *testing.T) {
	base := "n\n\n$$a+b$$\n"
	local := "n\n\n$$a+c$$\n"
	remote := "n\n\n$$a+d$$\n"
	_, conflict, err := MergeMarkdown(base, local, remote)
	if err != nil {
		t.Fatal(err)
	}
	if !conflict {
		t.Fatal("expected formula block conflict")
	}
}

func TestAnnotationAddMerge(t *testing.T) {
	base := map[string]any{"annotations": []any{}}
	local := map[string]any{"annotations": []any{map[string]any{"id": "11111111-1111-1111-1111-111111111111", "type": "highlight", "text": "a"}}}
	remote := map[string]any{"annotations": []any{map[string]any{"id": "22222222-2222-2222-2222-222222222222", "type": "comment", "text": "b"}}}
	r := MergeSnapshots(base, local, remote)
	if r.Conflict {
		t.Fatal("adds should merge")
	}
	arr, _ := r.Merged["annotations"].([]any)
	if len(arr) != 2 {
		t.Fatalf("want 2 anns, got %d", len(arr))
	}
}

func TestPDFReplaceConflict(t *testing.T) {
	base := map[string]any{"pdfBlobId": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}
	local := map[string]any{"pdfBlobId": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"}
	remote := map[string]any{"pdfBlobId": "cccccccc-cccc-cccc-cccc-cccccccccccc"}
	r := MergeSnapshots(base, local, remote)
	if !r.Conflict {
		t.Fatal("replace should conflict")
	}
}

func contains(s, sub string) bool {
	return len(s) >= len(sub) && (s == sub || len(sub) == 0 || (len(s) > 0 && (stringIndex(s, sub) >= 0)))
}

func stringIndex(s, sub string) int {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}
