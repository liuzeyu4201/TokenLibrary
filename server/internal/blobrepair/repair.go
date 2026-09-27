package blobrepair

import (
	"bytes"
	"crypto/sha256"
	"errors"
)

var (
	ErrNotRepairable = errors.New("blob is not unavailable")
	ErrMismatch      = errors.New("repair bytes do not match the original blob")
)

// Accept reports whether these bytes may replace an unavailable blob.
// The original hash and size are the only accepted identity.
func Accept(state string, expectedHash []byte, expectedSize int64, body []byte) error {
	if state != "unavailable" {
		return ErrNotRepairable
	}
	sum := sha256.Sum256(body)
	if int64(len(body)) != expectedSize || !bytes.Equal(sum[:], expectedHash) {
		return ErrMismatch
	}
	return nil
}
