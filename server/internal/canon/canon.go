package canon

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"math"
	"sort"
	"strconv"
	"strings"
)

// Encode produces canonical-v1 JSON: sorted keys, no HTML escape, nulls explicit
// for known optional fields, arrays sorted by identity when requested.
func Encode(v any) ([]byte, error) {
	var buf bytes.Buffer
	if err := writeValue(&buf, v); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func Hash(b []byte) [32]byte { return sha256.Sum256(b) }

func HashHex(b []byte) string {
	h := sha256.Sum256(b)
	return fmt.Sprintf("%x", h[:])
}

func writeValue(buf *bytes.Buffer, v any) error {
	switch t := v.(type) {
	case nil:
		buf.WriteString("null")
	case bool:
		if t {
			buf.WriteString("true")
		} else {
			buf.WriteString("false")
		}
	case int:
		buf.WriteString(strconv.Itoa(t))
	case int64:
		buf.WriteString(strconv.FormatInt(t, 10))
	case float64:
		if math.IsNaN(t) || math.IsInf(t, 0) {
			return fmt.Errorf("non-finite number")
		}
		buf.WriteString(strconv.FormatFloat(t, 'g', -1, 64))
	case json.Number:
		buf.WriteString(t.String())
	case string:
		b, _ := json.Marshal(t)
		buf.Write(b)
	case []any:
		buf.WriteByte('[')
		for i, e := range t {
			if i > 0 {
				buf.WriteByte(',')
			}
			if err := writeValue(buf, e); err != nil {
				return err
			}
		}
		buf.WriteByte(']')
	case map[string]any:
		keys := make([]string, 0, len(t))
		for k := range t {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		buf.WriteByte('{')
		for i, k := range keys {
			if i > 0 {
				buf.WriteByte(',')
			}
			kb, _ := json.Marshal(k)
			buf.Write(kb)
			buf.WriteByte(':')
			if err := writeValue(buf, t[k]); err != nil {
				return err
			}
		}
		buf.WriteByte('}')
	default:
		b, err := json.Marshal(t)
		if err != nil {
			return err
		}
		var raw any
		dec := json.NewDecoder(bytes.NewReader(b))
		dec.UseNumber()
		if err := dec.Decode(&raw); err != nil {
			return err
		}
		return writeValue(buf, raw)
	}
	return nil
}

func Parse(b []byte) (map[string]any, error) {
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		return nil, err
	}
	m, ok := v.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("object required")
	}
	return m, nil
}

func GetString(m map[string]any, k string) string {
	v, _ := m[k].(string)
	return v
}

func GetInt64(m map[string]any, k string) int64 {
	switch t := m[k].(type) {
	case json.Number:
		n, _ := t.Int64()
		return n
	case float64:
		return int64(t)
	case int64:
		return t
	case int:
		return int64(t)
	case string:
		n, _ := strconv.ParseInt(t, 10, 64)
		return n
	}
	return 0
}

func NormalizeUUID(s string) string {
	return strings.ToLower(strings.TrimSpace(s))
}
