#Requires -Version 5.1
<#
.SYNOPSIS
    Respaldo de Drivers: guarda los drivers instalados en el equipo organizados
    por categoría y los vuelve a instalar después de formatear.

.DESCRIPTION
    Modo gráfico (normal): doble clic en Iniciar-RespaldoDrivers.bat

    Modo línea de comandos (sin ventana):
        .\RespaldoDrivers.ps1 -Respaldar "E:\"
            Crea E:\Drivers_<Fabricante>_<Modelo>_<fecha> con todos los drivers.
        .\RespaldoDrivers.ps1 -Restaurar "E:\Drivers_HP_ProBook_450_2026-10-23"
            Instala todos los drivers del respaldo (excepto firmware/BIOS).

.NOTES
    Requiere Windows 10 (1607 o superior) u 11 y permisos de administrador.
    Solo se respaldan drivers de terceros (los que Windows no trae de fábrica).
#>
[CmdletBinding()]
param(
    [string]$Respaldar,
    [string]$Restaurar,
    [switch]$Elevado
)

$ErrorActionPreference = 'Stop'

$script:AppVersion       = '1.0.0'
$script:ManifestName     = 'respaldo.json'
$script:LauncherName     = 'Iniciar-RespaldoDrivers.bat'
$script:FirmwareCategory = 'Firmware y BIOS'
$script:Gui              = $null
$script:LogFile          = $null

# Ruta del script (o del .exe si se compiló con ps2exe)
$script:ScriptPath = if ($PSCommandPath) { $PSCommandPath } else { [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName }
$script:ScriptDir  = Split-Path -Parent $script:ScriptPath
$script:IsExe      = $script:ScriptPath -like '*.exe'

if ($Respaldar) { $Respaldar = $Respaldar.TrimEnd('\') }
if ($Restaurar) { $Restaurar = $Restaurar.TrimEnd('\') }

#region Permisos de administrador

function Test-IsAdmin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$script:ScriptPath`"", '-Elevado')
    if ($Respaldar) { $argList += @('-Respaldar', "`"$Respaldar`"") }
    if ($Restaurar) { $argList += @('-Restaurar', "`"$Restaurar`"") }
    if (-not ($Respaldar -or $Restaurar)) { $argList = @('-WindowStyle', 'Hidden') + $argList }
    try {
        Start-Process -FilePath ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -Verb RunAs -ArgumentList $argList
    } catch {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show(
            'Se necesitan permisos de administrador para respaldar e instalar drivers.',
            'Respaldo de Drivers', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
    }
    exit
}

#endregion

#region Categorías

# El orden define el nombre de la carpeta (01, 02...) y el orden de instalación:
# primero chipset y almacenamiento, al final extensiones y componentes de software.
$script:Categories = @(
    @{ Order = 1;  Name = 'Chipset y Sistema';           Classes = 'System', 'Processor', 'MultiFunction', 'Computer' }
    @{ Order = 2;  Name = 'Almacenamiento (SATA-NVMe)';  Classes = 'HDC', 'SCSIAdapter', 'DiskDrive', 'CDROM', 'Volume' }
    @{ Order = 3;  Name = 'USB y Thunderbolt';           Classes = 'USB', 'USBDevice' }
    @{ Order = 4;  Name = 'Video y Graficos';            Classes = 'Display' }
    @{ Order = 5;  Name = 'Audio';                       Classes = 'MEDIA', 'AudioProcessingObject', 'AudioEndpoint' }
    @{ Order = 6;  Name = 'Red (Ethernet y WiFi)';       Classes = 'Net', 'NetService', 'NetTrans', 'NetClient', 'Modem' }
    @{ Order = 7;  Name = 'Bluetooth';                   Classes = 'Bluetooth' }
    @{ Order = 8;  Name = 'Teclado, Mouse y Touchpad';   Classes = 'HIDClass', 'Keyboard', 'Mouse' }
    @{ Order = 9;  Name = 'Camaras y Escaneres';         Classes = 'Image', 'Camera' }
    @{ Order = 10; Name = 'Lectores de Tarjetas';        Classes = 'SDHost', 'SmartCardReader', 'SmartCard', 'MTD' }
    @{ Order = 11; Name = 'Biometricos y Seguridad';     Classes = 'Biometric', 'SecurityDevices', 'SmartCardFilter' }
    @{ Order = 12; Name = 'Sensores';                    Classes = 'Sensor' }
    @{ Order = 13; Name = 'Bateria y Energia';           Classes = 'Battery' }
    @{ Order = 14; Name = 'Puertos (COM y LPT)';         Classes = 'Ports', 'MultiPortSerial' }
    @{ Order = 15; Name = 'Impresoras';                  Classes = 'Printer', 'PrintQueue' }
    @{ Order = 16; Name = 'Monitores';                   Classes = 'Monitor' }
    @{ Order = 17; Name = $script:FirmwareCategory;      Classes = 'Firmware' }
    @{ Order = 18; Name = 'Componentes de Software';     Classes = 'SoftwareComponent', 'SoftwareDevice' }
    @{ Order = 19; Name = 'Extensiones de Drivers';      Classes = 'Extension' }
)
$script:OtherCategory = @{ Order = 99; Name = 'Otros'; Classes = @() }

function Get-DriverCategory([string]$ClassName) {
    foreach ($c in $script:Categories) {
        if ($c.Classes -contains $ClassName) { return $c }
    }
    $script:OtherCategory
}

#endregion

#region Utilidades

function Update-UI {
    if ($script:Gui) { [System.Windows.Forms.Application]::DoEvents() }
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Ok', 'Warn', 'Error')][string]$Level = 'Info'
    )
    $prefix = @{ Info = ''; Ok = '[OK] '; Warn = '[!] '; Error = '[ERROR] ' }[$Level]
    $line = '{0}  {1}{2}' -f (Get-Date -Format 'HH:mm:ss'), $prefix, $Message
    if ($script:LogFile) {
        try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 } catch { }
    }
    if ($script:Gui) {
        $script:Gui.Log.AppendText($line + [Environment]::NewLine)
        Update-UI
    } else {
        $color = @{ Info = 'Gray'; Ok = 'Green'; Warn = 'Yellow'; Error = 'Red' }[$Level]
        Write-Host $line -ForegroundColor $color
    }
}

function Set-LogFile([string]$Preferred) {
    $script:LogFile = $null
    foreach ($path in @($Preferred, (Join-Path $env:TEMP (Split-Path $Preferred -Leaf)))) {
        try {
            Add-Content -LiteralPath $path -Value ("===== {0} =====" -f (Get-Date)) -Encoding UTF8 -ErrorAction Stop
            $script:LogFile = $path
            return
        } catch { }
    }
}

function Set-Progress([int]$Value, [int]$Maximum, [string]$Status) {
    if ($script:Gui) {
        $bar = $script:Gui.Progress
        $bar.Value = 0
        $bar.Maximum = [Math]::Max(1, $Maximum)
        $bar.Value = [Math]::Min([Math]::Max(0, $Value), $bar.Maximum)
        if ($Status) { $script:Gui.Status.Text = $Status }
        Update-UI
    } elseif ($Status) {
        Write-Progress -Activity 'Respaldo de Drivers' -Status $Status -PercentComplete ([int](100 * $Value / [Math]::Max(1, $Maximum)))
    }
}

# Ejecuta un script en segundo plano sin congelar la ventana.
function Invoke-InBackground([scriptblock]$Script) {
    if (-not $script:Gui) { return & $Script }
    $ps = [PowerShell]::Create()
    try {
        [void]$ps.AddScript($Script.ToString())
        $handle = $ps.BeginInvoke()
        while (-not $handle.IsCompleted) {
            Update-UI
            Start-Sleep -Milliseconds 100
        }
        $ps.EndInvoke($handle)
    } finally {
        $ps.Dispose()
    }
}

function ConvertTo-ArgumentString([string[]]$Arguments) {
    $quoted = foreach ($a in $Arguments) {
        if ($a -match '[\s"]') { '"' + (($a -replace '"', '\"') -replace '(\\+)$', '$1$1') + '"' } else { $a }
    }
    $quoted -join ' '
}

# Ejecuta un programa externo (pnputil) capturando su salida sin congelar la ventana.
function Invoke-External([string]$FilePath, [string[]]$Arguments) {
    $oem = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = ConvertTo-ArgumentString $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $oem
    $psi.StandardErrorEncoding = $oem

    $proc = [Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEndAsync()
    $stderr = $proc.StandardError.ReadToEndAsync()
    while (-not $proc.WaitForExit(100)) { Update-UI }
    $proc.WaitForExit()
    [pscustomobject]@{
        ExitCode = $proc.ExitCode
        Output   = ($stdout.Result + $stderr.Result).Trim()
    }
}

$script:PnpUtil = Join-Path $env:SystemRoot 'System32\pnputil.exe'
$sysnativePnpUtil = Join-Path $env:SystemRoot 'Sysnative\pnputil.exe'
if (-not [Environment]::Is64BitProcess -and (Test-Path $sysnativePnpUtil)) { $script:PnpUtil = $sysnativePnpUtil }

function Get-SafeName([string]$Name, [int]$MaxLength = 70) {
    $n = (($Name -replace '[\\/:*?"<>|]', '_') -replace '\s+', ' ').Trim().TrimEnd('.')
    if ($n.Length -gt $MaxLength) { $n = $n.Substring(0, $MaxLength).Trim() }
    if (-not $n) { $n = 'driver' }
    $n
}

function Format-DriverDate($Value) {
    if ($Value -is [datetime]) { return $Value.ToString('yyyy-MM-dd') }
    $dt = [datetime]::MinValue
    if ([datetime]::TryParse("$Value", [ref]$dt)) { return $dt.ToString('yyyy-MM-dd') }
    "$Value"
}

function Get-LastLines([string]$Text, [int]$Count) {
    $lines = @($Text -split "`r?`n" | Where-Object { $_.Trim() })
    ($lines | Select-Object -Last $Count | ForEach-Object { '        ' + $_.Trim() }) -join [Environment]::NewLine
}

function Test-OnSystemDrive([string]$Path) {
    try {
        [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path)).TrimEnd('\') -ieq $env:SystemDrive
    } catch { $false }
}

#endregion

#region Información del equipo

function Get-ComputerSummary {
    $cs   = Get-CimInstance Win32_ComputerSystem
    $bios = Get-CimInstance Win32_BIOS
    $os   = Get-CimInstance Win32_OperatingSystem
    $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    [ordered]@{
        ComputerName = $env:COMPUTERNAME
        Manufacturer = "$($cs.Manufacturer)".Trim()
        Model        = "$($cs.Model)".Trim()
        SerialNumber = "$($bios.SerialNumber)".Trim()
        BiosVersion  = "$($bios.SMBIOSBIOSVersion)".Trim()
        OS           = "$($os.Caption)".Trim()
        OSVersion    = "$($os.Version)"
        Architecture = $arch
    }
}

function Get-DefaultBackupName {
    $pc = Get-ComputerSummary
    Get-SafeName ('Drivers_{0}_{1}_{2}' -f $pc.Manufacturer, $pc.Model, (Get-Date -Format 'yyyy-MM-dd')) 90
}

function Get-DefaultBackupParent {
    $dir = $script:ScriptDir
    # Si la app se ejecuta desde dentro de un respaldo, no crear el nuevo respaldo dentro de él
    if (Test-Path -LiteralPath (Join-Path $dir $script:ManifestName)) { $dir = Split-Path -Parent $dir }
    if ($dir -and -not (Test-OnSystemDrive $dir)) { return $dir }

    # Preferir una USB (tipo 2) y luego otro disco local (tipo 3) distinto de C:
    $other = Get-CimInstance Win32_LogicalDisk |
        Where-Object { $_.DriveType -in 2, 3 -and $_.DeviceID -ne $env:SystemDrive -and $_.FreeSpace -gt 2GB } |
        Sort-Object DriveType | Select-Object -First 1
    if ($other) { return $other.DeviceID + '\' }
    [Environment]::GetFolderPath('Desktop')
}

function Get-DevicesWithoutDriver {
    # Código 22 = deshabilitado por el usuario: no se considera un problema
    Get-CimInstance Win32_PnPEntity |
        Where-Object { $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -ne 22 } |
        ForEach-Object {
            [pscustomobject]@{
                Name       = if ($_.Name) { $_.Name } else { 'Dispositivo desconocido' }
                Code       = $_.ConfigManagerErrorCode
                HardwareId = @($_.HardwareID)[0]
            }
        }
}

#endregion

#region Respaldo

function Get-DriverLabel($Driver) {
    $text = '{0}  |  {1}  |  v{2}  |  {3}' -f $Driver.Provider, $Driver.InfName, $Driver.Version, $Driver.Date
    if ($Driver.Devices.Count) { $text += '  ->  ' + ($Driver.Devices -join ', ') }
    $text
}

function Get-InstalledDrivers {
    Write-Log 'Leyendo los drivers instalados (puede tardar hasta un minuto)...'
    $raw = @(Invoke-InBackground { Get-WindowsDriver -Online -ErrorAction Stop })

    $deviceMap = @{}
    try {
        $signed = @(Invoke-InBackground { Get-CimInstance Win32_PnPSignedDriver | Select-Object InfName, DeviceName })
        foreach ($dev in $signed) {
            if (-not $dev.InfName -or -not $dev.DeviceName) { continue }
            $key = $dev.InfName.ToLowerInvariant()
            if (-not $deviceMap.ContainsKey($key)) { $deviceMap[$key] = New-Object Collections.Generic.List[string] }
            if (-not $deviceMap[$key].Contains($dev.DeviceName)) { $deviceMap[$key].Add($dev.DeviceName) }
        }
    } catch {
        Write-Log "No se pudo leer la lista de dispositivos: $($_.Exception.Message)" Warn
    }

    $drivers = foreach ($d in $raw) {
        $cat = Get-DriverCategory $d.ClassName
        $key = "$($d.Driver)".ToLowerInvariant()
        [pscustomobject]@{
            PublishedName = $d.Driver
            InfName       = [IO.Path]::GetFileName($d.OriginalFileName)
            StorePath     = [IO.Path]::GetDirectoryName($d.OriginalFileName)
            ClassName     = $d.ClassName
            Provider      = if ("$($d.ProviderName)".Trim()) { "$($d.ProviderName)".Trim() } else { 'Desconocido' }
            Version       = "$($d.Version)"
            Date          = Format-DriverDate $d.Date
            Category      = $cat.Name
            CategoryOrder = $cat.Order
            Devices       = [string[]]@(if ($deviceMap.ContainsKey($key)) { $deviceMap[$key] })
            RelativePath  = $null
        }
    }
    $drivers = @($drivers | Sort-Object CategoryOrder, Provider, InfName)
    Write-Log "Se encontraron $($drivers.Count) drivers de terceros." Ok
    $drivers
}

function Export-SingleDriver($Driver, [string]$Target) {
    New-Item -ItemType Directory -Path $Target -Force | Out-Null
    $r = Invoke-External $script:PnpUtil @('/export-driver', $Driver.PublishedName, $Target)
    if ($r.ExitCode -eq 0 -and (Get-ChildItem -LiteralPath $Target -Filter *.inf -File -Recurse -ErrorAction SilentlyContinue)) { return }

    # Alternativa: copiar directamente la carpeta del almacén de drivers de Windows
    if (-not $Driver.StorePath -or -not (Test-Path -LiteralPath $Driver.StorePath)) {
        throw "pnputil terminó con código $($r.ExitCode) y no se encontró la carpeta original del driver."
    }
    Copy-Item -Path (Join-Path $Driver.StorePath '*') -Destination $Target -Recurse -Force
}

function Copy-AppToBackup([string]$Destination) {
    $files = if ($script:IsExe) { @($script:ScriptPath) } else { @($script:ScriptPath, (Join-Path $script:ScriptDir $script:LauncherName)) }
    foreach ($f in $files) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        $target = Join-Path $Destination (Split-Path $f -Leaf)
        if ([IO.Path]::GetFullPath($f) -ieq [IO.Path]::GetFullPath($target)) { continue }
        Copy-Item -LiteralPath $f -Destination $target -Force
    }
}

function Write-BackupReadme([string]$Destination, $Computer, [object[]]$Drivers) {
    $launcher = if ($script:IsExe) { Split-Path $script:ScriptPath -Leaf } else { $script:LauncherName }
    $lines = @(
        'RESPALDO DE DRIVERS'
        '==================='
        ''
        "Equipo:      $($Computer.Manufacturer) $($Computer.Model)"
        "N. de serie: $($Computer.SerialNumber)"
        "Sistema:     $($Computer.OS) ($($Computer.OSVersion), $($Computer.Architecture))"
        "Creado:      $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
        "Drivers:     $($Drivers.Count)"
        ''
        'CÓMO INSTALAR LOS DRIVERS DESPUÉS DE FORMATEAR'
        '----------------------------------------------'
        '1. Guarda esta carpeta completa en una USB o en un disco que no vayas a formatear.'
        '2. Después de instalar Windows, conecta la USB y abre esta carpeta.'
        "3. Haz doble clic en `"$launcher`" y acepta el permiso de administrador."
        '4. La aplicación abre la pestaña "Instalar drivers" con este respaldo ya cargado.'
        '5. Presiona "Instalar seleccionados" y reinicia el equipo al terminar.'
        ''
        'CONTENIDO POR CATEGORÍA'
        '-----------------------'
    )
    $lines += $Drivers | Group-Object Category | Sort-Object { $_.Group[0].CategoryOrder } |
        ForEach-Object { '{0,-32} {1,4} drivers' -f $_.Name, $_.Count }
    $lines += @('', 'El detalle de cada driver está en inventario.csv (se abre con Excel).')
    Set-Content -LiteralPath (Join-Path $Destination 'LEEME.txt') -Value $lines -Encoding UTF8
}

function Invoke-DriverBackup {
    param(
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][object[]]$Drivers
    )
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $Destination = (Resolve-Path -LiteralPath $Destination).ProviderPath
    Set-LogFile (Join-Path $Destination 'registro_respaldo.txt')
    Write-Log "Respaldando $($Drivers.Count) drivers en: $Destination"

    $ok = 0; $failed = 0; $i = 0
    $usedPaths = @{}
    foreach ($drv in $Drivers) {
        $i++
        Set-Progress ($i - 1) $Drivers.Count "Respaldando $i de $($Drivers.Count): $($drv.InfName)"
        $catFolder = '{0:D2} - {1}' -f $drv.CategoryOrder, $drv.Category
        $infBase = [IO.Path]::GetFileNameWithoutExtension($drv.InfName)
        $name = Get-SafeName ('{0} - {1} - {2}' -f $drv.Provider, $infBase, $drv.Version)
        $rel = Join-Path $catFolder $name
        if ($usedPaths.ContainsKey($rel)) {
            $rel = Join-Path $catFolder (Get-SafeName ('{0} ({1})' -f $name, [IO.Path]::GetFileNameWithoutExtension($drv.PublishedName)) 80)
        }
        $usedPaths[$rel] = $true

        try {
            Export-SingleDriver -Driver $drv -Target (Join-Path $Destination $rel)
            $drv.RelativePath = $rel
            $ok++
            Write-Log $rel Ok
        } catch {
            $drv.RelativePath = $null
            $failed++
            Write-Log "$($drv.InfName): $($_.Exception.Message)" Error
        }
    }

    Set-Progress $Drivers.Count $Drivers.Count 'Guardando inventario...'
    $saved = @($Drivers | Where-Object { $_.RelativePath })
    $computer = Get-ComputerSummary

    $manifest = [ordered]@{
        App        = 'RespaldoDrivers'
        AppVersion = $script:AppVersion
        Created    = (Get-Date).ToString('s')
        Computer   = $computer
        Drivers    = @($saved | ForEach-Object {
            [ordered]@{
                Category      = $_.Category
                CategoryOrder = $_.CategoryOrder
                ClassName     = $_.ClassName
                Provider      = $_.Provider
                InfName       = $_.InfName
                PublishedName = $_.PublishedName
                Version       = $_.Version
                Date          = $_.Date
                Devices       = @($_.Devices)
                RelativePath  = $_.RelativePath
            }
        })
    }
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Destination $script:ManifestName) -Encoding UTF8

    $saved | Select-Object `
        @{ n = 'Categoria';    e = { $_.Category } },
        @{ n = 'Fabricante';   e = { $_.Provider } },
        @{ n = 'Archivo INF';  e = { $_.InfName } },
        @{ n = 'Version';      e = { $_.Version } },
        @{ n = 'Fecha';        e = { $_.Date } },
        @{ n = 'Dispositivos'; e = { $_.Devices -join ' / ' } },
        @{ n = 'Carpeta';      e = { $_.RelativePath } } |
        Export-Csv -LiteralPath (Join-Path $Destination 'inventario.csv') -NoTypeInformation -Encoding UTF8 -UseCulture

    Write-BackupReadme -Destination $Destination -Computer $computer -Drivers $saved
    try { Copy-AppToBackup $Destination } catch { Write-Log "No se pudo copiar la aplicación al respaldo: $($_.Exception.Message)" Warn }

    Write-Log ("Respaldo terminado: {0} drivers guardados, {1} con error." -f $ok, $failed) $(if ($failed) { 'Warn' } else { 'Ok' })
    Set-Progress $Drivers.Count $Drivers.Count 'Respaldo terminado.'
    [pscustomobject]@{ Ok = $ok; Failed = $failed; Path = $Destination }
}

#endregion

#region Restauración

function Read-DriverBackup([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "La carpeta no existe: $Path" }
    $Path = (Resolve-Path -LiteralPath $Path).ProviderPath.TrimEnd('\')
    $manifestPath = Join-Path $Path $script:ManifestName
    $drivers = New-Object Collections.Generic.List[object]
    $computer = $null
    $created = $null

    if (Test-Path -LiteralPath $manifestPath) {
        $m = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $computer = $m.Computer
        $created = $m.Created
        foreach ($d in @($m.Drivers)) {
            $full = Join-Path $Path $d.RelativePath
            if (-not (Test-Path -LiteralPath $full)) {
                Write-Log "Falta la carpeta del driver: $($d.RelativePath)" Warn
                continue
            }
            $drivers.Add([pscustomobject]@{
                Category      = $d.Category
                CategoryOrder = [int]$d.CategoryOrder
                Provider      = $d.Provider
                InfName       = $d.InfName
                Version       = $d.Version
                Date          = $d.Date
                Devices       = [string[]]@($d.Devices | Where-Object { $_ })
                FullPath      = $full
                Recurse       = $true
            })
        }
    } else {
        # Carpeta sin respaldo.json (por ejemplo, drivers descargados del fabricante):
        # cada carpeta que contenga archivos .inf se trata como un driver.
        Write-Log 'No se encontró respaldo.json: se buscarán archivos .inf dentro de la carpeta.' Warn
        $dirs = Get-ChildItem -LiteralPath $Path -Filter *.inf -File -Recurse -ErrorAction SilentlyContinue |
            ForEach-Object { $_.DirectoryName } | Sort-Object -Unique
        foreach ($dir in $dirs) {
            $rel = $dir.Substring($Path.Length).TrimStart('\', '/')
            $parts = @($rel -split '[\\/]')
            $order = 99; $category = 'Otros'
            if ($parts.Count -gt 1) {
                $top = $parts[0]
                if ($top -match '^(\d{1,2})\s*-\s*(.+)$') { $order = [int]$Matches[1]; $category = $Matches[2] }
                else { $order = 50; $category = $top }
            }
            $inf = Get-ChildItem -LiteralPath $dir -Filter *.inf -File | Select-Object -First 1
            $drivers.Add([pscustomobject]@{
                Category      = $category
                CategoryOrder = $order
                Provider      = if ($rel) { Split-Path $dir -Leaf } else { Split-Path $Path -Leaf }
                InfName       = $inf.Name
                Version       = ''
                Date          = $inf.LastWriteTime.ToString('yyyy-MM-dd')
                Devices       = [string[]]@()
                FullPath      = $dir
                Recurse       = $false
            })
        }
    }

    if (-not $drivers.Count) { throw "No se encontraron drivers en: $Path" }
    [pscustomobject]@{
        Path     = $Path
        Computer = $computer
        Created  = $created
        Drivers  = $drivers.ToArray()
    }
}

function Invoke-DriverRestore {
    param(
        [Parameter(Mandatory)][object[]]$Drivers,
        [Parameter(Mandatory)][string]$Root
    )
    Set-LogFile (Join-Path $Root 'registro_instalacion.txt')
    $Drivers = @($Drivers | Sort-Object CategoryOrder, Category, Provider, InfName)
    $result = [pscustomobject]@{ Installed = 0; Unchanged = 0; Failed = 0; Reboot = $false; MissingBefore = 0; MissingAfter = 0 }
    $result.MissingBefore = @(Get-DevicesWithoutDriver).Count
    Write-Log "Instalando $($Drivers.Count) drivers. Dispositivos sin driver antes de empezar: $($result.MissingBefore)"

    $i = 0
    foreach ($d in $Drivers) {
        $i++
        $label = '{0} \ {1}' -f $d.Category, (Split-Path $d.FullPath -Leaf)
        Set-Progress ($i - 1) $Drivers.Count "Instalando $i de $($Drivers.Count): $label"
        $pnpArgs = @('/add-driver', (Join-Path $d.FullPath '*.inf'))
        if ($d.Recurse) { $pnpArgs += '/subdirs' }
        $pnpArgs += '/install'

        $r = Invoke-External $script:PnpUtil $pnpArgs
        switch ($r.ExitCode) {
            0       { $result.Installed++; Write-Log "Instalado: $label" Ok }
            3010    { $result.Installed++; $result.Reboot = $true; Write-Log "Instalado (requiere reiniciar): $label" Ok }
            259     { $result.Unchanged++; Write-Log "Sin cambios (ya estaba al día o el dispositivo no está conectado): $label" }
            default { $result.Failed++; Write-Log ("Error {0} en {1}{2}{3}" -f $r.ExitCode, $label, [Environment]::NewLine, (Get-LastLines $r.Output 4)) Error }
        }
    }

    Set-Progress $Drivers.Count $Drivers.Count 'Buscando cambios de hardware...'
    try { [void](Invoke-External $script:PnpUtil @('/scan-devices')) } catch { }
    $result.MissingAfter = @(Get-DevicesWithoutDriver).Count

    Write-Log ('Instalación terminada: {0} instalados, {1} sin cambios, {2} con error. Dispositivos sin driver: {3} -> {4}' -f
        $result.Installed, $result.Unchanged, $result.Failed, $result.MissingBefore, $result.MissingAfter) $(if ($result.Failed) { 'Warn' } else { 'Ok' })
    if ($result.Reboot) { Write-Log 'Es necesario reiniciar el equipo para terminar la instalación.' Warn }
    Set-Progress $Drivers.Count $Drivers.Count 'Instalación terminada.'
    $result
}

function Find-BackupNearApp {
    if (Test-Path -LiteralPath (Join-Path $script:ScriptDir $script:ManifestName)) {
        return [pscustomobject]@{ Path = $script:ScriptDir; IsSelf = $true }
    }
    $found = Get-ChildItem -LiteralPath $script:ScriptDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName $script:ManifestName) } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($found) { return [pscustomobject]@{ Path = $found.FullName; IsSelf = $false } }
    $null
}

#endregion

#region Interfaz gráfica

function P([int]$X, [int]$Y) { New-Object System.Drawing.Point($X, $Y) }
function S([int]$W, [int]$H) { New-Object System.Drawing.Size($W, $H) }

function New-Ctl([string]$Type, [Collections.IDictionary]$Props) {
    $c = New-Object "System.Windows.Forms.$Type"
    foreach ($k in $Props.Keys) { $c.$k = $Props[$k] }
    $c
}

function Show-Message([string]$Text, [string]$Icon = 'Information', [string]$Buttons = 'OK') {
    [System.Windows.Forms.MessageBox]::Show($script:Gui.Form, $Text, 'Respaldo de Drivers',
        [System.Windows.Forms.MessageBoxButtons]$Buttons, [System.Windows.Forms.MessageBoxIcon]$Icon)
}

function Set-Busy([bool]$Busy) {
    $script:Gui.IsBusy = $Busy
    $script:Gui.Tabs.Enabled = -not $Busy
    $script:Gui.Form.UseWaitCursor = $Busy
    if (-not $Busy) { $script:Gui.Progress.Value = 0 }
    Update-UI
}

function Invoke-GuiAction([scriptblock]$Action) {
    Set-Busy $true
    try {
        & $Action
    } catch {
        Write-Log $_.Exception.Message Error
        [void](Show-Message $_.Exception.Message 'Error')
    } finally {
        Set-Busy $false
    }
}

function Set-DriverTree($Tree, [object[]]$Drivers, [string[]]$UncheckedCategories = @()) {
    $Tree.BeginUpdate()
    $Tree.Nodes.Clear()
    $groups = $Drivers | Group-Object { '{0:D2} - {1}' -f $_.CategoryOrder, $_.Category } | Sort-Object Name
    foreach ($g in $groups) {
        $checked = -not ($UncheckedCategories -contains $g.Group[0].Category)
        $catNode = New-Object System.Windows.Forms.TreeNode("$($g.Name)   ($($g.Count))")
        $catNode.Checked = $checked
        foreach ($d in $g.Group) {
            $node = New-Object System.Windows.Forms.TreeNode((Get-DriverLabel $d))
            $node.Tag = $d
            $node.Checked = $checked
            if ($d.Devices.Count) { $node.ToolTipText = $d.Devices -join [Environment]::NewLine }
            [void]$catNode.Nodes.Add($node)
        }
        [void]$Tree.Nodes.Add($catNode)
    }
    $Tree.EndUpdate()
}

function Get-CheckedDrivers($Tree) {
    foreach ($cat in $Tree.Nodes) {
        foreach ($node in $cat.Nodes) {
            if ($node.Checked -and $node.Tag) { $node.Tag }
        }
    }
}

function Set-TreeChecked($Tree, [bool]$Checked) {
    foreach ($cat in $Tree.Nodes) {
        $cat.Checked = $Checked
        foreach ($node in $cat.Nodes) { $node.Checked = $Checked }
    }
}

function New-DriverTree {
    $tree = New-Ctl TreeView ([ordered]@{
        Dock = 'Fill'; CheckBoxes = $true; ShowNodeToolTips = $true; HideSelection = $false
        Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    })
    # Marcar una categoría marca todos sus drivers, y viceversa
    $tree.Add_AfterCheck({
        param($s, $e)
        if ($e.Action -eq [System.Windows.Forms.TreeViewAction]::Unknown) { return }
        $node = $e.Node
        foreach ($child in $node.Nodes) { $child.Checked = $node.Checked }
        if ($node.Parent) {
            $all = $true
            foreach ($sibling in $node.Parent.Nodes) { if (-not $sibling.Checked) { $all = $false; break } }
            $node.Parent.Checked = $all
        }
    })
    $tree
}

function Import-BackupIntoGui([string]$Path) {
    $g = $script:Gui
    $g.TxtSrc.Text = $Path
    $bk = Read-DriverBackup $Path
    $g.Backup = $bk
    Set-DriverTree $g.RsTree $bk.Drivers -UncheckedCategories @($script:FirmwareCategory)

    $info = "$($bk.Drivers.Count) drivers en $(@($bk.Drivers | Group-Object Category).Count) categorías."
    $g.LblSrcInfo.ForeColor = [System.Drawing.Color]::DimGray
    if ($bk.Computer) {
        $info = "Respaldo de: $($bk.Computer.Manufacturer) $($bk.Computer.Model)  (S/N $($bk.Computer.SerialNumber))  -  $($bk.Computer.OS)  -  creado $(Format-DriverDate $bk.Created)  -  $info"
        $current = Get-ComputerSummary
        if ($bk.Computer.Architecture -and $bk.Computer.Architecture -ne $current.Architecture) {
            $info += "`r`n¡Atención! El respaldo es de arquitectura $($bk.Computer.Architecture) y este Windows es $($current.Architecture): los drivers no serán compatibles."
            $g.LblSrcInfo.ForeColor = [System.Drawing.Color]::Firebrick
        } elseif ($bk.Computer.Model -and $bk.Computer.Model -ne $current.Model) {
            $info += "`r`nAtención: el respaldo es de otro modelo ($($bk.Computer.Model)). Solo se instalarán en dispositivos compatibles."
            $g.LblSrcInfo.ForeColor = [System.Drawing.Color]::DarkOrange
        }
    }
    if ($bk.Drivers | Where-Object { $_.Category -eq $script:FirmwareCategory }) {
        $info += "  La categoría '$($script:FirmwareCategory)' quedó desmarcada por seguridad."
    }
    $g.LblSrcInfo.Text = $info
    Write-Log "Respaldo cargado: $Path ($($bk.Drivers.Count) drivers)" Ok
}

function Show-MainWindow {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $g = @{ IsBusy = $false; Backup = $null }
    $script:Gui = $g
    $pc = Get-ComputerSummary

    $form = New-Ctl Form ([ordered]@{
        Text = "Respaldo de Drivers $script:AppVersion"; StartPosition = 'CenterScreen'
        Size = (S 1000 760); MinimumSize = (S 840 620); Font = New-Object System.Drawing.Font('Segoe UI', 9)
    })
    $g.Form = $form

    # --- Encabezado ---
    $header = New-Ctl Panel ([ordered]@{ Dock = 'Top'; Height = 62; BackColor = [System.Drawing.Color]::FromArgb(0, 84, 153) })
    $header.Controls.Add((New-Ctl Label ([ordered]@{
        Text = 'Respaldo de Drivers'; Location = (P 16 6); AutoSize = $true; ForeColor = [System.Drawing.Color]::White
        Font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
    })))
    $header.Controls.Add((New-Ctl Label ([ordered]@{
        Text = "$($pc.Manufacturer) $($pc.Model)   |   S/N $($pc.SerialNumber)   |   $($pc.OS) ($($pc.Architecture))"
        Location = (P 18 38); AutoSize = $true; ForeColor = [System.Drawing.Color]::FromArgb(210, 228, 245)
    })))

    # --- Registro y progreso (parte inferior) ---
    $bottom = New-Ctl Panel ([ordered]@{ Dock = 'Bottom'; Height = 200; Padding = New-Object System.Windows.Forms.Padding(10, 4, 10, 10) })
    $g.Log = New-Ctl TextBox ([ordered]@{
        Dock = 'Fill'; Multiline = $true; ReadOnly = $true; ScrollBars = 'Vertical'; WordWrap = $false
        BackColor = [System.Drawing.Color]::White; Font = New-Object System.Drawing.Font('Consolas', 9)
    })
    $g.Progress = New-Ctl ProgressBar ([ordered]@{ Dock = 'Top'; Height = 18 })
    $g.Status = New-Ctl Label ([ordered]@{ Dock = 'Top'; Height = 24; Text = 'Listo.'; TextAlign = 'MiddleLeft' })
    $bottom.Controls.Add($g.Log)
    $bottom.Controls.Add($g.Progress)
    $bottom.Controls.Add($g.Status)

    # Tamaños iniciales aproximados para que los controles anclados se calculen bien
    $tabs = New-Ctl TabControl ([ordered]@{ Size = (S 984 460); Dock = 'Fill'; Padding = (P 14 6) })
    $g.Tabs = $tabs

    # --- Pestaña 1: Respaldar ---
    $tabBackup = New-Ctl TabPage ([ordered]@{ Size = (S 976 430); Text = '1. Respaldar drivers (antes de formatear)'; Padding = New-Object System.Windows.Forms.Padding(8); UseVisualStyleBackColor = $true })

    $bkTop = New-Ctl Panel ([ordered]@{ Size = (S 900 44); Dock = 'Top' })
    $btnScan = New-Ctl Button ([ordered]@{ Text = 'Analizar drivers del equipo'; Location = (P 0 4); Size = (S 230 34) })
    $g.LblScan = New-Ctl Label ([ordered]@{
        Text = 'Presiona "Analizar" para ver los drivers instalados en este equipo.'
        Location = (P 244 12); Size = (S 440 22); Anchor = 'Top, Left, Right'; AutoEllipsis = $true
    })
    $btnBkAll  = New-Ctl Button ([ordered]@{ Text = 'Marcar todo'; Location = (P 700 7); Size = (S 95 28); Anchor = 'Top, Right' })
    $btnBkNone = New-Ctl Button ([ordered]@{ Text = 'Desmarcar';   Location = (P 805 7); Size = (S 95 28); Anchor = 'Top, Right' })
    $bkTop.Controls.AddRange(@($btnScan, $g.LblScan, $btnBkAll, $btnBkNone))

    $g.BkTree = New-DriverTree

    $bkBottom = New-Ctl Panel ([ordered]@{ Size = (S 900 74); Dock = 'Bottom' })
    $lblDest = New-Ctl Label ([ordered]@{
        Text = 'Carpeta donde se guardará el respaldo (usa una USB o un disco que no vayas a formatear):'
        Location = (P 0 8); AutoSize = $true
    })
    $g.TxtDest = New-Ctl TextBox ([ordered]@{ Location = (P 0 32); Size = (S 560 25); Anchor = 'Top, Left, Right' })
    $btnDest = New-Ctl Button ([ordered]@{ Text = 'Examinar...'; Location = (P 566 30); Size = (S 100 28); Anchor = 'Top, Right' })
    $btnBackup = New-Ctl Button ([ordered]@{
        Text = 'Respaldar seleccionados'; Location = (P 676 24); Size = (S 224 40); Anchor = 'Top, Right'
        BackColor = [System.Drawing.Color]::FromArgb(16, 124, 16); ForeColor = [System.Drawing.Color]::White; FlatStyle = 'Flat'
        Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    })
    $bkBottom.Controls.AddRange(@($lblDest, $g.TxtDest, $btnDest, $btnBackup))

    $tabBackup.Controls.Add($g.BkTree)
    $tabBackup.Controls.Add($bkBottom)
    $tabBackup.Controls.Add($bkTop)

    # --- Pestaña 2: Instalar ---
    $tabRestore = New-Ctl TabPage ([ordered]@{ Size = (S 976 430); Text = '2. Instalar drivers (después de formatear)'; Padding = New-Object System.Windows.Forms.Padding(8); UseVisualStyleBackColor = $true })

    $rsTop = New-Ctl Panel ([ordered]@{ Size = (S 900 98); Dock = 'Top' })
    $lblSrc = New-Ctl Label ([ordered]@{ Text = 'Carpeta del respaldo (la que contiene respaldo.json):'; Location = (P 0 6); AutoSize = $true })
    $g.TxtSrc = New-Ctl TextBox ([ordered]@{ Location = (P 0 30); Size = (S 560 25); Anchor = 'Top, Left, Right' })
    $btnSrc = New-Ctl Button ([ordered]@{ Text = 'Examinar...'; Location = (P 566 28); Size = (S 100 28); Anchor = 'Top, Right' })
    $btnLoad = New-Ctl Button ([ordered]@{ Text = 'Cargar respaldo'; Location = (P 676 28); Size = (S 224 28); Anchor = 'Top, Right' })
    $g.LblSrcInfo = New-Ctl Label ([ordered]@{
        Text = 'Elige la carpeta del respaldo y presiona "Cargar respaldo".'
        Location = (P 0 62); Size = (S 900 34); Anchor = 'Top, Left, Right'; ForeColor = [System.Drawing.Color]::DimGray
    })
    $rsTop.Controls.AddRange(@($lblSrc, $g.TxtSrc, $btnSrc, $btnLoad, $g.LblSrcInfo))

    $g.RsTree = New-DriverTree

    $rsBottom = New-Ctl Panel ([ordered]@{ Size = (S 900 56); Dock = 'Bottom' })
    $btnMissing = New-Ctl Button ([ordered]@{ Text = 'Ver dispositivos sin driver'; Location = (P 0 10); Size = (S 220 40) })
    $btnRsAll   = New-Ctl Button ([ordered]@{ Text = 'Marcar todo'; Location = (P 232 16); Size = (S 95 28) })
    $btnRsNone  = New-Ctl Button ([ordered]@{ Text = 'Desmarcar';   Location = (P 333 16); Size = (S 95 28) })
    $btnInstall = New-Ctl Button ([ordered]@{
        Text = 'Instalar seleccionados'; Location = (P 676 10); Size = (S 224 40); Anchor = 'Top, Right'
        BackColor = [System.Drawing.Color]::FromArgb(0, 103, 192); ForeColor = [System.Drawing.Color]::White; FlatStyle = 'Flat'
        Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    })
    $rsBottom.Controls.AddRange(@($btnMissing, $btnRsAll, $btnRsNone, $btnInstall))

    $tabRestore.Controls.Add($g.RsTree)
    $tabRestore.Controls.Add($rsBottom)
    $tabRestore.Controls.Add($rsTop)

    $tabs.TabPages.AddRange(@($tabBackup, $tabRestore))
    $g.TabRestore = $tabRestore

    # El control "Fill" va primero para que los paneles Top/Bottom se acomoden antes
    $form.Controls.Add($tabs)
    $form.Controls.Add($bottom)
    $form.Controls.Add($header)

    # --- Eventos ---
    $btnScan.Add_Click({
        Invoke-GuiAction {
            $g = $script:Gui
            $g.Status.Text = 'Analizando drivers...'
            $drivers = @(Get-InstalledDrivers)
            Set-DriverTree $g.BkTree $drivers
            $cats = @($drivers | Group-Object Category).Count
            $g.LblScan.Text = "Se encontraron $($drivers.Count) drivers en $cats categorías. Desmarca los que no quieras respaldar."
            $g.Status.Text = 'Análisis terminado.'
        }
    })
    $btnBkAll.Add_Click({ Set-TreeChecked $script:Gui.BkTree $true })
    $btnBkNone.Add_Click({ Set-TreeChecked $script:Gui.BkTree $false })
    $btnRsAll.Add_Click({ Set-TreeChecked $script:Gui.RsTree $true })
    $btnRsNone.Add_Click({ Set-TreeChecked $script:Gui.RsTree $false })

    $btnDest.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Elige la USB o carpeta donde se creará la carpeta del respaldo'
        $dlg.ShowNewFolderButton = $true
        if ($dlg.ShowDialog($script:Gui.Form) -eq 'OK') {
            $script:Gui.TxtDest.Text = Join-Path $dlg.SelectedPath (Get-DefaultBackupName)
        }
    })

    $btnBackup.Add_Click({
        $g = $script:Gui
        $selected = @(Get-CheckedDrivers $g.BkTree)
        if (-not $selected.Count) {
            [void](Show-Message 'Primero presiona "Analizar drivers del equipo" y marca los drivers que quieres respaldar.' 'Warning')
            return
        }
        $dest = $g.TxtDest.Text.Trim()
        if (-not $dest) { [void](Show-Message 'Indica la carpeta donde se guardará el respaldo.' 'Warning'); return }
        if (Test-OnSystemDrive $dest) {
            $answer = Show-Message ("La carpeta está en el disco $env:SystemDrive, que normalmente se borra al formatear.`n`n" +
                "Cuando termine el respaldo, copia la carpeta a una USB o a otro disco.`n`n¿Deseas continuar?") 'Warning' 'YesNo'
            if ($answer -ne 'Yes') { return }
        }
        Invoke-GuiAction {
            $res = Invoke-DriverBackup -Destination $dest -Drivers $selected
            $launcher = if ($script:IsExe) { Split-Path $script:ScriptPath -Leaf } else { $script:LauncherName }
            $answer = Show-Message ("Respaldo terminado.`n`nDrivers guardados: $($res.Ok)`nCon error: $($res.Failed)`n`nCarpeta:`n$($res.Path)`n`n" +
                "Después de formatear abre esa carpeta y ejecuta `"$launcher`" para instalar los drivers.`n`n¿Abrir la carpeta ahora?") 'Information' 'YesNo'
            if ($answer -eq 'Yes') { Start-Process explorer.exe -ArgumentList "`"$($res.Path)`"" }
        }
    })

    $btnSrc.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Elige la carpeta del respaldo de drivers (la que contiene respaldo.json)'
        $dlg.ShowNewFolderButton = $false
        if ($dlg.ShowDialog($script:Gui.Form) -eq 'OK') {
            $path = $dlg.SelectedPath
            Invoke-GuiAction { Import-BackupIntoGui $path }
        }
    })

    $btnLoad.Add_Click({
        $path = $script:Gui.TxtSrc.Text.Trim()
        if (-not $path) { [void](Show-Message 'Indica la carpeta del respaldo.' 'Warning'); return }
        Invoke-GuiAction { Import-BackupIntoGui $path }
    })

    $btnMissing.Add_Click({
        Invoke-GuiAction {
            $devices = @(Get-DevicesWithoutDriver)
            if (-not $devices.Count) {
                Write-Log 'Todos los dispositivos tienen su driver instalado.' Ok
                [void](Show-Message 'Todos los dispositivos tienen su driver instalado.')
                return
            }
            Write-Log "Dispositivos sin driver o con problemas: $($devices.Count)" Warn
            foreach ($d in $devices) { Write-Log ("   - {0}  [código {1}]  {2}" -f $d.Name, $d.Code, $d.HardwareId) Warn }
            [void](Show-Message ("Hay $($devices.Count) dispositivos sin driver o con problemas.`n`n" +
                (($devices | Select-Object -First 15 | ForEach-Object { '- ' + $_.Name }) -join "`n") +
                "`n`nEl detalle (con el ID de hardware) está en el registro de abajo.") 'Warning')
        }
    })

    $btnInstall.Add_Click({
        $g = $script:Gui
        if (-not $g.Backup) { [void](Show-Message 'Primero carga la carpeta del respaldo.' 'Warning'); return }
        $selected = @(Get-CheckedDrivers $g.RsTree)
        if (-not $selected.Count) { [void](Show-Message 'Marca los drivers que quieres instalar.' 'Warning'); return }
        $answer = Show-Message ("Se instalarán $($selected.Count) drivers.`n`n" +
            "Durante la instalación la pantalla puede parpadear o quedarse en negro unos segundos (driver de video) " +
            "y la red puede desconectarse un momento.`n`n¿Continuar?") 'Question' 'YesNo'
        if ($answer -ne 'Yes') { return }
        Invoke-GuiAction {
            $res = Invoke-DriverRestore -Drivers $selected -Root $script:Gui.Backup.Path
            $text = "Instalación terminada.`n`nInstalados: $($res.Installed)`nSin cambios: $($res.Unchanged)`nCon error: $($res.Failed)`n`n" +
                "Dispositivos sin driver: antes $($res.MissingBefore), ahora $($res.MissingAfter)."
            if ($res.Reboot) {
                if ((Show-Message ($text + "`n`nEs necesario reiniciar el equipo. ¿Reiniciar ahora?") 'Question' 'YesNo') -eq 'Yes') {
                    Restart-Computer -Force
                }
            } else {
                [void](Show-Message ($text + "`n`nSe recomienda reiniciar el equipo."))
            }
        }
    })

    $form.Add_FormClosing({
        param($s, $e)
        if ($script:Gui.IsBusy) {
            $e.Cancel = $true
            [void](Show-Message 'Espera a que termine la operación en curso.' 'Warning')
        }
    })

    $form.Add_Shown({
        $g = $script:Gui
        $g.TxtDest.Text = Join-Path (Get-DefaultBackupParent) (Get-DefaultBackupName)
        Write-Log "Respaldo de Drivers $script:AppVersion - $($env:COMPUTERNAME)"
        $near = Find-BackupNearApp
        if ($near) {
            $g.TxtSrc.Text = $near.Path
            if ($near.IsSelf) {
                # La app se abrió desde la carpeta de un respaldo: ir directo a instalar
                $g.Tabs.SelectedTab = $g.TabRestore
                Invoke-GuiAction { Import-BackupIntoGui $near.Path }
            }
        }
    })

    [void]$form.ShowDialog()
    $form.Dispose()
}

#endregion

#region Inicio

try {
    if ($Respaldar -or $Restaurar) {
        if ($Respaldar) {
            $drivers = @(Get-InstalledDrivers)
            [void](Invoke-DriverBackup -Destination (Join-Path $Respaldar (Get-DefaultBackupName)) -Drivers $drivers)
        }
        if ($Restaurar) {
            $bk = Read-DriverBackup $Restaurar
            $selected = @($bk.Drivers | Where-Object { $_.Category -ne $script:FirmwareCategory })
            $res = Invoke-DriverRestore -Drivers $selected -Root $bk.Path
            if ($res.Failed) { $global:LASTEXITCODE = 1 }
        }
        if ($Elevado) { Read-Host 'Presiona Enter para cerrar' }
    } else {
        Show-MainWindow
    }
} catch {
    if ($Respaldar -or $Restaurar) {
        Write-Log $_.Exception.Message Error
        if ($Elevado) { Read-Host 'Presiona Enter para cerrar' }
        exit 1
    }
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show("Ocurrió un error:`n`n$($_.Exception.Message)", 'Respaldo de Drivers',
        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
}

#endregion
