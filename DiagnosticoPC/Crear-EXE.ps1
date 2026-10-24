<#
    Genera DiagnosticoPC.exe a partir de DiagnosticoPC.ps1 usando el módulo ps2exe.
    Ejecutar en Windows PowerShell:  powershell -ExecutionPolicy Bypass -File .\Crear-EXE.ps1

    -EdicionStore   Genera la edición para la Microsoft Store (sin la opción "Iniciar con Windows").
#>
param(
    [string]$Version = '1.0.0',
    [string]$OutputDir = $PSScriptRoot,
    [switch]$EdicionStore
)
$ErrorActionPreference = 'Stop'
if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host 'Instalando el módulo ps2exe (solo la primera vez)...'
    Install-Module ps2exe -Scope CurrentUser -Force
}
Import-Module ps2exe
$OutputDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDir)
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$source = Join-Path $PSScriptRoot 'DiagnosticoPC.ps1'
$work = Join-Path ([IO.Path]::GetTempPath()) ("DiagnosticoPC-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null

try {
    # Copia del script con la versión y la edición elegidas
    $text = [IO.File]::ReadAllText($source, [Text.Encoding]::UTF8)
    $versionMarker = "`$script:AppVersion   = '1.0.0'"
    if (-not $text.Contains($versionMarker)) { throw "No se encontró $versionMarker en DiagnosticoPC.ps1" }
    $text = $text.Replace($versionMarker, "`$script:AppVersion   = '$Version'")
    if ($EdicionStore) {
        $storeMarker = "`$script:StoreEdition = `$false"
        if (-not $text.Contains($storeMarker)) { throw "No se encontró $storeMarker en DiagnosticoPC.ps1" }
        $text = $text.Replace($storeMarker, "`$script:StoreEdition = `$true")
    }
    $inputPath = Join-Path $work 'DiagnosticoPC.ps1'
    [IO.File]::WriteAllText($inputPath, $text, (New-Object Text.UTF8Encoding($true)))

    $params = @{
        inputFile    = $inputPath
        outputFile   = Join-Path $OutputDir 'DiagnosticoPC.exe'
        noConsole    = $true
        x64          = $true
        iconFile     = Join-Path $PSScriptRoot 'icono.ico'
        requireAdmin = $true
        STA          = $true
        title        = 'Diagnóstico PC'
        description  = 'Revisa Windows y muestra los problemas en rojo, amarillo y verde, con el paso a paso para arreglarlos'
        product      = 'Diagnóstico PC'
        company      = 'GarridoitSolutions'
        version      = $Version
    }
    Invoke-ps2exe @params
    if (-not (Test-Path $params.outputFile)) { throw 'No se generó el archivo .exe' }
    $edition = if ($EdicionStore) { ' (edición Microsoft Store)' } else { '' }
    Write-Host "Listo$($edition): $($params.outputFile)" -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
