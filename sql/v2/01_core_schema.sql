-- ============================================================================
-- VINCULACIÓN CULTURAL 2.0
-- 01_core_schema.sql
-- Fundación del esquema V2
-- Secretaría de Cultura de Guanajuato
--
-- PROPÓSITO:
--   Crear una base V2 aislada de la V1 actual.
--
-- ESTE SCRIPT:
--   ✓ crea el schema v2
--   ✓ crea perfiles V2
--   ✓ crea control de versiones
--   ✓ crea auditoría base
--   ✓ crea infraestructura de importaciones/staging
--   ✓ activa RLS explícitamente en todo lo creado
--   ✓ aplica seguridad "deny by default"
--
-- ESTE SCRIPT NO:
--   ✗ elimina ni altera public.registros_culturales
--   ✗ elimina ni altera public.profiles
--   ✗ elimina ni altera cat_docentes / cat_bibliotecas V1
--   ✗ modifica auth.users
--   ✗ modifica Storage
--   ✗ cambia las policies V1
--   ✗ migra todavía los 317 registros históricos
--
-- REQUISITO:
--   Haber ejecutado y revisado los tres preflight 00_*.
-- ============================================================================

BEGIN;

-- Evita esperas indefinidas si existiera algún bloqueo accidental.
SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '60s';

-- ============================================================================
-- 00. PRECONDICIONES
-- ============================================================================

DO $$
BEGIN
  IF to_regclass('auth.users') IS NULL THEN
    RAISE EXCEPTION 'PRECONDICIÓN FALLIDA: auth.users no existe.';
  END IF;

  IF to_regprocedure('gen_random_uuid()') IS NULL THEN
    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: gen_random_uuid() no está disponible.';
  END IF;
END
$$;


-- ============================================================================
-- 01. SCHEMA V2
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS v2;

COMMENT ON SCHEMA v2 IS
'Vinculación Cultural 2.0. Esquema aislado de la V1 durante la migración controlada.';

-- Seguridad por defecto:
-- ninguna sesión anónima obtiene acceso al nuevo schema.
REVOKE ALL ON SCHEMA v2 FROM PUBLIC;
REVOKE ALL ON SCHEMA v2 FROM anon;

-- No otorgamos todavía acceso aplicativo a authenticated.
-- Eso se hará de forma explícita en 06_rls.sql cuando las policies estén listas.


-- ============================================================================
-- 02. CONTROL DE VERSIONES DEL ESQUEMA
-- ============================================================================

CREATE TABLE IF NOT EXISTS v2.schema_migrations (
  version           TEXT PRIMARY KEY,
  descripcion       TEXT NOT NULL,
  ejecutado_en      TIMESTAMPTZ NOT NULL DEFAULT now(),
  ejecutado_por     TEXT NOT NULL DEFAULT current_user
);

COMMENT ON TABLE v2.schema_migrations IS
'Registro interno de versiones SQL instaladas en Vinculación Cultural V2.';

ALTER TABLE v2.schema_migrations ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE v2.schema_migrations FROM PUBLIC;
REVOKE ALL ON TABLE v2.schema_migrations FROM anon;
REVOKE ALL ON TABLE v2.schema_migrations FROM authenticated;


-- ============================================================================
-- 03. PROFILES V2
--
-- V1 public.profiles permanece intacta.
-- El trigger actual de auth.users seguirá alimentando V1 durante la transición.
-- La sincronización inicial hacia v2.profiles se hará posteriormente.
-- ============================================================================

CREATE TABLE IF NOT EXISTS v2.profiles (
  user_id           UUID PRIMARY KEY
                    REFERENCES auth.users(id) ON DELETE CASCADE,

  email             TEXT NOT NULL,
  nombre            TEXT,

  rol               TEXT NOT NULL DEFAULT 'CAPTURISTA'
                    CHECK (
                      rol IN (
                        'ADMIN',
                        'SUPERVISOR',
                        'DIRECTIVO',
                        'CAPTURISTA'
                      )
                    ),

  activo            BOOLEAN NOT NULL DEFAULT true,

  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE v2.profiles IS
'Perfiles y roles de Vinculación Cultural V2. No sustituye public.profiles hasta el corte final.';

COMMENT ON COLUMN v2.profiles.rol IS
'Rol aplicativo V2: ADMIN, SUPERVISOR, DIRECTIVO o CAPTURISTA.';

ALTER TABLE v2.profiles ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE v2.profiles FROM PUBLIC;
REVOKE ALL ON TABLE v2.profiles FROM anon;
REVOKE ALL ON TABLE v2.profiles FROM authenticated;

CREATE INDEX IF NOT EXISTS idx_v2_profiles_email
  ON v2.profiles (lower(email));

CREATE INDEX IF NOT EXISTS idx_v2_profiles_rol_activo
  ON v2.profiles (rol, activo);


-- ============================================================================
-- 04. AUDITORÍA BASE
--
-- La tabla existe desde el inicio aunque los triggers de auditoría se instalarán
-- en 05_functions_triggers.sql.
-- ============================================================================

CREATE TABLE IF NOT EXISTS v2.audit_log (
  id                BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

  schema_name       TEXT NOT NULL DEFAULT 'v2',
  table_name        TEXT NOT NULL,
  record_id         TEXT,

  accion            TEXT NOT NULL
                    CHECK (
                      accion IN (
                        'INSERT',
                        'UPDATE',
                        'STATUS_CHANGE',
                        'VALIDATE',
                        'OBSERVE',
                        'ANNUL',
                        'IMPORT',
                        'ROLE_CHANGE',
                        'CATALOG_CHANGE',
                        'EVIDENCE_CHANGE',
                        'LOGIN_RELATED'
                      )
                    ),

  user_id           UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  user_email        TEXT,

  valor_anterior    JSONB,
  valor_nuevo       JSONB,
  metadata          JSONB NOT NULL DEFAULT '{}'::jsonb,

  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE v2.audit_log IS
'Bitácora inmutable de operaciones críticas de Vinculación Cultural V2.';

ALTER TABLE v2.audit_log ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE v2.audit_log FROM PUBLIC;
REVOKE ALL ON TABLE v2.audit_log FROM anon;
REVOKE ALL ON TABLE v2.audit_log FROM authenticated;

CREATE INDEX IF NOT EXISTS idx_v2_audit_created_at
  ON v2.audit_log (created_at DESC);

CREATE INDEX IF NOT EXISTS idx_v2_audit_table_record
  ON v2.audit_log (table_name, record_id);

CREATE INDEX IF NOT EXISTS idx_v2_audit_user
  ON v2.audit_log (user_id, created_at DESC);


-- ============================================================================
-- 05. TRABAJOS DE IMPORTACIÓN
-- ============================================================================

CREATE TABLE IF NOT EXISTS v2.import_jobs (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  tipo_importacion  TEXT NOT NULL,
  archivo_nombre    TEXT NOT NULL,
  storage_path      TEXT,

  usuario_id        UUID REFERENCES auth.users(id) ON DELETE SET NULL,

  estatus           TEXT NOT NULL DEFAULT 'CREADO'
                    CHECK (
                      estatus IN (
                        'CREADO',
                        'LEYENDO',
                        'VALIDANDO',
                        'LISTO',
                        'IMPORTANDO',
                        'COMPLETADO',
                        'COMPLETADO_CON_ERRORES',
                        'ERROR',
                        'CANCELADO'
                      )
                    ),

  total_filas       INTEGER NOT NULL DEFAULT 0 CHECK (total_filas >= 0),
  filas_validas     INTEGER NOT NULL DEFAULT 0 CHECK (filas_validas >= 0),
  filas_error       INTEGER NOT NULL DEFAULT 0 CHECK (filas_error >= 0),
  filas_duplicadas  INTEGER NOT NULL DEFAULT 0 CHECK (filas_duplicadas >= 0),
  filas_importadas  INTEGER NOT NULL DEFAULT 0 CHECK (filas_importadas >= 0),

  metadata          JSONB NOT NULL DEFAULT '{}'::jsonb,

  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at      TIMESTAMPTZ
);

COMMENT ON TABLE v2.import_jobs IS
'Cabecera de cada carga Excel/CSV realizada mediante el proceso controlado de importación V2.';

ALTER TABLE v2.import_jobs ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE v2.import_jobs FROM PUBLIC;
REVOKE ALL ON TABLE v2.import_jobs FROM anon;
REVOKE ALL ON TABLE v2.import_jobs FROM authenticated;

CREATE INDEX IF NOT EXISTS idx_v2_import_jobs_usuario
  ON v2.import_jobs (usuario_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_v2_import_jobs_estatus
  ON v2.import_jobs (estatus, created_at DESC);


-- ============================================================================
-- 06. STAGING DE IMPORTACIONES
--
-- raw_data        = fila exactamente como fue interpretada
-- normalized_data = fila después de aliases / limpieza
-- errores         = lista estructurada de problemas
-- ============================================================================

CREATE TABLE IF NOT EXISTS v2.import_staging (
  id                BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

  import_job_id     UUID NOT NULL
                    REFERENCES v2.import_jobs(id) ON DELETE CASCADE,

  numero_fila       INTEGER NOT NULL CHECK (numero_fila > 0),

  raw_data          JSONB NOT NULL,
  normalized_data   JSONB,

  estatus           TEXT NOT NULL DEFAULT 'PENDIENTE'
                    CHECK (
                      estatus IN (
                        'PENDIENTE',
                        'VALIDO',
                        'ERROR',
                        'DUPLICADO',
                        'IMPORTADO',
                        'OMITIDO'
                      )
                    ),

  errores           JSONB NOT NULL DEFAULT '[]'::jsonb,

  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT uq_v2_import_staging_job_fila
    UNIQUE (import_job_id, numero_fila)
);

COMMENT ON TABLE v2.import_staging IS
'Filas temporales de importación antes de entrar a tablas productivas V2.';

ALTER TABLE v2.import_staging ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE v2.import_staging FROM PUBLIC;
REVOKE ALL ON TABLE v2.import_staging FROM anon;
REVOKE ALL ON TABLE v2.import_staging FROM authenticated;

CREATE INDEX IF NOT EXISTS idx_v2_import_staging_job_status
  ON v2.import_staging (import_job_id, estatus);


-- ============================================================================
-- 07. RESERVA DE FOLIOS
--
-- No genera todavía el folio final; prepara un contador atómico por ejercicio.
-- La función generadora se instalará en 05_functions_triggers.sql.
-- ============================================================================

CREATE TABLE IF NOT EXISTS v2.folio_sequences (
  ejercicio         INTEGER PRIMARY KEY
                    CHECK (ejercicio BETWEEN 2020 AND 2100),

  ultimo_numero     BIGINT NOT NULL DEFAULT 0
                    CHECK (ultimo_numero >= 0),

  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE v2.folio_sequences IS
'Contador transaccional por ejercicio para folios institucionales V2.';

ALTER TABLE v2.folio_sequences ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE v2.folio_sequences FROM PUBLIC;
REVOKE ALL ON TABLE v2.folio_sequences FROM anon;
REVOKE ALL ON TABLE v2.folio_sequences FROM authenticated;


-- ============================================================================
-- 08. DEFAULT PRIVILEGES DEL SCHEMA V2
--
-- Las futuras tablas creadas por el mismo propietario no deben quedar
-- accidentalmente disponibles para PUBLIC/anon/authenticated.
-- 06_rls.sql concederá únicamente lo necesario.
-- ============================================================================

ALTER DEFAULT PRIVILEGES IN SCHEMA v2
  REVOKE ALL ON TABLES FROM PUBLIC;

ALTER DEFAULT PRIVILEGES IN SCHEMA v2
  REVOKE ALL ON TABLES FROM anon;

ALTER DEFAULT PRIVILEGES IN SCHEMA v2
  REVOKE ALL ON TABLES FROM authenticated;

ALTER DEFAULT PRIVILEGES IN SCHEMA v2
  REVOKE ALL ON SEQUENCES FROM PUBLIC;

ALTER DEFAULT PRIVILEGES IN SCHEMA v2
  REVOKE ALL ON SEQUENCES FROM anon;

ALTER DEFAULT PRIVILEGES IN SCHEMA v2
  REVOKE ALL ON SEQUENCES FROM authenticated;

ALTER DEFAULT PRIVILEGES IN SCHEMA v2
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

ALTER DEFAULT PRIVILEGES IN SCHEMA v2
  REVOKE EXECUTE ON FUNCTIONS FROM anon;

ALTER DEFAULT PRIVILEGES IN SCHEMA v2
  REVOKE EXECUTE ON FUNCTIONS FROM authenticated;


-- ============================================================================
-- 09. REGISTRO DE MIGRACIÓN
-- ============================================================================

INSERT INTO v2.schema_migrations (
  version,
  descripcion
)
VALUES (
  '2.1.01',
  '01_core_schema.sql - Fundación V2: profiles, auditoría, importaciones y folios.'
)
ON CONFLICT (version) DO NOTHING;


COMMIT;


-- ============================================================================
-- 10. VERIFICACIÓN POST-INSTALACIÓN
-- Esta consulta solo muestra lo creado.
-- ============================================================================

SELECT
  'V2.1 CORE - 01_core_schema' AS instalacion,
  EXISTS (
    SELECT 1
    FROM information_schema.schemata
    WHERE schema_name = 'v2'
  ) AS schema_v2_existe,

  (
    SELECT count(*)
    FROM information_schema.tables
    WHERE table_schema = 'v2'
      AND table_type = 'BASE TABLE'
  ) AS tablas_v2,

  (
    SELECT count(*)
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'v2'
      AND c.relkind = 'r'
      AND c.relrowsecurity = true
  ) AS tablas_v2_con_rls,

  (
    SELECT count(*)
    FROM v2.schema_migrations
    WHERE version = '2.1.01'
  ) AS migracion_registrada;


-- ============================================================================
-- RESULTADO ESPERADO EN PRIMERA EJECUCIÓN:
--
-- schema_v2_existe       = true
-- tablas_v2              = 6
-- tablas_v2_con_rls      = 6
-- migracion_registrada   = 1
--
-- TABLAS CREADAS:
--   v2.schema_migrations
--   v2.profiles
--   v2.audit_log
--   v2.import_jobs
--   v2.import_staging
--   v2.folio_sequences
--
-- ROLLBACK DE EMERGENCIA (NO EJECUTAR salvo que se decida descartar V2
-- antes de crear dependencias posteriores):
--
--   DROP SCHEMA v2 CASCADE;
--
-- V1 permanecería intacta.
-- ============================================================================
