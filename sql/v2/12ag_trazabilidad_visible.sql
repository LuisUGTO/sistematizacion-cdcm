-- ============================================================================
-- ETAPA 7.7.7 - TRAZABILIDAD VISIBLE PARA EXPEDIENTES
-- Expone de forma segura la auditoría que ya conserva V2.
-- No modifica registros, permisos de captura ni historial existente.
-- ============================================================================

BEGIN;

DO $$
BEGIN
  IF to_regclass('v2.registros') IS NULL
     OR to_regclass('v2.audit_log') IS NULL
     OR to_regclass('v2.profiles') IS NULL
     OR to_regprocedure('v2_private.can_read_record(uuid)') IS NULL THEN
    RAISE EXCEPTION 'PRECONDICION: faltan objetos V2 de registros, auditoría o seguridad.';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION v2.rpc_get_registro_trazabilidad(
  p_registro_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_result JSONB;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED: se requiere una sesión autenticada.';
  END IF;

  IF NOT v2_private.can_read_record(p_registro_id) THEN
    RAISE EXCEPTION 'TRACEABILITY_SCOPE_FORBIDDEN: expediente fuera de tu alcance.';
  END IF;

  WITH expediente AS (
    SELECT r.id, r.created_at, r.updated_at, r.created_by, r.updated_by
    FROM v2.registros r
    WHERE r.id = p_registro_id
      AND r.deleted_at IS NULL
  ),
  eventos_base AS (
    SELECT
      a.accion,
      a.user_email,
      a.created_at,
      a.valor_anterior,
      a.valor_nuevo
    FROM v2.audit_log a
    WHERE a.schema_name = 'v2'
      AND a.table_name = 'registros'
      AND a.record_id = p_registro_id::TEXT
    ORDER BY a.created_at DESC
    LIMIT 20
  ),
  eventos AS (
    SELECT jsonb_build_object(
      'accion', e.accion,
      'correo', e.user_email,
      'fecha', e.created_at,
      'campos', COALESCE((
        SELECT jsonb_agg(k.clave ORDER BY k.clave)
        FROM (
          SELECT clave
          FROM (
            SELECT jsonb_object_keys(COALESCE(e.valor_anterior, '{}'::JSONB)) AS clave
            UNION
            SELECT jsonb_object_keys(COALESCE(e.valor_nuevo, '{}'::JSONB)) AS clave
          ) claves
        ) k
        WHERE COALESCE(e.valor_anterior, '{}'::JSONB) -> k.clave
          IS DISTINCT FROM COALESCE(e.valor_nuevo, '{}'::JSONB) -> k.clave
          AND k.clave NOT IN ('updated_at', 'updated_by', 'row_version')
      ), '[]'::JSONB)
    ) AS item
    FROM eventos_base e
  )
  SELECT jsonb_build_object(
    'creado_por', COALESCE(cp.email, 'Usuario histórico o no disponible'),
    'creado_en', x.created_at,
    'actualizado_por', COALESCE(up.email, 'Usuario histórico o no disponible'),
    'actualizado_en', x.updated_at,
    'eventos', COALESCE((SELECT jsonb_agg(item) FROM eventos), '[]'::JSONB)
  ) INTO v_result
  FROM expediente x
  LEFT JOIN v2.profiles cp ON cp.user_id = x.created_by
  LEFT JOIN v2.profiles up ON up.user_id = x.updated_by;

  IF v_result IS NULL THEN
    RAISE EXCEPTION 'RECORD_NOT_FOUND: el expediente no existe o fue retirado.';
  END IF;

  RETURN v_result;
END;
$function$;

COMMENT ON FUNCTION v2.rpc_get_registro_trazabilidad(UUID) IS
'Huella digital de un expediente dentro del alcance autorizado: creador, última actualización y eventos auditados.';

REVOKE ALL ON FUNCTION v2.rpc_get_registro_trazabilidad(UUID)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION v2.rpc_get_registro_trazabilidad(UUID)
TO authenticated;

INSERT INTO v2.schema_migrations(version, descripcion)
VALUES ('2.1.12ag', '12ag_trazabilidad_visible.sql - Huella digital visible y segura por expediente.')
ON CONFLICT (version) DO NOTHING;

COMMIT;

SELECT
  to_regprocedure('v2.rpc_get_registro_trazabilidad(uuid)') IS NOT NULL AS rpc_existe,
  has_function_privilege('authenticated', 'v2.rpc_get_registro_trazabilidad(uuid)', 'EXECUTE') AS authenticated_execute,
  NOT has_function_privilege('anon', 'v2.rpc_get_registro_trazabilidad(uuid)', 'EXECUTE') AS anon_bloqueado,
  (SELECT count(*) FROM v2.schema_migrations WHERE version = '2.1.12ag') AS migracion;
-- Esperado: true | true | true | 1
