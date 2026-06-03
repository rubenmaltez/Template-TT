# Carpeta `instalador/` — ops de instalación (PC)

Scripts y documentación para instalar / desinstalar **SITECSA CRM** en Windows,
y los `.md` importantes del proyecto a mano.

## Scripts (PowerShell)

| Script | Qué hace | Cómo correr |
|---|---|---|
| **`uninstall.ps1`** | Desinstala la app del PC (full — borra también la data local del paquete). | Click derecho → "Ejecutar con PowerShell" (no necesita admin). |
| **`install-latest.ps1`** | Baja la **última** versión de GitHub, confía el certificado e instala/actualiza. | Click derecho → **"Ejecutar como administrador"** (necesario para el cert). |

**Reinstalación limpia desde 0:** corré `uninstall.ps1`, después `install-latest.ps1`.

> Si PowerShell bloquea el script ("running scripts is disabled"):
> `pwsh -ExecutionPolicy Bypass -File .\install-latest.ps1` (en una consola de admin para el install).

### Android
Los scripts son para **PC**. En Android se instala bajando el APK en el teléfono:
Chrome → `github.com/rubenmaltez/Template-TT/releases/latest` → `SITECSA-CRM.apk` → Instalar.
Para "desde 0" en Android: ajustes → desinstalar la app → reinstalar el APK.

## Documentos (.md)

Copias de referencia de los `.md` importantes del proyecto (la **fuente de verdad
está en la raíz** del repo — estas copias son un snapshot por comodidad):

| Archivo | Qué es |
|---|---|
| `CLAUDE.md` | Contexto y reglas del proyecto (stack, roles, invariantes de dinero, proceso). |
| `ESTADO-APP.md` | Estado actual de la app (findings, cobertura, próximos pasos). |
| `REPORTE-SESION.md` | Comportamiento esperado por feature + lifecycle end-to-end + historial de fixes. |
| `RELEASE.md` | Runbook de distribución (cómo se buildea/publica una versión, auto-update). |

## Para BUILDEAR y PUBLICAR una versión nueva
Eso NO se hace desde acá — se hace desde la **raíz** del repo con:
```powershell
.\build-release.ps1
```
(Buildea Windows + Android con el env, copia los instaladores al Escritorio, y
crea/actualiza el GitHub Release. Ver `RELEASE.md`.)
