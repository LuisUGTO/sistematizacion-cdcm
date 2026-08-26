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

function renderDashboard(payload) {
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
      "No se pudo cargar el Dashboard Directivo: " +
      (error?.message ?? "error desconocido");

    await Swal.fire({
      icon: "error",
      title: "Dashboard no disponible",
      text:
        error?.message === "DASHBOARD_EMPTY_RESPONSE"
          ? "La RPC no devolvio un resultado valido."
          : error?.message ?? "No se pudieron consultar los indicadores.",
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
    renderPrograms();
    ui.program.value = "";
    ui.year.value = "2026";
    loadDashboard();
  });

  ui.refresh.addEventListener("click", () => {
    loadDashboard();
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
