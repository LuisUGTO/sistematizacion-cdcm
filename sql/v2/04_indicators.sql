-- ============================================================================
-- VINCULACIÓN CULTURAL 2.0
-- 04_indicators.sql
-- Indicadores, versiones, metas y reglas de aporte
-- Secretaría de Cultura de Guanajuato
--
-- REQUIERE:
--   01_core_schema.sql
--   02_catalogs.sql
--   03_operation_modules.sql
--
-- CREA:
--   v2.cat_indicadores
--   v2.indicadores_version
--   v2.metas_indicador
--   v2.accion_indicador
--   v2.registro_indicador_aportes
--
-- OBJETIVO:
--   Separar el indicador conceptual de su versión anual y permitir que
--   una acción institucional determine automáticamente a qué indicador aporta.
--
-- EJEMPLO:
--
--   Indicador conceptual:
--     "Reuniones de trabajo colaborativo"
--
--   Versión 2025:
--     clave = X2025
--     unidad = Acción
--
--   Versión 2026:
--     clave = X2026
--     unidad = Acción
--
--   El frontend NO tendrá que programarse nuevamente por cada ejercicio.
--
-- SEGURIDAD:
--   Todas las tablas nacen con RLS habilitado y deny-by-default.
--
-- NO HACE:
--   ✗ no toca V1
--   ✗ no crea todavía dashboard/views
--   ✗ no calcula todavía avances automáticamente
--   ✗ no carga indicadores reales 2025/2026
--   ✗ no crea policies finales
-- ============================================================================

BEGIN;

SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '120s';

-- ============================================================================
-- 00. PRECONDICIONES
-- ============================================================================

DO $$
BEGIN
  IF to_regclass('v2.cat_acciones') IS NULL
     OR to_regclass('v2.cat_unidades_medida') IS NULL
     OR to_regclass('v2.cat_unidades_operativas') IS NULL
     OR to_regclass('v2.cat_regiones') IS NULL
     OR to_regclass('v2.cat_municipios') IS NULL
     OR to_regclass('v2.registros') IS NULL THEN

    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: faltan objetos de 02_catalogs.sql o 03_operation_modules.sql.';
  END IF;
END
$$;


-- ============================================================================
-- 01. CATÁLOGO CONCEPTUAL DE INDICADORES
--
-- Esta tabla representa la identidad estable del indicador.
-- No guarda aún la clave anual ni meta anual.
-- ============================================================================

CREATE TABLE IF NOT EXISTS v2.cat_indicadores (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  clave_interna     TEXT NOT NULL,
  nombre_base       TEXT NOT NULL,
  descripcion       TEXT,

  unidad_operativa_id UUID
                    REFERENCES v2.cat_unidades_operativas(id)
                    ON DELETE RESTRICT,

  activo            BOOLEAN NOT NULL DEFAULT true,

  created_by        UUID REFERENCES auth.users(id) ON DELETE SET NULL
                    DEFAULT auth.uid(),

  updated_by        UUID REFERENCES auth.users(id) ON DELETE SET NULL
                    DEFAULT auth.uid(),

  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT ck_v2_indicador_clave_interna_no_vacia
    CHECK (btrim(clave_interna) <> ''),

  CONSTRAINT ck_v2_indicador_nombre_base_no_vacio
    CHECK (btrim(nombre_base) <> '')
);

COMMENT ON TABLE v2.cat_indicadores IS
'Identidad conceptual estable de indicadores. Las claves/nombres por ejercicio se almacenan en indicadores_version.';

CREATE UNIQUE INDEX IF NOT EXISTS uq_v2_indicadores_clave_interna_ci
  ON v2.cat_indicadores (lower(btrim(clave_interna)));

CREATE INDEX IF NOT EXISTS idx_v2_indicadores_unidad
  ON v2.cat_indicadores (unidad_operativa_id, activo);


-- ============================================================================
-- 02. VERSIONES DE INDICADOR POR EJERCICIO
--
-- Aquí viven las diferencias 2025, 2026, 2027...
-- ============================================================================

CREATE TABLE IF NOT EXISTS v2.indicadores_version (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  indicador_id        UUID NOT NULL
                      REFERENCES v2.cat_indicadores(id)
                      ON DELETE RESTRICT,

  ejercicio           INTEGER NOT NULL
                      CHECK (ejercicio BETWEEN 2000 AND 2100),

  clave               TEXT NOT NULL,
  nombre              TEXT NOT NULL,
  descripcion         TEXT,

  unidad_medida_id    UUID NOT NULL
                      REFERENCES v2.cat_unidades_medida(id)
                      ON DELETE RESTRICT,

  periodicidad        TEXT NOT NULL DEFAULT 'ANUAL'
                      CHECK (
                        periodicidad IN (
                          'MENSUAL',
                          'BIMESTRAL',
                          'TRIMESTRAL',
                          'CUATRIMESTRAL',
                          'SEMESTRAL',
                          'ANUAL',
                          'POR_EVENTO'
                        )
                      ),

  sentido             TEXT NOT NULL DEFAULT 'ASCENDENTE'
                      CHECK (
                        sentido IN (
                          'ASCENDENTE',
                          'DESCENDENTE',
                          'CONSTANTE'
                        )
                      ),

  fuente              TEXT,
  formula_descriptiva TEXT,
  desglose            TEXT,

  vigente_desde       DATE,
  vigente_hasta       DATE,

  activo              BOOLEAN NOT NULL DEFAULT true,

  metadata            JSONB NOT NULL DEFAULT '{}'::jsonb,

  created_by          UUID REFERENCES auth.users(id) ON DELETE SET NULL
                      DEFAULT auth.uid(),

  updated_by          UUID REFERENCES auth.users(id) ON DELETE SET NULL
                      DEFAULT auth.uid(),

  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT ck_v2_indicador_version_clave_no_vacia
    CHECK (btrim(clave) <> ''),

  CONSTRAINT ck_v2_indicador_version_nombre_no_vacio
    CHECK (btrim(nombre) <> ''),

  CONSTRAINT ck_v2_indicador_version_vigencia
    CHECK (
      vigente_hasta IS NULL
      OR vigente_desde IS NULL
      OR vigente_hasta >= vigente_desde
    ),

  CONSTRAINT uq_v2_indicador_version_ejercicio
    UNIQUE (indicador_id, ejercicio)
);

COMMENT ON TABLE v2.indicadores_version IS
'Configuración anual/versionada de cada indicador institucional.';

CREATE UNIQUE INDEX IF NOT EXISTS uq_v2_indicadores_version_clave_ejercicio_ci
  ON v2.indicadores_version (
    ejercicio,
    lower(btrim(clave))
  );

CREATE INDEX IF NOT EXISTS idx_v2_indicadores_version_ejercicio
  ON v2.indicadores_version (ejercicio, activo);

CREATE INDEX IF NOT EXISTS idx_v2_indicadores_version_unidad_medida
  ON v2.indicadores_version (unidad_medida_id, ejercicio);


-- ============================================================================
-- 03. METAS
--
-- Una meta puede ser:
--   ESTATAL
--   UNIDAD
--   REGION
--   MUNICIPIO
--
-- El scope se valida con CHECK para evitar metas ambiguas.
-- ============================================================================

CREATE TABLE IF NOT EXISTS v2.metas_indicador (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  indicador_version_id  UUID NOT NULL
                        REFERENCES v2.indicadores_version(id)
                        ON DELETE CASCADE,

  alcance               TEXT NOT NULL DEFAULT 'ESTATAL'
                        CHECK (
                          alcance IN (
                            'ESTATAL',
                            'UNIDAD',
                            'REGION',
                            'MUNICIPIO'
                          )
                        ),

  unidad_operativa_id   UUID
                        REFERENCES v2.cat_unidades_operativas(id)
                        ON DELETE RESTRICT,

  region_id             UUID
                        REFERENCES v2.cat_regiones(id)
                        ON DELETE RESTRICT,

  municipio_id          UUID
                        REFERENCES v2.cat_municipios(id)
                        ON DELETE RESTRICT,

  meta                  NUMERIC(18,4) NOT NULL
                        CHECK (meta >= 0),

  periodo_inicio        DATE,
  periodo_fin           DATE,

  observaciones         TEXT,
  activo                BOOLEAN NOT NULL DEFAULT true,

  created_by            UUID REFERENCES auth.users(id) ON DELETE SET NULL
                        DEFAULT auth.uid(),

  updated_by            UUID REFERENCES auth.users(id) ON DELETE SET NULL
                        DEFAULT auth.uid(),

  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT ck_v2_meta_periodo
    CHECK (
      periodo_fin IS NULL
      OR periodo_inicio IS NULL
      OR periodo_fin >= periodo_inicio
    ),

  CONSTRAINT ck_v2_meta_alcance
    CHECK (
      (
        alcance = 'ESTATAL'
        AND unidad_operativa_id IS NULL
        AND region_id IS NULL
        AND municipio_id IS NULL
      )
      OR
      (
        alcance = 'UNIDAD'
        AND unidad_operativa_id IS NOT NULL
        AND region_id IS NULL
        AND municipio_id IS NULL
      )
      OR
      (
        alcance = 'REGION'
        AND unidad_operativa_id IS NULL
        AND region_id IS NOT NULL
        AND municipio_id IS NULL
      )
      OR
      (
        alcance = 'MUNICIPIO'
        AND unidad_operativa_id IS NULL
        AND region_id IS NULL
        AND municipio_id IS NOT NULL
      )
    )
);

COMMENT ON TABLE v2.metas_indicador IS
'Metas por indicador versionado y alcance institucional/territorial.';

CREATE INDEX IF NOT EXISTS idx_v2_metas_indicador_version
  ON v2.metas_indicador (indicador_version_id, alcance, activo);

CREATE INDEX IF NOT EXISTS idx_v2_metas_unidad
  ON v2.metas_indicador (unidad_operativa_id)
  WHERE unidad_operativa_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_v2_metas_region
  ON v2.metas_indicador (region_id)
  WHERE region_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_v2_metas_municipio
  ON v2.metas_indicador (municipio_id)
  WHERE municipio_id IS NOT NULL;

-- Evita metas duplicadas para el mismo indicador y alcance.
CREATE UNIQUE INDEX IF NOT EXISTS uq_v2_meta_estatal
  ON v2.metas_indicador (indicador_version_id)
  WHERE alcance = 'ESTATAL' AND activo = true;

CREATE UNIQUE INDEX IF NOT EXISTS uq_v2_meta_unidad
  ON v2.metas_indicador (
    indicador_version_id,
    unidad_operativa_id
  )
  WHERE alcance = 'UNIDAD' AND activo = true;

CREATE UNIQUE INDEX IF NOT EXISTS uq_v2_meta_region
  ON v2.metas_indicador (
    indicador_version_id,
    region_id
  )
  WHERE alcance = 'REGION' AND activo = true;

CREATE UNIQUE INDEX IF NOT EXISTS uq_v2_meta_municipio
  ON v2.metas_indicador (
    indicador_version_id,
    municipio_id
  )
  WHERE alcance = 'MUNICIPIO' AND activo = true;


-- ============================================================================
-- 04. RELACIÓN ACCIÓN → INDICADOR
--
-- Es la base para que el usuario NO tenga que elegir manualmente un indicador
-- cada vez que captura.
--
-- Una acción puede aportar a uno o varios indicadores.
-- ============================================================================

CREATE TABLE IF NOT EXISTS v2.accion_indicador (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  accion_id             UUID NOT NULL
                        REFERENCES v2.cat_acciones(id)
                        ON DELETE CASCADE,

  indicador_version_id  UUID NOT NULL
                        REFERENCES v2.indicadores_version(id)
                        ON DELETE CASCADE,

  regla_aporte          TEXT NOT NULL DEFAULT 'UNO_POR_REGISTRO'
                        CHECK (
                          regla_aporte IN (
                            'UNO_POR_REGISTRO',
                            'TOTAL_BENEFICIARIOS',
                            'VALOR_METRICA',
                            'VALOR_MANUAL_VALIDADO'
                          )
                        ),

  -- Parámetros adicionales para reglas futuras.
  -- Ejemplo VALOR_METRICA:
  -- {"metrica_clave":"usuarios_atendidos"}
  parametros            JSONB NOT NULL DEFAULT '{}'::jsonb,

  -- Por defecto solo cuentan registros validados.
  requiere_validado     BOOLEAN NOT NULL DEFAULT true,

  factor                NUMERIC(18,6) NOT NULL DEFAULT 1
                        CHECK (factor >= 0),

  activo                BOOLEAN NOT NULL DEFAULT true,

  created_by            UUID REFERENCES auth.users(id) ON DELETE SET NULL
                        DEFAULT auth.uid(),

  updated_by            UUID REFERENCES auth.users(id) ON DELETE SET NULL
                        DEFAULT auth.uid(),

  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT uq_v2_accion_indicador
    UNIQUE (
      accion_id,
      indicador_version_id,
      regla_aporte
    )
);

COMMENT ON TABLE v2.accion_indicador IS
'Reglas versionadas que determinan automáticamente cómo aporta una acción institucional a un indicador.';

CREATE INDEX IF NOT EXISTS idx_v2_accion_indicador_accion
  ON v2.accion_indicador (accion_id, activo);

CREATE INDEX IF NOT EXISTS idx_v2_accion_indicador_version
  ON v2.accion_indicador (indicador_version_id, activo);


-- ============================================================================
-- 05. APORTES MANUALES / AJUSTES / MIGRACIONES
--
-- Los aportes automáticos normales se calcularán en vistas/RPC.
-- Esta tabla existe para casos explícitos:
--   - valor manual validado
--   - ajuste institucional autorizado
--   - migración histórica
--
-- No debe usarse para duplicar el cálculo automático.
-- ============================================================================

CREATE TABLE IF NOT EXISTS v2.registro_indicador_aportes (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  registro_id           UUID NOT NULL
                        REFERENCES v2.registros(id)
                        ON DELETE CASCADE,

  indicador_version_id  UUID NOT NULL
                        REFERENCES v2.indicadores_version(id)
                        ON DELETE RESTRICT,

  fuente                TEXT NOT NULL DEFAULT 'MANUAL'
                        CHECK (
                          fuente IN (
                            'MANUAL',
                            'AJUSTE',
                            'MIGRACION'
                          )
                        ),

  valor                 NUMERIC(18,4) NOT NULL
                        CHECK (valor >= 0),

  justificacion         TEXT,

  validado              BOOLEAN NOT NULL DEFAULT false,

  validado_por          UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  validado_at           TIMESTAMPTZ,

  activo                BOOLEAN NOT NULL DEFAULT true,

  created_by            UUID REFERENCES auth.users(id) ON DELETE SET NULL
                        DEFAULT auth.uid(),

  updated_by            UUID REFERENCES auth.users(id) ON DELETE SET NULL
                        DEFAULT auth.uid(),

  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),

  CONSTRAINT ck_v2_aporte_validacion
    CHECK (
      (
        validado = false
        AND validado_at IS NULL
      )
      OR
      (
        validado = true
        AND validado_por IS NOT NULL
        AND validado_at IS NOT NULL
      )
    )
);

COMMENT ON TABLE v2.registro_indicador_aportes IS
'Aportes manuales, ajustes institucionales o migrados. Los aportes automáticos se calcularán mediante vistas/RPC.';

CREATE INDEX IF NOT EXISTS idx_v2_aportes_registro
  ON v2.registro_indicador_aportes (
    registro_id,
    indicador_version_id,
    activo
  );

CREATE INDEX IF NOT EXISTS idx_v2_aportes_indicador
  ON v2.registro_indicador_aportes (
    indicador_version_id,
    validado,
    activo
  );


-- ============================================================================
-- 06. SEGURIDAD: RLS + DENY BY DEFAULT
-- ============================================================================

DO $$
DECLARE
  tbl TEXT;
BEGIN
  FOREACH tbl IN ARRAY ARRAY[
    'cat_indicadores',
    'indicadores_version',
    'metas_indicador',
    'accion_indicador',
    'registro_indicador_aportes'
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
-- 07. REGISTRO DE MIGRACIÓN
-- ============================================================================

INSERT INTO v2.schema_migrations (
  version,
  descripcion
)
VALUES (
  '2.1.04',
  '04_indicators.sql - Indicadores versionados, metas, reglas de aporte y aportes manuales.'
)
ON CONFLICT (version) DO NOTHING;


COMMIT;


-- ============================================================================
-- 08. VERIFICACIÓN POST-INSTALACIÓN
-- ============================================================================

WITH tablas_esperadas(nombre) AS (
  VALUES
    ('cat_indicadores'),
    ('indicadores_version'),
    ('metas_indicador'),
    ('accion_indicador'),
    ('registro_indicador_aportes')
)
SELECT
  'V2.1 - 04_indicators' AS instalacion,

  (
    SELECT count(*)
    FROM tablas_esperadas te
    WHERE to_regclass('v2.' || te.nombre) IS NOT NULL
  ) AS tablas_indicadores_creadas,

  (
    SELECT count(*)
    FROM tablas_esperadas te
    JOIN pg_class c
      ON c.oid = to_regclass('v2.' || te.nombre)
    WHERE c.relrowsecurity = true
  ) AS tablas_indicadores_con_rls,

  (
    SELECT count(*)
    FROM v2.schema_migrations
    WHERE version = '2.1.04'
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
-- tablas_indicadores_creadas   = 5
-- tablas_indicadores_con_rls   = 5
-- migracion_registrada         = 1
-- total_tablas_v2              = 44
--
-- Después de este paso:
--
--   01 Core          ✓
--   02 Catálogos     ✓
--   03 Operación     ✓
--   04 Indicadores   ✓
--
-- Próximo archivo:
--   05_functions_triggers.sql
--
-- Ahí se implementarán:
--   - updated_at automático
--   - row_version
--   - folio institucional atómico
--   - sincronización auth.users → v2.profiles
--   - auditoría
--   - control de transiciones de validación
-- ============================================================================
