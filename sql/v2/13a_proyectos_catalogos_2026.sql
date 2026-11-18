-- ============================================================================
-- 13a_proyectos_catalogos_2026.sql
-- Catálogo de proyectos (colaborativos de circuito/regionales y socioculturales
-- 3390), asignación de municipios y gestores.
--
-- ADITIVO: no elimina ni modifica tablas, columnas ni datos existentes,
-- salvo el UPDATE del nombre visible de la unidad CDCM (sección 0).
-- Las sesiones/actividades de proyecto se capturan como v2.registros mediante
-- las RPC existentes (metadata.proyecto_id), por lo que reutilizan RLS,
-- registro_evidencias, Storage y dashboard sin duplicar lógica.
-- No ejecutar fixtures. Ejecutar una sola vez tras revisión.
-- ============================================================================

-- 0) Nombre visible de la unidad (la clave CDCM se conserva: el frontend,
--    la semilla y las acciones dependen de ella).
UPDATE v2.cat_unidades_operativas
   SET nombre = 'Casas de la Cultura'
 WHERE upper(btrim(clave)) = 'CDCM'
   AND nombre <> 'Casas de la Cultura';

-- 1) Catálogo de proyectos -----------------------------------------------------
CREATE TABLE IF NOT EXISTS v2.cat_proyectos (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tipo              TEXT NOT NULL
                    CHECK (tipo IN ('COLABORATIVO_CIRCUITO',
                                    'COLABORATIVO_REGIONAL',
                                    'SOCIOCULTURAL_3390')),
  clave             TEXT,
  nombre            TEXT NOT NULL CHECK (length(btrim(nombre)) > 0),
  descripcion       TEXT,
  objetivo          TEXT,
  justificacion     TEXT,
  grupo_atencion    TEXT,
  disciplinas_temas TEXT,
  sedes_espacios    TEXT,
  requerimientos    TEXT,
  periodo_inicio    DATE,
  periodo_fin       DATE,
  resultado_final   TEXT,
  circuito_nombre   TEXT,
  region_id         UUID REFERENCES v2.cat_regiones(id),
  activo            BOOLEAN NOT NULL DEFAULT TRUE,
  created_by        UUID DEFAULT auth.uid(),
  updated_by        UUID,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT cat_proyectos_periodo_chk
    CHECK (periodo_fin IS NULL OR periodo_inicio IS NULL OR periodo_fin >= periodo_inicio)
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_cat_proyectos_tipo_nombre
  ON v2.cat_proyectos (tipo, lower(btrim(nombre)));

-- 2) Municipios participantes ---------------------------------------------------
CREATE TABLE IF NOT EXISTS v2.proyecto_municipios (
  proyecto_id  UUID NOT NULL REFERENCES v2.cat_proyectos(id) ON DELETE CASCADE,
  municipio_id UUID NOT NULL REFERENCES v2.cat_municipios(id),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (proyecto_id, municipio_id)
);

-- 3) Gestores asignados (usuarios normales de la plataforma) -------------------
CREATE TABLE IF NOT EXISTS v2.proyecto_gestores (
  proyecto_id UUID NOT NULL REFERENCES v2.cat_proyectos(id) ON DELETE CASCADE,
  user_id     UUID NOT NULL REFERENCES v2.profiles(user_id),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (proyecto_id, user_id)
);

CREATE INDEX IF NOT EXISTS ix_proyecto_gestores_user
  ON v2.proyecto_gestores (user_id);

-- 4) updated_at ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION v2_private.touch_cat_proyectos()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  NEW.updated_at := now();
  NEW.updated_by := auth.uid();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_touch_cat_proyectos ON v2.cat_proyectos;
CREATE TRIGGER trg_touch_cat_proyectos
  BEFORE UPDATE ON v2.cat_proyectos
  FOR EACH ROW EXECUTE FUNCTION v2_private.touch_cat_proyectos();

-- 5) RLS -----------------------------------------------------------------------
ALTER TABLE v2.cat_proyectos       ENABLE ROW LEVEL SECURITY;
ALTER TABLE v2.proyecto_municipios ENABLE ROW LEVEL SECURITY;
ALTER TABLE v2.proyecto_gestores   ENABLE ROW LEVEL SECURITY;

-- Proyectos colaborativos: visibles para cualquier usuario activo (son
-- catálogo operativo). Proyectos 3390: solo administración y sus gestores.
DROP POLICY IF EXISTS select_cat_proyectos ON v2.cat_proyectos;
CREATE POLICY select_cat_proyectos ON v2.cat_proyectos
  FOR SELECT TO authenticated
  USING (
    (SELECT v2_private.is_admin())
    OR (
      (SELECT v2_private.is_active_user())
      AND activo = TRUE
      AND (
        tipo IN ('COLABORATIVO_CIRCUITO', 'COLABORATIVO_REGIONAL')
        OR EXISTS (
          SELECT 1 FROM v2.proyecto_gestores g
           WHERE g.proyecto_id = cat_proyectos.id
             AND g.user_id = (SELECT auth.uid())
        )
      )
    )
  );

DROP POLICY IF EXISTS insert_admin_cat_proyectos ON v2.cat_proyectos;
CREATE POLICY insert_admin_cat_proyectos ON v2.cat_proyectos
  FOR INSERT TO authenticated
  WITH CHECK ((SELECT v2_private.is_admin()));

DROP POLICY IF EXISTS update_admin_cat_proyectos ON v2.cat_proyectos;
CREATE POLICY update_admin_cat_proyectos ON v2.cat_proyectos
  FOR UPDATE TO authenticated
  USING ((SELECT v2_private.is_admin()))
  WITH CHECK ((SELECT v2_private.is_admin()));

DROP POLICY IF EXISTS select_proyecto_municipios ON v2.proyecto_municipios;
CREATE POLICY select_proyecto_municipios ON v2.proyecto_municipios
  FOR SELECT TO authenticated
  USING (
    (SELECT v2_private.is_admin())
    OR (
      (SELECT v2_private.is_active_user())
      AND EXISTS (SELECT 1 FROM v2.cat_proyectos p
                   WHERE p.id = proyecto_municipios.proyecto_id)
    )
  );

DROP POLICY IF EXISTS write_admin_proyecto_municipios ON v2.proyecto_municipios;
CREATE POLICY write_admin_proyecto_municipios ON v2.proyecto_municipios
  FOR ALL TO authenticated
  USING ((SELECT v2_private.is_admin()))
  WITH CHECK ((SELECT v2_private.is_admin()));

DROP POLICY IF EXISTS select_proyecto_gestores ON v2.proyecto_gestores;
CREATE POLICY select_proyecto_gestores ON v2.proyecto_gestores
  FOR SELECT TO authenticated
  USING (
    (SELECT v2_private.is_admin())
    OR user_id = (SELECT auth.uid())
  );

DROP POLICY IF EXISTS write_admin_proyecto_gestores ON v2.proyecto_gestores;
CREATE POLICY write_admin_proyecto_gestores ON v2.proyecto_gestores
  FOR ALL TO authenticated
  USING ((SELECT v2_private.is_admin()))
  WITH CHECK ((SELECT v2_private.is_admin()));

-- 6) Permisos de Data API (RLS decide las filas) -------------------------------
GRANT SELECT, INSERT, UPDATE ON v2.cat_proyectos TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON v2.proyecto_municipios TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON v2.proyecto_gestores TO authenticated;
