/**
 * VINCULACION CULTURAL 2.0
 * dashboard.js
 *
 * Etapa 6: Dashboard Directivo e indicadores reales.
 *
 * La agregacion ocurre en PostgreSQL mediante rpc_dashboard_directivo().
 * El navegador solo presenta el resultado y nunca sustituye RLS.
 */

import { dbV2 } from "./supabase-client.js";
import {
  PERMISSIONS,
  can,
  isAdmin,
} from "./permissions.js";

let context = null;
let initialized = false;
let catalogState = {
  units: [],
  programs: [],
  municipalities: [],
};
let loadSequence = 0;
let mapRenderSequence = 0;
let mapGeometryPromise = null;
let lastPayload = null;
let selectedMapCode = null;
let mapFeaturesByCode = new Map();

const ui = {};
const $ = (id) => document.getElementById(id);

const STATUS_COLORS = Object.freeze({
  BORRADOR: "#94A3B8",
  CAPTURADO: "#38BDF8",
  EN_REVISION: "#F59E0B",
  OBSERVADO: "#F97316",
  CORREGIDO: "#8B5CF6",
  VALIDADO: "#059669",
  ANULADO: "#DC2626",
});

// La versión evita que una caché anterior del navegador conserve una descarga
// interrumpida de la cartografía publicada en GitHub Pages.
const MAP_DATA_URL =
  "./assets/geo/guanajuato-municipios.geojson?v=6.2.0";

const MAP_LOAD_TIMEOUT_MS = 12000;

const MAP_METRICS = Object.freeze({
  total_registros: {
    label: "Registros",
    hint: "Expedientes visibles en los filtros actuales",
  },
  validados: {
    label: "Validados",
    hint: "Expedientes validados dentro del alcance RLS",
  },
  pendientes: {
    label: "Pendientes",
    hint: "Expedientes que aún requieren resolución",
  },
  beneficiarios: {
    label: "Beneficiarios",
    hint: "Beneficiarios capturados en registros no anulados",
  },
  participantes: {
    label: "Participantes",
    hint: "Participantes capturados en registros no anulados",
  },
  accesos: {
    label: "Accesos",
    hint: "Accesos capturados en registros no anulados",
  },
});

const MONTHS = Object.freeze([
  "Ene", "Feb", "Mar", "Abr", "May", "Jun",
  "Jul", "Ago", "Sep", "Oct", "Nov", "Dic",
]);

function numeric(value) {
  const parsed = Number(value ?? 0);
  return Number.isFinite(parsed) ? parsed : 0;
}

function formatNumber(value, maximumFractionDigits = 0) {
  return new Intl.NumberFormat("es-MX", {
    maximumFractionDigits,
  }).format(numeric(value));
}

function formatPercent(value) {
  if (value === null || value === undefined) return "—";
  return `${formatNumber(value, 2)}%`;
}

function formatDateTime(value) {
  const date = value ? new Date(value) : new Date();

  if (Number.isNaN(date.getTime())) return "—";

  return new Intl.DateTimeFormat("es-MX", {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(date);
}

function labelStatus(value) {
  return String(value ?? "SIN_ESTADO")
    .replaceAll("_", " ");
}

function setText(element, value, fallback = "—") {
  if (!element) return;
  const normalized = String(value ?? "").trim();
  element.textContent = normalized || fallback;
}

function throwIfError(result, label) {
  if (!result.error) return result.data ?? [];

  const error = new Error(
    `${label}: ${result.error.message ?? "error de Data API"}`
  );
  error.cause = result.error;
  throw error;
}

function option(value, label) {
  const element = document.createElement("option");
  element.value = value ?? "";
  element.textContent = label;
  return element;
}

function fillSelect(
  element,
  rows,
  {
    placeholder,
    valueKey = "id",
    label = (row) => row.nombre,
    selected = "",
  }
) {
  element.replaceChildren();
  element.appendChild(option("", placeholder));

  for (const row of rows) {
    element.appendChild(
      option(row[valueKey], label(row))
    );
  }

  element.value = rows.some(
    (row) => String(row[valueKey]) === String(selected)
  ) ? String(selected) : "";
}

function allowedByScope(rows, scopeIds, key) {
  if (isAdmin(context) || !scopeIds.length) {
    return rows;
  }

  const allowed = new Set(scopeIds);
  return rows.filter((row) => allowed.has(row[key]));
}

async function loadCatalogs() {
  const [unitsResult, programsResult, municipalitiesResult] =
    await Promise.all([
      dbV2()
        .from("cat_unidades_operativas")
        .select("id,clave,nombre,orden")
        .eq("activo", true)
        .order("orden", { ascending: true })
        .order("nombre", { ascending: true }),

      dbV2()
        .from("cat_programas")
        .select("id,unidad_operativa_id,clave,nombre,orden")
        .eq("activo", true)
        .order("orden", { ascending: true })
        .order("nombre", { ascending: true }),

      dbV2()
        .from("cat_municipios")
        .select("id,clave_inegi,nombre_oficial,region_id,orden")
        .eq("activo", true)
        .order("nombre_oficial", { ascending: true }),
    ]);

  const units = throwIfError(
    unitsResult,
    "cat_unidades_operativas"
  );
  const programs = throwIfError(
    programsResult,
    "cat_programas"
  );
  const municipalities = throwIfError(
    municipalitiesResult,
    "cat_municipios"
  );

  const visibleUnits = allowedByScope(
    units,
    context?.scopes?.unitIds ?? [],
    "id"
  );

  const visibleMunicipalities = allowedByScope(
    municipalities,
    context?.scopes?.municipalityIds ?? [],
    "id"
  );

  const visibleUnitIds = new Set(
    visibleUnits.map((row) => row.id)
  );

  catalogState = {
    units: visibleUnits,
    programs: programs.filter(
      (row) =>
        isAdmin(context) ||
        !context?.scopes?.unitIds?.length ||
        visibleUnitIds.has(row.unidad_operativa_id)
    ),
    municipalities: visibleMunicipalities,
  };

  fillSelect(ui.unit, catalogState.units, {
    placeholder: "Todas las unidades visibles",
    label: (row) => `${row.clave} · ${row.nombre}`,
  });

  fillSelect(ui.municipality, catalogState.municipalities, {
    placeholder: "Todos los municipios visibles",
    label: (row) => row.nombre_oficial,
  });

  renderPrograms();
}

function renderYears() {
  const currentYear = new Date().getFullYear();
  const years = Array.from(
    new Set([currentYear, 2026, 2025])
  ).sort((a, b) => b - a);

  ui.year.replaceChildren();

  for (const year of years) {
    ui.year.appendChild(option(String(year), String(year)));
  }

  ui.year.value = years.includes(2026)
    ? "2026"
    : String(currentYear);
}

function renderPrograms() {
  const selected = ui.program.value;
  const unitId = ui.unit.value;

  const rows = catalogState.programs.filter(
    (row) =>
      !unitId || row.unidad_operativa_id === unitId
  );

  fillSelect(ui.program, rows, {
    placeholder: "Todos los programas visibles",
    label: (row) => `${row.clave} · ${row.nombre}`,
    selected,
  });
}

function currentFilters() {
  return {
    p_anio: Number(ui.year.value) || null,
    p_unidad: ui.unit.value || null,
    p_programa: ui.program.value || null,
    p_municipio: ui.municipality.value || null,
  };
}

function resetVisuals() {
  setText(ui.kpiRecords, "…");
  setText(ui.kpiValidated, "…");
  setText(ui.kpiPending, "…");
  setText(ui.kpiObserved, "…");
  setText(ui.kpiBeneficiaries, "…");
  setText(ui.kpiParticipants, "…");
  setText(ui.kpiAccesses, "…");
  setText(ui.kpiMunicipalities, "…");
}

function setLoading(loading, message = "Actualizando datos...") {
  ui.refresh.disabled = loading;
  ui.apply.disabled = loading;
  ui.reset.disabled = loading;

  ui.status.dataset.type = loading ? "loading" : "ok";
  ui.status.textContent = message;

  if (loading) resetVisuals();
}

function renderKpis(payload) {
  const summary = payload.resumen ?? {};

  setText(
    ui.kpiRecords,
    formatNumber(summary.total_registros)
  );
  setText(
    ui.kpiValidated,
    formatNumber(summary.validados)
  );
  setText(
    ui.kpiPending,
    formatNumber(summary.pendientes_revision)
  );
  setText(
    ui.kpiObserved,
    formatNumber(summary.observados)
  );
  setText(
    ui.kpiBeneficiaries,
    formatNumber(summary.total_beneficiarios)
  );
  setText(
    ui.kpiParticipants,
    formatNumber(summary.total_participantes)
  );
  setText(
    ui.kpiAccesses,
    formatNumber(summary.total_accesos)
  );
  setText(
    ui.kpiMunicipalities,
    formatNumber(summary.municipios_con_actividad)
  );

  setText(
    ui.validationRate,
    formatPercent(summary.porcentaje_validado)
  );
  setText(
    ui.qualityCount,
    formatNumber(summary.registros_con_incidencias)
  );
  setText(
    ui.contributionCount,
    formatNumber(summary.registros_con_aporte)
  );
  setText(
    ui.historicalCount,
    formatNumber(summary.historicos_migrados)
  );
}

function renderStatus(payload) {
  const rows = payload.estatus ?? [];
  const total = rows.reduce(
    (sum, row) => sum + numeric(row.total),
    0
  );

  ui.statusList.replaceChildren();

  if (!total) {
    ui.statusDonut.style.background = "#E2E8F0";
    ui.statusDonutValue.textContent = "0";

    const empty = document.createElement("p");
    empty.className = "dashboard-empty";
    empty.textContent = "No hay registros para los filtros seleccionados.";
    ui.statusList.appendChild(empty);
    return;
  }

  let offset = 0;
  const segments = [];

  for (const row of rows) {
    const value = numeric(row.total);
    const percent = value / total * 100;
    const color = STATUS_COLORS[row.estatus] ?? "#CBD5E1";

    if (value > 0) {
      segments.push(
        `${color} ${offset}% ${offset + percent}%`
      );
      offset += percent;
    }

    const item = document.createElement("div");
    item.className = "dashboard-status-row";

    const dot = document.createElement("span");
    dot.className = "dashboard-status-dot";
    dot.style.backgroundColor = color;

    const label = document.createElement("span");
    label.className = "dashboard-status-label";
    label.textContent = labelStatus(row.estatus);

    const count = document.createElement("strong");
    count.textContent = formatNumber(value);

    const share = document.createElement("small");
    share.textContent = formatPercent(percent);

    item.append(dot, label, count, share);
    ui.statusList.appendChild(item);
  }

  ui.statusDonut.style.background =
    `conic-gradient(${segments.join(", ")})`;
  ui.statusDonutValue.textContent = formatNumber(total);
}

function indicatorScope(row) {
  if (row.alcance === "UNIDAD") {
    return row.meta_unidad_nombre || "Unidad";
  }
  if (row.alcance === "REGION") {
    return row.meta_region_nombre || "Region";
  }
  if (row.alcance === "MUNICIPIO") {
    return row.meta_municipio_nombre || "Municipio";
  }
  return "Estatal";
}

function semaforoLabel(value) {
  const labels = {
    CUMPLIDA: "Cumplida",
    EN_RUTA: "En ruta",
    REZAGO: "Con rezago",
    SIN_AVANCE: "Sin avance",
    SIN_META: "Sin meta",
    PENDIENTE_ALINEACION: "Pendiente de alineacion",
  };

  return labels[value] ?? labelStatus(value);
}

function renderIndicators(payload) {
  const rows = payload.indicadores ?? [];
  ui.indicatorBody.replaceChildren();

  if (!rows.length) {
    const tr = document.createElement("tr");
    const td = document.createElement("td");
    td.colSpan = 6;
    td.className = "dashboard-empty";
    td.textContent =
      "No existen metas activas para el ejercicio seleccionado.";
    tr.appendChild(td);
    ui.indicatorBody.appendChild(tr);
    return;
  }

  for (const row of rows) {
    const tr = document.createElement("tr");

    const indicatorTd = document.createElement("td");
    const key = document.createElement("strong");
    key.className = "dashboard-indicator-key";
    key.textContent = row.indicador_clave || "Sin clave";

    const name = document.createElement("span");
    name.className = "dashboard-indicator-name";
    name.textContent = row.indicador_nombre || row.nombre_base || "—";

    const owner = document.createElement("small");
    owner.textContent = row.indicador_unidad_nombre || "Direccion de Vinculacion";
    indicatorTd.append(key, name, owner);

    const scopeTd = document.createElement("td");
    scopeTd.textContent = indicatorScope(row);

    const measureTd = document.createElement("td");
    measureTd.textContent = row.unidad_medida_nombre || "—";

    const figuresTd = document.createElement("td");
    const figures = document.createElement("strong");
    figures.textContent =
      `${formatNumber(row.avance, 2)} / ${formatNumber(row.meta, 2)}`;
    const pending = document.createElement("small");
    pending.textContent =
      `Pendiente: ${formatNumber(row.pendiente_meta, 2)}`;
    figuresTd.append(figures, pending);

    const progressTd = document.createElement("td");
    const progress = document.createElement("div");
    progress.className = "dashboard-progress";
    const bar = document.createElement("span");
    bar.className = `dashboard-progress-bar dashboard-progress-${String(row.semaforo).toLowerCase()}`;
    bar.style.width = `${Math.min(100, Math.max(0, numeric(row.cumplimiento_pct)))}%`;
    progress.appendChild(bar);
    const percent = document.createElement("small");
    percent.textContent = formatPercent(row.cumplimiento_pct);
    progressTd.append(progress, percent);

    const statusTd = document.createElement("td");
    const badge = document.createElement("span");
    badge.className =
      `dashboard-semaphore dashboard-semaphore-${String(row.semaforo).toLowerCase()}`;
    badge.textContent = semaforoLabel(row.semaforo);
    statusTd.appendChild(badge);

    if (!row.auto_calculable) {
      const note = document.createElement("small");
      note.className = "dashboard-alignment-note";
      note.textContent = "La meta existe; no se infiere avance sin regla aprobada.";
      statusTd.appendChild(note);
    }

    tr.append(
      indicatorTd,
      scopeTd,
      measureTd,
      figuresTd,
      progressTd,
      statusTd
    );
    ui.indicatorBody.appendChild(tr);
  }
}

function renderCoverage(payload) {
  const rows = (payload.municipios ?? []).slice(0, 15);
  ui.coverageBody.replaceChildren();

  if (!rows.length) {
    const tr = document.createElement("tr");
    const td = document.createElement("td");
    td.colSpan = 6;
    td.className = "dashboard-empty";
    td.textContent = "No hay cobertura territorial para estos filtros.";
    tr.appendChild(td);
    ui.coverageBody.appendChild(tr);
    return;
  }

  for (const row of rows) {
    const tr = document.createElement("tr");
    const values = [
      row.municipio_nombre,
      row.region_nombre,
      formatNumber(row.total_registros),
      formatNumber(row.validados),
      formatNumber(row.pendientes),
      formatNumber(row.beneficiarios),
    ];

    values.forEach((value, index) => {
      const td = document.createElement("td");
      td.textContent = value || "—";
      if (index === 0) td.className = "dashboard-strong";
      tr.appendChild(td);
    });

    ui.coverageBody.appendChild(tr);
  }
}

function renderRanking(container, rows, options) {
  container.replaceChildren();

  if (!rows.length) {
    const empty = document.createElement("p");
    empty.className = "dashboard-empty";
    empty.textContent = options.empty;
    container.appendChild(empty);
    return;
  }

  const max = Math.max(
    1,
    ...rows.map((row) => numeric(row.total_registros))
  );

  for (const row of rows.slice(0, 8)) {
    const item = document.createElement("div");
    item.className = "dashboard-ranking-item";

    const header = document.createElement("div");
    header.className = "dashboard-ranking-header";

    const name = document.createElement("strong");
    name.textContent = options.name(row);

    const value = document.createElement("span");
    value.textContent = `${formatNumber(row.total_registros)} registros`;
    header.append(name, value);

    const track = document.createElement("div");
    track.className = "dashboard-ranking-track";
    const bar = document.createElement("span");
    bar.style.width =
      `${numeric(row.total_registros) / max * 100}%`;
    track.appendChild(bar);

    const detail = document.createElement("small");
    detail.textContent =
      `${formatNumber(row.validados)} validados · ${formatNumber(row.pendientes)} pendientes`;

    item.append(header, track, detail);
    container.appendChild(item);
  }
}

function renderMonths(payload) {
  const rows = payload.meses ?? [];
  ui.monthChart.replaceChildren();

  const max = Math.max(
    1,
    ...rows.map((row) => numeric(row.total_registros))
  );

  for (let index = 0; index < 12; index += 1) {
    const row = rows.find(
      (item) => numeric(item.mes) === index + 1
    ) ?? { total_registros: 0, validados: 0 };

    const item = document.createElement("div");
    item.className = "dashboard-month";
    item.title =
      `${MONTHS[index]}: ${formatNumber(row.total_registros)} registros, ` +
      `${formatNumber(row.validados)} validados`;

    const value = document.createElement("strong");
    value.textContent = formatNumber(row.total_registros);

    const bars = document.createElement("div");
    bars.className = "dashboard-month-bars";

    const totalBar = document.createElement("span");
    totalBar.className = "dashboard-month-total";
    totalBar.style.height =
      `${Math.max(3, numeric(row.total_registros) / max * 100)}%`;

    const validatedBar = document.createElement("span");
    validatedBar.className = "dashboard-month-validated";
    validatedBar.style.height =
      `${Math.max(0, numeric(row.validados) / max * 100)}%`;

    bars.append(totalBar, validatedBar);

    const label = document.createElement("small");
    label.textContent = MONTHS[index];

    item.append(value, bars, label);
    ui.monthChart.appendChild(item);
  }
}

function normalizeMapCode(value) {
  const digits = String(value ?? "").replace(/\D/g, "");
  return digits ? digits.padStart(5, "0").slice(-5) : "";
}

function mapMetricConfig() {
  const key = ui.mapMetric?.value || "total_registros";
  return {
    key,
    ...(MAP_METRICS[key] ?? MAP_METRICS.total_registros),
  };
}

function mapRowsByCode(payload) {
  return new Map(
    (payload.municipios ?? []).map((row) => [
      normalizeMapCode(row.clave_inegi),
      row,
    ])
  );
}

function visibleMunicipalityCodes() {
  return new Set(
    catalogState.municipalities.map((row) =>
      normalizeMapCode(row.clave_inegi)
    )
  );
}

function municipalityCatalogByCode(code) {
  return catalogState.municipalities.find(
    (row) => normalizeMapCode(row.clave_inegi) === code
  ) ?? null;
}

async function loadMapGeometry() {
  if (!mapGeometryPromise) {
    const controller = new AbortController();
    const timeout = window.setTimeout(
      () => controller.abort(),
      MAP_LOAD_TIMEOUT_MS
    );

    mapGeometryPromise = fetch(MAP_DATA_URL, {
      cache: "no-store",
      signal: controller.signal,
    })
      .then(async (response) => {
        if (!response.ok) {
          throw new Error(`MAP_GEOMETRY_HTTP_${response.status}`);
        }

        const geometry = await response.json();
        const features = geometry?.features ?? [];

        if (
          geometry?.type !== "FeatureCollection" ||
          features.length !== 46
        ) {
          throw new Error("MAP_GEOMETRY_INVALID");
        }

        return geometry;
      })
      .catch((error) => {
        mapGeometryPromise = null;

        if (error?.name === "AbortError") {
          throw new Error("MAP_GEOMETRY_TIMEOUT");
        }

        throw error;
      })
      .finally(() => window.clearTimeout(timeout));
  }

  return mapGeometryPromise;
}

function renderMapLegend(scale, maximum) {
  ui.mapLegend.replaceChildren();

  const levels = [0, 0.25, 0.5, 0.75, 1].map(
    (share) => Math.round(maximum * share)
  );

  for (const [index, value] of levels.entries()) {
    const item = document.createElement("span");
    item.className = "dashboard-map-legend-item";

    const swatch = document.createElement("i");
    swatch.style.backgroundColor =
      index === 0 ? "#E2E8F0" : scale(value);

    const label = document.createElement("small");
    label.textContent = formatNumber(value);

    item.append(swatch, label);
    ui.mapLegend.appendChild(item);
  }
}

function updateMapDetail(code, payload) {
  const metric = mapMetricConfig();
  const rows = mapRowsByCode(payload);
  const row = rows.get(code) ?? null;
  const feature = mapFeaturesByCode.get(code) ?? null;
  const properties = feature?.properties ?? {};
  const catalog = municipalityCatalogByCode(code);

  if (!feature || !code) {
    const summary = payload?.resumen ?? {};
    const summaryMetric = {
      total_registros: summary.total_registros,
      validados: summary.validados,
      pendientes: summary.pendientes_revision,
      beneficiarios: summary.total_beneficiarios,
      participantes: summary.total_participantes,
      accesos: summary.total_accesos,
    };

    setText(ui.mapKicker, "Resumen estatal");
    setText(ui.mapMunicipality, "Vista estatal");
    setText(
      ui.mapRegion,
      "Totales de todos los municipios dentro de los filtros actuales."
    );
    setText(ui.mapMetricLabel, metric.label);
    setText(ui.mapMetricHint, "Total estatal dentro de los filtros actuales");
    setText(ui.mapMetricValue, formatNumber(summaryMetric[metric.key]));
    setText(ui.mapValidated, formatNumber(summary.validados));
    setText(ui.mapPending, formatNumber(summary.pendientes_revision));
    setText(ui.mapBeneficiaries, formatNumber(summary.total_beneficiarios));
    setText(ui.mapParticipants, formatNumber(summary.total_participantes));
    setText(ui.mapAccesses, formatNumber(summary.total_accesos));
    setText(ui.mapCodeLabel, "Municipios con actividad");
    setText(ui.mapCode, formatNumber(summary.municipios_con_actividad));
    ui.mapFilter.disabled = true;
    refreshMapClearControl();
    return;
  }

  setText(ui.mapKicker, "Municipio seleccionado");
  setText(
    ui.mapMunicipality,
    row?.municipio_nombre ||
      properties.nombre ||
      catalog?.nombre_oficial ||
      "Municipio"
  );
  setText(
    ui.mapRegion,
    row?.region_nombre ||
      (row ? "Región no registrada" : "Sin actividad en los filtros actuales")
  );
  setText(ui.mapMetricLabel, metric.label);
  setText(ui.mapMetricHint, metric.hint);
  setText(ui.mapMetricValue, formatNumber(row?.[metric.key]));
  setText(ui.mapValidated, formatNumber(row?.validados));
  setText(ui.mapPending, formatNumber(row?.pendientes));
  setText(ui.mapBeneficiaries, formatNumber(row?.beneficiarios));
  setText(ui.mapParticipants, formatNumber(row?.participantes));
  setText(ui.mapAccesses, formatNumber(row?.accesos));
  setText(ui.mapCodeLabel, "CVEGEO");
  setText(ui.mapCode, code);

  ui.mapFilter.disabled = !catalog;
  refreshMapClearControl();
}

function refreshMapClearControl() {
  const hasMunicipalityFilter = Boolean(ui.municipality.value);
  const hasMapSelection = Boolean(selectedMapCode);
  const shouldShow = hasMunicipalityFilter || hasMapSelection;

  ui.mapClear.hidden = !shouldShow;
  ui.mapClear.disabled = !shouldShow;
  ui.mapClear.textContent = hasMunicipalityFilter
    ? "Mostrar todos los municipios"
    : "Quitar selección del mapa";
}

function selectMapMunicipality(code, payload) {
  selectedMapCode = normalizeMapCode(code);

  window.d3
    .select(ui.mapSvg)
    .selectAll(".dashboard-map-municipality")
    .classed(
      "is-selected",
      function markSelected() {
        return this.dataset.code === selectedMapCode;
      }
    );

  updateMapDetail(selectedMapCode, payload);
}

function clearMapSelection(payload) {
  selectedMapCode = null;

  if (window.d3 && ui.mapSvg) {
    window.d3
      .select(ui.mapSvg)
      .selectAll(".dashboard-map-municipality")
      .classed("is-selected", false);
  }

  updateMapDetail(null, payload);
}

function defaultMapSelection(payload, visibleCodes) {
  const selectedCatalog = catalogState.municipalities.find(
    (row) => row.id === ui.municipality.value
  );
  const selectedFilterCode = normalizeMapCode(
    selectedCatalog?.clave_inegi
  );

  if (selectedFilterCode && visibleCodes.has(selectedFilterCode)) {
    return selectedFilterCode;
  }

  if (selectedMapCode && visibleCodes.has(selectedMapCode)) {
    return selectedMapCode;
  }

  // La vista sin filtro es estatal: no se selecciona arbitrariamente el
  // primer municipio ni se convierte el clic de detalle en un filtro.
  return null;
}

function showMapError(error) {
  console.error("Mapa territorial V2:", error);
  ui.mapSvg.setAttribute("hidden", "");
  ui.mapLoading.hidden = false;
  ui.mapLoading.textContent =
    "No se pudo cargar la cartografía municipal. El resto del dashboard continúa disponible.";
  ui.mapFilter.disabled = true;
}

async function renderMap(payload) {
  const sequence = ++mapRenderSequence;
  ui.mapLoading.hidden = false;
  ui.mapLoading.textContent = "Preparando cartografía municipal...";

  if (!window.d3) {
    throw new Error("D3_NOT_AVAILABLE");
  }

  const geometry = await loadMapGeometry();
  if (sequence !== mapRenderSequence) return;

  const d3 = window.d3;
  const rows = mapRowsByCode(payload);
  const visibleCodes = visibleMunicipalityCodes();
  const metric = mapMetricConfig();

  mapFeaturesByCode = new Map(
    geometry.features.map((feature) => [
      normalizeMapCode(feature.properties?.cvegeo),
      feature,
    ])
  );

  const values = geometry.features
    .map((feature) => {
      const code = normalizeMapCode(feature.properties?.cvegeo);
      return visibleCodes.has(code)
        ? numeric(rows.get(code)?.[metric.key])
        : 0;
    });
  const maximum = Math.max(1, ...values);

  const scale = d3
    .scaleSequentialSqrt(
      d3.interpolateRgbBasis([
        "#DDF7F4",
        "#74DBD4",
        "#14C3BA",
        "#087C91",
        "#081F34",
      ])
    )
    .domain([0, maximum]);

  const projection = d3
    .geoMercator()
    .fitExtent([[24, 22], [736, 498]], geometry);
  const path = d3.geoPath(projection);
  const svg = d3.select(ui.mapSvg);

  svg.selectAll("*").remove();

  const municipalities = svg
    .append("g")
    .attr("aria-hidden", "true")
    .selectAll("path")
    .data(geometry.features)
    .join("path")
    .attr("class", "dashboard-map-municipality")
    .attr("data-code", (feature) =>
      normalizeMapCode(feature.properties?.cvegeo)
    )
    .attr("d", path)
    .classed("is-out-of-scope", (feature) => {
      const code = normalizeMapCode(feature.properties?.cvegeo);
      return !visibleCodes.has(code);
    })
    .attr("fill", (feature) => {
      const code = normalizeMapCode(feature.properties?.cvegeo);
      if (!visibleCodes.has(code)) return "#F8FAFC";

      const value = numeric(rows.get(code)?.[metric.key]);
      return value > 0 ? scale(value) : "#E2E8F0";
    })
    .on("click", function selectMunicipality(event, feature) {
      const code = normalizeMapCode(feature.properties?.cvegeo);
      if (!visibleCodes.has(code)) return;
      selectMapMunicipality(code, payload);
    });

  municipalities
    .append("title")
    .text((feature) => {
      const code = normalizeMapCode(feature.properties?.cvegeo);
      const name = feature.properties?.nombre || code;

      if (!visibleCodes.has(code)) {
        return `${name}: fuera del alcance visible`;
      }

      return `${name}: ${formatNumber(rows.get(code)?.[metric.key])} ${metric.label.toLowerCase()}`;
    });

  renderMapLegend(scale, maximum);

  const nextSelection = defaultMapSelection(payload, visibleCodes);
  if (nextSelection) {
    selectMapMunicipality(nextSelection, payload);
  } else {
    clearMapSelection(payload);
  }

  ui.mapLoading.hidden = true;
  ui.mapSvg.removeAttribute("hidden");
}

function renderDashboard(payload) {
  lastPayload = payload;
  renderKpis(payload);
  renderStatus(payload);
  renderIndicators(payload);
  renderCoverage(payload);
  renderRanking(ui.unitRanking, payload.unidades ?? [], {
    empty: "No hay unidades con actividad para estos filtros.",
    name: (row) => row.unidad_clave || row.unidad_nombre,
  });
  renderRanking(ui.programRanking, payload.programas ?? [], {
    empty: "No hay programas con actividad para estos filtros.",
    name: (row) => row.programa_nombre || row.programa_clave,
  });
  renderMonths(payload);
  renderMap(payload).catch(showMapError);

  ui.status.dataset.type = "ok";
  ui.status.textContent =
    `Datos actualizados · ejercicio ${payload.ejercicio ?? ui.year.value}`;
  ui.updated.textContent =
    `Ultima consulta: ${formatDateTime(payload.generado_at)}`;
}

async function loadDashboard() {
  const sequence = ++loadSequence;
  setLoading(true);

  try {
    const { data, error } = await dbV2().rpc(
      "rpc_dashboard_directivo",
      currentFilters()
    );

    if (error) throw error;
    if (sequence !== loadSequence) return;

    const payload = Array.isArray(data) ? data[0] : data;

    if (!payload || typeof payload !== "object") {
      throw new Error("DASHBOARD_EMPTY_RESPONSE");
    }

    renderDashboard(payload);
  } catch (error) {
    if (sequence !== loadSequence) return;

    console.error("Dashboard Directivo V2:", error);
    ui.status.dataset.type = "error";
    ui.status.textContent =
      "No fue posible consultar los indicadores. Actualiza el panel o inténtalo nuevamente.";

    await Swal.fire({
      icon: "error",
      title: "Panel no disponible",
      text:
        error?.message === "DASHBOARD_EMPTY_RESPONSE"
          ? "No se recibió información válida para mostrar."
          : "No se pudieron consultar los indicadores. Inténtalo nuevamente y, si continúa, repórtalo mediante PULSO Q.",
    });
  } finally {
    if (sequence === loadSequence) {
      ui.refresh.disabled = false;
      ui.apply.disabled = false;
      ui.reset.disabled = false;
    }
  }
}

function bindUi() {
  Object.assign(ui, {
    form: $("dashboardFilters"),
    year: $("dashboardYear"),
    unit: $("dashboardUnit"),
    program: $("dashboardProgram"),
    municipality: $("dashboardMunicipality"),
    apply: $("dashboardApplyButton"),
    reset: $("dashboardResetButton"),
    refresh: $("dashboardRefreshButton"),
    status: $("dashboardStatus"),
    updated: $("dashboardUpdated"),

    kpiRecords: $("dashboardKpiRecords"),
    kpiValidated: $("dashboardKpiValidated"),
    kpiPending: $("dashboardKpiPending"),
    kpiObserved: $("dashboardKpiObserved"),
    kpiBeneficiaries: $("dashboardKpiBeneficiaries"),
    kpiParticipants: $("dashboardKpiParticipants"),
    kpiAccesses: $("dashboardKpiAccesses"),
    kpiMunicipalities: $("dashboardKpiMunicipalities"),

    validationRate: $("dashboardValidationRate"),
    qualityCount: $("dashboardQualityCount"),
    contributionCount: $("dashboardContributionCount"),
    historicalCount: $("dashboardHistoricalCount"),

    statusDonut: $("dashboardStatusDonut"),
    statusDonutValue: $("dashboardStatusDonutValue"),
    statusList: $("dashboardStatusList"),
    mapMetric: $("dashboardMapMetric"),
    mapSvg: $("dashboardMapSvg"),
    mapLoading: $("dashboardMapLoading"),
    mapKicker: $("dashboardMapKicker"),
    mapMunicipality: $("dashboardMapMunicipality"),
    mapRegion: $("dashboardMapRegion"),
    mapMetricLabel: $("dashboardMapMetricLabel"),
    mapMetricValue: $("dashboardMapMetricValue"),
    mapMetricHint: $("dashboardMapMetricHint"),
    mapValidated: $("dashboardMapValidated"),
    mapPending: $("dashboardMapPending"),
    mapBeneficiaries: $("dashboardMapBeneficiaries"),
    mapParticipants: $("dashboardMapParticipants"),
    mapAccesses: $("dashboardMapAccesses"),
    mapCodeLabel: $("dashboardMapCodeLabel"),
    mapCode: $("dashboardMapCode"),
    mapFilter: $("dashboardMapFilterButton"),
    mapClear: $("dashboardMapClearButton"),
    mapLegend: $("dashboardMapLegend"),
    indicatorBody: $("dashboardIndicatorBody"),
    coverageBody: $("dashboardCoverageBody"),
    unitRanking: $("dashboardUnitRanking"),
    programRanking: $("dashboardProgramRanking"),
    monthChart: $("dashboardMonthChart"),
  });
}

function bindEvents() {
  ui.form.addEventListener("submit", (event) => {
    event.preventDefault();
    loadDashboard();
  });

  ui.unit.addEventListener("change", () => {
    renderPrograms();
  });

  ui.reset.addEventListener("click", () => {
    ui.unit.value = "";
    ui.municipality.value = "";
    selectedMapCode = null;
    renderPrograms();
    ui.program.value = "";
    ui.year.value = "2026";
    loadDashboard();
  });

  ui.refresh.addEventListener("click", () => {
    loadDashboard();
  });

  ui.mapMetric.addEventListener("change", () => {
    if (!lastPayload) return;
    renderMap(lastPayload).catch(showMapError);
  });

  ui.mapFilter.addEventListener("click", () => {
    const municipality = municipalityCatalogByCode(
      selectedMapCode
    );

    if (!municipality) return;

    ui.municipality.value = municipality.id;
    loadDashboard();
  });

  ui.mapClear.addEventListener("click", () => {
    if (ui.municipality.value) {
      ui.municipality.value = "";
      selectedMapCode = null;
      loadDashboard();
      return;
    }

    if (lastPayload) clearMapSelection(lastPayload);
  });
}

export async function initDashboardV2(authContext) {
  context = authContext;

  if (!can(context, PERMISSIONS.DASHBOARD_VIEW_SCOPE)) {
    return;
  }

  if (!initialized) {
    bindUi();
    renderYears();
    bindEvents();
    initialized = true;
  }

  await loadCatalogs();
  await loadDashboard();
}

export async function refreshDashboardV2() {
  if (!initialized || !context) return;
  await loadDashboard();
}
