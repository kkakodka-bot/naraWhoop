-- Reset serial/identity sequences after a data-only restore.
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT
      pg_get_serial_sequence(quote_ident(n.nspname) || '.' || quote_ident(c.relname), a.attname) AS seq,
      quote_ident(n.nspname) || '.' || quote_ident(c.relname) AS tbl,
      a.attname AS col
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
    WHERE c.relkind = 'r'
      AND n.nspname = 'public'
      AND pg_get_serial_sequence(quote_ident(n.nspname) || '.' || quote_ident(c.relname), a.attname) IS NOT NULL
  LOOP
    EXECUTE format(
      'SELECT setval(%L, COALESCE((SELECT MAX(%I) FROM %s), 1))',
      r.seq, r.col, r.tbl
    );
  END LOOP;
END $$;
