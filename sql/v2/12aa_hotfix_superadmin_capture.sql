-- ============================================================================
-- HOTFIX 7.7.2.1 - SUPERADMIN PUEDE CAPTURAR Y EDITAR (CORREGIDO)
-- Ejecutar una sola vez en Supabase SQL Editor.
-- El intento anterior no aplicó cambios: su transacción se revirtió completa.
-- ============================================================================

BEGIN;

DO $$
DECLARE
  v_name TEXT;
  v_definition TEXT;
BEGIN
  SELECT pg_get_functiondef('v2.rpc_create_borrador(jsonb)'::regprocedure)
  INTO v_definition;

  IF position('v_role NOT IN (''ADMIN'', ''CAPTURISTA'')' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'PRECONDICION: no se reconoció la regla de roles esperada en rpc_create_borrador.';
  END IF;

  v_definition := replace(
    v_definition,
    'v_role NOT IN (''ADMIN'', ''CAPTURISTA'')',
    'v_role NOT IN (''SUPERADMIN'', ''ADMIN'', ''CAPTURISTA'')'
  );
  EXECUTE v_definition;

  FOREACH v_name IN ARRAY ARRAY[
    'v2_private.can_read_record(uuid)',
    'v2_private.can_edit_record(uuid)',
    'v2_private.can_create_record(uuid,uuid)',
    'v2_private.can_manage_record(uuid)',
    'v2_private.can_manage_import_job(uuid)'
  ]
  LOOP
    SELECT pg_get_functiondef(v_name::regprocedure) INTO v_definition;
    IF position('IF v_role = ''ADMIN'' THEN' IN v_definition) = 0 THEN
      RAISE EXCEPTION 'PRECONDICION: no se reconoció la regla ADMIN en %.', v_name;
    END IF;
    v_definition := replace(
      v_definition,
      'IF v_role = ''ADMIN'' THEN',
      'IF v_role IN (''SUPERADMIN'', ''ADMIN'') THEN'
    );
    EXECUTE v_definition;
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

-- Resultado esperado: true | true | true | 1
SELECT
  position('SUPERADMIN' IN pg_get_functiondef('v2.rpc_create_borrador(jsonb)'::regprocedure)) > 0 AS superadmin_puede_capturar,
  position('SUPERADMIN' IN pg_get_functiondef('v2_private.can_edit_record(uuid)'::regprocedure)) > 0 AS superadmin_puede_editar,
  position('SUPERADMIN' IN pg_get_functiondef('v2_private.can_read_record(uuid)'::regprocedure)) > 0 AS superadmin_puede_consultar,
  (SELECT count(*) FROM v2.schema_migrations WHERE version = '2.1.12aa') AS migracion_registrada;
