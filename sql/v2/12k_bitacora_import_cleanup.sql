-- ============================================================================
-- VINCULACION CULTURAL V2
-- 12k_bitacora_import_cleanup.sql
-- Etapa 6.5: importacion en Bitacora + depuracion administrativa segura
--
-- INCLUYE:
--   - Habilita edicion y envio a revision de IMPORTACION_EXCEL.
--   - Conserva MIGRACION_V1 como historico de solo lectura.
--   - Agrega previsualizacion y retiro logico individual/masivo para ADMIN.
--   - Nunca realiza DELETE fisico.
-- ============================================================================

BEGIN;

SET LOCAL lock_timeout = '10s';
SET LOCAL statement_timeout = '120s';


DO $$
BEGIN
  IF to_regclass('v2.registros') IS NULL
     OR to_regclass('v2.registro_validaciones') IS NULL
     OR to_regprocedure('v2.rpc_get_registro_editor(uuid)') IS NULL
     OR to_regprocedure('v2.rpc_update_borrador(uuid,integer,jsonb)') IS NULL
     OR to_regprocedure('v2.rpc_submit_borrador(uuid,integer)') IS NULL
     OR to_regprocedure('v2.rpc_import_historial()') IS NULL
     OR to_regprocedure('v2_private.is_admin()') IS NULL THEN
    RAISE EXCEPTION
      'PRECONDICION_FALLIDA: instale primero 12d_draft_workflow.sql y 12j_bulk_excel_import.sql.';
  END IF;
END
$$;


-- ============================================================================
-- 01. IMPORTACIONES EXCEL EDITABLES
--
-- Se reutilizan las funciones vigentes y se cambia unicamente la regla de
-- origen. Esto conserva todas sus validaciones, concurrencia y permisos.
-- ============================================================================

DO $hotfix$
DECLARE
  v_definition TEXT;
BEGIN
  v_definition := pg_catalog.pg_get_functiondef(
    'v2.rpc_get_registro_editor(uuid)'::REGPROCEDURE
  );

  IF pg_catalog.strpos(
       v_definition,
       'r.origen IN (''MANUAL'', ''IMPORTACION_EXCEL'')'
     ) = 0 THEN
    IF pg_catalog.strpos(v_definition, 'r.origen = ''MANUAL''') = 0 THEN
      RAISE EXCEPTION
        'HOTFIX_ABORTADO: no se encontro la regla de origen esperada en rpc_get_registro_editor.';
    END IF;

    v_definition := pg_catalog.replace(
      v_definition,
      'r.origen = ''MANUAL''',
      'r.origen IN (''MANUAL'', ''IMPORTACION_EXCEL'')'
    );
    EXECUTE v_definition;
  END IF;

  v_definition := pg_catalog.pg_get_functiondef(
    'v2.rpc_update_borrador(uuid,integer,jsonb)'::REGPROCEDURE
  );

  IF pg_catalog.strpos(
       v_definition,
       'v_record.origen NOT IN (''MANUAL'', ''IMPORTACION_EXCEL'')'
     ) = 0 THEN
    IF pg_catalog.strpos(
         v_definition,
         'v_record.origen <> ''MANUAL'''
       ) = 0 THEN
      RAISE EXCEPTION
        'HOTFIX_ABORTADO: no se encontro la regla de origen esperada en rpc_update_borrador.';
    END IF;

    v_definition := pg_catalog.replace(
      v_definition,
      'v_record.origen <> ''MANUAL''',
      'v_record.origen NOT IN (''MANUAL'', ''IMPORTACION_EXCEL'')'
    );
    EXECUTE v_definition;
  END IF;

  v_definition := pg_catalog.pg_get_functiondef(
    'v2.rpc_submit_borrador(uuid,integer)'::REGPROCEDURE
  );

  IF pg_catalog.strpos(
       v_definition,
       'v_record.origen NOT IN (''MANUAL'', ''IMPORTACION_EXCEL'')'
     ) = 0 THEN
    IF pg_catalog.strpos(
         v_definition,
         'v_record.origen <> ''MANUAL'''
       ) = 0 THEN
      RAISE EXCEPTION
        'HOTFIX_ABORTADO: no se encontro la regla de origen esperada en rpc_submit_borrador.';
    END IF;

    v_definition := pg_catalog.replace(
      v_definition,
      'v_record.origen <> ''MANUAL''',
      'v_record.origen NOT IN (''MANUAL'', ''IMPORTACION_EXCEL'')'
    );
    EXECUTE v_definition;
  END IF;
END
$hotfix$;


COMMENT ON FUNCTION v2.rpc_get_registro_editor(UUID) IS
'Detalle seguro para editor V2. Admite MANUAL e IMPORTACION_EXCEL; MIGRACION_V1 permanece de solo lectura.';
COMMENT ON FUNCTION v2.rpc_update_borrador(UUID, INTEGER, JSONB) IS
'Actualiza borradores MANUAL o IMPORTACION_EXCEL con concurrencia optimista y validaciones V2.';
COMMENT ON FUNCTION v2.rpc_submit_borrador(UUID, INTEGER) IS
'Envia a revision registros MANUAL o IMPORTACION_EXCEL; protege historicos MIGRACION_V1.';


-- ============================================================================
-- 02. PREVISUALIZAR RETIRO ADMINISTRATIVO
-- ============================================================================

CREATE OR REPLACE FUNCTION v2.rpc_admin_previsualizar_retiro(
  p_registro_ids UUID[]
)
RETURNS TABLE (
  id UUID,
  folio TEXT,
  nombre TEXT,
  origen TEXT,
  estatus TEXT,
  puede_retirar BOOLEAN,
  motivo_bloqueo TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid UUID := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED: se requiere una sesion autenticada.';
  END IF;

  IF NOT v2_private.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_REQUIRED: solo ADMIN puede depurar registros.';
  END IF;

  IF COALESCE(pg_catalog.cardinality(p_registro_ids), 0) = 0 THEN
    RAISE EXCEPTION 'SELECTION_REQUIRED: selecciona al menos un registro.';
  END IF;

  IF pg_catalog.cardinality(p_registro_ids) > 100 THEN
    RAISE EXCEPTION 'SELECTION_TOO_LARGE: revisa hasta 100 registros por operacion.';
  END IF;

  RETURN QUERY
  SELECT
    r.id,
    r.folio,
    r.nombre,
    r.origen,
    r.estatus,
    (
      r.deleted_at IS NULL
      AND r.origen <> 'MIGRACION_V1'
      AND r.estatus <> 'ANULADO'
    ) AS puede_retirar,
    CASE
      WHEN r.deleted_at IS NOT NULL OR r.estatus = 'ANULADO'
        THEN 'El registro ya fue retirado.'
      WHEN r.origen = 'MIGRACION_V1'
        THEN 'Los historicos MIGRACION_V1 estan protegidos.'
      ELSE NULL
    END AS motivo_bloqueo
  FROM v2.registros r
  WHERE r.id = ANY(p_registro_ids)
  ORDER BY r.folio;
END;
$function$;


-- ============================================================================
-- 03. RETIRO LOGICO INDIVIDUAL O MASIVO
-- ============================================================================

CREATE OR REPLACE FUNCTION v2.rpc_admin_retirar_registros(
  p_registro_ids UUID[],
  p_confirmacion TEXT,
  p_motivo TEXT
)
RETURNS TABLE (
  total_retirados INTEGER,
  folios TEXT[],
  retirado_en TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_ids UUID[];
  v_total INTEGER;
  v_existing INTEGER;
  v_confirmation_expected TEXT;
  v_now TIMESTAMPTZ := pg_catalog.now();
  v_folios TEXT[];
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED: se requiere una sesion autenticada.';
  END IF;

  IF NOT v2_private.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_REQUIRED: solo ADMIN puede depurar registros.';
  END IF;

  SELECT pg_catalog.array_agg(DISTINCT selected_id)
  INTO v_ids
  FROM pg_catalog.unnest(COALESCE(p_registro_ids, ARRAY[]::UUID[])) AS selected(selected_id);

  v_total := COALESCE(pg_catalog.cardinality(v_ids), 0);

  IF v_total = 0 THEN
    RAISE EXCEPTION 'SELECTION_REQUIRED: selecciona al menos un registro.';
  END IF;

  IF v_total > 100 THEN
    RAISE EXCEPTION 'SELECTION_TOO_LARGE: retira hasta 100 registros por operacion.';
  END IF;

  IF pg_catalog.length(pg_catalog.btrim(COALESCE(p_motivo, ''))) < 12 THEN
    RAISE EXCEPTION 'REASON_REQUIRED: documenta el motivo con al menos 12 caracteres.';
  END IF;

  v_confirmation_expected := CASE
    WHEN v_total = 1 THEN 'RETIRAR 1 REGISTRO'
    ELSE pg_catalog.format('RETIRAR %s REGISTROS', v_total)
  END;

  IF pg_catalog.upper(pg_catalog.btrim(COALESCE(p_confirmacion, '')))
       IS DISTINCT FROM v_confirmation_expected THEN
    RAISE EXCEPTION
      'CONFIRMATION_REQUIRED: escribe exactamente %.',
      v_confirmation_expected;
  END IF;

  -- Bloquea los expedientes elegidos durante toda la operacion.
  PERFORM 1
  FROM v2.registros r
  WHERE r.id = ANY(v_ids)
  FOR UPDATE;

  SELECT count(*)::INTEGER
  INTO v_existing
  FROM v2.registros r
  WHERE r.id = ANY(v_ids);

  IF v_existing <> v_total THEN
    RAISE EXCEPTION 'RECORD_NOT_FOUND: uno o mas registros no existen.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM v2.registros r
    WHERE r.id = ANY(v_ids)
      AND (
        r.deleted_at IS NOT NULL
        OR r.estatus = 'ANULADO'
        OR r.origen = 'MIGRACION_V1'
      )
  ) THEN
    RAISE EXCEPTION
      'PROTECTED_RECORD: la seleccion contiene historicos MIGRACION_V1 o registros ya retirados.';
  END IF;

  SELECT pg_catalog.array_agg(r.folio ORDER BY r.folio)
  INTO v_folios
  FROM v2.registros r
  WHERE r.id = ANY(v_ids);

  UPDATE v2.registros r
  SET
    estatus = 'ANULADO',
    deleted_at = v_now,
    deleted_by = v_uid,
    updated_by = v_uid,
    metadata = COALESCE(r.metadata, '{}'::JSONB) || pg_catalog.jsonb_build_object(
      'retiro_administrativo',
      pg_catalog.jsonb_build_object(
        'motivo', pg_catalog.btrim(p_motivo),
        'usuario_id', v_uid,
        'fecha', v_now,
        'fase', '6.5'
      )
    )
  WHERE r.id = ANY(v_ids);

  UPDATE v2.registro_validaciones rv
  SET observacion = pg_catalog.format(
    'Retiro administrativo: %s',
    pg_catalog.btrim(p_motivo)
  )
  WHERE rv.id IN (
    SELECT DISTINCT ON (rv2.registro_id) rv2.id
    FROM v2.registro_validaciones rv2
    WHERE rv2.registro_id = ANY(v_ids)
      AND rv2.estatus_nuevo = 'ANULADO'
    ORDER BY rv2.registro_id, rv2.created_at DESC, rv2.id DESC
  );

  RETURN QUERY
  SELECT v_total, v_folios, v_now;
END;
$function$;


COMMENT ON FUNCTION v2.rpc_admin_previsualizar_retiro(UUID[]) IS
'Previsualiza registros seleccionados y bloquea historicos MIGRACION_V1. Solo ADMIN.';
COMMENT ON FUNCTION v2.rpc_admin_retirar_registros(UUID[], TEXT, TEXT) IS
'Retiro logico individual o masivo con motivo, confirmacion, historial y auditoria. Nunca borra fisicamente.';


REVOKE ALL ON FUNCTION v2.rpc_admin_previsualizar_retiro(UUID[])
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION v2.rpc_admin_retirar_registros(UUID[], TEXT, TEXT)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION v2.rpc_admin_previsualizar_retiro(UUID[])
  TO authenticated;
GRANT EXECUTE ON FUNCTION v2.rpc_admin_retirar_registros(UUID[], TEXT, TEXT)
  TO authenticated;


INSERT INTO v2.schema_migrations (version, descripcion)
VALUES (
  '2.1.12k',
  '12k_bitacora_import_cleanup.sql - Importaciones editables en Bitacora y retiro logico masivo protegido para ADMIN.'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;


-- VERIFICACION POST-INSTALACION
SELECT
  to_regprocedure('v2.rpc_admin_previsualizar_retiro(uuid[])') IS NOT NULL AS rpc_preview,
  to_regprocedure('v2.rpc_admin_retirar_registros(uuid[],text,text)') IS NOT NULL AS rpc_retiro,
  pg_catalog.strpos(
    pg_catalog.pg_get_functiondef(
      'v2.rpc_get_registro_editor(uuid)'::REGPROCEDURE
    ),
    'IMPORTACION_EXCEL'
  ) > 0 AS editor_excel,
  pg_catalog.strpos(
    pg_catalog.pg_get_functiondef(
      'v2.rpc_update_borrador(uuid,integer,jsonb)'::REGPROCEDURE
    ),
    'IMPORTACION_EXCEL'
  ) > 0 AS update_excel,
  pg_catalog.strpos(
    pg_catalog.pg_get_functiondef(
      'v2.rpc_submit_borrador(uuid,integer)'::REGPROCEDURE
    ),
    'IMPORTACION_EXCEL'
  ) > 0 AS submit_excel,
  COALESCE(has_function_privilege(
    'authenticated', 'v2.rpc_admin_retirar_registros(uuid[],text,text)', 'EXECUTE'
  ), false) AS authenticated_retiro,
  COALESCE(has_function_privilege(
    'anon', 'v2.rpc_admin_retirar_registros(uuid[],text,text)', 'EXECUTE'
  ), false) AS anon_retiro,
  (SELECT count(*) FROM v2.schema_migrations WHERE version = '2.1.12k') AS migracion_registrada;

-- RESULTADO ESPERADO:
-- true | true | true | true | true | true | false | 1
