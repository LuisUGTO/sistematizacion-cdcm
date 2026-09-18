/** Etapa 7.3 — Directorio especializado de Bibliotecas V2. */
import { dbV2 } from "./supabase-client.js";
import { loadAuthContext } from "./auth.js";
import { isAdmin } from "./permissions.js";

const $ = (id) => document.getElementById(id);
const state = { municipalities: [], communities: [], libraries: [] };
const clean = (value) => String(value ?? "").trim();
const normalize = (value) => clean(value).normalize("NFD")
  .replace(/[\u0300-\u036f]/g, "").toLowerCase();

function friendly(error) {
  return String(error?.message ?? error ?? "Error no identificado")
    .replace(/^[A-Z_]+:\s*/i, "");
}

async function fail(title, error) {
  console.error(title, error);
  await Swal.fire({ icon: "error", title, text: friendly(error) });
}

function fill(select, rows, label, placeholder) {
  const previous = select.value;
  select.replaceChildren();
  const empty = document.createElement("option");
  empty.value = "";
  empty.textContent = placeholder;
  select.appendChild(empty);
  rows.forEach((item) => {
    const option = document.createElement("option");
    option.value = item.id;
    option.textContent = label(item);
    select.appendChild(option);
  });
  if ([...select.options].some((option) => option.value === previous)) {
    select.value = previous;
  }
}

async function loadCommunities(selected = "") {
  const municipalityId = $("libraryMunicipality").value;
  if (!municipalityId) {
    state.communities = [];
  } else {
    const { data, error } = await dbV2().from("cat_comunidades")
      .select("id,nombre").eq("municipio_id", municipalityId)
      .eq("activo", true).order("nombre");
    if (error) throw error;
    state.communities = data ?? [];
  }
  fill($("libraryCommunity"), state.communities, (item) => item.nombre,
    "Sin comunidad específica");
  if (selected) $("libraryCommunity").value = selected;
}

function resetForm() {
  $("libraryForm").reset();
  $("libraryId").value = "";
  $("libraryCancel").hidden = true;
  state.communities = [];
  fill($("libraryCommunity"), [], (item) => item.nombre,
    "Sin comunidad específica");
}

function filteredLibraries() {
  const query = normalize($("librarySearch").value);
  const municipality = $("libraryMunicipalityFilter").value;
  const status = $("libraryStatusFilter").value;
  return state.libraries.filter((item) => {
    if (municipality && item.municipio_id !== municipality) return false;
    if (status === "ACTIVE" && !item.activo) return false;
    if (status === "INACTIVE" && item.activo) return false;
    if (!query) return true;
    return normalize([
      item.municipio, item.comunidad, item.nombre, item.numero_dgb,
      item.responsable, item.correo, item.telefono,
    ].join(" ")).includes(query);
  });
}

function actionButton(label, className, handler) {
  const button = document.createElement("button");
  button.type = "button";
  button.className = `button ${className}`;
  button.textContent = label;
  button.addEventListener("click", handler);
  return button;
}

function render() {
  const rows = filteredLibraries();
  const tbody = $("libraryTable");
  tbody.replaceChildren();

  $("libraryTotal").textContent = state.libraries.length;
  $("libraryActive").textContent = state.libraries.filter((x) => x.activo).length;
  $("libraryMunicipalities").textContent = new Set(
    state.libraries.filter((x) => x.activo).map((x) => x.municipio_id)
  ).size;

  if (!rows.length) {
    const row = tbody.insertRow();
    row.insertCell().colSpan = 6;
    row.cells[0].className = "empty";
    row.cells[0].textContent = "No hay bibliotecas que coincidan con los filtros.";
    return;
  }

  rows.forEach((item) => {
    const row = tbody.insertRow();
    row.insertCell().textContent = item.comunidad
      ? `${item.municipio} · ${item.comunidad}` : item.municipio;
    const identity = row.insertCell();
    const strong = document.createElement("strong");
    strong.textContent = item.nombre;
    identity.append(strong, document.createElement("br"),
      document.createTextNode(item.numero_dgb ? `DGB ${item.numero_dgb}` : "Sin número DGB"));
    row.insertCell().textContent = [item.responsable, item.correo, item.telefono]
      .filter(Boolean).join(" · ") || "Sin responsable asignado";
    row.insertCell().textContent = item.horario || "Sin horario capturado";
    const status = row.insertCell();
    const badge = document.createElement("span");
    badge.className = `catalog-status ${item.activo ? "active" : "inactive"}`;
    badge.textContent = item.activo ? "Activa" : "Inactiva";
    status.appendChild(badge);
    const actions = row.insertCell();
    actions.className = "catalog-table-actions";
    actions.append(
      actionButton("Editar", "button-secondary", () => editLibrary(item)),
      actionButton(item.activo ? "Desactivar" : "Activar",
        item.activo ? "button-danger" : "button-quiet",
        () => toggleLibrary(item))
    );
  });
}

async function loadLibraries() {
  const { data, error } = await dbV2().rpc("rpc_admin_listar_bibliotecas");
  if (error) throw error;
  state.libraries = data ?? [];
  render();
}

async function editLibrary(item) {
  $("libraryId").value = item.espacio_id;
  $("libraryMunicipality").value = item.municipio_id;
  await loadCommunities(item.comunidad_id || "");
  $("libraryDgb").value = item.numero_dgb || "";
  $("libraryActiveInput").value = String(item.activo);
  $("libraryName").value = item.nombre || "";
  $("libraryAddress").value = item.direccion || "";
  $("libraryManager").value = item.responsable || "";
  $("libraryEmail").value = item.correo || "";
  $("libraryPhone").value = item.telefono || "";
  $("librarySchedule").value = item.horario || "";
  $("libraryCancel").hidden = false;
  $("libraryForm").scrollIntoView({ behavior: "smooth", block: "start" });
}

async function toggleLibrary(item) {
  const decision = await Swal.fire({
    icon: "question",
    title: item.activo ? "¿Desactivar biblioteca?" : "¿Activar biblioteca?",
    text: "La información histórica se conservará.",
    showCancelButton: true,
    confirmButtonText: item.activo ? "Desactivar" : "Activar",
    cancelButtonText: "Cancelar",
  });
  if (!decision.isConfirmed) return;
  const { error } = await dbV2().rpc("rpc_admin_cambiar_estado_biblioteca", {
    p_espacio_id: item.espacio_id, p_activo: !item.activo,
  });
  if (error) return fail("No se pudo cambiar el estado", error);
  await loadLibraries();
}

async function save(event) {
  event.preventDefault();
  const button = event.submitter;
  if (button) button.disabled = true;
  try {
    const { error } = await dbV2().rpc("rpc_admin_guardar_biblioteca", {
      p_espacio_id: $("libraryId").value || null,
      p_municipio_id: $("libraryMunicipality").value,
      p_comunidad_id: $("libraryCommunity").value || null,
      p_nombre: clean($("libraryName").value),
      p_direccion: clean($("libraryAddress").value) || null,
      p_numero_dgb: clean($("libraryDgb").value) || null,
      p_responsable: clean($("libraryManager").value) || null,
      p_correo: clean($("libraryEmail").value).toLowerCase() || null,
      p_telefono: clean($("libraryPhone").value) || null,
      p_horario: clean($("librarySchedule").value) || null,
      p_activo: $("libraryActiveInput").value === "true",
    });
    if (error) throw error;
    await Swal.fire({ icon: "success", title: "Biblioteca guardada", timer: 1300, showConfirmButton: false });
    resetForm();
    await loadLibraries();
  } catch (error) {
    await fail("No se pudo guardar la biblioteca", error);
  } finally {
    if (button) button.disabled = false;
  }
}

async function initialize() {
  if (!$("libraryForm")) return;
  try {
    const context = await loadAuthContext();
    if (!context || !isAdmin(context)) return;
    const { data, error } = await dbV2().from("cat_municipios")
      .select("id,nombre_oficial").eq("activo", true).order("nombre_oficial");
    if (error) throw error;
    state.municipalities = data ?? [];
    fill($("libraryMunicipality"), state.municipalities,
      (item) => item.nombre_oficial, "Seleccione municipio…");
    fill($("libraryMunicipalityFilter"), state.municipalities,
      (item) => item.nombre_oficial, "Todos los municipios");
    $("libraryMunicipality").addEventListener("change", () => loadCommunities().catch((e) => fail("No se cargaron las comunidades", e)));
    $("libraryForm").addEventListener("submit", save);
    $("libraryCancel").addEventListener("click", resetForm);
    ["librarySearch", "libraryMunicipalityFilter", "libraryStatusFilter"]
      .forEach((id) => $(id).addEventListener(id === "librarySearch" ? "input" : "change", render));
    await loadLibraries();
  } catch (error) {
    await fail("No se pudo iniciar el directorio de bibliotecas", error);
  }
}

initialize();
