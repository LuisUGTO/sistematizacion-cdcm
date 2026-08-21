-- ============================================================================
-- VINCULACIÓN CULTURAL 2.0
-- 10a_legacy_classifier.sql
-- Clasificador avanzado V1 -> V2 (DRY-RUN)
-- Secretaría de Cultura de Guanajuato
--
-- REQUIERE:
--   10_legacy_migration_preflight.sql ejecutado y revisado.
--
-- ESTE ARCHIVO ES 100% READ-ONLY.
--
-- OBJETIVO:
--   Reducir de forma reproducible los registros "sin clasificar" del primer
--   preflight SIN inventar información.
--
-- ESTRATEGIA:
--   1. Reconocer firmas exactas creadas por los importadores V1.
--   2. Separar periodo explícito de periodo inferido por firma.
--   3. Detectar talleres municipales por estructura, no por el valor
--      histórico tipo_actividad (que quedó contaminado como "Taller Cultural").
--   4. Mantener agregados, coberturas estatales y Bibliotecas fuera del
--      auto-mapeo cuando no exista equivalencia segura.
--   5. Proponer una disposición de staging:
--        MIGRAR_NORMAL
--        MIGRAR_BORRADOR
--        CONSERVAR_STAGING
--
-- NO:
--   ✗ inserta en V2
--   ✗ modifica V1
--   ✗ cambia folios
--   ✗ convierte demografía estimada en observada
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

  IF to_regclass('v2.cat_acciones') IS NULL
     OR to_regclass('v2.configuracion_acciones') IS NULL
     OR to_regclass('v2.cat_municipios') IS NULL
     OR to_regclass('v2.cat_municipio_alias') IS NULL THEN
    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: faltan objetos V2 requeridos.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM v2.schema_migrations
    WHERE version = '2.1.09e'
  ) THEN
    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: 09e_operational_seed_2026.sql no está aplicado.';
  END IF;
END
$$;


-- ============================================================================
-- 01. CLASIFICADOR
-- ============================================================================

WITH

legacy AS (
  SELECT
    r.ctid::TEXT AS legacy_row_ref,
    r.*,

    count(*) OVER (
      PARTITION BY NULLIF(btrim(r.folio), '')
    ) AS folio_repeticiones

  FROM public.registros_culturales r
),


normalizado AS (
  SELECT
    l.*,

    lower(
      regexp_replace(
        translate(
          COALESCE(l.disciplina, ''),
          'ÁÉÍÓÚÜÑáéíóúüñ',
          'AEIOUUNaeiouun'
        ),
        '\s+',
        ' ',
        'g'
      )
    ) AS n_disciplina,

    lower(
      regexp_replace(
        translate(
          COALESCE(l.sede, ''),
          'ÁÉÍÓÚÜÑáéíóúüñ',
          'AEIOUUNaeiouun'
        ),
        '\s+',
        ' ',
        'g'
      )
    ) AS n_sede,

    lower(
      regexp_replace(
        translate(
          COALESCE(l.programacion, ''),
          'ÁÉÍÓÚÜÑáéíóúüñ',
          'AEIOUUNaeiouun'
        ),
        '\s+',
        ' ',
        'g'
      )
    ) AS n_programacion,

    lower(
      regexp_replace(
        translate(
          COALESCE(l.docente, ''),
          'ÁÉÍÓÚÜÑáéíóúüñ',
          'AEIOUUNaeiouun'
        ),
        '\s+',
        ' ',
        'g'
      )
    ) AS n_docente,

    lower(
      regexp_replace(
        translate(
          COALESCE(l.municipio, ''),
          'ÁÉÍÓÚÜÑáéíóúüñ',
          'AEIOUUNaeiouun'
        ),
        '\s+',
        ' ',
        'g'
      )
    ) AS n_municipio

  FROM legacy l
),


territorio AS (
  SELECT
    n.*,

    COALESCE(
      (
        SELECT m.id
        FROM v2.cat_municipios m
        WHERE lower(
          translate(
            btrim(m.nombre_oficial),
            'ÁÉÍÓÚÜÑáéíóúüñ',
            'AEIOUUNaeiouun'
          )
        ) = n.n_municipio
        LIMIT 1
      ),
      (
        SELECT a.municipio_id
        FROM v2.cat_municipio_alias a
        WHERE lower(
          translate(
            btrim(a.alias),
            'ÁÉÍÓÚÜÑáéíóúüñ',
            'AEIOUUNaeiouun'
          )
        ) = n.n_municipio
          AND a.activo = true
        LIMIT 1
      )
    ) AS municipio_v2_id,

    COALESCE(
      (
        SELECT m.nombre_oficial
        FROM v2.cat_municipios m
        WHERE lower(
          translate(
            btrim(m.nombre_oficial),
            'ÁÉÍÓÚÜÑáéíóúüñ',
            'AEIOUUNaeiouun'
          )
        ) = n.n_municipio
        LIMIT 1
      ),
      (
        SELECT m.nombre_oficial
        FROM v2.cat_municipio_alias a
        JOIN v2.cat_municipios m
          ON m.id = a.municipio_id
        WHERE lower(
          translate(
            btrim(a.alias),
            'ÁÉÍÓÚÜÑáéíóúüñ',
            'AEIOUUNaeiouun'
          )
        ) = n.n_municipio
          AND a.activo = true
        LIMIT 1
      )
    ) AS municipio_normalizado

  FROM normalizado n
),


-- ============================================================================
-- 02. FIRMA DE ORIGEN
--
-- Estas firmas corresponden a textos que el propio frontend/importador V1
-- generaba programáticamente.
-- ============================================================================

firma AS (
  SELECT
    t.*,

    CASE
      WHEN t.n_disciplina LIKE 'proyecto estrategico:%'
        AND t.n_sede LIKE '%cobertura estatal%'
        THEN 'IMPORT_PROYECTO_ESTRATEGICO_2025'

      WHEN t.n_disciplina LIKE 'indicador presupuestal 2026%'
        THEN 'IMPORT_INDICADOR_PRESUPUESTAL_2026'

      WHEN t.n_disciplina LIKE 'proyecto sociocultural:%'
        THEN 'IMPORT_PROYECTO_SOCIOCULTURAL_2025'

      WHEN t.n_disciplina LIKE 'numeralia informe: red de talleres%'
        THEN 'IMPORT_NUMERALIA_TALLERES_2025'

      WHEN t.n_disciplina LIKE
           'concentrado anual de formacion y talleres%'
        THEN 'IMPORT_CONCENTRADO_TALLERES_2025'

      WHEN upper(COALESCE(t.area_programa, '')) = 'BIBLIOTECAS'
        OR t.n_sede LIKE '%biblioteca%'
        OR t.n_disciplina LIKE '%lectura%'
        OR t.n_disciplina LIKE '%bibliotec%'
        THEN 'BIBLIOTECA_LEGACY'

      WHEN upper(COALESCE(t.area_programa, '')) = 'CDCM'
        AND NULLIF(btrim(COALESCE(t.docente, '')), '') IS NOT NULL
        AND NULLIF(btrim(COALESCE(t.horario, '')), '') IS NOT NULL
        AND (
          NULLIF(btrim(COALESCE(t.dias, '')), '') IS NOT NULL
          OR NULLIF(btrim(COALESCE(t.sesion, '')), '') IS NOT NULL
        )
        AND t.n_sede NOT LIKE '%cobertura estatal%'
        THEN 'POSIBLE_TALLER_MUNICIPAL'

      ELSE 'DESCONOCIDO'
    END AS firma_origen

  FROM territorio t
),


-- ============================================================================
-- 03. PERIODO CANDIDATO + CONFIANZA
-- ============================================================================

periodo AS (
  SELECT
    f.*,

    CASE
      -- Año explícito en campos fuente.
      WHEN (
        COALESCE(f.programacion, '') ~* '(^|[^0-9])2025([^0-9]|$)'
        OR COALESCE(f.disciplina, '') ~* '(^|[^0-9])2025([^0-9]|$)'
      )
        THEN 2025

      WHEN (
        COALESCE(f.programacion, '') ~* '(^|[^0-9])2026([^0-9]|$)'
        OR COALESCE(f.disciplina, '') ~* '(^|[^0-9])2026([^0-9]|$)'
      )
        THEN 2026

      -- Firma generada por importadores cuyo año estaba fijado en código.
      WHEN f.firma_origen IN (
        'IMPORT_PROYECTO_ESTRATEGICO_2025',
        'IMPORT_PROYECTO_SOCIOCULTURAL_2025',
        'IMPORT_NUMERALIA_TALLERES_2025',
        'IMPORT_CONCENTRADO_TALLERES_2025'
      )
        THEN 2025

      WHEN f.firma_origen = 'IMPORT_INDICADOR_PRESUPUESTAL_2026'
        THEN 2026

      -- No se fuerza año para talleres municipales genéricos.
      ELSE NULL
    END AS periodo_candidato,

    CASE
      WHEN (
        COALESCE(f.programacion, '') ~* '(^|[^0-9])202[56]([^0-9]|$)'
        OR COALESCE(f.disciplina, '') ~* '(^|[^0-9])202[56]([^0-9]|$)'
      )
        THEN 'ALTA_EXPLICITO'

      WHEN f.firma_origen IN (
        'IMPORT_PROYECTO_ESTRATEGICO_2025',
        'IMPORT_PROYECTO_SOCIOCULTURAL_2025',
        'IMPORT_NUMERALIA_TALLERES_2025',
        'IMPORT_CONCENTRADO_TALLERES_2025',
        'IMPORT_INDICADOR_PRESUPUESTAL_2026'
      )
        THEN 'ALTA_POR_FIRMA'

      WHEN f.firma_origen = 'POSIBLE_TALLER_MUNICIPAL'
        THEN 'SIN_PERIODO'

      ELSE 'SIN_PERIODO'
    END AS confianza_periodo,

    CASE
      WHEN f.created_at IS NOT NULL
        THEN EXTRACT(YEAR FROM f.created_at)::INTEGER
      ELSE NULL
    END AS anio_carga_v1

  FROM firma f
),


-- ============================================================================
-- 04. EXTRAER CLAVE PB CUANDO ESTÁ ESCRITA EN EL REGISTRO
-- ============================================================================

clave_pb AS (
  SELECT
    p.*,

    upper(
      substring(
        COALESCE(p.disciplina, '')
        FROM '(PB[0-9]{4}\.260[0-9]+)'
      )
    ) AS clave_pb_explicita

  FROM periodo p
),


-- ============================================================================
-- 05. PROPUESTA DE ACCIÓN V2
-- ============================================================================

accion AS (
  SELECT
    p.*,

    CASE
      -- ---------------------------------------------------------------
      -- 2026: únicamente si la clave PB está explícita y existe.
      -- ---------------------------------------------------------------
      WHEN p.clave_pb_explicita = 'PB3562.2601'
        THEN 'PB3562_2601'
      WHEN p.clave_pb_explicita = 'PB3562.2602'
        THEN 'PB3562_2602'
      WHEN p.clave_pb_explicita = 'PB3562.2603'
        THEN 'PB3562_2603'
      WHEN p.clave_pb_explicita = 'PB3562.2604'
        THEN 'PB3562_2604'
      WHEN p.clave_pb_explicita = 'PB3562.2605'
        THEN 'PB3562_2605'

      WHEN p.clave_pb_explicita = 'PB3563.2601'
        THEN 'PB3563_2601'
      WHEN p.clave_pb_explicita = 'PB3563.2602'
        THEN 'PB3563_2602'
      WHEN p.clave_pb_explicita = 'PB3563.2603'
        THEN 'PB3563_2603'
      WHEN p.clave_pb_explicita = 'PB3563.2604'
        THEN 'PB3563_2604'
      WHEN p.clave_pb_explicita = 'PB3563.2605'
        THEN 'PB3563_2605'

      WHEN p.clave_pb_explicita = 'PB3564.2601'
        THEN 'PB3564_2601'
      WHEN p.clave_pb_explicita = 'PB3564.2602'
        THEN 'PB3564_2602'
      WHEN p.clave_pb_explicita = 'PB3564.2603'
        THEN 'PB3564_2603'

      -- ---------------------------------------------------------------
      -- 2025 / histórico: firmas y semántica suficientemente claras.
      -- ---------------------------------------------------------------
      WHEN p.n_disciplina LIKE 'proyecto sociocultural:%'
        THEN 'PROYECTO_SOCIOCULTURAL'

      WHEN p.n_disciplina LIKE '%proyecto%circuito%'
        OR p.n_disciplina LIKE '%circuito cultural%'
        THEN 'ACTIVIDAD_PROYECTO_CIRCUITO'

      WHEN p.n_disciplina LIKE '%proyecto%regional%'
        OR p.n_disciplina LIKE '%regional cultural%'
        THEN 'ACTIVIDAD_PROYECTO_REGIONAL'

      WHEN p.n_disciplina LIKE '%intercambio%'
        THEN 'INTERCAMBIO_CULTURAL'

      WHEN p.n_disciplina LIKE '%articulacion%'
        THEN 'ARTICULACION_INTER_INTRA'

      WHEN p.n_disciplina LIKE '%reunion%'
        THEN 'REUNION_COLABORACION'

      WHEN p.n_disciplina LIKE '%capacitacion%'
        THEN 'CAPACITACION_PROMOTORES'

      WHEN p.n_disciplina LIKE '%verano%'
        THEN 'TALLER_VERANO'

      WHEN p.n_disciplina LIKE '%exposicion%'
        OR p.n_disciplina LIKE '%muestra%'
        OR p.n_disciplina LIKE '%exhibicion%'
        THEN 'EXPOSICION_MUESTRA'

      WHEN p.n_disciplina LIKE '%evento%'
        OR p.n_disciplina LIKE '%festival%'
        OR p.n_disciplina LIKE '%feria%'
        OR p.n_disciplina LIKE '%fiesta%'
        THEN 'EVENTO_MUNICIPAL'

      -- Agregados no equivalen a un registro unitario.
      WHEN p.firma_origen IN (
        'IMPORT_PROYECTO_ESTRATEGICO_2025',
        'IMPORT_NUMERALIA_TALLERES_2025',
        'IMPORT_CONCENTRADO_TALLERES_2025'
      )
        THEN NULL

      -- Bibliotecas legacy no se fuerza a un PB moderno.
      WHEN p.firma_origen = 'BIBLIOTECA_LEGACY'
        THEN NULL

      -- Taller municipal con estructura fuerte.
      WHEN p.firma_origen = 'POSIBLE_TALLER_MUNICIPAL'
        AND (
          p.n_sede LIKE '%salon%cultura%'
          OR p.n_sede LIKE '%salon cultural%'
        )
        THEN 'TALLER_SALON_CULTURA'

      WHEN p.firma_origen = 'POSIBLE_TALLER_MUNICIPAL'
        THEN 'TALLER_CASA_CULTURA'

      ELSE NULL
    END AS accion_v2_candidata,

    CASE
      WHEN p.clave_pb_explicita IS NOT NULL
        THEN 'ALTA_CLAVE_EXPLICITA'

      WHEN p.n_disciplina LIKE 'proyecto sociocultural:%'
        OR p.n_disciplina LIKE '%proyecto%circuito%'
        OR p.n_disciplina LIKE '%proyecto%regional%'
        OR p.n_disciplina LIKE '%intercambio%'
        OR p.n_disciplina LIKE '%articulacion%'
        OR p.n_disciplina LIKE '%reunion%'
        OR p.n_disciplina LIKE '%capacitacion%'
        OR p.n_disciplina LIKE '%verano%'
        OR p.n_disciplina LIKE '%exposicion%'
        OR p.n_disciplina LIKE '%muestra%'
        OR p.n_disciplina LIKE '%evento%'
        OR p.n_disciplina LIKE '%festival%'
        THEN 'ALTA_SEMANTICA'

      WHEN p.firma_origen = 'POSIBLE_TALLER_MUNICIPAL'
        THEN 'MEDIA_ESTRUCTURA_TALLER'

      ELSE 'SIN_CLASIFICAR'
    END AS confianza_accion

  FROM clave_pb p
),


-- ============================================================================
-- 06. CALIDAD HISTÓRICA
-- ============================================================================

calidad AS (
  SELECT
    a.*,

    (
      a.total_beneficiarios = 1
      AND COALESCE(a.mujeres, 0) = 0
      AND COALESCE(a.hombres, 0) = 0
      AND COALESCE(a.ninez, 0) = 0
      AND COALESCE(a.adolescencia, 0) = 0
      AND COALESCE(a.juventudes, 0) = 0
      AND COALESCE(a.adultos_mayores, 0) = 0
      AND COALESCE(a.discapacidad, 0) = 0
      AND COALESCE(a.indigenas, 0) = 0
      AND COALESCE(a.afromexicanas, 0) = 0
      AND COALESCE(a.lgbtq, 0) = 0
    ) AS total_uno_artificial,

    (
      COALESCE(a.total_beneficiarios, 0) > 0
      AND (
        (
          COALESCE(a.mujeres, 0)
            = round(a.total_beneficiarios * 0.58)
          AND COALESCE(a.hombres, 0)
            = a.total_beneficiarios
              - round(a.total_beneficiarios * 0.58)
          AND (
            (
              COALESCE(a.ninez, 0)
                = round(a.total_beneficiarios * 0.35)
              AND COALESCE(a.adolescencia, 0)
                = round(a.total_beneficiarios * 0.28)
              AND COALESCE(a.juventudes, 0)
                = round(a.total_beneficiarios * 0.22)
            )
            OR
            (
              COALESCE(a.ninez, 0)
                = round(a.total_beneficiarios * 0.35)
              AND COALESCE(a.adolescencia, 0)
                = round(a.total_beneficiarios * 0.30)
              AND COALESCE(a.juventudes, 0)
                = round(a.total_beneficiarios * 0.20)
            )
          )
        )

        OR

        (
          COALESCE(a.mujeres, 0)
            = round(a.total_beneficiarios * 0.55)
          AND COALESCE(a.hombres, 0)
            = GREATEST(
                0,
                a.total_beneficiarios
                  - round(a.total_beneficiarios * 0.55)
              )
          AND COALESCE(a.adolescencia, 0)
            = round(a.total_beneficiarios * 0.25)
          AND COALESCE(a.juventudes, 0)
            = round(a.total_beneficiarios * 0.20)
        )
      )
    ) AS demografia_posiblemente_sintetica,

    (
      a.n_sede LIKE '%cobertura estatal%'
      OR a.firma_origen IN (
        'IMPORT_NUMERALIA_TALLERES_2025',
        'IMPORT_CONCENTRADO_TALLERES_2025',
        'IMPORT_PROYECTO_ESTRATEGICO_2025'
      )
    ) AS agregado_o_cobertura,

    CASE
      WHEN a.foto_url IS NULL OR btrim(a.foto_url) = ''
        THEN 'SIN_EVIDENCIA'
      WHEN a.foto_url ILIKE
        '%/storage/v1/object/public/evidencias/%'
        THEN 'URL_PUBLICA_V1'
      WHEN a.foto_url ILIKE 'http%'
        THEN 'URL_COMPLETA'
      ELSE 'RUTA_STORAGE'
    END AS evidencia_tipo

  FROM accion a
),


-- ============================================================================
-- 07. DISPONIBILIDAD DE DESTINO
-- ============================================================================

destino AS (
  SELECT
    c.*,

    av2.id AS accion_v2_id,

    ca.id AS configuracion_v2_id,

    CASE
      WHEN av2.id IS NULL THEN false
      WHEN c.periodo_candidato IS NULL THEN false
      WHEN ca.id IS NULL THEN false
      ELSE true
    END AS destino_exacto_disponible

  FROM calidad c

  LEFT JOIN v2.cat_acciones av2
    ON upper(btrim(av2.clave))
       = upper(btrim(c.accion_v2_candidata))
   AND av2.activo = true

  LEFT JOIN LATERAL (
    SELECT x.id
    FROM v2.configuracion_acciones x
    WHERE x.accion_id = av2.id
      AND x.activo = true
      AND c.periodo_candidato IS NOT NULL
      AND make_date(
            c.periodo_candidato,
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


-- ============================================================================
-- 08. PROPUESTA DE STAGING
--
-- MIGRAR_NORMAL:
--   municipio, periodo, acción y configuración de destino son claros y no
--   existen señales fuertes de agregado/dato sintético.
--
-- MIGRAR_BORRADOR:
--   el registro puede conservarse en V2, pero debe permanecer fuera de
--   indicadores automáticos hasta revisión/validación.
--
-- CONSERVAR_STAGING:
--   aún falta resolver una dimensión estructural importante.
-- ============================================================================

propuesta AS (
  SELECT
    d.*,

    CASE
      WHEN d.municipio_v2_id IS NULL
        OR d.agregado_o_cobertura = true
        OR d.accion_v2_candidata IS NULL

        THEN 'CONSERVAR_STAGING'

      WHEN d.periodo_candidato IS NULL
        OR d.destino_exacto_disponible = false
        OR d.total_uno_artificial
        OR d.demografia_posiblemente_sintetica
        OR d.folio IS NULL
        OR btrim(COALESCE(d.folio, '')) = ''
        OR d.folio_repeticiones > 1
        OR d.usuario IS NULL
        OR btrim(COALESCE(d.usuario, '')) = ''
        OR d.evidencia_tipo IN (
          'URL_PUBLICA_V1',
          'URL_COMPLETA'
        )

        THEN 'MIGRAR_BORRADOR'

      ELSE 'MIGRAR_NORMAL'
    END AS propuesta_staging

  FROM destino d
),


-- ============================================================================
-- 09. AGREGACIONES PARA UN RESULTADO COMPACTO
-- ============================================================================

fuentes AS (
  SELECT
    firma_origen AS clave,
    count(*)::INTEGER AS registros
  FROM propuesta
  GROUP BY firma_origen
),

periodos AS (
  SELECT
    COALESCE(periodo_candidato::TEXT, 'SIN_PERIODO') AS clave,
    count(*)::INTEGER AS registros
  FROM propuesta
  GROUP BY COALESCE(periodo_candidato::TEXT, 'SIN_PERIODO')
),

conf_periodos AS (
  SELECT
    confianza_periodo AS clave,
    count(*)::INTEGER AS registros
  FROM propuesta
  GROUP BY confianza_periodo
),

acciones AS (
  SELECT
    COALESCE(
      accion_v2_candidata,
      'SIN_CLASIFICAR'
    ) AS clave,
    count(*)::INTEGER AS registros
  FROM propuesta
  GROUP BY COALESCE(
    accion_v2_candidata,
    'SIN_CLASIFICAR'
  )
),

conf_acciones AS (
  SELECT
    confianza_accion AS clave,
    count(*)::INTEGER AS registros
  FROM propuesta
  GROUP BY confianza_accion
),

staging AS (
  SELECT
    propuesta_staging AS clave,
    count(*)::INTEGER AS registros
  FROM propuesta
  GROUP BY propuesta_staging
),

municipios_pendientes AS (
  SELECT
    COALESCE(
      NULLIF(btrim(municipio), ''),
      '[VACÍO]'
    ) AS municipio,
    count(*)::INTEGER AS registros
  FROM propuesta
  WHERE municipio_v2_id IS NULL
  GROUP BY COALESCE(
    NULLIF(btrim(municipio), ''),
    '[VACÍO]'
  )
  ORDER BY registros DESC, municipio
),

programaciones_sin_periodo AS (
  SELECT
    COALESCE(
      NULLIF(btrim(programacion), ''),
      '[VACÍO]'
    ) AS programacion,
    count(*)::INTEGER AS registros
  FROM propuesta
  WHERE periodo_candidato IS NULL
  GROUP BY COALESCE(
    NULLIF(btrim(programacion), ''),
    '[VACÍO]'
  )
  ORDER BY registros DESC, programacion
  LIMIT 30
),

disciplinas_sin_clasificar AS (
  SELECT
    COALESCE(
      NULLIF(btrim(disciplina), ''),
      '[VACÍO]'
    ) AS disciplina,
    count(*)::INTEGER AS registros
  FROM propuesta
  WHERE accion_v2_candidata IS NULL
  GROUP BY COALESCE(
    NULLIF(btrim(disciplina), ''),
    '[VACÍO]'
  )
  ORDER BY registros DESC, disciplina
  LIMIT 40
)


-- ============================================================================
-- 10. RESULTADO ÚNICO
-- ============================================================================

SELECT
  'V2.1 - 10a legacy classifier' AS diagnostico,

  count(*) AS legacy_total,

  count(*) FILTER (
    WHERE municipio_v2_id IS NOT NULL
  ) AS municipios_resueltos,

  count(*) FILTER (
    WHERE municipio_v2_id IS NULL
  ) AS municipios_pendientes,

  count(*) FILTER (
    WHERE periodo_candidato IS NOT NULL
  ) AS periodo_clasificado,

  count(*) FILTER (
    WHERE periodo_candidato IS NULL
  ) AS periodo_sin_clasificar,

  count(*) FILTER (
    WHERE accion_v2_candidata IS NOT NULL
  ) AS accion_clasificada,

  count(*) FILTER (
    WHERE accion_v2_candidata IS NULL
  ) AS accion_sin_clasificar,

  count(*) FILTER (
    WHERE destino_exacto_disponible
  ) AS destino_exacto_disponible,

  count(*) FILTER (
    WHERE total_uno_artificial
  ) AS total_uno_artificial,

  count(*) FILTER (
    WHERE demografia_posiblemente_sintetica
  ) AS demografia_posiblemente_sintetica,

  count(*) FILTER (
    WHERE agregado_o_cobertura
  ) AS agregados_o_cobertura,

  count(*) FILTER (
    WHERE propuesta_staging = 'MIGRAR_NORMAL'
  ) AS migrar_normal,

  count(*) FILTER (
    WHERE propuesta_staging = 'MIGRAR_BORRADOR'
  ) AS migrar_borrador,

  count(*) FILTER (
    WHERE propuesta_staging = 'CONSERVAR_STAGING'
  ) AS conservar_staging,

  (
    SELECT COALESCE(
      jsonb_object_agg(
        f.clave,
        f.registros
        ORDER BY f.clave
      ),
      '{}'::jsonb
    )
    FROM fuentes f
  ) AS resumen_firmas_origen,

  (
    SELECT COALESCE(
      jsonb_object_agg(
        p.clave,
        p.registros
        ORDER BY p.clave
      ),
      '{}'::jsonb
    )
    FROM periodos p
  ) AS resumen_periodos,

  (
    SELECT COALESCE(
      jsonb_object_agg(
        cp.clave,
        cp.registros
        ORDER BY cp.clave
      ),
      '{}'::jsonb
    )
    FROM conf_periodos cp
  ) AS resumen_confianza_periodo,

  (
    SELECT COALESCE(
      jsonb_object_agg(
        a.clave,
        a.registros
        ORDER BY a.clave
      ),
      '{}'::jsonb
    )
    FROM acciones a
  ) AS resumen_acciones,

  (
    SELECT COALESCE(
      jsonb_object_agg(
        ca.clave,
        ca.registros
        ORDER BY ca.clave
      ),
      '{}'::jsonb
    )
    FROM conf_acciones ca
  ) AS resumen_confianza_accion,

  (
    SELECT COALESCE(
      jsonb_object_agg(
        s.clave,
        s.registros
        ORDER BY s.clave
      ),
      '{}'::jsonb
    )
    FROM staging s
  ) AS resumen_propuesta_staging,

  (
    SELECT COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'municipio', mp.municipio,
          'registros', mp.registros
        )
        ORDER BY mp.registros DESC, mp.municipio
      ),
      '[]'::jsonb
    )
    FROM municipios_pendientes mp
  ) AS detalle_municipios_pendientes,

  (
    SELECT COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'programacion', ps.programacion,
          'registros', ps.registros
        )
        ORDER BY ps.registros DESC, ps.programacion
      ),
      '[]'::jsonb
    )
    FROM programaciones_sin_periodo ps
  ) AS detalle_programaciones_sin_periodo,

  (
    SELECT COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'disciplina', ds.disciplina,
          'registros', ds.registros
        )
        ORDER BY ds.registros DESC, ds.disciplina
      ),
      '[]'::jsonb
    )
    FROM disciplinas_sin_clasificar ds
  ) AS detalle_disciplinas_sin_clasificar,

  (
    SELECT count(*)
    FROM v2.registros
  ) AS registros_v2_actuales,

  (
    SELECT count(*)
    FROM v2.schema_migrations
    WHERE version = '2.1.09e'
  ) AS seed_09e_confirmado

FROM propuesta;


COMMIT;


-- ============================================================================
-- INTERPRETACIÓN
--
-- Este clasificador NO necesita llegar a 317/317.
--
-- ÉXITO significa:
--
--   1. Reducir significativamente accion_sin_clasificar.
--   2. Separar los agregados/cobertura de los registros unitarios.
--   3. Identificar qué filas pueden entrar como MIGRAR_BORRADOR.
--   4. Dejar únicamente problemas estructurales en CONSERVAR_STAGING.
--
-- IMPORTANTE:
--
-- MIGRAR_BORRADOR NO significa perder el registro.
-- Significa conservarlo en V2 con trazabilidad, pero SIN permitir que alimente
-- indicadores hasta ser revisado/validado.
--
-- SIGUIENTE:
--
--   10b_legacy_migration_staging.sql
--
-- ============================================================================
