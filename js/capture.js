/**
 * VINCULACIÓN CULTURAL 2.0
 * capture.js
 *
 * Captura Operativa V2 — Fase 2.1.
 *
 * Guarda registros nuevos como BORRADOR.
 * No valida ni alimenta indicadores hasta completar el flujo posterior.
 */

import { dbV2 } from "./supabase-client.js";
import {
  loadOperationalUnits,
  loadPrograms,
  loadActions,
  loadMunicipalities,
  loadSpaces,
  loadActionConfiguration,
  loadDemographicDefinition,
} from "./catalogs.js";

let context = null;
let currentConfig = null;
let currentDemography = [];
let initialized = false;

const $ = (id) => document.getElementById(id);

const ui = {};

function fillSelect(
  element,
  rows,
  {
    placeholder = "Seleccione...",
    valueKey = "id",
    labelKey = "nombre",
  } = {}
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

function numberOrNull(value) {
  if (value === "" || value === null || value === undefined) {
    return null;
  }

  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0
    ? Math.trunc(parsed)
    : null;
}

function moneyOrNull(value) {
  if (value === "" || value === null || value === undefined) {
    return null;
  }

  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0
    ? parsed
    : null;
}

function selectedText(select) {
  return select?.selectedOptions?.[0]?.textContent?.trim() || "";
}

function showNotice(message, type = "info") {
  ui.captureNotice.hidden = false;
  ui.captureNotice.dataset.type = type;
  ui.captureNotice.textContent = message;
}

function clearNotice() {
  ui.captureNotice.hidden = true;
  ui.captureNotice.textContent = "";
}

function setBusy(busy) {
  ui.saveDraftButton.disabled = busy;
  ui.saveDraftButton.textContent = busy
    ? "Guardando..."
    : "Guardar borrador V2";
}

function renderConfigSummary(config) {
  if (!config) {
    ui.configSummary.textContent =
      "No existe configuración vigente para esta acción y fecha.";
    ui.configSummary.className = "capture-config capture-config-warn";
    return;
  }

  const source =
    config.configuracion_extra?.clave_proceso ||
    "configuración operativa";

  ui.configSummary.textContent =
    `${config.tipo_formulario} · ${source}` +
    (config.requiere_validacion
      ? " · requiere validación"
      : "");

  ui.configSummary.className = "capture-config";
}

function toggleSpecializedFields(config) {
  const formType = String(
    config?.tipo_formulario ?? ""
  ).toUpperCase();

  const isTraining =
    formType === "TALLER" ||
    formType === "CAPACITACION";

  ui.trainingFields.hidden = !isTraining;

  ui.demographySection.hidden =
    !config?.requiere_demografia;

  ui.spaceSelectWrap.hidden =
    !config?.requiere_espacio;

  ui.spaceTextLabel.textContent =
    config?.requiere_espacio
      ? "Sede / espacio (si no aparece catalogado)"
      : "Lugar / sede (opcional)";
}

function createDemographicInput(
  universe,
  universeLabel,
  dimension,
  option
) {
  const wrapper = document.createElement("div");
  wrapper.className = "demographic-input";

  const label = document.createElement("label");
  label.textContent = option.nombre;

  const input = document.createElement("input");
  input.type = "number";
  input.min = "0";
  input.step = "1";
  input.inputMode = "numeric";
  input.placeholder = "0";

  input.dataset.universe = universe;
  input.dataset.optionId = option.id;
  input.dataset.dimensionKey = dimension.clave;

  wrapper.append(label, input);
  return wrapper;
}

function renderDemography(groups) {
  ui.demographyContainer.replaceChildren();

  if (!groups.length) {
    const empty = document.createElement("p");
    empty.className = "capture-muted";
    empty.textContent =
      "La configuración no tiene opciones demográficas habilitadas.";
    ui.demographyContainer.appendChild(empty);
    return;
  }

  const universes = [
    {
      key: "PARTICIPANTES",
      label: "Personas que participan",
    },
    {
      key: "ACCESOS",
      label: "Personas que acceden",
    },
  ];

  for (const universe of universes) {
    const universeCard = document.createElement("div");
    universeCard.className = "demographic-universe";

    const title = document.createElement("h4");
    title.textContent = universe.label;

    const help = document.createElement("p");
    help.textContent =
      "Cada dimensión se interpreta por separado. " +
      "No se suman Género + Grupo etario + Grupo prioritario.";

    universeCard.append(title, help);

    for (const dimension of groups) {
      const section = document.createElement("section");
      section.className = "demographic-dimension";

      const heading = document.createElement("h5");
      heading.textContent = dimension.nombre;

      const grid = document.createElement("div");
      grid.className = "demographic-grid";

      for (const option of dimension.options) {
        grid.appendChild(
          createDemographicInput(
            universe.key,
            universe.label,
            dimension,
            option
          )
        );
      }

      section.append(heading, grid);
      universeCard.appendChild(section);
    }

    ui.demographyContainer.appendChild(universeCard);
  }
}

async function refreshPrograms() {
  const unitId = ui.unit.value;

  fillSelect(ui.program, [], {
    placeholder: unitId
      ? "Cargando programas..."
      : "Seleccione primero una unidad",
  });

  fillSelect(ui.action, [], {
    placeholder: "Seleccione primero un programa",
  });

  currentConfig = null;
  currentDemography = [];
  renderConfigSummary(null);
  toggleSpecializedFields(null);

  if (!unitId) return;

  const programs = await loadPrograms(unitId);

  fillSelect(ui.program, programs, {
    placeholder: "Seleccione programa...",
  });

  if (programs.length === 1) {
    ui.program.value = programs[0].id;
    await refreshActions();
  }
}

async function refreshActions() {
  const unitId = ui.unit.value;
  const programId = ui.program.value;

  fillSelect(ui.action, [], {
    placeholder:
      unitId && programId
        ? "Cargando acciones..."
        : "Seleccione primero un programa",
  });

  currentConfig = null;
  currentDemography = [];
  renderConfigSummary(null);
  toggleSpecializedFields(null);

  if (!unitId || !programId) return;

  const actions = await loadActions(
    unitId,
    programId,
    ui.startDate.value
  );

  fillSelect(ui.action, actions, {
    placeholder:
      actions.length > 0
        ? "Seleccione acción / proceso..."
        : "No hay acciones vigentes para esta fecha",
  });
}

async function refreshActionConfig() {
  const actionId = ui.action.value;
  const date = ui.startDate.value;

  currentConfig = null;
  currentDemography = [];

  renderConfigSummary(null);
  toggleSpecializedFields(null);
  ui.demographyContainer.replaceChildren();

  if (!actionId || !date) return;

  currentConfig = await loadActionConfiguration(
    actionId,
    date
  );

  renderConfigSummary(currentConfig);
  toggleSpecializedFields(currentConfig);

  if (
    currentConfig?.requiere_demografia &&
    currentConfig?.esquema_demografico_id
  ) {
    currentDemography =
      await loadDemographicDefinition(
        currentConfig.esquema_demografico_id
      );

    renderDemography(currentDemography);
  }
}

async function refreshSpaces() {
  const municipalityId = ui.municipality.value;
  const unitId = ui.unit.value;

  fillSelect(ui.space, [], {
    placeholder: municipalityId
      ? "Cargando espacios..."
      : "Seleccione primero municipio",
  });

  if (!municipalityId) return;

  const spaces = await loadSpaces(
    municipalityId,
    unitId || null
  );

  fillSelect(ui.space, spaces, {
    placeholder:
      spaces.length > 0
        ? "Seleccione espacio..."
        : "Sin espacios catalogados",
  });
}

function collectDemography() {
  return [...ui.demographyContainer.querySelectorAll(
    "input[data-option-id][data-universe]"
  )]
    .map((input) => ({
      opcion_poblacion_id: input.dataset.optionId,
      universo: input.dataset.universe,
      cantidad: numberOrNull(input.value),
    }))
    .filter(
      (row) =>
        row.cantidad !== null &&
        row.cantidad > 0
    );
}

function validateBeforeSave() {
  if (!ui.unit.value) {
    throw new Error("Selecciona la unidad operativa.");
  }

  if (!ui.program.value) {
    throw new Error("Selecciona el programa.");
  }

  if (!ui.action.value) {
    throw new Error("Selecciona la acción / proceso.");
  }

  if (!ui.startDate.value) {
    throw new Error("Captura la fecha de la actividad.");
  }

  if (!currentConfig) {
    throw new Error(
      "La acción seleccionada no tiene configuración vigente para esa fecha."
    );
  }

  if (
    currentConfig.requiere_municipio &&
    !ui.municipality.value
  ) {
    throw new Error("Selecciona el municipio.");
  }

  if (!ui.activityName.value.trim()) {
    throw new Error(
      "Captura el nombre de la actividad."
    );
  }

  if (
    currentConfig.requiere_espacio &&
    !ui.space.value &&
    !ui.spaceText.value.trim()
  ) {
    throw new Error(
      "Indica el espacio o sede de la actividad."
    );
  }
}

async function insertWorkshopDetail(registrationId) {
  const formType = String(
    currentConfig?.tipo_formulario ?? ""
  ).toUpperCase();

  if (
    formType !== "TALLER" &&
    formType !== "CAPACITACION"
  ) {
    return;
  }

  const payload = {
    registro_id: registrationId,
    disciplina:
      ui.discipline.value.trim() || null,
    programacion:
      ui.programming.value || null,
    modalidad_cuota:
      ui.feeMode.value || null,
    costo:
      ui.feeMode.value === "CUOTA"
        ? moneyOrNull(ui.cost.value)
        : null,
    moneda: "MXN",
    observaciones:
      ui.trainingNotes.value.trim() || null,
  };

  const { error } = await dbV2()
    .from("registro_taller")
    .insert(payload);

  if (error) throw error;
}

async function insertDemography(registrationId) {
  if (!currentConfig?.requiere_demografia) {
    return;
  }

  const rows = collectDemography();

  if (!rows.length) return;

  const payload = rows.map((row) => ({
    registro_id: registrationId,
    opcion_poblacion_id:
      row.opcion_poblacion_id,
    universo: row.universo,
    cantidad: row.cantidad,
    observaciones:
      "Captura directa V2; no inferida automáticamente.",
  }));

  const { error } = await dbV2()
    .from("registro_poblacion")
    .insert(payload);

  if (error) throw error;
}

async function saveDraft(event) {
  event.preventDefault();

  clearNotice();
  setBusy(true);

  let created = null;

  try {
    validateBeforeSave();

    const date = new Date(
      `${ui.startDate.value}T12:00:00`
    );

    const participants =
      numberOrNull(ui.totalParticipants.value);

    const access =
      numberOrNull(ui.totalAccess.value);

    const beneficiaries =
      numberOrNull(ui.totalBeneficiaries.value);

    const metadata = {
      frontend: {
        version: "2.1-phase2.1",
        capture_module: "core",
      },
      location_text: {
        sede:
          ui.spaceText.value.trim() || null,
      },
      source_labels: {
        unidad: selectedText(ui.unit),
        programa: selectedText(ui.program),
        accion: selectedText(ui.action),
        municipio: selectedText(ui.municipality),
        espacio: selectedText(ui.space),
      },
    };

    const recordPayload = {
      unidad_operativa_id: ui.unit.value,
      programa_id: ui.program.value,
      accion_id: ui.action.value,
      tipo_registro_id:
        currentConfig.tipo_registro_id,
      configuracion_accion_id:
        currentConfig.id,

      municipio_id:
        ui.municipality.value || null,
      espacio_id:
        ui.space.value || null,

      nombre: ui.activityName.value.trim(),
      descripcion:
        ui.description.value.trim() || null,

      fecha_inicio: ui.startDate.value,
      fecha_fin:
        ui.endDate.value || ui.startDate.value,

      periodo_anio: date.getFullYear(),
      periodo_mes: date.getMonth() + 1,

      total_beneficiarios: beneficiaries,
      total_participantes: participants,
      total_accesos: access,

      esquema_demografico_id:
        currentConfig.esquema_demografico_id ||
        null,

      estatus: "BORRADOR",
      origen: "MANUAL",

      metadata,
    };

    const { data, error } = await dbV2()
      .from("registros")
      .insert(recordPayload)
      .select("id,folio,estatus")
      .single();

    if (error) throw error;

    created = data;

    try {
      await insertWorkshopDetail(created.id);
      await insertDemography(created.id);
    } catch (detailError) {
      console.error(
        "Detalle V2 después de crear núcleo:",
        detailError
      );

      showNotice(
        `Se creó el borrador ${created.folio}, pero un detalle secundario ` +
        `no pudo guardarse. El registro permanece en BORRADOR para revisión. ` +
        `Detalle: ${detailError.message}`,
        "warning"
      );

      await Swal.fire({
        icon: "warning",
        title: "Borrador creado con detalle pendiente",
        text:
          `${created.folio} quedó guardado. ` +
          "No lo valides hasta corregir el detalle indicado.",
      });

      return;
    }

    showNotice(
      `Borrador ${created.folio} guardado correctamente en V2.`,
      "success"
    );

    await Swal.fire({
      icon: "success",
      title: "Borrador V2 guardado",
      text:
        `${created.folio} quedó registrado como BORRADOR. ` +
        "Todavía no alimenta indicadores.",
    });

    ui.form.reset();
    setDefaultDates();
    currentConfig = null;
    currentDemography = [];
    renderConfigSummary(null);
    toggleSpecializedFields(null);
    ui.demographyContainer.replaceChildren();

    await populateInitialCatalogs();

  } catch (error) {
    console.error("Guardar borrador V2:", error);

    showNotice(
      error?.message ?? "No se pudo guardar el borrador.",
      "error"
    );

    await Swal.fire({
      icon: "error",
      title: "No se pudo guardar",
      text:
        error?.message ??
        "Ocurrió un error al guardar el borrador V2.",
    });
  } finally {
    setBusy(false);
  }
}

function setDefaultDates() {
  const today = new Date();
  const iso = today.toISOString().slice(0, 10);

  ui.startDate.value = iso;
  ui.endDate.value = iso;
}

async function populateInitialCatalogs() {
  clearNotice();

  const [units, municipalities] =
    await Promise.all([
      loadOperationalUnits(context),
      loadMunicipalities(context),
    ]);

  fillSelect(ui.unit, units, {
    placeholder: "Seleccione unidad operativa...",
  });

  fillSelect(ui.municipality, municipalities, {
    placeholder: "Seleccione municipio...",
    labelKey: "nombre_oficial",
  });

  fillSelect(ui.program, [], {
    placeholder: "Seleccione primero una unidad",
  });

  fillSelect(ui.action, [], {
    placeholder: "Seleccione primero un programa",
  });

  fillSelect(ui.space, [], {
    placeholder: "Seleccione primero municipio",
  });

  if (units.length === 1) {
    ui.unit.value = units[0].id;
    await refreshPrograms();
  }

  if (municipalities.length === 1) {
    ui.municipality.value =
      municipalities[0].id;
    await refreshSpaces();
  }

  if (!units.length) {
    showNotice(
      "Tu perfil no tiene una unidad operativa habilitada para captura.",
      "warning"
    );
  }
}

export async function initCaptureV2(authContext) {
  context = authContext;

  Object.assign(ui, {
    form: $("captureV2Form"),
    unit: $("captureUnit"),
    program: $("captureProgram"),
    action: $("captureAction"),
    municipality: $("captureMunicipality"),
    space: $("captureSpace"),
    spaceSelectWrap: $("captureSpaceSelectWrap"),
    spaceText: $("captureSpaceText"),
    spaceTextLabel: $("captureSpaceTextLabel"),

    activityName: $("captureActivityName"),
    description: $("captureDescription"),
    startDate: $("captureStartDate"),
    endDate: $("captureEndDate"),

    totalBeneficiaries: $("captureTotalBeneficiaries"),
    totalParticipants: $("captureTotalParticipants"),
    totalAccess: $("captureTotalAccess"),

    configSummary: $("captureConfigSummary"),

    trainingFields: $("captureTrainingFields"),
    discipline: $("captureDiscipline"),
    programming: $("captureProgramming"),
    feeMode: $("captureFeeMode"),
    cost: $("captureCost"),
    trainingNotes: $("captureTrainingNotes"),

    demographySection: $("captureDemographySection"),
    demographyContainer: $("captureDemographyContainer"),

    saveDraftButton: $("captureSaveDraft"),
    captureNotice: $("captureNotice"),
  });

  if (!ui.form) {
    throw new Error(
      "CAPTURE_V2_FORM_NOT_FOUND"
    );
  }

  if (!initialized) {
    ui.unit.addEventListener(
      "change",
      async () => {
        await refreshPrograms();
        await refreshSpaces();
      }
    );

    ui.program.addEventListener(
      "change",
      refreshActions
    );

    ui.action.addEventListener(
      "change",
      refreshActionConfig
    );

    ui.startDate.addEventListener(
      "change",
      async () => {
        if (!ui.endDate.value) {
          ui.endDate.value =
            ui.startDate.value;
        }

        // La fecha determina qué acciones/configuraciones son válidas.
        await refreshActions();
      }
    );

    ui.municipality.addEventListener(
      "change",
      refreshSpaces
    );

    ui.feeMode.addEventListener(
      "change",
      () => {
        const showCost =
          ui.feeMode.value === "CUOTA";

        ui.cost.disabled = !showCost;

        if (!showCost) {
          ui.cost.value = "";
        }
      }
    );

    ui.form.addEventListener(
      "submit",
      saveDraft
    );

    initialized = true;
  }

  setDefaultDates();
  toggleSpecializedFields(null);
  await populateInitialCatalogs();
}
