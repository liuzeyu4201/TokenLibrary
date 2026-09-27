package jobs

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"tokenlibrary/internal/store"
	"tokenlibrary/internal/synceng"
)

// This adds a real media/catalog corpus to the smaller byte-level roundtrip.
// It intentionally remains a storage/engine integration test, not native UI.
func TestMediaCatalogAndOpenConflictSurviveRealBackupRestore(t *testing.T) {
	s, cfg, root := localPG(t)
	ctx := context.Background()
	engine := &synceng.Engine{S: s}
	pdfBytes := readableFixturePDF()
	pngBuffer := &bytes.Buffer{}
	im := image.NewRGBA(image.Rect(0, 0, 8, 8))
	for x := 0; x < 8; x++ {
		for y := 0; y < 8; y++ {
			im.Set(x, y, color.RGBA{R: 120, G: uint8(y * 30), B: uint8(x * 30), A: 255})
		}
	}
	must(t, png.Encode(pngBuffer, im))
	pdfBlob := seedMediaBlob(t, s, pdfBytes, "application/pdf")
	imageBlob := seedMediaBlob(t, s, pngBuffer.Bytes(), "image/png")
	topicA, topicB, paper, note := uuid.New(), uuid.New(), uuid.New(), uuid.New()
	apply := func(action string, id uuid.UUID, revision int64, desired map[string]any) synceng.OpResult {
		t.Helper()
		env := synceng.Envelope{ProtocolVersion: 1, OperationID: uuid.NewString(), Epoch: s.Epoch.String(), DeviceID: uuid.NewString(), ObjectID: id.String(), Action: action, DesiredSnapshot: desired}
		if revision > 0 {
			env.Base = &synceng.BaseRef{Source: "revision", Revision: revision}
		}
		raw, err := json.Marshal(env)
		must(t, err)
		result, err := engine.Apply(ctx, env, "client", raw)
		must(t, err)
		if result.HTTP >= 400 {
			t.Fatalf("fixture operation failed: %#v", result)
		}
		return result
	}
	for i, id := range []uuid.UUID{topicA, topicB} {
		apply("createFolder", id, 0, map[string]any{"parentId": s.RootID.String(), "name": fmt.Sprintf("专题%d", i+1), "metadata": map[string]any{"category": "topic", "abstract": "research context"}})
	}
	annotationID := uuid.NewString()
	apply("createPDF", paper, 0, map[string]any{
		"parentId": s.RootID.String(), "name": "reading.pdf", "pdfBlobId": pdfBlob.String(),
		"metadata":    map[string]any{"category": "paper", "title": "Research paper", "authors": []string{"Alice", "某研究组"}, "year": 2026, "doi": "10.1000/restore", "topicIDs": []string{topicA.String(), topicB.String()}, "readingPositions": []any{map[string]any{"deviceID": "phone", "pageIndex": 0}}},
		"annotations": []any{map[string]any{"id": annotationID, "type": "highlight", "pageIndex": 0, "geometry": map[string]any{"x": 72, "y": 710, "width": 120, "height": 22}, "color": "#FFE08A", "text": "Reading fixture", "pdfBlobId": pdfBlob.String()}},
	})
	baseText := "# Reading notes\n\nbase opinion\n\n![figure](media/figure.png)\n"
	apply("createMarkdown", note, 0, map[string]any{
		"parentId": s.RootID.String(), "name": "notes.md", "markdownSource": baseText,
		"assets":   []any{map[string]any{"blobId": imageBlob.String(), "path": "media/figure.png", "mime": "image/png"}},
		"metadata": map[string]any{"category": "note", "sourceIDs": []string{paper.String()}, "topicIDs": []string{topicA.String()}, "archived": true, "excerpts": []any{map[string]any{"id": uuid.NewString(), "sourceID": paper.String(), "sourceTitle": "Research paper", "quote": "Reading fixture", "comment": "My interpretation", "pageIndex": 0}}},
	})
	apply("updateDocument", note, 1, map[string]any{"markdownSource": strings.Replace(baseText, "base opinion", "remote opinion", 1)})
	conflict := apply("updateDocument", note, 1, map[string]any{"markdownSource": strings.Replace(baseText, "base opinion", "local opinion", 1)})
	if conflict.Status != "conflict" || len(conflict.ConflictIDs) != 1 {
		t.Fatalf("missing conflict fixture: %#v", conflict)
	}
	before := map[uuid.UUID]string{}
	readSnapshot := func(st *store.Store, id uuid.UUID) string {
		t.Helper()
		tx, err := st.Pool.Begin(ctx)
		must(t, err)
		defer tx.Rollback(ctx)
		snapshot, err := (&synceng.Engine{S: st}).LoadPublic(ctx, tx, id)
		must(t, err)
		raw, err := json.Marshal(snapshot)
		must(t, err)
		return string(raw)
	}
	for _, id := range []uuid.UUID{topicA, topicB, paper, note} {
		before[id] = readSnapshot(s, id)
	}
	var oldLocal, oldBase, oldRemote []byte
	must(t, s.Pool.QueryRow(ctx, `SELECT local_snapshot,base_ref,remote_ref FROM conflicts WHERE id=$1`, conflict.ConflictIDs[0]).Scan(&oldLocal, &oldBase, &oldRemote))
	must(t, (&Runner{S: s}).RunBackup(ctx))
	var backupDir string
	must(t, s.Pool.QueryRow(ctx, `SELECT path FROM backups WHERE state='success'`).Scan(&backupDir))
	manifest, err := VerifyBackup(ctx, backupDir, time.Now())
	must(t, err)
	if len(manifest.Files) != 3 {
		t.Fatalf("expected database, PDF and PNG; got %d", len(manifest.Files))
	}
	_, err = s.Pool.Exec(ctx, `CREATE DATABASE media_restored`)
	must(t, err)
	target := cfg
	target.DatabaseURL = strings.Replace(cfg.DatabaseURL, "/postgres?", "/media_restored?", 1)
	target.DataRoot = filepath.Join(root, "media-restored-data")
	_, err = RestoreBackup(ctx, backupDir, target)
	must(t, err)
	restored, err := store.Connect(ctx, target)
	must(t, err)
	defer restored.Close()
	if restored.LibID != s.LibID || restored.Epoch == s.Epoch {
		t.Fatal("restore identity contract broken")
	}
	for id, expected := range before {
		if got := readSnapshot(restored, id); got != expected {
			t.Fatalf("restored catalog/media metadata differs for %s\n%s\n%s", id, expected, got)
		}
	}
	for id, expected := range map[uuid.UUID][]byte{pdfBlob: pdfBytes, imageBlob: pngBuffer.Bytes()} {
		got, err := os.ReadFile(store.BlobPath(target.DataRoot, id))
		must(t, err)
		if !bytes.Equal(got, expected) || sha256.Sum256(got) != sha256.Sum256(expected) {
			t.Fatalf("original media changed: %s", id)
		}
	}
	decoded, err := png.Decode(bytes.NewReader(pngBuffer.Bytes()))
	must(t, err)
	if decoded.Bounds().Dx() != 8 {
		t.Fatal("PNG fixture is not readable")
	}
	var newLocal, newBase, newRemote []byte
	var state string
	must(t, restored.Pool.QueryRow(ctx, `SELECT local_snapshot,base_ref,remote_ref,status FROM conflicts WHERE id=$1`, conflict.ConflictIDs[0]).Scan(&newLocal, &newBase, &newRemote, &state))
	if state != "open" || !bytes.Equal(oldLocal, newLocal) || !bytes.Equal(oldBase, newBase) || !bytes.Equal(oldRemote, newRemote) {
		t.Fatal("restore lost conflict materials")
	}
	var revisionCount int
	must(t, restored.Pool.QueryRow(ctx, `SELECT count(*) FROM revisions WHERE object_id=$1 AND epoch=$2`, note, restored.Epoch).Scan(&revisionCount))
	if revisionCount < 2 {
		t.Fatal("restored conflict base/remote revisions unavailable in new epoch")
	}
	var maintenance bool
	must(t, restored.Pool.QueryRow(ctx, `SELECT maintenance FROM libraries`).Scan(&maintenance))
	if maintenance {
		t.Fatal("restored media library still in maintenance")
	}
}

func seedMediaBlob(t *testing.T, s *store.Store, data []byte, mime string) uuid.UUID {
	t.Helper()
	id := uuid.New()
	path := store.BlobPath(s.Cfg.DataRoot, id)
	must(t, os.MkdirAll(filepath.Dir(path), 0750))
	must(t, os.WriteFile(path, data, 0640))
	hash := sha256.Sum256(data)
	_, err := s.Pool.Exec(context.Background(), `INSERT INTO blobs(id,library_id,sha256,size,mime,state) VALUES($1,$2,$3,$4,$5,'ready')`, id, s.LibID, hash[:], len(data), mime)
	must(t, err)
	return id
}

func readableFixturePDF() []byte {
	stream := "BT /F1 18 Tf 72 720 Td (Reading fixture) Tj ET\n"
	objects := []string{
		"1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n",
		"2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj\n",
		"3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >> endobj\n",
		fmt.Sprintf("4 0 obj << /Length %d >> stream\n%sendstream\nendobj\n", len(stream), stream),
		"5 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> endobj\n",
	}
	var out strings.Builder
	out.WriteString("%PDF-1.4\n")
	offsets := []int{}
	for _, object := range objects {
		offsets = append(offsets, out.Len())
		out.WriteString(object)
	}
	xref := out.Len()
	fmt.Fprintf(&out, "xref\n0 6\n0000000000 65535 f \n")
	for _, offset := range offsets {
		fmt.Fprintf(&out, "%010d 00000 n \n", offset)
	}
	fmt.Fprintf(&out, "trailer << /Size 6 /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n", xref)
	return []byte(out.String())
}
