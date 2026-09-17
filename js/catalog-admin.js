/**
 * VINCULACION CULTURAL 2.0
 * catalog-admin.js - Etapa 7.2.1
 * Gestion administrativa de programas, acciones, comunidades y espacios.
 */

import { dbV2 } from "./supabase-client.js";
import { loadAuthContext } from "./auth.js";
import { isAdmin } from "./permissions.js";

const state = {
  units: [], municipalities: [], settlementTypes: [], spaceTypes: [],
  recordTypes: [], programs: [], actions: [], configurations: [],
  communities: [], spaces: [],
};

const $ = (id) => document.getElementById(id);
const byId = (items, id) => items.find((item) => item.id === id);
const clean = (value) => String(value ?? "").trim();
const normalized = (value) => clean(value).normalize("NFD")
  .replace(/[\u0300-\u036f]/g, "").toLowerCase();
const nullable = (value) => clean(value) || null;
const numberOrNull = (value) => clean(value) === "" ? null : Number(value);

function friendlyError(error) {
  return String(error?.message ?? error ?? "Error no identificado")
    .replace(/^[A-Z_]+:\s*/i, "")
    .replace(/duplicate key value violates unique constraint[^.]*/i,
      "Ya existe un elemento con esa clave o nombre en la misma clasificación")
    .trim();
}

async function showError(title, error) {
  console.error(title, error);
  await Swal.fire({ icon: "error", title, text: friendlyError(error) });
}

function fillSelect(select, items, label, options = {}) {
  if (!select) return;
  const previous = select.value;
  select.replaceChildren();
  if (options.placeholder !== false) {
    const option = document.createElement("option");
    option.value = "";
    option.textContent = options.placeholder ?? "Seleccione…";
    select.appendChild(option);
  }
  items.forEach((item) => {
    const option = document.createElement("option");
    option.value = item.id;
    option.textContent = label(item);
    select.appendChild(option);
  });
  if ([...select.options].some((option) => option.value === previous)) {
    select.value = previous;
  }
}

function fillMunicipalitySelects() {
  const label = (item) => item.nombre_oficial;
  fillSelect($("communityMunicipality"), state.municipalities, label);
  fillSelect($("spaceMunicipality"), state.municipalities, label);
  fillSelect($("communityMunicipalityFilter"), state.municipalities, label,
    { placeholder: "Todos los municipios" });
  fillSelect($("spaceMunicipalityFilter"), state.municipalities, label,
    { placeholder: "Todos los municipios" });
}

function fillUnitSelects() {
  const label = (item) => `${item.clave} · ${item.nombre}`;
  fillSelect($("programUnit"), state.units, label);
  fillSelect($("actionUnit"), state.units, label);
  fillSelect($("spaceUnit"), state.units, label,
    { placeholder: "Sin unidad específica" });
  fillSelect($("programUnitFilter"), state.units, label,
    { placeholder: "Todas las unidades" });
  fillSelect($("actionUnitFilter"), state.units, label,
    { placeholder: "Todas las unidades" });
}

function fillStaticSelects() {
  fillSelect($("communityType"), state.settlementTypes,
    (item) => item.nombre, { placeholder: "Sin especificar" });
  fillSelect($("spaceType"), state.spaceTypes, (item) => item.nombre);
  fillSelect($("actionRecordType"), state.recordTypes,
    (item) => `${item.clave} · ${item.nombre}`);
}

function refreshActionPrograms(selected = "") {
  const unitId = $("actionUnit").value;
  fillSelect(
    $("actionProgram"),
    state.programs.filter((item) => item.unidad_operativa_id === unitId),
    (item) => `${item.clave} · ${item.nombre}`,
    { placeholder: unitId ? "Seleccione programa…" : "Seleccione primero una unidad" }
  );
  if (selected) $("actionProgram").value = selected;
}

function refreshSpaceCommunities(selected = "") {
  const municipalityId = $("spaceMunicipality").value;
  fillSelect(
    $("spaceCommunity"),
    state.communities.filter((item) => item.municipio_id === municipalityId && item.activo),
    (item) => item.nombre,
    { placeholder: "Sin comunidad" }
  );
  if (selected) $("spaceCommunity").value = selected;
}

function statusMatches(item, filterId) {
  const filter = $(filterId).value;
  return filter === "ALL" || (filter === "ACTIVE" ? item.activo : !item.activo);
}

function makeStatus(active) {
  const status = document.createElement("span");
  status.className = `catalog-status ${active ? "active" : "inactive"}`;
  status.textContent = active ? "Activo" : "Inactivo";
  return status;
}

function makeActions(kind, item, editHandler) {
  const container = document.createElement("div");
  container.className = "catalog-table-actions";
  const edit = document.createElement("button");
  edit.type = "button";
  edit.className = "button button-secondary";
  edit.textContent = "Editar";
  edit.addEventListener("click", () => editHandler(item));
  const toggle = document.createElement("button");
  toggle.type = "button";
  toggle.className = item.activo ? "button button-danger" : "button button-quiet";
  toggle.textContent = item.activo ? "Desactivar" : "Reactivar";
  toggle.addEventListener("click", () => toggleStatus(kind, item));
  container.append(edit, toggle);
  return container;
}

function setRow(tbody, values, actions) {
  const row = tbody.insertRow();
  values.forEach((value) => {
    const cell = row.insertCell();
    if (value instanceof Node) cell.appendChild(value);
    else cell.textContent = value ?? "—";
  });
  row.insertCell().appendChild(actions);
}

function renderCommunities() {
  const tbody = $("communityTable");
  tbody.replaceChildren();
  const query = normalized($("communitySearch").value);
  const municipalityId = $("communityMunicipalityFilter").value;
  const items = state.communities.filter((item) =>
    (!query || normalized(item.nombre).includes(query) || normalized(item.clave).includes(query)) &&
    (!municipalityId || item.municipio_id === municipalityId) &&
    statusMatches(item, "communityStatusFilter")
  );
  if (!items.length) return emptyRow(tbody, 5);
  items.forEach((item) => setRow(tbody, [
    byId(state.municipalities, item.municipio_id)?.nombre_oficial,
    item.nombre,
    byId(state.settlementTypes, item.tipo_asentamiento_id)?.nombre ?? "Sin especificar",
    makeStatus(item.activo),
  ], makeActions("COMUNIDAD", item, editCommunity)));
}

function renderSpaces() {
  const tbody = $("spaceTable");
  tbody.replaceChildren();
  const query = normalized($("spaceSearch").value);
  const municipalityId = $("spaceMunicipalityFilter").value;
  const items = state.spaces.filter((item) =>
    (!query || normalized(item.nombre).includes(query) || normalized(item.direccion).includes(query)) &&
    (!municipalityId || item.municipio_id === municipalityId) &&
    statusMatches(item, "spaceStatusFilter")
  );
  if (!items.length) return emptyRow(tbody, 5);
  items.forEach((item) => {
    const type = byId(state.spaceTypes, item.tipo_espacio_id)?.nombre ?? "Sin tipo";
    const community = byId(state.communities, item.comunidad_id)?.nombre;
    setRow(tbody, [
      byId(state.municipalities, item.municipio_id)?.nombre_oficial,
      item.nombre,
      community ? `${type} · ${community}` : type,
      makeStatus(item.activo),
    ], makeActions("ESPACIO", item, editSpace));
  });
}

function renderPrograms() {
  const tbody = $("programTable");
  tbody.replaceChildren();
  const query = normalized($("programSearch").value);
  const unitId = $("programUnitFilter").value;
  const items = state.programs.filter((item) =>
    (!query || normalized(item.nombre).includes(query) || normalized(item.clave).includes(query)) &&
    (!unitId || item.unidad_operativa_id === unitId) &&
    statusMatches(item, "programStatusFilter")
  );
  if (!items.length) return emptyRow(tbody, 5);
  items.forEach((item) => setRow(tbody, [
    byId(state.units, item.unidad_operativa_id)?.nombre,
    item.clave,
    item.nombre,
    makeStatus(item.activo),
  ], makeActions("PROGRAMA", item, editProgram)));
}

function latestConfiguration(actionId) {
  return state.configurations
    .filter((item) => item.accion_id === actionId)
    .sort((a, b) => String(b.vigente_desde).localeCompare(String(a.vigente_desde)))[0] ?? null;
}

function renderActions() {
  const tbody = $("actionTable");
  tbody.replaceChildren();
  const query = normalized($("actionSearch").value);
  const unitId = $("actionUnitFilter").value;
  const items = state.actions.filter((item) =>
    (!query || normalized(item.nombre).includes(query) || normalized(item.clave).includes(query)) &&
    (!unitId || item.unidad_operativa_id === unitId) &&
    statusMatches(item, "actionStatusFilter")
  );
  if (!items.length) return emptyRow(tbody, 5);
  items.forEach((item) => {
    const program = byId(state.programs, item.programa_id);
    const config = latestConfiguration(item.id);
    setRow(tbody, [
      `${byId(state.units, item.unidad_operativa_id)?.nombre ?? "—"} · ${program?.nombre ?? "Sin programa"}`,
      item.clave,
      config ? `${item.nombre} · ${config.tipo_formulario}` : `${item.nombre} · Sin configuración`,
      makeStatus(item.activo && Boolean(config?.activo)),
    ], makeActions("ACCION", item, editAction));
  });
}

function emptyRow(tbody, colspan) {
  const row = tbody.insertRow();
  const cell = row.insertCell();
  cell.colSpan = colspan;
  cell.className = "empty";
  cell.textContent = "No hay elementos que coincidan con los filtros.";
}

function renderAll() {
  renderCommunities(); renderSpaces(); renderPrograms(); renderActions();
}

function showCancel(formId, visible) {
  document.querySelector(`[data-form="${formId}"]`).hidden = !visible;
}

function resetForm(formId) {
  const form = $(formId);
  form.reset();
  form.querySelector('input[type="hidden"]').value = "";
  showCancel(formId, false);
  if (formId === "actionForm") {
    $("actionReqResponsible").checked = true;
    $("actionReqEvidence").checked = true;
    $("actionReqValidation").checked = true;
    $("actionValidFrom").value = `${new Date().getFullYear()}-01-01`;
    refreshActionPrograms();
  }
  if (formId === "spaceForm") refreshSpaceCommunities();
}

function editCommunity(item) {
  $("communityId").value = item.id;
  $("communityMunicipality").value = item.municipio_id;
  $("communityType").value = item.tipo_asentamiento_id ?? "";
  $("communityCode").value = item.clave ?? "";
  $("communityName").value = item.nombre;
  $("communityLatitude").value = item.latitud ?? "";
  $("communityLongitude").value = item.longitud ?? "";
  showCancel("communityForm", true); $("communityName").focus();
}

function editSpace(item) {
  $("spaceId").value = item.id;
  $("spaceMunicipality").value = item.municipio_id;
  refreshSpaceCommunities(item.comunidad_id);
  $("spaceType").value = item.tipo_espacio_id;
  $("spaceUnit").value = item.unidad_operativa_id ?? "";
  $("spaceCode").value = item.clave ?? "";
  $("spaceName").value = item.nombre;
  $("spaceAddress").value = item.direccion ?? "";
  $("spaceLatitude").value = item.latitud ?? "";
  $("spaceLongitude").value = item.longitud ?? "";
  showCancel("spaceForm", true); $("spaceName").focus();
}

function editProgram(item) {
  $("programId").value = item.id;
  $("programUnit").value = item.unidad_operativa_id;
  $("programCode").value = item.clave;
  $("programName").value = item.nombre;
  $("programDescription").value = item.descripcion ?? "";
  $("programOrder").value = item.orden ?? 0;
  showCancel("programForm", true); $("programName").focus();
}

function editAction(item) {
  const config = latestConfiguration(item.id);
  if (!config) {
    Swal.fire("Configuración faltante", "Completa la configuración para que esta acción aparezca en Captura.", "info");
  }
  $("actionId").value = item.id;
  $("actionUnit").value = item.unidad_operativa_id;
  refreshActionPrograms(item.programa_id);
  $("actionCode").value = item.clave;
  $("actionName").value = item.nombre;
  $("actionDescription").value = item.descripcion ?? "";
  $("actionOrder").value = item.orden ?? 0;
  if (config) {
    $("actionRecordType").value = config.tipo_registro_id;
    $("actionFormType").value = config.tipo_formulario;
    $("actionValidFrom").value = config.vigente_desde;
    $("actionValidUntil").value = config.vigente_hasta ?? "";
    $("actionReqCommunity").checked = config.requiere_comunidad;
    $("actionReqSpace").checked = config.requiere_espacio;
    $("actionReqResponsible").checked = config.requiere_responsable;
    $("actionReqTeacher").checked = config.requiere_docente;
    $("actionReqBeneficiaries").checked = config.requiere_beneficiarios;
    $("actionReqDemography").checked = config.requiere_demografia;
    $("actionReqGps").checked = config.requiere_gps;
    $("actionReqEvidence").checked = config.requiere_evidencia;
    $("actionReqValidation").checked = config.requiere_validacion;
  }
  showCancel("actionForm", true); $("actionName").focus();
}

async function toggleStatus(kind, item) {
  const activate = !item.activo;
  const decision = await Swal.fire({
    icon: activate ? "question" : "warning",
    title: activate ? "¿Reactivar elemento?" : "¿Desactivar elemento?",
    text: activate
      ? "Volverá a estar disponible para nuevas capturas."
      : "Dejará de aparecer en nuevas capturas, pero conservará su historial.",
    showCancelButton: true,
    confirmButtonText: activate ? "Reactivar" : "Desactivar",
    cancelButtonText: "Cancelar",
    confirmButtonColor: activate ? "#004b87" : "#c2413b",
  });
  if (!decision.isConfirmed) return;
  const { error } = await dbV2().rpc("rpc_admin_cambiar_estado_catalogo", {
    p_catalogo: kind, p_id: item.id, p_activo: activate,
  });
  if (error) return showError("No se pudo cambiar el estado", error);
  await loadOperationalCatalogs();
}

async function saveCommunity(event) {
  event.preventDefault();
  const current = byId(state.communities, $("communityId").value);
  const { error } = await dbV2().rpc("rpc_admin_guardar_comunidad", {
    p_id: nullable($("communityId").value),
    p_municipio_id: $("communityMunicipality").value,
    p_tipo_asentamiento_id: nullable($("communityType").value),
    p_clave: nullable($("communityCode").value),
    p_nombre: clean($("communityName").value),
    p_latitud: numberOrNull($("communityLatitude").value),
    p_longitud: numberOrNull($("communityLongitude").value),
    p_activo: current?.activo ?? true,
  });
  if (error) return showError("No se pudo guardar la comunidad", error);
  resetForm("communityForm"); await saved("Comunidad guardada");
}

async function saveSpace(event) {
  event.preventDefault();
  const current = byId(state.spaces, $("spaceId").value);
  const { error } = await dbV2().rpc("rpc_admin_guardar_espacio", {
    p_id: nullable($("spaceId").value),
    p_tipo_espacio_id: $("spaceType").value,
    p_unidad_operativa_id: nullable($("spaceUnit").value),
    p_municipio_id: $("spaceMunicipality").value,
    p_comunidad_id: nullable($("spaceCommunity").value),
    p_clave: nullable($("spaceCode").value),
    p_nombre: clean($("spaceName").value),
    p_direccion: nullable($("spaceAddress").value),
    p_latitud: numberOrNull($("spaceLatitude").value),
    p_longitud: numberOrNull($("spaceLongitude").value),
    p_activo: current?.activo ?? true,
  });
  if (error) return showError("No se pudo guardar el espacio", error);
  resetForm("spaceForm"); await saved("Espacio guardado");
}

async function saveProgram(event) {
  event.preventDefault();
  const current = byId(state.programs, $("programId").value);
  const { error } = await dbV2().rpc("rpc_admin_guardar_programa", {
    p_id: nullable($("programId").value),
    p_unidad_operativa_id: $("programUnit").value,
    p_clave: clean($("programCode").value),
    p_nombre: clean($("programName").value),
    p_descripcion: nullable($("programDescription").value),
    p_orden: Number($("programOrder").value || 0),
    p_activo: current?.activo ?? true,
  });
  if (error) return showError("No se pudo guardar el programa", error);
  resetForm("programForm"); await saved("Programa guardado");
}

async function saveAction(event) {
  event.preventDefault();
  const current = byId(state.actions, $("actionId").value);
  const recordType = byId(state.recordTypes, $("actionRecordType").value);
  const { error } = await dbV2().rpc("rpc_admin_guardar_accion", {
    p_id: nullable($("actionId").value),
    p_unidad_operativa_id: $("actionUnit").value,
    p_programa_id: $("actionProgram").value,
    p_clave: clean($("actionCode").value),
    p_nombre: clean($("actionName").value),
    p_descripcion: nullable($("actionDescription").value),
    p_orden: Number($("actionOrder").value || 0),
    p_activo: current?.activo ?? true,
    p_tipo_registro_clave: recordType?.clave ?? "",
    p_tipo_formulario: $("actionFormType").value,
    p_vigente_desde: $("actionValidFrom").value,
    p_vigente_hasta: nullable($("actionValidUntil").value),
    p_requiere_comunidad: $("actionReqCommunity").checked,
    p_requiere_espacio: $("actionReqSpace").checked,
    p_requiere_responsable: $("actionReqResponsible").checked,
    p_requiere_docente: $("actionReqTeacher").checked,
    p_requiere_beneficiarios: $("actionReqBeneficiaries").checked,
    p_requiere_demografia: $("actionReqDemography").checked,
    p_requiere_gps: $("actionReqGps").checked,
    p_requiere_evidencia: $("actionReqEvidence").checked,
    p_requiere_validacion: $("actionReqValidation").checked,
  });
  if (error) return showError("No se pudo guardar la acción", error);
  resetForm("actionForm"); await saved("Acción y configuración guardadas");
}

async function saved(title) {
  await loadOperationalCatalogs();
  await Swal.fire({ icon: "success", title, timer: 1400, showConfirmButton: false });
}

async function query(table, columns, orders = []) {
  let request = dbV2().from(table).select(columns);
  orders.forEach((column) => { request = request.order(column); });
  const { data, error } = await request;
  if (error) throw error;
  return data ?? [];
}

async function loadOperationalCatalogs() {
  const results = await Promise.all([
    query("cat_unidades_operativas", "id,clave,nombre,orden,activo", ["orden", "nombre"]),
    query("cat_municipios", "id,clave_inegi,nombre_oficial,orden,activo", ["orden", "nombre_oficial"]),
    query("cat_tipos_asentamiento", "id,clave,nombre,orden,activo", ["orden", "nombre"]),
    query("cat_tipos_espacio", "id,clave,nombre,orden,activo", ["orden", "nombre"]),
    query("cat_tipos_registro", "id,clave,nombre,orden,activo", ["orden", "nombre"]),
    query("cat_programas", "id,unidad_operativa_id,clave,nombre,descripcion,orden,activo", ["orden", "nombre"]),
    query("cat_acciones", "id,unidad_operativa_id,programa_id,clave,nombre,descripcion,orden,activo", ["orden", "nombre"]),
    query("configuracion_acciones", "id,accion_id,tipo_registro_id,tipo_formulario,requiere_comunidad,requiere_espacio,requiere_responsable,requiere_docente,requiere_beneficiarios,requiere_demografia,requiere_gps,requiere_evidencia,requiere_validacion,vigente_desde,vigente_hasta,activo", ["vigente_desde"]),
    query("cat_comunidades", "id,municipio_id,tipo_asentamiento_id,clave,nombre,latitud,longitud,activo", ["nombre"]),
    query("cat_espacios", "id,tipo_espacio_id,unidad_operativa_id,municipio_id,comunidad_id,clave,nombre,direccion,latitud,longitud,activo", ["nombre"]),
  ]);
  [state.units, state.municipalities, state.settlementTypes, state.spaceTypes,
    state.recordTypes, state.programs, state.actions, state.configurations,
    state.communities, state.spaces] = results;
  fillMunicipalitySelects(); fillUnitSelects(); fillStaticSelects();
  refreshActionPrograms(); refreshSpaceCommunities(); renderAll();
}

function installEvents() {
  document.querySelectorAll(".catalog-switch").forEach((button) => {
    button.addEventListener("click", () => {
      document.querySelectorAll(".catalog-switch").forEach((item) =>
        item.setAttribute("aria-selected", String(item === button)));
      document.querySelectorAll(".catalog-view").forEach((view) =>
        view.classList.toggle("active", view.id === `catalog-${button.dataset.catalog}`));
    });
  });
  $("communityForm").addEventListener("submit", saveCommunity);
  $("spaceForm").addEventListener("submit", saveSpace);
  $("programForm").addEventListener("submit", saveProgram);
  $("actionForm").addEventListener("submit", saveAction);
  $("spaceMunicipality").addEventListener("change", () => refreshSpaceCommunities());
  $("actionUnit").addEventListener("change", () => refreshActionPrograms());
  $("catalogRefresh").addEventListener("click", async () => {
    try { await loadOperationalCatalogs(); }
    catch (error) { await showError("No se pudieron actualizar los catálogos", error); }
  });
  document.querySelectorAll(".catalog-cancel").forEach((button) =>
    button.addEventListener("click", () => resetForm(button.dataset.form)));
  ["communitySearch", "communityMunicipalityFilter", "communityStatusFilter"]
    .forEach((id) => $(id).addEventListener("input", renderCommunities));
  ["spaceSearch", "spaceMunicipalityFilter", "spaceStatusFilter"]
    .forEach((id) => $(id).addEventListener("input", renderSpaces));
  ["programSearch", "programUnitFilter", "programStatusFilter"]
    .forEach((id) => $(id).addEventListener("input", renderPrograms));
  ["actionSearch", "actionUnitFilter", "actionStatusFilter"]
    .forEach((id) => $(id).addEventListener("input", renderActions));
}

async function initializeCatalogAdmin() {
  if (!$("panel-catalogs")) return;
  try {
    const context = await loadAuthContext();
    if (!context || !isAdmin(context)) return;
    installEvents();
    resetForm("actionForm");
    await loadOperationalCatalogs();
  } catch (error) {
    await showError("Catálogos operativos no disponibles", error);
  }
}

initializeCatalogAdmin();
