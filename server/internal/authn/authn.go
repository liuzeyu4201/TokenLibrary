package authn

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"strconv"
	"strings"

	"golang.org/x/crypto/argon2"
)

const (
	ArgonMemory  = 64 * 1024
	ArgonTime    = 3
	ArgonThreads = 1
	ArgonKeyLen  = 32
)

func RandomBytes(n int) []byte {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return b
}

func Token() string {
	return base64.RawURLEncoding.EncodeToString(RandomBytes(32))
}

func SHA256Bytes(s string) []byte {
	h := sha256.Sum256([]byte(s))
	return h[:]
}

func SHA256Hex(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])
}

func HashPassword(password string) string {
	salt := RandomBytes(16)
	key := argon2.IDKey([]byte(password), salt, ArgonTime, ArgonMemory, ArgonThreads, ArgonKeyLen)
	return fmt.Sprintf("$argon2id$v=19$m=%d,t=%d,p=%d$%s$%s",
		ArgonMemory, ArgonTime, ArgonThreads,
		base64.RawStdEncoding.EncodeToString(salt),
		base64.RawStdEncoding.EncodeToString(key),
	)
}

func VerifyPassword(phc, password string) bool {
	salt, key, mem, time, threads, err := parsePHC(phc)
	if err != nil {
		return false
	}
	got := argon2.IDKey([]byte(password), salt, time, mem, threads, uint32(len(key)))
	return subtle.ConstantTimeCompare(got, key) == 1
}

func parsePHC(phc string) (salt, key []byte, mem, time uint32, threads uint8, err error) {
	parts := strings.Split(phc, "$")
	if len(parts) != 6 || parts[1] != "argon2id" {
		err = fmt.Errorf("unsupported phc")
		return
	}
	params := parts[3]
	for _, kv := range strings.Split(params, ",") {
		k, v, ok := strings.Cut(kv, "=")
		if !ok {
			continue
		}
		n, _ := strconv.ParseUint(v, 10, 32)
		switch k {
		case "m":
			mem = uint32(n)
		case "t":
			time = uint32(n)
		case "p":
			threads = uint8(n)
		}
	}
	salt, err = base64.RawStdEncoding.DecodeString(parts[4])
	if err != nil {
		salt, err = base64.StdEncoding.DecodeString(parts[4])
	}
	if err != nil {
		return
	}
	key, err = base64.RawStdEncoding.DecodeString(parts[5])
	if err != nil {
		key, err = base64.StdEncoding.DecodeString(parts[5])
	}
	if mem == 0 {
		mem = ArgonMemory
	}
	if time == 0 {
		time = ArgonTime
	}
	if threads == 0 {
		threads = ArgonThreads
	}
	return
}

func EqualHash(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	return subtle.ConstantTimeCompare(a, b) == 1
}
