# Etapa 6.5.1 — Importador inteligente de reportes CDCM

Esta corrección convierte el reporte institucional de Cuerámaro en actividades V2 sin pedir que el usuario relacione columnas una por una.

## Archivos que se publican

En la raíz del sitio, reemplaza:

- `index.html`
- `sw.js`

Dentro de la carpeta `js`, reemplaza:

- `importer.js`

Dentro de la misma carpeta `js`, agrega:

- `importer-smart.js`

No es necesario ejecutar SQL para esta corrección. Conserva instalados `12j_bulk_excel_import.sql` y `12k_bitacora_import_depuracion.sql`.

## Publicación

1. Descomprime el ZIP antes de copiar los archivos.
2. Copia la estructura tal como aparece en la carpeta `Etapa_6_5_1_Archivos_Para_Instalar`.
3. Confirma los cambios y publícalos en GitHub.
4. Espera a que GitHub Pages termine el despliegue.
5. Abre el sistema y usa `Ctrl + Shift + R`. Si la pestaña llevaba mucho tiempo abierta, ciérrala y abre el sitio de nuevo.

## Prueba con el reporte de Cuerámaro

1. Inicia sesión como administrador.
2. Abre `Bitácora`.
3. Pulsa `Importar Excel`.
4. Selecciona `Cuerámaro - Reporte de actividades 2026.xlsx`.
5. El sistema debe mostrar `Reconocimiento automático`; no debe pedir hoja, encabezado, unidad, programa, acción ni columnas.
6. El resultado esperado antes de guardar es:
   - Municipio: Cuerámaro.
   - Año: 2026.
   - 12 hojas mensuales revisadas.
   - 77 actividades detectadas.
   - 34 talleres en Casa de Cultura.
   - 27 actividades de Salones culturales.
   - 2 reuniones de colaboración.
   - 13 eventos o actividades municipales.
   - 1 capacitación.
7. Pulsa `Revisar actividades detectadas`.
8. Revisa la vista previa. Las filas sin cifra de personas se muestran con un guion y se conservan como borradores para revisión; no se inventan cantidades.
9. Cuando estés conforme, pulsa `Importar filas válidas`.
10. Confirma que los nuevos borradores aparecen en la Bitácora y que el historial muestra la importación.

## Comportamiento para otros archivos

- Si el archivo usa el formato mensual institucional CDCM, el proceso será automático.
- Si usa la plantilla oficial V2, se reconocerán sus encabezados.
- Si es un formato todavía desconocido, aparecerá la relación avanzada de columnas como alternativa. Ese caso puede añadirse después al catálogo de formatos automáticos sin cambiar el Excel de origen.

## Seguridad de datos

- El archivo se analiza primero en el navegador.
- Los registros se crean como borradores V2.
- Se mantienen RLS, permisos, auditoría, detección de duplicados e historial de importaciones.
- No se importan las hojas de resumen junto con el detalle mensual, evitando duplicar cifras.
