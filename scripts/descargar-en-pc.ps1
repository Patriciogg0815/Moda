# Descarga (o actualiza) el proyecto QuéVeo en C:\pelis
# Uso: clic derecho > "Ejecutar con PowerShell", o en PowerShell:
#   powershell -ExecutionPolicy Bypass -File C:\pelis\scripts\descargar-en-pc.ps1

$ErrorActionPreference = 'Stop'
$destino = 'C:\pelis'
$rama    = 'claude/lucid-wozniak-0g599n'
$url     = "https://github.com/Patriciogg0815/Moda/archive/refs/heads/$rama.zip"
$zip     = Join-Path $env:TEMP 'queveo.zip'
$tmp     = Join-Path $env:TEMP 'queveo-descarga'

Write-Host "Descargando QueVeo desde GitHub..."
Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing

if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
Expand-Archive -Path $zip -DestinationPath $tmp -Force
$carpeta = Get-ChildItem $tmp -Directory | Select-Object -First 1

New-Item -ItemType Directory -Force -Path $destino | Out-Null
# El APK con el nombre anterior ya no se usa
$apkViejo = Join-Path $destino 'apk\Moda.apk'
if (Test-Path $apkViejo) { Remove-Item $apkViejo -Force }
Copy-Item -Path (Join-Path $carpeta.FullName '*') -Destination $destino -Recurse -Force
Remove-Item $zip, $tmp -Recurse -Force

Write-Host ""
Write-Host "Listo. Proyecto guardado en $destino" -ForegroundColor Green
Write-Host "La app para Android esta en: $destino\apk\QueVeo.apk" -ForegroundColor Yellow
explorer.exe "$destino\apk"
