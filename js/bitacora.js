/**
 * VINCULACIÓN CULTURAL 2.0
 * bitacora.js
 *
 * Bitácora V2 con paginación de servidor.
 * No usa select('*') y respeta RLS mediante vw_registros_operativos.
 * Etapa 6.5.6: conserva filtros por usuario entre recargas y cambios de foco.
 */

import { dbV2 } from "./supabase-client.js";
import {
  loadOperationalUnits,
  loadMunicipalities,
} from "./catalogs.js";

import {
  PERMISSIONS,
  can,
  isAdmin,
} from "./permissions.js";

import {
  initializeImporter,
} from "./importer.js";

const PAGE_SIZE = 25;
const FILTER_STORAGE_PREFIX = "v2.bitacora.filters";

let context = null;
let initialized = false;
let importerInitialized = false;

let state = {
  page: 0,
  total: 0,
  rows: [],
  selectedIds: new Set(),
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

  td.colSpan = 9;
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

    const selectionTd = document.createElement("td");
    selectionTd.className = "bitacora-selection-cell";
    selectionTd.hidden = !isAdmin(context);

    const selection = document.createElement("input");
    selection.type = "checkbox";
    selection.className = "bitacora-row-select";
    selection.value = row.id;
    selection.checked = state.selectedIds.has(row.id);
    selection.disabled = row.origen === "MIGRACION_V1";
    selection.setAttribute(
      "aria-label",
      `Seleccionar ${text(row.folio, row.nombre)}`
    );
    selection.addEventListener("change", () => {
      if (selection.checked) state.selectedIds.add(row.id);
      else state.selectedIds.delete(row.id);
      updateSelectionToolbar();
    });
    selectionTd.appendChild(selection);

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
    actionTd.className = "bitacora-actions";

    const viewButton =
      document.createElement("button");

    viewButton.type = "button";
    viewButton.className =
      "bitacora-view-button";

    viewButton.textContent = "Ver";

    viewButton.addEventListener(
      "click",
      () => showDetail(row)
    );

    actionTd.appendChild(
      viewButton
    );

    const editableOperational =
      ["MANUAL", "IMPORTACION_EXCEL"].includes(row.origen) &&
      ["BORRADOR", "OBSERVADO", "CORREGIDO"]
        .includes(row.estatus) &&
      can(
        context,
        PERMISSIONS.CAPTURE_EDIT_OWN
      );

    if (editableOperational) {
      const editButton =
        document.createElement("button");

      editButton.type = "button";
      editButton.className =
        "bitacora-edit-button";

      editButton.textContent =
        row.estatus === "BORRADOR"
          ? "Completar"
          : "Corregir";

      editButton.addEventListener(
        "click",
        () => {
          window.dispatchEvent(
            new CustomEvent(
              "v2:edit-record",
              {
                detail: {
                  id: row.id,
                },
              }
            )
          );
        }
      );

      actionTd.appendChild(
        editButton
      );
    }

    const removableRecord =
      row.origen !== "MIGRACION_V1" &&
      can(context, PERMISSIONS.RECORD_RETIRE);

    if (removableRecord) {
      const retireButton =
        document.createElement("button");

      retireButton.type = "button";
      retireButton.className =
        "bitacora-retire-button";

      retireButton.textContent = "Retirar";

      retireButton.addEventListener(
        "click",
        () => retireRecords([row])
      );

      actionTd.appendChild(retireButton);
    }

    tr.append(
      selectionTd,
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

  updateSelectionToolbar();
}

function updateSelectionToolbar() {
  if (!ui.selectionBar) return;

  const selectedCount = state.selectedIds.size;
  ui.selectionCount.textContent =
    `${selectedCount} registro(s) seleccionado(s)`;
  ui.retireSelected.disabled = selectedCount === 0;

  const selectableRows = state.rows.filter(
    (row) => row.origen !== "MIGRACION_V1"
  );
  ui.selectPage.checked =
    selectableRows.length > 0 &&
    selectableRows.every((row) => state.selectedIds.has(row.id));
  ui.selectPage.indeterminate =
    !ui.selectPage.checked &&
    selectableRows.some((row) => state.selectedIds.has(row.id));
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

function filterStorageKey() {
  const userId = context?.user?.id;
  return userId
    ? `${FILTER_STORAGE_PREFIX}:${userId}`
    : null;
}

function readStoredFilters() {
  const key = filterStorageKey();
  if (!key) return {};

  try {
    const saved = JSON.parse(localStorage.getItem(key) ?? "{}");
    return saved && typeof saved === "object" ? saved : {};
  } catch (error) {
    console.warn("Bitácora V2: no se pudieron leer los filtros guardados.", error);
    return {};
  }
}

function persistFilters(filters = getFilters()) {
  const key = filterStorageKey();
  if (!key) return;

  try {
    localStorage.setItem(key, JSON.stringify({
      search: String(filters.search ?? ""),
      status: String(filters.status ?? ""),
      unitId: String(filters.unitId ?? ""),
      municipalityId: String(filters.municipalityId ?? ""),
      year: String(filters.year ?? ""),
    }));
  } catch (error) {
    console.warn("Bitácora V2: no se pudieron guardar los filtros.", error);
  }
}

function restoreSelectValue(element, value) {
  const normalized = String(value ?? "");
  const exists = [...element.options].some(
    (option) => option.value === normalized
  );
  element.value = exists ? normalized : "";
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

  const pageIds = new Set(state.rows.map((row) => row.id));
  state.selectedIds = new Set(
    [...state.selectedIds].filter((id) => pageIds.has(id))
  );

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
  persistFilters();
  state.page = 0;
  refresh();
}

async function retireRecords(rows) {
  const ids = rows.map((row) => row.id);
  if (!ids.length) return;

  try {
    const previewResult = await dbV2().rpc(
      "rpc_admin_previsualizar_retiro",
      { p_registro_ids: ids }
    );

    if (previewResult.error) throw previewResult.error;

    const preview = previewResult.data ?? [];
    const blocked = preview.filter((item) => !item.puede_retirar);

    if (blocked.length) {
      await Swal.fire({
        icon: "warning",
        title: "La selección contiene registros protegidos",
        text: blocked.map((item) =>
          `${item.folio}: ${item.motivo_bloqueo}`
        ).join(" · "),
      });
      return;
    }

    const total = preview.length;
    if (!total) {
      throw new Error("No se encontraron registros disponibles para retirar.");
    }

    const expected = total === 1
      ? "RETIRAR 1 REGISTRO"
      : `RETIRAR ${total} REGISTROS`;
    const confirmation = await Swal.fire({
      icon: "warning",
      title: total === 1
        ? "Retirar registro"
        : `Retirar ${total} registros`,
      html: `
        <p style="text-align:left;line-height:1.55">
          Dejarán de aparecer en Bitácora y Dashboard, pero conservarán
          historial y auditoría. MIGRACION_V1 nunca puede retirarse aquí.
        </p>
        <label for="cleanupReason" style="display:block;text-align:left;font-weight:700;margin:12px 0 5px">Motivo</label>
        <textarea id="cleanupReason" class="swal2-textarea" style="margin:0;width:100%" placeholder="Ejemplo: registros generados durante pruebas de capacitación"></textarea>
        <label for="cleanupConfirmation" style="display:block;text-align:left;font-weight:700;margin:12px 0 5px">Escribe ${expected}</label>
        <input id="cleanupConfirmation" class="swal2-input" style="margin:0;width:100%" autocomplete="off">
      `,
      showCancelButton: true,
      confirmButtonText: "Retirar de la operación",
      confirmButtonColor: "#B91C1C",
      cancelButtonText: "Cancelar",
      reverseButtons: true,
      preConfirm: () => {
        const reason = document.getElementById("cleanupReason")?.value.trim() ?? "";
        const typed = document.getElementById("cleanupConfirmation")?.value.trim().toUpperCase() ?? "";
        if (reason.length < 12) {
          Swal.showValidationMessage("Documenta el motivo con al menos 12 caracteres.");
          return false;
        }
        if (typed !== expected) {
          Swal.showValidationMessage(`Escribe exactamente ${expected}.`);
          return false;
        }
        return { reason, typed };
      },
    });

    if (!confirmation.isConfirmed) return;

    const { data, error } = await dbV2().rpc(
      "rpc_admin_retirar_registros",
      {
        p_registro_ids: ids,
        p_confirmacion: confirmation.value.typed,
        p_motivo: confirmation.value.reason,
      }
    );

    if (error) throw error;

    const retired = Array.isArray(data) ? data[0] : data;

    await Swal.fire({
      icon: "success",
      title: total === 1 ? "Registro retirado" : "Registros retirados",
      text:
        `${retired?.total_retirados ?? total} registro(s) fueron anulados y retirados de las vistas operativas.`,
    });

    state.selectedIds.clear();

    window.dispatchEvent(
      new CustomEvent("v2:record-updated")
    );
  } catch (error) {
    console.error("Retiro administrativo V2:", error);

    await Swal.fire({
      icon: "error",
      title: "No se pudo retirar el registro",
      text:
        error?.message ??
        "Ocurrió un error al procesar el retiro administrativo.",
    });
  }
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
  const previousFilters = getFilters();

  const [units, municipalities] =
    await Promise.all([
      loadOperationalUnits(context),
      loadMunicipalities(context),
    ]);

  // Se consulta después de esperar los catálogos para conservar cualquier
  // cambio hecho por la persona mientras la red terminaba de responder.
  const storedFilters = readStoredFilters();
  const preferredFilters = {
    ...previousFilters,
    ...storedFilters,
  };

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

  if (!previousFilters.year && !("year" in storedFilters)) {
    preferredFilters.year = String(currentYear);
  }

  ui.search.value = String(preferredFilters.search ?? "");
  restoreSelectValue(ui.status, preferredFilters.status);
  restoreSelectValue(ui.unit, preferredFilters.unitId);
  restoreSelectValue(ui.municipality, preferredFilters.municipalityId);
  restoreSelectValue(ui.year, preferredFilters.year);
  persistFilters();

  return { units, municipalities };
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

    selectionHeader: $("bitacoraSelectionHeader"),
    selectionBar: $("bitacoraSelectionBar"),
    selectPage: $("bitacoraSelectPage"),
    selectionCount: $("bitacoraSelectionCount"),
    retireSelected: $("bitacoraRetireSelected"),

    importToggle: $("bitacoraImportToggle"),
    importWorkspace: $("bitacoraImportWorkspace"),
    importClose: $("bitacoraImportClose"),
  });

  if (!ui.body) {
    throw new Error(
      "BITACORA_V2_TABLE_NOT_FOUND"
    );
  }

  if (!initialized) {
    const searchChanged =
      debounce(filtersChanged);

    ui.search.addEventListener("input", () => {
      persistFilters();
      searchChanged();
    });

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

    ui.selectPage?.addEventListener("change", () => {
      state.rows
        .filter((row) => row.origen !== "MIGRACION_V1")
        .forEach((row) => {
          if (ui.selectPage.checked) state.selectedIds.add(row.id);
          else state.selectedIds.delete(row.id);
        });
      renderRows(state.rows);
    });

    ui.retireSelected?.addEventListener("click", () => {
      const selectedRows = state.rows.filter((row) =>
        state.selectedIds.has(row.id)
      );
      retireRecords(selectedRows);
    });

    ui.importToggle?.addEventListener("click", () => {
      ui.importWorkspace.hidden = false;
      ui.importToggle.setAttribute("aria-expanded", "true");
      ui.importWorkspace.scrollIntoView({ behavior: "smooth", block: "start" });
    });

    ui.importClose?.addEventListener("click", () => {
      ui.importWorkspace.hidden = true;
      ui.importToggle.setAttribute("aria-expanded", "false");
      ui.importToggle.focus();
    });

    window.addEventListener(
      "v2:record-updated",
      () => {
        refresh();
      }
    );

    initialized = true;
  }

  const catalogs = await populateFilters();

  const admin = isAdmin(context);
  ui.selectionHeader.hidden = !admin;
  ui.selectionBar.hidden = !admin;
  ui.importToggle.hidden = !admin;

  if (admin && !importerInitialized) {
    try {
      await initializeImporter({
        context,
        units: catalogs.units,
        municipalities: catalogs.municipalities,
      });
      importerInitialized = true;
    } catch (error) {
      console.error("Importador Excel en Bitácora:", error);
      const status = $("importStatus");
      if (status) {
        status.hidden = false;
        status.className = "import-status error";
        status.textContent =
          "La importación todavía no está habilitada en la base de datos. Ejecuta 12j y 12k, y actualiza la página.";
      }
    }
  }

  state.page = 0;
  await refresh();
}
