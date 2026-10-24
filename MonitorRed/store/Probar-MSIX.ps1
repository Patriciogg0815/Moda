<#
    Prueba el paquete MSIX: lo firma con un certificado de prueba, lo instala, comprueba que
    Windows lo registró y lo desinstala. Necesita permisos de administrador (lo usa GitHub Actions).
    El paquete que se sube a la Store es el original sin firmar: la Store lo firma.
#>
param([Parameter(Mandatory)][string]$Package)
$ErrorActionPreference = 'Stop'
$Package = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Package)
$signTool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" |
    Sort-Object { [version]$_.Directory.Parent.Name } -Descending | Select-Object -First 1 -ExpandProperty FullName

$id = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'identidad.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$work = Join-Path ([IO.Path]::GetTempPath()) ('msix-prueba-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $work | Out-Null
$testPackage = Join-Path $work 'MonitorRed-prueba.msix'
Copy-Item -LiteralPath $Package -Destination $testPackage

# Certificado de prueba con el mismo "Publisher" del manifiesto
$cert = New-SelfSignedCertificate -Type Custom -Subject $id.Publisher -KeyUsage DigitalSignature `
    -FriendlyName 'Monitor de Red (prueba)' -CertStoreLocation 'Cert:\CurrentUser\My' `
    -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')
$pfx = Join-Path $work 'prueba.pfx'
$password = ConvertTo-SecureString -String 'prueba' -Force -AsPlainText
Export-PfxCertificate -Cert $cert -FilePath $pfx -Password $password | Out-Null
Import-PfxCertificate -FilePath $pfx -CertStoreLocation 'Cert:\LocalMachine\TrustedPeople' -Password $password | Out-Null

try {
    & $signTool sign /fd SHA256 /f $pfx /p prueba $testPackage | Out-Host
    if ($LASTEXITCODE) { throw "signtool falló ($LASTEXITCODE)" }

    Add-AppxPackage -Path $testPackage
    $installed = Get-AppxPackage -Name $id.IdentityName
    if (-not $installed) { throw 'El paquete no aparece instalado.' }
    Write-Host "OK: instalado $($installed.Name) $($installed.Version) en $($installed.InstallLocation)"

    $exe = Join-Path $installed.InstallLocation 'MonitorRed.exe'
    if (-not (Test-Path $exe)) { throw 'Falta MonitorRed.exe dentro del paquete.' }
    $manifest = (Get-AppxPackageManifest $installed).Package
    $app = $manifest.Applications.Application
    Write-Host "OK: aplicación '$($app.Id)' -> $($app.Executable)"
    $caps = $manifest.Capabilities.ChildNodes | Where-Object { $_.NodeType -eq 'Element' } | ForEach-Object { $_.GetAttribute('Name') }
    foreach ($needed in 'runFullTrust', 'privateNetworkClientServer') {
        if ($caps -notcontains $needed) { throw "Falta el permiso $needed en el paquete." }
    }
    Write-Host "OK: permisos declarados: $($caps -join ', ')"
} finally {
    $leftover = Get-AppxPackage -Name $id.IdentityName
    if ($leftover) {
        Remove-AppxPackage -Package $leftover.PackageFullName
        Write-Host 'OK: paquete de prueba desinstalado'
    }
    Get-ChildItem 'Cert:\LocalMachine\TrustedPeople', 'Cert:\CurrentUser\My' |
        Where-Object Thumbprint -eq $cert.Thumbprint | Remove-Item
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
