-- ============================================================================
-- HOTFIX 7.7.2.2 - PERMISOS SUPERADMIN (IDEMPOTENTE)
-- Puede ejecutarse aunque algunas funciones ya reconozcan SUPERADMIN.
-- ============================================================================

BEGIN;

DO $$
DECLARE
  v_name TEXT;
  v_definition TEXT;
  v_updated TEXT;
BEGIN
  -- RPC principal de creación.
  SELECT pg_get_functiondef('v2.rpc_create_borrador(jsonb)'::regprocedure)
  INTO v_definition;

  IF position('SUPERADMIN' IN v_definition) = 0 THEN
    v_updated := pg_catalog.regexp_replace(
      v_definition,
      'v_role[[:space:]]+NOT[[:space:]]+IN[[:space:]]*\([[:space:]]*''ADMIN''(::text)?[[:space:]]*,[[:space:]]*''CAPTURISTA''(::text)?[[:space:]]*\)',
      'v_role NOT IN (''SUPERADMIN'', ''ADMIN'', ''CAPTURISTA'')',
      'g'
    );

    IF v_updated = v_definition THEN
      RAISE EXCEPTION 'PRECONDICION: no se reconoció la regla de creación en rpc_create_borrador.';
    END IF;

    EXECUTE v_updated;
  END IF;

  -- Helpers: conserva los ya corregidos y actualiza únicamente los antiguos.
  FOREACH v_name IN ARRAY ARRAY[
    'v2_private.can_read_record(uuid)',
    'v2_private.can_edit_record(uuid)',
    'v2_private.can_create_record(uuid,uuid)',
    'v2_private.can_manage_record(uuid)',
    'v2_private.can_manage_import_job(uuid)'
  ]
  LOOP
    SELECT pg_get_functiondef(v_name::regprocedure) INTO v_definition;

    IF position('SUPERADMIN' IN v_definition) > 0 THEN
      CONTINUE;
    END IF;

    v_updated := pg_catalog.regexp_replace(
      v_definition,
      'v_role[[:space:]]*=[[:space:]]*''ADMIN''(::text)?',
      'v_role IN (''SUPERADMIN'', ''ADMIN'')',
      'g'
    );

    IF v_updated = v_definition THEN
      RAISE EXCEPTION 'PRECONDICION: no se reconoció la regla administrativa en %.', v_name;
    END IF;

    EXECUTE v_updated;
  END LOOP;
END;
$$;

INSERT INTO v2.schema_migrations (version, descripcion)
VALUES (
  '2.1.12aa',
  '12aa_hotfix_superadmin_capture.sql - Alinea permisos operativos de SUPERADMIN con ADMIN.'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;

-- Resultado esperado: true | true | true | true | 1
SELECT
  position('SUPERADMIN' IN pg_get_functiondef('v2.rpc_create_borrador(jsonb)'::regprocedure)) > 0 AS puede_capturar,
  position('SUPERADMIN' IN pg_get_functiondef('v2_private.can_read_record(uuid)'::regprocedure)) > 0 AS puede_consultar,
  position('SUPERADMIN' IN pg_get_functiondef('v2_private.can_edit_record(uuid)'::regprocedure)) > 0 AS puede_editar,
  position('SUPERADMIN' IN pg_get_functiondef('v2_private.can_create_record(uuid,uuid)'::regprocedure)) > 0 AS helper_creacion,
  (SELECT count(*) FROM v2.schema_migrations WHERE version = '2.1.12aa') AS migracion;
