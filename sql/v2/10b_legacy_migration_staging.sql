-- ============================================================================
-- VINCULACIÓN CULTURAL 2.0
-- 10b_legacy_migration_staging.sql
-- Staging persistente y auditable de V1 -> V2
-- Secretaría de Cultura de Guanajuato
--
-- REQUIERE:
--   01_core_schema.sql
--   ...
--   09e_operational_seed_2026.sql
--   10_legacy_migration_preflight.sql
--   10a_legacy_classifier.sql
--
-- ESTE ARCHIVO:
--   ✓ NO modifica public.registros_culturales
--   ✓ NO inserta todavía en v2.registros
--   ✓ crea un import_job de migración histórica
--   ✓ copia las 317 filas V1 a v2.import_staging
--   ✓ conserva raw_data íntegro
--   ✓ guarda clasificación / normalización / advertencias
--   ✓ congela la decisión MIGRAR_BORRADOR / CONSERVAR_STAGING
--   ✓ registra la migración 2.1.10b
--
-- PRINCIPIO:
--   El staging es el "contrato" entre V1 y la futura migración productiva.
--   Ninguna fila V1 se altera.
--
-- IMPORTANTE:
--   Todos los registros que posteriormente entren en v2.registros desde este
--   staging entrarán inicialmente como BORRADOR.
--   La migración histórica NO valida datos automáticamente.
-- ============================================================================

BEGIN;

SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '240s';


-- ============================================================================
-- 00. PRECONDICIONES
-- ============================================================================

DO $$
DECLARE
  v_jobs INTEGER;
  v_rows INTEGER;
BEGIN
  IF to_regclass('public.registros_culturales') IS NULL THEN
    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: public.registros_culturales no existe.';
  END IF;

  IF to_regclass('v2.import_jobs') IS NULL
     OR to_regclass('v2.import_staging') IS NULL
     OR to_regclass('v2.registros') IS NULL THEN
    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: faltan objetos de importación V2.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM v2.schema_migrations
    WHERE version = '2.1.09e'
  ) THEN
    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: 09e no está registrado.';
  END IF;

  -- No queremos mezclar staging con una migración ya ejecutada.
  IF EXISTS (
    SELECT 1
    FROM v2.registros
    WHERE origen = 'MIGRACION_V1'
  ) THEN
    RAISE EXCEPTION
      'SEGURIDAD: ya existen registros MIGRACION_V1 en v2.registros. No recrear staging.';
  END IF;

  SELECT count(*)
  INTO v_jobs
  FROM v2.import_jobs
  WHERE tipo_importacion = 'MIGRACION_V1'
    AND metadata ->> 'migration_key'
        = 'LEGACY_V1_TO_V2_STAGE_2026';

  IF v_jobs > 1 THEN
    RAISE EXCEPTION
      'SEGURIDAD: existen % import_jobs con la misma migration_key.',
      v_jobs;
  END IF;

  IF v_jobs = 1 THEN
    SELECT count(*)
    INTO v_rows
    FROM v2.import_staging s
    JOIN v2.import_jobs j
      ON j.id = s.import_job_id
    WHERE j.tipo_importacion = 'MIGRACION_V1'
      AND j.metadata ->> 'migration_key'
          = 'LEGACY_V1_TO_V2_STAGE_2026';

    IF v_rows > 0 THEN
      RAISE EXCEPTION
        'SEGURIDAD: el staging histórico ya existe con % filas. No se sobrescribirá.',
        v_rows;
    END IF;
  END IF;
END
$$;


-- ============================================================================
-- 01. CREAR CABECERA DEL TRABAJO DE MIGRACIÓN
-- ============================================================================

INSERT INTO v2.import_jobs (
  tipo_importacion,
  archivo_nombre,
  storage_path,
  usuario_id,
  estatus,
  total_filas,
  filas_validas,
  filas_error,
  filas_duplicadas,
  filas_importadas,
  metadata
)
SELECT
  'MIGRACION_V1',
  'public.registros_culturales',
  NULL,
  auth.uid(),
  'VALIDANDO',
  0,
  0,
  0,
  0,
  0,
  pg_catalog.jsonb_build_object(
    'migration_key',
    'LEGACY_V1_TO_V2_STAGE_2026',
    'source_schema',
    'public',
    'source_table',
    'registros_culturales',
    'classifier',
    '10a_legacy_classifier.sql',
    'target_schema',
    'v2',
    'target_table',
    'registros',
    'strategy',
    'PRESERVAR_EN_BORRADOR',
    'created_by_sql',
    '10b_legacy_migration_staging.sql'
  )
WHERE NOT EXISTS (
  SELECT 1
  FROM v2.import_jobs
  WHERE tipo_importacion = 'MIGRACION_V1'
    AND metadata ->> 'migration_key'
        = 'LEGACY_V1_TO_V2_STAGE_2026'
);


-- ============================================================================
-- 02. CLASIFICAR Y CONGELAR LAS 317 FILAS
-- ============================================================================

WITH

legacy_base AS (
  SELECT
    row_number() OVER (
      ORDER BY
        r.created_at NULLS LAST,
        r.folio NULLS LAST,
        r.municipio NULLS LAST,
        r.disciplina NULLS LAST,
        r.ctid
    )::INTEGER AS numero_fila,

    r.ctid::TEXT AS legacy_row_ref,

    pg_catalog.to_jsonb(r) AS raw_data,

    pg_catalog.md5(
      pg_catalog.to_jsonb(r)::TEXT
    ) AS source_hash,

    r.*,

    count(*) OVER (
      PARTITION BY NULLIF(btrim(r.folio), '')
    ) AS folio_repeticiones

  FROM public.registros_culturales r
),


legacy AS (
  SELECT
    b.*,

    row_number() OVER (
      PARTITION BY b.source_hash
      ORDER BY
        b.created_at NULLS LAST,
        b.folio NULLS LAST,
        b.legacy_row_ref
    )::INTEGER AS source_occurrence

  FROM legacy_base b
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


periodo AS (
  SELECT
    f.*,

    CASE
      WHEN (
        COALESCE(f.programacion, '') ~*
          '(^|[^0-9])2025([^0-9]|$)'
        OR COALESCE(f.disciplina, '') ~*
          '(^|[^0-9])2025([^0-9]|$)'
      )
        THEN 2025

      WHEN (
        COALESCE(f.programacion, '') ~*
          '(^|[^0-9])2026([^0-9]|$)'
        OR COALESCE(f.disciplina, '') ~*
          '(^|[^0-9])2026([^0-9]|$)'
      )
        THEN 2026

      WHEN f.firma_origen IN (
        'IMPORT_PROYECTO_ESTRATEGICO_2025',
        'IMPORT_PROYECTO_SOCIOCULTURAL_2025',
        'IMPORT_NUMERALIA_TALLERES_2025',
        'IMPORT_CONCENTRADO_TALLERES_2025'
      )
        THEN 2025

      WHEN f.firma_origen =
           'IMPORT_INDICADOR_PRESUPUESTAL_2026'
        THEN 2026

      ELSE NULL
    END AS periodo_candidato,

    CASE
      WHEN (
        COALESCE(f.programacion, '') ~*
          '(^|[^0-9])202[56]([^0-9]|$)'
        OR COALESCE(f.disciplina, '') ~*
          '(^|[^0-9])202[56]([^0-9]|$)'
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

      ELSE 'SIN_PERIODO'
    END AS confianza_periodo

  FROM firma f
),


periodo_destino AS (
  SELECT
    p.*,

    COALESCE(
      p.periodo_candidato,
      EXTRACT(YEAR FROM p.created_at)::INTEGER,
      EXTRACT(YEAR FROM p.fecha_actividad)::INTEGER
    ) AS periodo_destino,

    CASE
      WHEN p.periodo_candidato IS NOT NULL
        THEN 'FUENTE_O_FIRMA'
      WHEN p.created_at IS NOT NULL
        THEN 'FALLBACK_CREATED_AT'
      WHEN p.fecha_actividad IS NOT NULL
        THEN 'FALLBACK_FECHA_ACTIVIDAD'
      ELSE 'SIN_PERIODO'
    END AS fuente_periodo_destino

  FROM periodo p
),


clave_pb AS (
  SELECT
    p.*,

    upper(
      substring(
        COALESCE(p.disciplina, '')
        FROM '(PB[0-9]{4}\.260[0-9]+)'
      )
    ) AS clave_pb_explicita

  FROM periodo_destino p
),


accion AS (
  SELECT
    p.*,

    CASE
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

      WHEN p.firma_origen IN (
        'IMPORT_PROYECTO_ESTRATEGICO_2025',
        'IMPORT_NUMERALIA_TALLERES_2025',
        'IMPORT_CONCENTRADO_TALLERES_2025'
      )
        THEN NULL

      WHEN p.firma_origen = 'BIBLIOTECA_LEGACY'
        THEN NULL

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


destino AS (
  SELECT
    c.*,

    av2.id AS accion_v2_id,
    av2.unidad_operativa_id AS unidad_v2_id,
    av2.programa_id AS programa_v2_id,

    ca.id AS configuracion_v2_id,
    ca.tipo_registro_id AS tipo_registro_v2_id,
    ca.esquema_demografico_id,

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
    SELECT
      x.id,
      x.tipo_registro_id,
      x.esquema_demografico_id
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
-- 03. DECISIÓN PERSISTENTE
-- ============================================================================

decision AS (
  SELECT
    d.*,

    CASE
      WHEN d.municipio_v2_id IS NULL
        OR d.agregado_o_cobertura = true
        OR d.accion_v2_candidata IS NULL
        OR d.periodo_destino IS NULL

        THEN 'CONSERVAR_STAGING'

      ELSE 'MIGRAR_BORRADOR'
    END AS migration_mode,

    -- Todo histórico que llegue a v2.registros entra como BORRADOR.
    'BORRADOR'::TEXT AS target_status,

    CASE
      WHEN d.total_uno_artificial
        THEN NULL
      ELSE d.total_beneficiarios
    END AS total_beneficiarios_destino,

    (
      NOT d.demografia_posiblemente_sintetica
      AND NOT d.total_uno_artificial
    ) AS migrar_demografia,

    CASE
      WHEN d.evidencia_tipo = 'RUTA_STORAGE'
        THEN 'NORMALIZAR_RUTA'
      WHEN d.evidencia_tipo IN (
        'URL_PUBLICA_V1',
        'URL_COMPLETA'
      )
        THEN 'MIGRAR_METADATA_PENDIENTE_STORAGE'
      ELSE 'SIN_EVIDENCIA'
    END AS estrategia_evidencia,

    ARRAY_REMOVE(
      ARRAY[
        CASE
          WHEN d.municipio_v2_id IS NULL
          THEN 'MUNICIPIO_NO_RESUELTO'
        END,

        CASE
          WHEN d.agregado_o_cobertura
          THEN 'AGREGADO_O_COBERTURA_NO_UNITARIA'
        END,

        CASE
          WHEN d.accion_v2_candidata IS NULL
          THEN 'ACCION_V2_NO_CLASIFICADA'
        END,

        CASE
          WHEN d.periodo_candidato IS NULL
          THEN 'PERIODO_INFERIDO_POR_FECHA_DE_CARGA'
        END,

        CASE
          WHEN d.periodo_destino IS NULL
          THEN 'PERIODO_DESTINO_NO_RESUELTO'
        END,

        CASE
          WHEN d.accion_v2_candidata IS NOT NULL
               AND d.configuracion_v2_id IS NULL
          THEN 'SIN_CONFIGURACION_EXACTA_PARA_PERIODO'
        END,

        CASE
          WHEN d.total_uno_artificial
          THEN 'TOTAL_BENEFICIARIOS_1_ARTIFICIAL'
        END,

        CASE
          WHEN d.demografia_posiblemente_sintetica
          THEN 'DEMOGRAFIA_POSIBLEMENTE_ESTIMADA'
        END,

        CASE
          WHEN d.folio IS NULL
               OR btrim(COALESCE(d.folio, '')) = ''
          THEN 'FOLIO_V1_FALTANTE'
        END,

        CASE
          WHEN d.folio IS NOT NULL
               AND btrim(d.folio) <> ''
               AND d.folio_repeticiones > 1
          THEN 'FOLIO_V1_DUPLICADO'
        END,

        CASE
          WHEN d.usuario IS NULL
               OR btrim(COALESCE(d.usuario, '')) = ''
          THEN 'USUARIO_V1_FALTANTE'
        END,

        CASE
          WHEN d.evidencia_tipo IN (
            'URL_PUBLICA_V1',
            'URL_COMPLETA'
          )
          THEN 'EVIDENCIA_V1_REQUIERE_NORMALIZACION'
        END
      ],
      NULL
    )::TEXT[] AS advertencias

  FROM destino d
),


-- ============================================================================
-- 04. JSON NORMALIZADO DEL STAGING
-- ============================================================================

prepared AS (
  SELECT
    d.numero_fila,
    d.raw_data,

    pg_catalog.jsonb_build_object(
      -- Identidad fuente
      'source_hash',
      d.source_hash,
      'source_occurrence',
      d.source_occurrence,
      'legacy_row_ref',
      d.legacy_row_ref,
      'legacy_folio',
      d.folio,

      -- Clasificación
      'firma_origen',
      d.firma_origen,
      'periodo_candidato',
      d.periodo_candidato,
      'confianza_periodo',
      d.confianza_periodo,
      'periodo_destino',
      d.periodo_destino,
      'fuente_periodo_destino',
      d.fuente_periodo_destino,

      'accion_v2_clave',
      d.accion_v2_candidata,
      'confianza_accion',
      d.confianza_accion,

      -- Destino
      'municipio_v2_id',
      d.municipio_v2_id,
      'municipio_normalizado',
      d.municipio_normalizado,

      'unidad_operativa_v2_id',
      d.unidad_v2_id,
      'programa_v2_id',
      d.programa_v2_id,
      'accion_v2_id',
      d.accion_v2_id,
      'configuracion_v2_id',
      d.configuracion_v2_id,
      'tipo_registro_v2_id',
      d.tipo_registro_v2_id,
      'esquema_demografico_id',
      d.esquema_demografico_id,

      -- Estrategia de migración
      'migration_mode',
      d.migration_mode,
      'target_status',
      d.target_status,
      'origen_v2',
      'MIGRACION_V1',

      -- Beneficiarios
      'total_beneficiarios_original',
      d.total_beneficiarios,
      'total_beneficiarios_destino',
      d.total_beneficiarios_destino,
      'total_uno_artificial',
      d.total_uno_artificial,

      'migrar_demografia',
      d.migrar_demografia,
      'demografia_posiblemente_sintetica',
      d.demografia_posiblemente_sintetica,

      -- Evidencia
      'evidencia_tipo',
      d.evidencia_tipo,
      'estrategia_evidencia',
      d.estrategia_evidencia,

      -- Seguridad semántica
      'destino_exacto_disponible',
      d.destino_exacto_disponible,
      'advertencias',
      pg_catalog.to_jsonb(d.advertencias)
    ) AS normalized_data,

    CASE
      WHEN d.migration_mode = 'MIGRAR_BORRADOR'
        THEN 'VALIDO'
      ELSE 'ERROR'
    END AS estatus_staging,

    pg_catalog.to_jsonb(d.advertencias) AS errores

  FROM decision d
),


job AS (
  SELECT id
  FROM v2.import_jobs
  WHERE tipo_importacion = 'MIGRACION_V1'
    AND metadata ->> 'migration_key'
        = 'LEGACY_V1_TO_V2_STAGE_2026'
  LIMIT 1
)


INSERT INTO v2.import_staging (
  import_job_id,
  numero_fila,
  raw_data,
  normalized_data,
  estatus,
  errores
)
SELECT
  j.id,
  p.numero_fila,
  p.raw_data,
  p.normalized_data,
  p.estatus_staging,
  p.errores
FROM prepared p
CROSS JOIN job j
ORDER BY p.numero_fila;


-- ============================================================================
-- 05. ACTUALIZAR CABECERA DEL JOB
-- ============================================================================

WITH job AS (
  SELECT id
  FROM v2.import_jobs
  WHERE tipo_importacion = 'MIGRACION_V1'
    AND metadata ->> 'migration_key'
        = 'LEGACY_V1_TO_V2_STAGE_2026'
  LIMIT 1
),

stats AS (
  SELECT
    count(*)::INTEGER AS total,
    count(*) FILTER (
      WHERE s.estatus = 'VALIDO'
    )::INTEGER AS validas,
    count(*) FILTER (
      WHERE s.estatus = 'ERROR'
    )::INTEGER AS errores,

    count(*) FILTER (
      WHERE s.normalized_data ->> 'migration_mode'
            = 'MIGRAR_BORRADOR'
    )::INTEGER AS migrar_borrador,

    count(*) FILTER (
      WHERE s.normalized_data ->> 'migration_mode'
            = 'CONSERVAR_STAGING'
    )::INTEGER AS conservar_staging,

    count(*) FILTER (
      WHERE (
        s.normalized_data
          ->> 'demografia_posiblemente_sintetica'
      )::BOOLEAN = true
    )::INTEGER AS demografia_sintetica,

    count(*) FILTER (
      WHERE (
        s.normalized_data
          ->> 'total_uno_artificial'
      )::BOOLEAN = true
    )::INTEGER AS total_uno_artificial

  FROM v2.import_staging s
  JOIN job j
    ON j.id = s.import_job_id
)

UPDATE v2.import_jobs j
SET
  estatus = 'LISTO',
  total_filas = st.total,
  filas_validas = st.validas,
  filas_error = st.errores,
  filas_duplicadas = 0,
  filas_importadas = 0,
  metadata =
    j.metadata
    || pg_catalog.jsonb_build_object(
      'staging_total',
      st.total,
      'migrar_borrador',
      st.migrar_borrador,
      'conservar_staging',
      st.conservar_staging,
      'demografia_posiblemente_sintetica',
      st.demografia_sintetica,
      'total_uno_artificial',
      st.total_uno_artificial,
      'v1_immutable',
      true,
      'all_target_rows_start_as',
      'BORRADOR',
      'staged_at',
      pg_catalog.now()
    )
FROM stats st
WHERE j.id = (
  SELECT id FROM job
);


-- ============================================================================
-- 06. REGISTRAR MIGRACIÓN
-- ============================================================================

INSERT INTO v2.schema_migrations (
  version,
  descripcion
)
VALUES (
  '2.1.10b',
  '10b_legacy_migration_staging.sql - Snapshot auditable de V1 en import_staging; sin insertar aún en v2.registros.'
)
ON CONFLICT (version) DO NOTHING;


COMMIT;


-- ============================================================================
-- 07. VERIFICACIÓN POST-INSTALACIÓN
-- ============================================================================

WITH job AS (
  SELECT *
  FROM v2.import_jobs
  WHERE tipo_importacion = 'MIGRACION_V1'
    AND metadata ->> 'migration_key'
        = 'LEGACY_V1_TO_V2_STAGE_2026'
  LIMIT 1
),

s AS (
  SELECT st.*
  FROM v2.import_staging st
  JOIN job j
    ON j.id = st.import_job_id
)

SELECT
  'V2.1 - 10b legacy staging' AS instalacion,

  (SELECT count(*) FROM public.registros_culturales)
    AS filas_v1_actuales,

  (SELECT total_filas FROM job)
    AS job_total_filas,

  (SELECT count(*) FROM s)
    AS staging_filas,

  (SELECT count(*) FROM s WHERE estatus = 'VALIDO')
    AS staging_validas,

  (SELECT count(*) FROM s WHERE estatus = 'ERROR')
    AS staging_revision,

  (
    SELECT count(*)
    FROM s
    WHERE normalized_data ->> 'migration_mode'
          = 'MIGRAR_BORRADOR'
  ) AS migrar_borrador,

  (
    SELECT count(*)
    FROM s
    WHERE normalized_data ->> 'migration_mode'
          = 'CONSERVAR_STAGING'
  ) AS conservar_staging,

  (
    SELECT count(*)
    FROM s
    WHERE normalized_data ->> 'source_hash' IS NOT NULL
  ) AS filas_con_hash,

  (
    SELECT count(*)
    FROM s
    WHERE normalized_data ->> 'periodo_destino' IS NOT NULL
  ) AS filas_con_periodo_destino,

  (
    SELECT count(*)
    FROM s
    WHERE normalized_data ->> 'accion_v2_id' IS NOT NULL
  ) AS filas_con_accion_v2,

  (
    SELECT count(*)
    FROM v2.registros
    WHERE origen = 'MIGRACION_V1'
  ) AS registros_productivos_migrados,

  (SELECT estatus FROM job)
    AS job_estatus,

  (
    SELECT count(*)
    FROM v2.schema_migrations
    WHERE version = '2.1.10b'
  ) AS migracion_registrada;


-- ============================================================================
-- RESULTADO ESPERADO CON EL SNAPSHOT ACTUAL:
--
-- filas_v1_actuales              = 317
-- job_total_filas                = 317
-- staging_filas                  = 317
-- staging_validas                = 238
-- staging_revision               = 79
-- migrar_borrador                = 238
-- conservar_staging              = 79
-- filas_con_hash                 = 317
-- filas_con_periodo_destino      ≈ 317
-- filas_con_accion_v2            = 261
-- registros_productivos_migrados = 0
-- job_estatus                    = LISTO
-- migracion_registrada           = 1
--
-- IMPORTANTE:
-- Si staging_filas != filas_v1_actuales, DETENERSE.
--
-- SIGUIENTE PASO:
--
--   10_legacy_migration.sql
--
-- Ese archivo tomará EXCLUSIVAMENTE las filas:
--
--   migration_mode = MIGRAR_BORRADOR
--
-- e insertará esos registros en v2.registros como BORRADOR, conservando:
--   - raw_data histórico
--   - legacy_folio
--   - advertencias
--   - vínculo al import_job
--
-- Las 79 filas CONSERVAR_STAGING permanecerán intactas para revisión.
-- ============================================================================
