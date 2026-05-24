# release.ps1 — Script de release para Cobranza ISP
# Uso: .\release.ps1 -Version "0.2.0" -Notes "Descripcion del cambio"
#
# Automatiza: version bump, commit, tag, build Windows+Android,
# renombrar archivos, generar version.json, abrir GitHub Releases.
# Paso manual: arrastrar archivos al release + subir version.json a Supabase.

param(
    [Parameter(Mandatory=$true)]
    [string]$Version,

    [Parameter(Mandatory=$true)]
    [string]$Notes
)

$ErrorActionPreference = "Stop"
$repo = "rubenmaltez/Template-TT"

Write-Host "`n=== Release v$Version ===" -ForegroundColor Cyan

# 1. Actualizar version en pubspec.yaml
Write-Host "`n[1/7] Actualizando pubspec.yaml..." -ForegroundColor Yellow
$pubspec = Get-Content "pubspec.yaml" -Raw
$pubspec = $pubspec -replace 'version: [\d]+\.[\d]+\.[\d]+\+\d+', "version: $Version+$($Version.Replace('.',''))"
Set-Content "pubspec.yaml" $pubspec
Write-Host "  version: $Version" -ForegroundColor Green

# 2. Commit + push + tag
Write-Host "`n[2/7] Commit + push + tag..." -ForegroundColor Yellow
git add pubspec.yaml
git commit -m "release: v$Version - $Notes"
git push origin main
git tag "v$Version"
git push origin "v$Version"
Write-Host "  Tag v$Version pusheado" -ForegroundColor Green

# 3. Build Windows
Write-Host "`n[3/7] Building Windows..." -ForegroundColor Yellow
flutter build windows --release --dart-define-from-file=.env.json
dart run msix:create --build-windows false
Write-Host "  Windows build OK" -ForegroundColor Green

# 4. Build Android
Write-Host "`n[4/7] Building Android..." -ForegroundColor Yellow
flutter build apk --release --dart-define-from-file=.env.json
Write-Host "  Android build OK" -ForegroundColor Green

# 5. Renombrar archivos
Write-Host "`n[5/7] Renombrando archivos..." -ForegroundColor Yellow
Copy-Item "build\windows\x64\runner\Release\isp_billing.msix" "cobranza-isp-$Version.msix" -Force
Copy-Item "build\app\outputs\flutter-apk\app-release.apk" "cobranza-isp-$Version.apk" -Force
Write-Host "  cobranza-isp-$Version.msix" -ForegroundColor Green
Write-Host "  cobranza-isp-$Version.apk" -ForegroundColor Green

# 6. Generar version.json
Write-Host "`n[6/7] Generando version.json..." -ForegroundColor Yellow
@"
{
  "version": "$Version",
  "download_url_windows": "https://github.com/$repo/releases/download/v$Version/cobranza-isp-$Version.msix",
  "download_url_android": "https://github.com/$repo/releases/download/v$Version/cobranza-isp-$Version.apk",
  "release_notes": "$Notes"
}
"@ | Out-File -Encoding utf8 "version.json"
Write-Host "  version.json generado" -ForegroundColor Green

# 7. Abrir browser
Write-Host "`n[7/7] Abriendo GitHub Releases..." -ForegroundColor Yellow
Start-Process "https://github.com/$repo/releases/new?tag=v$Version"

Write-Host "`n=== Build completado ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Pasos manuales:" -ForegroundColor Yellow
Write-Host "  1. Arrastra al release en GitHub:" -ForegroundColor White
Write-Host "     - cobranza-isp-$Version.msix" -ForegroundColor Gray
Write-Host "     - cobranza-isp-$Version.apk" -ForegroundColor Gray
Write-Host "     - version.json" -ForegroundColor Gray
Write-Host "  2. Click 'Publish release'" -ForegroundColor White
Write-Host "  3. Supabase Storage -> Installers: reemplazar version.json" -ForegroundColor White
Write-Host ""
