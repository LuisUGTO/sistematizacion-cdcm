-- ============================================================================
-- VINCULACION CULTURAL 2.0
-- 12g_dashboard_directivo.sql
-- Etapa 6: Dashboard Directivo + indicadores reales
-- Secretaria de Cultura de Guanajuato
--
-- REQUIERE:
--   08_views_rpc.sql
--   09d_demographic_model_2026.sql
--   09e_operational_seed_2026.sql
--   12f_validation_workflow.sql
--
-- CREA:
--   v2.rpc_dashboard_directivo(integer, uuid, uuid, uuid)
--
-- SEGURIDAD:
--   - SECURITY INVOKER: conserva RLS y el alcance del usuario.
--   - Solo authenticated puede ejecutar la RPC.
--   - anon y PUBLIC permanecen sin acceso.
--
-- REGLAS DE NEGOCIO CONSERVADAS:
--   - Los aportes se toman de v2.vw_aportes_indicadores.
--   - Las reglas 2026 con requiere_validado=true solo cuentan VALIDADO.
--   - Los BORRADOR provenientes de MIGRACION_V1 no alimentan indicadores.
--   - QC4102.2601 se muestra con meta, pero sin avance automatico mientras
--     no exista una regla accion_indicador institucionalmente aprobada.
--
-- NO HACE:
--   - No modifica V1.
--   - No actualiza registros, estatus, validaciones, auditoria ni historicos.
--   - No cambia RLS, triggers, vistas o RPC existentes.
-- ============================================================================

BEGIN;

SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '180s';


-- ============================================================================
-- 00. PRECONDICIONES
-- ============================================================================

DO $$
BEGIN
  IF to_regclass('v2.registros') IS NULL
     OR to_regclass('v2.vw_calidad_datos') IS NULL
     OR to_regclass('v2.vw_aportes_indicadores') IS NULL
     OR to_regclass('v2.indicadores_version') IS NULL
     OR to_regclass('v2.metas_indicador') IS NULL
     OR to_regclass('v2.accion_indicador') IS NULL THEN
    RAISE EXCEPTION
      'PRECONDICION FALLIDA: faltan objetos V2 requeridos para Etapa 6.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM v2.schema_migrations
    WHERE version = '2.1.12f'
  ) THEN
    RAISE EXCEPTION
      'PRECONDICION FALLIDA: primero debe instalarse 12f_validation_workflow.sql.';
  END IF;
END
$$;


-- ============================================================================
-- 01. RPC CONSOLIDADA DEL DASHBOARD
--
-- La respuesta JSON contiene:
--   resumen       KPIs operativos dentro del alcance/filtros
--   estatus       distribucion completa de estados
--   indicadores   metas y avances calculados desde aportes reales
--   municipios    cobertura territorial
--   unidades      operacion por unidad
--   programas     operacion por programa
--   meses         serie mensual del ejercicio
--
-- Los filtros son opcionales y se aplican DESPUES de RLS.
-- ============================================================================

CREATE OR REPLACE FUNCTION v2.rpc_dashboard_directivo(
  p_anio       INTEGER DEFAULT NULL,
  p_unidad     UUID DEFAULT NULL,
  p_programa   UUID DEFAULT NULL,
  p_municipio  UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $function$
WITH
parametros AS (
  SELECT
    COALESCE(
      p_anio,
      EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER
    ) AS ejercicio,
    p_unidad    AS unidad_id,
    p_programa  AS programa_id,
    p_municipio AS municipio_id
),

registros_filtrados AS MATERIALIZED (
  SELECT
    r.id,
    r.unidad_operativa_id,
    r.programa_id,
    r.municipio_id,
    r.periodo_anio,
    r.periodo_mes,
    r.estatus,
    r.origen,
    r.total_beneficiarios,
    r.total_participantes,
    r.total_accesos
  FROM v2.registros r
  CROSS JOIN parametros p
  WHERE r.deleted_at IS NULL
    AND r.periodo_anio = p.ejercicio
    AND (
      p.unidad_id IS NULL
      OR r.unidad_operativa_id = p.unidad_id
    )
    AND (
      p.programa_id IS NULL
      OR r.programa_id = p.programa_id
    )
    AND (
      p.municipio_id IS NULL
      OR r.municipio_id = p.municipio_id
    )
),

calidad AS MATERIALIZED (
  SELECT
    q.id,
    q.total_incidencias,
    q.datos_completos
  FROM v2.vw_calidad_datos q
  JOIN registros_filtrados rf
    ON rf.id = q.id
),

aportes_filtrados AS MATERIALIZED (
  SELECT
    a.indicador_version_id,
    SUM(a.valor)::NUMERIC(18,4) AS avance,
    COUNT(DISTINCT a.registro_id)::BIGINT AS registros_aportantes
  FROM v2.vw_aportes_indicadores a
  JOIN registros_filtrados rf
    ON rf.id = a.registro_id
  WHERE a.valor IS NOT NULL
  GROUP BY a.indicador_version_id
),

reglas_indicador AS MATERIALIZED (
  SELECT
    ai.indicador_version_id,
    COUNT(*) FILTER (WHERE ai.activo = true)::BIGINT AS reglas_activas,
    COUNT(*) FILTER (
      WHERE ai.activo = true
        AND ai.regla_aporte IN (
          'UNO_POR_REGISTRO',
          'TOTAL_BENEFICIARIOS'
        )
    )::BIGINT AS reglas_automaticas
  FROM v2.accion_indicador ai
  GROUP BY ai.indicador_version_id
),

resumen AS (
  SELECT
    COUNT(*)::BIGINT AS total_registros,
    COUNT(*) FILTER (
      WHERE rf.estatus = 'BORRADOR'
    )::BIGINT AS borradores,
    COUNT(*) FILTER (
      WHERE rf.estatus IN (
        'CAPTURADO',
        'EN_REVISION',
        'CORREGIDO'
      )
    )::BIGINT AS pendientes_revision,
    COUNT(*) FILTER (
      WHERE rf.estatus = 'EN_REVISION'
    )::BIGINT AS en_revision,
    COUNT(*) FILTER (
      WHERE rf.estatus = 'OBSERVADO'
    )::BIGINT AS observados,
    COUNT(*) FILTER (
      WHERE rf.estatus = 'CORREGIDO'
    )::BIGINT AS corregidos,
    COUNT(*) FILTER (
      WHERE rf.estatus = 'VALIDADO'
    )::BIGINT AS validados,
    COUNT(*) FILTER (
      WHERE rf.estatus = 'ANULADO'
    )::BIGINT AS anulados,
    COUNT(*) FILTER (
      WHERE rf.origen = 'MIGRACION_V1'
    )::BIGINT AS historicos_migrados,
    COALESCE(
      SUM(rf.total_beneficiarios) FILTER (
        WHERE rf.estatus <> 'ANULADO'
      ),
      0
    )::BIGINT AS total_beneficiarios,
    COALESCE(
      SUM(rf.total_participantes) FILTER (
        WHERE rf.estatus <> 'ANULADO'
      ),
      0
    )::BIGINT AS total_participantes,
    COALESCE(
      SUM(rf.total_accesos) FILTER (
        WHERE rf.estatus <> 'ANULADO'
      ),
      0
    )::BIGINT AS total_accesos,
    COUNT(DISTINCT rf.municipio_id) FILTER (
      WHERE rf.municipio_id IS NOT NULL
        AND rf.estatus <> 'ANULADO'
    )::BIGINT AS municipios_con_actividad,
    CASE
      WHEN COUNT(*) = 0 THEN 0::NUMERIC
      ELSE ROUND(
        COUNT(*) FILTER (
          WHERE rf.estatus = 'VALIDADO'
        )::NUMERIC
        / COUNT(*)::NUMERIC
        * 100,
        2
      )
    END AS porcentaje_validado,
    (
      SELECT COUNT(*)::BIGINT
      FROM calidad c
      WHERE c.total_incidencias > 0
    ) AS registros_con_incidencias,
    (
      SELECT COUNT(DISTINCT a.registro_id)::BIGINT
      FROM v2.vw_aportes_indicadores a
      JOIN registros_filtrados rfa
        ON rfa.id = a.registro_id
      WHERE a.valor IS NOT NULL
    ) AS registros_con_aporte
  FROM registros_filtrados rf
),

estatus_catalogo(estatus, orden) AS (
  VALUES
    ('BORRADOR'::TEXT, 10),
    ('CAPTURADO'::TEXT, 20),
    ('EN_REVISION'::TEXT, 30),
    ('OBSERVADO'::TEXT, 40),
    ('CORREGIDO'::TEXT, 50),
    ('VALIDADO'::TEXT, 60),
    ('ANULADO'::TEXT, 70)
),

estatus_resumen AS (
  SELECT
    ec.estatus,
    ec.orden,
    COUNT(rf.id)::BIGINT AS total
  FROM estatus_catalogo ec
  LEFT JOIN registros_filtrados rf
    ON rf.estatus = ec.estatus
  GROUP BY ec.estatus, ec.orden
),

indicadores_resumen AS (
  SELECT
    m.id AS meta_id,
    iv.indicador_id,
    iv.id AS indicador_version_id,
    iv.ejercicio,
    iv.clave AS indicador_clave,
    iv.nombre AS indicador_nombre,
    iv.periodicidad,
    iv.sentido,
    iv.formula_descriptiva,
    iv.metadata,
    ci.clave_interna,
    ci.nombre_base,
    ci.unidad_operativa_id AS indicador_unidad_id,
    iu.nombre AS indicador_unidad_nombre,
    um.clave AS unidad_medida_clave,
    um.nombre AS unidad_medida_nombre,
    um.simbolo AS unidad_medida_simbolo,
    m.alcance,
    m.unidad_operativa_id AS meta_unidad_id,
    mu.nombre AS meta_unidad_nombre,
    m.region_id AS meta_region_id,
    mr.nombre AS meta_region_nombre,
    m.municipio_id AS meta_municipio_id,
    mm.nombre_oficial AS meta_municipio_nombre,
    m.meta::NUMERIC(18,4) AS meta,
    COALESCE(af.avance, 0)::NUMERIC(18,4) AS avance,
    COALESCE(af.registros_aportantes, 0)::BIGINT AS registros_aportantes,
    CASE
      WHEN m.meta = 0 THEN NULL
      ELSE ROUND(
        COALESCE(af.avance, 0) / m.meta * 100,
        2
      )
    END AS cumplimiento_pct,
    GREATEST(
      m.meta - COALESCE(af.avance, 0),
      0
    )::NUMERIC(18,4) AS pendiente_meta,
    COALESCE(ri.reglas_activas, 0)::BIGINT AS reglas_activas,
    COALESCE(ri.reglas_automaticas, 0)::BIGINT AS reglas_automaticas,
    (COALESCE(ri.reglas_automaticas, 0) > 0) AS auto_calculable,
    CASE
      WHEN COALESCE(ri.reglas_automaticas, 0) = 0
        THEN 'PENDIENTE_ALINEACION'
      WHEN m.meta = 0
        THEN 'SIN_META'
      WHEN COALESCE(af.avance, 0) >= m.meta
        THEN 'CUMPLIDA'
      WHEN COALESCE(af.avance, 0) >= m.meta * 0.80
        THEN 'EN_RUTA'
      WHEN COALESCE(af.avance, 0) > 0
        THEN 'REZAGO'
      ELSE 'SIN_AVANCE'
    END AS semaforo
  FROM v2.metas_indicador m
  JOIN v2.indicadores_version iv
    ON iv.id = m.indicador_version_id
   AND iv.activo = true
  JOIN parametros p
    ON p.ejercicio = iv.ejercicio
  JOIN v2.cat_indicadores ci
    ON ci.id = iv.indicador_id
  JOIN v2.cat_unidades_medida um
    ON um.id = iv.unidad_medida_id
  LEFT JOIN v2.cat_unidades_operativas iu
    ON iu.id = ci.unidad_operativa_id
  LEFT JOIN v2.cat_unidades_operativas mu
    ON mu.id = m.unidad_operativa_id
  LEFT JOIN v2.cat_regiones mr
    ON mr.id = m.region_id
  LEFT JOIN v2.cat_municipios mm
    ON mm.id = m.municipio_id
  LEFT JOIN aportes_filtrados af
    ON af.indicador_version_id = iv.id
  LEFT JOIN reglas_indicador ri
    ON ri.indicador_version_id = iv.id
  WHERE m.activo = true
),

municipios_resumen AS (
  SELECT
    rf.municipio_id,
    m.clave_inegi,
    m.nombre_oficial AS municipio_nombre,
    m.region_id,
    rg.nombre AS region_nombre,
    COUNT(*)::BIGINT AS total_registros,
    COUNT(*) FILTER (
      WHERE rf.estatus = 'VALIDADO'
    )::BIGINT AS validados,
    COUNT(*) FILTER (
      WHERE rf.estatus IN (
        'CAPTURADO',
        'EN_REVISION',
        'OBSERVADO',
        'CORREGIDO'
      )
    )::BIGINT AS pendientes,
    COALESCE(
      SUM(rf.total_beneficiarios) FILTER (
        WHERE rf.estatus <> 'ANULADO'
      ),
      0
    )::BIGINT AS beneficiarios,
    COALESCE(
      SUM(rf.total_participantes) FILTER (
        WHERE rf.estatus <> 'ANULADO'
      ),
      0
    )::BIGINT AS participantes,
    COALESCE(
      SUM(rf.total_accesos) FILTER (
        WHERE rf.estatus <> 'ANULADO'
      ),
      0
    )::BIGINT AS accesos
  FROM registros_filtrados rf
  JOIN v2.cat_municipios m
    ON m.id = rf.municipio_id
  LEFT JOIN v2.cat_regiones rg
    ON rg.id = m.region_id
  GROUP BY
    rf.municipio_id,
    m.clave_inegi,
    m.nombre_oficial,
    m.region_id,
    rg.nombre
),

unidades_resumen AS (
  SELECT
    rf.unidad_operativa_id,
    u.clave AS unidad_clave,
    u.nombre AS unidad_nombre,
    COUNT(*)::BIGINT AS total_registros,
    COUNT(*) FILTER (
      WHERE rf.estatus = 'VALIDADO'
    )::BIGINT AS validados,
    COUNT(*) FILTER (
      WHERE rf.estatus IN (
        'CAPTURADO',
        'EN_REVISION',
        'OBSERVADO',
        'CORREGIDO'
      )
    )::BIGINT AS pendientes,
    COALESCE(
      SUM(rf.total_beneficiarios) FILTER (
        WHERE rf.estatus <> 'ANULADO'
      ),
      0
    )::BIGINT AS beneficiarios
  FROM registros_filtrados rf
  JOIN v2.cat_unidades_operativas u
    ON u.id = rf.unidad_operativa_id
  GROUP BY
    rf.unidad_operativa_id,
    u.clave,
    u.nombre
),

programas_resumen AS (
  SELECT
    rf.programa_id,
    p.unidad_operativa_id,
    p.clave AS programa_clave,
    p.nombre AS programa_nombre,
    COUNT(*)::BIGINT AS total_registros,
    COUNT(*) FILTER (
      WHERE rf.estatus = 'VALIDADO'
    )::BIGINT AS validados,
    COUNT(*) FILTER (
      WHERE rf.estatus IN (
        'CAPTURADO',
        'EN_REVISION',
        'OBSERVADO',
        'CORREGIDO'
      )
    )::BIGINT AS pendientes
  FROM registros_filtrados rf
  JOIN v2.cat_programas p
    ON p.id = rf.programa_id
  GROUP BY
    rf.programa_id,
    p.unidad_operativa_id,
    p.clave,
    p.nombre
),

meses_resumen AS (
  SELECT
    mes.numero AS mes,
    COUNT(rf.id)::BIGINT AS total_registros,
    COUNT(rf.id) FILTER (
      WHERE rf.estatus = 'VALIDADO'
    )::BIGINT AS validados,
    COALESCE(
      SUM(rf.total_beneficiarios) FILTER (
        WHERE rf.estatus <> 'ANULADO'
      ),
      0
    )::BIGINT AS beneficiarios,
    COALESCE(
      SUM(rf.total_participantes) FILTER (
        WHERE rf.estatus <> 'ANULADO'
      ),
      0
    )::BIGINT AS participantes,
    COALESCE(
      SUM(rf.total_accesos) FILTER (
        WHERE rf.estatus <> 'ANULADO'
      ),
      0
    )::BIGINT AS accesos
  FROM pg_catalog.generate_series(1, 12) AS mes(numero)
  LEFT JOIN registros_filtrados rf
    ON rf.periodo_mes = mes.numero
  GROUP BY mes.numero
),

resultado AS (
  SELECT pg_catalog.jsonb_build_object(
    'ejercicio', p.ejercicio,
    'generado_at', CURRENT_TIMESTAMP,
    'filtros', pg_catalog.jsonb_build_object(
      'unidad_id', p.unidad_id,
      'programa_id', p.programa_id,
      'municipio_id', p.municipio_id
    ),
    'resumen', COALESCE(
      (SELECT pg_catalog.to_jsonb(r) FROM resumen r),
      '{}'::JSONB
    ),
    'estatus', COALESCE(
      (
        SELECT pg_catalog.jsonb_agg(
          pg_catalog.to_jsonb(er) - 'orden'
          ORDER BY er.orden
        )
        FROM estatus_resumen er
      ),
      '[]'::JSONB
    ),
    'indicadores', COALESCE(
      (
        SELECT pg_catalog.jsonb_agg(
          pg_catalog.to_jsonb(ir)
          ORDER BY ir.indicador_clave, ir.alcance
        )
        FROM indicadores_resumen ir
      ),
      '[]'::JSONB
    ),
    'municipios', COALESCE(
      (
        SELECT pg_catalog.jsonb_agg(
          pg_catalog.to_jsonb(mr)
          ORDER BY mr.total_registros DESC, mr.municipio_nombre
        )
        FROM municipios_resumen mr
      ),
      '[]'::JSONB
    ),
    'unidades', COALESCE(
      (
        SELECT pg_catalog.jsonb_agg(
          pg_catalog.to_jsonb(ur)
          ORDER BY ur.total_registros DESC, ur.unidad_nombre
        )
        FROM unidades_resumen ur
      ),
      '[]'::JSONB
    ),
    'programas', COALESCE(
      (
        SELECT pg_catalog.jsonb_agg(
          pg_catalog.to_jsonb(pr)
          ORDER BY pr.total_registros DESC, pr.programa_nombre
        )
        FROM programas_resumen pr
      ),
      '[]'::JSONB
    ),
    'meses', COALESCE(
      (
        SELECT pg_catalog.jsonb_agg(
          pg_catalog.to_jsonb(ms)
          ORDER BY ms.mes
        )
        FROM meses_resumen ms
      ),
      '[]'::JSONB
    )
  ) AS payload
  FROM parametros p
)
SELECT payload
FROM resultado
$function$;


COMMENT ON FUNCTION v2.rpc_dashboard_directivo(
  INTEGER,
  UUID,
  UUID,
  UUID
) IS
'Dashboard directivo V2 filtrable. Consolida operacion, calidad, territorio y metas reales respetando RLS mediante SECURITY INVOKER.';


-- ============================================================================
-- 02. PERMISOS
-- ============================================================================

REVOKE ALL ON FUNCTION v2.rpc_dashboard_directivo(
  INTEGER,
  UUID,
  UUID,
  UUID
) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION v2.rpc_dashboard_directivo(
  INTEGER,
  UUID,
  UUID,
  UUID
) TO authenticated;


-- ============================================================================
-- 03. REGISTRO DE MIGRACION
-- ============================================================================

INSERT INTO v2.schema_migrations (
  version,
  descripcion
)
VALUES (
  '2.1.12g',
  '12g_dashboard_directivo.sql - RPC de lectura para Dashboard Directivo, metas reales, cobertura, calidad y filtros con RLS.'
)
ON CONFLICT (version) DO NOTHING;


COMMIT;


-- ============================================================================
-- 04. VERIFICACION POST-INSTALACION
-- ============================================================================

SELECT
  (
    to_regprocedure(
      'v2.rpc_dashboard_directivo(integer,uuid,uuid,uuid)'
    ) IS NOT NULL
  ) AS rpc_dashboard_existe,

  COALESCE(
    has_function_privilege(
      'authenticated',
      'v2.rpc_dashboard_directivo(integer,uuid,uuid,uuid)',
      'EXECUTE'
    ),
    false
  ) AS authenticated_execute,

  COALESCE(
    has_function_privilege(
      'anon',
      'v2.rpc_dashboard_directivo(integer,uuid,uuid,uuid)',
      'EXECUTE'
    ),
    false
  ) AS anon_execute,

  COALESCE(
    (
      SELECT p.prosecdef = false
      FROM pg_proc p
      JOIN pg_namespace n
        ON n.oid = p.pronamespace
      WHERE n.nspname = 'v2'
        AND p.proname = 'rpc_dashboard_directivo'
        AND pg_catalog.pg_get_function_identity_arguments(p.oid)
          = 'p_anio integer, p_unidad uuid, p_programa uuid, p_municipio uuid'
      LIMIT 1
    ),
    false
  ) AS security_invoker,

  (
    SELECT count(*)
    FROM v2.schema_migrations
    WHERE version = '2.1.12g'
  ) AS migracion_registrada;


-- RESULTADO ESPERADO:
-- rpc_dashboard_existe | authenticated_execute | anon_execute | security_invoker | migracion_registrada
-- true                  | true                  | false        | true             | 1
