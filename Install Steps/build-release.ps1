#requires -Version 7.0
<#
  build-release.ps1  --  Build + release de SITECSA CRM en UN comando.

  Hace, en orden, sin que tengas que acordarte de nada:
    1. Build Windows (MSIX) + Android (APK), con la config .env.json BAKED.
    2. Renombra a SITECSA-CRM.msix / SITECSA-CRM.apk (lo que espera version.json).
    3. Copia los DOS instaladores a tu Escritorio.
    4. Crea (o actualiza) el GitHub Release con los 3 assets.

  Uso (desde la raiz del repo o desde cualquier carpeta):
    .\'Install Steps'\build-release.ps1               # version del pubspec -> tag vX.Y.Z
    .\'Install Steps'\build-release.ps1 -Tag v0.4.1   # tag explicito

  Requisitos: flutter, gh (GitHub CLI logueado), y .env.json en la raiz.
#>
param([string]$Tag = "")
$ErrorActionPreference = "Stop"

# El script vive en `Install Steps/` pero TODAS sus rutas son relativas a la
# RAIZ del repo (pubspec.yaml, .env.json, build\, Releases\, version.json).
# Auto-cd a la raiz para que funcione invocado desde cualquier carpeta.
Set-Location (Split-Path $PSScriptRoot -Parent)

$repo = "rubenmaltez/Template-TT"

function Check($msg) { if ($LASTEXITCODE -ne 0) { throw "FALLO: $msg (exit $LASTEXITCODE)" } }

# 0) Pre-checks
if (-not (Test-Path ".env.json")) { throw ".env.json no existe en la raiz (config Supabase/PowerSync). Sin eso la app abre con 'Configuracion pendiente'." }
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) { throw "flutter no esta en el PATH." }
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw "gh (GitHub CLI) no esta en el PATH (instalalo o subi el release por la web)." }

$ver = ((Select-String -Path pubspec.yaml -Pattern '^version:\s*(\S+)').Matches.Groups[1].Value).Split('+')[0]
if ([string]::IsNullOrWhiteSpace($Tag)) { $Tag = "v$ver" }
Write-Host "`n=== SITECSA CRM  $ver  ->  release $Tag ===`n" -ForegroundColor Cyan

# 1) Deps
flutter pub get; Check "flutter pub get"

# 2) Windows + MSIX (con env).
#    OJO: 'msix:create' por defecto RE-buildea Windows (perdiendo el env). Por eso
#    buildeamos nosotros CON env y le decimos a msix que NO re-buildee (empaqueta lo que hay).
Write-Host "==> Build Windows (con env)..." -ForegroundColor Cyan
flutter build windows --release --dart-define-from-file=.env.json; Check "flutter build windows"

Write-Host "==> Empaquetando MSIX (sin re-buildear)..." -ForegroundColor Cyan
$msixHelp = (dart run msix:create --help 2>&1 | Out-String)
$noBuild  = if ($msixHelp -match 'no-build-windows') { @('--no-build-windows') } else { @('--build-windows','false') }
dart run msix:create @noBuild; Check "msix:create"

# 3) Android APK (con env)
Write-Host "==> Build Android APK (con env)..." -ForegroundColor Cyan
flutter build apk --release --dart-define-from-file=.env.json; Check "flutter build apk"

# 4) Dos juegos de nombres:
#    - VERSIONADOS (SITECSA-CRM-vX.Y.Z.msix/.apk): se apilan en .\Releases\vX.Y.Z\
#      + copia al Escritorio. Muestran la version en el nombre; son los que
#      archivas y distribuis a mano.
#    - FIJOS (SITECSA-CRM.msix/.apk): SOLO para subir al GitHub Release, para que
#      el auto-update (version.json -> latest/download/<fijo>) resuelva sin
#      editar URLs por version. Transitorios y gitignored.
$msixPath = (Get-ChildItem -Recurse -Filter *.msix build\windows | Select-Object -First 1).FullName
if (-not $msixPath) { throw "No se encontro el .msix generado bajo build\windows." }
$apkPath  = "build\app\outputs\flutter-apk\app-release.apk"
$msixVer  = "SITECSA-CRM-$Tag.msix"
$apkVer   = "SITECSA-CRM-$Tag.apk"

# 4a) Carpeta de releases versionada (historico que se apila): .\Releases\vX.Y.Z\
$relDir = Join-Path "Releases" $Tag
New-Item -ItemType Directory -Force -Path $relDir | Out-Null
Copy-Item $msixPath (Join-Path $relDir $msixVer) -Force
Copy-Item $apkPath  (Join-Path $relDir $apkVer)  -Force
Write-Host "==> Instaladores versionados en $relDir" -ForegroundColor Green

# 4b) Copia versionada al Escritorio (comoda para mandar por WhatsApp/USB)
$desk = [Environment]::GetFolderPath("Desktop")
Copy-Item (Join-Path $relDir $msixVer) (Join-Path $desk $msixVer) -Force
Copy-Item (Join-Path $relDir $apkVer)  (Join-Path $desk $apkVer)  -Force
Write-Host "==> Copias versionadas en el Escritorio." -ForegroundColor Green

# 4c) Copias con nombre FIJO para el upload a GitHub (auto-update).
Copy-Item (Join-Path $relDir $msixVer) ".\SITECSA-CRM.msix" -Force
Copy-Item (Join-Path $relDir $apkVer)  ".\SITECSA-CRM.apk"  -Force

# 6) version.json al dia (solo el campo version; las URLs usan latest/download y no cambian)
$vj = Get-Content version.json -Raw | ConvertFrom-Json
$vj.version = $ver
($vj | ConvertTo-Json) | Set-Content version.json -Encoding UTF8

# 7) Publicar / actualizar el release
gh release view $Tag *> $null
if ($LASTEXITCODE -eq 0) {
  Write-Host "==> Release $Tag ya existe -> reemplazando assets..." -ForegroundColor Cyan
  gh release upload $Tag ".\SITECSA-CRM.msix" ".\SITECSA-CRM.apk" ".\version.json" --clobber; Check "gh release upload"
} else {
  Write-Host "==> Creando release $Tag..." -ForegroundColor Cyan
  gh release create $Tag ".\SITECSA-CRM.msix" ".\SITECSA-CRM.apk" ".\version.json" --title $Tag --notes "Release $Tag de SITECSA CRM."; Check "gh release create"
}

Write-Host "`n=== LISTO ===" -ForegroundColor Green
Write-Host "Release:    https://github.com/$repo/releases/tag/$Tag" -ForegroundColor Green
Write-Host "Archivo:    .\Releases\$Tag\  ($msixVer + $apkVer)" -ForegroundColor Green
Write-Host "Escritorio: $msixVer  +  $apkVer" -ForegroundColor Green
Write-Host "Probar PC:  .\build\windows\x64\runner\Release\isp_billing.exe  (ya viene con el env)`n" -ForegroundColor Green
