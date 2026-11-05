# Auditoría y diagnóstico

Actualización documental al 31 de octubre de 2026: [contexto consolidado](../../CONTEXTO_PROYECTO.md). El informe del día 20 se conserva como evidencia histórica; no todos sus hallazgos describen el código posterior al paquete 01. Los cambios de ese paquete ya están en el historial local de Git; su instalación en Supabase y publicación efectiva requieren evidencia del servicio.

El informe y `inventario-inicial.json` conservan el estado anterior a la limpieza y al paquete 1. Las rutas antiguas citadas en el informe corresponden a esa revisión.

- Para instalar las correcciones: `../paquetes/seguridad-01/LEEME.md`.
- Para revisar qué se retiró y reubicó: `../LIMPIEZA.md`.
- Diagnóstico consolidado de lectura: `diagnostico_supabase_consolidado.sql`.
- Inventario vigente: `inventario-actual.json`, generado por `../../scripts/revisar-archivos.cjs`.

Los archivos SQL de esta carpeta son diagnósticos, no las correcciones. El archivo de corrección está en `sql/v2/13_security_package_01.sql` desde la raíz del proyecto.

El paquete 1 fue contrastado con el CSV de Supabase proporcionado por el responsable. Las pruebas locales aprobaron 14 casos; continúa pendiente la aplicación y verificación en Supabase. Los restantes hallazgos del informe siguen abiertos según su alcance.
