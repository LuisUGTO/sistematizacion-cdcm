/**
 * VINCULACIÓN CULTURAL — CASAS DE LA CULTURA (PEC 2026)
 * capture-matrix.js
 *
 * Paso 1 del rediseño operativo:
 * - Unidad operativa renombrada en interfaz a "Casas de la Cultura".
 * - Matriz mensual tipo libro de Excel con las 8 actividades del PEC 2026
 *   (Eje I: Educación Continua · Eje II: Mediación Cultural).
 * - Grupo etario Primera Infancia (0–5 años) integrado en todas las hojas.
 * - Suma automática de participantes/asistentes (M + H) en tiempo real.
 * - Cascada territorial diferenciada: Cabecera · Comunidad · Colonia,
 *   con registro al vuelo de nuevas colonias/comunidades y nombre conocido.
 * - Continuidad mensual de talleres y cálculo automático del máximo de
 *   alumnos por taller en el periodo (regla PEC 2026).
 *
 * SEGURIDAD E INTEGRIDAD:
 * - No escribe aún en el servicio compartido de Supabase (Paso 1: validación
 *   interactiva y borrador local aislado por usuario, municipio y periodo).
 * - Lee municipios y comunidades respetando sesión y RLS mediante catalogs.js.
 */

import { getDisplayIdentity } from "./auth.js?v=7.4.3";
import {
  loadMunicipalities,
  loadCommunities,
} from "./catalogs.js?v=7.2.2";

const STORAGE_PREFIX = "vc_casas_cultura_matriz_2026_v1";
const SETTLEMENTS_PREFIX = "vc_casas_cultura_asentamientos_2026_v1";

const MONTHS = Object.freeze([
  { num: "01", name: "Enero", short: "ENE" },
  { num: "02", name: "Febrero", short: "FEB" },
  { num: "03", name: "Marzo", short: "MAR" },
  { num: "04", name: "Abril", short: "ABR" },
  { num: "05", name: "Mayo", short: "MAY" },
  { num: "06", name: "Junio", short: "JUN" },
  { num: "07", name: "Julio", short: "JUL" },
  { num: "08", name: "Agosto", short: "AGO" },
  { num: "09", name: "Septiembre", short: "SEP" },
  { num: "10", name: "Octubre", short: "OCT" },
  { num: "11", name: "Noviembre", short: "NOV" },
  { num: "12", name: "Diciembre", short: "DIC" },
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
  { key: "pi", label: "Primera infancia", range: "0–5 años", isNew: true },
  { key: "inf", label: "Infancias", range: "6–12 años", isNew: false },
  { key: "ado", label: "Adolescentes", range: "13–17 años", isNew: false },
  { key: "jov", label: "Jóvenes", range: "18–29 años", isNew: false },
  { key: "adu", label: "Adultos", range: "30–59 años", isNew: false },
  { key: "may", label: "Adultos mayores", range: "60+ años", isNew: false },
]);

const DEMO_KEYS = Object.freeze(
  DEMO_GROUPS.flatMap((g) => [`${g.key}_m`, `${g.key}_h`])
);

const SAMPLE_COLLAB_PROJECTS = Object.freeze([
  "Circuito Cultural Bajío — Artes Escénicas en Movimiento",
  "Encuentro Regional de Saberes y Tradición Oral",
  "Caravana Cultural Intermunicipal del Noreste",
  "Red de Coros y Ensambles Comunitarios Regionales",
]);

const SHEETS = Object.freeze([
  {
    id: "talleres_cc",
    axis: "EDUCACION_CONTINUA",
    num: "1",
    shortTitle: "1. Talleres Casa de Cultura",
    fullTitle: "1) Talleres impartidos en Casa de la Cultura",
    description:
      "Procesos formativos impartidos dentro de las instalaciones de la Casa de la Cultura. El total de participantes se suma en automático.",
    metricLabel: "Participantes",
    supportsContinuity: true,
    kind: "WORKSHOP_CC",
  },
  {
    id: "salones",
    axis: "EDUCACION_CONTINUA",
    num: "2",
    shortTitle: "2. Salones Culturales",
    fullTitle: "2) Salones Culturales (Oferta descentralizada fuera de Casa de Cultura)",
    description:
      "Talleres descentralizados en cabecera, comunidades o colonias. Si registras una nueva colonia o comunidad, se integra en automático a la cascada del municipio.",
    metricLabel: "Participantes",
    supportsContinuity: true,
    kind: "SALON_DESC",
  },
  {
    id: "verano",
    axis: "EDUCACION_CONTINUA",
    num: "3",
    shortTitle: "3. Talleres de Verano",
    fullTitle: "3) Talleres y Cursos de Verano",
    description:
      "Oferta formativa de periodo vacacional en Casa de la Cultura o sedes descentralizadas.",
    metricLabel: "Participantes",
    supportsContinuity: false,
    kind: "SUMMER",
  },
  {
    id: "capacitaciones",
    axis: "EDUCACION_CONTINUA",
    num: "4",
    shortTitle: "4. Capacitaciones",
    fullTitle: "4) Procesos de Formación (Capacitaciones)",
    description:
      "Cursos, talleres y capacitaciones dirigidos a promotores, instructores y agentes culturales municipales.",
    metricLabel: "Asistentes",
    supportsContinuity: false,
    kind: "TRAINING",
  },
  {
    id: "reuniones",
    axis: "MEDIACION_CULTURAL",
    num: "5",
    shortTitle: "5. Reuniones Colaboración",
    fullTitle: "5) Reuniones de Trabajo Colaborativo",
    description:
      "Mesas y reuniones con clasificación Municipal, Colaborativa o Estatal. Suma automática de asistentes.",
    metricLabel: "Asistentes",
    supportsContinuity: false,
    kind: "MEETING",
  },
  {
    id: "talento_local",
    axis: "MEDIACION_CULTURAL",
    num: "6",
    shortTitle: "6. Promoción Talento Local",
    fullTitle: "6) Promoción de Talento Local (antes Intercambios)",
    description:
      "Presentaciones de agrupaciones, artistas y exposiciones locales impulsadas fuera de la Casa de la Cultura.",
    metricLabel: "Asistentes",
    supportsContinuity: false,
    kind: "LOCAL_TALENT",
  },
  {
    id: "proyectos_colab",
    axis: "MEDIACION_CULTURAL",
    num: "7",
    shortTitle: "7. Proyectos Colaborativos",
    fullTitle: "7) Proyectos Colaborativos (Circuitos y Regionales)",
    description:
      "Actividades municipales vinculadas a proyectos de circuito o regionales dados de alta por la administración estatal.",
    metricLabel: "Asistentes",
    supportsContinuity: false,
    kind: "COLLAB_PROJECT",
  },
  {
    id: "eventos_mpales",
    axis: "MEDIACION_CULTURAL",
    num: "8",
    shortTitle: "8. Eventos Municipales",
    fullTitle: "8) Eventos y Actividades Culturales Municipales",
    description:
      "Programación artística, festivales, muestras y actividades comunitarias realizadas por el municipio.",
    metricLabel: "Asistentes",
    supportsContinuity: false,
    kind: "MUNICIPAL_EVENT",
  },
]);

const FALLBACK_MUNICIPALITIES = Object.freeze([
  { id: "demo-manual-doblado", nombre_oficial: "Manuel Doblado" },
  { id: "demo-leon", nombre_oficial: "León" },
  { id: "demo-guanajuato", nombre_oficial: "Guanajuato" },
  { id: "demo-irapuato", nombre_oficial: "Irapuato" },
  { id: "demo-celaya", nombre_oficial: "Celaya" },
  { id: "demo-salamanca", nombre_oficial: "Salamanca" },
  { id: "demo-san-miguel", nombre_oficial: "San Miguel de Allende" },
  { id: "demo-dolores", nombre_oficial: "Dolores Hidalgo C.I.N." },
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

function toNonNegativeInt(val) {
  const parsed = Number.parseInt(String(val ?? "").trim(), 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : 0;
}

function toMoneyNumber(val) {
  const parsed = Number.parseFloat(String(val ?? "").trim());
  return Number.isFinite(parsed) && parsed > 0 ? parsed : 0;
}

function createEmptyRow(sheetKind = "WORKSHOP_CC") {
  const demo = {};
  for (const key of DEMO_KEYS) {
    demo[key] = 0;
  }

  return {
    id: makeRowId(),
    // Campos comunes o especializados según hoja
    titulo: "", // Disciplina / Tema / Temática / Agrupación / Actividad / Evento
    subtitulo: "", // Evento (talento local) / Proyecto colaborativo / Ponente (capacitaciones)
    tipoReunionEvento:
      sheetKind === "MEETING"
        ? "COLABORATIVA"
        : sheetKind === "MUNICIPAL_EVENT"
          ? "PRESENTACION_ARTISTICA"
          : "",
    temporalidad: "SEMESTRAL",
    fechaInicio: "",
    fechaFin: "",
    fechaUnica: "",
    dias: { L: false, Ma: false, Mi: false, J: false, V: false, S: false, D: false },
    horario: "",
    modalidadCosto: "SIN_COSTO",
    montoCuota: "",
    docente: "",
    zonaTipo: sheetKind === "SALON_DESC" ? "COLONIA" : "CABECERA",
    asentamientoId: "",
    asentamientoNombre: "",
    sedeEspecifica: "",
    recursoEstatal: "",
    recursoMunicipal: "",
    ...demo,
  };
}

function computeRowTotals(row) {
  let mujeres = 0;
  let hombres = 0;
  for (const g of DEMO_GROUPS) {
    mujeres += toNonNegativeInt(row[`${g.key}_m`]);
    hombres += toNonNegativeInt(row[`${g.key}_h`]);
  }
  const primeraInfancia =
    toNonNegativeInt(row.pi_m) + toNonNegativeInt(row.pi_h);
  return {
    mujeres,
    hombres,
    total: mujeres + hombres,
    primeraInfancia,
  };
}

function isRowMeaningful(row) {
  if (!row) return false;
  if (String(row.titulo || "").trim() !== "") return true;
  if (String(row.docente || "").trim() !== "") return true;
  if (String(row.sedeEspecifica || "").trim() !== "") return true;
  return computeRowTotals(row).total > 0;
}

export async function initCaptureMatrix2026(context) {
  const shell = document.getElementById("captureMatrix2026Shell");
  const standardForm = document.getElementById("captureV2Form");
  const modeBtnMatrix = document.getElementById("modeBtnMatrix2026");
  const modeBtnIndividual = document.getElementById("modeBtnIndividual");

  if (!shell) return;

  const userId = context?.user?.id || "local";
  const identity = context ? getDisplayIdentity(context) : { name: "", email: "" };

  const state = {
    activeSheetId: "talleres_cc",
    year: "2026",
    month: "01",
    municipalityId: "",
    elabora: identity.name || "",
    municipalities: [],
    settlementsByMunicipality: new Map(), // id -> Array<{id, nombre, nombreConocido, tipo, origin}>
    sheetsData: {}, // sheetId -> Array<row>
    autosaveTimer: null,
  };

  // DOM refs inside shell
  const els = {
    selectMunicipality: document.getElementById("matrixMunicipality"),
    selectYear: document.getElementById("matrixYear"),
    selectMonth: document.getElementById("matrixMonth"),
    inputElabora: document.getElementById("matrixElabora"),
    btnUseIdentity: document.getElementById("matrixUseIdentityBtn"),
    btnManageSettlements: document.getElementById("matrixManageSettlementsBtn"),
    autosavePill: document.getElementById("matrixAutosavePill"),

    kpiTotalRows: document.getElementById("matrixKpiRows"),
    kpiTotalRowsSub: document.getElementById("matrixKpiRowsSub"),
    kpiTotalPeople: document.getElementById("matrixKpiPeople"),
    kpiTotalPeopleSub: document.getElementById("matrixKpiPeopleSub"),
    kpiPrimeraInfancia: document.getElementById("matrixKpiPrimera"),
    kpiPrimeraInfanciaSub: document.getElementById("matrixKpiPrimeraSub"),
    kpiTerritory: document.getElementById("matrixKpiTerritory"),
    kpiTerritorySub: document.getElementById("matrixKpiTerritorySub"),
    kpiPeak: document.getElementById("matrixKpiPeak"),
    kpiPeakSub: document.getElementById("matrixKpiPeakSub"),

    tabsEdu: document.getElementById("matrixTabsEdu"),
    tabsMed: document.getElementById("matrixTabsMed"),

    sheetTitle: document.getElementById("matrixActiveSheetTitle"),
    sheetDesc: document.getElementById("matrixActiveSheetDesc"),

    btnAddRow: document.getElementById("matrixAddRowBtn"),
    btnAdd5Rows: document.getElementById("matrixAdd5RowsBtn"),
    btnCopyPrevMonth: document.getElementById("matrixCopyPrevMonthBtn"),
    btnNewSettlement: document.getElementById("matrixNewSettlementBtn"),
    btnLoadSample: document.getElementById("matrixLoadSampleBtn"),
    btnExportXlsx: document.getElementById("matrixExportXlsxBtn"),
    btnClearSheet: document.getElementById("matrixClearSheetBtn"),

    tableHead: document.getElementById("matrixTableHead"),
    tableBody: document.getElementById("matrixTableBody"),
    tableFoot: document.getElementById("matrixTableFoot"),

    continuityPanel: document.getElementById("matrixContinuityPanel"),
    continuityChips: document.getElementById("matrixContinuityChips"),
    btnSaveMonthlyDraft: document.getElementById("matrixSaveMonthlyDraftBtn"),
  };

  // Switch entre Matriz Mensual 2026 y Captura Individual Estándar
  function setCaptureMode(mode) {
    const isMatrix = mode === "matrix";
    shell.hidden = !isMatrix;
    if (standardForm) {
      standardForm.hidden = isMatrix;
    }
    modeBtnMatrix?.classList.toggle("active", isMatrix);
    modeBtnMatrix?.setAttribute("aria-pressed", isMatrix ? "true" : "false");
    modeBtnIndividual?.classList.toggle("active", !isMatrix);
    modeBtnIndividual?.setAttribute("aria-pressed", !isMatrix ? "true" : "false");
  }

  modeBtnMatrix?.addEventListener("click", () => setCaptureMode("matrix"));
  modeBtnIndividual?.addEventListener("click", () => setCaptureMode("individual"));
  setCaptureMode("matrix");

  // Claves de almacenamiento local
  function getMonthStorageKey(municipalityId, year, month) {
    return `${STORAGE_PREFIX}:${userId}:${municipalityId || "sin_mpio"}:${year}-${month}`;
  }

  function getLocalSettlementsKey(municipalityId) {
    return `${SETTLEMENTS_PREFIX}:${municipalityId || "sin_mpio"}`;
  }

  function loadLocalSettlements(municipalityId) {
    try {
      const raw = localStorage.getItem(getLocalSettlementsKey(municipalityId));
      const parsed = raw ? JSON.parse(raw) : [];
      return Array.isArray(parsed) ? parsed : [];
    } catch {
      return [];
    }
  }

  function saveLocalSettlements(municipalityId, list) {
    try {
      localStorage.setItem(
        getLocalSettlementsKey(municipalityId),
        JSON.stringify(list)
      );
    } catch (err) {
      console.warn("No se pudo guardar catálogo local de asentamientos:", err);
    }
  }

  async function ensureSettlementsForMunicipality(municipalityId) {
    if (!municipalityId) return [];
    if (state.settlementsByMunicipality.has(municipalityId)) {
      return state.settlementsByMunicipality.get(municipalityId);
    }

    let remoteRows = [];
    if (!String(municipalityId).startsWith("demo-")) {
      try {
        remoteRows = await loadCommunities(municipalityId);
      } catch (err) {
        console.warn("Lectura de comunidades remota omitida o sin alcance:", err);
      }
    }

    const mappedRemote = remoteRows.map((c) => ({
      id: c.id,
      nombre: c.nombre,
      nombreConocido: "",
      tipo: String(c.nombre || "").toLowerCase().startsWith("col.") ||
        String(c.nombre || "").toLowerCase().includes("colonia")
        ? "COLONIA"
        : "COMUNIDAD",
      origin: "BD",
    }));

    const localSaved = loadLocalSettlements(municipalityId);
    const merged = [...mappedRemote];

    for (const item of localSaved) {
      const exists = merged.some(
        (m) =>
          m.nombre.trim().toLowerCase() ===
            String(item.nombre || "").trim().toLowerCase() &&
          m.tipo === item.tipo
      );
      if (!exists) {
        merged.push(item);
      }
    }

    // Semilla inicial de ejemplo si el municipio aún no tiene colonias/comunidades cargadas
    if (merged.length === 0) {
      merged.push(
        {
          id: "seed_col_soledad",
          nombre: "La Soledad",
          nombreConocido: "Colonia La Soledad",
          tipo: "COLONIA",
          origin: "LOCAL",
        },
        {
          id: "seed_col_centro_impulso",
          nombre: "Las Flores",
          nombreConocido: "Barrio de las Flores",
          tipo: "COLONIA",
          origin: "LOCAL",
        },
        {
          id: "seed_com_frias",
          nombre: "Frías",
          nombreConocido: "Ex-Hacienda de Frías",
          tipo: "COMUNIDAD",
          origin: "LOCAL",
        },
        {
          id: "seed_com_maravillas",
          nombre: "Maravillas",
          nombreConocido: "Comunidad Las Maravillas",
          tipo: "COMUNIDAD",
          origin: "LOCAL",
        }
      );
    }

    merged.sort((a, b) => a.nombre.localeCompare(b.nombre, "es"));
    state.settlementsByMunicipality.set(municipalityId, merged);
    return merged;
  }

  function ensureDefaultSheetsStructure(existing = {}) {
    const result = {};
    for (const sheet of SHEETS) {
      const rows = Array.isArray(existing[sheet.id]) ? existing[sheet.id] : [];
      result[sheet.id] =
        rows.length > 0
          ? rows
          : [createEmptyRow(sheet.kind), createEmptyRow(sheet.kind), createEmptyRow(sheet.kind)];
    }
    return result;
  }

  function loadMonthState() {
    try {
      const raw = localStorage.getItem(
        getMonthStorageKey(state.municipalityId, state.year, state.month)
      );
      if (!raw) {
        state.sheetsData = ensureDefaultSheetsStructure();
        setAutosaveStatus("Nuevo periodo listo para captura", "ready");
        return;
      }
      const parsed = JSON.parse(raw);
      if (parsed?.elabora && !state.elabora) {
        state.elabora = parsed.elabora;
        if (els.inputElabora) els.inputElabora.value = state.elabora;
      }
      state.sheetsData = ensureDefaultSheetsStructure(parsed?.sheetsData || {});
      setAutosaveStatus(
        `Borrador local recuperado (${parsed?.savedAt || "reciente"})`,
        "saved"
      );
    } catch (err) {
      console.warn("Error al leer borrador mensual local:", err);
      state.sheetsData = ensureDefaultSheetsStructure();
    }
  }

  function persistMonthStateNow() {
    const now = new Date();
    const hhmm = now.toLocaleTimeString("es-MX", {
      hour: "2-digit",
      minute: "2-digit",
    });
    const payload = {
      version: "2026.1",
      municipalityId: state.municipalityId,
      year: state.year,
      month: state.month,
      elabora: state.elabora,
      savedAt: hhmm,
      sheetsData: state.sheetsData,
    };
    try {
      localStorage.setItem(
        getMonthStorageKey(state.municipalityId, state.year, state.month),
        JSON.stringify(payload)
      );
      setAutosaveStatus(`Guardado automático · ${hhmm}`, "saved");
    } catch (err) {
      console.warn("No se pudo guardar borrador en localStorage:", err);
    }
  }

  function scheduleAutosave() {
    if (state.autosaveTimer) clearTimeout(state.autosaveTimer);
    state.autosaveTimer = setTimeout(() => {
      persistMonthStateNow();
    }, 320);
  }

  function setAutosaveStatus(text, kind = "ready") {
    if (!els.autosavePill) return;
    els.autosavePill.textContent = `● ${text}`;
    els.autosavePill.dataset.state = kind;
  }

  function getActiveSheet() {
    return SHEETS.find((s) => s.id === state.activeSheetId) || SHEETS[0];
  }

  function getMunicipalityName() {
    const found = state.municipalities.find((m) => m.id === state.municipalityId);
    return found ? found.nombre_oficial : "Municipio";
  }

  function getMonthObj(monthNum = state.month) {
    return MONTHS.find((m) => m.num === monthNum) || MONTHS[0];
  }

  // Renderizado de pestañas de los dos ejes (Educación Continua y Mediación Cultural)
  function renderSheetTabs() {
    const renderGroup = (container, axisKey) => {
      if (!container) return;
      container.replaceChildren();
      for (const sheet of SHEETS.filter((s) => s.axis === axisKey)) {
        const rows = state.sheetsData[sheet.id] || [];
        const activeCount = rows.filter(isRowMeaningful).length;
        const btn = document.createElement("button");
        btn.type = "button";
        btn.className = `matrix-sheet-tab${sheet.id === state.activeSheetId ? " active" : ""}`;
        btn.dataset.sheetId = sheet.id;

        const label = document.createElement("span");
        label.textContent = sheet.shortTitle;

        const badge = document.createElement("span");
        badge.className = "matrix-sheet-count";
        badge.dataset.sheetBadge = sheet.id;
        badge.textContent = String(activeCount);

        btn.append(label, badge);
        btn.addEventListener("click", () => {
          if (state.activeSheetId === sheet.id) return;
          state.activeSheetId = sheet.id;
          renderAll();
        });
        container.appendChild(btn);
      }
    };

    renderGroup(els.tabsEdu, "EDUCACION_CONTINUA");
    renderGroup(els.tabsMed, "MEDIACION_CULTURAL");
  }

  function updateTabBadgesCounts() {
    for (const sheet of SHEETS) {
      const badge = shell.querySelector(`[data-sheet-badge="${sheet.id}"]`);
      if (badge) {
        const rows = state.sheetsData[sheet.id] || [];
        badge.textContent = String(rows.filter(isRowMeaningful).length);
      }
    }
  }

  // Configuración dinámica de columnas operativas por hoja
  function getOperationalColumnsSpec(sheet) {
    switch (sheet.kind) {
      case "WORKSHOP_CC":
        return {
          mainLabel: "Disciplina / Saber impartido",
          mainPlaceholder: "Ej. Ballet infantil, Pintura, Guitarra...",
          hasTerritory: false,
          hasCollabProject: false,
          hasTalentEvent: false,
          hasPresenter: false,
          hasMeetingType: false,
          hasEventType: false,
          hasTemporality: true,
          hasPeriodRange: true,
          hasSingleDate: false,
          hasDays: true,
          hasSchedule: true,
          hasCost: true,
          hasTeacher: true,
          hasSede: false,
        };
      case "SALON_DESC":
        return {
          mainLabel: "Disciplina / Saber impartido",
          mainPlaceholder: "Ej. Danza folclórica, Cartonería, Coro...",
          hasTerritory: true,
          hasCollabProject: false,
          hasTalentEvent: false,
          hasPresenter: false,
          hasMeetingType: false,
          hasEventType: false,
          hasTemporality: true,
          hasPeriodRange: true,
          hasSingleDate: false,
          hasDays: true,
          hasSchedule: true,
          hasCost: true,
          hasTeacher: true,
          hasSede: true,
          sedeLabel: "Lugar específico",
          sedePlaceholder: "Ej. Primaria Juárez, Kiosco, Salón ejidal",
        };
      case "SUMMER":
        return {
          mainLabel: "Disciplina / Curso de verano",
          mainPlaceholder: "Ej. Cartonería, Teatro infantil, Barro...",
          hasTerritory: true,
          hasCollabProject: false,
          hasTalentEvent: false,
          hasPresenter: false,
          hasMeetingType: false,
          hasEventType: false,
          hasTemporality: false,
          hasPeriodRange: true,
          hasSingleDate: false,
          hasDays: true,
          hasSchedule: true,
          hasCost: true,
          hasTeacher: true,
          hasSede: true,
          sedeLabel: "Sede",
          sedePlaceholder: "Casa de Cultura o sede alterna",
        };
      case "TRAINING":
        return {
          mainLabel: "Tema de la capacitación",
          mainPlaceholder: "Ej. Derechos culturales, Gestión comunitaria",
          hasTerritory: true,
          hasCollabProject: false,
          hasTalentEvent: false,
          hasPresenter: true,
          hasMeetingType: false,
          hasEventType: false,
          hasTemporality: false,
          hasPeriodRange: false,
          hasSingleDate: true,
          hasDays: false,
          hasSchedule: false,
          hasCost: false,
          hasTeacher: false,
          hasSede: true,
          sedeLabel: "Sede",
          sedePlaceholder: "Auditorio Casa de Cultura / Virtual",
        };
      case "MEETING":
        return {
          mainLabel: "Temática de la reunión",
          mainPlaceholder: "Ej. Planeación trimestral OCM, Red regional",
          hasTerritory: false,
          hasCollabProject: false,
          hasTalentEvent: false,
          hasPresenter: false,
          hasMeetingType: true,
          hasEventType: false,
          hasTemporality: false,
          hasPeriodRange: false,
          hasSingleDate: true,
          hasDays: false,
          hasSchedule: false,
          hasCost: false,
          hasTeacher: false,
          hasSede: true,
          sedeLabel: "Sede",
          sedePlaceholder: "Ej. Casa de la Cultura / Sala Cabildo",
        };
      case "LOCAL_TALENT":
        return {
          mainLabel: "Agrupación / Artista / Actividad",
          mainPlaceholder: "Ej. Banda de Viento Juvenil, Colectivo Gráfica",
          hasTerritory: true,
          hasCollabProject: false,
          hasTalentEvent: true,
          hasPresenter: false,
          hasMeetingType: false,
          hasEventType: false,
          hasTemporality: false,
          hasPeriodRange: false,
          hasSingleDate: true,
          hasDays: false,
          hasSchedule: false,
          hasCost: false,
          hasTeacher: false,
          hasSede: true,
          sedeLabel: "Sede (fuera de Casa de Cultura)",
          sedePlaceholder: "Ej. Jardín Principal, Atrio, Plaza cívica",
        };
      case "COLLAB_PROJECT":
        return {
          mainLabel: "Actividad realizada en el municipio",
          mainPlaceholder: "Ej. Función inaugural, Taller de memoria oral",
          hasTerritory: true,
          hasCollabProject: true,
          hasTalentEvent: false,
          hasPresenter: false,
          hasMeetingType: false,
          hasEventType: false,
          hasTemporality: false,
          hasPeriodRange: false,
          hasSingleDate: true,
          hasDays: false,
          hasSchedule: false,
          hasCost: false,
          hasTeacher: false,
          hasSede: true,
          sedeLabel: "Sede",
          sedePlaceholder: "Espacio o plaza donde se realizó",
        };
      case "MUNICIPAL_EVENT":
      default:
        return {
          mainLabel: "Evento / Actividad municipal",
          mainPlaceholder: "Ej. Muestra de danza, Domingos culturales",
          hasTerritory: true,
          hasCollabProject: false,
          hasTalentEvent: false,
          hasPresenter: false,
          hasMeetingType: false,
          hasEventType: true,
          hasTemporality: false,
          hasPeriodRange: false,
          hasSingleDate: true,
          hasDays: false,
          hasSchedule: false,
          hasCost: false,
          hasTeacher: false,
          hasSede: true,
          sedeLabel: "Sede (lugar donde se llevó a cabo)",
          sedePlaceholder: "Ej. Explanada municipal, Teatro, Cancha",
        };
    }
  }

  function countOperationalCols(spec) {
    let count = 2; // # + columna principal
    if (spec.hasCollabProject) count += 1;
    if (spec.hasTalentEvent) count += 1;
    if (spec.hasPresenter) count += 1;
    if (spec.hasMeetingType) count += 1;
    if (spec.hasEventType) count += 1;
    if (spec.hasTerritory) count += 2; // Zona + Comunidad/Colonia en cascada
    if (spec.hasSede) count += 1;
    if (spec.hasTemporality) count += 1;
    if (spec.hasPeriodRange) count += 2;
    if (spec.hasSingleDate) count += 1;
    if (spec.hasDays) count += 1;
    if (spec.hasSchedule) count += 1;
    if (spec.hasCost) count += 1;
    if (spec.hasTeacher) count += 1;
    return count;
  }

  function renderTableHeader(sheet, spec) {
    const opColsCount = countOperationalCols(spec);
    const demoHeadersTop = DEMO_GROUPS.map(
      (g) => `
        <th colspan="2" class="${g.isNew ? "th-group-primera" : "th-group-demo"}">
          ${escapeHtml(g.label)}<br />
          <span style="font-weight:600;opacity:.92;font-size:.68rem">${escapeHtml(g.range)}${g.isNew ? " · NUEVO" : ""}</span>
        </th>
      `
    ).join("");

    const demoHeadersSub = DEMO_GROUPS.map(
      (g) => `
        <th class="${g.isNew ? "th-primera-sub" : ""}" title="${escapeHtml(g.label)} — Mujeres">M</th>
        <th class="${g.isNew ? "th-primera-sub" : ""}" title="${escapeHtml(g.label)} — Hombres">H</th>
      `
    ).join("");

    const extraColsSub = [];
    if (spec.hasCollabProject) extraColsSub.push("<th>Proyecto colaborativo (Catálogo)</th>");
    if (spec.hasTalentEvent) extraColsSub.push("<th>Evento / Marco</th>");
    if (spec.hasPresenter) extraColsSub.push("<th>Ponente / Facilitador</th>");
    if (spec.hasMeetingType) extraColsSub.push("<th>Tipo de reunión</th>");
    if (spec.hasEventType) extraColsSub.push("<th>Tipo de actividad</th>");
    if (spec.hasTerritory) {
      extraColsSub.push("<th>Zona (Tipo)</th>");
      extraColsSub.push("<th>Comunidad / Colonia (Cascada)</th>");
    }
    if (spec.hasSede) extraColsSub.push(`<th>${escapeHtml(spec.sedeLabel || "Sede")}</th>`);
    if (spec.hasTemporality) extraColsSub.push("<th>Temporalidad</th>");
    if (spec.hasPeriodRange) {
      extraColsSub.push("<th>Inicio</th>");
      extraColsSub.push("<th>Fin</th>");
    }
    if (spec.hasSingleDate) extraColsSub.push("<th>Fecha</th>");
    if (spec.hasDays) extraColsSub.push("<th>Días de sesión</th>");
    if (spec.hasSchedule) extraColsSub.push("<th>Horario</th>");
    if (spec.hasCost) extraColsSub.push("<th>Costo / Libre acceso</th>");
    if (spec.hasTeacher) extraColsSub.push("<th>Nombre del docente</th>");

    els.tableHead.innerHTML = `
      <tr>
        <th colspan="${opColsCount}">Datos Operativos · ${escapeHtml(getMonthObj().name)} ${escapeHtml(state.year)}</th>
        ${demoHeadersTop}
        <th rowspan="2" class="th-group-total sticky-col-total">
          Total ${escapeHtml(sheet.metricLabel)}<br />
          <span style="font-size:.67rem;font-weight:600;opacity:.9">(Suma auto)</span>
        </th>
        <th colspan="2">Recurso ($ MXN)</th>
        <th rowspan="2">Fila</th>
      </tr>
      <tr>
        <th class="sticky-col-num">#</th>
        <th class="sticky-col-main">${escapeHtml(spec.mainLabel)}</th>
        ${extraColsSub.join("")}
        ${demoHeadersSub}
        <th>Estatal</th>
        <th>Municipal</th>
      </tr>
    `;
  }

  function buildSettlementOptionsHtml(zonaTipo, selectedValue) {
    const list = state.settlementsByMunicipality.get(state.municipalityId) || [];
    if (zonaTipo === "CABECERA") {
      return `<option value="CABECERA">Cabecera municipal (${escapeHtml(getMunicipalityName())})</option>`;
    }

    const filtered = list.filter((item) => item.tipo === zonaTipo);
    const tipoTexto = zonaTipo === "COLONIA" ? "colonia" : "comunidad";

    const options = [
      `<option value="">Selecciona ${tipoTexto}...</option>`,
      ...filtered.map((item) => {
        const display = item.nombreConocido
          ? `${item.nombre} (${item.nombreConocido})`
          : item.nombre;
        const isSel =
          selectedValue === item.id || selectedValue === item.nombre
            ? " selected"
            : "";
        return `<option value="${escapeHtml(item.id)}"${isSel}>${escapeHtml(display)}</option>`;
      }),
      `<option value="__ADD_NEW__">➕ Registrar nueva ${tipoTexto} en cascada...</option>`,
    ];
    return options.join("");
  }

  function renderTableBody(sheet, spec) {
    const rows = state.sheetsData[sheet.id] || [];
    els.tableBody.replaceChildren();

    rows.forEach((row, idx) => {
      const tr = document.createElement("tr");
      tr.dataset.rowId = row.id;

      const totals = computeRowTotals(row);
      const cells = [];

      // 1. Número de fila
      cells.push(`<td class="cell-row-num sticky-col-num">${idx + 1}</td>`);

      // 2. Campo principal (con datalist en disciplinas)
      const listAttr =
        sheet.kind === "WORKSHOP_CC" ||
        sheet.kind === "SALON_DESC" ||
        sheet.kind === "SUMMER"
          ? ' list="matrixDisciplinesList"'
          : "";
      cells.push(`
        <td class="sticky-col-main">
          <input
            type="text"
            class="cell-input-main"
            data-field="titulo"
            value="${escapeHtml(row.titulo)}"
            placeholder="${escapeHtml(spec.mainPlaceholder)}"${listAttr}
          />
        </td>
      `);

      // Campos condicionales según la pestaña
      if (spec.hasCollabProject) {
        const projOpts = [
          `<option value="">Selecciona proyecto...</option>`,
          ...SAMPLE_COLLAB_PROJECTS.map(
            (p) =>
              `<option value="${escapeHtml(p)}"${row.subtitulo === p ? " selected" : ""}>${escapeHtml(p)}</option>`
          ),
        ].join("");
        cells.push(`
          <td>
            <select class="cell-input-medium" data-field="subtitulo" style="width:220px">
              ${projOpts}
            </select>
          </td>
        `);
      }

      if (spec.hasTalentEvent) {
        cells.push(`
          <td>
            <input
              type="text"
              class="cell-input-medium"
              data-field="subtitulo"
              value="${escapeHtml(row.subtitulo)}"
              placeholder="Ej. Feria patronal, Encuentro"
            />
          </td>
        `);
      }

      if (spec.hasPresenter) {
        cells.push(`
          <td>
            <input
              type="text"
              class="cell-input-medium"
              data-field="subtitulo"
              value="${escapeHtml(row.subtitulo)}"
              placeholder="Nombre del ponente"
            />
          </td>
        `);
      }

      if (spec.hasMeetingType) {
        const mTypes = [
          { val: "MUNICIPAL", label: "Municipal" },
          { val: "COLABORATIVA", label: "Colaborativa" },
          { val: "ESTATAL", label: "Estatal" },
        ];
        cells.push(`
          <td>
            <select class="cell-input-short" data-field="tipoReunionEvento">
              ${mTypes
                .map(
                  (t) =>
                    `<option value="${t.val}"${row.tipoReunionEvento === t.val ? " selected" : ""}>${t.label}</option>`
                )
                .join("")}
            </select>
          </td>
        `);
      }

      if (spec.hasEventType) {
        const eTypes = [
          { val: "PRESENTACION_ARTISTICA", label: "Presentación artística" },
          { val: "EXPOSICION", label: "Exposición / Muestra" },
          { val: "FESTIVAL", label: "Festival / Feria" },
          { val: "CONVERSATORIO", label: "Charla / Conversatorio" },
          { val: "COMUNITARIA", label: "Activación comunitaria" },
        ];
        cells.push(`
          <td>
            <select class="cell-input-medium" data-field="tipoReunionEvento">
              ${eTypes
                .map(
                  (t) =>
                    `<option value="${t.val}"${row.tipoReunionEvento === t.val ? " selected" : ""}>${t.label}</option>`
                )
                .join("")}
            </select>
          </td>
        `);
      }

      if (spec.hasTerritory) {
        const z = row.zonaTipo || "CABECERA";
        const isCabecera = z === "CABECERA";
        cells.push(`
          <td>
            <select class="select-zona-tipo" data-field="zonaTipo" data-zona="${escapeHtml(z)}">
              <option value="CABECERA"${z === "CABECERA" ? " selected" : ""}>Cabecera</option>
              <option value="COMUNIDAD"${z === "COMUNIDAD" ? " selected" : ""}>Comunidad</option>
              <option value="COLONIA"${z === "COLONIA" ? " selected" : ""}>Colonia</option>
            </select>
          </td>
          <td>
            <div class="territory-cell-stack">
              <select
                class="select-cascade-settlement"
                data-field="asentamientoId"
                ${isCabecera ? "disabled" : ""}
              >
                ${buildSettlementOptionsHtml(z, row.asentamientoId || row.asentamientoNombre)}
              </select>
              <button
                type="button"
                class="btn-quick-add-settlement"
                data-action="quick-add-settlement"
                title="Registrar nueva colonia o comunidad en la cascada del municipio"
              >+</button>
            </div>
          </td>
        `);
      }

      if (spec.hasSede) {
        cells.push(`
          <td>
            <input
              type="text"
              class="cell-input-medium"
              data-field="sedeEspecifica"
              value="${escapeHtml(row.sedeEspecifica)}"
              placeholder="${escapeHtml(spec.sedePlaceholder || "Sede")}"
            />
          </td>
        `);
      }

      if (spec.hasTemporality) {
        const temps = [
          { val: "ANUAL", label: "Anual" },
          { val: "SEMESTRAL", label: "Semestral" },
          { val: "TRIMESTRAL", label: "Trimestral" },
          { val: "MENSUAL", label: "Mensual" },
          { val: "TEMPORAL", label: "Temporal" },
        ];
        cells.push(`
          <td>
            <select class="cell-input-short" data-field="temporalidad">
              ${temps
                .map(
                  (t) =>
                    `<option value="${t.val}"${row.temporalidad === t.val ? " selected" : ""}>${t.label}</option>`
                )
                .join("")}
            </select>
          </td>
        `);
      }

      if (spec.hasPeriodRange) {
        cells.push(`
          <td>
            <input type="date" class="cell-input-date" data-field="fechaInicio" value="${escapeHtml(row.fechaInicio)}" />
          </td>
          <td>
            <input type="date" class="cell-input-date" data-field="fechaFin" value="${escapeHtml(row.fechaFin)}" />
          </td>
        `);
      }

      if (spec.hasSingleDate) {
        cells.push(`
          <td>
            <input type="date" class="cell-input-date" data-field="fechaUnica" value="${escapeHtml(row.fechaUnica)}" />
          </td>
        `);
      }

      if (spec.hasDays) {
        const pills = DAYS_OF_WEEK.map((d) => {
          const active = Boolean(row.dias?.[d.key]);
          return `<button type="button" class="day-pill${active ? " is-on" : ""}" data-day="${d.key}" title="${d.title}" aria-pressed="${active}">${d.label}</button>`;
        }).join("");
        cells.push(`<td><div class="days-pill-group">${pills}</div></td>`);
      }

      if (spec.hasSchedule) {
        cells.push(`
          <td>
            <input
              type="text"
              class="cell-input-short"
              data-field="horario"
              value="${escapeHtml(row.horario)}"
              placeholder="Ej. 4:00 a 6:00 pm"
            />
          </td>
        `);
      }

      if (spec.hasCost) {
        const isCuota = row.modalidadCosto === "CON_CUOTA";
        cells.push(`
          <td>
            <div class="fee-cell-inline">
              <select data-field="modalidadCosto">
                <option value="SIN_COSTO"${!isCuota ? " selected" : ""}>Sin costo</option>
                <option value="CON_CUOTA"${isCuota ? " selected" : ""}>Con cuota</option>
              </select>
              <input
                type="number"
                min="0"
                step="1"
                data-field="montoCuota"
                value="${escapeHtml(row.montoCuota)}"
                placeholder="$0"
                ${!isCuota ? "disabled" : ""}
              />
            </div>
          </td>
        `);
      }

      if (spec.hasTeacher) {
        cells.push(`
          <td>
            <input
              type="text"
              class="cell-input-medium"
              data-field="docente"
              value="${escapeHtml(row.docente)}"
              placeholder="Nombre del docente"
            />
          </td>
        `);
      }

      // 12 celdas demográficas (6 grupos etarios × M/H)
      for (const g of DEMO_GROUPS) {
        for (const sex of ["m", "h"]) {
          const field = `${g.key}_${sex}`;
          const numVal = toNonNegativeInt(row[field]);
          const classes = [
            "cell-input-demo",
            g.isNew ? "primera-cell" : "",
            numVal === 0 ? "zero-muted" : "",
          ]
            .filter(Boolean)
            .join(" ");
          cells.push(`
            <td>
              <input
                type="number"
                min="0"
                step="1"
                inputmode="numeric"
                class="${classes}"
                data-demo-field="${field}"
                value="${numVal === 0 ? "" : numVal}"
                placeholder="0"
              />
            </td>
          `);
        }
      }

      // Celda de Total Automático (bloqueada contra errores manuales)
      cells.push(`
        <td class="cell-auto-total sticky-col-total">
          <div class="auto-total-badge" data-row-total-box>
            <strong data-row-total-num>${totals.total}</strong>
            <small data-row-total-split>${totals.mujeres}M · ${totals.hombres}H</small>
          </div>
        </td>
      `);

      // Recurso Estatal / Municipal
      cells.push(`
        <td>
          <input
            type="number"
            min="0"
            step="0.01"
            class="cell-input-money"
            data-field="recursoEstatal"
            value="${escapeHtml(row.recursoEstatal)}"
            placeholder="0.00"
          />
        </td>
        <td>
          <input
            type="number"
            min="0"
            step="0.01"
            class="cell-input-money"
            data-field="recursoMunicipal"
            value="${escapeHtml(row.recursoMunicipal)}"
            placeholder="0.00"
          />
        </td>
      `);

      // Acciones de fila
      cells.push(`
        <td class="row-actions-cell">
          <button type="button" class="row-icon-btn" data-action="duplicate-row" title="Duplicar fila">⧉</button>
          <button type="button" class="row-icon-btn delete" data-action="delete-row" title="Eliminar fila">✕</button>
        </td>
      `);

      tr.innerHTML = cells.join("");
      els.tableBody.appendChild(tr);
    });
  }

  function renderTableFooter(sheet, spec) {
    const rows = state.sheetsData[sheet.id] || [];
    const opColsCount = countOperationalCols(spec);

    const colSums = {};
    for (const key of DEMO_KEYS) colSums[key] = 0;
    let grandTotal = 0;
    let sumEst = 0;
    let sumMun = 0;

    for (const row of rows) {
      for (const key of DEMO_KEYS) {
        const v = toNonNegativeInt(row[key]);
        colSums[key] += v;
        grandTotal += v;
      }
      sumEst += toMoneyNumber(row.recursoEstatal);
      sumMun += toMoneyNumber(row.recursoMunicipal);
    }

    const demoFootCells = DEMO_KEYS.map(
      (k) => `<td class="tfoot-demo-sum" data-foot-demo="${k}">${colSums[k]}</td>`
    ).join("");

    els.tableFoot.innerHTML = `
      <tr>
        <td colspan="${opColsCount}" style="text-align:right;padding-right:14px">
          Σ Totales de la hoja (${escapeHtml(sheet.shortTitle)}):
        </td>
        ${demoFootCells}
        <td class="tfoot-grand-total sticky-col-total" data-foot-grand-total>${grandTotal.toLocaleString("es-MX")}</td>
        <td class="tfoot-demo-sum" data-foot-est>$${sumEst.toLocaleString("es-MX", { minimumFractionDigits: 0, maximumFractionDigits: 2 })}</td>
        <td class="tfoot-demo-sum" data-foot-mun>$${sumMun.toLocaleString("es-MX", { minimumFractionDigits: 0, maximumFractionDigits: 2 })}</td>
        <td></td>
      </tr>
    `;
  }

  // Actualiza sumatorias en vivo sin destruir el foco del teclado en las celdas
  function refreshLiveTotalsInPlace() {
    const sheet = getActiveSheet();
    const rows = state.sheetsData[sheet.id] || [];

    const colSums = {};
    for (const key of DEMO_KEYS) colSums[key] = 0;
    let sheetGrandTotal = 0;
    let sumEst = 0;
    let sumMun = 0;

    for (const row of rows) {
      const t = computeRowTotals(row);
      const tr = els.tableBody.querySelector(`tr[data-row-id="${row.id}"]`);
      if (tr) {
        const numEl = tr.querySelector("[data-row-total-num]");
        const splitEl = tr.querySelector("[data-row-total-split]");
        if (numEl) numEl.textContent = t.total.toLocaleString("es-MX");
        if (splitEl) splitEl.textContent = `${t.mujeres}M · ${t.hombres}H`;
      }
      for (const key of DEMO_KEYS) {
        colSums[key] += toNonNegativeInt(row[key]);
      }
      sheetGrandTotal += t.total;
      sumEst += toMoneyNumber(row.recursoEstatal);
      sumMun += toMoneyNumber(row.recursoMunicipal);
    }

    for (const key of DEMO_KEYS) {
      const footCell = els.tableFoot.querySelector(`[data-foot-demo="${key}"]`);
      if (footCell) footCell.textContent = colSums[key].toLocaleString("es-MX");
    }
    const grandEl = els.tableFoot.querySelector("[data-foot-grand-total]");
    if (grandEl) grandEl.textContent = sheetGrandTotal.toLocaleString("es-MX");

    const estEl = els.tableFoot.querySelector("[data-foot-est]");
    if (estEl) {
      estEl.textContent = `$${sumEst.toLocaleString("es-MX", { minimumFractionDigits: 0, maximumFractionDigits: 2 })}`;
    }
    const munEl = els.tableFoot.querySelector("[data-foot-mun]");
    if (munEl) {
      munEl.textContent = `$${sumMun.toLocaleString("es-MX", { minimumFractionDigits: 0, maximumFractionDigits: 2 })}`;
    }

    updateTabBadgesCounts();
    refreshKpisAndContinuity();
  }

  // Calcula KPIs globales del mes (8 hojas) y el máximo por taller en el año
  function computeAnnualWorkshopPeaks() {
    const peaksMap = new Map(); // workshopKey -> { label, peak, monthsCount, history }

    for (const m of MONTHS) {
      let monthSheets = null;
      if (m.num === state.month) {
        monthSheets = state.sheetsData;
      } else {
        try {
          const raw = localStorage.getItem(
            getMonthStorageKey(state.municipalityId, state.year, m.num)
          );
          if (raw) {
            monthSheets = JSON.parse(raw)?.sheetsData || null;
          }
        } catch {
          monthSheets = null;
        }
      }
      if (!monthSheets) continue;

      for (const sheetId of ["talleres_cc", "salones"]) {
        const list = monthSheets[sheetId] || [];
        for (const r of list) {
          const title = String(r.titulo || "").trim();
          if (!title) continue;
          const total = computeRowTotals(r).total;
          const place =
            sheetId === "salones"
              ? String(r.sedeEspecifica || r.zonaTipo || "Salón").trim()
              : "Casa de Cultura";
          const key = `${sheetId}::${title.toLowerCase()}::${place.toLowerCase()}`;
          const prev = peaksMap.get(key) || {
            label: `${title} (${place})`,
            peak: 0,
            monthsCount: 0,
            history: [],
          };
          prev.monthsCount += 1;
          if (total > prev.peak) prev.peak = total;
          prev.history.push(`${m.short}: ${total}`);
          peaksMap.set(key, prev);
        }
      }
    }

    return [...peaksMap.values()];
  }

  function refreshKpisAndContinuity() {
    let monthActiveRows = 0;
    let monthMujeres = 0;
    let monthHombres = 0;
    let monthPrimera = 0;
    const coloniasUsed = new Set();
    const comunidadesUsed = new Set();
    let cabeceraCount = 0;

    for (const sheet of SHEETS) {
      const rows = state.sheetsData[sheet.id] || [];
      for (const row of rows) {
        if (!isRowMeaningful(row)) continue;
        monthActiveRows += 1;
        const t = computeRowTotals(row);
        monthMujeres += t.mujeres;
        monthHombres += t.hombres;
        monthPrimera += t.primeraInfancia;

        if (sheet.id === "talleres_cc" || row.zonaTipo === "CABECERA") {
          cabeceraCount += 1;
        } else if (row.zonaTipo === "COLONIA") {
          coloniasUsed.add(row.asentamientoId || row.sedeEspecifica || row.id);
        } else if (row.zonaTipo === "COMUNIDAD") {
          comunidadesUsed.add(row.asentamientoId || row.sedeEspecifica || row.id);
        }
      }
    }

    const activeSheet = getActiveSheet();
    const activeRowsCount = (state.sheetsData[activeSheet.id] || []).filter(
      isRowMeaningful
    ).length;

    if (els.kpiTotalRows) {
      els.kpiTotalRows.textContent = monthActiveRows.toLocaleString("es-MX");
    }
    if (els.kpiTotalRowsSub) {
      els.kpiTotalRowsSub.textContent = `${activeRowsCount} en hoja actual · ${getMonthObj().name}`;
    }

    const totalMes = monthMujeres + monthHombres;
    if (els.kpiTotalPeople) {
      els.kpiTotalPeople.textContent = totalMes.toLocaleString("es-MX");
    }
    if (els.kpiTotalPeopleSub) {
      els.kpiTotalPeopleSub.textContent = `${monthMujeres.toLocaleString("es-MX")} mujeres · ${monthHombres.toLocaleString("es-MX")} hombres`;
    }

    if (els.kpiPrimeraInfancia) {
      els.kpiPrimeraInfancia.textContent = monthPrimera.toLocaleString("es-MX");
    }
    if (els.kpiPrimeraInfanciaSub) {
      const pct = totalMes > 0 ? Math.round((monthPrimera / totalMes) * 100) : 0;
      els.kpiPrimeraInfanciaSub.textContent = `0 a 5 años (${pct}% del mes)`;
    }

    if (els.kpiTerritory) {
      els.kpiTerritory.textContent = `${comunidadesUsed.size + coloniasUsed.size} sedes desc.`;
    }
    if (els.kpiTerritorySub) {
      els.kpiTerritorySub.textContent = `${cabeceraCount} cabecera · ${comunidadesUsed.size} comun. · ${coloniasUsed.size} col.`;
    }

    const peaks = computeAnnualWorkshopPeaks();
    const sumPeaks = peaks.reduce((acc, item) => acc + item.peak, 0);
    if (els.kpiPeak) {
      els.kpiPeak.textContent = sumPeaks.toLocaleString("es-MX");
    }
    if (els.kpiPeakSub) {
      els.kpiPeakSub.textContent = `${peaks.length} taller(es) únicos en ${state.year}`;
    }

    // Panel inferior de continuidad para hojas 1 y 2
    if (els.continuityPanel && els.continuityChips) {
      els.continuityPanel.hidden = !activeSheet.supportsContinuity;
      if (activeSheet.supportsContinuity) {
        els.continuityChips.replaceChildren();
        if (peaks.length === 0) {
          const empty = document.createElement("span");
          empty.style.fontSize = "0.82rem";
          empty.style.color = "#64748b";
          empty.textContent =
            "Al capturar disciplinas en uno o varios meses, el sistema identifica aquí el máximo de alumnos alcanzado por cada taller sin duplicar metas.";
          els.continuityChips.appendChild(empty);
        } else {
          peaks.slice(0, 10).forEach((item) => {
            const chip = document.createElement("span");
            chip.className = "continuity-chip";
            chip.title = `Historial mensual: ${item.history.join(" | ")}`;
            const nameSpan = document.createElement("span");
            nameSpan.textContent = item.label;
            const maxBadge = document.createElement("b");
            maxBadge.textContent = `Máx: ${item.peak} (${item.monthsCount} mes${item.monthsCount === 1 ? "" : "es"})`;
            chip.append(nameSpan, maxBadge);
            els.continuityChips.appendChild(chip);
          });
        }
      }
    }
  }

  function renderActiveSheet() {
    const sheet = getActiveSheet();
    const spec = getOperationalColumnsSpec(sheet);

    if (els.sheetTitle) els.sheetTitle.textContent = sheet.fullTitle;
    if (els.sheetDesc) els.sheetDesc.textContent = sheet.description;
    if (els.btnCopyPrevMonth) {
      els.btnCopyPrevMonth.hidden = !sheet.supportsContinuity;
    }

    renderTableHeader(sheet, spec);
    renderTableBody(sheet, spec);
    renderTableFooter(sheet, spec);
    refreshKpisAndContinuity();
  }

  function renderAll() {
    renderSheetTabs();
    renderActiveSheet();
  }

  // Alta rápida de Comunidad / Colonia en la cascada municipal
  async function promptAddSettlement(defaultTipo = "COLONIA", targetRowId = null) {
    const mpioName = getMunicipalityName();
    if (!window.Swal) return;

    const { value: formValues } = await window.Swal.fire({
      title: `Registrar en cascada · ${mpioName}`,
      html: `
        <div style="text-align:left;display:grid;gap:12px;margin-top:6px">
          <div>
            <label style="display:block;font-weight:700;font-size:.85rem;margin-bottom:4px">Tipo de asentamiento</label>
            <select id="swalSettlementType" class="swal2-input" style="margin:0;width:100%;height:42px;font-size:.92rem">
              <option value="COLONIA"${defaultTipo === "COLONIA" ? " selected" : ""}>Colonia (zona urbana / periferia)</option>
              <option value="COMUNIDAD"${defaultTipo === "COMUNIDAD" ? " selected" : ""}>Comunidad / Localidad rural</option>
            </select>
          </div>
          <div>
            <label style="display:block;font-weight:700;font-size:.85rem;margin-bottom:4px">Nombre oficial de la colonia o comunidad *</label>
            <input id="swalSettlementName" class="swal2-input" style="margin:0;width:100%;height:42px;font-size:.92rem" placeholder="Ej. La Soledad, San José del Agua..." />
          </div>
          <div>
            <label style="display:block;font-weight:700;font-size:.85rem;margin-bottom:4px">Nombre conocido / tradicional (opcional)</label>
            <input id="swalSettlementKnown" class="swal2-input" style="margin:0;width:100%;height:42px;font-size:.92rem" placeholder="Ej. Barrio Alto, Ex-Hacienda..." />
          </div>
        </div>
      `,
      focusConfirm: false,
      showCancelButton: true,
      confirmButtonText: "Guardar y añadir a la cascada",
      cancelButtonText: "Cancelar",
      preConfirm: () => {
        const tipo = document.getElementById("swalSettlementType")?.value || "COLONIA";
        const nombre = document.getElementById("swalSettlementName")?.value?.trim() || "";
        const nombreConocido = document.getElementById("swalSettlementKnown")?.value?.trim() || "";
        if (nombre.length < 2) {
          window.Swal.showValidationMessage("Escribe el nombre de la colonia o comunidad.");
          return false;
        }
        return { tipo, nombre, nombreConocido };
      },
    });

    if (!formValues) {
      if (targetRowId) renderActiveSheet();
      return;
    }

    const list = await ensureSettlementsForMunicipality(state.municipalityId);
    const existing = list.find(
      (item) =>
        item.tipo === formValues.tipo &&
        item.nombre.toLowerCase() === formValues.nombre.toLowerCase()
    );

    let chosen = existing;
    if (!chosen) {
      chosen = {
        id: `local_${Date.now().toString(36)}`,
        nombre: formValues.nombre,
        nombreConocido: formValues.nombreConocido,
        tipo: formValues.tipo,
        origin: "NUEVO_CASCADA",
      };
      list.push(chosen);
      list.sort((a, b) => a.nombre.localeCompare(b.nombre, "es"));
      state.settlementsByMunicipality.set(state.municipalityId, list);
      saveLocalSettlements(
        state.municipalityId,
        list.filter((i) => i.origin !== "BD")
      );
    }

    if (targetRowId) {
      const rows = state.sheetsData[state.activeSheetId] || [];
      const row = rows.find((r) => r.id === targetRowId);
      if (row) {
        row.zonaTipo = chosen.tipo;
        row.asentamientoId = chosen.id;
        row.asentamientoNombre = chosen.nombre;
        scheduleAutosave();
      }
    }

    renderActiveSheet();
  }

  // Modal de consulta del padrón de comunidades y colonias del municipio
  async function openSettlementsPadronModal() {
    if (!window.Swal) return;
    const list = await ensureSettlementsForMunicipality(state.municipalityId);
    const colonias = list.filter((i) => i.tipo === "COLONIA");
    const comunidades = list.filter((i) => i.tipo === "COMUNIDAD");

    const renderList = (items, emptyMsg) =>
      items.length === 0
        ? `<p style="margin:4px 0;color:#64748b;font-size:.84rem">${emptyMsg}</p>`
        : `<ul style="margin:6px 0;padding-left:18px;font-size:.85rem;max-height:140px;overflow:auto">
            ${items
              .map(
                (i) =>
                  `<li><b>${escapeHtml(i.nombre)}</b>${
                    i.nombreConocido
                      ? ` · <span style="color:#475569">Conocida como: ${escapeHtml(i.nombreConocido)}</span>`
                      : ""
                  }</li>`
              )
              .join("")}
          </ul>`;

    const res = await window.Swal.fire({
      title: `Padrón Territorial · ${getMunicipalityName()}`,
      html: `
        <div style="text-align:left;display:grid;gap:12px">
          <div style="padding:10px 12px;border-radius:10px;background:#eff6ff;border:1px solid #bfdbfe;font-size:.84rem">
            <b>1. Cabecera municipal:</b> ${escapeHtml(getMunicipalityName())} (siempre disponible)
          </div>
          <div style="padding:10px 12px;border-radius:10px;background:#fffbeb;border:1px solid #fde68a">
            <b style="font-size:.86rem">2. Comunidades registradas (${comunidades.length}):</b>
            ${renderList(comunidades, "Sin comunidades registradas aún.")}
          </div>
          <div style="padding:10px 12px;border-radius:10px;background:#ecfdf5;border:1px solid #a7f3d0">
            <b style="font-size:.86rem">3. Colonias en cascada (${colonias.length}):</b>
            ${renderList(colonias, "Sin colonias registradas aún.")}
          </div>
        </div>
      `,
      showCancelButton: true,
      confirmButtonText: "+ Agregar colonia o comunidad",
      cancelButtonText: "Cerrar",
    });

    if (res.isConfirmed) {
      await promptAddSettlement("COLONIA", null);
    }
  }

  // Delegación de eventos sobre la tabla tipo Excel
  els.tableBody.addEventListener("input", (event) => {
    const target = event.target;
    const tr = target.closest("tr[data-row-id]");
    if (!tr) return;

    const rows = state.sheetsData[state.activeSheetId] || [];
    const row = rows.find((r) => r.id === tr.dataset.rowId);
    if (!row) return;

    if (target.dataset.demoField) {
      const key = target.dataset.demoField;
      const val = toNonNegativeInt(target.value);
      row[key] = val;
      target.classList.toggle("zero-muted", val === 0);
      refreshLiveTotalsInPlace();
      scheduleAutosave();
      return;
    }

    const field = target.dataset.field;
    if (!field) return;

    row[field] = target.value;
    if (field === "recursoEstatal" || field === "recursoMunicipal" || field === "titulo") {
      refreshLiveTotalsInPlace();
    }
    scheduleAutosave();
  });

  els.tableBody.addEventListener("change", async (event) => {
    const target = event.target;
    const tr = target.closest("tr[data-row-id]");
    if (!tr) return;

    const rows = state.sheetsData[state.activeSheetId] || [];
    const row = rows.find((r) => r.id === tr.dataset.rowId);
    if (!row) return;

    const field = target.dataset.field;

    if (field === "zonaTipo") {
      row.zonaTipo = target.value;
      row.asentamientoId = "";
      row.asentamientoNombre = "";
      scheduleAutosave();
      renderActiveSheet();
      return;
    }

    if (field === "asentamientoId") {
      if (target.value === "__ADD_NEW__") {
        await promptAddSettlement(row.zonaTipo || "COLONIA", row.id);
        return;
      }
      row.asentamientoId = target.value;
      const list = state.settlementsByMunicipality.get(state.municipalityId) || [];
      const found = list.find((i) => i.id === target.value);
      row.asentamientoNombre = found ? found.nombre : "";
      scheduleAutosave();
      refreshKpisAndContinuity();
      return;
    }

    if (field === "modalidadCosto") {
      row.modalidadCosto = target.value;
      if (row.modalidadCosto !== "CON_CUOTA") {
        row.montoCuota = "";
      }
      scheduleAutosave();
      renderActiveSheet();
      return;
    }

    if (field) {
      row[field] = target.value;
      scheduleAutosave();
      refreshKpisAndContinuity();
    }
  });

  els.tableBody.addEventListener("click", async (event) => {
    const dayBtn = event.target.closest("button[data-day]");
    if (dayBtn) {
      const tr = dayBtn.closest("tr[data-row-id]");
      const rows = state.sheetsData[state.activeSheetId] || [];
      const row = rows.find((r) => r.id === tr?.dataset.rowId);
      if (!row) return;
      const dayKey = dayBtn.dataset.day;
      row.dias[dayKey] = !row.dias[dayKey];
      dayBtn.classList.toggle("is-on", row.dias[dayKey]);
      dayBtn.setAttribute("aria-pressed", String(row.dias[dayKey]));
      scheduleAutosave();
      return;
    }

    const actionBtn = event.target.closest("button[data-action]");
    if (!actionBtn) return;
    const tr = actionBtn.closest("tr[data-row-id]");
    const rows = state.sheetsData[state.activeSheetId] || [];
    const idx = rows.findIndex((r) => r.id === tr?.dataset.rowId);
    if (idx === -1) return;

    const action = actionBtn.dataset.action;
    if (action === "quick-add-settlement") {
      const row = rows[idx];
      const defaultTipo = row.zonaTipo === "COMUNIDAD" ? "COMUNIDAD" : "COLONIA";
      await promptAddSettlement(defaultTipo, row.id);
      return;
    }

    if (action === "duplicate-row") {
      const source = rows[idx];
      const clone = JSON.parse(JSON.stringify(source));
      clone.id = makeRowId();
      rows.splice(idx + 1, 0, clone);
      scheduleAutosave();
      renderActiveSheet();
      return;
    }

    if (action === "delete-row") {
      if (rows.length <= 1) {
        state.sheetsData[state.activeSheetId] = [createEmptyRow(getActiveSheet().kind)];
      } else {
        rows.splice(idx, 1);
      }
      scheduleAutosave();
      renderActiveSheet();
    }
  });

  // Navegación vertical con Enter / Flechas en celdas numéricas como en Excel
  els.tableBody.addEventListener("keydown", (event) => {
    const target = event.target;
    if (!target.dataset?.demoField) return;
    if (!["Enter", "ArrowDown", "ArrowUp"].includes(event.key)) return;

    event.preventDefault();
    const field = target.dataset.demoField;
    const allSameCol = [
      ...els.tableBody.querySelectorAll(`input[data-demo-field="${field}"]`),
    ];
    const pos = allSameCol.indexOf(target);
    if (pos === -1) return;
    const delta = event.key === "ArrowUp" ? -1 : 1;
    const next = allSameCol[pos + delta];
    if (next) {
      next.focus();
      next.select();
    }
  });

  // Botones de barra de herramientas
  els.btnAddRow?.addEventListener("click", () => {
    const sheet = getActiveSheet();
    state.sheetsData[sheet.id].push(createEmptyRow(sheet.kind));
    scheduleAutosave();
    renderActiveSheet();
  });

  els.btnAdd5Rows?.addEventListener("click", () => {
    const sheet = getActiveSheet();
    for (let i = 0; i < 5; i += 1) {
      state.sheetsData[sheet.id].push(createEmptyRow(sheet.kind));
    }
    scheduleAutosave();
    renderActiveSheet();
  });

  els.btnNewSettlement?.addEventListener("click", () => {
    promptAddSettlement("COLONIA", null);
  });

  els.btnManageSettlements?.addEventListener("click", () => {
    openSettlementsPadronModal();
  });

  els.btnUseIdentity?.addEventListener("click", () => {
    if (identity.name) {
      state.elabora = identity.name;
      if (els.inputElabora) els.inputElabora.value = state.elabora;
      scheduleAutosave();
    }
  });

  els.inputElabora?.addEventListener("input", () => {
    state.elabora = els.inputElabora.value;
    scheduleAutosave();
  });

  // Copiar talleres del mes inmediato anterior (continuidad mensual sin volver a teclear)
  els.btnCopyPrevMonth?.addEventListener("click", async () => {
    const currIdx = MONTHS.findIndex((m) => m.num === state.month);
    if (currIdx <= 0) {
      window.Swal?.fire(
        "Primer mes del año",
        "Selecciona un mes de Febrero a Diciembre para traer los talleres activos del mes anterior.",
        "info"
      );
      return;
    }

    const prevMonth = MONTHS[currIdx - 1];
    const rawPrev = localStorage.getItem(
      getMonthStorageKey(state.municipalityId, state.year, prevMonth.num)
    );
    if (!rawPrev) {
      window.Swal?.fire(
        `Sin datos en ${prevMonth.name}`,
        `Aún no hay talleres guardados en ${prevMonth.name} ${state.year} para este municipio.`,
        "info"
      );
      return;
    }

    const prevData = JSON.parse(rawPrev)?.sheetsData?.[state.activeSheetId] || [];
    const validPrev = prevData.filter((r) => String(r.titulo || "").trim() !== "");
    if (validPrev.length === 0) {
      window.Swal?.fire(
        "Hoja anterior vacía",
        `No se encontraron talleres registrados en ${prevMonth.name} dentro de esta pestaña.`,
        "info"
      );
      return;
    }

    const copied = validPrev.map((r) => {
      const next = JSON.parse(JSON.stringify(r));
      next.id = makeRowId();
      for (const k of DEMO_KEYS) next[k] = 0;
      return next;
    });

    const currentMeaningful = (state.sheetsData[state.activeSheetId] || []).filter(
      isRowMeaningful
    );
    state.sheetsData[state.activeSheetId] = [...currentMeaningful, ...copied];
    persistMonthStateNow();
    renderActiveSheet();

    window.Swal?.fire({
      icon: "success",
      title: `Talleres traídos de ${prevMonth.name}`,
      text: `Se precargaron ${copied.length} taller(es) conservando horarios, sede y docente. Solo captura la asistencia correspondiente a ${getMonthObj().name}.`,
      timer: 3200,
    });
  });

  // Cargar datos de ejemplo basados exactamente en MACHOTE 2026 / Proyecto para Luis
  els.btnLoadSample?.addEventListener("click", async () => {
    const list = await ensureSettlementsForMunicipality(state.municipalityId);
    const colSoledad = list.find((i) => i.tipo === "COLONIA")?.id || "";
    const comFrias = list.find((i) => i.tipo === "COMUNIDAD")?.id || "";

    const r1 = {
      ...createEmptyRow("WORKSHOP_CC"),
      titulo: "Ballet (infantil)",
      temporalidad: "SEMESTRAL",
      fechaInicio: "2026-01-12",
      fechaFin: "2026-06-30",
      dias: { L: true, Ma: false, Mi: true, J: false, V: true, S: false, D: false },
      horario: "3:00 a 5:00 pm",
      modalidadCosto: "CON_CUOTA",
      montoCuota: "80",
      docente: "Mariana Domínguez",
      pi_m: 6,
      pi_h: 2,
      inf_m: 12,
      inf_h: 3,
      recursoMunicipal: "4500",
    };

    const r2 = {
      ...createEmptyRow("WORKSHOP_CC"),
      titulo: "Guitarra popular y canto",
      temporalidad: "ANUAL",
      fechaInicio: "2026-01-15",
      fechaFin: "2026-11-30",
      dias: { L: false, Ma: true, Mi: false, J: true, V: false, S: false, D: false },
      horario: "5:00 a 7:00 pm",
      modalidadCosto: "SIN_COSTO",
      docente: "Jorge Luis Rincón",
      ado_m: 7,
      ado_h: 9,
      jov_m: 5,
      jov_h: 6,
      adu_m: 3,
      adu_h: 2,
      recursoMunicipal: "5200",
    };

    const s1 = {
      ...createEmptyRow("SALON_DESC"),
      titulo: "Danza folclórica comunitaria",
      zonaTipo: "COLONIA",
      asentamientoId: colSoledad,
      asentamientoNombre: "La Soledad",
      sedeEspecifica: " Cancha techada Col. La Soledad".trim(),
      temporalidad: "ANUAL",
      fechaInicio: "2026-01-13",
      fechaFin: "2026-11-28",
      dias: { L: false, Ma: true, Mi: false, J: true, V: true, S: false, D: false },
      horario: "4:00 a 6:30 pm",
      modalidadCosto: "SIN_COSTO",
      docente: "Rocío Hernández",
      pi_m: 4,
      pi_h: 3,
      inf_m: 11,
      inf_h: 8,
      ado_m: 6,
      ado_h: 4,
      recursoEstatal: "3000",
      recursoMunicipal: "2000",
    };

    const s2 = {
      ...createEmptyRow("SALON_DESC"),
      titulo: "Taller de cartonería tradicional",
      zonaTipo: "COMUNIDAD",
      asentamientoId: comFrias,
      asentamientoNombre: "Frías",
      sedeEspecifica: "Telesecundaria de Frías",
      temporalidad: "SEMESTRAL",
      fechaInicio: "2026-01-20",
      fechaFin: "2026-06-25",
      dias: { L: true, Ma: false, Mi: true, J: false, V: false, S: false, D: false },
      horario: "12:00 a 2:00 pm",
      modalidadCosto: "SIN_COSTO",
      docente: "Fernando Tapia",
      inf_m: 9,
      inf_h: 10,
      ado_m: 8,
      ado_h: 7,
      recursoEstatal: "3800",
    };

    const cap1 = {
      ...createEmptyRow("TRAINING"),
      titulo: "Mediación y derechos culturales en el ámbito local",
      subtitulo: "Mtra. Elena Villaseñor",
      zonaTipo: "CABECERA",
      sedeEspecifica: "Sala Audiovisual Casa de la Cultura",
      fechaUnica: `2026-${state.month}-18`,
      jov_m: 6,
      jov_h: 4,
      adu_m: 11,
      adu_h: 7,
      may_m: 2,
      may_h: 1,
    };

    const reu1 = {
      ...createEmptyRow("MEETING"),
      titulo: "Mesa de planeación colaborativa OCM — Región",
      sedeEspecifica: "Casa de la Cultura",
      tipoReunionEvento: "COLABORATIVA",
      fechaUnica: `2026-${state.month}-10`,
      jov_m: 2,
      jov_h: 1,
      adu_m: 8,
      adu_h: 6,
      may_m: 1,
    };

    const tal1 = {
      ...createEmptyRow("LOCAL_TALENT"),
      titulo: "Ensamble Juvenil de Cuerdas y Coro Infantil",
      subtitulo: "Domingos de Plaza y Tradición",
      zonaTipo: "COLONIA",
      asentamientoId: colSoledad,
      sedeEspecifica: "Plaza Principal de la Colonia",
      fechaUnica: `2026-${state.month}-24`,
      pi_m: 9,
      pi_h: 8,
      inf_m: 22,
      inf_h: 18,
      ado_m: 15,
      ado_h: 14,
      jov_m: 19,
      jov_h: 16,
      adu_m: 34,
      adu_h: 28,
      may_m: 12,
      may_h: 10,
      recursoMunicipal: "6500",
    };

    const proy1 = {
      ...createEmptyRow("COLLAB_PROJECT"),
      titulo: "Presentación itinerante de títeres y memoria comunitaria",
      subtitulo: SAMPLE_COLLAB_PROJECTS[0],
      zonaTipo: "COMUNIDAD",
      asentamientoId: comFrias,
      sedeEspecifica: "Explanada comunitaria",
      fechaUnica: `2026-${state.month}-27`,
      pi_m: 14,
      pi_h: 11,
      inf_m: 28,
      inf_h: 25,
      adu_m: 20,
      adu_h: 15,
      may_m: 7,
      may_h: 6,
      recursoEstatal: "8000",
      recursoMunicipal: "3500",
    };

    state.sheetsData.talleres_cc = [r1, r2, createEmptyRow("WORKSHOP_CC")];
    state.sheetsData.salones = [s1, s2, createEmptyRow("SALON_DESC")];
    state.sheetsData.capacitaciones = [cap1, createEmptyRow("TRAINING")];
    state.sheetsData.reuniones = [reu1, createEmptyRow("MEETING")];
    state.sheetsData.talento_local = [tal1, createEmptyRow("LOCAL_TALENT")];
    state.sheetsData.proyectos_colab = [proy1, createEmptyRow("COLLAB_PROJECT")];

    persistMonthStateNow();
    renderAll();

    window.Swal?.fire({
      icon: "success",
      title: "Ejemplo PEC 2026 cargado",
      text: "Revisa las pestañas de Educación Continua y Mediación Cultural para probar la suma automática, primera infancia y cascada de colonias.",
      timer: 3000,
    });
  });

  els.btnClearSheet?.addEventListener("click", async () => {
    const sheet = getActiveSheet();
    const res = await window.Swal?.fire({
      icon: "warning",
      title: `¿Vaciar ${sheet.shortTitle}?`,
      text: "Se limpiarán las filas de la pestaña actual en este mes.",
      showCancelButton: true,
      confirmButtonText: "Sí, limpiar pestaña",
      cancelButtonText: "Cancelar",
    });
    if (!res?.isConfirmed) return;
    state.sheetsData[sheet.id] = [
      createEmptyRow(sheet.kind),
      createEmptyRow(sheet.kind),
      createEmptyRow(sheet.kind),
    ];
    persistMonthStateNow();
    renderAll();
  });

  // Exportar las 8 hojas del mes a un archivo Excel (.xlsx) usando SheetJS local
  els.btnExportXlsx?.addEventListener("click", () => {
    if (!window.XLSX) {
      window.Swal?.fire("SheetJS no disponible", "No se encontró la librería de exportación XLSX.", "error");
      return;
    }

    const wb = window.XLSX.utils.book_new();
    const mpio = getMunicipalityName();
    const monthObj = getMonthObj();

    for (const sheet of SHEETS) {
      const rows = (state.sheetsData[sheet.id] || []).filter(isRowMeaningful);
      const header = [
        "No.",
        "Actividad / Disciplina / Tema",
        "Detalle / Proyecto / Evento",
        "Tipo",
        "Zona",
        "Comunidad / Colonia",
        "Sede",
        "Temporalidad",
        "Inicio",
        "Fin",
        "Fecha única",
        "Días",
        "Horario",
        "Modalidad costo",
        "Cuota MXN",
        "Docente",
        "Primera infancia M (0-5)",
        "Primera infancia H (0-5)",
        "Infancias M (6-12)",
        "Infancias H (6-12)",
        "Adolescentes M (13-17)",
        "Adolescentes H (13-17)",
        "Jóvenes M (18-29)",
        "Jóvenes H (18-29)",
        "Adultos M (30-59)",
        "Adultos H (30-59)",
        "Adultos mayores M (60+)",
        "Adultos mayores H (60+)",
        `Total ${sheet.metricLabel} (Auto)`,
        "Recurso Estatal",
        "Recurso Municipal",
      ];

      const aoa = [
        ["SECRETARÍA DE CULTURA DE GUANAJUATO — CASAS DE LA CULTURA (PEC 2026)"],
        [`Municipio: ${mpio}`, `Mes: ${monthObj.name} ${state.year}`, `Elabora: ${state.elabora || "—"}`],
        [sheet.fullTitle],
        [],
        header,
      ];

      rows.forEach((r, i) => {
        const activeDays = DAYS_OF_WEEK.filter((d) => r.dias?.[d.key])
          .map((d) => d.label)
          .join("-");
        const tot = computeRowTotals(r);
        aoa.push([
          i + 1,
          r.titulo,
          r.subtitulo,
          r.tipoReunionEvento,
          r.zonaTipo,
          r.asentamientoNombre || (r.zonaTipo === "CABECERA" ? "Cabecera" : ""),
          r.sedeEspecifica,
          r.temporalidad,
          r.fechaInicio,
          r.fechaFin,
          r.fechaUnica,
          activeDays,
          r.horario,
          r.modalidadCosto === "CON_CUOTA" ? "Con cuota" : "Sin costo",
          r.montoCuota,
          r.docente,
          toNonNegativeInt(r.pi_m),
          toNonNegativeInt(r.pi_h),
          toNonNegativeInt(r.inf_m),
          toNonNegativeInt(r.inf_h),
          toNonNegativeInt(r.ado_m),
          toNonNegativeInt(r.ado_h),
          toNonNegativeInt(r.jov_m),
          toNonNegativeInt(r.jov_h),
          toNonNegativeInt(r.adu_m),
          toNonNegativeInt(r.adu_h),
          toNonNegativeInt(r.may_m),
          toNonNegativeInt(r.may_h),
          tot.total,
          toMoneyNumber(r.recursoEstatal),
          toMoneyNumber(r.recursoMunicipal),
        ]);
      });

      const ws = window.XLSX.utils.aoa_to_sheet(aoa);
      const safeName = `${sheet.num}_${sheet.id}`.slice(0, 28);
      window.XLSX.utils.book_append_sheet(wb, ws, safeName);
    }

    const fileName = `Reporte_CasasCultura_${mpio.replace(/\s+/g, "_")}_${monthObj.short}_${state.year}.xlsx`;
    window.XLSX.writeFile(wb, fileName);
  });

  els.btnSaveMonthlyDraft?.addEventListener("click", () => {
    persistMonthStateNow();
    window.Swal?.fire({
      icon: "success",
      title: "Avance mensual resguardado",
      text: `El reporte de ${getMonthObj().name} ${state.year} (${getMunicipalityName()}) quedó guardado localmente. En el Paso 2 conectaremos este lote directo a las tablas v2 de Supabase.`,
    });
  });

  // Cambio de Municipio / Mes / Año
  els.selectMunicipality?.addEventListener("change", async () => {
    state.municipalityId = els.selectMunicipality.value;
    await ensureSettlementsForMunicipality(state.municipalityId);
    loadMonthState();
    renderAll();
  });

  els.selectMonth?.addEventListener("change", () => {
    state.month = els.selectMonth.value;
    loadMonthState();
    renderAll();
  });

  els.selectYear?.addEventListener("change", () => {
    state.year = els.selectYear.value;
    loadMonthState();
    renderAll();
  });

  // Inicialización de catálogos iniciales
  let loadedMpios = [];
  if (context) {
    try {
      loadedMpios = await loadMunicipalities(context);
    } catch (err) {
      console.warn("Usando listado municipal demostrativo en Matriz 2026:", err);
    }
  }
  state.municipalities =
    loadedMpios.length > 0 ? loadedMpios : [...FALLBACK_MUNICIPALITIES];
  state.municipalityId = state.municipalities[0]?.id || "";

  if (els.selectMunicipality) {
    els.selectMunicipality.replaceChildren();
    for (const m of state.municipalities) {
      const opt = document.createElement("option");
      opt.value = m.id;
      opt.textContent = m.nombre_oficial;
      els.selectMunicipality.appendChild(opt);
    }
  }

  if (els.selectMonth) {
    els.selectMonth.replaceChildren();
    for (const m of MONTHS) {
      const opt = document.createElement("option");
      opt.value = m.num;
      opt.textContent = `${m.num} · ${m.name}`;
      els.selectMonth.appendChild(opt);
    }
    els.selectMonth.value = state.month;
  }

  if (els.inputElabora && state.elabora) {
    els.inputElabora.value = state.elabora;
  }

  await ensureSettlementsForMunicipality(state.municipalityId);
  loadMonthState();
  renderAll();
}
