-- ============================================================================
-- VINCULACIÓN CULTURAL 2.0
-- 10_legacy_migration.sql
-- Migración productiva controlada V1 -> V2
-- Secretaría de Cultura de Guanajuato
--
-- REQUIERE:
--   01_core_schema.sql
--   02_catalogs.sql
--   03_operation_modules.sql
--   04_indicators.sql
--   05_functions_triggers.sql + 05a hotfix
--   06_rls.sql
--   07_storage.sql
--   08_views_rpc.sql
--   09_seed_base.sql
--   09b_operational_seed.sql
--   09d_demographic_model_2026.sql
--   09e_operational_seed_2026.sql
--   10_legacy_migration_preflight.sql
--   10a_legacy_classifier.sql
--   10b_legacy_migration_staging.sql
--
-- MIGRA:
--   ÚNICAMENTE filas del staging con:
--
--       migration_mode = MIGRAR_BORRADOR
--
-- PRINCIPIOS:
--   ✓ V1 permanece inmutable.
--   ✓ todos los históricos entran como BORRADOR.
--   ✓ se genera folio V2 nuevo y atómico.
--   ✓ legacy_folio conserva el folio V1.
--   ✓ raw_data completo queda en legacy_payload.
--   ✓ fila_origen enlaza exactamente con import_staging.numero_fila.
--   ✓ total artificial = 1 se convierte a NULL en V2.
--   ✓ demografía posiblemente estimada NO se normaliza a registro_poblacion.
--   ✓ total_beneficiarios NO se convierte a participantes/accesos.
--   ✓ evidencias V1 NO se fingen como objetos de evidencias-v2.
--   ✓ las filas CONSERVAR_STAGING permanecen en staging.
--
-- IMPORTANTE:
--   configuracion_accion_id puede resolverse por fallback histórico cuando
--   el periodo de la fuente no pudo demostrarse. Eso se registra en metadata.
--
-- ROLLBACK:
--   Todo ocurre dentro de una sola transacción.
--   Si cualquier validación falla, no se inserta ninguna fila.
-- ============================================================================

BEGIN;

SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '300s';


-- ============================================================================
-- 00. PRECONDICIONES
-- ============================================================================

DO $$
DECLARE
  v_job_id          UUID;
  v_job_status      TEXT;
  v_stage_total     INTEGER;
  v_migrables       INTEGER;
  v_existing        INTEGER;
  v_unresolved      INTEGER;
BEGIN
  IF to_regclass('v2.registros') IS NULL
     OR to_regclass('v2.import_jobs') IS NULL
     OR to_regclass('v2.import_staging') IS NULL THEN
    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: faltan objetos V2 requeridos.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM v2.schema_migrations
    WHERE version = '2.1.10b'
  ) THEN
    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: ejecute primero 10b_legacy_migration_staging.sql.';
  END IF;

  SELECT id, estatus
  INTO v_job_id, v_job_status
  FROM v2.import_jobs
  WHERE tipo_importacion = 'MIGRACION_V1'
    AND metadata ->> 'migration_key'
        = 'LEGACY_V1_TO_V2_STAGE_2026'
  LIMIT 1;

  IF v_job_id IS NULL THEN
    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: no se encontró el import_job histórico.';
  END IF;

  IF v_job_status <> 'LISTO' THEN
    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: import_job está en %, se esperaba LISTO.',
      v_job_status;
  END IF;

  SELECT count(*)
  INTO v_stage_total
  FROM v2.import_staging
  WHERE import_job_id = v_job_id;

  IF v_stage_total = 0 THEN
    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: staging histórico vacío.';
  END IF;

  IF v_stage_total <> (
    SELECT count(*) FROM public.registros_culturales
  ) THEN
    RAISE EXCEPTION
      'SEGURIDAD: staging (%) y V1 actual (%) no coinciden.',
      v_stage_total,
      (SELECT count(*) FROM public.registros_culturales);
  END IF;

  SELECT count(*)
  INTO v_migrables
  FROM v2.import_staging
  WHERE import_job_id = v_job_id
    AND normalized_data ->> 'migration_mode'
        = 'MIGRAR_BORRADOR'
    AND estatus = 'VALIDO';

  IF v_migrables = 0 THEN
    RAISE EXCEPTION
      'SEGURIDAD: no existen filas MIGRAR_BORRADOR válidas.';
  END IF;

  SELECT count(*)
  INTO v_existing
  FROM v2.registros
  WHERE origen = 'MIGRACION_V1'
     OR import_job_id = v_job_id;

  IF v_existing > 0 THEN
    RAISE EXCEPTION
      'SEGURIDAD: ya existen % registros productivos de esta migración.',
      v_existing;
  END IF;

  -- Cada fila migrable necesita acción; tipo/configuración puede resolverse
  -- mediante el fallback controlado del paso 01.
  SELECT count(*)
  INTO v_unresolved
  FROM v2.import_staging s
  WHERE s.import_job_id = v_job_id
    AND s.estatus = 'VALIDO'
    AND s.normalized_data ->> 'migration_mode'
        = 'MIGRAR_BORRADOR'
    AND (
      s.normalized_data ->> 'accion_v2_id' IS NULL
      OR s.normalized_data ->> 'municipio_v2_id' IS NULL
      OR s.normalized_data ->> 'periodo_destino' IS NULL
    );

  IF v_unresolved > 0 THEN
    RAISE EXCEPTION
      'SEGURIDAD: % filas MIGRAR_BORRADOR carecen de acción/municipio/periodo.',
      v_unresolved;
  END IF;
END
$$;


-- ============================================================================
-- 01. INSERTAR NÚCLEO PRODUCTIVO
--
-- Resolución de configuración:
--
--   A. configuracion_v2_id exacta del staging, si existe.
--   B. en caso contrario, última configuración conocida de la acción.
--
-- El fallback NO cambia el periodo del registro.
-- Solo aporta tipo_registro y esquema/formulario para poder preservar la fila
-- como BORRADOR. La decisión queda explícita en metadata.
-- ============================================================================

WITH job AS (
  SELECT id
  FROM v2.import_jobs
  WHERE tipo_importacion = 'MIGRACION_V1'
    AND metadata ->> 'migration_key'
        = 'LEGACY_V1_TO_V2_STAGE_2026'
  LIMIT 1
),

stage AS (
  SELECT
    s.id AS staging_id,
    s.import_job_id,
    s.numero_fila,
    s.raw_data,
    s.normalized_data,

    (s.normalized_data ->> 'accion_v2_id')::UUID
      AS accion_id,

    (s.normalized_data ->> 'municipio_v2_id')::UUID
      AS municipio_id,

    NULLIF(
      s.normalized_data ->> 'configuracion_v2_id',
      ''
    )::UUID AS config_exacta_id,

    (s.normalized_data ->> 'periodo_destino')::INTEGER
      AS periodo_destino,

    COALESCE(
      (
        s.normalized_data
          ->> 'total_beneficiarios_destino'
      )::INTEGER,
      NULL
    ) AS total_beneficiarios_destino

  FROM v2.import_staging s
  JOIN job j
    ON j.id = s.import_job_id

  WHERE s.estatus = 'VALIDO'
    AND s.normalized_data ->> 'migration_mode'
        = 'MIGRAR_BORRADOR'
),

resolved AS (
  SELECT
    st.*,

    a.unidad_operativa_id,
    a.programa_id,

    COALESCE(
      st.config_exacta_id,
      cf.id
    ) AS configuracion_id,

    COALESCE(
      ce.tipo_registro_id,
      cf.tipo_registro_id
    ) AS tipo_registro_id,

    COALESCE(
      ce.esquema_demografico_id,
      cf.esquema_demografico_id
    ) AS esquema_demografico_id,

    COALESCE(
      ce.tipo_formulario,
      cf.tipo_formulario
    ) AS tipo_formulario,

    (
      st.config_exacta_id IS NULL
      AND cf.id IS NOT NULL
    ) AS config_por_fallback

  FROM stage st

  JOIN v2.cat_acciones a
    ON a.id = st.accion_id

  LEFT JOIN v2.configuracion_acciones ce
    ON ce.id = st.config_exacta_id

  LEFT JOIN LATERAL (
    SELECT
      x.id,
      x.tipo_registro_id,
      x.esquema_demografico_id,
      x.tipo_formulario
    FROM v2.configuracion_acciones x
    WHERE x.accion_id = st.accion_id
      AND x.activo = true
    ORDER BY
      CASE
        WHEN make_date(st.periodo_destino, 1, 1)
             BETWEEN x.vigente_desde
                 AND COALESCE(
                       x.vigente_hasta,
                       DATE '9999-12-31'
                     )
          THEN 0
        WHEN x.vigente_desde
             <= make_date(st.periodo_destino, 1, 1)
          THEN 1
        ELSE 2
      END,
      x.vigente_desde DESC
    LIMIT 1
  ) cf ON true
),

validated AS (
  SELECT *
  FROM resolved
  WHERE configuracion_id IS NOT NULL
    AND tipo_registro_id IS NOT NULL
    AND unidad_operativa_id IS NOT NULL
)

INSERT INTO v2.registros (
  -- folio se deja NULL para generar folio institucional V2.
  folio,

  unidad_operativa_id,
  programa_id,
  accion_id,
  tipo_registro_id,
  configuracion_accion_id,

  municipio_id,
  comunidad_id,
  espacio_id,
  responsable_id,

  nombre,
  descripcion,

  fecha_inicio,
  fecha_fin,

  periodo_anio,
  periodo_mes,

  total_beneficiarios,
  total_participantes,
  total_accesos,

  esquema_demografico_id,

  estatus,
  origen,

  import_job_id,
  archivo_origen,
  fila_origen,

  legacy_folio,
  legacy_payload,

  metadata,

  created_by,
  updated_by,
  created_at
)
SELECT
  NULL,

  v.unidad_operativa_id,
  v.programa_id,
  v.accion_id,
  v.tipo_registro_id,
  v.configuracion_id,

  v.municipio_id,
  NULL,
  NULL,
  NULL,

  COALESCE(
    NULLIF(btrim(v.raw_data ->> 'disciplina'), ''),
    NULLIF(btrim(v.raw_data ->> 'tipo_actividad'), ''),
    NULLIF(btrim(v.raw_data ->> 'folio'), ''),
    'Registro histórico V1 #' || v.numero_fila::TEXT
  ),

  CASE
    WHEN v.config_por_fallback THEN
      'Migrado desde V1 como BORRADOR. La configuración de formulario fue resuelta mediante fallback histórico y requiere revisión.'
    ELSE
      'Migrado desde V1 como BORRADOR. Requiere revisión antes de validarse.'
  END,

  CASE
    WHEN NULLIF(v.raw_data ->> 'fecha_actividad', '') IS NULL
      THEN NULL

    -- Si existe un periodo de fuente explícito, no conservamos como fecha
    -- operativa una fecha cuyo año contradiga ese periodo.
    WHEN (
      v.normalized_data ->> 'periodo_candidato'
    ) IS NOT NULL
    AND EXTRACT(
          YEAR FROM
          (v.raw_data ->> 'fecha_actividad')::DATE
        )::INTEGER
        <> (
          v.normalized_data
            ->> 'periodo_candidato'
        )::INTEGER
      THEN NULL

    ELSE (v.raw_data ->> 'fecha_actividad')::DATE
  END AS fecha_inicio,

  NULL AS fecha_fin,

  v.periodo_destino,

  CASE
    WHEN NULLIF(v.raw_data ->> 'fecha_actividad', '') IS NULL
      THEN NULL

    WHEN (
      v.normalized_data ->> 'periodo_candidato'
    ) IS NOT NULL
    AND EXTRACT(
          YEAR FROM
          (v.raw_data ->> 'fecha_actividad')::DATE
        )::INTEGER
        <> (
          v.normalized_data
            ->> 'periodo_candidato'
        )::INTEGER
      THEN NULL

    ELSE EXTRACT(
      MONTH FROM
      (v.raw_data ->> 'fecha_actividad')::DATE
    )::SMALLINT
  END AS periodo_mes,

  v.total_beneficiarios_destino,

  -- Nunca inferir Participación o Acceso desde el total histórico.
  NULL,
  NULL,

  v.esquema_demografico_id,

  'BORRADOR',
  'MIGRACION_V1',

  v.import_job_id,
  'public.registros_culturales',
  v.numero_fila,

  NULLIF(
    btrim(v.raw_data ->> 'folio'),
    ''
  ),

  v.raw_data,

  pg_catalog.jsonb_build_object(
    'migration',
    pg_catalog.jsonb_build_object(
      'version', '2.1.10',
      'staging_id', v.staging_id,
      'source_hash',
        v.normalized_data ->> 'source_hash',
      'source_occurrence',
        v.normalized_data ->> 'source_occurrence',
      'migration_mode',
        v.normalized_data ->> 'migration_mode',
      'target_status', 'BORRADOR',
      'accion_confianza',
        v.normalized_data ->> 'confianza_accion',
      'periodo_confianza',
        v.normalized_data ->> 'confianza_periodo',
      'periodo_fuente',
        v.normalized_data ->> 'periodo_candidato',
      'periodo_destino', v.periodo_destino,
      'fuente_periodo_destino',
        v.normalized_data ->> 'fuente_periodo_destino',
      'configuracion_por_fallback',
        v.config_por_fallback,
      'total_uno_artificial',
        COALESCE(
          (
            v.normalized_data
              ->> 'total_uno_artificial'
          )::BOOLEAN,
          false
        ),
      'demografia_posiblemente_sintetica',
        COALESCE(
          (
            v.normalized_data
              ->> 'demografia_posiblemente_sintetica'
          )::BOOLEAN,
          false
        ),
      'migrar_demografia',
        COALESCE(
          (
            v.normalized_data
              ->> 'migrar_demografia'
          )::BOOLEAN,
          false
        ),
      'evidencia_tipo',
        v.normalized_data ->> 'evidencia_tipo',
      'estrategia_evidencia',
        v.normalized_data ->> 'estrategia_evidencia',
      'advertencias',
        COALESCE(
          v.normalized_data -> 'advertencias',
          '[]'::jsonb
        )
    ),

    'legacy',
    pg_catalog.jsonb_build_object(
      'municipio_original',
        v.raw_data ->> 'municipio',
      'municipio_normalizado',
        v.normalized_data ->> 'municipio_normalizado',
      'usuario_original',
        v.raw_data ->> 'usuario',
      'foto_url_original',
        v.raw_data ->> 'foto_url'
    )
  ),

  (
    SELECT u.id
    FROM auth.users u
    WHERE lower(u.email)
          = lower(
              btrim(
                COALESCE(v.raw_data ->> 'usuario', '')
              )
            )
    LIMIT 1
  ),

  (
    SELECT u.id
    FROM auth.users u
    WHERE lower(u.email)
          = lower(
              btrim(
                COALESCE(v.raw_data ->> 'usuario', '')
              )
            )
    LIMIT 1
  ),

  COALESCE(
    NULLIF(
      v.raw_data ->> 'created_at',
      ''
    )::TIMESTAMPTZ,
    pg_catalog.now()
  )

FROM validated v
ORDER BY v.numero_fila;


-- ============================================================================
-- 02. GATE: NÚMERO DE INSERTADOS DEBE COINCIDIR CON MIGRAR_BORRADOR
-- ============================================================================

DO $$
DECLARE
  v_job_id       UUID;
  v_expected     INTEGER;
  v_inserted     INTEGER;
BEGIN
  SELECT id
  INTO v_job_id
  FROM v2.import_jobs
  WHERE tipo_importacion = 'MIGRACION_V1'
    AND metadata ->> 'migration_key'
        = 'LEGACY_V1_TO_V2_STAGE_2026'
  LIMIT 1;

  SELECT count(*)
  INTO v_expected
  FROM v2.import_staging
  WHERE import_job_id = v_job_id
    AND estatus = 'VALIDO'
    AND normalized_data ->> 'migration_mode'
        = 'MIGRAR_BORRADOR';

  SELECT count(*)
  INTO v_inserted
  FROM v2.registros
  WHERE import_job_id = v_job_id
    AND origen = 'MIGRACION_V1';

  IF v_inserted <> v_expected THEN
    RAISE EXCEPTION
      'MIGRACIÓN ABORTADA: esperado %, insertado %.',
      v_expected,
      v_inserted;
  END IF;
END
$$;


-- ============================================================================
-- 03. MIGRAR DETALLE DE TALLER / FORMACIÓN
--
-- Se conservan disciplina, programación y costo únicamente cuando el costo
-- puede interpretarse inequívocamente como monto numérico.
--
-- Horario/días/sesión quedan en observaciones, porque V1 los almacenaba como
-- texto libre y no vamos a inventar una normalización horaria.
-- ============================================================================

WITH job AS (
  SELECT id
  FROM v2.import_jobs
  WHERE tipo_importacion = 'MIGRACION_V1'
    AND metadata ->> 'migration_key'
        = 'LEGACY_V1_TO_V2_STAGE_2026'
  LIMIT 1
),

base AS (
  SELECT
    r.id AS registro_id,
    r.configuracion_accion_id,
    s.raw_data,

    NULLIF(
      btrim(s.raw_data ->> 'costo'),
      ''
    ) AS costo_original

  FROM v2.registros r

  JOIN v2.import_staging s
    ON s.import_job_id = r.import_job_id
   AND s.numero_fila = r.fila_origen

  JOIN job j
    ON j.id = r.import_job_id

  WHERE r.origen = 'MIGRACION_V1'
),

formacion AS (
  SELECT
    b.*,
    ca.tipo_formulario
  FROM base b
  JOIN v2.configuracion_acciones ca
    ON ca.id = b.configuracion_accion_id
  WHERE ca.tipo_formulario IN (
    'TALLER',
    'CAPACITACION'
  )
)

INSERT INTO v2.registro_taller (
  registro_id,
  disciplina,
  programacion,
  modalidad_cuota,
  costo,
  moneda,
  observaciones
)
SELECT
  f.registro_id,

  NULLIF(
    btrim(f.raw_data ->> 'disciplina'),
    ''
  ),

  NULLIF(
    btrim(f.raw_data ->> 'programacion'),
    ''
  ),

  CASE
    WHEN f.costo_original IS NULL
      THEN NULL

    WHEN lower(f.costo_original) ~
         '(gratis|gratuito|sin costo)'
      THEN 'GRATUITO'

    WHEN f.costo_original ~
         '^\s*\$?\s*[0-9]+([.,][0-9]{1,2})?\s*$'
      THEN 'CUOTA'

    ELSE 'NO_DETERMINADO'
  END,

  CASE
    WHEN f.costo_original ~
         '^\s*\$?\s*[0-9]+([.,][0-9]{1,2})?\s*$'
      THEN
        replace(
          regexp_replace(
            f.costo_original,
            '[^0-9.,]',
            '',
            'g'
          ),
          ',',
          '.'
        )::NUMERIC(14,2)

    ELSE NULL
  END,

  'MXN',

  concat_ws(
    ' | ',
    CASE
      WHEN NULLIF(
        btrim(f.raw_data ->> 'horario'),
        ''
      ) IS NOT NULL
        THEN 'Horario V1: '
             || btrim(f.raw_data ->> 'horario')
    END,

    CASE
      WHEN NULLIF(
        btrim(f.raw_data ->> 'dias'),
        ''
      ) IS NOT NULL
        THEN 'Días V1: '
             || btrim(f.raw_data ->> 'dias')
    END,

    CASE
      WHEN NULLIF(
        btrim(f.raw_data ->> 'sesion'),
        ''
      ) IS NOT NULL
        THEN 'Sesión V1: '
             || btrim(f.raw_data ->> 'sesion')
    END,

    CASE
      WHEN f.costo_original IS NOT NULL
           AND f.costo_original !~
               '^\s*\$?\s*[0-9]+([.,][0-9]{1,2})?\s*$'
           AND lower(f.costo_original) !~
               '(gratis|gratuito|sin costo)'
        THEN 'Costo V1 no normalizado: '
             || f.costo_original
    END
  )

FROM formacion f

ON CONFLICT (registro_id)
DO NOTHING;


-- ============================================================================
-- 04. MIGRAR DEMOGRAFÍA SOLO CUANDO NO ESTÁ MARCADA COMO SINTÉTICA
--
-- Se insertan únicamente cantidades > 0.
-- Los ceros y la fila completa permanecen disponibles en legacy_payload.
-- Universo:
--
--   BENEFICIARIOS
--
-- Nunca se reinterpretan como PARTICIPANTES o ACCESOS.
-- ============================================================================

WITH job AS (
  SELECT id
  FROM v2.import_jobs
  WHERE tipo_importacion = 'MIGRACION_V1'
    AND metadata ->> 'migration_key'
        = 'LEGACY_V1_TO_V2_STAGE_2026'
  LIMIT 1
),

base AS (
  SELECT
    r.id AS registro_id,
    s.raw_data,
    s.normalized_data

  FROM v2.registros r

  JOIN v2.import_staging s
    ON s.import_job_id = r.import_job_id
   AND s.numero_fila = r.fila_origen

  JOIN job j
    ON j.id = r.import_job_id

  WHERE r.origen = 'MIGRACION_V1'
    AND COALESCE(
          (
            s.normalized_data
              ->> 'migrar_demografia'
          )::BOOLEAN,
          false
        ) = true
),

valores AS (
  SELECT
    b.registro_id,
    x.dimension_clave,
    x.opcion_clave,
    x.cantidad

  FROM base b

  CROSS JOIN LATERAL (
    VALUES
      (
        'GENERO',
        'MUJERES',
        COALESCE(
          (b.raw_data ->> 'mujeres')::INTEGER,
          0
        )
      ),
      (
        'GENERO',
        'HOMBRES',
        COALESCE(
          (b.raw_data ->> 'hombres')::INTEGER,
          0
        )
      ),

      (
        'GRUPO_ETARIO',
        'NINEZ',
        COALESCE(
          (b.raw_data ->> 'ninez')::INTEGER,
          0
        )
      ),
      (
        'GRUPO_ETARIO',
        'ADOLESCENCIA',
        COALESCE(
          (b.raw_data ->> 'adolescencia')::INTEGER,
          0
        )
      ),
      (
        'GRUPO_ETARIO',
        'JUVENTUDES',
        COALESCE(
          (b.raw_data ->> 'juventudes')::INTEGER,
          0
        )
      ),
      (
        'GRUPO_ETARIO',
        'ADULTOS_MAYORES',
        COALESCE(
          (b.raw_data ->> 'adultos_mayores')::INTEGER,
          0
        )
      ),

      (
        'GRUPO_PRIORITARIO',
        'DISCAPACIDAD',
        COALESCE(
          (b.raw_data ->> 'discapacidad')::INTEGER,
          0
        )
      ),
      (
        'GRUPO_PRIORITARIO',
        'INDIGENAS',
        COALESCE(
          (b.raw_data ->> 'indigenas')::INTEGER,
          0
        )
      ),
      (
        'GRUPO_PRIORITARIO',
        'AFROMEXICANAS',
        COALESCE(
          (b.raw_data ->> 'afromexicanas')::INTEGER,
          0
        )
      ),
      (
        'GRUPO_PRIORITARIO',
        'LGBTQ',
        COALESCE(
          (b.raw_data ->> 'lgbtq')::INTEGER,
          0
        )
      )
  ) AS x(
    dimension_clave,
    opcion_clave,
    cantidad
  )

  WHERE x.cantidad > 0
)

INSERT INTO v2.registro_poblacion (
  registro_id,
  opcion_poblacion_id,
  universo,
  cantidad,
  observaciones
)
SELECT
  v.registro_id,
  o.id,
  'BENEFICIARIOS',
  v.cantidad,
  'Migrado desde V1; valor histórico no reinterpretado como Participación/Acceso.'

FROM valores v

JOIN v2.cat_dimensiones_poblacion d
  ON upper(btrim(d.clave))
     = v.dimension_clave

JOIN v2.cat_opciones_poblacion o
  ON o.dimension_id = d.id
 AND upper(btrim(o.clave))
     = v.opcion_clave

ON CONFLICT (
  registro_id,
  opcion_poblacion_id,
  universo
)
DO NOTHING;


-- ============================================================================
-- 05. NO MIGRAR EVIDENCIAS FÍSICAS TODAVÍA
--
-- foto_url ya está:
--   - en legacy_payload
--   - en metadata.legacy.foto_url_original
--
-- No se inserta registro_evidencias porque los objetos siguen en V1 y el
-- bucket V2 "evidencias-v2" debe permanecer veraz/privado.
-- ============================================================================


-- ============================================================================
-- 06. MARCAR STAGING IMPORTADO Y ENLAZAR TARGET
-- ============================================================================

WITH job AS (
  SELECT id
  FROM v2.import_jobs
  WHERE tipo_importacion = 'MIGRACION_V1'
    AND metadata ->> 'migration_key'
        = 'LEGACY_V1_TO_V2_STAGE_2026'
  LIMIT 1
),

mapa AS (
  SELECT
    r.id AS registro_id,
    r.import_job_id,
    r.fila_origen
  FROM v2.registros r
  JOIN job j
    ON j.id = r.import_job_id
  WHERE r.origen = 'MIGRACION_V1'
)

UPDATE v2.import_staging s
SET
  estatus = 'IMPORTADO',

  normalized_data =
    s.normalized_data
    || pg_catalog.jsonb_build_object(
      'target_registro_id',
      m.registro_id,
      'migrated_at',
      pg_catalog.now(),
      'migration_version',
      '2.1.10'
    )

FROM mapa m
WHERE s.import_job_id = m.import_job_id
  AND s.numero_fila = m.fila_origen
  AND s.estatus = 'VALIDO';


-- ============================================================================
-- 07. CERRAR IMPORT_JOB
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
    count(*) FILTER (
      WHERE s.estatus = 'IMPORTADO'
    )::INTEGER AS importadas,

    count(*) FILTER (
      WHERE s.estatus = 'ERROR'
    )::INTEGER AS pendientes,

    count(*)::INTEGER AS total

  FROM v2.import_staging s
  JOIN job j
    ON j.id = s.import_job_id
)

UPDATE v2.import_jobs j
SET
  estatus =
    CASE
      WHEN st.pendientes > 0
        THEN 'COMPLETADO_CON_ERRORES'
      ELSE 'COMPLETADO'
    END,

  filas_importadas = st.importadas,
  filas_validas = st.importadas,
  filas_error = st.pendientes,

  completed_at = pg_catalog.now(),

  metadata =
    j.metadata
    || pg_catalog.jsonb_build_object(
      'productivo_migrado',
      st.importadas,
      'staging_pendiente_revision',
      st.pendientes,
      'target_status',
      'BORRADOR',
      'evidencias_fisicas_migradas',
      0,
      'completed_by_sql',
      '10_legacy_migration.sql',
      'completed_at',
      pg_catalog.now()
    )

FROM stats st
WHERE j.id = (
  SELECT id FROM job
);


-- ============================================================================
-- 08. REGISTRAR MIGRACIÓN
-- ============================================================================

INSERT INTO v2.schema_migrations (
  version,
  descripcion
)
VALUES (
  '2.1.10',
  '10_legacy_migration.sql - Migración productiva controlada de staging aprobado a v2.registros como BORRADOR.'
)
ON CONFLICT (version) DO NOTHING;


COMMIT;


-- ============================================================================
-- 09. VERIFICACIÓN POST-MIGRACIÓN
-- ============================================================================

WITH job AS (
  SELECT *
  FROM v2.import_jobs
  WHERE tipo_importacion = 'MIGRACION_V1'
    AND metadata ->> 'migration_key'
        = 'LEGACY_V1_TO_V2_STAGE_2026'
  LIMIT 1
),

stage AS (
  SELECT s.*
  FROM v2.import_staging s
  JOIN job j
    ON j.id = s.import_job_id
),

migrados AS (
  SELECT r.*
  FROM v2.registros r
  JOIN job j
    ON j.id = r.import_job_id
  WHERE r.origen = 'MIGRACION_V1'
)

SELECT
  'V2.1 - 10 legacy migration' AS instalacion,

  (SELECT count(*) FROM public.registros_culturales)
    AS v1_preservados,

  (SELECT count(*) FROM stage)
    AS staging_total,

  (SELECT count(*) FROM stage WHERE estatus = 'IMPORTADO')
    AS staging_importados,

  (SELECT count(*) FROM stage WHERE estatus = 'ERROR')
    AS staging_pendientes,

  (SELECT count(*) FROM migrados)
    AS registros_v2_migrados,

  (
    SELECT count(*)
    FROM migrados
    WHERE estatus = 'BORRADOR'
  ) AS migrados_borrador,

  (
    SELECT count(*)
    FROM migrados
    WHERE folio IS NOT NULL
      AND btrim(folio) <> ''
  ) AS migrados_con_folio_v2,

  (
    SELECT count(*)
    FROM migrados
    WHERE legacy_folio IS NOT NULL
      AND btrim(legacy_folio) <> ''
  ) AS migrados_con_legacy_folio,

  (
    SELECT count(*)
    FROM migrados
    WHERE metadata #>> '{migration,configuracion_por_fallback}'
          = 'true'
  ) AS configs_por_fallback,

  (
    SELECT count(*)
    FROM migrados
    WHERE metadata #>> '{migration,total_uno_artificial}'
          = 'true'
      AND total_beneficiarios IS NOT NULL
  ) AS artificiales_1_copiados_incorrectamente,

  (
    SELECT count(*)
    FROM migrados
    WHERE total_participantes IS NOT NULL
       OR total_accesos IS NOT NULL
  ) AS participacion_acceso_inferidos_incorrectamente,

  (
    SELECT count(DISTINCT registro_id)
    FROM v2.registro_poblacion rp
    JOIN migrados m
      ON m.id = rp.registro_id
  ) AS migrados_con_demografia_normalizada,

  (
    SELECT count(*)
    FROM v2.registro_taller rt
    JOIN migrados m
      ON m.id = rt.registro_id
  ) AS detalles_taller_migrados,

  (
    SELECT count(*)
    FROM v2.registro_evidencias re
    JOIN migrados m
      ON m.id = re.registro_id
  ) AS evidencias_v2_migradas,

  (SELECT estatus FROM job)
    AS job_estatus,

  (SELECT filas_importadas FROM job)
    AS job_filas_importadas,

  (
    SELECT count(*)
    FROM v2.schema_migrations
    WHERE version = '2.1.10'
  ) AS migracion_registrada;


-- ============================================================================
-- RESULTADO ESPERADO CON EL STAGING ACTUAL:
--
-- v1_preservados                           = 317
-- staging_total                            = 317
-- staging_importados                       = 238
-- staging_pendientes                        = 79
-- registros_v2_migrados                    = 238
-- migrados_borrador                        = 238
-- migrados_con_folio_v2                    = 238
-- migrados_con_legacy_folio                <= 238
-- configs_por_fallback                     > 0  (esperable)
--
-- CRÍTICOS DEBEN SER:
--
-- artificiales_1_copiados_incorrectamente = 0
-- participacion_acceso_inferidos_incorrectamente = 0
-- evidencias_v2_migradas                   = 0
--
-- job_estatus                              = COMPLETADO_CON_ERRORES
-- job_filas_importadas                     = 238
-- migracion_registrada                     = 1
--
-- "COMPLETADO_CON_ERRORES" es correcto:
-- las 79 filas no se perdieron; permanecen en staging para revisión.
--
-- SIGUIENTE:
--
--   11_tests.sql
--
-- Ese archivo validará:
--   - reconciliación 317 = 238 + 79
--   - unicidad de folios V2
--   - trazabilidad staging -> registro
--   - RLS y grants
--   - auditoría
--   - demografía
--   - indicadores
--   - Storage
--   - integridad de relaciones
-- ============================================================================
