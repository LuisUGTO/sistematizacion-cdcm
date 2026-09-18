-- ============================================================================
-- HOTFIX 7.6.1 - Visibilidad de Bitácora y Dashboard para SUPERADMIN
--
-- Corrige una regla heredada que sólo reconocía el rol ADMIN al consultar
-- expedientes. SUPERADMIN ya posee privilegios administrativos mediante
-- v2_private.is_admin(), pero esta función aún lo excluía explícitamente.
--
-- Este script NO inserta, elimina, modifica ni reimporta registros.
-- ============================================================================

BEGIN;

DO $$
BEGIN
  IF to_regclass('v2.registros') IS NULL
     OR to_regprocedure('v2_private.is_admin()') IS NULL
     OR to_regprocedure('v2_private.can_read_record(uuid)') IS NULL THEN
    RAISE EXCEPTION
      'PRECONDICION_FALLIDA: faltan objetos V2 requeridos para el hotfix.';
  END IF;
END
$$;

CREATE OR REPLACE FUNCTION v2_private.can_read_record(
  p_registro UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  r       RECORD;
  v_role  TEXT;
  v_uid   UUID := auth.uid();
BEGIN
  IF v_uid IS NULL OR NOT v2_private.is_active_user() THEN
    RETURN false;
  END IF;

  SELECT
    x.created_by,
    x.unidad_operativa_id,
    x.municipio_id
  INTO r
  FROM v2.registros x
  WHERE x.id = p_registro;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  -- is_admin() incluye ADMIN y SUPERADMIN.
  IF v2_private.is_admin() THEN
    RETURN true;
  END IF;

  v_role := v2_private.current_role();

  IF v_role IN ('SUPERVISOR', 'DIRECTIVO') THEN
    RETURN v2_private.has_scope(
      r.unidad_operativa_id,
      r.municipio_id
    );
  END IF;

  IF v_role = 'CAPTURISTA' THEN
    RETURN r.created_by = v_uid;
  END IF;

  RETURN false;
END;
$$;

REVOKE ALL ON FUNCTION v2_private.can_read_record(UUID)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION v2_private.can_read_record(UUID)
  TO authenticated;

INSERT INTO v2.schema_migrations (version, descripcion)
VALUES (
  '2.1.12y',
  '12y_hotfix_superadmin_bitacora.sql - SUPERADMIN puede consultar expedientes activos mediante RLS.'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- Verificación: debe devolver true en "usa_helper_admin" y 1 en "migracion".
SELECT
  pg_get_functiondef(
    'v2_private.can_read_record(uuid)'::regprocedure
  ) ILIKE '%v2_private.is_admin()%' AS usa_helper_admin,
  (
    SELECT count(*)
    FROM v2.schema_migrations
    WHERE version = '2.1.12y'
  ) AS migracion;
