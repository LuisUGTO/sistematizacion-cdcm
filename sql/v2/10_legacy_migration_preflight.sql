-- ============================================================================
-- VINCULACIÓN CULTURAL 2.0
-- 10_legacy_migration_preflight.sql
-- DRY-RUN de migración V1 -> V2
-- Secretaría de Cultura de Guanajuato
--
-- ESTE ARCHIVO ES 100% READ-ONLY.
--
-- NO:
--   ✗ INSERT
--   ✗ UPDATE
--   ✗ DELETE
--   ✗ CREATE TABLE
--   ✗ registra schema_migrations
--
-- OBJETIVO:
--   Analizar TODOS los registros de public.registros_culturales antes de
--   migrar una sola fila.
--
-- REVISA:
--   ✓ folios faltantes y duplicados
--   ✓ normalización de municipios oficiales + aliases
--   ✓ registros con cobertura estatal mal representada como municipio
--   ✓ periodo fuente probable
--   ✓ propuesta conservadora de acción V2
--   ✓ beneficiario artificial = 1
--   ✓ demografía posiblemente sintética/estimada por el importador V1
--   ✓ usuario histórico faltante
--   ✓ evidencias URL / ruta Storage
--   ✓ disponibilidad de acción/configuración destino
--   ✓ filas aptas para migración automática
--   ✓ filas que requieren revisión
--
-- PRINCIPIO:
--   "Migrar" no significa "dar por cierto".
--   Los valores dudosos pueden conservarse como metadata histórica, pero
--   no deben convertirse automáticamente en métricas auditables de V2.
--
-- IMPORTANTE:
--   La clasificación de acción es deliberadamente conservadora.
--   Si no existe señal suficiente, se devuelve REVISION_MANUAL.
-- ============================================================================

BEGIN TRANSACTION READ ONLY;

SET LOCAL statement_timeout = '180s';


-- ============================================================================
-- 00. PRECONDICIONES
-- ============================================================================

DO $$
BEGIN
  IF to_regclass('public.registros_culturales') IS NULL THEN
    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: public.registros_culturales no existe.';
  END IF;

  IF to_regclass('v2.registros') IS NULL
     OR to_regclass('v2.cat_municipios') IS NULL
     OR to_regclass('v2.cat_municipio_alias') IS NULL
     OR to_regclass('v2.cat_acciones') IS NULL
     OR to_regclass('v2.configuracion_acciones') IS NULL THEN
    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: faltan objetos requeridos de V2.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM v2.schema_migrations
    WHERE version = '2.1.09e'
  ) THEN
    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: ejecute primero 09e_operational_seed_2026.sql.';
  END IF;
END
$$;


-- ============================================================================
-- 01. DRY-RUN
-- ============================================================================

WITH

-- --------------------------------------------------------------------------
-- A. Base V1
-- ctid SOLO se usa como localizador diagnóstico dentro de esta ejecución.
-- NO se guardará como identificador de migración.
-- --------------------------------------------------------------------------
legacy AS (
  SELECT
    r.ctid::TEXT AS legacy_row_ref,

    r.folio,
    r.area_programa,
    r.usuario,
    r.municipio,
    r.sede,
    r.disciplina,
    r.programacion,
    r.docente,
    r.costo,
    r.horario,
    r.sesion,
    r.dias,
    r.latitud,
    r.longitud,
    r.foto_url,

    r.total_beneficiarios,
    r.mujeres,
    r.hombres,
    r.ninez,
    r.adolescencia,
    r.juventudes,
    r.adultos_mayores,
    r.discapacidad,
    r.indigenas,
    r.afromexicanas,
    r.lgbtq,

    r.fecha_actividad,
    r.tipo_actividad,
    r.created_at,

    count(*) OVER (
      PARTITION BY NULLIF(btrim(r.folio), '')
    ) AS folio_repeticiones,

    row_number() OVER (
      PARTITION BY NULLIF(btrim(r.folio), '')
      ORDER BY r.created_at NULLS LAST, r.ctid
    ) AS folio_ocurrencia

  FROM public.registros_culturales r
),


-- --------------------------------------------------------------------------
-- B. Municipio normalizado
--
-- Prioridad:
--   1. nombre oficial exacto case-insensitive
--   2. alias ya gobernado en V2
-- --------------------------------------------------------------------------
territorio AS (
  SELECT
    l.*,

    COALESCE(
      (
        SELECT m.id
        FROM v2.cat_municipios m
        WHERE lower(btrim(m.nombre_oficial))
              = lower(btrim(l.municipio))
        LIMIT 1
      ),
      (
        SELECT a.municipio_id
        FROM v2.cat_municipio_alias a
        WHERE lower(btrim(a.alias))
              = lower(btrim(l.municipio))
          AND a.activo = true
        LIMIT 1
      )
    ) AS municipio_v2_id,

    COALESCE(
      (
        SELECT m.nombre_oficial
        FROM v2.cat_municipios m
        WHERE lower(btrim(m.nombre_oficial))
              = lower(btrim(l.municipio))
        LIMIT 1
      ),
      (
        SELECT m.nombre_oficial
        FROM v2.cat_municipio_alias a
        JOIN v2.cat_municipios m
          ON m.id = a.municipio_id
        WHERE lower(btrim(a.alias))
              = lower(btrim(l.municipio))
          AND a.activo = true
        LIMIT 1
      )
    ) AS municipio_normalizado,

    EXISTS (
      SELECT 1
      FROM v2.cat_municipio_alias a
      WHERE lower(btrim(a.alias))
            = lower(btrim(l.municipio))
        AND a.activo = true
    ) AS municipio_resuelto_por_alias

  FROM legacy l
),


-- --------------------------------------------------------------------------
-- C. Señales temporales y de procedencia
--
-- created_at/fecha_actividad NO son suficientes para determinar el periodo
-- real porque V1 llegó a aplicar defaults/importaciones tardías.
-- programacion/disciplina son señales más prudentes cuando contienen año.
-- --------------------------------------------------------------------------
periodo AS (
  SELECT
    t.*,

    CASE
      WHEN COALESCE(t.programacion, '') ~* '(^|[^0-9])2025([^0-9]|$)'
        OR COALESCE(t.disciplina, '') ~* '(^|[^0-9])2025([^0-9]|$)'
        THEN 2025

      WHEN COALESCE(t.programacion, '') ~* '(^|[^0-9])2026([^0-9]|$)'
        OR COALESCE(t.disciplina, '') ~* '(^|[^0-9])2026([^0-9]|$)'
        THEN 2026

      ELSE NULL
    END AS periodo_fuente_probable,

    (
      lower(COALESCE(t.sede, '')) LIKE '%cobertura estatal%'
      OR lower(COALESCE(t.disciplina, '')) LIKE '%cobertura estatal%'
    ) AS posible_cobertura_estatal,

    (
      lower(COALESCE(t.disciplina, '')) LIKE '%concentrado anual%'
      OR lower(COALESCE(t.disciplina, '')) LIKE '%numeralia informe%'
      OR lower(COALESCE(t.disciplina, '')) LIKE '%resumen%'
      OR lower(COALESCE(t.disciplina, '')) LIKE '%(% activ.%'
      OR lower(COALESCE(t.disciplina, '')) LIKE '%(% grupos%'
    ) AS posible_registro_agregado

  FROM territorio t
),


-- --------------------------------------------------------------------------
-- D. Calidad de beneficiarios / demografía
--
-- 1 artificial:
--   V1 llegó a forzar mínimo 1 cuando todos los componentes eran 0.
--
-- Demografía posiblemente sintética:
--   Algunos importadores V1 calcularon proporciones a partir del total.
--   Se detectan firmas EXACTAS conocidas. El flag no afirma fraude/error;
--   indica que NO debe tratarse como observación demográfica auditada sin
--   revisar la fuente original.
-- --------------------------------------------------------------------------
calidad_poblacion AS (
  SELECT
    p.*,

    (
      p.total_beneficiarios = 1
      AND COALESCE(p.mujeres, 0) = 0
      AND COALESCE(p.hombres, 0) = 0
      AND COALESCE(p.ninez, 0) = 0
      AND COALESCE(p.adolescencia, 0) = 0
      AND COALESCE(p.juventudes, 0) = 0
      AND COALESCE(p.adultos_mayores, 0) = 0
      AND COALESCE(p.discapacidad, 0) = 0
      AND COALESCE(p.indigenas, 0) = 0
      AND COALESCE(p.afromexicanas, 0) = 0
      AND COALESCE(p.lgbtq, 0) = 0
    ) AS beneficiario_uno_artificial,

    (
      COALESCE(p.total_beneficiarios, 0) > 0
      AND (
        -- Firma 58/42 observada en importadores históricos
        (
          COALESCE(p.mujeres, 0)
            = round(p.total_beneficiarios * 0.58)
          AND COALESCE(p.hombres, 0)
            = p.total_beneficiarios
              - round(p.total_beneficiarios * 0.58)
          AND (
            (
              COALESCE(p.ninez, 0)
                = round(p.total_beneficiarios * 0.35)
              AND COALESCE(p.adolescencia, 0)
                = round(p.total_beneficiarios * 0.28)
              AND COALESCE(p.juventudes, 0)
                = round(p.total_beneficiarios * 0.22)
            )
            OR
            (
              COALESCE(p.ninez, 0)
                = round(p.total_beneficiarios * 0.35)
              AND COALESCE(p.adolescencia, 0)
                = round(p.total_beneficiarios * 0.30)
              AND COALESCE(p.juventudes, 0)
                = round(p.total_beneficiarios * 0.20)
            )
          )
        )

        OR

        -- Firma 55/45 observada en importación de proyectos socioculturales
        (
          COALESCE(p.mujeres, 0)
            = round(p.total_beneficiarios * 0.55)
          AND COALESCE(p.hombres, 0)
            = GREATEST(
                0,
                p.total_beneficiarios
                  - round(p.total_beneficiarios * 0.55)
              )
          AND COALESCE(p.adolescencia, 0)
            = round(p.total_beneficiarios * 0.25)
          AND COALESCE(p.juventudes, 0)
            = round(p.total_beneficiarios * 0.20)
        )
      )
    ) AS demografia_posiblemente_sintetica

  FROM periodo p
),


-- --------------------------------------------------------------------------
-- E. Clasificación conservadora de evidencia
-- --------------------------------------------------------------------------
evidencia AS (
  SELECT
    c.*,

    CASE
      WHEN c.foto_url IS NULL OR btrim(c.foto_url) = ''
        THEN 'SIN_EVIDENCIA'

      WHEN c.foto_url ILIKE
        '%/storage/v1/object/public/evidencias/%'
        THEN 'URL_PUBLICA_V1'

      WHEN c.foto_url ILIKE 'http%'
        THEN 'URL_COMPLETA'

      ELSE 'RUTA_STORAGE'
    END AS evidencia_tipo

  FROM calidad_poblacion c
),


-- --------------------------------------------------------------------------
-- F. Propuesta CONSERVADORA de acción
--
-- Para 2025 se pueden reconocer tipos históricos.
-- Para 2026 solo se propone un PB cuando el propio texto contiene la clave.
--
-- Esto evita inferir que un registro genérico equivale a una meta 2026.
-- --------------------------------------------------------------------------
clasificacion AS (
  SELECT
    e.*,

    CASE
      -- ================================================================
      -- 2026: solo código PB explícito
      -- ================================================================
      WHEN e.periodo_fuente_probable = 2026
           AND COALESCE(e.disciplina, '') ILIKE '%PB3562.2601%'
        THEN 'PB3562_2601'
      WHEN e.periodo_fuente_probable = 2026
           AND COALESCE(e.disciplina, '') ILIKE '%PB3562.2602%'
        THEN 'PB3562_2602'
      WHEN e.periodo_fuente_probable = 2026
           AND COALESCE(e.disciplina, '') ILIKE '%PB3562.2603%'
        THEN 'PB3562_2603'
      WHEN e.periodo_fuente_probable = 2026
           AND COALESCE(e.disciplina, '') ILIKE '%PB3562.2604%'
        THEN 'PB3562_2604'
      WHEN e.periodo_fuente_probable = 2026
           AND COALESCE(e.disciplina, '') ILIKE '%PB3562.2605%'
        THEN 'PB3562_2605'

      WHEN e.periodo_fuente_probable = 2026
           AND COALESCE(e.disciplina, '') ILIKE '%PB3563.2601%'
        THEN 'PB3563_2601'
      WHEN e.periodo_fuente_probable = 2026
           AND COALESCE(e.disciplina, '') ILIKE '%PB3563.2602%'
        THEN 'PB3563_2602'
      WHEN e.periodo_fuente_probable = 2026
           AND COALESCE(e.disciplina, '') ILIKE '%PB3563.2603%'
        THEN 'PB3563_2603'
      WHEN e.periodo_fuente_probable = 2026
           AND COALESCE(e.disciplina, '') ILIKE '%PB3563.2604%'
        THEN 'PB3563_2604'
      WHEN e.periodo_fuente_probable = 2026
           AND COALESCE(e.disciplina, '') ILIKE '%PB3563.2605%'
        THEN 'PB3563_2605'

      WHEN e.periodo_fuente_probable = 2026
           AND COALESCE(e.disciplina, '') ILIKE '%PB3564.2601%'
        THEN 'PB3564_2601'
      WHEN e.periodo_fuente_probable = 2026
           AND COALESCE(e.disciplina, '') ILIKE '%PB3564.2602%'
        THEN 'PB3564_2602'
      WHEN e.periodo_fuente_probable = 2026
           AND COALESCE(e.disciplina, '') ILIKE '%PB3564.2603%'
        THEN 'PB3564_2603'

      -- ================================================================
      -- 2025 / histórico
      -- ================================================================
      WHEN e.periodo_fuente_probable = 2025
           AND upper(COALESCE(e.area_programa, '')) = 'CDCM'
           AND (
             lower(COALESCE(e.disciplina, ''))
               LIKE '%proyecto sociocultural%'
           )
        THEN 'PROYECTO_SOCIOCULTURAL'

      WHEN e.periodo_fuente_probable = 2025
           AND upper(COALESCE(e.area_programa, '')) = 'CDCM'
           AND lower(COALESCE(e.disciplina, '')) LIKE '%circuito%'
        THEN 'ACTIVIDAD_PROYECTO_CIRCUITO'

      WHEN e.periodo_fuente_probable = 2025
           AND upper(COALESCE(e.area_programa, '')) = 'CDCM'
           AND lower(COALESCE(e.disciplina, '')) LIKE '%regional%'
        THEN 'ACTIVIDAD_PROYECTO_REGIONAL'

      WHEN e.periodo_fuente_probable = 2025
           AND upper(COALESCE(e.area_programa, '')) = 'CDCM'
           AND lower(COALESCE(e.disciplina, '')) LIKE '%intercambio%'
        THEN 'INTERCAMBIO_CULTURAL'

      WHEN e.periodo_fuente_probable = 2025
           AND upper(COALESCE(e.area_programa, '')) = 'CDCM'
           AND (
             lower(COALESCE(e.disciplina, '')) LIKE '%reunión%'
             OR lower(COALESCE(e.disciplina, '')) LIKE '%reunion%'
           )
        THEN 'REUNION_COLABORACION'

      WHEN e.periodo_fuente_probable = 2025
           AND upper(COALESCE(e.area_programa, '')) = 'CDCM'
           AND (
             lower(COALESCE(e.disciplina, '')) LIKE '%capacitación%'
             OR lower(COALESCE(e.disciplina, '')) LIKE '%capacitacion%'
           )
        THEN 'CAPACITACION_PROMOTORES'

      WHEN e.periodo_fuente_probable = 2025
           AND upper(COALESCE(e.area_programa, '')) = 'CDCM'
           AND lower(COALESCE(e.disciplina, '')) LIKE '%verano%'
        THEN 'TALLER_VERANO'

      WHEN e.periodo_fuente_probable = 2025
           AND upper(COALESCE(e.area_programa, '')) = 'CDCM'
           AND (
             lower(COALESCE(e.disciplina, '')) LIKE '%exposición%'
             OR lower(COALESCE(e.disciplina, '')) LIKE '%exposicion%'
             OR lower(COALESCE(e.disciplina, '')) LIKE '%muestra%'
           )
        THEN 'EXPOSICION_MUESTRA'

      WHEN e.periodo_fuente_probable = 2025
           AND upper(COALESCE(e.area_programa, '')) = 'CDCM'
           AND (
             lower(COALESCE(e.disciplina, '')) LIKE '%evento%'
             OR lower(COALESCE(e.disciplina, '')) LIKE '%festival%'
             OR lower(COALESCE(e.disciplina, '')) LIKE '%feria%'
             OR lower(COALESCE(e.disciplina, '')) LIKE '%fiesta%'
           )
        THEN 'EVENTO_MUNICIPAL'

      -- "Proyecto Estratégico" no se fuerza a sociocultural.
      WHEN e.periodo_fuente_probable = 2025
           AND upper(COALESCE(e.area_programa, '')) = 'CDCM'
           AND lower(COALESCE(e.disciplina, ''))
               LIKE '%proyecto estratégico%'
        THEN NULL

      -- Agregados de talleres se preservan pero requieren revisión.
      WHEN e.periodo_fuente_probable = 2025
           AND upper(COALESCE(e.area_programa, '')) = 'CDCM'
           AND e.posible_registro_agregado = true
        THEN NULL

      -- Taller individual histórico: última regla segura 2025.
      WHEN e.periodo_fuente_probable = 2025
           AND upper(COALESCE(e.area_programa, '')) = 'CDCM'
        THEN 'TALLER_CASA_CULTURA'

      ELSE NULL
    END AS accion_v2_propuesta

  FROM evidencia e
),


-- --------------------------------------------------------------------------
-- G. Resolver acción/configuración V2 propuesta
-- --------------------------------------------------------------------------
destino AS (
  SELECT
    c.*,

    a.id AS accion_v2_id,
    a.unidad_operativa_id AS unidad_v2_id,

    ca.id AS configuracion_v2_id,

    CASE
      WHEN a.id IS NULL
        THEN false
      WHEN c.periodo_fuente_probable IS NULL
        THEN false
      WHEN ca.id IS NULL
        THEN false
      ELSE true
    END AS destino_configurado

  FROM clasificacion c

  LEFT JOIN v2.cat_acciones a
    ON upper(btrim(a.clave))
       = upper(btrim(c.accion_v2_propuesta))
   AND a.activo = true

  LEFT JOIN LATERAL (
    SELECT x.id
    FROM v2.configuracion_acciones x
    WHERE x.accion_id = a.id
      AND x.activo = true
      AND c.periodo_fuente_probable IS NOT NULL
      AND make_date(
            c.periodo_fuente_probable,
            1,
            1
          )
          BETWEEN x.vigente_desde
              AND COALESCE(
                    x.vigente_hasta,
                    DATE '9999-12-31'
                  )
    ORDER BY x.vigente_desde DESC
    LIMIT 1
  ) ca ON true
),


-- --------------------------------------------------------------------------
-- H. Motivos de revisión
-- --------------------------------------------------------------------------
evaluacion AS (
  SELECT
    d.*,

    ARRAY_REMOVE(
      ARRAY[
        CASE
          WHEN d.municipio_v2_id IS NULL
          THEN 'MUNICIPIO_NO_RESUELTO'
        END,

        CASE
          WHEN d.posible_cobertura_estatal
          THEN 'COBERTURA_ESTATAL_REPRESENTADA_COMO_MUNICIPIO'
        END,

        CASE
          WHEN d.periodo_fuente_probable IS NULL
          THEN 'PERIODO_FUENTE_NO_DETERMINADO'
        END,

        CASE
          WHEN d.accion_v2_propuesta IS NULL
          THEN 'ACCION_V2_NO_CLASIFICADA'
        END,

        CASE
          WHEN d.accion_v2_propuesta IS NOT NULL
               AND d.destino_configurado = false
          THEN 'ACCION_SIN_CONFIGURACION_PARA_PERIODO'
        END,

        CASE
          WHEN d.posible_registro_agregado
          THEN 'REGISTRO_AGREGADO_NO_EQUIVALE_A_UNA_ACTIVIDAD'
        END,

        CASE
          WHEN d.beneficiario_uno_artificial
          THEN 'TOTAL_BENEFICIARIOS_1_ARTIFICIAL'
        END,

        CASE
          WHEN d.demografia_posiblemente_sintetica
          THEN 'DEMOGRAFIA_POSIBLEMENTE_ESTIMADA'
        END,

        CASE
          WHEN d.folio IS NULL OR btrim(d.folio) = ''
          THEN 'FOLIO_V1_FALTANTE'
        END,

        CASE
          WHEN d.folio IS NOT NULL
               AND btrim(d.folio) <> ''
               AND d.folio_repeticiones > 1
          THEN 'FOLIO_V1_DUPLICADO'
        END,

        CASE
          WHEN d.usuario IS NULL OR btrim(d.usuario) = ''
          THEN 'USUARIO_V1_FALTANTE'
        END,

        CASE
          WHEN d.costo ILIKE 'Col.%'
            OR d.costo ILIKE 'Com.%'
          THEN 'COSTO_PARECE_LOCALIDAD'
        END,

        CASE
          WHEN d.disciplina ~ '^[0-9]+$'
          THEN 'DISCIPLINA_SOLO_NUMEROS'
        END,

        CASE
          WHEN d.evidencia_tipo IN (
            'URL_PUBLICA_V1',
            'URL_COMPLETA'
          )
          THEN 'EVIDENCIA_REQUIERE_NORMALIZACION'
        END
      ],
      NULL
    )::TEXT[] AS motivos_revision

  FROM destino d
),


-- --------------------------------------------------------------------------
-- I. Decisión de migración
--
-- APTO_AUTO:
--   estructura suficientemente clara para insertar en V2, aunque valores
--   históricos puedan requerir tratamiento conservador.
--
-- MIGRAR_CON_SALVEDADES:
--   se puede conservar el registro, pero NO automatizar uno o más datos
--   auditables (beneficiarios/demografía/evidencia/folio).
--
-- REVISION_MANUAL:
--   falta contexto de clasificación/territorio/periodo.
-- --------------------------------------------------------------------------
decision AS (
  SELECT
    e.*,

    CASE
      WHEN e.municipio_v2_id IS NULL
        OR e.periodo_fuente_probable IS NULL
        OR e.accion_v2_propuesta IS NULL
        OR e.destino_configurado = false
        OR e.posible_cobertura_estatal
        OR e.posible_registro_agregado

        THEN 'REVISION_MANUAL'

      WHEN e.beneficiario_uno_artificial
        OR e.demografia_posiblemente_sintetica
        OR (e.folio IS NULL OR btrim(e.folio) = '')
        OR (
          e.folio IS NOT NULL
          AND btrim(e.folio) <> ''
          AND e.folio_repeticiones > 1
        )
        OR e.usuario IS NULL
        OR btrim(COALESCE(e.usuario, '')) = ''
        OR e.evidencia_tipo IN (
          'URL_PUBLICA_V1',
          'URL_COMPLETA'
        )

        THEN 'MIGRAR_CON_SALVEDADES'

      ELSE 'APTO_AUTO'
    END AS decision_migracion

  FROM evaluacion e
),


-- --------------------------------------------------------------------------
-- J. Motivos agregados para reporte
-- --------------------------------------------------------------------------
motivos_agg AS (
  SELECT
    motivo,
    count(*)::INTEGER AS registros
  FROM decision d
  CROSS JOIN LATERAL unnest(d.motivos_revision) AS x(motivo)
  GROUP BY motivo
),


acciones_agg AS (
  SELECT
    COALESCE(
      accion_v2_propuesta,
      'SIN_CLASIFICAR'
    ) AS accion,
    count(*)::INTEGER AS registros
  FROM decision
  GROUP BY COALESCE(
    accion_v2_propuesta,
    'SIN_CLASIFICAR'
  )
),


periodos_agg AS (
  SELECT
    COALESCE(
      periodo_fuente_probable::TEXT,
      'SIN_DETERMINAR'
    ) AS periodo,
    count(*)::INTEGER AS registros
  FROM decision
  GROUP BY COALESCE(
    periodo_fuente_probable::TEXT,
    'SIN_DETERMINAR'
  )
)


-- ============================================================================
-- 02. RESULTADO ÚNICO
-- ============================================================================

SELECT
  'V2.1 - 10 legacy migration preflight' AS diagnostico,

  -- Universo
  count(*) AS legacy_total,

  (
    SELECT count(*)
    FROM v2.registros
  ) AS registros_v2_actuales,

  -- Territorio
  count(*) FILTER (
    WHERE municipio_v2_id IS NOT NULL
  ) AS municipios_resueltos,

  count(*) FILTER (
    WHERE municipio_resuelto_por_alias
  ) AS municipios_por_alias,

  count(*) FILTER (
    WHERE municipio_v2_id IS NULL
  ) AS municipios_no_resueltos,

  count(*) FILTER (
    WHERE posible_cobertura_estatal
  ) AS coberturas_estatales_sospechosas,

  -- Periodo
  count(*) FILTER (
    WHERE periodo_fuente_probable = 2025
  ) AS registros_periodo_2025,

  count(*) FILTER (
    WHERE periodo_fuente_probable = 2026
  ) AS registros_periodo_2026,

  count(*) FILTER (
    WHERE periodo_fuente_probable IS NULL
  ) AS registros_periodo_indeterminado,

  -- Folios
  count(*) FILTER (
    WHERE folio IS NULL OR btrim(folio) = ''
  ) AS folios_v1_faltantes,

  (
    SELECT count(*)
    FROM (
      SELECT folio
      FROM legacy
      WHERE folio IS NOT NULL
        AND btrim(folio) <> ''
      GROUP BY folio
      HAVING count(*) > 1
    ) q
  ) AS grupos_folio_duplicado,

  count(*) FILTER (
    WHERE folio IS NOT NULL
      AND btrim(folio) <> ''
      AND folio_repeticiones > 1
  ) AS filas_con_folio_duplicado,

  -- Población
  count(*) FILTER (
    WHERE beneficiario_uno_artificial
  ) AS beneficiarios_uno_artificial,

  count(*) FILTER (
    WHERE demografia_posiblemente_sintetica
  ) AS demografia_posiblemente_sintetica,

  -- Evidencia
  count(*) FILTER (
    WHERE evidencia_tipo = 'SIN_EVIDENCIA'
  ) AS sin_evidencia,

  count(*) FILTER (
    WHERE evidencia_tipo = 'URL_PUBLICA_V1'
  ) AS evidencia_url_publica_v1,

  count(*) FILTER (
    WHERE evidencia_tipo = 'URL_COMPLETA'
  ) AS evidencia_url_completa_otro,

  count(*) FILTER (
    WHERE evidencia_tipo = 'RUTA_STORAGE'
  ) AS evidencia_ruta_storage,

  -- Calidad adicional
  count(*) FILTER (
    WHERE usuario IS NULL OR btrim(usuario) = ''
  ) AS sin_usuario_v1,

  count(*) FILTER (
    WHERE posible_registro_agregado
  ) AS posibles_registros_agregados,

  -- Clasificación
  count(*) FILTER (
    WHERE accion_v2_propuesta IS NOT NULL
  ) AS con_accion_v2_propuesta,

  count(*) FILTER (
    WHERE accion_v2_propuesta IS NULL
  ) AS sin_accion_v2_propuesta,

  count(*) FILTER (
    WHERE destino_configurado
  ) AS con_destino_configurado,

  -- Decisión
  count(*) FILTER (
    WHERE decision_migracion = 'APTO_AUTO'
  ) AS aptos_auto,

  count(*) FILTER (
    WHERE decision_migracion = 'MIGRAR_CON_SALVEDADES'
  ) AS migrar_con_salvedades,

  count(*) FILTER (
    WHERE decision_migracion = 'REVISION_MANUAL'
  ) AS revision_manual,

  -- Detalles compactos
  (
    SELECT COALESCE(
      jsonb_object_agg(
        p.periodo,
        p.registros
        ORDER BY p.periodo
      ),
      '{}'::jsonb
    )
    FROM periodos_agg p
  ) AS resumen_periodos,

  (
    SELECT COALESCE(
      jsonb_object_agg(
        a.accion,
        a.registros
        ORDER BY a.accion
      ),
      '{}'::jsonb
    )
    FROM acciones_agg a
  ) AS resumen_acciones_propuestas,

  (
    SELECT COALESCE(
      jsonb_object_agg(
        m.motivo,
        m.registros
        ORDER BY m.motivo
      ),
      '{}'::jsonb
    )
    FROM motivos_agg m
  ) AS resumen_motivos_revision,

  -- Safety gate
  (
    count(*) FILTER (
      WHERE municipio_v2_id IS NULL
    ) = 0
  ) AS territorio_listo,

  (
    count(*) FILTER (
      WHERE decision_migracion = 'REVISION_MANUAL'
    ) = 0
  ) AS migracion_100pct_automatica,

  (
    SELECT count(*)
    FROM v2.schema_migrations
    WHERE version = '2.1.09e'
  ) AS seed_09e_confirmado

FROM decision;


COMMIT;


-- ============================================================================
-- CÓMO INTERPRETAR EL RESULTADO
--
-- Valores históricos ya observados en el preflight anterior:
--
-- legacy_total                    ≈ 317
-- folios_v1_faltantes             = 6
-- grupos_folio_duplicado          = 1
-- filas_con_folio_duplicado       = 2
-- beneficiarios_uno_artificial    ≈ 186
-- sin_usuario_v1                  ≈ 7
-- sin_evidencia                   ≈ 312
-- evidencia URL total histórica   ≈ 4
-- evidencia ruta Storage          ≈ 1
--
-- IMPORTANTE:
-- Esas cifras se muestran solo como REFERENCIA del snapshot anterior.
-- Este script consulta el estado ACTUAL de Supabase y ese resultado manda.
--
-- NO existe un número esperado todavía para:
--
--   demografia_posiblemente_sintetica
--   registros_periodo_2025
--   registros_periodo_2026
--   registros_periodo_indeterminado
--   aptos_auto
--   migrar_con_salvedades
--   revision_manual
--
-- Precisamente por eso se ejecuta este DRY-RUN.
--
-- SIGUIENTE PASO:
--
--   Si el resultado es coherente:
--
--     10a_legacy_migration_staging.sql
--
--   Ese archivo creará una COPIA CONTROLADA / STAGING de las decisiones
--   de migración, todavía sin tocar public.registros_culturales.
--
--   Después revisaremos:
--     - filas REVISION_MANUAL
--     - demografía sintética
--     - agregados
--     - periodos sin determinar
--
--   Solo entonces:
--
--     10_legacy_migration.sql
--
-- ============================================================================
