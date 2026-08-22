-- ============================================================================
-- VINCULACIÓN CULTURAL 2.0
-- 12b_hotfix_registros_insert_rls.sql
-- Corrección definitiva de INSERT RLS + identidad de captura
-- ============================================================================

BEGIN;

SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '60s';

DO $$
BEGIN
  IF to_regclass('v2.registros') IS NULL
     OR to_regprocedure('v2.prepare_registro_insert()') IS NULL
     OR to_regprocedure('v2_private.can_create_record(uuid,uuid)') IS NULL THEN
    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: faltan objetos requeridos para el hotfix 12b.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM v2.schema_migrations
    WHERE version = '2.1.12a'
  ) THEN
    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: ejecute primero 12a_hotfix_frontend_folio.sql.';
  END IF;
END
$$;


-- ============================================================================
-- 01. IDENTIDAD DEL REGISTRO: LA IMPONE EL SERVIDOR
--
-- No confiamos en created_by enviado por el navegador.
-- La función trigger fuerza siempre auth.uid().
-- ============================================================================

CREATE OR REPLACE FUNCTION v2.prepare_registro_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid UUID := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED: se requiere una sesión autenticada para crear registros.';
  END IF;

  -- Nunca confiar en created_by/updated_by provenientes del cliente.
  NEW.created_by := v_uid;
  NEW.updated_by := v_uid;

  IF NEW.folio IS NULL OR pg_catalog.btrim(NEW.folio) = '' THEN
    NEW.folio := v2.next_folio(NEW.periodo_anio);
  END IF;

  NEW.created_at := COALESCE(
    NEW.created_at,
    pg_catalog.now()
  );

  NEW.updated_at := pg_catalog.now();
  NEW.row_version := 1;

  RETURN NEW;
END;
$$;


-- Las funciones siguen siendo internas a triggers.
REVOKE ALL ON FUNCTION v2.prepare_registro_insert()
FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION v2.next_folio(INTEGER)
FROM PUBLIC, anon, authenticated;


-- ============================================================================
-- 02. POLICY INSERT
--
-- La autorización determina QUIÉN puede crear y DÓNDE.
-- La identidad created_by ya la fuerza el trigger anterior.
-- ============================================================================

DROP POLICY IF EXISTS registros_insert
ON v2.registros;

CREATE POLICY registros_insert
ON v2.registros
FOR INSERT
TO authenticated
WITH CHECK (
  (
    SELECT v2_private.can_create_record(
      unidad_operativa_id,
      municipio_id
    )
  )
);


-- ============================================================================
-- 03. REGISTRO DE MIGRACIÓN
-- ============================================================================

INSERT INTO v2.schema_migrations (
  version,
  descripcion
)
VALUES (
  '2.1.12b',
  '12b_hotfix_registros_insert_rls.sql - Identidad created_by forzada por trigger y policy INSERT basada exclusivamente en autorización can_create_record.'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;


-- ============================================================================
-- 04. VERIFICACIÓN
--
-- Esperado:
-- 1 | true | false | false | 1
-- ============================================================================

SELECT
  (
    SELECT count(*)
    FROM pg_policies
    WHERE schemaname = 'v2'
      AND tablename = 'registros'
      AND policyname = 'registros_insert'
  ) AS policy_insert,

  (
    SELECT p.prosecdef
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'v2'
      AND p.proname = 'prepare_registro_insert'
      AND pg_get_function_identity_arguments(p.oid) = ''
    LIMIT 1
  ) AS prepare_security_definer,

  pg_catalog.has_function_privilege(
    'authenticated',
    'v2.prepare_registro_insert()',
    'EXECUTE'
  ) AS authenticated_prepare_directo,

  pg_catalog.has_function_privilege(
    'authenticated',
    'v2.next_folio(integer)',
    'EXECUTE'
  ) AS authenticated_next_folio_directo,

  (
    SELECT count(*)
    FROM v2.schema_migrations
    WHERE version = '2.1.12b'
  ) AS migracion_registrada;
