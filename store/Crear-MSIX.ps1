<#
    Arma el paquete MSIX para la Microsoft Store a partir de RespaldoDrivers.exe.
    Usa identidad.json (datos de Partner Center), AppxManifest.xml (plantilla) y la carpeta Assets.

    Ejemplo:
        .\store\Crear-MSIX.ps1 -ExePath .\dist\RespaldoDrivers.exe -Version 1.0.5.0 -OutputDir .\dist-store
#>
param(
    [Parameter(Mandatory)][string]$ExePath,
    [string]$Version = '1.0.0.0',
    [string]$OutputDir = (Join-Path $PSScriptRoot 'salida')
)
$ErrorActionPreference = 'Stop'
$resolve = { param($p) $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($p) }
$ExePath = & $resolve $ExePath
$OutputDir = & $resolve $OutputDir

if ($Version -notmatch '^\d+\.\d+\.\d+\.0$') { throw "La versión debe tener 4 números y terminar en .0 (por ejemplo 1.0.5.0). Recibido: $Version" }
if (-not (Test-Path -LiteralPath $ExePath)) { throw "No se encontró el .exe: $ExePath" }

# Herramientas del Windows SDK (makeappx y makepri)
function Find-SdkTool([string]$Name) {
    $tool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\$Name" -ErrorAction SilentlyContinue |
        Sort-Object { [version]$_.Directory.Parent.Name } -Descending | Select-Object -First 1
    if (-not $tool) { throw "No se encontró $Name. Instala el Windows 10/11 SDK." }
    $tool.FullName
}
$makeAppx = Find-SdkTool 'makeappx.exe'
$makePri = Find-SdkTool 'makepri.exe'

$id = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'identidad.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ("$($id.IdentityName)$($id.Publisher)$($id.PublisherDisplayName)" -match 'PENDIENTE') {
    Write-Warning 'identidad.json todavía tiene valores PENDIENTE: el paquete sirve para pruebas, pero la Store lo rechazará.'
}

# Carpeta con el contenido del paquete
$layout = Join-Path $OutputDir 'contenido'
if (Test-Path $layout) { Remove-Item $layout -Recurse -Force }
New-Item -ItemType Directory -Path (Join-Path $layout 'Assets') -Force | Out-Null
Copy-Item -LiteralPath $ExePath -Destination (Join-Path $layout 'RespaldoDrivers.exe')
Copy-Item -Path (Join-Path $PSScriptRoot 'Assets\*.png') -Destination (Join-Path $layout 'Assets')

$manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'AppxManifest.xml') -Raw -Encoding UTF8
$values = @{
    IdentityName         = $id.IdentityName
    Publisher            = $id.Publisher
    PublisherDisplayName = $id.PublisherDisplayName
    DisplayName          = $id.DisplayName
    Version              = $Version
}
foreach ($k in $values.Keys) { $manifest = $manifest.Replace("{{$k}}", [Security.SecurityElement]::Escape($values[$k])) }
if ($manifest -match '\{\{\w+\}\}') { throw "Quedó un valor sin reemplazar en el manifiesto: $($Matches[0])" }
[IO.File]::WriteAllText((Join-Path $layout 'AppxManifest.xml'), $manifest, (New-Object Text.UTF8Encoding($false)))

# Índice de recursos (para que Windows elija el ícono del tamaño correcto)
$priConfig = Join-Path $OutputDir 'priconfig.xml'
& $makePri createconfig /cf $priConfig /dq es-MX /pv 10.0.0 /o | Out-Host
if ($LASTEXITCODE) { throw "makepri createconfig falló ($LASTEXITCODE)" }
& $makePri new /pr $layout /cf $priConfig /mn (Join-Path $layout 'AppxManifest.xml') /of (Join-Path $layout 'resources.pri') /o | Out-Host
if ($LASTEXITCODE) { throw "makepri new falló ($LASTEXITCODE)" }

$msix = Join-Path $OutputDir 'RespaldoDrivers.msix'
& $makeAppx pack /d $layout /p $msix /o | Out-Host
if ($LASTEXITCODE) { throw "makeappx pack falló ($LASTEXITCODE)" }

Write-Host "Listo: $msix ($([math]::Round((Get-Item $msix).Length / 1KB)) KB, versión $Version)" -ForegroundColor Green
