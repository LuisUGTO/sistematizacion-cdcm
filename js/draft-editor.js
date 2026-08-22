/**
 * VINCULACIÓN CULTURAL 2.0
 * draft-editor.js
 *
 * Completar/editar BORRADOR manual y enviarlo a revisión.
 */

import { dbV2 } from "./supabase-client.js";

import {
  loadMunicipalities,
  loadSpaces,
  loadDemographicDefinition,
} from "./catalogs.js";

import {
  uploadEvidence,
  createEvidenceSignedUrl,
} from "./evidence.js";

let context = null;
let initialized = false;

let state = {
  recordId: null,
  rowVersion: null,
  data: null,
  demographics: [],
};

const ui = {};

const $ = (id) =>
  document.getElementById(id);

function setText(element, value) {
  element.textContent =
    String(value ?? "").trim() || "—";
}

function numberOrNull(value) {
  if (
    value === "" ||
    value === null ||
    value === undefined
  ) {
    return null;
  }

  const n = Number(value);

  if (
    !Number.isFinite(n) ||
    n < 0
  ) {
    return null;
  }

  return Math.trunc(n);
}

function moneyOrNull(value) {
  if (
    value === "" ||
    value === null ||
    value === undefined
  ) {
    return null;
  }

  const n = Number(value);

  return Number.isFinite(n) && n >= 0
    ? n
    : null;
}

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

  const empty =
    document.createElement("option");

  empty.value = "";
  empty.textContent = placeholder;

  element.appendChild(empty);

  for (const row of rows) {
    const option =
      document.createElement("option");

    option.value = row[valueKey];
    option.textContent =
      row[labelKey];

    element.appendChild(option);
  }
}

function showMessage(
  message,
  type = "info"
) {
  ui.notice.hidden = false;
  ui.notice.dataset.type = type;
  ui.notice.textContent = message;
}

function clearMessage() {
  ui.notice.hidden = true;
  ui.notice.textContent = "";
}

function openOverlay() {
  ui.overlay.hidden = false;
  document.body.style.overflow = "hidden";
}

function closeOverlay() {
  ui.overlay.hidden = true;
  document.body.style.overflow = "";
}

function setBusy(busy) {
  ui.save.disabled = busy;
  ui.submit.disabled = busy;
  ui.close.disabled = busy;
}

function configLabel(config) {
  const key =
    config?.configuracion_extra
      ?.clave_proceso;

  return [
    config?.tipo_formulario,
    key,
    config?.requiere_evidencia
      ? "evidencia requerida"
      : null,
    config?.requiere_validacion
      ? "validación requerida"
      : null,
  ]
    .filter(Boolean)
    .join(" · ");
}

function createDemographicInput(
  universe,
  dimension,
  option,
  currentMap
) {
  const wrap =
    document.createElement("div");

  wrap.className =
    "draft-demo-input";

  const label =
    document.createElement("label");

  label.textContent =
    option.nombre;

  const input =
    document.createElement("input");

  input.type = "number";
  input.min = "0";
  input.step = "1";
  input.inputMode = "numeric";

  input.dataset.universe =
    universe;

  input.dataset.optionId =
    option.id;

  const key =
    `${universe}:${option.id}`;

  input.value =
    currentMap.get(key) ?? "";

  wrap.append(label, input);

  return wrap;
}

function renderDemography(
  groups,
  currentRows
) {
  ui.demoContainer.replaceChildren();

  if (!groups.length) {
    ui.demoSection.hidden = true;
    return;
  }

  ui.demoSection.hidden = false;

  const currentMap =
    new Map(
      (currentRows ?? []).map(
        (row) => [
          `${row.universo}:${row.opcion_poblacion_id}`,
          row.cantidad,
        ]
      )
    );

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
    const block =
      document.createElement("div");

    block.className =
      "draft-demo-universe";

    const title =
      document.createElement("h4");

    title.textContent =
      universe.label;

    block.appendChild(title);

    for (const dimension of groups) {
      const section =
        document.createElement("section");

      const heading =
        document.createElement("h5");

      heading.textContent =
        dimension.nombre;

      const grid =
        document.createElement("div");

      grid.className =
        "draft-demo-grid";

      for (
        const option
        of dimension.options
      ) {
        grid.appendChild(
          createDemographicInput(
            universe.key,
            dimension,
            option,
            currentMap
          )
        );
      }

      section.append(
        heading,
        grid
      );

      block.appendChild(section);
    }

    ui.demoContainer.appendChild(
      block
    );
  }
}

function collectDemography() {
  return [
    ...ui.demoContainer
      .querySelectorAll(
        "input[data-universe][data-option-id]"
      ),
  ]
    .map((input) => ({
      opcion_poblacion_id:
        input.dataset.optionId,
      universo:
        input.dataset.universe,
      cantidad:
        numberOrNull(
          input.value
        ),
    }))
    .filter(
      (row) =>
        row.cantidad !== null &&
        row.cantidad > 0
    );
}

function renderEvidenceList(rows) {
  ui.evidenceList.replaceChildren();

  const evidences = rows ?? [];

  ui.evidenceCount.textContent =
    `${evidences.length} archivo(s)`;

  if (!evidences.length) {
    const empty =
      document.createElement("div");

    empty.className =
      "draft-evidence-empty";

    empty.textContent =
      "Todavía no hay evidencia activa.";

    ui.evidenceList.appendChild(empty);
    return;
  }

  for (const row of evidences) {
    const item =
      document.createElement("div");

    item.className =
      "draft-evidence-item";

    const copy =
      document.createElement("div");

    const name =
      document.createElement("strong");

    name.textContent =
      row.nombre_original ||
      row.tipo_evidencia ||
      "Evidencia";

    const meta =
      document.createElement("small");

    const kb =
      row.size_bytes
        ? Math.ceil(
            Number(row.size_bytes) /
            1024
          )
        : null;

    meta.textContent =
      [
        row.mime_type,
        kb ? `${kb} KB` : null,
      ]
        .filter(Boolean)
        .join(" · ");

    copy.append(
      name,
      meta
    );

    const open =
      document.createElement("button");

    open.type = "button";
    open.className =
      "btn-secondary";
    open.textContent = "Abrir";

    open.addEventListener(
      "click",
      async () => {
        try {
          const url =
            await createEvidenceSignedUrl(
              row.storage_path,
              120
            );

          if (!url) {
            throw new Error(
              "No se obtuvo URL temporal."
            );
          }

          window.open(
            url,
            "_blank",
            "noopener,noreferrer"
          );
        } catch (error) {
          await Swal.fire({
            icon: "error",
            title:
              "No se pudo abrir la evidencia",
            text:
              error?.message ??
              "Error de Storage.",
          });
        }
      }
    );

    item.append(
      copy,
      open
    );

    ui.evidenceList.appendChild(
      item
    );
  }
}

async function refreshSpaces(
  selectedId = null
) {
  const municipalityId =
    ui.municipality.value;

  fillSelect(
    ui.space,
    [],
    {
      placeholder:
        municipalityId
          ? "Cargando espacios..."
          : "Seleccione primero municipio",
    }
  );

  if (!municipalityId) {
    return;
  }

  const spaces =
    await loadSpaces(
      municipalityId,
      state.data?.record
        ?.unidad_operativa_id
    );

  fillSelect(
    ui.space,
    spaces,
    {
      placeholder:
        spaces.length
          ? "Seleccione espacio..."
          : "Sin espacios catalogados",
    }
  );

  if (
    selectedId &&
    [...ui.space.options].some(
      (option) =>
        option.value === selectedId
    )
  ) {
    ui.space.value =
      selectedId;
  }
}

async function renderEditor(data) {
  state.data = data;
  state.recordId =
    data.record.id;
  state.rowVersion =
    data.record.row_version;

  setText(
    ui.folio,
    data.record.folio
  );

  setText(
    ui.classification,
    [
      data.record.unidad_nombre,
      data.record.programa_nombre,
      data.record.accion_nombre,
    ]
      .filter(Boolean)
      .join(" · ")
  );

  setText(
    ui.config,
    configLabel(data.config)
  );

  ui.name.value =
    data.record.nombre ?? "";

  ui.description.value =
    data.record.descripcion ?? "";

  ui.startDate.value =
    data.record.fecha_inicio ?? "";

  ui.endDate.value =
    data.record.fecha_fin ??
    data.record.fecha_inicio ??
    "";

  ui.totalBeneficiaries.value =
    data.record.total_beneficiarios ??
    "";

  ui.totalParticipants.value =
    data.record.total_participantes ??
    "";

  ui.totalAccess.value =
    data.record.total_accesos ??
    "";

  ui.responsibleName.value =
    data.responsable?.nombre ??
    "";

  ui.responsibleEmail.value =
    data.responsable?.correo ??
    "";

  ui.responsiblePhone.value =
    data.responsable?.telefono ??
    "";

  ui.responsibleSection.hidden =
    !data.config
      ?.requiere_responsable;

  const municipalities =
    await loadMunicipalities(
      context
    );

  fillSelect(
    ui.municipality,
    municipalities,
    {
      placeholder:
        "Seleccione municipio...",
      labelKey:
        "nombre_oficial",
    }
  );

  if (
    data.record.municipio_id &&
    [...ui.municipality.options].some(
      (option) =>
        option.value ===
        data.record.municipio_id
    )
  ) {
    ui.municipality.value =
      data.record.municipio_id;
  }

  await refreshSpaces(
    data.record.espacio_id
  );

  ui.spaceWrap.hidden =
    !data.config?.requiere_espacio;

  const isTraining =
    ["TALLER", "CAPACITACION"]
      .includes(
        String(
          data.config
            ?.tipo_formulario ?? ""
        ).toUpperCase()
      );

  ui.trainingSection.hidden =
    !isTraining;

  ui.discipline.value =
    data.taller?.disciplina ??
    "";

  ui.programming.value =
    data.taller?.programacion ??
    "";

  ui.feeMode.value =
    data.taller
      ?.modalidad_cuota ??
    "";

  ui.cost.value =
    data.taller?.costo ??
    "";

  ui.cost.disabled =
    ui.feeMode.value !==
    "CUOTA";

  ui.trainingNotes.value =
    data.taller?.observaciones ??
    "";

  if (
    data.config
      ?.requiere_demografia &&
    data.record
      ?.esquema_demografico_id
  ) {
    state.demographics =
      await loadDemographicDefinition(
        data.record
          .esquema_demografico_id
      );

    renderDemography(
      state.demographics,
      data.demografia
    );
  } else {
    state.demographics = [];
    ui.demoSection.hidden = true;
    ui.demoContainer
      .replaceChildren();
  }

  ui.evidenceRequired.hidden =
    !data.config
      ?.requiere_evidencia;

  renderEvidenceList(
    data.evidencias
  );

  ui.submit.hidden =
    !data.permissions?.can_edit ||
    !["BORRADOR", "CORREGIDO"]
      .includes(
        data.record.estatus
      );

  ui.save.hidden =
    !data.permissions?.can_edit;

  clearMessage();
}

async function fetchEditor(
  recordId
) {
  const {
    data,
    error,
  } = await dbV2()
    .rpc(
      "rpc_get_registro_editor",
      {
        p_registro_id:
          recordId,
      }
    )
    .single();

  if (error) throw error;

  return data?.payload ?? null;
}

async function openRecord(
  recordId
) {
  setBusy(true);
  openOverlay();

  try {
    ui.title.textContent =
      "Cargando borrador...";

    const data =
      await fetchEditor(
        recordId
      );

    if (!data) {
      throw new Error(
        "El servidor no devolvió el registro."
      );
    }

    ui.title.textContent =
      "Completar borrador V2";

    await renderEditor(data);

  } catch (error) {
    console.error(
      "Editor de borrador:",
      error
    );

    await Swal.fire({
      icon: "error",
      title:
        "No se pudo abrir el borrador",
      text:
        error?.message ??
        "Error de Data API.",
    });

    closeOverlay();
  } finally {
    setBusy(false);
  }
}

function buildPayload() {
  return {
    nombre:
      ui.name.value.trim(),

    descripcion:
      ui.description.value
        .trim() || null,

    fecha_inicio:
      ui.startDate.value,

    fecha_fin:
      ui.endDate.value ||
      ui.startDate.value,

    municipio_id:
      ui.municipality.value ||
      null,

    espacio_id:
      ui.space.value ||
      null,

    total_beneficiarios:
      numberOrNull(
        ui.totalBeneficiaries
          .value
      ),

    total_participantes:
      numberOrNull(
        ui.totalParticipants
          .value
      ),

    total_accesos:
      numberOrNull(
        ui.totalAccess.value
      ),

    responsable: {
      nombre:
        ui.responsibleName
          .value.trim() ||
        null,

      correo:
        ui.responsibleEmail
          .value.trim() ||
        null,

      telefono:
        ui.responsiblePhone
          .value.trim() ||
        null,
    },

    taller:
      ui.trainingSection.hidden
        ? null
        : {
            disciplina:
              ui.discipline
                .value.trim() ||
              null,

            programacion:
              ui.programming.value ||
              null,

            modalidad_cuota:
              ui.feeMode.value ||
              null,

            costo:
              ui.feeMode.value ===
              "CUOTA"
                ? moneyOrNull(
                    ui.cost.value
                  )
                : null,

            observaciones:
              ui.trainingNotes
                .value.trim() ||
              null,
          },

    demografia:
      ui.demoSection.hidden
        ? []
        : collectDemography(),
  };
}

async function saveChanges() {
  clearMessage();
  setBusy(true);

  try {
    const {
      data,
      error,
    } = await dbV2()
      .rpc(
        "rpc_update_borrador",
        {
          p_registro_id:
            state.recordId,

          p_expected_row_version:
            state.rowVersion,

          p_payload:
            buildPayload(),
        }
      )
      .single();

    if (error) throw error;

    state.rowVersion =
      data.row_version;

    showMessage(
      `${data.folio} actualizado correctamente.`,
      "success"
    );

    window.dispatchEvent(
      new CustomEvent(
        "v2:record-updated",
        {
          detail: {
            id: state.recordId,
          },
        }
      )
    );

    const refreshed =
      await fetchEditor(
        state.recordId
      );

    await renderEditor(
      refreshed
    );

  } catch (error) {
    console.error(
      "Guardar cambios:",
      error
    );

    showMessage(
      error?.message ??
      "No se pudo actualizar.",
      "error"
    );
  } finally {
    setBusy(false);
  }
}

async function addEvidence() {
  const file =
    ui.evidenceFile.files?.[0];

  if (!file) {
    await Swal.fire({
      icon: "warning",
      title: "Selecciona un archivo",
      text:
        "Puedes usar JPG, PNG, WEBP o PDF de hasta 10 MB.",
    });

    return;
  }

  ui.uploadEvidence.disabled =
    true;

  ui.uploadEvidence.textContent =
    "Subiendo...";

  try {
    await uploadEvidence({
      recordId:
        state.recordId,

      unitId:
        state.data.record
          .unidad_operativa_id,

      file,
    });

    ui.evidenceFile.value = "";

    const refreshed =
      await fetchEditor(
        state.recordId
      );

    await renderEditor(
      refreshed
    );

    showMessage(
      "Evidencia privada registrada correctamente.",
      "success"
    );

  } catch (error) {
    console.error(
      "Evidencia:",
      error
    );

    await Swal.fire({
      icon: "error",
      title:
        "No se pudo cargar la evidencia",
      text:
        error?.message ??
        "Error de Storage.",
    });
  } finally {
    ui.uploadEvidence.disabled =
      false;

    ui.uploadEvidence.textContent =
      "Agregar evidencia";
  }
}

function humanizeQualityError(
  message
) {
  const raw =
    String(message ?? "");

  if (
    !raw.includes(
      "QUALITY_BLOCK:"
    )
  ) {
    return raw;
  }

  const codes =
    raw
      .split("QUALITY_BLOCK:")[1]
      ?.split(",")
      .map((item) =>
        item.trim()
      )
      .filter(Boolean) ??
    [];

  const labels = {
    SIN_FOLIO:
      "folio",
    SIN_NOMBRE:
      "nombre de actividad",
    SIN_CONFIGURACION_ACCION:
      "configuración de acción",
    SIN_MUNICIPIO:
      "municipio",
    SIN_COMUNIDAD:
      "comunidad",
    SIN_ESPACIO:
      "espacio cultural catalogado",
    SIN_RESPONSABLE:
      "persona responsable",
    SIN_TOTAL_BENEFICIARIOS:
      "total de beneficiarios",
    SIN_DEMOGRAFIA:
      "desagregación demográfica",
    SIN_EVIDENCIA:
      "evidencia",
  };

  return (
    "Antes de enviar a revisión completa: " +
    codes
      .map(
        (code) =>
          labels[code] ??
          code
      )
      .join(", ") +
    "."
  );
}

async function submitReview() {
  const confirmation =
    await Swal.fire({
      icon: "question",
      title:
        "¿Enviar a revisión?",
      text:
        "Después del envío ya no quedará como BORRADOR.",
      showCancelButton: true,
      confirmButtonText:
        "Sí, enviar",
      cancelButtonText:
        "Cancelar",
    });

  if (!confirmation.isConfirmed) {
    return;
  }

  setBusy(true);

  try {
    // Primero persistimos cualquier cambio visible.
    const saveResult =
      await dbV2()
        .rpc(
          "rpc_update_borrador",
          {
            p_registro_id:
              state.recordId,

            p_expected_row_version:
              state.rowVersion,

            p_payload:
              buildPayload(),
          }
        )
        .single();

    if (saveResult.error) {
      throw saveResult.error;
    }

    state.rowVersion =
      saveResult.data
        .row_version;

    const {
      data,
      error,
    } = await dbV2()
      .rpc(
        "rpc_submit_borrador",
        {
          p_registro_id:
            state.recordId,

          p_expected_row_version:
            state.rowVersion,
        }
      )
      .single();

    if (error) throw error;

    await Swal.fire({
      icon: "success",
      title:
        "Enviado a revisión",
      text:
        `${data.folio} ahora está EN REVISIÓN.`,
    });

    closeOverlay();

    window.dispatchEvent(
      new CustomEvent(
        "v2:record-updated",
        {
          detail: {
            id: state.recordId,
          },
        }
      )
    );

  } catch (error) {
    console.error(
      "Enviar a revisión:",
      error
    );

    await Swal.fire({
      icon: "warning",
      title:
        "El registro aún no puede enviarse",
      text:
        humanizeQualityError(
          error?.message ??
          "Faltan datos requeridos."
        ),
    });
  } finally {
    setBusy(false);
  }
}

export async function initDraftEditor(
  authContext
) {
  context = authContext;

  Object.assign(ui, {
    overlay:
      $("draftEditorOverlay"),
    title:
      $("draftEditorTitle"),
    close:
      $("draftEditorClose"),

    folio:
      $("draftEditorFolio"),
    classification:
      $("draftEditorClassification"),
    config:
      $("draftEditorConfig"),

    name:
      $("draftEditorName"),
    description:
      $("draftEditorDescription"),

    startDate:
      $("draftEditorStartDate"),
    endDate:
      $("draftEditorEndDate"),

    municipality:
      $("draftEditorMunicipality"),
    space:
      $("draftEditorSpace"),
    spaceWrap:
      $("draftEditorSpaceWrap"),

    totalBeneficiaries:
      $("draftEditorTotalBeneficiaries"),
    totalParticipants:
      $("draftEditorTotalParticipants"),
    totalAccess:
      $("draftEditorTotalAccess"),

    responsibleSection:
      $("draftEditorResponsibleSection"),
    responsibleName:
      $("draftEditorResponsibleName"),
    responsibleEmail:
      $("draftEditorResponsibleEmail"),
    responsiblePhone:
      $("draftEditorResponsiblePhone"),

    trainingSection:
      $("draftEditorTrainingSection"),
    discipline:
      $("draftEditorDiscipline"),
    programming:
      $("draftEditorProgramming"),
    feeMode:
      $("draftEditorFeeMode"),
    cost:
      $("draftEditorCost"),
    trainingNotes:
      $("draftEditorTrainingNotes"),

    demoSection:
      $("draftEditorDemoSection"),
    demoContainer:
      $("draftEditorDemoContainer"),

    evidenceRequired:
      $("draftEditorEvidenceRequired"),
    evidenceFile:
      $("draftEditorEvidenceFile"),
    uploadEvidence:
      $("draftEditorUploadEvidence"),
    evidenceList:
      $("draftEditorEvidenceList"),
    evidenceCount:
      $("draftEditorEvidenceCount"),

    notice:
      $("draftEditorNotice"),

    save:
      $("draftEditorSave"),
    submit:
      $("draftEditorSubmit"),
  });

  if (!ui.overlay) {
    throw new Error(
      "DRAFT_EDITOR_UI_NOT_FOUND"
    );
  }

  if (!initialized) {
    ui.close.addEventListener(
      "click",
      closeOverlay
    );

    ui.overlay.addEventListener(
      "click",
      (event) => {
        if (
          event.target ===
          ui.overlay
        ) {
          closeOverlay();
        }
      }
    );

    ui.municipality
      .addEventListener(
        "change",
        () =>
          refreshSpaces(null)
      );

    ui.feeMode
      .addEventListener(
        "change",
        () => {
          const enabled =
            ui.feeMode.value ===
            "CUOTA";

          ui.cost.disabled =
            !enabled;

          if (!enabled) {
            ui.cost.value = "";
          }
        }
      );

    ui.save.addEventListener(
      "click",
      saveChanges
    );

    ui.uploadEvidence
      .addEventListener(
        "click",
        addEvidence
      );

    ui.submit.addEventListener(
      "click",
      submitReview
    );

    window.addEventListener(
      "v2:edit-record",
      (event) => {
        const recordId =
          event.detail?.id;

        if (recordId) {
          openRecord(
            recordId
          );
        }
      }
    );

    initialized = true;
  }
}
