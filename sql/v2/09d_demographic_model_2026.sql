-- ============================================================================
-- VINCULACIÓN CULTURAL 2.0
-- 09d_demographic_model_2026.sql
-- Modelo demográfico versionado + Participación / Acceso
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
--   09c_source_alignment_2026.sql (diagnóstico)
--
-- OBJETIVO:
--   Permitir que V2 represente simultáneamente:
--
--   A) Modelo histórico V1 / CDCM 2025
--   B) Modelo oficial 2026
--
-- SIN reinterpretar silenciosamente los datos históricos.
--
-- AGREGA:
--   ✓ v2.cat_esquemas_demograficos
--   ✓ v2.esquema_dimensiones_poblacion
--   ✓ v2.esquema_opciones_poblacion
--
--   ✓ registros.total_participantes
--   ✓ registros.total_accesos
--   ✓ registros.esquema_demografico_id
--
--   ✓ configuracion_acciones.esquema_demografico_id
--
--   ✓ registro_poblacion.universo:
--       BENEFICIARIOS
--       PARTICIPANTES
--       ACCESOS
--
--   ✓ opciones oficiales 2026 faltantes
--   ✓ esquema HISTORICO_V1_2025
--   ✓ esquema OFICIAL_2026
--
-- IMPORTANTE:
--   Este archivo NO carga indicadores 2026 ni metas 2026.
--   Solo deja el modelo listo para hacerlo correctamente.
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
     OR to_regclass('v2.registro_poblacion') IS NULL
     OR to_regclass('v2.cat_dimensiones_poblacion') IS NULL
     OR to_regclass('v2.cat_opciones_poblacion') IS NULL
     OR to_regclass('v2.configuracion_acciones') IS NULL THEN

    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: faltan objetos V2 requeridos.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM v2.schema_migrations
    WHERE version = '2.1.09b'
  ) THEN
    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: ejecute primero 09b_operational_seed.sql.';
  END IF;
END
$$;


-- ============================================================================
-- 01. CATÁLOGO DE ESQUEMAS DEMOGRÁFICOS
--
-- Un esquema define qué dimensiones/opciones aplican en un periodo concreto.
-- De esta manera los datos históricos no cambian de significado cuando
-- evoluciona el catálogo institucional.
-- ============================================================================

CREATE TABLE IF NOT EXISTS v2.cat_esquemas_demograficos (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  unidad_operativa_id   UUID
                        REFERENCES v2.cat_unidades_operativas(id)
                        ON DELETE RESTRICT,

  clave                 TEXT NOT NULL,
  nombre                TEXT NOT NULL,
  descripcion           TEXT,

  vigente_desde         DATE NOT NULL,
  vigente_hasta         DATE,

  fuente                TEXT,
  metadata              JSONB NOT NULL DEFAULT '{}'::jsonb,

  activo                BOOLEAN NOT NULL DEFAULT true,

  created_by            UUID REFERENCES auth.users(id) ON DELETE SET NULL
                        DEFAULT auth.uid(),

  updated_by            UUID REFERENCES auth.users(id) ON DELETE SET NULL
                        DEFAULT auth.uid(),

  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT ck_v2_esquema_demografico_clave
    CHECK (btrim(clave) <> ''),

  CONSTRAINT ck_v2_esquema_demografico_nombre
    CHECK (btrim(nombre) <> ''),

  CONSTRAINT ck_v2_esquema_demografico_vigencia
    CHECK (
      vigente_hasta IS NULL
      OR vigente_hasta >= vigente_desde
    )
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_v2_esquema_demografico_unidad_clave
  ON v2.cat_esquemas_demograficos (
    COALESCE(
      unidad_operativa_id,
      '00000000-0000-0000-0000-000000000000'::uuid
    ),
    lower(btrim(clave))
  );

CREATE INDEX IF NOT EXISTS idx_v2_esquema_demografico_vigencia
  ON v2.cat_esquemas_demograficos (
    unidad_operativa_id,
    vigente_desde,
    vigente_hasta,
    activo
  );


COMMENT ON TABLE v2.cat_esquemas_demograficos IS
'Versiona la estructura demográfica aplicable por periodo/unidad sin alterar el significado de registros históricos.';


-- ============================================================================
-- 02. DIMENSIONES HABILITADAS POR ESQUEMA
-- ============================================================================

CREATE TABLE IF NOT EXISTS v2.esquema_dimensiones_poblacion (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  esquema_id            UUID NOT NULL
                        REFERENCES v2.cat_esquemas_demograficos(id)
                        ON DELETE CASCADE,

  dimension_id          UUID NOT NULL
                        REFERENCES v2.cat_dimensiones_poblacion(id)
                        ON DELETE RESTRICT,

  requerida             BOOLEAN NOT NULL DEFAULT false,
  orden                 INTEGER NOT NULL DEFAULT 0
                        CHECK (orden >= 0),

  activo                BOOLEAN NOT NULL DEFAULT true,

  created_by            UUID REFERENCES auth.users(id) ON DELETE SET NULL
                        DEFAULT auth.uid(),

  updated_by            UUID REFERENCES auth.users(id) ON DELETE SET NULL
                        DEFAULT auth.uid(),

  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT uq_v2_esquema_dimension
    UNIQUE (esquema_id, dimension_id)
);


-- ============================================================================
-- 03. OPCIONES HABILITADAS POR ESQUEMA
--
-- etiqueta_override permite conservar una opción técnica compartida y mostrar
-- la definición oficial correspondiente al periodo.
--
-- Ejemplo:
--   opción técnica JUVENTUDES
--   etiqueta 2026 "Jóvenes (18–29 años)"
-- ============================================================================

CREATE TABLE IF NOT EXISTS v2.esquema_opciones_poblacion (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  esquema_id            UUID NOT NULL
                        REFERENCES v2.cat_esquemas_demograficos(id)
                        ON DELETE CASCADE,

  opcion_poblacion_id   UUID NOT NULL
                        REFERENCES v2.cat_opciones_poblacion(id)
                        ON DELETE RESTRICT,

  etiqueta_override     TEXT,

  orden                 INTEGER NOT NULL DEFAULT 0
                        CHECK (orden >= 0),

  activo                BOOLEAN NOT NULL DEFAULT true,

  created_by            UUID REFERENCES auth.users(id) ON DELETE SET NULL
                        DEFAULT auth.uid(),

  updated_by            UUID REFERENCES auth.users(id) ON DELETE SET NULL
                        DEFAULT auth.uid(),

  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT uq_v2_esquema_opcion
    UNIQUE (esquema_id, opcion_poblacion_id)
);


CREATE INDEX IF NOT EXISTS idx_v2_esquema_opciones
  ON v2.esquema_opciones_poblacion (
    esquema_id,
    orden,
    activo
  );


-- ============================================================================
-- 04. AMPLIAR REGISTROS: PARTICIPACIÓN / ACCESO / ESQUEMA
--
-- total_beneficiarios SE CONSERVA.
--
-- NULL = no informado / no aplica.
-- 0    = se informó explícitamente cero.
-- ============================================================================

ALTER TABLE v2.registros
  ADD COLUMN IF NOT EXISTS total_participantes INTEGER;

ALTER TABLE v2.registros
  ADD COLUMN IF NOT EXISTS total_accesos INTEGER;

ALTER TABLE v2.registros
  ADD COLUMN IF NOT EXISTS esquema_demografico_id UUID;


ALTER TABLE v2.registros
  DROP CONSTRAINT IF EXISTS ck_v2_registros_total_participantes;

ALTER TABLE v2.registros
  ADD CONSTRAINT ck_v2_registros_total_participantes
  CHECK (
    total_participantes IS NULL
    OR total_participantes >= 0
  );


ALTER TABLE v2.registros
  DROP CONSTRAINT IF EXISTS ck_v2_registros_total_accesos;

ALTER TABLE v2.registros
  ADD CONSTRAINT ck_v2_registros_total_accesos
  CHECK (
    total_accesos IS NULL
    OR total_accesos >= 0
  );


DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'fk_v2_registro_esquema_demografico'
      AND conrelid = 'v2.registros'::regclass
  ) THEN

    ALTER TABLE v2.registros
      ADD CONSTRAINT fk_v2_registro_esquema_demografico
      FOREIGN KEY (esquema_demografico_id)
      REFERENCES v2.cat_esquemas_demograficos(id)
      ON DELETE RESTRICT;

  END IF;
END
$$;


CREATE INDEX IF NOT EXISTS idx_v2_registros_esquema_demografico
  ON v2.registros (
    esquema_demografico_id,
    periodo_anio
  );


COMMENT ON COLUMN v2.registros.total_participantes IS
'Número de personas que participan en procesos culturales. Variable independiente de accesos.';

COMMENT ON COLUMN v2.registros.total_accesos IS
'Número de personas que acceden a procesos culturales. Variable independiente de participantes.';

COMMENT ON COLUMN v2.registros.esquema_demografico_id IS
'Snapshot del esquema demográfico aplicable al registro al momento de captura.';


-- ============================================================================
-- 05. ASIGNAR ESQUEMA A CONFIGURACIÓN DE ACCIONES
-- ============================================================================

ALTER TABLE v2.configuracion_acciones
  ADD COLUMN IF NOT EXISTS esquema_demografico_id UUID;


DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'fk_v2_config_accion_esquema_demografico'
      AND conrelid = 'v2.configuracion_acciones'::regclass
  ) THEN

    ALTER TABLE v2.configuracion_acciones
      ADD CONSTRAINT fk_v2_config_accion_esquema_demografico
      FOREIGN KEY (esquema_demografico_id)
      REFERENCES v2.cat_esquemas_demograficos(id)
      ON DELETE RESTRICT;

  END IF;
END
$$;


CREATE INDEX IF NOT EXISTS idx_v2_config_accion_esquema
  ON v2.configuracion_acciones (
    esquema_demografico_id,
    vigente_desde,
    activo
  );


-- ============================================================================
-- 06. UNIVERSO DE LA DESAGREGACIÓN DEMOGRÁFICA
--
-- Un mismo registro puede tener, por ejemplo:
--
--   PARTICIPANTES / Jóvenes = 25
--   ACCESOS       / Jóvenes = 60
--
-- sin colisionar en la PK.
-- ============================================================================

ALTER TABLE v2.registro_poblacion
  ADD COLUMN IF NOT EXISTS universo TEXT
  NOT NULL
  DEFAULT 'BENEFICIARIOS';


ALTER TABLE v2.registro_poblacion
  DROP CONSTRAINT IF EXISTS ck_v2_registro_poblacion_universo;

ALTER TABLE v2.registro_poblacion
  ADD CONSTRAINT ck_v2_registro_poblacion_universo
  CHECK (
    universo IN (
      'BENEFICIARIOS',
      'PARTICIPANTES',
      'ACCESOS'
    )
  );


-- Reemplazar PK histórica (registro_id, opcion_poblacion_id)
-- por PK versionada por universo.
DO $$
DECLARE
  v_pk TEXT;
BEGIN
  SELECT c.conname
  INTO v_pk
  FROM pg_constraint c
  WHERE c.conrelid = 'v2.registro_poblacion'::regclass
    AND c.contype = 'p'
  LIMIT 1;

  IF v_pk IS NOT NULL THEN
    EXECUTE pg_catalog.format(
      'ALTER TABLE v2.registro_poblacion DROP CONSTRAINT %I',
      v_pk
    );
  END IF;
END
$$;


ALTER TABLE v2.registro_poblacion
  ADD CONSTRAINT pk_v2_registro_poblacion
  PRIMARY KEY (
    registro_id,
    opcion_poblacion_id,
    universo
  );


CREATE INDEX IF NOT EXISTS idx_v2_registro_poblacion_universo
  ON v2.registro_poblacion (
    registro_id,
    universo
  );


COMMENT ON COLUMN v2.registro_poblacion.universo IS
'Indica a qué total corresponde la desagregación: BENEFICIARIOS, PARTICIPANTES o ACCESOS.';


-- ============================================================================
-- 07. OPCIONES 2026 FALTANTES — GRUPO ETARIO
-- ============================================================================

INSERT INTO v2.cat_opciones_poblacion (
  dimension_id,
  clave,
  nombre,
  orden,
  activo
)
SELECT
  d.id,
  x.clave,
  x.nombre,
  x.orden,
  true
FROM v2.cat_dimensiones_poblacion d
CROSS JOIN (
  VALUES
    (
      'PRIMERA_INFANCIA_0_5',
      'Primera infancia (0–5 años)',
      10
    ),
    (
      'NINAS_NINOS_6_12',
      'Niñas y niños (6–12 años)',
      20
    ),
    (
      'ADULTOS_30_59',
      'Adultos (30–59 años)',
      50
    ),
    (
      'INTERGENERACIONAL',
      'Intergeneracional',
      70
    ),
    (
      'NO_ESPECIFICADO',
      'No especificado',
      80
    )
) AS x(clave, nombre, orden)

WHERE upper(btrim(d.clave)) = 'GRUPO_ETARIO'

  AND NOT EXISTS (
    SELECT 1
    FROM v2.cat_opciones_poblacion o
    WHERE o.dimension_id = d.id
      AND upper(btrim(o.clave)) = x.clave
  );


-- ============================================================================
-- 08. OPCIONES 2026 FALTANTES — GÉNERO
-- ============================================================================

INSERT INTO v2.cat_opciones_poblacion (
  dimension_id,
  clave,
  nombre,
  orden,
  activo
)
SELECT
  d.id,
  x.clave,
  x.nombre,
  x.orden,
  true
FROM v2.cat_dimensiones_poblacion d
CROSS JOIN (
  VALUES
    ('NO_BINARIO', 'No binario', 30),
    ('PERSONA_TRANS', 'Persona trans', 40),
    (
      'PREFIERE_NO_ESPECIFICAR',
      'Prefiere no especificar',
      50
    ),
    ('PUBLICO_MIXTO', 'Público mixto', 60)
) AS x(clave, nombre, orden)

WHERE upper(btrim(d.clave)) = 'GENERO'

  AND NOT EXISTS (
    SELECT 1
    FROM v2.cat_opciones_poblacion o
    WHERE o.dimension_id = d.id
      AND upper(btrim(o.clave)) = x.clave
  );


-- ============================================================================
-- 09. OPCIONES 2026 FALTANTES — GRUPOS PRIORITARIOS
-- ============================================================================

INSERT INTO v2.cat_opciones_poblacion (
  dimension_id,
  clave,
  nombre,
  orden,
  activo
)
SELECT
  d.id,
  x.clave,
  x.nombre,
  x.orden,
  true
FROM v2.cat_dimensiones_poblacion d
CROSS JOIN (
  VALUES
    (
      'MUJERES_VULNERABILIDAD',
      'Mujeres en situación de vulnerabilidad',
      40
    ),
    (
      'JUVENTUDES_RIESGO',
      'Juventudes en riesgo',
      50
    ),
    (
      'NNA',
      'Niñas, niños y adolescentes',
      60
    ),
    (
      'ADULTOS_MAYORES',
      'Personas adultas mayores',
      70
    ),
    (
      'MIGRANTES',
      'Personas migrantes',
      80
    ),
    (
      'PRIVADAS_LIBERTAD',
      'Personas privadas de la libertad',
      90
    )
) AS x(clave, nombre, orden)

WHERE upper(btrim(d.clave)) = 'GRUPO_PRIORITARIO'

  AND NOT EXISTS (
    SELECT 1
    FROM v2.cat_opciones_poblacion o
    WHERE o.dimension_id = d.id
      AND upper(btrim(o.clave)) = x.clave
  );


-- ============================================================================
-- 10. CREAR ESQUEMAS DEMOGRÁFICOS
-- ============================================================================

WITH unidad AS (
  SELECT id
  FROM v2.cat_unidades_operativas
  WHERE upper(btrim(clave)) = 'CDCM'
  LIMIT 1
)
INSERT INTO v2.cat_esquemas_demograficos (
  unidad_operativa_id,
  clave,
  nombre,
  descripcion,
  vigente_desde,
  vigente_hasta,
  fuente,
  metadata,
  activo
)
SELECT
  u.id,
  x.clave,
  x.nombre,
  x.descripcion,
  x.vigente_desde,
  x.vigente_hasta,
  x.fuente,
  x.metadata,
  true
FROM unidad u
CROSS JOIN (
  VALUES
    (
      'HISTORICO_V1_2025',
      'Esquema histórico V1 / CDCM 2025',
      'Preserva las categorías demográficas utilizadas por V1 y los concentrados CDCM históricos.',
      DATE '2025-01-01',
      DATE '2025-12-31',
      'V1 + CDCM 2025',
      '{"tipo":"historico","no_reinterpretar":true}'::jsonb
    ),
    (
      'OFICIAL_2026',
      'Esquema demográfico oficial 2026',
      'Estructura observada en la base oficial de indicadores/captura 2026.',
      DATE '2026-01-01',
      NULL::DATE,
      'Base para indicadores oficial 2026',
      '{"tipo":"oficial","ejercicio":2026}'::jsonb
    )
) AS x(
  clave,
  nombre,
  descripcion,
  vigente_desde,
  vigente_hasta,
  fuente,
  metadata
)
ON CONFLICT DO NOTHING;


-- ============================================================================
-- 11. DIMENSIONES POR ESQUEMA
-- ============================================================================

WITH esquemas AS (
  SELECT id, upper(btrim(clave)) AS clave
  FROM v2.cat_esquemas_demograficos
  WHERE upper(btrim(clave)) IN (
    'HISTORICO_V1_2025',
    'OFICIAL_2026'
  )
),
dimensiones AS (
  SELECT id, upper(btrim(clave)) AS clave
  FROM v2.cat_dimensiones_poblacion
  WHERE upper(btrim(clave)) IN (
    'GENERO',
    'GRUPO_ETARIO',
    'GRUPO_PRIORITARIO'
  )
),
datos(esquema_clave, dimension_clave, requerida, orden) AS (
  VALUES
    ('HISTORICO_V1_2025', 'GENERO',            false, 10),
    ('HISTORICO_V1_2025', 'GRUPO_ETARIO',      false, 20),
    ('HISTORICO_V1_2025', 'GRUPO_PRIORITARIO', false, 30),

    ('OFICIAL_2026',       'GENERO',            false, 10),
    ('OFICIAL_2026',       'GRUPO_ETARIO',      false, 20),
    ('OFICIAL_2026',       'GRUPO_PRIORITARIO', false, 30)
)
INSERT INTO v2.esquema_dimensiones_poblacion (
  esquema_id,
  dimension_id,
  requerida,
  orden,
  activo
)
SELECT
  e.id,
  d.id,
  x.requerida,
  x.orden,
  true
FROM datos x
JOIN esquemas e
  ON e.clave = x.esquema_clave
JOIN dimensiones d
  ON d.clave = x.dimension_clave

ON CONFLICT (esquema_id, dimension_id)
DO UPDATE SET
  requerida = EXCLUDED.requerida,
  orden = EXCLUDED.orden,
  activo = true;


-- ============================================================================
-- 12. OPCIONES DEL ESQUEMA HISTÓRICO V1 / 2025
-- ============================================================================

WITH esquema AS (
  SELECT id
  FROM v2.cat_esquemas_demograficos
  WHERE upper(btrim(clave)) = 'HISTORICO_V1_2025'
  LIMIT 1
),
datos(dimension_clave, opcion_clave, etiqueta, orden) AS (
  VALUES
    ('GENERO', 'HOMBRES', 'Hombres', 10),
    ('GENERO', 'MUJERES', 'Mujeres', 20),

    ('GRUPO_ETARIO', 'NINEZ', 'Niñez', 10),
    ('GRUPO_ETARIO', 'ADOLESCENCIA', 'Adolescencia', 20),
    ('GRUPO_ETARIO', 'JUVENTUDES', 'Juventudes', 30),
    (
      'GRUPO_ETARIO',
      'ADULTOS_MAYORES',
      'Personas adultas mayores',
      40
    ),

    (
      'GRUPO_PRIORITARIO',
      'AFROMEXICANAS',
      'Personas afromexicanas',
      10
    ),
    (
      'GRUPO_PRIORITARIO',
      'DISCAPACIDAD',
      'Personas con discapacidad',
      20
    ),
    (
      'GRUPO_PRIORITARIO',
      'INDIGENAS',
      'Personas indígenas',
      30
    ),
    (
      'GRUPO_PRIORITARIO',
      'LGBTQ',
      'Personas LGBTQ+',
      40
    )
)
INSERT INTO v2.esquema_opciones_poblacion (
  esquema_id,
  opcion_poblacion_id,
  etiqueta_override,
  orden,
  activo
)
SELECT
  e.id,
  o.id,
  x.etiqueta,
  x.orden,
  true
FROM esquema e
CROSS JOIN datos x
JOIN v2.cat_dimensiones_poblacion d
  ON upper(btrim(d.clave)) = x.dimension_clave
JOIN v2.cat_opciones_poblacion o
  ON o.dimension_id = d.id
 AND upper(btrim(o.clave)) = x.opcion_clave

ON CONFLICT (esquema_id, opcion_poblacion_id)
DO UPDATE SET
  etiqueta_override = EXCLUDED.etiqueta_override,
  orden = EXCLUDED.orden,
  activo = true;


-- ============================================================================
-- 13. OPCIONES DEL ESQUEMA OFICIAL 2026
-- ============================================================================

WITH esquema AS (
  SELECT id
  FROM v2.cat_esquemas_demograficos
  WHERE upper(btrim(clave)) = 'OFICIAL_2026'
  LIMIT 1
),
datos(dimension_clave, opcion_clave, etiqueta, orden) AS (
  VALUES
    -- Género
    ('GENERO', 'MUJERES', 'Mujer', 10),
    ('GENERO', 'HOMBRES', 'Hombre', 20),
    ('GENERO', 'NO_BINARIO', 'No binario', 30),
    ('GENERO', 'PERSONA_TRANS', 'Persona trans', 40),
    (
      'GENERO',
      'PREFIERE_NO_ESPECIFICAR',
      'Prefiere no especificar',
      50
    ),
    ('GENERO', 'PUBLICO_MIXTO', 'Público mixto', 60),

    -- Grupo etario
    (
      'GRUPO_ETARIO',
      'PRIMERA_INFANCIA_0_5',
      'Primera infancia (0–5 años)',
      10
    ),
    (
      'GRUPO_ETARIO',
      'NINAS_NINOS_6_12',
      'Niñas y niños (6–12 años)',
      20
    ),
    (
      'GRUPO_ETARIO',
      'ADOLESCENCIA',
      'Adolescencia (13–17 años)',
      30
    ),
    (
      'GRUPO_ETARIO',
      'JUVENTUDES',
      'Jóvenes (18–29 años)',
      40
    ),
    (
      'GRUPO_ETARIO',
      'ADULTOS_30_59',
      'Adultos (30–59 años)',
      50
    ),
    (
      'GRUPO_ETARIO',
      'ADULTOS_MAYORES',
      'Personas adultas mayores (60+)',
      60
    ),
    (
      'GRUPO_ETARIO',
      'INTERGENERACIONAL',
      'Intergeneracional',
      70
    ),
    (
      'GRUPO_ETARIO',
      'NO_ESPECIFICADO',
      'No especificado',
      80
    ),

    -- Grupos prioritarios
    (
      'GRUPO_PRIORITARIO',
      'DISCAPACIDAD',
      'Personas con discapacidad',
      10
    ),
    (
      'GRUPO_PRIORITARIO',
      'INDIGENAS',
      'Pueblos y comunidades indígenas',
      20
    ),
    (
      'GRUPO_PRIORITARIO',
      'AFROMEXICANAS',
      'Personas afromexicanas',
      30
    ),
    (
      'GRUPO_PRIORITARIO',
      'MUJERES_VULNERABILIDAD',
      'Mujeres en situación de vulnerabilidad',
      40
    ),
    (
      'GRUPO_PRIORITARIO',
      'JUVENTUDES_RIESGO',
      'Juventudes en riesgo',
      50
    ),
    (
      'GRUPO_PRIORITARIO',
      'NNA',
      'Niñas, niños y adolescentes',
      60
    ),
    (
      'GRUPO_PRIORITARIO',
      'ADULTOS_MAYORES',
      'Personas adultas mayores',
      70
    ),
    (
      'GRUPO_PRIORITARIO',
      'MIGRANTES',
      'Personas migrantes',
      80
    ),
    (
      'GRUPO_PRIORITARIO',
      'PRIVADAS_LIBERTAD',
      'Personas privadas de la libertad',
      90
    )
)
INSERT INTO v2.esquema_opciones_poblacion (
  esquema_id,
  opcion_poblacion_id,
  etiqueta_override,
  orden,
  activo
)
SELECT
  e.id,
  o.id,
  x.etiqueta,
  x.orden,
  true
FROM esquema e
CROSS JOIN datos x
JOIN v2.cat_dimensiones_poblacion d
  ON upper(btrim(d.clave)) = x.dimension_clave
JOIN v2.cat_opciones_poblacion o
  ON o.dimension_id = d.id
 AND upper(btrim(o.clave)) = x.opcion_clave

ON CONFLICT (esquema_id, opcion_poblacion_id)
DO UPDATE SET
  etiqueta_override = EXCLUDED.etiqueta_override,
  orden = EXCLUDED.orden,
  activo = true;


-- ============================================================================
-- 14. ASIGNAR ESQUEMA HISTÓRICO A LAS 12 CONFIGURACIONES CDCM 2025
-- ============================================================================

UPDATE v2.configuracion_acciones ca
SET esquema_demografico_id = e.id
FROM v2.cat_esquemas_demograficos e,
     v2.cat_acciones a,
     v2.cat_unidades_operativas u
WHERE ca.accion_id = a.id
  AND a.unidad_operativa_id = u.id
  AND upper(btrim(u.clave)) = 'CDCM'
  AND ca.vigente_desde = DATE '2025-01-01'
  AND upper(btrim(e.clave)) = 'HISTORICO_V1_2025'
  AND e.unidad_operativa_id = u.id;


-- ============================================================================
-- 15. SNAPSHOT AUTOMÁTICO DEL ESQUEMA EN NUEVOS REGISTROS
--
-- Si el frontend no envía esquema_demografico_id, se toma de la
-- configuracion_accion seleccionada.
-- ============================================================================

CREATE OR REPLACE FUNCTION v2.prepare_registro_insert()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NOT NULL THEN
    NEW.created_by := auth.uid();
    NEW.updated_by := auth.uid();
  END IF;

  IF NEW.esquema_demografico_id IS NULL
     AND NEW.configuracion_accion_id IS NOT NULL THEN

    SELECT ca.esquema_demografico_id
    INTO NEW.esquema_demografico_id
    FROM v2.configuracion_acciones ca
    WHERE ca.id = NEW.configuracion_accion_id;

  END IF;

  IF NEW.folio IS NULL OR pg_catalog.btrim(NEW.folio) = '' THEN
    NEW.folio := v2.next_folio(NEW.periodo_anio);
  END IF;

  NEW.created_at := COALESCE(
    NEW.created_at,
    pg_catalog.now()
  );

  NEW.updated_at := pg_catalog.now();
  NEW.row_version := 1;

  RETURN NEW;
END;
$$;


REVOKE ALL ON FUNCTION v2.prepare_registro_insert()
FROM PUBLIC, anon, authenticated;


-- ============================================================================
-- 16. SEGURIDAD DE LAS 3 TABLAS NUEVAS
-- ============================================================================

ALTER TABLE v2.cat_esquemas_demograficos
  ENABLE ROW LEVEL SECURITY;

ALTER TABLE v2.esquema_dimensiones_poblacion
  ENABLE ROW LEVEL SECURITY;

ALTER TABLE v2.esquema_opciones_poblacion
  ENABLE ROW LEVEL SECURITY;


REVOKE ALL ON TABLE
  v2.cat_esquemas_demograficos,
  v2.esquema_dimensiones_poblacion,
  v2.esquema_opciones_poblacion
FROM PUBLIC, anon, authenticated;


GRANT SELECT, INSERT, UPDATE ON
  v2.cat_esquemas_demograficos,
  v2.esquema_dimensiones_poblacion,
  v2.esquema_opciones_poblacion
TO authenticated;


-- ============================================================================
-- 17. POLICIES — lectura usuarios activos / escritura ADMIN
-- ============================================================================

DROP POLICY IF EXISTS select_active_cat_esquemas_demograficos
ON v2.cat_esquemas_demograficos;

DROP POLICY IF EXISTS insert_admin_cat_esquemas_demograficos
ON v2.cat_esquemas_demograficos;

DROP POLICY IF EXISTS update_admin_cat_esquemas_demograficos
ON v2.cat_esquemas_demograficos;


CREATE POLICY select_active_cat_esquemas_demograficos
ON v2.cat_esquemas_demograficos
FOR SELECT TO authenticated
USING (
  (SELECT v2_private.is_active_user())
  AND (
    activo = true
    OR (SELECT v2_private.is_admin())
  )
);

CREATE POLICY insert_admin_cat_esquemas_demograficos
ON v2.cat_esquemas_demograficos
FOR INSERT TO authenticated
WITH CHECK (
  (SELECT v2_private.is_admin())
);

CREATE POLICY update_admin_cat_esquemas_demograficos
ON v2.cat_esquemas_demograficos
FOR UPDATE TO authenticated
USING (
  (SELECT v2_private.is_admin())
)
WITH CHECK (
  (SELECT v2_private.is_admin())
);


DROP POLICY IF EXISTS select_active_esquema_dimensiones_poblacion
ON v2.esquema_dimensiones_poblacion;

DROP POLICY IF EXISTS insert_admin_esquema_dimensiones_poblacion
ON v2.esquema_dimensiones_poblacion;

DROP POLICY IF EXISTS update_admin_esquema_dimensiones_poblacion
ON v2.esquema_dimensiones_poblacion;


CREATE POLICY select_active_esquema_dimensiones_poblacion
ON v2.esquema_dimensiones_poblacion
FOR SELECT TO authenticated
USING (
  (SELECT v2_private.is_active_user())
  AND (
    activo = true
    OR (SELECT v2_private.is_admin())
  )
);

CREATE POLICY insert_admin_esquema_dimensiones_poblacion
ON v2.esquema_dimensiones_poblacion
FOR INSERT TO authenticated
WITH CHECK (
  (SELECT v2_private.is_admin())
);

CREATE POLICY update_admin_esquema_dimensiones_poblacion
ON v2.esquema_dimensiones_poblacion
FOR UPDATE TO authenticated
USING (
  (SELECT v2_private.is_admin())
)
WITH CHECK (
  (SELECT v2_private.is_admin())
);


DROP POLICY IF EXISTS select_active_esquema_opciones_poblacion
ON v2.esquema_opciones_poblacion;

DROP POLICY IF EXISTS insert_admin_esquema_opciones_poblacion
ON v2.esquema_opciones_poblacion;

DROP POLICY IF EXISTS update_admin_esquema_opciones_poblacion
ON v2.esquema_opciones_poblacion;


CREATE POLICY select_active_esquema_opciones_poblacion
ON v2.esquema_opciones_poblacion
FOR SELECT TO authenticated
USING (
  (SELECT v2_private.is_active_user())
  AND (
    activo = true
    OR (SELECT v2_private.is_admin())
  )
);

CREATE POLICY insert_admin_esquema_opciones_poblacion
ON v2.esquema_opciones_poblacion
FOR INSERT TO authenticated
WITH CHECK (
  (SELECT v2_private.is_admin())
);

CREATE POLICY update_admin_esquema_opciones_poblacion
ON v2.esquema_opciones_poblacion
FOR UPDATE TO authenticated
USING (
  (SELECT v2_private.is_admin())
)
WITH CHECK (
  (SELECT v2_private.is_admin())
);


-- ============================================================================
-- 18. TRIGGERS updated_at + auditoría PARA TABLAS NUEVAS
-- ============================================================================

DO $$
DECLARE
  tbl TEXT;
BEGIN
  FOREACH tbl IN ARRAY ARRAY[
    'cat_esquemas_demograficos',
    'esquema_dimensiones_poblacion',
    'esquema_opciones_poblacion'
  ]
  LOOP
    EXECUTE pg_catalog.format(
      'DROP TRIGGER IF EXISTS trg_v2_touch_metadata ON v2.%I',
      tbl
    );

    EXECUTE pg_catalog.format(
      'CREATE TRIGGER trg_v2_touch_metadata
       BEFORE UPDATE ON v2.%I
       FOR EACH ROW
       EXECUTE FUNCTION v2.touch_updated_metadata()',
      tbl
    );

    EXECUTE pg_catalog.format(
      'DROP TRIGGER IF EXISTS trg_v2_catalog_audit ON v2.%I',
      tbl
    );

    EXECUTE pg_catalog.format(
      'CREATE TRIGGER trg_v2_catalog_audit
       AFTER INSERT OR UPDATE OR DELETE ON v2.%I
       FOR EACH ROW
       EXECUTE FUNCTION v2.audit_catalog_change()',
      tbl
    );
  END LOOP;
END
$$;


-- ============================================================================
-- 19. REGISTRO DE MIGRACIÓN
-- ============================================================================

INSERT INTO v2.schema_migrations (
  version,
  descripcion
)
VALUES (
  '2.1.09d',
  '09d_demographic_model_2026.sql - Esquemas demográficos versionados, participación/acceso y catálogo oficial 2026.'
)
ON CONFLICT (version) DO NOTHING;


COMMIT;


-- ============================================================================
-- 20. VERIFICACIÓN POST-INSTALACIÓN
-- ============================================================================

SELECT
  'V2.1 - 09d_demographic_model_2026' AS instalacion,

  (
    SELECT count(*)
    FROM v2.cat_esquemas_demograficos
    WHERE upper(btrim(clave)) IN (
      'HISTORICO_V1_2025',
      'OFICIAL_2026'
    )
  ) AS esquemas_demograficos,

  (
    SELECT count(*)
    FROM v2.esquema_dimensiones_poblacion ed
    JOIN v2.cat_esquemas_demograficos e
      ON e.id = ed.esquema_id
    WHERE upper(btrim(e.clave)) IN (
      'HISTORICO_V1_2025',
      'OFICIAL_2026'
    )
  ) AS dimensiones_en_esquemas,

  (
    SELECT count(*)
    FROM v2.esquema_opciones_poblacion eo
    JOIN v2.cat_esquemas_demograficos e
      ON e.id = eo.esquema_id
    WHERE upper(btrim(e.clave)) = 'HISTORICO_V1_2025'
  ) AS opciones_historico,

  (
    SELECT count(*)
    FROM v2.esquema_opciones_poblacion eo
    JOIN v2.cat_esquemas_demograficos e
      ON e.id = eo.esquema_id
    WHERE upper(btrim(e.clave)) = 'OFICIAL_2026'
  ) AS opciones_oficial_2026,

  (
    SELECT count(*)
    FROM v2.cat_opciones_poblacion o
    WHERE upper(btrim(o.clave)) IN (
      'PRIMERA_INFANCIA_0_5',
      'NINAS_NINOS_6_12',
      'ADULTOS_30_59',
      'INTERGENERACIONAL',
      'NO_ESPECIFICADO',
      'NO_BINARIO',
      'PERSONA_TRANS',
      'PREFIERE_NO_ESPECIFICAR',
      'PUBLICO_MIXTO',
      'MUJERES_VULNERABILIDAD',
      'JUVENTUDES_RIESGO',
      'NNA',
      'MIGRANTES',
      'PRIVADAS_LIBERTAD'
    )
    OR (
      upper(btrim(o.clave)) = 'ADULTOS_MAYORES'
      AND o.dimension_id = (
        SELECT id
        FROM v2.cat_dimensiones_poblacion
        WHERE upper(btrim(clave)) = 'GRUPO_PRIORITARIO'
        LIMIT 1
      )
    )
  ) AS opciones_nuevas_2026,

  (
    SELECT count(*)
    FROM v2.configuracion_acciones ca
    JOIN v2.cat_acciones a
      ON a.id = ca.accion_id
    JOIN v2.cat_unidades_operativas u
      ON u.id = a.unidad_operativa_id
    WHERE upper(btrim(u.clave)) = 'CDCM'
      AND ca.vigente_desde = DATE '2025-01-01'
      AND ca.esquema_demografico_id IS NOT NULL
  ) AS configuraciones_2025_con_esquema,

  EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'v2'
      AND table_name = 'registros'
      AND column_name = 'total_participantes'
  ) AS total_participantes_existe,

  EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'v2'
      AND table_name = 'registros'
      AND column_name = 'total_accesos'
  ) AS total_accesos_existe,

  EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'v2'
      AND table_name = 'registro_poblacion'
      AND column_name = 'universo'
  ) AS universo_poblacion_existe,

  (
    SELECT count(*)
    FROM pg_class c
    JOIN pg_namespace n
      ON n.oid = c.relnamespace
    WHERE n.nspname = 'v2'
      AND c.relname IN (
        'cat_esquemas_demograficos',
        'esquema_dimensiones_poblacion',
        'esquema_opciones_poblacion'
      )
      AND c.relrowsecurity = true
  ) AS tablas_nuevas_con_rls,

  (
    SELECT count(*)
    FROM v2.schema_migrations
    WHERE version = '2.1.09d'
  ) AS migracion_registrada;


-- ============================================================================
-- RESULTADO ESPERADO:
--
-- esquemas_demograficos             = 2
-- dimensiones_en_esquemas           = 6
-- opciones_historico                = 10
-- opciones_oficial_2026             = 23
-- opciones_nuevas_2026              = 15
-- configuraciones_2025_con_esquema  = 12
-- total_participantes_existe        = true
-- total_accesos_existe              = true
-- universo_poblacion_existe         = true
-- tablas_nuevas_con_rls             = 3
-- migracion_registrada              = 1
--
-- Es decir:
--
--   2 | 6 | 10 | 23 | 15 | 12 | true | true | true | 3 | 1
--
-- SIGUIENTE PASO:
--
--   09e_operational_seed_2026.sql
--
-- Ahí ya podremos cargar:
--   - configuración vigente 2026
--   - indicadores/versiones 2026 confirmados
--   - reglas de aporte que sí puedan calcularse sin falsificar información
--
-- Después:
--   10_legacy_migration.sql
-- ============================================================================

