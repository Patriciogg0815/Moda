<#
    Prueba automática del Monitor de Red.
    - En cualquier sistema: lógica del escáner (MAC, NetBIOS, mDNS, UPnP, fabricantes),
      estimación del tipo de equipo y modos de medición.
    - Con -EscaneoReal: escanea la red de verdad (en GitHub Actions encuentra al menos este equipo).
    - Con -EdicionStore: prueba la edición de la Microsoft Store (sin el modo de interceptar tráfico)
      y deja sus capturas en .\capturas\store
    - En Windows: carga la ventana real (sin mostrarla al usuario), la llena con una casa de ejemplo,
      prueba la edición de nombres y los ajustes, y guarda capturas en .\capturas
#>
param(
    [string]$Fabricantes,
    [switch]$EscaneoReal,
    [switch]$EdicionStore
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$appPath = Join-Path (Join-Path $root 'MonitorRed') 'MonitorRed.ps1'
$out = Join-Path $root 'capturas'
if ($EdicionStore) { $out = Join-Path $out 'store' }
New-Item -ItemType Directory -Path $out -Force | Out-Null
$enWindows = [Environment]::OSVersion.Platform -eq 'Win32NT'

# 1. Sintaxis
$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($appPath, [ref]$null, [ref]$errs)
if ($errs) {
    $errs | ForEach-Object { Write-Host "Línea $($_.Extent.StartLineNumber): $($_.Message)" }
    throw 'El script tiene errores de sintaxis.'
}

# 2. Cargar funciones y variables del script sin ejecutar su inicio
foreach ($st in $ast.EndBlock.Statements) {
    if ($st -is [System.Management.Automation.Language.FunctionDefinitionAst] -or $st.Extent.Text -match '^\$script:\w+\s*=') {
        . ([scriptblock]::Create($st.Extent.Text))
    }
}
$script:ScriptDir = Join-Path $root 'MonitorRed'
if ($EdicionStore) {
    $script:StoreEdition = $true
    $script:MeasurementModes = @($script:MeasurementModes | Where-Object { $_.Id -ne 'Intercept' })
}
$modeCount = if ($EdicionStore) { 3 } else { 4 }

# Datos del usuario en una carpeta temporal, para no tocar los reales
$script:DataDir = Join-Path ([IO.Path]::GetTempPath()) ('MonitorRed-prueba-' + [guid]::NewGuid().ToString('N'))
$script:DevicesFile = Join-Path $script:DataDir 'dispositivos.json'
$script:SettingsFile = Join-Path $script:DataDir 'ajustes.json'

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FALLÓ: $Message" }
    Write-Host "OK: $Message"
}

Initialize-ScannerTypes
Import-AppData

# 3. Utilidades de red
Assert ([MonitorRed.Net]::FormatMac('a4-c3-f0-11-22-33') -eq 'A4:C3:F0:11:22:33') 'Formato de MAC'
Assert ([MonitorRed.Net]::FormatMac('ff:ff:ff:ff:ff:ff') -eq '') 'La MAC de broadcast se descarta'
Assert ([MonitorRed.Net]::IsRandomMac('DA:A1:19:5C:22:01')) 'Detecta MAC privada (aleatoria)'
Assert (-not [MonitorRed.Net]::IsRandomMac('F8:4D:89:10:20:30')) 'Una MAC de fábrica no es privada'
Assert ([MonitorRed.Net]::PrefixFromMask('255.255.255.0') -eq 24) 'Máscara /24'
$n = New-Object MonitorRed.LocalNetwork
$n.LocalIp = '10.0.37.5'
[MonitorRed.Net]::SetRange($n, 16)
Assert ($n.IsLimited -and $n.HostCount -eq 254 -and [MonitorRed.Net]::FromUInt($n.FirstHost) -eq '10.0.37.1') 'Una red /16 se limita a la /24 del equipo'
[MonitorRed.Net]::SetRange($n, 22)
Assert (-not $n.IsLimited -and $n.HostCount -eq 1022) 'Una red /22 se escanea completa (1022 equipos)'

# NetBIOS: respuesta NBSTAT con el nombre "SALA-PC"
$nb = New-Object byte[] 57
$nb[56] = 1
$entry = [Text.Encoding]::ASCII.GetBytes('SALA-PC'.PadRight(15)) + [byte[]](0, 0x04, 0x00)
Assert ([MonitorRed.NameQuery]::ParseNetBios([byte[]]($nb + $entry)) -eq 'SALA-PC') 'Lee el nombre NetBIOS'

# mDNS: respuesta PTR con compresión de nombres
$q = [MonitorRed.NameQuery]::BuildQuery('23.1.168.192.in-addr.arpa', 12)
$resp = [System.Collections.Generic.List[byte]]::new()
$resp.AddRange([byte[]]$q)
$resp[2] = 0x84; $resp[7] = 1  # respuesta, 1 registro
$resp.AddRange([byte[]](0xC0, 0x0C, 0, 12, 0, 1, 0, 0, 0, 120))
$name = [byte[]](@(13) + [Text.Encoding]::ASCII.GetBytes('iPhone-de-Ana') + @(5) + [Text.Encoding]::ASCII.GetBytes('local') + @(0))
$resp.AddRange([byte[]](0, $name.Length))
$resp.AddRange($name)
$parsed = [MonitorRed.NameQuery]::CleanLocal([MonitorRed.NameQuery]::ReadFirstAnswerName($resp.ToArray(), 12))
Assert ($parsed -eq 'iPhone-de-Ana') "Lee el nombre mDNS ($parsed)"

# UPnP: descripción de un router
$u = New-Object MonitorRed.UpnpInfo
$u.Location = 'http://192.168.1.1:1900/igd.xml'
[MonitorRed.Upnp]::ParseDescription($u, @'
<root><device><deviceType>urn:schemas-upnp-org:device:InternetGatewayDevice:1</deviceType>
<friendlyName>Archer C6</friendlyName><manufacturer>TP-Link</manufacturer><modelName>Archer C6</modelName>
<deviceList><device><serviceList><service><serviceType>urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1</serviceType>
<controlURL>/ctl/CmnIfCfg</controlURL></service></serviceList></device></deviceList></device></root>
'@)
Assert ($u.FriendlyName -eq 'Archer C6' -and $u.WanControlUrl -eq 'http://192.168.1.1:1900/ctl/CmnIfCfg') 'Lee la descripción UPnP y el servicio de tráfico total'
Assert ([MonitorRed.Upnp]::Header("HTTP/1.1 200 OK`r`nLocation: http://x/desc.xml`r`n", 'LOCATION') -eq 'http://x/desc.xml') 'Lee las cabeceras SSDP'

# Fabricantes: conversión del formato de Wireshark
$sample = "# comentario`n00:1B:C5`tIeee`tIEEE Registration Authority`n00:1B:C5:00:10:00/36`tOpenRB`tOpenRB.com, Direct SIA`nF8:4D:89`tApple`tApple, Inc.`n50:C7:BF`tTp-Link`tTp-Link Technologies Co.,Ltd.`n"
[MonitorRed.OuiDatabase]::Load([MonitorRed.OuiDatabase]::ConvertManuf($sample))
Assert ([MonitorRed.OuiDatabase]::Lookup('F8:4D:89:10:20:30') -eq 'Apple') 'Busca el fabricante por MAC'
Assert ([MonitorRed.OuiDatabase]::Lookup('50-c7-bf-00-00-01') -eq 'Tp-Link') 'Limpia el nombre del fabricante'
Assert ([MonitorRed.OuiDatabase]::Lookup('00:1B:C5:00:10:FF') -eq 'OpenRB.com, Direct SIA') 'Usa el bloque más específico (/36)'
$ieee = "Registry,Assignment,Organization Name,Organization Address`nMA-L,F84D89,`"Apple, Inc.`",1 Infinite Loop Cupertino CA US 95014`nMA-L,8C79F5,SAMSUNG ELECTRONICS CO.\,LTD,`"Suwon, KR`"`nMA-M,70B3D51,Shenzhen Example Tech Co. Ltd,CN`n"
[MonitorRed.OuiDatabase]::Load([MonitorRed.OuiDatabase]::ConvertIeeeCsv($ieee.Replace('\,', ',')))
Assert ([MonitorRed.OuiDatabase]::Lookup('F8:4D:89:00:00:01') -eq 'Apple') 'Lee el CSV de la IEEE (comillas incluidas)'
Assert ([MonitorRed.OuiDatabase]::Lookup('8C:79:F5:00:00:01') -eq 'Samsung') "Nombres en mayúsculas quedan legibles: $([MonitorRed.OuiDatabase]::Lookup('8C:79:F5:00:00:01'))"
Assert ([MonitorRed.OuiDatabase]::Lookup('70:B3:D5:1F:00:01') -eq 'Example Tech') "Bloques de 28 bits y sin la ciudad: $([MonitorRed.OuiDatabase]::Lookup('70:B3:D5:1F:00:01'))"

# Proxy ARP / repetidor: la misma MAC en varias IPs
$pn = New-Object MonitorRed.LocalNetwork
$pn.LocalIp = '10.1.0.4'; $pn.Gateway = '10.1.0.1'
[MonitorRed.Net]::SetRange($pn, 24)
$ps = New-Object MonitorRed.ScanSession($pn)
$ps.Report('10.1.0.4', '00:22:48:4A:AF:2A', 0)
$ps.Report('10.1.0.1', '12:34:56:78:9A:BC', -1)
foreach ($i in 5..30) { $ps.Report("10.1.0.$i", '12:34:56:78:9A:BC', -1) }
$ps.Report('10.1.0.40', '12:34:56:78:9A:BC', 12)
Assert ($ps.TakeChanges().Count -eq 0) 'La ventana no recibe equipos antes de revisar las MAC compartidas'
$ps.MarkSharedMacs()
$seen = @($ps.TakeChanges() | Sort-Object IpValue)
Assert ($seen.Count -eq 3 -and ($seen | ForEach-Object { $_.Ip }) -join ',' -eq '10.1.0.1,10.1.0.4,10.1.0.40') "Se quitan las IPs fantasma del proxy ARP: $(($seen | ForEach-Object { $_.Ip }) -join ', ')"
Assert ((Get-MacKey $seen[2]) -eq 'IP:10.1.0.40' -and (Get-MacKey $seen[1]) -eq '00:22:48:4A:AF:2A') 'Con MAC compartida el equipo se recuerda por IP'

if ($Fabricantes) {
    $script:EmbeddedOui = [Convert]::ToBase64String([IO.File]::ReadAllBytes($Fabricantes))
    [MonitorRed.OuiDatabase]::Load('')
    Assert (Import-OuiDatabase) 'Carga la base de fabricantes incrustada'
    Assert ([MonitorRed.OuiDatabase]::Count -gt 30000) "Base completa: $([MonitorRed.OuiDatabase]::Count) bloques"
    Assert ([MonitorRed.OuiDatabase]::Lookup('24:0A:C4:00:00:00') -eq 'Espressif') 'Espressif (enchufes y sensores inteligentes)'
}

# 4. Casa de ejemplo: estimación del tipo de equipo
function New-Record {
    param([string]$Ip, [string]$Mac, [string]$Mdns = '', [string]$NetBios = '', [string]$Dns = '', [int]$Ping = 3,
          [string]$UpnpType = '', [string]$UpnpName = '', [string]$UpnpMaker = '', [string]$UpnpModel = '', [switch]$Gateway, [switch]$Self)
    $r = New-Object MonitorRed.HostRecord
    $r.Ip = $Ip; $r.IpValue = [MonitorRed.Net]::ToUInt($Ip); $r.Mac = $Mac; $r.PingMs = $Ping
    $r.MdnsName = $Mdns; $r.NetBiosName = $NetBios; $r.DnsName = $Dns; $r.NamesDone = $true
    $r.IsGateway = [bool]$Gateway; $r.IsSelf = [bool]$Self
    if ($UpnpType) {
        $u = New-Object MonitorRed.UpnpInfo
        $u.DeviceType = $UpnpType; $u.FriendlyName = $UpnpName; $u.Manufacturer = $UpnpMaker; $u.ModelName = $UpnpModel
        $r.Upnp.Add($u)
    }
    $r
}

$casa = @(
    @{ R = (New-Record 192.168.1.1 50:C7:BF:3A:11:01 -UpnpType 'urn:schemas-upnp-org:device:InternetGatewayDevice:1' -UpnpName 'Archer C6' -UpnpMaker 'TP-Link' -UpnpModel 'Archer C6' -Gateway -Ping 1); Type = 'router' }
    @{ R = (New-Record 192.168.1.10 3C:A9:F4:52:8E:10 -NetBios 'DESKTOP-SALA' -Self -Ping 0); Type = 'computer' }
    @{ R = (New-Record 192.168.1.23 DA:A1:19:5C:22:01 -Mdns 'iPhone-de-Ana' -Ping 18); Type = 'phone' }
    @{ R = (New-Record 192.168.1.31 8C:79:F5:21:44:9A -UpnpType 'urn:schemas-upnp-org:device:MediaRenderer:1' -UpnpName '[TV] Samsung Q60 Series (55)' -UpnpMaker 'Samsung Electronics' -UpnpModel 'QN55Q60B'); Type = 'tv' }
    @{ R = (New-Record 192.168.1.32 54:60:09:0A:7C:33 -Mdns 'Chromecast-Living' -Ping 6); Type = 'tv' }
    @{ R = (New-Record 192.168.1.40 44:65:0D:9B:20:17 -Ping 9); Type = 'speaker' }
    @{ R = (New-Record 192.168.1.44 3C:D9:2B:66:01:5E -NetBios 'HP-OFFICEJET' -Ping 4); Type = 'printer' }
    @{ R = (New-Record 192.168.1.50 00:D9:D1:7E:31:02 -Ping 2); Type = 'console' }
    @{ R = (New-Record 192.168.1.61 24:0A:C4:3F:2A:1B -Dns 'ESP_3F2A1B.lan' -Ping 25); Type = 'smarthome' }
    @{ R = (New-Record 192.168.1.62 B0:4A:39:12:8C:40 -Ping 30); Type = 'appliance' }
    @{ R = (New-Record 192.168.1.70 C0:56:E3:45:A0:11 -Ping 5); Type = 'camera' }
    @{ R = (New-Record 192.168.1.80 64:09:80:B2:33:7D -Dns 'Redmi-Note-12.lan' -Ping 41); Type = 'phone' }
    @{ R = (New-Record 192.168.1.81 70:66:55:0C:19:E2 -NetBios 'LAPTOP-JUAN' -Ping 7); Type = 'laptop' }
    @{ R = (New-Record 192.168.1.90 E2:5B:00:41:7A:C9 -Ping -1); Type = 'phone' }
    @{ R = (New-Record 192.168.1.95 00:11:22:33:44:55 -Ping -1); Type = 'unknown' }
)
foreach ($h in $casa) {
    $f = Get-DeviceFacts $h.R $false
    Assert ($f.Guess.Type -eq $h.Type) "$($h.R.Ip) «$($f.AutoName)» es $($h.Type) ($($f.Guess.Reason))"
}
Assert ((Get-DeviceFacts $casa[2].R $false).AutoName -eq 'iPhone-de-Ana') 'El nombre automático usa el nombre mDNS'
Assert ((Get-DeviceFacts $casa[3].R $false).AutoName -eq '[TV] Samsung Q60 Series (55)') 'El nombre automático usa el nombre UPnP'
Assert ((Get-DeviceFacts $casa[1].R $true).Guess.Type -eq 'laptop') 'Este equipo es laptop si tiene batería'

# 5. Modos de medición
$fakeSession = [pscustomobject]@{ IsCompleted = $true; InternetGateways = @($u) }
$ctx = @{ Network = $null; Session = $fakeSession; Settings = (Get-DefaultSettings); Devices = @(); IsAdmin = $false }
$state = Get-MeasurementState $ctx
Assert ($state.Results.Count -eq $modeCount) "Hay $modeCount modos de medición"
Assert ($state.Active -and $state.Active.Mode.Id -eq 'Upnp') 'Automático elige UPnP si es el único disponible'
$ctx.Session = [pscustomobject]@{ IsCompleted = $true; InternetGateways = @() }
Assert (-not (Get-MeasurementState $ctx).Active) 'Sin UPnP ni otros modos, no hay modo activo'
if (-not $EdicionStore) {
    $ctx.Settings.InterceptConsent = $true
    $r = ((Get-MeasurementState $ctx).Results | Where-Object { $_.Mode.Id -eq 'Intercept' })
    Assert (-not $r.Available -and $r.Reason -match 'administrador' -and $r.Reason -match 'Npcap') "Interceptar avisa de Npcap y administrador: $($r.Reason)"
}
$ctx.Settings.MeasurementMode = 'RouterApi'
$ctx.Session = $fakeSession
$st = Get-MeasurementState $ctx
Assert (-not $st.Active -and (Get-MeasurementSummary $st) -match 'no está disponible') 'Un modo elegido a mano que no está disponible se informa'
# Medición: formato y cálculo de velocidad
Assert ((Format-Rate 0) -eq '0 B/s') 'Formato de velocidad: 0 B/s'
Assert ((Format-Rate 2048) -eq '2 KB/s') "Formato de velocidad: KB/s ($([MonitorRed.Net]::IsWindows))"
Assert ((Format-Rate (5 * 1024 * 1024)) -eq '5,0 MB/s' -or (Format-Rate (5 * 1024 * 1024)) -eq '5.0 MB/s') "Formato de velocidad: MB/s ($(Format-Rate (5*1024*1024)))"
Assert ((Format-Rate -1) -eq '—') 'Velocidad desconocida: raya'
Assert ((Format-Bytes (3 * 1024 * 1024 * 1024)) -match '^3[.,]0 GB$') "Formato de total: GB ($(Format-Bytes (3*1024*1024*1024)))"
Assert ([int](Get-RateBps 1000 3000 2.0) -eq 1000) 'Velocidad = (3000-1000)/2s = 1000 B/s'
Assert ((Get-RateBps 3000 1000 2.0) -eq -1) 'Contador que retrocede (reinicio): se vuelve a tomar la referencia'

# El modo UPnP ahora sí está implementado
$upnpMode = $script:MeasurementModes | Where-Object { $_.Id -eq 'Upnp' }
Assert ($upnpMode.Implemented) 'El modo Total por UPnP está implementado'

$enc = Protect-Text 'clave123'
if ($enWindows) { Assert ($enc -and $enc -ne 'clave123' -and (Unprotect-Text $enc) -eq 'clave123') 'La clave del router se guarda cifrada' }

# 6. Escaneo real
if ($EscaneoReal) {
    $net = [MonitorRed.Net]::GetLocalNetworks() | Select-Object -First 1
    Assert ($null -ne $net) "Red detectada: $($net.Summary) (equipo $($net.LocalIp), router $($net.Gateway))"
    $session = New-Object MonitorRed.ScanSession($net)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $session.Start()
    while (-not $session.IsCompleted -and $sw.Elapsed.TotalSeconds -lt 120) { Start-Sleep -Milliseconds 250 }
    Assert $session.IsCompleted "El escaneo terminó en $([int]$sw.Elapsed.TotalSeconds) s"
    Assert (-not $session.Error) "Sin errores en el escaneo $($session.Error)"
    $all = $session.GetAll()
    Assert ($all.Count -ge 1) "Equipos encontrados: $($all.Count)"
    $all | ForEach-Object { ConvertTo-DeviceRow $_ $false } | Sort-Object IpValue | Format-Table Nombre, Tipo, IP, MAC, Fabricante, Host, Ping -AutoSize | Out-String -Width 200 | Write-Host
}

if (-not $enWindows) {
    Write-Host 'Prueba de lógica terminada correctamente (la ventana solo se prueba en Windows).' -ForegroundColor Green
    return
}

# 7. Ventana real con la casa de ejemplo
function Save-Shot([string]$Name) {
    for ($i = 0; $i -lt 15; $i++) { Update-UI; Start-Sleep -Milliseconds 40 }
    $el = $window.Content
    $el.UpdateLayout()
    $w = [int]$el.ActualWidth; $h = [int]$el.ActualHeight
    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($el)
    foreach ($fmt in @(@{ Ext = 'png'; Enc = (New-Object System.Windows.Media.Imaging.PngBitmapEncoder) },
                       @{ Ext = 'jpg'; Enc = (New-Object System.Windows.Media.Imaging.JpegBitmapEncoder -Property @{ QualityLevel = 80 }) })) {
        $fmt.Enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
        $fs = [IO.File]::Create((Join-Path $out "$Name.$($fmt.Ext)"))
        try { $fmt.Enc.Save($fs) } finally { $fs.Close() }
    }
    Write-Host "Captura guardada: $Name ($w x $h)"
}

function Invoke-Click($Button) {
    $Button.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
    Update-UI
}

# Un equipo visto otro día (aparece con "Mostrar desconectados")
New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null
$old = (Get-Date).AddDays(-3).ToUniversalTime().ToString('o')
@{ 'F8:4D:89:10:20:30' = @{ Name = 'Tablet de Sofía'; Type = 'tablet'; AutoName = 'iPad'; AutoType = 'tablet'; Vendor = 'Apple'; LastIp = '192.168.1.27'; FirstSeen = $old; LastSeen = $old } } |
    ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:DevicesFile -Encoding UTF8

$script:AutoScan = $false
$window = New-MainWindow
Assert ($window -is [System.Windows.Window]) 'New-MainWindow devuelve una única ventana WPF'
$g = $script:Gui
foreach ($c in 'PageDevices', 'PageSettings', 'DeviceGrid', 'DetailPanel', 'TxtName', 'CbType', 'ModeList', 'RbAuto', 'BtnScan', 'TxtMeasure') {
    Assert ($null -ne $g[$c]) "Existe el control $c"
}
Assert ($g.Devices.Count -eq 1 -and -not $g.Devices[0].IsOnline) 'Los equipos vistos antes se cargan como desconectados'

$window.WindowStartupLocation = 'Manual'
# 1400 x 860: las capturas sirven para la Microsoft Store (mínimo 1366 x 768)
$window.Left = 0; $window.Top = 0; $window.Width = 1400; $window.Height = 860
$window.ShowActivated = $false
$window.Show()
Update-UI

# Simula un escaneo con la casa de ejemplo
$net = New-Object MonitorRed.LocalNetwork
$net.InterfaceName = 'Wi-Fi'; $net.LocalIp = '192.168.1.10'; $net.Gateway = '192.168.1.1'
[MonitorRed.Net]::SetRange($net, 24)
$g.Networks = @($net)
$g.CbNetwork.Visibility = 'Collapsed'
$g.Session = [pscustomobject]@{ IsCompleted = $true; InternetGateways = @($u); Error = '' }
$g.SeenKeys = @{}; $g.ByIp = @{}; $g.ScanStarted = (Get-Date).AddSeconds(-14); $g.HadHistory = $true
$g.TxtSubtitle.Text = "Red $($net.Summary)  ·  Este equipo: $($net.LocalIp)  ·  Router: $($net.Gateway)"
foreach ($h in $casa) { Update-DeviceFromRecord $h.R }
$g.Timer = New-Object System.Windows.Threading.DispatcherTimer
$g.Session | Add-Member -MemberType ScriptMethod -Name TakeChanges -Value { @() }
Complete-NetworkScan
Assert ($g.Devices.Count -eq $casa.Count + 1) "La lista tiene los $($casa.Count) equipos del escaneo y el desconectado"
Assert ($g.TxtOnline.Text -eq [string]$casa.Count) "Contador de equipos en línea: $($g.TxtOnline.Text)"
$visible = @($g.View).Count
Assert ($visible -eq $casa.Count) 'Los desconectados quedan ocultos por defecto'
Assert ($g.TxtMeasure.Text -match 'UPnP') "Resumen de medición: $($g.TxtMeasure.Text)"

# Medición: el modo UPnP activo arranca un hilo que consulta el total al router
Assert ($null -ne $g.UpnpPS) 'Con UPnP activo se arranca la consulta del total de la casa'
Assert ($null -ne (@($g.Devices | Where-Object { $_.IsSelf })[0])) 'La casa de ejemplo incluye este equipo'
# Se detiene el hilo real (apunta a un router de ejemplo) y se simula su lectura, para probar sin router
Stop-UpnpPoll
Assert ($null -eq $g.UpnpPS) 'La consulta del total se puede detener sin congelar la ventana'
$g.UpnpSync = @{ Stop = $false; Down = 10000000.0; Up = 2000000.0; Time = 1000.0 }
$g.PrevTotal = $null
Update-Measurement
$g.UpnpSync.Down = 10000000.0 + 1024 * 1024; $g.UpnpSync.Up = 2000000.0 + 512 * 1024; $g.UpnpSync.Time = 3000.0
Update-Measurement
Assert ($g.TotalRatePanel.Visibility -eq 'Visible' -and $g.TxtTotalDown.Text -ne '—') "Total de la casa en vivo: bajada $($g.TxtTotalDown.Text), subida $($g.TxtTotalUp.Text)"
Reset-Measurement
Assert ($g.TotalRatePanel.Visibility -eq 'Collapsed') 'Al reescanear se reinicia la medición'

$tv = $g.ByKey['8C:79:F5:21:44:9A']
$g.DeviceGrid.SelectedItem = $tv
Update-UI
Assert ($g.DetailPanel.Visibility -eq 'Visible' -and $g.TxtName.Text -eq $tv.DisplayName) 'Al elegir un equipo se muestra su detalle'
Save-Shot '1-equipos'

# Ponerle nombre a la TV
$g.TxtName.Text = 'TV del living'
Invoke-Click $g.BtnSaveDevice
Assert ($tv.DisplayName -eq 'TV del living') 'Guardar cambia el nombre en la lista'
$saved = Read-JsonFile $script:DevicesFile
Assert ($saved['8C:79:F5:21:44:9A'].Name -eq 'TV del living') 'El nombre queda guardado para la próxima vez'

# Elegir el tipo a mano para el equipo desconocido
$unknown = $g.ByKey['00:11:22:33:44:55']
$g.DeviceGrid.SelectedItem = $unknown
Update-UI
$g.TxtName.Text = 'Decodificador de cable'
$g.CbType.SelectedIndex = 1 + [array]::IndexOf(@($script:DeviceTypes | ForEach-Object { $_.Key }), 'tv')
Invoke-Click $g.BtnSaveDevice
Assert ($unknown.TypeKey -eq 'tv' -and $unknown.IsCustomType) 'Se puede elegir el tipo a mano'

$g.TxtSearch.Text = 'samsung'
Update-UI
Assert (@($g.View).Count -eq 1) 'La búsqueda filtra la lista'
$g.TxtSearch.Text = ''
$g.ChkOffline.IsChecked = $true
Update-UI
Assert (@($g.View).Count -eq $casa.Count + 1) '«Mostrar desconectados» muestra la tablet que no está conectada'
$g.CbTypeFilter.SelectedIndex = 1 + [array]::IndexOf(@($script:DeviceTypes | ForEach-Object { $_.Key }), 'phone')
Update-UI
Assert (@($g.View).Count -eq 3) 'El filtro por tipo muestra solo los teléfonos'
$g.CbTypeFilter.SelectedIndex = 0
$g.ChkOffline.IsChecked = $false
$g.DeviceGrid.SelectedItem = $g.ByKey['DA:A1:19:5C:22:01']
Update-UI
Save-Shot '2-detalle'

$csv = Join-Path $script:DataDir 'equipos.csv'
Export-DeviceCsv $csv
$rows = @(Import-Csv -LiteralPath $csv -Delimiter ([Globalization.CultureInfo]::CurrentCulture.TextInfo.ListSeparator))
Assert ($rows.Count -eq @($g.View).Count -and ($rows | Where-Object { $_.Nombre -eq 'TV del living' })) "Exportar a Excel guarda la lista visible ($($rows.Count) filas)"

Invoke-Click $g.BtnResetDevice
Assert ($g.ByKey['DA:A1:19:5C:22:01'].DisplayName -eq 'iPhone-de-Ana') 'Restablecer vuelve al nombre automático'

# Ajustes
Invoke-Click $g.BtnSettings
Assert ($g.PageSettings.Visibility -eq 'Visible') 'Se abre la página de Ajustes'
Assert ($g.RbAuto.IsChecked) 'Automático viene elegido'
$upnpItem = $g.ModeItems | Where-Object { $_.Id -eq 'Upnp' }
Assert ($upnpItem.Available -and $upnpItem.IsActive) 'UPnP aparece disponible y en uso'
Assert ($g.ModeItems.Count -eq $modeCount) "Ajustes muestra $modeCount modos"
if ($EdicionStore) {
    Assert ($g.InterceptSection.Visibility -eq 'Collapsed' -and $g.TxtAutoDesc.Text -notmatch 'intercept') 'La edición Store no muestra el modo de interceptar tráfico'
}
Save-Shot '3-ajustes'
$upnpItem.IsSelected = $true
Update-UI
Assert ($script:Settings.MeasurementMode -eq 'Upnp') 'Elegir un modo lo guarda en los ajustes'
$g.RbAuto.IsChecked = $true
Update-UI
Assert ($script:Settings.MeasurementMode -eq 'Auto') 'Volver a Automático'
$g.CbRouterBrand.SelectedIndex = 1
$g.PwdRouter.Password = 'clave123'
Invoke-Click $g.BtnSaveRouter
$s = Read-JsonFile $script:SettingsFile
Assert ($s.RouterBrand -eq 'TP-Link' -and $s.RouterPassword -and $s.RouterPassword -ne 'clave123') 'Los datos del router se guardan con la clave cifrada'
$router = $g.ModeItems | Where-Object { $_.Id -eq 'RouterApi' }
Assert ($router.Reason -match 'TP-Link') "Estado del modo router: $($router.Reason)"
Invoke-Click $g.BtnBack
Assert ($g.PageDevices.Visibility -eq 'Visible') 'El botón «Volver» regresa a la lista'

$window.Close()
Remove-Item -LiteralPath $script:DataDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'Prueba del Monitor de Red terminada correctamente.' -ForegroundColor Green
