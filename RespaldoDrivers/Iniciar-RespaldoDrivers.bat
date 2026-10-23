@echo off
rem Abre "Respaldo de Drivers". Windows pedira permiso de administrador.
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%~dp0RespaldoDrivers.ps1" (
    echo No se encontro RespaldoDrivers.ps1 junto a este archivo.
    pause
    exit /b 1
)
start "" "%PS%" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0RespaldoDrivers.ps1"
