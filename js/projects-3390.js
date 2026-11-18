/**
 * VINCULACIÓN CULTURAL — projects-3390.js
 * Módulo de Proyectos Socioculturales 3390 (Hoja P.Sociocultural / Proy. 3390)
 * para gestores asignados y administración:
 * - Consulta ficha técnica del proyecto 3390 asignado en v2.cat_proyectos.
 * - Registra bitácoras y sesiones mensuales (sesión, sede, comunidad, fecha,
 *   desarrollo, dinámica grupal, población por grupo etario M/H y recurso est./mun.).
 * - Sincroniza en v2.registros mediante rpc_create_borrador_integral /
 *   rpc_update_borrador_con_comunidad (acción PB3564_2602).
 * - Adjunta fotografías de evidencia reutilizando js/evidence.js (evidencias-v2).
 * - Exporta la bitácora del proyecto a Excel (.xlsx).
 */

import { dbV2 } from "./supabase-client.js";
import { getDisplayIdentity } from "./auth.js";
import { isAdmin } from "./permissions.js";
import { loadMunicipalities } from "./catalogs.js?v=7.2.3";
import {
  uploadEvidence,
  createEvidenceSignedUrl,
  deactivateEvidence,
} from "./evidence.js";
import {
  ensureMatrixCloudContext,
  cancelCloudDraftRow,
} from "./capture-matrix-sync.js?v=8.5.0";

const DEMO_GROUPS = Object.freeze([
  { key: "pi", label: "Primera inf. (0-5)", clave: "PRIMERA_INFANCIA_0_5" },
  { key: "inf", label: "Infancias (6-12)", clave: "NINAS_NINOS_6_12" },
  { key: "ado", label: "Adolesc. (13-17)", clave: "ADOLESCENTES_13_17" },
  { key: "jov", label: "Jóvenes (18-29)", clave: "JOVENES_18_29" },
  { key: "adu", label: "Adultos (30-59)", clave: "ADULTOS_30_59" },
  { key: "may", label: "Ads. Mayores (60+)", clave: "ADULTOS_MAYORES_60_MAS" },
]);

const MONTHS_LABEL = Object.freeze([
  "", "Enero", "Febrero", "Marzo", "Abril", "Mayo", "Junio",
  "Julio", "Agosto", "Septiembre", "Octubre", "Noviembre", "Diciembre",
]);

function clean(v) {
  return String(v ?? "").trim();
}

function toInt(v) {
  const n = Number.parseInt(v, 10);
  return Number.isFinite(n) && n > 0 ? n : 0;
}

function toMoney(v) {
  const n = Number.parseFloat(v);
  return Number.isFinite(n) && n >= 0 ? n : 0;
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function normalizeKey(str) {
  return String(str || "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toUpperCase()
    .trim();
}

function buildDemographyArray(dm, optionMap, totalPeople) {
  if (!optionMap || optionMap.size === 0 || totalPeople <= 0) return [];
  let sumM = 0;
  let sumH = 0;
  const buckets = [];
  for (const g of DEMO_GROUPS) {
    const m = toInt(dm[`${g.key}_m`]);
    const h = toInt(dm[`${g.key}_h`]);
    sumM += m;
    sumH += h;
    buckets.push([g.clave, m + h]);
  }
  buckets.unshift(["HOMBRES", sumH]);
  buckets.unshift(["MUJERES", sumM]);

  const out = [];
  for (const [clave, cantidad] of buckets) {
    if (cantidad <= 0) continue;
    const optionId =
      optionMap.get(clave) ||
      (clave === "ADULTOS_MAYORES_60_MAS"
        ? optionMap.get("ADULTOS_MAYORES_60") || optionMap.get("ADULTOS_MAYORES")
        : null);
    if (optionId) {
      out.push({
        opcion_poblacion_id: optionId,
        universo: "PARTICIPANTES",
        cantidad,
      });
    }
  }
  return out;
}

function sumDemoMatrix(dm = {}) {
  let total = 0;
  for (const g of DEMO_GROUPS) {
    total += toInt(dm[`${g.key}_m`]) + toInt(dm[`${g.key}_h`]);
  }
  return total;
}

/**
 * Consulta proyectos SOCIOCULTURAL_3390 visibles para la cuenta actual (RLS).
 */
export async function fetchAssigned3390Projects() {
  const { data, error } = await dbV2()
    .from("cat_proyectos")
    .select("*")
    .eq("tipo", "SOCIOCULTURAL_3390")
    .eq("activo", true)
    .order("nombre", { ascending: true });

  if (error) throw error;
  return data ?? [];
}

export async function initProjects3390Module(context, { preloadedProjects = null } = {}) {
  const root = document.getElementById("panel-proyectos3390");
  if (!root || !context) return [];

  let projects = preloadedProjects;
  if (!projects) {
    try {
      projects = await fetchAssigned3390Projects();
    } catch (err) {
      console.warn("No se pudieron cargar proyectos 3390:", err);
      projects = [];
    }
  }

  const admin = isAdmin(context);
  if (!admin && projects.length === 0) {
    return [];
  }

  const identity = getDisplayIdentity(context);
  let municipalities = [];
  try {
    municipalities = await loadMunicipalities(context);
  } catch {
    municipalities = [];
  }

  const state = {
    projects,
    selectedProjectId: projects[0]?.id || "",
    projectMunicipiosMap: new Map(),
    municipalities,
    sessions: [],
    evidenceCounts: new Map(),
    monthFilter: "",
    editingSessionId: "",
  };

  if (projects.length > 0) {
    try {
      const { data: linkRows } = await dbV2()
        .from("proyecto_municipios")
        .select("proyecto_id,municipio_id")
        .in("proyecto_id", projects.map((p) => p.id));
      for (const l of linkRows || []) {
        if (!state.projectMunicipiosMap.has(l.proyecto_id)) {
          state.projectMunicipiosMap.set(l.proyecto_id, new Set());
        }
        state.projectMunicipiosMap.get(l.proyecto_id).add(l.municipio_id);
      }
    } catch {
      // Continuar sin restricción visual adicional
    }
  }

  function currentProject() {
    return state.projects.find((p) => p.id === state.selectedProjectId) || null;
  }

  function availableMunicipalitiesForProject(proj) {
    if (!proj) return state.municipalities;
    const assigned = state.projectMunicipiosMap.get(proj.id);
    if (!assigned || assigned.size === 0) return state.municipalities;
    const filtered = state.municipalities.filter((m) => assigned.has(m.id));
    return filtered.length > 0 ? filtered : state.municipalities;
  }

  async function loadProjectSessions() {
    const proj = currentProject();
    if (!proj) {
      state.sessions = [];
      return;
    }

    const { data, error } = await dbV2()
      .from("registros")
      .select(
        "id,folio,estatus,row_version,unidad_operativa_id,municipio_id,nombre,descripcion,fecha_inicio,fecha_fin,periodo_mes,total_participantes,metadata"
      )
      .contains("metadata", { proyecto_id: proj.id })
      .is("deleted_at", null)
      .order("fecha_inicio", { ascending: true })
      .order("created_at", { ascending: true });

    if (error) {
      console.warn("Error cargando sesiones 3390:", error);
      state.sessions = [];
      return;
    }

    state.sessions = data || [];
    state.evidenceCounts = new Map();
    if (state.sessions.length > 0) {
      const { data: evRows } = await dbV2()
        .from("registro_evidencias")
        .select("id,registro_id")
        .in("registro_id", state.sessions.map((s) => s.id))
        .eq("activo", true);
      for (const ev of evRows || []) {
        state.evidenceCounts.set(
          ev.registro_id,
          (state.evidenceCounts.get(ev.registro_id) || 0) + 1
        );
      }
    }
  }

  function renderProjectDetails(proj) {
    const box = document.getElementById("p3390ProjectDetails");
    if (!box) return;
    if (!proj) {
      box.innerHTML = `
        <div class="dashboard-empty" style="padding:18px;background:#f8fafc;border-radius:10px;border:1px dashed #cbd5e1;">
          ${
            admin
              ? 'Aún no hay proyectos <strong>Sociocultural 3390</strong> activos. Créalos en <b>Administración → Proyectos</b> y asigna sus gestores.'
              : "No tienes proyectos 3390 asignados por el momento."
          }
        </div>`;
      return;
    }

    const periodo =
      proj.periodo_inicio || proj.periodo_fin
        ? `${proj.periodo_inicio || "—"} al ${proj.periodo_fin || "—"}`
        : "No especificado";

    box.innerHTML = `
      <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:10px;background:#f8fafc;border:1px solid #e2e8f0;border-radius:12px;padding:14px;font-size:12.5px;">
        <div><strong style="color:#004B87">Proyecto:</strong><br/>${escapeHtml(proj.nombre)}</div>
        <div><strong style="color:#004B87">Objetivo:</strong><br/>${escapeHtml(proj.objetivo || "—")}</div>
        <div><strong style="color:#004B87">Comunidad / grupo:</strong><br/>${escapeHtml(proj.grupo_atencion || "—")}</div>
        <div><strong style="color:#004B87">Disciplinas / temas:</strong><br/>${escapeHtml(proj.disciplinas_temas || "—")}</div>
        <div><strong style="color:#004B87">Sedes y espacios:</strong><br/>${escapeHtml(proj.sedes_espacios || "—")}</div>
        <div><strong style="color:#004B87">Periodo de ejecución:</strong><br/>${escapeHtml(periodo)}</div>
        <div><strong style="color:#004B87">Descripción general:</strong><br/>${escapeHtml(proj.descripcion || "—")}</div>
        <div><strong style="color:#004B87">Resultado final:</strong><br/>${escapeHtml(proj.resultado_final || "—")}</div>
      </div>`;
  }

  function renderSessionForm(proj, editing = null) {
    const form = document.getElementById("p3390SessionForm");
    if (!form) return;
    form.hidden = !proj;
    if (!proj) return;

    const meta = editing?.metadata?.proyecto_3390 || {};
    const dm = meta.demografia_matrix || {};
    const mpios = availableMunicipalitiesForProject(proj);

    const mpioOpts = mpios
      .map(
        (m) =>
          `<option value="${escapeHtml(m.id)}"${
            (editing?.municipio_id || mpios[0]?.id) === m.id ? " selected" : ""
          }>${escapeHtml(m.nombre_oficial)}</option>`
      )
      .join("");

    const nextNum =
      meta.numero_sesion ||
      (editing ? "" : String((state.sessions?.length || 0) + 1));

    const demoInputs = DEMO_GROUPS.map(
      (g) => `
      <div style="background:#fff;border:1px solid #e2e8f0;border-radius:8px;padding:6px 8px;">
        <div style="font-size:10.5px;font-weight:700;color:#334155;margin-bottom:4px;">${escapeHtml(g.label)}</div>
        <div style="display:grid;grid-template-columns:1fr 1fr;gap:4px;">
          <label style="font-size:10px;color:#64748b">M <input type="number" min="0" class="control p3390-demo" name="${g.key}_m" value="${toInt(dm[`${g.key}_m`])}" style="min-height:32px;padding:4px 6px;" /></label>
          <label style="font-size:10px;color:#64748b">H <input type="number" min="0" class="control p3390-demo" name="${g.key}_h" value="${toInt(dm[`${g.key}_h`])}" style="min-height:32px;padding:4px 6px;" /></label>
        </div>
      </div>`
    ).join("");

    form.innerHTML = `
      <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:10px;gap:10px;flex-wrap:wrap;">
        <h3 style="margin:0;color:#004B87;font-size:1rem;">${editing ? `Editando sesión · ${escapeHtml(editing.folio || "")}` : "Registrar nueva sesión / actividad mensual"}</h3>
        <div style="font-size:12px;font-weight:700;color:#047857;">Total asistentes: <span id="p3390LiveTotal">${sumDemoMatrix(dm)}</span></div>
      </div>

      <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(175px,1fr));gap:10px;">
        <div><label style="font-size:11px;font-weight:700;">No. Sesión *</label><input id="p3390Num" class="control" type="number" min="1" value="${escapeHtml(nextNum)}" required /></div>
        <div><label style="font-size:11px;font-weight:700;">Fecha *</label><input id="p3390Fecha" class="control" type="date" value="${escapeHtml(editing?.fecha_inicio || new Date().toISOString().slice(0, 10))}" required /></div>
        <div><label style="font-size:11px;font-weight:700;">Municipio *</label><select id="p3390Municipio" class="control" required>${mpioOpts}</select></div>
        <div><label style="font-size:11px;font-weight:700;">Comunidad / colonia</label><input id="p3390Comunidad" class="control" value="${escapeHtml(meta.comunidad_texto || "")}" placeholder="Nombre de comunidad o colonia" /></div>
        <div><label style="font-size:11px;font-weight:700;">Sede / lugar *</label><input id="p3390Sede" class="control" value="${escapeHtml(meta.sede || "")}" placeholder="Ej. Casa de la Cultura / Plaza" required /></div>
        <div><label style="font-size:11px;font-weight:700;">Título / actividad de la sesión *</label><input id="p3390Nombre" class="control" value="${escapeHtml(editing?.nombre || "")}" placeholder="Tema o actividad realizada" required /></div>
      </div>

      <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:10px;margin-top:10px;">
        <div><label style="font-size:11px;font-weight:700;">Desarrollo de la sesión (bitácora) *</label><textarea id="p3390Desarrollo" class="control" rows="2" required placeholder="Describe lo trabajado en la sesión...">${escapeHtml(meta.desarrollo_sesion || editing?.descripcion || "")}</textarea></div>
        <div><label style="font-size:11px;font-weight:700;">Dinámica grupal</label><textarea id="p3390Dinamica" class="control" rows="2" placeholder="Cómo participó el grupo, hallazgos o acuerdos...">${escapeHtml(meta.dinamica_grupal || "")}</textarea></div>
      </div>

      <div style="margin-top:10px;">
        <label style="font-size:11px;font-weight:700;display:block;margin-bottom:6px;">Población asistente por grupo etario y sexo</label>
        <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(145px,1fr));gap:8px;">
          ${demoInputs}
        </div>
      </div>

      <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:10px;margin-top:10px;align-items:end;">
        <div><label style="font-size:11px;font-weight:700;">Recurso Estatal ($$)</label><input id="p3390RecEst" class="control" type="number" min="0" step="0.01" value="${escapeHtml(meta.recursoEst || "")}" placeholder="0.00" /></div>
        <div><label style="font-size:11px;font-weight:700;">Recurso Municipal ($$)</label><input id="p3390RecMun" class="control" type="number" min="0" step="0.01" value="${escapeHtml(meta.recursoMun || "")}" placeholder="0.00" /></div>
        <div style="display:flex;gap:8px;justify-content:flex-end;grid-column:span 2 / -1;">
          ${editing ? `<button id="p3390CancelEdit" type="button" class="btn-secondary">Cancelar edición</button>` : ""}
          <button type="submit" class="btn-primary">${editing ? "Actualizar sesión" : "Guardar sesión en Supabase"}</button>
        </div>
      </div>`;

    form.querySelectorAll(".p3390-demo").forEach((inp) => {
      inp.addEventListener("input", () => {
        const live = {};
        form.querySelectorAll(".p3390-demo").forEach((x) => {
          live[x.name] = x.value;
        });
        const totalEl = document.getElementById("p3390LiveTotal");
        if (totalEl) totalEl.textContent = String(sumDemoMatrix(live));
      });
    });

    document.getElementById("p3390CancelEdit")?.addEventListener("click", () => {
      state.editingSessionId = "";
      renderSessionForm(currentProject(), null);
    });
  }

  function renderSessionsTable() {
    const tbody = document.getElementById("p3390SessionsBody");
    if (!tbody) return;
    const mpioMap = new Map(state.municipalities.map((m) => [m.id, m.nombre_oficial]));

    const filtered = state.sessions.filter(
      (s) => !state.monthFilter || String(s.periodo_mes) === String(Number(state.monthFilter))
    );

    if (!filtered.length) {
      tbody.innerHTML = `<tr><td colspan="9" style="text-align:center;color:#64748b;padding:16px;">No hay sesiones registradas para el filtro actual.</td></tr>`;
      return;
    }

    tbody.replaceChildren();
    for (const s of filtered) {
      const meta = s.metadata?.proyecto_3390 || {};
      const evCount = state.evidenceCounts.get(s.id) || 0;
      const tr = document.createElement("tr");
      tr.innerHTML = `
        <td style="text-align:center;font-weight:700;">${escapeHtml(meta.numero_sesion || "—")}</td>
        <td>${escapeHtml(s.fecha_inicio || "—")}</td>
        <td>${escapeHtml(mpioMap.get(s.municipio_id) || "—")}<br/><small style="color:#64748b">${escapeHtml(meta.comunidad_texto || "")}</small></td>
        <td>${escapeHtml(meta.sede || "—")}</td>
        <td><strong>${escapeHtml(s.nombre || "—")}</strong><br/><small style="color:#475569">${escapeHtml(clean(meta.desarrollo_sesion).slice(0, 80))}</small></td>
        <td style="text-align:center;font-weight:700;">${s.total_participantes ?? 0}</td>
        <td style="text-align:right;">Est: $${toMoney(meta.recursoEst).toLocaleString("es-MX")}<br/>Mun: $${toMoney(meta.recursoMun).toLocaleString("es-MX")}</td>
        <td style="text-align:center;">
          <button type="button" class="btn-secondary p3390-ev-btn" data-id="${escapeHtml(s.id)}" style="padding:5px 10px;font-size:11.5px;">
            📷 Evidencias (${evCount})
          </button>
        </td>
        <td style="white-space:nowrap;">
          <button type="button" class="btn-secondary p3390-edit-btn" data-id="${escapeHtml(s.id)}" style="padding:5px 9px;font-size:11.5px;">Editar</button>
          ${
            s.estatus === "BORRADOR"
              ? `<button type="button" class="btn-secondary p3390-del-btn" data-id="${escapeHtml(s.id)}" style="padding:5px 9px;font-size:11.5px;color:#b91c1c;">Quitar</button>`
              : ""
          }
        </td>`;
      tbody.appendChild(tr);
    }

    tbody.querySelectorAll(".p3390-edit-btn").forEach((btn) => {
      btn.addEventListener("click", () => {
        const rec = state.sessions.find((s) => s.id === btn.dataset.id);
        if (!rec) return;
        state.editingSessionId = rec.id;
        renderSessionForm(currentProject(), rec);
        document.getElementById("p3390SessionForm")?.scrollIntoView({ behavior: "smooth", block: "start" });
      });
    });

    tbody.querySelectorAll(".p3390-ev-btn").forEach((btn) => {
      btn.addEventListener("click", () => openEvidenceModal(btn.dataset.id));
    });

    tbody.querySelectorAll(".p3390-del-btn").forEach((btn) => {
      btn.addEventListener("click", async () => {
        const rec = state.sessions.find((s) => s.id === btn.dataset.id);
        if (!rec) return;
        const ok = await window.Swal?.fire({
          icon: "question",
          title: "Quitar sesión",
          text: `¿Deseas retirar la sesión "${rec.nombre}" de Supabase?`,
          showCancelButton: true,
          confirmButtonText: "Sí, retirar",
          cancelButtonText: "Cancelar",
        });
        if (!ok?.isConfirmed) return;
        try {
          await cancelCloudDraftRow(rec.id);
          await loadProjectSessions();
          renderSessionsTable();
        } catch (err) {
          window.Swal?.fire({ icon: "error", title: "No se pudo retirar", text: err?.message || "Error al retirar" });
        }
      });
    });
  }

  async function openEvidenceModal(recordId) {
    const rec = state.sessions.find((s) => s.id === recordId);
    if (!rec) return;

    async function renderEvidenceDialog() {
      const { data: rows, error } = await dbV2()
        .from("registro_evidencias")
        .select("id,tipo_evidencia,storage_path,nombre_original,mime_type,size_bytes,created_at")
        .eq("registro_id", recordId)
        .eq("activo", true)
        .order("created_at", { ascending: false });

      if (error) {
        window.Swal?.fire({ icon: "error", title: "Error cargando evidencias", text: error.message });
        return;
      }

      const itemsHtml =
        (rows || []).length === 0
          ? `<p style="color:#64748b;font-size:12.5px;">Aún no hay fotografías o archivos adjuntos en esta sesión.</p>`
          : `<ul style="list-style:none;padding:0;margin:0;display:grid;gap:8px;max-height:220px;overflow:auto;">
              ${(rows || [])
                .map(
                  (ev) => `
                <li style="display:flex;align-items:center;justify-content:space-between;gap:8px;background:#f8fafc;border:1px solid #e2e8f0;border-radius:8px;padding:7px 10px;font-size:12px;">
                  <span style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">🖼️ ${escapeHtml(ev.nombre_original)}</span>
                  <span style="display:flex;gap:6px;flex-shrink:0;">
                    <button type="button" class="swal-ev-view" data-path="${escapeHtml(ev.storage_path)}" style="padding:4px 8px;border:1px solid #cbd5e1;border-radius:6px;background:#fff;cursor:pointer;font-size:11px;">Ver</button>
                    <button type="button" class="swal-ev-del" data-ev-id="${escapeHtml(ev.id)}" style="padding:4px 8px;border:1px solid #fecaca;border-radius:6px;background:#fff1f2;color:#b91c1c;cursor:pointer;font-size:11px;">Quitar</button>
                  </span>
                </li>`
                )
                .join("")}
            </ul>`;

      await window.Swal?.fire({
        title: `Evidencias · ${rec.nombre}`,
        width: 580,
        html: `
          <div style="text-align:left;display:grid;gap:12px;">
            <div style="background:#eff6ff;border:1px solid #bfdbfe;border-radius:10px;padding:10px;">
              <label style="display:block;font-weight:700;font-size:12px;color:#004B87;margin-bottom:6px;">Subir fotografía o documento (JPG, PNG, WEBP, PDF · máx 10 MB)</label>
              <input id="swalP3390File" type="file" accept="image/jpeg,image/png,image/webp,application/pdf" style="font-size:12px;width:100%;" />
              <button id="swalP3390UploadBtn" type="button" class="swal2-confirm swal2-styled" style="margin:8px 0 0;padding:6px 14px;font-size:12px;background:#004B87;">Subir evidencia</button>
            </div>
            <div>
              <strong style="font-size:12px;color:#334155;display:block;margin-bottom:6px;">Archivos guardados (${(rows || []).length}):</strong>
              ${itemsHtml}
            </div>
          </div>`,
        showConfirmButton: true,
        confirmButtonText: "Cerrar",
        didOpen: () => {
          document.getElementById("swalP3390UploadBtn")?.addEventListener("click", async () => {
            const fileInput = document.getElementById("swalP3390File");
            const file = fileInput?.files?.[0];
            if (!file) {
              window.Swal?.showValidationMessage("Selecciona una fotografía o archivo primero.");
              return;
            }
            const btn = document.getElementById("swalP3390UploadBtn");
            btn.disabled = true;
            btn.textContent = "Subiendo...";
            try {
              const ctx = await ensureMatrixCloudContext(context);
              await uploadEvidence({
                recordId: rec.id,
                unitId: rec.unidad_operativa_id || ctx.unit.id,
                file,
                type: file.type === "application/pdf" ? "DOCUMENTO" : "FOTOGRAFIA",
              });
              await loadProjectSessions();
              renderSessionsTable();
              await renderEvidenceDialog();
            } catch (err) {
              btn.disabled = false;
              btn.textContent = "Subir evidencia";
              window.Swal?.showValidationMessage(err?.message || "No se pudo subir la evidencia.");
            }
          });

          document.querySelectorAll(".swal-ev-view").forEach((vBtn) => {
            vBtn.addEventListener("click", async () => {
              try {
                const url = await createEvidenceSignedUrl(vBtn.dataset.path);
                if (url) window.open(url, "_blank", "noopener,noreferrer");
              } catch (err) {
                window.Swal?.showValidationMessage(err?.message || "No se pudo abrir.");
              }
            });
          });

          document.querySelectorAll(".swal-ev-del").forEach((dBtn) => {
            dBtn.addEventListener("click", async () => {
              try {
                await deactivateEvidence(dBtn.dataset.evId);
                await loadProjectSessions();
                renderSessionsTable();
                await renderEvidenceDialog();
              } catch (err) {
                window.Swal?.showValidationMessage(err?.message || "No se pudo quitar.");
              }
            });
          });
        },
      });
    }

    await renderEvidenceDialog();
  }

  async function saveSession(event) {
    event.preventDefault();
    const proj = currentProject();
    if (!proj) return;

    const fecha = document.getElementById("p3390Fecha").value;
    const municipioId = document.getElementById("p3390Municipio").value;
    const sede = clean(document.getElementById("p3390Sede").value);
    const nombre = clean(document.getElementById("p3390Nombre").value);
    const desarrollo = clean(document.getElementById("p3390Desarrollo").value);
    const dinamica = clean(document.getElementById("p3390Dinamica").value);
    const comunidadTexto = clean(document.getElementById("p3390Comunidad").value);
    const numeroSesion = document.getElementById("p3390Num").value;
    const recursoEst = document.getElementById("p3390RecEst").value;
    const recursoMun = document.getElementById("p3390RecMun").value;

    const dm = {};
    document.querySelectorAll("#p3390SessionForm .p3390-demo").forEach((x) => {
      dm[x.name] = toInt(x.value);
    });
    const totalPeople = sumDemoMatrix(dm);

    try {
      const ctx = await ensureMatrixCloudContext(context);
      const action =
        ctx.actionByClave.get("PB3564_2602") ||
        ctx.actionByClave.get("PB3564_2601") ||
        ctx.actions[0];
      const config = ctx.configByActionId.get(action?.id);
      if (!action || !config) {
        throw new Error("No se encontró configuración activa para Proyectos Socioculturales.");
      }

      const optionMap = ctx.demoOptionMapBySchema.get(config.esquema_demografico_id);
      const editing = state.editingSessionId
        ? state.sessions.find((s) => s.id === state.editingSessionId)
        : null;
      const mpioName =
        state.municipalities.find((m) => m.id === municipioId)?.nombre_oficial || "";

      const payload = {
        unidad_operativa_id: ctx.unit.id,
        programa_id: action.programa_id,
        accion_id: action.id,
        configuracion_accion_id: config.id,
        municipio_id: municipioId,
        comunidad_id: null,
        espacio_id: null,
        nombre,
        descripcion: desarrollo || null,
        fecha_inicio: fecha,
        fecha_fin: fecha,
        total_beneficiarios: totalPeople,
        total_participantes: totalPeople,
        total_accesos: totalPeople,
        metadata: {
          frontend: {
            version: "8.5.0",
            capture_module: "proyecto_3390_2026",
          },
          proyecto_id: proj.id,
          proyecto_nombre: proj.nombre,
          proyecto_3390: {
            numero_sesion: String(numeroSesion || ""),
            sede,
            comunidad_texto: comunidadTexto,
            desarrollo_sesion: desarrollo,
            dinamica_grupal: dinamica,
            demografia_matrix: dm,
            recursoEst: recursoEst || "",
            recursoMun: recursoMun || "",
          },
          source_labels: {
            unidad: ctx.unit.nombre || "Casas de la Cultura",
            accion: action.nombre,
            municipio: mpioName,
            proyecto: proj.nombre,
          },
        },
        responsable: {
          nombre: identity?.name || "Gestor 3390",
          cargo: "Gestor de Proyecto 3390",
          correo: identity?.email || null,
          telefono: null,
        },
        proyecto: {
          justificacion: proj.justificacion || null,
          descripcion_problematica: proj.descripcion || null,
          poblacion_objetivo: proj.grupo_atencion || null,
          resultado_general: proj.resultado_final || null,
        },
        demografia: config.requiere_demografia
          ? buildDemographyArray(dm, optionMap, totalPeople)
          : [],
      };

      if (editing) {
        const { error } = await dbV2()
          .rpc("rpc_update_borrador_con_comunidad", {
            p_registro_id: editing.id,
            p_expected_row_version: editing.row_version || 1,
            p_payload: payload,
          })
          .single();
        if (error) throw error;
      } else {
        const { error } = await dbV2()
          .rpc("rpc_create_borrador_integral", { p_payload: payload })
          .single();
        if (error) throw error;
      }

      state.editingSessionId = "";
      await loadProjectSessions();
      renderSessionForm(proj, null);
      renderSessionsTable();
      window.Swal?.fire({
        icon: "success",
        title: editing ? "Sesión actualizada" : "Sesión guardada en Supabase",
        timer: 1400,
        showConfirmButton: false,
      });
    } catch (err) {
      window.Swal?.fire({
        icon: "error",
        title: "No se pudo guardar la sesión",
        text: err?.message || "Verifica tu alcance municipal o intenta nuevamente.",
      });
    }
  }

  function export3390Xlsx() {
    const proj = currentProject();
    if (!proj || !window.XLSX) return;
    const mpioMap = new Map(state.municipalities.map((m) => [m.id, m.nombre_oficial]));
    const aoa = [
      ["PROYECTO SOCIOCULTURAL 3390 · REPORTE Y BITÁCORA DE SESIONES"],
      ["Nombre del proyecto:", proj.nombre],
      ["Objetivo:", proj.objetivo || ""],
      ["Descripción general:", proj.descripcion || ""],
      ["Justificación:", proj.justificacion || ""],
      ["Comunidad (grupo de atención):", proj.grupo_atencion || ""],
      ["Disciplinas / temas:", proj.disciplinas_temas || ""],
      ["Sedes:", proj.sedes_espacios || ""],
      ["Periodo de ejecución:", `${proj.periodo_inicio || ""} a ${proj.periodo_fin || ""}`],
      ["Resultado final:", proj.resultado_final || ""],
      [],
      [
        "No. Sesión", "Fecha", "Municipio", "Comunidad / Colonia", "Sede / Lugar",
        "Actividad", "Desarrollo de la sesión", "Dinámica grupal",
        "0-5 M", "0-5 H", "6-12 M", "6-12 H", "13-17 M", "13-17 H",
        "18-29 M", "18-29 H", "30-59 M", "30-59 H", "60+ M", "60+ H",
        "Total Asistentes", "Recurso Estatal", "Recurso Municipal",
      ],
    ];

    for (const s of state.sessions) {
      const m = s.metadata?.proyecto_3390 || {};
      const dm = m.demografia_matrix || {};
      aoa.push([
        m.numero_sesion || "",
        s.fecha_inicio || "",
        mpioMap.get(s.municipio_id) || "",
        m.comunidad_texto || "",
        m.sede || "",
        s.nombre || "",
        m.desarrollo_sesion || "",
        m.dinamica_grupal || "",
        toInt(dm.pi_m), toInt(dm.pi_h),
        toInt(dm.inf_m), toInt(dm.inf_h),
        toInt(dm.ado_m), toInt(dm.ado_h),
        toInt(dm.jov_m), toInt(dm.jov_h),
        toInt(dm.adu_m), toInt(dm.adu_h),
        toInt(dm.may_m), toInt(dm.may_h),
        s.total_participantes ?? 0,
        toMoney(m.recursoEst),
        toMoney(m.recursoMun),
      ]);
    }

    const wb = window.XLSX.utils.book_new();
    const ws = window.XLSX.utils.aoa_to_sheet(aoa);
    window.XLSX.utils.book_append_sheet(wb, ws, "Proy. 3390");
    window.XLSX.writeFile(wb, `Proyecto_3390_${proj.nombre.replace(/\s+/g, "_").slice(0, 35)}.xlsx`);
  }

  root.innerHTML = `
    <div style="display:grid;gap:16px;">
      <article class="card section-card">
        <div class="bitacora-heading" style="display:flex;justify-content:space-between;align-items:flex-end;gap:12px;flex-wrap:wrap;">
          <div>
            <div class="hero-kicker capture-kicker">Proyectos Socioculturales · Partida 3390</div>
            <h2>Bitácora mensual y evidencias de gestores</h2>
            <p>Captura tus sesiones mensuales, grupos etarios, dinámica grupal y fotografías de evidencia directamente en tu proyecto asignado.</p>
          </div>
          <div style="display:flex;gap:8px;flex-wrap:wrap;align-items:center;">
            <select id="p3390ProjectSelect" class="control" style="min-width:260px;"></select>
            <select id="p3390MonthFilter" class="control" style="min-width:150px;">
              <option value="">Todos los meses</option>
              ${MONTHS_LABEL.slice(1).map((m, idx) => `<option value="${idx + 1}">${m}</option>`).join("")}
            </select>
            <button id="p3390ExportBtn" type="button" class="btn-secondary">⬇ Exportar 3390 (.xlsx)</button>
          </div>
        </div>

        <div id="p3390ProjectDetails" style="margin-top:12px;"></div>
      </article>

      <article class="card section-card">
        <form id="p3390SessionForm"></form>
      </article>

      <article class="card section-card">
        <h3 style="margin:0 0 10px;color:#004B87;font-size:1rem;">Sesiones y bitácoras registradas</h3>
        <div class="dashboard-table-wrap">
          <table class="dashboard-table">
            <thead>
              <tr>
                <th>No.</th>
                <th>Fecha</th>
                <th>Municipio / Comunidad</th>
                <th>Sede</th>
                <th>Sesión / Desarrollo</th>
                <th>Asistentes</th>
                <th>Recurso ($$)</th>
                <th>Evidencias</th>
                <th>Acciones</th>
              </tr>
            </thead>
            <tbody id="p3390SessionsBody"><tr><td colspan="9">Cargando...</td></tr></tbody>
          </table>
        </div>
      </article>
    </div>`;

  const projSelect = document.getElementById("p3390ProjectSelect");
  if (projects.length === 0) {
    projSelect.innerHTML = `<option value="">— Sin proyectos 3390 —</option>`;
  } else {
    projSelect.innerHTML = projects
      .map((p) => `<option value="${escapeHtml(p.id)}">${escapeHtml(p.nombre)}</option>`)
      .join("");
    projSelect.value = state.selectedProjectId;
  }

  projSelect.addEventListener("change", async () => {
    state.selectedProjectId = projSelect.value;
    state.editingSessionId = "";
    const p = currentProject();
    renderProjectDetails(p);
    await loadProjectSessions();
    renderSessionForm(p, null);
    renderSessionsTable();
  });

  document.getElementById("p3390MonthFilter").addEventListener("change", (e) => {
    state.monthFilter = e.target.value;
    renderSessionsTable();
  });

  document.getElementById("p3390ExportBtn").addEventListener("click", export3390Xlsx);
  document.getElementById("p3390SessionForm").addEventListener("submit", saveSession);

  const initialProj = currentProject();
  renderProjectDetails(initialProj);
  await loadProjectSessions();
  renderSessionForm(initialProj, null);
  renderSessionsTable();

  return projects;
}
