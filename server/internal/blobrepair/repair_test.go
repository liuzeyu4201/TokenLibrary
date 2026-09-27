package blobrepair

import (
	"crypto/sha256"
	"errors"
	"testing"
)

func TestRepairRejectsMismatchedBytes(t *testing.T) {
	original := []byte("original-blob-bytes")
	sum := sha256.Sum256(original)
	if err := Accept("ready", sum[:], int64(len(original)), original); !errors.Is(err, ErrNotRepairable) {
		t.Fatalf("ready blob: %v", err)
	}
	if err := Accept("unavailable", sum[:], int64(len(original)), []byte("different")); !errors.Is(err, ErrMismatch) {
		t.Fatalf("mismatch: %v", err)
	}
	if err := Accept("unavailable", sum[:], int64(len(original))+1, original); !errors.Is(err, ErrMismatch) {
		t.Fatalf("size: %v", err)
	}
	if err := Accept("unavailable", sum[:], int64(len(original)), original); err != nil {
		t.Fatal(err)
	}
}
