# Release runbook — Windows (MSIX) + Android (APK) + auto-update

La app se distribuye por **GitHub Releases**. El cliente (`lib/data/services/update_service.dart`)
lee `version.json` del **latest release** y, si su `version` (semver) es mayor que la
instalada, muestra el banner de update con el link al instalador de la plataforma.

## Publicar una versión nueva

1. **Bump de versión** en `pubspec.yaml` → `version: X.Y.Z+NNN`.
   - `X.Y.Z` = lo que compara el update service (semver major.minor.patch).
   - `NNN` (build) **debe subir siempre** (es el `versionCode` de Android; sin subir, Android rechaza el update).

2. **Build Windows (MSIX):**
   ```powershell
   flutter build windows --release
   dart run msix:create
   ```
   El `.msix` se genera bajo `build/windows/x64/runner/Release/` (la consola imprime la ruta exacta).
   **Renombralo a `SITECSA-CRM.msix`.**

3. **Build Android (APK):**
   ```powershell
   flutter build apk --release
   ```
   Sale en `build/app/outputs/flutter-apk/app-release.apk`. **Renombralo a `SITECSA-CRM.apk`.**

4. **Editar `version.json`** (raíz del repo): poné el `version` nuevo + `release_notes`.
   Los `download_url_*` ya usan `releases/latest/download/<nombre>`, así que NO cambian
   mientras los assets se llamen igual.

5. **Publicar el GitHub Release** con tag `vX.Y.Z` y subir **3 assets** con estos nombres EXACTOS:
   - `SITECSA-CRM.msix`
   - `SITECSA-CRM.apk`
   - `version.json`

6. Listo. Las apps instaladas con versión menor muestran el banner al abrir (chequeo no-bloqueante).

## Notas importantes

- **Update in-place** (no instalar al lado) requiere **misma identidad + misma firma**:
  - Windows: misma `identity_name` del `msix_config` (`com.sitecsa.crm`).
  - Android: mismo `applicationId` (hoy `com.example.isp_billing`) + misma firma. Hoy se firma
    con **debug key** → buildeá siempre en la misma máquina (mismo `~/.android/debug.keystore`).
    Si cambian appId o firma, Android trata el APK como app nueva (pide desinstalar el viejo).
- **MSIX self-signed**: al no haber cert comprado, `msix:create` firma con un cert de prueba.
  Windows pide **confiar ese cert** (`.cer`) en *Trusted People / Trusted Root* antes de instalar.
- **Nombres de assets fijos** (`SITECSA-CRM.msix`/`.apk`): así `releases/latest/download/...`
  siempre resuelve al último, sin tener que editar URLs por versión.
