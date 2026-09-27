-- TokenLibrary fixed schema v1. Fingerprint is SHA-256 of this file (LF, no trailing spaces).
CREATE TABLE schema_info (
    fingerprint TEXT PRIMARY KEY,
    initialized_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE libraries (
    id UUID PRIMARY KEY,
    epoch UUID NOT NULL,
    root_id UUID NOT NULL,
    change_seq BIGINT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    maintenance BOOLEAN NOT NULL DEFAULT FALSE,
    credential_generation INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE devices (
    id UUID PRIMARY KEY,
    library_id UUID NOT NULL REFERENCES libraries(id),
    name TEXT NOT NULL,
    platform TEXT NOT NULL,
    last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE sessions (
    id UUID PRIMARY KEY,
    device_id UUID NOT NULL REFERENCES devices(id),
    library_id UUID NOT NULL REFERENCES libraries(id),
    token_hash BYTEA NOT NULL UNIQUE,
    last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    revoked_at TIMESTAMPTZ,
    credential_generation INTEGER NOT NULL
);

CREATE TABLE objects (
    id UUID PRIMARY KEY,
    library_id UUID NOT NULL REFERENCES libraries(id),
    kind TEXT NOT NULL CHECK (kind IN ('folder', 'md', 'pdf')),
    parent_id UUID,
    name TEXT NOT NULL,
    name_key TEXT NOT NULL,
    revision BIGINT NOT NULL DEFAULT 0,
    state TEXT NOT NULL CHECK (state IN ('active', 'trashed', 'purged')),
    deleted_at TIMESTAMPTZ,
    purge_at TIMESTAMPTZ,
    trash_batch_id UUID,
    original_parent_id UUID,
    updated_seq BIGINT NOT NULL DEFAULT 0
);

CREATE UNIQUE INDEX objects_active_name ON objects (library_id, parent_id, name_key) WHERE state = 'active' AND parent_id IS NOT NULL;
CREATE INDEX objects_parent_state ON objects (parent_id, state, name_key);
CREATE INDEX objects_purge ON objects (purge_at) WHERE state = 'trashed';
CREATE INDEX objects_updated_seq ON objects (updated_seq);

CREATE TABLE documents (
    object_id UUID PRIMARY KEY REFERENCES objects(id),
    markdown_source TEXT,
    pdf_blob_id UUID
);

CREATE TABLE annotations (
    id UUID PRIMARY KEY,
    document_id UUID NOT NULL REFERENCES documents(object_id),
    pdf_blob_id UUID,
    type TEXT NOT NULL CHECK (type IN ('highlight', 'comment')),
    page_index INTEGER NOT NULL,
    geometry JSONB NOT NULL,
    color TEXT NOT NULL,
    text TEXT,
    placement_state TEXT NOT NULL CHECK (placement_state IN ('attached', 'needs_review'))
);

CREATE TABLE revisions (
    library_id UUID NOT NULL,
    epoch UUID NOT NULL,
    object_id UUID NOT NULL,
    revision BIGINT NOT NULL,
    snapshot_hash BYTEA NOT NULL,
    snapshot_bytes BYTEA NOT NULL,
    previous_revision BIGINT,
    source_operation_id UUID,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (library_id, epoch, object_id, revision)
);

CREATE TABLE operations (
    library_id UUID NOT NULL,
    epoch UUID NOT NULL,
    operation_id UUID NOT NULL,
    principal_kind TEXT NOT NULL,
    action TEXT NOT NULL,
    object_id UUID,
    request_hash BYTEA NOT NULL,
    input_hash BYTEA NOT NULL,
    status TEXT NOT NULL,
    result_revision BIGINT,
    result_seq BIGINT,
    conflict_ids JSONB,
    result_json JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (library_id, epoch, operation_id)
);

CREATE TABLE changes (
    library_id UUID NOT NULL,
    epoch UUID NOT NULL,
    seq BIGINT NOT NULL,
    event_manifest JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (library_id, epoch, seq)
);

CREATE TABLE conflicts (
    id UUID PRIMARY KEY,
    object_id UUID NOT NULL,
    kind TEXT NOT NULL,
    base_ref JSONB NOT NULL,
    local_snapshot BYTEA NOT NULL,
    remote_ref JSONB NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('open', 'resolved')),
    revision BIGINT NOT NULL,
    conflict_revision BIGINT NOT NULL DEFAULT 1,
    source_operation_id UUID,
    local_hash BYTEA,
    remote_hash BYTEA,
    base_hash BYTEA
);

CREATE INDEX conflicts_object_status ON conflicts (object_id, status);

CREATE TABLE conflict_drafts (
    id UUID PRIMARY KEY,
    conflict_id UUID NOT NULL REFERENCES conflicts(id),
    device_id UUID NOT NULL,
    revision BIGINT NOT NULL,
    body BYTEA NOT NULL,
    seen_conflict_revision BIGINT NOT NULL
);

CREATE TABLE tombstones (
    library_id UUID NOT NULL,
    object_id UUID NOT NULL,
    kind TEXT NOT NULL,
    purged_at TIMESTAMPTZ NOT NULL,
    purge_seq BIGINT NOT NULL,
    PRIMARY KEY (library_id, object_id)
);

CREATE TABLE blobs (
    id UUID PRIMARY KEY,
    library_id UUID NOT NULL REFERENCES libraries(id),
    sha256 BYTEA NOT NULL,
    size BIGINT NOT NULL,
    mime TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('staging', 'ready', 'unavailable', 'deleting')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    unreferenced_at TIMESTAMPTZ,
    password_required BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX blobs_sha ON blobs (sha256);

CREATE TABLE blob_refs (
    blob_id UUID NOT NULL REFERENCES blobs(id),
    owner_kind TEXT NOT NULL,
    owner_id UUID NOT NULL,
    slot TEXT NOT NULL,
    PRIMARY KEY (blob_id, owner_kind, owner_id, slot)
);

CREATE TABLE uploads (
    id UUID PRIMARY KEY,
    library_id UUID NOT NULL,
    epoch UUID NOT NULL,
    owner_kind TEXT NOT NULL,
    owner_id UUID NOT NULL,
    blob_id UUID NOT NULL,
    expected_size BIGINT NOT NULL,
    expected_hash BYTEA NOT NULL,
    mime TEXT NOT NULL,
    state TEXT NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    chunk_size INTEGER NOT NULL DEFAULT 1048576
);

CREATE TABLE upload_chunks (
    upload_id UUID NOT NULL REFERENCES uploads(id),
    chunk_index INTEGER NOT NULL,
    size INTEGER NOT NULL,
    sha256 BYTEA NOT NULL,
    relative_path TEXT NOT NULL,
    PRIMARY KEY (upload_id, chunk_index)
);

CREATE TABLE sync_snapshots (
    id UUID PRIMARY KEY,
    library_id UUID NOT NULL,
    epoch UUID NOT NULL,
    at_seq BIGINT NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    state TEXT NOT NULL
);

CREATE TABLE sync_snapshot_items (
    snapshot_id UUID NOT NULL REFERENCES sync_snapshots(id),
    item_id UUID NOT NULL,
    kind TEXT NOT NULL,
    revision_ref BIGINT,
    frozen_content BYTEA,
    hash BYTEA,
    PRIMARY KEY (snapshot_id, item_id)
);

CREATE TABLE jobs (
    id UUID PRIMARY KEY,
    type TEXT NOT NULL,
    scheduled_for TIMESTAMPTZ NOT NULL,
    attempt INTEGER NOT NULL DEFAULT 0,
    run_id UUID,
    state TEXT NOT NULL,
    heartbeat_at TIMESTAMPTZ,
    error_code TEXT,
    error_summary TEXT
);

CREATE TABLE backups (
    id UUID PRIMARY KEY,
    snapshot_at TIMESTAMPTZ NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    path TEXT NOT NULL,
    manifest_hash BYTEA,
    state TEXT NOT NULL,
    verified_at TIMESTAMPTZ
);

CREATE INDEX backups_expires ON backups (expires_at, state);
CREATE INDEX jobs_type_sched ON jobs (type, scheduled_for);
CREATE INDEX uploads_expires ON uploads (expires_at, state);
