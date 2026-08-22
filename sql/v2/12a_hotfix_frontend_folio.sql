-- ============================================================================
-- VINCULACIÓN CULTURAL 2.0
-- 12a_hotfix_frontend_folio.sql
-- Hotfix de generación de folio desde frontend autenticado
-- ============================================================================

BEGIN;

SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '60s';

DO $$
BEGIN
  IF to_regprocedure('v2.prepare_registro_insert()') IS NULL
     OR to_regprocedure('v2.next_folio(integer)') IS NULL THEN
    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: faltan prepare_registro_insert() o next_folio(integer).';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM v2.schema_migrations
    WHERE version = '2.1.10'
  ) THEN
    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: la migración productiva V2.1 no está registrada.';
  END IF;
END
$$;

-- El trigger debe poder llamar internamente a next_folio aunque
-- authenticated NO tenga EXECUTE directo sobre next_folio.
ALTER FUNCTION v2.prepare_registro_insert()
  SECURITY DEFINER;

-- Mantener ambas funciones cerradas a ejecución directa desde cliente.
REVOKE ALL ON FUNCTION v2.prepare_registro_insert()
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION v2.next_folio(INTEGER)
  FROM PUBLIC, anon, authenticated;

INSERT INTO v2.schema_migrations (
  version,
  descripcion
)
VALUES (
  '2.1.12a',
  '12a_hotfix_frontend_folio.sql - prepare_registro_insert SECURITY DEFINER para folio atómico desde INSERT autenticado sin exponer next_folio como RPC.'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- Resultado esperado:
-- true | false | false | true | 1
SELECT
  (
    SELECT p.prosecdef
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'v2'
      AND p.proname = 'prepare_registro_insert'
      AND pg_get_function_identity_arguments(p.oid) = ''
    LIMIT 1
  ) AS prepare_es_security_definer,

  pg_catalog.has_function_privilege(
    'authenticated',
    'v2.prepare_registro_insert()',
    'EXECUTE'
  ) AS authenticated_puede_ejecutar_prepare_directo,

  pg_catalog.has_function_privilege(
    'authenticated',
    'v2.next_folio(integer)',
    'EXECUTE'
  ) AS authenticated_puede_ejecutar_next_folio_directo,

  EXISTS (
    SELECT 1
    FROM pg_trigger t
    WHERE t.tgrelid = 'v2.registros'::regclass
      AND t.tgname = 'trg_v2_registro_prepare_insert'
      AND NOT t.tgisinternal
  ) AS trigger_folio_existe,

  (
    SELECT count(*)
    FROM v2.schema_migrations
    WHERE version = '2.1.12a'
  ) AS migracion_registrada;
