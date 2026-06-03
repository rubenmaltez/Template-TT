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

Write-Host "`n[OK] SITECSA CRM desinstalada del PC (data local incluida)." -ForegroundColor Green
Write-Host "     El certificado de confianza queda instalado (no molesta y sirve" -ForegroundColor DarkGray
Write-Host "     para reinstalar sin volver a pedir permisos)." -ForegroundColor DarkGray
