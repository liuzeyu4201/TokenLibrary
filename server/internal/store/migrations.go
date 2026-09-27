package store

import "context"

// Keep the v1 baseline fingerprint unchanged, so existing libraries can open.
// Additive, transactional feature migrations are recorded independently.
func (s *Store) ensureFeatures(ctx context.Context) error {
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err = tx.Exec(ctx, `SELECT pg_advisory_xact_lock(847301592)`); err != nil {
		return err
	}
	if _, err = tx.Exec(ctx, `
		CREATE TABLE IF NOT EXISTS app_migrations(version TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT now());
		ALTER TABLE objects ADD COLUMN IF NOT EXISTS metadata JSONB NOT NULL DEFAULT '{}'::jsonb;
		ALTER TABLE sync_snapshot_items ADD COLUMN IF NOT EXISTS ordinal BIGINT;
		CREATE INDEX IF NOT EXISTS sync_snapshot_items_page ON sync_snapshot_items(snapshot_id,ordinal);
		INSERT INTO app_migrations(version) VALUES ('v2-library-sync') ON CONFLICT DO NOTHING;
	`); err != nil {
		return err
	}
	// Annotation identity belongs to a document. Recovery/import copies preserve
	// annotation IDs (also embedded in PDF /NM), so a global ID key rejects a
	// legitimate copy. Keep existing rows and frozen operation payloads intact.
	if _, err = tx.Exec(ctx, `
		DO $migration$
		DECLARE key_name text; key_columns text[];
		BEGIN
			SELECT c.conname, ARRAY(
				SELECT a.attname::text FROM unnest(c.conkey) WITH ORDINALITY k(attnum, position)
				JOIN pg_attribute a ON a.attrelid=c.conrelid AND a.attnum=k.attnum
				ORDER BY k.position
			) INTO key_name, key_columns
			FROM pg_constraint c WHERE c.conrelid='annotations'::regclass AND c.contype='p';
			IF key_columns = ARRAY['id']::text[] THEN
				EXECUTE format('ALTER TABLE annotations DROP CONSTRAINT %I', key_name);
				ALTER TABLE annotations ADD CONSTRAINT annotations_pkey PRIMARY KEY(document_id,id);
			ELSIF key_columns IS DISTINCT FROM ARRAY['document_id','id']::text[] THEN
				RAISE EXCEPTION 'unexpected annotations primary key: %', key_columns;
			END IF;
		END $migration$;
		INSERT INTO app_migrations(version) VALUES ('v3-document-annotation-identity') ON CONFLICT DO NOTHING;
	`); err != nil {
		return err
	}
	return tx.Commit(ctx)
}
