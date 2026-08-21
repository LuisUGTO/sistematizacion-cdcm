-- ============================================================================
-- VINCULACIÓN CULTURAL 2.0
-- 00_preflight_engine.sql
-- Último diagnóstico de motor antes de crear el esquema V2
--
-- SOLO LECTURA.
-- No crea, altera ni elimina objetos.
-- Devuelve un único conjunto de resultados.
-- ============================================================================

BEGIN;
SET TRANSACTION READ ONLY;

WITH report AS (

  -- 01. Definición exacta de funciones relevantes
  SELECT
    10 AS orden,
    '01_funciones_relevantes'::text AS seccion,
    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'schema', n.nspname,
          'funcion', p.proname,
          'security_definer', p.prosecdef,
          'owner', pg_get_userbyid(p.proowner),
          'config', p.proconfig,
          'definicion', pg_get_functiondef(p.oid)
        )
        ORDER BY n.nspname, p.proname
      ),
      '[]'::jsonb
    ) AS detalle
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname IN ('handle_new_user', 'rls_auto_enable')

  UNION ALL

  -- 02. Event triggers de la base
  SELECT
    20,
    '02_event_triggers',
    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'nombre', e.evtname,
          'evento', e.evtevent,
          'habilitado', e.evtenabled,
          'funcion_oid', e.evtfoid,
          'funcion', p.proname,
          'schema_funcion', n.nspname,
          'tags', e.evttags
        )
        ORDER BY e.evtname
      ),
      '[]'::jsonb
    )
  FROM pg_event_trigger e
  JOIN pg_proc p ON p.oid = e.evtfoid
  JOIN pg_namespace n ON n.oid = p.pronamespace

  UNION ALL

  -- 03. Triggers de auth.users
  SELECT
    30,
    '03_triggers_auth_users',
    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'trigger', t.tgname,
          'habilitado', t.tgenabled,
          'definicion', pg_get_triggerdef(t.oid, true),
          'funcion', p.proname,
          'schema_funcion', pn.nspname
        )
        ORDER BY t.tgname
      ),
      '[]'::jsonb
    )
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace cn ON cn.oid = c.relnamespace
  JOIN pg_proc p ON p.oid = t.tgfoid
  JOIN pg_namespace pn ON pn.oid = p.pronamespace
  WHERE cn.nspname = 'auth'
    AND c.relname = 'users'
    AND NOT t.tgisinternal

  UNION ALL

  -- 04. Todos los triggers de usuario en public
  SELECT
    40,
    '04_triggers_public',
    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'tabla', c.relname,
          'trigger', t.tgname,
          'habilitado', t.tgenabled,
          'definicion', pg_get_triggerdef(t.oid, true),
          'funcion', p.proname
        )
        ORDER BY c.relname, t.tgname
      ),
      '[]'::jsonb
    )
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace cn ON cn.oid = c.relnamespace
  JOIN pg_proc p ON p.oid = t.tgfoid
  WHERE cn.nspname = 'public'
    AND NOT t.tgisinternal

  UNION ALL

  -- 05. Identidad / secuencias de IDs actuales
  SELECT
    50,
    '05_identity_actual',
    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'tabla', table_name,
          'columna', column_name,
          'is_identity', is_identity,
          'identity_generation', identity_generation,
          'default', column_default
        )
        ORDER BY table_name, ordinal_position
      ),
      '[]'::jsonb
    )
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name IN (
      'registros_culturales',
      'cat_docentes',
      'cat_bibliotecas',
      'profiles'
    )
    AND (
      is_identity = 'YES'
      OR column_name IN ('id', 'user_id', 'folio')
    )

  UNION ALL

  -- 06. Configuración PostgREST observable
  SELECT
    60,
    '06_postgrest_config',
    jsonb_build_object(
      'pgrst_db_schemas', current_setting('pgrst.db_schemas', true),
      'search_path', current_setting('search_path', true)
    )

  UNION ALL

  SELECT
    999,
    '99_estado',
    jsonb_build_object(
      'resultado', 'PRE-FLIGHT ENGINE COMPLETADO',
      'solo_lectura', true,
      'fecha', now()
    )
)

SELECT
  seccion,
  jsonb_pretty(detalle) AS detalle
FROM report
ORDER BY orden;

COMMIT;

-- ============================================================================
-- FIN
-- ============================================================================
