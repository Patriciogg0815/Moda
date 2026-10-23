#Requires -Version 5.1
<#
.SYNOPSIS
    Respaldo de Drivers: guarda los drivers instalados en el equipo organizados
    por categoría y los vuelve a instalar después de formatear.

.DESCRIPTION
    Este archivo es el código fuente de RespaldoDrivers.exe (GitHub Actions lo compila con ps2exe).
    Para probarlo sin compilar: clic derecho en el archivo → "Ejecutar con PowerShell".

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
# Página de Ko-fi para el botón "Apoyar" (si dice PENDIENTE, el botón no se muestra)
$script:SupportUrl       = 'https://ko-fi.com/garridoitsolutions'
$script:ManifestName     = 'respaldo.json'
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
    @{ Order = 1;  Name = 'Chipset y Sistema';           Glyph = 0xE950; Classes = 'System', 'Processor', 'MultiFunction', 'Computer' }
    @{ Order = 2;  Name = 'Almacenamiento (SATA-NVMe)';  Glyph = 0xEDA2; Classes = 'HDC', 'SCSIAdapter', 'DiskDrive', 'CDROM', 'Volume' }
    @{ Order = 3;  Name = 'USB y Thunderbolt';           Glyph = 0xE88E; Classes = 'USB', 'USBDevice' }
    @{ Order = 4;  Name = 'Video y Graficos';            Glyph = 0xE790; Classes = 'Display' }
    @{ Order = 5;  Name = 'Audio';                       Glyph = 0xE767; Classes = 'MEDIA', 'AudioProcessingObject', 'AudioEndpoint' }
    @{ Order = 6;  Name = 'Red (Ethernet y WiFi)';       Glyph = 0xE701; Classes = 'Net', 'NetService', 'NetTrans', 'NetClient', 'Modem' }
    @{ Order = 7;  Name = 'Bluetooth';                   Glyph = 0xE702; Classes = 'Bluetooth' }
    @{ Order = 8;  Name = 'Teclado, Mouse y Touchpad';   Glyph = 0xE765; Classes = 'HIDClass', 'Keyboard', 'Mouse' }
    @{ Order = 9;  Name = 'Camaras y Escaneres';         Glyph = 0xE722; Classes = 'Image', 'Camera' }
    @{ Order = 10; Name = 'Lectores de Tarjetas';        Glyph = 0xE8C7; Classes = 'SDHost', 'SmartCardReader', 'SmartCard', 'MTD' }
    @{ Order = 11; Name = 'Biometricos y Seguridad';     Glyph = 0xE928; Classes = 'Biometric', 'SecurityDevices', 'SmartCardFilter' }
    @{ Order = 12; Name = 'Sensores';                    Glyph = 0xE9D9; Classes = 'Sensor' }
    @{ Order = 13; Name = 'Bateria y Energia';           Glyph = 0xE83F; Classes = 'Battery' }
    @{ Order = 14; Name = 'Puertos (COM y LPT)';         Glyph = 0xE703; Classes = 'Ports', 'MultiPortSerial' }
    @{ Order = 15; Name = 'Impresoras';                  Glyph = 0xE749; Classes = 'Printer', 'PrintQueue' }
    @{ Order = 16; Name = 'Monitores';                   Glyph = 0xE7F4; Classes = 'Monitor' }
    @{ Order = 17; Name = $script:FirmwareCategory;      Glyph = 0xEA18; Classes = 'Firmware' }
    @{ Order = 18; Name = 'Componentes de Software';     Glyph = 0xECAA; Classes = 'SoftwareComponent', 'SoftwareDevice' }
    @{ Order = 19; Name = 'Extensiones de Drivers';      Glyph = 0xEA86; Classes = 'Extension' }
)
$script:OtherCategory = @{ Order = 99; Name = 'Otros'; Glyph = 0xE712; Classes = @() }

function Get-DriverCategory([string]$ClassName) {
    foreach ($c in $script:Categories) {
        if ($c.Classes -contains $ClassName) { return $c }
    }
    $script:OtherCategory
}

#endregion

#region Utilidades

# Deja que la ventana se redibuje y responda mientras se trabaja (equivalente a DoEvents en WPF)
function Update-UI {
    if (-not $script:Gui) { return }
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    [void][System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::Background, $script:UiCallback, $frame)
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
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
        $script:Gui.Log.ScrollToEnd()
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
        $bar.IsIndeterminate = $false
        $bar.Maximum = [Math]::Max(1, $Maximum)
        $bar.Value = [Math]::Min([Math]::Max(0, $Value), $bar.Maximum)
        if ($Status) { $script:Gui.OvDetail.Text = $Status }
        $script:Gui.OvPercent.Text = '{0} %' -f [int](100 * $bar.Value / $bar.Maximum)
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
            Start-Sleep -Milliseconds 30
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
    while (-not $proc.WaitForExit(50)) { Update-UI }
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

# Muestra el estado (Guardado, Instalado, Error...) en la fila del driver en la ventana
function Set-DriverStatus($Driver, [string]$Kind, [string]$Text) {
    $prop = $Driver.PSObject.Properties['UiItem']
    if ($prop -and $prop.Value) {
        $prop.Value.Status = $Text
        $prop.Value.StatusKind = $Kind
        Update-UI
    }
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

# Copia la app (el .exe) dentro del respaldo para poder usarla después de formatear
function Copy-AppToBackup([string]$Destination) {
    $target = Join-Path $Destination (Split-Path $script:ScriptPath -Leaf)
    if ([IO.Path]::GetFullPath($script:ScriptPath) -ieq [IO.Path]::GetFullPath($target)) { return }
    Copy-Item -LiteralPath $script:ScriptPath -Destination $target -Force
}

# Cómo abrir la copia de la app que queda en el respaldo
function Get-OpenInstruction {
    $name = Split-Path $script:ScriptPath -Leaf
    if ($script:IsExe) { "haz doble clic en «$name»" } else { "haz clic derecho en «$name» → Ejecutar con PowerShell" }
}

function Write-BackupReadme([string]$Destination, $Computer, [object[]]$Drivers) {
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
        "3. En esta carpeta, $(Get-OpenInstruction) y acepta el permiso de administrador."
        '4. En la pantalla de inicio presiona "Restaurar ahora".'
        '5. Presiona "Instalar N drivers" y reinicia el equipo al terminar.'
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
            Set-DriverStatus $drv 'Ok' 'Guardado'
            Write-Log $rel Ok
        } catch {
            $drv.RelativePath = $null
            $failed++
            Set-DriverStatus $drv 'Error' 'Error'
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
        Set-DriverStatus $d 'Info' 'Instalando...'

        $r = Invoke-External $script:PnpUtil $pnpArgs
        switch ($r.ExitCode) {
            0       { $result.Installed++; Set-DriverStatus $d 'Ok' 'Instalado'; Write-Log "Instalado: $label" Ok }
            3010    { $result.Installed++; $result.Reboot = $true; Set-DriverStatus $d 'Ok' 'Instalado *'; Write-Log "Instalado (requiere reiniciar): $label" Ok }
            259     { $result.Unchanged++; Set-DriverStatus $d 'Info' 'Sin cambios'; Write-Log "Sin cambios (ya estaba al día o el dispositivo no está conectado): $label" }
            default { $result.Failed++; Set-DriverStatus $d 'Error' "Error $($r.ExitCode)"; Write-Log ("Error {0} en {1}{2}{3}" -f $r.ExitCode, $label, [Environment]::NewLine, (Get-LastLines $r.Output 4)) Error }
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

#region Interfaz gráfica (WPF)

# Clases para enlazar datos a la ventana: categorías con casillas de 3 estados
# que marcan/desmarcan sus drivers y un contador total de seleccionados.
$script:GuiTypesSource = @'
using System;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace RespaldoDrivers
{
    public class Bindable : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler PropertyChanged;
        protected void Notify(string name)
        {
            PropertyChangedEventHandler h = PropertyChanged;
            if (h != null) h(this, new PropertyChangedEventArgs(name));
        }
    }

    public class DriverItem : Bindable
    {
        public object Source { get; set; }
        public string Provider { get; set; }
        public string InfName { get; set; }
        public string Version { get; set; }
        public string Date { get; set; }
        public string Devices { get; set; }
        internal CategoryItem Parent;

        private bool _isChecked = true;
        public bool IsChecked
        {
            get { return _isChecked; }
            set
            {
                if (_isChecked == value) return;
                _isChecked = value;
                Notify("IsChecked");
                if (Parent != null) Parent.OnChildChanged();
            }
        }

        private string _status = "";
        public string Status { get { return _status; } set { _status = value; Notify("Status"); } }

        private string _statusKind = "";
        public string StatusKind { get { return _statusKind; } set { _statusKind = value; Notify("StatusKind"); } }
    }

    public class CategoryItem : Bindable
    {
        public string Name { get; set; }
        public string Glyph { get; set; }
        public int Order { get; set; }
        public ObservableCollection<DriverItem> Drivers { get; private set; }
        internal DriverSet Owner;
        private bool _updating;

        public CategoryItem() { Drivers = new ObservableCollection<DriverItem>(); }

        public void Add(DriverItem d) { d.Parent = this; Drivers.Add(d); }

        public int CheckedCount
        {
            get { int n = 0; foreach (DriverItem d in Drivers) if (d.IsChecked) n++; return n; }
        }

        public string Summary
        {
            get
            {
                int c = CheckedCount;
                if (c == Drivers.Count) return Drivers.Count + (Drivers.Count == 1 ? " driver" : " drivers");
                return c + " de " + Drivers.Count + " seleccionados";
            }
        }

        public bool? IsChecked
        {
            get
            {
                int c = CheckedCount;
                if (c == 0) return false;
                if (c == Drivers.Count) return true;
                return null;
            }
            set
            {
                bool v = value ?? false;
                _updating = true;
                foreach (DriverItem d in Drivers) d.IsChecked = v;
                _updating = false;
                OnChildChanged();
            }
        }

        internal void OnChildChanged()
        {
            if (_updating) return;
            Notify("IsChecked");
            Notify("Summary");
            Notify("CheckedCount");
            if (Owner != null) Owner.OnChanged();
        }
    }

    public class DriverSet : Bindable
    {
        public ObservableCollection<CategoryItem> Categories { get; private set; }

        public DriverSet() { Categories = new ObservableCollection<CategoryItem>(); }

        public void Add(CategoryItem c) { c.Owner = this; Categories.Add(c); }

        public int CheckedCount
        {
            get { int n = 0; foreach (CategoryItem c in Categories) n += c.CheckedCount; return n; }
        }

        public int TotalCount
        {
            get { int n = 0; foreach (CategoryItem c in Categories) n += c.Drivers.Count; return n; }
        }

        public void SetAll(bool value)
        {
            foreach (CategoryItem c in Categories) c.IsChecked = value;
        }

        public object[] GetChecked()
        {
            System.Collections.Generic.List<object> list = new System.Collections.Generic.List<object>();
            foreach (CategoryItem c in Categories)
                foreach (DriverItem d in c.Drivers)
                    if (d.IsChecked) list.Add(d.Source);
            return list.ToArray();
        }

        internal void OnChanged() { Notify("CheckedCount"); }
    }

    public static class NativeMethods
    {
        [DllImport("user32.dll")]
        public static extern bool SetProcessDPIAware();
    }
}
'@

$script:Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Respaldo de Drivers" Width="1100" Height="740" MinWidth="940" MinHeight="660"
        WindowStartupLocation="CenterScreen" Background="#F3F3F3"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13" Foreground="#1A1A1A"
        TextOptions.TextFormattingMode="Display" UseLayoutRounding="True">
  <Window.Resources>
    <SolidColorBrush x:Key="Accent" Color="#0067C0"/>
    <SolidColorBrush x:Key="AccentHover" Color="#1975C5"/>
    <SolidColorBrush x:Key="AccentPressed" Color="#005A9E"/>
    <SolidColorBrush x:Key="AccentLight" Color="#E5F0FB"/>
    <SolidColorBrush x:Key="Green" Color="#0F7B0F"/>
    <SolidColorBrush x:Key="GreenLight" Color="#DFF6DD"/>
    <SolidColorBrush x:Key="CardBorder" Color="#E5E5E5"/>
    <SolidColorBrush x:Key="TextSecondary" Color="#5F5F5F"/>
    <FontFamily x:Key="Icons">Segoe Fluent Icons, Segoe MDL2 Assets</FontFamily>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="White"/>
      <Setter Property="BorderBrush" Value="{StaticResource CardBorder}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="8"/>
      <Setter Property="Padding" Value="16"/>
    </Style>

    <Style x:Key="Icon" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="{StaticResource Icons}"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="HorizontalAlignment" Value="Center"/>
    </Style>

    <Style x:Key="CellText" TargetType="TextBlock">
      <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>

    <Style x:Key="PrimaryButton" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Background" Value="{StaticResource Accent}"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="22,10"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource AccentHover}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource AccentPressed}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="SubtleButton" TargetType="Button">
      <Setter Property="Background" Value="White"/>
      <Setter Property="Foreground" Value="#1A1A1A"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="#D1D1D1" BorderThickness="1"
                    CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#F6F6F6"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#EDEDED"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="BigCard" TargetType="Button">
      <Setter Property="Background" Value="White"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border x:Name="Shadow" CornerRadius="12" Background="White">
                <Border.Effect>
                  <DropShadowEffect BlurRadius="14" ShadowDepth="2" Direction="270" Opacity="0.07"/>
                </Border.Effect>
              </Border>
              <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{StaticResource CardBorder}"
                      BorderThickness="1" CornerRadius="12" Padding="28">
                <ContentPresenter HorizontalAlignment="Stretch" VerticalAlignment="Stretch"/>
              </Border>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource Accent}"/>
                <Setter TargetName="Shadow" Property="Effect">
                  <Setter.Value>
                    <DropShadowEffect BlurRadius="22" ShadowDepth="4" Direction="270" Opacity="0.16"/>
                  </Setter.Value>
                </Setter>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#F7F9FC"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="CategoryItemStyle" TargetType="ListBoxItem">
      <Setter Property="Padding" Value="8,7"/>
      <Setter Property="Margin" Value="0,1"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="Bd" Background="Transparent" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#F5F5F5"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource AccentLight}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <DataTemplate x:Key="CategoryTemplate">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <CheckBox IsChecked="{Binding IsChecked, Mode=TwoWay}" VerticalAlignment="Center" Margin="2,0,0,0"/>
        <Border Grid.Column="1" Width="34" Height="34" CornerRadius="8" Background="#EEF4FB" Margin="10,0">
          <TextBlock Style="{StaticResource Icon}" Text="{Binding Glyph}" FontSize="16" Foreground="{StaticResource Accent}"/>
        </Border>
        <StackPanel Grid.Column="2" VerticalAlignment="Center">
          <TextBlock Text="{Binding Name}" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
          <TextBlock Text="{Binding Summary}" FontSize="12" Foreground="{StaticResource TextSecondary}"/>
        </StackPanel>
      </Grid>
    </DataTemplate>

    <DataTemplate x:Key="CheckCell">
      <CheckBox IsChecked="{Binding IsChecked, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"
                HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </DataTemplate>

    <DataTemplate x:Key="DeviceCell">
      <StackPanel VerticalAlignment="Center">
        <TextBlock Text="{Binding Devices}" TextTrimming="CharacterEllipsis" ToolTip="{Binding Devices}"/>
        <TextBlock Text="{Binding Provider}" FontSize="12" Foreground="#5F5F5F" TextTrimming="CharacterEllipsis"/>
      </StackPanel>
    </DataTemplate>

    <DataTemplate x:Key="StatusCell">
      <TextBlock x:Name="St" Text="{Binding Status}" FontWeight="SemiBold" VerticalAlignment="Center" Foreground="#5F5F5F"/>
      <DataTemplate.Triggers>
        <DataTrigger Binding="{Binding StatusKind}" Value="Ok">
          <Setter TargetName="St" Property="Foreground" Value="#0F7B0F"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding StatusKind}" Value="Warn">
          <Setter TargetName="St" Property="Foreground" Value="#9D5D00"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding StatusKind}" Value="Error">
          <Setter TargetName="St" Property="Foreground" Value="#C42B1C"/>
        </DataTrigger>
      </DataTemplate.Triggers>
    </DataTemplate>

    <Style TargetType="DataGrid">
      <Setter Property="Background" Value="White"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="RowBackground" Value="White"/>
      <Setter Property="AlternatingRowBackground" Value="#FAFAFA"/>
      <Setter Property="GridLinesVisibility" Value="Horizontal"/>
      <Setter Property="HorizontalGridLinesBrush" Value="#EFEFEF"/>
      <Setter Property="HeadersVisibility" Value="Column"/>
      <Setter Property="AutoGenerateColumns" Value="False"/>
      <Setter Property="CanUserAddRows" Value="False"/>
      <Setter Property="CanUserDeleteRows" Value="False"/>
      <Setter Property="CanUserResizeRows" Value="False"/>
      <Setter Property="IsReadOnly" Value="True"/>
      <Setter Property="SelectionMode" Value="Single"/>
      <Setter Property="RowHeight" Value="46"/>
    </Style>
    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="White"/>
      <Setter Property="Foreground" Value="{StaticResource TextSecondary}"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="8"/>
      <Setter Property="BorderBrush" Value="{StaticResource CardBorder}"/>
      <Setter Property="BorderThickness" Value="0,0,0,1"/>
    </Style>
    <Style TargetType="DataGridCell">
      <Setter Property="Padding" Value="8,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="DataGridCell">
            <Border Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Background" Value="{StaticResource AccentLight}"/>
          <Setter Property="Foreground" Value="#1A1A1A"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="BorderBrush" Value="#D1D1D1"/>
      <Setter Property="Padding" Value="8,0"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <!-- ===== Encabezado ===== -->
    <Grid Grid.Row="0" Margin="28,22,28,10">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <Button x:Name="BtnBack" Style="{StaticResource SubtleButton}" Width="40" Height="40" Padding="0"
              Margin="0,0,14,0" VerticalAlignment="Center" Visibility="Collapsed" ToolTip="Volver al inicio">
        <TextBlock Style="{StaticResource Icon}" Text="&#xE72B;" FontSize="16"/>
      </Button>
      <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="0,0,16,0">
        <TextBlock x:Name="TxtTitle" Text="Respaldo de Drivers" FontSize="26" FontWeight="SemiBold"
                   FontFamily="Segoe UI Variable Display, Segoe UI"/>
        <TextBlock x:Name="TxtSubtitle" Foreground="{StaticResource TextSecondary}" Margin="0,2,0,0" TextWrapping="Wrap"
                   Text="Guarda los drivers de tu equipo y vuelve a instalarlos después de formatear."/>
      </StackPanel>
      <Button x:Name="BtnSupport" Grid.Column="2" Style="{StaticResource SubtleButton}" Padding="14,9" Margin="0,0,12,0"
              VerticalAlignment="Center" Visibility="Collapsed" ToolTip="Abre la página de Ko-fi en tu navegador">
        <StackPanel Orientation="Horizontal">
          <TextBlock Style="{StaticResource Icon}" Text="&#xEB52;" Foreground="#FF5E5B" Margin="0,0,8,0"/>
          <TextBlock Text="Apoyar en Ko-fi" FontWeight="SemiBold"/>
        </StackPanel>
      </Button>
      <Border Grid.Column="3" Style="{StaticResource Card}" Padding="14,10" VerticalAlignment="Center">
        <StackPanel Orientation="Horizontal">
          <TextBlock Style="{StaticResource Icon}" Text="&#xE7F8;" FontSize="26" Foreground="{StaticResource Accent}" Margin="0,0,12,0"/>
          <StackPanel>
            <TextBlock x:Name="PcModel" FontWeight="SemiBold" Text="Este equipo"/>
            <TextBlock x:Name="PcDetails" FontSize="12" Foreground="{StaticResource TextSecondary}"/>
          </StackPanel>
        </StackPanel>
      </Border>
    </Grid>

    <!-- ===== Pantalla de inicio ===== -->
    <Grid x:Name="PageHome" Grid.Row="1" Margin="28,10,28,28">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <Border x:Name="HomeBanner" Grid.Row="0" Background="{StaticResource AccentLight}" BorderBrush="#B3D3F2" BorderThickness="1"
              CornerRadius="8" Padding="16,10" Margin="0,0,0,16" Visibility="Collapsed">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBlock Style="{StaticResource Icon}" Text="&#xE946;" FontSize="18" Foreground="{StaticResource Accent}" Margin="0,0,12,0"/>
          <TextBlock x:Name="HomeBannerText" Grid.Column="1" VerticalAlignment="Center" TextWrapping="Wrap"/>
          <Button x:Name="BtnBannerRestore" Grid.Column="2" Style="{StaticResource PrimaryButton}" Content="Restaurar ahora"
                  Padding="16,7" FontSize="13" Margin="12,0,0,0"/>
        </Grid>
      </Border>

      <TextBlock Grid.Row="1" Text="¿Qué deseas hacer?" FontSize="18" FontWeight="SemiBold" Margin="2,0,0,12"/>

      <Grid Grid.Row="2">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="20"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <Button x:Name="BtnGoBackup" Grid.Column="0" Style="{StaticResource BigCard}">
          <DockPanel>
            <DockPanel DockPanel.Dock="Bottom" Margin="0,18,0,0">
              <Border Background="{StaticResource AccentLight}" CornerRadius="10" Padding="10,3" VerticalAlignment="Center">
                <TextBlock Text="PASO 1 · ANTES DE FORMATEAR" FontSize="11" FontWeight="Bold" Foreground="{StaticResource Accent}"/>
              </Border>
              <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                <TextBlock Text="Comenzar" FontWeight="SemiBold" Foreground="{StaticResource Accent}" FontSize="14"/>
                <TextBlock Style="{StaticResource Icon}" Text="&#xE72A;" Foreground="{StaticResource Accent}" Margin="8,1,0,0"/>
              </StackPanel>
            </DockPanel>
            <StackPanel>
              <Border Width="76" Height="76" CornerRadius="38" Background="{StaticResource AccentLight}" HorizontalAlignment="Left">
                <TextBlock Style="{StaticResource Icon}" Text="&#xE896;" FontSize="34" Foreground="{StaticResource Accent}"/>
              </Border>
              <TextBlock Text="Respaldar drivers" FontSize="24" FontWeight="SemiBold" Margin="0,22,0,6"
                         FontFamily="Segoe UI Variable Display, Segoe UI"/>
              <TextBlock TextWrapping="Wrap" Foreground="{StaticResource TextSecondary}" FontSize="14" LineHeight="21"
                         Text="Guarda todos los drivers de este equipo, ordenados por categoría, en una USB o en un disco externo."/>
              <StackPanel Margin="0,18,0,0">
                <StackPanel Orientation="Horizontal" Margin="0,3">
                  <TextBlock Style="{StaticResource Icon}" Text="&#xE73E;" Foreground="{StaticResource Green}" Margin="0,0,10,0"/>
                  <TextBlock Text="Video, audio, red, WiFi, Bluetooth, chipset y más"/>
                </StackPanel>
                <StackPanel Orientation="Horizontal" Margin="0,3">
                  <TextBlock Style="{StaticResource Icon}" Text="&#xE73E;" Foreground="{StaticResource Green}" Margin="0,0,10,0"/>
                  <TextBlock Text="Inventario para Excel con los datos del equipo"/>
                </StackPanel>
                <StackPanel Orientation="Horizontal" Margin="0,3">
                  <TextBlock Style="{StaticResource Icon}" Text="&#xE73E;" Foreground="{StaticResource Green}" Margin="0,0,10,0"/>
                  <TextBlock Text="Incluye esta app para usarla después de formatear"/>
                </StackPanel>
              </StackPanel>
            </StackPanel>
          </DockPanel>
        </Button>

        <Button x:Name="BtnGoRestore" Grid.Column="2" Style="{StaticResource BigCard}">
          <DockPanel>
            <DockPanel DockPanel.Dock="Bottom" Margin="0,18,0,0">
              <Border Background="{StaticResource GreenLight}" CornerRadius="10" Padding="10,3" VerticalAlignment="Center">
                <TextBlock Text="PASO 2 · DESPUÉS DE FORMATEAR" FontSize="11" FontWeight="Bold" Foreground="{StaticResource Green}"/>
              </Border>
              <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                <TextBlock Text="Comenzar" FontWeight="SemiBold" Foreground="{StaticResource Green}" FontSize="14"/>
                <TextBlock Style="{StaticResource Icon}" Text="&#xE72A;" Foreground="{StaticResource Green}" Margin="8,1,0,0"/>
              </StackPanel>
            </DockPanel>
            <StackPanel>
              <Border Width="76" Height="76" CornerRadius="38" Background="{StaticResource GreenLight}" HorizontalAlignment="Left">
                <TextBlock Style="{StaticResource Icon}" Text="&#xE777;" FontSize="34" Foreground="{StaticResource Green}"/>
              </Border>
              <TextBlock Text="Restaurar drivers" FontSize="24" FontWeight="SemiBold" Margin="0,22,0,6"
                         FontFamily="Segoe UI Variable Display, Segoe UI"/>
              <TextBlock TextWrapping="Wrap" Foreground="{StaticResource TextSecondary}" FontSize="14" LineHeight="21"
                         Text="Instala los drivers desde un respaldo creado con esta aplicación o desde una carpeta del fabricante."/>
              <StackPanel Margin="0,18,0,0">
                <StackPanel Orientation="Horizontal" Margin="0,3">
                  <TextBlock Style="{StaticResource Icon}" Text="&#xE73E;" Foreground="{StaticResource Green}" Margin="0,0,10,0"/>
                  <TextBlock Text="Instala en el orden correcto: chipset primero"/>
                </StackPanel>
                <StackPanel Orientation="Horizontal" Margin="0,3">
                  <TextBlock Style="{StaticResource Icon}" Text="&#xE73E;" Foreground="{StaticResource Green}" Margin="0,0,10,0"/>
                  <TextBlock Text="Muestra qué dispositivos siguen sin driver"/>
                </StackPanel>
                <StackPanel Orientation="Horizontal" Margin="0,3">
                  <TextBlock Style="{StaticResource Icon}" Text="&#xE73E;" Foreground="{StaticResource Green}" Margin="0,0,10,0"/>
                  <TextBlock Text="Firmware y BIOS desmarcados por seguridad"/>
                </StackPanel>
              </StackPanel>
            </StackPanel>
          </DockPanel>
        </Button>
      </Grid>

      <Border Grid.Row="3" Style="{StaticResource Card}" Margin="0,20,0,0" Padding="16,12">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <Border x:Name="HomeStatusIconBg" Width="38" Height="38" CornerRadius="19" Background="#F3F3F3">
            <TextBlock x:Name="HomeStatusIcon" Style="{StaticResource Icon}" Text="&#xE9D9;" FontSize="16" Foreground="#5F5F5F"/>
          </Border>
          <StackPanel Grid.Column="1" Margin="12,0" VerticalAlignment="Center">
            <TextBlock x:Name="HomeStatusTitle" FontWeight="SemiBold" Text="Revisando los dispositivos del equipo..."/>
            <TextBlock x:Name="HomeStatusText" FontSize="12" Foreground="{StaticResource TextSecondary}"/>
          </StackPanel>
          <Button x:Name="BtnHomeMissing" Grid.Column="2" Style="{StaticResource SubtleButton}" Content="Ver detalle" Visibility="Collapsed"/>
        </Grid>
      </Border>
    </Grid>

    <!-- ===== Pantalla Respaldar ===== -->
    <Grid x:Name="PageBackup" Grid.Row="1" Margin="28,10,28,28" Visibility="Collapsed">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <Grid Grid.Row="0" Margin="0,0,0,12">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock x:Name="BkSummary" VerticalAlignment="Center" FontSize="14" TextWrapping="Wrap" Text="Analizando los drivers..."/>
        <StackPanel Grid.Column="1" Orientation="Horizontal">
          <Button x:Name="BtnBkAll" Style="{StaticResource SubtleButton}" Content="Marcar todo" Margin="8,0,0,0"/>
          <Button x:Name="BtnBkNone" Style="{StaticResource SubtleButton}" Content="Desmarcar todo" Margin="8,0,0,0"/>
          <Button x:Name="BtnBkRescan" Style="{StaticResource SubtleButton}" Margin="8,0,0,0">
            <StackPanel Orientation="Horizontal">
              <TextBlock Style="{StaticResource Icon}" Text="&#xE72C;" Margin="0,0,8,0"/>
              <TextBlock Text="Volver a analizar"/>
            </StackPanel>
          </Button>
        </StackPanel>
      </Grid>

      <Grid Grid.Row="1">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="320"/>
          <ColumnDefinition Width="16"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Border Style="{StaticResource Card}" Padding="8">
          <DockPanel>
            <TextBlock DockPanel.Dock="Top" Text="CATEGORÍAS" FontSize="11" FontWeight="Bold"
                       Foreground="{StaticResource TextSecondary}" Margin="8,4,0,8"/>
            <ListBox x:Name="BkCategories" ItemsSource="{Binding Categories}" BorderThickness="0" Background="Transparent"
                     ItemContainerStyle="{StaticResource CategoryItemStyle}" ItemTemplate="{StaticResource CategoryTemplate}"
                     ScrollViewer.HorizontalScrollBarVisibility="Disabled"/>
          </DockPanel>
        </Border>
        <Border Grid.Column="2" Style="{StaticResource Card}" Padding="0">
          <DockPanel>
            <TextBlock DockPanel.Dock="Top" Text="{Binding SelectedItem.Name, ElementName=BkCategories}"
                       FontSize="16" FontWeight="SemiBold" Margin="16,14,16,6"/>
            <DataGrid x:Name="BkGrid" ItemsSource="{Binding SelectedItem.Drivers, ElementName=BkCategories}" Margin="8,0,8,8">
              <DataGrid.Columns>
                <DataGridTemplateColumn Width="40" CellTemplate="{StaticResource CheckCell}"/>
                <DataGridTemplateColumn Header="Dispositivo y fabricante" Width="*" MinWidth="180" CellTemplate="{StaticResource DeviceCell}"/>
                <DataGridTextColumn Header="Driver" Binding="{Binding InfName}" Width="125" ElementStyle="{StaticResource CellText}"/>
                <DataGridTextColumn Header="Versión" Binding="{Binding Version}" Width="110" ElementStyle="{StaticResource CellText}"/>
                <DataGridTextColumn Header="Fecha" Binding="{Binding Date}" Width="85" ElementStyle="{StaticResource CellText}"/>
                <DataGridTemplateColumn Header="Estado" Width="90" CellTemplate="{StaticResource StatusCell}"/>
              </DataGrid.Columns>
            </DataGrid>
          </DockPanel>
        </Border>
      </Grid>

      <Border Grid.Row="2" Style="{StaticResource Card}" Margin="0,16,0,0" Padding="16,12">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBlock Text="Guardar en:" VerticalAlignment="Center" FontWeight="SemiBold" Margin="0,0,12,0"/>
          <TextBox x:Name="BkDest" Grid.Column="1" Height="36" FontSize="13"/>
          <Button x:Name="BtnBkBrowse" Grid.Column="2" Style="{StaticResource SubtleButton}" Margin="8,0,16,0" Height="36">
            <StackPanel Orientation="Horizontal">
              <TextBlock Style="{StaticResource Icon}" Text="&#xE838;" Margin="0,0,8,0"/>
              <TextBlock Text="Examinar"/>
            </StackPanel>
          </Button>
          <Button x:Name="BtnBkStart" Grid.Column="3" Style="{StaticResource PrimaryButton}">
            <StackPanel Orientation="Horizontal">
              <TextBlock Style="{StaticResource Icon}" Text="&#xE74E;" Margin="0,0,10,0"/>
              <TextBlock Text="{Binding CheckedCount, StringFormat='Respaldar {0} drivers', FallbackValue='Respaldar drivers'}"/>
            </StackPanel>
          </Button>
        </Grid>
      </Border>
    </Grid>

    <!-- ===== Pantalla Restaurar ===== -->
    <Grid x:Name="PageRestore" Grid.Row="1" Margin="28,10,28,28" Visibility="Collapsed">
      <Border x:Name="RsEmpty" Style="{StaticResource Card}" Padding="40">
        <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center" MaxWidth="480">
          <Border Width="92" Height="92" CornerRadius="46" Background="{StaticResource GreenLight}">
            <TextBlock Style="{StaticResource Icon}" Text="&#xE8B7;" FontSize="40" Foreground="{StaticResource Green}"/>
          </Border>
          <TextBlock Text="Elige el respaldo de drivers" FontSize="22" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,22,0,8"/>
          <TextBlock TextWrapping="Wrap" TextAlignment="Center" FontSize="14" LineHeight="21" Foreground="{StaticResource TextSecondary}"
                     Text="Conecta la USB o el disco donde guardaste el respaldo y selecciona la carpeta que empieza con «Drivers_». También puedes elegir una carpeta con drivers descargados del fabricante."/>
          <Button x:Name="BtnRsBrowse" Style="{StaticResource PrimaryButton}" Margin="0,26,0,0" HorizontalAlignment="Center">
            <StackPanel Orientation="Horizontal">
              <TextBlock Style="{StaticResource Icon}" Text="&#xE838;" Margin="0,0,10,0"/>
              <TextBlock Text="Buscar respaldo..."/>
            </StackPanel>
          </Button>
        </StackPanel>
      </Border>

      <Grid x:Name="RsContent" Visibility="Collapsed">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Border Grid.Row="0" Style="{StaticResource Card}" Padding="16,12" Margin="0,0,0,12">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Border Width="42" Height="42" CornerRadius="21" Background="{StaticResource GreenLight}">
              <TextBlock Style="{StaticResource Icon}" Text="&#xE8B7;" FontSize="18" Foreground="{StaticResource Green}"/>
            </Border>
            <StackPanel Grid.Column="1" Margin="12,0" VerticalAlignment="Center">
              <TextBlock x:Name="RsTitle" FontWeight="SemiBold" FontSize="14"/>
              <TextBlock x:Name="RsDetails" FontSize="12" Foreground="{StaticResource TextSecondary}" TextTrimming="CharacterEllipsis"/>
            </StackPanel>
            <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
              <Button x:Name="BtnRsAll" Style="{StaticResource SubtleButton}" Content="Marcar todo" Margin="8,0,0,0"/>
              <Button x:Name="BtnRsNone" Style="{StaticResource SubtleButton}" Content="Desmarcar todo" Margin="8,0,0,0"/>
              <Button x:Name="BtnRsChange" Style="{StaticResource SubtleButton}" Content="Cambiar respaldo" Margin="8,0,0,0"/>
            </StackPanel>
          </Grid>
        </Border>

        <Border x:Name="RsWarn" Grid.Row="1" Background="#FFF4CE" BorderBrush="#F2D57A" BorderThickness="1" CornerRadius="8"
                Padding="14,10" Margin="0,0,0,12" Visibility="Collapsed">
          <DockPanel>
            <TextBlock DockPanel.Dock="Left" Style="{StaticResource Icon}" Text="&#xE7BA;" Foreground="#9D5D00" FontSize="16"
                       Margin="0,0,10,0" VerticalAlignment="Top"/>
            <TextBlock x:Name="RsWarnText" TextWrapping="Wrap" VerticalAlignment="Center"/>
          </DockPanel>
        </Border>

        <Grid Grid.Row="2">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="320"/>
            <ColumnDefinition Width="16"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <Border Style="{StaticResource Card}" Padding="8">
            <DockPanel>
              <TextBlock DockPanel.Dock="Top" Text="CATEGORÍAS" FontSize="11" FontWeight="Bold"
                         Foreground="{StaticResource TextSecondary}" Margin="8,4,0,8"/>
              <ListBox x:Name="RsCategories" ItemsSource="{Binding Categories}" BorderThickness="0" Background="Transparent"
                       ItemContainerStyle="{StaticResource CategoryItemStyle}" ItemTemplate="{StaticResource CategoryTemplate}"
                       ScrollViewer.HorizontalScrollBarVisibility="Disabled"/>
            </DockPanel>
          </Border>
          <Border Grid.Column="2" Style="{StaticResource Card}" Padding="0">
            <DockPanel>
              <TextBlock DockPanel.Dock="Top" Text="{Binding SelectedItem.Name, ElementName=RsCategories}"
                         FontSize="16" FontWeight="SemiBold" Margin="16,14,16,6"/>
              <DataGrid x:Name="RsGrid" ItemsSource="{Binding SelectedItem.Drivers, ElementName=RsCategories}" Margin="8,0,8,8">
                <DataGrid.Columns>
                  <DataGridTemplateColumn Width="40" CellTemplate="{StaticResource CheckCell}"/>
                  <DataGridTemplateColumn Header="Dispositivo y fabricante" Width="*" MinWidth="180" CellTemplate="{StaticResource DeviceCell}"/>
                  <DataGridTextColumn Header="Driver" Binding="{Binding InfName}" Width="125" ElementStyle="{StaticResource CellText}"/>
                  <DataGridTextColumn Header="Versión" Binding="{Binding Version}" Width="110" ElementStyle="{StaticResource CellText}"/>
                  <DataGridTemplateColumn Header="Estado" Width="110" CellTemplate="{StaticResource StatusCell}"/>
                </DataGrid.Columns>
              </DataGrid>
            </DockPanel>
          </Border>
        </Grid>

        <Border Grid.Row="3" Style="{StaticResource Card}" Margin="0,16,0,0" Padding="16,12">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Border x:Name="RsMissingIconBg" Width="36" Height="36" CornerRadius="18" Background="#F3F3F3">
              <TextBlock x:Name="RsMissingIcon" Style="{StaticResource Icon}" Text="&#xE9D9;" FontSize="15" Foreground="#5F5F5F"/>
            </Border>
            <TextBlock x:Name="RsMissingText" Grid.Column="1" VerticalAlignment="Center" Margin="12,0" TextWrapping="Wrap"/>
            <Button x:Name="BtnRsMissing" Grid.Column="2" Style="{StaticResource SubtleButton}" Content="Ver dispositivos sin driver" Margin="0,0,16,0"/>
            <Button x:Name="BtnRsStart" Grid.Column="3" Style="{StaticResource PrimaryButton}">
              <StackPanel Orientation="Horizontal">
                <TextBlock Style="{StaticResource Icon}" Text="&#xE896;" Margin="0,0,10,0"/>
                <TextBlock Text="{Binding CheckedCount, StringFormat='Instalar {0} drivers', FallbackValue='Instalar drivers'}"/>
              </StackPanel>
            </Button>
          </Grid>
        </Border>
      </Grid>
    </Grid>

    <!-- ===== Ventana de progreso / resultado ===== -->
    <Grid x:Name="Overlay" Grid.RowSpan="2" Background="#66000000" Visibility="Collapsed">
      <Border Style="{StaticResource Card}" Width="620" Padding="28" CornerRadius="12"
              HorizontalAlignment="Center" VerticalAlignment="Center">
        <StackPanel>
          <StackPanel x:Name="OvBusy">
            <TextBlock x:Name="OvTitle" FontSize="20" FontWeight="SemiBold" Text="Trabajando..."/>
            <TextBlock x:Name="OvDetail" Foreground="{StaticResource TextSecondary}" Margin="0,8,0,16" TextTrimming="CharacterEllipsis"/>
            <ProgressBar x:Name="Progress" Height="6" Foreground="{StaticResource Accent}" Background="#E5E5E5" BorderThickness="0"/>
            <TextBlock x:Name="OvPercent" HorizontalAlignment="Right" FontSize="12" Foreground="{StaticResource TextSecondary}" Margin="0,6,0,0"/>
          </StackPanel>
          <StackPanel x:Name="OvDone" Visibility="Collapsed">
            <Border x:Name="OvIconBg" Width="64" Height="64" CornerRadius="32" HorizontalAlignment="Left" Background="{StaticResource GreenLight}">
              <TextBlock x:Name="OvIcon" Style="{StaticResource Icon}" FontSize="28" Text="&#xE73E;" Foreground="{StaticResource Green}"/>
            </Border>
            <TextBlock x:Name="OvDoneTitle" FontSize="20" FontWeight="SemiBold" Margin="0,16,0,8"/>
            <TextBlock x:Name="OvDoneText" TextWrapping="Wrap" FontSize="14" LineHeight="21"/>
          </StackPanel>
          <Expander Header="Ver registro detallado" Margin="0,18,0,0">
            <TextBox x:Name="Log" Height="170" Margin="0,8,0,0" IsReadOnly="True" FontFamily="Consolas" FontSize="12" Padding="6"
                     VerticalContentAlignment="Top" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
                     TextWrapping="NoWrap" Background="#FAFAFA" BorderBrush="{StaticResource CardBorder}"/>
          </Expander>
          <DockPanel x:Name="OvButtons" Margin="0,20,0,0" LastChildFill="False" Visibility="Collapsed">
            <Button x:Name="OvSupport" DockPanel.Dock="Left" Style="{StaticResource SubtleButton}" Padding="14,9" Visibility="Collapsed">
              <StackPanel Orientation="Horizontal">
                <TextBlock Style="{StaticResource Icon}" Text="&#xEB52;" Foreground="#FF5E5B" Margin="0,0,8,0"/>
                <TextBlock Text="¿Te sirvió? Apóyanos en Ko-fi"/>
              </StackPanel>
            </Button>
            <Button x:Name="OvClose" DockPanel.Dock="Right" Style="{StaticResource SubtleButton}" Content="Listo" Padding="22,9"/>
            <Button x:Name="OvPrimary" DockPanel.Dock="Right" Style="{StaticResource PrimaryButton}" Margin="0,0,8,0"/>
          </DockPanel>
        </StackPanel>
      </Border>
    </Grid>
  </Grid>
</Window>
'@

function Initialize-GuiTypes {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms
    if (-not ('RespaldoDrivers.DriverSet' -as [type])) { Add-Type -TypeDefinition $script:GuiTypesSource -Language CSharp }
    $script:UiCallback = [System.Windows.Threading.DispatcherOperationCallback]{ param($frame) $frame.Continue = $false; $null }
}

function Test-SupportConfigured { $script:SupportUrl -and $script:SupportUrl -notmatch 'PENDIENTE' }

# Abre Ko-fi con explorer.exe para que el navegador no se abra con permisos de administrador
function Open-SupportPage {
    try { Start-Process explorer.exe -ArgumentList "`"$script:SupportUrl`"" }
    catch { Write-Log "No se pudo abrir $($script:SupportUrl): $($_.Exception.Message)" Warn }
}

function New-Brush([string]$Hex) { (New-Object System.Windows.Media.BrushConverter).ConvertFromString($Hex) }

function Get-CategoryGlyph([string]$Name) {
    $code = $script:OtherCategory.Glyph
    foreach ($c in $script:Categories) { if ($c.Name -eq $Name) { $code = $c.Glyph; break } }
    [string][char]$code
}

function Show-Message([string]$Text, [string]$Icon = 'Information', [string]$Buttons = 'OK') {
    [System.Windows.MessageBox]::Show($script:Gui.Window, $Text, 'Respaldo de Drivers',
        [System.Windows.MessageBoxButton]$Buttons, [System.Windows.MessageBoxImage]$Icon)
}

function Select-Folder([string]$Description, [bool]$AllowNewFolder) {
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = $Description
    $dlg.ShowNewFolderButton = $AllowNewFolder
    $owner = New-Object System.Windows.Forms.NativeWindow
    $owner.AssignHandle((New-Object System.Windows.Interop.WindowInteropHelper($script:Gui.Window)).Handle)
    try {
        if ($dlg.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
    } finally {
        $owner.ReleaseHandle()
        $dlg.Dispose()
    }
    $null
}

function Show-Page([string]$Name) {
    $g = $script:Gui
    foreach ($page in 'PageHome', 'PageBackup', 'PageRestore') {
        $g[$page].Visibility = if ($page -eq $Name) { 'Visible' } else { 'Collapsed' }
    }
    $g.BtnBack.Visibility = if ($Name -eq 'PageHome') { 'Collapsed' } else { 'Visible' }
    switch ($Name) {
        'PageHome' {
            $g.TxtTitle.Text = 'Respaldo de Drivers'
            $g.TxtSubtitle.Text = 'Guarda los drivers de tu equipo y vuelve a instalarlos después de formatear.'
        }
        'PageBackup' {
            $g.TxtTitle.Text = 'Respaldar drivers'
            $g.TxtSubtitle.Text = 'Elige qué guardar y dónde. Usa una USB o un disco que no vayas a formatear.'
        }
        'PageRestore' {
            $g.TxtTitle.Text = 'Restaurar drivers'
            $g.TxtSubtitle.Text = 'Instala los drivers guardados en un respaldo.'
        }
    }
}

function Show-Overlay([string]$Title) {
    $g = $script:Gui
    $g.OvTitle.Text = $Title
    $g.OvDetail.Text = 'Un momento, por favor...'
    $g.OvPercent.Text = ''
    $g.Progress.IsIndeterminate = $true
    $g.OvBusy.Visibility = 'Visible'
    $g.OvDone.Visibility = 'Collapsed'
    $g.OvButtons.Visibility = 'Collapsed'
    $g.Overlay.Visibility = 'Visible'
    Update-UI
}

function Hide-Overlay {
    $g = $script:Gui
    $g.Overlay.Visibility = 'Collapsed'
    $g.OvDone.Visibility = 'Collapsed'
    $g.Progress.IsIndeterminate = $false
}

function Show-OverlayResult {
    param(
        [ValidateSet('Ok', 'Warn', 'Error', 'Info')][string]$Kind,
        [string]$Title,
        [string]$Text,
        [string]$PrimaryText,
        [scriptblock]$PrimaryAction,
        [string]$CloseText = 'Listo',
        [switch]$ShowSupport
    )
    $g = $script:Gui
    $style = @{
        Ok    = @{ Glyph = 0xE73E; Fg = '#0F7B0F'; Bg = '#DFF6DD' }
        Warn  = @{ Glyph = 0xE7BA; Fg = '#9D5D00'; Bg = '#FFF4CE' }
        Error = @{ Glyph = 0xE783; Fg = '#C42B1C'; Bg = '#FDE7E9' }
        Info  = @{ Glyph = 0xE946; Fg = '#0067C0'; Bg = '#E5F0FB' }
    }[$Kind]
    $g.OvIcon.Text = [string][char]$style.Glyph
    $g.OvIcon.Foreground = New-Brush $style.Fg
    $g.OvIconBg.Background = New-Brush $style.Bg
    $g.OvDoneTitle.Text = $Title
    $g.OvDoneText.Text = $Text
    $g.OvPrimaryAction = $PrimaryAction
    $g.OvPrimary.Content = $PrimaryText
    $g.OvPrimary.Visibility = if ($PrimaryText) { 'Visible' } else { 'Collapsed' }
    $g.OvClose.Content = $CloseText
    $g.OvSupport.Visibility = if ($ShowSupport -and (Test-SupportConfigured)) { 'Visible' } else { 'Collapsed' }
    $g.OvBusy.Visibility = 'Collapsed'
    $g.OvDone.Visibility = 'Visible'
    $g.OvButtons.Visibility = 'Visible'
    $g.Overlay.Visibility = 'Visible'
}

# Ejecuta una acción mostrando la ventana de progreso; si falla, muestra el error.
function Invoke-GuiAction([string]$BusyTitle, [scriptblock]$Action) {
    $g = $script:Gui
    $g.IsBusy = $true
    if ($BusyTitle) { Show-Overlay $BusyTitle }
    try {
        & $Action
        if ($g.OvDone.Visibility -ne 'Visible') { Hide-Overlay }
    } catch {
        Write-Log $_.Exception.Message Error
        Show-OverlayResult -Kind Error -Title 'Ocurrió un problema' -Text $_.Exception.Message
    } finally {
        $g.IsBusy = $false
    }
}

function New-DriverSet([object[]]$Drivers, [string[]]$UncheckedCategories = @()) {
    $set = New-Object RespaldoDrivers.DriverSet
    $groups = $Drivers | Group-Object CategoryOrder, Category | Sort-Object { $_.Group[0].CategoryOrder }, Name
    foreach ($grp in $groups) {
        $first = $grp.Group[0]
        $cat = New-Object RespaldoDrivers.CategoryItem
        $cat.Name = $first.Category
        $cat.Order = $first.CategoryOrder
        $cat.Glyph = Get-CategoryGlyph $first.Category
        $checked = -not ($UncheckedCategories -contains $first.Category)
        foreach ($d in $grp.Group) {
            $item = New-Object RespaldoDrivers.DriverItem
            $item.Source = $d
            $item.Provider = $d.Provider
            $item.InfName = $d.InfName
            $item.Version = $d.Version
            $item.Date = $d.Date
            $item.Devices = if ($d.Devices.Count) { $d.Devices -join ', ' } else { 'Sin dispositivo asociado' }
            $item.IsChecked = $checked
            $cat.Add($item)
            $d | Add-Member -NotePropertyName UiItem -NotePropertyValue $item -Force
        }
        $set.Add($cat)
    }
    $set
}

function Get-BackupSummary([string]$Path) {
    try {
        $m = Get-Content -LiteralPath (Join-Path $Path $script:ManifestName) -Raw -Encoding UTF8 | ConvertFrom-Json
        '{0} {1}  ·  creado {2}  ·  {3} drivers' -f $m.Computer.Manufacturer, $m.Computer.Model, (Format-DriverDate $m.Created), @($m.Drivers).Count
    } catch {
        Split-Path $Path -Leaf
    }
}

function Update-MissingStatus {
    $g = $script:Gui
    $devices = @(Invoke-InBackground ${function:Get-DevicesWithoutDriver})
    $g.MissingDevices = $devices
    $n = $devices.Count
    if ($n) {
        $title = if ($n -eq 1) { '1 dispositivo sin driver o con problemas' } else { "$n dispositivos sin driver o con problemas" }
        $g.HomeStatusTitle.Text = $title
        $g.HomeStatusText.Text = 'Si acabas de formatear, usa «Restaurar drivers» para instalarlos desde tu respaldo.'
        $g.RsMissingText.Text = "En este equipo: $title."
        $glyph = 0xE7BA; $fg = '#9D5D00'; $bg = '#FFF4CE'
    } else {
        $g.HomeStatusTitle.Text = 'Todos los dispositivos tienen su driver instalado'
        $g.HomeStatusText.Text = 'Es un buen momento para crear un respaldo.'
        $g.RsMissingText.Text = 'En este equipo todos los dispositivos tienen driver.'
        $glyph = 0xE73E; $fg = '#0F7B0F'; $bg = '#DFF6DD'
    }
    foreach ($pair in @(@($g.HomeStatusIcon, $g.HomeStatusIconBg), @($g.RsMissingIcon, $g.RsMissingIconBg))) {
        $pair[0].Text = [string][char]$glyph
        $pair[0].Foreground = New-Brush $fg
        $pair[1].Background = New-Brush $bg
    }
    $g.BtnHomeMissing.Visibility = if ($n) { 'Visible' } else { 'Collapsed' }
}

function Show-MissingDevices {
    $g = $script:Gui
    Invoke-GuiAction 'Revisando los dispositivos...' { Update-MissingStatus }
    $devices = @($g.MissingDevices)
    if (-not $devices.Count) {
        Show-OverlayResult -Kind Ok -Title 'Todo en orden' -Text 'Todos los dispositivos del equipo tienen su driver instalado.'
        return
    }
    Write-Log "Dispositivos sin driver o con problemas: $($devices.Count)" Warn
    foreach ($d in $devices) { Write-Log ("   - {0}  [código {1}]  {2}" -f $d.Name, $d.Code, $d.HardwareId) Warn }
    $list = ($devices | Select-Object -First 12 | ForEach-Object { '•  ' + $_.Name }) -join "`n"
    if ($devices.Count -gt 12) { $list += "`n•  ... y $($devices.Count - 12) más" }
    Show-OverlayResult -Kind Warn -Title "$($devices.Count) dispositivos sin driver" `
        -Text ($list + "`n`nEl ID de hardware de cada uno está en el registro detallado.")
}

function Open-BackupPage {
    Show-Page 'PageBackup'
    if (-not $script:Gui.BkSet) { Start-DriverScan }
}

function Start-DriverScan {
    Invoke-GuiAction 'Analizando los drivers del equipo...' {
        $g = $script:Gui
        $drivers = @(Get-InstalledDrivers)
        if (-not $drivers.Count) { throw 'No se encontraron drivers de terceros en este equipo.' }
        $set = New-DriverSet $drivers
        $g.BkSet = $set
        $g.PageBackup.DataContext = $set
        $g.BkCategories.SelectedIndex = 0
        $g.BkSummary.Text = "Se encontraron $($set.TotalCount) drivers en $($set.Categories.Count) categorías. Desmarca los que no quieras guardar."
    }
}

function Start-Backup {
    $g = $script:Gui
    if (-not $g.BkSet) { return }
    $selected = @($g.BkSet.GetChecked())
    if (-not $selected.Count) { [void](Show-Message 'Marca al menos un driver para respaldar.' 'Warning'); return }
    $dest = $g.BkDest.Text.Trim()
    if (-not $dest) { [void](Show-Message 'Indica la carpeta donde se guardará el respaldo.' 'Warning'); return }
    if (Test-OnSystemDrive $dest) {
        $answer = Show-Message ("La carpeta está en el disco $env:SystemDrive, que normalmente se borra al formatear.`n`n" +
            "Cuando termine el respaldo, cópiala a una USB o a otro disco.`n`n¿Deseas continuar?") 'Warning' 'YesNo'
        if ($answer -ne 'Yes') { return }
    }
    foreach ($s in $selected) { Set-DriverStatus $s '' '' }

    Invoke-GuiAction 'Respaldando drivers...' {
        $res = Invoke-DriverBackup -Destination $dest -Drivers $selected
        $text = "Se guardaron $($res.Ok) drivers"
        if ($res.Failed) { $text += " ($($res.Failed) con error)" }
        $text += " en:`n$($res.Path)`n`nDespués de formatear, abre esa carpeta y $(Get-OpenInstruction)."
        if (Test-OnSystemDrive $res.Path) { $text += "`n`nRecuerda copiar la carpeta a una USB antes de formatear." }
        $path = $res.Path
        Show-OverlayResult -Kind $(if ($res.Failed) { 'Warn' } else { 'Ok' }) -Title 'Respaldo terminado' -Text $text `
            -PrimaryText 'Abrir carpeta' -PrimaryAction ({ Start-Process explorer.exe -ArgumentList "`"$path`"" }.GetNewClosure()) `
            -ShowSupport:(-not $res.Failed)
    }
}

function Open-RestorePage([string]$Path) {
    $g = $script:Gui
    Show-Page 'PageRestore'
    if ($Path) { Import-BackupIntoGui $Path }
    elseif (-not $g.RsSet -and $g.NearBackup) { Import-BackupIntoGui $g.NearBackup }
}

function Import-BackupIntoGui([string]$Path) {
    Invoke-GuiAction 'Cargando el respaldo...' {
        $g = $script:Gui
        $bk = Read-DriverBackup $Path
        $set = New-DriverSet $bk.Drivers @($script:FirmwareCategory)
        $g.Backup = $bk
        $g.RsSet = $set
        $g.PageRestore.DataContext = $set
        $g.RsCategories.SelectedIndex = 0
        $g.RsEmpty.Visibility = 'Collapsed'
        $g.RsContent.Visibility = 'Visible'

        $c = $bk.Computer
        $g.RsTitle.Text = if ($c) { "Respaldo de $($c.Manufacturer) $($c.Model)" } else { "Carpeta de drivers: $(Split-Path $bk.Path -Leaf)" }
        $details = "$($set.TotalCount) drivers en $($set.Categories.Count) categorías  ·  $($bk.Path)"
        if ($bk.Created) { $details = "Creado $(Format-DriverDate $bk.Created)  ·  " + $details }
        $g.RsDetails.Text = $details

        $warnings = @()
        if ($c) {
            $current = Get-ComputerSummary
            if ($c.Architecture -and $c.Architecture -ne $current.Architecture) {
                $warnings += "El respaldo es de arquitectura $($c.Architecture) y este Windows es $($current.Architecture): los drivers no serán compatibles."
            } elseif ($c.Model -and $c.Model -ne $current.Model) {
                $warnings += "El respaldo es de otro modelo de equipo ($($c.Model)). Solo se instalarán en los dispositivos compatibles."
            }
        }
        if ($bk.Drivers | Where-Object { $_.Category -eq $script:FirmwareCategory }) {
            $warnings += "La categoría «$($script:FirmwareCategory)» quedó desmarcada por seguridad: actualiza el BIOS al reiniciar."
        }
        $g.RsWarnText.Text = $warnings -join "`n"
        $g.RsWarn.Visibility = if ($warnings.Count) { 'Visible' } else { 'Collapsed' }
        Write-Log "Respaldo cargado: $($bk.Path) ($($set.TotalCount) drivers)" Ok
        Update-MissingStatus
    }
}

function Start-Restore {
    $g = $script:Gui
    if (-not $g.RsSet) { return }
    $selected = @($g.RsSet.GetChecked())
    if (-not $selected.Count) { [void](Show-Message 'Marca al menos un driver para instalar.' 'Warning'); return }
    $answer = Show-Message ("Se instalarán $($selected.Count) drivers.`n`n" +
        "Durante la instalación la pantalla puede parpadear o quedarse en negro unos segundos (driver de video) " +
        "y la red puede desconectarse un momento.`n`n¿Continuar?") 'Question' 'YesNo'
    if ($answer -ne 'Yes') { return }
    foreach ($s in $selected) { Set-DriverStatus $s 'Info' 'Pendiente' }

    Invoke-GuiAction 'Instalando drivers...' {
        $res = Invoke-DriverRestore -Drivers $selected -Root $script:Gui.Backup.Path
        Update-MissingStatus
        $text = "Instalados:   $($res.Installed)`nSin cambios:  $($res.Unchanged)`nCon error:    $($res.Failed)`n`n" +
            "Dispositivos sin driver: antes $($res.MissingBefore), ahora $($res.MissingAfter)."
        $text += if ($res.Reboot) { "`n`nReinicia el equipo para terminar la instalación." } else { "`n`nSe recomienda reiniciar el equipo." }
        Show-OverlayResult -Kind $(if ($res.Failed) { 'Warn' } else { 'Ok' }) -Title 'Instalación terminada' -Text $text `
            -PrimaryText 'Reiniciar ahora' -PrimaryAction { Restart-Computer -Force } -CloseText 'Más tarde' `
            -ShowSupport:(-not $res.Failed)
    }
}

# Crea la ventana con todos sus eventos (sin mostrarla)
function New-MainWindow {
    Initialize-GuiTypes
    try { [void][RespaldoDrivers.NativeMethods]::SetProcessDPIAware() } catch { }
    [System.Windows.Forms.Application]::EnableVisualStyles()

    [xml]$xml = $script:Xaml
    $window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xml))
    # En pantallas pequeñas, que la ventana no sea más grande que el escritorio
    $area = [System.Windows.SystemParameters]::WorkArea
    $window.MinWidth = [Math]::Min($window.MinWidth, $area.Width)
    $window.MinHeight = [Math]::Min($window.MinHeight, $area.Height)
    $window.Width = [Math]::Min($window.Width, $area.Width)
    $window.Height = [Math]::Min($window.Height, $area.Height)

    $g = @{ Window = $window; IsBusy = $false; Backup = $null; BkSet = $null; RsSet = $null; NearBackup = $null; MissingDevices = @() }
    $xamlNs = 'http://schemas.microsoft.com/winfx/2006/xaml'
    $nsm = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
    $nsm.AddNamespace('x', $xamlNs)
    foreach ($node in $xml.SelectNodes('//*[@x:Name]', $nsm)) {
        $name = $node.GetAttribute('Name', $xamlNs)
        $element = $window.FindName($name)
        if ($element) { $g[$name] = $element }
    }
    $script:Gui = $g

    $pc = Get-ComputerSummary
    $g.PcModel.Text = "$($pc.Manufacturer) $($pc.Model)".Trim()
    $g.PcDetails.Text = "S/N $($pc.SerialNumber)  ·  $($pc.OS)  ·  $($pc.Architecture)"

    # --- Navegación ---
    $g.BtnBack.Add_Click({ Show-Page 'PageHome' })
    $g.BtnGoBackup.Add_Click({ Open-BackupPage })
    $g.BtnGoRestore.Add_Click({ Open-RestorePage })
    $g.BtnBannerRestore.Add_Click({ Open-RestorePage $script:Gui.NearBackup })
    $g.BtnHomeMissing.Add_Click({ Show-MissingDevices })

    # --- Respaldar ---
    $g.BtnBkAll.Add_Click({ if ($script:Gui.BkSet) { $script:Gui.BkSet.SetAll($true) } })
    $g.BtnBkNone.Add_Click({ if ($script:Gui.BkSet) { $script:Gui.BkSet.SetAll($false) } })
    $g.BtnBkRescan.Add_Click({ Start-DriverScan })
    $g.BtnBkBrowse.Add_Click({
        $folder = Select-Folder 'Elige la USB o carpeta donde se creará la carpeta del respaldo' $true
        if ($folder) { $script:Gui.BkDest.Text = Join-Path $folder (Get-DefaultBackupName) }
    })
    $g.BtnBkStart.Add_Click({ Start-Backup })

    # --- Restaurar ---
    $browseBackup = {
        $folder = Select-Folder 'Elige la carpeta del respaldo de drivers (la que contiene respaldo.json)' $false
        if ($folder) { Import-BackupIntoGui $folder }
    }
    $g.BtnRsBrowse.Add_Click($browseBackup)
    $g.BtnRsChange.Add_Click($browseBackup)
    $g.BtnRsAll.Add_Click({ if ($script:Gui.RsSet) { $script:Gui.RsSet.SetAll($true) } })
    $g.BtnRsNone.Add_Click({ if ($script:Gui.RsSet) { $script:Gui.RsSet.SetAll($false) } })
    $g.BtnRsMissing.Add_Click({ Show-MissingDevices })
    $g.BtnRsStart.Add_Click({ Start-Restore })

    # --- Ventana de resultado ---
    $g.OvClose.Add_Click({ Hide-Overlay })
    $g.OvSupport.Add_Click({ Open-SupportPage })
    $g.BtnSupport.Add_Click({ Open-SupportPage })
    $g.BtnSupport.Visibility = if (Test-SupportConfigured) { 'Visible' } else { 'Collapsed' }
    $g.OvPrimary.Add_Click({
        $action = $script:Gui.OvPrimaryAction
        Hide-Overlay
        if ($action) { & $action }
    })

    $window.Add_Closing({
        param($s, $e)
        if ($script:Gui.IsBusy) {
            $e.Cancel = $true
            [void](Show-Message 'Espera a que termine la operación en curso.' 'Warning')
        }
    })

    $window.Add_ContentRendered({
        $g = $script:Gui
        Write-Log "Respaldo de Drivers $script:AppVersion - $($env:COMPUTERNAME)"
        $g.BkDest.Text = Join-Path (Get-DefaultBackupParent) (Get-DefaultBackupName)
        $near = Find-BackupNearApp
        if ($near) {
            $g.NearBackup = $near.Path
            $summary = Get-BackupSummary $near.Path
            $g.HomeBannerText.Text = if ($near.IsSelf) {
                "Esta carpeta contiene un respaldo de drivers: $summary. ¿Acabas de formatear? Restáuralo ahora."
            } else {
                "Se encontró un respaldo junto a la aplicación: $summary."
            }
            $g.HomeBanner.Visibility = 'Visible'
        }
        Update-MissingStatus
    })

    Show-Page 'PageHome'
    $window
}

function Show-MainWindow {
    $window = New-MainWindow
    [void]$window.ShowDialog()
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
