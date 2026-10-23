<#
    Prueba automática en Windows: carga la ventana real de la app (sin mostrarla al usuario),
    llena las pantallas con datos de ejemplo, prueba algunos botones y guarda capturas en .\capturas
#>
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$appPath = Join-Path $root 'RespaldoDrivers\RespaldoDrivers.ps1'
$out = Join-Path $root 'capturas'
New-Item -ItemType Directory -Path $out -Force | Out-Null

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

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FALLÓ: $Message" }
    Write-Host "OK: $Message"
}

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

function New-FakeDriver($Order, $Category, $Provider, $Inf, $Version, $Date, $Device) {
    [pscustomobject]@{
        Category = $Category; CategoryOrder = $Order; Provider = $Provider; InfName = $Inf; Version = $Version
        Date = $Date; Devices = [string[]]@($Device | Where-Object { $_ }); FullPath = 'C:\Ejemplo'; Recurse = $true
    }
}

$drivers = @(
    New-FakeDriver 1  'Chipset y Sistema' 'Intel' 'heci.inf' '2306.4.3.0' '2023-05-02' 'Intel(R) Management Engine Interface'
    New-FakeDriver 1  'Chipset y Sistema' 'Intel' 'iaLPSS2_I2C.inf' '30.100.2237.25' '2022-09-10' 'Intel(R) Serial IO I2C Host Controller'
    New-FakeDriver 2  'Almacenamiento (SATA-NVMe)' 'Intel' 'iaStorVD.inf' '19.5.1.1040' '2023-02-14' 'Intel RST VMD Controller'
    New-FakeDriver 3  'USB y Thunderbolt' 'Intel' 'TbtHostController.inf' '1.41.1342.0' '2023-01-12' 'Thunderbolt(TM) Controller'
    New-FakeDriver 4  'Video y Graficos' 'Intel Corporation' 'iigd_dch.inf' '31.0.101.4502' '2023-06-14' 'Intel(R) UHD Graphics'
    New-FakeDriver 4  'Video y Graficos' 'NVIDIA' 'nv_dispig.inf' '32.0.15.5612' '2024-07-05' 'NVIDIA GeForce MX450'
    New-FakeDriver 4  'Video y Graficos' 'Intel Corporation' 'igcc_dch.inf' '1.100.4502.0' '2023-06-14' $null
    New-FakeDriver 5  'Audio' 'Realtek Semiconductor Corp.' 'HDXHPAI3.inf' '6.0.9549.1' '2023-08-01' 'Realtek(R) Audio'
    New-FakeDriver 6  'Red (Ethernet y WiFi)' 'Intel' 'Netwtw10.inf' '22.250.1.2' '2023-09-20' 'Intel(R) Wi-Fi 6 AX201 160MHz'
    New-FakeDriver 6  'Red (Ethernet y WiFi)' 'Realtek' 'rt640x64.inf' '10.68.815.2023' '2023-08-15' 'Realtek PCIe GbE Family Controller'
    New-FakeDriver 7  'Bluetooth' 'Intel Corporation' 'ibtusb.inf' '22.250.0.2' '2023-09-20' 'Intel(R) Wireless Bluetooth(R)'
    New-FakeDriver 8  'Teclado, Mouse y Touchpad' 'Synaptics' 'SynHidMini.inf' '19.5.35.1' '2022-11-03' 'Synaptics HID Touchpad'
    New-FakeDriver 9  'Camaras y Escaneres' 'Realtek' 'RtCamU64.inf' '10.0.22000.20304' '2023-03-03' 'HP HD Camera'
    New-FakeDriver 11 'Biometricos y Seguridad' 'Synaptics' 'synaWudfBioUsb.inf' '6.0.48.1123' '2023-04-11' 'Synaptics FP Sensors'
    New-FakeDriver 17 'Firmware y BIOS' 'HP' 'HPFirmware.inf' '1.15.0.0' '2024-02-01' 'System Firmware'
    New-FakeDriver 19 'Extensiones de Drivers' 'HP' 'HpAudioExt.inf' '1.0.12.0' '2023-08-01' $null
)

# 3. Crear la ventana real
$window = New-MainWindow
Assert ($window -is [System.Windows.Window]) 'New-MainWindow devuelve una única ventana WPF'
$g = $script:Gui
foreach ($n in 'PageHome', 'PageBackup', 'PageRestore', 'Overlay', 'BkCategories', 'BkGrid', 'RsCategories', 'RsGrid', 'Log', 'Progress', 'BtnBkStart', 'BtnRsStart') {
    Assert ($null -ne $g[$n]) "Existe el control $n"
}

$window.WindowStartupLocation = 'Manual'
$window.Left = 0; $window.Top = 0; $window.Width = 1100; $window.Height = 740
$window.ShowActivated = $false
$window.Content.Background = New-Brush '#F3F3F3'
$window.Show()
Update-UI
Assert ($g.PcModel.Text.Length -gt 0) 'Se muestran los datos del equipo'
Assert ($g.BkDest.Text.Length -gt 0) "Se propone una carpeta de destino: $($g.BkDest.Text)"

# Inicio
$g.HomeBannerText.Text = 'Se encontró un respaldo junto a la aplicación: HP ProBook 450 G8  ·  creado 2026-10-23  ·  16 drivers.'
$g.HomeBanner.Visibility = 'Visible'
Save-Shot '1-inicio'

# Respaldar
$set = New-DriverSet $drivers
$g.BkSet = $set
$g.PageBackup.DataContext = $set
$g.BkSummary.Text = "Se encontraron $($set.TotalCount) drivers en $($set.Categories.Count) categorías. Desmarca los que no quieras guardar."
Show-Page 'PageBackup'
$video = $set.Categories | Where-Object { $_.Name -eq 'Video y Graficos' }
$g.BkCategories.SelectedItem = $video
$video.Drivers[2].IsChecked = $false
Assert ($set.CheckedCount -eq $set.TotalCount - 1) 'Desmarcar un driver actualiza el total'
Assert ($null -eq $video.IsChecked) 'La categoría queda en estado parcial'
Save-Shot '2-respaldar'
Invoke-Click $g.BtnBkNone
Assert ($set.CheckedCount -eq 0) 'Botón "Desmarcar todo" funciona'
Invoke-Click $g.BtnBkAll
Assert ($set.CheckedCount -eq $set.TotalCount) 'Botón "Marcar todo" funciona'

# Restaurar sin respaldo
Show-Page 'PageRestore'
Save-Shot '3-restaurar-vacio'

# Restaurar con respaldo
$rs = New-DriverSet $drivers @($script:FirmwareCategory)
$g.RsSet = $rs
$g.PageRestore.DataContext = $rs
$g.RsEmpty.Visibility = 'Collapsed'
$g.RsContent.Visibility = 'Visible'
$g.RsTitle.Text = 'Respaldo de HP ProBook 450 G8'
$g.RsDetails.Text = "Creado 2026-10-23  ·  $($rs.TotalCount) drivers en $($rs.Categories.Count) categorías  ·  E:\Drivers_HP_ProBook 450 G8_2026-10-23"
$g.RsWarnText.Text = "La categoría «$($script:FirmwareCategory)» quedó desmarcada por seguridad: actualiza el BIOS al reiniciar."
$g.RsWarn.Visibility = 'Visible'
Assert ($rs.CheckedCount -eq $rs.TotalCount - 1) 'Firmware queda desmarcado al restaurar'
$g.RsCategories.SelectedItem = ($rs.Categories | Where-Object { $_.Name -eq 'Video y Graficos' })
$vd = @($drivers | Where-Object { $_.Category -eq 'Video y Graficos' })
Set-DriverStatus $vd[0] 'Ok' 'Instalado'
Set-DriverStatus $vd[1] 'Ok' 'Instalado *'
Set-DriverStatus $vd[2] 'Info' 'Sin cambios'
Save-Shot '4-restaurar'

# Progreso y resultado
Show-Overlay 'Instalando drivers...'
Write-Log 'Instalado: Video y Graficos \ Intel Corporation - iigd_dch - 31.0.101.4502' Ok
Set-Progress 9 15 'Instalando 10 de 15: Red (Ethernet y WiFi) \ Intel - Netwtw10 - 22.250.1.2'
Save-Shot '5-progreso'
Show-OverlayResult -Kind Ok -Title 'Instalación terminada' -PrimaryText 'Reiniciar ahora' -CloseText 'Más tarde' `
    -Text "Instalados:   12`nSin cambios:  3`nCon error:    0`n`nDispositivos sin driver: antes 12, ahora 0.`n`nReinicia el equipo para terminar la instalación."
Save-Shot '6-resultado'
Invoke-Click $g.OvClose
Assert ($g.Overlay.Visibility -eq 'Collapsed') 'El botón "Más tarde" cierra la ventana de resultado'

Invoke-Click $g.BtnBack
Assert ($g.PageHome.Visibility -eq 'Visible') 'El botón "Volver" regresa al inicio'

$window.Close()
Write-Host 'Prueba de interfaz terminada correctamente.' -ForegroundColor Green
