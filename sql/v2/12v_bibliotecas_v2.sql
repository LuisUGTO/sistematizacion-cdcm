-- ============================================================================
-- ETAPA 7.3 - DIRECTORIO ESPECIALIZADO DE BIBLIOTECAS V2
-- Ejecutar una sola vez en Supabase SQL Editor.
-- ============================================================================
BEGIN;

DO $$ BEGIN
  IF to_regprocedure('v2_private.is_admin()') IS NULL
     OR to_regclass('v2.cat_espacios') IS NULL
     OR to_regclass('v2.cat_personas') IS NULL THEN
    RAISE EXCEPTION 'PRECONDICION: aplica primero la estructura y seguridad V2.';
  END IF;
END $$;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM v2.cat_tipos_espacio WHERE lower(btrim(clave))='biblioteca') THEN
    UPDATE v2.cat_tipos_espacio SET nombre='Biblioteca',activo=true,updated_at=now()
    WHERE lower(btrim(clave))='biblioteca';
  ELSE
    INSERT INTO v2.cat_tipos_espacio (clave,nombre,descripcion,orden,activo)
    VALUES ('BIBLIOTECA','Biblioteca','Biblioteca pública de la Red Estatal.',10,true);
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS v2.biblioteca_detalle (
  espacio_id UUID PRIMARY KEY REFERENCES v2.cat_espacios(id) ON DELETE CASCADE,
  numero_dgb TEXT,
  correo TEXT,
  telefono TEXT,
  horario TEXT,
  datos_extra_controlados JSONB NOT NULL DEFAULT '{}'::JSONB,
  activo BOOLEAN NOT NULL DEFAULT true,
  created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL DEFAULT auth.uid(),
  updated_by UUID REFERENCES auth.users(id) ON DELETE SET NULL DEFAULT auth.uid(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT ck_v2_biblioteca_correo CHECK (correo IS NULL OR position('@' IN correo) > 1)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_v2_biblioteca_numero_dgb
ON v2.biblioteca_detalle (lower(btrim(numero_dgb)))
WHERE numero_dgb IS NOT NULL AND btrim(numero_dgb) <> '';

ALTER TABLE v2.biblioteca_detalle ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE v2.biblioteca_detalle FROM PUBLIC, anon, authenticated;

-- Conserva el directorio anterior: copia sólo coincidencias seguras de municipio
-- y nunca elimina ni modifica public.cat_bibliotecas.
DO $$
DECLARE
  x RECORD; v_municipio UUID; v_tipo UUID; v_unidad UUID;
  v_persona UUID; v_espacio UUID;
BEGIN
  IF to_regclass('public.cat_bibliotecas') IS NULL THEN RETURN; END IF;
  SELECT id INTO v_tipo FROM v2.cat_tipos_espacio
  WHERE lower(btrim(clave))='biblioteca' LIMIT 1;
  SELECT id INTO v_unidad FROM v2.cat_unidades_operativas
  WHERE clave='BIBLIOTECAS' LIMIT 1;

  FOR x IN SELECT municipio,nombre_biblioteca,responsable FROM public.cat_bibliotecas LOOP
    SELECT id INTO v_municipio FROM v2.cat_municipios
    WHERE lower(btrim(nombre_oficial))=lower(btrim(x.municipio)) LIMIT 1;
    IF v_municipio IS NULL OR NULLIF(btrim(x.nombre_biblioteca),'') IS NULL THEN CONTINUE; END IF;
    v_persona := NULL;
    IF NULLIF(btrim(x.responsable),'') IS NOT NULL THEN
      SELECT id INTO v_persona FROM v2.cat_personas
      WHERE lower(btrim(nombre))=lower(btrim(x.responsable))
        AND (municipio_id=v_municipio OR municipio_id IS NULL) LIMIT 1;
      IF v_persona IS NULL THEN
        INSERT INTO v2.cat_personas(nombre,municipio_id,activo)
        VALUES(btrim(x.responsable),v_municipio,true) RETURNING id INTO v_persona;
      END IF;
    END IF;
    SELECT id INTO v_espacio FROM v2.cat_espacios
    WHERE municipio_id=v_municipio AND lower(btrim(nombre))=lower(btrim(x.nombre_biblioteca)) LIMIT 1;
    IF v_espacio IS NULL THEN
      INSERT INTO v2.cat_espacios(tipo_espacio_id,unidad_operativa_id,municipio_id,
        responsable_id,nombre,activo,metadata)
      VALUES(v_tipo,v_unidad,v_municipio,v_persona,btrim(x.nombre_biblioteca),true,
        jsonb_build_object('migrado_desde','public.cat_bibliotecas')) RETURNING id INTO v_espacio;
    END IF;
    INSERT INTO v2.biblioteca_detalle(espacio_id,activo)
    VALUES(v_espacio,true) ON CONFLICT(espacio_id) DO NOTHING;
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION v2.rpc_admin_listar_bibliotecas()
RETURNS TABLE (
  espacio_id UUID, municipio_id UUID, municipio TEXT,
  comunidad_id UUID, comunidad TEXT, nombre TEXT, direccion TEXT,
  numero_dgb TEXT, responsable_id UUID, responsable TEXT,
  correo TEXT, telefono TEXT, horario TEXT, activo BOOLEAN
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT v2_private.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_REQUIRED: solo ADMIN puede consultar este directorio.';
  END IF;
  RETURN QUERY
  SELECT e.id, e.municipio_id, m.nombre_oficial,
         e.comunidad_id, c.nombre, e.nombre, e.direccion,
         b.numero_dgb, e.responsable_id, p.nombre,
         b.correo, b.telefono, b.horario,
         (e.activo AND b.activo)
  FROM v2.biblioteca_detalle b
  JOIN v2.cat_espacios e ON e.id = b.espacio_id
  JOIN v2.cat_municipios m ON m.id = e.municipio_id
  LEFT JOIN v2.cat_comunidades c ON c.id = e.comunidad_id
  LEFT JOIN v2.cat_personas p ON p.id = e.responsable_id
  ORDER BY m.nombre_oficial, e.nombre;
END $$;

CREATE OR REPLACE FUNCTION v2.rpc_admin_guardar_biblioteca(
  p_espacio_id UUID, p_municipio_id UUID, p_comunidad_id UUID,
  p_nombre TEXT, p_direccion TEXT, p_numero_dgb TEXT,
  p_responsable TEXT, p_correo TEXT, p_telefono TEXT,
  p_horario TEXT, p_activo BOOLEAN
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id UUID; v_tipo UUID; v_unidad UUID; v_persona UUID;
BEGIN
  IF auth.uid() IS NULL OR NOT v2_private.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_REQUIRED: solo ADMIN puede modificar bibliotecas.';
  END IF;
  IF p_municipio_id IS NULL OR NULLIF(pg_catalog.btrim(p_nombre), '') IS NULL THEN
    RAISE EXCEPTION 'DATA_REQUIRED: municipio y nombre son obligatorios.';
  END IF;
  IF p_comunidad_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM v2.cat_comunidades c
    WHERE c.id = p_comunidad_id AND c.municipio_id = p_municipio_id AND c.activo
  ) THEN
    RAISE EXCEPTION 'COMMUNITY_INVALID: la comunidad no pertenece al municipio.';
  END IF;

  SELECT t.id INTO v_tipo FROM v2.cat_tipos_espacio t
  WHERE t.clave = 'BIBLIOTECA' AND t.activo LIMIT 1;
  SELECT u.id INTO v_unidad FROM v2.cat_unidades_operativas u
  WHERE u.clave = 'BIBLIOTECAS' AND u.activo LIMIT 1;
  IF v_tipo IS NULL THEN RAISE EXCEPTION 'LIBRARY_TYPE_MISSING: falta el tipo Biblioteca.'; END IF;

  IF NULLIF(pg_catalog.btrim(p_responsable), '') IS NOT NULL THEN
    IF NULLIF(pg_catalog.btrim(p_correo), '') IS NOT NULL THEN
      SELECT x.id INTO v_persona FROM v2.cat_personas x
      WHERE x.activo AND lower(pg_catalog.btrim(x.correo)) = lower(pg_catalog.btrim(p_correo)) LIMIT 1;
    END IF;
    IF v_persona IS NULL THEN
      SELECT x.id INTO v_persona FROM v2.cat_personas x
      WHERE x.activo AND lower(pg_catalog.btrim(x.nombre)) = lower(pg_catalog.btrim(p_responsable))
        AND (x.municipio_id = p_municipio_id OR x.municipio_id IS NULL)
      ORDER BY (x.municipio_id = p_municipio_id) DESC LIMIT 1;
    END IF;
    IF v_persona IS NULL THEN
      INSERT INTO v2.cat_personas(nombre,correo,telefono,municipio_id,activo)
      VALUES(pg_catalog.btrim(p_responsable),NULLIF(lower(pg_catalog.btrim(p_correo)),''),
             NULLIF(pg_catalog.btrim(p_telefono),''),p_municipio_id,true)
      RETURNING id INTO v_persona;
    ELSE
      UPDATE v2.cat_personas SET
        correo=COALESCE(NULLIF(lower(pg_catalog.btrim(p_correo)),''),correo),
        telefono=COALESCE(NULLIF(pg_catalog.btrim(p_telefono),''),telefono),
        updated_by=auth.uid(),updated_at=now() WHERE id=v_persona;
    END IF;
  END IF;

  IF p_espacio_id IS NULL THEN
    INSERT INTO v2.cat_espacios(tipo_espacio_id,unidad_operativa_id,municipio_id,
      comunidad_id,responsable_id,nombre,direccion,activo)
    VALUES(v_tipo,v_unidad,p_municipio_id,p_comunidad_id,v_persona,
      pg_catalog.btrim(p_nombre),NULLIF(pg_catalog.btrim(p_direccion),''),COALESCE(p_activo,true))
    RETURNING id INTO v_id;
  ELSE
    UPDATE v2.cat_espacios SET tipo_espacio_id=v_tipo,unidad_operativa_id=v_unidad,
      municipio_id=p_municipio_id,comunidad_id=p_comunidad_id,responsable_id=v_persona,
      nombre=pg_catalog.btrim(p_nombre),direccion=NULLIF(pg_catalog.btrim(p_direccion),''),
      activo=COALESCE(p_activo,true),updated_by=auth.uid(),updated_at=now()
    WHERE id=p_espacio_id RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND: la biblioteca ya no existe.'; END IF;
  END IF;

  INSERT INTO v2.biblioteca_detalle(espacio_id,numero_dgb,correo,telefono,horario,activo)
  VALUES(v_id,NULLIF(pg_catalog.btrim(p_numero_dgb),''),NULLIF(lower(pg_catalog.btrim(p_correo)),''),
    NULLIF(pg_catalog.btrim(p_telefono),''),NULLIF(pg_catalog.btrim(p_horario),''),COALESCE(p_activo,true))
  ON CONFLICT (espacio_id) DO UPDATE SET
    numero_dgb=EXCLUDED.numero_dgb,correo=EXCLUDED.correo,telefono=EXCLUDED.telefono,
    horario=EXCLUDED.horario,activo=EXCLUDED.activo,updated_by=auth.uid(),updated_at=now();
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION v2.rpc_admin_cambiar_estado_biblioteca(p_espacio_id UUID,p_activo BOOLEAN)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT v2_private.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_REQUIRED: solo ADMIN puede modificar bibliotecas.';
  END IF;
  UPDATE v2.cat_espacios SET activo=COALESCE(p_activo,false),updated_by=auth.uid(),updated_at=now()
  WHERE id=p_espacio_id;
  UPDATE v2.biblioteca_detalle SET activo=COALESCE(p_activo,false),updated_by=auth.uid(),updated_at=now()
  WHERE espacio_id=p_espacio_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'NOT_FOUND: la biblioteca ya no existe.'; END IF;
END $$;

REVOKE ALL ON FUNCTION v2.rpc_admin_listar_bibliotecas() FROM PUBLIC;
REVOKE ALL ON FUNCTION v2.rpc_admin_guardar_biblioteca(UUID,UUID,UUID,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,BOOLEAN) FROM PUBLIC;
REVOKE ALL ON FUNCTION v2.rpc_admin_cambiar_estado_biblioteca(UUID,BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION v2.rpc_admin_listar_bibliotecas() TO authenticated;
GRANT EXECUTE ON FUNCTION v2.rpc_admin_guardar_biblioteca(UUID,UUID,UUID,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION v2.rpc_admin_cambiar_estado_biblioteca(UUID,BOOLEAN) TO authenticated;

INSERT INTO v2.schema_migrations(version,descripcion) VALUES
('2.1.12v','12v_bibliotecas_v2.sql - Directorio especializado de bibliotecas como espacios culturales V2.')
ON CONFLICT(version) DO NOTHING;
COMMIT;

-- Verificación esperada: true | true | true | false | 1
SELECT to_regclass('v2.biblioteca_detalle') IS NOT NULL AS tabla,
  to_regprocedure('v2.rpc_admin_listar_bibliotecas()') IS NOT NULL AS listar,
  pg_catalog.has_function_privilege('authenticated','v2.rpc_admin_guardar_biblioteca(uuid,uuid,uuid,text,text,text,text,text,text,text,boolean)','EXECUTE') AS admin_rpc,
  pg_catalog.has_function_privilege('anon','v2.rpc_admin_guardar_biblioteca(uuid,uuid,uuid,text,text,text,text,text,text,text,boolean)','EXECUTE') AS anon_rpc,
  (SELECT count(*) FROM v2.schema_migrations WHERE version='2.1.12v') AS migracion;
