#Requires -Version 5.1
<#
.SYNOPSIS
    Diagnóstico PC: revisa Windows y muestra los problemas en rojo, amarillo y verde, con el paso a
    paso para arreglarlos: energía e hibernación, temperatura, programas, drivers, pantallas azules,
    registro, archivos de Windows, disco, batería y antivirus. También avisa junto al reloj cuando
    aparece un problema nuevo.

.DESCRIPTION
    Este archivo es el código fuente de DiagnosticoPC.exe (GitHub Actions lo compila con ps2exe).
    Para probarlo sin compilar: clic derecho en el archivo → "Ejecutar con PowerShell".

    Modo línea de comandos:
        .\DiagnosticoPC.ps1 -Analizar
            Muestra el análisis en la consola (sin ventana).
        .\DiagnosticoPC.ps1 -Analizar -Informe "C:\informe.html"
            Además guarda el informe en HTML.
        .\DiagnosticoPC.ps1 -Avisos
            Arranca junto al reloj sin abrir la ventana (lo usa la opción "Iniciar con Windows").

.NOTES
    Requiere Windows 10 (versión 2004 o superior) u 11 y permisos de administrador.
    Antes de cambiar algo crea un punto de restauración y guarda el valor anterior para poder deshacerlo.
#>
[CmdletBinding()]
param(
    [switch]$Analizar,
    [string]$Informe,
    [switch]$Avisos,
    [switch]$Elevado
)

$ErrorActionPreference = 'Stop'

# Funciones que ya existían antes de cargar las de la app (para copiar solo las nuestras a segundo plano)
$script:InitialFunctions = @(Get-ChildItem function: | ForEach-Object { $_.Name })
$script:AppName      = 'Diagnóstico PC'
$script:AppVersion   = '1.0.0'
# Edición para la Microsoft Store: sin "Iniciar con Windows" (Crear-EXE.ps1 -EdicionStore lo cambia a $true)
$script:StoreEdition = $false
# Página de Ko-fi para el botón "Apoyar" (si dice PENDIENTE, el botón no se muestra)
$script:SupportUrl   = 'https://ko-fi.com/garridoitsolutions'
$script:DataDir      = Join-Path $env:APPDATA 'DiagnosticoPC'
$script:TaskName     = 'DiagnosticoPC-Avisos'
# En las pruebas automáticas no se crean puntos de restauración ni se abren programas
$script:TestMode     = $env:DIAGNOSTICOPC_PRUEBA -eq '1'
$script:Gui          = $null
$script:Wizard       = $null
$script:Settings     = $null
$script:PcInfo       = $null
$script:RestorePointDone = $false
# Lo que se está revisando en segundo plano (la ventana lo muestra en la barra de progreso)
$script:Progress     = [hashtable]::Synchronized(@{ Text = ''; Step = 0; Total = 1 })

# Ruta del script (o del .exe si se compiló con ps2exe)
$script:ScriptPath = if ($PSCommandPath) { $PSCommandPath } else { [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName }
$script:ScriptDir  = Split-Path -Parent $script:ScriptPath
$script:IsExe      = $script:ScriptPath -like '*.exe'

#region Permisos de administrador

function Test-IsAdmin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$script:ScriptPath`"", '-Elevado')
    if ($Analizar) { $argList += '-Analizar' }
    if ($Informe) { $argList += @('-Informe', "`"$Informe`"") }
    if ($Avisos) { $argList += '-Avisos' }
    if (-not $Analizar) { $argList = @('-WindowStyle', 'Hidden') + $argList }
    try {
        Start-Process -FilePath ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -Verb RunAs -ArgumentList $argList
    } catch {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show(
            'Se necesitan permisos de administrador para revisar y arreglar Windows.',
            'Diagnóstico PC', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
    }
    exit
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

# Espera sin congelar la ventana
function Wait-UI([int]$Milliseconds) {
    $end = [DateTime]::UtcNow.AddMilliseconds($Milliseconds)
    while ([DateTime]::UtcNow -lt $end) {
        Update-UI
        Start-Sleep -Milliseconds 30
    }
}

function Write-Log([string]$Message) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try {
        if (-not (Test-Path -LiteralPath $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
        Add-Content -LiteralPath (Join-Path $script:DataDir 'registro.txt') -Value $line -Encoding UTF8
    } catch { }
    if (-not $script:Gui) { Write-Verbose $line }
}

function ConvertTo-ArgumentString([string[]]$Arguments) {
    $quoted = foreach ($a in $Arguments) {
        if ($a -match '[\s"]' -or $a -eq '') { '"' + (($a -replace '"', '\"') -replace '(\\+)$', '$1$1') + '"' } else { $a }
    }
    $quoted -join ' '
}

# Ejecuta un programa de Windows (powercfg, pnputil, reg...) y devuelve su salida sin congelar la ventana
function Invoke-External([string]$FilePath, [string[]]$Arguments, [switch]$Unicode) {
    $enc = if ($Unicode) { [Text.Encoding]::Unicode } else { [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = ConvertTo-ArgumentString $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $enc
    $psi.StandardErrorEncoding = $enc
    $proc = [Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEndAsync()
    $stderr = $proc.StandardError.ReadToEndAsync()
    while (-not $proc.WaitForExit(50)) { Update-UI }
    $proc.WaitForExit()
    [pscustomobject]@{
        ExitCode = $proc.ExitCode
        Output   = (($stdout.Result + $stderr.Result) -replace "`0", '').Trim()
    }
}

function Invoke-PowerCfg([string[]]$Arguments) {
    $r = Invoke-External (Join-Path $env:SystemRoot 'System32\powercfg.exe') $Arguments
    if ($r.ExitCode -ne 0) { throw "powercfg $($Arguments -join ' '): $($r.Output)" }
    $r.Output
}

function Get-OwnFunctionNames {
    @(Get-ChildItem function: | Where-Object { $script:InitialFunctions -notcontains $_.Name } | ForEach-Object { $_.Name })
}

# Ejecuta un bloque en segundo plano (con todas las funciones de la app) sin congelar la ventana.
# Sin ventana (consola o pruebas de lógica) lo ejecuta directamente.
function Invoke-Background([scriptblock]$Script, [object[]]$Arguments = @()) {
    if (-not $script:Gui) { return & $Script @Arguments }
    $iss = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($name in Get-OwnFunctionNames) {
        $def = (Get-Item "function:$name").ScriptBlock.ToString()
        $iss.Commands.Add((New-Object Management.Automation.Runspaces.SessionStateFunctionEntry($name, $def)))
    }
    # Variables de la app (sin las de la ventana, que solo se usan en su propio hilo)
    foreach ($v in 'InitialFunctions', 'AppName', 'AppVersion', 'StoreEdition', 'SupportUrl', 'DataDir', 'TaskName', 'TestMode',
                   'Settings', 'PcInfo', 'RestorePointDone', 'Progress', 'ScriptPath', 'ScriptDir', 'IsExe', 'DefaultSettings',
                   'Areas', 'Checks', 'PowerGuids', 'OpenPowerAdvanced', 'OpenPowerButtons', 'CmdAdminPath', 'ProtectedProcesses',
                   'DeviceCodes', 'BugChecks', 'CrashFix', 'CauseTexts', 'FixInfo', 'Intervals') {
        $value = (Get-Variable -Name $v -Scope Script -ErrorAction SilentlyContinue).Value
        $iss.Variables.Add((New-Object Management.Automation.Runspaces.SessionStateVariableEntry($v, $value, '')))
    }
    $iss.Variables.Add((New-Object Management.Automation.Runspaces.SessionStateVariableEntry('ErrorActionPreference', 'Stop', '')))
    $rs = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
    $rs.ApartmentState = 'STA'
    $rs.Open()
    $ps = [PowerShell]::Create()
    $ps.Runspace = $rs
    try {
        [void]$ps.AddScript($Script.ToString())
        foreach ($a in $Arguments) { [void]$ps.AddArgument($a) }
        $handle = $ps.BeginInvoke()
        while (-not $handle.IsCompleted) {
            Update-UI
            if ($script:Gui -and $script:Gui.OvDetail -and $script:Progress.Text) { Set-BusyProgress }
            Start-Sleep -Milliseconds 30
        }
        $result = $ps.EndInvoke($handle)
        if ($ps.HadErrors -and $ps.Streams.Error.Count -and -not $result.Count) { throw $ps.Streams.Error[0].Exception }
        # PSDataCollection → arreglo normal
        $out = @()
        foreach ($r in $result) { $out += $r }
        $out
    } finally {
        $ps.Dispose()
        $rs.Dispose()
    }
}

function Get-RegValue([string]$Path, [string]$Name) {
    try { (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name } catch { $null }
}

# Guarda el valor actual de un registro para poder deshacer el cambio después
function Get-RegUndo([string]$Path, [string]$Name) {
    $undo = @{ T = 'reg'; Path = $Path; Name = $Name; Existed = $false; Kind = $null; Value = $null }
    try {
        $key = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($key.GetValueNames() -contains $Name) {
            $undo.Existed = $true
            $undo.Kind = "$($key.GetValueKind($Name))"
            $raw = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $undo.Value = switch ($undo.Kind) {
                'Binary'      { [Convert]::ToBase64String([byte[]]$raw) }
                'MultiString' { @($raw) }
                default       { $raw }
            }
        }
    } catch { }
    $undo
}

function Set-RegValue([string]$Path, [string]$Name, $Value, [string]$Kind = 'DWord') {
    $undo = Get-RegUndo $Path $Name
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Kind -Force | Out-Null
    $undo
}

function Remove-RegValue([string]$Path, [string]$Name) {
    $undo = Get-RegUndo $Path $Name
    if ($undo.Existed) { Remove-ItemProperty -LiteralPath $Path -Name $Name -Force }
    $undo
}

function Get-Events([hashtable]$Filter, [int]$Max = 500) {
    try { @(Get-WinEvent -FilterHashtable $Filter -MaxEvents $Max -ErrorAction Stop) } catch { @() }
}

function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1GB) { return '{0:N1} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N0} MB' -f ($Bytes / 1MB) }
    '{0:N0} KB' -f ($Bytes / 1KB)
}

function Format-Minutes([int]$Seconds) {
    if ($Seconds -le 0) { return 'nunca' }
    $m = [int][Math]::Round($Seconds / 60)
    if ($m -lt 60) { return "$m min" }
    $h = [Math]::Floor($m / 60); $r = $m % 60
    $text = if ($h -eq 1) { '1 hora' } else { "$h horas" }
    if ($r) { $text += " y $r min" }
    $text
}

function Format-Date([datetime]$Date) { $Date.ToString('dd/MM/yyyy HH:mm') }

function Get-Plural([int]$Count, [string]$One, [string]$Many) { if ($Count -eq 1) { "1 $One" } else { "$Count $Many" } }

function Limit-Text([string]$Text, [int]$Max) {
    if ($Text.Length -le $Max) { return $Text }
    $Text.Substring(0, $Max - 1).TrimEnd() + '…'
}

#endregion

#region Ajustes

$script:DefaultSettings = [ordered]@{
    AvisosActivos      = $true
    Intervalo          = 5
    AvisoPantallaAzul  = $true
    AvisoTemperatura   = $true
    AvisoProcesador    = $true
    AvisoMemoria       = $true
    AvisoDisco         = $true
    AvisoDespertar     = $true
    SeguirAlCerrar     = $true
    AvisoCerrarVisto   = $false
    UltimoAnalisis     = ''
    UltimoResumen      = ''
    UltimaRevisionAvisos = ''
}

function Get-Settings {
    $s = @{}
    foreach ($k in $script:DefaultSettings.Keys) { $s[$k] = $script:DefaultSettings[$k] }
    try {
        $file = Join-Path $script:DataDir 'ajustes.json'
        if (Test-Path -LiteralPath $file) {
            $json = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $json.PSObject.Properties) { if ($s.ContainsKey($p.Name)) { $s[$p.Name] = $p.Value } }
        }
    } catch { }
    if ([int]$s.Intervalo -lt 1) { $s.Intervalo = 5 }
    $s
}

function Save-Settings {
    try {
        if (-not (Test-Path -LiteralPath $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
        $script:Settings | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:DataDir 'ajustes.json') -Encoding UTF8
    } catch { Write-Log "No se pudieron guardar los ajustes: $($_.Exception.Message)" }
}

#endregion

#region Tipos para la ventana y para leer la energía

$script:TypesSource = @'
using System;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace DiagnosticoPC
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

    public static class Levels
    {
        public static string Fg(string level)
        {
            switch (level) { case "Rojo": return "#C42B1C"; case "Amarillo": return "#9D5D00"; case "Verde": return "#0F7B0F"; default: return "#0067C0"; }
        }
        public static string Bg(string level)
        {
            switch (level) { case "Rojo": return "#FDE7E9"; case "Amarillo": return "#FFF4CE"; case "Verde": return "#DFF6DD"; default: return "#E5F0FB"; }
        }
        public static string Glyph(string level)
        {
            switch (level) { case "Rojo": return "\uE711"; case "Amarillo": return "\uE7BA"; case "Verde": return "\uE73E"; default: return "\uE946"; }
        }
        public static string Text(string level)
        {
            switch (level) { case "Rojo": return "GRAVE"; case "Amarillo": return "REVISAR"; case "Verde": return "BIEN"; default: return "INFORMACIÓN"; }
        }
        public static int Order(string level)
        {
            switch (level) { case "Rojo": return 0; case "Amarillo": return 1; case "Info": return 2; default: return 3; }
        }
    }

    public class ItemView : Bindable
    {
        public object Source { get; set; }
        public string Name { get; set; }
        public string Detail { get; set; }
        public string ActionText { get; set; }
        public string Action2Text { get; set; }
        public bool HasAction { get { return !String.IsNullOrEmpty(ActionText); } }
        public bool HasAction2 { get { return !String.IsNullOrEmpty(Action2Text); } }
        public bool HasDetail { get { return !String.IsNullOrEmpty(Detail); } }

        private string _status = "";
        public string Status { get { return _status; } set { _status = value; Notify("Status"); Notify("HasStatus"); } }
        public bool HasStatus { get { return !String.IsNullOrEmpty(_status); } }

        private bool _enabled = true;
        public bool IsEnabled { get { return _enabled; } set { _enabled = value; Notify("IsEnabled"); } }
    }

    public class FindingView : Bindable
    {
        public FindingView() { Items = new ObservableCollection<ItemView>(); }
        public object Source { get; set; }
        public string Id { get; set; }
        public string Check { get; set; }
        public string Area { get; set; }
        public string AreaGlyph { get; set; }
        public string Level { get; set; }
        public string Title { get; set; }
        public string Summary { get; set; }
        public string Detail { get; set; }
        public string FixText { get; set; }
        public int StepCount { get; set; }
        public ObservableCollection<ItemView> Items { get; private set; }

        public bool HasFix { get { return !String.IsNullOrEmpty(FixText); } }
        public bool HasSteps { get { return StepCount > 0; } }
        public bool HasItems { get { return Items.Count > 0; } }
        public string LevelFg { get { return Levels.Fg(Level); } }
        public string LevelBg { get { return Levels.Bg(Level); } }
        public string LevelGlyph { get { return Levels.Glyph(Level); } }
        public string LevelText { get { return Levels.Text(Level); } }
        public int Order { get { return Levels.Order(Level); } }
        public string AreaLine { get { return Area.ToUpperInvariant(); } }
    }

    public class ChangeView : Bindable
    {
        public object Source { get; set; }
        public string Date { get; set; }
        public string Description { get; set; }
        private string _status = "";
        public string Status { get { return _status; } set { _status = value; Notify("Status"); } }
        private bool _canUndo;
        public bool CanUndo { get { return _canUndo; } set { _canUndo = value; Notify("CanUndo"); } }
    }

    public class AlertView
    {
        public string Time { get; set; }
        public string Title { get; set; }
        public string Text { get; set; }
    }

    public static class Power
    {
        [DllImport("powrprof.dll")]
        private static extern bool GetPwrCapabilities(byte[] capabilities);
        [DllImport("powrprof.dll")]
        private static extern uint PowerGetActiveScheme(IntPtr rootPowerKey, out IntPtr activePolicyGuid);
        [DllImport("powrprof.dll")]
        private static extern uint PowerReadACValueIndex(IntPtr rootPowerKey, ref Guid scheme, ref Guid subGroup, ref Guid setting, out uint value);
        [DllImport("powrprof.dll")]
        private static extern uint PowerReadDCValueIndex(IntPtr rootPowerKey, ref Guid scheme, ref Guid subGroup, ref Guid setting, out uint value);
        [DllImport("kernel32.dll")]
        private static extern IntPtr LocalFree(IntPtr mem);

        // SYSTEM_POWER_CAPABILITIES (76 bytes): se devuelve tal cual y se lee por posición
        public static byte[] Capabilities()
        {
            byte[] buffer = new byte[128];
            return GetPwrCapabilities(buffer) ? buffer : null;
        }

        public static Guid ActiveScheme()
        {
            IntPtr p;
            if (PowerGetActiveScheme(IntPtr.Zero, out p) != 0) return Guid.Empty;
            Guid g = (Guid)Marshal.PtrToStructure(p, typeof(Guid));
            LocalFree(p);
            return g;
        }

        // Devuelve -1 si el ajuste no existe en este equipo
        public static long Read(string subGroup, string setting, bool ac)
        {
            Guid scheme = ActiveScheme();
            Guid sub = new Guid(subGroup);
            Guid set = new Guid(setting);
            uint value;
            uint r = ac ? PowerReadACValueIndex(IntPtr.Zero, ref scheme, ref sub, ref set, out value)
                        : PowerReadDCValueIndex(IntPtr.Zero, ref scheme, ref sub, ref set, out value);
            return r == 0 ? (long)value : -1;
        }
    }

    public static class NativeMethods
    {
        [DllImport("user32.dll")]
        public static extern bool SetProcessDPIAware();
    }
}
'@

function Initialize-Types {
    if (-not ('DiagnosticoPC.Power' -as [type])) { Add-Type -TypeDefinition $script:TypesSource -Language CSharp }
}

#endregion

#region Resultados del análisis

# Un resultado del análisis. Level: Rojo (grave), Amarillo (revisar), Verde (bien) o Info.
# Steps: pasos para arreglarlo a mano (New-Step). Fix: arreglo automático (Invoke-Fix). Items: lista de
# programas, dispositivos o pantallas azules, cada uno con sus propios botones.
function New-Finding {
    param(
        [string]$Id, [string]$Area,
        [ValidateSet('Rojo', 'Amarillo', 'Verde', 'Info')][string]$Level,
        [string]$Title, [string]$Summary, [string]$Detail,
        [object[]]$Steps = @(), [string]$Fix, [string]$FixText, [object]$FixArg,
        [object[]]$Items = @(), [object]$Data
    )
    [pscustomobject]@{
        Id = $Id; Check = ''; Area = $Area; Level = $Level; Title = $Title; Summary = $Summary; Detail = $Detail
        Steps = @($Steps | Where-Object { $_ }); Fix = $Fix; FixText = $FixText; FixArg = $FixArg
        Items = @($Items | Where-Object { $_ }); Data = $Data
    }
}

# Un paso del "paso a paso". Path: dónde está en Windows. Command: comando para escribir.
# Button + Open: abre una ventana de Windows. Button + Fix: lo hace la app.
function New-Step {
    param([string]$Title, [string]$Text, [string]$Path, [string]$Command, [string]$Button, [string]$Open, [string]$Fix, [object]$FixArg)
    [pscustomobject]@{ Title = $Title; Text = $Text; Path = $Path; Command = $Command; Button = $Button; Open = $Open; Fix = $Fix; FixArg = $FixArg }
}

function New-FindingItem {
    param([string]$Name, [string]$Detail, [string]$Action, [string]$ActionText, [string]$Action2, [string]$Action2Text, [object]$Arg)
    [pscustomobject]@{ Name = $Name; Detail = $Detail; Action = $Action; ActionText = $ActionText; Action2 = $Action2; Action2Text = $Action2Text; Arg = $Arg }
}

$script:Areas = [ordered]@{
    'Energía'             = 0xE945
    'Temperatura'         = 0xE706
    'Programas'           = 0xE71D
    'Drivers'             = 0xE772
    'Pantallas azules'    = 0xE7F4
    'Registro'            = 0xE943
    'Archivos de Windows' = 0xE8A5
    'Disco'               = 0xEDA2
    'Batería'             = 0xE83F
    'Seguridad'           = 0xEA18
    'Sistema'             = 0xE777
}

# Revisiones en el orden en que se ejecutan (la del procesador va primero, antes de que el propio
# análisis ocupe el procesador)
$script:Checks = @(
    @{ Name = 'Test-CpuUsage';          Label = 'Programas que usan el procesador' }
    @{ Name = 'Test-Memory';            Label = 'Memoria' }
    @{ Name = 'Test-Hibernation';       Label = 'Hibernación y suspensión' }
    @{ Name = 'Test-LidAction';         Label = 'Qué pasa al cerrar la tapa' }
    @{ Name = 'Test-SleepBlockers';     Label = 'Programas que no dejan suspender' }
    @{ Name = 'Test-WakeSources';       Label = 'Qué despierta a la PC' }
    @{ Name = 'Test-PowerPlan';         Label = 'Plan de energía' }
    @{ Name = 'Test-FastStartup';       Label = 'Inicio rápido' }
    @{ Name = 'Test-Temperature';       Label = 'Temperatura' }
    @{ Name = 'Test-StartupApps';       Label = 'Programas que arrancan con Windows' }
    @{ Name = 'Test-DeviceProblems';    Label = 'Dispositivos y drivers' }
    @{ Name = 'Test-DisplayDriver';     Label = 'Driver de video' }
    @{ Name = 'Test-BlueScreens';       Label = 'Pantallas azules y apagones' }
    @{ Name = 'Test-CrashDumpSettings'; Label = 'Registro de pantallas azules' }
    @{ Name = 'Test-RegistryTampering'; Label = 'Registro de Windows' }
    @{ Name = 'Test-SystemFiles';       Label = 'Archivos de Windows' }
    @{ Name = 'Test-DiskSpace';         Label = 'Espacio en disco' }
    @{ Name = 'Test-DiskHealth';        Label = 'Salud del disco' }
    @{ Name = 'Test-Battery';           Label = 'Batería' }
    @{ Name = 'Test-Antivirus';         Label = 'Antivirus' }
    @{ Name = 'Test-Uptime';            Label = 'Reinicios y actualizaciones' }
)

function Invoke-Analysis([string[]]$Only) {
    $script:PcInfo = Get-PcInfo
    $list = @($script:Checks | Where-Object { -not $Only -or $Only -contains $_.Name })
    $results = New-Object System.Collections.ArrayList
    $i = 0
    foreach ($c in $list) {
        $i++
        $script:Progress.Text = $c.Label
        $script:Progress.Step = $i
        $script:Progress.Total = $list.Count
        try {
            $found = & $c.Name
        } catch {
            $found = New-Finding -Id $c.Name -Area 'Sistema' -Level Info -Title "No se pudo revisar: $($c.Label)" `
                -Summary 'Windows no entregó la información.' -Detail "Detalle técnico: $($_.Exception.Message)"
        }
        foreach ($f in @($found)) {
            if (-not $f) { continue }
            $f.Check = $c.Name
            [void]$results.Add($f)
        }
    }
    if (-not $Only) { Update-CrossChecks $results }
    $script:Progress.Text = ''
    $results.ToArray()
}

# Ajustes que dependen de varias revisiones a la vez
function Update-CrossChecks($Findings) {
    $byId = @{}
    foreach ($f in $Findings) { $byId[$f.Id] = $f }
    $fast = $byId['inicio-rapido']
    if ($fast -and $fast.Level -eq 'Verde' -and $fast.Data -and $fast.Data.Enabled) {
        $reasons = @()
        foreach ($id in 'pantallas-azules', 'apagones', 'drivers-error') {
            if ($byId[$id] -and $byId[$id].Level -in 'Rojo', 'Amarillo') { $reasons += $byId[$id].Title.ToLower() }
        }
        if ($reasons.Count) {
            $fast.Level = 'Amarillo'
            $fast.Summary = 'Conviene desactivarlo mientras haya fallas'
            $fast.Detail += "`n`nEn esta PC también se encontró: $($reasons -join '; '). Con el inicio rápido, «Apagar» no reinicia los drivers de verdad, y los errores pueden repetirse. Desactívalo para que cada encendido empiece de cero."
        }
    }
}

function Get-PcInfo {
    $cs = Get-CimInstance Win32_ComputerSystem
    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = @(Get-CimInstance Win32_Processor)[0]
    $display = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'DisplayVersion'
    $caps = Get-PowerCapabilities
    $hasBattery = $false
    try { $hasBattery = @(Get-CimInstance Win32_Battery -ErrorAction Stop).Count -gt 0 } catch { }
    $osName = "$($os.Caption)".Trim() -replace '^Microsoft\s+', ''
    if ([int]$os.BuildNumber -ge 22000) { $osName = $osName -replace 'Windows 10', 'Windows 11' }
    [pscustomobject]@{
        Manufacturer = "$($cs.Manufacturer)".Trim()
        Model        = "$($cs.Model)".Trim()
        OS           = (@($osName, $display) | Where-Object { $_ }) -join ' '
        Build        = [int]$os.BuildNumber
        Cpu          = ("$($cpu.Name)" -replace '\(R\)|\(TM\)|CPU', '' -replace '\s+', ' ').Trim()
        RamGB        = [int][Math]::Round($cs.TotalPhysicalMemory / 1GB)
        IsLaptop     = $hasBattery -or ($caps -and ($caps.BatteriesPresent -or $caps.LidPresent))
        IsVirtual    = "$($cs.Model) $($cs.Manufacturer)" -match 'Virtual|VMware|KVM|QEMU|Xen|HVM domU|Parallels'
        LastBoot     = $os.LastBootUpTime
    }
}

function Get-CachedPcInfo {
    if (-not $script:PcInfo) { $script:PcInfo = Get-PcInfo }
    $script:PcInfo
}

#endregion

#region Energía: lectura y cambios

$script:PowerGuids = @{
    SubSleep        = '238c9fa8-0aad-41ed-83f4-97be242c8f20'
    StandbyIdle     = '29f6c1db-86da-48c5-9fdb-f2b67b1f44da'
    HibernateIdle   = '9d7815a6-7ee4-497e-8888-515a05f02364'
    RtcWake         = 'bd3b718a-0680-4d9d-8ab2-e1d2b4ac806d'
    SubButtons      = '4f971e89-eebd-4455-a8de-9e59040e7347'
    LidAction       = '5ca83367-6e45-459f-a27b-476b1d01c936'
    SubProcessor    = '54533251-82be-4824-96c1-47b60b740d00'
    ProcThrottleMax = 'bc5038f7-23e0-4960-96da-33abaf5935ec'
    Balanced        = '381b4222-f694-41f0-9685-ff5bb260df2e'
    HighPerformance = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    Ultimate        = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
    PowerSaver      = 'a1841308-3541-4fab-bc81-f71556f20b4a'
}

function Get-PowerCapabilities {
    Initialize-Types
    $b = [DiagnosticoPC.Power]::Capabilities()
    if (-not $b) { return $null }
    [pscustomobject]@{
        LidPresent       = $b[2] -ne 0
        S3               = $b[5] -ne 0
        S4               = $b[6] -ne 0
        HiberFilePresent = $b[8] -ne 0
        AoAc             = $b[20] -ne 0
        HiberFileType    = [int]$b[22]
        BatteriesPresent = $b[30] -ne 0
    }
}

function Get-PowerValue([string]$Sub, [string]$Setting) {
    Initialize-Types
    [pscustomobject]@{
        Ac = [DiagnosticoPC.Power]::Read($Sub, $Setting, $true)
        Dc = [DiagnosticoPC.Power]::Read($Sub, $Setting, $false)
    }
}

# Cambia un ajuste del plan de energía activo. Devuelve cómo deshacerlo.
function Set-PowerValue([string]$Sub, [string]$Setting, $Ac = $null, $Dc = $null) {
    $old = Get-PowerValue $Sub $Setting
    if ($null -ne $Ac) { [void](Invoke-PowerCfg @('/setacvalueindex', 'SCHEME_CURRENT', $Sub, $Setting, "$Ac")) }
    if ($null -ne $Dc) { [void](Invoke-PowerCfg @('/setdcvalueindex', 'SCHEME_CURRENT', $Sub, $Setting, "$Dc")) }
    [void](Invoke-PowerCfg @('/setactive', 'SCHEME_CURRENT'))
    @{ T = 'power'; Sub = $Sub; Setting = $Setting
       Ac = $(if ($null -ne $Ac -and $old.Ac -ge 0) { $old.Ac } else { $null })
       Dc = $(if ($null -ne $Dc -and $old.Dc -ge 0) { $old.Dc } else { $null }) }
}

function Get-ActivePlan {
    Initialize-Types
    $guid = "$([DiagnosticoPC.Power]::ActiveScheme())"
    $name = ''
    try {
        $out = Invoke-PowerCfg @('/getactivescheme')
        if ($out -match '\(([^)]+)\)\s*\*?\s*$') { $name = $Matches[1].Trim() }
    } catch { }
    [pscustomobject]@{ Guid = $guid; Name = $name }
}

#endregion

#region Revisiones: energía, hibernación y temperatura

$script:OpenPowerAdvanced = 'control.exe|powercfg.cpl,,3'
$script:OpenPowerButtons  = 'control.exe|/name Microsoft.PowerOptions /page pageGlobalSettings'
$script:CmdAdminPath      = 'Inicio → escribe «cmd» → clic derecho en «Símbolo del sistema» → Ejecutar como administrador → Sí'

function Get-HibernationSteps {
    @(
        New-Step -Title 'Activa la hibernación' -Path $script:CmdAdminPath -Command 'powercfg /hibernate on' `
            -Text 'Abre el Símbolo del sistema como administrador, escribe el comando de abajo y presiona Enter. Si no aparece ningún error, quedó activada.' `
            -Button 'Hacerlo por mí' -Fix 'activar-hibernacion'
        New-Step -Title 'Elige cuándo debe hibernar' -Path 'Panel de control → Opciones de energía → Cambiar la configuración del plan → Cambiar la configuración avanzada de energía' `
            -Text 'En la ventana «Opciones de energía» despliega «Suspender» y luego «Hibernar tras». En «Con batería» escribe 60 (minutos) y en «Con corriente alterna» escribe 180. Presiona «Aceptar».' `
            -Button 'Abrir la configuración avanzada' -Open $script:OpenPowerAdvanced
        New-Step -Title 'Agrega «Hibernar» al menú de apagado' -Path 'Panel de control → Opciones de energía → Elegir el comportamiento de los botones de inicio/apagado' `
            -Text 'Presiona «Cambiar la configuración actualmente no disponible», marca la casilla «Hibernar» y presiona «Guardar cambios».' `
            -Button 'Abrir esa ventana' -Open $script:OpenPowerButtons
        New-Step -Title 'Úsala antes de guardar la laptop' `
            -Text 'Antes de meter la laptop en la mochila usa Inicio → botón de apagado → «Hibernar» (o «Apagar»). Si solo cierras la tapa, la PC se suspenderá y, pasado el tiempo que elegiste, se hibernará sola y dejará de calentarse.'
    )
}

function Test-Hibernation {
    $pc = Get-CachedPcInfo
    $caps = Get-PowerCapabilities
    $g = $script:PowerGuids
    $hib = Get-PowerValue $g.SubSleep $g.HibernateIdle
    $available = $caps -and $caps.S4 -and $caps.HiberFilePresent
    $modern = $caps -and $caps.AoAc
    $steps = Get-HibernationSteps
    $info = if ($modern) {
        'Este equipo usa la «Espera moderna»: mientras duerme, la PC sigue encendida por dentro (revisa correos, actualizaciones y notificaciones), igual que un teléfono.'
    } else {
        'Este equipo usa la suspensión clásica: mientras duerme, mantiene la memoria encendida con poca energía.'
    }

    if (-not $pc.IsLaptop) {
        $txt = if ($available) { 'La hibernación está disponible.' } else { 'La hibernación está desactivada, pero en una PC de escritorio no hace falta.' }
        return New-Finding -Id 'hibernacion' -Area 'Energía' -Level Verde -Title 'Suspensión e hibernación' `
            -Summary 'PC de escritorio: no hay riesgo de que se caliente en una mochila' -Detail "$txt $info" -Steps $steps
    }
    $why = 'Si la guardas así en la mochila puede seguir trabajando, calentarse mucho y gastar la batería. ' +
        'Con la hibernación, Windows guarda todo lo que tenías abierto y apaga la PC por completo después de un rato en suspensión; al encenderla, todo vuelve a aparecer como lo dejaste.'
    if (-not $available) {
        return New-Finding -Id 'hibernacion' -Area 'Energía' -Level Rojo -Title 'La hibernación está desactivada' `
            -Summary 'La PC no se apaga de verdad al cerrar la tapa' `
            -Detail "Cuando cierras la tapa, la PC queda suspendida, pero nunca pasa a hibernar. $info`n`n$why" `
            -Steps $steps -Fix 'activar-hibernacion' -FixText 'Activar la hibernación'
    }
    $dc = [int]$hib.Dc
    if ($dc -le 0) {
        $level = if ($modern) { 'Rojo' } else { 'Amarillo' }
        return New-Finding -Id 'hibernacion' -Area 'Energía' -Level $level -Title 'Con batería, la PC nunca pasa a hibernar' `
            -Summary 'Suspendida puede quedarse encendida por dentro durante horas' `
            -Detail "La hibernación está activada, pero el ajuste «Hibernar tras» dice «Nunca». $info`n`n$why" `
            -Steps $steps -Fix 'activar-hibernacion' -FixText 'Hibernar después de 1 hora'
    }
    if ($dc -gt 3 * 3600) {
        return New-Finding -Id 'hibernacion' -Area 'Energía' -Level Amarillo -Title "Con batería tarda $(Format-Minutes $dc) en hibernar" `
            -Summary 'Mientras tanto la PC puede calentarse y gastar batería' `
            -Detail "La hibernación funciona, pero la PC pasa mucho tiempo suspendida antes de hibernar. $info`n`nLo recomendable con batería es 1 hora." `
            -Steps $steps -Fix 'activar-hibernacion' -FixText 'Hibernar después de 1 hora'
    }
    New-Finding -Id 'hibernacion' -Area 'Energía' -Level Verde -Title 'La hibernación funciona bien' `
        -Summary "Con batería hiberna después de $(Format-Minutes $dc) en suspensión" `
        -Detail "Cuando la PC queda suspendida con batería, después de $(Format-Minutes $dc) Windows guarda todo y la apaga por completo. $info" -Steps $steps
}

function Test-LidAction {
    $pc = Get-CachedPcInfo
    $caps = Get-PowerCapabilities
    if (-not $pc.IsLaptop -or -not ($caps -and $caps.LidPresent)) { return }
    $g = $script:PowerGuids
    $v = Get-PowerValue $g.SubButtons $g.LidAction
    if ($v.Dc -lt 0) { return }
    $names = @('no hacer nada', 'suspender', 'hibernar', 'apagar')
    $nameOf = { param($x) if ($x -ge 0 -and $x -lt $names.Count) { $names[[int]$x] } else { 'otra acción' } }
    $steps = @(
        New-Step -Title 'Abre las opciones de la tapa' -Path 'Panel de control → Opciones de energía → Elegir el comportamiento del cierre de la tapa' `
            -Text 'Se abre la ventana «Configuración del sistema».' -Button 'Abrir esa ventana' -Open $script:OpenPowerButtons
        New-Step -Title 'Elige «Suspender» con batería' `
            -Text 'En la fila «Al cerrar la tapa», columna «Con batería», elige «Suspender» (o «Hibernar»). Presiona «Guardar cambios».' `
            -Button 'Hacerlo por mí' -Fix 'tapa'
    )
    if ($v.Dc -eq 0) {
        return New-Finding -Id 'tapa' -Area 'Energía' -Level Amarillo -Title 'Al cerrar la tapa no pasa nada' `
            -Summary 'Con batería, la PC sigue encendida con la tapa cerrada' `
            -Detail 'Con batería, al cerrar la tapa la PC sigue funcionando como si estuviera abierta. Si la guardas así en la mochila, se calienta y se queda sin batería.' `
            -Steps $steps -Fix 'tapa' -FixText 'Suspender al cerrar la tapa'
    }
    New-Finding -Id 'tapa' -Area 'Energía' -Level Verde -Title "Al cerrar la tapa: $(& $nameOf $v.Dc)" `
        -Summary "Con batería: $(& $nameOf $v.Dc) · Con cargador: $(& $nameOf $v.Ac)" `
        -Detail 'Al cerrar la tapa, la PC deja de funcionar como si estuviera abierta.' -Steps $steps
}

# Lee "powercfg /requests": qué programas, drivers o servicios piden que la PC no se suspenda
function Get-PowerRequests {
    $out = Invoke-PowerCfg @('/requests')
    $section = ''
    $last = $null
    $list = @()
    foreach ($raw in $out -split "`r?`n") {
        $line = $raw.Trim()
        if (-not $line) { continue }
        if ($line -cmatch '^([A-ZÁÉÍÓÚÑ]+):$') { $section = $Matches[1]; $last = $null; continue }
        if ($line -match '^\[([^\]]+)\]\s+(.+)$') {
            $last = [pscustomobject]@{ Section = $section; Type = $Matches[1].ToUpper(); Name = $Matches[2].Trim(); Reason = '' }
            $list += $last
            continue
        }
        if ($last -and -not $last.Reason) { $last.Reason = $line }
    }
    $list
}

function Test-SleepBlockers {
    $display = 'DISPLAY', 'PANTALLA'
    $reqs = @(Get-PowerRequests | Where-Object { $_.Section -notin 'PERFBOOST', 'ACTIVELOCKSCREEN' })
    $blocking = @($reqs | Where-Object { $_.Section -notin $display })
    $steps = @(
        New-Step -Title 'Mira qué lo impide' `
            -Text 'La lista de esta revisión muestra lo que ahora mismo no deja dormir a la PC. Suele ser el navegador con un video o música, una videollamada, una descarga, una impresión o un programa de sincronización.'
        New-Step -Title 'Cierra o pausa ese programa' `
            -Text 'Usa el botón «Cerrar» de la lista o ciérralo tú. Si es un video o música en el navegador, basta con pausarlo.'
        New-Step -Title 'Si pasa siempre con el mismo programa' -Path $script:CmdAdminPath `
            -Command 'powercfg /requestsoverride PROCESS chrome.exe SYSTEM AWAYMODE EXECUTION' `
            -Text 'Presiona «Que no impida suspender» en la lista: Windows ignorará sus pedidos de mantener la PC despierta. Equivale a escribir este comando como administrador (cambia chrome.exe por el programa):'
        New-Step -Title 'Compruébalo tú mismo' -Path $script:CmdAdminPath -Command 'powercfg /requests' `
            -Text 'Este comando muestra la lista actualizada. Si debajo de SYSTEM dice «Ninguno», nada impide la suspensión.'
    )
    $items = @()
    foreach ($grp in $reqs | Group-Object Name) {
        $r = $grp.Group[0]
        $isDisplayOnly = -not ($grp.Group | Where-Object { $_.Section -notin $display })
        $what = if ($isDisplayOnly) { 'Mantiene la pantalla encendida' } else { 'No deja que la PC se suspenda' }
        $detail = if ($r.Reason) { "$what · $($r.Reason)" } else { $what }
        $leaf = if ($r.Name -match '\\') { Split-Path $r.Name -Leaf } else { $r.Name }
        if ($leaf -match '\.exe$') {
            $items += New-FindingItem -Name $leaf -Detail $detail -Action 'cerrar-programa' -ActionText 'Cerrar' `
                -Action2 'ignorar-bloqueo' -Action2Text 'Que no impida suspender' `
                -Arg @{ Type = 'PROCESS'; Name = $leaf; Process = [IO.Path]::GetFileNameWithoutExtension($leaf) }
        } else {
            $type = if ($r.Type -match 'SERV') { 'SERVICE' } else { 'DRIVER' }
            $kind = if ($type -eq 'SERVICE') { 'Servicio' } else { 'Driver' }
            $items += New-FindingItem -Name "$kind`: $($r.Name)" -Detail $detail -Action2 'ignorar-bloqueo' -Action2Text 'Que no impida suspender' `
                -Arg @{ Type = $type; Name = $r.Name }
        }
    }
    if ($blocking.Count) {
        $n = @($blocking | Group-Object Name).Count
        return New-Finding -Id 'bloqueos-suspension' -Area 'Energía' -Level Amarillo `
            -Title "$(Get-Plural $n 'programa no deja' 'programas no dejan') suspender la PC" `
            -Summary (Limit-Text (($blocking | ForEach-Object { if ($_.Name -match '\\') { Split-Path $_.Name -Leaf } else { $_.Name } } | Select-Object -Unique) -join ', ') 90) `
            -Detail 'Ahora mismo hay programas o drivers que le piden a Windows que no se suspenda. Mientras sigan así, aunque cierres la tapa o dejes la PC sin usar, puede quedarse despierta, calentarse y gastar batería. Es normal mientras ves un video o descargas algo, pero no si ya no los estás usando.' `
            -Steps $steps -Items $items
    }
    $summary = if ($items.Count) { "Solo $(Get-Plural $items.Count 'programa mantiene' 'programas mantienen') la pantalla encendida" } else { 'Ahora mismo nada mantiene despierta la PC' }
    New-Finding -Id 'bloqueos-suspension' -Area 'Energía' -Level Verde -Title 'Nada impide la suspensión' -Summary $summary `
        -Detail 'Ningún programa ni driver le pide a Windows que la PC siga despierta. (Mantener la pantalla encendida mientras ves un video es normal.)' `
        -Steps $steps -Items $items
}

function Test-WakeSources {
    $pc = Get-CachedPcInfo
    $g = $script:PowerGuids
    $timers = Get-PowerValue $g.SubSleep $g.RtcWake
    $events = Get-Events @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Power-Troubleshooter'; Id = 1; StartTime = (Get-Date).AddDays(-7) } 200
    $night = @($events | Where-Object { $_.TimeCreated.Hour -lt 6 })
    $armed = @()
    try {
        $armed = @((Invoke-PowerCfg @('/devicequery', 'wake_armed')) -split "`r?`n" | ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and $_ -cnotmatch '^[A-ZÁÉÍÓÚÑ]+\.?$' })
    } catch { }
    $items = @()
    foreach ($e in $night | Select-Object -First 5) {
        $source = @("$($e.Message)" -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) | Select-Object -Last 1
        $items += New-FindingItem -Name "Se despertó sola el $(Format-Date $e.TimeCreated)" -Detail $source
    }
    foreach ($d in $armed) {
        $items += New-FindingItem -Name $d -Detail 'Tiene permiso para despertar a la PC' -Action 'quitar-despertar' -ActionText 'Que no la despierte' -Arg $d
    }
    $steps = @(
        New-Step -Title 'Apaga los temporizadores de reactivación' -Path 'Panel de control → Opciones de energía → Configuración avanzada → Suspender → Permitir temporizadores de reactivación' `
            -Text 'En «Con batería» elige «Deshabilitar». En «Con corriente alterna» elige «Solo temporizadores de reactivación importantes». Presiona «Aceptar». Así Windows Update y otras tareas no encienden la PC en la mochila.' `
            -Button 'Hacerlo por mí' -Fix 'despertares'
        New-Step -Title 'Que el mouse o la red no la despierten' -Path 'Inicio → clic derecho → Administrador de dispositivos' `
            -Text 'Busca el dispositivo (por ejemplo, el mouse o el adaptador de red), haz doble clic, ve a la pestaña «Administración de energía» y desmarca «Permitir que este dispositivo reactive el equipo». También puedes usar el botón «Que no la despierte» de la lista.' `
            -Button 'Abrir el Administrador de dispositivos' -Open 'devmgmt.msc'
        New-Step -Title 'Revisa qué la despertó la última vez' -Path $script:CmdAdminPath -Command 'powercfg /lastwake' `
            -Text 'Este comando dice qué despertó a la PC la última vez.'
    )
    $fixArgs = @{ Steps = $steps; Items = $items; Fix = 'despertares'; FixText = 'Que nada la despierte con batería' }
    if ($night.Count -ge 2 -or ($night.Count -ge 1 -and $pc.IsLaptop)) {
        return New-Finding -Id 'despertares' -Area 'Energía' -Level Amarillo `
            -Title "La PC se despertó sola $(Get-Plural $night.Count 'vez' 'veces') de madrugada" `
            -Summary 'Algo la enciende mientras debería estar dormida' `
            -Detail 'En los últimos 7 días la PC salió de la suspensión sola entre la medianoche y las 6 de la mañana. Si estaba en una mochila o en un lugar cerrado, pudo calentarse. Suelen despertarla Windows Update (temporizadores de reactivación), el mouse, el teclado o el adaptador de red.' `
            @fixArgs
    }
    if ($pc.IsLaptop -and $timers.Dc -eq 1) {
        return New-Finding -Id 'despertares' -Area 'Energía' -Level Amarillo -Title 'Los programas pueden despertar la PC con batería' `
            -Summary 'Windows Update y otras tareas pueden encenderla en la mochila' `
            -Detail 'Los «temporizadores de reactivación» están permitidos con batería: Windows Update, el antivirus u otras tareas programadas pueden despertar la PC mientras está suspendida, aunque esté guardada.' `
            @fixArgs
    }
    $fixArgs.Fix = $null
    $fixArgs.FixText = $null
    New-Finding -Id 'despertares' -Area 'Energía' -Level Verde -Title 'La PC no se despierta sola' `
        -Summary "$(Get-Plural $events.Count 'reactivación' 'reactivaciones') en 7 días, ninguna de madrugada" `
        -Detail 'En los últimos 7 días la PC no salió sola de la suspensión durante la madrugada.' @fixArgs
}

function Test-PowerPlan {
    $pc = Get-CachedPcInfo
    $plan = Get-ActivePlan
    $g = $script:PowerGuids
    $name = if ($plan.Name) { $plan.Name } else { 'personalizado' }
    $steps = @(
        New-Step -Title 'Elige el plan Equilibrado' -Path 'Panel de control → Opciones de energía' `
            -Text 'Marca «Equilibrado (recomendado)». Si no aparece, despliega «Mostrar planes adicionales».' `
            -Button 'Hacerlo por mí' -Fix 'plan-equilibrado'
        New-Step -Title 'En Windows 11, revisa el modo de energía' -Path 'Configuración → Sistema → Energía y batería → Modo de energía' `
            -Text 'Elige «Equilibrado», o «Mejor eficiencia energética» cuando uses la batería.' -Button 'Abrir Energía y batería' -Open 'ms-settings:powersleep'
    )
    if ($pc.IsLaptop -and $plan.Guid -in $g.HighPerformance, $g.Ultimate) {
        return New-Finding -Id 'plan-energia' -Area 'Energía' -Level Amarillo -Title "Plan de energía: $name" `
            -Summary 'Más calor y menos batería de lo necesario' `
            -Detail 'Este plan mantiene el procesador siempre a toda velocidad, aunque no lo necesites. En una laptop eso significa más calor, el ventilador más tiempo encendido y menos horas de batería. El plan «Equilibrado» acelera solo cuando hace falta.' `
            -Steps $steps -Fix 'plan-equilibrado' -FixText 'Cambiar a Equilibrado'
    }
    $summary = switch ($plan.Guid) {
        $g.Balanced   { 'Es el plan recomendado' }
        $g.PowerSaver { 'Gasta poca energía (la PC puede ir más lenta)' }
        default       { 'Sin problemas' }
    }
    New-Finding -Id 'plan-energia' -Area 'Energía' -Level Verde -Title "Plan de energía: $name" -Summary $summary `
        -Detail 'El plan de energía decide qué tan rápido trabaja el procesador y cuándo se apaga la pantalla.' -Steps $steps
}

function Test-FastStartup {
    $v = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled'
    $caps = Get-PowerCapabilities
    $enabled = ($v -eq 1) -and $caps -and $caps.HiberFilePresent
    $steps = @(
        New-Step -Title 'Abre las opciones de los botones de encendido' -Path 'Panel de control → Opciones de energía → Elegir el comportamiento de los botones de inicio/apagado' `
            -Text 'Se abre la ventana «Configuración del sistema».' -Button 'Abrir esa ventana' -Open $script:OpenPowerButtons
        New-Step -Title 'Desmarca «Activar inicio rápido»' `
            -Text 'Presiona «Cambiar la configuración actualmente no disponible», desmarca «Activar inicio rápido (recomendado)» y presiona «Guardar cambios».' `
            -Button 'Hacerlo por mí' -Fix 'desactivar-inicio-rapido'
        New-Step -Title 'Reinicia la PC' -Text 'Desde ahora, «Apagar» apaga la PC por completo y cada encendido empieza de cero. Encender tardará unos segundos más.'
    )
    if ($enabled) {
        return New-Finding -Id 'inicio-rapido' -Area 'Registro' -Level Verde -Title 'El inicio rápido está activado' `
            -Summary 'Al apagar, Windows no se reinicia del todo' `
            -Detail 'Con el inicio rápido, «Apagar» guarda el estado de Windows y de los drivers en el disco para encender más rápido. Funciona bien en la mayoría de las PC, pero si hay pantallas azules, apagones o drivers con fallas, conviene desactivarlo para que cada encendido empiece de cero. (Es el valor HiberbootEnabled del registro.)' `
            -Steps $steps -Fix 'desactivar-inicio-rapido' -FixText 'Desactivar el inicio rápido' -Data @{ Enabled = $true }
    }
    New-Finding -Id 'inicio-rapido' -Area 'Registro' -Level Verde -Title 'El inicio rápido está desactivado' `
        -Summary 'Cada encendido empieza de cero' -Detail 'Al apagar, Windows y los drivers se cierran por completo.' -Data @{ Enabled = $false }
}

function Get-Temperatures {
    $temps = @()
    try {
        foreach ($z in Get-CimInstance Win32_PerfFormattedData_Counters_ThermalZoneInformation -ErrorAction Stop) {
            $k = if ($z.HighPrecisionTemperature) { $z.HighPrecisionTemperature / 10 } else { $z.Temperature }
            if ($k -gt 0) { $temps += [Math]::Round($k - 273.15) }
        }
    } catch { }
    if (-not $temps.Count) {
        try {
            foreach ($z in Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop) {
                if ($z.CurrentTemperature -gt 0) { $temps += [Math]::Round($z.CurrentTemperature / 10 - 273.15) }
            }
        } catch { }
    }
    # Algunos equipos informan valores fijos o imposibles
    @($temps | Where-Object { $_ -gt 10 -and $_ -lt 120 })
}

function Test-Temperature {
    $temps = Get-Temperatures
    $max = if ($temps.Count) { ($temps | Measure-Object -Maximum).Maximum } else { $null }
    $throttle = Get-Events @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Processor-Power'; Id = 37; StartTime = (Get-Date).AddDays(-7) } 300
    $steps = @(
        New-Step -Title 'Limpia las rejillas de ventilación' `
            -Text 'Con la PC apagada y desenchufada, sopla las rejillas con aire comprimido (en ráfagas cortas). El polvo acumulado es la causa más común del calor. Si la laptop tiene varios años, un técnico puede cambiar la pasta térmica.'
        New-Step -Title 'Úsala sobre una superficie dura' `
            -Text 'Sobre la cama, un cojín o las piernas se tapan las entradas de aire. Usa una mesa o una base con ventilador.'
        New-Step -Title 'Cierra lo que consume mucho' `
            -Text 'Revisa en esta app «Programas que usan el procesador» y «Programas que arrancan con Windows», y cierra lo que no uses.'
        New-Step -Title 'Limita el procesador al 99 % (apaga el «Turbo»)' -Path 'Panel de control → Opciones de energía → Configuración avanzada → Administración de energía del procesador → Estado máximo del procesador' `
            -Text 'Escribe 99 en «Con batería» y en «Con corriente alterna», y presiona «Aceptar». El procesador deja de acelerar al máximo: la PC se calienta mucho menos y casi no se nota la diferencia de velocidad.' `
            -Button 'Hacerlo por mí' -Fix 'bajar-temperatura'
        New-Step -Title 'Actualiza el BIOS y los drivers del fabricante' `
            -Text 'Los fabricantes corrigen el control de los ventiladores con actualizaciones del BIOS. Búscalas en la página de soporte de tu marca con el modelo de tu PC.' `
            -Button 'Abrir la página del fabricante' -Open (Get-SupportUrl)
    )
    $parts = @()
    if ($null -ne $max) { $parts += "La temperatura más alta que informa el equipo es de $max °C (sensor interno de la placa)." }
    else { $parts += 'Este equipo no informa su temperatura a Windows, así que se revisa si el procesador tuvo que frenar por calor.' }
    if ($throttle.Count) { $parts += "En los últimos 7 días, Windows registró $(Get-Plural $throttle.Count 'vez' 'veces') que el procesador tuvo que bajar su velocidad (por calor o por límite de energía del fabricante)." }
    $detail = ($parts -join ' ') + "`n`nEl calor hace que la PC vaya lenta, que el ventilador suene fuerte y, con el tiempo, daña la batería y otros componentes."

    $level = 'Verde'
    if (($null -ne $max -and $max -ge 90)) { $level = 'Rojo' }
    elseif (($null -ne $max -and $max -ge 80) -or $throttle.Count -ge 10) { $level = 'Amarillo' }
    switch ($level) {
        'Rojo' {
            New-Finding -Id 'temperatura' -Area 'Temperatura' -Level Rojo -Title "La PC está muy caliente: $max °C" `
                -Summary 'Puede apagarse sola o dañarse' -Detail $detail -Steps $steps -Fix 'bajar-temperatura' -FixText 'Bajar la temperatura'
        }
        'Amarillo' {
            $title = if ($null -ne $max -and $max -ge 80) { "La PC está caliente: $max °C" } else { 'El procesador tuvo que frenar varias veces' }
            New-Finding -Id 'temperatura' -Area 'Temperatura' -Level Amarillo -Title $title `
                -Summary 'Conviene bajar la temperatura' -Detail $detail -Steps $steps -Fix 'bajar-temperatura' -FixText 'Bajar la temperatura'
        }
        default {
            $title = if ($null -ne $max) { "Temperatura normal: $max °C" } else { 'Sin señales de calor excesivo' }
            New-Finding -Id 'temperatura' -Area 'Temperatura' -Level Verde -Title $title `
                -Summary 'El procesador no tuvo que frenar por calor' -Detail $detail -Steps $steps
        }
    }
}

function Test-Uptime {
    $pc = Get-CachedPcInfo
    $days = [int][Math]::Floor(((Get-Date) - $pc.LastBoot).TotalDays)
    $pending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
    $steps = @(
        New-Step -Title 'Guarda tu trabajo' -Text 'Guarda los documentos abiertos y cierra los programas.'
        New-Step -Title 'Usa «Reiniciar», no «Apagar»' -Path 'Inicio → botón de apagado → Reiniciar' `
            -Text 'Con el inicio rápido activado, «Apagar» no reinicia Windows por completo. «Reiniciar» sí: cierra todo, termina las actualizaciones y vuelve a cargar los drivers desde cero.' `
            -Button 'Reiniciar ahora' -Fix 'reiniciar'
    )
    $since = "Último reinicio completo: $(Format-Date $pc.LastBoot)."
    if ($pending) {
        return New-Finding -Id 'reinicio' -Area 'Sistema' -Level Amarillo -Title 'Windows espera un reinicio' `
            -Summary 'Hay actualizaciones a medio instalar' `
            -Detail "Windows instaló actualizaciones que se terminan de aplicar al reiniciar. Mientras tanto la PC puede ir más lenta o fallar. $since" `
            -Steps $steps -Fix 'reiniciar' -FixText 'Reiniciar ahora'
    }
    if ($days -ge 14) {
        return New-Finding -Id 'reinicio' -Area 'Sistema' -Level Amarillo -Title "No se ha reiniciado en $days días" `
            -Summary 'Reiniciar de vez en cuando libera memoria y aplica arreglos' `
            -Detail "Windows funciona mejor si se reinicia al menos una vez por semana: se libera la memoria, se cierran programas colgados y se terminan las actualizaciones. $since" `
            -Steps $steps -Fix 'reiniciar' -FixText 'Reiniciar ahora'
    }
    $txt = if ($days -eq 0) { 'Se reinició hoy' } else { "Se reinició hace $(Get-Plural $days 'día' 'días')" }
    New-Finding -Id 'reinicio' -Area 'Sistema' -Level Verde -Title 'Reinicios al día' -Summary $txt -Detail "No hay actualizaciones esperando un reinicio. $since" -Steps $steps
}

#endregion

#region Revisiones: programas, memoria y arranque

# Procesos de Windows que la app nunca ofrece cerrar
$script:ProtectedProcesses = @(
    'System', 'Idle', 'Registry', 'smss', 'csrss', 'wininit', 'winlogon', 'services', 'lsass', 'LsaIso', 'svchost',
    'dwm', 'explorer', 'fontdrvhost', 'sihost', 'ctfmon', 'MsMpEng', 'NisSrv', 'SecurityHealthService', 'Memory Compression',
    'MemCompression', 'audiodg', 'spoolsv', 'conhost', 'dllhost', 'RuntimeBroker', 'taskhostw', 'WmiPrvSE', 'SearchIndexer',
    'SearchHost', 'StartMenuExperienceHost', 'ShellExperienceHost', 'TextInputHost', 'Secure System', 'powershell', 'DiagnosticoPC'
)

function Test-ProtectedProcess([string]$Name, [string]$Path) {
    if ($script:ProtectedProcesses -contains $Name) { return $true }
    if (-not $Path) { return $true }
    $Path.StartsWith($env:SystemRoot, [StringComparison]::OrdinalIgnoreCase)
}

function Get-ProcessLabel($Group) {
    $exe = "$($Group.Name).exe"
    if ($Group.Description -and $Group.Description -ne $Group.Name) { return "$($Group.Description) ($exe)" }
    $exe
}

# Mide durante unos segundos cuánto procesador usa cada programa (agrupado por nombre: chrome = todas sus pestañas)
function Get-CpuSample([int]$Milliseconds = 3000) {
    $first = @{}
    foreach ($p in Get-Process) { try { $first[$p.Id] = $p.TotalProcessorTime.TotalMilliseconds } catch { } }
    $t0 = [DateTime]::UtcNow
    Start-Sleep -Milliseconds $Milliseconds
    $elapsed = ([DateTime]::UtcNow - $t0).TotalMilliseconds * [Environment]::ProcessorCount
    Get-CpuGroups $first $elapsed
}

function Get-CpuGroups([hashtable]$Before, [double]$ElapsedCpuMs) {
    $groups = @{}
    foreach ($p in Get-Process) {
        if ($p.Id -eq 0 -or $p.Id -eq $PID -or -not $Before.ContainsKey($p.Id)) { continue }
        try { $ms = $p.TotalProcessorTime.TotalMilliseconds } catch { continue }
        $grp = $groups[$p.ProcessName]
        if (-not $grp) {
            $grp = [pscustomobject]@{ Name = $p.ProcessName; Cpu = 0.0; Count = 0; Path = $null; Description = $null }
            $groups[$p.ProcessName] = $grp
        }
        $grp.Cpu += [Math]::Max([double]0, [double]($ms - $Before[$p.Id]))
        $grp.Count++
        if (-not $grp.Path) { try { $grp.Path = $p.Path; $grp.Description = $p.Description } catch { } }
    }
    foreach ($grp in $groups.Values) { $grp.Cpu = [Math]::Round(100 * $grp.Cpu / [Math]::Max([double]1, [double]$ElapsedCpuMs), 1) }
    @($groups.Values | Sort-Object Cpu -Descending)
}

function Get-TaskManagerSteps([string]$Column) {
    @(
        New-Step -Title 'Abre el Administrador de tareas' -Path 'Presiona Ctrl + Shift + Esc' `
            -Text "En la pestaña «Procesos», haz clic en el encabezado «$Column» para ver arriba los que más consumen." `
            -Button 'Abrir el Administrador de tareas' -Open 'taskmgr.exe'
        New-Step -Title 'Cierra el programa' `
            -Text 'Guarda tu trabajo, selecciona el programa y presiona «Finalizar tarea». También puedes usar el botón «Cerrar» de la lista de esta app.'
        New-Step -Title 'Si vuelve a pasar' -Path 'Configuración → Aplicaciones → Aplicaciones instaladas' `
            -Text 'Si un programa consume mucho todo el tiempo, quítalo del arranque de Windows, actualízalo o desinstálalo. Si es «Antimalware Service Executable» (el antivirus) o «Windows Update», espera a que termine: es temporal.' `
            -Button 'Abrir Aplicaciones' -Open 'ms-settings:appsfeatures'
    )
}

function New-ProcessItem($Group, [string]$Detail) {
    $protected = Test-ProtectedProcess $Group.Name $Group.Path
    $label = Get-ProcessLabel $Group
    if ($Group.Count -gt 1) { $Detail += " · $($Group.Count) procesos" }
    if ($protected) {
        New-FindingItem -Name $label -Detail "$Detail · Es parte de Windows"
    } else {
        New-FindingItem -Name $label -Detail $Detail -Action 'cerrar-programa' -ActionText 'Cerrar' -Arg @{ Process = $Group.Name; Label = $label }
    }
}

function Test-CpuUsage {
    $sample = @(Get-CpuSample 3000)
    $total = [int][Math]::Min(100, [Math]::Round(($sample | Measure-Object Cpu -Sum).Sum))
    $top = @($sample | Where-Object { $_.Cpu -ge 3 } | Select-Object -First 5)
    $items = foreach ($grp in $top) { New-ProcessItem $grp "Usa el $([Math]::Round($grp.Cpu)) % del procesador" }
    $steps = Get-TaskManagerSteps 'CPU'
    $max = if ($top.Count) { $top[0].Cpu } else { 0 }
    $detail = "Uso total del procesador en este momento: $total %. Un programa que usa mucho procesador sin parar calienta la PC, hace sonar el ventilador y gasta la batería."
    if ($max -ge 25 -or $total -ge 85) {
        $level = if ($max -ge 50) { 'Rojo' } else { 'Amarillo' }
        $title = if ($top.Count) { "$(Get-ProcessLabel $top[0]) usa el $([Math]::Round($max)) % del procesador" } else { "El procesador está al $total %" }
        return New-Finding -Id 'procesos' -Area 'Programas' -Level $level -Title $title `
            -Summary 'Ciérralo si no lo estás usando' -Detail $detail -Steps $steps -Items $items
    }
    New-Finding -Id 'procesos' -Area 'Programas' -Level Verde -Title 'Ningún programa sobrecarga el procesador' `
        -Summary "Uso total en este momento: $total %" -Detail $detail -Steps $steps -Items $items
}

function Test-Memory {
    $pc = Get-CachedPcInfo
    $os = Get-CimInstance Win32_OperatingSystem
    $total = [double]$os.TotalVisibleMemorySize * 1KB
    $free = [double]$os.FreePhysicalMemory * 1KB
    $used = [int][Math]::Round(100 * ($total - $free) / $total)
    $groups = @{}
    foreach ($p in Get-Process) {
        if ($p.Id -eq 0 -or $p.Id -eq $PID) { continue }
        $grp = $groups[$p.ProcessName]
        if (-not $grp) {
            $grp = [pscustomobject]@{ Name = $p.ProcessName; Bytes = 0.0; Count = 0; Path = $null; Description = $null }
            $groups[$p.ProcessName] = $grp
        }
        $grp.Bytes += $p.WorkingSet64
        $grp.Count++
        if (-not $grp.Path) { try { $grp.Path = $p.Path; $grp.Description = $p.Description } catch { } }
    }
    $top = @($groups.Values | Where-Object { $_.Name -notin 'Memory Compression', 'MemCompression' } | Sort-Object Bytes -Descending | Select-Object -First 5)
    $items = foreach ($grp in $top) { New-ProcessItem $grp "Usa $(Format-Size $grp.Bytes) de memoria" }
    $steps = (Get-TaskManagerSteps 'Memoria') + @(
        New-Step -Title 'Si la memoria siempre está llena' `
            -Text "Esta PC tiene $($pc.RamGB) GB de memoria RAM. Con 8 GB o menos, abrir muchas pestañas del navegador la llena rápido: cierra las que no uses. Si siempre está llena, un técnico puede agregar más memoria."
    )
    $detail = "Se está usando el $used % de la memoria ($(Format-Size ($total - $free)) de $(Format-Size $total)). Cuando la memoria se llena, Windows usa el disco como memoria y todo se vuelve muy lento."
    if ($used -ge 80) {
        $level = if ($used -ge 90) { 'Rojo' } else { 'Amarillo' }
        return New-Finding -Id 'memoria' -Area 'Programas' -Level $level -Title "La memoria está al $used %" `
            -Summary 'La PC puede ponerse lenta o trabarse' -Detail $detail -Steps $steps -Items $items
    }
    New-Finding -Id 'memoria' -Area 'Programas' -Level Verde -Title "Memoria en uso: $used %" `
        -Summary "Hay memoria libre suficiente ($($pc.RamGB) GB en total)" -Detail $detail -Steps $steps -Items $items
}

function Get-CommandPath([string]$Command) {
    $c = [Environment]::ExpandEnvironmentVariables("$Command".Trim())
    $p = $null
    if ($c -match '^"([^"]+)"') { $p = $Matches[1] }
    elseif ($c -match '^(.+?\.(exe|com|bat|cmd|lnk|vbs))(\s|$)') { $p = $Matches[1] }
    else { $p = ($c -split '\s+')[0] }
    # Sin carpeta (rundll32, cmd...): está en Windows, no se revisa
    if ($p -notmatch '\\') { return $null }
    $p
}

# Programas que arrancan con Windows (claves Run y carpetas de Inicio), con su estado en StartupApproved,
# que es donde el Administrador de tareas guarda si están habilitados o no
function Get-StartupEntries {
    $approvedCU = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
    $approvedLM = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
    $sources = @(
        @{ Reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Approved = "$approvedCU\Run" }
        @{ Reg = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Approved = "$approvedLM\Run" }
        @{ Reg = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = "$approvedLM\Run32" }
        @{ Folder = [Environment]::GetFolderPath('Startup'); Approved = "$approvedCU\StartupFolder" }
        @{ Folder = [Environment]::GetFolderPath('CommonStartup'); Approved = "$approvedLM\StartupFolder" }
    )
    $shell = $null
    foreach ($src in $sources) {
        $entries = @()
        if ($src.Reg) {
            $key = Get-Item -LiteralPath $src.Reg -ErrorAction SilentlyContinue
            if (-not $key) { continue }
            foreach ($name in $key.GetValueNames()) {
                if ($name) { $entries += @{ Name = $name; Command = "$($key.GetValue($name))" } }
            }
        } elseif ($src.Folder -and (Test-Path -LiteralPath $src.Folder)) {
            foreach ($f in Get-ChildItem -LiteralPath $src.Folder -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' }) {
                $cmd = $f.FullName
                if ($f.Extension -eq '.lnk') {
                    try {
                        if (-not $shell) { $shell = New-Object -ComObject WScript.Shell }
                        $target = $shell.CreateShortcut($f.FullName).TargetPath
                        if ($target) { $cmd = "`"$target`"" }
                    } catch { }
                }
                $entries += @{ Name = $f.Name; Command = $cmd }
            }
        }
        foreach ($e in $entries) {
            $state = Get-RegValue $src.Approved $e.Name
            $enabled = (-not $state) -or ((([byte[]]$state)[0] % 2) -eq 0)
            $file = Get-CommandPath $e.Command
            $exists = if ($file) { Test-Path -LiteralPath $file } else { $true }
            $desc = $null
            if ($file -and $exists) { try { $desc = (Get-Item -LiteralPath $file).VersionInfo.FileDescription } catch { } }
            [pscustomobject]@{
                Name = $e.Name; Command = $e.Command; File = $file; Exists = $exists; Enabled = $enabled
                Approved = $src.Approved; Description = "$desc".Trim()
            }
        }
    }
}

function Test-StartupApps {
    $entries = @(Get-StartupEntries)
    $enabled = @($entries | Where-Object { $_.Enabled })
    $missing = @($enabled | Where-Object { -not $_.Exists })
    $items = @()
    foreach ($e in @($missing) + @($enabled | Where-Object { $_.Exists }) | Select-Object -First 30) {
        $detail = if (-not $e.Exists) { "El archivo ya no existe: $($e.File)" } elseif ($e.Description) { $e.Description } else { Limit-Text $e.Command 90 }
        if ($e.Name -match 'SecurityHealth|Windows Defender') {
            $items += New-FindingItem -Name $e.Name -Detail "$detail · Es la protección de Windows"
        } else {
            $items += New-FindingItem -Name $e.Name -Detail $detail -Action 'quitar-arranque' -ActionText 'Quitar del arranque' `
                -Arg @{ Name = $e.Name; Approved = $e.Approved }
        }
    }
    $steps = @(
        New-Step -Title 'Abre las aplicaciones de arranque' -Path 'Configuración → Aplicaciones → Inicio' `
            -Text 'Apaga el interruptor de los programas que no necesitas apenas enciendes la PC (por ejemplo Spotify, Steam, Discord, Teams o los ayudantes de impresoras). No se desinstalan: los puedes abrir cuando quieras.' `
            -Button 'Abrir Aplicaciones de arranque' -Open 'ms-settings:startupapps'
        New-Step -Title 'O desde el Administrador de tareas' -Path 'Ctrl + Shift + Esc → pestaña «Aplicaciones de arranque» (en Windows 10, «Inicio»)' `
            -Text 'Clic derecho en el programa → «Deshabilitar». La columna «Impacto de inicio» muestra cuánto retrasa cada uno el encendido.' `
            -Button 'Abrir el Administrador de tareas' -Open 'taskmgr.exe|/0 /startup'
        New-Step -Title 'Reinicia para comprobarlo' -Text 'La próxima vez que enciendas la PC, debería estar lista antes y con el ventilador más tranquilo.'
    )
    $detail = 'Cada programa que arranca con Windows hace que la PC tarde más en encender, ocupa memoria y procesador todo el tiempo y genera calor. Quítalos si no los usas a diario: no se desinstalan y puedes volver a activarlos cuando quieras.'
    if ($missing.Count) {
        return New-Finding -Id 'arranque' -Area 'Programas' -Level Amarillo `
            -Title "$(Get-Plural $missing.Count 'programa del arranque ya no existe' 'programas del arranque ya no existen')" `
            -Summary "Windows intenta abrir archivos que faltan · $($enabled.Count) programas arrancan con Windows" `
            -Detail "Hay programas configurados para arrancar con Windows cuyo archivo ya no está (por ejemplo, porque se desinstalaron mal). Windows los busca en cada encendido sin encontrarlos. $detail" `
            -Steps $steps -Items $items -Fix 'arranque-faltantes' -FixText 'Quitar los que ya no existen' `
            -FixArg @($missing | ForEach-Object { @{ Name = $_.Name; Approved = $_.Approved } })
    }
    if ($enabled.Count -ge 12) {
        return New-Finding -Id 'arranque' -Area 'Programas' -Level Amarillo -Title "$($enabled.Count) programas arrancan con Windows" `
            -Summary 'Son muchos: la PC tarda en encender y se calienta' -Detail $detail -Steps $steps -Items $items
    }
    New-Finding -Id 'arranque' -Area 'Programas' -Level Verde -Title "$(Get-Plural $enabled.Count 'programa arranca' 'programas arrancan') con Windows" `
        -Summary 'Una cantidad normal' -Detail $detail -Steps $steps -Items $items
}

#endregion

#region Revisiones: drivers

$script:DeviceCodes = @{
    1 = 'no está bien configurado'; 3 = 'su driver está dañado o falta memoria'; 10 = 'no puede iniciar'
    12 = 'no encuentra recursos libres'; 14 = 'necesita que reinicies la PC'; 18 = 'hay que reinstalar su driver'
    19 = 'su configuración en el registro está dañada'; 21 = 'Windows lo está quitando'; 22 = 'está desactivado'
    24 = 'no está presente o no funciona'; 28 = 'no tiene driver instalado'; 29 = 'está desactivado en el BIOS'
    31 = 'Windows no puede cargar su driver'; 32 = 'su servicio está desactivado'; 33 = 'no se pueden asignar sus recursos'
    34 = 'necesita configuración manual'; 35 = 'falta información en el BIOS'; 36 = 'tiene un conflicto de interrupciones'
    37 = 'su driver falló al iniciar'; 38 = 'una copia anterior del driver sigue en memoria'; 39 = 'su driver está dañado o falta'
    40 = 'su información en el registro está dañada'; 41 = 'Windows cargó el driver pero no encuentra el dispositivo'
    42 = 'está duplicado'; 43 = 'Windows lo detuvo porque informó problemas'; 44 = 'un programa lo apagó'
    47 = 'está preparado para quitarse'; 48 = 'su driver está bloqueado por incompatible'
    49 = 'el registro del sistema está demasiado grande'; 50 = 'no se pudieron aplicar sus propiedades'
    51 = 'espera a otro dispositivo'; 52 = 'su driver no tiene una firma digital válida'
}

function Get-SupportUrl {
    $pc = Get-CachedPcInfo
    $m = "$($pc.Manufacturer)"
    switch -Regex ($m) {
        '^HP|Hewlett'     { return 'https://support.hp.com/drivers' }
        'Lenovo'          { return 'https://pcsupport.lenovo.com' }
        'Dell'            { return 'https://www.dell.com/support/home' }
        'ASUS'            { return 'https://www.asus.com/support/download-center/' }
        'Acer'            { return 'https://www.acer.com/support' }
        'MSI|Micro-Star'  { return 'https://www.msi.com/support' }
        'Samsung'         { return 'https://www.samsung.com/support/' }
        'Huawei'          { return 'https://consumer.huawei.com/support/' }
        'Toshiba|Dynabook'{ return 'https://support.dynabook.com' }
        'Microsoft'       { return 'https://support.microsoft.com/surface' }
        'Gigabyte'        { return 'https://www.gigabyte.com/Support' }
    }
    'https://www.google.com/search?q=' + [uri]::EscapeDataString("$m $($pc.Model) drivers")
}

function Get-GpuUrl([string]$Vendor) {
    if ($Vendor -match 'NVIDIA') { return 'https://www.nvidia.com/Download/index.aspx' }
    if ($Vendor -match 'AMD|Advanced Micro|ATI') { return 'https://www.amd.com/en/support' }
    if ($Vendor -match 'Intel') { return 'https://www.intel.com/content/www/us/en/support/detect.html' }
    Get-SupportUrl
}

function Get-DriverSteps([string]$VendorUrl) {
    $pc = Get-CachedPcInfo
    $steps = @(
        New-Step -Title 'Busca drivers en Windows Update' -Path 'Configuración → Windows Update → Opciones avanzadas → Actualizaciones opcionales → Actualizaciones de controladores' `
            -Text 'Marca los drivers que aparezcan y presiona «Descargar e instalar». Reinicia la PC al terminar. Si no aparece nada, sigue con el paso siguiente.' `
            -Button 'Abrir Actualizaciones opcionales' -Open 'ms-settings:windowsupdate-optionalupdates'
        New-Step -Title 'Descárgalos de la página del fabricante' `
            -Text "Entra a la página de soporte de tu marca, escribe el modelo ($($pc.Manufacturer) $($pc.Model)) o el número de serie, y descarga los drivers de chipset, video, red y audio para tu versión de Windows." `
            -Button 'Abrir la página de soporte' -Open (Get-SupportUrl)
    )
    if ($VendorUrl) {
        $steps += New-Step -Title 'O del fabricante de la tarjeta de video' `
            -Text 'Intel, NVIDIA y AMD tienen una página que detecta tu tarjeta y ofrece el driver más reciente.' -Button 'Abrir la página de drivers de video' -Open $VendorUrl
    }
    $steps + @(
        New-Step -Title 'Reinstala el dispositivo' -Path 'Inicio → clic derecho → Administrador de dispositivos' `
            -Text 'Clic derecho en el dispositivo con el signo amarillo → «Desinstalar el dispositivo» → «Desinstalar». Después, en el menú «Acción», elige «Buscar cambios de hardware»: Windows lo vuelve a instalar.' `
            -Button 'Abrir el Administrador de dispositivos' -Open 'devmgmt.msc'
        New-Step -Title '¿Tienes un respaldo de RespaldoDrivers?' `
            -Text 'Si antes guardaste los drivers con la app RespaldoDrivers, ábrela y usa «Restaurar drivers»: instala de una vez todos los drivers guardados.'
    )
}

function Test-DeviceProblems {
    $devs = @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -ne 45 })
    $items = foreach ($d in $devs) {
        $code = [int]$d.ConfigManagerErrorCode
        $meaning = if ($script:DeviceCodes.ContainsKey($code)) { $script:DeviceCodes[$code] } else { 'tiene un problema' }
        $name = if ($d.Name) { $d.Name } else { 'Dispositivo desconocido' }
        $arg = @{ Id = $d.PNPDeviceID; Name = $name }
        $detail = "Código $code`: $meaning"
        switch ($code) {
            22 { New-FindingItem -Name $name -Detail $detail -Action 'habilitar-dispositivo' -ActionText 'Activar' -Arg $arg }
            14 { New-FindingItem -Name $name -Detail $detail }
            { $_ -in 10, 43, 3, 19, 41, 12, 38 } {
                New-FindingItem -Name $name -Detail $detail -Action 'reinstalar-dispositivo' -ActionText 'Reinstalar' -Action2 'buscar-driver' -Action2Text 'Buscar driver' -Arg $arg
            }
            default {
                New-FindingItem -Name $name -Detail $detail -Action 'buscar-driver' -ActionText 'Buscar driver' -Action2 'reinstalar-dispositivo' -Action2Text 'Reinstalar' -Arg $arg
            }
        }
    }
    $serious = @($devs | Where-Object { $_.ConfigManagerErrorCode -notin 22, 14 })
    $steps = Get-DriverSteps
    $names = Limit-Text ((@($devs | ForEach-Object { if ($_.Name) { $_.Name } else { 'Dispositivo desconocido' } }) | Select-Object -Unique) -join ', ') 90
    if ($serious.Count) {
        return New-Finding -Id 'drivers-error' -Area 'Drivers' -Level Rojo `
            -Title "$(Get-Plural $serious.Count 'dispositivo tiene' 'dispositivos tienen') problemas de driver" -Summary $names `
            -Detail 'Estos dispositivos aparecen con un signo amarillo en el Administrador de dispositivos: les falta el driver, está dañado o falló al iniciar. Un driver con fallas puede causar pantallas azules, que la PC no se suspenda o que algo no funcione (el sonido, el Wi-Fi, la cámara, el touchpad...).' `
            -Steps $steps -Items $items -Fix 'buscar-cambios' -FixText 'Volver a detectar el hardware'
    }
    if ($devs.Count) {
        return New-Finding -Id 'drivers-error' -Area 'Drivers' -Level Amarillo `
            -Title "$(Get-Plural $devs.Count 'dispositivo está desactivado' 'dispositivos están desactivados') o espera reinicio" -Summary $names `
            -Detail 'Estos dispositivos están apagados en el Administrador de dispositivos o esperan que reinicies la PC. Si los apagaste tú a propósito, no hace falta hacer nada.' `
            -Steps $steps -Items $items
    }
    New-Finding -Id 'drivers-error' -Area 'Drivers' -Level Verde -Title 'Todos los dispositivos tienen su driver' `
        -Summary 'Ningún dispositivo con signo amarillo' -Detail 'El Administrador de dispositivos no muestra dispositivos sin driver o con fallas.' -Steps $steps
}

function Test-DisplayDriver {
    $pc = Get-CachedPcInfo
    $vcs = @(Get-CimInstance Win32_VideoController)
    if (-not $vcs.Count) { return }
    $basic = @($vcs | Where-Object { $_.InfFilename -eq 'display.inf' -or $_.Name -match 'Basic Display|Basic Render|b.sico de (pantalla|Microsoft)' })
    $items = foreach ($vc in $vcs) {
        $date = if ($vc.DriverDate) { $vc.DriverDate.ToString('dd/MM/yyyy') } else { 'fecha desconocida' }
        New-FindingItem -Name $vc.Name -Detail "Driver $($vc.DriverVersion) del $date"
    }
    $vendor = @($vcs | Where-Object { $_.InfFilename -ne 'display.inf' } | ForEach-Object { "$($_.AdapterCompatibility) $($_.Name)" }) -join ' '
    $steps = Get-DriverSteps (Get-GpuUrl $vendor)
    if ($basic.Count -and -not $pc.IsVirtual) {
        return New-Finding -Id 'driver-video' -Area 'Drivers' -Level Rojo -Title 'La tarjeta de video no tiene su driver' `
            -Summary 'Windows usa un driver genérico' `
            -Detail 'Windows está usando el «Adaptador de pantalla básico de Microsoft»: la imagen puede verse borrosa, los videos y juegos van lentos, y el brillo o el segundo monitor pueden no funcionar. También puede causar fallas al suspender.' `
            -Steps $steps -Items $items -Fix 'buscar-driver' -FixText 'Buscar el driver de video'
    }
    $old = @($vcs | Where-Object { $_.DriverDate -and $_.DriverDate -lt (Get-Date).AddYears(-2) -and $_.InfFilename -ne 'display.inf' -and "$($_.AdapterCompatibility)" -notmatch 'Microsoft' })
    if ($old.Count -and -not $pc.IsVirtual) {
        return New-Finding -Id 'driver-video' -Area 'Drivers' -Level Amarillo -Title "El driver de video es del $($old[0].DriverDate.Year)" `
            -Summary $old[0].Name `
            -Detail 'El driver de la tarjeta de video tiene más de dos años. Los drivers nuevos corrigen pantallas azules (VIDEO_TDR), fallas al suspender, calor y problemas con monitores externos.' `
            -Steps $steps -Items $items -Fix 'buscar-driver' -FixText 'Buscar un driver más nuevo'
    }
    $first = $vcs[0]
    $date = if ($first.DriverDate) { " · driver del $($first.DriverDate.ToString('dd/MM/yyyy'))" } else { '' }
    New-Finding -Id 'driver-video' -Area 'Drivers' -Level Verde -Title 'Driver de video al día' -Summary "$($first.Name)$date" `
        -Detail 'La tarjeta de video tiene su driver y no es antiguo.' -Steps $steps -Items $items
}

#endregion

#region Revisiones: pantallas azules y apagones

# Códigos de pantalla azul más comunes: nombre, qué significa y tipo de causa (decide el paso a paso)
$script:BugChecks = @{
    0x0000009F = @('DRIVER_POWER_STATE_FAILURE', 'Un driver no respondió al suspender, hibernar o apagar', 'energia')
    0x0000014F = @('PDC_WATCHDOG_TIMEOUT', 'Un driver se colgó mientras la PC dormía (Espera moderna)', 'energia')
    0x000000A0 = @('INTERNAL_POWER_ERROR', 'Falló la administración de energía (suele ser la hibernación)', 'energia')
    0x000000D1 = @('DRIVER_IRQL_NOT_LESS_OR_EQUAL', 'Un driver usó memoria que no debía (a menudo Wi-Fi, red o antivirus)', 'driver')
    0x0000000A = @('IRQL_NOT_LESS_OR_EQUAL', 'Un driver o la memoria RAM fallaron', 'driver')
    0x0000003B = @('SYSTEM_SERVICE_EXCEPTION', 'Falló un driver o un componente del sistema (a menudo video o antivirus)', 'driver')
    0x0000007E = @('SYSTEM_THREAD_EXCEPTION_NOT_HANDLED', 'Un driver tuvo un error que no pudo manejar', 'driver')
    0x1000007E = @('SYSTEM_THREAD_EXCEPTION_NOT_HANDLED', 'Un driver tuvo un error que no pudo manejar', 'driver')
    0x0000008E = @('KERNEL_MODE_EXCEPTION_NOT_HANDLED', 'Un driver tuvo un error que no pudo manejar', 'driver')
    0x1000008E = @('KERNEL_MODE_EXCEPTION_NOT_HANDLED', 'Un driver tuvo un error que no pudo manejar', 'driver')
    0x0000001E = @('KMODE_EXCEPTION_NOT_HANDLED', 'Un driver tuvo un error', 'driver')
    0x000000C2 = @('BAD_POOL_CALLER', 'Un driver usó mal la memoria', 'driver')
    0x00000019 = @('BAD_POOL_HEADER', 'Se dañó la memoria del sistema (driver o antivirus)', 'driver')
    0x000000C5 = @('DRIVER_CORRUPTED_EXPOOL', 'Un driver dañó la memoria del sistema', 'driver')
    0x000000BE = @('ATTEMPTED_WRITE_TO_READONLY_MEMORY', 'Un driver intentó escribir en memoria protegida', 'driver')
    0x000000FC = @('ATTEMPTED_EXECUTE_OF_NOEXECUTE_MEMORY', 'Un driver ejecutó memoria protegida', 'driver')
    0x00000139 = @('KERNEL_SECURITY_CHECK_FAILURE', 'Windows detectó datos dañados (driver o archivos de Windows)', 'driver')
    0x000000C4 = @('DRIVER_VERIFIER_DETECTED_VIOLATION', 'El verificador de drivers encontró un driver con fallas', 'driver')
    0x00000144 = @('BUGCODE_USB3_DRIVER', 'Falló el driver de USB 3', 'driver')
    0x00000050 = @('PAGE_FAULT_IN_NONPAGED_AREA', 'Se pidió memoria que no existe (memoria RAM, driver o antivirus)', 'memoria')
    0x0000001A = @('MEMORY_MANAGEMENT', 'Falló el manejo de la memoria (a menudo, la memoria RAM)', 'memoria')
    0x0000004E = @('PFN_LIST_CORRUPT', 'Se dañó la lista de memoria (memoria RAM o driver)', 'memoria')
    0x00000109 = @('CRITICAL_STRUCTURE_CORRUPTION', 'Se dañó una parte esencial de Windows (memoria o driver)', 'memoria')
    0x0000012B = @('FAULTY_HARDWARE_CORRUPTED_PAGE', 'La memoria RAM tiene fallas', 'memoria')
    0x00000124 = @('WHEA_UNCORRECTABLE_ERROR', 'El hardware informó un error grave (calor, voltaje o el procesador)', 'calor')
    0x00000101 = @('CLOCK_WATCHDOG_TIMEOUT', 'Un núcleo del procesador dejó de responder (calor, BIOS o el procesador)', 'calor')
    0x0000009C = @('MACHINE_CHECK_EXCEPTION', 'El procesador detectó un error de hardware', 'calor')
    0x00000116 = @('VIDEO_TDR_FAILURE', 'La tarjeta de video dejó de responder y no se pudo recuperar', 'video')
    0x00000117 = @('VIDEO_TDR_TIMEOUT_DETECTED', 'La tarjeta de video dejó de responder', 'video')
    0x00000119 = @('VIDEO_SCHEDULER_INTERNAL_ERROR', 'Falló el driver de video', 'video')
    0x0000010E = @('VIDEO_MEMORY_MANAGEMENT_INTERNAL', 'Falló la memoria de video', 'video')
    0x00000133 = @('DPC_WATCHDOG_VIOLATION', 'Un driver tardó demasiado (a menudo el del disco SSD o su firmware)', 'disco')
    0x0000007A = @('KERNEL_DATA_INPAGE_ERROR', 'No se pudo leer el disco', 'disco')
    0x00000077 = @('KERNEL_STACK_INPAGE_ERROR', 'No se pudo leer el disco', 'disco')
    0x000000F4 = @('CRITICAL_OBJECT_TERMINATION', 'Se cerró un proceso esencial (a menudo por el disco)', 'disco')
    0x00000024 = @('NTFS_FILE_SYSTEM', 'Falló el sistema de archivos del disco', 'disco')
    0x00000154 = @('UNEXPECTED_STORE_EXCEPTION', 'Falló la lectura de la memoria o del disco (a menudo el SSD)', 'disco')
    0x0000007B = @('INACCESSIBLE_BOOT_DEVICE', 'Windows no pudo acceder al disco al encender', 'disco')
    0x000000ED = @('UNMOUNTABLE_BOOT_VOLUME', 'No se pudo abrir el disco de Windows', 'disco')
    0x000000EF = @('CRITICAL_PROCESS_DIED', 'Se cerró un proceso esencial de Windows', 'sistema')
    0x000000E2 = @('MANUALLY_INITIATED_CRASH', 'Se provocó a propósito (con el teclado o una herramienta)', 'manual')
}

$script:CrashFix = @{
    energia = @('desactivar-inicio-rapido', 'Desactivar el inicio rápido')
    driver  = @('buscar-driver', 'Buscar drivers nuevos')
    memoria = @('prueba-memoria', 'Probar la memoria RAM')
    disco   = @('revisar-disco', 'Revisar el disco al reiniciar')
    calor   = @('bajar-temperatura', 'Bajar la temperatura')
    video   = @('buscar-driver', 'Buscar el driver de video')
    sistema = @('reparar-windows', 'Reparar archivos de Windows')
}

$script:CauseTexts = @{
    energia = 'Causa probable: un driver (a menudo el de chipset, video, Wi-Fi o Bluetooth) no respondió cuando Windows quiso suspender, hibernar o apagar la PC. Se arregla actualizando los drivers del fabricante y desactivando el inicio rápido.'
    driver  = 'Causa probable: un driver con fallas. Se arregla actualizando los drivers (sobre todo video, Wi-Fi y chipset) y, si tienes un antivirus que no es el de Windows, actualizándolo o desinstalándolo.'
    memoria = 'Causa probable: la memoria RAM o un driver. Primero prueba la memoria con la herramienta de Windows.'
    disco   = 'Causa probable: el disco o su driver. Revisa el disco, actualiza el firmware del SSD y copia tus archivos importantes por si acaso.'
    calor   = 'Causa probable: el hardware, casi siempre por calor excesivo, el BIOS o un overclock. Revisa la temperatura y actualiza el BIOS.'
    video   = 'Causa probable: el driver de la tarjeta de video, o que la tarjeta se calienta. Instala el driver más reciente.'
    sistema = 'Causa probable: archivos de Windows dañados o el disco. Repara los archivos de Windows.'
    manual  = 'Esta pantalla azul se provocó a propósito: no indica una falla.'
}

function Get-BugCheckInfo($Code) {
    if ($null -eq $Code) {
        return [pscustomobject]@{ Name = 'Error sin código'; Hex = 'desconocido'; Text = 'Windows no guardó el código del error'; Cause = 'driver' }
    }
    $hex = '0x{0:X8}' -f [int64]$Code
    $info = $script:BugChecks[[int]$Code]
    if ($info) { return [pscustomobject]@{ Name = $info[0]; Hex = $hex; Text = $info[1]; Cause = $info[2] } }
    [pscustomobject]@{ Name = "Error $hex"; Hex = $hex; Text = 'Windows se detuvo por un error'; Cause = 'driver' }
}

# Lee el código de la pantalla azul de la cabecera de un minidump (C:\Windows\Minidump)
function Read-DumpCode([string]$Path) {
    try {
        $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try {
            $buf = New-Object byte[] 0x60
            if ($fs.Read($buf, 0, $buf.Length) -lt $buf.Length) { return $null }
        } finally { $fs.Close() }
        $sig = [Text.Encoding]::ASCII.GetString($buf, 0, 8)
        if ($sig -eq 'PAGEDU64') { return [int][BitConverter]::ToUInt32($buf, 0x38) }
        if ($sig -eq 'PAGEDUMP') { return [int][BitConverter]::ToUInt32($buf, 0x28) }
    } catch { }
    $null
}

function Find-NearCrash($List, [datetime]$Time, [string]$Dump) {
    foreach ($c in $List) {
        if ($Dump -and $c.Dump -and ($c.Dump -ieq $Dump)) { return $c }
        if ([Math]::Abs(($c.Time - $Time).TotalMinutes) -le 20) { return $c }
    }
    $null
}

# Pantallas azules (registro de Windows y minidumps) y apagones de golpe de los últimos días
function Get-Crashes([int]$Days = 90) {
    $since = (Get-Date).AddDays(-$Days)
    $crashes = New-Object System.Collections.ArrayList
    foreach ($e in Get-Events @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; StartTime = $since } 100) {
        $msg = "$($e.Message)"
        if (-not $msg) { $msg = ($e.Properties | ForEach-Object { "$($_.Value)" }) -join ' ' }
        $code = $null
        if ($msg -match '0x([0-9a-fA-F]{8})\b') { $code = [int][Convert]::ToInt64($Matches[1], 16) }
        $dump = if ($msg -match '([A-Za-z]:\\[^\s"]+\.dmp)') { $Matches[1] } else { $null }
        [void]$crashes.Add([pscustomobject]@{ Time = $e.TimeCreated; Code = $code; Dump = $dump })
    }
    $sudden = @()
    foreach ($e in Get-Events @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = $since } 100) {
        $bc = 0
        try { $bc = [int64]$e.Properties[0].Value } catch { }
        if ($bc -ne 0) {
            if (-not (Find-NearCrash $crashes $e.TimeCreated)) { [void]$crashes.Add([pscustomobject]@{ Time = $e.TimeCreated; Code = [int]$bc; Dump = $null }) }
        } else {
            $sudden += $e.TimeCreated
        }
    }
    foreach ($f in Get-ChildItem -LiteralPath (Join-Path $env:SystemRoot 'Minidump') -Filter *.dmp -ErrorAction SilentlyContinue) {
        if ($f.LastWriteTime -lt $since -or (Find-NearCrash $crashes $f.LastWriteTime $f.FullName)) { continue }
        [void]$crashes.Add([pscustomobject]@{ Time = $f.LastWriteTime; Code = (Read-DumpCode $f.FullName); Dump = $f.FullName })
    }
    [pscustomobject]@{ Crashes = @($crashes | Sort-Object Time -Descending); Sudden = @($sudden | Sort-Object -Descending) }
}

function Get-RepairSteps {
    @(
        New-Step -Title 'Repara la imagen de Windows' -Path $script:CmdAdminPath -Command 'DISM /Online /Cleanup-Image /RestoreHealth' `
            -Text 'Descarga de Microsoft los archivos que estén dañados. Necesita internet y tarda de 10 a 30 minutos: no cierres la ventana aunque parezca detenida.' `
            -Button 'Hacerlo por mí' -Fix 'reparar-windows'
        New-Step -Title 'Repara los archivos de Windows' -Path $script:CmdAdminPath -Command 'sfc /scannow' `
            -Text 'Revisa todos los archivos de Windows y reemplaza los dañados o los que faltan. Tarda unos 15 minutos. (El botón del paso anterior ya hace los dos pasos.)'
        New-Step -Title 'Reinicia la PC' -Text 'Algunos archivos se reemplazan al reiniciar.' -Button 'Reiniciar ahora' -Fix 'reiniciar'
        New-Step -Title 'Si sigue fallando' -Path 'Configuración → Sistema → Recuperación → Restablecer este equipo' `
            -Text 'Como último recurso, «Restablecer este equipo» → «Mantener mis archivos» reinstala Windows sin borrar tus documentos (los programas sí hay que volver a instalarlos).' `
            -Button 'Abrir Recuperación' -Open 'ms-settings:recovery'
    )
}

function Get-DiskSteps {
    @(
        New-Step -Title 'Copia tus archivos importantes' -Path 'Configuración → Cuentas → Copia de seguridad de Windows' `
            -Text 'Antes de nada, copia Documentos, Escritorio, Fotos y Descargas a una USB, a un disco externo o a OneDrive.' `
            -Button 'Abrir Copia de seguridad' -Open 'ms-settings:backup'
        New-Step -Title 'Revisa el disco' -Path $script:CmdAdminPath -Command 'chkdsk C: /f' `
            -Text 'Windows revisará y reparará el disco la próxima vez que reinicies (puede tardar un rato; no apagues la PC mientras tanto). Si escribes el comando, responde S cuando pregunte si quieres hacerlo al reiniciar.' `
            -Button 'Hacerlo por mí' -Fix 'revisar-disco'
        New-Step -Title 'Actualiza el firmware del SSD' `
            -Text 'Los fabricantes de discos SSD corrigen fallas con actualizaciones de firmware: usa su programa (Samsung Magician, Crucial Storage Executive, WD Dashboard, Kingston SSD Manager, etc.).'
        New-Step -Title 'Si el disco está fallando, cámbialo' `
            -Text 'Un SSD nuevo es económico y la PC quedará más rápida. Antes de cambiarlo, guarda tus archivos y tus drivers (con la app RespaldoDrivers).'
    )
}

function Get-CrashSteps([string]$Cause) {
    $reliability = New-Step -Title 'Mira el historial de fallas' -Path 'Inicio → escribe «Ver el historial de confiabilidad»' `
        -Text 'El Monitor de confiabilidad muestra día por día las pantallas azules y los programas que fallaron. Haz clic en una «X» roja para ver el detalle.' `
        -Button 'Abrir el Monitor de confiabilidad' -Open 'perfmon.exe|/rel'
    $steps = switch ($Cause) {
        'energia' {
            @((Get-DriverSteps)[0..1]) + @(
                New-Step -Title 'Desactiva el inicio rápido' -Path 'Panel de control → Opciones de energía → Elegir el comportamiento de los botones de inicio/apagado' `
                    -Text 'Presiona «Cambiar la configuración actualmente no disponible», desmarca «Activar inicio rápido» y presiona «Guardar cambios».' `
                    -Button 'Hacerlo por mí' -Fix 'desactivar-inicio-rapido'
                New-Step -Title 'Revisa la hibernación' -Text 'En esta app, revisa «Hibernación y suspensión» y los programas que no dejan suspender la PC.'
            )
        }
        'memoria' {
            @(
                New-Step -Title 'Prueba la memoria RAM' -Path 'Inicio → escribe «Diagnóstico de memoria de Windows» → «Reiniciar ahora y comprobar si existen problemas»' `
                    -Text 'La PC se reinicia y revisa la memoria (unos 20 minutos). Al volver a Windows, el resultado aparece en una notificación.' `
                    -Button 'Hacerlo por mí' -Fix 'prueba-memoria'
                New-Step -Title 'Si encuentra errores' -Text 'Hay que cambiar la memoria RAM (un técnico puede hacerlo). Si no hay errores, actualiza los drivers con los pasos siguientes.'
            ) + @((Get-DriverSteps)[0..1])
        }
        'disco'   { Get-DiskSteps }
        'calor'   {
            @(
                New-Step -Title 'Baja la temperatura' -Text 'Limpia las rejillas de ventilación, usa la PC sobre una superficie dura y revisa en esta app la sección «Temperatura».' `
                    -Button 'Hacerlo por mí' -Fix 'bajar-temperatura'
                New-Step -Title 'Quita el overclock' -Text 'Si aceleraste el procesador, la memoria o la tarjeta de video (overclock, XMP o «modo turbo» en el BIOS), vuelve a los valores normales.'
                New-Step -Title 'Actualiza el BIOS' -Text 'Busca en la página de soporte de tu marca una actualización del BIOS para tu modelo.' -Button 'Abrir la página de soporte' -Open (Get-SupportUrl)
            )
        }
        'video'   { Get-DriverSteps (Get-GpuUrl (@(Get-CimInstance Win32_VideoController | ForEach-Object { "$($_.AdapterCompatibility) $($_.Name)" }) -join ' ')) }
        'sistema' { Get-RepairSteps }
        'manual'  { @(New-Step -Title 'No hace falta hacer nada' -Text 'Esta pantalla azul se provocó a propósito (por ejemplo, con una combinación de teclas o una herramienta de pruebas).') }
        default   {
            @(Get-DriverSteps) + @(
                New-Step -Title 'Revisa el antivirus' -Text 'Si tienes un antivirus que no es el de Windows, actualízalo o desinstálalo para probar: Seguridad de Windows queda activo solo.'
            )
        }
    }
    @($steps) + $reliability
}

function Test-BlueScreens {
    $data = Get-Crashes 90
    $now = Get-Date
    $recent = @($data.Crashes | Where-Object { $_.Time -ge $now.AddDays(-30) })
    $items = foreach ($c in $data.Crashes | Select-Object -First 10) {
        $info = Get-BugCheckInfo $c.Code
        New-FindingItem -Name "$(Format-Date $c.Time) · $($info.Name)" -Detail "$($info.Text) (código $($info.Hex))" `
            -Action 'paso-a-paso' -ActionText 'Paso a paso' -Arg @{ Cause = $info.Cause; Title = "Pantalla azul $($info.Name)" }
    }
    if ($data.Crashes.Count) {
        $last = $data.Crashes[0]
        $info = Get-BugCheckInfo $last.Code
        $cause = (@($data.Crashes | ForEach-Object { (Get-BugCheckInfo $_.Code).Cause }) | Group-Object | Sort-Object Count -Descending | Select-Object -First 1).Name
        $fix = $script:CrashFix[$cause]
        $level = if ($recent.Count) { 'Rojo' } else { 'Amarillo' }
        $title = if ($recent.Count) { "$(Get-Plural $recent.Count 'pantalla azul' 'pantallas azules') en los últimos 30 días" }
                 else { "$(Get-Plural $data.Crashes.Count 'pantalla azul' 'pantallas azules') en los últimos 3 meses" }
        $detail = "Sí, se confirmó: Windows se detuvo con una pantalla azul. La última fue el $(Format-Date $last.Time), con el error $($info.Name) (código $($info.Hex)): $($info.Text.Substring(0,1).ToLower() + $info.Text.Substring(1)).`n`n" +
            $script:CauseTexts[$cause] + "`n`nEn la lista está cada pantalla azul con su propio paso a paso."
        $params = @{ Steps = (Get-CrashSteps $cause); Items = $items; Data = @{ Cause = $cause } }
        if ($fix) { $params.Fix = $fix[0]; $params.FixText = $fix[1] }
        $result = @(New-Finding -Id 'pantallas-azules' -Area 'Pantallas azules' -Level $level -Title $title `
            -Summary "La última: $(Format-Date $last.Time) · $($info.Text)" -Detail $detail @params)
    } else {
        $result = @(New-Finding -Id 'pantallas-azules' -Area 'Pantallas azules' -Level Verde -Title 'No hubo pantallas azules' `
            -Summary 'En los últimos 3 meses' -Detail 'Windows no registró ninguna pantalla azul en los últimos 90 días.' -Steps (Get-CrashSteps 'driver'))
    }

    $sudden = @($data.Sudden | Where-Object { $_ -ge $now.AddDays(-30) })
    $suddenSteps = @(
        New-Step -Title 'Revisa la temperatura' -Text 'Si la PC se calienta demasiado, se apaga sola para protegerse. Mira en esta app la sección «Temperatura» y limpia las rejillas de ventilación.' `
            -Button 'Bajar la temperatura' -Fix 'bajar-temperatura'
        New-Step -Title 'Revisa la batería y el cargador' -Text 'Si se apaga con poca batería aunque marque carga, o al mover el cable del cargador, la batería o el cargador están fallando. Mira el estado de la batería en esta app.'
        New-Step -Title 'Revisa la corriente' -Text 'En una PC de escritorio, los cortes y bajones de luz la apagan de golpe. Un UPS (respaldo de energía) o un regulador la protegen.'
        New-Step -Title 'No la apagues con el botón' -Text 'Mantener presionado el botón de encendido cuenta como apagón. Si la PC se traba, espera un minuto o usa Ctrl + Alt + Supr → botón de apagado → Reiniciar.'
        New-Step -Title 'Mira el historial de fallas' -Path 'Inicio → escribe «Ver el historial de confiabilidad»' `
            -Text 'El Monitor de confiabilidad muestra los apagones («Windows no se cerró correctamente») junto con lo que pasó antes.' `
            -Button 'Abrir el Monitor de confiabilidad' -Open 'perfmon.exe|/rel'
    )
    if ($sudden.Count) {
        $level = if ($sudden.Count -ge 3) { 'Rojo' } else { 'Amarillo' }
        $suddenItems = foreach ($t in $sudden | Select-Object -First 10) { New-FindingItem -Name "Se apagó de golpe el $(Format-Date $t)" -Detail 'Sin pantalla azul (Kernel-Power 41)' }
        $result += New-Finding -Id 'apagones' -Area 'Pantallas azules' -Level $level `
            -Title "La PC se apagó de golpe $(Get-Plural $sudden.Count 'vez' 'veces') en 30 días" `
            -Summary 'Sin pantalla azul: calor, batería, corriente o el botón de encendido' `
            -Detail 'Windows registró que la PC se apagó o se reinició sin cerrarse bien y sin mostrar una pantalla azul. Pasa cuando se calienta tanto que se apaga para protegerse, cuando la batería o el cargador fallan, cuando se corta la luz, o cuando se mantuvo presionado el botón de encendido porque estaba trabada.' `
            -Steps $suddenSteps -Items $suddenItems
    } else {
        $result += New-Finding -Id 'apagones' -Area 'Pantallas azules' -Level Verde -Title 'No hubo apagones de golpe' `
            -Summary 'En los últimos 30 días' -Detail 'La PC no se apagó sin cerrarse bien en los últimos 30 días.' -Steps $suddenSteps
    }
    $result
}

#endregion

#region Revisiones: registro, archivos de Windows, disco, batería y antivirus

function Test-CrashDumpSettings {
    $v = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' 'CrashDumpEnabled'
    $steps = @(
        New-Step -Title 'Abre «Inicio y recuperación»' -Path 'Inicio → escribe «Ver la configuración avanzada del sistema» → Opciones avanzadas → Inicio y recuperación → Configuración' `
            -Text 'En «Escribir información de depuración» elige «Volcado de memoria pequeño (256 KB)» y presiona «Aceptar».' `
            -Button 'Abrir la configuración avanzada' -Open 'SystemPropertiesAdvanced.exe'
        New-Step -Title 'O deja que la app lo haga' -Text 'Cambia en el registro HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\CrashControl el valor CrashDumpEnabled a 3 (volcado pequeño). Se guarda el valor anterior para deshacerlo.' `
            -Button 'Hacerlo por mí' -Fix 'activar-volcados'
    )
    if ($v -eq 0) {
        return New-Finding -Id 'registro-volcados' -Area 'Registro' -Level Amarillo -Title 'Windows no guarda información de las pantallas azules' `
            -Summary 'Si aparece una, no se sabrá la causa' `
            -Detail 'En el registro, CrashDumpEnabled está en 0: si hay una pantalla azul, Windows no guarda el archivo que dice qué la causó (el «volcado de memoria»). Conviene activarlo: ocupa muy poco.' `
            -Steps $steps -Fix 'activar-volcados' -FixText 'Guardar la información'
    }
    New-Finding -Id 'registro-volcados' -Area 'Registro' -Level Verde -Title 'Windows guarda la información de las pantallas azules' `
        -Summary 'Si aparece una, se podrá saber la causa' -Detail 'El volcado de memoria está activado (CrashDumpEnabled en el registro).' -Steps $steps
}

# Cambios en el registro que suelen hacer los virus: el inicio de Windows, bloqueos de herramientas
# y programas que "interceptan" al Administrador de tareas o al Editor del Registro
function Get-RegistryIssues {
    $issues = @()
    $wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $shell = "$(Get-RegValue $wl 'Shell')".Trim()
    if ($shell -and $shell -notmatch '^(explorer\.exe|[a-z]:\\windows\\explorer\.exe)$') {
        $issues += @{ Name = 'El programa que abre el escritorio (Shell) fue cambiado'; Detail = "Debería decir explorer.exe y dice: $shell"; Path = $wl; Value = 'Shell'; Restore = 'explorer.exe' }
    }
    $userinit = "$(Get-RegValue $wl 'Userinit')".Trim()
    $expected = "$env:SystemRoot\system32\userinit.exe,"
    if ($userinit -and $userinit.TrimEnd(',') -ine $expected.TrimEnd(',')) {
        $issues += @{ Name = 'El inicio de sesión (Userinit) fue cambiado'; Detail = "Debería decir $expected y dice: $userinit"; Path = $wl; Value = 'Userinit'; Restore = $expected }
    }
    $policies = @(
        @{ Value = 'DisableTaskMgr'; Name = 'El Administrador de tareas está bloqueado'; Sub = 'Software\Microsoft\Windows\CurrentVersion\Policies\System' }
        @{ Value = 'DisableRegistryTools'; Name = 'El Editor del Registro está bloqueado'; Sub = 'Software\Microsoft\Windows\CurrentVersion\Policies\System' }
        @{ Value = 'DisableCMD'; Name = 'El Símbolo del sistema está bloqueado'; Sub = 'Software\Policies\Microsoft\Windows\System' }
    )
    foreach ($hive in 'HKCU:', 'HKLM:') {
        foreach ($p in $policies) {
            $path = "$hive\$($p.Sub)"
            $v = Get-RegValue $path $p.Value
            if ($v -and $v -ne 0) {
                $issues += @{ Name = $p.Name; Detail = "Valor $($p.Value) = $v en $($path -replace ':', '')"; Path = $path; Value = $p.Value; Remove = $true }
            }
        }
    }
    $ifeo = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
    foreach ($exe in 'taskmgr.exe', 'regedit.exe', 'msconfig.exe', 'cmd.exe', 'explorer.exe', 'MsMpEng.exe', 'mmc.exe', 'rstrui.exe', 'sethc.exe', 'utilman.exe') {
        $dbg = "$(Get-RegValue "$ifeo\$exe" 'Debugger')".Trim()
        # Process Explorer puede reemplazar al Administrador de tareas a propósito
        if ($dbg -and $dbg -notmatch 'procexp') {
            $issues += @{ Name = "Otro programa se abre en lugar de $exe"; Detail = "Debugger = $dbg"; Path = "$ifeo\$exe"; Value = 'Debugger'; Remove = $true }
        }
    }
    $issues
}

function Test-RegistryTampering {
    $issues = @(Get-RegistryIssues)
    $items = foreach ($i in $issues) { New-FindingItem -Name $i.Name -Detail $i.Detail -Action 'restaurar-registro' -ActionText 'Restaurar' -Arg @($i) }
    $steps = @(
        New-Step -Title 'Haz un examen de virus' -Path 'Inicio → Seguridad de Windows → Protección contra virus y amenazas → Opciones de examen' `
            -Text 'Estos cambios suelen hacerlos los virus. Elige «Examen de Microsoft Defender sin conexión» y presiona «Examinar ahora»: la PC se reinicia y busca virus antes de que arranque Windows.' `
            -Button 'Abrir Seguridad de Windows' -Open 'windowsdefender://threat'
        New-Step -Title 'Restaura los valores normales' `
            -Text 'La app guarda el valor actual (para que puedas deshacerlo) y pone el valor normal de Windows.' -Button 'Hacerlo por mí' -Fix 'restaurar-registro' -FixArg $issues
        New-Step -Title 'Para hacerlo a mano en el Editor del Registro' -Path 'Inicio → escribe «regedit» → Sí' `
            -Text 'Ve a HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon. «Shell» debe decir explorer.exe y «Userinit» debe decir C:\Windows\system32\userinit.exe, (con la coma). Los bloqueos están en ...\CurrentVersion\Policies\System: borra DisableTaskMgr y DisableRegistryTools. Si la PC es de una empresa o un colegio, consulta antes con el área de sistemas: puede que los hayan puesto ellos.' `
            -Button 'Abrir el Editor del Registro' -Open 'regedit.exe'
    )
    if ($issues.Count) {
        return New-Finding -Id 'registro-seguridad' -Area 'Registro' -Level Rojo `
            -Title "$(Get-Plural $issues.Count 'cambio peligroso' 'cambios peligrosos') en el registro de Windows" `
            -Summary (Limit-Text (($issues | ForEach-Object { $_.Name }) -join ' · ') 90) `
            -Detail 'Alguien o algún programa cambió partes del registro que controlan cómo arranca Windows o que bloquean herramientas del sistema. Suele ser obra de un virus. (En PCs de empresas o colegios, algunos bloqueos los pone el área de sistemas a propósito.)' `
            -Steps $steps -Items $items -Fix 'restaurar-registro' -FixText 'Restaurar todo' -FixArg $issues
    }
    New-Finding -Id 'registro-seguridad' -Area 'Registro' -Level Verde -Title 'El registro de Windows no tiene cambios peligrosos' `
        -Summary 'El inicio de Windows y las herramientas del sistema están normales' `
        -Detail 'Se revisaron el inicio de sesión (Shell y Userinit), los bloqueos del Administrador de tareas, del Editor del Registro y del Símbolo del sistema, y los programas que podrían abrirse en su lugar.' -Steps $steps
}

function Test-SystemFiles {
    $state = $null
    try {
        Import-Module Dism -ErrorAction Stop
        $state = "$((Repair-WindowsImage -Online -CheckHealth -ErrorAction Stop).ImageHealthState)"
    } catch { }
    $steps = Get-RepairSteps
    switch ($state) {
        'Healthy' {
            New-Finding -Id 'archivos-sistema' -Area 'Archivos de Windows' -Level Verde -Title 'Los archivos de Windows están bien' `
                -Summary 'La revisión rápida no encontró daños' `
                -Detail 'Windows no tiene marcados archivos dañados ni faltantes. Si igual notas fallas raras, haz la revisión completa: revisa uno por uno todos los archivos de Windows (tarda de 15 a 30 minutos).' `
                -Steps $steps -Fix 'reparar-windows' -FixText 'Revisión completa (15 a 30 min)'
        }
        'Repairable' {
            New-Finding -Id 'archivos-sistema' -Area 'Archivos de Windows' -Level Rojo -Title 'Hay archivos de Windows dañados' `
                -Summary 'Se pueden reparar' `
                -Detail 'Windows encontró archivos del sistema dañados o que faltan. Pueden causar pantallas azules, errores al actualizar y programas que se cierran solos. Se reparan descargando de Microsoft las copias buenas (necesita internet) y revisando todos los archivos.' `
                -Steps $steps -Fix 'reparar-windows' -FixText 'Reparar archivos de Windows'
        }
        'NonRepairable' {
            New-Finding -Id 'archivos-sistema' -Area 'Archivos de Windows' -Level Rojo -Title 'Windows está muy dañado' `
                -Summary 'Puede que haya que restablecerlo' `
                -Detail 'Windows marcó su imagen como «no reparable». Intenta la reparación igual; si falla, usa «Restablecer este equipo» manteniendo tus archivos.' `
                -Steps $steps -Fix 'reparar-windows' -FixText 'Intentar reparar'
        }
        default {
            New-Finding -Id 'archivos-sistema' -Area 'Archivos de Windows' -Level Info -Title 'No se pudo hacer la revisión rápida de archivos' `
                -Summary 'Puedes hacer la revisión completa' -Detail 'Windows no respondió a la revisión rápida. La revisión completa revisa todos los archivos de Windows (de 15 a 30 minutos).' `
                -Steps $steps -Fix 'reparar-windows' -FixText 'Revisión completa (15 a 30 min)'
        }
    }
}

function Test-DiskSpace {
    $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
    $free = [double]$d.FreeSpace
    $size = [double]$d.Size
    $pct = [int][Math]::Round(100 * $free / [Math]::Max([double]1, $size))
    $steps = @(
        New-Step -Title 'Borra los archivos temporales' `
            -Text 'La app borra los archivos temporales de Windows y de los programas que tengan más de un día. No toca tus documentos.' `
            -Button 'Hacerlo por mí' -Fix 'liberar-espacio'
        New-Step -Title 'Activa el Sensor de almacenamiento' -Path 'Configuración → Sistema → Almacenamiento' `
            -Text 'Activa «Sensor de almacenamiento» y entra a «Recomendaciones de limpieza»: muestra archivos grandes, descargas viejas y programas que no usas.' `
            -Button 'Abrir Almacenamiento' -Open 'ms-settings:storagesense'
        New-Step -Title 'Usa el Liberador de espacio en disco' -Path 'Inicio → escribe «Liberador de espacio en disco» → Limpiar archivos del sistema' `
            -Text 'Marca «Limpieza de actualizaciones de Windows», «Archivos temporales» y la «Papelera de reciclaje», y presiona «Aceptar».' `
            -Button 'Abrir el Liberador' -Open 'cleanmgr.exe'
        New-Step -Title 'Desinstala lo que no uses' -Path 'Configuración → Aplicaciones → Aplicaciones instaladas' `
            -Text 'Ordena por tamaño y desinstala juegos y programas que ya no uses. Mueve fotos y videos a un disco externo o a la nube.' `
            -Button 'Abrir Aplicaciones' -Open 'ms-settings:appsfeatures'
    )
    $detail = "En el disco $env:SystemDrive quedan $(Format-Size $free) libres de $(Format-Size $size) ($pct %). Windows necesita espacio libre para actualizarse, para la memoria virtual y para hibernar; con el disco lleno todo se vuelve lento y las actualizaciones fallan."
    if ($free -lt 5GB -or $pct -lt 5) {
        return New-Finding -Id 'espacio' -Area 'Disco' -Level Rojo -Title "El disco $env:SystemDrive está casi lleno" -Summary "Solo quedan $(Format-Size $free) libres" `
            -Detail $detail -Steps $steps -Fix 'liberar-espacio' -FixText 'Borrar archivos temporales'
    }
    if ($free -lt 15GB -or $pct -lt 10) {
        return New-Finding -Id 'espacio' -Area 'Disco' -Level Amarillo -Title "Queda poco espacio en $env:SystemDrive" -Summary "$(Format-Size $free) libres ($pct %)" `
            -Detail $detail -Steps $steps -Fix 'liberar-espacio' -FixText 'Borrar archivos temporales'
    }
    New-Finding -Id 'espacio' -Area 'Disco' -Level Verde -Title "Espacio suficiente en $env:SystemDrive" -Summary "$(Format-Size $free) libres ($pct %)" `
        -Detail $detail -Steps $steps -Fix 'liberar-espacio' -FixText 'Borrar archivos temporales'
}

function Test-DiskHealth {
    $items = @()
    $bad = @()
    $warn = @()
    $disks = @()
    try { $disks = @(Get-PhysicalDisk -ErrorAction Stop) } catch { }
    foreach ($d in $disks) {
        $rel = $null
        try { $rel = $d | Get-StorageReliabilityCounter -ErrorAction Stop } catch { }
        $health = "$($d.HealthStatus)"
        $hText = switch ($health) { 'Healthy' { 'bien' } 'Warning' { 'con advertencias' } 'Unhealthy' { 'con fallas' } default { 'desconocido' } }
        $parts = @("Estado: $hText")
        if ($rel -and $rel.Wear -gt 0) { $parts += "Desgaste: $($rel.Wear) %" }
        if ($rel -and $rel.Temperature -gt 0) { $parts += "$($rel.Temperature) °C" }
        $type = switch ("$($d.MediaType)") { 'SSD' { 'SSD' } 'HDD' { 'disco duro' } default { '' } }
        $name = "$($d.FriendlyName) ($((@($type, (Format-Size $d.Size)) | Where-Object { $_ }) -join ', '))"
        $items += New-FindingItem -Name $name -Detail ($parts -join ' · ')
        if ($health -eq 'Unhealthy') { $bad += $name }
        elseif ($health -eq 'Warning' -or ($rel -and $rel.Wear -ge 90)) { $warn += $name }
    }
    try {
        if (@(Get-CimInstance -Namespace root/wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction Stop | Where-Object { $_.PredictFailure }).Count) {
            $bad += 'el disco (aviso SMART de falla)'
        }
    } catch { }
    $since = (Get-Date).AddDays(-30)
    $diskErrors = (Get-Events @{ LogName = 'System'; ProviderName = 'disk'; Id = @(7, 51, 153); StartTime = $since } 200).Count
    $ntfsErrors = (Get-Events @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Ntfs'; Id = 55; StartTime = $since } 50).Count +
        (Get-Events @{ LogName = 'System'; ProviderName = 'Ntfs'; Id = 55; StartTime = $since } 50).Count
    $steps = Get-DiskSteps
    if ($bad.Count) {
        return New-Finding -Id 'salud-disco' -Area 'Disco' -Level Rojo -Title 'El disco está fallando' -Summary 'Copia tus archivos importantes ahora' `
            -Detail "El propio disco avisa que está fallando: $($bad -join ', '). Puede dejar de funcionar en cualquier momento y perderías lo que tiene guardado. Copia tus archivos hoy mismo y planea cambiarlo." `
            -Steps $steps -Items $items
    }
    if ($warn.Count -or $diskErrors -ge 5) {
        $why = if ($warn.Count) { "El disco muestra señales de desgaste: $($warn -join ', ')." } else { "Windows registró $diskErrors errores al leer o escribir el disco en los últimos 30 días." }
        return New-Finding -Id 'salud-disco' -Area 'Disco' -Level Amarillo -Title 'El disco muestra señales de desgaste' -Summary 'Haz una copia de tus archivos' `
            -Detail "$why Todavía funciona, pero conviene tener copia de tus archivos y revisarlo." -Steps $steps -Items $items -Fix 'revisar-disco' -FixText 'Revisar el disco al reiniciar'
    }
    if ($ntfsErrors) {
        return New-Finding -Id 'salud-disco' -Area 'Disco' -Level Amarillo -Title 'El sistema de archivos tiene errores' -Summary 'Se reparan revisando el disco al reiniciar' `
            -Detail "Windows encontró $(Get-Plural $ntfsErrors 'error' 'errores') en la estructura de archivos del disco en los últimos 30 días (por ejemplo, por apagones). Se reparan con una revisión del disco al reiniciar." `
            -Steps $steps -Items $items -Fix 'revisar-disco' -FixText 'Revisar el disco al reiniciar'
    }
    New-Finding -Id 'salud-disco' -Area 'Disco' -Level Verde -Title 'Los discos están sanos' -Summary 'Sin fallas ni errores de lectura' `
        -Detail 'Los discos informan buen estado y Windows no registró errores de lectura ni de escritura en los últimos 30 días.' -Steps $steps -Items $items
}

function Test-Battery {
    $pc = Get-CachedPcInfo
    if (-not $pc.IsLaptop) { return }
    try {
        $design = (@(Get-CimInstance -Namespace root/wmi -ClassName BatteryStaticData -ErrorAction Stop) | Measure-Object DesignedCapacity -Sum).Sum
        $full = (@(Get-CimInstance -Namespace root/wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop) | Measure-Object FullChargedCapacity -Sum).Sum
    } catch { return }
    if (-not $design -or -not $full) { return }
    $health = [int][Math]::Min(100, [Math]::Round(100 * $full / $design))
    $cycles = $null
    try { $cycles = (@(Get-CimInstance -Namespace root/wmi -ClassName BatteryCycleCount -ErrorAction Stop) | Measure-Object CycleCount -Sum).Sum } catch { }
    $steps = @(
        New-Step -Title 'Mira el informe completo' -Path $script:CmdAdminPath -Command 'powercfg /batteryreport' `
            -Text 'Windows arma un informe con la capacidad original, la actual y el uso de los últimos días.' -Button 'Hacerlo por mí' -Fix 'informe-bateria'
        New-Step -Title 'Cuídala' `
            -Text 'Evita el calor (no la dejes en el auto ni sobre la cama). Si la usas siempre enchufada, activa el modo de cuidado de batería del fabricante (por ejemplo en HP Support Assistant, Lenovo Vantage o MyASUS), que la carga solo hasta el 80 %.'
        New-Step -Title 'Cuándo cambiarla' `
            -Text 'Por debajo del 50 % conviene cambiarla. Si se hincha (la tapa o el touchpad se levantan), deja de usarla de inmediato y llévala a un técnico.'
    )
    $detail = "La batería guarda hoy $full mWh; cuando era nueva guardaba $design mWh. Es decir, conserva el $health % de su capacidad original."
    if ($cycles) { $detail += " Lleva $cycles ciclos de carga." }
    $fixArgs = @{ Steps = $steps; Fix = 'informe-bateria'; FixText = 'Ver el informe de batería' }
    if ($health -lt 70) {
        $level = if ($health -lt 50) { 'Rojo' } else { 'Amarillo' }
        return New-Finding -Id 'bateria' -Area 'Batería' -Level $level -Title "La batería solo guarda el $health % de su carga original" `
            -Summary 'Dura menos y puede apagarse de golpe' -Detail $detail @fixArgs
    }
    New-Finding -Id 'bateria' -Area 'Batería' -Level Verde -Title "Batería en buen estado: $health %" -Summary 'Conserva casi toda su capacidad' -Detail $detail @fixArgs
}

function Test-Antivirus {
    # Windows Server no tiene el Centro de seguridad: ahí no se revisa
    try { $products = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop) } catch { return }
    $active = @()
    $outdated = @()
    $items = foreach ($p in $products) {
        $st = [int]$p.productState
        $on = ($st -band 0x1000) -ne 0
        $old = ($st -band 0x10) -ne 0
        if ($on) { $active += $p.displayName; if ($old) { $outdated += $p.displayName } }
        $state = if ($on) { 'Activado' } else { 'Desactivado' }
        if ($on) { $state += if ($old) { ' · firmas desactualizadas' } else { ' · al día' } }
        New-FindingItem -Name $p.displayName -Detail $state
    }
    $steps = @(
        New-Step -Title 'Abre Seguridad de Windows' -Path 'Inicio → Seguridad de Windows → Protección contra virus y amenazas' `
            -Text 'Activa «Protección en tiempo real» y, en «Actualizaciones de protección», presiona «Buscar actualizaciones».' `
            -Button 'Abrir Seguridad de Windows' -Open 'windowsdefender://threat'
        New-Step -Title 'Haz un examen' `
            -Text 'Presiona «Examen rápido». Si sospechas de un virus, entra a «Opciones de examen» y usa «Examen de Microsoft Defender sin conexión».'
        New-Step -Title 'Usa un solo antivirus' `
            -Text 'Dos antivirus a la vez vuelven lenta la PC y causan fallas. Si instalaste otro, deja solo uno (el de Windows es suficiente para la mayoría).'
    )
    $fixArgs = @{ Steps = $steps; Items = $items; Fix = 'abrir-seguridad'; FixText = 'Abrir Seguridad de Windows' }
    $others = @($active | Where-Object { $_ -notmatch 'Defender' })
    if (-not $active.Count) {
        return New-Finding -Id 'antivirus' -Area 'Seguridad' -Level Rojo -Title 'No hay un antivirus activo' -Summary 'La PC está desprotegida' `
            -Detail 'Ningún antivirus está encendido. Sin protección, un virus puede robar tus contraseñas, llenar la PC de publicidad o hacerla muy lenta.' @fixArgs
    }
    if ($outdated.Count -eq $active.Count) {
        return New-Finding -Id 'antivirus' -Area 'Seguridad' -Level Amarillo -Title 'El antivirus está desactualizado' -Summary ($active -join ', ') `
            -Detail 'El antivirus está encendido, pero no tiene las firmas de virus recientes: no reconoce los virus nuevos.' @fixArgs
    }
    if ($others.Count -ge 2) {
        return New-Finding -Id 'antivirus' -Area 'Seguridad' -Level Amarillo -Title "Hay $($others.Count) antivirus activos a la vez" -Summary ($others -join ', ') `
            -Detail 'Tener varios antivirus a la vez vuelve lenta la PC, la calienta y puede causar pantallas azules. Deja solo uno.' @fixArgs
    }
    New-Finding -Id 'antivirus' -Area 'Seguridad' -Level Verde -Title "Protegido por $($active -join ', ')" -Summary 'Antivirus activo y al día' `
        -Detail 'El antivirus está encendido y tiene las firmas de virus al día.' @fixArgs
}

#endregion

#region Arreglos automáticos y deshacer

# Qué hace cada arreglo (se muestra antes de confirmar). Changes = cambia la configuración: antes se crea
# un punto de restauración. Long = tarda: se ejecuta en segundo plano.
$script:FixInfo = @{
    'activar-hibernacion'      = @{ Changes = $true; Text = 'Activar la hibernación, hacer que con batería la PC pase de la suspensión a la hibernación después de 1 hora y mostrar «Hibernar» en el menú de apagado.' }
    'tapa'                     = @{ Changes = $true; Text = 'Hacer que, con batería, la PC se suspenda al cerrar la tapa.' }
    'despertares'              = @{ Changes = $true; Text = 'Apagar los temporizadores de reactivación con batería (y dejar solo los importantes con el cargador), para que nada encienda la PC en la mochila.' }
    'desactivar-inicio-rapido' = @{ Changes = $true; Text = 'Desactivar el inicio rápido (valor HiberbootEnabled del registro), para que «Apagar» cierre Windows y los drivers por completo.' }
    'plan-equilibrado'         = @{ Changes = $true; Text = 'Cambiar al plan de energía «Equilibrado».' }
    'bajar-temperatura'        = @{ Changes = $true; Text = 'Limitar el procesador al 99 % (apaga el «Turbo»): la PC se calienta mucho menos y casi no pierde velocidad.' }
    'activar-volcados'         = @{ Changes = $true; Text = 'Hacer que Windows guarde un volcado pequeño (256 KB) en cada pantalla azul, para saber la causa.' }
    'restaurar-registro'       = @{ Changes = $true; Text = 'Poner los valores normales de Windows en el registro (se guarda el valor actual para deshacerlo).' }
    'quitar-arranque'          = @{ Changes = $true; Text = 'Quitar este programa del arranque de Windows (no se desinstala; puedes volver a activarlo).' }
    'arranque-faltantes'       = @{ Changes = $true; Text = 'Quitar del arranque de Windows los programas cuyo archivo ya no existe.' }
    'ignorar-bloqueo'          = @{ Changes = $true; Text = 'Hacer que Windows ignore los pedidos de este programa de mantener la PC despierta.' }
    'quitar-despertar'         = @{ Changes = $true; Text = 'Quitarle a este dispositivo el permiso de despertar a la PC.' }
    'cerrar-programa'          = @{ Changes = $false; Text = 'Cerrar este programa. Si tiene trabajo sin guardar, se perderá.' }
    'reparar-windows'          = @{ Changes = $false; Long = $true; Text = 'Reparar los archivos de Windows: primero DISM (descarga de Microsoft los archivos dañados; necesita internet) y luego SFC (revisa todos los archivos). Tarda de 15 a 45 minutos; puedes seguir usando la PC.' }
    'liberar-espacio'          = @{ Changes = $false; Long = $true; Text = 'Borrar los archivos temporales de Windows y de los programas que tengan más de un día. No toca tus documentos.' }
    'revisar-disco'            = @{ Changes = $false; Text = "Marcar el disco $env:SystemDrive para que Windows lo revise y repare la próxima vez que reinicies (puede tardar un rato; no apagues la PC mientras tanto)." }
    'prueba-memoria'           = @{ Changes = $false; Text = 'Abrir el Diagnóstico de memoria de Windows. Elige «Reiniciar ahora y comprobar si existen problemas» (guarda tu trabajo antes).' }
    'reiniciar'                = @{ Changes = $false; Text = 'Reiniciar la PC ahora. Guarda tu trabajo antes.' }
    'buscar-cambios'           = @{ Changes = $false; Text = 'Volver a detectar todo el hardware para que Windows instale los drivers que encuentre.' }
    'reinstalar-dispositivo'   = @{ Changes = $false; Text = 'Desinstalar este dispositivo y volver a detectarlo, para que Windows reinstale su driver.' }
    'habilitar-dispositivo'    = @{ Changes = $false; Text = 'Volver a activar este dispositivo.' }
}

function Get-FixDescription([string]$Id) {
    $i = $script:FixInfo[$Id]
    if ($i) { $i.Text } else { '' }
}

function Test-FixChanges([string]$Id) { [bool]($script:FixInfo[$Id] -and $script:FixInfo[$Id].Changes) }

# Ejecuta un arreglo. Devuelve @{ Message; Undo (lista de cómo deshacerlo); Description }.
function Invoke-Fix([string]$Id, $Arg) {
    $g = $script:PowerGuids
    $undo = @()
    $msg = ''
    $desc = ''
    switch ($Id) {
        'activar-hibernacion' {
            $caps = Get-PowerCapabilities
            if (-not ($caps -and $caps.S4 -and $caps.HiberFilePresent)) {
                [void](Invoke-PowerCfg @('/hibernate', 'on'))
                try { [void](Invoke-PowerCfg @('/hibernate', '/type', 'full')) } catch { }
                $undo += @{ T = 'hibernate-off' }
            }
            $hib = Get-PowerValue $g.SubSleep $g.HibernateIdle
            $dc = if ($hib.Dc -le 0 -or $hib.Dc -gt 3600) { 3600 } else { $null }
            $ac = if ($hib.Ac -le 0 -and $caps -and $caps.AoAc) { 10800 } else { $null }
            if ($null -ne $dc -or $null -ne $ac) { $undo += Set-PowerValue $g.SubSleep $g.HibernateIdle $ac $dc }
            $undo += Set-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings' 'ShowHibernateOption' 1
            $desc = 'Hibernación activada (con batería, después de 1 hora en suspensión)'
            $msg = 'Listo. La hibernación está activada: con batería, después de 1 hora en suspensión la PC guarda todo y se apaga por completo. Además, «Hibernar» aparece en Inicio → botón de apagado.'
        }
        'tapa' {
            $undo += Set-PowerValue $g.SubButtons $g.LidAction $null 1
            $desc = 'Con batería, la PC se suspende al cerrar la tapa'
            $msg = 'Listo. Con batería, al cerrar la tapa la PC se suspende (y, si la hibernación está activada, después se hiberna).'
        }
        'despertares' {
            $undo += Set-PowerValue $g.SubSleep $g.RtcWake 2 0
            $desc = 'Temporizadores de reactivación apagados con batería'
            $msg = 'Listo. Con batería ningún programa puede despertar la PC; con el cargador, solo las tareas importantes de Windows.'
        }
        'desactivar-inicio-rapido' {
            $undo += Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 0
            $desc = 'Inicio rápido desactivado'
            $msg = 'Listo. El inicio rápido está desactivado: desde ahora «Apagar» cierra Windows y los drivers por completo.'
        }
        'plan-equilibrado' {
            $old = Get-ActivePlan
            [void](Invoke-PowerCfg @('/setactive', $g.Balanced))
            $undo += @{ T = 'scheme'; Guid = $old.Guid }
            $desc = "Plan de energía cambiado a Equilibrado (antes: $($old.Name))"
            $msg = 'Listo. El plan de energía ahora es «Equilibrado».'
        }
        'bajar-temperatura' {
            $v = Get-PowerValue $g.SubProcessor $g.ProcThrottleMax
            $ac = if ($v.Ac -gt 99) { 99 } else { $null }
            $dc = if ($v.Dc -gt 99) { 99 } else { $null }
            if ($null -ne $ac -or $null -ne $dc) { $undo += Set-PowerValue $g.SubProcessor $g.ProcThrottleMax $ac $dc }
            $desc = 'Procesador limitado al 99 % (sin Turbo)'
            $msg = 'Listo. El procesador quedó limitado al 99 %: deja de acelerar al máximo y se calienta mucho menos. Limpia también las rejillas de ventilación.'
        }
        'activar-volcados' {
            $undo += Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' 'CrashDumpEnabled' 3
            $desc = 'Windows guarda un volcado pequeño en cada pantalla azul'
            $msg = 'Listo. Si vuelve a aparecer una pantalla azul, Windows guardará la información para saber la causa.'
        }
        'restaurar-registro' {
            $names = @()
            foreach ($i in @($Arg)) {
                if ($i.Remove) { $undo += Remove-RegValue $i.Path $i.Value }
                else { $undo += Set-RegValue $i.Path $i.Value $i.Restore 'String' }
                $names += $i.Name
            }
            $desc = "Registro restaurado: $($names -join '; ')"
            $msg = 'Listo. Se pusieron los valores normales de Windows. Haz también un examen de virus, porque estos cambios suelen hacerlos los virus.'
        }
        { $_ -in 'quitar-arranque', 'arranque-faltantes' } {
            $names = @()
            foreach ($e in @($Arg)) {
                $bytes = [byte[]](@(3, 0, 0, 0) + [BitConverter]::GetBytes([DateTime]::Now.ToFileTime()))
                $undo += Set-RegValue $e.Approved $e.Name $bytes 'Binary'
                $names += $e.Name
            }
            $desc = "Quitado del arranque: $($names -join ', ')"
            $msg = "Listo. $(if ($names.Count -eq 1) { "«$($names[0])» ya no arranca" } else { "$($names.Count) programas ya no arrancan" }) con Windows. No se desinstaló nada."
        }
        'ignorar-bloqueo' {
            [void](Invoke-PowerCfg @('/requestsoverride', $Arg.Type, $Arg.Name, 'SYSTEM', 'AWAYMODE', 'EXECUTION'))
            $undo += @{ T = 'override'; Type = $Arg.Type; Name = $Arg.Name }
            $desc = "Windows ignora los pedidos de $($Arg.Name) de no suspender"
            $msg = "Listo. Windows ya no hará caso cuando $($Arg.Name) pida que la PC no se suspenda."
        }
        'quitar-despertar' {
            [void](Invoke-PowerCfg @('/devicedisablewake', "$Arg"))
            $undo += @{ T = 'wake'; Device = "$Arg" }
            $desc = "$Arg ya no despierta a la PC"
            $msg = "Listo. «$Arg» ya no puede despertar a la PC."
        }
        'cerrar-programa' {
            $procs = @(Get-Process -Name $Arg.Process -ErrorAction SilentlyContinue)
            foreach ($p in $procs) { try { $p.Kill() } catch { } }
            $desc = "Programa cerrado: $($Arg.Label)"
            $msg = "Listo. Se cerró «$($Arg.Label)»."
        }
        'reparar-windows' {
            $script:Progress.Text = 'Paso 1 de 2: reparando la imagen de Windows con DISM (necesita internet)...'
            $dism = Invoke-External (Join-Path $env:SystemRoot 'System32\dism.exe') @('/Online', '/Cleanup-Image', '/RestoreHealth')
            $script:Progress.Text = 'Paso 2 de 2: revisando todos los archivos de Windows con SFC...'
            $start = Get-Date
            $sfc = Invoke-External (Join-Path $env:SystemRoot 'System32\sfc.exe') @('/scannow') -Unicode
            $res = Get-SfcResult $start
            $desc = 'Reparación de archivos de Windows (DISM + SFC)'
            $dismText = if ($dism.ExitCode -eq 0) { 'DISM terminó bien.' } else { "DISM no pudo terminar (código $($dism.ExitCode)); revisa la conexión a internet." }
            $sfcText = if ($res.CannotRepair) { "SFC encontró $($res.CannotRepair) archivos que no pudo reparar: si las fallas siguen, usa «Restablecer este equipo» manteniendo tus archivos." }
                elseif ($res.Repaired) { "SFC reparó $($res.Repaired) archivos dañados." }
                else { 'SFC no encontró archivos dañados.' }
            $msg = "Terminó la reparación. $dismText $sfcText Reinicia la PC para terminar."
        }
        'liberar-espacio' {
            $before = (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'").FreeSpace
            $limit = (Get-Date).AddDays(-1)
            foreach ($dir in @($env:TEMP, (Join-Path $env:SystemRoot 'Temp')) | Select-Object -Unique) {
                if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { continue }
                $script:Progress.Text = "Borrando archivos temporales de $dir..."
                Get-ChildItem -LiteralPath $dir -Recurse -Force -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -lt $limit } |
                    ForEach-Object { try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop } catch { } }
            }
            $after = (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'").FreeSpace
            $freed = [Math]::Max([double]0, [double]$after - [double]$before)
            $desc = "Archivos temporales borrados ($(Format-Size $freed))"
            $msg = "Listo. Se liberaron $(Format-Size $freed). Para liberar más, usa el Sensor de almacenamiento o el Liberador de espacio en disco (en el paso a paso)."
        }
        'revisar-disco' {
            $r = Invoke-External (Join-Path $env:SystemRoot 'System32\fsutil.exe') @('dirty', 'set', $env:SystemDrive)
            if ($r.ExitCode -ne 0) { throw "No se pudo marcar el disco para revisión: $($r.Output)" }
            $desc = "Disco $env:SystemDrive marcado para revisión al reiniciar"
            $msg = "Listo. La próxima vez que reinicies, Windows revisará y reparará el disco $env:SystemDrive antes de arrancar. Puede tardar un rato: no apagues la PC mientras tanto."
        }
        'prueba-memoria' {
            if (-not $script:TestMode) { Start-Process (Join-Path $env:SystemRoot 'System32\mdsched.exe') }
            $msg = 'Se abrió el Diagnóstico de memoria de Windows. Guarda tu trabajo y elige «Reiniciar ahora y comprobar si existen problemas».'
        }
        'reiniciar' {
            if (-not $script:TestMode) { Restart-Computer -Force }
            $msg = 'Reiniciando...'
        }
        'buscar-cambios' {
            $r = Invoke-External (Join-Path $env:SystemRoot 'System32\pnputil.exe') @('/scan-devices')
            $desc = 'Se volvió a detectar el hardware'
            $msg = 'Listo. Windows volvió a detectar el hardware. Si algún dispositivo sigue sin driver, sigue el paso a paso (Windows Update → Actualizaciones opcionales o la página del fabricante).'
            if ($r.ExitCode -ne 0) { $msg = "Windows no pudo volver a detectar el hardware ($($r.Output)). Sigue el paso a paso." }
        }
        'reinstalar-dispositivo' {
            $pnp = Join-Path $env:SystemRoot 'System32\pnputil.exe'
            $r = Invoke-External $pnp @('/remove-device', $Arg.Id)
            [void](Invoke-External $pnp @('/scan-devices'))
            $desc = "Dispositivo reinstalado: $($Arg.Name)"
            $msg = if ($r.ExitCode -eq 0) { "Listo. Se reinstaló «$($Arg.Name)». Si sigue con problemas, reinicia la PC o busca su driver." }
                   else { "No se pudo reinstalar «$($Arg.Name)»: $($r.Output)" }
        }
        'habilitar-dispositivo' {
            $r = Invoke-External (Join-Path $env:SystemRoot 'System32\pnputil.exe') @('/enable-device', $Arg.Id)
            $desc = "Dispositivo activado: $($Arg.Name)"
            $msg = if ($r.ExitCode -eq 0) { "Listo. «$($Arg.Name)» está activado." } else { "No se pudo activar «$($Arg.Name)»: $($r.Output)" }
        }
        'informe-bateria' {
            $file = Join-Path $script:DataDir 'informe-bateria.html'
            if (-not (Test-Path -LiteralPath $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
            [void](Invoke-PowerCfg @('/batteryreport', '/output', $file))
            Open-Target $file
            $msg = 'Se abrió el informe de batería en el navegador. Compara «DESIGN CAPACITY» (capacidad original) con «FULL CHARGE CAPACITY» (capacidad actual).'
        }
        'buscar-driver' { Open-Target 'ms-settings:windowsupdate-optionalupdates'; $msg = 'Se abrió Windows Update. Entra a «Actualizaciones opcionales» → «Actualizaciones de controladores». Si no aparece nada, usa el paso a paso para descargarlo de la página del fabricante.' }
        'abrir-seguridad' { Open-Target 'windowsdefender://threat'; $msg = 'Se abrió Seguridad de Windows.' }
        default { throw "Arreglo desconocido: $Id" }
    }
    @{ Message = $msg; Undo = @($undo | Where-Object { $_ }); Description = $desc }
}

# Lee el CBS.log para saber qué hizo SFC desde que empezó
function Get-SfcResult([datetime]$Since) {
    $res = @{ Repaired = 0; CannotRepair = 0 }
    try {
        $log = Join-Path $env:SystemRoot 'Logs\CBS\CBS.log'
        $fs = [IO.File]::Open($log, 'Open', 'Read', 'ReadWrite')
        $reader = New-Object IO.StreamReader($fs)
        try {
            while ($null -ne ($line = $reader.ReadLine())) {
                if ($line -notmatch '\[SR\]') { continue }
                if ($line -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})') {
                    if ([datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', $null) -lt $Since.AddSeconds(-5)) { continue }
                }
                if ($line -match 'Cannot repair member file') { $res.CannotRepair++ }
                elseif ($line -match 'Repairing corrupted file|Repaired file') { $res.Repaired++ }
            }
        } finally { $reader.Close() }
    } catch { }
    $res
}

function Undo-Record($Record) {
    switch ($Record.T) {
        'power' {
            if ($null -ne $Record.Ac) { [void](Invoke-PowerCfg @('/setacvalueindex', 'SCHEME_CURRENT', $Record.Sub, $Record.Setting, "$($Record.Ac)")) }
            if ($null -ne $Record.Dc) { [void](Invoke-PowerCfg @('/setdcvalueindex', 'SCHEME_CURRENT', $Record.Sub, $Record.Setting, "$($Record.Dc)")) }
            [void](Invoke-PowerCfg @('/setactive', 'SCHEME_CURRENT'))
        }
        'scheme' { [void](Invoke-PowerCfg @('/setactive', $Record.Guid)) }
        'hibernate-off' { [void](Invoke-PowerCfg @('/hibernate', 'off')) }
        'override' { [void](Invoke-PowerCfg @('/requestsoverride', $Record.Type, $Record.Name)) }
        'wake' { [void](Invoke-PowerCfg @('/deviceenablewake', $Record.Device)) }
        'reg' {
            if ($Record.Existed) {
                $value = switch ($Record.Kind) {
                    'Binary'      { [byte[]][Convert]::FromBase64String($Record.Value) }
                    'MultiString' { [string[]]@($Record.Value) }
                    'DWord'       { [int]$Record.Value }
                    'QWord'       { [long]$Record.Value }
                    default       { "$($Record.Value)" }
                }
                if (-not (Test-Path -LiteralPath $Record.Path)) { New-Item -Path $Record.Path -Force | Out-Null }
                New-ItemProperty -LiteralPath $Record.Path -Name $Record.Name -Value $value -PropertyType $Record.Kind -Force | Out-Null
            } else {
                Remove-ItemProperty -LiteralPath $Record.Path -Name $Record.Name -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Get-ChangeLog {
    $file = Join-Path $script:DataDir 'cambios.json'
    try {
        if (Test-Path -LiteralPath $file) {
            # En PowerShell 5.1, ConvertFrom-Json no separa los elementos del arreglo: se devuelve la variable
            $data = (Get-Content -LiteralPath $file -Raw -Encoding UTF8) | ConvertFrom-Json
            return $data
        }
    } catch { }
}

function Save-ChangeLog($Changes) {
    if (-not (Test-Path -LiteralPath $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
    ConvertTo-Json -InputObject @($Changes) -Depth 8 | Set-Content -LiteralPath (Join-Path $script:DataDir 'cambios.json') -Encoding UTF8
}

function Add-ChangeLog([string]$Description, $Undo) {
    if (-not $Description) { return }
    $entry = [pscustomobject]@{
        Id = [guid]::NewGuid().ToString('N'); Fecha = (Get-Date).ToString('dd/MM/yyyy HH:mm'); Descripcion = $Description
        Undo = @($Undo); Deshecho = $false
    }
    $all = @(Get-ChangeLog) + $entry
    Save-ChangeLog ($all | Select-Object -Last 200)
    Write-Log "Cambio: $Description"
    $entry
}

function Undo-Change([string]$Id) {
    $all = @(Get-ChangeLog)
    $entry = $all | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if (-not $entry -or $entry.Deshecho) { return $null }
    $records = @($entry.Undo)
    [array]::Reverse($records)
    foreach ($r in $records) { Undo-Record $r }
    $entry.Deshecho = $true
    Save-ChangeLog $all
    Write-Log "Deshecho: $($entry.Descripcion)"
    $entry
}

function New-RestorePoint {
    if ($script:TestMode) { return 'Prueba: no se crea un punto de restauración.' }
    try {
        Checkpoint-Computer -Description 'Diagnóstico PC' -RestorePointType MODIFY_SETTINGS -WarningAction Stop -ErrorAction Stop
        $null
    } catch {
        'No se pudo crear un punto de restauración (Restaurar sistema está apagado o ya se creó uno hoy), pero el cambio se puede deshacer en «Herramientas y cambios».'
    }
}

# Abre una ventana de Windows, una página web o un archivo. "programa|argumentos" para pasar argumentos.
function Open-Target([string]$Target) {
    if (-not $Target -or $script:TestMode) { return }
    if ($Target -match '^(https?:|[a-zA-Z]:\\.+\.html?$)') {
        # Con explorer.exe el navegador no se abre con permisos de administrador
        Start-Process explorer.exe -ArgumentList "`"$Target`""
    } elseif ($Target -match '\|') {
        $parts = $Target -split '\|', 2
        Start-Process -FilePath $parts[0] -ArgumentList $parts[1]
    } else {
        Start-Process $Target
    }
}

#endregion

#region Informe en HTML y consola

function ConvertTo-HtmlText([string]$Text) { [System.Net.WebUtility]::HtmlEncode($Text) -replace "`n", '<br>' }

function Get-SortedFindings($Findings) {
    @($Findings | Sort-Object @{ Expression = { [DiagnosticoPC.Levels]::Order($_.Level) } }, @{ Expression = { @($script:Areas.Keys).IndexOf($_.Area) } })
}

function Export-Report($Findings, [string]$Path) {
    Initialize-Types
    $pc = Get-CachedPcInfo
    $sorted = Get-SortedFindings $Findings
    $count = @{ Rojo = 0; Amarillo = 0; Verde = 0; Info = 0 }
    foreach ($f in $sorted) { $count[$f.Level]++ }
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append(@"
<!doctype html><html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Diagnóstico PC · $(ConvertTo-HtmlText "$($pc.Manufacturer) $($pc.Model)")</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;background:#f3f3f3;color:#1a1a1a;margin:0;padding:24px;font-size:16px;line-height:1.5}
main{max-width:980px;margin:0 auto}h1{font-size:30px;margin:0}h2{font-size:21px;margin:0 0 4px}.sub{color:#555;margin:4px 0 20px}
.counts{display:flex;gap:12px;margin-bottom:20px;flex-wrap:wrap}.count{flex:1;min-width:150px;border-radius:10px;padding:14px 18px;font-weight:600}
.count b{display:block;font-size:34px}.Rojo{background:#fde7e9;color:#c42b1c}.Amarillo{background:#fff4ce;color:#9d5d00}.Verde{background:#dff6dd;color:#0f7b0f}.Info{background:#e5f0fb;color:#0067c0}
.card{background:#fff;border:1px solid #e5e5e5;border-left-width:8px;border-radius:10px;padding:16px 20px;margin-bottom:14px}
.card.Rojo{border-left-color:#c42b1c}.card.Amarillo{border-left-color:#e0a100}.card.Verde{border-left-color:#0f7b0f}.card.Info{border-left-color:#0067c0}
.tag{display:inline-block;font-size:12px;font-weight:700;border-radius:8px;padding:2px 10px;margin-right:8px}.area{color:#555;font-size:13px;text-transform:uppercase;letter-spacing:.5px}
.summary{color:#444;margin:2px 0 8px;font-weight:600}table{border-collapse:collapse;width:100%;margin:8px 0;font-size:14px}td{border-top:1px solid #eee;padding:6px 4px;vertical-align:top}
ol{margin:8px 0 0 0;padding-left:22px}li{margin-bottom:6px}code{background:#f0f0f0;padding:1px 6px;border-radius:4px}.path{color:#555;font-size:14px}footer{color:#666;font-size:13px;margin-top:24px}
</style></head><body><main>
<h1>Diagnóstico PC</h1>
<p class="sub">$(ConvertTo-HtmlText "$($pc.Manufacturer) $($pc.Model) · $($pc.OS) · $($pc.Cpu) · $($pc.RamGB) GB de RAM") · Análisis del $(ConvertTo-HtmlText (Format-Date (Get-Date)))</p>
<div class="counts"><div class="count Rojo"><b>$($count.Rojo)</b>Graves</div><div class="count Amarillo"><b>$($count.Amarillo)</b>Para revisar</div><div class="count Verde"><b>$($count.Verde)</b>Bien</div></div>
"@)
    foreach ($f in $sorted) {
        $label = [DiagnosticoPC.Levels]::Text($f.Level)
        [void]$sb.Append("<section class=""card $($f.Level)""><div class=""area""><span class=""tag $($f.Level)"">$label</span>$(ConvertTo-HtmlText $f.Area)</div>")
        [void]$sb.Append("<h2>$(ConvertTo-HtmlText $f.Title)</h2><div class=""summary"">$(ConvertTo-HtmlText $f.Summary)</div><p>$(ConvertTo-HtmlText $f.Detail)</p>")
        if ($f.Items.Count) {
            [void]$sb.Append('<table>')
            foreach ($i in $f.Items) { [void]$sb.Append("<tr><td><b>$(ConvertTo-HtmlText $i.Name)</b></td><td>$(ConvertTo-HtmlText $i.Detail)</td></tr>") }
            [void]$sb.Append('</table>')
        }
        if ($f.Level -in 'Rojo', 'Amarillo' -and $f.Steps.Count) {
            [void]$sb.Append('<b>Paso a paso para arreglarlo</b><ol>')
            foreach ($s in $f.Steps) {
                [void]$sb.Append("<li><b>$(ConvertTo-HtmlText $s.Title)</b>")
                if ($s.Path) { [void]$sb.Append("<div class=""path"">$(ConvertTo-HtmlText $s.Path)</div>") }
                if ($s.Text) { [void]$sb.Append("<div>$(ConvertTo-HtmlText $s.Text)</div>") }
                if ($s.Command) { [void]$sb.Append("<div><code>$(ConvertTo-HtmlText $s.Command)</code></div>") }
                [void]$sb.Append('</li>')
            }
            [void]$sb.Append('</ol>')
        }
        [void]$sb.Append('</section>')
    }
    [void]$sb.Append("<footer>Generado por Diagnóstico PC $script:AppVersion · GarridoitSolutions</footer></main></body></html>")
    [IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object Text.UTF8Encoding($true)))
}

function Write-ConsoleReport($Findings) {
    $colors = @{ Rojo = 'Red'; Amarillo = 'Yellow'; Verde = 'Green'; Info = 'Cyan' }
    $pc = Get-CachedPcInfo
    Write-Host "Diagnóstico PC $script:AppVersion · $($pc.Manufacturer) $($pc.Model) · $($pc.OS)"
    foreach ($f in Get-SortedFindings $Findings) {
        Write-Host ('[{0,-11}] {1,-20} {2}' -f [DiagnosticoPC.Levels]::Text($f.Level), $f.Area, $f.Title) -ForegroundColor $colors[$f.Level]
        if ($f.Summary) { Write-Host ('{0,36}{1}' -f '', $f.Summary) -ForegroundColor Gray }
    }
}

#endregion

#region Ventana: diseño

$script:XamlResources = @'
    <SolidColorBrush x:Key="Accent" Color="#4F46E5"/>
    <SolidColorBrush x:Key="AccentHover" Color="#6366F1"/>
    <SolidColorBrush x:Key="AccentPressed" Color="#4338CA"/>
    <SolidColorBrush x:Key="AccentLight" Color="#EEF0FF"/>
    <SolidColorBrush x:Key="CardBorder" Color="#E5E5E5"/>
    <SolidColorBrush x:Key="TextSecondary" Color="#555555"/>
    <FontFamily x:Key="Icons">Segoe Fluent Icons, Segoe MDL2 Assets</FontFamily>
    <BooleanToVisibilityConverter x:Key="BoolVis"/>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="White"/>
      <Setter Property="BorderBrush" Value="{StaticResource CardBorder}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="10"/>
      <Setter Property="Padding" Value="18"/>
    </Style>

    <Style x:Key="Icon" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="{StaticResource Icons}"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="HorizontalAlignment" Value="Center"/>
    </Style>

    <Style x:Key="PrimaryButton" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Background" Value="{StaticResource Accent}"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="22,10"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="7" Padding="{TemplateBinding Padding}">
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
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Padding" Value="14,8"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="HorizontalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="#CFCFCF" BorderThickness="1"
                    CornerRadius="7" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#F5F5F5"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="#A9A9A9"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#EBEBEB"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="SmallButton" TargetType="Button" BasedOn="{StaticResource SubtleButton}">
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Padding" Value="12,6"/>
    </Style>

    <Style x:Key="TabButton" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#444444"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="14,10"/>
      <Setter Property="Margin" Value="0,0,6,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid Background="Transparent">
              <Border x:Name="Bg" CornerRadius="7" Margin="0,0,0,6" Background="Transparent"/>
              <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
              <Border x:Name="Line" Height="3" CornerRadius="2" VerticalAlignment="Bottom" Margin="10,0" Background="Transparent"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bg" Property="Background" Value="#E9E9EF"/>
              </Trigger>
              <Trigger Property="Tag" Value="sel">
                <Setter TargetName="Line" Property="Background" Value="{StaticResource Accent}"/>
                <Setter Property="Foreground" Value="{StaticResource Accent}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="CounterButton" TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="2"
                    CornerRadius="10" Padding="16,12">
              <ContentPresenter HorizontalAlignment="Left" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Opacity" Value="0.88"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="CheckBox">
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="Margin" Value="0,5"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Cursor" Value="Hand"/>
    </Style>
'@

$script:Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Diagnóstico PC" Width="1220" Height="800" MinWidth="980" MinHeight="680"
        WindowStartupLocation="CenterScreen" Background="#F3F3F3"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="14" Foreground="#1A1A1A"
        TextOptions.TextFormattingMode="Display" UseLayoutRounding="True">
  <Window.Resources>
<!--RECURSOS-->
    <Style x:Key="FindingItemStyle" TargetType="ListBoxItem">
      <Setter Property="Padding" Value="10,9"/>
      <Setter Property="Margin" Value="0,1"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="Bd" Background="Transparent" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#F4F4F6"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource AccentLight}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="PlainItemStyle" TargetType="ListBoxItem">
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <ContentPresenter/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <DataTemplate x:Key="FindingTemplate">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Border Width="40" Height="40" CornerRadius="20" Background="{Binding LevelBg}" Margin="0,0,12,0" VerticalAlignment="Top">
          <TextBlock Style="{StaticResource Icon}" Text="{Binding LevelGlyph}" FontSize="17" Foreground="{Binding LevelFg}"/>
        </Border>
        <StackPanel Grid.Column="1">
          <TextBlock Text="{Binding AreaLine}" FontSize="11" FontWeight="Bold" Foreground="{Binding LevelFg}"/>
          <TextBlock Text="{Binding Title}" FontSize="15" FontWeight="SemiBold" TextWrapping="Wrap"/>
          <TextBlock Text="{Binding Summary}" FontSize="13" Foreground="#555555" TextWrapping="Wrap" Margin="0,1,0,0"/>
        </StackPanel>
      </Grid>
    </DataTemplate>

    <DataTemplate x:Key="ItemRowTemplate">
      <Border BorderBrush="#EEEEEE" BorderThickness="0,1,0,0" Padding="0,10">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <StackPanel>
            <TextBlock Text="{Binding Name}" FontWeight="SemiBold" FontSize="14" TextWrapping="Wrap"/>
            <TextBlock Text="{Binding Detail}" Foreground="#555555" FontSize="13" TextWrapping="Wrap"
                       Visibility="{Binding HasDetail, Converter={StaticResource BoolVis}}"/>
            <TextBlock Text="{Binding Status}" Foreground="#0B5394" FontSize="13" FontWeight="SemiBold" TextWrapping="Wrap" Margin="0,3,0,0"
                       Visibility="{Binding HasStatus, Converter={StaticResource BoolVis}}"/>
          </StackPanel>
          <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center" Margin="12,0,0,0">
            <Button Tag="1" Content="{Binding ActionText}" Style="{StaticResource SmallButton}" IsEnabled="{Binding IsEnabled}"
                    Visibility="{Binding HasAction, Converter={StaticResource BoolVis}}"/>
            <Button Tag="2" Content="{Binding Action2Text}" Style="{StaticResource SmallButton}" Margin="8,0,0,0" IsEnabled="{Binding IsEnabled}"
                    Visibility="{Binding HasAction2, Converter={StaticResource BoolVis}}"/>
          </StackPanel>
        </Grid>
      </Border>
    </DataTemplate>

    <DataTemplate x:Key="ChangeTemplate">
      <Border BorderBrush="#EEEEEE" BorderThickness="0,0,0,1" Padding="0,10">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <StackPanel>
            <TextBlock Text="{Binding Description}" FontWeight="SemiBold" TextWrapping="Wrap"/>
            <TextBlock FontSize="13" Foreground="#555555">
              <Run Text="{Binding Date, Mode=OneWay}"/><Run Text="  ·  "/><Run Text="{Binding Status, Mode=OneWay}"/>
            </TextBlock>
          </StackPanel>
          <Button Grid.Column="1" Tag="undo" Style="{StaticResource SmallButton}" Margin="12,0,0,0" VerticalAlignment="Center"
                  IsEnabled="{Binding CanUndo}">
            <StackPanel Orientation="Horizontal">
              <TextBlock Style="{StaticResource Icon}" Text="&#xE7A7;" Margin="0,0,6,0"/>
              <TextBlock Text="Deshacer"/>
            </StackPanel>
          </Button>
        </Grid>
      </Border>
    </DataTemplate>

    <DataTemplate x:Key="AlertTemplate">
      <Border BorderBrush="#EEEEEE" BorderThickness="0,0,0,1" Padding="0,10">
        <StackPanel>
          <TextBlock FontSize="13" Foreground="#555555" Text="{Binding Time}"/>
          <TextBlock FontWeight="SemiBold" FontSize="15" TextWrapping="Wrap" Text="{Binding Title}"/>
          <TextBlock TextWrapping="Wrap" Foreground="#333333" Text="{Binding Text}"/>
        </StackPanel>
      </Border>
    </DataTemplate>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <!-- ===== Encabezado ===== -->
    <Grid Grid.Row="0" Margin="28,20,28,6">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <Border Width="52" Height="52" CornerRadius="14" Margin="0,0,14,0">
        <Border.Background>
          <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
            <GradientStop Color="#6D5DF6" Offset="0"/>
            <GradientStop Color="#4338CA" Offset="1"/>
          </LinearGradientBrush>
        </Border.Background>
        <TextBlock Style="{StaticResource Icon}" Text="&#xE9D9;" FontSize="26" Foreground="White"/>
      </Border>
      <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="0,0,16,0">
        <TextBlock Text="Diagnóstico PC" FontSize="27" FontWeight="SemiBold" FontFamily="Segoe UI Variable Display, Segoe UI"/>
        <TextBlock x:Name="TxtSubtitle" Foreground="{StaticResource TextSecondary}" FontSize="14" TextWrapping="Wrap"
                   Text="Encuentra lo que calienta, frena o traba tu PC, y te enseña a arreglarlo."/>
      </StackPanel>
      <Button x:Name="BtnSupport" Grid.Column="2" Style="{StaticResource SubtleButton}" Padding="14,10" Margin="0,0,12,0"
              VerticalAlignment="Center" Visibility="Collapsed" ToolTip="Abre la página de apoyo en tu navegador">
        <StackPanel Orientation="Horizontal">
          <TextBlock Style="{StaticResource Icon}" Text="&#xEB52;" Foreground="#FF5E5B" Margin="0,0,8,0"/>
          <TextBlock Text="Apoyar a la app" FontWeight="SemiBold"/>
        </StackPanel>
      </Button>
      <Border Grid.Column="3" Style="{StaticResource Card}" Padding="14,10" VerticalAlignment="Center" MaxWidth="360">
        <StackPanel Orientation="Horizontal">
          <TextBlock x:Name="PcGlyph" Style="{StaticResource Icon}" Text="&#xE7F8;" FontSize="26" Foreground="{StaticResource Accent}" Margin="0,0,12,0"/>
          <StackPanel>
            <TextBlock x:Name="PcModel" FontWeight="SemiBold" Text="Este equipo" TextTrimming="CharacterEllipsis"/>
            <TextBlock x:Name="PcDetails" FontSize="12" Foreground="{StaticResource TextSecondary}" TextTrimming="CharacterEllipsis"/>
          </StackPanel>
        </StackPanel>
      </Border>
    </Grid>

    <!-- ===== Pestañas ===== -->
    <DockPanel Grid.Row="1" Margin="22,4,28,0" LastChildFill="False">
      <Button x:Name="TabResults" Style="{StaticResource TabButton}" Tag="sel">
        <StackPanel Orientation="Horizontal">
          <TextBlock Style="{StaticResource Icon}" Text="&#xE9D9;" Margin="0,0,8,0"/>
          <TextBlock Text="Diagnóstico"/>
        </StackPanel>
      </Button>
      <Button x:Name="TabAlerts" Style="{StaticResource TabButton}">
        <StackPanel Orientation="Horizontal">
          <TextBlock Style="{StaticResource Icon}" Text="&#xEA8F;" Margin="0,0,8,0"/>
          <TextBlock Text="Avisos"/>
        </StackPanel>
      </Button>
      <Button x:Name="TabTools" Style="{StaticResource TabButton}">
        <StackPanel Orientation="Horizontal">
          <TextBlock Style="{StaticResource Icon}" Text="&#xE90F;" Margin="0,0,8,0"/>
          <TextBlock Text="Herramientas y cambios"/>
        </StackPanel>
      </Button>
      <Button x:Name="BtnRescan" DockPanel.Dock="Right" Style="{StaticResource PrimaryButton}" Padding="18,9" FontSize="14" VerticalAlignment="Center" Visibility="Collapsed">
        <StackPanel Orientation="Horizontal">
          <TextBlock Style="{StaticResource Icon}" Text="&#xE72C;" Foreground="White" Margin="0,0,8,0"/>
          <TextBlock Text="Analizar de nuevo"/>
        </StackPanel>
      </Button>
      <Button x:Name="BtnReport" DockPanel.Dock="Right" Style="{StaticResource SubtleButton}" Padding="16,9" Margin="0,0,10,0" VerticalAlignment="Center" Visibility="Collapsed"
              ToolTip="Guarda el diagnóstico en un archivo para enviarlo o imprimirlo">
        <StackPanel Orientation="Horizontal">
          <TextBlock Style="{StaticResource Icon}" Text="&#xE74E;" Margin="0,0,8,0"/>
          <TextBlock Text="Guardar informe"/>
        </StackPanel>
      </Button>
    </DockPanel>

    <!-- ===== Inicio ===== -->
    <Grid x:Name="PageHome" Grid.Row="2" Margin="28,12,28,24">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="1.05*"/>
        <ColumnDefinition Width="20"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <Border Style="{StaticResource Card}" Padding="38,30">
        <StackPanel VerticalAlignment="Center">
          <Border Width="92" Height="92" CornerRadius="24" HorizontalAlignment="Left">
            <Border.Background>
              <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                <GradientStop Color="#6D5DF6" Offset="0"/>
                <GradientStop Color="#4338CA" Offset="1"/>
              </LinearGradientBrush>
            </Border.Background>
            <TextBlock Style="{StaticResource Icon}" Text="&#xE9D9;" FontSize="44" Foreground="White"/>
          </Border>
          <TextBlock Text="Revisa tu PC en un minuto" FontSize="32" FontWeight="SemiBold" Margin="0,24,0,10"
                     FontFamily="Segoe UI Variable Display, Segoe UI" TextWrapping="Wrap"/>
          <TextBlock FontSize="17" LineHeight="26" TextWrapping="Wrap" Foreground="#333333"
                     Text="Diagnóstico PC busca lo que hace que tu computadora se caliente, se ponga lenta o muestre pantallas azules. Te muestra cada cosa en rojo, amarillo o verde, con el paso a paso para arreglarla."/>
          <StackPanel Orientation="Horizontal" Margin="0,22,0,0">
            <Border Background="#FDE7E9" CornerRadius="12" Padding="12,5" Margin="0,0,8,0">
              <TextBlock Text="Rojo: grave" Foreground="#C42B1C" FontWeight="SemiBold"/>
            </Border>
            <Border Background="#FFF4CE" CornerRadius="12" Padding="12,5" Margin="0,0,8,0">
              <TextBlock Text="Amarillo: revisar" Foreground="#9D5D00" FontWeight="SemiBold"/>
            </Border>
            <Border Background="#DFF6DD" CornerRadius="12" Padding="12,5">
              <TextBlock Text="Verde: bien" Foreground="#0F7B0F" FontWeight="SemiBold"/>
            </Border>
          </StackPanel>
          <Button x:Name="BtnAnalyze" Style="{StaticResource PrimaryButton}" FontSize="19" Padding="36,15" HorizontalAlignment="Left" Margin="0,28,0,0">
            <StackPanel Orientation="Horizontal">
              <TextBlock Style="{StaticResource Icon}" Text="&#xE721;" Foreground="White" FontSize="19" Margin="0,0,12,0"/>
              <TextBlock Text="Analizar mi PC"/>
            </StackPanel>
          </Button>
          <TextBlock x:Name="HomeLast" Margin="2,14,0,0" Foreground="#555555" FontSize="14" TextWrapping="Wrap"
                     Text="Tarda alrededor de un minuto. No cambia nada sin preguntarte."/>
        </StackPanel>
      </Border>
      <Border Grid.Column="2" Style="{StaticResource Card}" Padding="24,20">
        <DockPanel>
          <TextBlock DockPanel.Dock="Top" Text="Qué revisa" FontSize="19" FontWeight="SemiBold" Margin="2,0,0,10"/>
          <UniformGrid x:Name="HomeAreas" Columns="2"/>
        </DockPanel>
      </Border>
    </Grid>

    <!-- ===== Resultados ===== -->
    <Grid x:Name="PageResults" Grid.Row="2" Margin="28,12,28,24" Visibility="Collapsed">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>
      <Grid Margin="0,0,0,14">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Button x:Name="CntRojo" Style="{StaticResource CounterButton}" Background="#FDE7E9" Margin="0,0,12,0" ToolTip="Toca para ver solo estos">
          <StackPanel Orientation="Horizontal">
            <Border Width="44" Height="44" CornerRadius="22" Background="White">
              <TextBlock Style="{StaticResource Icon}" Text="&#xE711;" FontSize="18" Foreground="#C42B1C"/>
            </Border>
            <TextBlock x:Name="CntRojoN" Text="0" FontSize="32" FontWeight="Bold" Foreground="#C42B1C" Margin="14,0,12,0" VerticalAlignment="Center"/>
            <StackPanel VerticalAlignment="Center">
              <TextBlock Text="Graves" FontSize="17" FontWeight="SemiBold" Foreground="#C42B1C"/>
              <TextBlock Text="Arréglalos primero" FontSize="13" Foreground="#8A2A20"/>
            </StackPanel>
          </StackPanel>
        </Button>
        <Button x:Name="CntAmarillo" Grid.Column="1" Style="{StaticResource CounterButton}" Background="#FFF4CE" Margin="0,0,12,0" ToolTip="Toca para ver solo estos">
          <StackPanel Orientation="Horizontal">
            <Border Width="44" Height="44" CornerRadius="22" Background="White">
              <TextBlock Style="{StaticResource Icon}" Text="&#xE7BA;" FontSize="18" Foreground="#9D5D00"/>
            </Border>
            <TextBlock x:Name="CntAmarilloN" Text="0" FontSize="32" FontWeight="Bold" Foreground="#9D5D00" Margin="14,0,12,0" VerticalAlignment="Center"/>
            <StackPanel VerticalAlignment="Center">
              <TextBlock Text="Para revisar" FontSize="17" FontWeight="SemiBold" Foreground="#9D5D00"/>
              <TextBlock Text="Conviene arreglarlos" FontSize="13" Foreground="#6B4A00"/>
            </StackPanel>
          </StackPanel>
        </Button>
        <Button x:Name="CntVerde" Grid.Column="2" Style="{StaticResource CounterButton}" Background="#DFF6DD" ToolTip="Toca para ver solo estos">
          <StackPanel Orientation="Horizontal">
            <Border Width="44" Height="44" CornerRadius="22" Background="White">
              <TextBlock Style="{StaticResource Icon}" Text="&#xE73E;" FontSize="18" Foreground="#0F7B0F"/>
            </Border>
            <TextBlock x:Name="CntVerdeN" Text="0" FontSize="32" FontWeight="Bold" Foreground="#0F7B0F" Margin="14,0,12,0" VerticalAlignment="Center"/>
            <StackPanel VerticalAlignment="Center">
              <TextBlock Text="Bien" FontSize="17" FontWeight="SemiBold" Foreground="#0F7B0F"/>
              <TextBlock Text="No hace falta hacer nada" FontSize="13" Foreground="#1D5E1D"/>
            </StackPanel>
          </StackPanel>
        </Button>
      </Grid>

      <Grid Grid.Row="1">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="430"/>
          <ColumnDefinition Width="16"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Border Style="{StaticResource Card}" Padding="8">
          <DockPanel>
            <TextBlock x:Name="TxtFilter" DockPanel.Dock="Top" Margin="10,6,10,6" FontSize="13" Foreground="{StaticResource TextSecondary}" TextWrapping="Wrap"/>
            <ListBox x:Name="FindingList" BorderThickness="0" Background="Transparent"
                     ItemContainerStyle="{StaticResource FindingItemStyle}" ItemTemplate="{StaticResource FindingTemplate}"
                     ScrollViewer.HorizontalScrollBarVisibility="Disabled"/>
          </DockPanel>
        </Border>
        <Border Grid.Column="2" Style="{StaticResource Card}" Padding="0">
          <Grid>
            <TextBlock x:Name="DetailEmpty" Text="Elige un resultado de la lista para ver qué pasa y cómo arreglarlo." FontSize="16"
                       Foreground="{StaticResource TextSecondary}" HorizontalAlignment="Center" VerticalAlignment="Center" TextWrapping="Wrap" Margin="40"/>
            <ScrollViewer x:Name="DetailScroll" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
              <StackPanel x:Name="DetailPanel" Margin="24,20,24,22">
                <Border Background="{Binding LevelBg}" CornerRadius="10" Padding="18,16">
                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="Auto"/>
                      <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <Border Width="56" Height="56" CornerRadius="28" Background="White" VerticalAlignment="Top">
                      <TextBlock Style="{StaticResource Icon}" Text="{Binding LevelGlyph}" FontSize="24" Foreground="{Binding LevelFg}"/>
                    </Border>
                    <StackPanel Grid.Column="1" Margin="16,0,0,0" VerticalAlignment="Center">
                      <StackPanel Orientation="Horizontal">
                        <Border Background="{Binding LevelFg}" CornerRadius="9" Padding="10,2">
                          <TextBlock Text="{Binding LevelText}" Foreground="White" FontSize="11" FontWeight="Bold"/>
                        </Border>
                        <TextBlock Text="{Binding Area}" Margin="10,0,0,0" Foreground="{Binding LevelFg}" FontWeight="SemiBold" VerticalAlignment="Center"/>
                      </StackPanel>
                      <TextBlock Text="{Binding Title}" FontSize="23" FontWeight="SemiBold" TextWrapping="Wrap" Margin="0,6,0,2"
                                 FontFamily="Segoe UI Variable Display, Segoe UI"/>
                      <TextBlock Text="{Binding Summary}" FontSize="15" TextWrapping="Wrap" Foreground="#333333"/>
                    </StackPanel>
                  </Grid>
                </Border>
                <WrapPanel Margin="0,16,0,0">
                  <Button x:Name="BtnFix" Style="{StaticResource PrimaryButton}" Margin="0,0,10,8" Visibility="{Binding HasFix, Converter={StaticResource BoolVis}}">
                    <StackPanel Orientation="Horizontal">
                      <TextBlock Style="{StaticResource Icon}" Text="&#xE90F;" Foreground="White" Margin="0,0,9,0"/>
                      <TextBlock Text="{Binding FixText}"/>
                    </StackPanel>
                  </Button>
                  <Button x:Name="BtnSteps" Style="{StaticResource SubtleButton}" Padding="18,10" Margin="0,0,10,8" FontSize="15"
                          Visibility="{Binding HasSteps, Converter={StaticResource BoolVis}}">
                    <StackPanel Orientation="Horizontal">
                      <TextBlock Style="{StaticResource Icon}" Text="&#xE8FD;" Margin="0,0,9,0"/>
                      <TextBlock Text="Ver el paso a paso" FontWeight="SemiBold"/>
                    </StackPanel>
                  </Button>
                  <Button x:Name="BtnRecheck" Style="{StaticResource SubtleButton}" Padding="18,10" Margin="0,0,10,8" FontSize="15">
                    <StackPanel Orientation="Horizontal">
                      <TextBlock Style="{StaticResource Icon}" Text="&#xE72C;" Margin="0,0,9,0"/>
                      <TextBlock Text="Volver a revisar"/>
                    </StackPanel>
                  </Button>
                </WrapPanel>
                <TextBlock Text="Qué pasa" FontSize="18" FontWeight="SemiBold" Margin="0,10,0,6"/>
                <TextBlock Text="{Binding Detail}" FontSize="15" TextWrapping="Wrap" LineHeight="24"/>
                <StackPanel Margin="0,18,0,0" Visibility="{Binding HasItems, Converter={StaticResource BoolVis}}">
                  <TextBlock Text="Detalle" FontSize="18" FontWeight="SemiBold" Margin="0,0,0,6"/>
                  <ItemsControl x:Name="DetailItems" ItemsSource="{Binding Items}" ItemTemplate="{StaticResource ItemRowTemplate}"/>
                </StackPanel>
                <Border Background="#F6F6F8" CornerRadius="8" Padding="14,10" Margin="0,20,0,0">
                  <StackPanel Orientation="Horizontal">
                    <TextBlock Style="{StaticResource Icon}" Text="&#xE72E;" Foreground="{StaticResource Accent}" Margin="0,0,10,0" VerticalAlignment="Top"/>
                    <TextBlock FontSize="13" Foreground="#444444" TextWrapping="Wrap" MaxWidth="560"
                               Text="Antes de cambiar algo, Diagnóstico PC te pregunta, crea un punto de restauración y guarda el valor anterior: puedes deshacerlo en «Herramientas y cambios»."/>
                  </StackPanel>
                </Border>
              </StackPanel>
            </ScrollViewer>
          </Grid>
        </Border>
      </Grid>
    </Grid>

    <!-- ===== Avisos ===== -->
    <Grid x:Name="PageAlerts" Grid.Row="2" Margin="28,12,28,24" Visibility="Collapsed">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="20"/>
        <ColumnDefinition Width="0.8*"/>
      </Grid.ColumnDefinitions>
      <Border Style="{StaticResource Card}" Padding="28,24">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel>
            <TextBlock Text="Avisos junto al reloj" FontSize="22" FontWeight="SemiBold"/>
            <TextBlock FontSize="15" LineHeight="23" TextWrapping="Wrap" Foreground="#444444" Margin="0,6,0,0"
                       Text="Mientras Diagnóstico PC esté abierta (o junto al reloj de Windows), revisa la PC cada pocos minutos y te muestra una notificación si aparece un problema. Al hacer clic en la notificación se abre el problema con su paso a paso."/>
            <CheckBox x:Name="ChkAlerts" Content="Avisarme cuando aparezca un problema" FontSize="17" FontWeight="SemiBold" Margin="0,18,0,8"/>
            <StackPanel x:Name="AlertOptions" Margin="26,0,0,0">
              <CheckBox x:Name="ChkAlertBsod" Content="Pantallas azules y apagones de golpe"/>
              <CheckBox x:Name="ChkAlertTemp" Content="Temperatura alta o procesador frenado por calor"/>
              <CheckBox x:Name="ChkAlertCpu" Content="Un programa usa mucho el procesador durante varios minutos"/>
              <CheckBox x:Name="ChkAlertMem" Content="La memoria está casi llena"/>
              <CheckBox x:Name="ChkAlertDisk" Content="Queda poco espacio en el disco"/>
              <CheckBox x:Name="ChkAlertWake" Content="La PC se despertó sola de madrugada"/>
              <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                <TextBlock Text="Revisar cada" VerticalAlignment="Center" FontSize="15"/>
                <ComboBox x:Name="CbInterval" Width="90" Margin="10,0" FontSize="15" VerticalContentAlignment="Center"/>
                <TextBlock Text="minutos" VerticalAlignment="Center" FontSize="15"/>
              </StackPanel>
            </StackPanel>
            <Border Height="1" Background="#E5E5E5" Margin="0,18"/>
            <CheckBox x:Name="ChkKeep" Content="Al cerrar la ventana, seguir avisando junto al reloj"/>
            <CheckBox x:Name="ChkStartup" Content="Iniciar con Windows (junto al reloj, sin abrir la ventana)"/>
            <Button x:Name="BtnTestAlert" Style="{StaticResource SubtleButton}" HorizontalAlignment="Left" Margin="0,16,0,0" Padding="16,9">
              <StackPanel Orientation="Horizontal">
                <TextBlock Style="{StaticResource Icon}" Text="&#xEA8F;" Margin="0,0,8,0"/>
                <TextBlock Text="Probar un aviso"/>
              </StackPanel>
            </Button>
          </StackPanel>
        </ScrollViewer>
      </Border>
      <Border Grid.Column="2" Style="{StaticResource Card}" Padding="24,20">
        <DockPanel>
          <TextBlock DockPanel.Dock="Top" Text="Últimos avisos" FontSize="19" FontWeight="SemiBold" Margin="0,0,0,6"/>
          <TextBlock x:Name="AlertsEmpty" DockPanel.Dock="Top" Text="Todavía no hubo avisos." Foreground="{StaticResource TextSecondary}" FontSize="15" Margin="0,6"/>
          <ListBox x:Name="AlertList" BorderThickness="0" ItemTemplate="{StaticResource AlertTemplate}" ItemContainerStyle="{StaticResource PlainItemStyle}"
                   ScrollViewer.HorizontalScrollBarVisibility="Disabled"/>
        </DockPanel>
      </Border>
    </Grid>

    <!-- ===== Herramientas y cambios ===== -->
    <Grid x:Name="PageTools" Grid.Row="2" Margin="28,12,28,24" Visibility="Collapsed">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="20"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <Border Style="{StaticResource Card}" Padding="24,20">
        <DockPanel>
          <TextBlock DockPanel.Dock="Top" Text="Herramientas de Windows" FontSize="19" FontWeight="SemiBold"/>
          <TextBlock DockPanel.Dock="Top" Text="Informes y ventanas de Windows útiles para revisar la PC a fondo." Foreground="{StaticResource TextSecondary}" FontSize="14" Margin="0,2,0,10" TextWrapping="Wrap"/>
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <StackPanel x:Name="ToolList"/>
          </ScrollViewer>
        </DockPanel>
      </Border>
      <Border Grid.Column="2" Style="{StaticResource Card}" Padding="24,20">
        <DockPanel>
          <TextBlock DockPanel.Dock="Top" Text="Cambios hechos por Diagnóstico PC" FontSize="19" FontWeight="SemiBold"/>
          <TextBlock DockPanel.Dock="Top" Foreground="{StaticResource TextSecondary}" FontSize="14" Margin="0,2,0,8" TextWrapping="Wrap"
                     Text="Cada arreglo guarda cómo deshacerlo. Si algo no te gusta, presiona «Deshacer»."/>
          <Button x:Name="BtnRestore" DockPanel.Dock="Bottom" Style="{StaticResource SubtleButton}" HorizontalAlignment="Left" Margin="0,12,0,0" Padding="16,9">
            <StackPanel Orientation="Horizontal">
              <TextBlock Style="{StaticResource Icon}" Text="&#xE777;" Margin="0,0,8,0"/>
              <TextBlock Text="Abrir Restaurar sistema"/>
            </StackPanel>
          </Button>
          <TextBlock x:Name="ChangesEmpty" DockPanel.Dock="Top" Text="Todavía no se cambió nada." Foreground="{StaticResource TextSecondary}" FontSize="15" Margin="0,6"/>
          <ListBox x:Name="ChangeList" BorderThickness="0" ItemTemplate="{StaticResource ChangeTemplate}" ItemContainerStyle="{StaticResource PlainItemStyle}"
                   ScrollViewer.HorizontalScrollBarVisibility="Disabled"/>
        </DockPanel>
      </Border>
    </Grid>

    <!-- ===== Progreso y resultado ===== -->
    <Grid x:Name="Overlay" Grid.RowSpan="3" Background="#80000000" Visibility="Collapsed">
      <Border Style="{StaticResource Card}" Width="580" Padding="30,26" HorizontalAlignment="Center" VerticalAlignment="Center">
        <Border.Effect>
          <DropShadowEffect BlurRadius="30" ShadowDepth="6" Direction="270" Opacity="0.3"/>
        </Border.Effect>
        <StackPanel>
          <StackPanel x:Name="OvBusy">
            <TextBlock x:Name="OvTitle" FontSize="20" FontWeight="SemiBold" TextWrapping="Wrap"/>
            <TextBlock x:Name="OvDetail" Margin="0,8,0,14" FontSize="15" Foreground="{StaticResource TextSecondary}" TextWrapping="Wrap"/>
            <ProgressBar x:Name="Progress" Height="8" IsIndeterminate="True" Foreground="{StaticResource Accent}" Background="#E8E8EE" BorderThickness="0"/>
            <TextBlock x:Name="OvPercent" Margin="0,8,0,0" FontSize="13" Foreground="{StaticResource TextSecondary}"/>
          </StackPanel>
          <StackPanel x:Name="OvDone" Visibility="Collapsed">
            <Border x:Name="OvIconBg" Width="60" Height="60" CornerRadius="30" HorizontalAlignment="Left">
              <TextBlock x:Name="OvIcon" Style="{StaticResource Icon}" FontSize="26"/>
            </Border>
            <TextBlock x:Name="OvDoneTitle" FontSize="21" FontWeight="SemiBold" Margin="0,16,0,8" TextWrapping="Wrap"/>
            <TextBlock x:Name="OvDoneText" FontSize="15" LineHeight="23" TextWrapping="Wrap"/>
          </StackPanel>
          <DockPanel x:Name="OvButtons" Margin="0,24,0,0" Visibility="Collapsed" LastChildFill="False">
            <Button x:Name="OvSupport" DockPanel.Dock="Left" Style="{StaticResource SubtleButton}" Padding="12,9" Visibility="Collapsed">
              <StackPanel Orientation="Horizontal">
                <TextBlock Style="{StaticResource Icon}" Text="&#xEB52;" Foreground="#FF5E5B" Margin="0,0,8,0"/>
                <TextBlock Text="¿Te sirvió? Apoya a la app"/>
              </StackPanel>
            </Button>
            <Button x:Name="OvClose" DockPanel.Dock="Right" Style="{StaticResource SubtleButton}" Content="Listo" Padding="24,9"/>
            <Button x:Name="OvPrimary" DockPanel.Dock="Right" Style="{StaticResource PrimaryButton}" Margin="0,0,8,0"/>
          </DockPanel>
        </StackPanel>
      </Border>
    </Grid>
  </Grid>
</Window>
'@

$script:WizardXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Paso a paso · Diagnóstico PC" Width="880" Height="640" MinWidth="680" MinHeight="520"
        WindowStartupLocation="CenterOwner" Background="#F3F3F3" ShowInTaskbar="False"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="15" Foreground="#1A1A1A"
        TextOptions.TextFormattingMode="Display" UseLayoutRounding="True">
  <Window.Resources>
<!--RECURSOS-->
  </Window.Resources>
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <Border x:Name="WzHeader" Padding="28,20" Background="#EEF0FF">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Border Width="54" Height="54" CornerRadius="27" Background="White">
          <TextBlock x:Name="WzGlyph" Style="{StaticResource Icon}" FontSize="23" Text="&#xE90F;"/>
        </Border>
        <StackPanel Grid.Column="1" Margin="16,0" VerticalAlignment="Center">
          <TextBlock x:Name="WzKicker" Text="PASO A PASO PARA ARREGLARLO" FontSize="12" FontWeight="Bold"/>
          <TextBlock x:Name="WzTitle" FontSize="21" FontWeight="SemiBold" TextWrapping="Wrap" FontFamily="Segoe UI Variable Display, Segoe UI"/>
        </StackPanel>
        <Border Grid.Column="2" Background="White" CornerRadius="16" Padding="14,6" VerticalAlignment="Center">
          <TextBlock x:Name="WzCounter" FontSize="15" FontWeight="SemiBold"/>
        </Border>
      </Grid>
    </Border>
    <Border Grid.Row="1" Style="{StaticResource Card}" Margin="28,20,28,0" Padding="30,24">
      <ScrollViewer VerticalScrollBarVisibility="Auto">
        <StackPanel>
          <ProgressBar x:Name="WzProgress" Height="6" Foreground="{StaticResource Accent}" Background="#E8E8EE" BorderThickness="0"/>
          <Grid Margin="0,20,0,0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Border Width="48" Height="48" CornerRadius="24" Background="{StaticResource Accent}" VerticalAlignment="Top">
              <TextBlock x:Name="WzNumber" Foreground="White" FontSize="21" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <TextBlock x:Name="WzStepTitle" Grid.Column="1" FontSize="23" FontWeight="SemiBold" Margin="16,0,0,0" VerticalAlignment="Center" TextWrapping="Wrap"
                       FontFamily="Segoe UI Variable Display, Segoe UI"/>
          </Grid>
          <Border x:Name="WzPathBox" Background="{StaticResource AccentLight}" CornerRadius="8" Padding="14,10" Margin="0,18,0,0">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock Style="{StaticResource Icon}" Text="&#xE8B7;" Foreground="{StaticResource Accent}" Margin="0,0,10,0" FontSize="16"/>
              <TextBlock x:Name="WzPath" Grid.Column="1" TextWrapping="Wrap" FontSize="15" Foreground="#2B2580" FontWeight="SemiBold"/>
            </Grid>
          </Border>
          <TextBlock x:Name="WzText" FontSize="17" LineHeight="27" TextWrapping="Wrap" Margin="0,16,0,0"/>
          <Border x:Name="WzCmdBox" Background="#1F1F2E" CornerRadius="8" Padding="16,10" Margin="0,16,0,0">
            <DockPanel>
              <Button x:Name="WzCopy" DockPanel.Dock="Right" Style="{StaticResource SmallButton}" Margin="12,0,0,0">
                <StackPanel Orientation="Horizontal">
                  <TextBlock Style="{StaticResource Icon}" Text="&#xE8C8;" Margin="0,0,6,0"/>
                  <TextBlock Text="Copiar"/>
                </StackPanel>
              </Button>
              <TextBlock x:Name="WzCmd" FontFamily="Consolas" FontSize="17" Foreground="White" VerticalAlignment="Center" TextWrapping="Wrap"/>
            </DockPanel>
          </Border>
          <Button x:Name="WzAction" Style="{StaticResource PrimaryButton}" HorizontalAlignment="Left" Margin="0,22,0,0" Padding="24,11"/>
          <Border x:Name="WzResultBox" Background="#E5F0FB" CornerRadius="8" Padding="14,10" Margin="0,16,0,0" Visibility="Collapsed">
            <TextBlock x:Name="WzResult" TextWrapping="Wrap" FontSize="15" LineHeight="23"/>
          </Border>
        </StackPanel>
      </ScrollViewer>
    </Border>
    <DockPanel Grid.Row="2" Margin="28,16,28,22" LastChildFill="False">
      <Button x:Name="WzClose" Style="{StaticResource SubtleButton}" Content="Cerrar" Padding="22,10" FontSize="15"/>
      <Button x:Name="WzNext" DockPanel.Dock="Right" Style="{StaticResource PrimaryButton}" Padding="26,10" Margin="10,0,0,0"/>
      <Button x:Name="WzPrev" DockPanel.Dock="Right" Style="{StaticResource SubtleButton}" Padding="22,10" FontSize="15">
        <StackPanel Orientation="Horizontal">
          <TextBlock Style="{StaticResource Icon}" Text="&#xE72B;" Margin="0,0,8,0"/>
          <TextBlock Text="Anterior"/>
        </StackPanel>
      </Button>
    </DockPanel>
  </Grid>
</Window>
'@

#endregion

#region Ventana: funciones

function Initialize-GuiTypes {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms, System.Drawing
    Initialize-Types
    $script:UiCallback = [System.Windows.Threading.DispatcherOperationCallback]{ param($frame) $frame.Continue = $false; $null }
}

function Test-SupportConfigured { $script:SupportUrl -and $script:SupportUrl -notmatch 'PENDIENTE' }

function Open-SupportPage {
    try { if (-not $script:TestMode) { Start-Process explorer.exe -ArgumentList "`"$script:SupportUrl`"" } } catch { }
}

function New-Brush([string]$Hex) { (New-Object System.Windows.Media.BrushConverter).ConvertFromString($Hex) }

# Carga un XAML y devuelve la ventana y sus controles con nombre
function New-XamlWindow([string]$Xaml) {
    [xml]$xml = $Xaml.Replace('<!--RECURSOS-->', $script:XamlResources)
    $window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xml))
    $controls = @{ Window = $window }
    $xamlNs = 'http://schemas.microsoft.com/winfx/2006/xaml'
    $nsm = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
    $nsm.AddNamespace('x', $xamlNs)
    foreach ($node in $xml.SelectNodes('//*[@x:Name]', $nsm)) {
        $name = $node.GetAttribute('Name', $xamlNs)
        $element = $window.FindName($name)
        if ($element) { $controls[$name] = $element }
    }
    $controls
}

function Get-ActiveWindow {
    if ($script:Wizard -and $script:Wizard.Window.IsVisible) { return $script:Wizard.Window }
    $script:Gui.Window
}

function Show-Message([string]$Text, [string]$Icon = 'Information', [string]$Buttons = 'OK') {
    $owner = Get-ActiveWindow
    if ($owner -and $owner.IsVisible) {
        return "$([System.Windows.MessageBox]::Show($owner, $Text, $script:AppName, [System.Windows.MessageBoxButton]$Buttons, [System.Windows.MessageBoxImage]$Icon))"
    }
    "$([System.Windows.MessageBox]::Show($Text, $script:AppName, [System.Windows.MessageBoxButton]$Buttons, [System.Windows.MessageBoxImage]$Icon))"
}

function Show-Page([string]$Name) {
    $g = $script:Gui
    foreach ($page in 'PageHome', 'PageResults', 'PageAlerts', 'PageTools') {
        $g[$page].Visibility = if ($page -eq $Name) { 'Visible' } else { 'Collapsed' }
    }
    $tab = switch ($Name) { 'PageAlerts' { 'TabAlerts' } 'PageTools' { 'TabTools' } default { 'TabResults' } }
    foreach ($t in 'TabResults', 'TabAlerts', 'TabTools') { $g[$t].Tag = if ($t -eq $tab) { 'sel' } else { $null } }
    $hasResults = $Name -eq 'PageResults'
    $g.BtnRescan.Visibility = if ($hasResults) { 'Visible' } else { 'Collapsed' }
    $g.BtnReport.Visibility = if ($hasResults) { 'Visible' } else { 'Collapsed' }
}

function Show-ResultsOrHome {
    if (@($script:Gui.AllFindings).Count) { Show-Page 'PageResults' } else { Show-Page 'PageHome' }
}

function Show-Overlay([string]$Title, [string]$Detail = 'Un momento, por favor...') {
    $g = $script:Gui
    $g.OvTitle.Text = $Title
    $g.OvDetail.Text = $Detail
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

# Texto de "trabajando..." en la ventana que esté al frente (la principal o la del paso a paso)
function Set-BusyText([string]$Text) {
    if ($script:Wizard -and $script:Wizard.Window.IsVisible) {
        $script:Wizard.WzResult.Text = $Text
        $script:Wizard.WzResultBox.Background = New-Brush '#E5F0FB'
        $script:Wizard.WzResultBox.Visibility = 'Visible'
    } else {
        $script:Gui.OvDetail.Text = $Text
    }
    Update-UI
}

# La llama Invoke-Background mientras espera: muestra qué se está revisando
function Set-BusyProgress {
    $g = $script:Gui
    $p = $script:Progress
    if (-not $p.Text) { return }
    if ($g.AnalysisRunning -and $p.Total -gt 1) {
        $g.OvDetail.Text = "Revisando: $($p.Text)"
        $g.Progress.IsIndeterminate = $false
        $g.Progress.Maximum = $p.Total
        $g.Progress.Value = [Math]::Max(0, $p.Step - 1)
        $g.OvPercent.Text = "$($p.Step) de $($p.Total)"
    } elseif ($script:Wizard -and $script:Wizard.Window.IsVisible) {
        $script:Wizard.WzResult.Text = $p.Text
    } else {
        $g.OvDetail.Text = $p.Text
    }
}

function Show-OverlayResult {
    param(
        [ValidateSet('Ok', 'Warn', 'Error', 'Info')][string]$Kind,
        [string]$Title, [string]$Text, [string]$PrimaryText, [scriptblock]$PrimaryAction,
        [string]$CloseText = 'Listo', [switch]$ShowSupport
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

# Ejecuta una acción mostrando la ventana de progreso; si falla, muestra el error
function Invoke-GuiAction([string]$BusyTitle, [scriptblock]$Action) {
    $g = $script:Gui
    if ($g.IsBusy) { return }
    $g.IsBusy = $true
    if ($BusyTitle) { Show-Overlay $BusyTitle }
    try {
        & $Action
        if ($g.OvDone.Visibility -ne 'Visible') { Hide-Overlay }
    } catch {
        Write-Log $_.Exception.Message
        Show-OverlayResult -Kind Error -Title 'Ocurrió un problema' -Text $_.Exception.Message
    } finally {
        $g.IsBusy = $false
    }
}

function ConvertTo-FindingView($Finding) {
    $v = New-Object DiagnosticoPC.FindingView
    $v.Source = $Finding
    $v.Id = $Finding.Id
    $v.Check = $Finding.Check
    $v.Area = $Finding.Area
    $code = $script:Areas[$Finding.Area]
    $v.AreaGlyph = if ($code) { [string][char]$code } else { '' }
    $v.Level = $Finding.Level
    $v.Title = $Finding.Title
    $v.Summary = $Finding.Summary
    $v.Detail = $Finding.Detail
    $v.FixText = if ($Finding.Fix) { $Finding.FixText } else { '' }
    $v.StepCount = @($Finding.Steps).Count
    foreach ($i in @($Finding.Items)) {
        $iv = New-Object DiagnosticoPC.ItemView
        $iv.Source = $i
        $iv.Name = $i.Name
        $iv.Detail = $i.Detail
        $iv.ActionText = $i.ActionText
        $iv.Action2Text = $i.Action2Text
        $v.Items.Add($iv)
    }
    $v
}

function Get-LevelCounts($Findings) {
    $count = @{ Rojo = 0; Amarillo = 0; Verde = 0; Info = 0 }
    foreach ($f in @($Findings)) { $count[$f.Level]++ }
    $count
}

function Update-Counters {
    $g = $script:Gui
    $count = Get-LevelCounts $g.AllFindings
    $g.CntRojoN.Text = "$($count.Rojo)"
    $g.CntAmarilloN.Text = "$($count.Amarillo)"
    $g.CntVerdeN.Text = "$($count.Verde + $count.Info)"
    foreach ($pair in @(@('CntRojo', 'Rojo', '#C42B1C'), @('CntAmarillo', 'Amarillo', '#9D5D00'), @('CntVerde', 'Verde', '#0F7B0F'))) {
        $g[$pair[0]].BorderBrush = if ($g.Filter -eq $pair[1]) { New-Brush $pair[2] } else { [System.Windows.Media.Brushes]::Transparent }
    }
    $names = @{ Rojo = 'solo los graves'; Amarillo = 'solo los que hay que revisar'; Verde = 'solo los que están bien' }
    $g.TxtFilter.Text = if ($g.Filter) { "Mostrando $($names[$g.Filter]). Toca el mismo color otra vez para ver todo." }
                        else { "$(@($g.AllFindings).Count) revisiones · Toca un color de arriba para filtrar." }
}

function Update-FindingList([string]$SelectId) {
    $g = $script:Gui
    if (-not $SelectId -and $g.FindingList.SelectedItem) { $SelectId = $g.FindingList.SelectedItem.Id }
    $coll = New-Object 'System.Collections.ObjectModel.ObservableCollection[DiagnosticoPC.FindingView]'
    foreach ($f in Get-SortedFindings $g.AllFindings) {
        $level = if ($f.Level -eq 'Info') { 'Verde' } else { $f.Level }
        if ($g.Filter -and $level -ne $g.Filter) { continue }
        $coll.Add((ConvertTo-FindingView $f))
    }
    $g.FindingList.ItemsSource = $coll
    $sel = $null
    if ($SelectId) { $sel = $coll | Where-Object { $_.Id -eq $SelectId } | Select-Object -First 1 }
    if (-not $sel -and $coll.Count) { $sel = $coll[0] }
    $g.FindingList.SelectedItem = $sel
    if ($sel) { $g.FindingList.ScrollIntoView($sel) }
    Show-FindingDetail $sel
    Update-Counters
}

function Show-FindingDetail($View) {
    $g = $script:Gui
    $g.DetailPanel.DataContext = $View
    $g.DetailScroll.Visibility = if ($View) { 'Visible' } else { 'Collapsed' }
    $g.DetailEmpty.Visibility = if ($View) { 'Collapsed' } else { 'Visible' }
    $g.DetailScroll.ScrollToTop()
}

function Set-Findings($Findings) {
    $g = $script:Gui
    $g.AllFindings = @($Findings)
    $g.Filter = $null
    Update-FindingList
    $count = Get-LevelCounts $Findings
    $script:Settings.UltimoAnalisis = Format-Date (Get-Date)
    $script:Settings.UltimoResumen = "$($count.Rojo) graves, $($count.Amarillo) para revisar y $($count.Verde + $count.Info) bien"
    Save-Settings
    Update-HomeLast
}

function Update-HomeLast {
    $g = $script:Gui
    $s = $script:Settings
    $g.HomeLast.Text = if ($s.UltimoAnalisis) { "Último análisis: $($s.UltimoAnalisis) · $($s.UltimoResumen). Tarda alrededor de un minuto y no cambia nada sin preguntarte." }
                       else { 'Tarda alrededor de un minuto. No cambia nada sin preguntarte.' }
}

function Start-Analysis {
    $g = $script:Gui
    if ($g.IsBusy) { return }
    $g.IsBusy = $true
    $g.AnalysisRunning = $true
    Show-Overlay 'Analizando tu PC...' 'Preparando la revisión...'
    try {
        $findings = Invoke-Background { Invoke-Analysis }
        $g.AnalysisRunning = $false
        Set-Findings $findings
        Hide-Overlay
        Show-Page 'PageResults'
        $count = Get-LevelCounts $findings
        Write-Log "Análisis: $($script:Settings.UltimoResumen)"
        if (-not $count.Rojo -and -not $count.Amarillo) {
            Show-OverlayResult -Kind Ok -Title '¡Tu PC está en orden!' -ShowSupport `
                -Text 'No se encontraron problemas. Puedes dejar activados los avisos para que Diagnóstico PC te avise si aparece alguno.'
        }
    } catch {
        Show-OverlayResult -Kind Error -Title 'No se pudo terminar el análisis' -Text $_.Exception.Message
    } finally {
        $g.AnalysisRunning = $false
        $g.IsBusy = $false
        $script:Progress.Text = ''
    }
}

# Vuelve a hacer solo una revisión (después de un arreglo o con "Volver a revisar")
function Invoke-Recheck([string]$Check, [string]$SelectId) {
    $g = $script:Gui
    if (-not $Check) { return }
    $new = @(Invoke-Background { param($c) Invoke-Analysis @($c) } @($Check))
    $g.AllFindings = @($g.AllFindings | Where-Object { $_.Check -ne $Check }) + $new
    if (-not $SelectId -and $new.Count) { $SelectId = $new[0].Id }
    Update-FindingList $SelectId
}

function Start-Recheck($View) {
    if (-not $View) { return }
    $check = $View.Check
    $id = $View.Id
    Invoke-GuiAction 'Revisando de nuevo...' { Invoke-Recheck $check $id }
}

# Pregunta, crea el punto de restauración, ejecuta el arreglo y lo anota en "Cambios hechos".
# Devuelve @{ Ok; Message } o $null si el usuario dijo que no.
function Invoke-FixFlow([string]$Id, $Arg) {
    $g = $script:Gui
    $text = Get-FixDescription $Id
    $changes = Test-FixChanges $Id
    if ($text -and $Id -notin 'buscar-driver', 'abrir-seguridad', 'informe-bateria') {
        $question = "Diagnóstico PC va a:`n`n$text"
        if ($changes) { $question += "`n`nAntes se creará un punto de restauración, y podrás deshacerlo en «Herramientas y cambios»." }
        if ((Show-Message "$question`n`n¿Continuar?" 'Question' 'YesNo') -ne 'Yes') { return $null }
    }
    $wasBusy = $g.IsBusy
    $g.IsBusy = $true
    try {
        $note = $null
        if ($changes -and -not $script:RestorePointDone) {
            Set-BusyText 'Creando un punto de restauración (puede tardar un minuto)...'
            $note = @(Invoke-Background { New-RestorePoint })[0]
            $script:RestorePointDone = $true
        }
        Set-BusyText 'Aplicando el arreglo...'
        $script:Progress.Text = ''
        $script:Progress.Total = 1
        $res = if ($script:FixInfo[$Id] -and $script:FixInfo[$Id].Long) {
            @(Invoke-Background { param($i, $a) Invoke-Fix $i $a } @($Id, $Arg))[0]
        } else {
            Invoke-Fix $Id $Arg
        }
        $script:Progress.Text = ''
        if ($res.Description) { [void](Add-ChangeLog $res.Description $res.Undo) }
        Update-ChangeList
        $msg = $res.Message
        if ($note) { $msg += "`n`n$note" }
        @{ Ok = $true; Message = $msg }
    } catch {
        Write-Log "Error en el arreglo $Id`: $($_.Exception.Message)"
        @{ Ok = $false; Message = "No se pudo completar: $($_.Exception.Message)" }
    } finally {
        $g.IsBusy = $wasBusy
    }
}

# Arreglos después de los cuales conviene volver a revisar
function Test-NeedsRecheck([string]$Id) {
    (Test-FixChanges $Id) -or $Id -in 'cerrar-programa', 'liberar-espacio', 'buscar-cambios', 'reinstalar-dispositivo', 'habilitar-dispositivo', 'reparar-windows'
}

function Start-FindingFix($View) {
    $g = $script:Gui
    if (-not $View -or $g.IsBusy) { return }
    $f = $View.Source
    Show-Overlay $View.FixText
    $res = Invoke-FixFlow $f.Fix $f.FixArg
    if (-not $res) { Hide-Overlay; return }
    if ($res.Ok -and (Test-NeedsRecheck $f.Fix)) {
        Set-BusyText 'Revisando de nuevo...'
        $g.IsBusy = $true
        try { Invoke-Recheck $f.Check $f.Id } catch { } finally { $g.IsBusy = $false }
    }
    $kind = if ($res.Ok) { 'Ok' } else { 'Error' }
    $title = if ($res.Ok) { 'Listo' } else { 'No se pudo arreglar' }
    Show-OverlayResult -Kind $kind -Title $title -Text $res.Message -ShowSupport:$res.Ok
}

# Botón de una fila del detalle (Cerrar, Quitar del arranque, Paso a paso...)
function Start-ItemAction($Item, [string]$Which) {
    $g = $script:Gui
    if (-not $Item -or $g.IsBusy) { return }
    $src = $Item.Source
    $action = if ($Which -eq '2') { $src.Action2 } else { $src.Action }
    if (-not $action) { return }
    $view = $g.FindingList.SelectedItem
    if ($action -eq 'paso-a-paso') {
        Show-StepWizard -Title $src.Arg.Title -Level 'Rojo' -Steps (Get-CrashSteps $src.Arg.Cause) -FindingView $view
        return
    }
    $arg = $src.Arg
    if ($action -eq 'cerrar-programa' -and $arg.Process) {
        # El aviso de confirmación nombra el programa
        $script:FixInfo['cerrar-programa'].Text = "Cerrar «$($arg.Label)». Si tiene trabajo sin guardar, se perderá."
    }
    $Item.Status = 'Trabajando...'
    Show-Overlay $(if ($Which -eq '2') { $src.Action2Text } else { $src.ActionText })
    $res = Invoke-FixFlow $action $arg
    Hide-Overlay
    if (-not $res) { $Item.Status = ''; return }
    $Item.Status = $res.Message
    if ($res.Ok -and $action -ne 'buscar-driver') { $Item.IsEnabled = $false }
}

#endregion

#region Ventana: paso a paso

function New-StepWizard {
    param([string]$Title, [string]$Level = 'Info', [object[]]$Steps, $FindingView)
    $wz = New-XamlWindow $script:WizardXaml
    $all = @($Steps | Where-Object { $_ })
    if ($FindingView) {
        $all += New-Step -Title '¿Se solucionó?' -Button 'Volver a revisar' -Fix '__recheck' `
            -Text 'Presiona «Volver a revisar»: Diagnóstico PC revisa otra vez esta parte y te muestra si ya está en verde. Si sigue igual, vuelve a los pasos anteriores o prueba el arreglo automático.'
    }
    $wz.Steps = $all
    $wz.Index = 0
    $wz.FindingView = $FindingView
    $wz.NeedsRecheck = $false
    $wz.Working = $false
    $wz.WzTitle.Text = $Title
    $fg = New-Brush ([DiagnosticoPC.Levels]::Fg($Level))
    $wz.WzHeader.Background = New-Brush ([DiagnosticoPC.Levels]::Bg($Level))
    $wz.WzGlyph.Text = [DiagnosticoPC.Levels]::Glyph($Level)
    $wz.WzGlyph.Foreground = $fg
    $wz.WzKicker.Foreground = $fg
    $wz.WzProgress.Maximum = [Math]::Max(1, $all.Count)

    $wz.WzNext.Add_Click({
        $w = $script:Wizard
        if ($w.Index -ge $w.Steps.Count - 1) { $w.Window.Close() } else { $w.Index++; Show-WizardStep }
    })
    $wz.WzPrev.Add_Click({
        $w = $script:Wizard
        if ($w.Index -gt 0) { $w.Index--; Show-WizardStep }
    })
    $wz.WzClose.Add_Click({ $script:Wizard.Window.Close() })
    $wz.WzCopy.Add_Click({
        try {
            [System.Windows.Clipboard]::SetText($script:Wizard.WzCmd.Text)
            Show-WizardResult 'Copiado. Pégalo en el Símbolo del sistema con clic derecho (o Ctrl + V) y presiona Enter.' 'Info'
        } catch { }
    })
    $wz.WzAction.Add_Click({ Invoke-WizardAction })
    $wz.Window.Add_Closing({
        param($s, $e)
        if ($script:Wizard -and $script:Wizard.Working) { $e.Cancel = $true }
    })
    $script:Wizard = $wz
    Show-WizardStep
    $wz
}

function Show-WizardStep {
    $w = $script:Wizard
    $s = $w.Steps[$w.Index]
    $n = $w.Steps.Count
    $w.WzCounter.Text = "Paso $($w.Index + 1) de $n"
    $w.WzProgress.Value = $w.Index + 1
    $w.WzNumber.Text = "$($w.Index + 1)"
    $w.WzStepTitle.Text = $s.Title
    $w.WzPath.Text = "$($s.Path)"
    $w.WzPathBox.Visibility = if ($s.Path) { 'Visible' } else { 'Collapsed' }
    $w.WzText.Text = "$($s.Text)"
    $w.WzText.Visibility = if ($s.Text) { 'Visible' } else { 'Collapsed' }
    $w.WzCmd.Text = "$($s.Command)"
    $w.WzCmdBox.Visibility = if ($s.Command) { 'Visible' } else { 'Collapsed' }
    $hasAction = $s.Button -and ($s.Open -or $s.Fix)
    $w.WzAction.Content = "$($s.Button)"
    $w.WzAction.Visibility = if ($hasAction) { 'Visible' } else { 'Collapsed' }
    $w.WzResultBox.Visibility = 'Collapsed'
    $w.WzPrev.IsEnabled = $w.Index -gt 0
    $w.WzNext.Content = if ($w.Index -ge $n - 1) { 'Terminar' } else { 'Siguiente' }
}

function Show-WizardResult([string]$Text, [string]$Kind = 'Info') {
    $w = $script:Wizard
    $bg = @{ Ok = '#DFF6DD'; Error = '#FDE7E9'; Info = '#E5F0FB' }[$Kind]
    $w.WzResultBox.Background = New-Brush $bg
    $w.WzResult.Text = $Text
    $w.WzResultBox.Visibility = 'Visible'
}

function Invoke-WizardAction {
    $w = $script:Wizard
    $s = $w.Steps[$w.Index]
    if ($s.Open) {
        Open-Target $s.Open
        Show-WizardResult 'Se abrió la ventana de Windows. Sigue las indicaciones de arriba y vuelve aquí para el paso siguiente.'
        return
    }
    if ($s.Fix -eq '__recheck') {
        $w.NeedsRecheck = $true
        $w.Window.Close()
        return
    }
    if (-not $s.Fix) { return }
    $w.Working = $true
    foreach ($b in 'WzAction', 'WzNext', 'WzPrev', 'WzClose') { $w[$b].IsEnabled = $false }
    try {
        $res = Invoke-FixFlow $s.Fix $s.FixArg
    } finally {
        $w.Working = $false
        foreach ($b in 'WzAction', 'WzNext', 'WzClose') { $w[$b].IsEnabled = $true }
        $w.WzPrev.IsEnabled = $w.Index -gt 0
    }
    if (-not $res) { $w.WzResultBox.Visibility = 'Collapsed'; return }
    Show-WizardResult $res.Message $(if ($res.Ok) { 'Ok' } else { 'Error' })
    if ($res.Ok -and (Test-NeedsRecheck $s.Fix)) { $w.NeedsRecheck = $true }
}

function Show-StepWizard {
    param([string]$Title, [string]$Level = 'Info', [object[]]$Steps, $FindingView)
    if (-not @($Steps).Count) { return }
    $wz = New-StepWizard -Title $Title -Level $Level -Steps $Steps -FindingView $FindingView
    if ($script:Gui.Window.IsVisible) { $wz.Window.Owner = $script:Gui.Window }
    try { [void]$wz.Window.ShowDialog() } finally { $script:Wizard = $null }
    if ($wz.NeedsRecheck -and $FindingView) { Start-Recheck $FindingView }
}

#endregion

#region Ventana: inicio, herramientas y cambios

$script:HomeAreas = @(
    ,@(0xE945, 'Energía e hibernación', 'Si la PC se suspende y se apaga de verdad, y qué la despierta')
    ,@(0xE706, 'Temperatura', 'Calor y procesador frenado por calor')
    ,@(0xE71D, 'Programas', 'Lo que consume procesador y memoria, y lo que arranca con Windows')
    ,@(0xE772, 'Drivers', 'Dispositivos sin driver o con fallas')
    ,@(0xE7F4, 'Pantallas azules', 'Si hubo, cuándo, por qué y cómo evitarlas')
    ,@(0xE943, 'Registro de Windows', 'Cambios peligrosos y ajustes importantes')
    ,@(0xE8A5, 'Archivos de Windows', 'Archivos dañados o que faltan')
    ,@(0xEDA2, 'Disco, batería y antivirus', 'Espacio, salud del disco, batería y protección')
)

$script:Tools = @(
    @{ Id = 'sleepstudy';   Glyph = 0xE708; Title = 'Informe de suspensión'; Text = 'Qué pasó y cuánta batería se gastó mientras la PC «dormía» (equipos con Espera moderna).' }
    @{ Id = 'energy';       Glyph = 0xE945; Title = 'Informe de energía'; Text = 'Windows observa la PC durante 1 minuto y lista los problemas de energía.' }
    @{ Id = 'battery';      Glyph = 0xE83F; Title = 'Informe de batería'; Text = 'Capacidad original y actual de la batería, y su uso reciente.' }
    @{ Id = 'reliability';  Glyph = 0xE9D9; Title = 'Monitor de confiabilidad'; Text = 'Historial día por día de pantallas azules y programas que fallaron.' }
    @{ Id = 'restorepoint'; Glyph = 0xE777; Title = 'Crear un punto de restauración'; Text = 'Guarda el estado actual de Windows para poder volver atrás.' }
    @{ Id = 'devmgmt';      Glyph = 0xE772; Title = 'Administrador de dispositivos'; Text = 'Dispositivos y drivers (los que tienen problemas llevan un signo amarillo).' }
    @{ Id = 'taskmgr';      Glyph = 0xE71D; Title = 'Administrador de tareas'; Text = 'Programas abiertos y lo que consume cada uno.' }
    @{ Id = 'cleanmgr';     Glyph = 0xE74D; Title = 'Liberador de espacio en disco'; Text = 'Borra archivos temporales y restos de actualizaciones.' }
    @{ Id = 'security';     Glyph = 0xEA18; Title = 'Seguridad de Windows'; Text = 'Antivirus, firewall y examen de virus.' }
)

function New-IconTextBlock([int]$Glyph, [double]$Size) {
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Style = $script:Gui.Window.FindResource('Icon')
    $tb.Text = [string][char]$Glyph
    $tb.FontSize = $Size
    $tb.Foreground = $script:Gui.Window.FindResource('Accent')
    $tb
}

# Ícono + título + descripción (tarjetas del inicio y botones de herramientas)
function New-GlyphRow([int]$Glyph, [string]$Title, [string]$Text) {
    $grid = New-Object System.Windows.Controls.Grid
    foreach ($w in 'Auto', '*') {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = (New-Object System.Windows.GridLengthConverter).ConvertFromString($w)
        $grid.ColumnDefinitions.Add($cd)
    }
    $circle = New-Object System.Windows.Controls.Border
    $circle.Width = 42; $circle.Height = 42
    $circle.CornerRadius = New-Object System.Windows.CornerRadius(21)
    $circle.Background = $script:Gui.Window.FindResource('AccentLight')
    $circle.VerticalAlignment = 'Center'
    $circle.Child = New-IconTextBlock $Glyph 18
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = New-Object System.Windows.Thickness(12, 0, 0, 0)
    $sp.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($sp, 1)
    $t1 = New-Object System.Windows.Controls.TextBlock
    $t1.Text = $Title; $t1.FontSize = 15; $t1.FontWeight = 'SemiBold'; $t1.TextWrapping = 'Wrap'
    $t2 = New-Object System.Windows.Controls.TextBlock
    $t2.Text = $Text; $t2.FontSize = 13; $t2.TextWrapping = 'Wrap'
    $t2.Foreground = New-Brush '#555555'
    [void]$sp.Children.Add($t1)
    [void]$sp.Children.Add($t2)
    [void]$grid.Children.Add($circle)
    [void]$grid.Children.Add($sp)
    $grid
}

function Add-HomeAreas {
    $g = $script:Gui
    foreach ($a in $script:HomeAreas) {
        $row = New-GlyphRow $a[0] $a[1] $a[2]
        $row.Margin = New-Object System.Windows.Thickness(0, 7, 14, 7)
        [void]$g.HomeAreas.Children.Add($row)
    }
}

function Add-ToolButtons {
    $g = $script:Gui
    foreach ($t in $script:Tools) {
        $b = New-Object System.Windows.Controls.Button
        $b.Style = $g.Window.FindResource('SubtleButton')
        $b.HorizontalContentAlignment = 'Stretch'
        $b.Padding = New-Object System.Windows.Thickness(14, 10, 14, 10)
        $b.Margin = New-Object System.Windows.Thickness(0, 0, 0, 8)
        $b.Content = New-GlyphRow $t.Glyph $t.Title $t.Text
        $b.Tag = $t.Id
        $b.Add_Click({ param($s) Invoke-Tool $s.Tag })
        [void]$g.ToolList.Children.Add($b)
    }
}

function Invoke-Tool([string]$Id) {
    if (-not (Test-Path -LiteralPath $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
    $powercfg = Join-Path $env:SystemRoot 'System32\powercfg.exe'
    switch ($Id) {
        'sleepstudy' {
            Invoke-GuiAction 'Preparando el informe de suspensión...' {
                $file = Join-Path $script:DataDir 'informe-suspension.html'
                $r = Invoke-External $powercfg @('/sleepstudy', '/output', $file)
                if ($r.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $file)) {
                    Show-OverlayResult -Kind Info -Title 'Informe no disponible' `
                        -Text "Este equipo no usa la Espera moderna, así que Windows no arma este informe. Usa el «Informe de energía».`n`n$($r.Output)"
                } else { Open-Target $file }
            }
        }
        'energy' {
            if ((Show-Message 'Windows va a observar la PC durante 1 minuto. Mientras tanto no la uses. ¿Continuar?' 'Question' 'YesNo') -ne 'Yes') { return }
            Invoke-GuiAction 'Observando la PC durante 1 minuto...' {
                $file = Join-Path $script:DataDir 'informe-energia.html'
                $r = Invoke-External $powercfg @('/energy', '/output', $file, '/duration', '60')
                if (-not (Test-Path -LiteralPath $file)) { throw "Windows no pudo crear el informe. $($r.Output)" }
                Open-Target $file
            }
        }
        'battery' {
            Invoke-GuiAction 'Preparando el informe de batería...' {
                if (-not (Get-CachedPcInfo).IsLaptop) { throw 'Este equipo no tiene batería.' }
                $res = Invoke-Fix 'informe-bateria' $null
                Show-OverlayResult -Kind Info -Title 'Informe de batería' -Text $res.Message
            }
        }
        'reliability'  { Open-Target 'perfmon.exe|/rel' }
        'restorepoint' {
            Invoke-GuiAction 'Creando un punto de restauración...' {
                $note = @(Invoke-Background { New-RestorePoint })[0]
                if ($note) { Show-OverlayResult -Kind Warn -Title 'No se pudo crear' -Text $note }
                else {
                    $script:RestorePointDone = $true
                    Show-OverlayResult -Kind Ok -Title 'Punto de restauración creado' -Text 'Si algo sale mal, puedes volver a este momento con «Abrir Restaurar sistema».'
                }
            }
        }
        'devmgmt'  { Open-Target 'devmgmt.msc' }
        'taskmgr'  { Open-Target 'taskmgr.exe' }
        'cleanmgr' { Open-Target 'cleanmgr.exe' }
        'security' { Open-Target 'windowsdefender://threat' }
    }
}

function Update-ChangeList {
    $g = $script:Gui
    if (-not $g) { return }
    $list = @(Get-ChangeLog)
    [array]::Reverse($list)
    $coll = New-Object 'System.Collections.ObjectModel.ObservableCollection[DiagnosticoPC.ChangeView]'
    foreach ($c in $list) {
        if (-not $c) { continue }
        $v = New-Object DiagnosticoPC.ChangeView
        $v.Source = $c
        $v.Date = "$($c.Fecha)"
        $v.Description = "$($c.Descripcion)"
        $undoable = @($c.Undo | Where-Object { $_ }).Count -gt 0
        $v.Status = if ($c.Deshecho) { 'Deshecho' } elseif ($undoable) { 'Se puede deshacer' } else { 'No hace falta deshacerlo' }
        $v.CanUndo = $undoable -and -not $c.Deshecho
        $coll.Add($v)
    }
    $g.ChangeList.ItemsSource = $coll
    $g.ChangesEmpty.Visibility = if ($coll.Count) { 'Collapsed' } else { 'Visible' }
}

function Start-Undo($View) {
    if (-not $View -or -not $View.CanUndo) { return }
    if ((Show-Message "¿Deshacer este cambio?`n`n$($View.Description)" 'Question' 'YesNo') -ne 'Yes') { return }
    Invoke-GuiAction 'Deshaciendo el cambio...' {
        [void](Undo-Change $View.Source.Id)
        Update-ChangeList
        Show-OverlayResult -Kind Ok -Title 'Cambio deshecho' `
            -Text "Quedó como estaba antes: $($View.Description).`n`nPresiona «Analizar de nuevo» para actualizar el diagnóstico."
    }
}

function Save-ReportDialog {
    $g = $script:Gui
    if (-not @($g.AllFindings).Count) { return }
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.FileName = "Diagnostico-PC-$(Get-Date -Format 'yyyy-MM-dd').html"
    $dlg.Filter = 'Página web (*.html)|*.html'
    $dlg.InitialDirectory = [Environment]::GetFolderPath('Desktop')
    if (-not $dlg.ShowDialog($g.Window)) { return }
    Invoke-GuiAction 'Guardando el informe...' {
        Export-Report $g.AllFindings $dlg.FileName
        $g.LastReport = $dlg.FileName
        Show-OverlayResult -Kind Ok -Title 'Informe guardado' -PrimaryText 'Abrir el informe' -PrimaryAction { Open-Target $script:Gui.LastReport } `
            -Text "Se guardó en:`n$($dlg.FileName)`n`nPuedes enviarlo a un técnico o imprimirlo desde el navegador."
    }
}

#endregion

#region Avisos junto al reloj

function New-WatchState {
    $since = (Get-Date).AddMinutes(-15)
    $saved = [datetime]::MinValue
    if ($script:Settings -and $script:Settings.UltimaRevisionAvisos -and
        [datetime]::TryParse("$($script:Settings.UltimaRevisionAvisos)", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$saved)) {
        # Al iniciar con Windows, avisa de lo que pasó desde la última revisión (máximo un día atrás)
        if ($saved -gt (Get-Date).AddDays(-1) -and $saved -lt $since) { $since = $saved }
    }
    @{ Since = $since; Cpu = $null; CpuTime = $null; Strikes = @{}; Last = @{} }
}

# Revisión liviana para los avisos. Devuelve los avisos nuevos (sin repetir el mismo antes de 1 hora).
function Get-WatchAlerts($State, $Settings) {
    $now = Get-Date
    $since = $State.Since
    $State.Since = $now
    $alerts = @()
    if ($Settings.AvisoPantallaAzul) {
        $bsod = @(Get-Events @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; StartTime = $since } 5)
        if ($bsod.Count) {
            $code = $null
            if ("$($bsod[0].Message)" -match '0x([0-9a-fA-F]{8})\b') { $code = [int][Convert]::ToInt64($Matches[1], 16) }
            $info = Get-BugCheckInfo $code
            $alerts += @{ Type = 'pantalla-azul'; Title = 'Hubo una pantalla azul'; Check = 'Test-BlueScreens'; FindingId = 'pantallas-azules'
                Text = "Windows se detuvo con el error $($info.Name). Haz clic para ver la causa y cómo arreglarlo." }
        }
        $sudden = @(Get-Events @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = $since } 5 |
            Where-Object { try { [int64]$_.Properties[0].Value -eq 0 } catch { $true } })
        if ($sudden.Count) {
            $alerts += @{ Type = 'apagon'; Title = 'La PC se apagó de golpe'; Check = 'Test-BlueScreens'; FindingId = 'apagones'
                Text = 'Windows no se cerró bien la última vez (sin pantalla azul). Haz clic para ver las causas posibles.' }
        }
    }
    if ($Settings.AvisoTemperatura) {
        $temps = Get-Temperatures
        $max = if ($temps.Count) { ($temps | Measure-Object -Maximum).Maximum } else { $null }
        if ($null -ne $max -and $max -ge 85) {
            $alerts += @{ Type = 'temperatura'; Title = "La PC está muy caliente: $max °C"; Check = 'Test-Temperature'; FindingId = 'temperatura'
                Text = 'Revisa que las rejillas no estén tapadas y cierra los programas pesados. Haz clic para ver cómo bajar la temperatura.' }
        } elseif ((Get-Events @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Processor-Power'; Id = 37; StartTime = $since } 20).Count -ge 3) {
            $alerts += @{ Type = 'temperatura'; Title = 'El procesador está frenando'; Check = 'Test-Temperature'; FindingId = 'temperatura'
                Text = 'Windows tuvo que bajar la velocidad del procesador varias veces (suele ser por calor). Haz clic para ver qué hacer.' }
        }
    }
    if ($Settings.AvisoProcesador) {
        $strikes = @{}
        if ($State.Cpu -and $State.CpuTime) {
            $elapsed = ($now - $State.CpuTime).TotalMilliseconds * [Environment]::ProcessorCount
            $top = @(Get-CpuGroups $State.Cpu $elapsed) | Select-Object -First 1
            if ($top -and $top.Cpu -ge 40 -and -not (Test-ProtectedProcess $top.Name $top.Path)) {
                $strikes[$top.Name] = 1 + [int]$State.Strikes[$top.Name]
                if ($strikes[$top.Name] -ge 2) {
                    $alerts += @{ Type = "cpu-$($top.Name)"; Title = "$(Get-ProcessLabel $top) usa el $([Math]::Round($top.Cpu)) % del procesador"
                        Check = 'Test-CpuUsage'; FindingId = 'procesos'
                        Text = 'Lleva varios minutos así: calienta la PC y gasta batería. Haz clic para ver cómo cerrarlo.' }
                }
            }
        }
        $State.Strikes = $strikes
        $snap = @{}
        foreach ($p in Get-Process) { try { $snap[$p.Id] = $p.TotalProcessorTime.TotalMilliseconds } catch { } }
        $State.Cpu = $snap
        $State.CpuTime = Get-Date
    }
    if ($Settings.AvisoMemoria) {
        $os = Get-CimInstance Win32_OperatingSystem
        $used = [int][Math]::Round(100 * (1 - [double]$os.FreePhysicalMemory / [double]$os.TotalVisibleMemorySize))
        if ($used -ge 92) {
            $alerts += @{ Type = 'memoria'; Title = "La memoria está al $used %"; Check = 'Test-Memory'; FindingId = 'memoria'
                Text = 'La PC puede trabarse. Cierra programas o pestañas que no uses. Haz clic para ver cuáles consumen más.' }
        }
    }
    if ($Settings.AvisoDisco) {
        $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
        if ($d.Size -and ($d.FreeSpace -lt 10GB -or $d.FreeSpace / $d.Size -lt 0.1)) {
            $alerts += @{ Type = 'disco'; Title = "Queda poco espacio en $env:SystemDrive"; Check = 'Test-DiskSpace'; FindingId = 'espacio'
                Text = "Quedan $(Format-Size $d.FreeSpace) libres. Haz clic para liberar espacio." }
        }
    }
    if ($Settings.AvisoDespertar) {
        $wake = @(Get-Events @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Power-Troubleshooter'; Id = 1; StartTime = $since } 10 |
            Where-Object { $_.TimeCreated.Hour -lt 6 })
        if ($wake.Count) {
            $alerts += @{ Type = 'despertar'; Title = 'La PC se despertó sola de madrugada'; Check = 'Test-WakeSources'; FindingId = 'despertares'
                Text = "Salió de la suspensión a las $($wake[0].TimeCreated.ToString('HH:mm')). Haz clic para ver qué la despierta y evitarlo." }
        }
    }
    $result = @()
    foreach ($a in $alerts) {
        $wait = if ($a.Type -eq 'disco') { 1440 } else { 60 }
        $last = $State.Last[$a.Type]
        if ($last -and ($now - $last).TotalMinutes -lt $wait) { continue }
        $State.Last[$a.Type] = $now
        $result += $a
    }
    $result
}

function Invoke-WatchRound {
    $g = $script:Gui
    if (-not $g -or $g.IsBusy -or -not $script:Settings.AvisosActivos -or $g.WatchRunning) { return }
    $g.WatchRunning = $true
    try {
        $alerts = @(Invoke-Background { param($st, $se) Get-WatchAlerts $st $se } @($g.WatchState, $script:Settings))
        $script:Settings.UltimaRevisionAvisos = ([datetime]$g.WatchState.Since).ToString('o')
        Save-Settings
        if ($alerts.Count) {
            Show-Alert $alerts[0]
            foreach ($a in $alerts | Select-Object -Skip 1) { Add-AlertHistory $a }
        }
    } catch {
        Write-Log "Error en la revisión de avisos: $($_.Exception.Message)"
    } finally {
        $g.WatchRunning = $false
    }
}

function Add-AlertHistory($Alert) {
    $g = $script:Gui
    $v = New-Object DiagnosticoPC.AlertView
    $v.Time = Format-Date (Get-Date)
    $v.Title = $Alert.Title
    $v.Text = $Alert.Text
    $g.AlertItems.Insert(0, $v)
    while ($g.AlertItems.Count -gt 30) { $g.AlertItems.RemoveAt($g.AlertItems.Count - 1) }
    $g.AlertsEmpty.Visibility = 'Collapsed'
}

function Show-Alert($Alert) {
    $g = $script:Gui
    $g.LastAlert = $Alert
    Add-AlertHistory $Alert
    Write-Log "Aviso: $($Alert.Title)"
    if (-not $g.Tray) { return }
    $g.Tray.Visible = $true
    $g.Tray.BalloonTipTitle = Limit-Text $Alert.Title 63
    $g.Tray.BalloonTipText = Limit-Text $Alert.Text 255
    $g.Tray.BalloonTipIcon = if ($Alert.Test) { 'Info' } else { 'Warning' }
    $g.Tray.ShowBalloonTip(15000)
}

function Send-TestAlert {
    Show-Alert @{ Type = 'prueba'; Test = $true; Title = 'Así se ven los avisos'
        Text = 'Cuando Diagnóstico PC encuentre un problema verás un aviso como este. Al hacer clic se abre con el paso a paso.' }
}

# Al hacer clic en el aviso: abre la ventana con ese problema elegido (revisado de nuevo)
function Open-LastAlert {
    $g = $script:Gui
    $a = $g.LastAlert
    Restore-MainWindow
    if (-not $a -or $a.Test) { Show-Page 'PageAlerts'; return }
    if (@($g.AllFindings).Count) {
        Show-Page 'PageResults'
        $g.Filter = $null
        Invoke-GuiAction 'Revisando el problema...' { Invoke-Recheck $a.Check $a.FindingId }
    } else {
        Start-Analysis
        Update-FindingList $a.FindingId
    }
}

function Get-AppIcon {
    try {
        if ($script:IsExe) { return [System.Drawing.Icon]::ExtractAssociatedIcon($script:ScriptPath) }
        $ico = Join-Path $script:ScriptDir 'icono.ico'
        if (Test-Path -LiteralPath $ico) { return New-Object System.Drawing.Icon($ico) }
    } catch { }
    [System.Drawing.SystemIcons]::Information
}

function Initialize-Tray {
    $g = $script:Gui
    try {
        $tray = New-Object System.Windows.Forms.NotifyIcon
        $tray.Icon = Get-AppIcon
        $tray.Text = 'Diagnóstico PC'
        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        [void]$menu.Items.Add('Abrir Diagnóstico PC', $null, { Restore-MainWindow })
        [void]$menu.Items.Add('Analizar ahora', $null, { Restore-MainWindow; Show-ResultsOrHome; Start-Analysis })
        [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
        [void]$menu.Items.Add('Salir', $null, { Exit-App })
        $tray.ContextMenuStrip = $menu
        $tray.Add_BalloonTipClicked({ Open-LastAlert })
        $tray.Add_MouseClick({ param($s, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Restore-MainWindow } })
        $g.Tray = $tray
    } catch {
        $g.Tray = $null
    }
}

function Update-Tray {
    $g = $script:Gui
    if (-not $g.Tray) { return }
    $hidden = -not $g.Window.IsVisible
    $g.Tray.Visible = [bool]($script:Settings.AvisosActivos -or $hidden)
    $g.Tray.Text = if ($script:Settings.AvisosActivos) { Limit-Text "Diagnóstico PC · revisa cada $($script:Settings.Intervalo) min" 63 } else { 'Diagnóstico PC' }
}

function Remove-Tray {
    $g = $script:Gui
    if (-not $g -or -not $g.Tray) { return }
    try { $g.Tray.Visible = $false; $g.Tray.Dispose() } catch { }
    $g.Tray = $null
}

function Restore-MainWindow {
    $w = $script:Gui.Window
    if (-not $w.IsVisible) { $w.Show() }
    if ($w.WindowState -eq 'Minimized') { $w.WindowState = 'Normal' }
    [void]$w.Activate()
    $w.Topmost = $true
    $w.Topmost = $false
    Update-Tray
}

function Exit-App {
    $g = $script:Gui
    $g.ExitRequested = $true
    $g.Window.Close()
}

function Restart-WatchTimer {
    $g = $script:Gui
    if (-not $g.WatchTimer) { return }
    $g.WatchTimer.Stop()
    $g.WatchTimer.Interval = [TimeSpan]::FromMinutes([Math]::Max(1, [int]$script:Settings.Intervalo))
    if ($script:Settings.AvisosActivos) { $g.WatchTimer.Start() }
    Update-Tray
}

# "Iniciar con Windows": tarea programada al iniciar sesión, con permisos de administrador (sin preguntar)
function Set-StartupTask([bool]$Enable) {
    if (-not $Enable) {
        Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
        return
    }
    if ($script:IsExe) {
        $exe = $script:ScriptPath
        $arguments = '-Avisos'
    } else {
        $exe = Join-Path $PSHOME 'powershell.exe'
        $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File `"$script:ScriptPath`" -Avisos"
    }
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action = New-ScheduledTaskAction -Execute $exe -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $trigger.Delay = 'PT30S'
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
        -Description 'Diagnóstico PC: avisos junto al reloj' -Force | Out-Null
}

function Test-StartupTask { [bool](Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue) }

$script:Intervals = @(2, 5, 10, 15, 30)

function Import-SettingsToUi {
    $g = $script:Gui
    $s = $script:Settings
    $g.LoadingSettings = $true
    $g.ChkAlerts.IsChecked = [bool]$s.AvisosActivos
    $g.ChkAlertBsod.IsChecked = [bool]$s.AvisoPantallaAzul
    $g.ChkAlertTemp.IsChecked = [bool]$s.AvisoTemperatura
    $g.ChkAlertCpu.IsChecked = [bool]$s.AvisoProcesador
    $g.ChkAlertMem.IsChecked = [bool]$s.AvisoMemoria
    $g.ChkAlertDisk.IsChecked = [bool]$s.AvisoDisco
    $g.ChkAlertWake.IsChecked = [bool]$s.AvisoDespertar
    $g.ChkKeep.IsChecked = [bool]$s.SeguirAlCerrar
    $g.CbInterval.Items.Clear()
    foreach ($m in $script:Intervals) { [void]$g.CbInterval.Items.Add($m) }
    $g.CbInterval.SelectedItem = if ($script:Intervals -contains [int]$s.Intervalo) { [int]$s.Intervalo } else { 5 }
    if ($script:StoreEdition) {
        $g.ChkStartup.Visibility = 'Collapsed'
    } else {
        try { $g.ChkStartup.IsChecked = Test-StartupTask } catch { $g.ChkStartup.IsChecked = $false }
    }
    $g.AlertOptions.IsEnabled = [bool]$s.AvisosActivos
    $g.LoadingSettings = $false
}

function Save-SettingsFromUi {
    $g = $script:Gui
    if ($g.LoadingSettings) { return }
    $s = $script:Settings
    $s.AvisosActivos = [bool]$g.ChkAlerts.IsChecked
    $s.AvisoPantallaAzul = [bool]$g.ChkAlertBsod.IsChecked
    $s.AvisoTemperatura = [bool]$g.ChkAlertTemp.IsChecked
    $s.AvisoProcesador = [bool]$g.ChkAlertCpu.IsChecked
    $s.AvisoMemoria = [bool]$g.ChkAlertMem.IsChecked
    $s.AvisoDisco = [bool]$g.ChkAlertDisk.IsChecked
    $s.AvisoDespertar = [bool]$g.ChkAlertWake.IsChecked
    $s.SeguirAlCerrar = [bool]$g.ChkKeep.IsChecked
    if ($g.CbInterval.SelectedItem) { $s.Intervalo = [int]$g.CbInterval.SelectedItem }
    $g.AlertOptions.IsEnabled = $s.AvisosActivos
    Save-Settings
    Restart-WatchTimer
}

function Set-StartupFromUi {
    $g = $script:Gui
    if ($g.LoadingSettings) { return }
    $want = [bool]$g.ChkStartup.IsChecked
    try {
        Set-StartupTask $want
    } catch {
        [void](Show-Message "No se pudo cambiar el inicio con Windows:`n$($_.Exception.Message)" 'Warning')
        $g.LoadingSettings = $true
        $g.ChkStartup.IsChecked = -not $want
        $g.LoadingSettings = $false
    }
}

#endregion

#region Ventana principal

# Crea la ventana con todos sus eventos (sin mostrarla)
function New-MainWindow {
    Initialize-GuiTypes
    try { [void][DiagnosticoPC.NativeMethods]::SetProcessDPIAware() } catch { }
    [System.Windows.Forms.Application]::EnableVisualStyles()
    if (-not $script:Settings) { $script:Settings = Get-Settings }

    $g = New-XamlWindow $script:Xaml
    $window = $g.Window
    # En pantallas pequeñas, que la ventana no sea más grande que el escritorio
    $area = [System.Windows.SystemParameters]::WorkArea
    $window.MinWidth = [Math]::Min($window.MinWidth, $area.Width)
    $window.MinHeight = [Math]::Min($window.MinHeight, $area.Height)
    $window.Width = [Math]::Min($window.Width, $area.Width)
    $window.Height = [Math]::Min($window.Height, $area.Height)
    foreach ($k in 'IsBusy', 'AnalysisRunning', 'WatchRunning', 'ExitRequested', 'Running', 'LoadingSettings') { $g[$k] = $false }
    $g.AllFindings = @()
    $g.Filter = $null
    $g.LastAlert = $null
    $script:Gui = $g

    $pc = Get-CachedPcInfo
    $g.PcModel.Text = "$($pc.Manufacturer) $($pc.Model)".Trim()
    $g.PcDetails.Text = "$($pc.OS) · $($pc.RamGB) GB de RAM"
    $g.PcModel.ToolTip = "$($pc.Manufacturer) $($pc.Model) · $($pc.Cpu)"
    if (-not $pc.IsLaptop) { $g.PcGlyph.Text = [string][char]0xE7F4 }
    Add-HomeAreas
    Add-ToolButtons
    Update-HomeLast
    $g.AlertItems = New-Object 'System.Collections.ObjectModel.ObservableCollection[DiagnosticoPC.AlertView]'
    $g.AlertList.ItemsSource = $g.AlertItems
    Update-ChangeList
    Import-SettingsToUi
    $g.BtnSupport.Visibility = if (Test-SupportConfigured) { 'Visible' } else { 'Collapsed' }

    # --- Navegación ---
    $g.TabResults.Add_Click({ Show-ResultsOrHome })
    $g.TabAlerts.Add_Click({ Show-Page 'PageAlerts' })
    $g.TabTools.Add_Click({ Update-ChangeList; Show-Page 'PageTools' })
    $g.BtnAnalyze.Add_Click({ Start-Analysis })
    $g.BtnRescan.Add_Click({ Start-Analysis })
    $g.BtnReport.Add_Click({ Save-ReportDialog })

    # --- Resultados ---
    $g.FindingList.Add_SelectionChanged({ Show-FindingDetail $script:Gui.FindingList.SelectedItem })
    foreach ($level in 'Rojo', 'Amarillo', 'Verde') {
        $g["Cnt$level"].Tag = $level
        $g["Cnt$level"].Add_Click({
            param($s)
            $gg = $script:Gui
            $gg.Filter = if ($gg.Filter -eq $s.Tag) { $null } else { $s.Tag }
            Update-FindingList
        })
    }
    $g.BtnFix.Add_Click({ Start-FindingFix $script:Gui.FindingList.SelectedItem })
    $g.BtnSteps.Add_Click({
        $v = $script:Gui.FindingList.SelectedItem
        if ($v) { Show-StepWizard -Title $v.Title -Level $v.Level -Steps $v.Source.Steps -FindingView $v }
    })
    $g.BtnRecheck.Add_Click({ Start-Recheck $script:Gui.FindingList.SelectedItem })
    $g.DetailItems.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
        param($s, $e)
        $b = $e.OriginalSource
        if ($b -is [System.Windows.Controls.Button] -and "$($b.Tag)" -in '1', '2') { Start-ItemAction $b.DataContext "$($b.Tag)" }
    })

    # --- Avisos ---
    foreach ($name in 'ChkAlerts', 'ChkAlertBsod', 'ChkAlertTemp', 'ChkAlertCpu', 'ChkAlertMem', 'ChkAlertDisk', 'ChkAlertWake', 'ChkKeep') {
        $g[$name].Add_Checked({ Save-SettingsFromUi })
        $g[$name].Add_Unchecked({ Save-SettingsFromUi })
    }
    $g.CbInterval.Add_SelectionChanged({ Save-SettingsFromUi })
    $g.ChkStartup.Add_Click({ Set-StartupFromUi })
    $g.BtnTestAlert.Add_Click({ Send-TestAlert })

    # --- Herramientas y cambios ---
    $g.BtnRestore.Add_Click({ Open-Target 'rstrui.exe' })
    $g.ChangeList.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
        param($s, $e)
        $b = $e.OriginalSource
        if ($b -is [System.Windows.Controls.Button] -and "$($b.Tag)" -eq 'undo') { Start-Undo $b.DataContext }
    })

    # --- Ventana de resultado ---
    $g.OvClose.Add_Click({ Hide-Overlay })
    $g.OvSupport.Add_Click({ Open-SupportPage })
    $g.BtnSupport.Add_Click({ Open-SupportPage })
    $g.OvPrimary.Add_Click({
        $action = $script:Gui.OvPrimaryAction
        Hide-Overlay
        if ($action) { & $action }
    })

    # --- Avisos: ícono junto al reloj y revisión cada pocos minutos ---
    Initialize-Tray
    $g.WatchState = New-WatchState
    $g.WatchTimer = New-Object System.Windows.Threading.DispatcherTimer
    $g.WatchTimer.Add_Tick({ Invoke-WatchRound })
    $g.FirstWatch = New-Object System.Windows.Threading.DispatcherTimer
    $g.FirstWatch.Interval = [TimeSpan]::FromSeconds(20)
    $g.FirstWatch.Add_Tick({ $script:Gui.FirstWatch.Stop(); Invoke-WatchRound })

    $window.Add_Closing({
        param($s, $e)
        $gg = $script:Gui
        if ($gg.IsBusy) {
            $e.Cancel = $true
            [void](Show-Message 'Espera a que termine lo que se está haciendo.' 'Warning')
            return
        }
        # Al cerrar, sigue avisando junto al reloj (si está activado)
        if ($gg.Running -and -not $gg.ExitRequested -and $script:Settings.AvisosActivos -and $script:Settings.SeguirAlCerrar -and $gg.Tray) {
            $e.Cancel = $true
            $s.Hide()
            Update-Tray
            if (-not $script:Settings.AvisoCerrarVisto) {
                $script:Settings.AvisoCerrarVisto = $true
                Save-Settings
                $gg.Tray.BalloonTipTitle = 'Diagnóstico PC sigue junto al reloj'
                $gg.Tray.BalloonTipText = 'Te avisará si aparece un problema. Para cerrarla del todo: clic derecho en su ícono → Salir.'
                $gg.Tray.BalloonTipIcon = 'Info'
                $gg.Tray.ShowBalloonTip(10000)
            }
        }
    })

    Show-Page 'PageHome'
    $window
}

function Start-App([switch]$Hidden) {
    $script:Settings = Get-Settings
    if ($Hidden -and -not $script:Settings.AvisosActivos) { return }
    # Una sola copia abierta: si ya hay una (por ejemplo junto al reloj), se le pide que se muestre
    $created = $false
    $mutex = New-Object Threading.Mutex($true, 'Local\DiagnosticoPC', [ref]$created)
    if (-not $created) {
        if (-not $Hidden) {
            try { [void][Threading.EventWaitHandle]::OpenExisting('Local\DiagnosticoPC-Mostrar').Set() } catch { }
        }
        $mutex.Dispose()
        return
    }
    $showEvent = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::AutoReset, 'Local\DiagnosticoPC-Mostrar')
    try {
        $window = New-MainWindow
        $g = $script:Gui
        $g.Running = $true
        $g.ShowEvent = $showEvent
        $poll = New-Object System.Windows.Threading.DispatcherTimer
        $poll.Interval = [TimeSpan]::FromMilliseconds(700)
        $poll.Add_Tick({ if ($script:Gui.ShowEvent.WaitOne(0)) { Restore-MainWindow } })
        $poll.Start()
        $g.Poll = $poll
        $window.Add_Closed({
            $gg = $script:Gui
            foreach ($t in $gg.Poll, $gg.WatchTimer, $gg.FirstWatch) { if ($t) { $t.Stop() } }
            Remove-Tray
            [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
        })
        Restart-WatchTimer
        if ($script:Settings.AvisosActivos) { $g.FirstWatch.Start() }
        if (-not $Hidden) { $window.Show() }
        Update-Tray
        [System.Windows.Threading.Dispatcher]::Run()
    } finally {
        $showEvent.Dispose()
        try { $mutex.ReleaseMutex() } catch { }
        $mutex.Dispose()
    }
}

#endregion

#region Inicio

try {
    if ($Analizar) {
        Initialize-Types
        $script:Settings = Get-Settings
        $findings = Invoke-Analysis
        Write-ConsoleReport $findings
        if ($Informe) {
            Export-Report $findings $Informe
            Write-Host "Informe guardado: $Informe"
        }
        if ($Elevado) { Read-Host 'Presiona Enter para cerrar' }
    } else {
        Start-App -Hidden:$Avisos
    }
} catch {
    if ($Analizar) {
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
        if ($Elevado) { Read-Host 'Presiona Enter para cerrar' }
        exit 1
    }
    Write-Log "Error: $($_.Exception.Message)"
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show("Ocurrió un error:`n`n$($_.Exception.Message)", 'Diagnóstico PC',
        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
}

#endregion
