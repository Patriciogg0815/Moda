<#
    Prepara webview2.zip con las DLL de WebView2 que necesita el banner de publicidad de MonitorRed.exe.
    Descarga el paquete oficial de Microsoft desde NuGet, comprueba su huella SHA-256 y guarda solo:
      Microsoft.Web.WebView2.Core.dll, Microsoft.Web.WebView2.Wpf.dll (lib\net462) y WebView2Loader.dll (win-x64).
    La versión es la de $script:WebView2Version en MonitorRed.ps1.

    Ejecutar en Windows PowerShell:  powershell -ExecutionPolicy Bypass -File .\Preparar-WebView2.ps1 -Destino .\webview2.zip
    Con -Carpeta además deja las DLL sueltas (por ejemplo en .\webview2, para probar MonitorRed.ps1 sin compilar).
#>
param(
    [Parameter(Mandatory)][string]$Destino,
    [string]$Carpeta
)
$ErrorActionPreference = 'Stop'

# Huella SHA-256 del paquete de NuGet de cada versión. Al cambiar de versión, agregar aquí la nueva huella.
$knownHashes = @{
    '1.0.3912.50' = '8DD696301D8E5AD8389F26B636329BBF35754B793974E82168B1F6DDA234EB07'
}

$source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'MonitorRed.ps1'), [Text.Encoding]::UTF8)
if ($source -notmatch "\`$script:WebView2Version = '([\d.]+)'") { throw 'No se encontró $script:WebView2Version en MonitorRed.ps1' }
$version = $Matches[1]
if (-not $knownHashes.ContainsKey($version)) { throw "Falta la huella SHA-256 del paquete WebView2 $version en Preparar-WebView2.ps1" }

$Destino = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destino)
$work = Join-Path ([IO.Path]::GetTempPath()) ('WebView2-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $work 'dll') -Force | Out-Null
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $nupkg = Join-Path $work 'webview2.nupkg'
    $url = "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/$version/microsoft.web.webview2.$version.nupkg"
    Write-Host "Descargando WebView2 $version..."
    Invoke-WebRequest -Uri $url -OutFile $nupkg -UseBasicParsing
    $hash = (Get-FileHash -LiteralPath $nupkg -Algorithm SHA256).Hash
    if ($hash -ne $knownHashes[$version]) { throw "La huella del paquete WebView2 no coincide ($hash): no se usa." }

    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $wanted = @{
        'lib/net462/Microsoft.Web.WebView2.Core.dll'      = 'Microsoft.Web.WebView2.Core.dll'
        'lib/net462/Microsoft.Web.WebView2.Wpf.dll'       = 'Microsoft.Web.WebView2.Wpf.dll'
        'runtimes/win-x64/native/WebView2Loader.dll'      = 'WebView2Loader.dll'
    }
    $pkg = [IO.Compression.ZipFile]::OpenRead($nupkg)
    try {
        foreach ($entry in $pkg.Entries) {
            if ($wanted.ContainsKey($entry.FullName)) {
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $work "dll\$($wanted[$entry.FullName])"), $true)
            }
        }
    } finally { $pkg.Dispose() }
    foreach ($name in $wanted.Values) {
        if (-not (Test-Path -LiteralPath (Join-Path $work "dll\$name"))) { throw "El paquete WebView2 no trae $name" }
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent $Destino) -Force | Out-Null
    if (Test-Path -LiteralPath $Destino) { Remove-Item -LiteralPath $Destino -Force }
    [IO.Compression.ZipFile]::CreateFromDirectory((Join-Path $work 'dll'), $Destino)
    if ($Carpeta) {
        $Carpeta = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Carpeta)
        New-Item -ItemType Directory -Path $Carpeta -Force | Out-Null
        Copy-Item -Path (Join-Path $work 'dll\*') -Destination $Carpeta -Force
    }
    Write-Host "Listo: WebView2 $version → $Destino" -ForegroundColor Green
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
