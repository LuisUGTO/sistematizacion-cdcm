const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const cp = require('node:child_process');
const root = path.resolve(__dirname, '..');
const rows = [];
function walk(dir) {
  for (const entry of fs.readdirSync(dir, {withFileTypes:true})) {
    if (['.git', 'node_modules'].includes(entry.name) || path.relative(root,dir).replaceAll('\\','/')==='docs/auditoria') continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) { walk(full); continue; }
    const bytes = fs.readFileSync(full);
    const rel = path.relative(root, full).replaceAll('\\', '/');
    const textual = /\.(js|cjs|mjs|ts|sql|html|css|md|json|webmanifest|geojson|txt|gitattributes|yml|yaml)$/i.test(rel) || rel==='.gitignore';
    const text = textual ? bytes.toString('utf8') : '';
    const row = {archivo:rel, bytes:bytes.length, sha256:crypto.createHash('sha256').update(bytes).digest('hex'), alcance:textual?'Inspección estática automatizada; revisión manual focalizada por riesgo':'Inventariado; contenido binario sin auditoría semántica', lineas:textual?text.split('\n').length:null};
    if (/\.(js|cjs|mjs)$/.test(rel)) {
      const result = cp.spawnSync(process.execPath, ['--input-type='+ (rel.startsWith('js/')?'module':'commonjs'), '--check'], {input:text,encoding:'utf8'});
      row.sintaxis = result.status === 0 ? 'PASS' : result.stderr;
    }
    if (/\.(json|webmanifest|geojson)$/.test(rel)) {
      try {const obj=JSON.parse(text);row.json='PASS';if(obj.features)row.entidades=obj.features.length;} catch(e) {row.json=e.message;}
    }
    if (rel.includes('xlsx.full')) row.versiones = [...text.matchAll(/(?:XLSX\.version|version)\s*=\s*["']([^"']+)["']/g)].slice(0,8).map(x=>x[1]);
    if (/\.sql$/.test(rel)) row.funciones = [...text.matchAll(/CREATE OR REPLACE FUNCTION\s+([^\s(]+)/gi)].map(x=>x[1]);
    if (/\.(js|html)$/.test(rel) && !rel.includes('/vendor/')) {
      row.referenciasLocalesAusentes = [];
      const pattern=rel.endsWith('.html') ? /(?:src|href)\s*=\s*["']([^"']+)["']/g : /(?:import|export)[^;\n]*?\bfrom\s+["']([^"']+)["']/g;
      for(const m of text.matchAll(pattern)) {
        const ref=decodeURIComponent(m[1].split(/[?#]/)[0]);
        if(ref.includes('${'))continue;
        if(!ref || /^(?:[a-z]+:|\/|#)/i.test(ref))continue;
        if(!fs.existsSync(path.resolve(path.dirname(full),ref)))row.referenciasLocalesAusentes.push(ref);
      }
    }
    if (rel.endsWith('.html')) {
      row.scriptsInline=[];
      for(const m of text.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)) {
        if(/\bsrc\s*=/.test(m[1]) || !m[2].trim())continue;
        if(/type\s*=\s*["'](?:application\/ld\+json|application\/json)/.test(m[1]))continue;
        const result=cp.spawnSync(process.execPath,['--input-type='+ (/type\s*=\s*["']module/.test(m[1])?'module':'commonjs'),'--check'],{input:m[2],encoding:'utf8'});
        row.scriptsInline.push(result.status===0?'PASS':result.stderr);
      }
    }
    rows.push(row);
  }
}
walk(root);
rows.sort((a,b)=>a.archivo.localeCompare(b.archivo));
fs.writeFileSync(path.join(root,'docs/auditoria/inventario-actual.json'),JSON.stringify(rows,null,2)+'\n');
console.log(JSON.stringify({archivos:rows.length, texto:rows.filter(x=>x.lineas!==null).length, binarios:rows.filter(x=>x.lineas===null).length, js:rows.filter(x=>x.sintaxis).length, erroresSintaxis:rows.filter(x=>x.sintaxis&&x.sintaxis!=='PASS'), erroresJson:rows.filter(x=>x.json&&x.json!=='PASS'), referencias:rows.filter(x=>x.referenciasLocalesAusentes?.length),xlsx:rows.find(x=>x.archivo.includes('xlsx.full')),sql:rows.filter(x=>x.archivo.endsWith('.sql')).length},null,2));
