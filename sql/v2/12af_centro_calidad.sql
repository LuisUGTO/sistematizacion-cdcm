-- ============================================================================
-- ETAPA 7.7.5 - CENTRO DE CALIDAD Y VALIDACIÓN PRIORIZADA
-- Lectura interna. No modifica registros, estatus ni historial.
-- ============================================================================

BEGIN;

DO $$
BEGIN
  IF to_regclass('v2.registros') IS NULL
     OR to_regclass('v2.vw_calidad_datos') IS NULL
     OR to_regprocedure('v2.rpc_inteligencia_cultural(integer,uuid,uuid,uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'PRECONDICION: ejecuta primero 12ac y 12ad de Inteligencia Cultural.';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION v2.rpc_inteligencia_calidad(
  p_anio INTEGER DEFAULT NULL,
  p_unidad UUID DEFAULT NULL,
  p_programa UUID DEFAULT NULL,
  p_municipio UUID DEFAULT NULL,
  p_modo TEXT DEFAULT 'OPERATIVO'
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $function$
DECLARE
  v_role TEXT;
  v_result JSONB;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED: se requiere una sesión autenticada.';
  END IF;

  v_role := v2_private.current_role();
  IF v_role NOT IN ('SUPERADMIN', 'ADMIN', 'SUPERVISOR') THEN
    RAISE EXCEPTION 'ROLE_FORBIDDEN: el Centro de calidad es de uso interno para administración y supervisión.';
  END IF;

  WITH base AS MATERIALIZED (
    SELECT
      r.id, r.folio, r.nombre, r.estatus, r.updated_at,
      r.unidad_operativa_id, r.programa_id, r.municipio_id,
      u.nombre AS unidad_nombre, p.nombre AS programa_nombre,
      m.nombre_oficial AS municipio_nombre,
      COALESCE(q.incidencias, ARRAY[]::TEXT[]) AS incidencias,
      COALESCE(q.total_incidencias, 0)::INTEGER AS total_incidencias
    FROM v2.registros r
    LEFT JOIN v2.vw_calidad_datos q ON q.id = r.id
    LEFT JOIN v2.cat_unidades_operativas u ON u.id = r.unidad_operativa_id
    LEFT JOIN v2.cat_programas p ON p.id = r.programa_id
    LEFT JOIN v2.cat_municipios m ON m.id = r.municipio_id
    WHERE r.deleted_at IS NULL
      AND r.periodo_anio = COALESCE(p_anio, EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER)
      AND (p_unidad IS NULL OR r.unidad_operativa_id = p_unidad)
      AND (p_programa IS NULL OR r.programa_id = p_programa)
      AND (p_municipio IS NULL OR r.municipio_id = p_municipio)
      AND r.estatus IN ('CAPTURADO', 'EN_REVISION', 'OBSERVADO', 'CORREGIDO')
  ),
  clasificados AS MATERIALIZED (
    SELECT
      b.*,
      CASE
        WHEN b.estatus = 'EN_REVISION' AND b.total_incidencias = 0 THEN 'LISTO_PARA_VALIDAR'
        WHEN b.estatus = 'EN_REVISION' THEN 'BLOQUEADO'
        WHEN b.estatus = 'OBSERVADO' THEN 'PENDIENTE_CORRECCION'
        WHEN b.estatus = 'CORREGIDO' THEN 'PENDIENTE_RE_REVISION'
        ELSE 'PENDIENTE_ENVIO'
      END AS prioridad,
      (CURRENT_DATE - b.updated_at::DATE)::INTEGER AS dias_sin_movimiento
    FROM base b
  ),
  resumen AS (
    SELECT
      COUNT(*)::BIGINT AS pendientes_totales,
      COUNT(*) FILTER (WHERE estatus = 'EN_REVISION')::BIGINT AS en_revision,
      COUNT(*) FILTER (WHERE estatus = 'OBSERVADO')::BIGINT AS observados,
      COUNT(*) FILTER (WHERE prioridad = 'LISTO_PARA_VALIDAR')::BIGINT AS listos_para_validar,
      COUNT(*) FILTER (WHERE total_incidencias > 0)::BIGINT AS bloqueados
    FROM clasificados
  ),
  incidencias AS (
    SELECT incidencia, COUNT(*)::BIGINT AS registros
    FROM clasificados c
    CROSS JOIN LATERAL unnest(c.incidencias) AS incidencia
    GROUP BY incidencia
  ),
  prioridades AS (
    SELECT *
    FROM clasificados
    ORDER BY
      CASE prioridad
        WHEN 'LISTO_PARA_VALIDAR' THEN 1
        WHEN 'BLOQUEADO' THEN 2
        WHEN 'PENDIENTE_CORRECCION' THEN 3
        WHEN 'PENDIENTE_RE_REVISION' THEN 4
        ELSE 5
      END,
      dias_sin_movimiento DESC,
      updated_at ASC
    LIMIT 20
  )
  SELECT jsonb_build_object(
    'resumen', COALESCE((SELECT to_jsonb(r) FROM resumen r), '{}'::JSONB),
    'incidencias', COALESCE((SELECT jsonb_agg(to_jsonb(i) ORDER BY i.registros DESC, i.incidencia) FROM incidencias i), '[]'::JSONB),
    'prioridades', COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id', p.id, 'folio', p.folio, 'nombre', p.nombre, 'estatus', p.estatus,
      'prioridad', p.prioridad, 'dias_sin_movimiento', p.dias_sin_movimiento,
      'unidad_nombre', p.unidad_nombre, 'programa_nombre', p.programa_nombre,
      'municipio_nombre', p.municipio_nombre, 'incidencias', p.incidencias,
      'total_incidencias', p.total_incidencias
    )) FROM prioridades p), '[]'::JSONB),
    'ejercicio', COALESCE(p_anio, EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER),
    'generado_at', now()
  ) INTO v_result;

  RETURN v_result;
END;
$function$;

COMMENT ON FUNCTION v2.rpc_inteligencia_calidad(INTEGER, UUID, UUID, UUID, TEXT) IS
'Centro de calidad de solo lectura para SUPERADMIN, ADMIN y SUPERVISOR. Respeta RLS y alcances.';

REVOKE ALL ON FUNCTION v2.rpc_inteligencia_calidad(INTEGER, UUID, UUID, UUID, TEXT)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION v2.rpc_inteligencia_calidad(INTEGER, UUID, UUID, UUID, TEXT)
TO authenticated;

INSERT INTO v2.schema_migrations(version, descripcion)
VALUES ('2.1.12af', '12af_centro_calidad.sql - Centro de calidad y validación priorizada.')
ON CONFLICT (version) DO NOTHING;

COMMIT;

SELECT
  to_regprocedure('v2.rpc_inteligencia_calidad(integer,uuid,uuid,uuid,text)') IS NOT NULL AS rpc_existe,
  has_function_privilege('authenticated', 'v2.rpc_inteligencia_calidad(integer,uuid,uuid,uuid,text)', 'EXECUTE') AS authenticated_execute,
  NOT has_function_privilege('anon', 'v2.rpc_inteligencia_calidad(integer,uuid,uuid,uuid,text)', 'EXECUTE') AS anon_bloqueado,
  (SELECT count(*) FROM v2.schema_migrations WHERE version = '2.1.12af') AS migracion;
-- Esperado: true | true | true | 1
