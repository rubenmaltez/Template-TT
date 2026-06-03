#requires -Version 7.0
<#
  install-latest.ps1  --  Baja la ULTIMA version de SITECSA CRM de GitHub e instala (PC).

  CORRER COMO ADMINISTRADOR (click derecho -> "Ejecutar como administrador"),
  porque el MSIX esta firmado con un certificado self-signed y hay que confiarlo
  en el almacen de la maquina antes de instalar.

  Que hace, solo:
    1. Descarga SITECSA-CRM.msix del release "latest" de GitHub.
    2. Extrae el certificado del MSIX y lo confia (LocalMachine\TrustedPeople).
    3. Instala (o actualiza) la app.
#>
$ErrorActionPreference = "Stop"
$repo    = "rubenmaltez/Template-TT"
$msixUrl = "https://github.com/$repo/releases/latest/download/SITECSA-CRM.msix"
$tmpMsix = Join-Path $env:TEMP "SITECSA-CRM.msix"
$tmpCer  = Join-Path $env:TEMP "SITECSA-CRM.cer"

# Necesita admin para importar el cert a LocalMachine\TrustedPeople
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
  throw "Corre este script COMO ADMINISTRADOR (click derecho -> Ejecutar como administrador). Hace falta para confiar el certificado."
}

Write-Host "==> Descargando la ultima version desde GitHub..." -ForegroundColor Cyan
Invoke-WebRequest -Uri $msixUrl -OutFile $tmpMsix
$sizeMB = [math]::Round((Get-Item $tmpMsix).Length / 1MB, 1)
Write-Host "    Descargado: $sizeMB MB" -ForegroundColor DarkGray

Write-Host "==> Confiando el certificado del instalador..." -ForegroundColor Cyan
$sig = Get-AuthenticodeSignature $tmpMsix
if (-not $sig.SignerCertificate) { throw "El MSIX descargado no tiene firma. Abortando." }
Export-Certificate -Cert $sig.SignerCertificate -FilePath $tmpCer | Out-Null
Import-Certificate -FilePath $tmpCer -CertStoreLocation "Cert:\LocalMachine\TrustedPeople" | Out-Null

Write-Host "==> Instalando / actualizando..." -ForegroundColor Cyan
Add-AppxPackage -Path $tmpMsix -ForceApplicationShutdown -ForceUpdateFromAnyVersion

$inst = @(Get-AppxPackage | Where-Object { $_.Name -like "*sitecsa*" })[0]
Write-Host "`n[OK] SITECSA CRM instalada: v$($inst.Version). Buscala en el menu Inicio." -ForegroundColor Green
