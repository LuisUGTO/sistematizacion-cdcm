import { dbV2 } from "./supabase-client.js";
import { loadAuthContext, signOut, getDisplayIdentity } from "./auth.js?v=7.4.3";
import { PERMISSIONS, can, isAdmin } from "./permissions.js";

const $ = (id) => document.getElementById(id);
const MONTHS = ["Ene","Feb","Mar","Abr","May","Jun","Jul","Ago","Sep","Oct","Nov","Dic"];
const AXES = [
  ["tipo_actividad", "Tipo de actividad"],
  ["formato", "Formato"],
  ["temporalidad", "Temporalidad"],
  ["disciplina", "Disciplina"],
];

let context = null;
let payload = null;
let selectedAxis = "tipo_actividad";
let selectedMapCode = null;
let catalogs = { units: [], programs: [], municipalities: [] };

function number(value) {
  const parsed = Number(value ?? 0);
  return Number.isFinite(parsed) ? parsed : 0;
}

function fmt(value, digits = 0) {
  return new Intl.NumberFormat("es-MX", { maximumFractionDigits: digits }).format(number(value));
}

function setText(id, value, fallback = "—") {
  const element = $(id);
  if (element) element.textContent = String(value ?? "").trim() || fallback;
}

function option(value, label) {
  const item = document.createElement("option");
  item.value = value ?? "";
  item.textContent = label;
  return item;
}

function fillSelect(element, rows, placeholder, label, selected = "") {
  element.replaceChildren(option("", placeholder));
  rows.forEach((row) => element.appendChild(option(row.id, label(row))));
  element.value = rows.some((row) => row.id === selected) ? selected : "";
}

function allowed(rows, ids, key = "id") {
  if (isAdmin(context) || !ids?.length) return rows;
  const set = new Set(ids);
  return rows.filter((row) => set.has(row[key]));
}

async function loadCatalogs() {
  const [u, p, m] = await Promise.all([
    dbV2().from("cat_unidades_operativas").select("id,clave,nombre,orden").eq("activo", true).order("orden"),
    dbV2().from("cat_programas").select("id,unidad_operativa_id,clave,nombre,orden").eq("activo", true).order("orden"),
    dbV2().from("cat_municipios").select("id,clave_inegi,nombre_oficial,region_id,orden").eq("activo", true).order("nombre_oficial"),
  ]);
  for (const result of [u, p, m]) if (result.error) throw result.error;

  const units = allowed(u.data ?? [], context.scopes?.unitIds, "id");
  const unitIds = new Set(units.map((row) => row.id));
  catalogs = {
    units,
    programs: (p.data ?? []).filter((row) => isAdmin(context) || !context.scopes?.unitIds?.length || unitIds.has(row.unidad_operativa_id)),
    municipalities: allowed(m.data ?? [], context.scopes?.municipalityIds, "id"),
  };
  fillSelect($("unit"), catalogs.units, "Todas las unidades visibles", (row) => `${row.clave} · ${row.nombre}`);
  fillSelect($("municipality"), catalogs.municipalities, "Todos los municipios visibles", (row) => row.nombre_oficial);
  renderPrograms();
}

function renderPrograms() {
  const selected = $("program").value;
  const unit = $("unit").value;
  const rows = catalogs.programs.filter((row) => !unit || row.unidad_operativa_id === unit);
  fillSelect($("program"), rows, "Todos los programas visibles", (row) => `${row.clave} · ${row.nombre}`, selected);
}

function filters() {
  return {
    p_anio: Number($("year").value) || null,
    p_unidad: $("unit").value || null,
    p_programa: $("program").value || null,
    p_municipio: $("municipality").value || null,
  };
}

function setLoading(active, message = "Actualizando información estratégica…") {
  $("apply").disabled = active;
  $("clear").disabled = active;
  $("state").dataset.kind = active ? "loading" : "ok";
  $("state").textContent = message;
}

function renderKpis(data) {
  const r = data.resumen ?? {};
  setText("kRecords", fmt(r.total_registros));
  setText("kValidated", fmt(r.validados));
  setText("kBeneficiaries", fmt(r.total_beneficiarios));
  setText("kParticipants", fmt(r.total_participantes));
  setText("kAccesses", fmt(r.total_accesos));
  setText("kMunicipalities", `${fmt(r.municipios_con_actividad)} / 46`);
  setText("kValidationRate", `${fmt(r.porcentaje_validado, 1)}% del universo visible.`);
}

function renderMonths(data) {
  const container = $("months");
  container.replaceChildren();
  const rows = data.meses ?? [];
  const max = Math.max(1, ...rows.map((row) => number(row.total_registros)));
  for (let month = 1; month <= 12; month += 1) {
    const row = rows.find((item) => number(item.mes) === month) ?? {};
    const item = document.createElement("div"); item.className = "month";
    const value = document.createElement("div"); value.className = "month-value"; value.textContent = fmt(row.total_registros);
    const bars = document.createElement("div"); bars.className = "month-bars";
    const total = document.createElement("i"); total.style.height = `${Math.max(2, number(row.total_registros) / max * 100)}%`;
    const valid = document.createElement("i"); valid.className = "valid"; valid.style.height = `${Math.max(1, number(row.validados) / max * 100)}%`;
    const label = document.createElement("small"); label.textContent = MONTHS[month - 1];
    bars.append(total, valid); item.append(value, bars, label); container.appendChild(item);
  }
}

function renderRanking(container, rows, { name, subtitle = () => "", metric = "total_registros", empty = "Sin datos para los filtros seleccionados." } = {}) {
  container.replaceChildren();
  const visible = rows.slice(0, 8);
  if (!visible.length) { const e = document.createElement("div"); e.className = "empty"; e.textContent = empty; container.appendChild(e); return; }
  const max = Math.max(1, ...visible.map((row) => number(row[metric])));
  visible.forEach((row) => {
    const item = document.createElement("div"); item.className = "rank-item";
    const label = document.createElement("div"); label.className = "rank-label";
    const strong = document.createElement("strong"); strong.textContent = name(row);
    const small = document.createElement("small"); small.textContent = subtitle(row);
    label.append(strong, small);
    const track = document.createElement("div"); track.className = "track";
    const bar = document.createElement("i"); bar.style.width = `${number(row[metric]) / max * 100}%`; track.appendChild(bar);
    const value = document.createElement("div"); value.className = "rank-value"; value.textContent = fmt(row[metric]);
    item.append(label, track, value); container.appendChild(item);
  });
}

function renderProgramRanking(data) {
  renderRanking($("programRanking"), data.programas ?? [], {
    name: (row) => row.programa_nombre || row.programa_clave || "Sin programa",
    subtitle: (row) => `${fmt(row.validados)} validados`,
  });
}

function renderClassificationTabs() {
  const tabs = $("classificationTabs"); tabs.replaceChildren();
  AXES.forEach(([key, label]) => {
    const button = document.createElement("button"); button.type = "button"; button.textContent = label;
    button.classList.toggle("active", key === selectedAxis);
    button.addEventListener("click", () => { selectedAxis = key; renderClassificationTabs(); renderClassification(payload); });
    tabs.appendChild(button);
  });
}

function renderClassification(data) {
  const rows = (data?.clasificaciones ?? []).filter((row) => row.eje === selectedAxis);
  renderRanking($("classificationRanking"), rows, {
    name: (row) => row.etiqueta,
    subtitle: (row) => `${fmt(row.participantes)} participantes · ${fmt(row.accesos)} accesos`,
    metric: "registros",
  });
}

function renderActions(data) {
  renderRanking($("actionRanking"), data.acciones ?? [], {
    name: (row) => row.accion_nombre || row.accion_clave,
    subtitle: (row) => `${fmt(row.validados)} validados · ${fmt(row.beneficiarios)} beneficiarios`,
    metric: "registros",
  });
}

function renderPopulation(data) {
  const container = $("population"); container.replaceChildren();
  const rows = data.poblacion ?? [];
  const universes = [["BENEFICIARIOS","Beneficiarios"],["PARTICIPANTES","Participantes"],["ACCESOS","Accesos"]];
  universes.forEach(([key, label]) => {
    const column = document.createElement("section"); column.className = "population-column";
    const title = document.createElement("h3"); title.textContent = label; column.appendChild(title);
    const universeRows = rows.filter((row) => row.universo === key);
    if (!universeRows.length) { const e = document.createElement("div"); e.className = "empty"; e.textContent = "Sin desglose declarado."; column.appendChild(e); }
    let dimension = null;
    universeRows.slice(0, 18).forEach((row) => {
      if (dimension !== row.dimension_clave) {
        dimension = row.dimension_clave;
        const heading = document.createElement("div"); heading.className = "dimension";
        heading.textContent = `${row.dimension_nombre}${row.es_exclusiva ? "" : " · puede traslaparse"}`; column.appendChild(heading);
      }
      const line = document.createElement("div"); line.className = "population-row";
      const name = document.createElement("span"); name.textContent = row.opcion_nombre;
      const value = document.createElement("strong"); value.textContent = fmt(row.cantidad);
      line.append(name, value); column.appendChild(line);
    });
    container.appendChild(column);
  });
}

function renderIndicators(data) {
  const body = $("indicators"); body.replaceChildren();
  const rows = data.indicadores ?? [];
  if (!rows.length) { const tr = document.createElement("tr"); const td = document.createElement("td"); td.colSpan = 6; td.className = "empty"; td.textContent = "No existen metas activas para este ejercicio y alcance."; tr.appendChild(td); body.appendChild(tr); return; }
  rows.forEach((row) => {
    const tr = document.createElement("tr");
    const cells = [
      `${row.indicador_clave ?? ""} · ${row.indicador_nombre ?? "Indicador"}`,
      row.meta_unidad_nombre || row.meta_municipio_nombre || row.alcance || "Estatal",
      fmt(row.avance, 2), fmt(row.meta, 2), row.cumplimiento_pct == null ? "—" : `${fmt(row.cumplimiento_pct, 1)}%`,
    ];
    cells.forEach((text) => { const td = document.createElement("td"); td.textContent = text; tr.appendChild(td); });
    const state = document.createElement("td"); const pill = document.createElement("span"); pill.className = "pill"; pill.textContent = String(row.semaforo ?? "SIN ESTADO").replaceAll("_", " "); state.appendChild(pill); tr.appendChild(state); body.appendChild(tr);
  });
}

function mapCode(value) {
  const digits = String(value ?? "").replace(/\D/g, "");
  return digits ? digits.padStart(5, "0").slice(-5) : "";
}

function mapDetail(code) {
  const rows = new Map((payload?.municipios ?? []).map((row) => [mapCode(row.clave_inegi), row]));
  const row = code ? rows.get(code) : null;
  const summary = payload?.resumen ?? {};
  setText("mapName", row?.municipio_nombre || "Vista estatal");
  setText("mapRecords", fmt(row?.total_registros ?? summary.total_registros));
  setText("mapValidated", fmt(row?.validados ?? summary.validados));
  setText("mapBeneficiaries", fmt(row?.beneficiarios ?? summary.total_beneficiarios));
  setText("mapPopulation", `${fmt(row?.participantes ?? summary.total_participantes)} / ${fmt(row?.accesos ?? summary.total_accesos)}`);
  $("mapClear").hidden = !code;
}

async function renderMap(data) {
  if (!window.d3) return;
  const response = await fetch("./assets/geo/guanajuato-municipios.geojson?v=7.7.2", { cache: "force-cache" });
  if (!response.ok) throw new Error(`MAP_HTTP_${response.status}`);
  const geometry = await response.json();
  const rows = new Map((data.municipios ?? []).map((row) => [mapCode(row.clave_inegi), row]));
  const visible = new Set(catalogs.municipalities.map((row) => mapCode(row.clave_inegi)));
  const max = Math.max(1, ...[...rows.values()].map((row) => number(row.total_registros)));
  const d3 = window.d3;
  const scale = d3.scaleSequentialSqrt(d3.interpolateRgbBasis(["#dff5f2","#61d2ca","#087c91","#082e4e"])).domain([0, max]);
  const projection = d3.geoMercator().fitExtent([[24,20],[736,410]], geometry);
  const path = d3.geoPath(projection); const svg = d3.select($("map")); svg.selectAll("*").remove();
  svg.append("g").selectAll("path").data(geometry.features).join("path")
    .attr("class", (feature) => `municipality${visible.has(mapCode(feature.properties?.cvegeo)) ? "" : " out"}${selectedMapCode === mapCode(feature.properties?.cvegeo) ? " selected" : ""}`)
    .attr("d", path).attr("fill", (feature) => { const code = mapCode(feature.properties?.cvegeo); const value = number(rows.get(code)?.total_registros); return !visible.has(code) ? "#eef2f6" : value ? scale(value) : "#dbe4ed"; })
    .on("click", (_event, feature) => { const code = mapCode(feature.properties?.cvegeo); if (!visible.has(code)) return; selectedMapCode = code; renderMap(payload); mapDetail(code); })
    .append("title").text((feature) => { const code = mapCode(feature.properties?.cvegeo); return `${feature.properties?.nombre ?? code}: ${fmt(rows.get(code)?.total_registros)} registros`; });
  mapDetail(selectedMapCode);
}

function render(data) {
  payload = data;
  setText("heroYear", `Ejercicio ${data.ejercicio ?? $("year").value}`);
  renderKpis(data); renderMonths(data); renderProgramRanking(data); renderClassificationTabs(); renderClassification(data); renderActions(data); renderPopulation(data); renderIndicators(data);
  renderMap(data).catch((error) => console.error("Mapa estratégico:", error));
}

async function load() {
  setLoading(true);
  try {
    const { data, error } = await dbV2().rpc("rpc_inteligencia_cultural", filters());
    if (error) throw error;
    const result = Array.isArray(data) ? data[0] : data;
    if (!result || typeof result !== "object") throw new Error("INTELLIGENCE_EMPTY_RESPONSE");
    render(result);
    setLoading(false, `Datos actualizados · ejercicio ${result.ejercicio ?? $("year").value}`);
  } catch (error) {
    console.error("Inteligencia Cultural:", error);
    $("state").dataset.kind = "error";
    $("state").textContent = `No se pudo cargar Inteligencia Cultural: ${error?.message ?? "error desconocido"}`;
    $("apply").disabled = false; $("clear").disabled = false;
  }
}

async function init() {
  context = await loadAuthContext({ force: true });
  if (!context) { window.location.replace("index.html"); return; }
  if (!can(context, PERMISSIONS.DASHBOARD_VIEW_SCOPE)) { window.location.replace("index.html"); return; }
  const identity = getDisplayIdentity(context);
  setText("identity", `${identity.name} · ${context.profile.rol}`);
  setText("heroRole", `Rol ${context.profile.rol}`);
  const current = new Date().getFullYear();
  [current, 2026, 2025].filter((year, index, all) => all.indexOf(year) === index).sort((a,b) => b-a).forEach((year) => $("year").appendChild(option(year, year)));
  $("year").value = "2026";
  await loadCatalogs();
  $("app").hidden = false;
  await load();
}

$("unit").addEventListener("change", renderPrograms);
$("apply").addEventListener("click", load);
$("clear").addEventListener("click", () => { $("unit").value = ""; renderPrograms(); $("program").value = ""; $("municipality").value = ""; $("year").value = "2026"; selectedMapCode = null; load(); });
$("mapClear").addEventListener("click", () => { selectedMapCode = null; renderMap(payload); mapDetail(null); });
$("back").addEventListener("click", () => window.location.href = "index.html");
$("logout").addEventListener("click", async () => { await signOut(); window.location.replace("index.html"); });

init().catch((error) => { console.error(error); window.location.replace("index.html"); });
