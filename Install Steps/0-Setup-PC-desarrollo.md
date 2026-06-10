# 0 — Setup de una PC de DESARROLLO nueva

Cómo dejar una computadora nueva lista para trabajar en SITECSA CRM
(desarrollar, correr la app, correr tests y publicar releases). Tiempo
estimado: ~30-45 min (la mayoría es instalar Flutter/Visual Studio).

> Esta guía es para la PC del DEV (Rubén). Para instalar la APP en una PC de
> un cliente/admin, eso es `2-Instalar-en-PC.md`.

---

## Paso 1 — Instalar las herramientas

| Herramienta | Para qué | De dónde |
|---|---|---|
| **Git** | clonar el repo | git-scm.com |
| **Flutter SDK** (canal stable) | la app | docs.flutter.dev/get-started → agregar `flutter\bin` al PATH |
| **Visual Studio 2022** (Community) con el workload **"Desktop development with C++"** | build de Windows | visualstudio.microsoft.com |
| **Android Studio** (o solo el Android SDK + cmdline-tools) | build del APK | developer.android.com |
| **PowerShell 7+** (`pwsh`) | los scripts del repo | microsoft.com/powershell |
| **GitHub CLI** (`gh`) | publicar releases | cli.github.com → después `gh auth login` |

Verificación: `flutter doctor` — debe dar check verde en Windows, Android
y (opcional) Chrome. Los issues de iOS/macOS se ignoran.

## Paso 2 — Clonar el repo

```powershell
cd C:\Users\<tu-usuario>\Projects
git clone https://github.com/rubenmaltez/Template-TT.git
cd Template-TT
git checkout main
```

## Paso 3 — Copiar `.env.json` (EL ÚNICO ARCHIVO QUE NO VIENE POR GIT)

`.env.json` tiene las keys de Supabase y PowerSync → **NUNCA va al repo**.
Copialo desde tu PC anterior (USB, o pasátelo por un canal privado) a la
**raíz** del proyecto. Sin este archivo la app abre con "Configuración
pendiente" y el build falla a propósito.

> Si lo perdiste: las URLs/keys están en el Dashboard de Supabase (Settings →
> API) y en el Dashboard de PowerSync (Instance URL). La estructura del JSON
> se ve en `lib/config/env.dart`.

## Paso 4 — Dependencias y primera corrida

```powershell
flutter pub get
flutter run -d windows
```

**Qué deberías ver:** la app compila y abre en el login. (La primera
compilación de Windows tarda varios minutos — descarga pdfium y compila
los plugins nativos.)

## Paso 5 — Verificar los tests (opcional pero recomendado)

```powershell
flutter test
```

**Qué deberías ver:** todos verdes (incluye la suite de dinero de
`pagos_repo`). Las DLLs nativas de PowerSync que estos tests necesitan
(`powersync.dll` / `powersync_x64.dll`) **ya vienen en el repo** (raíz),
igual que el certificado público `SITECSA-CRM.cer` — no hay pasos manuales.

## Paso 6 — Para publicar releases desde esta PC

```powershell
gh auth login    # una sola vez (cuenta rubenmaltez)
```

Y de ahí en más, el flujo normal de release: `1-Publicar-nueva-version.md`
(bump de versión + migraciones + `.\'Install Steps'\build-release.ps1`).
La firma del MSIX usa el certificado de prueba del paquete `msix` (sin
`certificate_path` custom), así que los releases generados desde esta PC
son compatibles con los instalados — no hay que mover certificados privados.

---

## Resumen: qué viene de dónde

| Cosa | Cómo llega a la PC nueva |
|---|---|
| Código + docs + scripts | `git clone` (rama `main`) |
| `powersync.dll` / `powersync_x64.dll` / `SITECSA-CRM.cer` | vienen en el repo |
| `.env.json` | **a mano, por canal seguro** (nunca git) |
| Dependencias Dart | `flutter pub get` |
| `build/`, `.dart_tool/`, etc. | se generan solos al compilar |
| `Releases\` (instaladores versionados) | se crea sola al correr `build-release.ps1` (el histórico viejo queda en la PC anterior / GitHub Releases) |
