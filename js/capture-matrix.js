/**
 * VINCULACIÓN CULTURAL — CASAS DE LA CULTURA
 * capture-matrix.js
 *
 * Libro mensual continuo estilo Excel:
 * - Una sola hoja continua por mes con las 8 secciones (Educación Continua y
 *   Mediación Cultural), idéntica al flujo de trabajo en Excel.
 * - Barra inferior de pestañas tipo Excel: ENE..DIC + Concent. Sem 1 y Sem 2.
 * - Municipio fijo automático para cuentas municipales; selector en celda
 *   únicamente cuando entra un perfil con múltiples municipios (ej. Admin).
 * - Suma automática en tiempo real por fila y por sección (incluyendo Primera
 *   Infancia 0–5 años).
 * - Cascada territorial (Cabecera / Comunidad / Colonia) con alta al vuelo.
 * - Persistencia automática para que al abrir su sesión vean sus filas tal
 *   como las dejaron (actualmente 100% editables; bloqueables en etapa de cierre).
 */

import { getDisplayIdentity } from "./auth.js?v=7.4.3";
import { isAdmin } from "./permissions.js";
import {
  loadMunicipalities,
  loadCommunities,
} from "./catalogs.js?v=7.2.2";

const STORAGE_PREFIX = "vc_libro_excel_2026_v2";
const SETTLEMENTS_PREFIX = "vc_asentamientos_cascada_2026_v1";
const DEFAULT_EMPTY_ROWS = 5;

const MONTHS = Object.freeze([
  { num: "01", name: "ENERO", label: "Enero", short: "ENE", sem: 1 },
  { num: "02", name: "FEBRERO", label: "Febrero", short: "FEB", sem: 1 },
  { num: "03", name: "MARZO", label: "Marzo", short: "MAR", sem: 1 },
  { num: "04", name: "ABRIL", label: "Abril", short: "ABR", sem: 1 },
  { num: "05", name: "MAYO", label: "Mayo", short: "MAY", sem: 1 },
  { num: "06", name: "JUNIO", label: "Junio", short: "JUN", sem: 1 },
  { num: "07", name: "JULIO", label: "Julio", short: "JUL", sem: 1 },
  { num: "08", name: "AGOSTO", label: "Agosto", short: "AGO", sem: 2 },
  { num: "09", name: "SEPTIEMBRE", label: "Septiembre", short: "SEP", sem: 2 },
  { num: "10", name: "OCTUBRE", label: "Octubre", short: "OCT", sem: 2 },
  { num: "11", name: "NOVIEMBRE", label: "Noviembre", short: "NOV", sem: 2 },
  { num: "12", name: "DICIEMBRE", label: "Diciembre", short: "DIC", sem: 2 },
]);

const BOTTOM_TABS = Object.freeze([
  ...MONTHS.filter((m) => m.sem === 1).map((m) => ({
    id: m.num,
    label: m.short,
    title: `Informe mensual de ${m.label}`,
    type: "MONTH",
  })),
  {
    id: "SEM1",
    label: "Concent. Sem 1",
    title: "Concentrado automático de Enero a Julio",
    type: "SUMMARY",
    sem: 1,
  },
  ...MONTHS.filter((m) => m.sem === 2).map((m) => ({
    id: m.num,
    label: m.short,
    title: `Informe mensual de ${m.label}`,
    type: "MONTH",
  })),
  {
    id: "SEM2",
    label: "Concent. Sem 2",
    title: "Concentrado automático de Agosto a Diciembre",
    type: "SUMMARY",
    sem: 2,
  },
]);

const DAYS_OF_WEEK = Object.freeze([
  { key: "L", label: "L", title: "Lunes" },
  { key: "Ma", label: "M", title: "Martes" },
  { key: "Mi", label: "Mi", title: "Miércoles" },
  { key: "J", label: "J", title: "Jueves" },
  { key: "V", label: "V", title: "Viernes" },
  { key: "S", label: "S", title: "Sábado" },
  { key: "D", label: "D", title: "Domingo" },
]);

const DEMO_GROUPS = Object.freeze([
  { key: "pi", label: "Primera infancia (0–5)", isFirst: true },
  { key: "inf", label: "Infancias (6–12)", isFirst: false },
  { key: "ado", label: "Adolescentes (13–17)", isFirst: false },
  { key: "jov", label: "Jóvenes (18–29)", isFirst: false },
  { key: "adu", label: "Adultos (30–59)", isFirst: false },
  { key: "may", label: "Adultos mayores (60+)", isFirst: false },
]);

const DEMO_KEYS = Object.freeze(
  DEMO_GROUPS.flatMap((g) => [`${g.key}_m`, `${g.key}_h`])
);

const SECTIONS = Object.freeze([
  {
    id: "talleres_cc",
    axis: "EDUCACION_CONTINUA",
    num: 1,
    jumpLabel: "1. Talleres CC",
    title: "1) Talleres en Casa de la Cultura",
    peopleLabel: "Participantes",
    fixedSedeOne: true,
    kind: "WORKSHOP_CC",
  },
  {
    id: "salones",
    axis: "EDUCACION_CONTINUA",
    num: 2,
    jumpLabel: "2. Salones Culturales",
    title: "2) Salones Culturales (descentralizados fuera de Casa de la Cultura)",
    peopleLabel: "Participantes",
    fixedSedeOne: false,
    kind: "SALON_DESC",
  },
  {
    id: "verano",
    axis: "EDUCACION_CONTINUA",
    num: 3,
    jumpLabel: "3. Verano",
    title: "3) Talleres de Verano",
    peopleLabel: "Participantes",
    fixedSedeOne: false,
    kind: "SUMMER",
  },
  {
    id: "capacitaciones",
    axis: "EDUCACION_CONTINUA",
    num: 4,
    jumpLabel: "4. Capacitaciones",
    title: "4) Procesos de Formación (capacitaciones)",
    peopleLabel: "Asistentes",
    fixedSedeOne: false,
    kind: "TRAINING",
  },
  {
    id: "reuniones",
    axis: "MEDIACION_CULTURAL",
    num: 5,
    jumpLabel: "5. Reuniones",
    title: "5) Reuniones de Colaboración",
    peopleLabel: "Asistentes",
    fixedSedeOne: false,
    kind: "MEETING",
  },
  {
    id: "talento_local",
    axis: "MEDIACION_CULTURAL",
    num: 6,
    jumpLabel: "6. Talento Local",
    title: "6) Promoción de Talento Local (grupos, artistas, exposiciones — fuera de Casa de Cultura)",
    peopleLabel: "Asistentes",
    fixedSedeOne: false,
    kind: "LOCAL_TALENT",
  },
  {
    id: "proyectos_colab",
    axis: "MEDIACION_CULTURAL",
    num: 7,
    jumpLabel: "7. Proy. Colaborativos",
    title: "7) Proyectos Colaborativos (de circuito o regionales)",
    peopleLabel: "Asistentes",
    fixedSedeOne: false,
    kind: "COLLAB_PROJECT",
  },
  {
    id: "eventos_mpales",
    axis: "MEDIACION_CULTURAL",
    num: 8,
    jumpLabel: "8. Eventos Municipales",
    title: "8) Eventos y Actividades Municipales",
    peopleLabel: "Asistentes",
    fixedSedeOne: false,
    kind: "MUNICIPAL_EVENT",
  },
]);

const COLLAB_CATALOG_SEED = Object.freeze([
  "Circuito Cultural Regional — Artes Escénicas",
  "Encuentro Intermunicipal de Tradición y Memoria",
  "Caravana Cultural Comunitaria",
]);

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function makeRowId() {
  return `r_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 7)}`;
}

function toInt(val) {
  const n = Number.parseInt(String(val ?? "").trim(), 10);
  return Number.isFinite(n) && n > 0 ? n : 0;
}

function toMoney(val) {
  const n = Number.parseFloat(String(val ?? "").trim());
  return Number.isFinite(n) && n > 0 ? n : 0;
}

function todayFormatted() {
  return new Date().toLocaleDateString("es-MX", {
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
  });
}

function createBlankRow(kind) {
  const demo = {};
  for (const k of DEMO_KEYS) demo[k] = 0;

  return {
    id: makeRowId(),
    titulo: "",
    subtitulo: "",
    tipo:
      kind === "MEETING"
        ? "COLABORATIVA"
        : kind === "MUNICIPAL_EVENT"
          ? "Artistica"
          : "",
    zona: kind === "SALON_DESC" ? "COLONIA" : "CABECERA",
    asentamientoId: "",
    asentamientoNombre: "",
    sede: "",
    temporalidad: "SEMESTRAL",
    inicio: "",
    fin: "",
    fecha: "",
    dias: { L: false, Ma: false, Mi: false, J: false, V: false, S: false, D: false },
    horario: "",
    costo: "",
    docente: "",
    recursoEst: "",
    recursoMun: "",
    ...demo,
  };
}

function createDefaultSectionRows(kind, count = DEFAULT_EMPTY_ROWS) {
  const list = [];
  for (let i = 0; i < count; i += 1) {
    list.push(createBlankRow(kind));
  }
  return list;
}

function rowTotalPeople(row) {
  let sum = 0;
  for (const k of DEMO_KEYS) sum += toInt(row[k]);
  return sum;
}

function isRowUsed(row) {
  if (!row) return false;
  if (String(row.titulo || "").trim() !== "") return true;
  if (String(row.subtitulo || "").trim() !== "") return true;
  if (String(row.docente || "").trim() !== "") return true;
  if (String(row.sede || "").trim() !== "") return true;
  return rowTotalPeople(row) > 0;
}

function getColumnsSpec(kind) {
  switch (kind) {
    case "WORKSHOP_CC":
      return {
        mainHeader: "Disciplina / Saber impartido",
        mainWidth: 210,
        hasProject: false,
        hasEventName: false,
        hasPonente: false,
        hasMeetingType: false,
        hasEventType: false,
        hasTerritory: false,
        hasSede: false,
        hasTemporality: true,
        hasRange: true,
        hasDate: false,
        hasDays: true,
        hasHorario: true,
        hasCosto: true,
        hasDocente: true,
      };
    case "SALON_DESC":
      return {
        mainHeader: "Disciplina / Saber impartido",
        mainWidth: 200,
        hasProject: false,
        hasEventName: false,
        hasPonente: false,
        hasMeetingType: false,
        hasEventType: false,
        hasTerritory: true,
        hasSede: true,
        sedeHeader: "Lugar específico",
        hasTemporality: true,
        hasRange: true,
        hasDate: false,
        hasDays: true,
        hasHorario: true,
        hasCosto: true,
        hasDocente: true,
      };
    case "SUMMER":
      return {
        mainHeader: "Disciplina / Saber impartido",
        mainWidth: 200,
        hasProject: false,
        hasEventName: false,
        hasPonente: false,
        hasMeetingType: false,
        hasEventType: false,
        hasTerritory: true,
        hasSede: true,
        sedeHeader: "Sede",
        hasTemporality: false,
        hasRange: true,
        hasDate: false,
        hasDays: true,
        hasHorario: true,
        hasCosto: true,
        hasDocente: true,
      };
    case "TRAINING":
      return {
        mainHeader: "Tema",
        mainWidth: 220,
        hasProject: false,
        hasEventName: false,
        hasPonente: true,
        hasMeetingType: false,
        hasEventType: false,
        hasTerritory: true,
        hasSede: true,
        sedeHeader: "Sede",
        hasTemporality: false,
        hasRange: false,
        hasDate: true,
        hasDays: false,
        hasHorario: false,
        hasCosto: false,
        hasDocente: false,
      };
    case "MEETING":
      return {
        mainHeader: "Temática",
        mainWidth: 240,
        hasProject: false,
        hasEventName: false,
        hasPonente: false,
        hasMeetingType: true,
        hasEventType: false,
        hasTerritory: false,
        hasSede: true,
        sedeHeader: "Sede",
        hasTemporality: false,
        hasRange: false,
        hasDate: true,
        hasDays: false,
        hasHorario: false,
        hasCosto: false,
        hasDocente: false,
      };
    case "LOCAL_TALENT":
      return {
        mainHeader: "Agrupación / Artista / Actividad",
        mainWidth: 220,
        hasProject: false,
        hasEventName: true,
        hasPonente: false,
        hasMeetingType: false,
        hasEventType: false,
        hasTerritory: true,
        hasSede: true,
        sedeHeader: "Sede",
        hasTemporality: false,
        hasRange: false,
        hasDate: true,
        hasDays: false,
        hasHorario: false,
        hasCosto: false,
        hasDocente: false,
      };
    case "COLLAB_PROJECT":
      return {
        mainHeader: "Actividad",
        mainWidth: 210,
        hasProject: true,
        hasEventName: false,
        hasPonente: false,
        hasMeetingType: false,
        hasEventType: false,
        hasTerritory: true,
        hasSede: true,
        sedeHeader: "Sede",
        hasTemporality: false,
        hasRange: false,
        hasDate: true,
        hasDays: false,
        hasHorario: false,
        hasCosto: false,
        hasDocente: false,
      };
    case "MUNICIPAL_EVENT":
    default:
      return {
        mainHeader: "Evento / Actividad",
        mainWidth: 220,
        hasProject: false,
        hasEventName: false,
        hasPonente: false,
        hasMeetingType: false,
        hasEventType: true,
        hasTerritory: true,
        hasSede: true,
        sedeHeader: "Sede (lugar donde se llevó a cabo)",
        hasTemporality: false,
        hasRange: false,
        hasDate: true,
        hasDays: false,
        hasHorario: false,
        hasCosto: false,
        hasDocente: false,
      };
  }
}

function countLeftCols(spec) {
  let n = 2; // No. + main
  if (spec.hasProject) n += 1;
  if (spec.hasEventName) n += 1;
  if (spec.hasPonente) n += 1;
  if (spec.hasTerritory) n += 2;
  if (spec.hasSede) n += 1;
  if (spec.hasMeetingType) n += 1;
  if (spec.hasEventType) n += 1;
  if (spec.hasTemporality) n += 1;
  if (spec.hasRange) n += 2;
  if (spec.hasDate) n += 1;
  if (spec.hasDays) n += 1;
  if (spec.hasHorario) n += 1;
  if (spec.hasCosto) n += 1;
  if (spec.hasDocente) n += 1;
  return n;
}

export async function initCaptureMatrix2026(context) {
  const shell = document.getElementById("captureMatrix2026Shell");
  if (!shell) return;

  const userId = context?.user?.id || "local";
  const identity = context ? getDisplayIdentity(context) : { name: "", email: "" };
  const adminMode = isAdmin(context);

  const currentMonthIdx = new Date().getMonth(); // 0..11
  const defaultTabId = MONTHS[currentMonthIdx]?.num || "01";

  const state = {
    year: "2026",
    activeTabId: defaultTabId, // "01".."12" | "SEM1" | "SEM2"
    municipalityId: "",
    municipalities: [],
    elabora: identity.name || "",
    settlementsCache: new Map(),
    sectionsData: {}, // sectionId -> rows[]
    saveTimer: null,
  };

  const els = {
    bookTitle: document.getElementById("excelBookTitle"),
    bookSub: document.getElementById("excelBookSub"),
    autosaveStatus: document.getElementById("excelAutosaveStatus"),
    btnCopyPrev: document.getElementById("excelCopyPrevBtn"),
    btnPadron: document.getElementById("excelPadronBtn"),
    btnExport: document.getElementById("excelExportBtn"),
    btnSave: document.getElementById("excelSaveBtn"),
    jumpBar: document.getElementById("excelJumpBar"),
    canvas: document.getElementById("excelCanvas"),
    bottomTabs: document.getElementById("excelBottomTabsBar"),
  };

  function monthKey(mpioId, year, monthNum) {
    return `${STORAGE_PREFIX}:${userId}:${mpioId || "mpio"}:${year}-${monthNum}`;
  }

  function settlementsKey(mpioId) {
    return `${SETTLEMENTS_PREFIX}:${mpioId || "mpio"}`;
  }

  function hasSavedDataForMonth(monthNum) {
    if (monthNum === state.activeTabId) {
      return SECTIONS.some((sec) =>
        (state.sectionsData[sec.id] || []).some(isRowUsed)
      );
    }
    try {
      const raw = localStorage.getItem(
        monthKey(state.municipalityId, state.year, monthNum)
      );
      if (!raw) return false;
      const parsed = JSON.parse(raw);
      return SECTIONS.some((sec) =>
        (parsed?.sectionsData?.[sec.id] || []).some(isRowUsed)
      );
    } catch {
      return false;
    }
  }

  function readMonthFromStorage(monthNum) {
    try {
      const raw = localStorage.getItem(
        monthKey(state.municipalityId, state.year, monthNum)
      );
      return raw ? JSON.parse(raw) : null;
    } catch {
      return null;
    }
  }

  function loadActiveMonthData() {
    if (state.activeTabId === "SEM1" || state.activeTabId === "SEM2") return;

    const stored = readMonthFromStorage(state.activeTabId);
    const nextData = {};
    for (const sec of SECTIONS) {
      const savedRows = stored?.sectionsData?.[sec.id];
      nextData[sec.id] =
        Array.isArray(savedRows) && savedRows.length > 0
          ? savedRows
          : createDefaultSectionRows(sec.kind, DEFAULT_EMPTY_ROWS);
    }
    if (stored?.elabora) {
      state.elabora = stored.elabora;
    } else if (!state.elabora && identity.name) {
      state.elabora = identity.name;
    }
    state.sectionsData = nextData;

    if (stored?.savedAt) {
      setStatus(`Datos cargados (${stored.savedAt})`, "saved");
    } else {
      setStatus("Hoja lista para captura", "ready");
    }
  }

  function saveActiveMonthNow() {
    if (state.activeTabId === "SEM1" || state.activeTabId === "SEM2") return;

    const hhmm = new Date().toLocaleTimeString("es-MX", {
      hour: "2-digit",
      minute: "2-digit",
    });
    const payload = {
      version: 2,
      municipalityId: state.municipalityId,
      year: state.year,
      month: state.activeTabId,
      elabora: state.elabora,
      savedAt: hhmm,
      sectionsData: state.sectionsData,
    };
    try {
      localStorage.setItem(
        monthKey(state.municipalityId, state.year, state.activeTabId),
        JSON.stringify(payload)
      );
      setStatus(`Guardado · ${hhmm}`, "saved");
      updateBottomTabsDots();
    } catch (err) {
      console.warn("No se pudo guardar hoja mensual:", err);
    }
  }

  function scheduleSave() {
    if (state.saveTimer) clearTimeout(state.saveTimer);
    state.saveTimer = setTimeout(() => {
      saveActiveMonthNow();
    }, 300);
  }

  function setStatus(text, stateKind = "ready") {
    if (!els.autosaveStatus) return;
    els.autosaveStatus.textContent = text;
    els.autosaveStatus.dataset.state = stateKind;
  }

  function getMunicipalityName() {
    const m = state.municipalities.find((x) => x.id === state.municipalityId);
    return m ? m.nombre_oficial : "Sin municipio asignado";
  }

  async function ensureSettlements(mpioId) {
    if (!mpioId) return [];
    if (state.settlementsCache.has(mpioId)) {
      return state.settlementsCache.get(mpioId);
    }

    let dbRows = [];
    if (!String(mpioId).startsWith("local-")) {
      try {
        dbRows = await loadCommunities(mpioId);
      } catch {
        dbRows = [];
      }
    }

    const list = dbRows.map((c) => ({
      id: c.id,
      nombre: c.nombre,
      nombreConocido: "",
      tipo:
        String(c.nombre || "").toLowerCase().startsWith("col.") ||
        String(c.nombre || "").toLowerCase().includes("colonia")
          ? "COLONIA"
          : "COMUNIDAD",
      source: "BD",
    }));

    try {
      const localRaw = localStorage.getItem(settlementsKey(mpioId));
      const localParsed = localRaw ? JSON.parse(localRaw) : [];
      if (Array.isArray(localParsed)) {
        for (const item of localParsed) {
          const dup = list.some(
            (x) =>
              x.tipo === item.tipo &&
              x.nombre.trim().toLowerCase() ===
                String(item.nombre || "").trim().toLowerCase()
          );
          if (!dup) list.push(item);
        }
      }
    } catch {
      // ignore
    }

    list.sort((a, b) => a.nombre.localeCompare(b.nombre, "es"));
    state.settlementsCache.set(mpioId, list);
    return list;
  }

  function saveLocalSettlements(mpioId) {
    const all = state.settlementsCache.get(mpioId) || [];
    const custom = all.filter((x) => x.source !== "BD");
    try {
      localStorage.setItem(settlementsKey(mpioId), JSON.stringify(custom));
    } catch {
      // ignore
    }
  }

  async function promptNewSettlement(defaultTipo = "COLONIA", onCreated = null) {
    if (!window.Swal) return;
    const mpioName = getMunicipalityName();

    const { value } = await window.Swal.fire({
      title: `Agregar a cascada · ${mpioName}`,
      html: `
        <div style="text-align:left;display:grid;gap:10px">
          <div>
            <label style="display:block;font-weight:700;font-size:.83rem;margin-bottom:3px">Clasificación territorial</label>
            <select id="swalTipoAsent" class="swal2-input" style="margin:0;width:100%;height:40px;font-size:.9rem">
              <option value="COLONIA"${defaultTipo === "COLONIA" ? " selected" : ""}>Colonia</option>
              <option value="COMUNIDAD"${defaultTipo === "COMUNIDAD" ? " selected" : ""}>Comunidad</option>
            </select>
          </div>
          <div>
            <label style="display:block;font-weight:700;font-size:.83rem;margin-bottom:3px">Nombre de la comunidad o colonia *</label>
            <input id="swalNomAsent" class="swal2-input" style="margin:0;width:100%;height:40px;font-size:.9rem" placeholder="Ej. Cerrito de Agua Azul, La Soledad..." />
          </div>
          <div>
            <label style="display:block;font-weight:700;font-size:.83rem;margin-bottom:3px">Nombre conocido (opcional)</label>
            <input id="swalConocidoAsent" class="swal2-input" style="margin:0;width:100%;height:40px;font-size:.9rem" placeholder="Cómo la ubica la gente en el municipio" />
          </div>
        </div>
      `,
      showCancelButton: true,
      confirmButtonText: "Añadir a la cascada",
      cancelButtonText: "Cancelar",
      preConfirm: () => {
        const tipo = document.getElementById("swalTipoAsent")?.value || "COLONIA";
        const nombre = document.getElementById("swalNomAsent")?.value?.trim() || "";
        const nombreConocido =
          document.getElementById("swalConocidoAsent")?.value?.trim() || "";
        if (nombre.length < 2) {
          window.Swal.showValidationMessage("Ingresa el nombre.");
          return false;
        }
        return { tipo, nombre, nombreConocido };
      },
    });

    if (!value) {
      if (onCreated) onCreated(null);
      return;
    }

    const list = await ensureSettlements(state.municipalityId);
    let item = list.find(
      (x) =>
        x.tipo === value.tipo &&
        x.nombre.toLowerCase() === value.nombre.toLowerCase()
    );
    if (!item) {
      item = {
        id: `asent_${Date.now().toString(36)}`,
        nombre: value.nombre,
        nombreConocido: value.nombreConocido,
        tipo: value.tipo,
        source: "CASCADA_LOCAL",
      };
      list.push(item);
      list.sort((a, b) => a.nombre.localeCompare(b.nombre, "es"));
      state.settlementsCache.set(state.municipalityId, list);
      saveLocalSettlements(state.municipalityId);
    }

    if (onCreated) onCreated(item);
  }

  async function openPadronModal() {
    if (!window.Swal) return;
    const list = await ensureSettlements(state.municipalityId);
    const comunidades = list.filter((x) => x.tipo === "COMUNIDAD");
    const colonias = list.filter((x) => x.tipo === "COLONIA");

    const fmt = (arr) =>
      arr.length === 0
        ? `<div style="color:#64748b;font-size:.82rem">Sin registros todavía.</div>`
        : `<ul style="margin:4px 0;padding-left:18px;max-height:130px;overflow:auto;font-size:.84rem">
            ${arr
              .map(
                (x) =>
                  `<li><b>${escapeHtml(x.nombre)}</b>${
                    x.nombreConocido
                      ? ` <span style="color:#475569">(${escapeHtml(x.nombreConocido)})</span>`
                      : ""
                  }</li>`
              )
              .join("")}
          </ul>`;

    const res = await window.Swal.fire({
      title: `Comunidades y Colonias · ${getMunicipalityName()}`,
      html: `
        <div style="text-align:left;display:grid;gap:10px">
          <div style="padding:8px 10px;background:#f1f5f9;border-radius:6px;font-size:.83rem">
            <b>Cabecera municipal:</b> ${escapeHtml(getMunicipalityName())}
          </div>
          <div style="padding:8px 10px;background:#fffbeb;border:1px solid #fde68a;border-radius:6px">
            <b style="font-size:.84rem">Comunidades (${comunidades.length})</b>
            ${fmt(comunidades)}
          </div>
          <div style="padding:8px 10px;background:#ecfdf5;border:1px solid #a7f3d0;border-radius:6px">
            <b style="font-size:.84rem">Colonias (${colonias.length})</b>
            ${fmt(colonias)}
          </div>
        </div>
      `,
      showCancelButton: true,
      confirmButtonText: "+ Registrar comunidad o colonia",
      cancelButtonText: "Cerrar",
    });

    if (res.isConfirmed) {
      await promptNewSettlement("COLONIA", () => renderCurrentView());
    }
  }

  function renderTopHeaderTitles() {
    const mpioName = getMunicipalityName();
    if (els.bookTitle) {
      els.bookTitle.textContent = `Casas de la Cultura — ${mpioName} (${state.year})`;
    }
    const tab = BOTTOM_TABS.find((t) => t.id === state.activeTabId);
    if (els.bookSub) {
      els.bookSub.textContent = tab ? tab.title : "Reporte mensual de actividades";
    }
    if (els.btnCopyPrev) {
      els.btnCopyPrev.hidden =
        state.activeTabId === "SEM1" || state.activeTabId === "SEM2";
    }
  }

  function renderJumpBar() {
    if (!els.jumpBar) return;
    const isSummary = state.activeTabId === "SEM1" || state.activeTabId === "SEM2";
    els.jumpBar.hidden = isSummary;
    if (isSummary) return;

    els.jumpBar.replaceChildren();
    const label = document.createElement("span");
    label.className = "excel-jump-label";
    label.textContent = "Ir a bloque:";
    els.jumpBar.appendChild(label);

    for (const sec of SECTIONS) {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = "excel-jump-chip";
      btn.textContent = sec.jumpLabel;
      btn.addEventListener("click", () => {
        const el = document.getElementById(`excel-sec-${sec.id}`);
        el?.scrollIntoView({ behavior: "smooth", block: "start" });
      });
      els.jumpBar.appendChild(btn);
    }
  }

  function renderBottomTabs() {
    if (!els.bottomTabs) return;
    els.bottomTabs.replaceChildren();

    for (const tab of BOTTOM_TABS) {
      const btn = document.createElement("button");
      btn.type = "button";
      const isSummary = tab.type === "SUMMARY";
      const isActive = tab.id === state.activeTabId;
      btn.className = [
        "excel-bottom-tab",
        isSummary ? "summary-tab" : "",
        isActive ? "active" : "",
      ]
        .filter(Boolean)
        .join(" ");
      btn.dataset.bottomTab = tab.id;
      btn.title = tab.title;

      const txt = document.createElement("span");
      txt.textContent = tab.label;
      btn.appendChild(txt);

      if (!isSummary && hasSavedDataForMonth(tab.id)) {
        const dot = document.createElement("span");
        dot.className = "excel-tab-dot";
        dot.title = "Contiene registros capturados";
        btn.appendChild(dot);
      }

      btn.addEventListener("click", () => {
        if (state.activeTabId === tab.id) return;
        saveActiveMonthNow();
        state.activeTabId = tab.id;
        loadActiveMonthData();
        renderCurrentView();
      });

      els.bottomTabs.appendChild(btn);
    }
  }

  function updateBottomTabsDots() {
    if (!els.bottomTabs) return;
    for (const m of MONTHS) {
      const btn = els.bottomTabs.querySelector(`[data-bottom-tab="${m.num}"]`);
      if (!btn) continue;
      const existingDot = btn.querySelector(".excel-tab-dot");
      const hasData = hasSavedDataForMonth(m.num);
      if (hasData && !existingDot) {
        const dot = document.createElement("span");
        dot.className = "excel-tab-dot";
        btn.appendChild(dot);
      } else if (!hasData && existingDot) {
        existingDot.remove();
      }
    }
  }

  function buildCascadeSelectHtml(zona, selectedIdOrName) {
    if (zona === "CABECERA") {
      return `<option value="CABECERA">Cabecera municipal</option>`;
    }
    const all = state.settlementsCache.get(state.municipalityId) || [];
    const items = all.filter((x) => x.tipo === zona);
    const labelTipo = zona === "COLONIA" ? "colonia" : "comunidad";

    return [
      `<option value="">— Seleccionar ${labelTipo} —</option>`,
      ...items.map((x) => {
        const label = x.nombreConocido
          ? `${x.nombre} (${x.nombreConocido})`
          : x.nombre;
        const sel =
          x.id === selectedIdOrName || x.nombre === selectedIdOrName
            ? " selected"
            : "";
        return `<option value="${escapeHtml(x.id)}"${sel}>${escapeHtml(label)}</option>`;
      }),
      `<option value="__NEW__">➕ Nueva ${labelTipo}...</option>`,
    ].join("");
  }

  function computeSectionMetrics(sec, rows) {
    const used = rows.filter(isRowUsed);
    const cantidad = used.length;
    let totalPeople = 0;
    const sedesSet = new Set();

    for (const r of used) {
      totalPeople += rowTotalPeople(r);
      if (!sec.fixedSedeOne) {
        const key = String(r.sede || r.asentamientoId || r.zona || "").trim();
        if (key) sedesSet.add(key.toLowerCase());
      }
    }

    const sedes = sec.fixedSedeOne ? (cantidad > 0 ? 1 : 0) : sedesSet.size;
    return { cantidad, sedes, totalPeople };
  }

  function renderSectionBlockHtml(sec) {
    const spec = getColumnsSpec(sec.kind);
    const leftCols = countLeftCols(spec);
    const rows = state.sectionsData[sec.id] || [];
    const metrics = computeSectionMetrics(sec, rows);

    const demoHeadTop = DEMO_GROUPS.map(
      (g) =>
        `<th colspan="2" class="${g.isFirst ? "demo-band-first" : "demo-band"}" style="width:92px">${escapeHtml(g.label)}</th>`
    ).join("");

    const demoHeadSub = DEMO_GROUPS.map(
      () => `<th style="width:46px">M</th><th style="width:46px">H</th>`
    ).join("");

    const extraSubHeaders = [];
    if (spec.hasProject) {
      extraSubHeaders.push('<th style="width:205px">Proyecto colaborativo</th>');
    }
    if (spec.hasEventName) {
      extraSubHeaders.push('<th style="width:165px">Evento</th>');
    }
    if (spec.hasPonente) {
      extraSubHeaders.push('<th style="width:165px">Ponente</th>');
    }
    if (spec.hasTerritory) {
      extraSubHeaders.push('<th style="width:105px">Zona</th>');
      extraSubHeaders.push('<th style="width:185px">Comunidad / Colonia</th>');
    }
    if (spec.hasSede) {
      extraSubHeaders.push(`<th style="width:175px">${escapeHtml(spec.sedeHeader || "Sede")}</th>`);
    }
    if (spec.hasMeetingType) {
      extraSubHeaders.push('<th style="width:125px">Tipo</th>');
    }
    if (spec.hasEventType) {
      extraSubHeaders.push('<th style="width:140px">Tipo</th>');
    }
    if (spec.hasTemporality) {
      extraSubHeaders.push('<th style="width:110px">Temporalidad</th>');
    }
    if (spec.hasRange) {
      extraSubHeaders.push('<th style="width:118px">Inicio</th>');
      extraSubHeaders.push('<th style="width:118px">Fin</th>');
    }
    if (spec.hasDate) {
      extraSubHeaders.push('<th style="width:118px">Fecha</th>');
    }
    if (spec.hasDays) {
      extraSubHeaders.push('<th style="width:170px">Días de sesión</th>');
    }
    if (spec.hasHorario) {
      extraSubHeaders.push('<th style="width:125px">Horario</th>');
    }
    if (spec.hasCosto) {
      extraSubHeaders.push('<th style="width:115px">Costo / libre</th>');
    }
    if (spec.hasDocente) {
      extraSubHeaders.push('<th style="width:165px">Nombre del docente</th>');
    }

    const colSums = {};
    for (const k of DEMO_KEYS) colSums[k] = 0;
    let grandTotal = 0;
    let sumEst = 0;
    let sumMun = 0;

    const bodyRowsHtml = rows
      .map((r, idx) => {
        const rTotal = rowTotalPeople(r);
        grandTotal += rTotal;
        for (const k of DEMO_KEYS) colSums[k] += toInt(r[k]);
        sumEst += toMoney(r.recursoEst);
        sumMun += toMoney(r.recursoMun);

        const tds = [];
        tds.push(`<td class="excel-rownum">${idx + 1}</td>`);
        tds.push(`
          <td>
            <input
              type="text"
              class="excel-cell-input"
              data-field="titulo"
              value="${escapeHtml(r.titulo)}"
            />
          </td>
        `);

        if (spec.hasProject) {
          const opts = [
            '<option value="">— Seleccionar —</option>',
            ...COLLAB_CATALOG_SEED.map(
              (p) =>
                `<option value="${escapeHtml(p)}"${r.subtitulo === p ? " selected" : ""}>${escapeHtml(p)}</option>`
            ),
          ].join("");
          tds.push(`<td><select class="excel-cell-select" data-field="subtitulo">${opts}</select></td>`);
        }

        if (spec.hasEventName || spec.hasPonente) {
          tds.push(`
            <td>
              <input type="text" class="excel-cell-input" data-field="subtitulo" value="${escapeHtml(r.subtitulo)}" />
            </td>
          `);
        }

        if (spec.hasTerritory) {
          const z = r.zona || "CABECERA";
          tds.push(`
            <td>
              <select class="excel-cell-select" data-field="zona">
                <option value="CABECERA"${z === "CABECERA" ? " selected" : ""}>Cabecera</option>
                <option value="COMUNIDAD"${z === "COMUNIDAD" ? " selected" : ""}>Comunidad</option>
                <option value="COLONIA"${z === "COLONIA" ? " selected" : ""}>Colonia</option>
              </select>
            </td>
            <td>
              <select class="excel-cell-select" data-field="asentamientoId" ${z === "CABECERA" ? "disabled" : ""}>
                ${buildCascadeSelectHtml(z, r.asentamientoId || r.asentamientoNombre)}
              </select>
            </td>
          `);
        }

        if (spec.hasSede) {
          tds.push(`
            <td>
              <input type="text" class="excel-cell-input" data-field="sede" value="${escapeHtml(r.sede)}" />
            </td>
          `);
        }

        if (spec.hasMeetingType) {
          tds.push(`
            <td>
              <select class="excel-cell-select" data-field="tipo">
                <option value="MUNICIPAL"${r.tipo === "MUNICIPAL" ? " selected" : ""}>Municipal</option>
                <option value="COLABORATIVA"${r.tipo === "COLABORATIVA" ? " selected" : ""}>Colaborativa</option>
                <option value="ESTATAL"${r.tipo === "ESTATAL" ? " selected" : ""}>Estatal</option>
              </select>
            </td>
          `);
        }

        if (spec.hasEventType) {
          tds.push(`
            <td>
              <input type="text" class="excel-cell-input" data-field="tipo" value="${escapeHtml(r.tipo)}" placeholder="Artística / Comunitaria..." />
            </td>
          `);
        }

        if (spec.hasTemporality) {
          tds.push(`
            <td>
              <select class="excel-cell-select" data-field="temporalidad">
                <option value="ANUAL"${r.temporalidad === "ANUAL" ? " selected" : ""}>Anual</option>
                <option value="SEMESTRAL"${r.temporalidad === "SEMESTRAL" ? " selected" : ""}>Semestral</option>
                <option value="MENSUAL"${r.temporalidad === "MENSUAL" ? " selected" : ""}>Mensual</option>
                <option value="TEMPORAL"${r.temporalidad === "TEMPORAL" ? " selected" : ""}>Temporal</option>
              </select>
            </td>
          `);
        }

        if (spec.hasRange) {
          tds.push(`
            <td><input type="date" class="excel-cell-input" data-field="inicio" value="${escapeHtml(r.inicio)}" /></td>
            <td><input type="date" class="excel-cell-input" data-field="fin" value="${escapeHtml(r.fin)}" /></td>
          `);
        }

        if (spec.hasDate) {
          tds.push(`
            <td><input type="date" class="excel-cell-input" data-field="fecha" value="${escapeHtml(r.fecha)}" /></td>
          `);
        }

        if (spec.hasDays) {
          const btns = DAYS_OF_WEEK.map((d) => {
            const on = Boolean(r.dias?.[d.key]);
            return `<button type="button" class="excel-day-toggle${on ? " on" : ""}" data-day="${d.key}" title="${d.title}">${d.label}</button>`;
          }).join("");
          tds.push(`<td><div class="excel-days-cell">${btns}</div></td>`);
        }

        if (spec.hasHorario) {
          tds.push(`
            <td><input type="text" class="excel-cell-input" data-field="horario" value="${escapeHtml(r.horario)}" placeholder="Ej. 4 a 6 pm" /></td>
          `);
        }

        if (spec.hasCosto) {
          tds.push(`
            <td><input type="text" class="excel-cell-input" data-field="costo" value="${escapeHtml(r.costo)}" placeholder="Sin costo / $80" /></td>
          `);
        }

        if (spec.hasDocente) {
          tds.push(`
            <td><input type="text" class="excel-cell-input" data-field="docente" value="${escapeHtml(r.docente)}" /></td>
          `);
        }

        for (const k of DEMO_KEYS) {
          const val = toInt(r[k]);
          tds.push(`
            <td>
              <input
                type="number"
                min="0"
                step="1"
                inputmode="numeric"
                class="excel-cell-input excel-cell-num${val === 0 ? " is-zero" : ""}"
                data-demo="${k}"
                value="${val === 0 ? "" : val}"
                placeholder="0"
              />
            </td>
          `);
        }

        tds.push(`
          <td class="excel-formula-cell" data-row-sum title="Fórmula automática: suma de participantes/asistentes de la fila">
            ${rTotal}
          </td>
        `);

        tds.push(`
          <td><input type="number" min="0" step="0.01" class="excel-cell-input excel-cell-num" data-field="recursoEst" value="${escapeHtml(r.recursoEst)}" placeholder="0" /></td>
          <td><input type="number" min="0" step="0.01" class="excel-cell-input excel-cell-num" data-field="recursoMun" value="${escapeHtml(r.recursoMun)}" placeholder="0" /></td>
        `);

        tds.push(`
          <td class="excel-del-cell">
            <button type="button" class="excel-del-btn" data-del-row title="Quitar fila">✕</button>
          </td>
        `);

        return `<tr data-row-id="${r.id}">${tds.join("")}</tr>`;
      })
      .join("");

    const footDemoHtml = DEMO_KEYS.map(
      (k) => `<td class="subtotal-num" data-sec-demo-sum="${k}">${colSums[k]}</td>`
    ).join("");

    const sedesCounterHtml =
      sec.kind === "WORKSHOP_CC" || sec.kind === "SALON_DESC" || sec.kind === "SUMMER"
        ? `<span class="excel-counter-box">Sedes: <b data-sec-sedes="${sec.id}">${metrics.sedes}</b></span>`
        : "";

    return `
      <section id="excel-sec-${sec.id}" class="excel-section-block" data-section-id="${sec.id}">
        <div class="excel-block-titlebar">
          <h3>${escapeHtml(sec.title)}</h3>
          <div class="excel-block-counters">
            <span class="excel-counter-box">Cantidad: <b data-sec-count="${sec.id}">${metrics.cantidad}</b></span>
            ${sedesCounterHtml}
            <span class="excel-counter-box">${escapeHtml(sec.peopleLabel)}: <b data-sec-people="${sec.id}">${metrics.totalPeople.toLocaleString("es-MX")}</b></span>
            <button type="button" class="excel-add-row-inline" data-add-row="${sec.id}">+ Fila</button>
          </div>
        </div>

        <div class="excel-table-scroll">
          <table class="excel-grid">
            <thead>
              <tr>
                <th colspan="${leftCols}">Registro operativo</th>
                ${demoHeadTop}
                <th rowspan="2" class="total-band" style="width:76px">Total<br /><span style="font-weight:600;font-size:.65rem">(Auto)</span></th>
                <th colspan="2" style="width:150px">Recurso ($$)</th>
                <th rowspan="2" style="width:30px"></th>
              </tr>
              <tr>
                <th style="width:34px">No.</th>
                <th style="width:${spec.mainWidth}px">${escapeHtml(spec.mainHeader)}</th>
                ${extraSubHeaders.join("")}
                ${demoHeadSub}
                <th style="width:75px">Est.</th>
                <th style="width:75px">Munic.</th>
              </tr>
            </thead>
            <tbody>
              ${bodyRowsHtml}
            </tbody>
            <tfoot>
              <tr>
                <td colspan="${leftCols}" class="subtotal-label">Subtotal sección ${sec.num}:</td>
                ${footDemoHtml}
                <td class="subtotal-grand" data-sec-grand="${sec.id}">${grandTotal.toLocaleString("es-MX")}</td>
                <td class="subtotal-num" data-sec-est="${sec.id}">${sumEst > 0 ? sumEst.toLocaleString("es-MX") : "0"}</td>
                <td class="subtotal-num" data-sec-mun="${sec.id}">${sumMun > 0 ? sumMun.toLocaleString("es-MX") : "0"}</td>
                <td></td>
              </tr>
            </tfoot>
          </table>
        </div>
      </section>
    `;
  }

  function renderMonthSheet() {
    const monthObj = MONTHS.find((m) => m.num === state.activeTabId) || MONTHS[0];
    const mpioName = getMunicipalityName();
    const canSwitchMunicipality = adminMode && state.municipalities.length > 1;

    const municipalityCellHtml = canSwitchMunicipality
      ? `<select id="excelInlineMunicipalitySelect" class="excel-generales-inline-select">
          ${state.municipalities
            .map(
              (m) =>
                `<option value="${escapeHtml(m.id)}"${m.id === state.municipalityId ? " selected" : ""}>${escapeHtml(m.nombre_oficial)}</option>`
            )
            .join("")}
        </select>`
      : `<span class="excel-generales-fixed">${escapeHtml(mpioName)}</span>`;

    const eduSectionsHtml = SECTIONS.filter(
      (s) => s.axis === "EDUCACION_CONTINUA"
    )
      .map(renderSectionBlockHtml)
      .join("");

    const medSectionsHtml = SECTIONS.filter(
      (s) => s.axis === "MEDIACION_CULTURAL"
    )
      .map(renderSectionBlockHtml)
      .join("");

    els.canvas.innerHTML = `
      <div class="excel-sheet-dochead">
        <div class="excel-dochead-banner">
          <div class="excel-dochead-inst">
            <strong>SECRETARÍA DE CULTURA DE GUANAJUATO · Dirección General de Vinculación y Desarrollo Cultural</strong>
            <span>Casas de la Cultura — Informe mensual de actividades</span>
          </div>
          <div class="excel-dochead-month-tag">${escapeHtml(monthObj.name)} ${escapeHtml(state.year)}</div>
        </div>

        <table class="excel-generales-table">
          <tbody>
            <tr>
              <th>Municipio:</th>
              <td>${municipalityCellHtml}</td>
              <th>Mes:</th>
              <td>${escapeHtml(monthObj.label)} ${escapeHtml(state.year)}</td>
            </tr>
            <tr>
              <th>Elabora:</th>
              <td>
                <input
                  id="excelInlineElaboraInput"
                  type="text"
                  class="excel-generales-inline-input"
                  value="${escapeHtml(state.elabora)}"
                  placeholder="Nombre de quien reporta"
                />
              </td>
              <th>Fecha:</th>
              <td>${escapeHtml(todayFormatted())}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="excel-axis-banner">
        <div>EDUCACIÓN CONTINUA</div>
        <span>Talleres · Salones Culturales · Verano · Capacitaciones</span>
      </div>
      ${eduSectionsHtml}

      <div class="excel-axis-banner mediacion">
        <div>MEDIACIÓN CULTURAL</div>
        <span>Reuniones · Promoción de Talento Local · Proyectos Colaborativos · Eventos Municipales</span>
      </div>
      ${medSectionsHtml}
    `;

    const inlineMpio = document.getElementById("excelInlineMunicipalitySelect");
    inlineMpio?.addEventListener("change", async () => {
      saveActiveMonthNow();
      state.municipalityId = inlineMpio.value;
      await ensureSettlements(state.municipalityId);
      loadActiveMonthData();
      renderCurrentView();
    });

    const inlineElabora = document.getElementById("excelInlineElaboraInput");
    inlineElabora?.addEventListener("input", () => {
      state.elabora = inlineElabora.value;
      scheduleSave();
    });
  }

  // Hoja de Concentrado Semestral automático (Concent. Sem 1 / Sem 2)
  function renderSummarySheet(semNumber) {
    const semMonths = MONTHS.filter((m) => m.sem === semNumber);
    const periodLabel =
      semNumber === 1 ? "De Enero a Julio" : "De Agosto a Diciembre";

    const rowsSummary = SECTIONS.map((sec) => {
      const demoTotals = {};
      for (const k of DEMO_KEYS) demoTotals[k] = 0;
      let countActs = 0;
      let totalPersonas = 0;

      for (const m of semMonths) {
        const stored = readMonthFromStorage(m.num);
        const list = stored?.sectionsData?.[sec.id] || [];
        for (const r of list) {
          if (!isRowUsed(r)) continue;
          countActs += 1;
          for (const k of DEMO_KEYS) {
            const v = toInt(r[k]);
            demoTotals[k] += v;
            totalPersonas += v;
          }
        }
      }

      return { sec, countActs, demoTotals, totalPersonas };
    });

    // Cálculo automático del máximo de alumnos por taller continuo en el semestre
    const workshopPeaks = new Map();
    for (const m of semMonths) {
      const stored = readMonthFromStorage(m.num);
      for (const secId of ["talleres_cc", "salones"]) {
        const list = stored?.sectionsData?.[secId] || [];
        for (const r of list) {
          const name = String(r.titulo || "").trim();
          if (!name) continue;
          const sede =
            secId === "salones"
              ? String(r.sede || r.asentamientoNombre || "Salón").trim()
              : "Casa de Cultura";
          const key = `${secId}::${name.toLowerCase()}::${sede.toLowerCase()}`;
          const tot = rowTotalPeople(r);
          const prev = workshopPeaks.get(key) || {
            taller: name,
            sede,
            docente: r.docente || "—",
            maxAlumnos: 0,
            mesMax: m.short,
          };
          if (tot >= prev.maxAlumnos) {
            prev.maxAlumnos = tot;
            prev.mesMax = m.short;
          }
          workshopPeaks.set(key, prev);
        }
      }
    }

    const grandCols = {};
    for (const k of DEMO_KEYS) grandCols[k] = 0;
    let grandActs = 0;
    let grandPeople = 0;

    for (const item of rowsSummary) {
      grandActs += item.countActs;
      grandPeople += item.totalPersonas;
      for (const k of DEMO_KEYS) grandCols[k] += item.demoTotals[k];
    }

    els.canvas.innerHTML = `
      <div class="excel-sheet-dochead">
        <div class="excel-dochead-banner">
          <div class="excel-dochead-inst">
            <strong>SECRETARÍA DE CULTURA DE GUANAJUATO · Casas de la Cultura</strong>
            <span>Informe concentrado semestral del municipio de ${escapeHtml(getMunicipalityName())}</span>
          </div>
          <div class="excel-dochead-month-tag">CONCENTRADO SEMESTRE ${semNumber} (${periodLabel})</div>
        </div>
      </div>

      <div class="excel-concentrado-wrap">
        <table class="excel-concentrado-table">
          <thead>
            <tr>
              <th rowspan="2">No.</th>
              <th rowspan="2" style="text-align:left">Proceso / Actividad</th>
              <th rowspan="2">Cantidad</th>
              ${DEMO_GROUPS.map((g) => `<th colspan="2">${escapeHtml(g.label)}</th>`).join("")}
              <th rowspan="2">Total Personas</th>
            </tr>
            <tr>
              ${DEMO_GROUPS.map(() => "<th>M</th><th>H</th>").join("")}
            </tr>
          </thead>
          <tbody>
            ${rowsSummary
              .map(
                (item) => `
              <tr>
                <td class="num">${item.sec.num}</td>
                <td><b>${escapeHtml(item.sec.title)}</b></td>
                <td class="num"><b>${item.countActs}</b></td>
                ${DEMO_KEYS.map((k) => `<td class="num">${item.demoTotals[k]}</td>`).join("")}
                <td class="num"><b>${item.totalPersonas.toLocaleString("es-MX")}</b></td>
              </tr>
            `
              )
              .join("")}
            <tr class="sum-row">
              <td colspan="2" style="text-align:right">TOTAL SEMESTRE ${semNumber}:</td>
              <td class="num">${grandActs}</td>
              ${DEMO_KEYS.map((k) => `<td class="num">${grandCols[k]}</td>`).join("")}
              <td class="num">${grandPeople.toLocaleString("es-MX")}</td>
            </tr>
          </tbody>
        </table>

        <h3 style="margin:18px 0 8px;font-size:.95rem;color:#003663">
          Máximo de alumnos por taller en el periodo (${periodLabel})
        </h3>
        <table class="excel-concentrado-table">
          <thead>
            <tr>
              <th style="text-align:left">Taller / Disciplina</th>
              <th style="text-align:left">Sede / Lugar</th>
              <th style="text-align:left">Docente</th>
              <th>Mes pico</th>
              <th>Máximo de alumnos</th>
            </tr>
          </thead>
          <tbody>
            ${
              workshopPeaks.size === 0
                ? `<tr><td colspan="5" style="text-align:center;color:#64748b">Aún no hay talleres capturados en los meses de este semestre.</td></tr>`
                : [...workshopPeaks.values()]
                    .map(
                      (w) => `
                  <tr>
                    <td><b>${escapeHtml(w.taller)}</b></td>
                    <td>${escapeHtml(w.sede)}</td>
                    <td>${escapeHtml(w.docente)}</td>
                    <td style="text-align:center">${escapeHtml(w.mesMax)}</td>
                    <td class="num"><b>${w.maxAlumnos}</b></td>
                  </tr>
                `
                    )
                    .join("")
            }
          </tbody>
        </table>
      </div>
    `;
  }

  function renderCurrentView() {
    renderTopHeaderTitles();
    renderJumpBar();
    renderBottomTabs();

    if (state.activeTabId === "SEM1") {
      renderSummarySheet(1);
    } else if (state.activeTabId === "SEM2") {
      renderSummarySheet(2);
    } else {
      renderMonthSheet();
    }
  }

  // Recálculo instantáneo de una sección sin perder foco de escritura
  function refreshSectionTotalsInDom(secId) {
    const sec = SECTIONS.find((s) => s.id === secId);
    if (!sec) return;
    const blockEl = document.getElementById(`excel-sec-${secId}`);
    if (!blockEl) return;

    const rows = state.sectionsData[secId] || [];
    const colSums = {};
    for (const k of DEMO_KEYS) colSums[k] = 0;
    let grand = 0;
    let sumEst = 0;
    let sumMun = 0;

    for (const r of rows) {
      const rt = rowTotalPeople(r);
      grand += rt;
      for (const k of DEMO_KEYS) colSums[k] += toInt(r[k]);
      sumEst += toMoney(r.recursoEst);
      sumMun += toMoney(r.recursoMun);

      const tr = blockEl.querySelector(`tr[data-row-id="${r.id}"]`);
      const sumCell = tr?.querySelector("[data-row-sum]");
      if (sumCell) sumCell.textContent = String(rt);
    }

    for (const k of DEMO_KEYS) {
      const td = blockEl.querySelector(`[data-sec-demo-sum="${k}"]`);
      if (td) td.textContent = String(colSums[k]);
    }

    const grandEl = blockEl.querySelector(`[data-sec-grand="${secId}"]`);
    if (grandEl) grandEl.textContent = grand.toLocaleString("es-MX");

    const estEl = blockEl.querySelector(`[data-sec-est="${secId}"]`);
    if (estEl) estEl.textContent = sumEst > 0 ? sumEst.toLocaleString("es-MX") : "0";

    const munEl = blockEl.querySelector(`[data-sec-mun="${secId}"]`);
    if (munEl) munEl.textContent = sumMun > 0 ? sumMun.toLocaleString("es-MX") : "0";

    const metrics = computeSectionMetrics(sec, rows);
    const countEl = blockEl.querySelector(`[data-sec-count="${secId}"]`);
    if (countEl) countEl.textContent = String(metrics.cantidad);

    const sedesEl = blockEl.querySelector(`[data-sec-sedes="${secId}"]`);
    if (sedesEl) sedesEl.textContent = String(metrics.sedes);

    const peopleEl = blockEl.querySelector(`[data-sec-people="${secId}"]`);
    if (peopleEl) peopleEl.textContent = metrics.totalPeople.toLocaleString("es-MX");
  }

  // Eventos delegados en el lienzo de la hoja de cálculo
  els.canvas.addEventListener("input", (event) => {
    const target = event.target;
    const blockEl = target.closest(".excel-section-block[data-section-id]");
    const tr = target.closest("tr[data-row-id]");
    if (!blockEl || !tr) return;

    const secId = blockEl.dataset.sectionId;
    const rows = state.sectionsData[secId] || [];
    const row = rows.find((r) => r.id === tr.dataset.rowId);
    if (!row) return;

    if (target.dataset.demo) {
      const k = target.dataset.demo;
      const val = toInt(target.value);
      row[k] = val;
      target.classList.toggle("is-zero", val === 0);
      refreshSectionTotalsInDom(secId);
      scheduleSave();
      return;
    }

    const field = target.dataset.field;
    if (field) {
      row[field] = target.value;
      refreshSectionTotalsInDom(secId);
      scheduleSave();
    }
  });

  els.canvas.addEventListener("change", async (event) => {
    const target = event.target;
    const blockEl = target.closest(".excel-section-block[data-section-id]");
    const tr = target.closest("tr[data-row-id]");
    if (!blockEl || !tr) return;

    const secId = blockEl.dataset.sectionId;
    const rows = state.sectionsData[secId] || [];
    const row = rows.find((r) => r.id === tr.dataset.rowId);
    if (!row) return;

    const field = target.dataset.field;
    if (field === "zona") {
      row.zona = target.value;
      row.asentamientoId = "";
      row.asentamientoNombre = "";
      scheduleSave();
      renderMonthSheet();
      return;
    }

    if (field === "asentamientoId") {
      if (target.value === "__NEW__") {
        await promptNewSettlement(row.zona || "COLONIA", (created) => {
          if (created) {
            row.zona = created.tipo;
            row.asentamientoId = created.id;
            row.asentamientoNombre = created.nombre;
            scheduleSave();
          }
          renderMonthSheet();
        });
        return;
      }
      row.asentamientoId = target.value;
      const all = state.settlementsCache.get(state.municipalityId) || [];
      const found = all.find((x) => x.id === target.value);
      row.asentamientoNombre = found ? found.nombre : "";
      refreshSectionTotalsInDom(secId);
      scheduleSave();
      return;
    }

    if (field) {
      row[field] = target.value;
      refreshSectionTotalsInDom(secId);
      scheduleSave();
    }
  });

  els.canvas.addEventListener("click", (event) => {
    const addBtn = event.target.closest("button[data-add-row]");
    if (addBtn) {
      const secId = addBtn.dataset.addRow;
      const sec = SECTIONS.find((s) => s.id === secId);
      if (!sec) return;
      state.sectionsData[secId].push(createBlankRow(sec.kind));
      scheduleSave();
      renderMonthSheet();
      return;
    }

    const dayBtn = event.target.closest("button[data-day]");
    if (dayBtn) {
      const blockEl = dayBtn.closest(".excel-section-block[data-section-id]");
      const tr = dayBtn.closest("tr[data-row-id]");
      if (!blockEl || !tr) return;
      const rows = state.sectionsData[blockEl.dataset.sectionId] || [];
      const row = rows.find((r) => r.id === tr.dataset.rowId);
      if (!row) return;
      const dKey = dayBtn.dataset.day;
      row.dias[dKey] = !row.dias[dKey];
      dayBtn.classList.toggle("on", row.dias[dKey]);
      scheduleSave();
      return;
    }

    const delBtn = event.target.closest("button[data-del-row]");
    if (delBtn) {
      const blockEl = delBtn.closest(".excel-section-block[data-section-id]");
      const tr = delBtn.closest("tr[data-row-id]");
      if (!blockEl || !tr) return;
      const secId = blockEl.dataset.sectionId;
      const sec = SECTIONS.find((s) => s.id === secId);
      const rows = state.sectionsData[secId] || [];
      const idx = rows.findIndex((r) => r.id === tr.dataset.rowId);
      if (idx === -1) return;
      if (rows.length <= 1) {
        state.sectionsData[secId] = [createBlankRow(sec?.kind || "WORKSHOP_CC")];
      } else {
        rows.splice(idx, 1);
      }
      scheduleSave();
      renderMonthSheet();
    }
  });

  // Navegación con Enter y flechas Arriba/Abajo entre filas de la misma columna como en Excel
  els.canvas.addEventListener("keydown", (event) => {
    const target = event.target;
    if (!(target instanceof HTMLInputElement)) return;
    if (!["Enter", "ArrowDown", "ArrowUp"].includes(event.key)) return;

    const blockEl = target.closest(".excel-section-block[data-section-id]");
    if (!blockEl) return;

    const selector = target.dataset.demo
      ? `input[data-demo="${target.dataset.demo}"]`
      : target.dataset.field
        ? `input[data-field="${target.dataset.field}"]`
        : null;
    if (!selector) return;

    event.preventDefault();
    const colInputs = [...blockEl.querySelectorAll(selector)];
    const idx = colInputs.indexOf(target);
    if (idx === -1) return;

    const nextIdx = event.key === "ArrowUp" ? idx - 1 : idx + 1;
    if (nextIdx >= colInputs.length && event.key === "Enter") {
      // Si presiona Enter en la última fila, agrega una nueva fila automáticamente como tabla de Excel
      const secId = blockEl.dataset.sectionId;
      const sec = SECTIONS.find((s) => s.id === secId);
      if (sec) {
        state.sectionsData[secId].push(createBlankRow(sec.kind));
        scheduleSave();
        renderMonthSheet();
        const refreshedBlock = document.getElementById(`excel-sec-${secId}`);
        const refreshedInputs = refreshedBlock?.querySelectorAll(selector);
        const createdInput = refreshedInputs?.[nextIdx];
        createdInput?.focus();
      }
      return;
    }

    const nextInput = colInputs[nextIdx];
    if (nextInput) {
      nextInput.focus();
      if (nextInput.type !== "date") nextInput.select?.();
    }
  });

  // Copiar talleres permanentes del mes anterior (para no volver a escribir disciplinas/horarios)
  els.btnCopyPrev?.addEventListener("click", () => {
    const idx = MONTHS.findIndex((m) => m.num === state.activeTabId);
    if (idx <= 0) {
      window.Swal?.fire(
        "Mes inicial",
        "Ubícate de Febrero en adelante para traer los talleres y salones capturados el mes previo.",
        "info"
      );
      return;
    }
    const prevMonth = MONTHS[idx - 1];
    const prevStored = readMonthFromStorage(prevMonth.num);
    if (!prevStored) {
      window.Swal?.fire(
        `Sin registros en ${prevMonth.label}`,
        `Todavía no hay talleres guardados en la hoja de ${prevMonth.label}.`,
        "info"
      );
      return;
    }

    let copiedTotal = 0;
    for (const secId of ["talleres_cc", "salones"]) {
      const sec = SECTIONS.find((s) => s.id === secId);
      const prevRows = (prevStored.sectionsData?.[secId] || []).filter(
        (r) => String(r.titulo || "").trim() !== ""
      );
      if (prevRows.length === 0) continue;

      const cloned = prevRows.map((r) => {
        const copy = JSON.parse(JSON.stringify(r));
        copy.id = makeRowId();
        for (const k of DEMO_KEYS) copy[k] = 0;
        return copy;
      });

      const currentUsed = (state.sectionsData[secId] || []).filter(isRowUsed);
      state.sectionsData[secId] = [
        ...currentUsed,
        ...cloned,
        createBlankRow(sec.kind),
      ];
      copiedTotal += cloned.length;
    }

    if (copiedTotal === 0) {
      window.Swal?.fire(
        "Sin talleres previos",
        `No se encontraron disciplinas registradas en ${prevMonth.label}.`,
        "info"
      );
      return;
    }

    saveActiveMonthNow();
    renderMonthSheet();
    window.Swal?.fire({
      icon: "success",
      title: `Se copiaron ${copiedTotal} taller(es) de ${prevMonth.label}`,
      text: "Se conservaron disciplinas, sedes, horarios y docentes; captura únicamente la asistencia de este mes.",
      timer: 2800,
    });
  });

  els.btnPadron?.addEventListener("click", openPadronModal);

  els.btnSave?.addEventListener("click", () => {
    saveActiveMonthNow();
    window.Swal?.fire({
      icon: "success",
      title: "Hoja guardada",
      text: "Tus filas quedaron guardadas. Al volver a entrar verás tu hoja exactamente como la dejaste.",
      timer: 2000,
    });
  });

  // Exportar el libro completo (ENE..DIC) a .xlsx real
  els.btnExport?.addEventListener("click", () => {
    if (!window.XLSX) return;
    saveActiveMonthNow();

    const wb = window.XLSX.utils.book_new();
    const mpio = getMunicipalityName();

    for (const m of MONTHS) {
      const stored =
        m.num === state.activeTabId
          ? { elabora: state.elabora, sectionsData: state.sectionsData }
          : readMonthFromStorage(m.num);

      const aoa = [
        ["SECRETARÍA DE CULTURA DE GUANAJUATO — CASAS DE LA CULTURA"],
        [`Informe concentrado de actividades correspondiente al mes de: ${m.name} ${state.year}`],
        [`Municipio: ${mpio}`, "", `Elabora: ${stored?.elabora || state.elabora || ""}`],
        [],
      ];

      for (const sec of SECTIONS) {
        const list = (stored?.sectionsData?.[sec.id] || []).filter(isRowUsed);
        aoa.push([sec.title]);
        aoa.push([
          "No.",
          "Actividad / Disciplina / Tema",
          "Detalle / Proyecto / Evento",
          "Zona",
          "Comunidad / Colonia",
          "Sede",
          "Tipo",
          "Temporalidad",
          "Inicio",
          "Fin",
          "Fecha",
          "Días",
          "Horario",
          "Costo",
          "Docente",
          "Primera inf. M",
          "Primera inf. H",
          "Infancias M",
          "Infancias H",
          "Adolescentes M",
          "Adolescentes H",
          "Jóvenes M",
          "Jóvenes H",
          "Adultos M",
          "Adultos H",
          "Adultos may. M",
          "Adultos may. H",
          `Total ${sec.peopleLabel}`,
          "Recurso Est.",
          "Recurso Munic.",
        ]);

        list.forEach((r, idx) => {
          const daysStr = DAYS_OF_WEEK.filter((d) => r.dias?.[d.key])
            .map((d) => d.label)
            .join("-");
          aoa.push([
            idx + 1,
            r.titulo,
            r.subtitulo,
            r.zona,
            r.asentamientoNombre || (r.zona === "CABECERA" ? "Cabecera" : ""),
            r.sede,
            r.tipo,
            r.temporalidad,
            r.inicio,
            r.fin,
            r.fecha,
            daysStr,
            r.horario,
            r.costo,
            r.docente,
            toInt(r.pi_m),
            toInt(r.pi_h),
            toInt(r.inf_m),
            toInt(r.inf_h),
            toInt(r.ado_m),
            toInt(r.ado_h),
            toInt(r.jov_m),
            toInt(r.jov_h),
            toInt(r.adu_m),
            toInt(r.adu_h),
            toInt(r.may_m),
            toInt(r.may_h),
            rowTotalPeople(r),
            toMoney(r.recursoEst),
            toMoney(r.recursoMun),
          ]);
        });
        aoa.push([]);
      }

      const ws = window.XLSX.utils.aoa_to_sheet(aoa);
      window.XLSX.utils.book_append_sheet(wb, ws, m.short);
    }

    const cleanName = mpio.replace(/\s+/g, "_");
    window.XLSX.writeFile(wb, `Libro_CasasDeLaCultura_${cleanName}_${state.year}.xlsx`);
  });

  // Carga del municipio asignado al usuario en sesión
  let mpios = [];
  if (context) {
    try {
      mpios = await loadMunicipalities(context);
    } catch (err) {
      console.warn("No se pudieron consultar municipios en catálogo:", err);
    }
  }
  if (mpios.length === 0) {
    mpios = [{ id: "local-municipio", nombre_oficial: "Mi Municipio" }];
  }

  state.municipalities = mpios;
  state.municipalityId = mpios[0].id;

  await ensureSettlements(state.municipalityId);
  loadActiveMonthData();
  renderCurrentView();
}
