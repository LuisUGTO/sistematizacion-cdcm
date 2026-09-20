import { dbV2 } from "./supabase-client.js";
import { loadAuthContext, signOut, getDisplayIdentity } from "./auth.js?v=7.4.3";
import { PERMISSIONS, can, isAdmin } from "./permissions.js";
import { getActiveIntelligenceTheme, applyIntelligenceTheme } from "./inteligencia-theme.js";

const $ = (id) => document.getElementById(id);
const MONTHS = ["Ene","Feb","Mar","Abr","May","Jun","Jul","Ago","Sep","Oct","Nov","Dic"];
const AXES = [
  ["tipo_actividad", "Tipo de actividad"],
  ["formato", "Formato"],
  ["temporalidad", "Temporalidad"],
  ["disciplina", "Disciplina"],
];
const VIEWS = new Set(["panorama", "territorio", "oferta", "poblacion", "indicadores", "calidad"]);

let context = null;
let payload = null;
let mapPayload = null;
let selectedAxis = "tipo_actividad";
let selectedMapCode = null;
let catalogs = { units: [], programs: [], municipalities: [] };
let activeView = "panorama";
let qualityPayload = null;

function viewFromHash() {
  const value = window.location.hash.replace(/^#\/?/, "").toLowerCase();
  return VIEWS.has(value) ? value : "panorama";
}

function setActiveView(view, { updateUrl = true, focus = false } = {}) {
  activeView = VIEWS.has(view) && (view !== "calidad" || can(context, PERMISSIONS.VALIDATION_REVIEW)) ? view : "panorama";
  document.querySelectorAll("[data-view-panel]").forEach((panel) => {
    panel.hidden = panel.dataset.viewPanel !== activeView;
  });
  document.querySelectorAll("[data-view-intro]").forEach((intro) => {
    intro.classList.toggle("active", intro.dataset.viewIntro === activeView);
  });
  document.querySelectorAll("#viewNav [data-view]").forEach((button) => {
    const selected = button.dataset.view === activeView;
    button.classList.toggle("active", selected);
    button.setAttribute("aria-current", selected ? "page" : "false");
  });
  if (updateUrl) history.replaceState(null, "", `${window.location.pathname}${window.location.search}#${activeView}`);
  if (activeView === "territorio" && mapPayload) renderMap(mapPayload).catch((error) => console.error("Mapa estratégico:", error));
  if (focus) $("viewNav").scrollIntoView({ behavior: "smooth", block: "start" });
}

function number(value) {
  const parsed = Number(value ?? 0);
  return Number.isFinite(parsed) ? parsed : 0;
}

function fmt(value, digits = 0) {
  return new Intl.NumberFormat("es-MX", { maximumFractionDigits: digits }).format(number(value));
}

function pct(value, total) {
  return total > 0 ? number(value) / number(total) * 100 : 0;
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
    p_modo: $("universe").value || "OFICIAL",
  };
}

function setLoading(active, message = "Actualizando información estratégica…") {
  $("apply").disabled = active;
  $("clear").disabled = active;
  $("universe").disabled = active;
  $("state").dataset.kind = active ? "loading" : "ok";
  $("state").textContent = message;
}

function renderTrust(data, operationalData = data) {
  const mode = data.modo === "OFICIAL" ? "OFICIAL" : "OPERATIVO";
  const current = data.resumen ?? {};
  const operational = operationalData?.resumen ?? current;
  const totalOperational = number(operational.total_registros);
  const validatedOperational = number(operational.validados);
  const validationRate = pct(validatedOperational, totalOperational);
  const quality = data.calidad_clasificacion ?? {};
  const qualityBase = number(quality.registros_activos);
  const classificationRate = qualityBase
    ? (pct(quality.con_tipo_actividad, qualityBase) + pct(quality.con_formato, qualityBase) + pct(quality.con_disciplina, qualityBase)) / 3
    : 0;
  const generated = data.generado_at ? new Date(data.generado_at) : new Date();
  $("trust").dataset.mode = mode;
  setText("heroMode", mode === "OFICIAL" ? "Información oficial" : "Seguimiento operativo");
  setText("trustTitle", mode === "OFICIAL" ? "Información oficial" : "Seguimiento operativo");
  setText("trustDescription", mode === "OFICIAL"
    ? "Sólo expedientes validados institucionalmente; aptos para lectura directiva."
    : "Incluye borradores y expedientes en proceso; sus cifras todavía pueden cambiar.");
  setText("trustUniverse", fmt(current.total_registros));
  setText("trustUniverseNote", mode === "OFICIAL" ? `de ${fmt(totalOperational)} expedientes operativos` : "expedientes dentro del seguimiento");
  setText("trustValidation", `${fmt(validationRate, 1)}%`);
  setText("trustValidationNote", `${fmt(validatedOperational)} de ${fmt(totalOperational)} expedientes validados`);
  setText("trustCoverage", `${fmt(current.municipios_con_actividad)} / 46`);
  setText("trustUpdated", generated.toLocaleTimeString("es-MX", { hour: "2-digit", minute: "2-digit" }));
  const alerts = [];
  if (totalOperational && validationRate < 25) alerts.push(`Validación baja: sólo ${fmt(validatedOperational)} de ${fmt(totalOperational)} expedientes cuentan como información oficial.`);
  if (qualityBase && classificationRate < 70) alerts.push(`Clasificación operativa incompleta: el promedio de cobertura en tipo, formato y disciplina es ${fmt(classificationRate, 1)}%.`);
  if (!number(current.municipios_con_actividad)) alerts.push("No hay cobertura territorial para los filtros seleccionados.");
  const alert = $("trustAlert");
  alert.textContent = alerts.join(" ");
  alert.classList.toggle("visible", alerts.length > 0);
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

function qualityLabel(priority) {
  return ({ LISTO_PARA_VALIDAR: "Listo para validar", BLOQUEADO: "Con incidencias", PENDIENTE_CORRECCION: "En corrección", PENDIENTE_RE_REVISION: "Revisión posterior", PENDIENTE_ENVIO: "Pendiente de envío" })[priority] ?? "En proceso";
}

function renderQuality(data) {
  if (!can(context, PERMISSIONS.VALIDATION_REVIEW)) return;
  qualityPayload = data ?? {};
  const summary = qualityPayload.resumen ?? {};
  const summaryBox = $("qualitySummary"); summaryBox.replaceChildren();
  const cards = [
    ["Listos para validar", summary.listos_para_validar, "Sin incidencias estructurales.", "#07875d"],
    ["Con incidencias", summary.bloqueados, "Requieren completar o corregir información.", "#be123c"],
    ["Observados", summary.observados, "Devueltos para corrección institucional.", "#d97706"],
    ["En revisión", summary.en_revision, "Expedientes dentro de la bandeja.", "#075a98"],
  ];
  cards.forEach(([label, value, note, accent]) => { const card = document.createElement("article"); card.className = "quality-kpi"; card.style.setProperty("--accent", accent); const title = document.createElement("span"); title.textContent = label; const amount = document.createElement("strong"); amount.textContent = fmt(value); const detail = document.createElement("small"); detail.textContent = note; card.append(title, amount, detail); summaryBox.appendChild(card); });
  const issues = $("qualityIssues"); issues.replaceChildren();
  const issueRows = qualityPayload.incidencias ?? [];
  if (!issueRows.length) { const empty = document.createElement("div"); empty.className = "empty"; empty.textContent = "No hay incidencias estructurales en los filtros seleccionados."; issues.appendChild(empty); }
  issueRows.slice(0, 8).forEach((row) => { const item = document.createElement("div"); item.className = "issue-row"; const label = document.createElement("strong"); label.textContent = String(row.incidencia ?? "INCIDENCIA").replaceAll("_", " "); const amount = document.createElement("span"); amount.textContent = fmt(row.registros); item.append(label, amount); issues.appendChild(item); });
  const body = $("qualityPriorities"); body.replaceChildren();
  const priorities = qualityPayload.prioridades ?? [];
  if (!priorities.length) { const tr = document.createElement("tr"); const td = document.createElement("td"); td.colSpan = 4; td.className = "empty"; td.textContent = "No hay expedientes pendientes para los filtros seleccionados."; tr.appendChild(td); body.appendChild(tr); return; }
  priorities.forEach((row) => { const tr = document.createElement("tr"); const priority = document.createElement("td"); const pill = document.createElement("span"); pill.className = `quality-status ${row.prioridad === "LISTO_PARA_VALIDAR" ? "ready" : row.prioridad === "EN_REVISION" ? "review" : ""}`; pill.textContent = qualityLabel(row.prioridad); priority.appendChild(pill); const folio = document.createElement("td"); const folioTitle = document.createElement("strong"); folioTitle.textContent = row.folio ?? "Sin folio"; const folioDetail = document.createElement("small"); folioDetail.textContent = row.nombre ?? "Sin nombre de actividad"; folio.append(folioTitle, folioDetail); const scope = document.createElement("td"); scope.textContent = row.municipio_nombre ?? "Sin municipio"; const scopeDetail = document.createElement("small"); scopeDetail.textContent = row.programa_nombre ?? row.unidad_nombre ?? "Sin programa"; scope.appendChild(scopeDetail); const issuesCell = document.createElement("td"); const issuesNumber = document.createElement("strong"); issuesNumber.textContent = fmt(row.total_incidencias); const issuesDetail = document.createElement("small"); issuesDetail.textContent = row.total_incidencias ? (row.incidencias ?? []).join(", ").replaceAll("_", " ") : "Sin incidencias"; issuesCell.append(issuesNumber, issuesDetail); tr.append(priority, folio, scope, issuesCell); body.appendChild(tr); });
}

function mapCode(value) {
  const digits = String(value ?? "").replace(/\D/g, "");
  return digits ? digits.padStart(5, "0").slice(-5) : "";
}

function mapDetail(code) {
  const source = mapPayload ?? payload ?? {};
  const rows = new Map((source.municipios ?? []).map((row) => [mapCode(row.clave_inegi), row]));
  const row = code ? rows.get(code) : null;
  const summary = source.resumen ?? {};
  const catalog = catalogs.municipalities.find((item) => mapCode(item.clave_inegi) === code);
  const records = code ? number(row?.total_registros) : number(summary.total_registros);
  const validated = code ? number(row?.validados) : number(summary.validados);
  const beneficiaries = code ? number(row?.beneficiarios) : number(summary.total_beneficiarios);
  const participants = code ? number(row?.participantes) : number(summary.total_participantes);
  const accesses = code ? number(row?.accesos) : number(summary.total_accesos);
  const recordShare = pct(records, number(summary.total_registros));
  const beneficiaryShare = pct(beneficiaries, number(summary.total_beneficiarios));
  const validationRate = pct(validated, records);
  setText("mapName", row?.municipio_nombre || catalog?.nombre_oficial || "Vista estatal");
  setText("mapContext", code ? (records ? "Resultados municipales dentro del universo estatal visible." : "Sin actividad registrada para los filtros actuales.") : "Resumen del alcance visible con los filtros actuales.");
  setText("mapRecords", fmt(records));
  setText("mapValidated", fmt(validated));
  setText("mapBeneficiaries", fmt(beneficiaries));
  setText("mapPopulation", `${fmt(participants)} / ${fmt(accesses)}`);
  setText("mapShare", code ? `${fmt(recordShare, 1)}% de los registros estatales` : `${fmt(summary.municipios_con_actividad)} de 46 municipios con actividad`);
  setText("mapValidation", records ? `${fmt(validationRate, 1)}% de validación` : "Sin expedientes para validar");
  setText("mapBeneficiaryShare", code ? `${fmt(beneficiaryShare, 1)}% del total estatal reportado` : "Total del alcance visible");
  let insight = "Selecciona un territorio para conocer su peso dentro del estado.";
  if (code && !records) insight = "Este municipio está dentro de tu alcance, pero no tiene registros para los filtros aplicados.";
  else if (code && recordShare >= 75) insight = `Concentración muy alta: este municipio reúne ${fmt(recordShare, 1)}% de los registros visibles.`;
  else if (code && recordShare >= 40) insight = `Concentración alta: este municipio reúne ${fmt(recordShare, 1)}% de los registros visibles.`;
  else if (code) insight = `Participación territorial: ${fmt(recordShare, 1)}% de los registros visibles.`;
  setText("mapInsight", insight);
  $("mapClear").hidden = !code;
}

function showMapTooltip(event, feature, row) {
  const tooltip = $("mapTooltip");
  const title = document.createElement("strong");
  title.textContent = row?.municipio_nombre || feature.properties?.nombre || "Municipio";
  const records = document.createElement("span");
  records.textContent = `${fmt(row?.total_registros)} registros · ${fmt(row?.validados)} validados`;
  const people = document.createElement("span");
  people.textContent = `${fmt(row?.beneficiarios)} beneficiarios`;
  tooltip.replaceChildren(title, records, people);
  tooltip.style.left = `${event.clientX + 14}px`;
  tooltip.style.top = `${event.clientY + 14}px`;
  tooltip.hidden = false;
}

function hideMapTooltip() {
  $("mapTooltip").hidden = true;
}

async function selectMunicipalityFromMap(code) {
  const municipality = catalogs.municipalities.find((row) => mapCode(row.clave_inegi) === code);
  if (!municipality) return;
  selectedMapCode = code;
  $("municipality").value = municipality.id;
  mapDetail(code);
  await load();
}

async function renderMap(data) {
  if (!window.d3) return;
  const response = await fetch("./assets/geo/guanajuato-municipios.geojson?v=7.7.3a", { cache: "force-cache" });
  if (!response.ok) throw new Error(`MAP_HTTP_${response.status}`);
  const geometry = await response.json();
  const rows = new Map((data.municipios ?? []).map((row) => [mapCode(row.clave_inegi), row]));
  const visible = new Set(catalogs.municipalities.map((row) => mapCode(row.clave_inegi)));
  const max = Math.max(1, ...[...rows.values()].map((row) => number(row.total_registros)));
  setText("mapLegendMax", fmt(max));
  const d3 = window.d3;
  const scale = d3.scaleSequentialSqrt(d3.interpolateRgbBasis(["#dff5f2","#61d2ca","#087c91","#082e4e"])).domain([0, max]);
  const projection = d3.geoMercator().fitExtent([[24,20],[736,410]], geometry);
  const path = d3.geoPath(projection); const svg = d3.select($("map")); svg.selectAll("*").remove();
  svg.append("g").selectAll("path").data(geometry.features).join("path")
    .attr("class", (feature) => `municipality${visible.has(mapCode(feature.properties?.cvegeo)) ? "" : " out"}${selectedMapCode === mapCode(feature.properties?.cvegeo) ? " selected" : ""}`)
    .attr("d", path)
    .classed("no-data", (feature) => !number(rows.get(mapCode(feature.properties?.cvegeo))?.total_registros))
    .style("fill", (feature) => { const code = mapCode(feature.properties?.cvegeo); const value = number(rows.get(code)?.total_registros); return !visible.has(code) ? "#eef2f6" : value ? scale(value) : "#dbe4ed"; })
    .on("mouseenter", (event, feature) => { const code = mapCode(feature.properties?.cvegeo); if (visible.has(code)) showMapTooltip(event, feature, rows.get(code)); })
    .on("mousemove", (event) => { const tooltip = $("mapTooltip"); tooltip.style.left = `${event.clientX + 14}px`; tooltip.style.top = `${event.clientY + 14}px`; })
    .on("mouseleave", hideMapTooltip)
    .on("click", (_event, feature) => { const code = mapCode(feature.properties?.cvegeo); if (visible.has(code)) selectMunicipalityFromMap(code); })
    .append("title").text((feature) => { const code = mapCode(feature.properties?.cvegeo); return `${feature.properties?.nombre ?? code}: ${fmt(rows.get(code)?.total_registros)} registros`; });
  mapDetail(selectedMapCode);
}

function render(data, mapData = data, operationalData = data, qualityData = null) {
  payload = data;
  mapPayload = mapData;
  setText("heroYear", `Ejercicio ${data.ejercicio ?? $("year").value}`);
  renderTrust(data, operationalData); renderKpis(data); renderMonths(data); renderProgramRanking(data); renderClassificationTabs(); renderClassification(data); renderActions(data); renderPopulation(data); renderIndicators(data);
  renderMap(mapData).catch((error) => console.error("Mapa estratégico:", error));
  renderQuality(qualityData);
}

async function load() {
  setLoading(true);
  try {
    const currentFilters = filters();
    const currentRequest = dbV2().rpc("rpc_inteligencia_cultural", currentFilters);
    const overviewRequest = currentFilters.p_municipio
      ? dbV2().rpc("rpc_inteligencia_cultural", { ...currentFilters, p_municipio: null })
      : Promise.resolve(null);
    const operationalRequest = currentFilters.p_modo === "OFICIAL"
      ? dbV2().rpc("rpc_inteligencia_cultural", { ...currentFilters, p_modo: "OPERATIVO" })
      : Promise.resolve(null);
    const qualityRequest = can(context, PERMISSIONS.VALIDATION_REVIEW)
      ? dbV2().rpc("rpc_inteligencia_calidad", currentFilters)
      : Promise.resolve(null);
    const [currentResponse, overviewResponse, operationalResponse, qualityResponse] = await Promise.all([currentRequest, overviewRequest, operationalRequest, qualityRequest]);
    if (currentResponse.error) throw currentResponse.error;
    if (overviewResponse?.error) throw overviewResponse.error;
    if (operationalResponse?.error) throw operationalResponse.error;
    if (qualityResponse?.error) throw qualityResponse.error;
    const result = Array.isArray(currentResponse.data) ? currentResponse.data[0] : currentResponse.data;
    const overview = overviewResponse ? (Array.isArray(overviewResponse.data) ? overviewResponse.data[0] : overviewResponse.data) : result;
    const operational = operationalResponse ? (Array.isArray(operationalResponse.data) ? operationalResponse.data[0] : operationalResponse.data) : result;
    if (!result || typeof result !== "object") throw new Error("INTELLIGENCE_EMPTY_RESPONSE");
    const selected = catalogs.municipalities.find((row) => row.id === currentFilters.p_municipio);
    selectedMapCode = selected ? mapCode(selected.clave_inegi) : null;
    const quality = qualityResponse ? (Array.isArray(qualityResponse.data) ? qualityResponse.data[0] : qualityResponse.data) : null;
    render(result, overview, operational, quality);
    setLoading(false, `${result.modo === "OFICIAL" ? "Información oficial" : "Seguimiento operativo"} · ejercicio ${result.ejercicio ?? $("year").value}${selected ? ` · ${selected.nombre_oficial}` : " · vista estatal"}`);
  } catch (error) {
    console.error("Inteligencia Cultural:", error);
    $("state").dataset.kind = "error";
    $("state").textContent = `No se pudo cargar Inteligencia Cultural: ${error?.message ?? "error desconocido"}`;
    $("apply").disabled = false; $("clear").disabled = false; $("universe").disabled = false;
  }
}

async function init() {
  context = await loadAuthContext({ force: true });
  if (!context) { window.location.replace("index.html"); return; }
  if (!can(context, PERMISSIONS.DASHBOARD_VIEW_SCOPE)) { window.location.replace("index.html"); return; }
  const identity = getDisplayIdentity(context);
  setText("identity", `${identity.name} · ${context.profile.rol}`);
  setText("heroRole", `Rol ${context.profile.rol}`);
  document.querySelectorAll("[data-permission]").forEach((element) => { element.hidden = !can(context, element.dataset.permission); });
  try {
    const theme = await getActiveIntelligenceTheme();
    applyIntelligenceTheme(theme);
  } catch (error) {
    console.warn("Tema cultural no disponible; se usa identidad institucional.", error);
  }
  const current = new Date().getFullYear();
  [current, 2026, 2025].filter((year, index, all) => all.indexOf(year) === index).sort((a,b) => b-a).forEach((year) => $("year").appendChild(option(year, year)));
  $("year").value = "2026";
  $("universe").value = "OFICIAL";
  await loadCatalogs();
  $("app").hidden = false;
  setActiveView(viewFromHash(), { updateUrl: true });
  await load();
}

$("unit").addEventListener("change", renderPrograms);
$("universe").addEventListener("change", load);
$("viewNav").addEventListener("click", (event) => {
  const button = event.target.closest("[data-view]");
  if (button) setActiveView(button.dataset.view, { updateUrl: true, focus: true });
});
window.addEventListener("hashchange", () => setActiveView(viewFromHash(), { updateUrl: false }));
$("apply").addEventListener("click", load);
$("clear").addEventListener("click", () => { $("unit").value = ""; renderPrograms(); $("program").value = ""; $("municipality").value = ""; $("year").value = "2026"; selectedMapCode = null; load(); });
$("mapClear").addEventListener("click", async () => { $("municipality").value = ""; selectedMapCode = null; await load(); });
$("back").addEventListener("click", () => window.location.href = "index.html");
$("logout").addEventListener("click", async () => { await signOut(); window.location.replace("index.html"); });

init().catch((error) => { console.error(error); window.location.replace("index.html"); });
