/**
 * VINCULACIÓN CULTURAL 2.0
 * evidence.js
 *
 * Evidencia privada V2.
 *
 * Ruta:
 *   unidad_uuid/registro_uuid/archivo_uuid.ext
 *
 * Bucket:
 *   evidencias-v2
 */

import {
  dbV2,
  evidenceStorage,
} from "./supabase-client.js";

const MAX_BYTES = 10 * 1024 * 1024;

const ALLOWED_MIME = new Set([
  "image/jpeg",
  "image/png",
  "image/webp",
  "application/pdf",
]);

function extensionFor(file) {
  const name = String(file?.name ?? "");
  const match = name.match(/\.([a-zA-Z0-9]{1,10})$/);

  if (match) {
    return match[1].toLowerCase();
  }

  const byMime = {
    "image/jpeg": "jpg",
    "image/png": "png",
    "image/webp": "webp",
    "application/pdf": "pdf",
  };

  return byMime[file?.type] ?? "bin";
}

export function validateEvidenceFile(file) {
  if (!file) {
    throw new Error(
      "Selecciona un archivo."
    );
  }

  if (file.size <= 0) {
    throw new Error(
      "El archivo está vacío."
    );
  }

  if (file.size > MAX_BYTES) {
    throw new Error(
      "La evidencia excede 10 MB."
    );
  }

  if (!ALLOWED_MIME.has(file.type)) {
    throw new Error(
      "Tipo no permitido. Usa JPG, PNG, WEBP o PDF."
    );
  }

  return true;
}

export async function uploadEvidence({
  recordId,
  unitId,
  file,
  type = "FOTOGRAFIA",
}) {
  validateEvidenceFile(file);

  if (!recordId || !unitId) {
    throw new Error(
      "No se pudo determinar registro/unidad."
    );
  }

  const fileId = crypto.randomUUID();
  const ext = extensionFor(file);

  const path =
    `${unitId}/${recordId}/${fileId}.${ext}`;

  const storage = evidenceStorage();

  const {
    data: storageData,
    error: storageError,
  } = await storage.upload(
    path,
    file,
    {
      cacheControl: "3600",
      contentType: file.type,
      upsert: false,
    }
  );

  if (storageError) {
    throw storageError;
  }

  const canonicalPath =
    storageData?.path || path;

  const {
    data: metadata,
    error: metadataError,
  } = await dbV2()
    .from("registro_evidencias")
    .insert({
      registro_id: recordId,
      tipo_evidencia: type,
      bucket_id: "evidencias-v2",
      storage_path: canonicalPath,
      nombre_original: file.name,
      mime_type: file.type,
      size_bytes: file.size,
      metadata: {
        frontend: "phase4-draft-editor",
      },
    })
    .select(
      "id,tipo_evidencia,bucket_id,storage_path,nombre_original,mime_type,size_bytes,created_at"
    )
    .single();

  if (metadataError) {
    const error = new Error(
      "El archivo subió a Storage, pero no se pudo registrar su metadata. " +
      metadataError.message
    );

    error.cause = metadataError;
    throw error;
  }

  return metadata;
}

export async function createEvidenceSignedUrl(
  storagePath,
  expiresIn = 120
) {
  if (!storagePath) {
    throw new Error(
      "La evidencia no tiene ruta."
    );
  }

  const {
    data,
    error,
  } = await evidenceStorage()
    .createSignedUrl(
      storagePath,
      expiresIn
    );

  if (error) throw error;

  return data?.signedUrl ?? null;
}

export async function deactivateEvidence(
  evidenceId
) {
  if (!evidenceId) {
    throw new Error(
      "Evidencia inválida."
    );
  }

  const { error } = await dbV2()
    .from("registro_evidencias")
    .update({
      activo: false,
    })
    .eq("id", evidenceId);

  if (error) throw error;

  return true;
}
