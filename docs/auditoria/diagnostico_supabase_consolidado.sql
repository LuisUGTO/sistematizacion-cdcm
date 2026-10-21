-- DIAGNÓSTICO CONSOLIDADO DE VINCULACIÓN CULTURAL
-- Sólo lectura: una consulta, una fila y una columna llamada resultado.
-- No corrige ni cambia datos. Ejecutar completa en Supabase > SQL Editor.
-- Exportar la fila como CSV; no copiar sólo la parte visible de la celda.
-- Incluye configuración y código de funciones relevantes, no registros
-- operativos, archivos de evidencias, claves ni datos de auth.users.
-- Los correos literales encontrados en definiciones se ocultan al final.
WITH
tablas AS (
  SELECT n.nspname AS esquema,c.relname AS objeto,
    c.relrowsecurity AS rls,c.relforcerowsecurity AS force_rls
  FROM pg_catalog.pg_class c
  JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname IN ('v2','v2_private','public')
    AND c.relkind IN ('r','p')
),
politicas AS (
  SELECT schemaname,tablename,policyname,roles,cmd,qual,with_check
  FROM pg_catalog.pg_policies
  WHERE schemaname IN ('v2','v2_private','storage','public')
),
funciones AS (
  SELECT n.nspname AS esquema,p.proname AS nombre,
    pg_catalog.pg_get_function_identity_arguments(p.oid) AS argumentos,
    p.prosecdef AS security_definer,
    pg_catalog.pg_get_userbyid(p.proowner) AS propietario,
    p.proconfig AS configuracion,
    pg_catalog.has_function_privilege('anon',p.oid,'EXECUTE') AS anon_execute,
    pg_catalog.has_function_privilege('authenticated',p.oid,'EXECUTE') AS authenticated_execute,
    CASE WHEN
      (n.nspname='v2_private' AND p.proname IN (
        'current_role','is_active_user','is_admin','is_superadmin','has_scope',
        'can_read_record','can_edit_record','can_create_record',
        'can_manage_record','can_manage_import_job','protect_superadmin',
        'protect_last_admin','authorize_status_transition',
        'storage_v2_can_read','storage_v2_can_write','storage_v2_can_delete'))
      OR (n.nspname='v2' AND p.proname IN (
        'rpc_superadmin_actualizar_nombre_usuario','rpc_admin_guardar_acceso',
        'rpc_get_registro_validacion','rpc_decide_validacion',
        'rpc_import_preparar','rpc_import_cargar_lote','rpc_import_confirmar',
        'rpc_import_historial','rpc_import_validar_lote',
        'rpc_create_borrador_integral','rpc_submit_borrador'))
      THEN pg_catalog.pg_get_functiondef(p.oid)
      ELSE NULL END AS definicion
  FROM pg_catalog.pg_proc p
  JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname IN ('v2','v2_private') AND p.prokind IN ('f','p')
),
triggers_instalados AS (
  SELECT n.nspname AS esquema,c.relname AS tabla,t.tgname AS nombre,
    t.tgenabled AS habilitado,pg_catalog.pg_get_triggerdef(t.oid) AS definicion
  FROM pg_catalog.pg_trigger t
  JOIN pg_catalog.pg_class c ON c.oid=t.tgrelid
  JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='v2' AND NOT t.tgisinternal
),
vistas AS (
  SELECT n.nspname AS esquema,c.relname AS nombre,c.reloptions AS opciones
  FROM pg_catalog.pg_class c
  JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='v2' AND c.relkind IN ('v','m')
),
permisos AS (
  SELECT table_schema,table_name,grantee,privilege_type
  FROM information_schema.role_table_grants
  WHERE table_schema IN ('v2','v2_private','public')
    AND grantee IN ('anon','authenticated','service_role','PUBLIC')
),
permisos_esquema AS (
  SELECT n.nspname AS esquema,r.rol,
    pg_catalog.has_schema_privilege(r.rol,n.oid,'USAGE') AS uso,
    pg_catalog.has_schema_privilege(r.rol,n.oid,'CREATE') AS crear
  FROM pg_catalog.pg_namespace n
  CROSS JOIN (VALUES ('anon'),('authenticated'),('service_role')) r(rol)
  WHERE n.nspname IN ('v2','v2_private','public')
),
reporte AS (
  SELECT jsonb_build_object(
    'formato','vinculacion-auditoria-1',
    'generado_en',CURRENT_TIMESTAMP,
    'postgresql',current_setting('server_version'),
    'alcance','Diagnóstico de lectura; no es una prueba de explotación ni certifica la configuración Auth o Edge Functions.',
    'migraciones',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'version',version,'descripcion',descripcion) ORDER BY version)
      FROM v2.schema_migrations),'[]'::jsonb),
    'tablas',COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY esquema,objeto) FROM tablas x),'[]'::jsonb),
    'politicas',COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY schemaname,tablename,policyname) FROM politicas x),'[]'::jsonb),
    'funciones',COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY esquema,nombre,argumentos) FROM funciones x),'[]'::jsonb),
    'triggers',COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY esquema,tabla,nombre) FROM triggers_instalados x),'[]'::jsonb),
    'vistas',COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY esquema,nombre) FROM vistas x),'[]'::jsonb),
    'permisos_tablas',COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY table_schema,table_name,grantee,privilege_type) FROM permisos x),'[]'::jsonb),
    'permisos_esquema',COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY esquema,rol) FROM permisos_esquema x),'[]'::jsonb),
    'buckets',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id',id,'publico',public,'limite_bytes',file_size_limit,
      'tipos_permitidos',allowed_mime_types) ORDER BY id)
      FROM storage.buckets
      WHERE id IN ('evidencias-v2','contenido-inicio','temas-inteligencia','evidencias')),'[]'::jsonb),
    'cuentas_por_rol',COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY rol,activo)
      FROM (SELECT rol,activo,count(*) AS cuentas FROM v2.profiles GROUP BY rol,activo) x),'[]'::jsonb),
    'comprobacion_null',jsonb_build_object(
      'comparacion_antigua_rechaza',(NULL::text <> 'SUPERADMIN') IS TRUE,
      'comparacion_propuesta_rechaza',(NULL::text IS DISTINCT FROM 'SUPERADMIN'))
  ) AS contenido
)
SELECT pg_catalog.regexp_replace(
  contenido::text,
  '[A-Za-z0-9._%+!~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}',
  '[CORREO_OCULTO]','g'
) AS resultado
FROM reporte;
