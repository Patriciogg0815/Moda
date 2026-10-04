# Descarga (o actualiza) el proyecto Moda en C:\Moda
# Uso: clic derecho > "Ejecutar con PowerShell", o en PowerShell:
#   powershell -ExecutionPolicy Bypass -File C:\Moda\scripts\descargar-en-pc.ps1

$ErrorActionPreference = 'Stop'
$destino = 'C:\Moda'
$rama    = 'claude/movie-series-recommender-app-unh84n'
$url     = "https://github.com/Patriciogg0815/Moda/archive/refs/heads/$rama.zip"
$zip     = Join-Path $env:TEMP 'moda.zip'
$tmp     = Join-Path $env:TEMP 'moda-descarga'

Write-Host "Descargando Moda desde GitHub..."
Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing

if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
Expand-Archive -Path $zip -DestinationPath $tmp -Force
$carpeta = Get-ChildItem $tmp -Directory | Select-Object -First 1

New-Item -ItemType Directory -Force -Path $destino | Out-Null
Copy-Item -Path (Join-Path $carpeta.FullName '*') -Destination $destino -Recurse -Force
Remove-Item $zip, $tmp -Recurse -Force

Write-Host ""
Write-Host "Listo. Proyecto guardado en $destino" -ForegroundColor Green
Write-Host "La app para Android esta en: $destino\apk\Moda.apk" -ForegroundColor Yellow
explorer.exe "$destino\apk"
