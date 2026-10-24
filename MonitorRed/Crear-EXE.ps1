<#
    Genera MonitorRed.exe a partir de MonitorRed.ps1 usando el módulo ps2exe.
    Antes incrusta la base de fabricantes por MAC, para que la app funcione sin internet, y las DLL de WebView2
    que muestran el banner de publicidad.
    Ejecutar en Windows PowerShell:  powershell -ExecutionPolicy Bypass -File .\Crear-EXE.ps1

    -EdicionStore   Genera la edición para la Microsoft Store (sin el modo de interceptar tráfico).
    -Fabricantes    Usa un fabricantes.gz ya generado en vez de descargarlo.
    -WebView2       Usa un webview2.zip ya preparado (Preparar-WebView2.ps1) en vez de descargarlo.
#>
param(
    [string]$Version = '1.0.0',
    [string]$OutputDir = $PSScriptRoot,
    [switch]$EdicionStore,
    [string]$Fabricantes,
    [string]$WebView2
)
$ErrorActionPreference = 'Stop'
if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host 'Instalando el módulo ps2exe (solo la primera vez)...'
    Install-Module ps2exe -Scope CurrentUser -Force
}
Import-Module ps2exe
$OutputDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDir)
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$source = Join-Path $PSScriptRoot 'MonitorRed.ps1'
$work = Join-Path ([IO.Path]::GetTempPath()) ("MonitorRed-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null

try {
    # 1. Base de fabricantes (registro público de la IEEE, vía el archivo "manuf" de Wireshark)
    if (-not $Fabricantes) {
        $Fabricantes = Join-Path $work 'fabricantes.gz'
        & powershell -NoProfile -ExecutionPolicy Bypass -File $source -GenerarFabricantes $Fabricantes
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $Fabricantes)) { throw 'No se pudo generar la base de fabricantes.' }
    }
    $oui = [Convert]::ToBase64String([IO.File]::ReadAllBytes($Fabricantes))

    # 1b. DLL de WebView2 para el banner de publicidad (paquete oficial de Microsoft en NuGet).
    # La edición Store NO lleva publicidad, así que no incrusta WebView2 (paquete más liviano y sin el navegador).
    $webView2Zip = ''
    if (-not $EdicionStore) {
        if (-not $WebView2) {
            $WebView2 = Join-Path $work 'webview2.zip'
            & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Preparar-WebView2.ps1') -Destino $WebView2
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path $WebView2)) { throw 'No se pudo preparar WebView2.' }
        }
        $webView2Zip = [Convert]::ToBase64String([IO.File]::ReadAllBytes($WebView2))
    }

    # 2. Copia del script con la base incrustada (y la edición elegida)
    $text = [IO.File]::ReadAllText($source, [Text.Encoding]::UTF8)
    $marker = "`$script:EmbeddedOui = ''"
    if (-not $text.Contains($marker)) { throw "No se encontró $marker en MonitorRed.ps1" }
    $text = $text.Replace($marker, "`$script:EmbeddedOui = '$oui'")
    if (-not $EdicionStore) {
        $wvMarker = "`$script:EmbeddedWebView2 = ''"
        if (-not $text.Contains($wvMarker)) { throw "No se encontró $wvMarker en MonitorRed.ps1" }
        $text = $text.Replace($wvMarker, "`$script:EmbeddedWebView2 = '$webView2Zip'")
    }
    $text = $text.Replace("`$script:AppVersion = '1.0.0'", "`$script:AppVersion = '$Version'")
    if ($EdicionStore) {
        $storeMarker = "`$script:StoreEdition = `$false"
        if (-not $text.Contains($storeMarker)) { throw "No se encontró $storeMarker en MonitorRed.ps1" }
        $text = $text.Replace($storeMarker, "`$script:StoreEdition = `$true")
    }
    $inputPath = Join-Path $work 'MonitorRed.ps1'
    [IO.File]::WriteAllText($inputPath, $text, (New-Object Text.UTF8Encoding($true)))

    # 3. Compilar
    $params = @{
        inputFile   = $inputPath
        outputFile  = Join-Path $OutputDir 'MonitorRed.exe'
        noConsole   = $true
        x64         = $true
        iconFile    = Join-Path $PSScriptRoot 'icono.ico'
        STA         = $true
        title       = 'Monitor de Red'
        description = 'Muestra los equipos conectados a la red de la casa'
        product     = 'Monitor de Red'
        version     = $Version
    }
    Invoke-ps2exe @params
    if (-not (Test-Path $params.outputFile)) { throw 'No se generó el archivo .exe' }
    $edition = if ($EdicionStore) { ' (edición Microsoft Store)' } else { '' }
    Write-Host "Listo$($edition): $($params.outputFile)" -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
