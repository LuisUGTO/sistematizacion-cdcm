-- ============================================================================
-- VINCULACIÓN CULTURAL 2.0
-- 05a_hotfix_audit_current_user.sql
-- Hotfix de funciones de auditoría instaladas por 05_functions_triggers.sql
--
-- CAUSA:
--   pg_catalog.current_user es sintaxis inválida en PostgreSQL.
--   CURRENT_USER es una palabra especial y debe usarse sin prefijo de schema.
--
-- CORRECCIÓN:
--   COALESCE(auth.jwt() ->> 'email', CURRENT_USER::text)
--
-- ESTE HOTFIX:
--   ✓ reemplaza únicamente 6 funciones de auditoría
--   ✓ conserva triggers, tablas, RLS y datos
--   ✓ no toca V1
--   ✓ registra la corrección como 2.1.05a
-- ============================================================================

BEGIN;

SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '120s';


-- ============================================================================
-- 01. AUDITORÍA GENÉRICA DE CATÁLOGOS / CONFIGURACIÓN
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
-- 02. AUDITORÍA DE PERFILES / ROLES
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
-- 03. AUDITORÍA DEL REGISTRO NÚCLEO
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
-- 04. AUDITORÍA DE DETALLES OPERATIVOS
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
-- 05. AUDITORÍA DE EVIDENCIAS
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
-- 06. AUDITORÍA DE IMPORTACIONES
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
-- 07. MANTENER FUNCIONES NO INVOCABLES DESDE API
-- ============================================================================

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
-- 08. REGISTRO DEL HOTFIX
-- ============================================================================

INSERT INTO v2.schema_migrations (
  version,
  descripcion
)
VALUES (
  '2.1.05a',
  'Hotfix auditoría: reemplaza pg_catalog.current_user por CURRENT_USER::text.'
)
ON CONFLICT (version) DO NOTHING;


COMMIT;


-- ============================================================================
-- 09. VERIFICACIÓN
-- ============================================================================

SELECT
  'V2.1 - 05a audit hotfix' AS instalacion,

  (
    SELECT count(*)
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'v2'
      AND p.proname IN (
        'audit_catalog_change',
        'audit_profile_change',
        'audit_registro_change',
        'audit_operational_change',
        'audit_evidence_change',
        'audit_import_change'
      )
  ) AS funciones_auditoria,

  (
    SELECT count(*)
    FROM pg_proc p
    JOIN pg_namespace n
      ON n.oid = p.pronamespace
    WHERE n.nspname = 'v2'
      AND p.proname IN (
        'audit_catalog_change',
        'audit_profile_change',
        'audit_registro_change',
        'audit_operational_change',
        'audit_evidence_change',
        'audit_import_change'
      )
      AND pg_get_functiondef(p.oid) ILIKE '%pg_catalog.current_user%'
  ) AS funciones_con_bug,

  (
    SELECT count(*)
    FROM v2.schema_migrations
    WHERE version = '2.1.05a'
  ) AS hotfix_registrado;


-- RESULTADO ESPERADO:
-- funciones_auditoria = 6
-- funciones_con_bug   = 0
-- hotfix_registrado   = 1
-- ============================================================================
