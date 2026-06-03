# Release runbook → movido a `Install Steps/`

El runbook de release y las guías de instalación viven ahora en la carpeta
**`Install Steps/`** (fuente única, orden absoluto):

- `Install Steps/1-Publicar-nueva-version.md` — bump de versión + migraciones +
  `build-release.ps1`.
- `Install Steps/2-Instalar-en-PC.md` — instalar/actualizar en Windows.
- `Install Steps/3-Instalar-en-Android.md` — instalar/actualizar en Android.
- `Install Steps/README.md` — índice + cómo queda organizado todo.

Los instaladores versionados se apilan en `Releases\vX.Y.Z\` (local, gitignored).
