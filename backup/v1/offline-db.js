// --- MOTOR INDEXEDDB PARA CAPTURA OFFLINE ---
const DB_NAME = 'CulturaGTO_OfflineDB';
const DB_VERSION = 1;
const STORE_NAME = 'capturas_pendientes';

function abrirDBOffline() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, DB_VERSION);
    request.onupgradeneeded = (e) => {
      const db = e.target.result;
      if (!db.objectStoreNames.contains(STORE_NAME)) {
        db.createObjectStore(STORE_NAME, { keyPath: 'folio' });
      }
    };
    request.onsuccess = (e) => resolve(e.target.result);
    request.onerror = (e) => reject(e.target.error);
  });
}

async function guardarCapturaLocal(paquete, fotoBase64 = null) {
  const db = await abrirDBOffline();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE_NAME, 'readwrite');
    const store = tx.objectStore(STORE_NAME);
    paquete.foto_offline = fotoBase64;
    paquete.fecha_guardado_local = new Date().toISOString();
    const req = store.put(paquete);
    req.onsuccess = () => resolve(true);
    req.onerror = () => reject(req.error);
  });
}

async function obtenerPendientesOffline() {
  const db = await abrirDBOffline();
  return new Promise((resolve) => {
    const tx = db.transaction(STORE_NAME, 'readonly');
    const store = tx.objectStore(STORE_NAME);
    const req = store.getAll();
    req.onsuccess = () => resolve(req.result || []);
    req.onerror = () => resolve([]);
  });
}

async function eliminarCapturaLocal(folio) {
  const db = await abrirDBOffline();
  return new Promise((resolve) => {
    const tx = db.transaction(STORE_NAME, 'readwrite');
    const store = tx.objectStore(STORE_NAME);
    const req = store.delete(folio);
    req.onsuccess = () => resolve(true);
    req.onerror = () => resolve(false);
  });
}

// Sincronización automática: almacena la ruta del archivo privado
async function sincronizarPendientesConNube() {
  if (!navigator.onLine || !conexionSupabase) return;
  const pendientes = await obtenerPendientesOffline();
  if (pendientes.length === 0) return;

  for (const item of pendientes) {
    try {
      let pathFoto = item.foto_url;
      if (item.foto_offline) {
        const extension = 'jpg';
        const nombreLimpio = `${item.folio}_offline_${Date.now()}.${extension}`;
        const blob = dataURItoBlob(item.foto_offline);
        const { error: errFoto } = await conexionSupabase.storage
          .from('evidencias')
          .upload(nombreLimpio, blob, { cacheControl: '3600', upsert: true });

        if (!errFoto) {
          pathFoto = nombreLimpio;
        }
      }

      const registroSQL = { ...item, foto_url: pathFoto };
      delete registroSQL.foto_offline;
      delete registroSQL.fecha_guardado_local;

      const { error: errInsert } = await conexionSupabase.from(TABLA_SQL).insert([registroSQL]);
      if (!errInsert) {
        await eliminarCapturaLocal(item.folio);
      }
    } catch (e) {
      console.error('Error al sincronizar folio:', item.folio, e);
    }
  }

  if (typeof actualizarEstadoConexionUI === 'function') actualizarEstadoConexionUI();
  if (typeof cargarBitacora === 'function') cargarBitacora();
  if (typeof inicializarDashboardDirectivo === 'function') inicializarDashboardDirectivo();
}

function dataURItoBlob(dataURI) {
  const byteString = atob(dataURI.split(',')[1]);
  const mimeString = dataURI.split(',')[0].split(':')[1].split(';')[0];
  const ab = new ArrayBuffer(byteString.length);
  const ia = new Uint8Array(ab);
  for (let i = 0; i < byteString.length; i++) {
    ia[i] = byteString.charCodeAt(i);
  }
  return new Blob([ab], { type: mimeString });
}