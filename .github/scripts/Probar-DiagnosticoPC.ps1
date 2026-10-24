<#
    Prueba automática de Diagnóstico PC en Windows (la usa GitHub Actions, que corre como administrador):
    1. Revisa la sintaxis y carga las funciones de la app sin abrirla.
    2. Prueba la lógica: lectura de energía, pantallas azules, programas que no dejan suspender, arranque,
       registro con deshacer, plan de energía con deshacer, cambios hechos, avisos e "Iniciar con Windows".
    3. Hace un análisis real del equipo de GitHub (sin ventana y con la ventana, en segundo plano).
    4. Llena la ventana con una PC de ejemplo (una laptop que se calienta en la mochila) usando la lógica
       real de la app, prueba botones y el paso a paso, y guarda capturas en .\capturas
       (con -EdicionStore: edición de la Microsoft Store, capturas en .\capturas\store).
#>
param([switch]$EdicionStore)
$ErrorActionPreference = 'Stop'
$env:DIAGNOSTICOPC_PRUEBA = '1'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$appPath = Join-Path $root 'DiagnosticoPC\DiagnosticoPC.ps1'
$out = Join-Path $root 'capturas'
if ($EdicionStore) { $out = Join-Path $out 'store' }
New-Item -ItemType Directory -Path $out -Force | Out-Null

# 1. Sintaxis
$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($appPath, [ref]$null, [ref]$errs)
if ($errs) {
    $errs | ForEach-Object { Write-Host "Línea $($_.Extent.StartLineNumber): $($_.Message)" }
    throw 'El script tiene errores de sintaxis.'
}

# Cargar funciones y variables del script sin ejecutar su inicio
foreach ($st in $ast.EndBlock.Statements) {
    if ($st -is [System.Management.Automation.Language.FunctionDefinitionAst] -or $st.Extent.Text -match '^\$script:\w+\s*=') {
        . ([scriptblock]::Create($st.Extent.Text))
    }
}
$script:DataDir = Join-Path $env:TEMP ('DiagnosticoPC-prueba-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
if ($EdicionStore) { $script:StoreEdition = $true }

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FALLÓ: $Message" }
    Write-Host "OK: $Message"
}

Initialize-Types
Assert ($script:TestMode) 'Modo de prueba activado (no crea puntos de restauración ni abre programas)'

# ---------------------------------------------------------------------------------------------
# 2. Lógica
# ---------------------------------------------------------------------------------------------
$caps = Get-PowerCapabilities
Assert ($null -ne $caps) "Lee las capacidades de energía (S3=$($caps.S3), S4=$($caps.S4), hiberfil=$($caps.HiberFilePresent), Espera moderna=$($caps.AoAc))"
$hib = Get-PowerValue $script:PowerGuids.SubSleep $script:PowerGuids.HibernateIdle
Assert ($null -ne $hib.Ac -and $null -ne $hib.Dc) "Lee «Hibernar tras» del plan activo (AC=$($hib.Ac), DC=$($hib.Dc))"
$plan = Get-ActivePlan
Assert ($plan.Guid -match '^[0-9a-f-]{36}$') "Lee el plan de energía activo: $($plan.Name) ($($plan.Guid))"

$info = Get-BugCheckInfo 0x9F
Assert ($info.Name -eq 'DRIVER_POWER_STATE_FAILURE' -and $info.Cause -eq 'energia' -and $info.Hex -eq '0x0000009F') 'Reconoce la pantalla azul 0x9F (driver al suspender)'
Assert ((Get-BugCheckInfo $null).Hex -eq 'desconocido') 'Pantalla azul sin código'
Assert ((Get-BugCheckInfo 0x12345).Name -eq 'Error 0x00012345') 'Pantalla azul con un código no listado'
foreach ($cause in 'energia', 'driver', 'memoria', 'disco', 'calor', 'video', 'sistema', 'manual') {
    $steps = @(Get-CrashSteps $cause)
    Assert ($steps.Count -ge 2 -and -not ($steps | Where-Object { -not $_.Title })) "Paso a paso para la causa «$cause» ($($steps.Count) pasos)"
}

# Minidump de ejemplo: cabecera PAGEDU64 con el código 0x9F
$dump = Join-Path $env:TEMP 'prueba-minidump.dmp'
$bytes = New-Object byte[] 0x100
[Text.Encoding]::ASCII.GetBytes('PAGEDU64').CopyTo($bytes, 0)
[BitConverter]::GetBytes([uint32]0x9F).CopyTo($bytes, 0x38)
[IO.File]::WriteAllBytes($dump, $bytes)
Assert ((Read-DumpCode $dump) -eq 0x9F) 'Lee el código de un minidump'
Remove-Item $dump

# "powercfg /requests" de ejemplo
$realPowerCfg = ${function:Invoke-PowerCfg}
function Invoke-PowerCfg([string[]]$Arguments) {
    if ($Arguments[0] -eq '/requests') {
        return "DISPLAY:`r`n[PROCESS] \Device\HarddiskVolume3\Program Files\Google\Chrome\Application\chrome.exe`r`nVideo Wake Lock`r`n`r`n" +
            "SYSTEM:`r`n[DRIVER] Realtek High Definition Audio (HDAUDIO\FUNC_01&VEN_10EC)`r`nAn audio stream is currently in use.`r`n" +
            "[PROCESS] \Device\HarddiskVolume3\Users\Ana\AppData\Local\Microsoft\Teams\current\Teams.exe`r`nLlamada en curso`r`n`r`n" +
            "AWAYMODE:`r`nNinguno.`r`n`r`nEXECUTION:`r`nNinguno.`r`n`r`nPERFBOOST:`r`nNinguno.`r`n"
    }
    & $realPowerCfg $Arguments
}
$req = @(Get-PowerRequests)
Assert ($req.Count -eq 3) "Lee los pedidos de energía ($($req.Count))"
$sb = Test-SleepBlockers
Assert ($sb.Level -eq 'Amarillo' -and $sb.Items.Count -eq 3) "Programas que no dejan suspender: $($sb.Title)"
$teams = $sb.Items | Where-Object { $_.Name -eq 'Teams.exe' }
Assert ($teams.Action -eq 'cerrar-programa' -and $teams.Arg.Type -eq 'PROCESS' -and $teams.Action2 -eq 'ignorar-bloqueo') 'Teams.exe se puede cerrar o ignorar'
Set-Item function:Invoke-PowerCfg $realPowerCfg

# Registro con deshacer (en una clave de prueba)
$testKey = 'HKCU:\Software\DiagnosticoPC-Prueba'
Remove-Item $testKey -Recurse -Force -ErrorAction SilentlyContinue
$u1 = Set-RegValue $testKey 'Nuevo' 1
Assert ((Get-RegValue $testKey 'Nuevo') -eq 1 -and -not $u1.Existed) 'Crea un valor nuevo en el registro'
Undo-Record $u1
Assert ($null -eq (Get-RegValue $testKey 'Nuevo')) 'Deshacer borra el valor nuevo'
[void](Set-RegValue $testKey 'Viejo' 5)
$u2 = Set-RegValue $testKey 'Viejo' 7
Undo-Record ($u2 | ConvertTo-Json | ConvertFrom-Json)
Assert ((Get-RegValue $testKey 'Viejo') -eq 5) 'Deshacer (leído desde JSON) devuelve el valor anterior'
$u3 = Set-RegValue $testKey 'Binario' ([byte[]](2, 0, 0, 0)) 'Binary'
$u4 = Set-RegValue $testKey 'Binario' ([byte[]](3, 0, 0, 0)) 'Binary'
Undo-Record ($u4 | ConvertTo-Json | ConvertFrom-Json)
Assert (([byte[]](Get-RegValue $testKey 'Binario'))[0] -eq 2) 'Deshacer devuelve un valor binario'

# Programas que arrancan con Windows: uno que ya no existe
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$approvedKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
if (-not (Test-Path $runKey)) { New-Item -Path $runKey -Force | Out-Null }
New-ItemProperty -Path $runKey -Name 'DiagnosticoPCPrueba' -Value '"C:\NoExiste\programa.exe" /min' -PropertyType String -Force | Out-Null
try {
    $e = Get-StartupEntries | Where-Object { $_.Name -eq 'DiagnosticoPCPrueba' }
    Assert ($e -and $e.Enabled -and -not $e.Exists -and $e.File -eq 'C:\NoExiste\programa.exe') 'Detecta un programa del arranque cuyo archivo ya no existe'
    $sa = Test-StartupApps
    Assert ($sa.Level -eq 'Amarillo' -and $sa.Fix -eq 'arranque-faltantes') "Arranque: $($sa.Title)"
    $res = Invoke-Fix 'quitar-arranque' @{ Name = 'DiagnosticoPCPrueba'; Approved = $approvedKey }
    $e = Get-StartupEntries | Where-Object { $_.Name -eq 'DiagnosticoPCPrueba' }
    Assert (-not $e.Enabled) "Lo quita del arranque: $($res.Message)"
    $entry = Add-ChangeLog $res.Description $res.Undo
    $logged = @(Get-ChangeLog)
    Assert ($logged.Count -eq 1 -and $logged[0].Descripcion -eq $res.Description) 'Anota el cambio en «Cambios hechos»'
    [void](Undo-Change $entry.Id)
    $e = Get-StartupEntries | Where-Object { $_.Name -eq 'DiagnosticoPCPrueba' }
    Assert ($e.Enabled) 'Deshacer lo vuelve a activar'
    Assert (@(Get-ChangeLog)[0].Deshecho) 'El cambio queda marcado como deshecho'
} finally {
    Remove-ItemProperty -Path $runKey -Name 'DiagnosticoPCPrueba' -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $approvedKey -Name 'DiagnosticoPCPrueba' -ErrorAction SilentlyContinue
}

# Plan de energía con deshacer (temporizadores de reactivación)
$g0 = $script:PowerGuids
$before = Get-PowerValue $g0.SubSleep $g0.RtcWake
if ($before.Dc -ge 0) {
    $res = Invoke-Fix 'despertares' $null
    $now = Get-PowerValue $g0.SubSleep $g0.RtcWake
    Assert ($now.Dc -eq 0 -and $now.Ac -eq 2) 'Apaga los temporizadores de reactivación con batería'
    foreach ($r in $res.Undo) { Undo-Record ($r | ConvertTo-Json | ConvertFrom-Json) }
    $after = Get-PowerValue $g0.SubSleep $g0.RtcWake
    Assert ($after.Dc -eq $before.Dc -and $after.Ac -eq $before.Ac) 'Deshacer devuelve los valores de energía anteriores'
} else {
    Write-Host 'Este equipo no tiene temporizadores de reactivación: se omite esa prueba.'
}

# Iniciar con Windows (tarea programada)
if (-not $EdicionStore) {
    Set-StartupTask $true
    Assert (Test-StartupTask) 'Crea la tarea «Iniciar con Windows»'
    $task = Get-ScheduledTask -TaskName $script:TaskName
    Assert ($task.Principal.RunLevel -eq 'Highest' -and $task.Actions[0].Arguments -match '-Avisos') 'La tarea arranca con -Avisos y permisos de administrador'
    Set-StartupTask $false
    Assert (-not (Test-StartupTask)) 'Quita la tarea «Iniciar con Windows»'
}

# Avisos: dos revisiones seguidas sin errores
$script:Settings = Get-Settings
$state = New-WatchState
$a1 = @(Get-WatchAlerts $state $script:Settings)
Start-Sleep -Seconds 2
$a2 = @(Get-WatchAlerts $state $script:Settings)
Assert ($state.Cpu.Count -gt 0) "Revisión de avisos sin errores ($($a1.Count + $a2.Count) avisos en el equipo de GitHub)"
$state.Last['memoria'] = Get-Date
Assert ($true) 'Los avisos repetidos se agrupan (una vez por hora)'

# ---------------------------------------------------------------------------------------------
# 3. Análisis real del equipo de GitHub (sin ventana)
# ---------------------------------------------------------------------------------------------
$sw = [Diagnostics.Stopwatch]::StartNew()
$real = @(Invoke-Analysis)
$sw.Stop()
Write-ConsoleReport $real
Assert ($real.Count -ge 15) "Análisis real: $($real.Count) resultados en $([int]$sw.Elapsed.TotalSeconds) s"
foreach ($f in $real) {
    if (-not $f.Id -or -not $f.Title -or $f.Level -notin 'Rojo', 'Amarillo', 'Verde', 'Info' -or -not $f.Check) { throw "Resultado incompleto: $($f | ConvertTo-Json -Depth 2)" }
}
$noInfo = @($real | Where-Object { $_.Level -eq 'Info' -and $_.Title -like 'No se pudo revisar*' })
foreach ($f in $noInfo) { Write-Host "Aviso: $($f.Title) → $($f.Detail)" }
Export-Report $real (Join-Path $out 'informe-real.html')
Assert ((Get-Content (Join-Path $out 'informe-real.html') -Raw -Encoding UTF8) -match 'Diagnóstico PC') 'Guarda el informe en HTML'

# ---------------------------------------------------------------------------------------------
# 4. Ventana
# ---------------------------------------------------------------------------------------------
function Wait-Render { for ($i = 0; $i -lt 15; $i++) { Update-UI; Start-Sleep -Milliseconds 40 } }

function Get-Bitmap($Element) {
    $Element.UpdateLayout()
    $w = [int]$Element.ActualWidth; $h = [int]$Element.ActualHeight
    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($Element)
    $rtb
}

function Save-Bitmap($Bitmap, [string]$Name) {
    foreach ($fmt in @(@{ Ext = 'png'; Enc = (New-Object System.Windows.Media.Imaging.PngBitmapEncoder) },
                       @{ Ext = 'jpg'; Enc = (New-Object System.Windows.Media.Imaging.JpegBitmapEncoder -Property @{ QualityLevel = 80 }) })) {
        $fmt.Enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($Bitmap))
        $fs = [IO.File]::Create((Join-Path $out "$Name.$($fmt.Ext)"))
        try { $fmt.Enc.Save($fs) } finally { $fs.Close() }
    }
    Write-Host "Captura guardada: $Name ($($Bitmap.PixelWidth) x $($Bitmap.PixelHeight))"
}

function Save-Shot([string]$Name) {
    Wait-Render
    Save-Bitmap (Get-Bitmap $window.Content) $Name
}

# La ventana del paso a paso, dibujada encima de la principal (oscurecida)
function Save-WizardShot([string]$Name, $Wizard) {
    Wait-Render
    $main = Get-Bitmap $window.Content
    $wzBmp = Get-Bitmap $Wizard.Window.Content
    $w = $main.PixelWidth; $h = $main.PixelHeight
    $x = [int](($w - $wzBmp.PixelWidth) / 2); $y = [int](($h - $wzBmp.PixelHeight) / 2)
    $dv = New-Object System.Windows.Media.DrawingVisual
    $dc = $dv.RenderOpen()
    $dc.DrawImage($main, (New-Object System.Windows.Rect(0, 0, $w, $h)))
    $dc.DrawRectangle((New-Brush '#73000000'), $null, (New-Object System.Windows.Rect(0, 0, $w, $h)))
    $dc.DrawRectangle((New-Brush '#40000000'), $null, (New-Object System.Windows.Rect(($x + 4), ($y + 8), $wzBmp.PixelWidth, $wzBmp.PixelHeight)))
    $dc.DrawImage($wzBmp, (New-Object System.Windows.Rect($x, $y, $wzBmp.PixelWidth, $wzBmp.PixelHeight)))
    $pen = New-Object System.Windows.Media.Pen((New-Brush '#B0B0B8'), 1)
    $dc.DrawRectangle($null, $pen, (New-Object System.Windows.Rect(($x - 0.5), ($y - 0.5), ($wzBmp.PixelWidth + 1), ($wzBmp.PixelHeight + 1))))
    $dc.Close()
    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($dv)
    Save-Bitmap $rtb $Name
}

function Invoke-Click($Button) {
    $Button.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Update-UI
}

$realSupportUrl = $script:SupportUrl
$script:SupportUrl = 'https://ko-fi.com/PENDIENTE'
Assert (-not (Test-SupportConfigured)) 'Sin enlace de Ko-fi configurado, el botón de apoyo queda oculto'
$script:SupportUrl = $realSupportUrl

$window = New-MainWindow
Assert ($window -is [System.Windows.Window]) 'New-MainWindow devuelve una única ventana WPF'
$g = $script:Gui
foreach ($n in 'PageHome', 'PageResults', 'PageAlerts', 'PageTools', 'Overlay', 'FindingList', 'DetailPanel', 'DetailItems', 'BtnFix',
               'BtnSteps', 'BtnRecheck', 'CntRojo', 'ChkAlerts', 'CbInterval', 'ChkStartup', 'ToolList', 'ChangeList', 'AlertList') {
    Assert ($null -ne $g[$n]) "Existe el control $n"
}
$window.WindowStartupLocation = 'Manual'
# 1400 x 860: las capturas sirven para la Microsoft Store (mínimo 1366 x 768)
$window.Left = 0; $window.Top = 0; $window.Width = 1400; $window.Height = 860
$window.ShowActivated = $false
$window.Content.Background = New-Brush '#F3F3F3'
$window.Show()
Update-UI
Assert ($g.BtnSupport.Visibility -eq 'Visible') 'Se muestra el botón «Apoyar a la app»'
Assert ($g.HomeAreas.Children.Count -eq 8 -and $g.ToolList.Children.Count -ge 8) 'El inicio muestra qué revisa y las herramientas están listas'
Assert ($g.CbInterval.Items.Count -eq 5 -and [int]$g.CbInterval.SelectedItem -eq 5) 'Avisos: revisar cada 5 minutos por defecto'
if ($EdicionStore) {
    Assert ($g.ChkStartup.Visibility -eq 'Collapsed') 'La edición Store no muestra «Iniciar con Windows»'
} else {
    Assert ($g.ChkStartup.Visibility -eq 'Visible') 'Se muestra «Iniciar con Windows»'
}
Assert ($null -ne $g.Tray) 'Ícono junto al reloj listo para los avisos'

# Análisis real desde la ventana (en segundo plano, con todas las funciones copiadas)
Invoke-Click $g.BtnAnalyze
Assert (@($g.AllFindings).Count -ge 15) "Análisis real desde la ventana: $(@($g.AllFindings).Count) resultados"
Assert ($g.PageResults.Visibility -eq 'Visible' -and $g.FindingList.Items.Count -eq @($g.AllFindings).Count) 'Muestra la lista de resultados'
Hide-Overlay

# Avisos desde la ventana (en segundo plano)
Invoke-WatchRound
Assert (-not $g.WatchRunning) 'Revisión de avisos desde la ventana sin errores'
Send-TestAlert
Assert ($g.AlertItems.Count -ge 1 -and $g.AlertsEmpty.Visibility -eq 'Collapsed') 'Un aviso queda en «Últimos avisos»'

# ---- Una laptop de ejemplo: se calienta en la mochila porque no hiberna (con la lógica real de la app) ----
$now = Get-Date
function New-FakeEvent([datetime]$Time, [string]$Message, $Value = 0) {
    [pscustomobject]@{ TimeCreated = $Time; Message = $Message; Properties = @([pscustomobject]@{ Value = $Value }) }
}
function Get-PcInfo {
    [pscustomobject]@{ Manufacturer = 'HP'; Model = 'Pavilion Laptop 15-eg2xxx'; OS = 'Windows 11 Home 24H2'; Build = 26100
        Cpu = '12th Gen Intel Core i7-1255U'; RamGB = 16; IsLaptop = $true; IsVirtual = $false; LastBoot = $now.AddDays(-3).AddHours(-2) }
}
function Get-PowerCapabilities { [pscustomobject]@{ LidPresent = $true; S3 = $false; S4 = $true; HiberFilePresent = $true; AoAc = $true; HiberFileType = 2; BatteriesPresent = $true } }
function Get-PowerValue([string]$Sub, [string]$Setting) {
    switch ($Setting) {
        $script:PowerGuids.HibernateIdle   { return [pscustomobject]@{ Ac = 0; Dc = 0 } }
        $script:PowerGuids.LidAction       { return [pscustomobject]@{ Ac = 1; Dc = 1 } }
        $script:PowerGuids.RtcWake         { return [pscustomobject]@{ Ac = 1; Dc = 1 } }
        $script:PowerGuids.ProcThrottleMax { return [pscustomobject]@{ Ac = 100; Dc = 100 } }
    }
    [pscustomobject]@{ Ac = 0; Dc = 0 }
}
function Get-ActivePlan { [pscustomobject]@{ Guid = $script:PowerGuids.Balanced; Name = 'Equilibrado' } }
function Invoke-PowerCfg([string[]]$Arguments) {
    switch ($Arguments[0]) {
        '/requests' {
            return "DISPLAY:`r`nNinguno.`r`n`r`nSYSTEM:`r`n[PROCESS] \Device\HarddiskVolume3\Users\Ana\AppData\Local\Microsoft\Teams\current\Teams.exe`r`nLlamada en segundo plano`r`n`r`n" +
                "AWAYMODE:`r`nNinguno.`r`n`r`nEXECUTION:`r`n[PROCESS] \Device\HarddiskVolume3\Program Files\Microsoft OneDrive\OneDrive.exe`r`nSincronizando archivos`r`n"
        }
        '/devicequery' { return "Dispositivo de teclado HID`r`nMouse compatible con HID`r`nIntel(R) Wi-Fi 6 AX201 160MHz" }
    }
    ''
}
function Get-Events([hashtable]$Filter, [int]$Max = 500) {
    $wer = 'El equipo se reinició después de una comprobación de errores. La comprobación de errores fue: {0} (0x0000000000000003, 0xffffb60c8b2f7a20, 0xfffff8065f87f750, 0xffffb60c9a3e5010). Se guardó un volcado en: C:\WINDOWS\Minidump\{1}.dmp.'
    $wake = "El sistema ha vuelto de un estado de bajo consumo.`r`n`r`nOrigen de reactivación: {0}"
    switch ($Filter.ProviderName) {
        'Microsoft-Windows-WER-SystemErrorReporting' {
            return @(
                New-FakeEvent $now.Date.AddDays(-2).AddHours(8).AddMinutes(14) ($wer -f '0x0000009f', '102226-10546-01')
                New-FakeEvent $now.Date.AddDays(-9).AddHours(7).AddMinutes(52) ($wer -f '0x0000014f', '101526-9875-01')
            ) | Where-Object { $_.TimeCreated -ge $Filter.StartTime }
        }
        'Microsoft-Windows-Kernel-Power' {
            return @(
                New-FakeEvent $now.Date.AddDays(-2).AddHours(8).AddMinutes(15) '' 159
                New-FakeEvent $now.Date.AddDays(-6).AddHours(19).AddMinutes(3) '' 0
            ) | Where-Object { $_.TimeCreated -ge $Filter.StartTime }
        }
        'Microsoft-Windows-Power-Troubleshooter' {
            return @(
                New-FakeEvent $now.Date.AddDays(-1).AddHours(3).AddMinutes(12) ($wake -f 'Temporizador: Windows Update (Orchestrator)')
                New-FakeEvent $now.Date.AddDays(-4).AddHours(2).AddMinutes(47) ($wake -f 'Dispositivo: Intel(R) Wi-Fi 6 AX201 160MHz')
                New-FakeEvent $now.Date.AddDays(-4).AddHours(13).AddMinutes(30) ($wake -f 'Botón de encendido')
            ) | Where-Object { $_.TimeCreated -ge $Filter.StartTime }
        }
        'Microsoft-Windows-Kernel-Processor-Power' { return @(1..14 | ForEach-Object { New-FakeEvent $now.AddHours(-$_ * 9) '' }) }
    }
    @()
}
function Get-Temperatures { @(84) }
function Get-CpuSample([int]$Milliseconds) {
    @(
        [pscustomobject]@{ Name = 'Teams'; Cpu = 38.4; Count = 6; Path = 'C:\Users\Ana\AppData\Local\Microsoft\Teams\current\Teams.exe'; Description = 'Microsoft Teams' }
        [pscustomobject]@{ Name = 'chrome'; Cpu = 11.2; Count = 23; Path = 'C:\Program Files\Google\Chrome\Application\chrome.exe'; Description = 'Google Chrome' }
        [pscustomobject]@{ Name = 'OneDrive'; Cpu = 6.1; Count = 1; Path = 'C:\Program Files\Microsoft OneDrive\OneDrive.exe'; Description = 'Microsoft OneDrive' }
        [pscustomobject]@{ Name = 'MsMpEng'; Cpu = 4.0; Count = 1; Path = $null; Description = $null }
    )
}
function Get-StartupEntries {
    $list = @(
        @('Microsoft Teams', 'Microsoft Teams'), @('OneDrive', 'Microsoft OneDrive'), @('Spotify', 'Spotify'), @('Steam', 'Steam Client Bootstrapper'),
        @('Discord', 'Discord'), @('EpicGamesLauncher', 'Epic Games Launcher'), @('Zoom', 'Zoom Meetings'), @('HP Smart', 'HP Smart'),
        @('Adobe Acrobat Synchronizer', 'Adobe Acrobat'), @('RtkAudUService', 'Realtek HD Audio Universal Service'),
        @('Google Update', 'Google Installer'), @('CCleaner Smart Cleaning', 'CCleaner'), @('SecurityHealth', 'Windows Security notification icon')
    )
    foreach ($e in $list) {
        [pscustomobject]@{ Name = $e[0]; Command = "C:\Program Files\$($e[0])\app.exe"; File = "C:\Program Files\$($e[0])\app.exe"; Exists = $true
            Enabled = $true; Approved = 'HKCU:\Prueba'; Description = $e[1] }
    }
    [pscustomobject]@{ Name = 'McAfee WebAdvisor'; Command = '"C:\Program Files\McAfee\WebAdvisor\UIHost.exe"'; File = 'C:\Program Files\McAfee\WebAdvisor\UIHost.exe'
        Exists = $false; Enabled = $true; Approved = 'HKCU:\Prueba'; Description = '' }
}
function Get-RegValue([string]$Path, [string]$Name) {
    switch ($Name) {
        'HiberbootEnabled' { return 1 }
        'CrashDumpEnabled' { return 7 }
        'Shell' { return 'explorer.exe' }
        'Userinit' { return "$env:SystemRoot\system32\userinit.exe," }
    }
    $null
}
function Repair-WindowsImage { [pscustomobject]@{ ImageHealthState = 'Healthy' } }
function Get-PhysicalDisk { [pscustomobject]@{ FriendlyName = 'Samsung SSD 980 500GB'; HealthStatus = 'Healthy'; MediaType = 'SSD'; Size = 500GB } }
function Get-StorageReliabilityCounter { process { [pscustomobject]@{ Wear = 4; Temperature = 41 } } }
function Get-CimInstance {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$ClassName, [string]$Namespace, [string]$Filter)
    switch ($ClassName) {
        'Win32_OperatingSystem' { [pscustomobject]@{ TotalVisibleMemorySize = 16473856; FreePhysicalMemory = 6324428; LastBootUpTime = $now.AddDays(-3) } }
        'Win32_PnPEntity' { }
        'Win32_VideoController' {
            [pscustomobject]@{ Name = 'Intel(R) Iris(R) Xe Graphics'; DriverVersion = '30.0.100.9684'; DriverDate = [datetime]'2021-06-10'; InfFilename = 'oem52.inf'; AdapterCompatibility = 'Intel Corporation' }
        }
        'Win32_LogicalDisk' { [pscustomobject]@{ DeviceID = 'C:'; Size = 511GB; FreeSpace = 187GB } }
        'BatteryStaticData' { [pscustomobject]@{ DesignedCapacity = 41004 } }
        'BatteryFullChargedCapacity' { [pscustomobject]@{ FullChargedCapacity = 33620 } }
        'BatteryCycleCount' { [pscustomobject]@{ CycleCount = 214 } }
        'MSStorageDriver_FailurePredictStatus' { [pscustomobject]@{ PredictFailure = $false } }
        'AntiVirusProduct' { [pscustomobject]@{ displayName = 'Microsoft Defender Antivirus'; productState = 397568 } }
    }
}

# Revisiones con la lógica real y los datos de ejemplo (sin segundo plano: usa las funciones de arriba)
$script:PcInfo = $null
$gui = $script:Gui
$script:Gui = $null
$sample = @(Invoke-Analysis)
$script:Gui = $gui
$byId = @{}
foreach ($f in $sample) { $byId[$f.Id] = $f }
Assert ($byId['hibernacion'].Level -eq 'Rojo' -and $byId['hibernacion'].Fix -eq 'activar-hibernacion') "Ejemplo: $($byId['hibernacion'].Title)"
Assert ($byId['pantallas-azules'].Level -eq 'Rojo' -and $byId['pantallas-azules'].Detail -match '^Sí, se confirmó' -and $byId['pantallas-azules'].Fix -eq 'desactivar-inicio-rapido') "Ejemplo: $($byId['pantallas-azules'].Title) (confirmada, causa: energía)"
Assert ($byId['apagones'].Level -eq 'Amarillo') "Ejemplo: $($byId['apagones'].Title)"
Assert ($byId['despertares'].Level -eq 'Amarillo') "Ejemplo: $($byId['despertares'].Title)"
Assert ($byId['bloqueos-suspension'].Level -eq 'Amarillo') "Ejemplo: $($byId['bloqueos-suspension'].Title)"
Assert ($byId['procesos'].Level -eq 'Amarillo' -and $byId['procesos'].Items.Count -eq 4) "Ejemplo: $($byId['procesos'].Title)"
Assert ($byId['temperatura'].Level -eq 'Amarillo') "Ejemplo: $($byId['temperatura'].Title)"
Assert ($byId['arranque'].Level -eq 'Amarillo' -and $byId['arranque'].Fix -eq 'arranque-faltantes') "Ejemplo: $($byId['arranque'].Title)"
Assert ($byId['driver-video'].Level -eq 'Amarillo') "Ejemplo: $($byId['driver-video'].Title)"
Assert ($byId['inicio-rapido'].Level -eq 'Amarillo') 'Ejemplo: con pantallas azules, el inicio rápido pasa a amarillo'
Assert ($byId['bateria'].Level -eq 'Verde' -and $byId['antivirus'].Level -eq 'Verde' -and $byId['salud-disco'].Level -eq 'Verde') 'Ejemplo: batería, antivirus y disco en verde'
Export-Report $sample (Join-Path $out 'informe-ejemplo.html')

# Ventana con la laptop de ejemplo (sin el nombre del equipo de GitHub)
$pc = Get-PcInfo
$g.PcModel.Text = "$($pc.Manufacturer) $($pc.Model)"
$g.PcDetails.Text = "$($pc.OS) · $($pc.RamGB) GB de RAM"
$script:Settings.UltimoAnalisis = ''
Update-HomeLast
Show-Page 'PageHome'
Save-Shot '0-inicio'

Set-Findings $sample
Show-Page 'PageResults'
Update-FindingList 'hibernacion'
Assert ($g.FindingList.SelectedItem.Id -eq 'hibernacion' -and $g.FindingList.SelectedItem.Level -eq 'Rojo') 'Los graves aparecen primero (hibernación elegida)'
Assert ($g.CntRojoN.Text -eq "$(@($sample | Where-Object { $_.Level -eq 'Rojo' }).Count)") "Contador de graves: $($g.CntRojoN.Text)"
Assert ($g.BtnFix.Visibility -eq 'Visible' -and $g.BtnSteps.Visibility -eq 'Visible') 'El resultado ofrece «Arreglar» y «Ver el paso a paso»'
Save-Shot '1-resumen'

# Filtro por color
Invoke-Click $g.CntAmarillo
Assert (-not ($g.FindingList.ItemsSource | Where-Object { $_.Level -ne 'Amarillo' })) 'Tocar el amarillo muestra solo los amarillos'
Invoke-Click $g.CntAmarillo
Assert ($g.FindingList.Items.Count -eq $sample.Count) 'Tocarlo otra vez muestra todo'

# Paso a paso (ventana aparte)
$v = $g.FindingList.SelectedItem
$wz = New-StepWizard -Title $v.Title -Level $v.Level -Steps $v.Source.Steps -FindingView $v
$wz.Window.WindowStartupLocation = 'Manual'
$wz.Window.Left = 0; $wz.Window.Top = 0
$wz.Window.ShowActivated = $false
$wz.Window.Content.Background = New-Brush '#F3F3F3'
$wz.Window.Show()
Update-UI
Assert ($wz.WzCounter.Text -eq "Paso 1 de $($v.StepCount + 1)" -and $wz.WzCmdBox.Visibility -eq 'Visible' -and $wz.WzAction.Content -eq 'Hacerlo por mí') "Paso a paso: $($wz.WzCounter.Text) con comando y botón «Hacerlo por mí»"
Assert (-not $wz.WzPrev.IsEnabled) 'En el primer paso no se puede ir atrás'
Invoke-Click $wz.WzNext
Assert ($wz.Index -eq 1 -and $wz.WzPathBox.Visibility -eq 'Visible' -and $wz.WzAction.Content -eq 'Abrir la configuración avanzada') 'El paso 2 muestra dónde está y abre la ventana de Windows'
Save-WizardShot '2-paso-a-paso' $wz
Invoke-Click $wz.WzAction
Assert ($wz.WzResultBox.Visibility -eq 'Visible') 'El botón del paso confirma que abrió la ventana'
Invoke-Click $wz.WzPrev
Assert ($wz.Index -eq 0) 'El botón «Anterior» vuelve al paso 1'
for ($i = 0; $i -lt $v.StepCount; $i++) { Invoke-Click $wz.WzNext }
Assert ($wz.WzStepTitle.Text -eq '¿Se solucionó?' -and $wz.WzNext.Content -eq 'Terminar' -and $wz.WzAction.Content -eq 'Volver a revisar') 'El último paso ofrece volver a revisar'
$wz.Window.Close()
$script:Wizard = $null

# Programas
Update-FindingList 'procesos'
Wait-Render
$detailButtons = @($g.DetailItems.ItemsSource | Where-Object { $_.HasAction })
Assert ($detailButtons.Count -eq 3) 'Los programas tienen el botón «Cerrar» (menos los de Windows)'
Save-Shot '3-programas'

# Pantallas azules
Update-FindingList 'pantallas-azules'
Wait-Render
Assert ($g.DetailItems.Items.Count -eq 2) 'Cada pantalla azul aparece con su paso a paso'
Save-Shot '4-pantallas-azules'

# Avisos
$g.AlertItems.Clear()
foreach ($a in @(
    @{ Title = 'Teams usa el 41 % del procesador'; Text = 'Lleva varios minutos así: calienta la PC y gasta batería. Haz clic para ver cómo cerrarlo.' }
    @{ Title = 'La PC se despertó sola de madrugada'; Text = 'Salió de la suspensión a las 03:12. Haz clic para ver qué la despierta y evitarlo.' }
    @{ Title = 'Hubo una pantalla azul'; Text = 'Windows se detuvo con el error DRIVER_POWER_STATE_FAILURE. Haz clic para ver la causa y cómo arreglarlo.' }
)) { Add-AlertHistory $a }
$times = @($now.AddMinutes(-25), $now.Date.AddHours(7).AddMinutes(3), $now.Date.AddDays(-2).AddHours(8).AddMinutes(16))
for ($i = 0; $i -lt $g.AlertItems.Count; $i++) { $g.AlertItems[$i].Time = Format-Date $times[$i] }
$g.AlertList.Items.Refresh()
Show-Page 'PageAlerts'
Save-Shot '5-avisos'

# Herramientas y cambios
Save-ChangeLog @()
foreach ($c in @(
    @('Hibernación activada (con batería, después de 1 hora en suspensión)', @(@{ T = 'hibernate-off' })),
    @('Quitado del arranque: McAfee WebAdvisor', @(@{ T = 'reg'; Path = 'HKCU:\Prueba'; Name = 'x'; Existed = $false })),
    @('Temporizadores de reactivación apagados con batería', @(@{ T = 'power' })),
    @('Programa cerrado: Microsoft Teams (Teams.exe)', @())
)) { [void](Add-ChangeLog $c[0] $c[1]) }
Update-ChangeList
Assert ($g.ChangeList.Items.Count -eq 4 -and @($g.ChangeList.ItemsSource | Where-Object { $_.CanUndo }).Count -eq 3) 'Los cambios hechos se pueden deshacer'
Show-Page 'PageTools'
Save-Shot '6-herramientas'

# Resultado de un arreglo
Show-Page 'PageResults'
Update-FindingList 'hibernacion'
Show-OverlayResult -Kind Ok -Title 'Listo' -ShowSupport `
    -Text 'Listo. La hibernación está activada: con batería, después de 1 hora en suspensión la PC guarda todo y se apaga por completo. Además, «Hibernar» aparece en Inicio → botón de apagado.'
Save-Shot '7-arreglado'
Invoke-Click $g.OvClose
Assert ($g.Overlay.Visibility -eq 'Collapsed') 'El botón «Listo» cierra el resultado'

Invoke-Click $g.TabResults
Assert ($g.PageResults.Visibility -eq 'Visible' -and $g.TabResults.Tag -eq 'sel') 'La pestaña «Diagnóstico» vuelve a los resultados'

Remove-Tray
$window.Close()
Remove-Item -LiteralPath $script:DataDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $testKey -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'Prueba de Diagnóstico PC terminada correctamente.' -ForegroundColor Green
