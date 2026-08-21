-- ============================================================================
-- VINCULACIÓN CULTURAL 2.0
-- 02_catalogs.sql
-- Catálogos maestros y relaciones institucionales
-- Secretaría de Cultura de Guanajuato
--
-- REQUIERE:
--   01_core_schema.sql instalado correctamente.
--
-- CREA:
--   Organización:
--     v2.cat_unidades_operativas
--     v2.cat_programas
--     v2.cat_acciones
--     v2.cat_tipos_registro
--
--   Territorio:
--     v2.cat_regiones
--     v2.cat_municipios
--     v2.cat_municipio_alias
--     v2.cat_tipos_asentamiento
--     v2.cat_comunidades
--
--   Espacios:
--     v2.cat_tipos_espacio
--     v2.cat_espacios
--
--   Personas:
--     v2.cat_personas
--     v2.cat_funciones
--     v2.persona_funciones
--
--   Seguimiento / configuración:
--     v2.cat_unidades_medida
--     v2.cat_dimensiones_poblacion
--     v2.cat_opciones_poblacion
--     v2.configuracion_acciones
--
--   Alcances:
--     v2.profile_unidades
--     v2.profile_municipios
--
-- SEGURIDAD:
--   Todas las tablas nacen con RLS habilitado y sin acceso aplicativo.
--   Los GRANT y policies finales llegarán en 06_rls.sql.
--
-- NO HACE:
--   ✗ No modifica tablas V1.
--   ✗ No migra registros históricos.
--   ✗ No carga todavía los 46 municipios.
--   ✗ No crea policies permisivas.
-- ============================================================================

BEGIN;

SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '90s';

-- ============================================================================
-- 00. PRECONDICIONES
-- ============================================================================

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.schemata
    WHERE schema_name = 'v2'
  ) THEN
    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: schema v2 no existe. Ejecute 01_core_schema.sql.';
  END IF;

  IF to_regclass('v2.profiles') IS NULL THEN
    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: v2.profiles no existe. Ejecute 01_core_schema.sql.';
  END IF;
END
$$;


-- ============================================================================
-- 01. ORGANIZACIÓN
-- ============================================================================

CREATE TABLE IF NOT EXISTS v2.cat_unidades_operativas (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  clave             TEXT NOT NULL,
  nombre            TEXT NOT NULL,
  descripcion       TEXT,
  orden             INTEGER NOT NULL DEFAULT 0 CHECK (orden >= 0),
  activo            BOOLEAN NOT NULL DEFAULT true,

  created_by        UUID REFERENCES auth.users(id) ON DELETE SET NULL
                    DEFAULT auth.uid(),
  updated_by        UUID REFERENCES auth.users(id) ON DELETE SET NULL
                    DEFAULT auth.uid(),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT ck_v2_unidad_clave_no_vacia
    CHECK (btrim(clave) <> ''),
  CONSTRAINT ck_v2_unidad_nombre_no_vacio
    CHECK (btrim(nombre) <> '')
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_v2_unidades_clave_ci
  ON v2.cat_unidades_operativas (lower(btrim(clave)));

CREATE UNIQUE INDEX IF NOT EXISTS uq_v2_unidades_nombre_ci
  ON v2.cat_unidades_operativas (lower(btrim(nombre)));

COMMENT ON TABLE v2.cat_unidades_operativas IS
'Grandes ámbitos operativos de Vinculación Cultural: CDCM, Bibliotecas y futuras unidades.';


CREATE TABLE IF NOT EXISTS v2.cat_programas (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  unidad_operativa_id   UUID NOT NULL
                        REFERENCES v2.cat_unidades_operativas(id)
                        ON DELETE RESTRICT,

  clave                 TEXT NOT NULL,
  nombre                TEXT NOT NULL,
  descripcion           TEXT,
  orden                 INTEGER NOT NULL DEFAULT 0 CHECK (orden >= 0),
  activo                BOOLEAN NOT NULL DEFAULT true,

  created_by            UUID REFERENCES auth.users(id) ON DELETE SET NULL
                        DEFAULT auth.uid(),
  updated_by            UUID REFERENCES auth.users(id) ON DELETE SET NULL
                        DEFAULT auth.uid(),
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT ck_v2_programa_clave_no_vacia
    CHECK (btrim(clave) <> ''),
  CONSTRAINT ck_v2_programa_nombre_no_vacio
    CHECK (btrim(nombre) <> ''),

  -- Permite FK compuesta desde acciones y garantiza consistencia unidad/programa.
  CONSTRAINT uq_v2_programa_id_unidad
    UNIQUE (id, unidad_operativa_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_v2_programas_clave_ci
  ON v2.cat_programas (lower(btrim(clave)));

CREATE UNIQUE INDEX IF NOT EXISTS uq_v2_programas_unidad_nombre_ci
  ON v2.cat_programas (
    unidad_operativa_id,
    lower(btrim(nombre))
  );

CREATE INDEX IF NOT EXISTS idx_v2_programas_unidad
  ON v2.cat_programas (unidad_operativa_id, activo, orden);


CREATE TABLE IF NOT EXISTS v2.cat_tipos_registro (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  clave             TEXT NOT NULL,
  nombre            TEXT NOT NULL,
  descripcion       TEXT,
  orden             INTEGER NOT NULL DEFAULT 0 CHECK (orden >= 0),
  activo            BOOLEAN NOT NULL DEFAULT true,

  created_by        UUID REFERENCES auth.users(id) ON DELETE SET NULL
                    DEFAULT auth.uid(),
  updated_by        UUID REFERENCES auth.users(id) ON DELETE SET NULL
                    DEFAULT auth.uid(),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT ck_v2_tipo_registro_clave_no_vacia
    CHECK (btrim(clave) <> ''),
  CONSTRAINT ck_v2_tipo_registro_nombre_no_vacio
    CHECK (btrim(nombre) <> '')
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_v2_tipos_registro_clave_ci
  ON v2.cat_tipos_registro (lower(btrim(clave)));

CREATE UNIQUE INDEX IF NOT EXISTS uq_v2_tipos_registro_nombre_ci
  ON v2.cat_tipos_registro (lower(btrim(nombre)));


CREATE TABLE IF NOT EXISTS v2.cat_acciones (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  unidad_operativa_id   UUID NOT NULL
                        REFERENCES v2.cat_unidades_operativas(id)
                        ON DELETE RESTRICT,

  programa_id           UUID,

  clave                 TEXT NOT NULL,
  nombre                TEXT NOT NULL,
  descripcion           TEXT,

  orden                 INTEGER NOT NULL DEFAULT 0 CHECK (orden >= 0),
  activo                BOOLEAN NOT NULL DEFAULT true,

  created_by            UUID REFERENCES auth.users(id) ON DELETE SET NULL
                        DEFAULT auth.uid(),
  updated_by            UUID REFERENCES auth.users(id) ON DELETE SET NULL
                        DEFAULT auth.uid(),
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT ck_v2_accion_clave_no_vacia
    CHECK (btrim(clave) <> ''),
  CONSTRAINT ck_v2_accion_nombre_no_vacio
    CHECK (btrim(nombre) <> ''),

  -- Si programa_id tiene valor, éste debe pertenecer a la misma unidad operativa.
  CONSTRAINT fk_v2_accion_programa_unidad
    FOREIGN KEY (programa_id, unidad_operativa_id)
    REFERENCES v2.cat_programas (id, unidad_operativa_id)
    ON DELETE RESTRICT
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_v2_acciones_clave_ci
  ON v2.cat_acciones (lower(btrim(clave)));

CREATE UNIQUE INDEX IF NOT EXISTS uq_v2_acciones_unidad_nombre_ci
  ON v2.cat_acciones (
    unidad_operativa_id,
    lower(btrim(nombre))
  );

CREATE INDEX IF NOT EXISTS idx_v2_acciones_unidad_programa
  ON v2.cat_acciones (
    unidad_operativa_id,
    programa_id,
    activo,
    orden
  );


-- ============================================================================
-- 02. TERRITORIO
-- ============================================================================

CREATE TABLE IF NOT EXISTS v2.cat_regiones (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  clave             TEXT NOT NULL,
  nombre            TEXT NOT NULL,
  descripcion       TEXT,
  orden             INTEGER NOT NULL DEFAULT 0 CHECK (orden >= 0),
  activo            BOOLEAN NOT NULL DEFAULT true,

  created_by        UUID REFERENCES auth.users(id) ON DELETE SET NULL
                    DEFAULT auth.uid(),
  updated_by        UUID REFERENCES auth.users(id) ON DELETE SET NULL
                    DEFAULT auth.uid(),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT ck_v2_region_clave_no_vacia CHECK (btrim(clave) <> ''),
  CONSTRAINT ck_v2_region_nombre_no_vacio CHECK (btrim(nombre) <> '')
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_v2_regiones_clave_ci
  ON v2.cat_regiones (lower(btrim(clave)));

CREATE UNIQUE INDEX IF NOT EXISTS uq_v2_regiones_nombre_ci
  ON v2.cat_regiones (lower(btrim(nombre)));


CREATE TABLE IF NOT EXISTS v2.cat_municipios (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  clave_inegi       TEXT,
  nombre_oficial    TEXT NOT NULL,
  region_id         UUID REFERENCES v2.cat_regiones(id) ON DELETE RESTRICT,

  orden             INTEGER NOT NULL DEFAULT 0 CHECK (orden >= 0),
  activo            BOOLEAN NOT NULL DEFAULT true,

  created_by        UUID REFERENCES auth.users(id) ON DELETE SET NULL
                    DEFAULT auth.uid(),
  updated_by        UUID REFERENCES auth.users(id) ON DELETE SET NULL
                    DEFAULT auth.uid(),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT ck_v2_municipio_nombre_no_vacio
    CHECK (btrim(nombre_oficial) <> '')
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_v2_municipios_nombre_ci
  ON v2.cat_municipios (lower(btrim(nombre_oficial)));

CREATE UNIQUE INDEX IF NOT EXISTS uq_v2_municipios_clave_inegi
  ON v2.cat_municipios (clave_inegi)
  WHERE clave_inegi IS NOT NULL AND btrim(clave_inegi) <> '';

CREATE INDEX IF NOT EXISTS idx_v2_municipios_region
  ON v2.cat_municipios (region_id, activo, orden);


CREATE TABLE IF NOT EXISTS v2.cat_municipio_alias (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  municipio_id      UUID NOT NULL
                    REFERENCES v2.cat_municipios(id)
                    ON DELETE CASCADE,

  alias             TEXT NOT NULL,
  origen            TEXT,
  activo            BOOLEAN NOT NULL DEFAULT true,

  created_by        UUID REFERENCES auth.users(id) ON DELETE SET NULL
                    DEFAULT auth.uid(),
  updated_by        UUID REFERENCES auth.users(id) ON DELETE SET NULL
                    DEFAULT auth.uid(),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT ck_v2_municipio_alias_no_vacio
    CHECK (btrim(alias) <> '')
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_v2_municipio_alias_ci
  ON v2.cat_municipio_alias (lower(btrim(alias)));

CREATE INDEX IF NOT EXISTS idx_v2_municipio_alias_municipio
  ON v2.cat_municipio_alias (municipio_id, activo);


CREATE TABLE IF NOT EXISTS v2.cat_tipos_asentamiento (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  clave             TEXT NOT NULL,
  nombre            TEXT NOT NULL,
  descripcion       TEXT,
  orden             INTEGER NOT NULL DEFAULT 0 CHECK (orden >= 0),
  activo            BOOLEAN NOT NULL DEFAULT true,

  created_by        UUID REFERENCES auth.users(id) ON DELETE SET NULL
                    DEFAULT auth.uid(),
  updated_by        UUID REFERENCES auth.users(id) ON DELETE SET NULL
                    DEFAULT auth.uid(),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT ck_v2_tipo_asentamiento_clave_no_vacia
    CHECK (btrim(clave) <> ''),
  CONSTRAINT ck_v2_tipo_asentamiento_nombre_no_vacio
    CHECK (btrim(nombre) <> '')
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_v2_tipos_asentamiento_clave_ci
  ON v2.cat_tipos_asentamiento (lower(btrim(clave)));

CREATE UNIQUE INDEX IF NOT EXISTS uq_v2_tipos_asentamiento_nombre_ci
  ON v2.cat_tipos_asentamiento (lower(btrim(nombre)));


CREATE TABLE IF NOT EXISTS v2.cat_comunidades (
  id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  municipio_id            UUID NOT NULL
                          REFERENCES v2.cat_municipios(id)
                          ON DELETE RESTRICT,

  tipo_asentamiento_id    UUID
                          REFERENCES v2.cat_tipos_asentamiento(id)
                          ON DELETE RESTRICT,

  clave                   TEXT,
  nombre                  TEXT NOT NULL,

  latitud                 DOUBLE PRECISION,
  longitud                DOUBLE PRECISION,

  activo                  BOOLEAN NOT NULL DEFAULT true,

  created_by              UUID REFERENCES auth.users(id) ON DELETE SET NULL
                          DEFAULT auth.uid(),
  updated_by              UUID REFERENCES auth.users(id) ON DELETE SET NULL
                          DEFAULT auth.uid(),
  created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT ck_v2_comunidad_nombre_no_vacio
    CHECK (btrim(nombre) <> ''),

  CONSTRAINT ck_v2_comunidad_latitud
    CHECK (latitud IS NULL OR latitud BETWEEN -90 AND 90),

  CONSTRAINT ck_v2_comunidad_longitud
    CHECK (longitud IS NULL OR longitud BETWEEN -180 AND 180)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_v2_comunidades_municipio_nombre_ci
  ON v2.cat_comunidades (
    municipio_id,
    lower(btrim(nombre))
  );

CREATE UNIQUE INDEX IF NOT EXISTS uq_v2_comunidades_municipio_clave
  ON v2.cat_comunidades (municipio_id, clave)
  WHERE clave IS NOT NULL AND btrim(clave) <> '';

CREATE INDEX IF NOT EXISTS idx_v2_comunidades_municipio
  ON v2.cat_comunidades (municipio_id, activo, nombre);


-- ============================================================================
-- 03. ESPACIOS CULTURALES
-- ============================================================================

CREATE TABLE IF NOT EXISTS v2.cat_tipos_espacio (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  clave             TEXT NOT NULL,
  nombre            TEXT NOT NULL,
  descripcion       TEXT,
  orden             INTEGER NOT NULL DEFAULT 0 CHECK (orden >= 0),
  activo            BOOLEAN NOT NULL DEFAULT true,

  created_by        UUID REFERENCES auth.users(id) ON DELETE SET NULL
                    DEFAULT auth.uid(),
  updated_by        UUID REFERENCES auth.users(id) ON DELETE SET NULL
                    DEFAULT auth.uid(),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT ck_v2_tipo_espacio_clave_no_vacia
    CHECK (btrim(clave) <> ''),
  CONSTRAINT ck_v2_tipo_espacio_nombre_no_vacio
    CHECK (btrim(nombre) <> '')
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_v2_tipos_espacio_clave_ci
  ON v2.cat_tipos_espacio (lower(btrim(clave)));

CREATE UNIQUE INDEX IF NOT EXISTS uq_v2_tipos_espacio_nombre_ci
  ON v2.cat_tipos_espacio (lower(btrim(nombre)));


-- ============================================================================
-- 04. PERSONAS
-- ============================================================================

CREATE TABLE IF NOT EXISTS v2.cat_personas (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  nombre            TEXT NOT NULL,
  correo            TEXT,
  telefono          TEXT,

  municipio_id      UUID REFERENCES v2.cat_municipios(id) ON DELETE SET NULL,

  activo            BOOLEAN NOT NULL DEFAULT true,

  created_by        UUID REFERENCES auth.users(id) ON DELETE SET NULL
                    DEFAULT auth.uid(),
  updated_by        UUID REFERENCES auth.users(id) ON DELETE SET NULL
                    DEFAULT auth.uid(),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT ck_v2_persona_nombre_no_vacio
    CHECK (btrim(nombre) <> '')
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_v2_personas_correo_ci
  ON v2.cat_personas (lower(btrim(correo)))
  WHERE correo IS NOT NULL AND btrim(correo) <> '';

CREATE INDEX IF NOT EXISTS idx_v2_personas_nombre
  ON v2.cat_personas (lower(btrim(nombre)));

CREATE INDEX IF NOT EXISTS idx_v2_personas_municipio
  ON v2.cat_personas (municipio_id, activo);


CREATE TABLE IF NOT EXISTS v2.cat_funciones (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  clave             TEXT NOT NULL,
  nombre            TEXT NOT NULL,
  descripcion       TEXT,
  orden             INTEGER NOT NULL DEFAULT 0 CHECK (orden >= 0),
  activo            BOOLEAN NOT NULL DEFAULT true,

  created_by        UUID REFERENCES auth.users(id) ON DELETE SET NULL
                    DEFAULT auth.uid(),
  updated_by        UUID REFERENCES auth.users(id) ON DELETE SET NULL
                    DEFAULT auth.uid(),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT ck_v2_funcion_clave_no_vacia
    CHECK (btrim(clave) <> ''),
  CONSTRAINT ck_v2_funcion_nombre_no_vacio
    CHECK (btrim(nombre) <> '')
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_v2_funciones_clave_ci
  ON v2.cat_funciones (lower(btrim(clave)));

CREATE UNIQUE INDEX IF NOT EXISTS uq_v2_funciones_nombre_ci
  ON v2.cat_funciones (lower(btrim(nombre)));


CREATE TABLE IF NOT EXISTS v2.persona_funciones (
  persona_id         UUID NOT NULL
                     REFERENCES v2.cat_personas(id)
                     ON DELETE CASCADE,

  funcion_id         UUID NOT NULL
                     REFERENCES v2.cat_funciones(id)
                     ON DELETE RESTRICT,

  unidad_operativa_id UUID
                     REFERENCES v2.cat_unidades_operativas(id)
                     ON DELETE RESTRICT,

  municipio_id       UUID
                     REFERENCES v2.cat_municipios(id)
                     ON DELETE RESTRICT,

  activo             BOOLEAN NOT NULL DEFAULT true,

  created_by         UUID REFERENCES auth.users(id) ON DELETE SET NULL
                     DEFAULT auth.uid(),
  updated_by         UUID REFERENCES auth.users(id) ON DELETE SET NULL
                     DEFAULT auth.uid(),
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),

  PRIMARY KEY (persona_id, funcion_id)
);

CREATE INDEX IF NOT EXISTS idx_v2_persona_funciones_funcion
  ON v2.persona_funciones (funcion_id, activo);

CREATE INDEX IF NOT EXISTS idx_v2_persona_funciones_unidad_municipio
  ON v2.persona_funciones (
    unidad_operativa_id,
    municipio_id,
    activo
  );


-- ============================================================================
-- 05. ESPACIOS CONCRETOS
-- Se crea después de personas porque puede referenciar a responsable.
-- ============================================================================

CREATE TABLE IF NOT EXISTS v2.cat_espacios (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  tipo_espacio_id       UUID NOT NULL
                        REFERENCES v2.cat_tipos_espacio(id)
                        ON DELETE RESTRICT,

  unidad_operativa_id   UUID
                        REFERENCES v2.cat_unidades_operativas(id)
                        ON DELETE RESTRICT,

  municipio_id          UUID NOT NULL
                        REFERENCES v2.cat_municipios(id)
                        ON DELETE RESTRICT,

  comunidad_id          UUID
                        REFERENCES v2.cat_comunidades(id)
                        ON DELETE RESTRICT,

  responsable_id        UUID
                        REFERENCES v2.cat_personas(id)
                        ON DELETE SET NULL,

  clave                 TEXT,
  nombre                TEXT NOT NULL,
  direccion             TEXT,

  latitud               DOUBLE PRECISION,
  longitud              DOUBLE PRECISION,

  metadata              JSONB NOT NULL DEFAULT '{}'::jsonb,

  activo                BOOLEAN NOT NULL DEFAULT true,

  created_by            UUID REFERENCES auth.users(id) ON DELETE SET NULL
                        DEFAULT auth.uid(),
  updated_by            UUID REFERENCES auth.users(id) ON DELETE SET NULL
                        DEFAULT auth.uid(),
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT ck_v2_espacio_nombre_no_vacio
    CHECK (btrim(nombre) <> ''),

  CONSTRAINT ck_v2_espacio_latitud
    CHECK (latitud IS NULL OR latitud BETWEEN -90 AND 90),

  CONSTRAINT ck_v2_espacio_longitud
    CHECK (longitud IS NULL OR longitud BETWEEN -180 AND 180)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_v2_espacios_clave_ci
  ON v2.cat_espacios (lower(btrim(clave)))
  WHERE clave IS NOT NULL AND btrim(clave) <> '';

-- Evita duplicados exactos del mismo espacio dentro de la misma ubicación,
-- pero permite nombres iguales en municipios distintos.
CREATE UNIQUE INDEX IF NOT EXISTS uq_v2_espacios_contexto_nombre_ci
  ON v2.cat_espacios (
    municipio_id,
    COALESCE(
      comunidad_id,
      '00000000-0000-0000-0000-000000000000'::uuid
    ),
    tipo_espacio_id,
    lower(btrim(nombre))
  );

CREATE INDEX IF NOT EXISTS idx_v2_espacios_municipio
  ON v2.cat_espacios (municipio_id, activo, nombre);

CREATE INDEX IF NOT EXISTS idx_v2_espacios_unidad
  ON v2.cat_espacios (unidad_operativa_id, activo);


-- ============================================================================
-- 06. UNIDADES DE MEDIDA
-- ============================================================================

CREATE TABLE IF NOT EXISTS v2.cat_unidades_medida (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  clave             TEXT NOT NULL,
  nombre            TEXT NOT NULL,
  simbolo           TEXT,

  tipo_dato         TEXT NOT NULL DEFAULT 'ENTERO'
                    CHECK (
                      tipo_dato IN (
                        'ENTERO',
                        'DECIMAL',
                        'PORCENTAJE',
                        'MONEDA'
                      )
                    ),

  activo            BOOLEAN NOT NULL DEFAULT true,

  created_by        UUID REFERENCES auth.users(id) ON DELETE SET NULL
                    DEFAULT auth.uid(),
  updated_by        UUID REFERENCES auth.users(id) ON DELETE SET NULL
                    DEFAULT auth.uid(),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT ck_v2_unidad_medida_clave_no_vacia
    CHECK (btrim(clave) <> ''),
  CONSTRAINT ck_v2_unidad_medida_nombre_no_vacio
    CHECK (btrim(nombre) <> '')
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_v2_unidades_medida_clave_ci
  ON v2.cat_unidades_medida (lower(btrim(clave)));

CREATE UNIQUE INDEX IF NOT EXISTS uq_v2_unidades_medida_nombre_ci
  ON v2.cat_unidades_medida (lower(btrim(nombre)));


-- ============================================================================
-- 07. CATÁLOGOS DE POBLACIÓN
-- ============================================================================

CREATE TABLE IF NOT EXISTS v2.cat_dimensiones_poblacion (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  clave             TEXT NOT NULL,
  nombre            TEXT NOT NULL,
  descripcion       TEXT,

  -- true: las opciones representan una partición del total
  -- (ej. género o grupo etario).
  -- false: las opciones pueden traslaparse
  -- (ej. grupos prioritarios).
  es_exclusiva      BOOLEAN NOT NULL DEFAULT false,

  orden             INTEGER NOT NULL DEFAULT 0 CHECK (orden >= 0),
  activo            BOOLEAN NOT NULL DEFAULT true,

  created_by        UUID REFERENCES auth.users(id) ON DELETE SET NULL
                    DEFAULT auth.uid(),
  updated_by        UUID REFERENCES auth.users(id) ON DELETE SET NULL
                    DEFAULT auth.uid(),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT ck_v2_dimension_poblacion_clave_no_vacia
    CHECK (btrim(clave) <> ''),
  CONSTRAINT ck_v2_dimension_poblacion_nombre_no_vacio
    CHECK (btrim(nombre) <> '')
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_v2_dimensiones_poblacion_clave_ci
  ON v2.cat_dimensiones_poblacion (lower(btrim(clave)));


CREATE TABLE IF NOT EXISTS v2.cat_opciones_poblacion (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  dimension_id      UUID NOT NULL
                    REFERENCES v2.cat_dimensiones_poblacion(id)
                    ON DELETE RESTRICT,

  clave             TEXT NOT NULL,
  nombre            TEXT NOT NULL,

  orden             INTEGER NOT NULL DEFAULT 0 CHECK (orden >= 0),
  activo            BOOLEAN NOT NULL DEFAULT true,

  created_by        UUID REFERENCES auth.users(id) ON DELETE SET NULL
                    DEFAULT auth.uid(),
  updated_by        UUID REFERENCES auth.users(id) ON DELETE SET NULL
                    DEFAULT auth.uid(),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT ck_v2_opcion_poblacion_clave_no_vacia
    CHECK (btrim(clave) <> ''),
  CONSTRAINT ck_v2_opcion_poblacion_nombre_no_vacio
    CHECK (btrim(nombre) <> '')
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_v2_opciones_poblacion_dimension_clave_ci
  ON v2.cat_opciones_poblacion (
    dimension_id,
    lower(btrim(clave))
  );

CREATE UNIQUE INDEX IF NOT EXISTS uq_v2_opciones_poblacion_dimension_nombre_ci
  ON v2.cat_opciones_poblacion (
    dimension_id,
    lower(btrim(nombre))
  );


-- ============================================================================
-- 08. MATRIZ DE CONFIGURACIÓN DE ACCIONES
--
-- Una acción puede tener distintas configuraciones a través del tiempo.
-- Ésta será la base del formulario dinámico.
-- ============================================================================

CREATE TABLE IF NOT EXISTS v2.configuracion_acciones (
  id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  accion_id               UUID NOT NULL
                          REFERENCES v2.cat_acciones(id)
                          ON DELETE CASCADE,

  tipo_registro_id        UUID NOT NULL
                          REFERENCES v2.cat_tipos_registro(id)
                          ON DELETE RESTRICT,

  tipo_formulario         TEXT NOT NULL,

  requiere_municipio      BOOLEAN NOT NULL DEFAULT true,
  requiere_comunidad      BOOLEAN NOT NULL DEFAULT false,
  requiere_espacio        BOOLEAN NOT NULL DEFAULT false,
  requiere_responsable    BOOLEAN NOT NULL DEFAULT false,
  requiere_docente        BOOLEAN NOT NULL DEFAULT false,

  requiere_beneficiarios  BOOLEAN NOT NULL DEFAULT false,
  requiere_demografia     BOOLEAN NOT NULL DEFAULT false,

  requiere_gps            BOOLEAN NOT NULL DEFAULT false,
  requiere_evidencia      BOOLEAN NOT NULL DEFAULT true,
  requiere_validacion     BOOLEAN NOT NULL DEFAULT true,

  permite_offline         BOOLEAN NOT NULL DEFAULT true,

  vigente_desde           DATE NOT NULL DEFAULT CURRENT_DATE,
  vigente_hasta           DATE,

  configuracion_extra     JSONB NOT NULL DEFAULT '{}'::jsonb,

  activo                  BOOLEAN NOT NULL DEFAULT true,

  created_by              UUID REFERENCES auth.users(id) ON DELETE SET NULL
                          DEFAULT auth.uid(),
  updated_by              UUID REFERENCES auth.users(id) ON DELETE SET NULL
                          DEFAULT auth.uid(),
  created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT ck_v2_config_accion_formulario_no_vacio
    CHECK (btrim(tipo_formulario) <> ''),

  CONSTRAINT ck_v2_config_accion_vigencia
    CHECK (
      vigente_hasta IS NULL
      OR vigente_hasta >= vigente_desde
    ),

  CONSTRAINT uq_v2_config_accion_inicio
    UNIQUE (accion_id, vigente_desde)
);

CREATE INDEX IF NOT EXISTS idx_v2_config_acciones_vigencia
  ON v2.configuracion_acciones (
    accion_id,
    activo,
    vigente_desde,
    vigente_hasta
  );


-- ============================================================================
-- 09. ALCANCES DE USUARIO
-- Un usuario puede pertenecer a varias unidades y/o municipios.
-- ============================================================================

CREATE TABLE IF NOT EXISTS v2.profile_unidades (
  user_id               UUID NOT NULL
                        REFERENCES v2.profiles(user_id)
                        ON DELETE CASCADE,

  unidad_operativa_id   UUID NOT NULL
                        REFERENCES v2.cat_unidades_operativas(id)
                        ON DELETE CASCADE,

  es_principal          BOOLEAN NOT NULL DEFAULT false,
  activo                BOOLEAN NOT NULL DEFAULT true,

  created_by            UUID REFERENCES auth.users(id) ON DELETE SET NULL
                        DEFAULT auth.uid(),
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),

  PRIMARY KEY (user_id, unidad_operativa_id)
);

CREATE INDEX IF NOT EXISTS idx_v2_profile_unidades_unidad
  ON v2.profile_unidades (unidad_operativa_id, activo);


CREATE TABLE IF NOT EXISTS v2.profile_municipios (
  user_id           UUID NOT NULL
                    REFERENCES v2.profiles(user_id)
                    ON DELETE CASCADE,

  municipio_id      UUID NOT NULL
                    REFERENCES v2.cat_municipios(id)
                    ON DELETE CASCADE,

  es_principal      BOOLEAN NOT NULL DEFAULT false,
  activo            BOOLEAN NOT NULL DEFAULT true,

  created_by        UUID REFERENCES auth.users(id) ON DELETE SET NULL
                    DEFAULT auth.uid(),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

  PRIMARY KEY (user_id, municipio_id)
);

CREATE INDEX IF NOT EXISTS idx_v2_profile_municipios_municipio
  ON v2.profile_municipios (municipio_id, activo);


-- ============================================================================
-- 10. SEGURIDAD BASE: RLS + DENY BY DEFAULT
-- El event trigger existente solo cubre public, por lo que V2 se protege aquí.
-- ============================================================================

DO $$
DECLARE
  tbl TEXT;
BEGIN
  FOREACH tbl IN ARRAY ARRAY[
    'cat_unidades_operativas',
    'cat_programas',
    'cat_tipos_registro',
    'cat_acciones',
    'cat_regiones',
    'cat_municipios',
    'cat_municipio_alias',
    'cat_tipos_asentamiento',
    'cat_comunidades',
    'cat_tipos_espacio',
    'cat_espacios',
    'cat_personas',
    'cat_funciones',
    'persona_funciones',
    'cat_unidades_medida',
    'cat_dimensiones_poblacion',
    'cat_opciones_poblacion',
    'configuracion_acciones',
    'profile_unidades',
    'profile_municipios'
  ]
  LOOP
    EXECUTE format('ALTER TABLE v2.%I ENABLE ROW LEVEL SECURITY', tbl);

    EXECUTE format('REVOKE ALL ON TABLE v2.%I FROM PUBLIC', tbl);
    EXECUTE format('REVOKE ALL ON TABLE v2.%I FROM anon', tbl);
    EXECUTE format('REVOKE ALL ON TABLE v2.%I FROM authenticated', tbl);
  END LOOP;
END
$$;


-- ============================================================================
-- 11. COMENTARIOS DE GOBIERNO DE DATOS
-- ============================================================================

COMMENT ON TABLE v2.cat_municipios IS
'Catálogo oficial de municipios. La captura operativa nunca debe aceptar municipio como texto libre.';

COMMENT ON TABLE v2.cat_municipio_alias IS
'Alias históricos utilizados exclusivamente para normalización/importaciones.';

COMMENT ON TABLE v2.cat_comunidades IS
'Comunidades/localidades dependientes de un municipio oficial.';

COMMENT ON TABLE v2.cat_espacios IS
'Espacios culturales concretos: bibliotecas, casas de cultura, teatros, museos, centros y otros.';

COMMENT ON TABLE v2.cat_personas IS
'Personas operativas reutilizables: docentes, talleristas, bibliotecarios, enlaces y responsables.';

COMMENT ON TABLE v2.configuracion_acciones IS
'Matriz que controla qué formulario y campos requiere cada acción institucional.';

COMMENT ON TABLE v2.profile_unidades IS
'Alcance de acceso de cada perfil sobre unidades operativas.';

COMMENT ON TABLE v2.profile_municipios IS
'Alcance territorial de cada perfil sobre municipios.';


-- ============================================================================
-- 12. REGISTRO DE MIGRACIÓN
-- ============================================================================

INSERT INTO v2.schema_migrations (
  version,
  descripcion
)
VALUES (
  '2.1.02',
  '02_catalogs.sql - Catálogos maestros, matriz de configuración y alcances.'
)
ON CONFLICT (version) DO NOTHING;


COMMIT;


-- ============================================================================
-- 13. VERIFICACIÓN POST-INSTALACIÓN
-- ============================================================================

WITH tablas_esperadas(nombre) AS (
  VALUES
    ('cat_unidades_operativas'),
    ('cat_programas'),
    ('cat_tipos_registro'),
    ('cat_acciones'),
    ('cat_regiones'),
    ('cat_municipios'),
    ('cat_municipio_alias'),
    ('cat_tipos_asentamiento'),
    ('cat_comunidades'),
    ('cat_tipos_espacio'),
    ('cat_espacios'),
    ('cat_personas'),
    ('cat_funciones'),
    ('persona_funciones'),
    ('cat_unidades_medida'),
    ('cat_dimensiones_poblacion'),
    ('cat_opciones_poblacion'),
    ('configuracion_acciones'),
    ('profile_unidades'),
    ('profile_municipios')
)
SELECT
  'V2.1 - 02_catalogs' AS instalacion,

  (
    SELECT count(*)
    FROM tablas_esperadas te
    WHERE to_regclass('v2.' || te.nombre) IS NOT NULL
  ) AS tablas_catalogos_creadas,

  (
    SELECT count(*)
    FROM tablas_esperadas te
    JOIN pg_class c
      ON c.oid = to_regclass('v2.' || te.nombre)
    WHERE c.relrowsecurity = true
  ) AS tablas_catalogos_con_rls,

  (
    SELECT count(*)
    FROM v2.schema_migrations
    WHERE version = '2.1.02'
  ) AS migracion_registrada,

  (
    SELECT count(*)
    FROM information_schema.tables
    WHERE table_schema = 'v2'
      AND table_type = 'BASE TABLE'
  ) AS total_tablas_v2;


-- ============================================================================
-- RESULTADO ESPERADO:
--
-- tablas_catalogos_creadas      = 20
-- tablas_catalogos_con_rls      = 20
-- migracion_registrada          = 1
-- total_tablas_v2               = 26
--
-- NOTA:
-- Todavía NO habrá filas en estos catálogos.
-- Los datos iniciales llegarán en 09_seed_base.sql y mediante Admin V2.
--
-- ROLLBACK DE ESTE PASO:
-- No ejecutar manualmente salvo decisión expresa.
-- Como V2 aún está aislada, el rollback integral sigue siendo:
--
--   DROP SCHEMA v2 CASCADE;
--
-- V1 permanecería intacta.
-- ============================================================================
