# release.ps1 — Script de release para Cobranza ISP
# Uso: .\release.ps1 -Version "0.2.0" -Notes "Descripcion del cambio"
#
# 100% automatizado: version bump, commit, tag, build Windows+Android,
# crear GitHub Release con assets, actualizar version.json en Supabase.
# Requiere: flutter, dart, git, gh (GitHub CLI), supabase CLI.

param(
    [Parameter(Mandatory=$true)]
    [string]$Version,

    [Parameter(Mandatory=$true)]
    [string]$Notes
)

$ErrorActionPreference = "Stop"
$repo = "rubenmaltez/Template-TT"
$supabaseProject = "vxxzesbmilfolwjhfxgr"
$bucket = "Installers"

Write-Host "`n=== Release v$Version ===" -ForegroundColor Cyan

# 1. Actualizar version en pubspec.yaml
Write-Host "`n[1/8] Actualizando pubspec.yaml..." -ForegroundColor Yellow
$pubspec = Get-Content "pubspec.yaml" -Raw
$pubspec = $pubspec -replace 'version: [\d]+\.[\d]+\.[\d]+\+\d+', "version: $Version+$($Version.Replace('.',''))"
Set-Content "pubspec.yaml" $pubspec
Write-Host "  version: $Version" -ForegroundColor Green

# 2. Commit + push + tag
Write-Host "`n[2/8] Commit + push + tag..." -ForegroundColor Yellow
git add pubspec.yaml
git commit -m "release: v$Version - $Notes"
git push origin main
git tag "v$Version"
git push origin "v$Version"
Write-Host "  Tag v$Version pusheado" -ForegroundColor Green

# 3. Build Windows
Write-Host "`n[3/8] Building Windows..." -ForegroundColor Yellow
flutter build windows --release --dart-define-from-file=.env.json
dart run msix:create --build-windows false
Write-Host "  Windows build OK" -ForegroundColor Green

# 4. Build Android
Write-Host "`n[4/8] Building Android..." -ForegroundColor Yellow
flutter build apk --release --dart-define-from-file=.env.json
Write-Host "  Android build OK" -ForegroundColor Green

# 5. Renombrar archivos
Write-Host "`n[5/8] Preparando archivos..." -ForegroundColor Yellow
$msix = "cobranza-isp-$Version.msix"
$apk = "cobranza-isp-$Version.apk"
Copy-Item "build\windows\x64\runner\Release\isp_billing.msix" $msix -Force
Copy-Item "build\app\outputs\flutter-apk\app-release.apk" $apk -Force
Write-Host "  $msix ($([math]::Round((Get-Item $msix).Length/1MB, 1)) MB)" -ForegroundColor Green
Write-Host "  $apk ($([math]::Round((Get-Item $apk).Length/1MB, 1)) MB)" -ForegroundColor Green

# 6. Generar version.json
Write-Host "`n[6/8] Generando version.json..." -ForegroundColor Yellow
@"
{
  "version": "$Version",
  "download_url_windows": "https://github.com/$repo/releases/download/v$Version/$msix",
  "download_url_android": "https://github.com/$repo/releases/download/v$Version/$apk",
  "release_notes": "$Notes"
}
"@ | Out-File -Encoding utf8 "version.json"
Write-Host "  version.json listo" -ForegroundColor Green

# 7. Crear GitHub Release con assets
Write-Host "`n[7/8] Creando GitHub Release..." -ForegroundColor Yellow
gh release create "v$Version" $msix $apk "version.json" --repo $repo --title "v$Version - $Notes" --notes $Notes
Write-Host "  Release v$Version publicado con 3 assets" -ForegroundColor Green

# 8. Subir version.json a Supabase Storage
Write-Host "`n[8/8] Actualizando version.json en Supabase Storage..." -ForegroundColor Yellow
$supabaseUrl = "https://$supabaseProject.supabase.co"
$serviceKey = (Get-Content ".env.json" | ConvertFrom-Json).SUPABASE_ANON_KEY
# Borrar el viejo
try {
    Invoke-RestMethod -Uri "$supabaseUrl/storage/v1/object/$bucket/version.json" -Method Delete -Headers @{ "Authorization" = "Bearer $serviceKey"; "apikey" = $serviceKey }
} catch { }
# Subir el nuevo
$bytes = [System.IO.File]::ReadAllBytes("$PWD\version.json")
Invoke-RestMethod -Uri "$supabaseUrl/storage/v1/object/$bucket/version.json" -Method Post -Headers @{ "Authorization" = "Bearer $serviceKey"; "apikey" = $serviceKey; "Content-Type" = "application/json" } -Body $bytes
Write-Host "  version.json actualizado en Supabase Storage" -ForegroundColor Green

Write-Host "`n=== Release v$Version completado ===" -ForegroundColor Cyan
Write-Host "Los users veran el banner de update al abrir la app." -ForegroundColor Green
Write-Host ""
