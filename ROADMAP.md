# Hoja de ruta

## Estado actual

- Lectura de EPUB en el reloj y sincronización con KOReader Sync (compatible con Readest y KOReader).

## Fase opcional: cliente de la API de sincronización de Readest

Objetivo: sincronizar directamente con la nube de Readest sin pasar por KOReader Sync, y descargar libros de la biblioteca de Readest. Referencia: el plugin oficial [`apps/readest.koplugin`](https://github.com/readest/readest/tree/main/apps/readest.koplugin) del repositorio `readest/readest`. Los nombres de abajo proceden de ese código; hay que verificarlos de nuevo antes de implementar, porque la API no es pública ni estable.

### Autenticación (Supabase, email y contraseña)

Según `supabase-auth-api.json` del plugin (base `https://<proyecto>.supabase.co/auth/v1/`):
- `POST /token?grant_type=password` con `email` y `password`.
- `POST /token?grant_type=refresh_token` con `refresh_token`.
- `POST /logout` y `GET /user`.
- Guardar los tokens en el Keychain y renovarlos automáticamente.

### API de sincronización

Según `readest-sync-api.json` (base `https://web.readest.com/api`):
- `GET /sync` con `since`, `type`, `book`, `meta_hash` (y `limit`) para traer cambios.
- `POST /sync` con `books`, `notes`, `configs` (y `statBooks`, `statPages`) para subirlos.
- Progreso de lectura: registros de configuración con `bookHash`, `metaHash`, `progress`, `xpointer` y `updatedAt` (en el plugin, `type = "configs"`; la respuesta trae `configs`). Para libros reflowables se usa `xpointer`; para paginados `progress` como `[página, total]`.
- Descarga de libros: `GET /storage/download?fileKey=...`, `GET /storage/list?bookHash=...` y `POST /storage/upload`.
- La pestaña `book_configs` de la base de datos de Readest debe consultarse en el código de Readest (no está documentada en el plugin); no se asume su esquema.

### Tareas

1. Cliente de autenticación Supabase en `ReaderCore` (con pruebas con respuestas simuladas).
2. Cliente `/sync` para `configs` y resolución de conflictos por `updatedAt`.
3. Listado y descarga de libros de la nube de Readest al reloj.
4. Selector de backend de sincronización: KOReader Sync o Readest.

## Otras ideas

- Mayor precisión de posición (más allá del inicio de párrafo).
- Complicación de esfera con el libro actual y el porcentaje.
- Ajustes de tipografía, tamaño y tema; control con la corona digital.
- Tabla de contenidos, marcadores y subrayados.
- Transferencia de libros por Wi-Fi/LocalSend desde el reloj.
- Estadísticas de lectura.
- Lectura en voz alta y modo de bajo consumo.
- Distribución por TestFlight o cuenta de pago para evitar el límite de 7 días.
