# Procedencia de recursos — Etapa 6.1

## PULSO Q

- Archivo: `brand/pulso-q-logo.png`
- Procedencia: imagen incrustada en `PULSO_Q_1.pptx`, proporcionado por Luis Ángel Durán Álvarez el 25 de agosto de 2026.
- Uso: co-marca discreta en Ayuda y soporte y en el menú de cuenta.

## Cartografía municipal de Guanajuato

- Archivo: `geo/guanajuato-municipios.geojson`
- Fuente institucional: INEGI, Marco Geoestadístico 2025, capa de áreas geoestadísticas municipales.
- Servicio oficial: <https://lcidsig.inegi.org.mx/server/rest/services/Hosted/Municipios_2025/FeatureServer/0>
- Copia de descarga utilizada: <https://github.com/MacWilliXD/INEGI-geojson/blob/main/geojson_descargas/AGEM_11.geojson>
- Validación local: 46 entidades, claves CVEGEO de cinco caracteres para Guanajuato (`11`).
- Tratamiento: simplificación geométrica para visualización web con tolerancia de 0.00032 grados y redondeo a seis decimales. No se alteraron claves ni nombres.

La cartografía representa áreas geoestadísticas para referenciar información estadística; no debe interpretarse como definición jurídica de límites político-administrativos.

## D3.js

- Archivo: `vendor/d3.v7.9.0.min.js`
- Versión: 7.9.0
- Proyecto: <https://d3js.org/>
- Uso: proyección geográfica, generación de trazos SVG y escala secuencial del mapa coroplético.
