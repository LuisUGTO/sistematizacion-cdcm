-- Sólo lectura. Ejecutar después de aplicar 13_security_package_01.sql.
-- Una fila/columna resultado: todos los controles deben devolver true.
WITH expected(firma,hash) AS (VALUES
  ('v2.rpc_superadmin_actualizar_nombre_usuario(uuid,text)','34926bfd6d324ba6db8a5eeb24bc46e3'),
  ('v2.rpc_get_registro_validacion(uuid)','4667f3edb0c3e2493291f808b4c9c0e4'),
  ('v2.rpc_decide_validacion(uuid,integer,text,text)','4f3dd7610634dec7776602e58f84c8d6'),
  ('v2.rpc_import_preparar(text,text,jsonb)','9231a79e1c6b92bec1fbadcb921fbd4b'),
  ('v2.rpc_import_cargar_lote(uuid,jsonb)','2bba1df0268a61c220e95028b1d440a8'),
  ('v2.rpc_import_confirmar(uuid)','9da4d13e47e4ae29828251a76c84b2b6'),
  ('v2.rpc_import_historial()','f718f85c974ae91be8b2ba7de784944a'),
  ('v2_private.authorize_status_transition()','f7fca46310ba487466093bbece40301e'),
  ('v2_private.protect_superadmin()','84438e5341c9aca46ffe7b60b0fd0125')
), checks AS (
  SELECT firma AS control,
    COALESCE(md5(replace(pg_get_functiondef(to_regprocedure(firma)),chr(13),''))=hash,false) AS correcto
  FROM expected
  UNION ALL
  SELECT 'migracion_registrada',EXISTS(SELECT 1 FROM v2.schema_migrations WHERE version='2.1.13-security-01')
  UNION ALL
  SELECT 'bucket_privado_10MiB_tipos',EXISTS(SELECT 1 FROM storage.buckets WHERE id='evidencias-v2'
    AND public=false AND file_size_limit=10485760
    AND allowed_mime_types=ARRAY['image/jpeg','image/png','image/webp','application/pdf']::text[])
  UNION ALL
  SELECT 'sin_ejecucion_anonima',COALESCE(bool_and(NOT has_function_privilege('anon',to_regprocedure(firma),'EXECUTE')),false) FROM expected
  UNION ALL
  SELECT 'rpc_accesibles_authenticated',COALESCE(bool_and(has_function_privilege('authenticated',to_regprocedure(firma),'EXECUTE')),false)
  FROM expected WHERE firma LIKE 'v2.%'
  UNION ALL
  SELECT 'triggers_sin_ejecucion_directa',COALESCE(bool_and(NOT has_function_privilege('authenticated',to_regprocedure(firma),'EXECUTE')),false)
  FROM expected WHERE firma LIKE 'v2_private.%'
)
SELECT jsonb_build_object('paquete','seguridad-01','todos_correctos',bool_and(correcto),
  'controles',jsonb_object_agg(control,correcto))::text AS resultado FROM checks;
