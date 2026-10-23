<#
    Genera RespaldoDrivers.exe a partir de RespaldoDrivers.ps1 usando el módulo ps2exe.
    Ejecutar en Windows PowerShell:  powershell -ExecutionPolicy Bypass -File .\Crear-EXE.ps1
#>
param(
    [string]$Version = '1.0.0',
    [string]$OutputDir = $PSScriptRoot
)
$ErrorActionPreference = 'Stop'
if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host 'Instalando el módulo ps2exe (solo la primera vez)...'
    Install-Module ps2exe -Scope CurrentUser -Force
}
Import-Module ps2exe
$OutputDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDir)
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$params = @{
    inputFile    = Join-Path $PSScriptRoot 'RespaldoDrivers.ps1'
    outputFile   = Join-Path $OutputDir 'RespaldoDrivers.exe'
    noConsole    = $true
    x64          = $true
    iconFile     = Join-Path $PSScriptRoot 'icono.ico'
    requireAdmin = $true
    STA          = $true
    title        = 'Respaldo de Drivers'
    description  = 'Respalda los drivers por categoría y los reinstala después de formatear'
    product      = 'Respaldo de Drivers'
    version      = $Version
}
Invoke-ps2exe @params
if (-not (Test-Path $params.outputFile)) { throw 'No se generó el archivo .exe' }
Write-Host "Listo: $($params.outputFile)" -ForegroundColor Green
