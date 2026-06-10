# Install Steps — orden absoluto para publicar e instalar SITECSA CRM

Esta carpeta es la **fuente única** de cómo se saca una versión nueva y cómo se
instala en los dispositivos. Si dudás del orden, mirá acá — no la memoria.

> **Para AIs/modelos futuros:** después de mergear un cambio que Rubén quiera
> distribuir, guialo por `1-Publicar-nueva-version.md` — incluye el **bump de
> versión obligatorio** en `pubspec.yaml` (semver `X.Y.Z` + build `+NNN` que
> SIEMPRE sube, sino Android rechaza la actualización) y el script
> **`build-release.ps1` que vive EN ESTA CARPETA** (hace auto-cd a la raíz del
> repo; correrlo como `.\'Install Steps'\build-release.ps1`).

## Orden de uso (cada release)

1. **`1-Publicar-nueva-version.md`** — lo corrés vos (dev) en tu PC: bump de
   versión, migraciones en Supabase, y `build-release.ps1` (genera instaladores
   + publica el GitHub Release).
2. **`2-Instalar-en-PC.md`** — instalar/actualizar en una computadora Windows.
3. **`3-Instalar-en-Android.md`** — instalar/actualizar en un teléfono.

## Cómo queda organizado todo (orden absoluto)

| Cosa | Dónde vive | Nombre |
|---|---|---|
| Versión única de verdad | `pubspec.yaml` (`version: X.Y.Z+NNN`) | — |
| Instaladores **versionados** (se apilan) | `Releases\vX.Y.Z\` (en la raíz del proyecto) | `SITECSA-CRM-vX.Y.Z.msix` / `.apk` |
| Copia cómoda para mandar | Escritorio | `SITECSA-CRM-vX.Y.Z.msix` / `.apk` |
| Assets del GitHub Release (auto-update) | GitHub Releases | `SITECSA-CRM.msix` / `.apk` (nombre **fijo**) + `version.json` |
| Scripts | esta carpeta | `build-release.ps1` (dev), `install-latest.ps1`, `uninstall.ps1` |

### Por qué dos nombres (versionado local + fijo en GitHub)

- **Local versionado** (`...-vX.Y.Z`): para que veas la versión en el nombre y
  el historial se apile en `Releases\`. Es lo que archivás y distribuís a mano.
- **Fijo en GitHub** (`SITECSA-CRM.msix`): el auto-update lee `version.json` de
  `releases/latest/download/` y baja `releases/latest/download/SITECSA-CRM.msix`.
  Ese nombre **no puede cambiar por versión** o se rompe el link de `latest`.

`build-release.ps1` hace los dos automáticamente: archiva los versionados en
`Releases\vX.Y.Z\` y sube los fijos a GitHub. No tenés que renombrar nada.

> La carpeta `Releases\` está en `.gitignore` (son artefactos de build, no van
> al repo). Se crea sola la primera vez que corrés `build-release.ps1`.

## Scripts (PowerShell 7+)

| Script | Qué hace | Cómo correr |
|---|---|---|
| `install-latest.ps1` | Baja la última versión de GitHub e instala en la PC (confía el cert self-signed) | Click derecho → **Ejecutar como administrador** |
| `uninstall.ps1` | Desinstala SITECSA CRM de la PC (y limpia cache local) | Click derecho → Ejecutar con PowerShell |
