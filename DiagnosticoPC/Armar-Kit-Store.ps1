<#
    Arma en esta PC todo lo que pide la Microsoft Store para Diagnóstico PC, sin GitHub:
    el .exe normal, el .exe de la Store, el .msix, las capturas, los logos, el arte y la ficha.

    Cómo usarlo: clic derecho en este archivo → "Ejecutar con PowerShell".
    O en PowerShell:  powershell -ExecutionPolicy Bypass -File .\Armar-Kit-Store.ps1

    -Version   Número de versión (por ejemplo 1.0.120). Si no se indica, usa uno más que la última vez
               (empieza en 1.0.100 para quedar por encima de las versiones que armó GitHub).
    -Salida    Carpeta donde queda el kit. Por defecto, en el Escritorio.
    -SinPausa  No espera Enter al final ni abre la carpeta (para pruebas automáticas).
#>
param(
    [string]$Version,
    [string]$Salida,
    [switch]$SinPausa
)
$ErrorActionPreference = 'Stop'
$raiz = $PSScriptRoot
$store = Join-Path $raiz 'store'

function Paso([string]$Texto) { Write-Host ''; Write-Host "== $Texto" -ForegroundColor Cyan }

try {
    # Número de versión: la Store exige que cada envío tenga una versión mayor que el anterior
    $datos = Join-Path $env:APPDATA 'DiagnosticoPC-Kit'
    $archivoVersion = Join-Path $datos 'ultima-version.txt'
    if (-not $Version) {
        $ultimo = 99
        $leido = 0
        if ((Test-Path $archivoVersion) -and [int]::TryParse((Get-Content $archivoVersion -Raw).Trim(), [ref]$leido) -and $leido -gt $ultimo) {
            $ultimo = $leido
        }
        $Version = "1.0.$($ultimo + 1)"
    }
    if ($Version -notmatch '^1\.0\.(\d+)$') { throw "La versión debe ser como 1.0.120. Recibido: $Version" }
    $numero = [int]$Matches[1]
    if (-not $Salida) { $Salida = Join-Path ([Environment]::GetFolderPath('Desktop')) "DiagnosticoPC-Store-$Version" }
    $Salida = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Salida)
    Write-Host "Diagnóstico PC $Version → $Salida" -ForegroundColor Green

    Paso 'Revisando ps2exe (convierte la app en .exe)'
    if (-not (Get-Module -ListAvailable -Name ps2exe)) {
        try {
            if ((Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue).InstallationPolicy -ne 'Trusted') {
                Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
            }
            Install-Module ps2exe -Scope CurrentUser -Force -ErrorAction Stop
        } catch {
            Write-Host "Install-Module falló ($_). Se descarga ps2exe directamente."
            $destino = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules\ps2exe'
            $zip = Join-Path $env:TEMP 'ps2exe.zip'
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest 'https://www.powershellgallery.com/api/v2/package/ps2exe' -OutFile $zip -UseBasicParsing
            if (Test-Path $destino) { Remove-Item $destino -Recurse -Force }
            Expand-Archive $zip -DestinationPath $destino -Force
        }
    }
    Import-Module ps2exe
    Write-Host "ps2exe $((Get-Module ps2exe).Version) listo"

    Paso 'Revisando el Windows SDK (arma el .msix)'
    $sdk = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\makeappx.exe" -ErrorAction SilentlyContinue
    if (-not $sdk) {
        Write-Host 'Falta el Windows SDK. Se intenta instalar con winget (puede tardar varios minutos)...'
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            winget install --id Microsoft.WindowsSDK.10.0.26100 -e --accept-package-agreements --accept-source-agreements
        }
        $sdk = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\makeappx.exe" -ErrorAction SilentlyContinue
        if (-not $sdk) {
            throw ('No se pudo instalar el Windows SDK. Descárgalo de https://developer.microsoft.com/windows/downloads/windows-sdk/ ' +
                   '(botón "Download the installer"), instálalo con las opciones por defecto y vuelve a ejecutar este archivo.')
        }
    }
    Write-Host 'Windows SDK listo'

    if (Test-Path $Salida) { Remove-Item $Salida -Recurse -Force }
    $temporal = Join-Path $Salida '_temporal'

    Paso 'Creando DiagnosticoPC.exe (para usar o compartir)'
    & (Join-Path $raiz 'Crear-EXE.ps1') -Version $Version -OutputDir (Join-Path $Salida 'exe')

    Paso 'Creando la edición para la Microsoft Store'
    & (Join-Path $raiz 'Crear-EXE.ps1') -Version $Version -OutputDir (Join-Path $temporal 'store') -EdicionStore

    Paso 'Creando DiagnosticoPC.msix'
    & (Join-Path $store 'Crear-MSIX.ps1') -ExePath (Join-Path $temporal 'store\DiagnosticoPC.exe') -Version "$Version.0" -OutputDir (Join-Path $temporal 'msix')

    Paso 'Juntando capturas, logos, arte y textos'
    Copy-Item (Join-Path $temporal 'msix\DiagnosticoPC.msix') $Salida
    Copy-Item (Join-Path $store 'LogoTienda-*.png'), (Join-Path $store 'ArteSuperheroe-*.png'), (Join-Path $store 'FICHA-TIENDA.md'), (Join-Path $store 'privacidad.html') $Salida
    New-Item -ItemType Directory -Path (Join-Path $Salida 'capturas') -Force | Out-Null
    Copy-Item (Join-Path $store 'capturas\*.png') (Join-Path $Salida 'capturas')
    Remove-Item $temporal -Recurse -Force

    New-Item -ItemType Directory -Path $datos -Force | Out-Null
    Set-Content -Path $archivoVersion -Value $numero

    Write-Host ''
    Write-Host "Listo. Sube $Salida\DiagnosticoPC.msix en Partner Center (Paquetes)." -ForegroundColor Green
    Get-ChildItem $Salida -Recurse -File | ForEach-Object { Write-Host "  $($_.FullName.Substring($Salida.Length + 1))" }
    if (-not $SinPausa) { Start-Process explorer.exe $Salida }
} catch {
    Write-Host ''
    Write-Host "No se pudo terminar: $_" -ForegroundColor Red
    if ($SinPausa) { throw }
}
if (-not $SinPausa) {
    Write-Host ''
    Read-Host 'Presiona Enter para cerrar'
}
