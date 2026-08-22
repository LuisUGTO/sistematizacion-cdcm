/**
 * VINCULACIÓN CULTURAL 2.0
 * catalogs.js
 *
 * Lectura de catálogos V2 gobernada por RLS.
 */

import { dbV2 } from "./supabase-client.js";
import { isAdmin } from "./permissions.js";

function throwIfError(result, label) {
  if (result.error) {
    const error = new Error(
      `${label}: ${result.error.message ?? "error de Data API"}`
    );
    error.cause = result.error;
    throw error;
  }
  return result.data ?? [];
}

function todayISO() {
  return new Date().toISOString().slice(0, 10);
}

export async function loadOperationalUnits(context) {
  const result = await dbV2()
    .from("cat_unidades_operativas")
    .select("id,clave,nombre,descripcion,orden")
    .eq("activo", true)
    .order("orden", { ascending: true })
    .order("nombre", { ascending: true });

  let rows = throwIfError(result, "cat_unidades_operativas");

  if (!isAdmin(context)) {
    const allowed = new Set(context?.scopes?.unitIds ?? []);
    rows = rows.filter((row) => allowed.has(row.id));
  }

  return rows;
}

export async function loadPrograms(unitId) {
  if (!unitId) return [];

  const result = await dbV2()
    .from("cat_programas")
    .select("id,unidad_operativa_id,clave,nombre,descripcion,orden")
    .eq("unidad_operativa_id", unitId)
    .eq("activo", true)
    .order("orden", { ascending: true })
    .order("nombre", { ascending: true });

  return throwIfError(result, "cat_programas");
}

export async function loadActions(unitId, programId = null) {
  if (!unitId) return [];

  let query = dbV2()
    .from("cat_acciones")
    .select(
      "id,unidad_operativa_id,programa_id,clave,nombre,descripcion,orden"
    )
    .eq("unidad_operativa_id", unitId)
    .eq("activo", true);

  if (programId) {
    query = query.eq("programa_id", programId);
  }

  const result = await query
    .order("orden", { ascending: true })
    .order("nombre", { ascending: true });

  return throwIfError(result, "cat_acciones");
}

export async function loadMunicipalities(context) {
  const result = await dbV2()
    .from("cat_municipios")
    .select("id,clave_inegi,nombre_oficial,region_id,orden")
    .eq("activo", true)
    .order("nombre_oficial", { ascending: true });

  let rows = throwIfError(result, "cat_municipios");

  if (!isAdmin(context)) {
    const allowed = new Set(context?.scopes?.municipalityIds ?? []);
    rows = rows.filter((row) => allowed.has(row.id));
  }

  return rows;
}

export async function loadSpaces(municipalityId, unitId = null) {
  if (!municipalityId) return [];

  let query = dbV2()
    .from("cat_espacios")
    .select(
      "id,nombre,direccion,municipio_id,unidad_operativa_id,comunidad_id"
    )
    .eq("municipio_id", municipalityId)
    .eq("activo", true);

  const result = await query.order("nombre", { ascending: true });
  let rows = throwIfError(result, "cat_espacios");

  if (unitId) {
    rows = rows.filter(
      (row) =>
        row.unidad_operativa_id === null ||
        row.unidad_operativa_id === unitId
    );
  }

  return rows;
}

export async function loadActionConfiguration(
  actionId,
  referenceDate = todayISO()
) {
  if (!actionId) return null;

  const result = await dbV2()
    .from("configuracion_acciones")
    .select(
      [
        "id",
        "accion_id",
        "tipo_registro_id",
        "tipo_formulario",
        "requiere_municipio",
        "requiere_comunidad",
        "requiere_espacio",
        "requiere_responsable",
        "requiere_docente",
        "requiere_beneficiarios",
        "requiere_demografia",
        "requiere_gps",
        "requiere_evidencia",
        "requiere_validacion",
        "permite_offline",
        "vigente_desde",
        "vigente_hasta",
        "configuracion_extra",
        "esquema_demografico_id",
      ].join(",")
    )
    .eq("accion_id", actionId)
    .eq("activo", true)
    .order("vigente_desde", { ascending: false });

  const rows = throwIfError(result, "configuracion_acciones");

  const ref = referenceDate || todayISO();

  return (
    rows.find((row) => {
      const fromOk = !row.vigente_desde || row.vigente_desde <= ref;
      const toOk = !row.vigente_hasta || row.vigente_hasta >= ref;
      return fromOk && toOk;
    }) ?? null
  );
}

export async function loadDemographicDefinition(schemaId) {
  if (!schemaId) return [];

  const [linksResult, optionsResult, dimensionsResult] = await Promise.all([
    dbV2()
      .from("esquema_opciones_poblacion")
      .select(
        "opcion_poblacion_id,etiqueta_override,orden"
      )
      .eq("esquema_id", schemaId)
      .eq("activo", true)
      .order("orden", { ascending: true }),

    dbV2()
      .from("cat_opciones_poblacion")
      .select(
        "id,dimension_id,clave,nombre,orden"
      )
      .eq("activo", true),

    dbV2()
      .from("cat_dimensiones_poblacion")
      .select("id,clave,nombre,orden")
      .eq("activo", true)
      .order("orden", { ascending: true }),
  ]);

  const links = throwIfError(
    linksResult,
    "esquema_opciones_poblacion"
  );
  const options = throwIfError(
    optionsResult,
    "cat_opciones_poblacion"
  );
  const dimensions = throwIfError(
    dimensionsResult,
    "cat_dimensiones_poblacion"
  );

  const optionById = new Map(
    options.map((row) => [row.id, row])
  );

  const dimensionById = new Map(
    dimensions.map((row) => [row.id, row])
  );

  const groups = new Map();

  for (const link of links) {
    const option = optionById.get(link.opcion_poblacion_id);
    if (!option) continue;

    const dimension = dimensionById.get(option.dimension_id);
    if (!dimension) continue;

    if (!groups.has(dimension.id)) {
      groups.set(dimension.id, {
        id: dimension.id,
        clave: dimension.clave,
        nombre: dimension.nombre,
        orden: dimension.orden ?? 0,
        options: [],
      });
    }

    groups.get(dimension.id).options.push({
      id: option.id,
      clave: option.clave,
      nombre:
        link.etiqueta_override ||
        option.nombre,
      orden: link.orden ?? option.orden ?? 0,
    });
  }

  return [...groups.values()]
    .sort((a, b) => a.orden - b.orden)
    .map((group) => ({
      ...group,
      options: group.options.sort(
        (a, b) => a.orden - b.orden
      ),
    }));
}
