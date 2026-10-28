# WristReader

Lector de EPUB para el Apple Watch (watchOS) con sincronización de progreso mediante el protocolo **KOReader Sync**, compatible con **Readest** y **KOReader**. Se instala en tu reloj con una cuenta gratuita de Apple (Personal Team), sin pagar el programa de desarrollador ni usar capacidades especiales (sin iCloud, App Groups ni notificaciones push).

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
- La sincronización habla directamente con un servidor KOReader Sync (por defecto `https://sync.koreader.rocks`).

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

## Configurar la sincronización

WristReader usa el mismo servidor y el mismo método que tus otros lectores, de modo que el progreso se comparta.

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

## Importar EPUBs

- Desde el iPhone: abre un `.epub` con "Abrir en WristReader" (menú Compartir de Archivos, Safari, etc.) o usa el botón de importar en la app. La app los transfiere al reloj.
- La app expone su carpeta de documentos en la app Archivos (`UIFileSharingEnabled`).

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

CI en GitHub Actions: `.github/workflows/linux.yml` (tests de `ReaderCore` en `swift:6.0`) y `.github/workflows/macos.yml` (XcodeGen, tests y compilación de iOS y watchOS para simulador sin firma). Más detalles de planes futuros en [ROADMAP.md](ROADMAP.md).
