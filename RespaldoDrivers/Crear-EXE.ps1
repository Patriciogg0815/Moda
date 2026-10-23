<#
    Genera RespaldoDrivers.exe a partir de RespaldoDrivers.ps1 usando el módulo ps2exe.
    Ejecutar en Windows PowerShell:  powershell -ExecutionPolicy Bypass -File .\Crear-EXE.ps1
#>
$ErrorActionPreference = 'Stop'
if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host 'Instalando el módulo ps2exe (solo la primera vez)...'
    Install-Module ps2exe -Scope CurrentUser -Force
}
Import-Module ps2exe
$params = @{
    inputFile   = Join-Path $PSScriptRoot 'RespaldoDrivers.ps1'
    outputFile  = Join-Path $PSScriptRoot 'RespaldoDrivers.exe'
    noConsole   = $true
    requireAdmin = $true
    STA         = $true
    title       = 'Respaldo de Drivers'
    description = 'Respalda los drivers por categoría y los reinstala después de formatear'
    version     = '1.0.0'
}
Invoke-ps2exe @params
Write-Host "Listo: $($params.outputFile)" -ForegroundColor Green
