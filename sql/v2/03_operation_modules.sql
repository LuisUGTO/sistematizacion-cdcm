-- ============================================================================
-- VINCULACIÓN CULTURAL 2.0
-- 03_operation_modules.sql
-- Núcleo operativo y módulos especializados de captura
-- Secretaría de Cultura de Guanajuato
--
-- REQUIERE:
--   01_core_schema.sql
--   02_catalogs.sql
--
-- CREA:
--   v2.registros
--   v2.registro_territorios
--   v2.registro_personas
--   v2.registro_poblacion
--   v2.registro_taller
--   v2.taller_horarios
--   v2.registro_proyecto
--   v2.proyecto_objetivos
--   v2.proyecto_actividades
--   v2.registro_reunion
--   v2.registro_intercambio
--   v2.registro_evidencias
--   v2.registro_validaciones
--
-- MODELO:
--   registro común
--       ├── territorios
--       ├── personas
--       ├── población
--       ├── evidencias
--       ├── validaciones
--       └── detalle especializado
--             ├── taller
--             ├── proyecto
--             ├── reunión
--             └── intercambio
--
-- SEGURIDAD:
--   Todas las tablas nacen con RLS activado.
--   No se conceden todavía permisos a anon/authenticated.
--
-- NO HACE:
--   ✗ no toca V1
--   ✗ no migra históricos
--   ✗ no genera todavía folios
--   ✗ no crea todavía policies finales
--   ✗ no modifica Storage
-- ============================================================================

BEGIN;

SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '120s';

-- ============================================================================
-- 00. PRECONDICIONES
-- ============================================================================

DO $$
BEGIN
  IF to_regclass('v2.cat_unidades_operativas') IS NULL
     OR to_regclass('v2.cat_acciones') IS NULL
     OR to_regclass('v2.cat_tipos_registro') IS NULL
     OR to_regclass('v2.cat_municipios') IS NULL
     OR to_regclass('v2.cat_comunidades') IS NULL
     OR to_regclass('v2.cat_espacios') IS NULL
     OR to_regclass('v2.cat_personas') IS NULL
     OR to_regclass('v2.configuracion_acciones') IS NULL THEN

    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: 02_catalogs.sql no está instalado completamente.';
  END IF;
END
$$;


-- ============================================================================
-- 01. REFUERZO DE INTEGRIDAD CONTEXTUAL DE CATÁLOGOS
-- Permite usar FK compuestas para garantizar que comunidad/espacio pertenezcan
-- al municipio declarado en un registro.
-- ============================================================================

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'uq_v2_comunidad_id_municipio'
      AND conrelid = 'v2.cat_comunidades'::regclass
  ) THEN
    ALTER TABLE v2.cat_comunidades
      ADD CONSTRAINT uq_v2_comunidad_id_municipio
      UNIQUE (id, municipio_id);
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'uq_v2_espacio_id_municipio'
      AND conrelid = 'v2.cat_espacios'::regclass
  ) THEN
    ALTER TABLE v2.cat_espacios
      ADD CONSTRAINT uq_v2_espacio_id_municipio
      UNIQUE (id, municipio_id);
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'uq_v2_accion_id_unidad'
      AND conrelid = 'v2.cat_acciones'::regclass
  ) THEN
    ALTER TABLE v2.cat_acciones
      ADD CONSTRAINT uq_v2_accion_id_unidad
      UNIQUE (id, unidad_operativa_id);
  END IF;
END
$$;


-- Si un espacio declara comunidad, ésta debe pertenecer al mismo municipio.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'fk_v2_espacio_comunidad_municipio'
      AND conrelid = 'v2.cat_espacios'::regclass
  ) THEN
    ALTER TABLE v2.cat_espacios
      ADD CONSTRAINT fk_v2_espacio_comunidad_municipio
      FOREIGN KEY (comunidad_id, municipio_id)
      REFERENCES v2.cat_comunidades (id, municipio_id)
      ON DELETE RESTRICT;
  END IF;
END
$$;


-- ============================================================================
-- 02. REGISTRO NÚCLEO
-- ============================================================================

CREATE TABLE IF NOT EXISTS v2.registros (
  id                        UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Folio humano. Será generado en BD por 05_functions_triggers.sql.
  folio                     TEXT,

  unidad_operativa_id       UUID NOT NULL,
  programa_id               UUID,
  accion_id                 UUID NOT NULL,
  tipo_registro_id          UUID NOT NULL
                            REFERENCES v2.cat_tipos_registro(id)
                            ON DELETE RESTRICT,

  configuracion_accion_id   UUID
                            REFERENCES v2.configuracion_acciones(id)
                            ON DELETE RESTRICT,

  -- Territorio principal. Puede ser NULL para registros estatales/regionales.
  municipio_id              UUID
                            REFERENCES v2.cat_municipios(id)
                            ON DELETE RESTRICT,

  comunidad_id              UUID,
  espacio_id                UUID,

  -- Persona responsable principal, cuando aplique.
  responsable_id            UUID
                            REFERENCES v2.cat_personas(id)
                            ON DELETE SET NULL,

  nombre                    TEXT NOT NULL,
  descripcion               TEXT,

  fecha_inicio              DATE,
  fecha_fin                 DATE,

  periodo_anio              INTEGER NOT NULL
                            DEFAULT EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER
                            CHECK (periodo_anio BETWEEN 2000 AND 2100),

  periodo_mes               SMALLINT
                            CHECK (
                              periodo_mes IS NULL
                              OR periodo_mes BETWEEN 1 AND 12
                            ),

  -- NULL significa "no informado / no aplica todavía".
  -- Cero significa "se reportó explícitamente cero".
  total_beneficiarios       INTEGER
                            CHECK (
                              total_beneficiarios IS NULL
                              OR total_beneficiarios >= 0
                            ),

  estatus                   TEXT NOT NULL DEFAULT 'BORRADOR'
                            CHECK (
                              estatus IN (
                                'BORRADOR',
                                'CAPTURADO',
                                'EN_REVISION',
                                'OBSERVADO',
                                'CORREGIDO',
                                'VALIDADO',
                                'ANULADO'
                              )
                            ),

  origen                    TEXT NOT NULL DEFAULT 'MANUAL'
                            CHECK (
                              origen IN (
                                'MANUAL',
                                'OFFLINE',
                                'IMPORTACION_EXCEL',
                                'MIGRACION_V1',
                                'API'
                              )
                            ),

  -- Trazabilidad de importaciones.
  import_job_id             UUID
                            REFERENCES v2.import_jobs(id)
                            ON DELETE SET NULL,

  archivo_origen            TEXT,
  fila_origen               INTEGER
                            CHECK (
                              fila_origen IS NULL
                              OR fila_origen > 0
                            ),

  -- Referencia histórica sin usarla como identidad V2.
  legacy_folio              TEXT,
  legacy_payload            JSONB NOT NULL DEFAULT '{}'::jsonb,

  metadata                  JSONB NOT NULL DEFAULT '{}'::jsonb,

  -- Control de concurrencia optimista.
  row_version               INTEGER NOT NULL DEFAULT 1
                            CHECK (row_version > 0),

  created_by                UUID REFERENCES auth.users(id) ON DELETE SET NULL
                            DEFAULT auth.uid(),

  updated_by                UUID REFERENCES auth.users(id) ON DELETE SET NULL
                            DEFAULT auth.uid(),

  created_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                TIMESTAMPTZ NOT NULL DEFAULT now(),

  deleted_at                TIMESTAMPTZ,
  deleted_by                UUID REFERENCES auth.users(id) ON DELETE SET NULL,

  CONSTRAINT ck_v2_registro_nombre_no_vacio
    CHECK (btrim(nombre) <> ''),

  CONSTRAINT ck_v2_registro_fechas
    CHECK (
      fecha_fin IS NULL
      OR fecha_inicio IS NULL
      OR fecha_fin >= fecha_inicio
    ),

  CONSTRAINT fk_v2_registro_accion_unidad
    FOREIGN KEY (accion_id, unidad_operativa_id)
    REFERENCES v2.cat_acciones (id, unidad_operativa_id)
    ON DELETE RESTRICT,

  CONSTRAINT fk_v2_registro_programa_unidad
    FOREIGN KEY (programa_id, unidad_operativa_id)
    REFERENCES v2.cat_programas (id, unidad_operativa_id)
    ON DELETE RESTRICT,

  CONSTRAINT fk_v2_registro_comunidad_municipio
    FOREIGN KEY (comunidad_id, municipio_id)
    REFERENCES v2.cat_comunidades (id, municipio_id)
    ON DELETE RESTRICT,

  CONSTRAINT fk_v2_registro_espacio_municipio
    FOREIGN KEY (espacio_id, municipio_id)
    REFERENCES v2.cat_espacios (id, municipio_id)
    ON DELETE RESTRICT
);

COMMENT ON TABLE v2.registros IS
'Núcleo común de toda captura operativa de Vinculación Cultural V2.';

COMMENT ON COLUMN v2.registros.id IS
'UUID técnico estable. Puede ser generado en cliente offline y enviado a PostgreSQL.';

COMMENT ON COLUMN v2.registros.folio IS
'Folio humano único generado por PostgreSQL. No es la PK técnica.';

COMMENT ON COLUMN v2.registros.total_beneficiarios IS
'Total oficial reportado. No se calcula sumando dimensiones demográficas distintas.';

COMMENT ON COLUMN v2.registros.legacy_folio IS
'Folio V1 original, si existe, conservado únicamente para trazabilidad histórica.';


CREATE UNIQUE INDEX IF NOT EXISTS uq_v2_registros_folio
  ON v2.registros (folio)
  WHERE folio IS NOT NULL AND btrim(folio) <> '';

-- Evita duplicar una misma fila confirmada del mismo trabajo de importación.
CREATE UNIQUE INDEX IF NOT EXISTS uq_v2_registros_import_job_fila
  ON v2.registros (import_job_id, fila_origen)
  WHERE import_job_id IS NOT NULL AND fila_origen IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_v2_registros_unidad
  ON v2.registros (unidad_operativa_id, estatus, periodo_anio);

CREATE INDEX IF NOT EXISTS idx_v2_registros_accion
  ON v2.registros (accion_id, periodo_anio, estatus);

CREATE INDEX IF NOT EXISTS idx_v2_registros_municipio
  ON v2.registros (municipio_id, periodo_anio, estatus);

CREATE INDEX IF NOT EXISTS idx_v2_registros_created_by
  ON v2.registros (created_by, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_v2_registros_created_at
  ON v2.registros (created_at DESC);

CREATE INDEX IF NOT EXISTS idx_v2_registros_validacion
  ON v2.registros (estatus, updated_at DESC);


-- ============================================================================
-- 03. COBERTURA TERRITORIAL ADICIONAL
--
-- El municipio/comunidad/espacio en v2.registros representa la ubicación
-- principal. Esta tabla permite proyectos regionales o actividades con
-- múltiples municipios/comunidades.
-- ============================================================================

CREATE TABLE IF NOT EXISTS v2.registro_territorios (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  registro_id           UUID NOT NULL
                        REFERENCES v2.registros(id)
                        ON DELETE CASCADE,

  municipio_id          UUID NOT NULL
                        REFERENCES v2.cat_municipios(id)
                        ON DELETE RESTRICT,

  comunidad_id          UUID,
  espacio_id            UUID,

  es_principal          BOOLEAN NOT NULL DEFAULT false,

  beneficiarios         INTEGER
                        CHECK (
                          beneficiarios IS NULL
                          OR beneficiarios >= 0
                        ),

  observaciones         TEXT,

  created_by            UUID REFERENCES auth.users(id) ON DELETE SET NULL
                        DEFAULT auth.uid(),

  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT fk_v2_registro_territorio_comunidad
    FOREIGN KEY (comunidad_id, municipio_id)
    REFERENCES v2.cat_comunidades (id, municipio_id)
    ON DELETE RESTRICT,

  CONSTRAINT fk_v2_registro_territorio_espacio
    FOREIGN KEY (espacio_id, municipio_id)
    REFERENCES v2.cat_espacios (id, municipio_id)
    ON DELETE RESTRICT
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_v2_registro_territorio_contexto
  ON v2.registro_territorios (
    registro_id,
    municipio_id,
    COALESCE(
      comunidad_id,
      '00000000-0000-0000-0000-000000000000'::uuid
    ),
    COALESCE(
      espacio_id,
      '00000000-0000-0000-0000-000000000000'::uuid
    )
  );

-- Solo un territorio adicional puede marcarse como principal.
CREATE UNIQUE INDEX IF NOT EXISTS uq_v2_registro_territorio_principal
  ON v2.registro_territorios (registro_id)
  WHERE es_principal = true;

CREATE INDEX IF NOT EXISTS idx_v2_registro_territorios_municipio
  ON v2.registro_territorios (municipio_id, registro_id);


-- ============================================================================
-- 04. PERSONAS RELACIONADAS AL REGISTRO
--
-- Permite más de un docente, responsable, bibliotecario, enlace, etc.
-- ============================================================================

CREATE TABLE IF NOT EXISTS v2.registro_personas (
  registro_id           UUID NOT NULL
                        REFERENCES v2.registros(id)
                        ON DELETE CASCADE,

  persona_id            UUID NOT NULL
                        REFERENCES v2.cat_personas(id)
                        ON DELETE RESTRICT,

  funcion_id            UUID NOT NULL
                        REFERENCES v2.cat_funciones(id)
                        ON DELETE RESTRICT,

  es_principal          BOOLEAN NOT NULL DEFAULT false,
  observaciones         TEXT,

  created_by            UUID REFERENCES auth.users(id) ON DELETE SET NULL
                        DEFAULT auth.uid(),

  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),

  PRIMARY KEY (registro_id, persona_id, funcion_id)
);

CREATE INDEX IF NOT EXISTS idx_v2_registro_personas_persona
  ON v2.registro_personas (persona_id, funcion_id);

CREATE INDEX IF NOT EXISTS idx_v2_registro_personas_registro
  ON v2.registro_personas (registro_id);


-- ============================================================================
-- 05. POBLACIÓN DESAGREGADA
-- ============================================================================

CREATE TABLE IF NOT EXISTS v2.registro_poblacion (
  registro_id           UUID NOT NULL
                        REFERENCES v2.registros(id)
                        ON DELETE CASCADE,

  opcion_poblacion_id   UUID NOT NULL
                        REFERENCES v2.cat_opciones_poblacion(id)
                        ON DELETE RESTRICT,

  cantidad              INTEGER NOT NULL
                        CHECK (cantidad >= 0),

  observaciones         TEXT,

  created_by            UUID REFERENCES auth.users(id) ON DELETE SET NULL
                        DEFAULT auth.uid(),

  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),

  PRIMARY KEY (registro_id, opcion_poblacion_id)
);

COMMENT ON TABLE v2.registro_poblacion IS
'Desagregaciones poblacionales. No deben sumarse entre dimensiones diferentes para obtener el total.';

CREATE INDEX IF NOT EXISTS idx_v2_registro_poblacion_opcion
  ON v2.registro_poblacion (opcion_poblacion_id, registro_id);


-- ============================================================================
-- 06. MÓDULO TALLER / FORMACIÓN
-- ============================================================================

CREATE TABLE IF NOT EXISTS v2.registro_taller (
  registro_id           UUID PRIMARY KEY
                        REFERENCES v2.registros(id)
                        ON DELETE CASCADE,

  disciplina            TEXT,
  programacion          TEXT,

  modalidad_cuota       TEXT,

  costo                 NUMERIC(14,2)
                        CHECK (costo IS NULL OR costo >= 0),

  moneda                CHAR(3) NOT NULL DEFAULT 'MXN',

  observaciones         TEXT,

  created_by            UUID REFERENCES auth.users(id) ON DELETE SET NULL
                        DEFAULT auth.uid(),

  updated_by            UUID REFERENCES auth.users(id) ON DELETE SET NULL
                        DEFAULT auth.uid(),

  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE v2.registro_taller IS
'Detalle especializado para talleres, cursos de verano, capacitaciones y procesos de formación.';


CREATE TABLE IF NOT EXISTS v2.taller_horarios (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  registro_id           UUID NOT NULL
                        REFERENCES v2.registro_taller(registro_id)
                        ON DELETE CASCADE,

  -- ISO: 1=Lunes ... 7=Domingo
  dia_semana            SMALLINT NOT NULL
                        CHECK (dia_semana BETWEEN 1 AND 7),

  hora_inicio           TIME,
  hora_fin              TIME,

  observaciones         TEXT,

  created_by            UUID REFERENCES auth.users(id) ON DELETE SET NULL
                        DEFAULT auth.uid(),

  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT ck_v2_taller_horario_horas
    CHECK (
      hora_fin IS NULL
      OR hora_inicio IS NULL
      OR hora_fin > hora_inicio
    )
);

CREATE INDEX IF NOT EXISTS idx_v2_taller_horarios_registro
  ON v2.taller_horarios (registro_id, dia_semana);


-- ============================================================================
-- 07. MÓDULO PROYECTOS
-- ============================================================================

CREATE TABLE IF NOT EXISTS v2.registro_proyecto (
  registro_id               UUID PRIMARY KEY
                            REFERENCES v2.registros(id)
                            ON DELETE CASCADE,

  justificacion             TEXT,
  descripcion_problematica  TEXT,
  poblacion_objetivo        TEXT,
  resultado_general         TEXT,

  created_by                UUID REFERENCES auth.users(id) ON DELETE SET NULL
                            DEFAULT auth.uid(),

  updated_by                UUID REFERENCES auth.users(id) ON DELETE SET NULL
                            DEFAULT auth.uid(),

  created_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE v2.registro_proyecto IS
'Detalle especializado para proyecto sociocultural, de circuito o regional.';


CREATE TABLE IF NOT EXISTS v2.proyecto_objetivos (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  registro_id           UUID NOT NULL
                        REFERENCES v2.registro_proyecto(registro_id)
                        ON DELETE CASCADE,

  tipo                  TEXT NOT NULL
                        CHECK (
                          tipo IN (
                            'GENERAL',
                            'ESPECIFICO'
                          )
                        ),

  objetivo              TEXT NOT NULL,
  orden                 INTEGER NOT NULL DEFAULT 0 CHECK (orden >= 0),

  activo                BOOLEAN NOT NULL DEFAULT true,

  created_by            UUID REFERENCES auth.users(id) ON DELETE SET NULL
                        DEFAULT auth.uid(),

  updated_by            UUID REFERENCES auth.users(id) ON DELETE SET NULL
                        DEFAULT auth.uid(),

  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT ck_v2_proyecto_objetivo_no_vacio
    CHECK (btrim(objetivo) <> '')
);

-- Máximo un objetivo general activo por proyecto.
CREATE UNIQUE INDEX IF NOT EXISTS uq_v2_proyecto_objetivo_general
  ON v2.proyecto_objetivos (registro_id)
  WHERE tipo = 'GENERAL' AND activo = true;

CREATE INDEX IF NOT EXISTS idx_v2_proyecto_objetivos
  ON v2.proyecto_objetivos (registro_id, tipo, orden);


CREATE TABLE IF NOT EXISTS v2.proyecto_actividades (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  registro_id           UUID NOT NULL
                        REFERENCES v2.registro_proyecto(registro_id)
                        ON DELETE CASCADE,

  nombre                TEXT NOT NULL,
  descripcion           TEXT,

  fecha_inicio          DATE,
  fecha_fin             DATE,

  estatus               TEXT NOT NULL DEFAULT 'PLANEADA'
                        CHECK (
                          estatus IN (
                            'PLANEADA',
                            'EN_PROCESO',
                            'REALIZADA',
                            'CANCELADA'
                          )
                        ),

  resultado             TEXT,
  orden                 INTEGER NOT NULL DEFAULT 0 CHECK (orden >= 0),

  activo                BOOLEAN NOT NULL DEFAULT true,

  created_by            UUID REFERENCES auth.users(id) ON DELETE SET NULL
                        DEFAULT auth.uid(),

  updated_by            UUID REFERENCES auth.users(id) ON DELETE SET NULL
                        DEFAULT auth.uid(),

  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT ck_v2_proyecto_actividad_nombre_no_vacio
    CHECK (btrim(nombre) <> ''),

  CONSTRAINT ck_v2_proyecto_actividad_fechas
    CHECK (
      fecha_fin IS NULL
      OR fecha_inicio IS NULL
      OR fecha_fin >= fecha_inicio
    )
);

CREATE INDEX IF NOT EXISTS idx_v2_proyecto_actividades
  ON v2.proyecto_actividades (
    registro_id,
    estatus,
    orden
  );


-- ============================================================================
-- 08. MÓDULO REUNIONES
-- ============================================================================

CREATE TABLE IF NOT EXISTS v2.registro_reunion (
  registro_id           UUID PRIMARY KEY
                        REFERENCES v2.registros(id)
                        ON DELETE CASCADE,

  tema                  TEXT,
  acuerdos              TEXT,

  numero_participantes  INTEGER
                        CHECK (
                          numero_participantes IS NULL
                          OR numero_participantes >= 0
                        ),

  created_by            UUID REFERENCES auth.users(id) ON DELETE SET NULL
                        DEFAULT auth.uid(),

  updated_by            UUID REFERENCES auth.users(id) ON DELETE SET NULL
                        DEFAULT auth.uid(),

  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);


-- ============================================================================
-- 09. MÓDULO INTERCAMBIOS
-- ============================================================================

CREATE TABLE IF NOT EXISTS v2.registro_intercambio (
  registro_id           UUID PRIMARY KEY
                        REFERENCES v2.registros(id)
                        ON DELETE CASCADE,

  movimiento            TEXT NOT NULL
                        CHECK (
                          movimiento IN (
                            'ENVIADO',
                            'RECIBIDO',
                            'AMBOS'
                          )
                        ),

  municipio_origen_id   UUID
                        REFERENCES v2.cat_municipios(id)
                        ON DELETE RESTRICT,

  municipio_destino_id  UUID
                        REFERENCES v2.cat_municipios(id)
                        ON DELETE RESTRICT,

  -- Para intercambios fuera del catálogo estatal.
  origen_externo        TEXT,
  destino_externo       TEXT,

  descripcion           TEXT,
  resultado             TEXT,

  created_by            UUID REFERENCES auth.users(id) ON DELETE SET NULL
                        DEFAULT auth.uid(),

  updated_by            UUID REFERENCES auth.users(id) ON DELETE SET NULL
                        DEFAULT auth.uid(),

  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT ck_v2_intercambio_origen
    CHECK (
      municipio_origen_id IS NOT NULL
      OR NULLIF(btrim(origen_externo), '') IS NOT NULL
    ),

  CONSTRAINT ck_v2_intercambio_destino
    CHECK (
      municipio_destino_id IS NOT NULL
      OR NULLIF(btrim(destino_externo), '') IS NOT NULL
    )
);


-- ============================================================================
-- 10. EVIDENCIAS
-- ============================================================================

CREATE TABLE IF NOT EXISTS v2.registro_evidencias (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  registro_id           UUID NOT NULL
                        REFERENCES v2.registros(id)
                        ON DELETE CASCADE,

  tipo_evidencia        TEXT NOT NULL DEFAULT 'FOTOGRAFIA',

  storage_path          TEXT NOT NULL,
  nombre_original       TEXT,
  mime_type             TEXT,
  size_bytes            BIGINT
                        CHECK (
                          size_bytes IS NULL
                          OR size_bytes >= 0
                        ),

  metadata              JSONB NOT NULL DEFAULT '{}'::jsonb,

  activo                BOOLEAN NOT NULL DEFAULT true,

  uploaded_by           UUID REFERENCES auth.users(id) ON DELETE SET NULL
                        DEFAULT auth.uid(),

  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT ck_v2_evidencia_path_no_vacio
    CHECK (btrim(storage_path) <> '')
);

COMMENT ON TABLE v2.registro_evidencias IS
'Metadatos de evidencias privadas. storage_path es canónico; no se guardan Signed URLs permanentes.';

CREATE UNIQUE INDEX IF NOT EXISTS uq_v2_evidencia_storage_path
  ON v2.registro_evidencias (storage_path);

CREATE INDEX IF NOT EXISTS idx_v2_evidencias_registro
  ON v2.registro_evidencias (registro_id, activo, created_at DESC);


-- ============================================================================
-- 11. HISTORIAL DE VALIDACIÓN
-- ============================================================================

CREATE TABLE IF NOT EXISTS v2.registro_validaciones (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  registro_id           UUID NOT NULL
                        REFERENCES v2.registros(id)
                        ON DELETE CASCADE,

  estatus_anterior      TEXT
                        CHECK (
                          estatus_anterior IS NULL
                          OR estatus_anterior IN (
                            'BORRADOR',
                            'CAPTURADO',
                            'EN_REVISION',
                            'OBSERVADO',
                            'CORREGIDO',
                            'VALIDADO',
                            'ANULADO'
                          )
                        ),

  estatus_nuevo         TEXT NOT NULL
                        CHECK (
                          estatus_nuevo IN (
                            'BORRADOR',
                            'CAPTURADO',
                            'EN_REVISION',
                            'OBSERVADO',
                            'CORREGIDO',
                            'VALIDADO',
                            'ANULADO'
                          )
                        ),

  observacion           TEXT,

  usuario_id            UUID REFERENCES auth.users(id) ON DELETE SET NULL
                        DEFAULT auth.uid(),

  created_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE v2.registro_validaciones IS
'Historial inmutable de transiciones del flujo institucional de revisión y validación.';

CREATE INDEX IF NOT EXISTS idx_v2_validaciones_registro
  ON v2.registro_validaciones (registro_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_v2_validaciones_usuario
  ON v2.registro_validaciones (usuario_id, created_at DESC);


-- ============================================================================
-- 12. SEGURIDAD: RLS + DENY BY DEFAULT
-- ============================================================================

DO $$
DECLARE
  tbl TEXT;
BEGIN
  FOREACH tbl IN ARRAY ARRAY[
    'registros',
    'registro_territorios',
    'registro_personas',
    'registro_poblacion',
    'registro_taller',
    'taller_horarios',
    'registro_proyecto',
    'proyecto_objetivos',
    'proyecto_actividades',
    'registro_reunion',
    'registro_intercambio',
    'registro_evidencias',
    'registro_validaciones'
  ]
  LOOP
    EXECUTE format(
      'ALTER TABLE v2.%I ENABLE ROW LEVEL SECURITY',
      tbl
    );

    EXECUTE format(
      'REVOKE ALL ON TABLE v2.%I FROM PUBLIC',
      tbl
    );

    EXECUTE format(
      'REVOKE ALL ON TABLE v2.%I FROM anon',
      tbl
    );

    EXECUTE format(
      'REVOKE ALL ON TABLE v2.%I FROM authenticated',
      tbl
    );
  END LOOP;
END
$$;


-- ============================================================================
-- 13. REGISTRO DE MIGRACIÓN
-- ============================================================================

INSERT INTO v2.schema_migrations (
  version,
  descripcion
)
VALUES (
  '2.1.03',
  '03_operation_modules.sql - Registro núcleo, territorio, población, personas, módulos operativos, evidencias y validación.'
)
ON CONFLICT (version) DO NOTHING;


COMMIT;


-- ============================================================================
-- 14. VERIFICACIÓN POST-INSTALACIÓN
-- ============================================================================

WITH tablas_esperadas(nombre) AS (
  VALUES
    ('registros'),
    ('registro_territorios'),
    ('registro_personas'),
    ('registro_poblacion'),
    ('registro_taller'),
    ('taller_horarios'),
    ('registro_proyecto'),
    ('proyecto_objetivos'),
    ('proyecto_actividades'),
    ('registro_reunion'),
    ('registro_intercambio'),
    ('registro_evidencias'),
    ('registro_validaciones')
)
SELECT
  'V2.1 - 03_operation_modules' AS instalacion,

  (
    SELECT count(*)
    FROM tablas_esperadas te
    WHERE to_regclass('v2.' || te.nombre) IS NOT NULL
  ) AS tablas_operativas_creadas,

  (
    SELECT count(*)
    FROM tablas_esperadas te
    JOIN pg_class c
      ON c.oid = to_regclass('v2.' || te.nombre)
    WHERE c.relrowsecurity = true
  ) AS tablas_operativas_con_rls,

  (
    SELECT count(*)
    FROM v2.schema_migrations
    WHERE version = '2.1.03'
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
-- tablas_operativas_creadas   = 13
-- tablas_operativas_con_rls   = 13
-- migracion_registrada        = 1
-- total_tablas_v2             = 39
--
-- Después de este paso:
--
--   01 Core         ✓
--   02 Catálogos    ✓
--   03 Operación    ✓
--
-- Próximo archivo:
--   04_indicators.sql
--
-- NOTA:
-- Todavía no debe haber captura productiva en V2.
-- Los permisos siguen cerrados.
-- ============================================================================
