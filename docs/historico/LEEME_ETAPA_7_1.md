# Etapa 7.1 — Inicio institucional

Esta entrega renueva únicamente la portada del sistema. No cambia tablas,
registros, validaciones ni información ya capturada.

## Qué incluye

- Portada institucional visible solamente en la pestaña Inicio.
- Tres fotografías organizadas en `assets/identidad-institucional/inicio/`.
- Accesos directos a Captura, Bitácora, Validación y Dashboard según el rol.
- Resumen compacto de sesión y alcance.
- Mapa de los 46 municipios usando la cartografía que ya tiene el proyecto.
- Explicación sencilla del flujo de trabajo.
- Rutas corregidas para los logotipos del encabezado, acceso, administración,
  manifiesto y modo sin conexión.
- Diseño adaptable para computadora, tableta y teléfono.

## Instalación en Windows

1. Cierra cualquier archivo del proyecto que esté abierto en un editor.
2. Descomprime este ZIP.
3. Copia todo el contenido de la carpeta descomprimida dentro de:

   `D:\Proyectos\sistematizacion-cdcm`

4. Cuando Windows lo pregunte, elige **Reemplazar los archivos en el destino**.
5. Abre GitHub Desktop y confirma que aparezcan los archivos modificados y las
   nuevas carpetas de `assets`.
6. Usa como resumen del commit:

   `Etapa 7.1 - Inicio institucional`

7. Haz **Commit to main** y después **Push origin**.
8. Abre el sistema publicado y realiza una recarga completa con `Ctrl + F5`.

## No ejecutar SQL

Esta etapa no incluye cambios para Supabase y no requiere ejecutar consultas.

## Comprobación rápida

- El logotipo aparece en acceso, encabezado y Administración.
- La fotografía de Guanajuato aparece en la portada.
- Las otras dos fotografías aparecen al final del Inicio.
- Al entrar a Captura, Bitácora, Validación o Dashboard desaparece la portada.
- Los accesos directos llevan al módulo correspondiente.
- Un usuario sin permiso no ve el acceso directo al módulo restringido.
- El mapa muestra los 46 municipios. Si la cartografía no carga, el resto del
  Inicio sigue funcionando.
- En teléfono no existe desplazamiento horizontal.

## Siguiente etapa

La Etapa 7.2 incorporará el Gestor de contenido para sustituir fotografías y
textos desde Administración, con permisos, vista previa y publicación.
