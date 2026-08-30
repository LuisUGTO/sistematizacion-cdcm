/**
 * VINCULACION CULTURAL V2
 * importer.js — Etapa 6.5.2
 * Reconocimiento institucional, alternativa avanzada, vista previa y carga segura.
 */

import { dbV2 } from "./supabase-client.js";
import {
  loadPrograms,
  loadActions,
  loadActionConfiguration,
  loadDemographicDefinition,
} from "./catalogs.js";
import {
  parseInstitutionalCdcmWorkbook,
  SMART_ACTION_CANDIDATES,
} from "./importer-smart.js";

const MAX_FILE_BYTES = 20 * 1024 * 1024;
const MAX_ROWS = 5000;
const BATCH_SIZE = 200;

const FIELD_DEFINITIONS = [
  { key: "nombre", label: "Nombre de actividad", required: true, aliases: ["nombre de la actividad", "actividad", "proyecto", "taller", "evento", "disciplina actividad", "disciplina"] },
  { key: "municipio", label: "Municipio", aliases: ["municipio", "municipios", "municipio s"] },
  { key: "fecha_inicio", label: "Fecha de inicio", aliases: ["fecha", "fecha inicio", "fecha de inicio", "fecha realizacion", "fecha de realizacion"] },
  { key: "fecha_fin", label: "Fecha final", aliases: ["fecha fin", "fecha final", "fecha de termino"] },
  { key: "sede", label: "Sede / espacio", aliases: ["sede", "espacio", "lugar", "recinto", "domicilio", "ubicacion"] },
  { key: "descripcion", label: "Descripcion", aliases: ["descripcion", "observaciones", "actividad realizada", "acciones realizadas"] },
  { key: "disciplina", label: "Disciplina / tema", aliases: ["disciplina", "tema", "nombre del taller", "tipo de taller"] },
  { key: "responsable", label: "Responsable / docente", aliases: ["responsable", "docente", "docente responsable", "tallerista", "ponente", "instructor"] },
  { key: "programacion", label: "Programacion", aliases: ["programacion", "periodicidad", "dias", "dia"] },
  { key: "modalidad_cuota", label: "Modalidad / cuota", aliases: ["modalidad cuota", "modalidad", "cuota", "costo"] },
  { key: "total_beneficiarios", label: "Total beneficiarios", aliases: ["total beneficiarios", "beneficiarios", "total personas", "total usuarios", "usuarios", "asistentes", "total asistentes"] },
  { key: "total_participantes", label: "Total participantes", aliases: ["total participantes", "participantes"] },
  { key: "total_accesos", label: "Total accesos", aliases: ["total accesos", "accesos", "visitas"] },
  { key: "mujeres", label: "Mujeres", aliases: ["mujeres", "mujer", "femenino"] },
  { key: "hombres", label: "Hombres", aliases: ["hombres", "hombre", "masculino"] },
  { key: "primera_infancia", label: "Primera infancia", aliases: ["primera infancia", "0 5", "0 a 5"] },
  { key: "ninez", label: "Ninez", aliases: ["ninez", "ninas ninos", "infancia", "6 11", "6 a 11"] },
  { key: "adolescencia", label: "Adolescencia", aliases: ["adolescencia", "adolescentes", "12 17", "12 a 17"] },
  { key: "juventudes", label: "Juventudes", aliases: ["juventudes", "jovenes", "18 29", "18 a 29"] },
  { key: "adultos", label: "Personas adultas", aliases: ["adultos", "personas adultas", "30 59", "30 a 59", "adultos 30 59"] },
  { key: "adultos_mayores", label: "Adultos mayores", aliases: ["adultos mayores", "personas adultas mayores", "60 y mas"] },
  { key: "discapacidad", label: "Discapacidad", aliases: ["discapacidad", "personas con discapacidad"] },
  { key: "indigenas", label: "Pueblos indigenas", aliases: ["indigenas", "grupos indigenas", "pueblos indigenas"] },
  { key: "afromexicanas", label: "Personas afromexicanas", aliases: ["afromexicanas", "afromexicanos", "personas afromexicanas"] },
  { key: "lgbtq", label: "LGBTQ+", aliases: ["lgbtq", "lgbtq+", "diversidad sexual"] },
];

const DEMOGRAPHIC_FIELDS = [
  "mujeres", "hombres", "primera_infancia", "ninez", "adolescencia",
  "juventudes", "adultos", "adultos_mayores", "discapacidad", "indigenas",
  "afromexicanas", "lgbtq",
];

const state = {
  context: null,
  units: [],
  municipalities: [],
  workbook: null,
  file: null,
  matrix: [],
  headers: [],
  headerIndex: 0,
  profile: null,
  config: null,
  demographics: [],
  preview: [],
  smart: null,
  smartDestinations: new Map(),
  smartDemographics: new Map(),
};

const $ = (id) => document.getElementById(id);
const ui = {};

function normalize(value) {
  return String(value ?? "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[^a-zA-Z0-9]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .toLowerCase();
}

function friendlyError(error) {
  return String(error?.message ?? error ?? "Error no identificado")
    .replace(/^[A-Z_]+:\s*/, "")
    .trim();
}

function rpcRow(data) {
  if (Array.isArray(data)) return data[0] ?? null;
  return data ?? null;
}

async function alertError(title, error) {
  console.error(title, error);
  await Swal.fire({ icon: "error", title, text: friendlyError(error) });
}

function setStatus(message, kind = "info") {
  ui.status.className = `import-status ${kind}`;
  ui.status.textContent = message;
  ui.status.hidden = !message;
}

function setBusy(busy, label = "Procesando…") {
  ui.importButton.disabled = busy || !state.preview.some((row) => row.valid);
  ui.previewButton.disabled = busy;
  ui.file.disabled = busy;
  ui.importButton.textContent = busy ? label : "Importar filas validas";
}

function fillSelect(select, rows, { placeholder, value = "id", label = "nombre" } = {}) {
  select.replaceChildren();
  const first = document.createElement("option");
  first.value = "";
  first.textContent = placeholder ?? "Seleccione…";
  select.appendChild(first);
  rows.forEach((row) => {
    const option = document.createElement("option");
    option.value = row[value];
    option.textContent = row[label];
    select.appendChild(option);
  });
}

function aliasScore(header) {
  const value = normalize(header);
  if (!value) return 0;
  return FIELD_DEFINITIONS.some((field) =>
    field.aliases.some((alias) => value === normalize(alias))
  ) ? 1 : 0;
}

function detectHeader(matrix) {
  let best = { index: 0, score: -1, populated: 0 };
  matrix.slice(0, 30).forEach((row, index) => {
    const populated = row.filter((cell) => normalize(cell)).length;
    const score = row.reduce((sum, cell) => sum + aliasScore(cell), 0);
    if (score > best.score || (score === best.score && populated > best.populated)) {
      best = { index, score, populated };
    }
  });
  return best;
}

function detectProfile(fileName, sheetName, matrix) {
  const sample = normalize([
    fileName,
    sheetName,
    ...matrix.slice(0, 12).flat().slice(0, 180),
  ].join(" "));
  const header = detectHeader(matrix);

  if (header.score >= 3 && /actividad|proyecto|taller|evento|disciplina/.test(sample)) {
    return { key: "ACTIVIDADES_OPERATIVAS", label: "Actividades operativas", allowed: true, note: "Se encontraron columnas compatibles con actividades." };
  }
  if (/diagnostico|directorio|bibliotecarios|autoridades municipales/.test(sample)) {
    return { key: "CATALOGO_BIBLIOTECAS", label: "Catalogo / directorio", allowed: false, note: "Este libro alimenta catalogos, no actividades. Se integrara sin alterar el dashboard operativo." };
  }
  if (/estadisticas|estadistica mensual|servicios bibliotecarios/.test(sample)) {
    return { key: "ESTADISTICA_BIBLIOTECAS", label: "Estadistica de bibliotecas", allowed: false, note: "Es un agregado estadistico y requiere su capa de indicadores para evitar doble conteo." };
  }
  if (/indicadores|meta anual|numeralia|resumen por proyecto/.test(sample)) {
    return { key: "INDICADORES_PROYECTO", label: "Indicadores / numeralia", allowed: false, note: "Es informacion agregada. No se mezclara con actividades individuales." };
  }
  if (/concentrado|concentrados|resumen/.test(sample)) {
    return { key: "AGREGADO_MENSUAL", label: "Concentrado mensual", allowed: false, note: "Se detecto un concentrado; importarlo como actividad duplicaria cifras si tambien existen hojas de detalle." };
  }
  return { key: "MAPEO_ASISTIDO", label: "Mapeo asistido", allowed: true, note: "Revisa las columnas sugeridas antes de continuar." };
}

function bestHeaderForField(field, headers) {
  const normalizedAliases = field.aliases.map(normalize);
  let exact = headers.findIndex((header) => normalizedAliases.includes(normalize(header)));
  if (exact >= 0) return String(exact);
  exact = headers.findIndex((header) =>
    normalizedAliases.some((alias) => normalize(header).includes(alias) || alias.includes(normalize(header)))
  );
  return exact >= 0 ? String(exact) : "";
}

function renderMappings() {
  ui.mappingGrid.replaceChildren();
  FIELD_DEFINITIONS.forEach((field) => {
    const wrapper = document.createElement("div");
    wrapper.className = "mapping-field";
    const label = document.createElement("label");
    label.htmlFor = `map-${field.key}`;
    label.textContent = `${field.label}${field.required ? " *" : ""}`;
    const select = document.createElement("select");
    select.className = "control import-map";
    select.id = `map-${field.key}`;
    select.dataset.field = field.key;
    const empty = document.createElement("option");
    empty.value = "";
    empty.textContent = "No usar columna";
    select.appendChild(empty);
    state.headers.forEach((header, index) => {
      const option = document.createElement("option");
      option.value = String(index);
      option.textContent = header || `Columna ${index + 1}`;
      select.appendChild(option);
    });
    select.value = bestHeaderForField(field, state.headers);
    wrapper.append(label, select);
    ui.mappingGrid.appendChild(wrapper);
  });
}

function currentMapping() {
  return Object.fromEntries(
    [...document.querySelectorAll(".import-map")].map((select) => [
      select.dataset.field,
      select.value === "" ? null : Number(select.value),
    ])
  );
}

function setSmartMode(active) {
  ui.smartSummary.hidden = !active;
  ui.formatSection.hidden = active;
  ui.destinationSection.hidden = active;
  ui.mappingSection.hidden = active;
  ui.previewButton.textContent = active
    ? "Revisar actividades detectadas"
    : "Preparar vista previa";
}

function renderSmartSummary() {
  const smart = state.smart;
  if (!smart?.recognized) return;

  const municipality = findMunicipality(smart.municipalityName);
  const zeroTotals = smart.rows.filter((row) => !row.total_beneficiarios).length;
  const missingDestinations = smart.categories.filter(
    (category) => !state.smartDestinations.get(category.key)?.action
  ).length;

  ui.smartSummaryText.textContent =
    `${smart.municipalityName || "Municipio por confirmar"} · ${smart.year} · ` +
    `${smart.sheets.length} hojas mensuales · ${smart.rows.length} actividades localizadas.`;
  ui.smartCategoryList.replaceChildren();

  for (const category of smart.categories) {
    const destination = state.smartDestinations.get(category.key);
    const item = document.createElement("div");
    item.className = destination?.action
      ? "smart-category-card"
      : "smart-category-card warning";

    const title = document.createElement("strong");
    title.textContent = `${category.label}: ${category.count}`;
    const detail = document.createElement("span");
    detail.textContent = destination?.action
      ? `Destino V2: ${destination.action.nombre}`
      : "Falta una acción V2 compatible";
    item.append(title, detail);
    ui.smartCategoryList.appendChild(item);
  }

  const notes = [];
  if (!municipality) notes.push(`No se reconoció el municipio “${smart.municipalityName}”.`);
  if (missingDestinations) notes.push(`${missingDestinations} categoría(s) no tienen destino V2 configurado.`);
  if (zeroTotals) notes.push(`${zeroTotals} actividad(es) no contienen cifra de personas; se mostrarán para revisión.`);
  ui.smartSummaryNote.textContent = notes.length
    ? notes.join(" ")
    : "Todo quedó relacionado automáticamente. Solo revisa la vista previa antes de importar.";
  ui.smartSummaryNote.className = notes.length
    ? "smart-summary-note warning"
    : "smart-summary-note";
}

async function activateSmartCdcmMode() {
  const smart = state.smart;
  const unit = state.units.find((row) =>
    normalize(row.clave) === "cdcm" || normalize(row.nombre).includes("desarrollo cultural municipal")
  );

  state.smartDestinations.clear();
  state.smartDemographics.clear();

  if (!unit) {
    setSmartMode(true);
    renderSmartSummary();
    return;
  }

  const referenceDate = `${smart.year}-01-01`;
  const actions = await loadActions(unit.id, null, referenceDate);

  for (const category of smart.categories) {
    const candidates = SMART_ACTION_CANDIDATES[category.key] ?? [];
    const action = candidates
      .map((key) => actions.find((item) => normalize(item.clave) === normalize(key)))
      .find(Boolean) ?? null;
    const config = action
      ? await loadActionConfiguration(action.id, referenceDate)
      : null;

    state.smartDestinations.set(category.key, { unit, action, config });

    if (config?.esquema_demografico_id && !state.smartDemographics.has(config.esquema_demografico_id)) {
      const definition = await loadDemographicDefinition(config.esquema_demografico_id);
      state.smartDemographics.set(config.esquema_demografico_id, definition);
    }
  }

  state.profile = {
    key: smart.profile,
    label: smart.label,
    allowed: true,
    note: "El sistema separó automáticamente meses, bloques, actividades y población.",
  };
  setSmartMode(true);
  renderSmartSummary();
}

function updateSheet() {
  if (!state.workbook || !ui.sheet.value) return;
  const sheet = state.workbook.Sheets[ui.sheet.value];
  state.matrix = XLSX.utils.sheet_to_json(sheet, {
    header: 1,
    defval: null,
    raw: true,
    blankrows: false,
  });
  const detected = detectHeader(state.matrix);
  state.headerIndex = detected.index;
  ui.headerRow.value = String(detected.index + 1);
  state.headers = (state.matrix[detected.index] ?? []).map((cell, index) =>
    String(cell ?? "").trim() || `Columna ${index + 1}`
  );
  state.profile = detectProfile(state.file.name, ui.sheet.value, state.matrix);
  ui.profile.textContent = state.profile.label;
  ui.profileNote.textContent = state.profile.note;
  ui.profileBox.className = `profile-box ${state.profile.allowed ? "safe" : "warning"}`;
  renderMappings();
  state.preview = [];
  renderPreview();
}

function updateHeaderRow() {
  const requested = Math.max(1, Number(ui.headerRow.value) || 1) - 1;
  state.headerIndex = Math.min(requested, Math.max(0, state.matrix.length - 1));
  state.headers = (state.matrix[state.headerIndex] ?? []).map((cell, index) =>
    String(cell ?? "").trim() || `Columna ${index + 1}`
  );
  renderMappings();
  state.preview = [];
  renderPreview();
}

async function readFile(file) {
  if (!window.XLSX) throw new Error("No se pudo cargar el lector de Excel. Revisa la conexion y actualiza la pagina.");
  if (!file) return;
  if (file.size > MAX_FILE_BYTES) throw new Error("El archivo supera el limite de 20 MB.");
  if (!/\.(xlsx|xls|csv)$/i.test(file.name)) throw new Error("Selecciona un archivo .xlsx, .xls o .csv.");

  setStatus("Leyendo el archivo en este dispositivo…");
  const bytes = await file.arrayBuffer();
  state.workbook = XLSX.read(bytes, { type: "array", cellDates: true, raw: true });
  state.file = file;
  state.smart = parseInstitutionalCdcmWorkbook(state.workbook, file.name, XLSX);
  fillSelect(
    ui.sheet,
    state.workbook.SheetNames.map((name) => ({ id: name, nombre: name })),
    { placeholder: "Seleccione una hoja…" }
  );
  ui.sheet.value = state.workbook.SheetNames[0] ?? "";
  if (state.smart.recognized) {
    await activateSmartCdcmMode();
  } else {
    setSmartMode(false);
    updateSheet();
  }
  ui.configuration.hidden = false;
  setStatus(
    state.smart.recognized
      ? `Formato institucional reconocido automáticamente: ${state.smart.rows.length} actividades encontradas.`
      : `Archivo listo: ${state.workbook.SheetNames.length} hoja(s) detectada(s).`,
    "success"
  );
}

function toNumber(value) {
  if (value === null || value === undefined || value === "") return null;
  if (typeof value === "number" && Number.isFinite(value)) return Math.round(value);
  const cleaned = String(value).replace(/[^0-9.,-]/g, "").replace(/,/g, "");
  if (!cleaned) return null;
  const parsed = Number(cleaned);
  return Number.isFinite(parsed) ? Math.round(parsed) : null;
}

function toISODate(value, fallback = null) {
  if (value instanceof Date && !Number.isNaN(value.getTime())) return value.toISOString().slice(0, 10);
  if (typeof value === "number" && window.XLSX?.SSF) {
    const parsed = XLSX.SSF.parse_date_code(value);
    if (parsed) return `${parsed.y}-${String(parsed.m).padStart(2, "0")}-${String(parsed.d).padStart(2, "0")}`;
  }
  const text = String(value ?? "").trim();
  if (!text) return fallback;
  if (/^\d{4}-\d{1,2}-\d{1,2}$/.test(text)) {
    const [year, month, day] = text.split("-");
    return `${year}-${month.padStart(2, "0")}-${day.padStart(2, "0")}`;
  }
  const match = text.match(/^(\d{1,2})[\/-](\d{1,2})[\/-](\d{2,4})$/);
  if (match) {
    const year = match[3].length === 2 ? `20${match[3]}` : match[3];
    return `${year}-${match[2].padStart(2, "0")}-${match[1].padStart(2, "0")}`;
  }
  const parsed = new Date(text);
  return Number.isNaN(parsed.getTime()) ? fallback : parsed.toISOString().slice(0, 10);
}

function findMunicipality(value) {
  const target = normalize(value);
  if (!target) return null;
  const exact = state.municipalities.find((row) => normalize(row.nombre_oficial) === target);
  if (exact) return exact;
  const partial = state.municipalities.filter((row) => {
    const name = normalize(row.nombre_oficial);
    return name.includes(target) || target.includes(name);
  });
  return partial.length === 1 ? partial[0] : null;
}

function valueAt(row, mapping, key) {
  const index = mapping[key];
  return index === null || index === undefined ? null : row[index];
}

function rowAsObject(headers, row) {
  return Object.fromEntries(headers.map((header, index) => [header || `Columna ${index + 1}`, row[index] ?? null]));
}

function fingerprint(parts) {
  const input = parts.map((part) => normalize(part)).join("|");
  let hash = 2166136261;
  for (let index = 0; index < input.length; index += 1) {
    hash ^= input.charCodeAt(index);
    hash = Math.imul(hash, 16777619);
  }
  return `v2-${(hash >>> 0).toString(16).padStart(8, "0")}-${input.length}`;
}

function demographicOption(field, definitions = state.demographics) {
  const definition = FIELD_DEFINITIONS.find((item) => item.key === field);
  const aliases = [field, ...(definition?.aliases ?? [])].map(normalize);
  const options = (definitions ?? []).flatMap((group) => group.options ?? []);
  return options.find((option) => {
    const values = [option.clave, option.nombre].map(normalize);
    return values.some((value) => aliases.some((alias) => value === alias || value.includes(alias) || alias.includes(value)));
  }) ?? null;
}

function makeDemography(row, mapping) {
  if (!state.config?.requiere_demografia) return [];
  return DEMOGRAPHIC_FIELDS.flatMap((field) => {
    const quantity = toNumber(valueAt(row, mapping, field));
    const option = demographicOption(field);
    if (!option || quantity === null || quantity <= 0) return [];
    return [{ opcion_poblacion_id: option.id, universo: "BENEFICIARIOS", cantidad: quantity }];
  });
}

function makeSmartDemography(row, config) {
  if (!config?.requiere_demografia) return [];
  const definitions = state.smartDemographics.get(config.esquema_demografico_id) ?? [];
  return DEMOGRAPHIC_FIELDS.flatMap((field) => {
    const quantity = toNumber(row[field]);
    const option = demographicOption(field, definitions);
    if (!option || quantity === null || quantity <= 0) return [];
    return [{ opcion_poblacion_id: option.id, universo: "BENEFICIARIOS", cantidad: quantity }];
  });
}

function buildSmartPreviewRows() {
  const municipality = findMunicipality(state.smart.municipalityName);

  return state.smart.rows.map((row, index) => {
    const destination = state.smartDestinations.get(row.category) ?? {};
    const { unit, action, config } = destination;
    const errors = [];

    if (!unit) errors.push("No se encontró la unidad CDCM");
    if (!action) errors.push(`No existe una acción V2 para ${row.categoryLabel}`);
    if (!config) errors.push(`La acción ${action?.nombre ?? row.categoryLabel} no tiene configuración vigente`);
    if (config?.requiere_municipio && !municipality) {
      errors.push(`Municipio no reconocido: ${state.smart.municipalityName}`);
    }

    const beneficiaries = row.total_beneficiarios > 0
      ? row.total_beneficiarios
      : null;
    const formType = String(config?.tipo_formulario ?? "").toUpperCase();
    const payload = {
      unidad_operativa_id: unit?.id ?? null,
      programa_id: action?.programa_id ?? null,
      accion_id: action?.id ?? null,
      configuracion_accion_id: config?.id ?? null,
      municipio_id: municipality?.id ?? null,
      nombre: row.name,
      descripcion: row.description || null,
      fecha_inicio: row.date,
      fecha_fin: row.date,
      total_beneficiarios: beneficiaries,
      total_participantes: null,
      total_accesos: null,
      metadata: {
        frontend: { version: "6.5.2", capture_module: "smart_excel_import" },
        location_text: { sede: row.venue || null },
        importacion_automatica: {
          formato: state.smart.profile,
          categoria: row.category,
          mes: row.sheet,
          fila_excel: row.excelRow,
          cifras_vacias: beneficiaries === null,
        },
        source_labels: {
          unidad: unit?.nombre ?? "CDCM",
          programa: action?.programa_id ? "Asignado automáticamente por la acción" : null,
          accion: action?.nombre ?? null,
          municipio: municipality?.nombre_oficial ?? state.smart.municipalityName,
          responsable: row.responsible || null,
        },
      },
      taller: ["TALLER", "CAPACITACION"].includes(formType) ? {
        disciplina: row.name,
        programacion: [row.days, row.schedule].filter(Boolean).join(" · ") || null,
        modalidad_cuota: row.fee || null,
        observaciones: row.responsible
          ? `Responsable en archivo: ${row.responsible}`
          : null,
      } : null,
      demografia: makeSmartDemography(row, config),
    };

    const rowFingerprint = fingerprint([
      unit?.id,
      action?.id,
      municipality?.id,
      row.date,
      row.name,
      beneficiaries,
      row.sheet,
    ]);

    return {
      valid: errors.length === 0,
      errors,
      excelRow: row.excelRow,
      sheet: row.sheet,
      name: row.name,
      municipality: municipality?.nombre_oficial ?? state.smart.municipalityName,
      date: row.date,
      total: beneficiaries,
      staging: {
        numero_fila: index + 1,
        raw_data: {
          hoja: row.sheet,
          fila_excel: row.excelRow,
          categoria: row.categoryLabel,
          valores: row.raw,
        },
        normalized_data: {
          perfil: state.smart.profile,
          hoja: row.sheet,
          fila_excel: row.excelRow,
          fingerprint: rowFingerprint,
          payload,
        },
      },
    };
  });
}

function buildPreviewRows() {
  const mapping = currentMapping();
  const defaultMunicipality = state.municipalities.find((row) => row.id === ui.defaultMunicipality.value) ?? null;
  const defaultDate = ui.defaultDate.value || null;
  const selectedUnit = state.units.find((row) => row.id === ui.unit.value);
  const selectedProgram = [...ui.program.options].find((option) => option.value === ui.program.value);
  const selectedAction = [...ui.action.options].find((option) => option.value === ui.action.value);
  const output = [];

  if (!ui.unit.value || !ui.program.value || !ui.action.value || !state.config) {
    throw new Error("Selecciona unidad, programa y accion antes de preparar la vista previa.");
  }
  if (mapping.nombre === null) throw new Error("Asigna la columna Nombre de actividad.");

  const dataRows = state.matrix.slice(state.headerIndex + 1);
  let sequential = 0;
  for (let index = 0; index < dataRows.length; index += 1) {
    const row = dataRows[index];
    if (!row.some((cell) => normalize(cell))) continue;
    const name = String(valueAt(row, mapping, "nombre") ?? "").trim();
    const hasMetrics = ["total_beneficiarios", "total_participantes", "total_accesos", ...DEMOGRAPHIC_FIELDS]
      .some((field) => toNumber(valueAt(row, mapping, field)) !== null);
    if (!name && !hasMetrics) continue;
    sequential += 1;
    if (sequential > MAX_ROWS) throw new Error(`La hoja supera el limite de ${MAX_ROWS.toLocaleString("es-MX")} filas por importacion.`);

    const errors = [];
    const municipalityText = valueAt(row, mapping, "municipio");
    const municipality = findMunicipality(municipalityText) ?? defaultMunicipality;
    const dateStart = toISODate(valueAt(row, mapping, "fecha_inicio"), defaultDate);
    const dateEnd = toISODate(valueAt(row, mapping, "fecha_fin"), dateStart);
    const beneficiaries = toNumber(valueAt(row, mapping, "total_beneficiarios"));
    const participants = toNumber(valueAt(row, mapping, "total_participantes"));
    const access = toNumber(valueAt(row, mapping, "total_accesos"));
    if (!name) errors.push("Falta nombre de actividad");
    if (!dateStart) errors.push("Falta una fecha valida");
    if (state.config.requiere_municipio && !municipality) errors.push(`Municipio no reconocido: ${municipalityText ?? "sin dato"}`);
    if ([beneficiaries, participants, access].some((value) => value !== null && value < 0)) errors.push("Los totales no pueden ser negativos");

    const description = String(valueAt(row, mapping, "descripcion") ?? "").trim() || null;
    const venue = String(valueAt(row, mapping, "sede") ?? "").trim() || null;
    const responsible = String(valueAt(row, mapping, "responsable") ?? "").trim() || null;
    const discipline = String(valueAt(row, mapping, "disciplina") ?? "").trim() || null;
    const formType = String(state.config.tipo_formulario ?? "").toUpperCase();

    const payload = {
      unidad_operativa_id: ui.unit.value,
      programa_id: ui.program.value,
      accion_id: ui.action.value,
      configuracion_accion_id: state.config.id,
      municipio_id: municipality?.id ?? null,
      nombre: name,
      descripcion,
      fecha_inicio: dateStart,
      fecha_fin: dateEnd,
      total_beneficiarios: beneficiaries,
      total_participantes: participants,
      total_accesos: access,
      metadata: {
        frontend: { version: "6.5.2", capture_module: "excel_import" },
        location_text: { sede: venue },
        source_labels: {
          unidad: selectedUnit?.nombre ?? null,
          programa: selectedProgram?.textContent ?? null,
          accion: selectedAction?.textContent ?? null,
          municipio: municipality?.nombre_oficial ?? municipalityText ?? null,
          responsable: responsible,
        },
      },
      taller: ["TALLER", "CAPACITACION"].includes(formType) ? {
        disciplina,
        programacion: String(valueAt(row, mapping, "programacion") ?? "").trim() || null,
        modalidad_cuota: String(valueAt(row, mapping, "modalidad_cuota") ?? "").trim() || null,
        observaciones: responsible ? `Responsable en archivo: ${responsible}` : null,
      } : null,
      demografia: makeDemography(row, mapping),
    };

    const rowFingerprint = fingerprint([
      ui.unit.value, ui.action.value, municipality?.id, dateStart, dateEnd,
      name, beneficiaries, participants, access,
    ]);

    output.push({
      valid: errors.length === 0,
      errors,
      excelRow: state.headerIndex + index + 2,
      sheet: ui.sheet.value,
      name,
      municipality: municipality?.nombre_oficial ?? String(municipalityText ?? ""),
      date: dateStart,
      total: beneficiaries,
      staging: {
        numero_fila: sequential,
        raw_data: rowAsObject(state.headers, row),
        normalized_data: {
          perfil: state.profile.key,
          hoja: ui.sheet.value,
          fila_excel: state.headerIndex + index + 2,
          fingerprint: rowFingerprint,
          payload,
        },
      },
    });
  }
  return output;
}

function renderPreview() {
  ui.previewBody.replaceChildren();
  const valid = state.preview.filter((row) => row.valid).length;
  const errors = state.preview.length - valid;
  ui.previewSummary.textContent = state.preview.length
    ? `${state.preview.length.toLocaleString("es-MX")} filas: ${valid.toLocaleString("es-MX")} listas y ${errors.toLocaleString("es-MX")} con observaciones.`
    : "Prepara una vista previa para revisar los datos antes de guardarlos.";

  state.preview.slice(0, 100).forEach((item) => {
    const row = ui.previewBody.insertRow();
    row.className = item.valid ? "preview-valid" : "preview-error";
    row.insertCell().textContent = `${item.sheet} · ${item.excelRow}`;
    row.insertCell().textContent = item.name || "Sin nombre";
    row.insertCell().textContent = item.municipality || "Sin municipio";
    row.insertCell().textContent = item.date || "Sin fecha";
    row.insertCell().textContent = item.total ?? "—";
    row.insertCell().textContent = item.valid ? "Lista" : item.errors.join(" · ");
  });
  ui.previewLimit.hidden = state.preview.length <= 100;
  ui.importButton.disabled = valid === 0;
}

async function preparePreview() {
  try {
    if (state.smart?.recognized) {
      state.preview = buildSmartPreviewRows();
      renderPreview();
      const valid = state.preview.filter((row) => row.valid).length;
      setStatus(
        `Vista previa automática lista: ${valid.toLocaleString("es-MX")} de ${state.preview.length.toLocaleString("es-MX")} actividad(es) pueden importarse.`,
        valid ? "success" : "warning"
      );
      return;
    }

    if (!state.profile?.allowed) {
      const decision = await Swal.fire({
        icon: "warning",
        title: "Formato agregado detectado",
        text: `${state.profile.note} Si esta hoja realmente contiene actividades individuales, puedes continuar bajo tu responsabilidad.`,
        showCancelButton: true,
        confirmButtonText: "Continuar con el mapeo",
        cancelButtonText: "Cancelar",
      });
      if (!decision.isConfirmed) return;
    }
    state.preview = buildPreviewRows();
    renderPreview();
    const valid = state.preview.filter((row) => row.valid).length;
    setStatus(`Vista previa lista. ${valid.toLocaleString("es-MX")} fila(s) pueden importarse como borradores.`, valid ? "success" : "warning");
  } catch (error) {
    await alertError("No se pudo preparar la vista previa", error);
  }
}

async function importRows() {
  const validRows = state.preview.filter((row) => row.valid);
  if (!validRows.length) return;
  const invalidCount = state.preview.length - validRows.length;
  const decision = await Swal.fire({
    icon: "question",
    title: `Importar ${validRows.length.toLocaleString("es-MX")} actividad(es)`,
    html: `Se guardaran como <b>borradores V2</b> para su revision.${invalidCount ? `<br>${invalidCount} fila(s) con observaciones quedaran registradas en el trabajo, sin crear actividad.` : ""}`,
    showCancelButton: true,
    confirmButtonText: "Si, iniciar importacion",
    cancelButtonText: "Revisar de nuevo",
  });
  if (!decision.isConfirmed) return;

  setBusy(true, "Importando…");
  try {
    const prepare = await dbV2().rpc("rpc_import_preparar", {
      p_archivo_nombre: state.file.name,
      p_tipo_importacion: state.profile.key,
      p_metadata: {
        frontend_version: "6.5.2",
        hoja: ui.sheet.value,
        filas_previsualizadas: state.preview.length,
        filas_validas_cliente: validRows.length,
      },
    });
    if (prepare.error) throw prepare.error;
    const jobId = prepare.data;

    let validationResult = null;
    for (let start = 0; start < state.preview.length; start += BATCH_SIZE) {
      const batch = state.preview.slice(start, start + BATCH_SIZE).map((row) => row.staging);
      setStatus(`Validando filas ${start + 1} a ${Math.min(start + BATCH_SIZE, state.preview.length)}…`);
      const loaded = await dbV2().rpc("rpc_import_cargar_lote", { p_job_id: jobId, p_rows: batch });
      if (loaded.error) throw loaded.error;
      validationResult = rpcRow(loaded.data);
    }

    const serverValid = Number(validationResult?.filas_validas ?? 0);
    const serverErrors = Number(validationResult?.filas_error ?? 0);
    const serverDuplicates = Number(validationResult?.filas_duplicadas ?? 0);

    if (serverValid === 0) {
      const duplicateOnly = serverDuplicates > 0 && serverErrors === 0;
      const statusMessage = duplicateOnly
        ? `El archivo ya había sido importado: ${serverDuplicates.toLocaleString("es-MX")} duplicado(s) y 0 registros nuevos.`
        : `No se crearon registros: ${serverErrors.toLocaleString("es-MX")} fila(s) con error y ${serverDuplicates.toLocaleString("es-MX")} duplicado(s).`;

      setStatus(statusMessage, duplicateOnly ? "success" : "warning");
      await loadHistory();
      await Swal.fire({
        icon: duplicateOnly ? "info" : "warning",
        title: duplicateOnly ? "El archivo ya estaba importado" : "No había filas nuevas para importar",
        html: duplicateOnly
          ? `<b>${serverDuplicates.toLocaleString("es-MX")}</b> actividad(es) ya existen.<br>No se creó ningún registro duplicado.`
          : `<b>0</b> registros nuevos.<br>${serverErrors.toLocaleString("es-MX")} error(es) · ${serverDuplicates.toLocaleString("es-MX")} duplicado(s).`,
        confirmButtonText: "Entendido",
      });
      return;
    }

    setStatus("Creando borradores V2 y aplicando validaciones institucionales…");
    const confirmed = await dbV2().rpc("rpc_import_confirmar", { p_job_id: jobId }).single();
    if (confirmed.error) throw confirmed.error;
    const result = confirmed.data;
    await loadHistory();
    window.dispatchEvent(new CustomEvent("v2:record-updated"));
    setStatus(`Importacion terminada: ${result.filas_importadas} borrador(es), ${result.filas_error} error(es) y ${result.filas_duplicadas} duplicado(s).`, result.filas_importadas ? "success" : "warning");
    await Swal.fire({
      icon: result.filas_importadas ? "success" : "warning",
      title: "Importacion terminada",
      html: `<b>${result.filas_importadas}</b> borrador(es) creados.<br>${result.filas_error} error(es) · ${result.filas_duplicadas} duplicado(s).<br><br>Puedes revisarlos en Bitacora antes de enviarlos a validacion.`,
      confirmButtonText: "Entendido",
    });
  } catch (error) {
    await alertError("No se pudo completar la importacion", error);
    setStatus("La importacion se detuvo. Ninguna fila pendiente se confirmo silenciosamente.", "error");
  } finally {
    setBusy(false);
  }
}

async function updatePrograms() {
  state.config = null;
  state.demographics = [];
  const programs = await loadPrograms(ui.unit.value);
  fillSelect(ui.program, programs, { placeholder: "Seleccione programa…" });
  fillSelect(ui.action, [], { placeholder: "Seleccione primero un programa…" });
}

async function updateActions() {
  state.config = null;
  state.demographics = [];
  const referenceDate = ui.defaultDate.value || new Date().toISOString().slice(0, 10);
  const actions = await loadActions(ui.unit.value, ui.program.value, referenceDate);
  fillSelect(ui.action, actions, { placeholder: "Seleccione accion…" });
}

async function updateConfiguration() {
  state.config = null;
  state.demographics = [];
  if (!ui.action.value) return;
  const referenceDate = ui.defaultDate.value || new Date().toISOString().slice(0, 10);
  state.config = await loadActionConfiguration(ui.action.value, referenceDate);
  if (!state.config) throw new Error("La accion no tiene configuracion vigente para la fecha elegida.");
  state.demographics = await loadDemographicDefinition(state.config.esquema_demografico_id);
  ui.actionNote.textContent = `Formulario ${state.config.tipo_formulario}. ${state.config.requiere_municipio ? "Requiere municipio." : "Municipio opcional."} ${state.config.requiere_demografia ? "Acepta desglose demografico." : "Sin desglose demografico para esta accion."}`;
}

async function loadHistory() {
  const { data, error } = await dbV2().rpc("rpc_import_historial");
  if (error) throw error;
  ui.historyBody.replaceChildren();
  if (!(data ?? []).length) {
    const row = ui.historyBody.insertRow();
    row.insertCell().colSpan = 6;
    row.cells[0].textContent = "Aun no hay importaciones V2.";
    return;
  }
  data.forEach((job) => {
    const row = ui.historyBody.insertRow();
    row.insertCell().textContent = new Intl.DateTimeFormat("es-MX", { dateStyle: "medium", timeStyle: "short" }).format(new Date(job.created_at));
    row.insertCell().textContent = job.archivo_nombre;
    row.insertCell().textContent = job.estatus.replaceAll("_", " ");
    row.insertCell().textContent = job.total_filas;
    row.insertCell().textContent = job.filas_importadas;
    row.insertCell().textContent = `${job.filas_error} / ${job.filas_duplicadas}`;
  });
}

function installEvents() {
  ui.file.addEventListener("change", async () => {
    try { await readFile(ui.file.files?.[0]); } catch (error) { await alertError("No se pudo leer el archivo", error); }
  });
  ui.sheet.addEventListener("change", updateSheet);
  ui.headerRow.addEventListener("change", updateHeaderRow);
  ui.unit.addEventListener("change", async () => {
    try { await updatePrograms(); } catch (error) { await alertError("No se cargaron los programas", error); }
  });
  ui.program.addEventListener("change", async () => {
    try { await updateActions(); } catch (error) { await alertError("No se cargaron las acciones", error); }
  });
  ui.action.addEventListener("change", async () => {
    try { await updateConfiguration(); } catch (error) { await alertError("Configuracion no disponible", error); }
  });
  ui.defaultDate.addEventListener("change", async () => {
    if (ui.program.value) await updateActions();
  });
  ui.previewButton.addEventListener("click", preparePreview);
  ui.importButton.addEventListener("click", importRows);
  ui.templateLink.addEventListener("click", () => {
    setStatus("La plantilla oficial incluye los encabezados que el sistema reconoce automaticamente.", "success");
  });
}

export async function initializeImporter({ context, units, municipalities }) {
  Object.assign(ui, {
    file: $("importFile"),
    sheet: $("importSheet"),
    headerRow: $("importHeaderRow"),
    profile: $("importProfile"),
    profileNote: $("importProfileNote"),
    profileBox: $("importProfileBox"),
    configuration: $("importConfiguration"),
    unit: $("importUnit"),
    program: $("importProgram"),
    action: $("importAction"),
    defaultMunicipality: $("importDefaultMunicipality"),
    defaultDate: $("importDefaultDate"),
    actionNote: $("importActionNote"),
    mappingGrid: $("importMappingGrid"),
    previewButton: $("prepareImportPreview"),
    importButton: $("confirmImport"),
    previewSummary: $("importPreviewSummary"),
    previewBody: $("importPreviewBody"),
    previewLimit: $("importPreviewLimit"),
    historyBody: $("importHistoryBody"),
    status: $("importStatus"),
    templateLink: $("downloadImportTemplate"),
    smartSummary: $("importSmartSummary"),
    smartSummaryText: $("importSmartSummaryText"),
    smartCategoryList: $("importSmartCategoryList"),
    smartSummaryNote: $("importSmartSummaryNote"),
    formatSection: $("importFormatSection"),
    destinationSection: $("importDestinationSection"),
    mappingSection: $("importMappingSection"),
  });

  state.context = context;
  state.units = units;
  state.municipalities = municipalities;
  fillSelect(ui.unit, units, { placeholder: "Seleccione unidad…" });
  fillSelect(ui.defaultMunicipality, municipalities, { placeholder: "Usar municipio de cada fila", label: "nombre_oficial" });
  ui.defaultDate.value = new Date().toISOString().slice(0, 10);
  installEvents();
  renderPreview();
  await loadHistory();
}
