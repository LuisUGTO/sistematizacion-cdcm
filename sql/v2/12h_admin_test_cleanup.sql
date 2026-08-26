-- ============================================================================
-- VINCULACION CULTURAL 2.0
-- 12h_admin_test_cleanup.sql
-- Etapa 6.2: administración V2 y retiro seguro de registros de prueba
-- Secretaria de Cultura de Guanajuato
--
-- REQUIERE:
--   06_rls.sql
--   05_functions_triggers.sql
--   12g_dashboard_directivo.sql
--
-- CREA:
--   v2.rpc_retirar_registro_prueba(uuid, text)
--
-- SEGURIDAD:
--   - Solo ADMIN autenticado puede ejecutar la RPC.
--   - Nunca elimina físicamente registros.
--   - Solo admite registros de origen MANUAL; protege MIGRACION_V1,
--     importaciones y cualquier otro origen institucional.
--   - Conserva transición ANULADO, historial y auditoría existentes.
-- ============================================================================

BEGIN;

SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '60s';


-- ============================================================================
-- 00. PRECONDICIONES
-- ============================================================================

DO $$
BEGIN
  IF to_regclass('v2.registros') IS NULL
     OR to_regclass('v2.registro_validaciones') IS NULL
     OR to_regprocedure('v2_private.is_admin()') IS NULL THEN
    RAISE EXCEPTION
      'PRECONDICION FALLIDA: faltan objetos V2 requeridos para el retiro de pruebas.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM v2.schema_migrations
    WHERE version = '2.1.12g'
  ) THEN
    RAISE EXCEPTION
      'PRECONDICION FALLIDA: primero debe instalarse 12g_dashboard_directivo.sql.';
  END IF;
END
$$;


-- ============================================================================
-- 01. RETIRO LÓGICO DE UN REGISTRO MANUAL DE PRUEBA
--
-- El registro no se borra: se anula y se marca deleted_at/deleted_by.
-- Las vistas V2 ya excluyen deleted_at IS NOT NULL, por lo que desaparece
-- de la operación cotidiana pero mantiene la trazabilidad requerida.
-- ============================================================================

CREATE OR REPLACE FUNCTION v2.rpc_retirar_registro_prueba(
  p_registro_id          UUID,
  p_folio_confirmacion   TEXT
)
RETURNS TABLE (
  id          UUID,
  folio       TEXT,
  estatus     TEXT,
  deleted_at  TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid       UUID := auth.uid();
  v_record    v2.registros%ROWTYPE;
  v_retired   v2.registros%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION
      'AUTH_REQUIRED: se requiere una sesión autenticada.';
  END IF;

  IF NOT v2_private.is_admin() THEN
    RAISE EXCEPTION
      'ADMIN_REQUIRED: solo ADMIN puede retirar registros de prueba.';
  END IF;

  SELECT r.*
  INTO v_record
  FROM v2.registros r
  WHERE r.id = p_registro_id
    AND r.deleted_at IS NULL
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'RECORD_NOT_FOUND: el registro no existe o ya fue retirado.';
  END IF;

  IF v_record.origen <> 'MANUAL' THEN
    RAISE EXCEPTION
      'TEST_RECORD_ONLY: solo se pueden retirar registros de origen MANUAL.';
  END IF;

  IF pg_catalog.btrim(COALESCE(p_folio_confirmacion, ''))
       IS DISTINCT FROM pg_catalog.btrim(COALESCE(v_record.folio, '')) THEN
    RAISE EXCEPTION
      'FOLIO_CONFIRMATION_REQUIRED: confirma exactamente el folio del registro.';
  END IF;

  UPDATE v2.registros AS r
  SET
    estatus = 'ANULADO',
    deleted_at = pg_catalog.now(),
    deleted_by = v_uid,
    updated_by = v_uid
  WHERE r.id = v_record.id
  RETURNING r.* INTO v_retired;

  -- El trigger ya generó el historial de transición a ANULADO. Se documenta
  -- el motivo sin borrar ni modificar el contenido operativo del expediente.
  UPDATE v2.registro_validaciones rv
  SET observacion =
    'Retiro administrativo de registro MANUAL para depuración de pruebas.'
  WHERE rv.id = (
    SELECT rv2.id
    FROM v2.registro_validaciones rv2
    WHERE rv2.registro_id = v_retired.id
      AND rv2.estatus_nuevo = 'ANULADO'
    ORDER BY rv2.created_at DESC, rv2.id DESC
    LIMIT 1
  );

  RETURN QUERY
  SELECT
    v_retired.id,
    v_retired.folio,
    v_retired.estatus,
    v_retired.deleted_at;
END;
$function$;


COMMENT ON FUNCTION v2.rpc_retirar_registro_prueba(UUID, TEXT) IS
'Retiro lógico de registros MANUAL de prueba. Solo ADMIN autenticado; protege históricos, importaciones y auditoría V2.';


-- ============================================================================
-- 02. PERMISOS
-- ============================================================================

REVOKE ALL ON FUNCTION v2.rpc_retirar_registro_prueba(UUID, TEXT)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION v2.rpc_retirar_registro_prueba(UUID, TEXT)
  TO authenticated;


-- ============================================================================
-- 03. REGISTRO DE MIGRACION
-- ============================================================================

INSERT INTO v2.schema_migrations (
  version,
  descripcion
)
VALUES (
  '2.1.12h',
  '12h_admin_test_cleanup.sql - Panel administrativo V2 y retiro lógico de registros MANUAL de prueba solo para ADMIN.'
)
ON CONFLICT (version) DO NOTHING;


COMMIT;


-- ============================================================================
-- 04. VERIFICACION POST-INSTALACION
-- ============================================================================

SELECT
  (
    to_regprocedure(
      'v2.rpc_retirar_registro_prueba(uuid,text)'
    ) IS NOT NULL
  ) AS rpc_retiro_existe,

  COALESCE(
    has_function_privilege(
      'authenticated',
      'v2.rpc_retirar_registro_prueba(uuid,text)',
      'EXECUTE'
    ),
    false
  ) AS authenticated_execute,

  COALESCE(
    has_function_privilege(
      'anon',
      'v2.rpc_retirar_registro_prueba(uuid,text)',
      'EXECUTE'
    ),
    false
  ) AS anon_execute,

  COALESCE(
    (
      SELECT p.prosecdef
      FROM pg_proc p
      JOIN pg_namespace n
        ON n.oid = p.pronamespace
      WHERE n.nspname = 'v2'
        AND p.proname = 'rpc_retirar_registro_prueba'
        AND pg_catalog.pg_get_function_identity_arguments(p.oid)
          = 'p_registro_id uuid, p_folio_confirmacion text'
      LIMIT 1
    ),
    false
  ) AS security_definer,

  (
    SELECT count(*)
    FROM v2.schema_migrations
    WHERE version = '2.1.12h'
  ) AS migracion_registrada;


-- RESULTADO ESPERADO:
-- rpc_retiro_existe | authenticated_execute | anon_execute | security_definer | migracion_registrada
-- true              | true                  | false        | true             | 1
