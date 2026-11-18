/**
 * VINCULACIÓN CULTURAL — projects-admin.js
 * Catálogo administrativo de proyectos (colaborativos de circuito/regionales y
 * socioculturales 3390), con municipios participantes y gestores asignados.
 * Tablas: v2.cat_proyectos, v2.proyecto_municipios, v2.proyecto_gestores.
 * RLS: solo ADMIN escribe; la interfaz no sustituye la autorización del servidor.
 */

import { dbV2 } from "./supabase-client.js";
import { loadAuthContext } from "./auth.js";
import { isAdmin } from "./permissions.js";

const TIPOS = Object.freeze({
  COLABORATIVO_CIRCUITO: "Colaborativo · Circuito cultural",
  COLABORATIVO_REGIONAL: "Colaborativo · Regional",
  SOCIOCULTURAL_3390: "Sociocultural 3390 (gestores)",
});

const state = {
  projects: [],
  municipalities: [],
  regions: [],
  profiles: [],
  links: new Map(), // proyecto_id -> { municipios:Set, gestores:Set }
  editingId: "",
};

const $ = (id) => document.getElementById(id);
const clean = (v) => String(v ?? "").trim();
const nullable = (v) => clean(v) || null;

function friendly(error) {
  return String(error?.message ?? error ?? "Error no identificado")
    .replace(/duplicate key value violates unique constraint[^.]*/i,
      "Ya existe un proyecto con ese nombre en el mismo tipo")
    .replace(/row-level security[^.]*/i, "No tienes permiso para esta acción")
    .trim();
}

async function fail(title, error) {
  console.error(title, error);
  await Swal.fire({ icon: "error", title, text: friendly(error) });
}

function el(tag, props = {}, ...children) {
  const node = document.createElement(tag);
  Object.assign(node, props);
  for (const child of children) {
    node.append(child instanceof Node ? child : document.createTextNode(child));
  }
  return node;
}

function buildPanel() {
  const panel = $("panel-projects");
  panel.replaceChildren();
  panel.innerHTML = `
    <article class="card">
      <div class="card-heading"><div>
        <h2>Proyectos colaborativos y 3390</h2>
        <p>Cada proyecto se da de alta una sola vez. Los municipios eligen proyectos colaborativos en su captura; los gestores del 3390 reportan sesiones y evidencias desde su propio módulo. Los proyectos con historial se desactivan, no se eliminan.</p>
      </div><button id="projectRefresh" class="button button-secondary" type="button">Actualizar</button></div>

      <form id="projectForm" class="catalog-form">
        <input id="projectId" type="hidden" />
        <div><label for="projectType">Tipo de proyecto</label><select id="projectType" class="control" required></select></div>
        <div class="span-2"><label for="projectName">Nombre del proyecto</label><input id="projectName" class="control" maxlength="200" required /></div>
        <div><label for="projectActive">Estatus</label><select id="projectActive" class="control"><option value="true">Activo</option><option value="false">Inactivo</option></select></div>
        <div id="projectCircuitBox"><label for="projectCircuit">Nombre del circuito</label><input id="projectCircuit" class="control" maxlength="160" /></div>
        <div id="projectRegionBox"><label for="projectRegion">Región</label><select id="projectRegion" class="control"></select></div>
        <div><label for="projectStart">Periodo de ejecución · inicio</label><input id="projectStart" class="control" type="date" /></div>
        <div><label for="projectEnd">Periodo de ejecución · fin</label><input id="projectEnd" class="control" type="date" /></div>
        <div class="span-2"><label for="projectDescription">Descripción general</label><textarea id="projectDescription" class="control" rows="3"></textarea></div>
        <div class="span-2"><label for="projectObjective">Objetivo</label><textarea id="projectObjective" class="control" rows="3"></textarea></div>
        <div class="span-2"><label for="projectJustification">Justificación</label><textarea id="projectJustification" class="control" rows="3"></textarea></div>
        <div class="span-2"><label for="projectGroup">Comunidad (grupo de atención)</label><textarea id="projectGroup" class="control" rows="3"></textarea></div>
        <div class="span-2"><label for="projectTopics">Disciplinas / temas</label><textarea id="projectTopics" class="control" rows="2"></textarea></div>
        <div class="span-2"><label for="projectVenues">Sedes y/o espacios</label><textarea id="projectVenues" class="control" rows="2"></textarea></div>
        <div class="span-2"><label for="projectRequirements">Requerimientos</label><textarea id="projectRequirements" class="control" rows="2"></textarea></div>
        <div class="span-2"><label for="projectResult">Resultado final (entregable)</label><textarea id="projectResult" class="control" rows="2"></textarea></div>
        <div class="span-4"><label>Municipios que participan</label>
          <input id="projectMuniSearch" class="control" type="search" placeholder="Buscar municipio…" style="margin-bottom:8px" />
          <div id="projectMuniChecks" class="check-grid"></div></div>
        <div id="projectManagersBox" class="span-4"><label>Gestores / gestoras asignados (usuarios de la plataforma)</label>
          <input id="projectManagerSearch" class="control" type="search" placeholder="Buscar persona…" style="margin-bottom:8px" />
          <div id="projectManagerChecks" class="check-grid"></div></div>
        <div class="catalog-form-actions">
          <button id="projectCancel" class="button button-quiet" type="button" hidden>Cancelar edición</button>
          <button class="button button-primary" type="submit">Guardar proyecto</button>
        </div>
      </form>

      <div class="catalog-toolbar" style="display:flex;gap:10px;margin-bottom:10px;flex-wrap:wrap">
        <select id="projectFilterType" class="control" style="max-width:280px"><option value="">Todos los tipos</option></select>
        <input id="projectSearch" class="control" type="search" placeholder="Buscar proyecto…" style="max-width:280px" />
      </div>
      <div class="table-wrap"><table><thead><tr>
        <th>Tipo</th><th>Proyecto</th><th>Municipios</th><th>Gestores</th><th>Estatus</th><th>Acciones</th>
      </tr></thead><tbody id="projectTable"><tr><td colspan="6">Cargando…</td></tr></tbody></table></div>
    </article>`;

  const typeSelect = $("projectType");
  typeSelect.append(el("option", { value: "", textContent: "Seleccione…" }));
  const filter = $("projectFilterType");
  for (const [value, label] of Object.entries(TIPOS)) {
    typeSelect.append(el("option", { value, textContent: label }));
    filter.append(el("option", { value, textContent: label }));
  }
}

function checkItem(group, value, label, checked) {
  const wrap = el("label", { className: "check-item" });
  const input = el("input", { type: "checkbox", value, checked });
  input.dataset.group = group;
  wrap.append(input, document.createTextNode(` ${label}`));
  return wrap;
}

function renderChecks(containerId, group, items, labelOf, selected, searchId) {
  const container = $(containerId);
  const term = clean($(searchId)?.value).toLowerCase();
  const previous = new Set(
    [...container.querySelectorAll("input:checked")].map((i) => i.value)
  );
  const chosen = selected ?? previous;
  container.replaceChildren();
  for (const item of items) {
    const label = labelOf(item);
    if (term && !label.toLowerCase().includes(term) && !chosen.has(item.id ?? item.user_id)) continue;
    const value = item.id ?? item.user_id;
    container.append(checkItem(group, value, label, chosen.has(value)));
  }
}

function currentSelection(containerId) {
  return new Set(
    [...$(containerId).querySelectorAll("input:checked")].map((i) => i.value)
  );
}

function updateTypeFields() {
  const type = $("projectType").value;
  $("projectCircuitBox").hidden = type !== "COLABORATIVO_CIRCUITO";
  $("projectRegionBox").hidden = type !== "COLABORATIVO_REGIONAL";
  $("projectManagersBox").hidden = type !== "SOCIOCULTURAL_3390";
}

function renderTable() {
  const tbody = $("projectTable");
  const type = $("projectFilterType").value;
  const term = clean($("projectSearch").value).toLowerCase();
  tbody.replaceChildren();

  const rows = state.projects.filter((p) =>
    (!type || p.tipo === type) && (!term || p.nombre.toLowerCase().includes(term)));

  if (!rows.length) {
    tbody.append(el("tr", {}, el("td", { colSpan: 6, textContent: "Sin proyectos para los filtros actuales." })));
    return;
  }

  for (const p of rows) {
    const links = state.links.get(p.id) ?? { municipios: new Set(), gestores: new Set() };
    const edit = el("button", { className: "button button-secondary", type: "button", textContent: "Editar" });
    edit.addEventListener("click", () => editProject(p));
    const toggle = el("button", {
      className: "button button-quiet", type: "button",
      textContent: p.activo ? "Desactivar" : "Activar",
    });
    toggle.addEventListener("click", () => toggleProject(p));
    tbody.append(el("tr", {},
      el("td", { textContent: TIPOS[p.tipo] ?? p.tipo }),
      el("td", { textContent: p.nombre }),
      el("td", { textContent: String(links.municipios.size) }),
      el("td", { textContent: p.tipo === "SOCIOCULTURAL_3390" ? String(links.gestores.size) : "—" }),
      el("td", { textContent: p.activo ? "Activo" : "Inactivo" }),
      el("td", {}, edit, " ", toggle)));
  }
}

function resetForm() {
  $("projectForm").reset();
  $("projectId").value = "";
  state.editingId = "";
  $("projectCancel").hidden = true;
  $("projectActive").value = "true";
  renderChecks("projectMuniChecks", "mun", state.municipalities,
    (m) => m.nombre_oficial, new Set(), "projectMuniSearch");
  renderChecks("projectManagerChecks", "mgr", state.profiles,
    (p) => `${p.nombre || p.email} (${p.email})`, new Set(), "projectManagerSearch");
  updateTypeFields();
}

function editProject(p) {
  state.editingId = p.id;
  $("projectId").value = p.id;
  $("projectType").value = p.tipo;
  $("projectName").value = p.nombre ?? "";
  $("projectActive").value = String(p.activo);
  $("projectCircuit").value = p.circuito_nombre ?? "";
  $("projectRegion").value = p.region_id ?? "";
  $("projectStart").value = p.periodo_inicio ?? "";
  $("projectEnd").value = p.periodo_fin ?? "";
  $("projectDescription").value = p.descripcion ?? "";
  $("projectObjective").value = p.objetivo ?? "";
  $("projectJustification").value = p.justificacion ?? "";
  $("projectGroup").value = p.grupo_atencion ?? "";
  $("projectTopics").value = p.disciplinas_temas ?? "";
  $("projectVenues").value = p.sedes_espacios ?? "";
  $("projectRequirements").value = p.requerimientos ?? "";
  $("projectResult").value = p.resultado_final ?? "";
  const links = state.links.get(p.id) ?? { municipios: new Set(), gestores: new Set() };
  renderChecks("projectMuniChecks", "mun", state.municipalities,
    (m) => m.nombre_oficial, new Set(links.municipios), "projectMuniSearch");
  renderChecks("projectManagerChecks", "mgr", state.profiles,
    (x) => `${x.nombre || x.email} (${x.email})`, new Set(links.gestores), "projectManagerSearch");
  updateTypeFields();
  $("projectCancel").hidden = false;
  $("projectForm").scrollIntoView({ behavior: "smooth", block: "start" });
}

async function syncLinks(table, column, projectId, desired) {
  const current = state.links.get(projectId)?.[table === "proyecto_municipios" ? "municipios" : "gestores"] ?? new Set();
  const toRemove = [...current].filter((id) => !desired.has(id));
  const toAdd = [...desired].filter((id) => !current.has(id));

  if (toRemove.length) {
    const { error } = await dbV2().from(table).delete()
      .eq("proyecto_id", projectId).in(column, toRemove);
    if (error) throw error;
  }
  if (toAdd.length) {
    const { error } = await dbV2().from(table)
      .insert(toAdd.map((id) => ({ proyecto_id: projectId, [column]: id })));
    if (error) throw error;
  }
}

async function saveProject(event) {
  event.preventDefault();
  const tipo = $("projectType").value;
  const nombre = clean($("projectName").value);
  if (!tipo || !nombre) return;

  const start = $("projectStart").value || null;
  const end = $("projectEnd").value || null;
  if (start && end && end < start) {
    await Swal.fire({ icon: "warning", title: "Revisa el periodo", text: "La fecha final no puede ser anterior a la inicial." });
    return;
  }

  const municipios = currentSelection("projectMuniChecks");
  const gestores = tipo === "SOCIOCULTURAL_3390" ? currentSelection("projectManagerChecks") : new Set();

  if (!municipios.size) {
    const answer = await Swal.fire({
      icon: "question", title: "Sin municipios participantes",
      text: "El proyecto no será visible para ningún municipio. ¿Guardar de todos modos?",
      showCancelButton: true, confirmButtonText: "Guardar", cancelButtonText: "Volver",
    });
    if (!answer.isConfirmed) return;
  }

  const payload = {
    tipo, nombre,
    descripcion: nullable($("projectDescription").value),
    objetivo: nullable($("projectObjective").value),
    justificacion: nullable($("projectJustification").value),
    grupo_atencion: nullable($("projectGroup").value),
    disciplinas_temas: nullable($("projectTopics").value),
    sedes_espacios: nullable($("projectVenues").value),
    requerimientos: nullable($("projectRequirements").value),
    resultado_final: nullable($("projectResult").value),
    periodo_inicio: start, periodo_fin: end,
    circuito_nombre: tipo === "COLABORATIVO_CIRCUITO" ? nullable($("projectCircuit").value) : null,
    region_id: tipo === "COLABORATIVO_REGIONAL" ? ($("projectRegion").value || null) : null,
    activo: $("projectActive").value === "true",
  };

  try {
    let projectId = state.editingId;
    if (projectId) {
      const { error } = await dbV2().from("cat_proyectos").update(payload).eq("id", projectId);
      if (error) throw error;
    } else {
      const { data, error } = await dbV2().from("cat_proyectos").insert(payload).select("id").single();
      if (error) throw error;
      projectId = data.id;
    }
    await syncLinks("proyecto_municipios", "municipio_id", projectId, municipios);
    await syncLinks("proyecto_gestores", "user_id", projectId, gestores);
    await loadAll();
    resetForm();
    await Swal.fire({ icon: "success", title: "Proyecto guardado", timer: 1400, showConfirmButton: false });
  } catch (error) {
    await fail("No se pudo guardar el proyecto", error);
  }
}

async function toggleProject(p) {
  const next = !p.activo;
  const answer = await Swal.fire({
    icon: "question",
    title: next ? "Activar proyecto" : "Desactivar proyecto",
    text: next
      ? "Volverá a estar disponible para captura."
      : "Dejará de ofrecerse en la captura. Los registros existentes se conservan.",
    showCancelButton: true, confirmButtonText: "Confirmar", cancelButtonText: "Cancelar",
  });
  if (!answer.isConfirmed) return;
  try {
    const { error } = await dbV2().from("cat_proyectos").update({ activo: next }).eq("id", p.id);
    if (error) throw error;
    await loadAll();
  } catch (error) {
    await fail("No se pudo cambiar el estatus", error);
  }
}

async function read(table, columns, order) {
  let request = dbV2().from(table).select(columns);
  if (order) request = request.order(order);
  const { data, error } = await request;
  if (error) throw error;
  return data ?? [];
}

async function loadAll() {
  const [projects, municipalities, regions, profiles, muni, mgr] = await Promise.all([
    read("cat_proyectos", "*", "nombre"),
    read("cat_municipios", "id,nombre_oficial", "nombre_oficial"),
    read("cat_regiones", "id,nombre", "nombre"),
    read("profiles", "user_id,nombre,email,activo,rol", "nombre"),
    read("proyecto_municipios", "proyecto_id,municipio_id"),
    read("proyecto_gestores", "proyecto_id,user_id"),
  ]);
  state.projects = projects;
  state.municipalities = municipalities;
  state.regions = regions;
  state.profiles = profiles.filter((p) => p.activo);
  state.links = new Map();
  const bucket = (id) => {
    if (!state.links.has(id)) state.links.set(id, { municipios: new Set(), gestores: new Set() });
    return state.links.get(id);
  };
  muni.forEach((r) => bucket(r.proyecto_id).municipios.add(r.municipio_id));
  mgr.forEach((r) => bucket(r.proyecto_id).gestores.add(r.user_id));

  const regionSelect = $("projectRegion");
  const keep = regionSelect.value;
  regionSelect.replaceChildren(el("option", { value: "", textContent: "Seleccione…" }));
  regions.forEach((r) => regionSelect.append(el("option", { value: r.id, textContent: r.nombre })));
  regionSelect.value = keep;

  renderChecks("projectMuniChecks", "mun", state.municipalities,
    (m) => m.nombre_oficial, state.editingId ? undefined : new Set(), "projectMuniSearch");
  renderChecks("projectManagerChecks", "mgr", state.profiles,
    (p) => `${p.nombre || p.email} (${p.email})`, state.editingId ? undefined : new Set(), "projectManagerSearch");
  renderTable();
}

async function init() {
  if (!$("panel-projects")) return;
  try {
    const context = await loadAuthContext();
    if (!context || !isAdmin(context)) return;
    buildPanel();
    $("projectForm").addEventListener("submit", saveProject);
    $("projectType").addEventListener("change", updateTypeFields);
    $("projectCancel").addEventListener("click", resetForm);
    $("projectRefresh").addEventListener("click", () => loadAll().catch((e) => fail("No se pudo actualizar", e)));
    $("projectFilterType").addEventListener("input", renderTable);
    $("projectSearch").addEventListener("input", renderTable);
    $("projectMuniSearch").addEventListener("input", () =>
      renderChecks("projectMuniChecks", "mun", state.municipalities, (m) => m.nombre_oficial, undefined, "projectMuniSearch"));
    $("projectManagerSearch").addEventListener("input", () =>
      renderChecks("projectManagerChecks", "mgr", state.profiles, (p) => `${p.nombre || p.email} (${p.email})`, undefined, "projectManagerSearch"));
    await loadAll();
    updateTypeFields();
  } catch (error) {
    await fail("Proyectos no disponibles", error);
  }
}

init();
