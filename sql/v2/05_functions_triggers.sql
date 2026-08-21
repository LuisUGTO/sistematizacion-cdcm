-- ============================================================================
-- VINCULACIÓN CULTURAL 2.0
-- 05_functions_triggers.sql
-- Automatización, folios, perfiles, validación y auditoría
-- Secretaría de Cultura de Guanajuato
--
-- REQUIERE:
--   01_core_schema.sql
--   02_catalogs.sql
--   03_operation_modules.sql
--   04_indicators.sql
--
-- IMPLEMENTA:
--   ✓ updated_at automático
--   ✓ updated_by automático donde aplica
--   ✓ row_version en registros
--   ✓ folio institucional atómico
--   ✓ identidad de usuario en nuevas capturas
--   ✓ sincronización auth.users -> v2.profiles
--   ✓ backfill inicial de usuarios existentes
--   ✓ control de transiciones de estatus
--   ✓ historial automático de validaciones
--   ✓ auditoría de perfiles, catálogos, registros, evidencias e importaciones
--   ✓ audit_log inmutable
--
-- PRINCIPIO DE SEGURIDAD:
--   Las funciones SECURITY DEFINER usan search_path vacío y referencias
--   explícitas de schema.
--
-- NO HACE:
--   ✗ no cambia las policies V1
--   ✗ no abre todavía permisos del frontend
--   ✗ no modifica Storage
--   ✗ no migra los 317 registros V1
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
     OR to_regclass('v2.audit_log') IS NULL
     OR to_regclass('v2.folio_sequences') IS NULL
     OR to_regclass('v2.cat_indicadores') IS NULL THEN

    RAISE EXCEPTION
      'PRECONDICIÓN FALLIDA: faltan objetos de 01-04. No continúe.';
  END IF;
END
$$;


-- ============================================================================
-- 01. AMPLIAR CATÁLOGO DE ACCIONES DE AUDITORÍA
-- V2 permitirá auditar DELETE físico aunque la operación normal sea soft delete.
-- ============================================================================

ALTER TABLE v2.audit_log
  DROP CONSTRAINT IF EXISTS audit_log_accion_check;

ALTER TABLE v2.audit_log
  DROP CONSTRAINT IF EXISTS ck_v2_audit_accion;

ALTER TABLE v2.audit_log
  ADD CONSTRAINT ck_v2_audit_accion
  CHECK (
    accion IN (
      'INSERT',
      'UPDATE',
      'DELETE',
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
  );


-- ============================================================================
-- 02. updated_at SIMPLE
-- Para tablas que tienen updated_at pero no updated_by.
-- ============================================================================

CREATE OR REPLACE FUNCTION v2.touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  NEW.updated_at := pg_catalog.now();
  RETURN NEW;
END;
$$;


-- ============================================================================
-- 03. updated_at + updated_by
-- Solo se conecta a tablas que tienen ambos campos.
-- ============================================================================

CREATE OR REPLACE FUNCTION v2.touch_updated_metadata()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  NEW.updated_at := pg_catalog.now();

  IF auth.uid() IS NOT NULL THEN
    NEW.updated_by := auth.uid();
  END IF;

  RETURN NEW;
END;
$$;


-- ============================================================================
-- 04. ACTUALIZACIÓN ESPECIAL DE v2.registros
-- Incrementa row_version para concurrencia optimista.
-- ============================================================================

CREATE OR REPLACE FUNCTION v2.touch_registro()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  NEW.updated_at := pg_catalog.now();
  NEW.row_version := OLD.row_version + 1;

  IF auth.uid() IS NOT NULL THEN
    NEW.updated_by := auth.uid();
  END IF;

  RETURN NEW;
END;
$$;


-- ============================================================================
-- 05. FOLIO INSTITUCIONAL
--
-- Ejemplo:
--   SC-V-2026-000001
--
-- La tabla folio_sequences se bloquea/actualiza transaccionalmente.
-- Los folios son únicos y atómicos.
-- No se promete ausencia absoluta de huecos si una transacción se revierte.
-- ============================================================================

CREATE OR REPLACE FUNCTION v2.next_folio(p_ejercicio INTEGER)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_numero BIGINT;
BEGIN
  IF p_ejercicio IS NULL OR p_ejercicio < 2000 OR p_ejercicio > 2100 THEN
    RAISE EXCEPTION 'Ejercicio inválido para folio: %', p_ejercicio;
  END IF;

  INSERT INTO v2.folio_sequences (
    ejercicio,
    ultimo_numero,
    updated_at
  )
  VALUES (
    p_ejercicio,
    1,
    pg_catalog.now()
  )
  ON CONFLICT (ejercicio)
  DO UPDATE SET
    ultimo_numero = v2.folio_sequences.ultimo_numero + 1,
    updated_at = pg_catalog.now()
  RETURNING ultimo_numero
  INTO v_numero;

  RETURN pg_catalog.format(
    'SC-V-%s-%s',
    p_ejercicio,
    pg_catalog.lpad(v_numero::TEXT, 6, '0')
  );
END;
$$;


-- ============================================================================
-- 06. PREPARAR INSERT DE REGISTRO
-- - fuerza identidad del usuario autenticado
-- - genera folio si no se proporcionó uno
-- - preserva UUID suministrado por cliente offline
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

  IF NEW.folio IS NULL OR pg_catalog.btrim(NEW.folio) = '' THEN
    NEW.folio := v2.next_folio(NEW.periodo_anio);
  END IF;

  NEW.created_at := COALESCE(NEW.created_at, pg_catalog.now());
  NEW.updated_at := pg_catalog.now();
  NEW.row_version := 1;

  RETURN NEW;
END;
$$;


-- ============================================================================
-- 07. CONTROL DE TRANSICIONES DE VALIDACIÓN
--
-- Flujo institucional:
-- BORRADOR -> CAPTURADO -> EN_REVISION -> VALIDADO
--                               |
--                               -> OBSERVADO -> CORREGIDO -> EN_REVISION
--
-- ANULADO es final.
-- VALIDADO puede pasar a ANULADO; una reapertura futura deberá hacerse mediante
-- procedimiento administrativo específico, no con UPDATE libre.
-- ============================================================================

CREATE OR REPLACE FUNCTION v2.validate_registro_transition()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_valida BOOLEAN := false;
BEGIN
  IF NEW.estatus IS NOT DISTINCT FROM OLD.estatus THEN
    RETURN NEW;
  END IF;

  v_valida :=
    CASE OLD.estatus

      WHEN 'BORRADOR' THEN
        NEW.estatus IN ('CAPTURADO', 'ANULADO')

      WHEN 'CAPTURADO' THEN
        NEW.estatus IN ('EN_REVISION', 'ANULADO')

      WHEN 'EN_REVISION' THEN
        NEW.estatus IN ('VALIDADO', 'OBSERVADO', 'ANULADO')

      WHEN 'OBSERVADO' THEN
        NEW.estatus IN ('CORREGIDO', 'ANULADO')

      WHEN 'CORREGIDO' THEN
        NEW.estatus IN ('EN_REVISION', 'ANULADO')

      WHEN 'VALIDADO' THEN
        NEW.estatus IN ('ANULADO')

      WHEN 'ANULADO' THEN
        false

      ELSE
        false
    END;

  IF NOT v_valida THEN
    RAISE EXCEPTION
      'Transición de estatus no permitida: % -> %',
      OLD.estatus,
      NEW.estatus;
  END IF;

  RETURN NEW;
END;
$$;


-- ============================================================================
-- 08. HISTORIAL AUTOMÁTICO DE VALIDACIÓN
-- SECURITY DEFINER porque registro_validaciones permanecerá protegido por RLS.
-- ============================================================================

CREATE OR REPLACE FUNCTION v2.log_registro_validation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN

    INSERT INTO v2.registro_validaciones (
      registro_id,
      estatus_anterior,
      estatus_nuevo,
      observacion,
      usuario_id,
      created_at
    )
    VALUES (
      NEW.id,
      NULL,
      NEW.estatus,
      'Estatus inicial del registro.',
      auth.uid(),
      pg_catalog.now()
    );

  ELSIF TG_OP = 'UPDATE'
        AND NEW.estatus IS DISTINCT FROM OLD.estatus THEN

    INSERT INTO v2.registro_validaciones (
      registro_id,
      estatus_anterior,
      estatus_nuevo,
      usuario_id,
      created_at
    )
    VALUES (
      NEW.id,
      OLD.estatus,
      NEW.estatus,
      auth.uid(),
      pg_catalog.now()
    );

  END IF;

  RETURN NEW;
END;
$$;


-- ============================================================================
-- 09. SINCRONIZACIÓN auth.users -> v2.profiles
--
-- V1 conserva public.handle_new_user y su trigger.
-- Este es un SEGUNDO trigger independiente para V2.
--
-- Si por algún motivo la sincronización V2 falla, se genera WARNING y se
-- permite continuar el alta Auth. Así un error de V2 no derriba el login.
-- ============================================================================

CREATE OR REPLACE FUNCTION v2.sync_auth_user_v2()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_nombre TEXT;
BEGIN
  v_nombre := COALESCE(
    NEW.raw_user_meta_data ->> 'full_name',
    NEW.raw_user_meta_data ->> 'name'
  );

  BEGIN
    INSERT INTO v2.profiles (
      user_id,
      email,
      nombre,
      rol,
      activo,
      created_at,
      updated_at
    )
    VALUES (
      NEW.id,
      NEW.email,
      v_nombre,
      'CAPTURISTA',
      true,
      COALESCE(NEW.created_at, pg_catalog.now()),
      pg_catalog.now()
    )
    ON CONFLICT (user_id)
    DO UPDATE SET
      email = EXCLUDED.email,
      nombre = COALESCE(v2.profiles.nombre, EXCLUDED.nombre),
      updated_at = pg_catalog.now();

  EXCEPTION
    WHEN OTHERS THEN
      RAISE WARNING
        'V2 profile sync falló para auth user %: %',
        NEW.id,
        SQLERRM;
  END;

  RETURN NEW;
END;
$$;


-- ============================================================================
-- 10. BACKFILL CONTROLADO DE LOS USUARIOS YA EXISTENTES
--
-- Copia roles existentes de public.profiles SOLO en la primera inserción V2.
-- Si 05 se reejecuta, no degrada/modifica roles que ya se administren en V2.
-- ============================================================================

INSERT INTO v2.profiles (
  user_id,
  email,
  nombre,
  rol,
  activo,
  created_at,
  updated_at
)
SELECT
  u.id,
  u.email,
  p.nombre,
  COALESCE(p.rol, 'CAPTURISTA'),
  COALESCE(p.activo, true),
  COALESCE(p.created_at, u.created_at, pg_catalog.now()),
  COALESCE(p.updated_at, pg_catalog.now())
FROM auth.users u
LEFT JOIN public.profiles p
  ON p.user_id = u.id
ON CONFLICT (user_id)
DO UPDATE SET
  email = EXCLUDED.email,
  nombre = COALESCE(v2.profiles.nombre, EXCLUDED.nombre),
  updated_at = pg_catalog.now();


-- ============================================================================
-- 11. TRIGGERS AUTH V2
-- ============================================================================

DROP TRIGGER IF EXISTS on_auth_user_created_v2
ON auth.users;

CREATE TRIGGER on_auth_user_created_v2
AFTER INSERT ON auth.users
FOR EACH ROW
EXECUTE FUNCTION v2.sync_auth_user_v2();


DROP TRIGGER IF EXISTS on_auth_user_email_updated_v2
ON auth.users;

CREATE TRIGGER on_auth_user_email_updated_v2
AFTER UPDATE OF email ON auth.users
FOR EACH ROW
WHEN (OLD.email IS DISTINCT FROM NEW.email)
EXECUTE FUNCTION v2.sync_auth_user_v2();


-- ============================================================================
-- 12. AUDIT LOG INMUTABLE
-- ============================================================================

CREATE OR REPLACE FUNCTION v2.prevent_audit_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  RAISE EXCEPTION
    'v2.audit_log es inmutable. No se permiten UPDATE/DELETE.';
END;
$$;

DROP TRIGGER IF EXISTS trg_v2_audit_log_immutable
ON v2.audit_log;

CREATE TRIGGER trg_v2_audit_log_immutable
BEFORE UPDATE OR DELETE ON v2.audit_log
FOR EACH ROW
EXECUTE FUNCTION v2.prevent_audit_mutation();


-- ============================================================================
-- 13. AUDITORÍA GENÉRICA DE CATÁLOGOS / CONFIGURACIÓN
-- ============================================================================

CREATE OR REPLACE FUNCTION v2.audit_catalog_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_old       JSONB;
  v_new       JSONB;
  v_record_id TEXT;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_old := pg_catalog.to_jsonb(OLD);
    v_new := NULL;
  ELSIF TG_OP = 'INSERT' THEN
    v_old := NULL;
    v_new := pg_catalog.to_jsonb(NEW);
  ELSE
    v_old := pg_catalog.to_jsonb(OLD);
    v_new := pg_catalog.to_jsonb(NEW);
  END IF;

  v_record_id := COALESCE(
    v_new ->> 'id',
    v_new ->> 'user_id',
    v_new ->> 'registro_id',
    v_new ->> 'persona_id',
    v_old ->> 'id',
    v_old ->> 'user_id',
    v_old ->> 'registro_id',
    v_old ->> 'persona_id'
  );

  INSERT INTO v2.audit_log (
    schema_name,
    table_name,
    record_id,
    accion,
    user_id,
    user_email,
    valor_anterior,
    valor_nuevo,
    metadata,
    created_at
  )
  VALUES (
    TG_TABLE_SCHEMA,
    TG_TABLE_NAME,
    v_record_id,
    'CATALOG_CHANGE',
    auth.uid(),
    COALESCE(auth.jwt() ->> 'email', CURRENT_USER::text),
    v_old,
    v_new,
    pg_catalog.jsonb_build_object(
      'operation', TG_OP,
      'trigger', TG_NAME
    ),
    pg_catalog.now()
  );

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;

  RETURN NEW;
END;
$$;


-- ============================================================================
-- 14. AUDITORÍA DE PERFILES / ROLES
-- ============================================================================

CREATE OR REPLACE FUNCTION v2.audit_profile_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_old       JSONB;
  v_new       JSONB;
  v_action    TEXT;
  v_record_id TEXT;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_old := pg_catalog.to_jsonb(OLD);
    v_new := NULL;
    v_action := 'ROLE_CHANGE';
    v_record_id := OLD.user_id::TEXT;

  ELSIF TG_OP = 'INSERT' THEN
    v_old := NULL;
    v_new := pg_catalog.to_jsonb(NEW);
    v_action := 'INSERT';
    v_record_id := NEW.user_id::TEXT;

  ELSE
    v_old := pg_catalog.to_jsonb(OLD);
    v_new := pg_catalog.to_jsonb(NEW);
    v_record_id := NEW.user_id::TEXT;

    IF NEW.rol IS DISTINCT FROM OLD.rol
       OR NEW.activo IS DISTINCT FROM OLD.activo THEN
      v_action := 'ROLE_CHANGE';
    ELSE
      v_action := 'UPDATE';
    END IF;
  END IF;

  INSERT INTO v2.audit_log (
    schema_name,
    table_name,
    record_id,
    accion,
    user_id,
    user_email,
    valor_anterior,
    valor_nuevo,
    metadata,
    created_at
  )
  VALUES (
    TG_TABLE_SCHEMA,
    TG_TABLE_NAME,
    v_record_id,
    v_action,
    auth.uid(),
    COALESCE(auth.jwt() ->> 'email', CURRENT_USER::text),
    v_old,
    v_new,
    pg_catalog.jsonb_build_object('operation', TG_OP),
    pg_catalog.now()
  );

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;

  RETURN NEW;
END;
$$;


-- ============================================================================
-- 15. AUDITORÍA DEL REGISTRO NÚCLEO
-- ============================================================================

CREATE OR REPLACE FUNCTION v2.audit_registro_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_old    JSONB;
  v_new    JSONB;
  v_action TEXT;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_old := pg_catalog.to_jsonb(OLD);
    v_new := NULL;
    v_action := 'DELETE';

  ELSIF TG_OP = 'INSERT' THEN
    v_old := NULL;
    v_new := pg_catalog.to_jsonb(NEW);
    v_action := 'INSERT';

  ELSE
    v_old := pg_catalog.to_jsonb(OLD);
    v_new := pg_catalog.to_jsonb(NEW);

    IF NEW.estatus IS DISTINCT FROM OLD.estatus THEN
      v_action :=
        CASE NEW.estatus
          WHEN 'VALIDADO' THEN 'VALIDATE'
          WHEN 'OBSERVADO' THEN 'OBSERVE'
          WHEN 'ANULADO' THEN 'ANNUL'
          ELSE 'STATUS_CHANGE'
        END;
    ELSE
      v_action := 'UPDATE';
    END IF;
  END IF;

  INSERT INTO v2.audit_log (
    schema_name,
    table_name,
    record_id,
    accion,
    user_id,
    user_email,
    valor_anterior,
    valor_nuevo,
    metadata,
    created_at
  )
  VALUES (
    TG_TABLE_SCHEMA,
    TG_TABLE_NAME,
    COALESCE(NEW.id, OLD.id)::TEXT,
    v_action,
    auth.uid(),
    COALESCE(auth.jwt() ->> 'email', CURRENT_USER::text),
    v_old,
    v_new,
    pg_catalog.jsonb_build_object('operation', TG_OP),
    pg_catalog.now()
  );

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;

  RETURN NEW;
END;
$$;


-- ============================================================================
-- 16. AUDITORÍA DE DETALLES OPERATIVOS
-- ============================================================================

CREATE OR REPLACE FUNCTION v2.audit_operational_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_old       JSONB;
  v_new       JSONB;
  v_record_id TEXT;
  v_action    TEXT;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_old := pg_catalog.to_jsonb(OLD);
    v_new := NULL;
    v_action := 'DELETE';

  ELSIF TG_OP = 'INSERT' THEN
    v_old := NULL;
    v_new := pg_catalog.to_jsonb(NEW);
    v_action := 'INSERT';

  ELSE
    v_old := pg_catalog.to_jsonb(OLD);
    v_new := pg_catalog.to_jsonb(NEW);
    v_action := 'UPDATE';
  END IF;

  v_record_id := COALESCE(
    v_new ->> 'registro_id',
    v_new ->> 'id',
    v_old ->> 'registro_id',
    v_old ->> 'id'
  );

  INSERT INTO v2.audit_log (
    schema_name,
    table_name,
    record_id,
    accion,
    user_id,
    user_email,
    valor_anterior,
    valor_nuevo,
    metadata,
    created_at
  )
  VALUES (
    TG_TABLE_SCHEMA,
    TG_TABLE_NAME,
    v_record_id,
    v_action,
    auth.uid(),
    COALESCE(auth.jwt() ->> 'email', CURRENT_USER::text),
    v_old,
    v_new,
    pg_catalog.jsonb_build_object('operation', TG_OP),
    pg_catalog.now()
  );

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;

  RETURN NEW;
END;
$$;


-- ============================================================================
-- 17. AUDITORÍA DE EVIDENCIAS
-- ============================================================================

CREATE OR REPLACE FUNCTION v2.audit_evidence_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_old JSONB;
  v_new JSONB;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_old := pg_catalog.to_jsonb(OLD);
    v_new := NULL;
  ELSIF TG_OP = 'INSERT' THEN
    v_old := NULL;
    v_new := pg_catalog.to_jsonb(NEW);
  ELSE
    v_old := pg_catalog.to_jsonb(OLD);
    v_new := pg_catalog.to_jsonb(NEW);
  END IF;

  INSERT INTO v2.audit_log (
    schema_name,
    table_name,
    record_id,
    accion,
    user_id,
    user_email,
    valor_anterior,
    valor_nuevo,
    metadata,
    created_at
  )
  VALUES (
    TG_TABLE_SCHEMA,
    TG_TABLE_NAME,
    COALESCE(NEW.registro_id, OLD.registro_id)::TEXT,
    'EVIDENCE_CHANGE',
    auth.uid(),
    COALESCE(auth.jwt() ->> 'email', CURRENT_USER::text),
    v_old,
    v_new,
    pg_catalog.jsonb_build_object('operation', TG_OP),
    pg_catalog.now()
  );

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;

  RETURN NEW;
END;
$$;


-- ============================================================================
-- 18. AUDITORÍA DE IMPORTACIONES
-- Solo auditamos la cabecera import_jobs, no cada fila de staging.
-- ============================================================================

CREATE OR REPLACE FUNCTION v2.audit_import_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_old JSONB;
  v_new JSONB;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_old := pg_catalog.to_jsonb(OLD);
    v_new := NULL;
  ELSIF TG_OP = 'INSERT' THEN
    v_old := NULL;
    v_new := pg_catalog.to_jsonb(NEW);
  ELSE
    v_old := pg_catalog.to_jsonb(OLD);
    v_new := pg_catalog.to_jsonb(NEW);
  END IF;

  INSERT INTO v2.audit_log (
    schema_name,
    table_name,
    record_id,
    accion,
    user_id,
    user_email,
    valor_anterior,
    valor_nuevo,
    metadata,
    created_at
  )
  VALUES (
    TG_TABLE_SCHEMA,
    TG_TABLE_NAME,
    COALESCE(NEW.id, OLD.id)::TEXT,
    'IMPORT',
    auth.uid(),
    COALESCE(auth.jwt() ->> 'email', CURRENT_USER::text),
    v_old,
    v_new,
    pg_catalog.jsonb_build_object('operation', TG_OP),
    pg_catalog.now()
  );

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;

  RETURN NEW;
END;
$$;


-- ============================================================================
-- 19. TRIGGERS updated_at / updated_by
-- ============================================================================

DO $$
DECLARE
  tbl TEXT;
BEGIN
  -- Tablas con updated_at + updated_by
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
    'registro_taller',
    'registro_proyecto',
    'proyecto_objetivos',
    'proyecto_actividades',
    'registro_reunion',
    'registro_intercambio',
    'cat_indicadores',
    'indicadores_version',
    'metas_indicador',
    'accion_indicador',
    'registro_indicador_aportes'
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
  END LOOP;

  -- Tablas con updated_at pero sin updated_by
  FOREACH tbl IN ARRAY ARRAY[
    'profiles',
    'import_jobs',
    'import_staging',
    'registro_poblacion'
  ]
  LOOP
    EXECUTE pg_catalog.format(
      'DROP TRIGGER IF EXISTS trg_v2_touch_updated_at ON v2.%I',
      tbl
    );

    EXECUTE pg_catalog.format(
      'CREATE TRIGGER trg_v2_touch_updated_at
       BEFORE UPDATE ON v2.%I
       FOR EACH ROW
       EXECUTE FUNCTION v2.touch_updated_at()',
      tbl
    );
  END LOOP;
END
$$;


-- ============================================================================
-- 20. TRIGGERS DEL REGISTRO NÚCLEO
-- ============================================================================

DROP TRIGGER IF EXISTS trg_v2_registro_prepare_insert
ON v2.registros;

CREATE TRIGGER trg_v2_registro_prepare_insert
BEFORE INSERT ON v2.registros
FOR EACH ROW
EXECUTE FUNCTION v2.prepare_registro_insert();


DROP TRIGGER IF EXISTS trg_v2_registro_validate_transition
ON v2.registros;

CREATE TRIGGER trg_v2_registro_validate_transition
BEFORE UPDATE OF estatus ON v2.registros
FOR EACH ROW
WHEN (OLD.estatus IS DISTINCT FROM NEW.estatus)
EXECUTE FUNCTION v2.validate_registro_transition();


DROP TRIGGER IF EXISTS trg_v2_registro_touch
ON v2.registros;

CREATE TRIGGER trg_v2_registro_touch
BEFORE UPDATE ON v2.registros
FOR EACH ROW
EXECUTE FUNCTION v2.touch_registro();


DROP TRIGGER IF EXISTS trg_v2_registro_validation_history
ON v2.registros;

CREATE TRIGGER trg_v2_registro_validation_history
AFTER INSERT OR UPDATE OF estatus ON v2.registros
FOR EACH ROW
EXECUTE FUNCTION v2.log_registro_validation();


DROP TRIGGER IF EXISTS trg_v2_registro_audit
ON v2.registros;

CREATE TRIGGER trg_v2_registro_audit
AFTER INSERT OR UPDATE OR DELETE ON v2.registros
FOR EACH ROW
EXECUTE FUNCTION v2.audit_registro_change();


-- ============================================================================
-- 21. AUDITORÍA DE PROFILES
-- ============================================================================

DROP TRIGGER IF EXISTS trg_v2_profiles_audit
ON v2.profiles;

CREATE TRIGGER trg_v2_profiles_audit
AFTER INSERT OR UPDATE OR DELETE ON v2.profiles
FOR EACH ROW
EXECUTE FUNCTION v2.audit_profile_change();


-- ============================================================================
-- 22. AUDITORÍA DE CATÁLOGOS Y CONFIGURACIÓN
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
    'profile_municipios',
    'cat_indicadores',
    'indicadores_version',
    'metas_indicador',
    'accion_indicador'
  ]
  LOOP
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
-- 23. AUDITORÍA DE DETALLE OPERATIVO
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
    'registro_intercambio',
    'registro_indicador_aportes'
  ]
  LOOP
    EXECUTE pg_catalog.format(
      'DROP TRIGGER IF EXISTS trg_v2_operational_audit ON v2.%I',
      tbl
    );

    EXECUTE pg_catalog.format(
      'CREATE TRIGGER trg_v2_operational_audit
       AFTER INSERT OR UPDATE OR DELETE ON v2.%I
       FOR EACH ROW
       EXECUTE FUNCTION v2.audit_operational_change()',
      tbl
    );
  END LOOP;
END
$$;


-- ============================================================================
-- 24. AUDITORÍA DE EVIDENCIAS E IMPORTACIONES
-- ============================================================================

DROP TRIGGER IF EXISTS trg_v2_evidence_audit
ON v2.registro_evidencias;

CREATE TRIGGER trg_v2_evidence_audit
AFTER INSERT OR UPDATE OR DELETE ON v2.registro_evidencias
FOR EACH ROW
EXECUTE FUNCTION v2.audit_evidence_change();


DROP TRIGGER IF EXISTS trg_v2_import_jobs_audit
ON v2.import_jobs;

CREATE TRIGGER trg_v2_import_jobs_audit
AFTER INSERT OR UPDATE OR DELETE ON v2.import_jobs
FOR EACH ROW
EXECUTE FUNCTION v2.audit_import_change();


-- ============================================================================
-- 25. RESTRINGIR EJECUCIÓN DIRECTA DE FUNCIONES
--
-- Los triggers pueden ejecutar sus funciones sin exponerlas como RPC pública.
-- Las funciones que necesitemos llamar desde frontend se concederán después,
-- de forma individual.
-- ============================================================================

REVOKE ALL ON FUNCTION v2.touch_updated_at()
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION v2.touch_updated_metadata()
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION v2.touch_registro()
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION v2.next_folio(INTEGER)
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION v2.prepare_registro_insert()
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION v2.validate_registro_transition()
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION v2.log_registro_validation()
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION v2.sync_auth_user_v2()
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION v2.prevent_audit_mutation()
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION v2.audit_catalog_change()
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION v2.audit_profile_change()
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION v2.audit_registro_change()
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION v2.audit_operational_change()
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION v2.audit_evidence_change()
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION v2.audit_import_change()
  FROM PUBLIC, anon, authenticated;


-- ============================================================================
-- 26. REGISTRO DE MIGRACIÓN
-- ============================================================================

INSERT INTO v2.schema_migrations (
  version,
  descripcion
)
VALUES (
  '2.1.05',
  '05_functions_triggers.sql - Automatización, Auth V2, folios, validación y auditoría.'
)
ON CONFLICT (version) DO NOTHING;


COMMIT;


-- ============================================================================
-- 27. VERIFICACIÓN POST-INSTALACIÓN
-- ============================================================================

SELECT
  'V2.1 - 05_functions_triggers' AS instalacion,

  (SELECT count(*) FROM auth.users) AS auth_users,

  (SELECT count(*) FROM v2.profiles) AS profiles_v2,

  (
    SELECT count(*)
    FROM auth.users u
    LEFT JOIN v2.profiles p
      ON p.user_id = u.id
    WHERE p.user_id IS NULL
  ) AS auth_sin_profile_v2,

  (
    to_regprocedure('v2.next_folio(integer)') IS NOT NULL
  ) AS funcion_folio_existe,

  EXISTS (
    SELECT 1
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'auth'
      AND c.relname = 'users'
      AND t.tgname = 'on_auth_user_created_v2'
      AND NOT t.tgisinternal
  ) AS trigger_auth_v2_existe,

  EXISTS (
    SELECT 1
    FROM pg_trigger t
    WHERE t.tgrelid = 'v2.registros'::regclass
      AND t.tgname = 'trg_v2_registro_validate_transition'
      AND NOT t.tgisinternal
  ) AS trigger_validacion_existe,

  EXISTS (
    SELECT 1
    FROM pg_trigger t
    WHERE t.tgrelid = 'v2.audit_log'::regclass
      AND t.tgname = 'trg_v2_audit_log_immutable'
      AND NOT t.tgisinternal
  ) AS audit_inmutable,

  (
    SELECT count(*)
    FROM v2.schema_migrations
    WHERE version = '2.1.05'
  ) AS migracion_registrada;


-- ============================================================================
-- RESULTADO ESPERADO EN TU ESTADO ACTUAL:
--
-- auth_users                 = 2
-- profiles_v2                = 2
-- auth_sin_profile_v2        = 0
-- funcion_folio_existe       = true
-- trigger_auth_v2_existe     = true
-- trigger_validacion_existe  = true
-- audit_inmutable            = true
-- migracion_registrada       = 1
--
-- Si entre tanto se creó otro usuario:
-- auth_users y profiles_v2 pueden ser >2, pero deben ser IGUALES.
--
-- Próximo archivo:
--   06_rls.sql
--
-- Ese archivo será crítico:
--   - helpers seguros de rol/alcance
--   - GRANT mínimos
--   - policies ADMIN / SUPERVISOR / DIRECTIVO / CAPTURISTA
--   - impedir auto-promoción
--   - alcance por unidad y municipio
-- ============================================================================
