-- ============================================================================
-- VINCULACIÓN CULTURAL 2.0
-- 06_rls.sql
-- Autorización, roles, alcances y Row Level Security
-- Secretaría de Cultura de Guanajuato
--
-- REQUIERE:
--   01_core_schema.sql
--   02_catalogs.sql
--   03_operation_modules.sql
--   04_indicators.sql
--   05_functions_triggers.sql
--
-- IMPLEMENTA:
--   ✓ schema privado de helpers de autorización
--   ✓ usuario activo/inactivo
--   ✓ ADMIN / SUPERVISOR / DIRECTIVO / CAPTURISTA
--   ✓ alcance por unidad operativa y municipio
--   ✓ lectura/escritura de registros según rol
--   ✓ control de transiciones por rol
--   ✓ protección contra auto-promoción
--   ✓ protección del último ADMIN activo
--   ✓ catálogos: lectura autenticada, escritura ADMIN
--   ✓ importaciones ADMIN/SUPERVISOR
--   ✓ auditoría visible solo a ADMIN
--   ✓ ningún acceso de anon
--
-- IMPORTANTE:
--   Este archivo otorga privilegios SQL a authenticated, pero el schema "v2"
--   todavía NO necesita exponerse en la Data API. Ese paso se hará cuando
--   lleguemos al frontend V2.
--
-- NO HACE:
--   ✗ no toca las policies V1
--   ✗ no expone v2 a PostgREST por sí solo
--   ✗ no modifica Storage
--   ✗ no migra datos V1
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
     OR to_regclass('v2.profiles') IS NULL
     OR to_regclass('v2.audit_log') IS NULL THEN
    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: faltan objetos de V2. Ejecute 01-05 primero.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM v2.profiles
    WHERE rol = 'ADMIN'
      AND activo = true
  ) THEN
    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: V2 no tiene ningún ADMIN activo.';
  END IF;
END
$$;


-- ============================================================================
-- 01. SCHEMA PRIVADO PARA HELPERS RLS
--
-- No se expondrá en PostgREST.
-- Las policies pueden llamar funciones schema-qualified desde aquí.
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS v2_private;

REVOKE ALL ON SCHEMA v2_private FROM PUBLIC;
REVOKE ALL ON SCHEMA v2_private FROM anon;
REVOKE ALL ON SCHEMA v2_private FROM authenticated;

-- authenticated requiere USAGE para evaluar helpers desde policies,
-- pero el schema no será incluido en Exposed Schemas de PostgREST.
GRANT USAGE ON SCHEMA v2_private TO authenticated;

ALTER DEFAULT PRIVILEGES IN SCHEMA v2_private
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

ALTER DEFAULT PRIVILEGES IN SCHEMA v2_private
  REVOKE EXECUTE ON FUNCTIONS FROM anon;

ALTER DEFAULT PRIVILEGES IN SCHEMA v2_private
  REVOKE EXECUTE ON FUNCTIONS FROM authenticated;


-- ============================================================================
-- 02. HELPERS DE IDENTIDAD Y ROL
-- ============================================================================

CREATE OR REPLACE FUNCTION v2_private.current_role()
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT p.rol
  FROM v2.profiles p
  WHERE p.user_id = auth.uid()
    AND p.activo = true
  LIMIT 1
$$;


CREATE OR REPLACE FUNCTION v2_private.is_active_user()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM v2.profiles p
    WHERE p.user_id = auth.uid()
      AND p.activo = true
  )
$$;


CREATE OR REPLACE FUNCTION v2_private.is_admin()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(v2_private.current_role() = 'ADMIN', false)
$$;


CREATE OR REPLACE FUNCTION v2_private.is_supervisor()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(v2_private.current_role() = 'SUPERVISOR', false)
$$;


CREATE OR REPLACE FUNCTION v2_private.is_directivo()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(v2_private.current_role() = 'DIRECTIVO', false)
$$;


CREATE OR REPLACE FUNCTION v2_private.is_capturista()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(v2_private.current_role() = 'CAPTURISTA', false)
$$;


-- ============================================================================
-- 03. HELPER DE ALCANCE
--
-- Semántica:
--   - ADMIN: acceso global.
--   - Para otros roles debe existir al menos una asignación activa de
--     unidad o municipio.
--   - Si el usuario tiene asignaciones en una dimensión, esa dimensión
--     restringe.
--   - Si no tiene asignaciones en una dimensión, esa dimensión queda abierta
--     dentro de la otra dimensión asignada.
--
-- Ejemplos:
--   Supervisor solo CDCM, sin municipios -> CDCM estatal.
--   Supervisor solo León, sin unidades   -> todas sus unidades en León.
--   Capturista CDCM + León               -> intersección CDCM/León.
-- ============================================================================

CREATE OR REPLACE FUNCTION v2_private.has_scope(
  p_unidad UUID,
  p_municipio UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid               UUID := auth.uid();
  v_has_unit_scopes   BOOLEAN;
  v_has_muni_scopes   BOOLEAN;
  v_unit_ok           BOOLEAN;
  v_muni_ok           BOOLEAN;
BEGIN
  IF v_uid IS NULL THEN
    RETURN false;
  END IF;

  IF v2_private.is_admin() THEN
    RETURN true;
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM v2.profile_unidades pu
    WHERE pu.user_id = v_uid
      AND pu.activo = true
  )
  INTO v_has_unit_scopes;

  SELECT EXISTS (
    SELECT 1
    FROM v2.profile_municipios pm
    WHERE pm.user_id = v_uid
      AND pm.activo = true
  )
  INTO v_has_muni_scopes;

  -- Sin ningún alcance asignado: deny by default.
  IF NOT v_has_unit_scopes AND NOT v_has_muni_scopes THEN
    RETURN false;
  END IF;

  v_unit_ok :=
    NOT v_has_unit_scopes
    OR (
      p_unidad IS NOT NULL
      AND EXISTS (
        SELECT 1
        FROM v2.profile_unidades pu
        WHERE pu.user_id = v_uid
          AND pu.unidad_operativa_id = p_unidad
          AND pu.activo = true
      )
    );

  v_muni_ok :=
    NOT v_has_muni_scopes
    OR p_municipio IS NULL
    OR EXISTS (
      SELECT 1
      FROM v2.profile_municipios pm
      WHERE pm.user_id = v_uid
        AND pm.municipio_id = p_municipio
        AND pm.activo = true
    );

  RETURN v_unit_ok AND v_muni_ok;
END;
$$;


-- ============================================================================
-- 04. HELPERS DE REGISTROS
-- ============================================================================

CREATE OR REPLACE FUNCTION v2_private.can_read_record(
  p_registro UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  r       RECORD;
  v_role  TEXT;
  v_uid   UUID := auth.uid();
BEGIN
  IF v_uid IS NULL OR NOT v2_private.is_active_user() THEN
    RETURN false;
  END IF;

  SELECT
    x.created_by,
    x.unidad_operativa_id,
    x.municipio_id
  INTO r
  FROM v2.registros x
  WHERE x.id = p_registro;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  v_role := v2_private.current_role();

  IF v_role = 'ADMIN' THEN
    RETURN true;
  END IF;

  IF v_role IN ('SUPERVISOR', 'DIRECTIVO') THEN
    RETURN v2_private.has_scope(
      r.unidad_operativa_id,
      r.municipio_id
    );
  END IF;

  IF v_role = 'CAPTURISTA' THEN
    RETURN r.created_by = v_uid;
  END IF;

  RETURN false;
END;
$$;


CREATE OR REPLACE FUNCTION v2_private.can_edit_record(
  p_registro UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  r       RECORD;
  v_role  TEXT;
  v_uid   UUID := auth.uid();
BEGIN
  IF v_uid IS NULL OR NOT v2_private.is_active_user() THEN
    RETURN false;
  END IF;

  SELECT
    x.created_by,
    x.unidad_operativa_id,
    x.municipio_id,
    x.estatus
  INTO r
  FROM v2.registros x
  WHERE x.id = p_registro;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  v_role := v2_private.current_role();

  IF v_role = 'ADMIN' THEN
    RETURN true;
  END IF;

  IF v_role = 'SUPERVISOR' THEN
    RETURN
      r.estatus NOT IN ('VALIDADO', 'ANULADO')
      AND v2_private.has_scope(
        r.unidad_operativa_id,
        r.municipio_id
      );
  END IF;

  IF v_role = 'CAPTURISTA' THEN
    RETURN
      r.created_by = v_uid
      AND r.estatus IN (
        'BORRADOR',
        'CAPTURADO',
        'OBSERVADO',
        'CORREGIDO'
      );
  END IF;

  RETURN false;
END;
$$;


CREATE OR REPLACE FUNCTION v2_private.can_create_record(
  p_unidad UUID,
  p_municipio UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_role TEXT := v2_private.current_role();
BEGIN
  IF NOT v2_private.is_active_user() THEN
    RETURN false;
  END IF;

  IF v_role = 'ADMIN' THEN
    RETURN true;
  END IF;

  IF v_role = 'CAPTURISTA' THEN
    RETURN v2_private.has_scope(p_unidad, p_municipio);
  END IF;

  RETURN false;
END;
$$;


CREATE OR REPLACE FUNCTION v2_private.can_manage_record(
  p_registro UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  r       RECORD;
  v_role  TEXT := v2_private.current_role();
BEGIN
  IF NOT v2_private.is_active_user() THEN
    RETURN false;
  END IF;

  IF v_role = 'ADMIN' THEN
    RETURN true;
  END IF;

  IF v_role <> 'SUPERVISOR' THEN
    RETURN false;
  END IF;

  SELECT unidad_operativa_id, municipio_id
  INTO r
  FROM v2.registros
  WHERE id = p_registro;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  RETURN v2_private.has_scope(
    r.unidad_operativa_id,
    r.municipio_id
  );
END;
$$;


CREATE OR REPLACE FUNCTION v2_private.can_manage_import_job(
  p_job UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_role TEXT := v2_private.current_role();
  v_uid  UUID := auth.uid();
BEGIN
  IF v_uid IS NULL OR NOT v2_private.is_active_user() THEN
    RETURN false;
  END IF;

  IF v_role = 'ADMIN' THEN
    RETURN true;
  END IF;

  IF v_role = 'SUPERVISOR' THEN
    RETURN EXISTS (
      SELECT 1
      FROM v2.import_jobs j
      WHERE j.id = p_job
        AND j.usuario_id = v_uid
    );
  END IF;

  RETURN false;
END;
$$;


-- ============================================================================
-- 05. EJECUCIÓN DE HELPERS
-- Solo authenticated puede usarlos dentro de RLS.
-- El schema v2_private NO se expondrá en PostgREST.
-- ============================================================================

REVOKE ALL ON FUNCTION v2_private.current_role()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION v2_private.is_active_user()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION v2_private.is_admin()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION v2_private.is_supervisor()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION v2_private.is_directivo()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION v2_private.is_capturista()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION v2_private.has_scope(UUID, UUID)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION v2_private.can_read_record(UUID)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION v2_private.can_edit_record(UUID)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION v2_private.can_create_record(UUID, UUID)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION v2_private.can_manage_record(UUID)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION v2_private.can_manage_import_job(UUID)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION v2_private.current_role()
  TO authenticated;
GRANT EXECUTE ON FUNCTION v2_private.is_active_user()
  TO authenticated;
GRANT EXECUTE ON FUNCTION v2_private.is_admin()
  TO authenticated;
GRANT EXECUTE ON FUNCTION v2_private.is_supervisor()
  TO authenticated;
GRANT EXECUTE ON FUNCTION v2_private.is_directivo()
  TO authenticated;
GRANT EXECUTE ON FUNCTION v2_private.is_capturista()
  TO authenticated;
GRANT EXECUTE ON FUNCTION v2_private.has_scope(UUID, UUID)
  TO authenticated;
GRANT EXECUTE ON FUNCTION v2_private.can_read_record(UUID)
  TO authenticated;
GRANT EXECUTE ON FUNCTION v2_private.can_edit_record(UUID)
  TO authenticated;
GRANT EXECUTE ON FUNCTION v2_private.can_create_record(UUID, UUID)
  TO authenticated;
GRANT EXECUTE ON FUNCTION v2_private.can_manage_record(UUID)
  TO authenticated;
GRANT EXECUTE ON FUNCTION v2_private.can_manage_import_job(UUID)
  TO authenticated;


-- ============================================================================
-- 06. PROTECCIÓN DEL ÚLTIMO ADMIN
-- ============================================================================

CREATE OR REPLACE FUNCTION v2_private.protect_last_admin()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_admins INTEGER;
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.rol = 'ADMIN' AND OLD.activo = true THEN
      SELECT count(*)
      INTO v_admins
      FROM v2.profiles
      WHERE rol = 'ADMIN'
        AND activo = true
        AND user_id <> OLD.user_id;

      IF v_admins = 0 THEN
        RAISE EXCEPTION
          'No se puede eliminar el último ADMIN activo de V2.';
      END IF;
    END IF;

    RETURN OLD;
  END IF;

  IF OLD.rol = 'ADMIN'
     AND OLD.activo = true
     AND (
       NEW.rol IS DISTINCT FROM OLD.rol
       OR NEW.activo IS DISTINCT FROM OLD.activo
     )
     AND (
       NEW.rol <> 'ADMIN'
       OR NEW.activo = false
     ) THEN

    SELECT count(*)
    INTO v_admins
    FROM v2.profiles
    WHERE rol = 'ADMIN'
      AND activo = true
      AND user_id <> OLD.user_id;

    IF v_admins = 0 THEN
      RAISE EXCEPTION
        'No se puede desactivar o degradar el último ADMIN activo de V2.';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION v2_private.protect_last_admin()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_v2_profiles_protect_last_admin
ON v2.profiles;

CREATE TRIGGER trg_v2_profiles_protect_last_admin
BEFORE UPDATE OR DELETE ON v2.profiles
FOR EACH ROW
EXECUTE FUNCTION v2_private.protect_last_admin();


-- ============================================================================
-- 07. AUTORIZACIÓN DE TRANSICIÓN DE ESTATUS POR ROL
--
-- El trigger de 05 valida que la transición sea válida funcionalmente.
-- Este trigger valida QUIÉN puede ejecutarla.
-- ============================================================================

CREATE OR REPLACE FUNCTION v2_private.authorize_status_transition()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_role TEXT;
BEGIN
  -- Migraciones controladas desde SQL Editor / servicio.
  IF auth.uid() IS NULL
     AND current_user IN ('postgres', 'supabase_admin', 'service_role') THEN
    RETURN NEW;
  END IF;

  v_role := v2_private.current_role();

  IF v_role = 'ADMIN' THEN
    RETURN NEW;
  END IF;

  IF v_role = 'CAPTURISTA'
     AND OLD.created_by = auth.uid()
     AND (
       (OLD.estatus = 'BORRADOR'   AND NEW.estatus = 'CAPTURADO')
       OR
       (OLD.estatus = 'CAPTURADO'  AND NEW.estatus = 'EN_REVISION')
       OR
       (OLD.estatus = 'OBSERVADO'  AND NEW.estatus = 'CORREGIDO')
       OR
       (OLD.estatus = 'CORREGIDO'  AND NEW.estatus = 'EN_REVISION')
     ) THEN
    RETURN NEW;
  END IF;

  IF v_role = 'SUPERVISOR'
     AND v2_private.has_scope(
       OLD.unidad_operativa_id,
       OLD.municipio_id
     )
     AND (
       (OLD.estatus = 'CAPTURADO'  AND NEW.estatus = 'EN_REVISION')
       OR
       (OLD.estatus = 'EN_REVISION' AND NEW.estatus = 'VALIDADO')
       OR
       (OLD.estatus = 'EN_REVISION' AND NEW.estatus = 'OBSERVADO')
       OR
       (OLD.estatus = 'CORREGIDO' AND NEW.estatus = 'EN_REVISION')
     ) THEN
    RETURN NEW;
  END IF;

  RAISE EXCEPTION
    'El rol % no puede realizar la transición % -> %.',
    COALESCE(v_role, 'SIN_ROL'),
    OLD.estatus,
    NEW.estatus;
END;
$$;

REVOKE ALL ON FUNCTION v2_private.authorize_status_transition()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_v2_registro_authorize_transition
ON v2.registros;

CREATE TRIGGER trg_v2_registro_authorize_transition
BEFORE UPDATE OF estatus ON v2.registros
FOR EACH ROW
WHEN (OLD.estatus IS DISTINCT FROM NEW.estatus)
EXECUTE FUNCTION v2_private.authorize_status_transition();


-- ============================================================================
-- 08. PRIVILEGIOS DE SCHEMA
-- ============================================================================

REVOKE ALL ON SCHEMA v2 FROM PUBLIC;
REVOKE ALL ON SCHEMA v2 FROM anon;

GRANT USAGE ON SCHEMA v2 TO authenticated;


-- ============================================================================
-- 09. PRIVILEGIOS DE TABLA
--
-- Los GRANT permiten llegar a la tabla.
-- Las policies determinan qué filas se pueden operar.
-- ============================================================================

-- Profiles
GRANT SELECT, UPDATE
ON v2.profiles
TO authenticated;

-- Catálogos / configuración: SELECT para todos los usuarios activos;
-- INSERT/UPDATE quedan filtrados a ADMIN por RLS.
GRANT SELECT, INSERT, UPDATE ON
  v2.cat_unidades_operativas,
  v2.cat_programas,
  v2.cat_tipos_registro,
  v2.cat_acciones,
  v2.cat_regiones,
  v2.cat_municipios,
  v2.cat_municipio_alias,
  v2.cat_tipos_asentamiento,
  v2.cat_comunidades,
  v2.cat_tipos_espacio,
  v2.cat_espacios,
  v2.cat_personas,
  v2.cat_funciones,
  v2.persona_funciones,
  v2.cat_unidades_medida,
  v2.cat_dimensiones_poblacion,
  v2.cat_opciones_poblacion,
  v2.configuracion_acciones,
  v2.profile_unidades,
  v2.profile_municipios,
  v2.cat_indicadores,
  v2.indicadores_version,
  v2.metas_indicador,
  v2.accion_indicador
TO authenticated;

-- Registro núcleo: nunca DELETE físico desde API.
GRANT SELECT, INSERT, UPDATE
ON v2.registros
TO authenticated;

-- Detalles operativos que pueden editarse/reemplazarse mientras el registro
-- sea editable.
GRANT SELECT, INSERT, UPDATE, DELETE ON
  v2.registro_territorios,
  v2.registro_personas,
  v2.registro_poblacion,
  v2.registro_taller,
  v2.taller_horarios,
  v2.registro_proyecto,
  v2.proyecto_objetivos,
  v2.proyecto_actividades,
  v2.registro_reunion,
  v2.registro_intercambio
TO authenticated;

-- Evidencias: baja lógica mediante activo=false; no DELETE directo.
GRANT SELECT, INSERT, UPDATE
ON v2.registro_evidencias
TO authenticated;

-- Validaciones: historial solo lectura desde cliente.
GRANT SELECT
ON v2.registro_validaciones
TO authenticated;

-- Aportes manuales de indicadores.
GRANT SELECT, INSERT, UPDATE
ON v2.registro_indicador_aportes
TO authenticated;

-- Importaciones.
GRANT SELECT, INSERT, UPDATE
ON v2.import_jobs
TO authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE
ON v2.import_staging
TO authenticated;

-- Auditoría: solo SELECT, y la policy limitará a ADMIN.
GRANT SELECT
ON v2.audit_log
TO authenticated;

-- La identity de import_staging sí debe poder asignar IDs a filas cargadas.
DO $$
DECLARE
  v_seq TEXT;
BEGIN
  v_seq := pg_catalog.pg_get_serial_sequence(
    'v2.import_staging',
    'id'
  );

  IF v_seq IS NOT NULL THEN
    EXECUTE pg_catalog.format(
      'GRANT USAGE, SELECT ON SEQUENCE %s TO authenticated',
      v_seq
    );
  END IF;
END
$$;


-- ============================================================================
-- 10. LIMPIEZA DE POLICIES V2 PREVIAS
-- Permite reejecutar este archivo sin duplicar policies.
-- ============================================================================

DO $$
DECLARE
  p RECORD;
BEGIN
  FOR p IN
    SELECT schemaname, tablename, policyname
    FROM pg_policies
    WHERE schemaname = 'v2'
  LOOP
    EXECUTE pg_catalog.format(
      'DROP POLICY IF EXISTS %I ON %I.%I',
      p.policyname,
      p.schemaname,
      p.tablename
    );
  END LOOP;
END
$$;


-- ============================================================================
-- 11. PROFILES
-- ============================================================================

CREATE POLICY profiles_select
ON v2.profiles
FOR SELECT
TO authenticated
USING (
  (SELECT v2_private.is_active_user())
  AND (
    user_id = (SELECT auth.uid())
    OR (SELECT v2_private.is_admin())
  )
);

CREATE POLICY profiles_update_admin
ON v2.profiles
FOR UPDATE
TO authenticated
USING (
  (SELECT v2_private.is_admin())
)
WITH CHECK (
  (SELECT v2_private.is_admin())
);


-- ============================================================================
-- 12. CATÁLOGOS CON COLUMNA activo
-- Lectura: cualquier usuario autenticado activo ve activos; ADMIN también
-- puede ver inactivos.
-- Escritura: solo ADMIN.
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
    'cat_indicadores',
    'indicadores_version',
    'metas_indicador',
    'accion_indicador'
  ]
  LOOP
    EXECUTE pg_catalog.format(
      'CREATE POLICY %I
       ON v2.%I
       FOR SELECT TO authenticated
       USING (
         (SELECT v2_private.is_active_user())
         AND (
           activo = true
           OR (SELECT v2_private.is_admin())
         )
       )',
      'select_active_' || tbl,
      tbl
    );

    EXECUTE pg_catalog.format(
      'CREATE POLICY %I
       ON v2.%I
       FOR INSERT TO authenticated
       WITH CHECK (
         (SELECT v2_private.is_admin())
       )',
      'insert_admin_' || tbl,
      tbl
    );

    EXECUTE pg_catalog.format(
      'CREATE POLICY %I
       ON v2.%I
       FOR UPDATE TO authenticated
       USING (
         (SELECT v2_private.is_admin())
       )
       WITH CHECK (
         (SELECT v2_private.is_admin())
       )',
      'update_admin_' || tbl,
      tbl
    );
  END LOOP;
END
$$;


-- ============================================================================
-- 13. ALCANCES DE PERFIL
-- Usuario puede leer sus propios alcances; ADMIN puede leer todos.
-- Solo ADMIN administra.
-- ============================================================================

CREATE POLICY profile_unidades_select
ON v2.profile_unidades
FOR SELECT TO authenticated
USING (
  (SELECT v2_private.is_active_user())
  AND (
    user_id = (SELECT auth.uid())
    OR (SELECT v2_private.is_admin())
  )
);

CREATE POLICY profile_unidades_insert_admin
ON v2.profile_unidades
FOR INSERT TO authenticated
WITH CHECK ((SELECT v2_private.is_admin()));

CREATE POLICY profile_unidades_update_admin
ON v2.profile_unidades
FOR UPDATE TO authenticated
USING ((SELECT v2_private.is_admin()))
WITH CHECK ((SELECT v2_private.is_admin()));


CREATE POLICY profile_municipios_select
ON v2.profile_municipios
FOR SELECT TO authenticated
USING (
  (SELECT v2_private.is_active_user())
  AND (
    user_id = (SELECT auth.uid())
    OR (SELECT v2_private.is_admin())
  )
);

CREATE POLICY profile_municipios_insert_admin
ON v2.profile_municipios
FOR INSERT TO authenticated
WITH CHECK ((SELECT v2_private.is_admin()));

CREATE POLICY profile_municipios_update_admin
ON v2.profile_municipios
FOR UPDATE TO authenticated
USING ((SELECT v2_private.is_admin()))
WITH CHECK ((SELECT v2_private.is_admin()));


-- ============================================================================
-- 14. REGISTRO NÚCLEO
-- ============================================================================

CREATE POLICY registros_select
ON v2.registros
FOR SELECT TO authenticated
USING (
  (SELECT v2_private.can_read_record(id))
);

-- ADMIN y CAPTURISTA con alcance pueden crear.
CREATE POLICY registros_insert
ON v2.registros
FOR INSERT TO authenticated
WITH CHECK (
  (SELECT v2_private.can_create_record(
    unidad_operativa_id,
    municipio_id
  ))
  AND created_by = (SELECT auth.uid())
);

-- ADMIN
CREATE POLICY registros_update_admin
ON v2.registros
FOR UPDATE TO authenticated
USING (
  (SELECT v2_private.is_admin())
)
WITH CHECK (
  (SELECT v2_private.is_admin())
);

-- SUPERVISOR dentro de alcance.
CREATE POLICY registros_update_supervisor
ON v2.registros
FOR UPDATE TO authenticated
USING (
  (SELECT v2_private.is_supervisor())
  AND (SELECT v2_private.has_scope(
    unidad_operativa_id,
    municipio_id
  ))
  AND estatus NOT IN ('VALIDADO', 'ANULADO')
)
WITH CHECK (
  (SELECT v2_private.is_supervisor())
  AND (SELECT v2_private.has_scope(
    unidad_operativa_id,
    municipio_id
  ))
);

-- CAPTURISTA: únicamente sus propios registros editables.
CREATE POLICY registros_update_capturista
ON v2.registros
FOR UPDATE TO authenticated
USING (
  (SELECT v2_private.is_capturista())
  AND created_by = (SELECT auth.uid())
  AND estatus IN (
    'BORRADOR',
    'CAPTURADO',
    'OBSERVADO',
    'CORREGIDO'
  )
)
WITH CHECK (
  (SELECT v2_private.is_capturista())
  AND created_by = (SELECT auth.uid())
  AND (SELECT v2_private.has_scope(
    unidad_operativa_id,
    municipio_id
  ))
  AND estatus IN (
    'BORRADOR',
    'CAPTURADO',
    'EN_REVISION',
    'OBSERVADO',
    'CORREGIDO'
  )
);


-- ============================================================================
-- 15. DETALLES OPERATIVOS CON registro_id
-- ============================================================================

DO $$
DECLARE
  tbl TEXT;
BEGIN
  FOREACH tbl IN ARRAY ARRAY[
    'registro_territorios',
    'registro_personas',
    'registro_poblacion',
    'registro_taller',
    'taller_horarios',
    'registro_proyecto',
    'proyecto_objetivos',
    'proyecto_actividades',
    'registro_reunion',
    'registro_intercambio'
  ]
  LOOP
    EXECUTE pg_catalog.format(
      'CREATE POLICY %I
       ON v2.%I
       FOR SELECT TO authenticated
       USING (
         (SELECT v2_private.can_read_record(registro_id))
       )',
      'select_' || tbl,
      tbl
    );

    EXECUTE pg_catalog.format(
      'CREATE POLICY %I
       ON v2.%I
       FOR INSERT TO authenticated
       WITH CHECK (
         (SELECT v2_private.can_edit_record(registro_id))
       )',
      'insert_' || tbl,
      tbl
    );

    EXECUTE pg_catalog.format(
      'CREATE POLICY %I
       ON v2.%I
       FOR UPDATE TO authenticated
       USING (
         (SELECT v2_private.can_edit_record(registro_id))
       )
       WITH CHECK (
         (SELECT v2_private.can_edit_record(registro_id))
       )',
      'update_' || tbl,
      tbl
    );

    EXECUTE pg_catalog.format(
      'CREATE POLICY %I
       ON v2.%I
       FOR DELETE TO authenticated
       USING (
         (SELECT v2_private.can_edit_record(registro_id))
       )',
      'delete_' || tbl,
      tbl
    );
  END LOOP;
END
$$;


-- ============================================================================
-- 16. EVIDENCIAS
-- ============================================================================

CREATE POLICY evidencias_select
ON v2.registro_evidencias
FOR SELECT TO authenticated
USING (
  (SELECT v2_private.can_read_record(registro_id))
);

CREATE POLICY evidencias_insert
ON v2.registro_evidencias
FOR INSERT TO authenticated
WITH CHECK (
  (SELECT v2_private.can_edit_record(registro_id))
  AND uploaded_by = (SELECT auth.uid())
);

CREATE POLICY evidencias_update
ON v2.registro_evidencias
FOR UPDATE TO authenticated
USING (
  (SELECT v2_private.can_edit_record(registro_id))
)
WITH CHECK (
  (SELECT v2_private.can_edit_record(registro_id))
);


-- ============================================================================
-- 17. HISTORIAL DE VALIDACIÓN
-- Solo lectura; lo escribe trigger SECURITY DEFINER.
-- ============================================================================

CREATE POLICY validaciones_select
ON v2.registro_validaciones
FOR SELECT TO authenticated
USING (
  (SELECT v2_private.can_read_record(registro_id))
);


-- ============================================================================
-- 18. APORTES MANUALES DE INDICADOR
-- Lectura según registro.
-- Escritura solo ADMIN / SUPERVISOR con alcance.
-- ============================================================================

CREATE POLICY aportes_select
ON v2.registro_indicador_aportes
FOR SELECT TO authenticated
USING (
  (SELECT v2_private.can_read_record(registro_id))
);

CREATE POLICY aportes_insert
ON v2.registro_indicador_aportes
FOR INSERT TO authenticated
WITH CHECK (
  (SELECT v2_private.can_manage_record(registro_id))
);

CREATE POLICY aportes_update
ON v2.registro_indicador_aportes
FOR UPDATE TO authenticated
USING (
  (SELECT v2_private.can_manage_record(registro_id))
)
WITH CHECK (
  (SELECT v2_private.can_manage_record(registro_id))
);


-- ============================================================================
-- 19. IMPORTACIONES
-- ADMIN: todas.
-- SUPERVISOR: únicamente sus propios jobs.
-- ============================================================================

CREATE POLICY import_jobs_select
ON v2.import_jobs
FOR SELECT TO authenticated
USING (
  (SELECT v2_private.is_admin())
  OR (
    (SELECT v2_private.is_supervisor())
    AND usuario_id = (SELECT auth.uid())
  )
);

CREATE POLICY import_jobs_insert
ON v2.import_jobs
FOR INSERT TO authenticated
WITH CHECK (
  (
    (SELECT v2_private.is_admin())
    OR (SELECT v2_private.is_supervisor())
  )
  AND usuario_id = (SELECT auth.uid())
);

CREATE POLICY import_jobs_update
ON v2.import_jobs
FOR UPDATE TO authenticated
USING (
  (SELECT v2_private.can_manage_import_job(id))
)
WITH CHECK (
  (SELECT v2_private.can_manage_import_job(id))
);


CREATE POLICY import_staging_select
ON v2.import_staging
FOR SELECT TO authenticated
USING (
  (SELECT v2_private.can_manage_import_job(import_job_id))
);

CREATE POLICY import_staging_insert
ON v2.import_staging
FOR INSERT TO authenticated
WITH CHECK (
  (SELECT v2_private.can_manage_import_job(import_job_id))
);

CREATE POLICY import_staging_update
ON v2.import_staging
FOR UPDATE TO authenticated
USING (
  (SELECT v2_private.can_manage_import_job(import_job_id))
)
WITH CHECK (
  (SELECT v2_private.can_manage_import_job(import_job_id))
);

CREATE POLICY import_staging_delete
ON v2.import_staging
FOR DELETE TO authenticated
USING (
  (SELECT v2_private.can_manage_import_job(import_job_id))
);


-- ============================================================================
-- 20. AUDITORÍA
-- Solo ADMIN puede consultar.
-- No existe INSERT/UPDATE/DELETE directo desde authenticated.
-- ============================================================================

CREATE POLICY audit_log_select_admin
ON v2.audit_log
FOR SELECT TO authenticated
USING (
  (SELECT v2_private.is_admin())
);


-- ============================================================================
-- 21. OBJETOS INTERNOS SIN API
-- Defensa adicional.
-- ============================================================================

REVOKE ALL ON TABLE v2.schema_migrations
FROM PUBLIC, anon, authenticated;

REVOKE ALL ON TABLE v2.folio_sequences
FROM PUBLIC, anon, authenticated;

-- audit_log solo mantiene el SELECT concedido anteriormente.
REVOKE INSERT, UPDATE, DELETE
ON v2.audit_log
FROM authenticated;


-- ============================================================================
-- 22. REGISTRO DE MIGRACIÓN
-- ============================================================================

INSERT INTO v2.schema_migrations (
  version,
  descripcion
)
VALUES (
  '2.1.06',
  '06_rls.sql - Roles, alcances, permisos mínimos, RLS y protección anti-escalamiento.'
)
ON CONFLICT (version) DO NOTHING;


COMMIT;


-- ============================================================================
-- 23. VERIFICACIÓN POST-INSTALACIÓN
-- ============================================================================

SELECT
  'V2.1 - 06_rls' AS instalacion,

  (
    SELECT count(*)
    FROM information_schema.tables
    WHERE table_schema = 'v2'
      AND table_type = 'BASE TABLE'
  ) AS tablas_v2,

  (
    SELECT count(*)
    FROM pg_class c
    JOIN pg_namespace n
      ON n.oid = c.relnamespace
    WHERE n.nspname = 'v2'
      AND c.relkind = 'r'
      AND c.relrowsecurity = true
  ) AS tablas_v2_con_rls,

  (
    SELECT count(*)
    FROM pg_policies
    WHERE schemaname = 'v2'
  ) AS policies_v2,

  (
    SELECT count(*)
    FROM pg_policies
    WHERE schemaname = 'v2'
      AND (
        'anon' = ANY (roles)
        OR 'public' = ANY (roles)
      )
  ) AS policies_v2_anon_o_public,

  (
    SELECT count(*)
    FROM information_schema.role_table_grants
    WHERE table_schema = 'v2'
      AND grantee = 'anon'
  ) AS grants_anon_v2,

  pg_catalog.has_schema_privilege(
    'authenticated',
    'v2',
    'USAGE'
  ) AS authenticated_usage_v2,

  (
    SELECT count(*)
    FROM v2.profiles
    WHERE rol = 'ADMIN'
      AND activo = true
  ) AS admins_activos,

  (
    SELECT count(*)
    FROM v2.schema_migrations
    WHERE version = '2.1.06'
  ) AS migracion_registrada;


-- ============================================================================
-- RESULTADO ESPERADO:
--
-- tablas_v2                    = 44
-- tablas_v2_con_rls            = 44
-- policies_v2                  > 0
-- policies_v2_anon_o_public    = 0
-- grants_anon_v2               = 0
-- authenticated_usage_v2       = true
-- admins_activos               >= 1
-- migracion_registrada         = 1
--
-- IMPORTANTE:
-- Si policies_v2_anon_o_public o grants_anon_v2 son distintos de 0,
-- detenerse y revisar antes de continuar.
--
-- Próximo archivo:
--   07_storage.sql
--
-- Ahí:
--   - limpiaremos policies históricas del bucket evidencias
--   - mantendremos el bucket PRIVADO
--   - crearemos rutas V2 namespaced por registro
--   - configuraremos SELECT/INSERT/DELETE según RLS y roles
-- ============================================================================
