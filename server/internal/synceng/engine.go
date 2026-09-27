package synceng

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"tokenlibrary/internal/canon"
	"tokenlibrary/internal/merge"
	"tokenlibrary/internal/names"
	"tokenlibrary/internal/store"
)

var (
	ErrMaintenance   = errors.New("maintenance")
	ErrBusy          = errors.New("short write contention")
	ErrEpoch         = errors.New("epoch_changed")
	ErrIdempotency   = errors.New("idempotency_mismatch")
	ErrNameConflict  = errors.New("name_conflict")
	ErrNotFound      = errors.New("not_found")
	ErrGone          = errors.New("gone")
	ErrConflictStale = errors.New("conflict_stale")
	ErrBase          = errors.New("base_invalid")
	ErrProtocol      = errors.New("protocol_unsupported")
	ErrAuth          = errors.New("unauthorized")
	ErrForbidden     = errors.New("forbidden")
	ErrValidation    = errors.New("validation")
)

type Envelope struct {
	ProtocolVersion int            `json:"protocolVersion"`
	OperationID     string         `json:"operationId"`
	Epoch           string         `json:"epoch"`
	DeviceID        string         `json:"deviceId"`
	ObjectID        string         `json:"objectId"`
	Action          string         `json:"action"`
	Base            *BaseRef       `json:"base"`
	DesiredSnapshot map[string]any `json:"desiredSnapshot"`
	Scope           map[string]any `json:"scope"`
	Resolution      map[string]any `json:"resolution"`
}

type BaseRef struct {
	Source        string `json:"source"`
	Revision      int64  `json:"revision"`
	OperationID   string `json:"operationId"`
	Hash          string `json:"hash"`
	SnapshotBytes string `json:"snapshotBytes"`
}

type OpResult struct {
	OperationID  uuid.UUID
	HTTP         int
	Status       string
	ObjectID     uuid.UUID
	Revision     int64
	ChangeSeq    int64
	Epoch        uuid.UUID
	ConflictIDs  []uuid.UUID
	ReceiptHash  string
	Replayed     bool
	FinalName    string
	ParentID     uuid.UUID
	ErrorCode    string
	ErrorMessage string
	Retryable    bool
	Snapshot     map[string]any
}

type Engine struct {
	S *store.Store
}

func (e *Engine) Apply(ctx context.Context, env Envelope, principal string, inputBytes []byte) (OpResult, error) {
	if !e.S.Writes.TryRLock() {
		maintenance, err := e.S.Ready(ctx)
		if err != nil {
			return OpResult{HTTP: 503, ErrorCode: "UNAVAILABLE", Retryable: true}, err
		}
		if maintenance {
			return OpResult{HTTP: 503, ErrorCode: "MAINTENANCE", Retryable: true}, ErrMaintenance
		}
		// A short retention pass also takes the exclusive lock. It is not a
		// backup window: clients can replay the same operation shortly.
		return OpResult{HTTP: 503, ErrorCode: "BUSY", Retryable: true}, ErrBusy
	}
	defer e.S.Writes.RUnlock()
	if _, err := e.S.Ready(ctx); err != nil {
		return OpResult{HTTP: 503, ErrorCode: "UNAVAILABLE", Retryable: true}, err
	}
	if env.ProtocolVersion != 1 {
		return OpResult{HTTP: 426, ErrorCode: "PROTOCOL_UNSUPPORTED", ErrorMessage: "protocolVersion=1 required"}, ErrProtocol
	}
	opID, err := uuid.Parse(env.OperationID)
	if err != nil {
		return OpResult{HTTP: 422, ErrorCode: "VALIDATION", ErrorMessage: "operationId"}, ErrValidation
	}
	objID, err := uuid.Parse(env.ObjectID)
	if err != nil && env.Action != "" {
		return OpResult{HTTP: 422, ErrorCode: "VALIDATION", ErrorMessage: "objectId"}, ErrValidation
	}
	inputHash := sha256.Sum256(inputBytes)
	tx, err := e.S.Pool.Begin(ctx)
	if err != nil {
		return OpResult{HTTP: 503, ErrorCode: "UNAVAILABLE", Retryable: true}, err
	}
	defer tx.Rollback(ctx)

	epoch, seq, maint, err := e.S.LockLibrary(ctx, tx)
	if err != nil {
		return OpResult{HTTP: 503, ErrorCode: "UNAVAILABLE", Retryable: true}, err
	}
	if maint {
		return OpResult{HTTP: 503, ErrorCode: "MAINTENANCE", ErrorMessage: "cloud writes paused", Retryable: true}, ErrMaintenance
	}
	reqEpoch, err := uuid.Parse(env.Epoch)
	if err != nil || reqEpoch != epoch {
		return OpResult{HTTP: 409, ErrorCode: "EPOCH_CHANGED", ErrorMessage: "epoch mismatch"}, ErrEpoch
	}

	var existingStatus string
	var existingHash []byte
	var existing json.RawMessage
	err = tx.QueryRow(ctx, `SELECT status, input_hash, result_json FROM operations WHERE library_id=$1 AND epoch=$2 AND operation_id=$3`,
		e.S.LibID, epoch, opID).Scan(&existingStatus, &existingHash, &existing)
	if err == nil {
		if !bytes.Equal(existingHash, inputHash[:]) {
			return OpResult{HTTP: 409, ErrorCode: "IDEMPOTENCY_MISMATCH"}, ErrIdempotency
		}
		var gone bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM tombstones WHERE library_id=$1 AND object_id=$2) OR EXISTS(SELECT 1 FROM objects WHERE library_id=$1 AND id=$2 AND purge_at<=now())`, e.S.LibID, objID).Scan(&gone); err != nil {
			return OpResult{HTTP: 503, ErrorCode: "UNAVAILABLE", Retryable: true}, err
		}
		if gone {
			return OpResult{HTTP: 410, ErrorCode: "GONE"}, ErrGone
		}
		var r OpResult
		_ = json.Unmarshal(existing, &r)
		r.OperationID = opID
		r.Replayed = true
		r.ReceiptHash = hex.EncodeToString(inputHash[:])
		if r.HTTP == 0 {
			r.HTTP = 200
		}
		return r, nil
	}
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return OpResult{}, err
	}

	res, err := e.dispatch(ctx, tx, env, opID, objID, epoch, seq, inputHash[:], principal)
	if err != nil || res.HTTP >= 400 {
		if res.HTTP == 0 {
			res.HTTP = 500
			res.ErrorCode = "INTERNAL"
			res.ErrorMessage = err.Error()
		}
		return res, err
	}
	res.Epoch = epoch
	res.OperationID = opID
	res.ReceiptHash = hex.EncodeToString(inputHash[:])
	res.Snapshot, err = e.LoadPublic(ctx, tx, objID)
	if err != nil {
		return OpResult{HTTP: 500, ErrorCode: "INTERNAL"}, err
	}
	body, _ := json.Marshal(res)
	confJSON, _ := json.Marshal(res.ConflictIDs)
	_, err = tx.Exec(ctx, `INSERT INTO operations(library_id, epoch, operation_id, principal_kind, action, object_id, request_hash, input_hash, status, result_revision, result_seq, conflict_ids, result_json)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12::jsonb,$13::jsonb)`,
		e.S.LibID, epoch, opID, principal, env.Action, objID, inputHash[:], inputHash[:], res.Status, res.Revision, res.ChangeSeq, string(confJSON), string(body))
	if err != nil {
		return OpResult{HTTP: 500, ErrorCode: "INTERNAL", ErrorMessage: "opins:" + err.Error()}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return OpResult{HTTP: 503, ErrorCode: "UNAVAILABLE", Retryable: true}, err
	}
	res.ReceiptHash = hex.EncodeToString(inputHash[:])
	return res, nil
}

func (e *Engine) dispatch(ctx context.Context, tx pgx.Tx, env Envelope, opID, objID, epoch uuid.UUID, seq int64, inputHash []byte, principal string) (OpResult, error) {
	switch env.Action {
	case "createFolder", "createMarkdown", "createPDF":
		return e.create(ctx, tx, env, opID, objID, epoch, seq)
	case "updateDocument", "rename", "move":
		return e.update(ctx, tx, env, opID, objID, epoch, seq)
	case "trash":
		return e.trash(ctx, tx, env, opID, objID, epoch, seq)
	case "restore":
		return e.restore(ctx, tx, env, opID, objID, epoch, seq)
	case "resolveConflicts":
		return e.resolve(ctx, tx, env, opID, objID, epoch, seq)
	default:
		return OpResult{HTTP: 422, ErrorCode: "VALIDATION", ErrorMessage: "unknown action"}, ErrValidation
	}
}

func (e *Engine) create(ctx context.Context, tx pgx.Tx, env Envelope, opID, objID, epoch uuid.UUID, seq int64) (OpResult, error) {
	var gone int
	_ = tx.QueryRow(ctx, `SELECT 1 FROM tombstones WHERE library_id=$1 AND object_id=$2`, e.S.LibID, objID).Scan(&gone)
	if gone == 1 {
		return OpResult{HTTP: 410, ErrorCode: "GONE", ErrorMessage: "uuid retired"}, ErrGone
	}
	var exists int
	_ = tx.QueryRow(ctx, `SELECT 1 FROM objects WHERE id=$1`, objID).Scan(&exists)
	if exists == 1 {
		return OpResult{HTTP: 409, ErrorCode: "EXISTS"}, ErrValidation
	}
	kind := map[string]string{"createFolder": "folder", "createMarkdown": "md", "createPDF": "pdf"}[env.Action]
	name, _ := env.DesiredSnapshot["name"].(string)
	if err := names.Validate(name, kind == "folder"); err != nil {
		return OpResult{HTTP: 422, ErrorCode: "VALIDATION", ErrorMessage: err.Error()}, ErrValidation
	}
	parent := e.parentOf(env)
	if raw, supplied := env.DesiredSnapshot["parentId"]; supplied {
		if _, err := uuid.Parse(fmt.Sprint(raw)); err != nil {
			return OpResult{HTTP: 422, ErrorCode: "VALIDATION", ErrorMessage: "parentId"}, ErrValidation
		}
	}
	if err := e.ensureParent(ctx, tx, parent); err != nil {
		return OpResult{HTTP: 422, ErrorCode: "VALIDATION", ErrorMessage: "parent"}, err
	}
	auto := false
	if v, ok := env.DesiredSnapshot["autoSuffix"].(bool); ok {
		auto = v
	}
	name, err := e.uniqueName(ctx, tx, parent, name, auto)
	if err != nil {
		return OpResult{HTTP: 409, ErrorCode: "NAME_CONFLICT", ErrorMessage: err.Error()}, ErrNameConflict
	}
	snap := snapshotFromDesired(kind, name, parent, env.DesiredSnapshot, "active")
	snap["name"] = name
	bindAnnotations(snap, snap["pdfBlobId"])
	if err := e.validateSnapshot(ctx, tx, kind, snap); err != nil {
		return OpResult{HTTP: 422, ErrorCode: "VALIDATION", ErrorMessage: err.Error()}, err
	}
	b, err := canon.Encode(snap)
	if err != nil {
		return OpResult{HTTP: 422, ErrorCode: "VALIDATION"}, err
	}
	h := sha256.Sum256(b)
	newSeq := seq + 1
	if err := e.insertObject(ctx, tx, objID, kind, parent, name, 1, "active", newSeq, snap, b, h[:], opID, epoch, nil); err != nil {
		return OpResult{HTTP: 500}, err
	}
	if err := e.writeChange(ctx, tx, epoch, newSeq, objID, 1, nil); err != nil {
		return OpResult{HTTP: 500}, err
	}
	return OpResult{HTTP: 201, Status: "committed", ObjectID: objID, Revision: 1, ChangeSeq: newSeq, FinalName: name, ParentID: parent}, nil
}

func (e *Engine) update(ctx context.Context, tx pgx.Tx, env Envelope, opID, objID, epoch uuid.UUID, seq int64) (OpResult, error) {
	obj, err := e.loadObject(ctx, tx, objID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return OpResult{HTTP: 410, ErrorCode: "GONE"}, ErrGone
		}
		return OpResult{HTTP: 500}, err
	}
	if obj.State == "purged" || obj.PurgeAt != nil && !obj.PurgeAt.After(time.Now()) {
		return OpResult{HTTP: 410, ErrorCode: "GONE"}, ErrGone
	}
	baseSnap, baseRev, err := e.loadBase(ctx, tx, env, obj, epoch)
	if err != nil {
		return OpResult{HTTP: 409, ErrorCode: "BASE_INVALID", ErrorMessage: err.Error()}, ErrBase
	}
	// Trashed rows have no physical parent, while their public snapshots keep
	// the original location for restoration. A metadata update carrying that
	// unchanged location is not a move into a deleted folder.
	logicalParent := obj.Parent
	if obj.State == "trashed" {
		logicalParent = obj.OriginalParent
		if env.Action == "move" || env.Action == "rename" {
			return OpResult{HTTP: 422, ErrorCode: "VALIDATION", ErrorMessage: "restore before moving or renaming"}, ErrValidation
		}
		if name, ok := env.DesiredSnapshot["name"].(string); ok && name != "" && name != obj.Name {
			return OpResult{HTTP: 422, ErrorCode: "VALIDATION", ErrorMessage: "restore before renaming"}, ErrValidation
		}
		if raw, supplied := env.DesiredSnapshot["parentId"]; supplied && raw != logicalParent.String() {
			return OpResult{HTTP: 422, ErrorCode: "VALIDATION", ErrorMessage: "restore before moving"}, ErrValidation
		}
	}
	desired := snapshotFromDesired(obj.Kind, obj.Name, logicalParent, env.DesiredSnapshot, obj.State)
	// Older clients omit newer fields. Absence means unchanged, not deletion.
	for _, key := range []string{"metadata", "assets", "markdownSource", "pdfBlobId", "annotations"} {
		if _, supplied := env.DesiredSnapshot[key]; !supplied {
			if value, exists := baseSnap[key]; exists {
				desired[key] = value
			} else if value, exists := obj.Snapshot[key]; exists {
				desired[key] = value
			}
		}
	}
	if env.Action == "rename" {
		if n, ok := env.DesiredSnapshot["name"].(string); ok {
			if err := names.Validate(n, obj.Kind == "folder"); err != nil {
				return OpResult{HTTP: 422, ErrorCode: "VALIDATION"}, err
			}
			if names.NameKey(n) != names.NameKey(obj.Name) {
				if err := e.checkName(ctx, tx, obj.Parent, n, obj.ID); err != nil {
					return OpResult{HTTP: 409, ErrorCode: "NAME_CONFLICT"}, ErrNameConflict
				}
			}
			desired["name"] = n
		}
	}
	if env.Action == "move" || (env.DesiredSnapshot["parentId"] != nil && env.DesiredSnapshot["parentId"] != logicalParent.String()) {
		if raw, supplied := env.DesiredSnapshot["parentId"]; supplied {
			if _, err := uuid.Parse(fmt.Sprint(raw)); err != nil {
				return OpResult{HTTP: 422, ErrorCode: "VALIDATION", ErrorMessage: "parentId"}, ErrValidation
			}
		}
		p := e.parentOf(env)
		if err := e.ensureParent(ctx, tx, p); err != nil {
			return OpResult{HTTP: 422, ErrorCode: "VALIDATION", ErrorMessage: "parent"}, err
		}
		if err := e.wouldCycle(ctx, tx, objID, p); err != nil {
			return OpResult{HTTP: 422, ErrorCode: "VALIDATION", ErrorMessage: "cycle"}, err
		}
		desired["parentId"] = p.String()
		if n, _ := desired["name"].(string); n != "" {
			if err := e.checkName(ctx, tx, p, n, obj.ID); err != nil {
				return OpResult{HTTP: 409, ErrorCode: "NAME_CONFLICT"}, ErrNameConflict
			}
		}
	}
	remote := obj.Snapshot
	bindAnnotations(baseSnap, baseSnap["pdfBlobId"])
	bindAnnotations(desired, baseSnap["pdfBlobId"])
	bindAnnotations(remote, remote["pdfBlobId"])
	if err := e.validateSnapshot(ctx, tx, obj.Kind, desired); err != nil {
		return OpResult{HTTP: 422, ErrorCode: "VALIDATION", ErrorMessage: err.Error()}, err
	}
	mr := merge.MergeSnapshots(baseSnap, desired, remote)
	if mr.Conflict {
		cid := uuid.New()
		lb, _ := canon.Encode(desired)
		rb, _ := canon.Encode(remote)
		bb, _ := canon.Encode(baseSnap)
		lh, rh, bh := sha256.Sum256(lb), sha256.Sum256(rb), sha256.Sum256(bb)
		baseRef, _ := json.Marshal(map[string]any{"revision": baseRev, "hash": hex.EncodeToString(bh[:])})
		remoteRef, _ := json.Marshal(map[string]any{"revision": obj.Revision, "hash": hex.EncodeToString(rh[:])})
		_, err = tx.Exec(ctx, `INSERT INTO conflicts(id, object_id, kind, base_ref, local_snapshot, remote_ref, status, revision, source_operation_id, local_hash, remote_hash, base_hash)
			VALUES ($1,$2,$3,$4::jsonb,$5,$6::jsonb,'open',$7,$8,$9,$10,$11)`,
			cid, objID, "merge", string(baseRef), lb, string(remoteRef), obj.Revision, opID, lh[:], rh[:], bh[:])
		if err != nil {
			return OpResult{HTTP: 500}, err
		}
		if err := e.setBlobRefs(ctx, tx, "conflict", cid, desired); err != nil {
			return OpResult{HTTP: 500}, err
		}
		newSeq := seq + 1
		if err := e.writeChange(ctx, tx, epoch, newSeq, objID, obj.Revision, &cid); err != nil {
			return OpResult{HTTP: 500}, err
		}
		return OpResult{HTTP: 200, Status: "conflict", ObjectID: objID, Revision: obj.Revision, ChangeSeq: newSeq, ConflictIDs: []uuid.UUID{cid}}, nil
	}
	merged := mr.Merged
	bindAnnotations(merged, baseSnap["pdfBlobId"])
	name, _ := merged["name"].(string)
	if err := names.Validate(name, obj.Kind == "folder"); err != nil {
		return OpResult{HTTP: 422, ErrorCode: "VALIDATION", ErrorMessage: err.Error()}, err
	}
	parent := obj.Parent
	if raw, ok := merged["parentId"].(string); ok {
		parent, err = uuid.Parse(raw)
		if err != nil {
			return OpResult{HTTP: 422, ErrorCode: "VALIDATION", ErrorMessage: "parentId"}, err
		}
	}
	if obj.ID == e.S.RootID && (parent != uuid.Nil || name != obj.Name) {
		return OpResult{HTTP: 422, ErrorCode: "VALIDATION", ErrorMessage: "cannot move or rename root"}, ErrValidation
	}
	if obj.State == "trashed" {
		if parent != logicalParent || name != obj.Name {
			return OpResult{HTTP: 422, ErrorCode: "VALIDATION", ErrorMessage: "restore before moving or renaming"}, ErrValidation
		}
		// Keep the row detached. original_parent_id, deletion batch and purge
		// deadline are deliberately unchanged by a content/metadata update.
		parent = obj.Parent
	}
	if obj.State == "active" && obj.ID != e.S.RootID {
		if err := e.ensureParent(ctx, tx, parent); err != nil {
			return OpResult{HTTP: 422, ErrorCode: "VALIDATION", ErrorMessage: "parent"}, err
		}
		if err := e.wouldCycle(ctx, tx, objID, parent); err != nil {
			return OpResult{HTTP: 422, ErrorCode: "VALIDATION", ErrorMessage: "cycle"}, err
		}
		if err := e.checkName(ctx, tx, parent, name, objID); err != nil {
			return OpResult{HTTP: 409, ErrorCode: "NAME_CONFLICT"}, ErrNameConflict
		}
	}
	if err := e.validateSnapshot(ctx, tx, obj.Kind, merged); err != nil {
		return OpResult{HTTP: 422, ErrorCode: "VALIDATION", ErrorMessage: err.Error()}, err
	}
	nb, _ := canon.Encode(merged)
	nh := sha256.Sum256(nb)
	ob, _ := canon.Encode(remote)
	if bytes.Equal(nb, ob) {
		return OpResult{HTTP: 200, Status: "no_change", ObjectID: objID, Revision: obj.Revision, ChangeSeq: seq}, nil
	}
	newRev := obj.Revision + 1
	newSeq := seq + 1
	state := obj.State
	if st, ok := merged["state"].(string); ok && st != "" {
		state = st
	}
	if err := e.updateObject(ctx, tx, objID, name, parent, newRev, state, newSeq, merged, nb, nh[:], opID, epoch, obj.Revision); err != nil {
		return OpResult{HTTP: 500, ErrorCode: "INTERNAL", ErrorMessage: "upd:" + err.Error()}, err
	}
	if err := e.writeChange(ctx, tx, epoch, newSeq, objID, newRev, nil); err != nil {
		return OpResult{HTTP: 500, ErrorCode: "INTERNAL", ErrorMessage: "chg:" + err.Error()}, err
	}
	return OpResult{HTTP: 200, Status: "committed", ObjectID: objID, Revision: newRev, ChangeSeq: newSeq, FinalName: name, ParentID: parent}, nil
}

func (e *Engine) trash(ctx context.Context, tx pgx.Tx, env Envelope, opID, objID, epoch uuid.UUID, seq int64) (OpResult, error) {
	obj, err := e.loadObject(ctx, tx, objID)
	if err != nil || obj.PurgeAt != nil && !obj.PurgeAt.After(time.Now()) {
		return OpResult{HTTP: 410, ErrorCode: "GONE"}, ErrGone
	}
	if obj.ID == e.S.RootID {
		return OpResult{HTTP: 422, ErrorCode: "VALIDATION", ErrorMessage: "cannot trash root"}, ErrValidation
	}
	if obj.State == "trashed" {
		return OpResult{HTTP: 200, Status: "no_change", ObjectID: objID, Revision: obj.Revision, ChangeSeq: seq}, nil
	}
	ids := []uuid.UUID{objID}
	changed := []uuid.UUID{}
	newSeq := seq + 1
	if obj.Kind == "folder" && obj.Metadata["category"] == "topic" {
		// A topic is an organizing relation, not a request to delete its sources.
		// Rehome physical children in this transaction too: another device may have
		// added a child after the deleting client last enumerated the topic.
		changed, err = e.rehomeTopicChildren(ctx, tx, obj, opID, epoch, newSeq)
		if err != nil {
			return OpResult{HTTP: 500, ErrorCode: "INTERNAL"}, err
		}
	} else if obj.Kind == "folder" {
		children, err := e.subtree(ctx, tx, objID)
		if err != nil {
			return OpResult{HTTP: 500}, err
		}
		ids = append(ids, children...)
	}
	batch, now := uuid.New(), time.Now().UTC()
	purge := now.Add(30 * 24 * time.Hour)
	for _, id := range ids {
		o, err := e.loadObject(ctx, tx, id)
		if err != nil {
			return OpResult{HTTP: 500}, err
		}
		snap := o.Snapshot
		snap["state"] = "trashed"
		b, err := canon.Encode(snap)
		if err != nil {
			return OpResult{HTTP: 500}, err
		}
		hash := sha256.Sum256(b)
		if err = e.updateObject(ctx, tx, id, o.Name, uuid.Nil, o.Revision+1, "trashed", newSeq, snap, b, hash[:], opID, epoch, o.Revision); err != nil {
			return OpResult{HTTP: 500}, err
		}
		if _, err = tx.Exec(ctx, `UPDATE objects SET deleted_at=$2,purge_at=$3,trash_batch_id=$4,original_parent_id=$5 WHERE id=$1`, id, now, purge, batch, o.Parent); err != nil {
			return OpResult{HTTP: 500}, err
		}
	}
	if err = e.writeChanges(ctx, tx, epoch, newSeq, append(changed, ids...), nil); err != nil {
		return OpResult{HTTP: 500}, err
	}
	return OpResult{HTTP: 200, Status: "committed", ObjectID: objID, Revision: obj.Revision + 1, ChangeSeq: newSeq}, nil
}

func (e *Engine) rehomeTopicChildren(ctx context.Context, tx pgx.Tx, topic objectRow, opID, epoch uuid.UUID, seq int64) ([]uuid.UUID, error) {
	parent := topic.Parent
	if err := e.ensureParent(ctx, tx, parent); err != nil {
		parent = e.S.RootID
	}
	rows, err := tx.Query(ctx, `SELECT id FROM objects WHERE library_id=$1 AND parent_id=$2 AND state='active' ORDER BY id`, e.S.LibID, topic.ID)
	if err != nil {
		return nil, err
	}
	children := []uuid.UUID{}
	for rows.Next() {
		var id uuid.UUID
		if err = rows.Scan(&id); err != nil {
			rows.Close()
			return nil, err
		}
		children = append(children, id)
	}
	rows.Close()
	if err = rows.Err(); err != nil {
		return nil, err
	}
	for _, id := range children {
		child, err := e.loadObject(ctx, tx, id)
		if err != nil {
			return nil, err
		}
		name, err := e.uniqueName(ctx, tx, parent, child.Name, true)
		if err != nil {
			return nil, err
		}
		snapshot := child.Snapshot
		snapshot["parentId"], snapshot["name"] = parent.String(), name
		raw, err := canon.Encode(snapshot)
		if err != nil {
			return nil, err
		}
		hash := sha256.Sum256(raw)
		if err = e.updateObject(ctx, tx, id, name, parent, child.Revision+1, "active", seq, snapshot, raw, hash[:], opID, epoch, child.Revision); err != nil {
			return nil, err
		}
	}
	return children, nil
}

func (e *Engine) restore(ctx context.Context, tx pgx.Tx, env Envelope, opID, objID, epoch uuid.UUID, seq int64) (OpResult, error) {
	obj, err := e.loadObject(ctx, tx, objID)
	if err != nil || obj.PurgeAt != nil && time.Now().UTC().After(*obj.PurgeAt) {
		return OpResult{HTTP: 410, ErrorCode: "GONE"}, ErrGone
	}
	if obj.State != "trashed" {
		return OpResult{HTTP: 422, ErrorCode: "VALIDATION"}, ErrValidation
	}
	parent := obj.OriginalParent
	if raw, ok := env.DesiredSnapshot["parentId"].(string); ok && raw != "" {
		parent, err = uuid.Parse(raw)
		if err != nil {
			return OpResult{HTTP: 422, ErrorCode: "VALIDATION"}, err
		}
	}
	if err = e.ensureParent(ctx, tx, parent); err != nil {
		parent = e.S.RootID
	}
	name := obj.Name
	if n, ok := env.DesiredSnapshot["name"].(string); ok && n != "" {
		name = n
	}
	if err = names.Validate(name, obj.Kind == "folder"); err != nil {
		return OpResult{HTTP: 422, ErrorCode: "VALIDATION"}, err
	}
	ids := []uuid.UUID{objID}
	if obj.Kind == "folder" {
		rows, err := tx.Query(ctx, `WITH RECURSIVE subtree AS (
			SELECT id FROM objects WHERE id=$2 AND library_id=$1
			UNION ALL
			SELECT o.id FROM objects o JOIN subtree t ON o.original_parent_id=t.id
			WHERE o.library_id=$1 AND o.state='trashed' AND o.trash_batch_id=(SELECT trash_batch_id FROM objects WHERE id=$2)
		) SELECT id FROM subtree WHERE id<>$2 ORDER BY id`, e.S.LibID, objID)
		if err != nil {
			return OpResult{HTTP: 500}, err
		}
		for rows.Next() {
			var id uuid.UUID
			if err = rows.Scan(&id); err != nil {
				rows.Close()
				return OpResult{HTTP: 500}, err
			}
			ids = append(ids, id)
		}
		rows.Close()
		if err = rows.Err(); err != nil {
			return OpResult{HTTP: 500}, err
		}
	}
	restoring := map[uuid.UUID]bool{}
	for _, id := range ids {
		restoring[id] = true
	}
	newSeq := seq + 1
	for _, id := range ids {
		o, err := e.loadObject(ctx, tx, id)
		if err != nil {
			return OpResult{HTTP: 500}, err
		}
		p, n := o.OriginalParent, o.Name
		if id == objID {
			p, n = parent, name
		} else if !restoring[p] {
			if err = e.ensureParent(ctx, tx, p); err != nil {
				p = e.S.RootID
			}
		}
		if err = e.checkName(ctx, tx, p, n, id); err != nil {
			return OpResult{HTTP: 409, ErrorCode: "NAME_CONFLICT"}, ErrNameConflict
		}
		snap := o.Snapshot
		snap["state"] = "active"
		snap["parentId"] = p.String()
		snap["name"] = n
		b, err := canon.Encode(snap)
		if err != nil {
			return OpResult{HTTP: 500}, err
		}
		hash := sha256.Sum256(b)
		if err = e.updateObject(ctx, tx, id, n, p, o.Revision+1, "active", newSeq, snap, b, hash[:], opID, epoch, o.Revision); err != nil {
			return OpResult{HTTP: 500}, err
		}
		if _, err = tx.Exec(ctx, `UPDATE objects SET deleted_at=NULL,purge_at=NULL,trash_batch_id=NULL,original_parent_id=NULL WHERE id=$1`, id); err != nil {
			return OpResult{HTTP: 500}, err
		}
	}
	if err = e.writeChanges(ctx, tx, epoch, newSeq, ids, nil); err != nil {
		return OpResult{HTTP: 500}, err
	}
	return OpResult{HTTP: 200, Status: "committed", ObjectID: objID, Revision: obj.Revision + 1, ChangeSeq: newSeq, FinalName: name, ParentID: parent}, nil
}

func (e *Engine) resolve(ctx context.Context, tx pgx.Tx, env Envelope, opID, objID, epoch uuid.UUID, seq int64) (OpResult, error) {
	obj, err := e.loadObject(ctx, tx, objID)
	if err != nil || obj.PurgeAt != nil && !obj.PurgeAt.After(time.Now()) {
		return OpResult{HTTP: 410, ErrorCode: "GONE"}, ErrGone
	}
	ids, ok := env.Resolution["conflictIds"].([]any)
	if !ok || len(ids) == 0 || canon.GetInt64(env.Resolution, "revision") != obj.Revision {
		return OpResult{HTTP: 409, ErrorCode: "CONFLICT_STALE"}, ErrConflictStale
	}
	conflicts := []uuid.UUID{}
	for _, raw := range ids {
		id, err := uuid.Parse(fmt.Sprint(raw))
		if err != nil {
			return OpResult{HTTP: 422, ErrorCode: "VALIDATION"}, err
		}
		var open bool
		if err = tx.QueryRow(ctx, `SELECT status='open' FROM conflicts WHERE id=$1 AND object_id=$2`, id, objID).Scan(&open); err != nil || !open {
			return OpResult{HTTP: 409, ErrorCode: "CONFLICT_STALE"}, ErrConflictStale
		}
		conflicts = append(conflicts, id)
	}
	desired := snapshotFromDesired(obj.Kind, obj.Name, obj.Parent, env.DesiredSnapshot, obj.State)
	for _, key := range []string{"metadata", "assets", "markdownSource", "pdfBlobId", "annotations"} {
		if _, ok := env.DesiredSnapshot[key]; !ok {
			if value, exists := obj.Snapshot[key]; exists {
				desired[key] = value
			}
		}
	}
	parent := obj.Parent
	if p, ok := env.DesiredSnapshot["parentId"].(string); ok && p != "" {
		parent, err = uuid.Parse(p)
		if err != nil {
			return OpResult{HTTP: 422, ErrorCode: "VALIDATION"}, err
		}
		desired["parentId"] = parent.String()
	}
	name, _ := desired["name"].(string)
	if err = names.Validate(name, obj.Kind == "folder"); err != nil {
		return OpResult{HTTP: 422, ErrorCode: "VALIDATION"}, err
	}
	if err = e.ensureParent(ctx, tx, parent); err != nil {
		return OpResult{HTTP: 422, ErrorCode: "VALIDATION"}, err
	}
	if err = e.wouldCycle(ctx, tx, objID, parent); err != nil {
		return OpResult{HTTP: 422, ErrorCode: "VALIDATION"}, err
	}
	if err = e.checkName(ctx, tx, parent, name, objID); err != nil {
		return OpResult{HTTP: 409, ErrorCode: "NAME_CONFLICT"}, ErrNameConflict
	}
	bindAnnotations(desired, obj.Snapshot["pdfBlobId"])
	if err = e.validateSnapshot(ctx, tx, obj.Kind, desired); err != nil {
		return OpResult{HTTP: 422, ErrorCode: "VALIDATION", ErrorMessage: err.Error()}, err
	}
	b, err := canon.Encode(desired)
	if err != nil {
		return OpResult{HTTP: 422, ErrorCode: "VALIDATION"}, err
	}
	hash := sha256.Sum256(b)
	if err = e.updateObject(ctx, tx, objID, name, parent, obj.Revision+1, obj.State, seq+1, desired, b, hash[:], opID, epoch, obj.Revision); err != nil {
		return OpResult{HTTP: 500}, err
	}
	for _, id := range conflicts {
		if _, err = tx.Exec(ctx, `UPDATE conflicts SET status='resolved' WHERE id=$1`, id); err != nil {
			return OpResult{HTTP: 500}, err
		}
	}
	if err = e.writeChange(ctx, tx, epoch, seq+1, objID, obj.Revision+1, nil); err != nil {
		return OpResult{HTTP: 500}, err
	}
	return OpResult{HTTP: 200, Status: "committed", ObjectID: objID, Revision: obj.Revision + 1, ChangeSeq: seq + 1}, nil
}

type objectRow struct {
	ID             uuid.UUID
	Kind           string
	Parent         uuid.UUID
	Name           string
	Revision       int64
	State          string
	Snapshot       map[string]any
	PurgeAt        *time.Time
	OriginalParent uuid.UUID
	TrashBatch     *uuid.UUID
	Metadata       map[string]any
}

func (e *Engine) loadObject(ctx context.Context, tx pgx.Tx, id uuid.UUID) (objectRow, error) {
	var o objectRow
	var parent *uuid.UUID
	var orig *uuid.UUID
	var md *string
	var pdf *uuid.UUID
	var metadata []byte
	err := tx.QueryRow(ctx, `SELECT o.id, o.kind, o.parent_id, o.name, o.revision, o.state, o.purge_at, o.original_parent_id, d.markdown_source, d.pdf_blob_id, o.metadata, o.trash_batch_id
		FROM objects o LEFT JOIN documents d ON d.object_id=o.id WHERE o.id=$1 AND o.library_id=$2`, id, e.S.LibID).
		Scan(&o.ID, &o.Kind, &parent, &o.Name, &o.Revision, &o.State, &o.PurgeAt, &orig, &md, &pdf, &metadata, &o.TrashBatch)
	if err != nil {
		return o, err
	}
	if parent != nil {
		o.Parent = *parent
	}
	if orig != nil {
		o.OriginalParent = *orig
	}
	o.Metadata, err = canon.Parse(metadata)
	if err != nil {
		return o, err
	}
	o.Snapshot = snapshotFromDesired(o.Kind, o.Name, o.Parent, map[string]any{
		"markdownSource": nilIfEmpty(md),
		"pdfBlobId":      uuidStr(pdf),
	}, o.State)
	if o.Kind == "pdf" {
		o.Snapshot["annotations"] = e.loadAnns(ctx, tx, id)
	}
	if o.Revision > 0 {
		var b []byte
		if err := tx.QueryRow(ctx, `SELECT snapshot_bytes FROM revisions WHERE library_id=$1 AND epoch=$2 AND object_id=$3 AND revision=$4`,
			e.S.LibID, e.S.Epoch, id, o.Revision).Scan(&b); err == nil {
			if m, err := canon.Parse(b); err == nil {
				o.Snapshot = m
			}
		}
	}
	o.Snapshot["metadata"] = o.Metadata
	return o, nil
}

func (e *Engine) loadAnns(ctx context.Context, tx pgx.Tx, doc uuid.UUID) []any {
	rows, err := tx.Query(ctx, `SELECT id, type, page_index, geometry, color, text, placement_state, pdf_blob_id FROM annotations WHERE document_id=$1 ORDER BY id`, doc)
	if err != nil {
		return []any{}
	}
	defer rows.Close()
	var out []any
	for rows.Next() {
		var id uuid.UUID
		var typ, color, place string
		var page int
		var geom []byte
		var text *string
		var pdf *uuid.UUID
		if err := rows.Scan(&id, &typ, &page, &geom, &color, &text, &place, &pdf); err != nil {
			continue
		}
		var g any
		_ = json.Unmarshal(geom, &g)
		out = append(out, map[string]any{
			"id": id.String(), "type": typ, "pageIndex": page, "geometry": g, "color": color,
			"text": text, "placementState": place, "pdfBlobId": uuidStr(pdf),
		})
	}
	if out == nil {
		out = []any{}
	}
	return out
}

func (e *Engine) loadBase(ctx context.Context, tx pgx.Tx, env Envelope, obj objectRow, epoch uuid.UUID) (map[string]any, int64, error) {
	if env.Base == nil {
		return map[string]any{}, 0, nil
	}
	if strings.ToLower(env.Base.Source) == "receipt" {
		oid, err := uuid.Parse(env.Base.OperationID)
		if err != nil {
			return nil, 0, err
		}
		var hash []byte
		var revision int64
		err = tx.QueryRow(ctx, `SELECT result_revision, input_hash FROM operations WHERE library_id=$1 AND epoch=$2 AND operation_id=$3 AND object_id=$4`,
			e.S.LibID, epoch, oid, obj.ID).Scan(&revision, &hash)
		if err != nil {
			return nil, 0, fmt.Errorf("receipt missing")
		}
		if env.Base.Hash != "" && env.Base.Hash != hex.EncodeToString(hash) {
			return nil, 0, fmt.Errorf("receipt hash")
		}
		var raw []byte
		if err = tx.QueryRow(ctx, `SELECT snapshot_bytes FROM revisions WHERE library_id=$1 AND epoch=$2 AND object_id=$3 AND revision=$4`, e.S.LibID, epoch, obj.ID, revision).Scan(&raw); err != nil {
			return nil, 0, fmt.Errorf("receipt revision missing")
		}
		m, err := canon.Parse(raw)
		return m, revision, err
	}
	if env.Base.Source != "revision" && env.Base.Source != "" {
		return nil, 0, fmt.Errorf("unknown base source")
	}
	if env.Base.Revision != obj.Revision && env.Base.Revision != 0 {
		var b []byte
		err := tx.QueryRow(ctx, `SELECT snapshot_bytes FROM revisions WHERE library_id=$1 AND epoch=$2 AND object_id=$3 AND revision=$4`,
			e.S.LibID, epoch, obj.ID, env.Base.Revision).Scan(&b)
		if err != nil {
			return nil, 0, fmt.Errorf("base revision missing")
		}
		m, err := canon.Parse(b)
		return m, env.Base.Revision, err
	}
	return obj.Snapshot, obj.Revision, nil
}

func decodeMaybeB64(s string) ([]byte, error) {
	if strings.HasPrefix(s, "{") {
		return []byte(s), nil
	}
	return []byte(s), nil
}

func (e *Engine) insertObject(ctx context.Context, tx pgx.Tx, id uuid.UUID, kind string, parent uuid.UUID, name string, rev int64, state string, seq int64, snap map[string]any, bytes, hash []byte, op uuid.UUID, epoch uuid.UUID, prev *int64) error {
	var parentArg any
	if parent != uuid.Nil {
		parentArg = parent
	}
	if _, err := tx.Exec(ctx, `INSERT INTO objects(id, library_id, kind, parent_id, name, name_key, revision, state, updated_seq)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)`, id, e.S.LibID, kind, parentArg, name, names.NameKey(name), rev, state, seq); err != nil {
		return err
	}
	metadata, _ := json.Marshal(snap["metadata"])
	if _, err := tx.Exec(ctx, `UPDATE objects SET metadata=$2::jsonb WHERE id=$1`, id, string(metadata)); err != nil {
		return err
	}
	if err := e.setBlobRefs(ctx, tx, "object", id, snap); err != nil {
		return err
	}
	if err := e.setBlobRefs(ctx, tx, fmt.Sprintf("revision:%d", rev), id, snap); err != nil {
		return err
	}
	if kind == "md" || kind == "pdf" {
		var md *string
		var pdf *uuid.UUID
		if s, ok := snap["markdownSource"].(string); ok {
			md = &s
		}
		if s, ok := snap["pdfBlobId"].(string); ok && s != "" {
			u, err := uuid.Parse(s)
			if err == nil {
				pdf = &u
			}
		}
		if _, err := tx.Exec(ctx, `INSERT INTO documents(object_id, markdown_source, pdf_blob_id) VALUES ($1,$2,$3)`, id, md, pdf); err != nil {
			return err
		}
		if err := e.replaceAnns(ctx, tx, id, snap["annotations"]); err != nil {
			return err
		}
	}
	if _, err := tx.Exec(ctx, `INSERT INTO revisions(library_id, epoch, object_id, revision, snapshot_hash, snapshot_bytes, previous_revision, source_operation_id)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8)`, e.S.LibID, epoch, id, rev, hash, bytes, prev, op); err != nil {
		return err
	}
	_, err := tx.Exec(ctx, `UPDATE libraries SET change_seq=$1 WHERE id=$2`, seq, e.S.LibID)
	return err
}

func (e *Engine) updateObject(ctx context.Context, tx pgx.Tx, id uuid.UUID, name string, parent uuid.UUID, rev int64, state string, seq int64, snap map[string]any, bytes, hash []byte, op uuid.UUID, epoch uuid.UUID, prev int64) error {
	var parentArg any
	if parent != uuid.Nil {
		parentArg = parent
	}
	if _, err := tx.Exec(ctx, `UPDATE objects SET name=$2, name_key=$3, parent_id=$4, revision=$5, state=$6, updated_seq=$7 WHERE id=$1`,
		id, name, names.NameKey(name), parentArg, rev, state, seq); err != nil {
		return err
	}
	metadata, _ := json.Marshal(snap["metadata"])
	if _, err := tx.Exec(ctx, `UPDATE objects SET metadata=$2::jsonb WHERE id=$1`, id, string(metadata)); err != nil {
		return err
	}
	if err := e.setBlobRefs(ctx, tx, "object", id, snap); err != nil {
		return err
	}
	if err := e.setBlobRefs(ctx, tx, fmt.Sprintf("revision:%d", rev), id, snap); err != nil {
		return err
	}
	if s, ok := snap["markdownSource"].(string); ok {
		if _, err := tx.Exec(ctx, `UPDATE documents SET markdown_source=$2 WHERE object_id=$1`, id, s); err != nil {
			return fmt.Errorf("update markdown: %w", err)
		}
	}
	if s, ok := snap["pdfBlobId"].(string); ok {
		var pdf *uuid.UUID
		if s != "" {
			u, err := uuid.Parse(s)
			if err == nil {
				pdf = &u
			}
		}
		if _, err := tx.Exec(ctx, `UPDATE documents SET pdf_blob_id=$2 WHERE object_id=$1`, id, pdf); err != nil {
			return fmt.Errorf("update pdf blob: %w", err)
		}
	}
	if err := e.replaceAnns(ctx, tx, id, snap["annotations"]); err != nil {
		return fmt.Errorf("annotations: %w", err)
	}
	if _, err := tx.Exec(ctx, `INSERT INTO revisions(library_id, epoch, object_id, revision, snapshot_hash, snapshot_bytes, previous_revision, source_operation_id)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8)`, e.S.LibID, epoch, id, rev, hash, bytes, prev, op); err != nil {
		return err
	}
	_, err := tx.Exec(ctx, `UPDATE libraries SET change_seq=$1 WHERE id=$2`, seq, e.S.LibID)
	return err
}

func (e *Engine) replaceAnns(ctx context.Context, tx pgx.Tx, doc uuid.UUID, raw any) error {
	if raw == nil {
		return nil
	}
	arr, _ := raw.([]any)
	if _, err := tx.Exec(ctx, `DELETE FROM annotations WHERE document_id=$1`, doc); err != nil {
		return err
	}
	for _, a := range arr {
		m, _ := a.(map[string]any)
		if m == nil {
			continue
		}
		id, _ := uuid.Parse(fmt.Sprint(m["id"]))
		if id == uuid.Nil {
			id, _ = uuid.Parse(fmt.Sprint(m["annotationId"]))
		}
		if id == uuid.Nil {
			id = uuid.New()
		}
		geom, _ := json.Marshal(m["geometry"])
		var text *string
		if t, ok := m["text"].(string); ok {
			text = &t
		}
		place, _ := m["placementState"].(string)
		if place == "" {
			place = "attached"
		}
		typ, _ := m["type"].(string)
		color, _ := m["color"].(string)
		if color == "" {
			color = "#FFE08A"
		}
		page := int(canon.GetInt64(m, "pageIndex"))
		var pdf *uuid.UUID
		if s, ok := m["pdfBlobId"].(string); ok && s != "" {
			u, err := uuid.Parse(s)
			if err == nil {
				pdf = &u
			}
		}
		if _, err := tx.Exec(ctx, `INSERT INTO annotations(id, document_id, pdf_blob_id, type, page_index, geometry, color, text, placement_state)
			VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)`, id, doc, pdf, typ, page, geom, color, text, place); err != nil {
			return err
		}
	}
	return nil
}

func (e *Engine) writeChange(ctx context.Context, tx pgx.Tx, epoch uuid.UUID, seq int64, obj uuid.UUID, rev int64, conflict *uuid.UUID) error {
	return e.writeChanges(ctx, tx, epoch, seq, []uuid.UUID{obj}, conflict)
}

func (e *Engine) writeChanges(ctx context.Context, tx pgx.Tx, epoch uuid.UUID, seq int64, ids []uuid.UUID, conflict *uuid.UUID) error {
	items := []any{}
	for _, id := range ids {
		snap, err := e.LoadPublic(ctx, tx, id)
		if err != nil {
			return err
		}
		items = append(items, map[string]any{"id": id.String(), "revision": snap["revision"], "snapshot": snap})
	}
	man := map[string]any{"objects": items, "deletedIds": []string{}}
	if conflict != nil {
		man["conflictId"] = conflict.String()
	}
	b, err := json.Marshal(man)
	if err != nil {
		return err
	}
	if _, err = tx.Exec(ctx, `INSERT INTO changes(library_id,epoch,seq,event_manifest) VALUES($1,$2,$3,$4::jsonb)`, e.S.LibID, epoch, seq, string(b)); err != nil {
		return err
	}
	_, err = tx.Exec(ctx, `UPDATE libraries SET change_seq=$1 WHERE id=$2 AND change_seq<$1`, seq, e.S.LibID)
	return err
}

func (e *Engine) parentOf(env Envelope) uuid.UUID {
	if env.DesiredSnapshot != nil {
		if s, ok := env.DesiredSnapshot["parentId"].(string); ok && s != "" {
			u, err := uuid.Parse(s)
			if err == nil {
				return u
			}
		}
	}
	return e.S.RootID
}

func (e *Engine) ensureParent(ctx context.Context, tx pgx.Tx, parent uuid.UUID) error {
	if parent == e.S.RootID {
		return nil
	}
	var kind, state string
	err := tx.QueryRow(ctx, `SELECT kind, state FROM objects WHERE id=$1 AND library_id=$2`, parent, e.S.LibID).Scan(&kind, &state)
	if err != nil || kind != "folder" || state != "active" {
		return fmt.Errorf("parent")
	}
	return nil
}

func (e *Engine) checkName(ctx context.Context, tx pgx.Tx, parent uuid.UUID, name string, except uuid.UUID) error {
	var id uuid.UUID
	err := tx.QueryRow(ctx, `SELECT id FROM objects WHERE library_id=$1 AND parent_id=$2 AND name_key=$3 AND state='active' AND id<>$4`,
		e.S.LibID, parent, names.NameKey(name), except).Scan(&id)
	if err == nil {
		return fmt.Errorf("name taken")
	}
	return nil
}

func (e *Engine) uniqueName(ctx context.Context, tx pgx.Tx, parent uuid.UUID, name string, autoSuffix bool) (string, error) {
	if err := e.checkName(ctx, tx, parent, name, uuid.Nil); err == nil {
		return name, nil
	}
	if !autoSuffix {
		return name, fmt.Errorf("name taken")
	}
	taken := map[string]bool{}
	rows, err := tx.Query(ctx, `SELECT name_key FROM objects WHERE library_id=$1 AND parent_id=$2 AND state='active'`, e.S.LibID, parent)
	if err != nil {
		return "", err
	}
	defer rows.Close()
	for rows.Next() {
		var k string
		_ = rows.Scan(&k)
		taken[k] = true
	}
	return names.NextSuffix(name, taken), nil
}

func (e *Engine) UniqueNameAuto(ctx context.Context, tx pgx.Tx, parent uuid.UUID, name string) (string, error) {
	if err := e.checkName(ctx, tx, parent, name, uuid.Nil); err == nil {
		return name, nil
	}
	return e.uniqueName(ctx, tx, parent, name, true)
}

func (e *Engine) wouldCycle(ctx context.Context, tx pgx.Tx, obj, newParent uuid.UUID) error {
	if obj == newParent {
		return fmt.Errorf("cycle")
	}
	cur := newParent
	for i := 0; i < 40; i++ {
		if cur == uuid.Nil || cur == e.S.RootID {
			return nil
		}
		if cur == obj {
			return fmt.Errorf("cycle")
		}
		var p *uuid.UUID
		if err := tx.QueryRow(ctx, `SELECT parent_id FROM objects WHERE id=$1`, cur).Scan(&p); err != nil {
			return nil
		}
		if p == nil {
			return nil
		}
		cur = *p
	}
	return fmt.Errorf("cycle")
}

func (e *Engine) subtree(ctx context.Context, tx pgx.Tx, root uuid.UUID) ([]uuid.UUID, error) {
	rows, err := tx.Query(ctx, `
		WITH RECURSIVE t AS (
			SELECT id FROM objects WHERE parent_id=$1 AND state='active'
			UNION ALL
			SELECT o.id FROM objects o JOIN t ON o.parent_id=t.id WHERE o.state='active'
		) SELECT id FROM t`, root)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var ids []uuid.UUID
	for rows.Next() {
		var id uuid.UUID
		_ = rows.Scan(&id)
		ids = append(ids, id)
	}
	return ids, nil
}

func snapshotFromDesired(kind, name string, parent uuid.UUID, d map[string]any, state string) map[string]any {
	if d == nil {
		d = map[string]any{}
	}
	out := map[string]any{
		"kind":     kind,
		"name":     name,
		"parentId": nil,
		"state":    state,
		"metadata": map[string]any{},
	}
	if metadata, ok := d["metadata"]; ok && metadata != nil {
		out["metadata"] = metadata
	}
	if parent != uuid.Nil {
		out["parentId"] = parent.String()
	}
	if n, ok := d["name"].(string); ok && n != "" {
		out["name"] = n
	}
	if kind == "md" {
		out["markdownSource"] = ""
		if s, ok := d["markdownSource"].(string); ok {
			out["markdownSource"] = s
		}
		if s, ok := d["markdown"].(string); ok && out["markdownSource"] == "" {
			out["markdownSource"] = s
		}
		out["assets"] = d["assets"]
		if out["assets"] == nil {
			out["assets"] = []any{}
		}
	}
	if kind == "pdf" {
		out["pdfBlobId"] = d["pdfBlobId"]
		if out["pdfBlobId"] == nil {
			out["pdfBlobId"] = nil
		}
		out["annotations"] = d["annotations"]
		if out["annotations"] == nil {
			out["annotations"] = []any{}
		}
	}
	return out
}

func nilIfEmpty(s *string) any {
	if s == nil {
		return nil
	}
	return *s
}

func uuidStr(u *uuid.UUID) any {
	if u == nil {
		return nil
	}
	return u.String()
}

func (e *Engine) LoadPublic(ctx context.Context, tx pgx.Tx, id uuid.UUID) (map[string]any, error) {
	obj, err := e.loadObject(ctx, tx, id)
	if err != nil {
		return nil, err
	}
	if obj.PurgeAt != nil && time.Now().UTC().After(*obj.PurgeAt) {
		return nil, ErrGone
	}
	out := obj.Snapshot
	out["id"] = obj.ID.String()
	out["revision"] = fmt.Sprintf("%d", obj.Revision)
	out["state"] = obj.State
	out["trashBatchId"] = uuidStr(obj.TrashBatch)
	if obj.State == "trashed" && obj.OriginalParent != uuid.Nil {
		out["parentId"] = obj.OriginalParent.String()
	}
	rows, err := tx.Query(ctx, `SELECT id FROM conflicts WHERE object_id=$1 AND status='open' ORDER BY id`, id)
	if err != nil {
		return nil, err
	}
	conflictIDs := []string{}
	for rows.Next() {
		var cid uuid.UUID
		if err := rows.Scan(&cid); err != nil {
			rows.Close()
			return nil, err
		}
		conflictIDs = append(conflictIDs, cid.String())
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	out["conflictIds"] = conflictIDs
	if obj.PurgeAt != nil {
		out["purgeAt"] = obj.PurgeAt.UTC().Format(time.RFC3339Nano)
	}
	return out, nil
}
