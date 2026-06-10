# 1 — Publicar una versión nueva (dev)

Lo corrés vos, en tu PC, con el repo clonado. Requisitos: `flutter`, `gh`
(logueado con `gh auth login`), `pwsh` 7+, y `.env.json` en la raíz.

---

## Paso 1 — Bump de versión

En `pubspec.yaml`, subí la línea `version`:

```yaml
version: 0.6.4+064   # X.Y.Z+NNN
```

- `X.Y.Z` = semver. Es lo que compara el auto-update y lo que se muestra en la
  app (login, sidebar admin, perfil cobrador).
- `+NNN` (build) **siempre sube** — es el `versionCode` de Android; sin subirlo,
  Android rechaza la actualización.

> No hace falta tocar `version.json` a mano: `build-release.ps1` le pone el
> número del `pubspec.yaml` solo.

## Paso 2 — Migraciones de Supabase (si la versión trae)

Si el release incluye archivos nuevos en `supabase/migrations/`, corrélos en
orden **antes** de que la gente instale, vía Dashboard → SQL Editor:

```powershell
Get-Content supabase\migrations\NNNN_*.sql -Raw | Set-Clipboard
```
Pegá en SQL Editor → Run → esperá `Success`. Repetí por cada migración nueva,
en orden numérico.

> Si la migración solo inserta filas en tablas ya sincronizadas (ej. `settings`),
> **no** hace falta bumpear schema ni redeployar sync rules. Si agrega columnas o
> tablas, seguí el checklist de integridad de `CLAUDE.md`.

## Paso 3 — Build + publicar (un comando)

```powershell
.\'Install Steps'\build-release.ps1
```

> El script vive en `Install Steps\` y hace auto-cd a la raíz del repo —
> funciona invocado desde cualquier carpeta.

Hace todo, en orden:
1. Build Windows (MSIX) + Android (APK) con el `.env.json` baked.
2. Archiva los instaladores **versionados** en `.\Releases\vX.Y.Z\`
   (`SITECSA-CRM-vX.Y.Z.msix` / `.apk`) — se apilan por versión.
3. Copia versionada al Escritorio.
4. Sube al **GitHub Release** los assets con nombre **fijo** (`SITECSA-CRM.msix`
   / `.apk`) + `version.json` actualizado. Tag `vX.Y.Z`.

Para forzar un tag distinto: `.\'Install Steps'\build-release.ps1 -Tag v0.6.5`.

Salida esperada al final, en verde:
```
=== LISTO ===
Release:    https://github.com/rubenmaltez/Template-TT/releases/tag/vX.Y.Z
Archivo:    .\Releases\vX.Y.Z\  (SITECSA-CRM-vX.Y.Z.msix + .apk)
Escritorio: SITECSA-CRM-vX.Y.Z.msix  +  SITECSA-CRM-vX.Y.Z.apk
```

## Paso 4 — Avisar / instalar

- Las apps ya instaladas muestran solo el banner **"Actualización disponible
  vX.Y.Z"** al abrir. Para aplicarla hay que instalar (ver guías 2 y 3).
- Para instalar en cada dispositivo: `2-Instalar-en-PC.md` y
  `3-Instalar-en-Android.md`.

---

## Probar en tu PC sin instalar

El build deja un `.exe` que ya viene con el `.env`:
```powershell
.\build\windows\x64\runner\Release\isp_billing.exe
```
