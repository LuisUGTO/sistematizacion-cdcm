const {test,before,after}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const {randomUUID}=require('node:crypto');
const {PGlite}=require('@electric-sql/pglite');
const root=path.resolve(__dirname,'..');
const read=p=>fs.readFileSync(path.join(root,p),'utf8');
const migration=read('sql/v2/13_security_package_01.sql');
let db;
const users={};
const unit=randomUUID(),municipality=randomUUID(),otherMunicipality=randomUUID();
async function actor(id,role='authenticated'){
  await db.exec('RESET ROLE');
  await db.query("SELECT set_config('request.jwt.claim.sub',$1,false)",[id||'']);
  await db.exec('SET ROLE '+role);
}
async function admin(){await actor(null,'postgres');}
async function error(sql,params,pattern){await assert.rejects(db.query(sql,params),pattern);}
before(async()=>{
  db=new PGlite();
  await db.exec(read('tests/fixtures/base-minima.sql'));
  await db.exec(read('tests/fixtures/funciones-auditadas.sql'));
  for(const [name,rol,activo] of [
    ['super','SUPERADMIN',true],['admin','ADMIN',true],['supervisor','SUPERVISOR',true],
    ['capturista','CAPTURISTA',true],['directivo','DIRECTIVO',true],['inactive','SUPERADMIN',false]]){
    users[name]=randomUUID();
    await db.query('INSERT INTO v2.profiles VALUES($1,$2,$3,$4,$5,now())',[users[name],name+'@example.invalid',name,rol,activo]);
  }
  users.absent=randomUUID();
  await db.query('INSERT INTO v2.profile_unidades VALUES($1,$2,true)',[users.supervisor,unit]);
  await db.query('INSERT INTO v2.profile_municipios VALUES($1,$2,true)',[users.supervisor,municipality]);
  await db.exec(`CREATE TRIGGER protect_superadmin BEFORE UPDATE ON v2.profiles
    FOR EACH ROW EXECUTE FUNCTION v2_private.protect_superadmin();
    CREATE TRIGGER authorize_transition BEFORE UPDATE OF estatus ON v2.registros
    FOR EACH ROW WHEN (OLD.estatus IS DISTINCT FROM NEW.estatus)
    EXECUTE FUNCTION v2_private.authorize_status_transition();`);
  await db.exec(migration);
});
after(async()=>{if(db)await db.close();});

test('la migración completa compila y se puede repetir sin duplicar versión',async()=>{
  await admin();await db.exec(migration);
  const {rows}=await db.query("SELECT count(*)::integer AS n FROM v2.schema_migrations WHERE version='2.1.13-security-01'");
  assert.equal(rows[0].n,1);
});
test('una definición que cambió desde el diagnóstico detiene toda la migración',async()=>{
  await admin();
  const {rows}=await db.query("SELECT pg_get_functiondef('v2.rpc_import_historial()'::regprocedure) AS sql");
  await db.exec("ALTER FUNCTION v2.rpc_import_historial() SET search_path TO public");
  await assert.rejects(db.exec(migration),/VERSION_DISTINTA/);
  await db.exec('ROLLBACK');
  await db.exec(rows[0].sql);
});
test('sólo SUPERADMIN activo puede cambiar nombres; nulo e inactivo quedan rechazados',async()=>{
  for(const name of ['admin','supervisor','capturista','directivo','inactive','absent']){
    await actor(users[name]);
    await error('SELECT * FROM v2.rpc_superadmin_actualizar_nombre_usuario($1,$2)',[users.capturista,'Cambio indebido'],/SUPERADMIN_REQUIRED/);
  }
  await actor(null);
  await error('SELECT * FROM v2.rpc_superadmin_actualizar_nombre_usuario($1,$2)',[users.capturista,'Sin sesión'],/AUTH_REQUIRED/);
  await actor(users.super);
  const {rows}=await db.query('SELECT * FROM v2.rpc_superadmin_actualizar_nombre_usuario($1,$2)',[users.capturista,'Nombre permitido']);
  assert.equal(rows[0].nombre,'Nombre permitido');
});
test('permiso de ejecución anónimo retirado y triggers sin ejecución directa',async()=>{
  await admin();
  const {rows}=await db.query(`SELECT
    has_function_privilege('anon','v2.rpc_import_preparar(text,text,jsonb)','EXECUTE') AS anon,
    has_function_privilege('authenticated','v2_private.protect_superadmin()','EXECUTE') AS trigger`);
  assert.deepEqual(rows[0],{anon:false,trigger:false});
});
async function record(muni=municipality){
  await admin();const id=randomUUID();
  await db.query("INSERT INTO v2.registros(id,estatus,unidad_operativa_id,municipio_id,created_by) VALUES($1,'EN_REVISION',$2,$3,$4)",[id,unit,muni,users.capturista]);
  return id;
}
test('SUPERADMIN y ADMIN pueden observar sin saltarse la versión del registro',async()=>{
  for(const name of ['super','admin']){
    const id=await record();await actor(users[name]);
    await error("SELECT * FROM v2.rpc_decide_validacion($1,99,'OBSERVAR','Observación de prueba')",[id],/VERSION_CONFLICT/);
    const {rows}=await db.query("SELECT * FROM v2.rpc_decide_validacion($1,1,'OBSERVAR','Observación de prueba')",[id]);
    assert.equal(rows[0].estatus,'OBSERVADO');
  }
});
test('SUPERADMIN conserva el bloqueo por datos incompletos al aprobar',async()=>{
  const id=await record();await db.query('INSERT INTO v2.vw_calidad_datos VALUES($1,$2)',[id,['FALTA_EVIDENCIA']]);
  await actor(users.super);
  await error("SELECT * FROM v2.rpc_decide_validacion($1,1,'VALIDAR',NULL)",[id],/QUALITY_BLOCK/);
});
test('SUPERVISOR valida dentro de alcance y se rechaza fuera de municipio',async()=>{
  const inside=await record(),outside=await record(otherMunicipality);
  await actor(users.supervisor);
  assert.equal((await db.query("SELECT * FROM v2.rpc_decide_validacion($1,1,'VALIDAR',NULL)",[inside])).rows[0].estatus,'VALIDADO');
  await error("SELECT * FROM v2.rpc_decide_validacion($1,1,'VALIDAR',NULL)",[outside],/VALIDATION_SCOPE_FORBIDDEN/);
});
test('capturista, directivo, inactivo y perfil ausente no revisan ni deciden',async()=>{
  const id=await record();
  for(const name of ['capturista','directivo','inactive','absent']){
    await actor(users[name]);
    await error('SELECT * FROM v2.rpc_get_registro_validacion($1)',[id],/VALIDATION_ROLE_REQUIRED/);
    await error("SELECT * FROM v2.rpc_decide_validacion($1,1,'VALIDAR',NULL)",[id],/VALIDATION_ROLE_REQUIRED/);
  }
});
test('importación completa de lote por SUPERADMIN y ADMIN; conserva duplicados y propietario',async()=>{
  for(const name of ['super','admin']){
    await actor(users[name]);
    const job=(await db.query("SELECT v2.rpc_import_preparar('prueba.xlsx') AS id")).rows[0].id;
    const rows=[{numero_fila:1,normalized_data:{fingerprint:randomUUID(),payload:{accion_id:randomUUID(),configuracion_accion_id:randomUUID(),nombre:'Actividad',fecha_inicio:'2026-10-20'}}}];
    const loaded=await db.query('SELECT * FROM v2.rpc_import_cargar_lote($1,$2)',[job,JSON.stringify(rows)]);
    assert.equal(loaded.rows[0].filas_validas,1);
    const done=await db.query('SELECT * FROM v2.rpc_import_confirmar($1)',[job]);
    assert.equal(done.rows[0].filas_importadas,1);
    assert.equal(done.rows[0].estatus,'COMPLETADO');
    assert.ok((await db.query('SELECT * FROM v2.rpc_import_historial()')).rows.some(x=>x.id===job));
    await actor(users[name==='super'?'admin':'super']);
    await error('SELECT * FROM v2.rpc_import_cargar_lote($1,$2)',[job,'[]'],/IMPORT_JOB_FORBIDDEN/);
  }
});
test('roles sin importación no preparan lotes ni ven historial',async()=>{
  for(const name of ['supervisor','capturista','directivo','inactive','absent']){
    await actor(users[name]);
    await error("SELECT v2.rpc_import_preparar('prueba.xlsx')",[],/ADMIN_REQUIRED/);
    assert.equal((await db.query('SELECT * FROM v2.rpc_import_historial()')).rows.length,0);
  }
});
test('bucket privado con 10 MiB y cuatro tipos; no se alteran otros buckets',async()=>{
  await admin();const {rows}=await db.query("SELECT public,file_size_limit::integer AS bytes,allowed_mime_types AS types FROM storage.buckets WHERE id='evidencias-v2'");
  assert.equal(rows[0].public,false);assert.equal(rows[0].bytes,10485760);
  assert.deepEqual(rows[0].types,['image/jpeg','image/png','image/webp','application/pdf']);
  const other=(await db.query("SELECT public,file_size_limit::integer AS bytes FROM storage.buckets WHERE id='contenido-inicio'")).rows[0];
  assert.deepEqual(other,{public:true,bytes:5242880});
});
test('continúa un lote de duplicados sin reimportarlos',async()=>{
  await actor(users.super);
  const job=(await db.query("SELECT v2.rpc_import_preparar('duplicados.xlsx') AS id")).rows[0].id;
  const payload={accion_id:randomUUID(),configuracion_accion_id:randomUUID(),nombre:'Repetida',fecha_inicio:'2026-10-20'};
  const fingerprint=randomUUID();
  const row=(numero_fila,fp)=>({numero_fila,normalized_data:{fingerprint:fp,payload}});
  await db.query('SELECT * FROM v2.rpc_import_cargar_lote($1,$2)',[job,JSON.stringify([row(1,fingerprint)])]);
  await db.query('SELECT * FROM v2.rpc_import_confirmar($1)',[job]);
  const second=(await db.query("SELECT v2.rpc_import_preparar('segundo.xlsx') AS id")).rows[0].id;
  const duplicate=await db.query('SELECT * FROM v2.rpc_import_cargar_lote($1,$2)',[second,JSON.stringify([row(1,fingerprint)])]);
  assert.equal(duplicate.rows[0].filas_duplicadas,1);
  const continued=await db.query('SELECT * FROM v2.rpc_import_cargar_lote($1,$2)',[second,JSON.stringify([row(2,randomUUID())])]);
  assert.equal(continued.rows[0].filas_validas,1);
  const final=await db.query('SELECT * FROM v2.rpc_import_confirmar($1)',[second]);
  assert.equal(final.rows[0].filas_importadas,1);assert.equal(final.rows[0].filas_duplicadas,1);
});
test('el verificador entregable confirma todos los controles después de instalar',async()=>{
  await admin();
  const result=await db.query(read('docs/paquetes/seguridad-01/02_verificar.sql'));
  assert.equal(JSON.parse(result.rows[0].resultado).todos_correctos,true);
});
test('interfaz coincide con importación restringida y rechaza perfiles inactivos',async()=>{
  const code=read('js/permissions.js');
  const {can,PERMISSIONS}=await import('data:text/javascript;base64,'+Buffer.from(code).toString('base64'));
  for(const rol of ['SUPERADMIN','ADMIN'])assert.equal(can({rol,activo:true},PERMISSIONS.IMPORT_MANAGE),true);
  for(const rol of ['SUPERVISOR','CAPTURISTA','DIRECTIVO'])assert.equal(can({rol,activo:true},PERMISSIONS.IMPORT_MANAGE),false);
  assert.equal(can({rol:'SUPERADMIN',activo:false},PERMISSIONS.IMPORT_MANAGE),false);
});
