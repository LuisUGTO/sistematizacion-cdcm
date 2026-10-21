// Genera reemplazos completos a partir del diagnóstico instalado aprobado.
// Uso: node scripts/preparar-paquete-seguridad.cjs <CSV de diagnóstico>
// No se conecta a servicios. Aborta si una sustitución esperada no es única.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const root = path.resolve(__dirname, '..');
const raw = fs.readFileSync(process.argv[2], 'utf8').replace(/^\uFEFF/, '');
// El export contiene una sola columna. Se permiten saltos de línea en la celda.
const value = raw.slice(raw.indexOf('\n')+1).trim();
const report = JSON.parse(value.startsWith('"') ? value.slice(1,-1).replaceAll('""','"') : value);
if(report.formato !== 'vinculacion-auditoria-1') throw Error('Diagnóstico no reconocido');
const specs = [
  ['v2','rpc_superadmin_actualizar_nombre_usuario','uuid,text',"v2_private.current_role() <> 'SUPERADMIN'","v2_private.current_role() IS DISTINCT FROM 'SUPERADMIN'"],
  ['v2','rpc_get_registro_validacion','uuid',"v_role NOT IN ('ADMIN', 'SUPERVISOR')","COALESCE(v_role, '') NOT IN ('SUPERADMIN', 'ADMIN', 'SUPERVISOR')"],
  ['v2','rpc_decide_validacion','uuid,integer,text,text',"v_role NOT IN ('ADMIN', 'SUPERVISOR')","COALESCE(v_role, '') NOT IN ('SUPERADMIN', 'ADMIN', 'SUPERVISOR')"],
  ['v2','rpc_import_preparar','text,text,jsonb',"p.rol = 'ADMIN'","p.rol IN ('SUPERADMIN', 'ADMIN')"],
  ['v2','rpc_import_cargar_lote','uuid,jsonb',"p.rol = 'ADMIN'","p.rol IN ('SUPERADMIN', 'ADMIN')"],
  ['v2','rpc_import_confirmar','uuid',"p.rol = 'ADMIN'","p.rol IN ('SUPERADMIN', 'ADMIN')"],
  ['v2','rpc_import_historial','',"p.rol = 'ADMIN'","p.rol IN ('SUPERADMIN', 'ADMIN')"],
  ['v2_private','authorize_status_transition','',"v_role = 'ADMIN'","v_role IN ('SUPERADMIN', 'ADMIN')"],
  ['v2_private','protect_superadmin','',"caller<>'SUPERADMIN'","caller IS DISTINCT FROM 'SUPERADMIN'"],
];
function md5(s){return crypto.createHash('md5').update(s.replaceAll('\r','')).digest('hex');}
const changes=specs.map(([schema,name,args,before,after])=>{
  const matches=report.funciones.filter(x=>x.esquema===schema&&x.nombre===name);
  if(matches.length!==1 || !matches[0].definicion)throw Error('Definición no única: '+name);
  const old=matches[0].definicion;
  if(old.split(before).length!==2)throw Error('Regla no única: '+name);
  let corrected=old.replace(before,after);
  if(schema==='v2') corrected=corrected.replaceAll('solo ADMIN/SUPERVISOR','solo SUPERADMIN/ADMIN/SUPERVISOR').replaceAll('solo ADMIN puede realizar importaciones','solo SUPERADMIN/ADMIN puede realizar importaciones');
  return {signature:`${schema}.${name}(${args})`,old,corrected};
});
const sqlQuote=s=>"'"+s.replaceAll("'","''")+"'";
const expectations=changes.map(c=>`(${sqlQuote(c.signature)},${sqlQuote(md5(c.old))},${sqlQuote(md5(c.corrected))})`).join(',\n      ');
const preflight=`DO $preflight$
DECLARE r RECORD; v_actual TEXT;
BEGIN
  IF to_regclass('v2.schema_migrations') IS NULL OR
     NOT EXISTS (SELECT 1 FROM storage.buckets WHERE id='evidencias-v2') THEN
    RAISE EXCEPTION 'PRECONDICION: faltan migraciones o bucket evidencias-v2.';
  END IF;
  FOR r IN SELECT * FROM (VALUES
      ${expectations}
    ) AS expected(firma,anterior,corregida)
  LOOP
    IF to_regprocedure(r.firma) IS NULL THEN
      RAISE EXCEPTION 'PRECONDICION: falta %',r.firma;
    END IF;
    v_actual:=md5(replace(pg_get_functiondef(to_regprocedure(r.firma)),chr(13),''));
    IF v_actual NOT IN (r.anterior,r.corregida) THEN
      RAISE EXCEPTION 'VERSION_DISTINTA: % cambió desde el diagnóstico; no se aplicó el paquete.',r.firma;
    END IF;
  END LOOP;
END;
$preflight$;
`;
const acl=changes.map(c=>`REVOKE ALL ON FUNCTION ${c.signature} FROM PUBLIC, anon, authenticated;`+(c.signature.startsWith('v2.')?`\nGRANT EXECUTE ON FUNCTION ${c.signature} TO authenticated;`:'')).join('\n');
const header=`-- PAQUETE 1: seguridad y permisos. Basado en el diagnóstico entregado.
-- Ejecutar completo. No elimina registros ni cambia asignaciones o contactos.
-- Transacción: si hay error antes de COMMIT, no conserva cambios del paquete.
-- Se rechazan definiciones diferentes de la copia auditada o de este paquete.
BEGIN;
SET LOCAL lock_timeout='10s';
SET LOCAL statement_timeout='120s';
`;
fs.writeFileSync(path.join(root,'sql/v2/13_security_package_01.sql'),header+preflight+'\n'+changes.map(c=>c.corrected+';').join('\n\n')+'\n'+acl+`
UPDATE storage.buckets
SET file_size_limit=10485760,
    allowed_mime_types=ARRAY['image/jpeg','image/png','image/webp','application/pdf']::text[],
    public=false
WHERE id='evidencias-v2';
INSERT INTO v2.schema_migrations(version,descripcion)
VALUES ('2.1.13-security-01','Paquete 1: autorización segura, SUPERADMIN en validación/importación y evidencias privadas con límites.')
ON CONFLICT(version) DO NOTHING;
COMMIT;
SELECT 'PAQUETE_1_APLICADO' AS resultado;
`);
// Referencia de los hashes; no se incluye el CSV ni sus datos agregados.
fs.mkdirSync(path.join(root,'docs/paquetes/seguridad-01'),{recursive:true});
fs.writeFileSync(path.join(root,'docs/paquetes/seguridad-01/definiciones.json'),JSON.stringify(changes.map(({signature,old,corrected})=>({firma:signature,md5_anterior:md5(old),md5_corregida:md5(corrected)})),null,2)+'\n');
fs.mkdirSync(path.join(root,'tests/fixtures'),{recursive:true});
const helpers=['current_role','is_active_user','is_admin','has_scope','can_manage_record'];
fs.writeFileSync(path.join(root,'tests/fixtures/funciones-auditadas.sql'),
  '-- Sólo para pruebas locales: definiciones ANTERIORES al paquete. No ejecutar en Supabase.\n'+
  report.funciones.filter(f=>f.esquema==='v2_private'&&helpers.includes(f.nombre)).map(f=>f.definicion+';').join('\n\n')+'\n'+
  changes.map(c=>c.old+';').join('\n\n')+'\n');
fs.writeFileSync(path.join(root,'docs/paquetes/seguridad-01/02_verificar.sql'),`-- Sólo lectura. Ejecutar después de aplicar 13_security_package_01.sql.
-- Una fila/columna resultado: todos los controles deben devolver true.
WITH expected(firma,hash) AS (VALUES
  ${changes.map(c=>`(${sqlQuote(c.signature)},${sqlQuote(md5(c.corrected))})`).join(',\n  ')}
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
`);
console.log('Paquete generado: '+changes.length+' funciones completas, sin cambios en Supabase.');
