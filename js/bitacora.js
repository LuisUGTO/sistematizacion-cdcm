/**
 * VINCULACIÓN CULTURAL 2.0
 * bitacora.js
 *
 * Bitácora V2 con paginación de servidor.
 * No usa select('*') y respeta RLS mediante vw_registros_operativos.
 */

import { dbV2 } from "./supabase-client.js";
import {
  loadOperationalUnits,
  loadMunicipalities,
} from "./catalogs.js";

const PAGE_SIZE = 25;

let context = null;
let initialized = false;

let state = {
  page: 0,
  total: 0,
  rows: [],
};

const ui = {};

const $ = (id) => document.getElementById(id);

function text(value, fallback = "—") {
  const normalized = String(value ?? "").trim();
  return normalized || fallback;
}

function formatDate(value) {
  if (!value) return "—";

  const date = new Date(`${value}T12:00:00`);

  if (Number.isNaN(date.getTime())) {
    return value;
  }

  return new Intl.DateTimeFormat(
    "es-MX",
    {
      year: "numeric",
      month: "short",
      day: "2-digit",
    }
  ).format(date);
}

function formatDateTime(value) {
  if (!value) return "—";

  const date = new Date(value);

  if (Number.isNaN(date.getTime())) {
    return value;
  }

  return new Intl.DateTimeFormat(
    "es-MX",
    {
      dateStyle: "medium",
      timeStyle: "short",
    }
  ).format(date);
}

function fillSelect(
  element,
  rows,
  {
    placeholder,
    valueKey = "id",
    labelKey = "nombre",
  }
) {
  element.replaceChildren();

  const empty = document.createElement("option");
  empty.value = "";
  empty.textContent = placeholder;
  element.appendChild(empty);

  for (const row of rows) {
    const option = document.createElement("option");
    option.value = row[valueKey];
    option.textContent = row[labelKey];
    element.appendChild(option);
  }
}

function badgeStatus(status) {
  const value = text(status, "SIN_ESTADO");
  const span = document.createElement("span");

  span.className =
    `bitacora-status bitacora-status-${value.toLowerCase()}`;

  span.textContent = value.replaceAll("_", " ");

  return span;
}

function clearTable() {
  ui.body.replaceChildren();
}

function renderEmpty(message) {
  clearTable();

  const tr = document.createElement("tr");
  const td = document.createElement("td");

  td.colSpan = 8;
  td.className = "bitacora-empty";
  td.textContent = message;

  tr.appendChild(td);
  ui.body.appendChild(tr);
}

function renderRows(rows) {
  clearTable();

  if (!rows.length) {
    renderEmpty(
      "No hay registros que coincidan con los filtros."
    );
    return;
  }

  for (const row of rows) {
    const tr = document.createElement("tr");

    const folioTd = document.createElement("td");
    const folio = document.createElement("strong");
    folio.className = "bitacora-folio";
    folio.textContent = text(row.folio);

    const origin = document.createElement("small");
    origin.textContent =
      row.legacy_folio
        ? `Legado: ${row.legacy_folio}`
        : text(row.origen);

    folioTd.append(folio, origin);

    const dateTd = document.createElement("td");
    dateTd.textContent = formatDate(row.fecha_inicio);

    const locationTd = document.createElement("td");
    const muni = document.createElement("strong");
    muni.textContent = text(
      row.municipio_nombre,
      "Sin municipio"
    );

    const place = document.createElement("small");
    place.textContent = text(
      row.espacio_nombre ||
        row.comunidad_nombre ||
        row.region_nombre,
      "Sin sede catalogada"
    );

    locationTd.append(muni, place);

    const activityTd = document.createElement("td");
    const activity = document.createElement("strong");
    activity.textContent = text(row.nombre);

    const action = document.createElement("small");
    action.textContent =
      `${text(row.accion_clave)} · ${text(row.accion_nombre)}`;

    activityTd.append(activity, action);

    const unitTd = document.createElement("td");
    const unit = document.createElement("strong");
    unit.textContent = text(row.unidad_clave);

    const program = document.createElement("small");
    program.textContent = text(
      row.programa_nombre,
      "Sin programa"
    );

    unitTd.append(unit, program);

    const beneficiariesTd =
      document.createElement("td");

    beneficiariesTd.className =
      "bitacora-number";

    beneficiariesTd.textContent =
      row.total_beneficiarios === null ||
      row.total_beneficiarios === undefined
        ? "—"
        : Number(
            row.total_beneficiarios
          ).toLocaleString("es-MX");

    const statusTd = document.createElement("td");
    statusTd.appendChild(
      badgeStatus(row.estatus)
    );

    const actionTd = document.createElement("td");
    const button = document.createElement("button");

    button.type = "button";
    button.className = "bitacora-view-button";
    button.textContent = "Ver";

    button.addEventListener(
      "click",
      () => showDetail(row)
    );

    actionTd.appendChild(button);

    tr.append(
      folioTd,
      dateTd,
      locationTd,
      activityTd,
      unitTd,
      beneficiariesTd,
      statusTd,
      actionTd
    );

    ui.body.appendChild(tr);
  }
}

function renderPagination() {
  const start =
    state.total === 0
      ? 0
      : state.page * PAGE_SIZE + 1;

  const end = Math.min(
    state.total,
    (state.page + 1) * PAGE_SIZE
  );

  ui.range.textContent =
    `${start}-${end} de ${state.total}`;

  ui.prev.disabled = state.page <= 0;

  ui.next.disabled =
    (state.page + 1) * PAGE_SIZE >= state.total;
}

function setLoading(loading) {
  ui.refresh.disabled = loading;
  ui.prev.disabled = loading || state.page <= 0;
  ui.next.disabled = loading;

  ui.refresh.textContent =
    loading ? "Cargando..." : "Actualizar";

  if (loading) {
    renderEmpty(
      "Cargando registros desde V2..."
    );
  }
}

function getFilters() {
  return {
    search: ui.search.value.trim(),
    status: ui.status.value,
    unitId: ui.unit.value,
    municipalityId: ui.municipality.value,
    year: ui.year.value,
  };
}

async function fetchRows() {
  const {
    search,
    status,
    unitId,
    municipalityId,
    year,
  } = getFilters();

  let query = dbV2()
    .from("vw_registros_operativos")
    .select(
      [
        "id",
        "folio",
        "unidad_operativa_id",
        "unidad_clave",
        "unidad_nombre",
        "programa_id",
        "programa_clave",
        "programa_nombre",
        "accion_id",
        "accion_clave",
        "accion_nombre",
        "tipo_registro_clave",
        "tipo_registro_nombre",
        "municipio_id",
        "municipio_nombre",
        "region_nombre",
        "comunidad_nombre",
        "espacio_nombre",
        "nombre",
        "descripcion",
        "fecha_inicio",
        "fecha_fin",
        "periodo_anio",
        "periodo_mes",
        "total_beneficiarios",
        "estatus",
        "origen",
        "created_by",
        "created_at",
        "updated_at",
        "row_version",
        "legacy_folio",
      ].join(","),
      {
        count: "exact",
      }
    );

  if (search) {
    // PostgREST aplica OR únicamente sobre estas columnas textuales.
    // Se escapan comas y paréntesis para evitar romper el filtro.
    const safeSearch = search
      .replaceAll(",", " ")
      .replaceAll("(", " ")
      .replaceAll(")", " ")
      .trim();

    if (safeSearch) {
      query = query.or(
        [
          `folio.ilike.%${safeSearch}%`,
          `nombre.ilike.%${safeSearch}%`,
          `accion_nombre.ilike.%${safeSearch}%`,
          `municipio_nombre.ilike.%${safeSearch}%`,
        ].join(",")
      );
    }
  }

  if (status) {
    query = query.eq("estatus", status);
  }

  if (unitId) {
    query = query.eq(
      "unidad_operativa_id",
      unitId
    );
  }

  if (municipalityId) {
    query = query.eq(
      "municipio_id",
      municipalityId
    );
  }

  if (year) {
    query = query.eq(
      "periodo_anio",
      Number(year)
    );
  }

  const from = state.page * PAGE_SIZE;
  const to = from + PAGE_SIZE - 1;

  const { data, error, count } =
    await query
      .order(
        "created_at",
        {
          ascending: false,
        }
      )
      .range(from, to);

  if (error) {
    throw error;
  }

  state.rows = data ?? [];
  state.total = count ?? 0;

  renderRows(state.rows);
  renderPagination();

  ui.kpiTotal.textContent =
    state.total.toLocaleString("es-MX");

  const drafts =
    state.rows.filter(
      (row) => row.estatus === "BORRADOR"
    ).length;

  ui.kpiDrafts.textContent =
    drafts.toLocaleString("es-MX");

  const visibleMunicipalities =
    new Set(
      state.rows
        .map((row) => row.municipio_id)
        .filter(Boolean)
    ).size;

  ui.kpiMunicipalities.textContent =
    visibleMunicipalities.toLocaleString(
      "es-MX"
    );
}

async function refresh() {
  setLoading(true);

  try {
    await fetchRows();
  } catch (error) {
    console.error(
      "Bitácora V2:",
      error
    );

    renderEmpty(
      `No se pudo cargar la bitácora: ${
        error?.message ??
        "error desconocido"
      }`
    );
  } finally {
    setLoading(false);
    renderPagination();
  }
}

function debounce(fn, wait = 350) {
  let timer = null;

  return (...args) => {
    clearTimeout(timer);

    timer = setTimeout(
      () => fn(...args),
      wait
    );
  };
}

function filtersChanged() {
  state.page = 0;
  refresh();
}

function showDetail(row) {
  const content = document.createElement("div");
  content.className =
    "bitacora-detail-grid";

  const fields = [
    ["Folio", row.folio],
    ["Estado", row.estatus],
    ["Origen", row.origen],
    ["Fecha", formatDate(row.fecha_inicio)],
    ["Unidad", row.unidad_nombre],
    ["Programa", row.programa_nombre],
    ["Acción", row.accion_nombre],
    ["Tipo", row.tipo_registro_nombre],
    ["Municipio", row.municipio_nombre],
    ["Región", row.region_nombre],
    ["Espacio", row.espacio_nombre],
    ["Actividad", row.nombre],
    ["Descripción", row.descripcion],
    [
      "Beneficiarios",
      row.total_beneficiarios === null
        ? "No informado"
        : Number(
            row.total_beneficiarios
          ).toLocaleString("es-MX"),
    ],
    [
      "Actualizado",
      formatDateTime(row.updated_at),
    ],
    ["Folio V1", row.legacy_folio],
  ];

  for (const [label, value] of fields) {
    const item = document.createElement("div");
    item.className =
      "bitacora-detail-item";

    const dt = document.createElement("strong");
    dt.textContent = label;

    const dd = document.createElement("span");
    dd.textContent = text(value);

    item.append(dt, dd);
    content.appendChild(item);
  }

  Swal.fire({
    title: text(row.folio, "Registro V2"),
    html: content,
    width: 820,
    confirmButtonText: "Cerrar",
  });
}

async function populateFilters() {
  const [units, municipalities] =
    await Promise.all([
      loadOperationalUnits(context),
      loadMunicipalities(context),
    ]);

  fillSelect(
    ui.unit,
    units,
    {
      placeholder: "Todas las unidades",
      labelKey: "nombre",
    }
  );

  fillSelect(
    ui.municipality,
    municipalities,
    {
      placeholder: "Todos los municipios",
      labelKey: "nombre_oficial",
    }
  );

  const currentYear =
    new Date().getFullYear();

  const years = [];

  for (
    let year = currentYear;
    year >= 2025;
    year -= 1
  ) {
    years.push({
      id: String(year),
      nombre: String(year),
    });
  }

  fillSelect(
    ui.year,
    years,
    {
      placeholder: "Todos los años",
    }
  );

  ui.year.value =
    String(currentYear);
}

export async function initBitacoraV2(
  authContext
) {
  context = authContext;

  Object.assign(ui, {
    search: $("bitacoraSearch"),
    status: $("bitacoraStatus"),
    unit: $("bitacoraUnit"),
    municipality:
      $("bitacoraMunicipality"),
    year: $("bitacoraYear"),

    refresh: $("bitacoraRefresh"),
    body: $("bitacoraBody"),

    prev: $("bitacoraPrev"),
    next: $("bitacoraNext"),
    range: $("bitacoraRange"),

    kpiTotal: $("bitacoraKpiTotal"),
    kpiDrafts:
      $("bitacoraKpiDrafts"),
    kpiMunicipalities:
      $("bitacoraKpiMunicipalities"),
  });

  if (!ui.body) {
    throw new Error(
      "BITACORA_V2_TABLE_NOT_FOUND"
    );
  }

  if (!initialized) {
    const searchChanged =
      debounce(filtersChanged);

    ui.search.addEventListener(
      "input",
      searchChanged
    );

    [
      ui.status,
      ui.unit,
      ui.municipality,
      ui.year,
    ].forEach((element) => {
      element.addEventListener(
        "change",
        filtersChanged
      );
    });

    ui.refresh.addEventListener(
      "click",
      refresh
    );

    ui.prev.addEventListener(
      "click",
      () => {
        if (state.page <= 0) return;

        state.page -= 1;
        refresh();
      }
    );

    ui.next.addEventListener(
      "click",
      () => {
        if (
          (state.page + 1) * PAGE_SIZE >=
          state.total
        ) {
          return;
        }

        state.page += 1;
        refresh();
      }
    );

    initialized = true;
  }

  await populateFilters();
  state.page = 0;
  await refresh();
}
