# WristReader

Lector de EPUB para el Apple Watch (watchOS). Funciona **sin cuenta y sin conexión** con tus propios archivos EPUB. Opcionalmente puede sincronizar el progreso de lectura con cualquier servidor compatible con el protocolo **KOReader Sync** (el de KOReader, el de Readest o uno alojado por ti). Se instala en tu reloj con una cuenta gratuita de Apple (Personal Team), sin pagar el programa de desarrollador ni usar capacidades especiales (sin iCloud, App Groups ni notificaciones push).

## Usar sin cuenta

La sincronización es **opcional**; no hace falta ninguna cuenta (ni de Readest ni de KOReader) para leer.

1. Importa tus EPUB en la app del iPhone (botón +, o "Abrir en WristReader" desde Archivos o el menú Compartir). Se envían solos al reloj.
2. Lee en el reloj. La posición se guarda en el propio reloj y todo funciona sin conexión.
3. Sin usuario y contraseña guardados, la app no hace ninguna petición de sincronización ni muestra avisos o indicadores de sync. La única función que usa la red por iniciativa tuya es la consulta de diccionario.
4. Si más adelante quieres sincronizar, ve en el iPhone a *Settings › Progress Sync* (ver más abajo). Puedes desactivarla cuando quieras con *Turn Off Sync and Remove Login*, que borra las credenciales del iPhone y del reloj y vacía el progreso pendiente (también desde Ajustes del reloj → *Remove credentials*).

## Arquitectura

```
Packages/ReaderCore   Paquete SwiftPM (lógica pura, probado también en Linux):
                      lectura de EPUB, XPointer, cliente KOReader Sync, hash de documento.
iOSApp/               App de iPhone (SwiftUI): importa EPUBs y los envía al reloj.
WatchApp/             App de watchOS (SwiftUI): lector y sincronización.
Config/               Ajustes de compilación (xcconfig).
project.yml           Especificación de XcodeGen (el .xcodeproj no se versiona).
```

- La app del reloj es una app de watchOS de un solo target (`WKApplication = true`) emparejada con la app de iPhone mediante `WKCompanionAppBundleIdentifier`. La app de iPhone incluye (embebe) la del reloj.
- Ambas apps dependen de `ReaderCore`.
- La sincronización (opcional) habla directamente con un servidor compatible con KOReader Sync que tú configuras (la URL sugerida por defecto es `https://sync.koreader.rocks`, pero no se usa hasta que guardas usuario y contraseña).

## Compilar en un Mac con XcodeGen

Requisitos: macOS con Xcode 15 o superior y [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
cp Config/Local.xcconfig.example Config/Local.xcconfig   # edítalo (ver abajo)
xcodegen generate
open WristReader.xcodeproj
```

## Firma con Personal Team (gratuita)

1. En Xcode: Settings → Accounts → añade tu Apple ID. Anota tu **Team ID** (10 caracteres).
2. Edita `Config/Local.xcconfig` (ignorado por git):
   ```
   DEVELOPMENT_TEAM = TU_TEAM_ID
   WR_BUNDLE_ID = com.tunombre.wristreader
   ```
   El identificador debe ser **único globalmente**; el de la app del reloj será `WR_BUNDLE_ID.watchkitapp`. También puedes pasar `DEVELOPMENT_TEAM=...` a `xcodebuild`.
3. Vuelve a ejecutar `xcodegen generate` si cambiaste algo.

Con la firma automática, Xcode crea los perfiles de aprovisionamiento. No se usa ninguna capacidad (entitlements) que requiera una cuenta de pago.

## Instalar en el iPhone y en el Apple Watch

1. Activa el **Modo desarrollador** en el iPhone (Ajustes → Privacidad y seguridad → Modo desarrollador) y en el Apple Watch (Ajustes → Privacidad y seguridad → Modo desarrollador, o desde la app Watch en el iPhone). Ambos se reinician.
2. Conecta el iPhone por cable y confía en el ordenador. El reloj debe estar emparejado y desbloqueado.
3. En Xcode selecciona el esquema `WristReader` y tu iPhone como destino, y pulsa Run. Esto instala también la app del reloj.
4. Si no aparece en el reloj, abre la app Watch en el iPhone → WristReader → "Instalar". Alternativamente, elige el esquema `WristReaderWatch` y tu reloj como destino.
5. En iPhone: Ajustes → General → VPN y gestión de dispositivos → confía en tu certificado de desarrollador.

**Límite de 7 días:** con Personal Team, la firma caduca a los 7 días. Hay que volver a instalar desde Xcode (Run) para renovarla. Los datos se conservan si reinstalas sin borrar la app. Además hay un máximo de 3 apps activas y de identificadores nuevos por semana.

## Configurar la sincronización (opcional)

Solo si quieres continuar el mismo libro en otros lectores. WristReader usa el mismo servidor y el mismo método que tus otros lectores, de modo que el progreso se comparta.

### Readest

Settings → Integrations → **KOReader Sync**:
- Servidor: el mismo que en WristReader (por defecto `https://sync.koreader.rocks`).
- Usuario y contraseña de ese servidor.
- Método de coincidencia de documentos: **File Content** (hash del contenido del archivo).

### KOReader

Herramientas → **Sincronización de progreso** (Progress sync) → configura el servidor personalizado y cuenta.
- Método de coincidencia de documentos: **Binary** (hash del archivo binario).

Ambos métodos calculan el mismo hash MD5 parcial del contenido del archivo, por lo que el mismo EPUB se reconoce en todos los dispositivos. Debe ser el **mismo archivo** (sin reempaquetar).

### Servidor

Puedes usar el servidor público `https://sync.koreader.rocks` o alojar el tuyo con [koreader-sync-server](https://github.com/koreader/koreader-sync-server). Introduce la misma URL en todas las apps.

### Servidor HTTP (ATS)

Por defecto se usa **https**. iOS y watchOS bloquean `http://` mediante App Transport Security (ATS), así que WristReader declara en ambos `Info.plist` (vía `project.yml`) únicamente `NSAllowsLocalNetworking`: permite `http://` hacia la **red local** (direcciones IP, nombres `.local` y nombres sin puntos como `http://nas:5200`) sin desactivar ATS para el resto.

- Servidor en LAN por http: funciona tal cual. La app de iPhone muestra un aviso naranja al ver `http://` (el tráfico no va cifrado; úsalo solo en una red de confianza).
- Servidor con nombre de dominio público por **http**: iOS lo bloquea. Lo recomendable es poner un proxy inverso con https. Si aun así lo necesitas, añade una excepción solo para ese dominio en `project.yml` (en los dos targets, `WristReader` y `WristReaderWatch`) y ejecuta `xcodegen generate`:

```yaml
NSAppTransportSecurity:
  NSAllowsLocalNetworking: true
  NSExceptionDomains:
    sync.ejemplo.org:
      NSExceptionAllowsInsecureHTTPLoads: true
```

No se usa `NSAllowsArbitraryLoads`.

## Tipografía configurable

En el reloj (menú del lector, icono de lista → *Typography*, o Ajustes) y en la app del iPhone (pestaña *Reading*, con vista previa en vivo) puedes cambiar: familia tipográfica (SF, serif/New York, redondeada, monoespaciada), tamaño, interlineado, márgenes, separación entre párrafos, alineación (izquierda/centrada), negrita, escala de los títulos, espaciado entre letras y tema (oscuro, tenue, sepia, alto contraste), además de varios *presets* y "Reset to defaults". En el reloj, *Match System Text Size* hace que el tamaño del libro siga el tamaño de texto del sistema.

- Los cambios hechos en el iPhone se envían al reloj por el canal de ajustes (`updateApplicationContext`) y los del reloj se publican al iPhone. Gana el **último cambio** (por marca de tiempo). Ver [docs/WATCH_CONNECTIVITY.md](docs/WATCH_CONNECTIVITY.md).
- Al cambiar un ajuste el lector mantiene el bloque actual como ancla; las fuentes se calculan una vez por cambio y el texto con estilo se guarda en caché por bloque, por lo que el `LazyVStack` no se reconstruye entero.
- Tamaño de letra: el ajuste antiguo se migra automáticamente.
- Limitaciones de SwiftUI en watchOS: no hay texto justificado ni guionado automático (se ofrece izquierda/centrada y espaciado entre letras). No se incluyen fuentes personalizadas: añadirlas aumentaría el tamaño y habría que revisar su licencia; solo se usan las del sistema.

## Diccionario (consulta de palabras)

watchOS no permite seleccionar texto en `Text` ni mostrar el diccionario del sistema, así que hay un "modo consulta": toca un párrafo (o menú del lector → *Look up a word*), gira la **Digital Crown** para mover el cursor entre las palabras (también hay botones ‹ ›) y pulsa *Look up*. Se muestran categoría gramatical, definiciones y un ejemplo, con desplazamiento.

- **Necesita conexión de red** (Wi-Fi/LTE del reloj o a través del iPhone). Las palabras ya consultadas se guardan en una caché LRU en disco (máx. 200 entradas / ~600 KB) y funcionan sin conexión.
- Fuente: la API REST de Wiktionary (edición inglesa, `en.wiktionary.org/api/rest_v1/page/definition/{palabra}`), que contiene palabras de todos los idiomas; se usa el idioma del libro (`dc:language`). Las definiciones salen **en inglés** también para libros en otros idiomas, porque las demás ediciones de Wiktionary no ofrecen este endpoint (devuelven HTTP 501). Para inglés hay respaldo en `api.dictionaryapi.dev`.
- Si la forma exacta no existe, se prueban minúsculas y reducciones simples (plurales, -ed, -ing) como reintento.
- Errores claros: sin conexión, no encontrada, servicio ocupado (límite de peticiones).
- Contenido de Wiktionary bajo licencia CC BY-SA.
- Ajustes del reloj: *Tap paragraph to look up* y *Clear dictionary cache*.

## Importar EPUBs

- Desde el iPhone: abre un `.epub` con "Abrir en WristReader" (menú Compartir de Archivos, Safari, etc.) o usa el botón de importar en la app. La app los transfiere al reloj.
- Si el reloj aún no tenía la app instalada, no se pierde nada: los ajustes de sincronización y los libros pendientes se reenvían automáticamente cuando la sesión se activa, la app del reloj se instala, cambia la conectividad o abres la app del iPhone. El reloj informa de qué libros tiene, de modo que se reenvían los que falten.
- La app expone su carpeta de documentos en la app Archivos (`UIFileSharingEnabled`).

## Idiomas

Las apps del iPhone y del reloj están traducidas a inglés (idioma base), español, francés, alemán, italiano, portugués de Brasil, japonés y chino simplificado, con String Catalogs de Xcode (`Localizable.xcstrings` e `InfoPlist.xcstrings` en `iOSApp/Resources` y `WatchApp/Resources`). `python3 scripts/check_strings.py` (también en la CI de Linux) comprueba que no falte ninguna traducción; cómo añadir textos o idiomas en [docs/LOCALIZATION.md](docs/LOCALIZATION.md).

## Limitaciones

- La granularidad de la posición es el **inicio del párrafo** (XPointer): al sincronizar con KOReader/Readest se llega al párrafo, no a la palabra o línea exacta.
- Si el XPointer remoto no se puede resolver (por ejemplo, el libro se reflowa distinto), se recurre al **porcentaje** de progreso.
- La app no usa iCloud ni App Groups por la restricción de la cuenta gratuita.
- No se soportan EPUB con DRM.

## Desarrollo

Probar el núcleo (funciona en macOS y Linux):

```sh
cd Packages/ReaderCore
swift test
```

CI en GitHub Actions: `.github/workflows/linux.yml` (tests de `ReaderCore` en `swift:6.0`) y `.github/workflows/macos.yml` (XcodeGen, tests de `ReaderCore` y ejecución real de los tests de la app iOS y watchOS en simuladores, sin firma; se suben los `.xcresult` como artefactos) y `.github/workflows/accessibility.yml` (auditoría de accesibilidad con UI tests, lenta: en cada push a `main`, a mano desde Actions o en PRs con la etiqueta `accessibility`; no bloquea los PRs). Qué se ejecuta dónde: [docs/TESTING.md](docs/TESTING.md). Más detalles de planes futuros en [ROADMAP.md](ROADMAP.md).
