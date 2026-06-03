# 2 — Instalar / actualizar en una PC (Windows)

El MSIX está firmado con un **certificado self-signed** (no comprado), así que
hay que confiarlo una vez por máquina. Update **in-place**: no hace falta
desinstalar la versión vieja, los datos viven en el backend.

---

## Opción A (recomendada) — script automático

1. Copiá `install-latest.ps1` (de esta carpeta) a la PC.
2. **Click derecho → Ejecutar como administrador** (hace falta admin para
   confiar el certificado en la máquina).
3. El script baja la última versión de GitHub, confía el cert e instala.

Al final muestra: `[OK] SITECSA CRM instalada: vX.Y.Z`. Buscala en el menú
Inicio.

> Necesita PowerShell 7+. Si tu PC tiene solo Windows PowerShell 5, instalá
> `pwsh` (https://aka.ms/powershell) o usá la Opción B.

## Opción B — manual (un instalador puntual)

1. Conseguí el instalador versionado: de `Releases\vX.Y.Z\SITECSA-CRM-vX.Y.Z.msix`
   (en la PC de build) o del Escritorio, o bajalo de
   `https://github.com/rubenmaltez/Template-TT/releases/latest/download/SITECSA-CRM.msix`.
2. Doble click en el `.msix`.
3. Si Windows dice que el editor no es de confianza:
   - Click derecho sobre el `.msix` → **Propiedades** → pestaña **Firmas
     digitales** → seleccioná la firma → **Detalles** → **Ver certificado** →
     **Instalar certificado** → **Equipo local** → "Colocar en el siguiente
     almacén" → **Personas de confianza** → Aceptar.
   - Volvé a abrir el `.msix` → **Instalar**.

---

## Verificar

Abrí la app → en el **login** (al pie) y en el **sidebar del admin** (abajo)
debe decir `SITECSA CRM vX.Y.Z` con la versión que instalaste.

## Desinstalar

Corré `uninstall.ps1` (click derecho → Ejecutar con PowerShell). No requiere
admin. Limpia también la cache local de AppData; la data real está en el backend.
