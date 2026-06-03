#requires -Version 7.0
<#
  uninstall.ps1  --  Desinstala SITECSA CRM del PC (full).

  Uso:  click derecho -> "Ejecutar con PowerShell"
        o:  pwsh -ExecutionPolicy Bypass -File .\uninstall.ps1

  NO requiere administrador (Remove-AppxPackage es por-usuario).
  Al desinstalar el MSIX, su data local (el SQLite de PowerSync que vive en el
  contenedor del paquete) se borra junto con la app -> queda 100% limpio.
#>
$ErrorActionPreference = "Stop"

$pkgs = @(Get-AppxPackage | Where-Object { $_.Name -like "*sitecsa*" })
if ($pkgs.Count -eq 0) {
  Write-Host "SITECSA CRM no esta instalada (nada que desinstalar)." -ForegroundColor Yellow
  return
}

foreach ($p in $pkgs) {
  Write-Host "Desinstalando $($p.Name)  v$($p.Version) ..." -ForegroundColor Cyan
  Remove-AppxPackage -Package $p.PackageFullName
}

# Limpiar AppData sobrante del paquete (sesion + SQLite local de PowerSync), por si
# Windows lo retuvo tras el Remove-AppxPackage (pasa con updates in-place).
Get-ChildItem "$env:LOCALAPPDATA\Packages" -Directory -Filter "*sitecsa*" -ErrorAction SilentlyContinue | ForEach-Object {
  Write-Host "Limpiando cache local: $($_.Name) ..." -ForegroundColor Cyan
  Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`n[OK] SITECSA CRM desinstalada + cache local borrada." -ForegroundColor Green
Write-Host "     OJO: esto borra solo lo LOCAL. La data (clientes/cuotas/pagos) vive en" -ForegroundColor Yellow
Write-Host "     Supabase (la nube) y se re-baja al loguearte. Para empezar de 0 de verdad" -ForegroundColor Yellow
Write-Host "     hay que vaciar el BACKEND (ver el wipe SQL)." -ForegroundColor Yellow
