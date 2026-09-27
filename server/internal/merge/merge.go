package merge

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"tokenlibrary/internal/canon"
)

type FieldConflict struct {
	Field  string
	Base   any
	Local  any
	Remote any
}

type Result struct {
	Merged   map[string]any
	Conflict bool
	Fields   []FieldConflict
	Text     string
}

func ThreeWayScalar(base, local, remote any) (any, bool) {
	if equalJSON(local, remote) {
		return local, false
	}
	if equalJSON(local, base) {
		return remote, false
	}
	if equalJSON(remote, base) {
		return local, false
	}
	return nil, true
}

func equalJSON(a, b any) bool {
	ab, _ := canon.Encode(a)
	bb, _ := canon.Encode(b)
	return bytes.Equal(ab, bb)
}

var fenced = regexp.MustCompile("(?s)```[ \t]*([a-zA-Z0-9_-]+)[ \t]*\n.*?```")
var mathBlock = regexp.MustCompile("(?s)\\$\\$.*?\\$\\$")

func ProtectBlocks(src string) (string, []string) {
	var blocks []string
	out := fenced.ReplaceAllStringFunc(src, func(m string) string {
		lang := ""
		if i := strings.Index(m, "\n"); i > 0 {
			header := strings.TrimSpace(strings.TrimPrefix(m[:i], "```"))
			lang = strings.ToLower(header)
		}
		if lang == "mermaid" || strings.HasPrefix(m, "```mermaid") {
			idx := len(blocks)
			blocks = append(blocks, m)
			return fmt.Sprintf("\n%%TLBLOCK%d%%\n", idx)
		}
		return m
	})
	out = mathBlock.ReplaceAllStringFunc(out, func(m string) string {
		idx := len(blocks)
		blocks = append(blocks, m)
		return fmt.Sprintf("\n%%TLBLOCK%d%%\n", idx)
	})
	return out, blocks
}

func RestoreBlocks(src string, blocks []string) string {
	for i, b := range blocks {
		src = strings.ReplaceAll(src, fmt.Sprintf("%%TLBLOCK%d%%", i), b)
	}
	return src
}

func MergeMarkdown(base, local, remote string) (string, bool, error) {
	// Preserve exact source when no actual merge is needed (including trailing
	// newlines and block formatting). Paragraph normalization is only a fallback.
	if local == remote {
		return local, false, nil
	}
	if local == base {
		return remote, false, nil
	}
	if remote == base {
		return local, false, nil
	}
	bProt, _ := ProtectBlocks(base)
	lProt, lBlocks := ProtectBlocks(local)
	rProt, rBlocks := ProtectBlocks(remote)
	mergedProt, paraConflict := mergeParagraphs(bProt, lProt, rProt)
	blocksConflict := blockConflict(base, local, remote)
	if !paraConflict && !blocksConflict {
		return RestoreBlocks(mergedProt, pickBlocks(lBlocks, rBlocks)), false, nil
	}
	if blocksConflict {
		gitOut, gitConflict, err := gitMergeFile(bProt, lProt, rProt)
		if err != nil {
			return RestoreBlocks(mergedProt, pickBlocks(lBlocks, rBlocks)), true, nil
		}
		return RestoreBlocks(gitOut, pickBlocks(lBlocks, rBlocks)), true || gitConflict, nil
	}
	// Paragraph-level conflict: still try git merge-file in case it can auto-merge.
	gitOut, gitConflict, err := gitMergeFile(bProt, lProt, rProt)
	if err == nil && !gitConflict {
		return RestoreBlocks(gitOut, pickBlocks(lBlocks, rBlocks)), false, nil
	}
	if !paraConflict {
		return RestoreBlocks(mergedProt, pickBlocks(lBlocks, rBlocks)), false, nil
	}
	return RestoreBlocks(mergedProt, pickBlocks(lBlocks, rBlocks)), true, nil
}

func splitParas(s string) []string {
	s = strings.ReplaceAll(s, "\r\n", "\n")
	s = strings.TrimSpace(s)
	if s == "" {
		return nil
	}
	parts := regexp.MustCompile(`\n{2,}`).Split(s, -1)
	var out []string
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}

func joinParas(ps []string) string {
	if len(ps) == 0 {
		return ""
	}
	return strings.Join(ps, "\n\n") + "\n"
}

func alignExact(base, side []string) []int {
	used := make([]bool, len(side))
	out := make([]int, len(base))
	for i, p := range base {
		out[i] = -1
		for j := 0; j < len(side); j++ {
			if !used[j] && side[j] == p {
				used[j] = true
				out[i] = j
				break
			}
		}
	}
	return out
}

func nextMatch(idx []int, from int) int {
	for i := from; i < len(idx); i++ {
		if idx[i] >= 0 {
			return idx[i]
		}
	}
	return -1
}

func mergeParagraphs(base, local, remote string) (string, bool) {
	b := splitParas(base)
	l := splitParas(local)
	r := splitParas(remote)
	if len(b) == 0 && len(l) == 0 {
		return joinParas(r), false
	}
	if len(b) == 0 && len(r) == 0 {
		return joinParas(l), false
	}
	lAl := alignExact(b, l)
	rAl := alignExact(b, r)
	var out []string
	li, ri := 0, 0
	seen := map[string]bool{}
	emit := func(p string) {
		if p == "" || seen[p] {
			return
		}
		seen[p] = true
		out = append(out, p)
	}
	for bi := 0; bi <= len(b); bi++ {
		lEnd, rEnd := len(l), len(r)
		if bi < len(b) {
			if n := nextMatch(lAl, bi); n >= 0 {
				lEnd = n
			} else if lAl[bi] >= 0 {
				lEnd = lAl[bi]
			}
			if n := nextMatch(rAl, bi); n >= 0 {
				rEnd = n
			} else if rAl[bi] >= 0 {
				rEnd = rAl[bi]
			}
		}
		if lEnd < li {
			lEnd = li
		}
		if rEnd < ri {
			rEnd = ri
		}
		lGap := []string{}
		rGap := []string{}
		if li < lEnd && lEnd <= len(l) {
			lGap = l[li:lEnd]
		}
		if ri < rEnd && rEnd <= len(r) {
			rGap = r[ri:rEnd]
		}
		baseMatchedL := bi < len(b) && lAl[bi] >= 0
		baseMatchedR := bi < len(b) && rAl[bi] >= 0
		bothGaps := len(lGap) > 0 && len(rGap) > 0
		if bothGaps {
			if equalStringSlice(lGap, rGap) {
				for _, p := range lGap {
					emit(p)
				}
			} else if !baseMatchedL && !baseMatchedR && bi < len(b) {
				// both replaced the same original paragraph
				return joinParas(append(out, lGap...)), true
			} else {
				// independent insertions
				for _, p := range lGap {
					emit(p)
				}
				for _, p := range rGap {
					emit(p)
				}
			}
		} else {
			for _, p := range lGap {
				emit(p)
			}
			for _, p := range rGap {
				emit(p)
			}
		}
		if bi < len(b) {
			switch {
			case baseMatchedL && baseMatchedR:
				emit(b[bi])
				li = lAl[bi] + 1
				ri = rAl[bi] + 1
			case baseMatchedL && !baseMatchedR:
				// remote edited/deleted; local kept original — take remote gap already emitted; drop original
				li = lAl[bi] + 1
				ri = rEnd
			case !baseMatchedL && baseMatchedR:
				ri = rAl[bi] + 1
				li = lEnd
			default:
				li = lEnd
				ri = rEnd
			}
		} else {
			li = len(l)
			ri = len(r)
		}
	}
	return joinParas(out), false
}

func equalStringSlice(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func conflictProtected(b, l, r []string) bool { return false }

func conflictProtectedFromText(base, local, remote string) bool {
	return blockConflict(base, local, remote)
}

func extractSpecial(src string) []string {
	var out []string
	for _, m := range fenced.FindAllString(src, -1) {
		if strings.Contains(strings.SplitN(m, "\n", 2)[0], "mermaid") {
			out = append(out, m)
		}
	}
	out = append(out, mathBlock.FindAllString(src, -1)...)
	return out
}

func blockConflict(base, local, remote string) bool {
	lb := extractSpecial(local)
	rb := extractSpecial(remote)
	bb := extractSpecial(base)
	n := max(len(lb), len(rb), len(bb))
	for i := 0; i < n; i++ {
		var b, l, r string
		if i < len(bb) {
			b = bb[i]
		}
		if i < len(lb) {
			l = lb[i]
		}
		if i < len(rb) {
			r = rb[i]
		}
		if l != r && l != b && r != b && l != "" && r != "" {
			return true
		}
	}
	return false
}

func pickBlocks(l, r []string) []string {
	if len(l) >= len(r) {
		return l
	}
	return r
}

func gitMergeFile(base, local, remote string) (string, bool, error) {
	dir, err := os.MkdirTemp("", "tl-merge-*")
	if err != nil {
		return "", true, err
	}
	defer os.RemoveAll(dir)
	_ = os.Chmod(dir, 0700)
	write := func(name, body string) error {
		p := filepath.Join(dir, name)
		return os.WriteFile(p, []byte(body), 0600)
	}
	if err := write("base", base); err != nil {
		return "", true, err
	}
	if err := write("local", local); err != nil {
		return "", true, err
	}
	if err := write("remote", remote); err != nil {
		return "", true, err
	}
	cmd := exec.Command("git", "merge-file", "--diff3", "--diff-algorithm=histogram",
		filepath.Join(dir, "local"), filepath.Join(dir, "base"), filepath.Join(dir, "remote"))
	cmd.Env = []string{"GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null", "HOME=" + dir}
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	err = cmd.Run()
	out, _ := os.ReadFile(filepath.Join(dir, "local"))
	if err == nil {
		return string(out), false, nil
	}
	if ee, ok := err.(*exec.ExitError); ok {
		code := ee.ExitCode()
		if code >= 1 && code <= 127 {
			return string(out), true, nil
		}
		return "", true, fmt.Errorf("merge-file failed: %s", stderr.String())
	}
	return "", true, err
}

func MergeSnapshots(base, local, remote map[string]any) Result {
	res := Result{Merged: map[string]any{}}
	keys := map[string]struct{}{}
	for _, m := range []map[string]any{base, local, remote} {
		for k := range m {
			keys[k] = struct{}{}
		}
	}
	textConflict := false
	for k := range keys {
		if k == "metadata" {
			merged, c := MergeMetadata(base[k], local[k], remote[k])
			res.Merged[k] = merged
			if c {
				res.Conflict = true
				res.Fields = append(res.Fields, FieldConflict{Field: k, Base: base[k], Local: local[k], Remote: remote[k]})
			}
			continue
		}
		if k == "markdownSource" {
			bs := fmt.Sprint(nilToEmpty(base[k]))
			ls := fmt.Sprint(nilToEmpty(local[k]))
			rs := fmt.Sprint(nilToEmpty(remote[k]))
			merged, c, err := MergeMarkdown(bs, ls, rs)
			if err != nil {
				res.Conflict = true
				res.Fields = append(res.Fields, FieldConflict{Field: k, Base: base[k], Local: local[k], Remote: remote[k]})
				res.Merged[k] = local[k]
				continue
			}
			res.Merged[k] = merged
			if c {
				textConflict = true
				res.Fields = append(res.Fields, FieldConflict{Field: k, Base: base[k], Local: local[k], Remote: remote[k]})
			}
			continue
		}
		if k == "annotations" {
			merged, c := mergeAnnotations(base[k], local[k], remote[k])
			res.Merged[k] = merged
			if c {
				res.Conflict = true
				res.Fields = append(res.Fields, FieldConflict{Field: k, Base: base[k], Local: local[k], Remote: remote[k]})
			}
			continue
		}
		v, c := ThreeWayScalar(base[k], local[k], remote[k])
		if c {
			res.Conflict = true
			res.Fields = append(res.Fields, FieldConflict{Field: k, Base: base[k], Local: local[k], Remote: remote[k]})
			res.Merged[k] = local[k]
			continue
		}
		res.Merged[k] = v
	}
	if textConflict {
		res.Conflict = true
	}
	return res
}

func nilToEmpty(v any) string {
	if v == nil {
		return ""
	}
	if s, ok := v.(string); ok {
		return s
	}
	return fmt.Sprint(v)
}

func mergeAnnotations(base, local, remote any) (any, bool) {
	bm := indexAnns(base)
	lm := indexAnns(local)
	rm := indexAnns(remote)
	ids := map[string]struct{}{}
	for k := range bm {
		ids[k] = struct{}{}
	}
	for k := range lm {
		ids[k] = struct{}{}
	}
	for k := range rm {
		ids[k] = struct{}{}
	}
	var out []any
	conflict := false
	ordered := make([]string, 0, len(ids))
	for id := range ids {
		ordered = append(ordered, id)
	}
	sort.Strings(ordered)
	for _, id := range ordered {
		b, hb := bm[id]
		l, hl := lm[id]
		r, hr := rm[id]
		switch {
		case hl && hr && equalJSON(l, r):
			out = append(out, l)
		case hl && !hr && equalJSON(l, b):
			// remote deleted, local unchanged -> delete
		case hr && !hl && equalJSON(r, b):
			// local deleted
		case !hb && hl && !hr:
			out = append(out, l)
		case !hb && hr && !hl:
			out = append(out, r)
		case hl && hr:
			v, c := ThreeWayScalar(b, l, r)
			if c {
				conflict = true
				out = append(out, l)
			} else if v != nil {
				out = append(out, v)
			}
		case hl:
			conflict = conflict || hb // local edit against a remote deletion
			out = append(out, l)
		case hr:
			conflict = conflict || hb // remote edit against a local deletion
			out = append(out, r)
		}
		_ = hb
	}
	return out, conflict
}

// MergeMetadata merges independent nested fields. Arrays are atomic except
// readingPositions/deviceID and excerpts/id, which have stable record identities.
func MergeMetadata(base, local, remote any) (any, bool) {
	if v, conflict := ThreeWayScalar(base, local, remote); !conflict {
		return v, false
	}
	b, bok := base.(map[string]any)
	l, lok := local.(map[string]any)
	r, rok := remote.(map[string]any)
	if base == nil {
		b, bok = map[string]any{}, true
	}
	if !bok || !lok || !rok {
		return local, true
	}
	keys := map[string]bool{}
	for _, m := range []map[string]any{b, l, r} {
		for k := range m {
			keys[k] = true
		}
	}
	out := map[string]any{}
	conflict := false
	for k := range keys {
		_, hasB := b[k]
		_, hasL := l[k]
		_, hasR := r[k]
		// Presence is part of a JSON value: deleting a key differs from null.
		switch {
		case hasL == hasR && equalJSON(l[k], r[k]):
			if hasL {
				out[k] = l[k]
			}
		case hasL == hasB && equalJSON(l[k], b[k]):
			if hasR {
				out[k] = r[k]
			}
		case hasR == hasB && equalJSON(r[k], b[k]):
			if hasL {
				out[k] = l[k]
			}
		case !hasL || !hasR:
			conflict = true
			if hasL {
				out[k] = l[k]
			}
		default:
			var v any
			var c bool
			if k == "readingPositions" {
				v, c = mergeMetadataRecords(b[k], l[k], r[k], "deviceID")
			} else if k == "excerpts" {
				v, c = mergeMetadataRecords(b[k], l[k], r[k], "id")
			} else {
				v, c = MergeMetadata(b[k], l[k], r[k])
			}
			conflict = conflict || c
			out[k] = v
		}
	}
	return out, conflict
}

// Device reading positions and excerpts have stable identities. Independent
// devices/records can advance together without treating the whole array as one
// scalar. Malformed or duplicate identities remain an explicit conflict.
func mergeMetadataRecords(base, local, remote any, identity string) (any, bool) {
	index := func(raw any) (map[string]any, bool) {
		out := map[string]any{}
		if raw == nil {
			return out, true
		}
		array, ok := raw.([]any)
		if !ok {
			return nil, false
		}
		for _, rawRecord := range array {
			record, ok := rawRecord.(map[string]any)
			if !ok {
				return nil, false
			}
			id, ok := record[identity].(string)
			if !ok || id == "" {
				return nil, false
			}
			if _, duplicate := out[id]; duplicate {
				return nil, false
			}
			out[id] = record
		}
		return out, true
	}
	b, bok := index(base)
	l, lok := index(local)
	r, rok := index(remote)
	if !bok || !lok || !rok {
		return local, true
	}
	value, conflict := MergeMetadata(b, l, r)
	merged := value.(map[string]any)
	ids := make([]string, 0, len(merged))
	for id := range merged {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	out := make([]any, 0, len(ids))
	for _, id := range ids {
		out = append(out, merged[id])
	}
	return out, conflict
}

func indexAnns(v any) map[string]any {
	m := map[string]any{}
	arr, _ := v.([]any)
	for _, e := range arr {
		em, _ := e.(map[string]any)
		if em == nil {
			continue
		}
		id, _ := em["id"].(string)
		if id == "" {
			id, _ = em["annotationId"].(string)
		}
		if id != "" {
			m[id] = e
		}
	}
	return m
}

func max(a ...int) int {
	m := 0
	for _, v := range a {
		if v > m {
			m = v
		}
	}
	return m
}

// Keep unused import for potential timeout wrapper.
var _ = time.Second
