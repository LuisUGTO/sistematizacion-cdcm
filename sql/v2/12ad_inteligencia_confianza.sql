-- ============================================================================
-- ETAPA 7.7.3C - CONFIANZA DEL DATO
-- Universos OFICIAL y OPERATIVO; respeta RLS y el alcance institucional.
-- ============================================================================

BEGIN;

DO $$
BEGIN
  IF to_regclass('v2.registros') IS NULL
     OR to_regclass('v2.registro_poblacion') IS NULL
     OR to_regprocedure('v2.rpc_dashboard_directivo_universo(integer,uuid,uuid,uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'PRECONDICION: ejecuta primero 12ac_dashboard_universo.sql.';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION v2.rpc_inteligencia_cultural(
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
  v_base JSONB;
  v_extra JSONB;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED: se requiere una sesión autenticada.';
  END IF;

  v_role := v2_private.current_role();
  IF v_role NOT IN ('SUPERADMIN', 'ADMIN', 'SUPERVISOR', 'DIRECTIVO') THEN
    RAISE EXCEPTION 'ROLE_FORBIDDEN: la vista estratégica requiere perfil directivo o de supervisión.';
  END IF;

  v_base := v2.rpc_dashboard_directivo_universo(
    p_anio,
    p_unidad,
    p_programa,
    p_municipio,
    CASE WHEN upper(COALESCE(p_modo, 'OPERATIVO')) = 'OFICIAL' THEN 'OFICIAL' ELSE 'OPERATIVO' END
  );

  WITH registros_filtrados AS MATERIALIZED (
    SELECT
      r.id, r.accion_id, r.estatus, r.total_beneficiarios,
      r.total_participantes, r.total_accesos, r.metadata
    FROM v2.registros r
    WHERE r.deleted_at IS NULL
      AND r.periodo_anio = COALESCE(p_anio, EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER)
      AND (p_unidad IS NULL OR r.unidad_operativa_id = p_unidad)
      AND (p_programa IS NULL OR r.programa_id = p_programa)
      AND (p_municipio IS NULL OR r.municipio_id = p_municipio)
      AND (
        upper(COALESCE(p_modo, 'OPERATIVO')) <> 'OFICIAL'
        OR r.estatus = 'VALIDADO'
      )
  ),
  registros_activos AS MATERIALIZED (
    SELECT * FROM registros_filtrados WHERE estatus <> 'ANULADO'
  ),
  ejes(eje, ruta) AS (
    VALUES
      ('tipo_actividad'::TEXT, ARRAY['clasificacion_operativa','tipo_actividad']::TEXT[]),
      ('formato'::TEXT, ARRAY['clasificacion_operativa','formato']::TEXT[]),
      ('temporalidad'::TEXT, ARRAY['clasificacion_operativa','temporalidad']::TEXT[]),
      ('disciplina'::TEXT, ARRAY['clasificacion_operativa','disciplina']::TEXT[]),
      ('subdisciplina'::TEXT, ARRAY['clasificacion_operativa','subdisciplina']::TEXT[])
  ),
  clasificaciones AS (
    SELECT
      e.eje,
      COALESCE(NULLIF(btrim(ra.metadata #>> e.ruta), ''), 'SIN CLASIFICAR') AS etiqueta,
      COUNT(*)::BIGINT AS registros,
      COALESCE(SUM(ra.total_beneficiarios), 0)::BIGINT AS beneficiarios,
      COALESCE(SUM(ra.total_participantes), 0)::BIGINT AS participantes,
      COALESCE(SUM(ra.total_accesos), 0)::BIGINT AS accesos
    FROM registros_activos ra
    CROSS JOIN ejes e
    GROUP BY e.eje, COALESCE(NULLIF(btrim(ra.metadata #>> e.ruta), ''), 'SIN CLASIFICAR')
  ),
  poblacion AS (
    SELECT
      rp.universo,
      d.clave AS dimension_clave,
      d.nombre AS dimension_nombre,
      d.es_exclusiva,
      o.clave AS opcion_clave,
      o.nombre AS opcion_nombre,
      SUM(rp.cantidad)::BIGINT AS cantidad
    FROM v2.registro_poblacion rp
    JOIN registros_activos ra ON ra.id = rp.registro_id
    JOIN v2.cat_opciones_poblacion o ON o.id = rp.opcion_poblacion_id
    JOIN v2.cat_dimensiones_poblacion d ON d.id = o.dimension_id
    GROUP BY rp.universo, d.clave, d.nombre, d.es_exclusiva, o.clave, o.nombre
  ),
  acciones AS (
    SELECT
      a.id AS accion_id,
      a.clave AS accion_clave,
      a.nombre AS accion_nombre,
      COUNT(*)::BIGINT AS registros,
      COUNT(*) FILTER (WHERE ra.estatus = 'VALIDADO')::BIGINT AS validados,
      COALESCE(SUM(ra.total_beneficiarios), 0)::BIGINT AS beneficiarios,
      COALESCE(SUM(ra.total_participantes), 0)::BIGINT AS participantes,
      COALESCE(SUM(ra.total_accesos), 0)::BIGINT AS accesos
    FROM registros_activos ra
    JOIN v2.cat_acciones a ON a.id = ra.accion_id
    GROUP BY a.id, a.clave, a.nombre
  ),
  calidad_clasificacion AS (
    SELECT
      COUNT(*)::BIGINT AS registros_activos,
      COUNT(*) FILTER (
        WHERE NULLIF(btrim(metadata #>> '{clasificacion_operativa,tipo_actividad}'), '') IS NOT NULL
      )::BIGINT AS con_tipo_actividad,
      COUNT(*) FILTER (
        WHERE NULLIF(btrim(metadata #>> '{clasificacion_operativa,formato}'), '') IS NOT NULL
      )::BIGINT AS con_formato,
      COUNT(*) FILTER (
        WHERE NULLIF(btrim(metadata #>> '{clasificacion_operativa,disciplina}'), '') IS NOT NULL
      )::BIGINT AS con_disciplina
    FROM registros_activos
  )
  SELECT jsonb_build_object(
    'clasificaciones', COALESCE((
      SELECT jsonb_agg(to_jsonb(c) ORDER BY c.eje, c.registros DESC, c.etiqueta)
      FROM clasificaciones c
    ), '[]'::JSONB),
    'poblacion', COALESCE((
      SELECT jsonb_agg(to_jsonb(p) ORDER BY p.universo, p.dimension_nombre, p.cantidad DESC)
      FROM poblacion p
    ), '[]'::JSONB),
    'acciones', COALESCE((
      SELECT jsonb_agg(to_jsonb(a) ORDER BY a.registros DESC, a.accion_nombre)
      FROM acciones a
    ), '[]'::JSONB),
    'calidad_clasificacion', COALESCE((
      SELECT to_jsonb(q) FROM calidad_clasificacion q
    ), '{}'::JSONB)
  ) INTO v_extra;

  RETURN COALESCE(v_base, '{}'::JSONB) || COALESCE(v_extra, '{}'::JSONB)
    || jsonb_build_object(
      'modulo', 'INTELIGENCIA_CULTURAL',
      'version', '7.7.3C',
      'modo', CASE WHEN upper(COALESCE(p_modo, 'OPERATIVO')) = 'OFICIAL' THEN 'OFICIAL' ELSE 'OPERATIVO' END
    );
END;
$function$;

COMMENT ON FUNCTION v2.rpc_inteligencia_cultural(INTEGER, UUID, UUID, UUID, TEXT) IS
'Vista estratégica por universo OFICIAL u OPERATIVO para coordinación, supervisión y dirección. Respeta RLS.';

REVOKE ALL ON FUNCTION v2.rpc_inteligencia_cultural(INTEGER, UUID, UUID, UUID, TEXT)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION v2.rpc_inteligencia_cultural(INTEGER, UUID, UUID, UUID, TEXT)
TO authenticated;

INSERT INTO v2.schema_migrations(version, descripcion)
VALUES ('2.1.12ad', '12ad_inteligencia_confianza.sql - Universos OFICIAL y OPERATIVO para Inteligencia Cultural.')
ON CONFLICT (version) DO NOTHING;

COMMIT;

SELECT
  to_regprocedure('v2.rpc_inteligencia_cultural(integer,uuid,uuid,uuid,text)') IS NOT NULL AS rpc_existe,
  has_function_privilege('authenticated', 'v2.rpc_inteligencia_cultural(integer,uuid,uuid,uuid,text)', 'EXECUTE') AS authenticated_execute,
  NOT has_function_privilege('anon', 'v2.rpc_inteligencia_cultural(integer,uuid,uuid,uuid,text)', 'EXECUTE') AS anon_bloqueado,
  (SELECT count(*) FROM v2.schema_migrations WHERE version = '2.1.12ad') AS migracion;
-- Esperado: true | true | true | 1
