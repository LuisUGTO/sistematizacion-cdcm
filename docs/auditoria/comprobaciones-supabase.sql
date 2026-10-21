-- Auditoría complementaria: sólo lectura. No instala ni modifica objetos.
-- Ejecutar con una cuenta autorizada en SQL Editor y compartir los resultados
-- sin tokens, claves, correos ni registros personales.
BEGIN TRANSACTION READ ONLY;
SET LOCAL statement_timeout = '30s';

SELECT version, descripcion FROM v2.schema_migrations ORDER BY version;

SELECT n.nspname AS esquema, c.relname AS objeto, c.relrowsecurity AS rls,
       c.relforcerowsecurity AS force_rls
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname IN ('v2','v2_private') AND c.relkind='r'
ORDER BY 1,2;

SELECT schemaname,tablename,policyname,roles,cmd,qual,with_check
FROM pg_policies WHERE schemaname IN ('v2','storage') ORDER BY 1,2,3;

SELECT n.nspname,p.proname,pg_get_function_identity_arguments(p.oid) AS argumentos,
       p.prosecdef AS security_definer,pg_get_userbyid(p.proowner) AS propietario,
       p.proconfig,
       has_function_privilege('anon',p.oid,'EXECUTE') AS anon_execute,
       has_function_privilege('authenticated',p.oid,'EXECUTE') AS authenticated_execute
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname IN ('v2','v2_private') ORDER BY 1,2,3;

SELECT n.nspname,p.proname,pg_get_functiondef(p.oid) AS definicion
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE (n.nspname='v2_private' AND p.proname IN
  ('current_role','has_scope','protect_superadmin','authorize_status_transition'))
 OR (n.nspname='v2' AND p.proname IN
  ('rpc_superadmin_actualizar_nombre_usuario','rpc_decide_validacion',
   'rpc_import_preparar','rpc_import_cargar_lote','rpc_import_confirmar','rpc_import_historial'));

SELECT table_schema,table_name,grantee,privilege_type
FROM information_schema.role_table_grants
WHERE table_schema='v2' AND grantee IN ('anon','authenticated','service_role')
ORDER BY 1,2,3,4;

SELECT id,public,file_size_limit,allowed_mime_types
FROM storage.buckets
WHERE id IN ('evidencias-v2','contenido-inicio','temas-inteligencia','evidencias');

SELECT rol,activo,count(*) AS cuentas FROM v2.profiles GROUP BY rol,activo ORDER BY 1,2;

SELECT 'NULL <> SUPERADMIN' AS caso,
       (NULL::text <> 'SUPERADMIN') IS TRUE AS ejecutaria_rechazo;
ROLLBACK;
