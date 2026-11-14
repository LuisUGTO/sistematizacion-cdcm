/**
 * VINCULACIÓN CULTURAL — CASAS DE LA CULTURA
 * capture-matrix-sync.js
 *
 * Sincronización del Libro Mensual Tipo Excel con Supabase (esquema v2).
 * Convierte cada fila capturada en la matriz mensual en un registro canónico
 * de v2.registros usando las RPCs oficiales (rpc_create_borrador_integral y
 * rpc_update_borrador_con_comunidad), preservando compatibilidad total con
 * Bitácora, Validación, Panel Directivo e Inteligencia Cultural.
 */

import { dbV2 } from "./supabase-client.js";
import {
  loadOperationalUnits,
  loadActions,
  loadActionConfiguration,
  loadDemographicDefinition,
  resolveCaptureSpace,
} from "./catalogs.js?v=7.2.2";

const SECTION_TO_ACTION_CLAVE = Object.freeze({
  talleres_cc: "PB3562_2602",
  salones: "PB3562_2602",
  verano: "PB3562_2602",
  capacitaciones: "PB3562_2601",
  reuniones: "PB3563_2602",
  talento_local: "PB3563_2601",
  proyectos_colab: "PB3564_2601",
  eventos_mpales: "PB3564_2602",
});

let cloudCtxPromise = null;
let cloudCtx = null;

function toInt(val) {
  const n = Number.parseInt(val, 10);
  return Number.isFinite(n) && n > 0 ? n : 0;
}

function normalizeKey(str) {
  return String(str || "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toUpperCase()
    .trim();
}

/**
 * Inicializa y cachea la estructura CDCM (unidad, acciones, configuraciones y
 * opciones demográficas OFICIAL_2026) desde Supabase.
 */
export async function ensureMatrixCloudContext(context) {
  if (cloudCtx) return cloudCtx;
  if (cloudCtxPromise) return cloudCtxPromise;

  cloudCtxPromise = (async () => {
    const units = await loadOperationalUnits(context);
    const cdcmUnit =
      units.find((u) => normalizeKey(u.clave) === "CDCM") || units[0];
    if (!cdcmUnit) {
      throw new Error("No se encontró la unidad operativa CDCM en catálogos.");
    }

    const actions = await loadActions(cdcmUnit.id);
    if (!actions || actions.length === 0) {
      throw new Error("No hay acciones operativas activas para CDCM.");
    }

    const actionByClave = new Map();
    for (const a of actions) {
      actionByClave.set(normalizeKey(a.clave), a);
    }

    const configByActionId = new Map();
    const demoOptionMapBySchema = new Map();

    for (const secKey of Object.values(SECTION_TO_ACTION_CLAVE)) {
      const action = actionByClave.get(secKey) || actions[0];
      if (!action || configByActionId.has(action.id)) continue;

      try {
        const cfg = await loadActionConfiguration(action.id);
        if (cfg) {
          configByActionId.set(action.id, cfg);
          if (
            cfg.esquema_demografico_id &&
            !demoOptionMapBySchema.has(cfg.esquema_demografico_id)
          ) {
            const groups = await loadDemographicDefinition(
              cfg.esquema_demografico_id
            );
            const optionMap = new Map();
            for (const g of groups) {
              for (const opt of g.options || []) {
                optionMap.set(normalizeKey(opt.clave), opt.id);
              }
            }
            demoOptionMapBySchema.set(cfg.esquema_demografico_id, optionMap);
          }
        }
      } catch (err) {
        console.warn("Configuración de acción no disponible:", action.clave, err);
      }
    }

    cloudCtx = {
      unit: cdcmUnit,
      actions,
      actionByClave,
      configByActionId,
      demoOptionMapBySchema,
      spaceCache: new Map(),
    };
    return cloudCtx;
  })();

  try {
    return await cloudCtxPromise;
  } catch (err) {
    cloudCtxPromise = null;
    throw err;
  }
}

function buildDemographyArray(row, optionMap, totalPeople) {
  if (!optionMap || optionMap.size === 0 || totalPeople <= 0) return [];

  const sumM =
    toInt(row.pi_m) +
    toInt(row.inf_m) +
    toInt(row.ado_m) +
    toInt(row.jov_m) +
    toInt(row.adu_m) +
    toInt(row.may_m);
  const sumH =
    toInt(row.pi_h) +
    toInt(row.inf_h) +
    toInt(row.ado_h) +
    toInt(row.jov_h) +
    toInt(row.adu_h) +
    toInt(row.may_h);

  const buckets = [
    ["MUJERES", sumM],
    ["HOMBRES", sumH],
    ["PRIMERA_INFANCIA_0_5", toInt(row.pi_m) + toInt(row.pi_h)],
    ["NINAS_NINOS_6_12", toInt(row.inf_m) + toInt(row.inf_h)],
    ["ADOLESCENTES_13_17", toInt(row.ado_m) + toInt(row.ado_h)],
    ["JOVENES_18_29", toInt(row.jov_m) + toInt(row.jov_h)],
    ["ADULTOS_30_59", toInt(row.adu_m) + toInt(row.adu_h)],
    ["ADULTOS_MAYORES_60_MAS", toInt(row.may_m) + toInt(row.may_h)],
  ];

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

async function resolveSpaceCached(ctx, municipalityId, unitId, rawName) {
  const clean = String(rawName || "").trim() || "Casa de la Cultura";
  const cacheKey = `${municipalityId}::${normalizeKey(clean)}`;
  if (ctx.spaceCache.has(cacheKey)) {
    return ctx.spaceCache.get(cacheKey);
  }
  const space = await resolveCaptureSpace({
    municipalityId,
    unitId,
    name: clean,
  });
  if (space?.id) {
    ctx.spaceCache.set(cacheKey, space.id);
    return space.id;
  }
  return null;
}

/**
 * Sincroniza con Supabase las filas nuevas o modificadas de un mes.
 */
export async function syncMonthRowsToCloud({
  context,
  municipalityId,
  municipalityName,
  year,
  monthNum,
  elabora,
  identity,
  sections,
  sectionsData,
  isRowUsed,
  rowTotalPeople,
}) {
  if (!municipalityId || String(municipalityId).startsWith("local-")) {
    return { synced: 0, created: 0, updated: 0, skipped: 0, errors: [] };
  }

  const ctx = await ensureMatrixCloudContext(context);
  const defaultMonthDate = `${year}-${String(monthNum).padStart(2, "0")}-01`;

  let created = 0;
  let updated = 0;
  let skipped = 0;
  const errors = [];

  for (const sec of sections) {
    const rows = sectionsData[sec.id] || [];
    const targetClave = SECTION_TO_ACTION_CLAVE[sec.id] || "PB3562_2602";
    const action = ctx.actionByClave.get(targetClave) || ctx.actions[0];
    const config = ctx.configByActionId.get(action?.id);

    if (!action || !config) {
      errors.push(`Sin configuración para sección ${sec.jumpLabel}`);
      continue;
    }

    const optionMap = ctx.demoOptionMapBySchema.get(
      config.esquema_demografico_id
    );

    for (const r of rows) {
      if (!isRowUsed(r)) continue;

      // Filas enviadas a revisión o validadas quedan protegidas
      if (r.estatus === "VALIDADO" || r.estatus === "EN_REVISION") {
        skipped += 1;
        continue;
      }

      // Si ya está en la nube y no tiene cambios pendientes, omitir
      if (r.recordId && !r._dirty) {
        skipped += 1;
        continue;
      }

      const totalPeople = rowTotalPeople(r);
      const fechaInicio = r.inicio || r.fecha || defaultMonthDate;
      const fechaFin = r.fin || fechaInicio;

      let comunidadId = null;
      if (r.zona !== "CABECERA" && r.asentamientoId && !String(r.asentamientoId).startsWith("local-")) {
        comunidadId = r.asentamientoId;
      }

      let espacioId = null;
      if (config.requiere_espacio) {
        try {
          espacioId = await resolveSpaceCached(
            ctx,
            municipalityId,
            ctx.unit.id,
            r.sede || (sec.id === "talleres_cc" ? "Casa de la Cultura" : "Espacio Municipal")
          );
        } catch (err) {
          console.warn("No se pudo resolver espacio:", err);
        }
      }

      const metadata = {
        frontend: {
          version: "8.4.0",
          capture_module: "excel_matrix_2026",
        },
        libro_excel_2026: {
          year: String(year),
          month: String(monthNum).padStart(2, "0"),
          sectionId: sec.id,
          rowClientId: r.id,
          elabora: elabora || "",
          zona: r.zona || "CABECERA",
          asentamientoNombre: r.asentamientoNombre || "",
          sede: r.sede || "",
          tipo: r.tipo || "",
          temporalidad: r.temporalidad || "",
          dias: r.dias || {},
          horario: r.horario || "",
          costo: r.costo || "",
          docente: r.docente || "",
          demografia_matrix: {
            pi_m: toInt(r.pi_m),
            pi_h: toInt(r.pi_h),
            inf_m: toInt(r.inf_m),
            inf_h: toInt(r.inf_h),
            ado_m: toInt(r.ado_m),
            ado_h: toInt(r.ado_h),
            jov_m: toInt(r.jov_m),
            jov_h: toInt(r.jov_h),
            adu_m: toInt(r.adu_m),
            adu_h: toInt(r.adu_h),
            may_m: toInt(r.may_m),
            may_h: toInt(r.may_h),
          },
          recursoEst: r.recursoEst || "",
          recursoMun: r.recursoMun || "",
        },
        source_labels: {
          unidad: ctx.unit.nombre || "CDCM",
          accion: action.nombre,
          municipio: municipalityName,
          sede: r.sede || "Casa de la Cultura",
        },
      };

      const isTaller = ["TALLER", "CAPACITACION"].includes(
        String(config.tipo_formulario || "").toUpperCase()
      );

      const recordPayload = {
        unidad_operativa_id: ctx.unit.id,
        programa_id: action.programa_id,
        accion_id: action.id,
        configuracion_accion_id: config.id,
        municipio_id: municipalityId,
        comunidad_id: comunidadId,
        espacio_id: espacioId,
        nombre: String(r.titulo || sec.jumpLabel).trim(),
        descripcion: String(r.subtitulo || "").trim() || null,
        fecha_inicio: fechaInicio,
        fecha_fin: fechaFin,
        total_beneficiarios: totalPeople,
        total_participantes: totalPeople,
        total_accesos: totalPeople,
        metadata,
        responsable: {
          nombre: elabora || identity?.name || "Enlace Municipal",
          cargo: "Enlace Municipal",
          correo: identity?.email || null,
          telefono: null,
        },
        taller: isTaller
          ? {
              disciplina: String(r.titulo || "").trim() || null,
              programacion: r.temporalidad || null,
              modalidad_cuota: r.costo ? "CUOTA" : "GRATUITO",
              costo: null,
              observaciones: [r.horario, r.docente].filter(Boolean).join(" · ") || null,
            }
          : null,
        demografia: config.requiere_demografia
          ? buildDemographyArray(r, optionMap, totalPeople)
          : [],
      };

      try {
        if (!r.recordId) {
          const { data, error } = await dbV2()
            .rpc("rpc_create_borrador_integral", { p_payload: recordPayload })
            .single();
          if (error) throw error;
          r.recordId = data.id;
          r.folio = data.folio;
          r.estatus = data.estatus || "BORRADOR";
          r.rowVersion = 1;
          r._dirty = false;
          created += 1;
        } else {
          const { data, error } = await dbV2()
            .rpc("rpc_update_borrador_con_comunidad", {
              p_registro_id: r.recordId,
              p_expected_row_version: r.rowVersion || 1,
              p_payload: recordPayload,
            })
            .single();
          if (error) throw error;
          r.rowVersion = data.row_version || (r.rowVersion || 1) + 1;
          r.estatus = data.estatus || r.estatus;
          r._dirty = false;
          updated += 1;
        }
      } catch (err) {
        console.warn("Error sincronizando fila con Supabase:", r.titulo, err);
        errors.push(`${r.titulo || sec.jumpLabel}: ${err?.message || "Error al guardar"}`);
      }
    }
  }

  return {
    synced: created + updated,
    created,
    updated,
    skipped,
    errors,
  };
}

/**
 * Carga registros guardados en Supabase para el municipio, año y mes activos,
 * reconstruyendo las filas del libro mensual.
 */
export async function fetchMonthRowsFromCloud({
  municipalityId,
  year,
  monthNum,
}) {
  if (!municipalityId || String(municipalityId).startsWith("local-")) {
    return null;
  }

  const { data, error } = await dbV2()
    .from("registros")
    .select(
      "id,folio,estatus,row_version,accion_id,municipio_id,comunidad_id,espacio_id,nombre,descripcion,fecha_inicio,fecha_fin,total_participantes,metadata"
    )
    .eq("municipio_id", municipalityId)
    .eq("periodo_anio", Number(year))
    .eq("periodo_mes", Number(monthNum))
    .is("deleted_at", null)
    .order("created_at", { ascending: true });

  if (error) {
    console.warn("No se pudieron leer registros de Supabase:", error);
    return null;
  }

  const bySection = {};
  let elaboraFound = "";

  for (const row of data || []) {
    const excelMeta = row.metadata?.libro_excel_2026;
    if (!excelMeta || !excelMeta.sectionId) continue;

    if (!bySection[excelMeta.sectionId]) {
      bySection[excelMeta.sectionId] = [];
    }
    if (!elaboraFound && excelMeta.elabora) {
      elaboraFound = excelMeta.elabora;
    }

    const dm = excelMeta.demografia_matrix || {};
    bySection[excelMeta.sectionId].push({
      id: excelMeta.rowClientId || row.id,
      recordId: row.id,
      folio: row.folio,
      estatus: row.estatus || "BORRADOR",
      rowVersion: row.row_version || 1,
      _dirty: false,
      titulo: row.nombre || "",
      subtitulo: row.descripcion || "",
      zona: excelMeta.zona || "CABECERA",
      asentamientoId: row.comunidad_id || "",
      asentamientoNombre: excelMeta.asentamientoNombre || "",
      sede: excelMeta.sede || "",
      tipo: excelMeta.tipo || "",
      temporalidad: excelMeta.temporalidad || "MENSUAL",
      inicio: row.fecha_inicio || "",
      fin: row.fecha_fin || "",
      fecha: row.fecha_inicio || "",
      dias: excelMeta.dias || {},
      horario: excelMeta.horario || "",
      costo: excelMeta.costo || "",
      docente: excelMeta.docente || "",
      pi_m: dm.pi_m || "",
      pi_h: dm.pi_h || "",
      inf_m: dm.inf_m || "",
      inf_h: dm.inf_h || "",
      ado_m: dm.ado_m || "",
      ado_h: dm.ado_h || "",
      jov_m: dm.jov_m || "",
      jov_h: dm.jov_h || "",
      adu_m: dm.adu_m || "",
      adu_h: dm.adu_h || "",
      may_m: dm.may_m || "",
      may_h: dm.may_h || "",
      recursoEst: excelMeta.recursoEst || "",
      recursoMun: excelMeta.recursoMun || "",
    });
  }

  return {
    bySection,
    elabora: elaboraFound,
    totalCloudRows: (data || []).length,
  };
}
