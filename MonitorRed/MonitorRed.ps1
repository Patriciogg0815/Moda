#Requires -Version 5.1
<#
.SYNOPSIS
    Monitor de Red: muestra todos los equipos conectados a la red de la casa (PCs, teléfonos,
    TVs, consolas, electrodomésticos...) con su IP, MAC, nombre, fabricante y tipo.

.DESCRIPTION
    Este archivo es el código fuente de MonitorRed.exe (GitHub Actions lo compila con ps2exe).
    Para probarlo sin compilar: clic derecho en el archivo → "Ejecutar con PowerShell".

    Al abrirse escanea la red sola: no hay que configurar el router ni instalar nada.

    Modo línea de comandos (sin ventana):
        .\MonitorRed.ps1 -Escanear
            Escanea la red y muestra la tabla de equipos.
        .\MonitorRed.ps1 -Escanear -Json
            Igual, pero en formato JSON.
        .\MonitorRed.ps1 -GenerarFabricantes .\fabricantes.gz [-Desde .\oui.csv]
            Genera la base de fabricantes por MAC (la usa Crear-EXE.ps1). Sin -Desde la descarga.

.NOTES
    Requiere Windows 10 u 11. No necesita permisos de administrador.
#>
[CmdletBinding()]
param(
    [switch]$Escanear,
    [switch]$Json,
    [string]$GenerarFabricantes,
    [string]$Desde
)

$ErrorActionPreference = 'Stop'

$script:AppName    = 'Monitor de Red'
$script:AppVersion = '1.0.0'
$script:Gui        = $null
$script:AutoScan   = $true   # la prueba automática lo apaga para llenar la ventana con datos de ejemplo

# Base de fabricantes por MAC (registro público de la IEEE). Crear-EXE.ps1 la incrusta aquí al compilar;
# si está vacía se busca junto al script o se descarga una vez. Si la IEEE rechaza la descarga se usa
# la copia de esos mismos datos que publica Wireshark.
$script:EmbeddedOui = ''
$script:OuiIeeeUrls = @(
    'https://standards-oui.ieee.org/oui/oui.csv'
    'https://standards-oui.ieee.org/oui28/mam.csv'
    'https://standards-oui.ieee.org/oui36/oui36.csv'
)
$script:OuiFallbackUrl = 'https://www.wireshark.org/download/automated/data/manuf'
$script:OuiFileName = 'fabricantes.gz'

# Edición para la Microsoft Store: sin el modo de interceptar tráfico (Crear-EXE.ps1 -EdicionStore la activa)
$script:StoreEdition = $false

# Página de Ko-fi para el botón "Apoyar a la app" (si dice PENDIENTE, el botón no se muestra)
$script:SupportUrl = 'https://ko-fi.com/garridoitsolutions'

# Publicidad: página con un banner de Adsterra de 728x90 (archivo MonitorRed/web/app-banner.html), publicada en
# el sitio aprobado en Adsterra. Si dice PENDIENTE, o la página no carga, la franja de publicidad no se muestra.
$script:AdPageUrl = 'https://convertir-ec.netlify.app/app-banner.html'
# Cada cuánto se vuelve a intentar si la página no cargó (por ejemplo, sin internet al abrir la app)
$script:AdRetryMinutes = 5

# WebView2 (navegador Edge incrustado) para mostrar el banner. Crear-EXE.ps1 incrusta aquí sus DLL en un .zip;
# si está vacío se buscan en la carpeta "webview2" junto al script. Sin ellas la app funciona igual, sin publicidad.
$script:WebView2Version = '1.0.3912.50'
$script:EmbeddedWebView2 = ''
$script:WebView2Ready = $null

# Ruta del script (o del .exe si se compiló con ps2exe)
$script:ScriptPath = if ($PSCommandPath) { $PSCommandPath } else { [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName }
$script:ScriptDir  = Split-Path -Parent $script:ScriptPath

# Nombre con el que aparece este equipo en la lista (las pruebas ponen uno de ejemplo para las capturas)
$script:SelfName = [Environment]::MachineName

# Datos del usuario: nombres puestos a mano, equipos vistos y ajustes
$script:DataDir      = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'MonitorRed'
$script:DevicesFile  = Join-Path $script:DataDir 'dispositivos.json'
$script:SettingsFile = Join-Path $script:DataDir 'ajustes.json'

#region Tipos de dispositivo

# Key: se guarda en dispositivos.json. Glyph: ícono de Segoe MDL2 Assets.
$script:DeviceTypes = @(
    @{ Key = 'router';    Label = 'Router';                Glyph = 0xE968 }
    @{ Key = 'computer';  Label = 'Computadora';           Glyph = 0xE977 }
    @{ Key = 'laptop';    Label = 'Laptop';                Glyph = 0xE7F8 }
    @{ Key = 'phone';     Label = 'Teléfono';              Glyph = 0xE8EA }
    @{ Key = 'tablet';    Label = 'Tablet';                Glyph = 0xE70A }
    @{ Key = 'tv';        Label = 'TV / Streaming';        Glyph = 0xE7F4 }
    @{ Key = 'console';   Label = 'Consola de juegos';     Glyph = 0xE7FC }
    @{ Key = 'speaker';   Label = 'Parlante / Asistente';  Glyph = 0xE7F5 }
    @{ Key = 'printer';   Label = 'Impresora';             Glyph = 0xE749 }
    @{ Key = 'camera';    Label = 'Cámara';                Glyph = 0xE722 }
    @{ Key = 'smarthome'; Label = 'Hogar inteligente';     Glyph = 0xE80F }
    @{ Key = 'appliance'; Label = 'Electrodoméstico';      Glyph = 0xE7E8 }
    @{ Key = 'nas';       Label = 'Almacenamiento (NAS)';  Glyph = 0xEDA2 }
    @{ Key = 'network';   Label = 'Equipo de red';         Glyph = 0xE701 }
    @{ Key = 'unknown';   Label = 'Desconocido';           Glyph = 0xE9CE }
)

# Pistas en el nombre del equipo (host, mDNS, NetBIOS, UPnP). Se prueban en este orden.
$script:NameRules = @(
    @{ Type = 'console';   Pattern = 'xbox|playstation|\bps[345]\b|ps[345]-|nintendo|steam-?deck' }
    @{ Type = 'tv';        Pattern = '\btv\b|-tv|tv-|smart-?tv|bravia|roku|chromecast|fire-?tv|firestick|apple-?tv|webos|tizen|android-?tv|google-?tv|shield|vizio|hisense|vidaa|mi-?box|tivo|kodi|\[tv\]' }
    @{ Type = 'speaker';   Pattern = 'sonos|\becho\b|echo-|alexa|google-?home|nest-?(mini|audio|hub)|homepod|bose|\bjbl\b|denon|marantz|soundbar' }
    @{ Type = 'printer';   Pattern = 'printer|impresora|officejet|deskjet|laserjet|pagewide|epson|\bet-\d|brother|\bmfc-|\bdcp-|\bhl-|canon|pixma|xerox|lexmark|kyocera|ricoh' }
    @{ Type = 'camera';    Pattern = 'camera|camara|\bcam\b|-cam|cam-|ipcam|\bipc\b|hikvision|dahua|wyze|ezviz|reolink|imou|arlo|\bring-|blink|doorbell|timbre|tapo-?c\d' }
    @{ Type = 'nas';       Pattern = 'synology|diskstation|qnap|my-?cloud|truenas|freenas|unraid|\bnas\b|-nas' }
    @{ Type = 'appliance'; Pattern = 'roomba|irobot|roborock|deebot|ecovacs|dyson|vacuum|aspiradora|washer|lavadora|dryer|secadora|fridge|refrigerador|nevera|heladera|\boven\b|horno|dishwasher|lavavajillas|aircon|\bac-|midea|haier|whirlpool|thinq|miele|electrolux|frigidaire' }
    @{ Type = 'tablet';    Pattern = 'ipad|galaxy-?tab|\btab\b|tab-|tablet|kindle|fire-?hd|mediapad|matepad' }
    @{ Type = 'laptop';    Pattern = 'laptop|notebook|macbook|thinkpad|ideapad|vivobook|zenbook|inspiron|latitude|pavilion|elitebook|probook|surface|galaxy-?book|chromebook' }
    @{ Type = 'phone';     Pattern = 'iphone|android|galaxy|\bsm-[a-z]\d|pixel|redmi|xiaomi|\bpoco|motorola|\bmoto|huawei|honor|oneplus|oppo|\bvivo\b|realme|nokia|phone|celular|telefono' }
    @{ Type = 'computer';  Pattern = 'desktop|\bpc\b|-pc|pc-|imac|mac-?mini|mac-?pro|workstation|raspberry|\bwin-|windows|ubuntu|debian|fedora|server|servidor' }
    @{ Type = 'smarthome'; Pattern = 'esp[_-]|esp32|esp8266|tasmota|shelly|sonoff|tuya|smartlife|smart-?plug|enchufe|\bkasa|\bhs1\d\d|\bkp\d{3}|tapo-?p\d|philips-?hue|\bhue\b|\bwiz\b|yeelight|meross|govee|broadlink|lifx|nanoleaf|ecobee|thermostat|termostato|netatmo|\bnest\b|switchbot|aqara|zigbee' }
    @{ Type = 'network';   Pattern = 'repeater|repetidor|extender|\bap-|access-?point|\bmesh\b|\bdeco\b|eero|orbi|velop|unifi|mikrotik|powerline|tl-wa|\bre\d{3}\b' }
)

# Pistas en el fabricante de la tarjeta de red (por la MAC). Se usan si el nombre no dice nada.
$script:VendorRules = @(
    @{ Type = 'console';   Pattern = 'nintendo|sony interactive' }
    @{ Type = 'camera';    Pattern = 'hikvision|dahua|wyze|ezviz|reolink|\bring\b|arlo|axis communications|imou|hanwha|uniview' }
    @{ Type = 'printer';   Pattern = 'hewlett|\bhp inc|epson|canon|brother|xerox|lexmark|kyocera|ricoh|konica|zebra' }
    @{ Type = 'nas';       Pattern = 'synology|qnap|western digital|buffalo|asustor' }
    @{ Type = 'speaker';   Pattern = 'sonos|bose|harman|denon|sound united|bang & olufsen|amazon' }
    @{ Type = 'tv';        Pattern = 'roku|vizio|hisense|\btcl\b|tp vision|funai|skyworth|sharp|vestel|tivo|nvidia|lg electronics|\bsony\b|google' }
    @{ Type = 'appliance'; Pattern = 'irobot|roborock|ecovacs|dyson|midea|haier|whirlpool|bsh hausger|miele|electrolux|lg innotek|daikin|\bgree\b' }
    @{ Type = 'smarthome'; Pattern = 'espressif|tuya|shelly|allterco|itead|signify|philips lighting|lifx|nanoleaf|ecobee|netatmo|nest labs|switchbot|wonder labs|lumi united|broadlink|meross|govee|wiz connected|leedarson|beken|bouffalo|silicon lab' }
    @{ Type = 'phone';     Pattern = 'apple|samsung|xiaomi|huawei|honor|oneplus|oppo|\bvivo\b|realme|motorola|zte|nokia|hmd global|meizu|tecno|transsion|infinix|\bhtc\b' }
    @{ Type = 'network';   Pattern = 'tp-?link|netgear|d-link|ubiquiti|zyxel|tenda|mercusys|eero|linksys|belkin|cisco|mikrotik|routerboard|arcadyan|sagemcom|technicolor|askey|fiberhome|actiontec|arris|commscope|hitron|aruba|ruckus|cudy|wavlink|totolink|edimax' }
    @{ Type = 'computer';  Pattern = 'intel|dell|lenovo|asustek|micro-star|giga-?byte|acer|lite-?on|azurewave|hon hai|foxconn|quanta|compal|wistron|pegatron|raspberry|microsoft|super micro|asrock|realtek|qualcomm|mediatek|broadcom|clevo|framework' }
)

function Get-DeviceType([string]$Key) {
    foreach ($t in $script:DeviceTypes) { if ($t.Key -eq $Key) { return $t } }
    $script:DeviceTypes[-1]
}

function Get-TypeGlyph([string]$Key) { [string][char](Get-DeviceType $Key).Glyph }

#endregion

#region Identificación de cada equipo

function Get-ShortHostName([string]$Name) {
    if (-not $Name) { return '' }
    $n = $Name.Trim().TrimEnd('.')
    if ($n -match '^\d+(\.\d+){3}$') { return '' }
    $first = $n.Split('.')[0]
    if ($first) { $first } else { $n }
}

# El mejor nombre de host que se averiguó: mDNS (Apple, Android, Chromecast), NetBIOS (Windows) o DNS del router
function Get-BestHostName($Record) {
    foreach ($n in @($Record.MdnsName, $Record.NetBiosName, (Get-ShortHostName $Record.DnsName))) {
        if ($n -and $n.Trim()) { return $n.Trim() }
    }
    ''
}

function Get-UpnpSummary($Record) {
    $root = $null
    foreach ($u in $Record.Upnp) {
        if (-not $u.FriendlyName -and -not $u.ModelName) { continue }
        if (-not $root) { $root = $u }
        # Preferir el dispositivo raíz más descriptivo (TV antes que su servicio DIAL, etc.)
        if ($u.DeviceType -match 'MediaRenderer|InternetGatewayDevice|Printer|ZonePlayer' -and $root.DeviceType -notmatch 'MediaRenderer|InternetGatewayDevice|Printer|ZonePlayer') { $root = $u }
    }
    $root
}

# Estima el tipo de equipo con lo que se sabe. Devuelve @{ Type; Reason }.
function Get-DeviceGuess {
    param($Record, [string]$Vendor, [bool]$IsRandomMac, [bool]$IsLaptopSelf)

    if ($Record.IsGateway) { return @{ Type = 'router'; Reason = 'Es la puerta de enlace de la red (el router).' } }
    if ($Record.IsSelf) {
        $t = if ($IsLaptopSelf) { 'laptop' } else { 'computer' }
        return @{ Type = $t; Reason = 'Es este equipo.' }
    }

    $upnpText = ''
    foreach ($u in $Record.Upnp) {
        $dt = [string]$u.DeviceType
        $mfr = [string]$u.Manufacturer
        if ($dt -match 'InternetGatewayDevice|WANDevice|WANConnectionDevice') { return @{ Type = 'router'; Reason = 'Se anuncia por UPnP como router.' } }
        if ($dt -match 'ZonePlayer') { return @{ Type = 'speaker'; Reason = 'Se anuncia por UPnP como parlante.' } }
        if ($dt -match 'Printer') { return @{ Type = 'printer'; Reason = 'Se anuncia por UPnP como impresora.' } }
        if ($dt -match 'WLANAccessPoint|WFADevice') { return @{ Type = 'network'; Reason = 'Se anuncia por UPnP como punto de acceso Wi-Fi.' } }
        if ($dt -match 'MediaRenderer|dial') {
            if ($mfr -match 'sonos|bose|denon|marantz|yamaha|harman|jbl|bang') { return @{ Type = 'speaker'; Reason = "Reproductor multimedia UPnP de $mfr." } }
            return @{ Type = 'tv'; Reason = 'Se anuncia por UPnP como pantalla o reproductor multimedia.' }
        }
        $upnpText += ' ' + $u.FriendlyName + ' ' + $u.ModelName + ' ' + $u.ModelDescription + ' ' + $mfr
    }

    $names = @($Record.MdnsName, $Record.NetBiosName, $Record.DnsName, $upnpText) | Where-Object { $_ -and $_.Trim() }
    $hay = (($names -join ' ') -replace '\s+', ' ').ToLowerInvariant()
    if ($hay) {
        foreach ($rule in $script:NameRules) {
            if ($hay -match $rule.Pattern) {
                $hint = $Matches[0].Trim(' ', '-', '[', ']')
                return @{ Type = $rule.Type; Reason = "Por el nombre del equipo («$hint»)." }
            }
        }
    }

    if ($Vendor) {
        $v = $Vendor.ToLowerInvariant()
        foreach ($rule in $script:VendorRules) {
            if ($v -match $rule.Pattern) { return @{ Type = $rule.Type; Reason = "Por el fabricante de su tarjeta de red ($Vendor). Es una estimación." } }
        }
    }

    if ($IsRandomMac) {
        return @{ Type = 'phone'; Reason = 'Usa una dirección MAC privada (aleatoria), algo típico de teléfonos y tablets.' }
    }
    @{ Type = 'unknown'; Reason = 'No hay datos suficientes para saber qué es. Puedes elegir el tipo a mano.' }
}

function Get-AutoName {
    param($Record, [string]$HostName, [string]$Vendor, [string]$TypeKey)
    if ($Record.IsSelf) { return "$script:SelfName (este equipo)" }
    $upnp = Get-UpnpSummary $Record
    if ($upnp -and $upnp.FriendlyName -and $upnp.FriendlyName -notmatch '^(uuid:|[0-9a-f-]{20,})') { return $upnp.FriendlyName }
    if ($HostName) { return $HostName }
    $label = (Get-DeviceType $TypeKey).Label
    if ($Record.IsGateway) { if ($Vendor) { return "Router $Vendor" } else { return 'Router' } }
    if ($TypeKey -eq 'unknown') {
        if ($Vendor) { return "Equipo $Vendor" }
        return 'Equipo sin nombre'
    }
    if ($Vendor) { return "$label $Vendor" }
    $label
}

function Get-MacKey($Record) {
    if ($Record.Mac -and -not $Record.SharedMac) { return $Record.Mac }
    "IP:$($Record.Ip)"
}

# Todo lo que se deduce de lo que averiguó el escáner sobre una IP
function Get-DeviceFacts($Record, [bool]$IsLaptopSelf) {
    $vendor = if ($Record.Mac) { [MonitorRed.OuiDatabase]::Lookup($Record.Mac) } else { '' }
    $random = [MonitorRed.Net]::IsRandomMac($Record.Mac)
    $hostName = Get-BestHostName $Record
    $guess = Get-DeviceGuess -Record $Record -Vendor $vendor -IsRandomMac $random -IsLaptopSelf $IsLaptopSelf
    @{
        Key         = Get-MacKey $Record
        Vendor      = $vendor
        IsRandomMac = $random
        HostName    = $hostName
        Guess       = $guess
        AutoName    = Get-AutoName -Record $Record -HostName $hostName -Vendor $vendor -TypeKey $guess.Type
        Upnp        = Get-UpnpSummary $Record
    }
}

#endregion

#region Datos guardados (nombres, equipos vistos, ajustes)

function ConvertTo-Hashtable($Object) {
    $h = @{}
    if ($null -eq $Object) { return $h }
    foreach ($p in $Object.PSObject.Properties) {
        $v = $p.Value
        if ($v -is [System.Management.Automation.PSCustomObject]) { $v = ConvertTo-Hashtable $v }
        $h[$p.Name] = $v
    }
    $h
}

function Read-JsonFile([string]$Path) {
    try {
        if (Test-Path -LiteralPath $Path) {
            $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
            if ($text.Trim()) { return ConvertTo-Hashtable ($text | ConvertFrom-Json) }
        }
    } catch { }
    @{}
}

function Write-JsonFile([string]$Path, $Data) {
    try {
        New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
        $tmp = "$Path.tmp"
        [IO.File]::WriteAllText($tmp, ($Data | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $Path -Force
    } catch { }
}

function Get-DefaultSettings {
    @{ MeasurementMode = 'Auto'; InterceptConsent = $false; RouterBrand = ''; RouterUser = 'admin'; RouterPassword = ''; ShowOffline = $false }
}

function Import-AppData {
    $script:Known = Read-JsonFile $script:DevicesFile
    $script:Settings = Get-DefaultSettings
    $saved = Read-JsonFile $script:SettingsFile
    foreach ($k in $saved.Keys) { $script:Settings[$k] = $saved[$k] }
}

function Save-KnownDevices { Write-JsonFile $script:DevicesFile $script:Known }
function Save-Settings { Write-JsonFile $script:SettingsFile $script:Settings }

# La clave del router se guarda cifrada con DPAPI (solo este usuario de Windows puede leerla)
function Protect-Text([string]$Text) {
    if (-not $Text) { return '' }
    try { ConvertTo-SecureString $Text -AsPlainText -Force | ConvertFrom-SecureString } catch { '' }
}

function Unprotect-Text([string]$Cipher) {
    if (-not $Cipher) { return '' }
    try {
        $sec = ConvertTo-SecureString $Cipher
        [Runtime.InteropServices.Marshal]::PtrToStringUni([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    } catch { '' }
}

function Format-LastSeen([string]$Iso) {
    if (-not $Iso) { return '' }
    try { $d = [datetime]::Parse($Iso, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime() } catch { return '' }
    $days = ((Get-Date).Date - $d.Date).Days
    if ($days -le 0) { return 'hoy ' + $d.ToString('HH:mm') }
    if ($days -eq 1) { return 'ayer ' + $d.ToString('HH:mm') }
    if ($days -lt 30) { return "hace $days días" }
    $d.ToString('dd/MM/yyyy')
}

#endregion

#region Escáner de red (C#)

# Clases en C# para escanear rápido y en paralelo sin congelar la ventana: interfaces de red,
# barrido ping + ARP, nombres (DNS, NetBIOS, mDNS), UPnP, fabricantes por MAC y el modelo de la lista.
$script:ScannerSource = @'
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace MonitorRed
{
    // ---------------------------------------------------------------- Red local

    public class LocalNetwork
    {
        public string InterfaceName { get; set; }
        public string InterfaceId { get; set; }
        public string Description { get; set; }
        public string InterfaceType { get; set; }
        public string LocalIp { get; set; }
        public string LocalMac { get; set; }
        public string Mask { get; set; }
        public int PrefixLength { get; set; }
        public string Gateway { get; set; }
        public uint FirstHost { get; set; }
        public uint LastHost { get; set; }
        public bool IsLimited { get; set; }
        public int Score { get; set; }

        public int HostCount { get { return (int)(LastHost - FirstHost + 1); } }

        public string Summary
        {
            get
            {
                return Net.FromUInt(FirstHost & Net.MaskFromPrefix(PrefixLength)) + "/" + PrefixLength + "  ·  " + InterfaceName;
            }
        }
    }

    public static class Net
    {
        public static uint ToUInt(string ip)
        {
            byte[] b = IPAddress.Parse(ip).GetAddressBytes();
            return ((uint)b[0] << 24) | ((uint)b[1] << 16) | ((uint)b[2] << 8) | b[3];
        }

        public static string FromUInt(uint v)
        {
            return ((v >> 24) & 255) + "." + ((v >> 16) & 255) + "." + ((v >> 8) & 255) + "." + (v & 255);
        }

        public static uint MaskFromPrefix(int prefix)
        {
            if (prefix <= 0) return 0;
            if (prefix >= 32) return 0xFFFFFFFF;
            return 0xFFFFFFFF << (32 - prefix);
        }

        public static int PrefixFromMask(string mask)
        {
            uint m = ToUInt(mask);
            int n = 0;
            while ((m & 0x80000000) != 0) { n++; m <<= 1; }
            return n;
        }

        // "a4c3f0112233", "A4-C3-F0-11-22-33"... -> "A4:C3:F0:11:22:33"
        public static string FormatMac(string mac)
        {
            if (string.IsNullOrEmpty(mac)) return "";
            string hex = Regex.Replace(mac, "[^0-9A-Fa-f]", "").ToUpperInvariant();
            if (hex.Length != 12) return "";
            if (hex == "000000000000" || hex == "FFFFFFFFFFFF") return "";
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < 12; i += 2)
            {
                if (i > 0) sb.Append(':');
                sb.Append(hex, i, 2);
            }
            return sb.ToString();
        }

        public static string FormatMac(byte[] bytes, int length)
        {
            if (bytes == null || length < 6) return "";
            return FormatMac(BitConverter.ToString(bytes, 0, 6));
        }

        // Bit "administrado localmente": los teléfonos y PCs modernos usan MAC aleatorias (privadas)
        public static bool IsRandomMac(string mac)
        {
            string f = FormatMac(mac);
            if (f.Length == 0) return false;
            int first = Convert.ToInt32(f.Substring(0, 2), 16);
            return (first & 0x02) != 0 && (first & 0x01) == 0;
        }

        public static bool IsMulticastMac(string mac)
        {
            string f = FormatMac(mac);
            if (f.Length == 0) return true;
            int first = Convert.ToInt32(f.Substring(0, 2), 16);
            return (first & 0x01) != 0;
        }

        static readonly string[] VirtualWords = {
            "virtual", "hyper-v", "vethernet", "vmware", "virtualbox", "vbox", "wsl", "loopback",
            "bluetooth", "tap-", "tap ", "tun", "wireguard", "zerotier", "tailscale", "hamachi", "vpn", "npcap", "docker"
        };

        public static LocalNetwork[] GetLocalNetworks()
        {
            List<LocalNetwork> list = new List<LocalNetwork>();
            foreach (NetworkInterface ni in NetworkInterface.GetAllNetworkInterfaces())
            {
                try
                {
                    if (ni.OperationalStatus != OperationalStatus.Up) continue;
                    if (ni.NetworkInterfaceType == NetworkInterfaceType.Loopback || ni.NetworkInterfaceType == NetworkInterfaceType.Tunnel) continue;
                    IPInterfaceProperties props = ni.GetIPProperties();
                    string gateway = "";
                    foreach (GatewayIPAddressInformation g in props.GatewayAddresses)
                    {
                        if (g.Address.AddressFamily == AddressFamily.InterNetwork && !g.Address.Equals(IPAddress.Any)) { gateway = g.Address.ToString(); break; }
                    }
                    foreach (UnicastIPAddressInformation ua in props.UnicastAddresses)
                    {
                        if (ua.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                        string ip = ua.Address.ToString();
                        if (ip.StartsWith("169.254.") || ip.StartsWith("127.")) continue;
                        if (ua.IPv4Mask == null || ua.IPv4Mask.Equals(IPAddress.Any)) continue;
                        int prefix = PrefixFromMask(ua.IPv4Mask.ToString());
                        if (prefix < 8 || prefix > 30) continue;

                        LocalNetwork n = new LocalNetwork();
                        n.InterfaceName = ni.Name;
                        n.InterfaceId = ni.Id;
                        n.Description = ni.Description;
                        n.InterfaceType = ni.NetworkInterfaceType.ToString();
                        n.LocalIp = ip;
                        n.LocalMac = FormatMac(ni.GetPhysicalAddress().ToString());
                        n.Gateway = gateway;
                        SetRange(n, prefix);

                        string text = (ni.Name + " " + ni.Description).ToLowerInvariant();
                        int score = 0;
                        if (gateway.Length > 0) score += 100;
                        if (ni.NetworkInterfaceType == NetworkInterfaceType.Wireless80211) score += 20;
                        if (ni.NetworkInterfaceType == NetworkInterfaceType.Ethernet) score += 15;
                        foreach (string w in VirtualWords) if (text.Contains(w)) { score -= 200; break; }
                        if (IsPrivate(ip)) score += 10;
                        n.Score = score;
                        list.Add(n);
                    }
                }
                catch { }
            }
            list.Sort(delegate (LocalNetwork a, LocalNetwork b) { return b.Score.CompareTo(a.Score); });
            return list.ToArray();
        }

        // Redes más grandes que /22 (más de 1022 equipos) se limitan a la /24 del propio equipo.
        public static void SetRange(LocalNetwork n, int prefix)
        {
            uint ip = ToUInt(n.LocalIp);
            int scanPrefix = prefix;
            n.IsLimited = false;
            if (prefix < 22) { scanPrefix = 24; n.IsLimited = true; }
            uint mask = MaskFromPrefix(scanPrefix);
            uint network = ip & mask;
            uint broadcast = network | ~mask;
            n.PrefixLength = prefix;
            n.Mask = FromUInt(MaskFromPrefix(prefix));
            n.FirstHost = network + 1;
            n.LastHost = broadcast - 1;
        }

        public static bool IsPrivate(string ip)
        {
            uint v = ToUInt(ip);
            return (v >> 24) == 10 || (v >> 20) == (172 << 4 | 1) || (v >> 16) == (192 << 8 | 168);
        }

        public static bool IsWindows { get { return Environment.OSVersion.Platform == PlatformID.Win32NT; } }
    }

    // ---------------------------------------------------------------- Windows: ARP

    public static class NativeArp
    {
        [DllImport("iphlpapi.dll", ExactSpelling = true)]
        static extern int SendARP(uint destIp, uint srcIp, byte[] macAddr, ref int physAddrLen);

        [DllImport("iphlpapi.dll", ExactSpelling = true)]
        static extern int GetIpNetTable(IntPtr pIpNetTable, ref int pdwSize, bool bOrder);

        static uint ToInAddr(string ip) { return BitConverter.ToUInt32(IPAddress.Parse(ip).GetAddressBytes(), 0); }

        // Pregunta la MAC directamente con ARP: responde aunque el equipo bloquee el ping.
        public static string Resolve(string ip, string sourceIp)
        {
            if (!Net.IsWindows) return "";
            try
            {
                byte[] mac = new byte[8];
                int len = mac.Length;
                uint src = string.IsNullOrEmpty(sourceIp) ? 0 : ToInAddr(sourceIp);
                if (SendARP(ToInAddr(ip), src, mac, ref len) == 0) return Net.FormatMac(mac, len);
            }
            catch { }
            return "";
        }

        // Tabla ARP del sistema: IP -> MAC
        public static Dictionary<string, string> GetTable()
        {
            Dictionary<string, string> result = new Dictionary<string, string>();
            try
            {
                if (Net.IsWindows) ReadWindowsTable(result);
                else if (File.Exists("/proc/net/arp")) ReadLinuxTable(result);
            }
            catch { }
            return result;
        }

        static void ReadWindowsTable(Dictionary<string, string> result)
        {
            int size = 0;
            GetIpNetTable(IntPtr.Zero, ref size, true);
            if (size <= 0) return;
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try
            {
                if (GetIpNetTable(buffer, ref size, true) != 0) return;
                int count = Marshal.ReadInt32(buffer);
                // MIB_IPNETROW: dwIndex, dwPhysAddrLen, bPhysAddr[8], dwAddr, dwType = 24 bytes
                for (int i = 0; i < count; i++)
                {
                    IntPtr row = new IntPtr(buffer.ToInt64() + 4 + i * 24);
                    int macLen = Marshal.ReadInt32(row, 4);
                    byte[] mac = new byte[8];
                    Marshal.Copy(new IntPtr(row.ToInt64() + 8), mac, 0, 8);
                    byte[] addr = new byte[4];
                    Marshal.Copy(new IntPtr(row.ToInt64() + 16), addr, 0, 4);
                    int type = Marshal.ReadInt32(row, 20);
                    if (type == 2) continue; // inválida
                    string m = Net.FormatMac(mac, macLen);
                    if (m.Length == 0 || Net.IsMulticastMac(m)) continue;
                    result[new IPAddress(addr).ToString()] = m;
                }
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }

        static void ReadLinuxTable(Dictionary<string, string> result)
        {
            string[] lines = File.ReadAllLines("/proc/net/arp");
            for (int i = 1; i < lines.Length; i++)
            {
                string[] p = Regex.Split(lines[i].Trim(), "\\s+");
                if (p.Length < 4) continue;
                string m = Net.FormatMac(p[3]);
                if (m.Length == 0 || Net.IsMulticastMac(m)) continue;
                result[p[0]] = m;
            }
        }
    }

    // ---------------------------------------------------------------- Nombres: NetBIOS y mDNS

    public static class NameQuery
    {
        static int _id = Environment.TickCount & 0x7FFF;

        static byte[] Exchange(string ip, int port, byte[] query, int timeoutMs)
        {
            using (UdpClient udp = new UdpClient(0))
            {
                udp.Client.ReceiveTimeout = timeoutMs;
                IPEndPoint target = new IPEndPoint(IPAddress.Parse(ip), port);
                udp.Send(query, query.Length, target);
                DateTime end = DateTime.UtcNow.AddMilliseconds(timeoutMs);
                while (DateTime.UtcNow < end)
                {
                    IPEndPoint from = new IPEndPoint(IPAddress.Any, 0);
                    byte[] data;
                    try { data = udp.Receive(ref from); }
                    catch (SocketException) { return null; }
                    if (from.Address.Equals(target.Address) && data.Length > 12 && data[0] == query[0] && data[1] == query[1]) return data;
                }
            }
            return null;
        }

        static void WriteId(byte[] packet)
        {
            int id = Interlocked.Increment(ref _id) & 0xFFFF;
            packet[0] = (byte)(id >> 8);
            packet[1] = (byte)id;
        }

        // Consulta NBSTAT (puerto 137): la responden Windows, Samba, NAS e impresoras.
        public static string NetBios(string ip, int timeoutMs)
        {
            try
            {
                byte[] q = new byte[50];
                WriteId(q);
                q[5] = 1; // 1 pregunta
                q[12] = 0x20;
                q[13] = (byte)'C'; q[14] = (byte)'K'; // "*" codificado
                for (int i = 15; i < 45; i++) q[i] = (byte)'A';
                q[45] = 0;
                q[47] = 0x21; // NBSTAT
                q[49] = 0x01; // IN
                byte[] r = Exchange(ip, 137, q, timeoutMs);
                return ParseNetBios(r);
            }
            catch { return ""; }
        }

        public static string ParseNetBios(byte[] r)
        {
            if (r == null || r.Length < 57) return "";
            int count = r[56];
            for (int i = 0; i < count; i++)
            {
                int off = 57 + i * 18;
                if (off + 18 > r.Length) break;
                int suffix = r[off + 15];
                int flags = (r[off + 16] << 8) | r[off + 17];
                if (suffix == 0 && (flags & 0x8000) == 0)
                    return Encoding.ASCII.GetString(r, off, 15).Trim();
            }
            return "";
        }

        // Pregunta mDNS directa al equipo (puerto 5353) por su nombre inverso: iPhone, Mac,
        // Android, Chromecast, impresoras y muchos dispositivos inteligentes responden "nombre.local".
        public static string Mdns(string ip, int timeoutMs)
        {
            try
            {
                string[] o = ip.Split('.');
                string name = o[3] + "." + o[2] + "." + o[1] + "." + o[0] + ".in-addr.arpa";
                byte[] q = BuildQuery(name, 12);
                byte[] r = Exchange(ip, 5353, q, timeoutMs);
                if (r == null) return "";
                return CleanLocal(ReadFirstAnswerName(r, 12));
            }
            catch { return ""; }
        }

        public static byte[] BuildQuery(string name, int qtype)
        {
            List<byte> b = new List<byte>();
            b.AddRange(new byte[] { 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0 });
            foreach (string label in name.Split('.'))
            {
                if (label.Length == 0) continue;
                byte[] l = Encoding.UTF8.GetBytes(label);
                b.Add((byte)l.Length);
                b.AddRange(l);
            }
            b.Add(0);
            b.Add((byte)(qtype >> 8)); b.Add((byte)qtype);
            b.Add(0x80); b.Add(0x01); // IN + respuesta unicast
            byte[] q = b.ToArray();
            WriteId(q);
            return q;
        }

        public static string ReadFirstAnswerName(byte[] r, int wantedType)
        {
            int qd = (r[4] << 8) | r[5];
            int an = ((r[6] << 8) | r[7]) + ((r[8] << 8) | r[9]) + ((r[10] << 8) | r[11]);
            int off = 12;
            for (int i = 0; i < qd; i++) { ReadName(r, ref off); off += 4; }
            for (int i = 0; i < an && off + 10 <= r.Length; i++)
            {
                ReadName(r, ref off);
                int type = (r[off] << 8) | r[off + 1];
                int len = (r[off + 8] << 8) | r[off + 9];
                off += 10;
                if (type == wantedType)
                {
                    int p = off;
                    return ReadName(r, ref p);
                }
                off += len;
            }
            return "";
        }

        public static string ReadName(byte[] r, ref int offset)
        {
            StringBuilder sb = new StringBuilder();
            int off = offset;
            bool jumped = false;
            int guard = 0;
            while (off < r.Length && guard++ < 64)
            {
                int len = r[off];
                if (len == 0) { off++; break; }
                if ((len & 0xC0) == 0xC0)
                {
                    if (off + 1 >= r.Length) break;
                    int ptr = ((len & 0x3F) << 8) | r[off + 1];
                    if (!jumped) offset = off + 2;
                    jumped = true;
                    off = ptr;
                    continue;
                }
                off++;
                if (off + len > r.Length) break;
                if (sb.Length > 0) sb.Append('.');
                sb.Append(Encoding.UTF8.GetString(r, off, len));
                off += len;
            }
            if (!jumped) offset = off;
            return sb.ToString();
        }

        public static string CleanLocal(string name)
        {
            if (string.IsNullOrEmpty(name)) return "";
            name = name.TrimEnd('.');
            if (name.EndsWith(".local", StringComparison.OrdinalIgnoreCase)) name = name.Substring(0, name.Length - 6);
            return name;
        }

        public static string ReverseDns(string ip, int timeoutMs)
        {
            try
            {
                IAsyncResult ar = Dns.BeginGetHostEntry(ip, null, null);
                if (!ar.AsyncWaitHandle.WaitOne(timeoutMs)) return "";
                IPHostEntry e = Dns.EndGetHostEntry(ar);
                string h = e.HostName;
                if (string.IsNullOrEmpty(h) || h == ip) return "";
                IPAddress tmp;
                if (IPAddress.TryParse(h, out tmp)) return "";
                return h.TrimEnd('.');
            }
            catch { return ""; }
        }
    }

    // ---------------------------------------------------------------- UPnP / SSDP

    public class UpnpInfo
    {
        public string Location;
        public string Server;
        public string FriendlyName = "";
        public string Manufacturer = "";
        public string ModelName = "";
        public string ModelDescription = "";
        public string DeviceType = "";
        public string WanControlUrl = "";
        public string WanServiceType = "";
    }

    public static class Upnp
    {
        // Busca dispositivos UPnP (TVs, consolas, parlantes, impresoras, el router) durante unos segundos.
        // Devuelve IP -> lista de (LOCATION, SERVER).
        public static Dictionary<string, List<UpnpInfo>> Discover(string localIp, int timeoutMs, ScanSession session)
        {
            Dictionary<string, List<UpnpInfo>> found = new Dictionary<string, List<UpnpInfo>>();
            try
            {
                using (UdpClient udp = new UdpClient(new IPEndPoint(IPAddress.Parse(localIp), 0)))
                {
                    udp.Client.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastTimeToLive, 2);
                    udp.Client.ReceiveTimeout = 300;
                    IPEndPoint group = new IPEndPoint(IPAddress.Parse("239.255.255.250"), 1900);
                    string[] targets = { "ssdp:all", "upnp:rootdevice", "urn:schemas-upnp-org:device:InternetGatewayDevice:1" };
                    foreach (string st in targets)
                    {
                        byte[] msg = Encoding.ASCII.GetBytes("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: " + st + "\r\n\r\n");
                        udp.Send(msg, msg.Length, group);
                    }
                    DateTime end = DateTime.UtcNow.AddMilliseconds(timeoutMs);
                    while (DateTime.UtcNow < end && (session == null || !session.IsCancelled))
                    {
                        IPEndPoint from = new IPEndPoint(IPAddress.Any, 0);
                        byte[] data;
                        try { data = udp.Receive(ref from); }
                        catch (SocketException) { continue; }
                        string text = Encoding.UTF8.GetString(data);
                        string location = Header(text, "LOCATION");
                        if (location.Length == 0) continue;
                        string ip = from.Address.ToString();
                        lock (found)
                        {
                            List<UpnpInfo> l;
                            if (!found.TryGetValue(ip, out l)) { l = new List<UpnpInfo>(); found[ip] = l; }
                            bool exists = false;
                            foreach (UpnpInfo u in l) if (u.Location == location) { exists = true; break; }
                            if (!exists && l.Count < 4)
                            {
                                UpnpInfo info = new UpnpInfo();
                                info.Location = location;
                                info.Server = Header(text, "SERVER");
                                l.Add(info);
                            }
                        }
                    }
                }
            }
            catch { }
            return found;
        }

        public static string Header(string text, string name)
        {
            Match m = Regex.Match(text, "^" + name + "\\s*:\\s*(.*?)\\s*$", RegexOptions.IgnoreCase | RegexOptions.Multiline);
            return m.Success ? m.Groups[1].Value : "";
        }

        public static void FetchDescription(UpnpInfo info, int timeoutMs)
        {
            try
            {
                HttpWebRequest req = (HttpWebRequest)WebRequest.Create(info.Location);
                req.Timeout = timeoutMs;
                req.ReadWriteTimeout = timeoutMs;
                req.Proxy = null;
                req.UserAgent = "MonitorRed/1.0 UPnP/1.1";
                string xml;
                using (WebResponse resp = req.GetResponse())
                using (StreamReader sr = new StreamReader(resp.GetResponseStream()))
                {
                    char[] buf = new char[262144];
                    int n = sr.ReadBlock(buf, 0, buf.Length);
                    xml = new string(buf, 0, n);
                }
                ParseDescription(info, xml);
            }
            catch { }
        }

        public static void ParseDescription(UpnpInfo info, string xml)
        {
            info.DeviceType = Tag(xml, "deviceType");
            info.FriendlyName = Tag(xml, "friendlyName");
            info.Manufacturer = Tag(xml, "manufacturer");
            info.ModelName = Tag(xml, "modelName");
            info.ModelDescription = Tag(xml, "modelDescription");

            // Servicio que da los bytes totales de internet (para el modo de medición UPnP)
            foreach (Match s in Regex.Matches(xml, "<service>(.*?)</service>", RegexOptions.Singleline | RegexOptions.IgnoreCase))
            {
                string st = Tag(s.Groups[1].Value, "serviceType");
                if (st.IndexOf("WANCommonInterfaceConfig", StringComparison.OrdinalIgnoreCase) < 0) continue;
                string control = Tag(s.Groups[1].Value, "controlURL");
                if (control.Length == 0) continue;
                string baseUrl = Tag(xml, "URLBase");
                if (baseUrl.Length == 0) baseUrl = info.Location;
                try { info.WanControlUrl = new Uri(new Uri(baseUrl), control).ToString(); } catch { info.WanControlUrl = control; }
                info.WanServiceType = st;
                break;
            }
        }

        static string Tag(string xml, string tag)
        {
            Match m = Regex.Match(xml, "<" + tag + ">\\s*(.*?)\\s*</" + tag + ">", RegexOptions.Singleline | RegexOptions.IgnoreCase);
            return m.Success ? WebUtilityDecode(m.Groups[1].Value) : "";
        }

        static string WebUtilityDecode(string s) { return WebUtility.HtmlDecode(s).Trim(); }

        // Pregunta al router, por UPnP (acción SOAP del servicio WANCommonInterfaceConfig), cuántos bytes
        // han pasado por internet desde que se encendió. Devuelve el contador, o -1 si no respondió.
        public static long GetTotalBytes(string controlUrl, string serviceType, bool received, int timeoutMs)
        {
            string action = received ? "GetTotalBytesReceived" : "GetTotalBytesSent";
            string tag = received ? "NewTotalBytesReceived" : "NewTotalBytesSent";
            string body =
                "<?xml version=\"1.0\"?>" +
                "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" " +
                "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">" +
                "<s:Body><u:" + action + " xmlns:u=\"" + serviceType + "\"></u:" + action + "></s:Body></s:Envelope>";
            try
            {
                HttpWebRequest req = (HttpWebRequest)WebRequest.Create(controlUrl);
                req.Method = "POST";
                req.ContentType = "text/xml; charset=\"utf-8\"";
                req.Headers.Add("SOAPACTION", "\"" + serviceType + "#" + action + "\"");
                req.Timeout = timeoutMs;
                req.ReadWriteTimeout = timeoutMs;
                req.Proxy = null;
                byte[] data = Encoding.UTF8.GetBytes(body);
                req.ContentLength = data.Length;
                using (Stream rs = req.GetRequestStream()) rs.Write(data, 0, data.Length);
                string xml;
                using (WebResponse resp = req.GetResponse())
                using (StreamReader sr = new StreamReader(resp.GetResponseStream())) xml = sr.ReadToEnd();
                string value = Tag(xml, tag);
                // El contador es de 32 bits y da la vuelta; se trata como sin signo
                long result;
                if (long.TryParse(value, out result) && result >= 0) return result;
            }
            catch { }
            return -1;
        }
    }

    // ---------------------------------------------------------------- Fabricantes por MAC

    public static class OuiDatabase
    {
        static Dictionary<string, string> _map = new Dictionary<string, string>();

        public static int Count { get { return _map.Count; } }

        // Formato compacto: una línea por bloque, "PREFIJO<TAB>Fabricante" (6, 7 o 9 dígitos hex)
        public static void Load(string compact)
        {
            Dictionary<string, string> map = new Dictionary<string, string>(StringComparer.Ordinal);
            using (StringReader sr = new StringReader(compact))
            {
                string line;
                while ((line = sr.ReadLine()) != null)
                {
                    int tab = line.IndexOf('\t');
                    if (tab < 6) continue;
                    map[line.Substring(0, tab)] = line.Substring(tab + 1);
                }
            }
            _map = map;
        }

        public static void LoadGzip(byte[] data)
        {
            using (MemoryStream ms = new MemoryStream(data))
            using (GZipStream gz = new GZipStream(ms, CompressionMode.Decompress))
            using (StreamReader sr = new StreamReader(gz, Encoding.UTF8))
            {
                Load(sr.ReadToEnd());
            }
        }

        public static string Lookup(string mac)
        {
            string hex = Regex.Replace(mac ?? "", "[^0-9A-Fa-f]", "").ToUpperInvariant();
            if (hex.Length < 6) return "";
            string name;
            if (hex.Length >= 9 && _map.TryGetValue(hex.Substring(0, 9), out name)) return name;
            if (hex.Length >= 7 && _map.TryGetValue(hex.Substring(0, 7), out name)) return name;
            if (_map.TryGetValue(hex.Substring(0, 6), out name)) return name;
            return "";
        }

        static readonly Regex Suffix = new Regex(
            "[,\\s]+(co\\.?,?\\s*ltd\\.?|co\\.?|ltd\\.?|limited|inc\\.?|incorporated|corporation|corp\\.?|llc|l\\.l\\.c\\.|gmbh|ag|s\\.?a\\.?|s\\.?a\\.?s\\.?|b\\.?v\\.?|oy|ab|a/s|plc|pte\\.?|pty\\.?|srl|s\\.r\\.l\\.|kg|technologies|technology|electronics|electronic|international)$",
            RegexOptions.IgnoreCase);

        // Ciudades/provincias que muchos fabricantes chinos ponen delante del nombre
        static readonly Regex CityPrefix = new Regex(
            "^(shenzhen|beijing|hangzhou|guangdong|guangzhou|shanghai|zhejiang|qingdao|xiamen|chongqing|wuhan|suzhou|nanjing|fujian|jiangsu|dongguan|zhuhai|ningbo|hefei|tianjin|chengdu|sichuan)\\s+",
            RegexOptions.IgnoreCase);

        public static string CleanName(string name)
        {
            string n = Regex.Replace(name ?? "", "\\s+", " ").Trim().Trim(',', '.', ' ');
            n = FixAllCaps(n);
            string withoutCity = CityPrefix.Replace(n, "");
            if (withoutCity.Length >= 3) n = withoutCity;
            for (int i = 0; i < 4; i++)
            {
                string m = Suffix.Replace(n, "").Trim().Trim(',', ' ');
                if (m == n || m.Length < 2) break;
                n = m;
            }
            return n;
        }

        // "SAMSUNG ELECTRONICS" -> "Samsung Electronics" (las siglas cortas como LG, HP o ZTE quedan igual)
        static string FixAllCaps(string n)
        {
            if (Regex.IsMatch(n, "[a-z]")) return n;
            return Regex.Replace(n, "[A-Z][A-Z0-9]{3,}", delegate (Match m)
            {
                return m.Value.Substring(0, 1) + m.Value.Substring(1).ToLowerInvariant();
            });
        }

        // Convierte los archivos CSV del registro de la IEEE (oui.csv, mam.csv, oui36.csv) al formato compacto.
        // Columnas: Registry, Assignment, Organization Name, Organization Address
        public static string ConvertIeeeCsv(string csv)
        {
            StringBuilder sb = new StringBuilder();
            using (StringReader sr = new StringReader(csv))
            {
                string line;
                while ((line = sr.ReadLine()) != null)
                {
                    if (line.Length < 10 || line.StartsWith("Registry,")) continue;
                    List<string> cols = SplitCsv(line);
                    if (cols.Count < 3) continue;
                    string hex = cols[1].Trim().ToUpperInvariant();
                    if (!Regex.IsMatch(hex, "^[0-9A-F]{6}$|^[0-9A-F]{7}$|^[0-9A-F]{9}$")) continue;
                    string name = CleanName(cols[2]);
                    if (name.Length == 0) continue;
                    sb.Append(hex).Append('\t').Append(name).Append('\n');
                }
            }
            return sb.ToString();
        }

        static List<string> SplitCsv(string line)
        {
            List<string> cols = new List<string>();
            StringBuilder cur = new StringBuilder();
            bool quoted = false;
            for (int i = 0; i < line.Length; i++)
            {
                char c = line[i];
                if (quoted)
                {
                    if (c == '"' && i + 1 < line.Length && line[i + 1] == '"') { cur.Append('"'); i++; }
                    else if (c == '"') quoted = false;
                    else cur.Append(c);
                }
                else if (c == '"') quoted = true;
                else if (c == ',') { cols.Add(cur.ToString()); cur.Length = 0; }
                else cur.Append(c);
            }
            cols.Add(cur.ToString());
            return cols;
        }

        // Convierte el archivo "manuf" de Wireshark (datos públicos del registro IEEE) al formato compacto.
        public static string ConvertManuf(string manuf)
        {
            StringBuilder sb = new StringBuilder();
            using (StringReader sr = new StringReader(manuf))
            {
                string line;
                while ((line = sr.ReadLine()) != null)
                {
                    if (line.Length == 0 || line[0] == '#') continue;
                    string[] p = line.Split('\t');
                    if (p.Length < 2) continue;
                    string block = p[0].Trim();
                    string full = p.Length >= 3 ? p[2].Trim() : p[1].Trim();
                    if (full.Length == 0) full = p[1].Trim();
                    int bits = 24;
                    int slash = block.IndexOf('/');
                    if (slash > 0) { int.TryParse(block.Substring(slash + 1), out bits); block = block.Substring(0, slash); }
                    string hex = Regex.Replace(block, "[^0-9A-Fa-f]", "").ToUpperInvariant();
                    int digits = bits / 4;
                    if (digits != 6 && digits != 7 && digits != 9) continue;
                    if (hex.Length < digits) continue;
                    sb.Append(hex, 0, digits).Append('\t').Append(CleanName(full)).Append('\n');
                }
            }
            return sb.ToString();
        }
    }

    // ---------------------------------------------------------------- Escaneo

    // Lo que se averiguó de una IP. El escaneo corre en segundo plano y la ventana
    // recoge los cambios con TakeChanges() para mostrarlos a medida que aparecen.
    public class HostRecord
    {
        public string Ip;
        public uint IpValue;
        public string Mac = "";
        public int PingMs = -1;
        public bool ArpOnly;
        public string DnsName = "";
        public string NetBiosName = "";
        public string MdnsName = "";
        public bool IsGateway;
        public bool IsSelf;
        public bool NamesDone;
        // Varias IPs responden con la misma MAC: un repetidor Wi-Fi que "traduce" MACs o un router con proxy ARP
        public bool SharedMac;
        // Fantasma de proxy ARP (MAC compartida y no responde): la ventana lo quita de la lista
        public bool Removed;
        // La ventana recibe los equipos recién cuando se revisaron las MAC compartidas
        public bool Ready;
        public List<UpnpInfo> Upnp = new List<UpnpInfo>();
    }

    public class ScanSession
    {
        public LocalNetwork Network { get; private set; }
        public int Threads = 96;
        public int PingTimeoutMs = 700;
        public int NameTimeoutMs = 900;
        public bool UseActiveProbes = true;

        readonly Dictionary<string, HostRecord> _records = new Dictionary<string, HostRecord>();
        readonly HashSet<string> _changed = new HashSet<string>();
        readonly object _lock = new object();
        int _swept;
        volatile bool _cancel;
        volatile bool _completed;
        volatile string _phase = "Preparando...";
        volatile int _percent;
        string _error = "";
        readonly List<UpnpInfo> _gateways = new List<UpnpInfo>();
        bool _marked;

        public ScanSession(LocalNetwork network) { Network = network; }

        public bool IsCancelled { get { return _cancel; } }
        public bool IsCompleted { get { return _completed; } }
        public string Phase { get { return _phase; } }
        public int Percent { get { return _percent; } }
        public string Error { get { return _error; } }
        public int FoundCount
        {
            get { lock (_lock) { int n = 0; foreach (HostRecord r in _records.Values) if (!r.Removed) n++; return n; } }
        }

        public UpnpInfo[] InternetGateways { get { lock (_lock) return _gateways.ToArray(); } }

        public void Cancel() { _cancel = true; }

        public void Start()
        {
            Thread t = new Thread(Run);
            t.IsBackground = true;
            t.Start();
        }

        public HostRecord[] TakeChanges()
        {
            lock (_lock)
            {
                List<HostRecord> list = new List<HostRecord>();
                List<string> pending = new List<string>();
                foreach (string ip in _changed)
                {
                    HostRecord r = _records[ip];
                    if (!r.Ready) pending.Add(ip);
                    else if (!r.Removed) list.Add(r);
                }
                _changed.Clear();
                foreach (string ip in pending) _changed.Add(ip);
                return list.ToArray();
            }
        }

        public HostRecord[] GetAll()
        {
            lock (_lock)
            {
                List<HostRecord> list = new List<HostRecord>();
                foreach (HostRecord r in _records.Values) if (!r.Removed) list.Add(r);
                return list.ToArray();
            }
        }

        // Algunos routers (y las redes en la nube) responden ARP por todas las IPs con su propia MAC.
        // Si una MAC aparece en varias IPs: se quitan las que no responden al ping (no son equipos reales)
        // y las demás se marcan para recordarlas por IP en vez de por MAC.
        public void MarkSharedMacs()
        {
            lock (_lock)
            {
                _marked = true;
                Dictionary<string, List<HostRecord>> byMac = new Dictionary<string, List<HostRecord>>();
                foreach (HostRecord r in _records.Values)
                {
                    r.Ready = true;
                    _changed.Add(r.Ip);
                    if (r.Mac.Length == 0 || r.IsSelf) continue;
                    List<HostRecord> l;
                    if (!byMac.TryGetValue(r.Mac, out l)) { l = new List<HostRecord>(); byMac[r.Mac] = l; }
                    l.Add(r);
                }
                foreach (List<HostRecord> group in byMac.Values)
                {
                    if (group.Count < 2) continue;
                    foreach (HostRecord r in group)
                    {
                        r.SharedMac = true;
                        if (r.PingMs < 0 && !r.IsGateway) r.Removed = true;
                        _changed.Add(r.Ip);
                    }
                }
            }
        }

        HostRecord Touch(string ip)
        {
            HostRecord r;
            if (!_records.TryGetValue(ip, out r))
            {
                r = new HostRecord();
                r.Ip = ip;
                r.IpValue = Net.ToUInt(ip);
                r.IsGateway = ip == Network.Gateway;
                r.IsSelf = ip == Network.LocalIp;
                r.Ready = _marked;
                _records[ip] = r;
            }
            _changed.Add(ip);
            return r;
        }

        public void Report(string ip, string mac, int pingMs)
        {
            lock (_lock)
            {
                HostRecord r = Touch(ip);
                if (!string.IsNullOrEmpty(mac)) r.Mac = mac;
                if (pingMs >= 0) r.PingMs = pingMs;
            }
        }

        void Run()
        {
            try
            {
                Report(Network.LocalIp, Network.LocalMac, 0);

                // UPnP en paralelo con el barrido
                Dictionary<string, List<UpnpInfo>> upnp = null;
                Thread ssdp = new Thread(delegate () { upnp = Upnp.Discover(Network.LocalIp, 5000, this); });
                ssdp.IsBackground = true;
                if (UseActiveProbes) ssdp.Start();

                Sweep();
                if (_cancel) return;

                _phase = "Leyendo la tabla ARP...";
                foreach (KeyValuePair<string, string> e in NativeArp.GetTable())
                {
                    uint v;
                    try { v = Net.ToUInt(e.Key); } catch { continue; }
                    if (v < Network.FirstHost || v > Network.LastHost) continue;
                    lock (_lock)
                    {
                        bool isNew = !_records.ContainsKey(e.Key);
                        HostRecord r = Touch(e.Key);
                        if (r.Mac.Length == 0) r.Mac = e.Value;
                        if (isNew) r.ArpOnly = true;
                    }
                }
                MarkSharedMacs();
                _percent = 72;

                ResolveNames();
                if (_cancel) return;

                _phase = "Consultando dispositivos UPnP (TVs, consolas, parlantes)...";
                if (UseActiveProbes) ssdp.Join(8000);
                if (upnp != null) FetchUpnp(upnp);
                _percent = 100;
                _phase = "Listo";
            }
            catch (Exception ex)
            {
                _error = ex.Message;
            }
            finally
            {
                _completed = true;
            }
        }

        void RunWorkers(int count, ThreadStart work)
        {
            List<Thread> threads = new List<Thread>();
            for (int i = 0; i < count; i++)
            {
                Thread t = new Thread(work);
                t.IsBackground = true;
                t.Start();
                threads.Add(t);
            }
            foreach (Thread t in threads) t.Join();
        }

        void Sweep()
        {
            _phase = "Buscando equipos en " + Net.FromUInt(Network.FirstHost) + " - " + Net.FromUInt(Network.LastHost) + "...";
            int total = Network.HostCount;
            int next = -1;
            if (!UseActiveProbes) return;
            RunWorkers(Math.Min(Threads, total), delegate ()
            {
                using (Ping ping = new Ping())
                {
                    while (!_cancel)
                    {
                        int i = Interlocked.Increment(ref next);
                        if (i >= total) break;
                        string ip = Net.FromUInt((uint)(Network.FirstHost + i));
                        if (ip != Network.LocalIp)
                        {
                            int ms = -1;
                            try
                            {
                                PingReply reply = ping.Send(ip, PingTimeoutMs);
                                if (reply.Status == IPStatus.Success) ms = (int)reply.RoundtripTime;
                            }
                            catch { }
                            string mac = NativeArp.Resolve(ip, Network.LocalIp);
                            if (ms >= 0 || mac.Length > 0) Report(ip, mac, ms);
                        }
                        int done = Interlocked.Increment(ref _swept);
                        _percent = (int)(70.0 * done / total);
                    }
                }
            });
        }

        void ResolveNames()
        {
            _phase = "Averiguando los nombres de los equipos...";
            HostRecord[] all = GetAll();
            int next = -1;
            int done = 0;
            RunWorkers(Math.Min(32, Math.Max(1, all.Length)), delegate ()
            {
                while (!_cancel)
                {
                    int i = Interlocked.Increment(ref next);
                    if (i >= all.Length) break;
                    HostRecord r = all[i];
                    string dns = NameQuery.ReverseDns(r.Ip, 1500);
                    string nb = UseActiveProbes ? NameQuery.NetBios(r.Ip, NameTimeoutMs) : "";
                    string md = UseActiveProbes ? NameQuery.Mdns(r.Ip, NameTimeoutMs) : "";
                    lock (_lock)
                    {
                        r.DnsName = dns;
                        r.NetBiosName = nb;
                        r.MdnsName = md;
                        r.NamesDone = true;
                        _changed.Add(r.Ip);
                    }
                    int d = Interlocked.Increment(ref done);
                    _percent = 72 + (int)(18.0 * d / all.Length);
                }
            });
        }

        void FetchUpnp(Dictionary<string, List<UpnpInfo>> upnp)
        {
            List<UpnpInfo> todo = new List<UpnpInfo>();
            List<string> owners = new List<string>();
            foreach (KeyValuePair<string, List<UpnpInfo>> e in upnp)
            {
                foreach (UpnpInfo u in e.Value) { todo.Add(u); owners.Add(e.Key); }
            }
            int next = -1;
            RunWorkers(Math.Min(16, Math.Max(1, todo.Count)), delegate ()
            {
                while (!_cancel)
                {
                    int i = Interlocked.Increment(ref next);
                    if (i >= todo.Count) break;
                    Upnp.FetchDescription(todo[i], 2500);
                    string ip = owners[i];
                    uint v;
                    try { v = Net.ToUInt(ip); } catch { continue; }
                    lock (_lock)
                    {
                        if (todo[i].WanControlUrl.Length > 0) _gateways.Add(todo[i]);
                        if (v < Network.FirstHost || v > Network.LastHost) continue;
                        HostRecord r = Touch(ip);
                        r.Upnp.Add(todo[i]);
                    }
                }
            });
        }
    }

    // ---------------------------------------------------------------- Modelo para la ventana

    public class Bindable : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler PropertyChanged;
        protected void Notify(string name)
        {
            PropertyChangedEventHandler h = PropertyChanged;
            if (h != null) h(this, new PropertyChangedEventArgs(name));
        }
        protected bool Set<T>(ref T field, T value, string name)
        {
            if (EqualityComparer<T>.Default.Equals(field, value)) return false;
            field = value;
            Notify(name);
            return true;
        }
    }

    public class DeviceItem : Bindable
    {
        // Clave para recordar el equipo entre escaneos: la MAC (o la IP si no se conoce la MAC)
        public string Key { get; set; }

        string _ip = "", _mac = "", _vendor = "", _hostName = "", _autoName = "", _customName = "";
        string _typeKey = "", _typeLabel = "", _glyph = "", _typeReason = "", _details = "", _badge = "";
        string _status = "", _lastSeen = "", _download = "—", _upload = "—";
        uint _ipValue;
        bool _isOnline, _isRandomMac, _isGateway, _isSelf, _isCustomType;
        int _pingMs = -1;

        public string Ip { get { return _ip; } set { Set(ref _ip, value, "Ip"); } }
        public uint IpValue { get { return _ipValue; } set { Set(ref _ipValue, value, "IpValue"); } }
        public string Mac { get { return _mac; } set { Set(ref _mac, value, "Mac"); } }
        public string Vendor { get { return _vendor; } set { Set(ref _vendor, value, "Vendor"); } }
        public string HostName { get { return _hostName; } set { Set(ref _hostName, value, "HostName"); } }
        public int PingMs { get { return _pingMs; } set { Set(ref _pingMs, value, "PingMs"); } }

        public string AutoName { get { return _autoName; } set { if (Set(ref _autoName, value, "AutoName")) Notify("DisplayName"); } }
        public string CustomName
        {
            get { return _customName; }
            set { if (Set(ref _customName, value ?? "", "CustomName")) { Notify("DisplayName"); Notify("HasCustomName"); } }
        }
        public bool HasCustomName { get { return _customName.Length > 0; } }
        public string DisplayName { get { return _customName.Length > 0 ? _customName : _autoName; } }

        public string TypeKey { get { return _typeKey; } set { Set(ref _typeKey, value, "TypeKey"); } }
        public string TypeLabel { get { return _typeLabel; } set { Set(ref _typeLabel, value, "TypeLabel"); } }
        public string Glyph { get { return _glyph; } set { Set(ref _glyph, value, "Glyph"); } }
        public string TypeReason { get { return _typeReason; } set { Set(ref _typeReason, value, "TypeReason"); } }
        public bool IsCustomType { get { return _isCustomType; } set { Set(ref _isCustomType, value, "IsCustomType"); } }
        public string Details { get { return _details; } set { Set(ref _details, value, "Details"); } }
        public string Badge { get { return _badge; } set { Set(ref _badge, value, "Badge"); } }

        public bool IsOnline { get { return _isOnline; } set { Set(ref _isOnline, value, "IsOnline"); } }
        public string Status { get { return _status; } set { Set(ref _status, value, "Status"); } }
        public string LastSeen { get { return _lastSeen; } set { Set(ref _lastSeen, value, "LastSeen"); } }
        public bool IsRandomMac { get { return _isRandomMac; } set { Set(ref _isRandomMac, value, "IsRandomMac"); } }
        public bool IsGateway { get { return _isGateway; } set { Set(ref _isGateway, value, "IsGateway"); } }
        public bool IsSelf { get { return _isSelf; } set { Set(ref _isSelf, value, "IsSelf"); } }

        // Consumo: lo llena el modo de medición activo (por ahora ninguno mide por equipo)
        public string Download { get { return _download; } set { Set(ref _download, value, "Download"); } }
        public string Upload { get { return _upload; } set { Set(ref _upload, value, "Upload"); } }

        public object Record { get; set; }
    }

    // Un modo de medición de consumo, para mostrarlo en Ajustes
    public class ModeItem : Bindable
    {
        public string Id { get; set; }
        public string Name { get; set; }
        public string Description { get; set; }
        public string Scope { get; set; }
        public string Glyph { get; set; }
        public string Warning { get; set; }
        bool _available, _isActive, _isSelected;
        string _reason = "";
        public bool Available { get { return _available; } set { Set(ref _available, value, "Available"); } }
        public string Reason { get { return _reason; } set { Set(ref _reason, value, "Reason"); } }
        public bool IsActive { get { return _isActive; } set { Set(ref _isActive, value, "IsActive"); } }
        public bool IsSelected { get { return _isSelected; } set { Set(ref _isSelected, value, "IsSelected"); } }
    }

    // ---------------------------------------------------------------- Interceptar tráfico (modo avanzado)

    // Mide el consumo de CADA equipo poniéndose "en medio" con ARP, solo en la red propia del usuario.
    // Para no cortar internet, reenvía en modo usuario cada paquete a su destino real; al detenerse
    // restaura la tabla ARP de todos los equipos. Requiere Npcap y permisos de administrador.
    public class DeviceTarget
    {
        public string Ip;
        public byte[] IpBytes;
        public uint IpValue;
        public byte[] Mac;
        public string MacStr;
    }

    public class Interceptor
    {
        const int DLT_EN10MB = 1;

        [DllImport("wpcap.dll", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
        static extern IntPtr pcap_open_live(string device, int snaplen, int promisc, int to_ms, byte[] errbuf);
        [DllImport("wpcap.dll", CallingConvention = CallingConvention.Cdecl)]
        static extern int pcap_next_ex(IntPtr p, ref IntPtr header, ref IntPtr data);
        [DllImport("wpcap.dll", CallingConvention = CallingConvention.Cdecl)]
        static extern int pcap_sendpacket(IntPtr p, byte[] buf, int size);
        [DllImport("wpcap.dll", CallingConvention = CallingConvention.Cdecl)]
        static extern void pcap_close(IntPtr p);
        [DllImport("wpcap.dll", CallingConvention = CallingConvention.Cdecl)]
        static extern int pcap_datalink(IntPtr p);

        [StructLayout(LayoutKind.Sequential)]
        struct pcap_pkthdr { public int tv_sec; public int tv_usec; public uint caplen; public uint len; }

        IntPtr _pcap;
        byte[] _localMac, _localIp, _gatewayIp, _gatewayMac;
        uint _localIpValue;
        readonly List<DeviceTarget> _targets = new List<DeviceTarget>();
        readonly Dictionary<string, long[]> _counts = new Dictionary<string, long[]>(); // mac -> {bajada, subida}
        readonly object _lock = new object();
        volatile bool _stop;
        Thread _capture, _poison;
        string _error = "";

        public string Error { get { return _error; } }
        public int TargetCount { get { return _targets.Count; } }

        public static bool WpcapPresent()
        {
            try
            {
                string sys = Environment.GetFolderPath(Environment.SpecialFolder.System);
                return File.Exists(Path.Combine(sys, "Npcap\\wpcap.dll")) || File.Exists(Path.Combine(sys, "wpcap.dll"));
            }
            catch { return false; }
        }

        static byte[] MacBytes(string mac)
        {
            string hex = Regex.Replace(mac ?? "", "[^0-9A-Fa-f]", "");
            if (hex.Length != 12) return null;
            byte[] b = new byte[6];
            for (int i = 0; i < 6; i++) b[i] = Convert.ToByte(hex.Substring(i * 2, 2), 16);
            return b;
        }

        // devices: IP -> MAC de los equipos reales del escaneo (sin este PC, el router ni MAC compartidas)
        public bool Start(string deviceName, LocalNetwork net, string gatewayMac, Dictionary<string, string> devices)
        {
            try
            {
                _localMac = MacBytes(net.LocalMac);
                _gatewayMac = MacBytes(gatewayMac);
                if (string.IsNullOrEmpty(net.Gateway) || _localMac == null || _gatewayMac == null)
                { _error = "Faltan datos del router (no se pudo leer su dirección MAC). Escanea de nuevo."; return false; }
                _localIp = IPAddress.Parse(net.LocalIp).GetAddressBytes();
                _gatewayIp = IPAddress.Parse(net.Gateway).GetAddressBytes();
                _localIpValue = Net.ToUInt(net.LocalIp);
                foreach (KeyValuePair<string, string> d in devices)
                {
                    if (d.Key == net.LocalIp || d.Key == net.Gateway) continue;
                    byte[] mac = MacBytes(d.Value);
                    if (mac == null) continue;
                    DeviceTarget t = new DeviceTarget();
                    t.Ip = d.Key;
                    t.IpBytes = IPAddress.Parse(d.Key).GetAddressBytes();
                    t.IpValue = Net.ToUInt(d.Key);
                    t.Mac = mac;
                    t.MacStr = Net.FormatMac(d.Value);
                    _targets.Add(t);
                }
                if (_targets.Count == 0) { _error = "No hay equipos con MAC conocida para medir todavía."; return false; }

                byte[] errbuf = new byte[256];
                _pcap = pcap_open_live(deviceName, 65536, 1, 100, errbuf);
                if (_pcap == IntPtr.Zero) { _error = "No se pudo abrir la red con Npcap: " + Encoding.ASCII.GetString(errbuf).TrimEnd('\0'); return false; }
                if (pcap_datalink(_pcap) != DLT_EN10MB) { pcap_close(_pcap); _pcap = IntPtr.Zero; _error = "Esta red no es compatible con el modo avanzado."; return false; }

                _stop = false;
                _capture = new Thread(CaptureLoop); _capture.IsBackground = true; _capture.Start();
                _poison = new Thread(PoisonLoop); _poison.IsBackground = true; _poison.Start();
                return true;
            }
            catch (DllNotFoundException) { _error = "Falta Npcap (no se encontró wpcap.dll)."; return false; }
            catch (Exception ex) { _error = ex.Message; return false; }
        }

        public void Stop()
        {
            _stop = true;
            try { if (_poison != null) _poison.Join(2000); } catch { }
            try { if (_capture != null) _capture.Join(2000); } catch { }
            try { Restore(); } catch { }
            try { if (_pcap != IntPtr.Zero) pcap_close(_pcap); } catch { }
            _pcap = IntPtr.Zero;
        }

        public Dictionary<string, long[]> Snapshot()
        {
            lock (_lock)
            {
                Dictionary<string, long[]> copy = new Dictionary<string, long[]>();
                foreach (KeyValuePair<string, long[]> e in _counts) copy[e.Key] = new long[] { e.Value[0], e.Value[1] };
                return copy;
            }
        }

        void Add(string mac, long downBytes, long upBytes)
        {
            lock (_lock)
            {
                long[] c;
                if (!_counts.TryGetValue(mac, out c)) { c = new long[2]; _counts[mac] = c; }
                c[0] += downBytes; c[1] += upBytes;
            }
        }

        void CaptureLoop()
        {
            IntPtr header = IntPtr.Zero, data = IntPtr.Zero;
            while (!_stop)
            {
                int res;
                try { res = pcap_next_ex(_pcap, ref header, ref data); } catch { break; }
                if (res == 0) continue;   // se agotó el tiempo de espera, sin paquete
                if (res < 0) break;       // error de captura
                if (data == IntPtr.Zero) continue;
                pcap_pkthdr h = (pcap_pkthdr)Marshal.PtrToStructure(header, typeof(pcap_pkthdr));
                int len = (int)h.caplen;
                if (len < 34 || len > 65536) continue;   // Ethernet(14) + IPv4(20) mínimo
                byte[] pkt = new byte[len];
                Marshal.Copy(data, pkt, 0, len);
                try { Handle(pkt, len); } catch { }
            }
        }

        void Handle(byte[] pkt, int len)
        {
            // Solo nos interesa el IPv4 que nos llega por el envenenamiento ARP (destino = nuestra MAC)
            if (pkt[12] != 0x08 || pkt[13] != 0x00) return;
            for (int i = 0; i < 6; i++) if (pkt[i] != _localMac[i]) return;
            uint dstIp = (uint)((pkt[30] << 24) | (pkt[31] << 16) | (pkt[32] << 8) | pkt[33]);
            if (dstIp == _localIpValue) return;   // tráfico para este PC: lo mide el consumo de "este equipo"
            uint srcIp = (uint)((pkt[26] << 24) | (pkt[27] << 16) | (pkt[28] << 8) | pkt[29]);

            DeviceTarget dst = FindByIp(dstIp);
            DeviceTarget src = FindByIp(srcIp);
            byte[] nextHop;
            if (dst != null) { nextHop = dst.Mac; Add(dst.MacStr, len, 0); }       // baja hacia el equipo destino
            else if (src != null) { nextHop = _gatewayMac; Add(src.MacStr, 0, len); } // sube del equipo origen a internet
            else return;

            // Reenviar: MAC destino = salto real, MAC origen = nosotros, y reinyectar para no cortar la red
            for (int i = 0; i < 6; i++) { pkt[i] = nextHop[i]; pkt[6 + i] = _localMac[i]; }
            try { pcap_sendpacket(_pcap, pkt, len); } catch { }
        }

        DeviceTarget FindByIp(uint ip)
        {
            for (int i = 0; i < _targets.Count; i++) if (_targets[i].IpValue == ip) return _targets[i];
            return null;
        }

        void PoisonLoop()
        {
            while (!_stop)
            {
                foreach (DeviceTarget t in _targets)
                {
                    Send(ArpReply(t.Mac, _localMac, _gatewayIp, t.Mac, t.IpBytes));    // al equipo: "el router está en mi MAC"
                    Send(ArpReply(_gatewayMac, _localMac, t.IpBytes, _gatewayMac, _gatewayIp)); // al router: "el equipo está en mi MAC"
                    if (_stop) return;
                }
                for (int i = 0; i < 20 && !_stop; i++) Thread.Sleep(100);   // ~2 s
            }
        }

        void Restore()
        {
            // Avisa la verdad varias veces para que todos corrijan su tabla ARP al salir
            for (int round = 0; round < 5; round++)
            {
                foreach (DeviceTarget t in _targets)
                {
                    Send(ArpReply(t.Mac, _gatewayMac, _gatewayIp, t.Mac, t.IpBytes));
                    Send(ArpReply(_gatewayMac, t.Mac, t.IpBytes, _gatewayMac, _gatewayIp));
                }
                Thread.Sleep(120);
            }
        }

        void Send(byte[] frame) { try { if (_pcap != IntPtr.Zero) pcap_sendpacket(_pcap, frame, frame.Length); } catch { } }

        // Trama Ethernet con una respuesta ARP (op=2): "senderIp está en senderMac", dirigida a destMac
        byte[] ArpReply(byte[] destMac, byte[] senderMac, byte[] senderIp, byte[] targetMac, byte[] targetIp)
        {
            byte[] f = new byte[42];
            for (int i = 0; i < 6; i++) { f[i] = destMac[i]; f[6 + i] = senderMac[i]; }
            f[12] = 0x08; f[13] = 0x06;
            f[14] = 0x00; f[15] = 0x01;
            f[16] = 0x08; f[17] = 0x00;
            f[18] = 6; f[19] = 4; f[20] = 0x00; f[21] = 0x02;
            for (int i = 0; i < 6; i++) f[22 + i] = senderMac[i];
            for (int i = 0; i < 4; i++) f[28 + i] = senderIp[i];
            for (int i = 0; i < 6; i++) f[32 + i] = targetMac[i];
            for (int i = 0; i < 4; i++) f[38 + i] = targetIp[i];
            return f;
        }
    }

    public static class NativeMethods
    {
        [DllImport("user32.dll")]
        public static extern bool SetProcessDPIAware();
    }
}
'@

#endregion

#region Base de fabricantes por MAC

function Initialize-ScannerTypes {
    if (-not ('MonitorRed.ScanSession' -as [type])) {
        Add-Type -TypeDefinition $script:ScannerSource -Language CSharp -IgnoreWarnings -WarningAction SilentlyContinue
    }
}

# Carga la base desde: el .exe (incrustada) → junto al script → caché del usuario. Devuelve $true si quedó cargada.
function Import-OuiDatabase {
    if ([MonitorRed.OuiDatabase]::Count -gt 0) { return $true }
    try {
        if ($script:EmbeddedOui) {
            [MonitorRed.OuiDatabase]::LoadGzip([Convert]::FromBase64String($script:EmbeddedOui))
            return $true
        }
    } catch { }
    foreach ($path in @((Join-Path $script:ScriptDir $script:OuiFileName), (Join-Path $script:DataDir $script:OuiFileName))) {
        try {
            if (Test-Path -LiteralPath $path) {
                [MonitorRed.OuiDatabase]::LoadGzip([IO.File]::ReadAllBytes($path))
                if ([MonitorRed.OuiDatabase]::Count -gt 0) { return $true }
            }
        } catch { }
    }
    $false
}

function ConvertTo-GzipBytes([string]$Text) {
    $ms = New-Object IO.MemoryStream
    $gz = New-Object IO.Compression.GZipStream($ms, [IO.Compression.CompressionLevel]::Optimal)
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($Text)
    $gz.Write($bytes, 0, $bytes.Length)
    $gz.Dispose()
    $ms.ToArray()
}

# Descarga la base de la IEEE (o, si falla, la de Wireshark). Es un scriptblock para poder usarlo
# también en segundo plano desde la ventana. Devuelve @{ Kind = 'ieee' | 'manuf'; Text }.
$script:OuiDownloadScript = {
    param([string[]]$IeeeUrls, [string]$FallbackUrl, [string]$Agent)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    function Get-Text([string]$Url) {
        $wc = New-Object Net.WebClient
        $wc.Encoding = [Text.Encoding]::UTF8
        $wc.Headers['User-Agent'] = $Agent
        try { $wc.DownloadString($Url) } finally { $wc.Dispose() }
    }
    try {
        $parts = foreach ($u in $IeeeUrls) { Get-Text $u }
        return @{ Kind = 'ieee'; Text = ($parts -join "`n") }
    } catch {
        return @{ Kind = 'manuf'; Text = (Get-Text $FallbackUrl) }
    }
}

function ConvertTo-CompactOui([string]$Kind, [string]$Text) {
    if ($Kind -eq 'ieee') { [MonitorRed.OuiDatabase]::ConvertIeeeCsv($Text) } else { [MonitorRed.OuiDatabase]::ConvertManuf($Text) }
}

function Save-CompactOui([string]$Destination, [string]$Compact) {
    if ($Compact.Length -lt 100000) { throw 'La base de fabricantes descargada está incompleta.' }
    New-Item -ItemType Directory -Path (Split-Path $Destination -Parent) -Force | Out-Null
    [IO.File]::WriteAllBytes($Destination, (ConvertTo-GzipBytes $Compact))
    [MonitorRed.OuiDatabase]::Load($Compact)
}

# Genera fabricantes.gz (unos 600 KB). $SourcePath: oui.csv de la IEEE o manuf de Wireshark ya descargados.
function Save-OuiDatabase([string]$Destination, [string]$SourcePath) {
    if ($SourcePath) {
        $text = [IO.File]::ReadAllText($SourcePath, [Text.Encoding]::UTF8)
        $kind = if ($text.StartsWith('Registry,')) { 'ieee' } else { 'manuf' }
    } else {
        $r = & $script:OuiDownloadScript $script:OuiIeeeUrls $script:OuiFallbackUrl "Mozilla/5.0 (Windows NT 10.0; Win64; x64) MonitorRed/$script:AppVersion"
        $kind = $r.Kind
        $text = $r.Text
    }
    Save-CompactOui $Destination (ConvertTo-CompactOui $kind $text)
    $kind
}

#endregion

#region Modos de medición de consumo

# Cada modo es una "pieza" con la misma forma, para poder agregar o mejorar modos sin tocar el resto:
#   Id, Name, Description, Scope ('Por equipo' o 'Solo total'), Glyph, Warning
#   Priority          Orden en el modo Automático (menor = mejor). Los modos por equipo van antes que el total.
#   RequiresConsent   Si es $true, Automático solo lo usa cuando el usuario lo activó en Ajustes.
#   Implemented       $false mientras la medición en sí está en desarrollo (el modo igual informa si está disponible).
#   Test  { param($Ctx) }  → @{ Available = [bool]; Reason = 'texto para el usuario' }
#   Read  { param($Ctx) }  → lista de muestras @{ Key = <MAC o 'TOTAL'>; DownBytes; UpBytes } con los
#                            bytes acumulados (contadores); el bucle calcula la velocidad por la diferencia.
# $Ctx tiene: Network (LocalNetwork), Session (ScanSession), Settings, Devices, IsAdmin.
$script:MeasurementModes = @(
    @{
        Id = 'RouterApi'; Number = 1; Priority = 1; Name = 'API del router'; Scope = 'Por equipo'; Glyph = 0xE968
        Description = 'Entra al router con su usuario y clave de administrador y lee el consumo de cada equipo. Es el modo más exacto, pero depende de la marca del router.'
        Warning = ''; RequiresConsent = $false; Implemented = $false
        Test = { param($Ctx) Test-RouterApiMode $Ctx }
        Read = { param($Ctx) @() }
    }
    @{
        Id = 'Upnp'; Number = 2; Priority = 4; Name = 'Total por UPnP'; Scope = 'Solo total'; Glyph = 0xE774
        Description = 'Pregunta al router, por UPnP, cuántos datos pasan por internet. No necesita clave, pero solo da el total de la casa, no por equipo.'
        Warning = ''; RequiresConsent = $false; Implemented = $true
        Test = { param($Ctx) Test-UpnpMode $Ctx }
        Read = { param($Ctx) Read-UpnpTotal $Ctx }
    }
    @{
        Id = 'Intercept'; Number = 3; Priority = 3; Name = 'Interceptar el tráfico (avanzado)'; Scope = 'Por equipo'; Glyph = 0xE7BA
        Description = 'Esta PC se pone "en medio" entre los equipos y el router (ARP) para contar el tráfico de cada uno. Funciona con cualquier router.'
        Warning = 'Modo avanzado: puede hacer más lenta la red, algunos antivirus y routers lo bloquean, y solo debes usarlo en tu propia red. Necesita el controlador Npcap (gratis, en npcap.com) y abrir la app como administrador.'
        RequiresConsent = $true; Implemented = $true
        Test = { param($Ctx) Test-InterceptMode $Ctx }
        Read = { param($Ctx) @() }   # La captura la maneja la ventana (Start/Stop-InterceptCapture), como UPnP.
    }
    @{
        Id = 'Agent'; Number = 4; Priority = 2; Name = 'Agente en cada equipo'; Scope = 'Por equipo'; Glyph = 0xE8EA
        Description = 'Una pequeña app instalada en cada PC o teléfono informa su propio consumo. Es exacto y no depende del router, pero hay que instalarla en cada equipo.'
        Warning = ''; RequiresConsent = $false; Implemented = $false
        Test = { param($Ctx) Test-AgentMode $Ctx }
        Read = { param($Ctx) @() }
    }
)

if ($script:StoreEdition) { $script:MeasurementModes = @($script:MeasurementModes | Where-Object { $_.Id -ne 'Intercept' }) }

# Marcas de router con conector para el modo "API del router". Cada conector tendrá:
#   @{ Brand = 'TP-Link'; Match = 'tp-?link'; Login = { param($Url, $User, $Pass) }; ReadUsage = { param($Session) } }
$script:RouterConnectors = @()
$script:RouterBrandsPlanned = @('TP-Link', 'Huawei', 'ZTE', 'Xiaomi', 'ASUS', 'Netgear', 'MikroTik', 'Otra marca')

function Get-GatewayVendor($Ctx) {
    $gw = $null
    if ($Ctx.Devices) { $gw = @($Ctx.Devices | Where-Object { $_.IsGateway })[0] }
    if ($gw -and $gw.Vendor) { return $gw.Vendor }
    ''
}

function Test-RouterApiMode($Ctx) {
    $brand = [string]$Ctx.Settings.RouterBrand
    $vendor = Get-GatewayVendor $Ctx
    $hint = if ($vendor) { " Tu router parece ser $vendor." } else { '' }
    if (-not $brand) { return @{ Available = $false; Reason = "Elige la marca del router y escribe su clave en la sección de abajo.$hint" } }
    $connector = $script:RouterConnectors | Where-Object { $_.Brand -eq $brand } | Select-Object -First 1
    if (-not $connector) { return @{ Available = $false; Reason = "Todavía no hay conector para routers $brand (próximamente).$hint" } }
    if (-not $Ctx.Settings.RouterPassword) { return @{ Available = $false; Reason = 'Falta la clave del router.' } }
    @{ Available = $true; Reason = "Conector $brand configurado." }
}

function Test-UpnpMode($Ctx) {
    $igd = @()
    if ($Ctx.Session) { $igd = @($Ctx.Session.InternetGateways) }
    if ($igd.Count -gt 0) {
        $name = $igd[0].FriendlyName
        if (-not $name) { $name = $igd[0].ModelName }
        return @{ Available = $true; Reason = "El router ($name) informa el tráfico total por UPnP." }
    }
    if (-not $Ctx.Session -or -not $Ctx.Session.IsCompleted) { return @{ Available = $false; Reason = 'Se sabrá al terminar el escaneo.' } }
    @{ Available = $false; Reason = 'El router no respondió por UPnP (puede estar desactivado en su configuración).' }
}

# Lee del router los bytes totales que han pasado por internet (bajada y subida de toda la casa).
function Read-UpnpTotal($Ctx) {
    $igd = @($Ctx.Session.InternetGateways) | Where-Object { $_.WanControlUrl } | Select-Object -First 1
    if (-not $igd) { return @() }
    $down = [MonitorRed.Upnp]::GetTotalBytes($igd.WanControlUrl, $igd.WanServiceType, $true, 4000)
    $up = [MonitorRed.Upnp]::GetTotalBytes($igd.WanControlUrl, $igd.WanServiceType, $false, 4000)
    if ($down -lt 0 -and $up -lt 0) { return @() }
    @(@{ Key = 'TOTAL'; DownBytes = $down; UpBytes = $up })
}

function Test-NpcapInstalled {
    if (-not $env:SystemRoot) { return $false }
    (Test-Path (Join-Path $env:SystemRoot 'System32\Npcap\wpcap.dll')) -or [bool](Get-Service -Name npcap -ErrorAction SilentlyContinue)
}

function Test-InterceptMode($Ctx) {
    if (-not $Ctx.Settings.InterceptConsent) { return @{ Available = $false; Reason = 'Desactivado. Actívalo en Ajustes si entiendes los riesgos.' } }
    # Muestra TODO lo que falta a la vez (no solo lo primero), para que el usuario lo vea de un vistazo.
    $missing = @()
    if (-not (Test-NpcapInstalled)) { $missing += 'instalar Npcap (gratis, desde npcap.com)' }
    if (-not $Ctx.IsAdmin) { $missing += 'abrir la app como administrador' }
    if ($missing.Count -gt 0) { return @{ Available = $false; Reason = "Falta $($missing -join ' y ') para medir el consumo por equipo." } }
    @{ Available = $true; Reason = 'Listo para interceptar el tráfico.' }
}

function Test-AgentMode($Ctx) {
    # Los agentes se anunciarán en la red por mDNS (_monitorred._tcp). Aún no hay agentes publicados.
    @{ Available = $false; Reason = 'No se encontró ningún agente en la red. El agente para PC y teléfono está en desarrollo.' }
}

function Test-IsAdmin {
    try {
        $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { $false }
}

# Evalúa todos los modos y elige el que se usa: el elegido en Ajustes, o el mejor disponible en Automático.
function Get-MeasurementState($Ctx) {
    $results = @()
    foreach ($m in $script:MeasurementModes) {
        $r = $null
        try { $r = & $m.Test $Ctx } catch { $r = @{ Available = $false; Reason = $_.Exception.Message } }
        $results += [pscustomobject]@{ Mode = $m; Available = [bool]$r.Available; Reason = [string]$r.Reason }
    }
    $wanted = [string]$Ctx.Settings.MeasurementMode
    $active = $null
    if ($wanted -and $wanted -ne 'Auto') {
        $active = $results | Where-Object { $_.Mode.Id -eq $wanted -and $_.Available } | Select-Object -First 1
    } else {
        $active = $results | Where-Object { $_.Available -and (-not $_.Mode.RequiresConsent -or $Ctx.Settings.InterceptConsent) } |
            Sort-Object { $_.Mode.Priority } | Select-Object -First 1
    }
    [pscustomobject]@{ Results = $results; Active = $active; Wanted = $wanted }
}

function Get-MeasurementSummary($State) {
    $prefix = if ($State.Wanted -and $State.Wanted -ne 'Auto') { 'Modo de medición' } else { 'Modo de medición automático' }
    if (-not $State.Active) {
        if ($State.Wanted -and $State.Wanted -ne 'Auto') {
            $chosen = $State.Results | Where-Object { $_.Mode.Id -eq $State.Wanted } | Select-Object -First 1
            if ($chosen) { return "${prefix}: $($chosen.Mode.Name) no está disponible. $($chosen.Reason)" }
        }
        return "${prefix}: ningún modo disponible todavía. El consumo por equipo se mostrará cuando haya uno (ver Ajustes)."
    }
    $m = $State.Active.Mode
    $suffix = if ($m.Implemented) { '' } else { ' La medición de este modo está en desarrollo.' }
    "${prefix}: $($m.Name) ($($m.Scope.ToLower())).$suffix"
}

# "1,2 MB/s", "340 KB/s"... para una velocidad en bytes por segundo
function Format-Rate([double]$BytesPerSec) {
    if ($BytesPerSec -lt 0) { return '—' }
    if ($BytesPerSec -lt 1024) { return '{0:0} B/s' -f $BytesPerSec }
    $kb = $BytesPerSec / 1024
    if ($kb -lt 1000) { return '{0:0} KB/s' -f $kb }
    $mb = $kb / 1024
    if ($mb -lt 1000) { return '{0:0.0} MB/s' -f $mb }
    '{0:0.0} GB/s' -f ($mb / 1024)
}

# "4,7 GB", "812 MB"... para una cantidad total de bytes
function Format-Bytes([double]$Bytes) {
    if ($Bytes -lt 0) { return '—' }
    $u = 'B', 'KB', 'MB', 'GB', 'TB'
    $i = 0
    while ($Bytes -ge 1024 -and $i -lt $u.Count - 1) { $Bytes /= 1024; $i++ }
    $fmt = if ($i -eq 0) { '{0:0} {1}' } else { '{0:0.0} {1}' }
    $fmt -f $Bytes, $u[$i]
}

# Velocidad entre dos lecturas del mismo contador de bytes. Si el contador bajó (el equipo o el router
# se reinició, o el contador de 32 bits dio la vuelta), se devuelve -1 para volver a tomar la referencia:
# así se evita mostrar un pico falso; solo se pierde una lectura.
function Get-RateBps([double]$PrevBytes, [double]$NowBytes, [double]$Seconds) {
    if ($Seconds -le 0 -or $PrevBytes -lt 0 -or $NowBytes -lt 0) { return -1 }
    $delta = $NowBytes - $PrevBytes
    if ($delta -lt 0) { return -1 }
    $delta / $Seconds
}

# Bytes que han pasado por la tarjeta de red de ESTE equipo (siempre disponible, sin depender del router)
function Get-SelfTrafficBytes($Network) {
    try {
        foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($ni.OperationalStatus -ne 'Up') { continue }
            $match = $false
            foreach ($ua in $ni.GetIPProperties().UnicastAddresses) {
                if ($ua.Address.ToString() -eq $Network.LocalIp) { $match = $true; break }
            }
            if (-not $match) { continue }
            $s = $ni.GetIPStatistics()
            return @{ DownBytes = [double]$s.BytesReceived; UpBytes = [double]$s.BytesSent }
        }
    } catch { }
    $null
}

#endregion

#region Escaneo sin ventana (línea de comandos)

function Get-ScanContext($Network, $Session, $Devices) {
    @{ Network = $Network; Session = $Session; Settings = $script:Settings; Devices = $Devices; IsAdmin = (Test-IsAdmin) }
}

function Test-IsLaptop {
    try { return [bool](Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop) } catch { $false }
}

# Convierte lo averiguado de una IP en los datos que se muestran (sin ventana)
function ConvertTo-DeviceRow($Record, [bool]$IsLaptopSelf) {
    $f = Get-DeviceFacts $Record $IsLaptopSelf
    $known = $script:Known[$f.Key]
    $type = $f.Guess.Type
    $name = $f.AutoName
    if ($known) {
        if ($known.Type) { $type = $known.Type }
        if ($known.Name) { $name = $known.Name }
    }
    [pscustomobject]@{
        Nombre     = $name
        Tipo       = (Get-DeviceType $type).Label
        IP         = $Record.Ip
        MAC        = $Record.Mac
        Fabricante = if ($f.Vendor) { $f.Vendor } elseif ($f.IsRandomMac) { '(MAC privada)' } else { '' }
        Host       = $f.HostName
        Modelo     = if ($f.Upnp) { (@($f.Upnp.Manufacturer, $f.Upnp.ModelName) | Where-Object { $_ }) -join ' ' } else { '' }
        Ping       = if ($Record.PingMs -ge 0) { "$($Record.PingMs) ms" } else { '' }
        Motivo     = $f.Guess.Reason
        IpValue    = $Record.IpValue
    }
}

function Invoke-ConsoleScan {
    Initialize-ScannerTypes
    Import-AppData
    if (-not (Import-OuiDatabase)) {
        try { [void](Save-OuiDatabase (Join-Path $script:DataDir $script:OuiFileName)) } catch { Write-Warning "No se pudo descargar la base de fabricantes: $($_.Exception.Message)" }
    }
    $net = [MonitorRed.Net]::GetLocalNetworks() | Select-Object -First 1
    if (-not $net) { throw 'Este equipo no está conectado a ninguna red.' }
    Write-Host "Escaneando $($net.Summary) (este equipo: $($net.LocalIp), router: $($net.Gateway))..." -ForegroundColor Cyan
    $session = New-Object MonitorRed.ScanSession($net)
    $session.Start()
    while (-not $session.IsCompleted) {
        Write-Progress -Activity $script:AppName -Status $session.Phase -PercentComplete $session.Percent
        Start-Sleep -Milliseconds 200
    }
    Write-Progress -Activity $script:AppName -Completed
    if ($session.Error) { throw $session.Error }
    $laptop = Test-IsLaptop
    $rows = @($session.GetAll() | ForEach-Object { ConvertTo-DeviceRow $_ $laptop } | Sort-Object IpValue)
    $state = Get-MeasurementState (Get-ScanContext $net $session @())
    if ($Json) {
        [pscustomobject]@{
            Red = $net.Summary; EsteEquipo = $net.LocalIp; Router = $net.Gateway; FabricantesCargados = [MonitorRed.OuiDatabase]::Count
            Equipos = @($rows | Select-Object * -ExcludeProperty IpValue)
            Medicion = @($state.Results | ForEach-Object { [pscustomobject]@{ Modo = $_.Mode.Id; Disponible = $_.Available; Detalle = $_.Reason } })
            ModoActivo = if ($state.Active) { $state.Active.Mode.Id } else { '' }
        } | ConvertTo-Json -Depth 5
    } else {
        $rows | Format-Table Nombre, Tipo, IP, MAC, Fabricante, Host, Ping -AutoSize | Out-String -Width 220 | Write-Host
        Write-Host "$($rows.Count) equipos encontrados." -ForegroundColor Green
        Write-Host (Get-MeasurementSummary $state)
    }
}

#endregion

#region Interfaz gráfica (WPF)

$script:Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Monitor de Red" Width="1220" Height="860" MinWidth="980" MinHeight="680"
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

    <Style x:Key="Label" TargetType="TextBlock">
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,12,0,4"/>
    </Style>

    <Style x:Key="Pill" TargetType="Border">
      <Setter Property="Background" Value="#F0F0F0"/>
      <Setter Property="CornerRadius" Value="9"/>
      <Setter Property="Padding" Value="8,1"/>
      <Setter Property="Margin" Value="8,0,0,0"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>

    <Style x:Key="PrimaryButton" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Background" Value="{StaticResource Accent}"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="18,8"/>
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

    <Style x:Key="LinkButton" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource Accent}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <TextBlock x:Name="Tx" Text="{Binding Content, RelativeSource={RelativeSource TemplatedParent}}" Foreground="{TemplateBinding Foreground}"/>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Tx" Property="TextDecorations" Value="Underline"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <DataTemplate x:Key="DeviceCell">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Border x:Name="Tile" Width="36" Height="36" CornerRadius="8" Background="#EEF4FB" Margin="0,0,12,0">
          <TextBlock x:Name="Gl" Style="{StaticResource Icon}" Text="{Binding Glyph}" FontSize="17" Foreground="{StaticResource Accent}"/>
        </Border>
        <StackPanel Grid.Column="1" VerticalAlignment="Center">
          <TextBlock Text="{Binding DisplayName}" FontWeight="SemiBold" TextTrimming="CharacterEllipsis" ToolTip="{Binding DisplayName}"/>
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="{Binding TypeLabel}" FontSize="12" Foreground="{StaticResource TextSecondary}" VerticalAlignment="Center"/>
            <Border x:Name="BadgeBox" Style="{StaticResource Pill}" Background="{StaticResource AccentLight}" Padding="7,0">
              <TextBlock Text="{Binding Badge}" FontSize="11" FontWeight="SemiBold" Foreground="{StaticResource Accent}"/>
            </Border>
          </StackPanel>
        </StackPanel>
      </Grid>
      <DataTemplate.Triggers>
        <DataTrigger Binding="{Binding Badge}" Value="">
          <Setter TargetName="BadgeBox" Property="Visibility" Value="Collapsed"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding IsOnline}" Value="False">
          <Setter TargetName="Tile" Property="Background" Value="#F2F2F2"/>
          <Setter TargetName="Gl" Property="Foreground" Value="#8A8A8A"/>
        </DataTrigger>
      </DataTemplate.Triggers>
    </DataTemplate>

    <DataTemplate x:Key="StatusCell">
      <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
        <Ellipse x:Name="Dot" Width="8" Height="8" Fill="#0F7B0F" Margin="0,0,8,0" VerticalAlignment="Center"/>
        <TextBlock x:Name="St" Text="{Binding Status}" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
      </StackPanel>
      <DataTemplate.Triggers>
        <DataTrigger Binding="{Binding IsOnline}" Value="False">
          <Setter TargetName="Dot" Property="Fill" Value="#BDBDBD"/>
          <Setter TargetName="St" Property="Foreground" Value="#8A8A8A"/>
        </DataTrigger>
      </DataTemplate.Triggers>
    </DataTemplate>

    <DataTemplate x:Key="ModeTemplate">
      <Border Style="{StaticResource Card}" Margin="0,0,0,10" Padding="14,12">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <RadioButton GroupName="MeasureMode" IsChecked="{Binding IsSelected, Mode=TwoWay}" Tag="{Binding Id}"
                       VerticalAlignment="Top" Margin="0,10,12,0"/>
          <Border Grid.Column="1" Width="38" Height="38" CornerRadius="8" Background="#EEF4FB" VerticalAlignment="Top">
            <TextBlock Style="{StaticResource Icon}" Text="{Binding Glyph}" FontSize="17" Foreground="{StaticResource Accent}"/>
          </Border>
          <StackPanel Grid.Column="2" Margin="12,0,0,0">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="{Binding Name}" FontWeight="SemiBold" FontSize="14"/>
              <Border Style="{StaticResource Pill}">
                <TextBlock Text="{Binding Scope}" FontSize="11" Foreground="{StaticResource TextSecondary}"/>
              </Border>
              <Border x:Name="ActivePill" Style="{StaticResource Pill}" Background="{StaticResource GreenLight}" Visibility="Collapsed">
                <TextBlock Text="En uso" FontSize="11" FontWeight="SemiBold" Foreground="{StaticResource Green}"/>
              </Border>
            </StackPanel>
            <TextBlock Text="{Binding Description}" TextWrapping="Wrap" Foreground="{StaticResource TextSecondary}" Margin="0,3,0,0"/>
            <StackPanel Orientation="Horizontal" Margin="0,6,0,0">
              <TextBlock x:Name="StIcon" Style="{StaticResource Icon}" Text="&#xE711;" Foreground="#8A8A8A" FontSize="12" Margin="0,0,6,0"/>
              <TextBlock x:Name="StText" Text="{Binding Reason}" TextWrapping="Wrap" Foreground="#5F5F5F" MaxWidth="720"/>
            </StackPanel>
            <TextBlock x:Name="Warn" Text="{Binding Warning}" TextWrapping="Wrap" Foreground="#9D5D00" Margin="0,6,0,0"/>
          </StackPanel>
        </Grid>
      </Border>
      <DataTemplate.Triggers>
        <DataTrigger Binding="{Binding Available}" Value="True">
          <Setter TargetName="StIcon" Property="Text" Value="&#xE73E;"/>
          <Setter TargetName="StIcon" Property="Foreground" Value="#0F7B0F"/>
          <Setter TargetName="StText" Property="Foreground" Value="#0F7B0F"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding IsActive}" Value="True">
          <Setter TargetName="ActivePill" Property="Visibility" Value="Visible"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding Warning}" Value="">
          <Setter TargetName="Warn" Property="Visibility" Value="Collapsed"/>
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
      <Setter Property="RowHeight" Value="52"/>
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
      <Setter Property="Height" Value="34"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="PasswordBox">
      <Setter Property="BorderBrush" Value="#D1D1D1"/>
      <Setter Property="Padding" Value="8,0"/>
      <Setter Property="Height" Value="34"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Height" Value="34"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Padding" Value="8,0"/>
    </Style>
  </Window.Resources>

  <Grid Background="#F3F3F3">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- ===== Encabezado ===== -->
    <Grid Grid.Row="0" Margin="28,20,28,12">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <Button x:Name="BtnBack" Style="{StaticResource SubtleButton}" Width="40" Height="40" Padding="0"
              Margin="0,0,14,0" VerticalAlignment="Center" Visibility="Collapsed" ToolTip="Volver a la lista de equipos">
        <TextBlock Style="{StaticResource Icon}" Text="&#xE72B;" FontSize="16"/>
      </Button>
      <Border Grid.Column="1" Width="46" Height="46" CornerRadius="10" Background="{StaticResource Accent}" Margin="0,0,14,0">
        <TextBlock Style="{StaticResource Icon}" Text="&#xE968;" FontSize="22" Foreground="White"/>
      </Border>
      <StackPanel Grid.Column="2" VerticalAlignment="Center" Margin="0,0,16,0">
        <TextBlock x:Name="TxtTitle" Text="Monitor de Red" FontSize="24" FontWeight="SemiBold"
                   FontFamily="Segoe UI Variable Display, Segoe UI"/>
        <TextBlock x:Name="TxtSubtitle" Foreground="{StaticResource TextSecondary}" Margin="0,2,0,0" TextTrimming="CharacterEllipsis"
                   Text="Buscando la red..."/>
      </StackPanel>
      <ComboBox x:Name="CbNetwork" Grid.Column="3" Width="260" Margin="0,0,10,0" VerticalAlignment="Center"
                Visibility="Collapsed" ToolTip="Este equipo está conectado a más de una red: elige cuál escanear"/>
      <Button x:Name="BtnScan" Grid.Column="4" Style="{StaticResource PrimaryButton}" Margin="0,0,10,0" VerticalAlignment="Center">
        <StackPanel Orientation="Horizontal">
          <TextBlock Style="{StaticResource Icon}" Text="&#xE72C;" Margin="0,0,8,0" Foreground="White"/>
          <TextBlock x:Name="BtnScanText" Text="Escanear de nuevo"/>
        </StackPanel>
      </Button>
      <Button x:Name="BtnSettings" Grid.Column="5" Style="{StaticResource SubtleButton}" Padding="12,8" VerticalAlignment="Center" ToolTip="Ajustes y modos de medición">
        <StackPanel Orientation="Horizontal">
          <TextBlock Style="{StaticResource Icon}" Text="&#xE713;" Margin="0,0,8,0"/>
          <TextBlock Text="Ajustes"/>
        </StackPanel>
      </Button>
      <Button x:Name="BtnSupport" Grid.Column="6" Style="{StaticResource SubtleButton}" Padding="12,8" Margin="10,0,0,0"
              VerticalAlignment="Center" Visibility="Collapsed" ToolTip="Abre la página de apoyo en tu navegador">
        <StackPanel Orientation="Horizontal">
          <TextBlock Style="{StaticResource Icon}" Text="&#xEB52;" Foreground="#FF5E5B" Margin="0,0,8,0"/>
          <TextBlock Text="Apoyar a la app" FontWeight="SemiBold"/>
        </StackPanel>
      </Button>
    </Grid>

    <!-- ===== Estado del escaneo y de la medición ===== -->
    <Border Grid.Row="1" Style="{StaticResource Card}" Margin="28,0,28,12" Padding="16,10">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal">
          <TextBlock x:Name="StatusIcon" Style="{StaticResource Icon}" Text="&#xE721;" Foreground="{StaticResource Accent}" Margin="0,0,10,0"/>
          <TextBlock x:Name="TxtStatus" Text="Preparando..." VerticalAlignment="Center"/>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal">
          <TextBlock x:Name="TxtOnline" Text="0" FontWeight="SemiBold" FontSize="15" VerticalAlignment="Center"/>
          <TextBlock x:Name="TxtOnlineLabel" Text=" equipos en línea" Foreground="{StaticResource TextSecondary}" VerticalAlignment="Center"/>
        </StackPanel>
        <ProgressBar x:Name="ScanProgress" Grid.Row="1" Grid.ColumnSpan="2" Height="4" Margin="0,8,0,0" Minimum="0" Maximum="100"
                     Foreground="{StaticResource Accent}" Background="#EDEDED" BorderThickness="0"/>
        <Grid Grid.Row="2" Grid.ColumnSpan="2" Margin="0,8,0,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <StackPanel Orientation="Horizontal">
            <TextBlock Style="{StaticResource Icon}" Text="&#xE9D9;" Foreground="{StaticResource TextSecondary}" Margin="0,0,10,0"/>
            <TextBlock x:Name="TxtMeasure" Foreground="{StaticResource TextSecondary}" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" MaxWidth="760"/>
            <Button x:Name="BtnMeasureSettings" Style="{StaticResource LinkButton}" Content="Cambiar" Margin="10,0,0,0" VerticalAlignment="Center"/>
          </StackPanel>
          <StackPanel x:Name="TotalRatePanel" Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center" Visibility="Collapsed">
            <TextBlock Text="Toda la casa:" Foreground="{StaticResource TextSecondary}" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <TextBlock Style="{StaticResource Icon}" Text="&#xE74B;" Foreground="{StaticResource Accent}" FontSize="12" Margin="0,0,3,0"/>
            <TextBlock x:Name="TxtTotalDown" Text="—" FontWeight="SemiBold" VerticalAlignment="Center" Margin="0,0,12,0"/>
            <TextBlock Style="{StaticResource Icon}" Text="&#xE74A;" Foreground="{StaticResource Green}" FontSize="12" Margin="0,0,3,0"/>
            <TextBlock x:Name="TxtTotalUp" Text="—" FontWeight="SemiBold" VerticalAlignment="Center"/>
          </StackPanel>
        </Grid>
      </Grid>
    </Border>

    <!-- ===== Lista de equipos ===== -->
    <Grid x:Name="PageDevices" Grid.Row="2" Margin="28,0,28,24">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="340"/>
      </Grid.ColumnDefinitions>

      <Border Style="{StaticResource Card}" Padding="0">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <Grid Margin="14,12,14,8">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Grid>
              <TextBox x:Name="TxtSearch" Padding="30,0,8,0"/>
              <TextBlock Style="{StaticResource Icon}" Text="&#xE721;" HorizontalAlignment="Left" Margin="10,0,0,0" Foreground="#8A8A8A" IsHitTestVisible="False"/>
              <TextBlock Text="Buscar por nombre, IP, MAC o fabricante" Margin="31,0,0,0" VerticalAlignment="Center" Foreground="#8A8A8A" IsHitTestVisible="False">
                <TextBlock.Style>
                  <Style TargetType="TextBlock">
                    <Setter Property="Visibility" Value="Collapsed"/>
                    <Style.Triggers>
                      <DataTrigger Binding="{Binding Text, ElementName=TxtSearch}" Value="">
                        <Setter Property="Visibility" Value="Visible"/>
                      </DataTrigger>
                    </Style.Triggers>
                  </Style>
                </TextBlock.Style>
              </TextBlock>
            </Grid>
            <ComboBox x:Name="CbTypeFilter" Grid.Column="1" Width="190" Margin="10,0,0,0"/>
            <CheckBox x:Name="ChkOffline" Grid.Column="2" Content="Mostrar desconectados" VerticalAlignment="Center" Margin="14,0,0,0"/>
            <Button x:Name="BtnExport" Grid.Column="3" Style="{StaticResource SubtleButton}" Margin="14,0,0,0" ToolTip="Guarda la lista que se ve en un archivo que abre Excel">
              <StackPanel Orientation="Horizontal">
                <TextBlock Style="{StaticResource Icon}" Text="&#xE896;" Margin="0,0,8,0"/>
                <TextBlock Text="Exportar a Excel"/>
              </StackPanel>
            </Button>
          </Grid>
          <DataGrid x:Name="DeviceGrid" Grid.Row="1" Margin="4,0,4,4">
            <DataGrid.Columns>
              <DataGridTemplateColumn Header="Equipo" CellTemplate="{StaticResource DeviceCell}" Width="2.2*" SortMemberPath="DisplayName"/>
              <DataGridTextColumn Header="IP" Binding="{Binding Ip}" Width="112" SortMemberPath="IpValue"/>
              <DataGridTextColumn Header="MAC" Binding="{Binding Mac}" Width="140" FontFamily="Consolas"/>
              <DataGridTextColumn Header="Fabricante" Binding="{Binding Vendor}" Width="1.2*"/>
              <DataGridTemplateColumn Header="Estado" CellTemplate="{StaticResource StatusCell}" Width="1.1*" SortMemberPath="IsOnline"/>
              <DataGridTextColumn Header="Bajada" Binding="{Binding Download}" Width="72">
                <DataGridTextColumn.ElementStyle>
                  <Style TargetType="TextBlock">
                    <Setter Property="ToolTip" Value="Datos que baja de internet. El consumo de esta PC y el total de la casa (arriba) se muestran siempre; para el consumo de los demás equipos hace falta un modo que mida por equipo (ver Ajustes)."/>
                  </Style>
                </DataGridTextColumn.ElementStyle>
              </DataGridTextColumn>
              <DataGridTextColumn Header="Subida" Binding="{Binding Upload}" Width="72">
                <DataGridTextColumn.ElementStyle>
                  <Style TargetType="TextBlock">
                    <Setter Property="ToolTip" Value="Datos que sube a internet. El consumo de esta PC y el total de la casa (arriba) se muestran siempre; para el consumo de los demás equipos hace falta un modo que mida por equipo (ver Ajustes)."/>
                  </Style>
                </DataGridTextColumn.ElementStyle>
              </DataGridTextColumn>
            </DataGrid.Columns>
          </DataGrid>
          <TextBlock x:Name="TxtEmpty" Grid.Row="1" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="{StaticResource TextSecondary}"
                     Text="Buscando equipos en la red..." Visibility="Collapsed"/>
        </Grid>
      </Border>

      <!-- Detalle del equipo elegido -->
      <Border Grid.Column="1" Style="{StaticResource Card}" Margin="12,0,0,0" Padding="18">
        <Grid>
          <TextBlock x:Name="DetailEmpty" TextWrapping="Wrap" Foreground="{StaticResource TextSecondary}" TextAlignment="Center" VerticalAlignment="Center"
                     Text="Elige un equipo de la lista para ver sus datos y ponerle un nombre."/>
          <ScrollViewer x:Name="DetailPanel" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
            <StackPanel>
              <StackPanel Orientation="Horizontal">
                <Border Width="52" Height="52" CornerRadius="12" Background="#EEF4FB">
                  <TextBlock x:Name="DetGlyph" Style="{StaticResource Icon}" FontSize="24" Foreground="{StaticResource Accent}"/>
                </Border>
                <StackPanel Margin="14,0,0,0" VerticalAlignment="Center" MaxWidth="220">
                  <TextBlock x:Name="DetTitle" FontSize="17" FontWeight="SemiBold" TextWrapping="Wrap"/>
                  <TextBlock x:Name="DetSubtitle" Foreground="{StaticResource TextSecondary}" TextWrapping="Wrap"/>
                </StackPanel>
              </StackPanel>

              <TextBlock Style="{StaticResource Label}" Text="Nombre"/>
              <TextBox x:Name="TxtName" ToolTip="Ponle un nombre fácil de reconocer, por ejemplo «TV del living»"/>
              <TextBlock Style="{StaticResource Label}" Text="Tipo de equipo"/>
              <ComboBox x:Name="CbType"/>
              <TextBlock x:Name="DetReason" TextWrapping="Wrap" FontSize="12" Foreground="{StaticResource TextSecondary}" Margin="0,6,0,0"/>
              <StackPanel Orientation="Horizontal" Margin="0,14,0,0">
                <Button x:Name="BtnSaveDevice" Style="{StaticResource PrimaryButton}" Content="Guardar"/>
                <Button x:Name="BtnResetDevice" Style="{StaticResource SubtleButton}" Content="Restablecer" Margin="8,0,0,0"
                        ToolTip="Vuelve al nombre y tipo detectados automáticamente"/>
              </StackPanel>

              <Border Height="1" Background="{StaticResource CardBorder}" Margin="0,18,0,12"/>
              <TextBlock Text="Datos del equipo" FontWeight="SemiBold" Margin="0,0,0,6"/>
              <TextBlock x:Name="DetDetails" TextWrapping="Wrap" LineHeight="21"/>
            </StackPanel>
          </ScrollViewer>
        </Grid>
      </Border>
    </Grid>

    <!-- ===== Ajustes ===== -->
    <ScrollViewer x:Name="PageSettings" Grid.Row="2" Margin="28,0,12,24" Padding="0,0,16,0" VerticalScrollBarVisibility="Auto" Visibility="Collapsed">
      <StackPanel MaxWidth="980" HorizontalAlignment="Left">
        <TextBlock Text="Modo de medición del consumo" FontSize="18" FontWeight="SemiBold" Margin="2,0,0,4"/>
        <TextBlock TextWrapping="Wrap" Foreground="{StaticResource TextSecondary}" Margin="2,0,0,12"
                   Text="Cada router es distinto, por eso la app tiene varias formas de medir cuántos datos usa cada equipo. Al abrirse revisa cuáles funcionan en tu red."/>

        <Border Style="{StaticResource Card}" Margin="0,0,0,10" Padding="14,12">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <RadioButton x:Name="RbAuto" GroupName="MeasureMode" Tag="Auto" VerticalAlignment="Top" Margin="0,10,12,0"/>
            <Border Grid.Column="1" Width="38" Height="38" CornerRadius="8" Background="{StaticResource Accent}" VerticalAlignment="Top">
              <TextBlock Style="{StaticResource Icon}" Text="&#xE945;" FontSize="17" Foreground="White"/>
            </Border>
            <StackPanel Grid.Column="2" Margin="12,0,0,0">
              <TextBlock Text="Automático (recomendado)" FontWeight="SemiBold" FontSize="14"/>
              <TextBlock x:Name="TxtAutoDesc" TextWrapping="Wrap" Foreground="{StaticResource TextSecondary}" Margin="0,3,0,0"/>
              <TextBlock x:Name="TxtAutoResult" TextWrapping="Wrap" Margin="0,6,0,0" Foreground="#5F5F5F"/>
            </StackPanel>
          </Grid>
        </Border>

        <ItemsControl x:Name="ModeList" ItemTemplate="{StaticResource ModeTemplate}"/>

        <TextBlock Text="Datos del router (modo 1)" FontSize="18" FontWeight="SemiBold" Margin="2,14,0,8"/>
        <Border Style="{StaticResource Card}">
          <StackPanel>
            <TextBlock x:Name="TxtRouterHint" TextWrapping="Wrap" Foreground="{StaticResource TextSecondary}"/>
            <Grid Margin="0,4,0,0">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="16"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="16"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <StackPanel>
                <TextBlock Style="{StaticResource Label}" Text="Marca del router"/>
                <ComboBox x:Name="CbRouterBrand"/>
              </StackPanel>
              <StackPanel Grid.Column="2">
                <TextBlock Style="{StaticResource Label}" Text="Usuario"/>
                <TextBox x:Name="TxtRouterUser"/>
              </StackPanel>
              <StackPanel Grid.Column="4">
                <TextBlock Style="{StaticResource Label}" Text="Clave"/>
                <PasswordBox x:Name="PwdRouter"/>
              </StackPanel>
            </Grid>
            <StackPanel Orientation="Horizontal" Margin="0,14,0,0">
              <Button x:Name="BtnSaveRouter" Style="{StaticResource PrimaryButton}" Content="Guardar datos del router"/>
              <TextBlock x:Name="TxtRouterSaved" VerticalAlignment="Center" Margin="12,0,0,0" Foreground="{StaticResource Green}"/>
            </StackPanel>
            <TextBlock TextWrapping="Wrap" FontSize="12" Foreground="{StaticResource TextSecondary}" Margin="0,10,0,0"
                       Text="La clave se guarda cifrada en este equipo (solo tu usuario de Windows puede leerla) y nunca sale de tu red."/>
          </StackPanel>
        </Border>

        <StackPanel x:Name="InterceptSection">
        <TextBlock Text="Modo avanzado (modo 3)" FontSize="18" FontWeight="SemiBold" Margin="2,18,0,8"/>
        <Border Background="#FFF4CE" BorderBrush="#F2D88F" BorderThickness="1" CornerRadius="8" Padding="16">
          <StackPanel>
            <StackPanel Orientation="Horizontal">
              <TextBlock Style="{StaticResource Icon}" Text="&#xE7BA;" Foreground="#9D5D00" FontSize="16" Margin="0,0,10,0"/>
              <TextBlock Text="Interceptar el tráfico de la red" FontWeight="SemiBold" VerticalAlignment="Center"/>
            </StackPanel>
            <TextBlock x:Name="TxtInterceptWarning" TextWrapping="Wrap" Margin="0,8,0,10"/>
            <TextBlock FontWeight="SemiBold" Margin="0,0,0,4" Text="Para medir el consumo por equipo, este modo necesita 2 cosas:"/>
            <TextBlock x:Name="TxtInterceptReqNpcap" TextWrapping="Wrap" Margin="0,0,0,2"/>
            <TextBlock x:Name="TxtInterceptReqAdmin" TextWrapping="Wrap" Margin="0,0,0,10"/>
            <CheckBox x:Name="ChkIntercept" Content="Entiendo los riesgos y quiero permitir este modo en mi propia red"/>
            <TextBlock x:Name="TxtInterceptStatus" TextWrapping="Wrap" FontSize="12" Foreground="#5F5F5F" Margin="0,8,0,0"/>
          </StackPanel>
        </Border>
        </StackPanel>

        <TextBlock Text="Acerca de" FontSize="18" FontWeight="SemiBold" Margin="2,18,0,8"/>
        <Border Style="{StaticResource Card}">
          <StackPanel>
            <TextBlock x:Name="TxtAbout" TextWrapping="Wrap" LineHeight="21"/>
            <Button x:Name="BtnOpenData" Style="{StaticResource SubtleButton}" Content="Abrir la carpeta de datos" HorizontalAlignment="Left" Margin="0,10,0,0"/>
          </StackPanel>
        </Border>
      </StackPanel>
    </ScrollViewer>

    <!-- ===== Publicidad (banner de 728x90 en un WebView2, ver Start-AdBanner) ===== -->
    <Border x:Name="AdBar" Grid.Row="3" BorderBrush="{StaticResource CardBorder}" BorderThickness="0,1,0,0" Padding="0,4,0,8" Visibility="Collapsed">
      <StackPanel HorizontalAlignment="Center">
        <TextBlock Text="Publicidad" FontSize="11" Foreground="{StaticResource TextSecondary}" Margin="0,0,0,3"/>
        <ContentControl x:Name="AdHost" Width="728" Height="90"/>
      </StackPanel>
    </Border>
  </Grid>
</Window>
'@

function Initialize-GuiTypes {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms
    Initialize-ScannerTypes
    $script:UiCallback = [System.Windows.Threading.DispatcherOperationCallback]{ param($frame) $frame.Continue = $false; $null }
}

# Deja que la ventana se redibuje (equivalente a DoEvents en WPF)
function Update-UI {
    if (-not $script:Gui) { return }
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    [void][System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::Background, $script:UiCallback, $frame)
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

function New-Brush([string]$Hex) { (New-Object System.Windows.Media.BrushConverter).ConvertFromString($Hex) }

function Show-Page([string]$Name) {
    $g = $script:Gui
    $g.PageDevices.Visibility = if ($Name -eq 'PageDevices') { 'Visible' } else { 'Collapsed' }
    $g.PageSettings.Visibility = if ($Name -eq 'PageSettings') { 'Visible' } else { 'Collapsed' }
    $g.BtnBack.Visibility = if ($Name -eq 'PageDevices') { 'Collapsed' } else { 'Visible' }
    $g.BtnSettings.Visibility = if ($Name -eq 'PageDevices') { 'Visible' } else { 'Collapsed' }
    $g.TxtTitle.Text = if ($Name -eq 'PageSettings') { 'Ajustes' } else { $script:AppName }
    if ($Name -eq 'PageSettings') { Update-SettingsPage }
}

function Get-SelectedNetwork {
    $g = $script:Gui
    if (-not $g.Networks -or $g.Networks.Count -eq 0) { return $null }
    $i = [Math]::Max(0, $g.CbNetwork.SelectedIndex)
    $g.Networks[$i]
}

function Get-GuiContext {
    $g = $script:Gui
    Get-ScanContext (Get-SelectedNetwork) $g.Session @($g.Devices)
}

#region Lista de equipos

function Get-OrCreateDevice([string]$Key) {
    $g = $script:Gui
    $d = $g.ByKey[$Key]
    if (-not $d) {
        $d = New-Object MonitorRed.DeviceItem
        $d.Key = $Key
        $g.ByKey[$Key] = $d
        $g.Devices.Add($d)
    }
    $d
}

function Set-DeviceType($Device, [string]$TypeKey) {
    $t = Get-DeviceType $TypeKey
    $Device.TypeKey = $t.Key
    $Device.TypeLabel = $t.Label
    $Device.Glyph = [string][char]$t.Glyph
}

function Update-DeviceStatus($Device) {
    if ($Device.IsOnline) {
        $Device.Status = if ($Device.PingMs -ge 0) { "En línea · $($Device.PingMs) ms" } else { 'En línea' }
    } else {
        $seen = Format-LastSeen $Device.LastSeen
        $Device.Status = if ($seen) { "Desconectado · visto $seen" } else { 'Desconectado' }
    }
}

# Equipos vistos en otros escaneos (para "Mostrar desconectados" y para recordar sus nombres)
function Import-KnownDevicesIntoList {
    foreach ($key in @($script:Known.Keys)) {
        $k = $script:Known[$key]
        if ($key -like 'IP:*') { continue }
        $d = Get-OrCreateDevice $key
        $d.Mac = $key
        $d.Ip = [string]$k.LastIp
        try { $d.IpValue = [MonitorRed.Net]::ToUInt($d.Ip) } catch { }
        $d.Vendor = [string]$k.Vendor
        $d.HostName = [string]$k.HostName
        $d.AutoName = if ($k.AutoName) { [string]$k.AutoName } else { $key }
        $d.CustomName = [string]$k.Name
        $type = if ($k.Type) { [string]$k.Type } elseif ($k.AutoType) { [string]$k.AutoType } else { 'unknown' }
        Set-DeviceType $d $type
        $d.IsCustomType = [bool]$k.Type
        $d.LastSeen = [string]$k.LastSeen
        $d.IsOnline = $false
        $d.IsRandomMac = [MonitorRed.Net]::IsRandomMac($key)
        $d.TypeReason = 'Datos del último escaneo en que se vio este equipo.'
        $d.Details = "Dirección IP (la última vez): $($d.Ip)`nDirección MAC: $key`nFabricante: $(if ($d.Vendor) { $d.Vendor } else { '—' })`nVisto por primera vez: $(Format-LastSeen ([string]$k.FirstSeen))`nVisto por última vez: $(Format-LastSeen $d.LastSeen)"
        Update-DeviceStatus $d
    }
}

function Get-DeviceDetails($Device, $Record, $Facts, $Known) {
    $lines = @()
    $lines += "Dirección IP: $($Record.Ip)"
    $macNote = if ($Facts.IsRandomMac) { ' (privada: el equipo la cambia para proteger su privacidad)' } else { '' }
    $lines += "Dirección MAC: $(if ($Record.Mac) { $Record.Mac } else { 'no se pudo leer' })$macNote"
    if ($Record.SharedMac) { $lines += 'Varias IPs usan esta misma MAC (por ejemplo, equipos detrás de un repetidor Wi-Fi), así que el nombre se recuerda por la IP.' }
    $lines += "Fabricante: $(if ($Facts.Vendor) { $Facts.Vendor } elseif ($Facts.IsRandomMac) { 'no se sabe (MAC privada)' } else { '—' })"
    $names = @()
    if ($Record.MdnsName) { $names += "$($Record.MdnsName) (mDNS)" }
    if ($Record.NetBiosName) { $names += "$($Record.NetBiosName) (NetBIOS)" }
    if ($Record.DnsName) { $names += "$($Record.DnsName) (DNS)" }
    $lines += "Nombre de host: $(if ($names) { $names -join ', ' } elseif ($Record.NamesDone) { 'no lo informa' } else { 'buscando...' })"
    if ($Facts.Upnp) {
        $model = (@($Facts.Upnp.Manufacturer, $Facts.Upnp.ModelName) | Where-Object { $_ }) -join ' '
        if ($model) { $lines += "Modelo (UPnP): $model" }
    }
    if ($Record.PingMs -ge 0) { $lines += "Responde al ping: $($Record.PingMs) ms" }
    elseif ($Record.IsSelf) { }
    else { $lines += 'Responde al ping: no (se encontró por ARP)' }
    if ($Known -and $Known.FirstSeen) { $lines += "Visto por primera vez: $(Format-LastSeen ([string]$Known.FirstSeen))" }
    $lines -join "`n"
}

# Pasa lo que averiguó el escáner sobre una IP a la fila de la lista (y a lo guardado)
function Update-DeviceFromRecord($Record) {
    $g = $script:Gui
    if ($Record.Removed) { return }
    $facts = Get-DeviceFacts $Record $g.IsLaptop
    $key = $facts.Key

    # Si ya estaba en la lista solo por su IP y ahora se conoce su MAC, cambia de clave
    $device = $g.ByKey[$key]
    $byIp = $g.ByIp[$Record.Ip]
    if ($byIp -and $byIp.Key -ne $key -and $byIp.Key -like 'IP:*') {
        $g.ByKey.Remove($byIp.Key)
        $g.SeenKeys.Remove($byIp.Key)
        $script:Known.Remove($byIp.Key)
        if ($device) {
            [void]$g.Devices.Remove($byIp)
        } else {
            $device = $byIp
            $device.Key = $key
            $g.ByKey[$key] = $device
        }
    }
    if (-not $device) { $device = Get-OrCreateDevice $key }
    $g.ByIp[$Record.Ip] = $device
    $g.SeenKeys[$key] = $true

    $known = $script:Known[$key]
    $isNew = -not $known
    $now = (Get-Date).ToUniversalTime().ToString('o')
    if ($isNew) { $known = @{ FirstSeen = $now }; $script:Known[$key] = $known }

    $device.Record = $Record
    $device.Ip = $Record.Ip
    $device.IpValue = $Record.IpValue
    $device.Mac = $Record.Mac
    $device.IsRandomMac = $facts.IsRandomMac
    $device.Vendor = if ($facts.Vendor) { $facts.Vendor } elseif ($facts.IsRandomMac) { 'MAC privada' } else { '' }
    $device.HostName = $facts.HostName
    $device.PingMs = $Record.PingMs
    $device.IsGateway = $Record.IsGateway
    $device.IsSelf = $Record.IsSelf
    $device.IsOnline = $true
    $device.LastSeen = $now
    $device.AutoName = $facts.AutoName
    $device.CustomName = [string]$known.Name
    $device.IsCustomType = [bool]$known.Type
    if ($known.Type) {
        Set-DeviceType $device ([string]$known.Type)
        $device.TypeReason = "Elegido por ti. La app había estimado: $((Get-DeviceType $facts.Guess.Type).Label)."
    } else {
        Set-DeviceType $device $facts.Guess.Type
        $device.TypeReason = $facts.Guess.Reason
    }
    $device.Badge = if ($Record.IsSelf) { 'Este equipo' } elseif ($Record.IsGateway) { 'Router' } elseif ($isNew -and $g.HadHistory) { 'Nuevo' } else { '' }
    $device.Details = Get-DeviceDetails $device $Record $facts $known
    Update-DeviceStatus $device

    if (-not ($key -like 'IP:*')) {
        $known.LastSeen = $now
        $known.LastIp = $Record.Ip
        $known.Vendor = $device.Vendor
        $known.HostName = $facts.HostName
        $known.AutoName = $facts.AutoName
        $known.AutoType = $facts.Guess.Type
    } else {
        $script:Known.Remove($key)
    }
    if ($g.DeviceGrid.SelectedItem -eq $device) { Update-DetailPanel -KeepEdits }
}

function Test-DeviceFilter($Device) {
    $g = $script:Gui
    if (-not $g.ChkOffline.IsChecked -and -not $Device.IsOnline) { return $false }
    $type = $null
    if ($g.CbTypeFilter.SelectedItem) { $type = $g.CbTypeFilter.SelectedItem.Tag }
    if ($type -and $Device.TypeKey -ne $type) { return $false }
    $q = $g.TxtSearch.Text
    if ($q) {
        $q = $q.Trim()
        $hay = "$($Device.DisplayName) $($Device.AutoName) $($Device.Ip) $($Device.Mac) $($Device.Vendor) $($Device.HostName) $($Device.TypeLabel)"
        if ($hay.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
    }
    $true
}

function Update-DeviceView {
    $g = $script:Gui
    $g.View.Refresh()
    $online = @($g.Devices | Where-Object { $_.IsOnline }).Count
    $g.TxtOnline.Text = [string]$online
    $g.TxtOnlineLabel.Text = if ($online -eq 1) { ' equipo en línea' } else { ' equipos en línea' }
    $visible = 0
    foreach ($x in $g.View) { $visible++ }
    if ($visible -eq 0) {
        $g.TxtEmpty.Text = if ($g.Session -and -not $g.Session.IsCompleted) { 'Buscando equipos en la red...' } elseif ($g.Devices.Count -gt 0) { 'Ningún equipo coincide con la búsqueda.' } else { 'No se encontraron equipos.' }
        $g.TxtEmpty.Visibility = 'Visible'
    } else {
        $g.TxtEmpty.Visibility = 'Collapsed'
    }
}

#endregion

#region Escaneo con ventana

function Start-NetworkScan {
    $g = $script:Gui
    if ($g.Session -and -not $g.Session.IsCompleted) { return }
    $net = Get-SelectedNetwork
    if (-not $net) {
        $g.TxtSubtitle.Text = 'Sin conexión de red'
        $g.TxtStatus.Text = 'Este equipo no está conectado a ninguna red. Conéctate al Wi-Fi o al cable de la casa y presiona «Escanear de nuevo».'
        $g.ScanProgress.Value = 0
        return
    }
    $g.TxtSubtitle.Text = "Red $($net.Summary)  ·  Este equipo: $($net.LocalIp)  ·  Router: $(if ($net.Gateway) { $net.Gateway } else { 'no detectado' })"
    if ($net.IsLimited) { $g.TxtSubtitle.Text += '  ·  Red grande: se escanea solo la parte de este equipo (/24)' }
    $g.SeenKeys = @{}
    $g.ByIp = @{}
    Reset-Measurement
    $g.ScanStarted = Get-Date
    $session = New-Object MonitorRed.ScanSession($net)
    $g.Session = $session
    $g.BtnScan.IsEnabled = $false
    $g.BtnScanText.Text = 'Escaneando...'
    $g.CbNetwork.IsEnabled = $false
    $g.ScanProgress.Value = 0
    $g.ScanProgress.Visibility = 'Visible'
    $g.TxtStatus.Text = 'Buscando equipos...'
    $session.Start()
    $g.Timer.Start()
    Update-MeasurementUi
}

# Cada 250 ms: trae lo nuevo del escáner, actualiza la lista y el progreso
function Update-ScanProgress {
    $g = $script:Gui
    Complete-OuiDownload
    $s = $g.Session
    if (-not $s) { $g.Timer.Stop(); return }
    $changes = $s.TakeChanges()
    foreach ($r in $changes) { Update-DeviceFromRecord $r }
    if ($changes.Count -gt 0) { Update-DeviceView }
    $g.ScanProgress.Value = $s.Percent
    $g.TxtStatus.Text = "$($s.Phase)  ($($s.FoundCount) encontrados)"
    if ($s.IsCompleted) { Complete-NetworkScan }
}

function Complete-NetworkScan {
    $g = $script:Gui
    $s = $g.Session
    $g.Timer.Stop()
    foreach ($r in $s.TakeChanges()) { Update-DeviceFromRecord $r }
    foreach ($d in @($g.Devices)) {
        if (-not $g.SeenKeys[$d.Key]) {
            $d.IsOnline = $false
            if ($d.Key -like 'IP:*') { [void]$g.Devices.Remove($d); $g.ByKey.Remove($d.Key); continue }
            $d.Badge = ''
            Update-DeviceStatus $d
        }
    }
    Save-KnownDevices
    $secs = [int]((Get-Date) - $g.ScanStarted).TotalSeconds
    $n = $g.SeenKeys.Count
    if ($s.Error) {
        $g.TxtStatus.Text = "El escaneo se detuvo por un error: $($s.Error)"
    } else {
        $g.TxtStatus.Text = "Escaneo terminado en $secs s: $n $(if ($n -eq 1) { 'equipo conectado' } else { 'equipos conectados' }). Haz clic en un equipo para ponerle nombre."
    }
    $g.ScanProgress.Value = 100
    $g.ScanProgress.Visibility = 'Collapsed'
    $g.BtnScan.IsEnabled = $true
    $g.BtnScanText.Text = 'Escanear de nuevo'
    $g.CbNetwork.IsEnabled = $true
    Update-DeviceView
    Update-MeasurementUi
}

# Si la base de fabricantes no venía incluida, se descarga una vez en segundo plano
function Start-OuiDownload {
    $g = $script:Gui
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($script:OuiDownloadScript.ToString()).AddArgument($script:OuiIeeeUrls).AddArgument($script:OuiFallbackUrl).AddArgument("Mozilla/5.0 (Windows NT 10.0; Win64; x64) MonitorRed/$script:AppVersion")
    $g.OuiJob = @{ PS = $ps; Handle = $ps.BeginInvoke() }
}

function Complete-OuiDownload {
    $g = $script:Gui
    $job = $g.OuiJob
    if (-not $job -or -not $job.Handle.IsCompleted) { return }
    $g.OuiJob = $null
    try {
        $r = @($job.PS.EndInvoke($job.Handle))[0]
        Save-CompactOui (Join-Path $script:DataDir $script:OuiFileName) (ConvertTo-CompactOui $r.Kind $r.Text)
        foreach ($d in @($g.Devices)) { if ($d.Record -and $d.IsOnline) { Update-DeviceFromRecord $d.Record } }
        Update-DeviceView
    } catch { } finally { $job.PS.Dispose() }
}

#endregion

function Export-DeviceList {
    $g = $script:Gui
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Title = 'Exportar la lista de equipos'
    $dlg.Filter = 'Archivo para Excel (*.csv)|*.csv'
    $dlg.FileName = "Equipos de la red $(Get-Date -Format 'yyyy-MM-dd').csv"
    if (-not $dlg.ShowDialog($g.Window)) { return }
    Export-DeviceCsv $dlg.FileName
    $g.TxtStatus.Text = "Lista exportada a $($dlg.FileName)"
}

function Export-DeviceCsv([string]$Path) {
    $g = $script:Gui
    $rows = foreach ($d in $g.View) {
        [pscustomobject][ordered]@{
            'Nombre' = $d.DisplayName; 'Tipo' = $d.TypeLabel; 'IP' = $d.Ip; 'MAC' = $d.Mac; 'Fabricante' = $d.Vendor
            'Nombre de host' = $d.HostName; 'Estado' = $d.Status; 'Visto por última vez' = (Format-LastSeen $d.LastSeen)
        }
    }
    # -UseCulture usa el separador de listas de Windows (";" en español), que es el que espera Excel
    @($rows) | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8 -UseCulture
}

#region Detalle y edición de un equipo

function Update-DetailPanel {
    param([switch]$KeepEdits)
    $g = $script:Gui
    $d = $g.DeviceGrid.SelectedItem
    if (-not $d) {
        $g.DetailPanel.Visibility = 'Collapsed'
        $g.DetailEmpty.Visibility = 'Visible'
        return
    }
    $g.DetailEmpty.Visibility = 'Collapsed'
    $g.DetailPanel.Visibility = 'Visible'
    $g.DetGlyph.Text = $d.Glyph
    $g.DetTitle.Text = $d.DisplayName
    $g.DetSubtitle.Text = "$($d.TypeLabel)  ·  $($d.Status)"
    $g.DetReason.Text = $d.TypeReason
    $g.DetDetails.Text = $d.Details
    if ($KeepEdits -and $g.EditingKey -eq $d.Key) { return }
    $g.EditingKey = $d.Key
    $g.TxtName.Text = $d.DisplayName
    $auto = $g.CbType.Items[0]
    $autoType = $d.TypeKey
    if ($d.IsCustomType) {
        $k = $script:Known[$d.Key]
        if ($k -and $k.AutoType) { $autoType = [string]$k.AutoType }
    }
    $auto.Content = "Automático ($((Get-DeviceType $autoType).Label))"
    $g.CbType.SelectedIndex = 0
    if ($d.IsCustomType) {
        for ($i = 1; $i -lt $g.CbType.Items.Count; $i++) {
            if ($g.CbType.Items[$i].Tag -eq $d.TypeKey) { $g.CbType.SelectedIndex = $i; break }
        }
    }
}

function Save-DeviceEdit {
    $g = $script:Gui
    $d = $g.DeviceGrid.SelectedItem
    if (-not $d) { return }
    $name = $g.TxtName.Text.Trim()
    if ($name -eq $d.AutoName) { $name = '' }
    $type = ''
    if ($g.CbType.SelectedIndex -gt 0) { $type = [string]$g.CbType.SelectedItem.Tag }

    $known = $script:Known[$d.Key]
    if (-not $known) { $known = @{ FirstSeen = (Get-Date).ToUniversalTime().ToString('o'); LastIp = $d.Ip }; $script:Known[$d.Key] = $known }
    $known.Name = $name
    $known.Type = $type
    if (-not $known.AutoType) { $known.AutoType = $d.TypeKey }
    Save-KnownDevices

    $d.CustomName = $name
    $d.IsCustomType = [bool]$type
    if ($type) {
        Set-DeviceType $d $type
        $d.TypeReason = "Elegido por ti. La app había estimado: $((Get-DeviceType ([string]$known.AutoType)).Label)."
    } else {
        Set-DeviceType $d ([string]$known.AutoType)
        if ($d.Record) { $d.TypeReason = (Get-DeviceFacts $d.Record $g.IsLaptop).Guess.Reason }
    }
    if ($d.Key -like 'IP:*') {
        $g.TxtStatus.Text = 'Aviso: no se pudo leer la MAC de este equipo, así que su nombre solo se recordará mientras tenga la misma IP.'
    }
    $g.EditingKey = $null
    Update-DetailPanel
    Update-DeviceView
}

function Reset-DeviceEdit {
    $g = $script:Gui
    $d = $g.DeviceGrid.SelectedItem
    if (-not $d) { return }
    $g.TxtName.Text = $d.AutoName
    $g.CbType.SelectedIndex = 0
    Save-DeviceEdit
}

#endregion

#region Ajustes y modos de medición

function Update-MeasurementUi {
    $g = $script:Gui
    $state = Get-MeasurementState (Get-GuiContext)
    $g.MeasureState = $state
    foreach ($item in $g.ModeItems) {
        $r = $state.Results | Where-Object { $_.Mode.Id -eq $item.Id } | Select-Object -First 1
        $item.Available = $r.Available
        $item.Reason = $r.Reason
        $item.IsActive = [bool]($state.Active -and $state.Active.Mode.Id -eq $item.Id)
    }
    $g.TxtMeasure.Text = Get-MeasurementSummary $state
    $g.TxtAutoResult.Text = if ($state.Active) { "Ahora mismo elegiría: $($state.Active.Mode.Name)." } else { 'Ahora mismo no hay ningún modo disponible.' }
    Sync-MeasureSources
}

#region Medición en vivo del consumo

# Arranca o detiene las fuentes de medición. El consumo de ESTE equipo se mide siempre (es gratis).
# El total de la casa (UPnP) se muestra en la cabecera como complemento siempre que el router lo
# informe, sin importar el modo por equipo. La medición por equipo depende del modo activo.
function Sync-MeasureSources {
    $g = $script:Gui
    $state = $g.MeasureState
    $completed = [bool]($g.Session -and $g.Session.IsCompleted)

    $upnpAvail = $false
    if ($completed -and $g.Session) {
        $upnpAvail = [bool](@($g.Session.InternetGateways) | Where-Object { $_.WanControlUrl } | Select-Object -First 1)
    }
    if ($upnpAvail) {
        if (-not $g.UpnpPS) { Start-UpnpPoll }
    } else {
        Stop-UpnpPoll
        $g.TotalRatePanel.Visibility = 'Collapsed'
    }

    $interceptActive = [bool]($state -and $state.Active -and $state.Active.Mode.Id -eq 'Intercept' -and $completed)
    if ($interceptActive) {
        if (-not $g.Interceptor) { Start-InterceptCapture }
    } else {
        Stop-InterceptCapture
    }
}

function Reset-Measurement {
    $g = $script:Gui
    Stop-UpnpPoll
    Stop-InterceptCapture
    $g.InterceptConfirmed = $false
    $g.PrevSelf = $null
    foreach ($d in @($g.Devices)) { $d.Download = '—'; $d.Upload = '—' }
    $g.TotalRatePanel.Visibility = 'Collapsed'
    $g.TxtTotalDown.Text = '—'; $g.TxtTotalUp.Text = '—'
}

# Modo avanzado: pone esta PC "en medio" (ARP) para contar el tráfico de cada equipo, solo en la red
# propia. Pide confirmación explícita una vez, mide en segundo plano y restaura la red al detenerse.
function Start-InterceptCapture {
    $g = $script:Gui
    $net = Get-SelectedNetwork
    if (-not $net) { return }

    if (-not $g.InterceptConfirmed) {
        $msg = "El modo avanzado mide el consumo de cada equipo poniendo esta PC en medio del trafico de tu red (tecnica ARP)." + [Environment]::NewLine + [Environment]::NewLine +
               "- Usalo solo en TU PROPIA red." + [Environment]::NewLine +
               "- Puede hacer la red un poco mas lenta mientras esta activo." + [Environment]::NewLine +
               "- Algunos antivirus o routers pueden bloquearlo." + [Environment]::NewLine +
               "- Al cerrar la app o cambiar de modo, la red se restaura automaticamente." + [Environment]::NewLine + [Environment]::NewLine +
               "Deseas continuar?"
        $r = [System.Windows.MessageBox]::Show($g.Window, $msg, 'Interceptar el trafico (avanzado)',
            [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
        if ($r -ne [System.Windows.MessageBoxResult]::Yes) {
            # El usuario no confirmo: vuelve a Automatico para no quedar en un modo que no mide
            $script:Settings.InterceptConsent = $false
            $g.ChkIntercept.IsChecked = $false
            $script:Settings.MeasurementMode = 'Auto'
            Save-Settings
            Update-MeasurementUi
            return
        }
        $g.InterceptConfirmed = $true
    }

    # Equipos reales a medir: IP -> MAC, sin este PC, sin el router y sin fantasmas de proxy ARP
    $devices = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    $gatewayMac = ''
    foreach ($d in @($g.Devices)) {
        if (-not $d.IsOnline -or -not $d.Mac) { continue }
        if ($d.IsGateway) { $gatewayMac = $d.Mac; continue }
        if ($d.IsSelf -or $d.SharedMac) { continue }
        if (-not $devices.ContainsKey($d.Ip)) { $devices[$d.Ip] = $d.Mac }
    }
    if (-not $gatewayMac) { $g.TxtInterceptStatus.Text = 'No se pudo leer la direccion MAC del router. Vuelve a escanear.'; return }
    if ($devices.Count -eq 0) { $g.TxtInterceptStatus.Text = 'Todavia no hay otros equipos con MAC conocida para medir.'; return }

    $deviceName = '\Device\NPF_' + $net.InterfaceId
    $interceptor = New-Object MonitorRed.Interceptor
    if ($interceptor.Start($deviceName, $net, $gatewayMac, $devices)) {
        $g.Interceptor = $interceptor
        $g.PrevDev = @{}
        $g.TxtInterceptStatus.Text = "Midiendo el trafico de $($interceptor.TargetCount) equipos. La red se restaura al cerrar o cambiar de modo."
    } else {
        $g.TxtInterceptStatus.Text = "No se pudo iniciar el modo avanzado: $($interceptor.Error)"
        $g.Interceptor = $null
    }
}

# Detiene la captura y restaura la tabla ARP de todos los equipos (dentro de Stop()).
function Stop-InterceptCapture {
    $g = $script:Gui
    if (-not $g.Interceptor) { return }
    try { $g.Interceptor.Stop() } catch { }
    $g.Interceptor = $null
    $g.PrevDev = $null
    foreach ($d in @($g.Devices)) { if (-not $d.IsSelf) { $d.Download = '—'; $d.Upload = '—' } }
}

# Consumo real de la tarjeta de red de este equipo, sin depender del router (lectura instantánea)
function Update-SelfMeasurement {
    $g = $script:Gui
    $net = Get-SelectedNetwork
    if (-not $net) { return }
    $self = $null
    foreach ($d in @($g.Devices)) { if ($d.IsSelf) { $self = $d; break } }
    if (-not $self) { return }
    $now = Get-SelfTrafficBytes $net
    if (-not $now) { return }
    $t = [double][Environment]::TickCount
    if ($g.PrevSelf) {
        $secs = ($t - $g.PrevSelf.Time) / 1000.0
        $self.Download = Format-Rate (Get-RateBps $g.PrevSelf.DownBytes $now.DownBytes $secs)
        $self.Upload = Format-Rate (Get-RateBps $g.PrevSelf.UpBytes $now.UpBytes $secs)
    }
    $g.PrevSelf = @{ DownBytes = $now.DownBytes; UpBytes = $now.UpBytes; Time = $t }
}

# El total por UPnP hace una llamada al router que puede tardar unos segundos, así que se consulta en
# un hilo aparte que escribe el resultado en una tabla compartida; la ventana solo lo lee.
function Start-UpnpPoll {
    $g = $script:Gui
    if (-not $g.Session) { return }
    $igd = @($g.Session.InternetGateways) | Where-Object { $_.WanControlUrl } | Select-Object -First 1
    if (-not $igd) { return }
    $sync = [hashtable]::Synchronized(@{ Stop = $false; Time = 0.0; Down = -1.0; Up = -1.0 })
    $ps = [PowerShell]::Create()
    $ps.Runspace.SessionStateProxy.SetVariable('sync', $sync)
    [void]$ps.AddScript({
        param($Source, $Url, $ServiceType, $IntervalMs)
        try { if (-not ('MonitorRed.Upnp' -as [type])) { Add-Type -TypeDefinition $Source -Language CSharp -IgnoreWarnings -ErrorAction SilentlyContinue } } catch { }
        while (-not $sync.Stop) {
            $d = [MonitorRed.Upnp]::GetTotalBytes($Url, $ServiceType, $true, 4000)
            $u = [MonitorRed.Upnp]::GetTotalBytes($Url, $ServiceType, $false, 4000)
            $sync.Down = [double]$d; $sync.Up = [double]$u; $sync.Time = [double][Environment]::TickCount
            $waited = 0
            while (-not $sync.Stop -and $waited -lt $IntervalMs) { Start-Sleep -Milliseconds 100; $waited += 100 }
        }
    }).AddArgument($script:ScannerSource).AddArgument($igd.WanControlUrl).AddArgument($igd.WanServiceType).AddArgument(2000)
    $g.UpnpSync = $sync
    $g.UpnpPS = $ps
    $g.UpnpHandle = $ps.BeginInvoke()
    $g.PrevTotal = $null
}

function Stop-UpnpPoll {
    $g = $script:Gui
    if ($g.UpnpSync) { $g.UpnpSync.Stop = $true }
    # El hilo puede estar dentro de una llamada al router (hasta unos segundos) y no termina al instante.
    # Para no congelar la ventana no se espera aquí: se guarda y se desecha más tarde, cuando ya terminó.
    if ($g.UpnpPS) { $g.UpnpDisposing.Add(@{ PS = $g.UpnpPS; Handle = $g.UpnpHandle }) | Out-Null }
    $g.UpnpPS = $null; $g.UpnpSync = $null; $g.UpnpHandle = $null; $g.PrevTotal = $null
}

# Desecha los hilos de medición que ya terminaron (llamado desde el temporizador)
function Clear-FinishedPolls {
    $g = $script:Gui
    if ($g.UpnpDisposing.Count -eq 0) { return }
    foreach ($job in @($g.UpnpDisposing)) {
        if ($job.Handle.IsCompleted) {
            try { [void]$job.PS.EndInvoke($job.Handle) } catch { }
            try { $job.PS.Dispose() } catch { }
            $g.UpnpDisposing.Remove($job)
        }
    }
}

# Llamado por el temporizador cada 2 s: actualiza el consumo de este equipo y el total de la casa
function Update-Measurement {
    $g = $script:Gui
    Clear-FinishedPolls
    if (-not $g.Networks -or $g.Networks.Count -eq 0) { return }
    Update-SelfMeasurement

    # Total de la casa (UPnP) en la cabecera, como complemento, mientras el hilo esté activo
    if ($g.UpnpSync) {
        $s = $g.UpnpSync
        if ($s.Time -ne 0 -and ($s.Down -ge 0 -or $s.Up -ge 0)) {
            if ($g.PrevTotal -and $s.Time -ne $g.PrevTotal.Time) {
                $secs = ($s.Time - $g.PrevTotal.Time) / 1000.0
                $g.TxtTotalDown.Text = Format-Rate (Get-RateBps $g.PrevTotal.Down $s.Down $secs)
                $g.TxtTotalUp.Text = Format-Rate (Get-RateBps $g.PrevTotal.Up $s.Up $secs)
                $g.TotalRatePanel.Visibility = 'Visible'
            }
            if (-not $g.PrevTotal -or $s.Time -ne $g.PrevTotal.Time) {
                $g.PrevTotal = @{ Down = $s.Down; Up = $s.Up; Time = $s.Time }
            }
        }
    }

    # Consumo por equipo con el modo Interceptar: lee los bytes acumulados y calcula la velocidad
    if ($g.Interceptor) {
        $snap = $g.Interceptor.Snapshot()
        $t = [double][Environment]::TickCount
        if (-not $g.PrevDev) { $g.PrevDev = @{} }
        foreach ($d in @($g.Devices)) {
            if ($d.IsSelf -or $d.IsGateway -or -not $d.Mac) { continue }
            $mac = [MonitorRed.Net]::FormatMac($d.Mac)
            if (-not $snap.ContainsKey($mac)) { continue }
            $down = [double]$snap[$mac][0]; $up = [double]$snap[$mac][1]
            $prev = $g.PrevDev[$mac]
            if ($prev) {
                $secs = ($t - $prev.Time) / 1000.0
                $d.Download = Format-Rate (Get-RateBps $prev.Down $down $secs)
                $d.Upload = Format-Rate (Get-RateBps $prev.Up $up $secs)
            }
            $g.PrevDev[$mac] = @{ Down = $down; Up = $up; Time = $t }
        }
    }
}

#endregion

function Update-SettingsPage {
    $g = $script:Gui
    $s = $script:Settings
    $g.LoadingSettings = $true
    try {
        $wanted = [string]$s.MeasurementMode
        $g.RbAuto.IsChecked = (-not $wanted -or $wanted -eq 'Auto')
        foreach ($item in $g.ModeItems) { $item.IsSelected = ($item.Id -eq $wanted) }
        $g.CbRouterBrand.SelectedIndex = 0
        for ($i = 1; $i -lt $g.CbRouterBrand.Items.Count; $i++) {
            if ($g.CbRouterBrand.Items[$i].Tag -eq $s.RouterBrand) { $g.CbRouterBrand.SelectedIndex = $i; break }
        }
        $g.TxtRouterUser.Text = [string]$s.RouterUser
        $g.PwdRouter.Password = Unprotect-Text ([string]$s.RouterPassword)
        $g.TxtRouterSaved.Text = ''
        $vendor = Get-GatewayVendor (Get-GuiContext)
        $gw = (Get-SelectedNetwork)
        $g.TxtRouterHint.Text = "Router detectado: $(if ($gw -and $gw.Gateway) { $gw.Gateway } else { 'no detectado' })$(if ($vendor) { " ($vendor)" })." +
            ' Son los mismos datos con los que entras a la página de configuración del router (suelen venir en una etiqueta debajo del equipo).'
        $g.ChkIntercept.IsChecked = [bool]$s.InterceptConsent
        $intercept = $script:MeasurementModes | Where-Object { $_.Id -eq 'Intercept' }
        $g.InterceptSection.Visibility = if ($intercept) { 'Visible' } else { 'Collapsed' }
        $order = @($script:MeasurementModes | Sort-Object { $_.Priority } | ForEach-Object {
            if ($_.RequiresConsent) { "$($_.Name) (solo si lo permitiste)" } else { $_.Name } })
        $g.TxtAutoDesc.Text = "Usa el mejor modo disponible, en este orden: $($order -join ', ')."
        if ($intercept) {
            $g.TxtInterceptWarning.Text = $intercept.Warning
            $hasNpcap = Test-NpcapInstalled
            $isAdmin = Test-IsAdmin
            $g.TxtInterceptReqNpcap.Text = if ($hasNpcap) {
                '✓  Npcap instalado.'
            } else {
                '✗  Falta Npcap. Descárgalo gratis en npcap.com e instálalo (deja marcadas las opciones por defecto).'
            }
            $g.TxtInterceptReqNpcap.Foreground = if ($hasNpcap) { '#107C10' } else { '#B00020' }
            $g.TxtInterceptReqAdmin.Text = if ($isAdmin) {
                '✓  La app está abierta como administrador.'
            } else {
                '✗  Abre la app como administrador: ciérrala, clic derecho en MonitorRed.exe → «Ejecutar como administrador».'
            }
            $g.TxtInterceptReqAdmin.Foreground = if ($isAdmin) { '#107C10' } else { '#B00020' }
            if (-not $g.Interceptor) {
                $g.TxtInterceptStatus.Text = if ($hasNpcap -and $isAdmin) {
                    'Todo listo. Elige «Interceptar el tráfico» como modo de medición (o déjalo en Automático) para ver el consumo de cada equipo.'
                } else {
                    'Cuando tengas las 2 cosas, las columnas Bajada/Subida de cada equipo se llenarán solas.'
                }
            }
        }
        $g.TxtAbout.Text = "$script:AppName $script:AppVersion`nFabricantes conocidos: $([MonitorRed.OuiDatabase]::Count) bloques de direcciones MAC (registro público de la IEEE).`nTus nombres y ajustes se guardan en: $script:DataDir`nLa app es gratis gracias a la publicidad de abajo (la muestra Adsterra) y al apoyo de quienes la usan."
        Update-MeasurementUi
    } finally {
        $g.LoadingSettings = $false
    }
}

function Set-MeasurementMode([string]$Id) {
    $g = $script:Gui
    if ($g.LoadingSettings -or -not $Id) { return }
    $script:Settings.MeasurementMode = $Id
    Save-Settings
    Update-MeasurementUi
}

function Save-RouterSettings {
    $g = $script:Gui
    $brand = ''
    if ($g.CbRouterBrand.SelectedIndex -gt 0) { $brand = [string]$g.CbRouterBrand.SelectedItem.Tag }
    $script:Settings.RouterBrand = $brand
    $script:Settings.RouterUser = $g.TxtRouterUser.Text.Trim()
    $script:Settings.RouterPassword = Protect-Text $g.PwdRouter.Password
    Save-Settings
    $g.TxtRouterSaved.Text = 'Guardado.'
    Update-MeasurementUi
}

#endregion

function New-ComboItem([string]$Text, $Tag) {
    $item = New-Object System.Windows.Controls.ComboBoxItem
    $item.Content = $Text
    $item.Tag = $Tag
    $item
}

#region Publicidad y apoyo

function Test-SupportConfigured { $script:SupportUrl -and $script:SupportUrl -notmatch 'PENDIENTE' }

# Abre un enlace con explorer.exe, para que el navegador no se abra con permisos de administrador (modo Interceptar)
function Open-ExternalLink([string]$Url) {
    if ($Url -notmatch '^https?://') { return }
    try { Start-Process explorer.exe -ArgumentList "`"$Url`"" } catch { }
}

# Carpeta con las DLL de WebView2: las incrustadas en el .exe se extraen una vez en %LOCALAPPDATA%
function Get-WebView2Folder {
    if (-not [Environment]::Is64BitProcess) { return $null }   # se incluye solo WebView2Loader.dll de 64 bits
    if (-not $script:EmbeddedWebView2) {
        $dir = Join-Path $script:ScriptDir 'webview2'
        if (Test-Path -LiteralPath (Join-Path $dir 'Microsoft.Web.WebView2.Wpf.dll')) { return $dir }
        return $null
    }
    $dir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) "MonitorRed\WebView2\$script:WebView2Version"
    if (Test-Path -LiteralPath (Join-Path $dir 'Microsoft.Web.WebView2.Wpf.dll')) { return $dir }
    # Se extrae en una carpeta temporal y se renombra al final, para no dejar una copia a medias
    $tmp = "$dir.tmp$PID"
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
        $zip = "$tmp.zip"
        [IO.File]::WriteAllBytes($zip, [Convert]::FromBase64String($script:EmbeddedWebView2))
        try { [IO.Compression.ZipFile]::ExtractToDirectory($zip, $tmp) } finally { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue }
        if (-not (Test-Path -LiteralPath $dir)) { Move-Item -LiteralPath $tmp -Destination $dir }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    $dir
}

# Carga WebView2. Devuelve $false (y la app sigue sin publicidad) si faltan las DLL o el WebView2 Runtime de
# Windows, que viene con Windows 11 y con Microsoft Edge en Windows 10.
function Initialize-WebView2 {
    if ($null -ne $script:WebView2Ready) { return $script:WebView2Ready }
    $script:WebView2Ready = $false
    try {
        $dir = Get-WebView2Folder
        if (-not $dir) { $script:AdError = 'Sin las DLL de WebView2'; return $false }
        Add-Type -Path (Join-Path $dir 'Microsoft.Web.WebView2.Core.dll')
        Add-Type -Path (Join-Path $dir 'Microsoft.Web.WebView2.Wpf.dll')
        [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::SetLoaderDllFolderPath($dir)
        [void][Microsoft.Web.WebView2.Core.CoreWebView2Environment]::GetAvailableBrowserVersionString()
        $script:WebView2Ready = $true
    } catch {
        $script:AdError = "WebView2 no disponible: $($_.Exception.Message)"
    }
    $script:WebView2Ready
}

function Test-AdsEnabled {
    # Las pruebas automáticas (GitHub Actions) no cargan anuncios reales: serían impresiones inválidas
    $script:AdPageUrl -and $script:AdPageUrl -notmatch 'PENDIENTE' -and $env:MONITORRED_PRUEBA -ne '1'
}

# Solo se navega dentro del sitio del banner; un clic en el anuncio se abre en el navegador del usuario
function Test-AdPageUri([string]$Uri) {
    try { ([Uri]$Uri).Host -eq ([Uri]$script:AdPageUrl).Host } catch { $false }
}

function Hide-AdBanner([string]$Reason) {
    $g = $script:Gui
    $g.AdBar.Visibility = 'Collapsed'
    $g.AdState = 'Oculto'
    $script:AdError = $Reason
    # Si ya había WebView2 (por ejemplo, no había internet), se vuelve a intentar más tarde
    if ($g.AdView -and $g.AdView.CoreWebView2 -and $g.AdRetryTimer) { $g.AdRetryTimer.Start() }
}

function Start-AdBanner {
    $g = $script:Gui
    if (-not (Test-AdsEnabled) -or -not (Initialize-WebView2)) {
        $g.AdBar.Visibility = 'Collapsed'
        $g.AdState = 'NoDisponible'
        return
    }
    $g.AdState = 'Cargando'
    # La franja se muestra antes de crear el control: WebView2 se inicia recién cuando está en la ventana
    $g.AdBar.Visibility = 'Visible'

    $g.AdRetryTimer = New-Object System.Windows.Threading.DispatcherTimer
    $g.AdRetryTimer.Interval = [TimeSpan]::FromMinutes($script:AdRetryMinutes)
    $g.AdRetryTimer.Add_Tick({
        $g = $script:Gui
        $g.AdRetryTimer.Stop()
        if ($g.AdView -and $g.AdView.CoreWebView2) { $g.AdView.CoreWebView2.Navigate($script:AdPageUrl) }
    })

    $wv = New-Object Microsoft.Web.WebView2.Wpf.WebView2
    $props = New-Object Microsoft.Web.WebView2.Wpf.CoreWebView2CreationProperties
    $props.UserDataFolder = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'MonitorRed\Navegador'
    $wv.CreationProperties = $props
    $wv.Add_CoreWebView2InitializationCompleted({
        param($s, $e)
        if (-not $e.IsSuccess) {
            $msg = if ($e.InitializationException) { $e.InitializationException.Message } else { 'error desconocido' }
            Hide-AdBanner "No se pudo iniciar WebView2: $msg"
            return
        }
        $core = $s.CoreWebView2
        $core.Settings.AreDefaultContextMenusEnabled = $false
        $core.Settings.AreDevToolsEnabled = $false
        $core.Settings.IsStatusBarEnabled = $false
        $core.Settings.IsZoomControlEnabled = $false
        $core.Settings.AreBrowserAcceleratorKeysEnabled = $false
        # Solo se abre el navegador si la persona hizo clic; las ventanas que el anuncio abre solo se bloquean
        $core.add_NewWindowRequested({
            param($c, $a)
            $a.Handled = $true
            if ($a.IsUserInitiated) { Open-ExternalLink $a.Uri }
        })
        $core.add_NavigationStarting({
            param($c, $a)
            if (-not (Test-AdPageUri $a.Uri)) {
                $a.Cancel = $true
                Open-ExternalLink $a.Uri
            }
        })
    })
    $wv.Add_NavigationCompleted({
        param($s, $e)
        $g = $script:Gui
        if ($e.IsSuccess -and $e.HttpStatusCode -lt 400) {
            $g.AdBar.Visibility = 'Visible'
            $g.AdState = 'Visible'
            $script:AdError = $null
        } else {
            Hide-AdBanner "La página del banner no cargó ($($e.WebErrorStatus), HTTP $($e.HttpStatusCode))"
        }
    })
    $g.AdView = $wv
    $g.AdHost.Content = $wv
    $wv.Source = New-Object Uri $script:AdPageUrl
}

function Stop-AdBanner {
    $g = $script:Gui
    if ($g.AdRetryTimer) { $g.AdRetryTimer.Stop() }
    if ($g.AdView) {
        try { $g.AdView.Dispose() } catch { }
        $g.AdView = $null
    }
}

#endregion

function New-MainWindow {
    Initialize-GuiTypes
    try { [void][MonitorRed.NativeMethods]::SetProcessDPIAware() } catch { }
    Import-AppData

    [xml]$xml = $script:Xaml
    $window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xml))
    # En pantallas pequeñas, que la ventana no sea más grande que el escritorio
    $area = [System.Windows.SystemParameters]::WorkArea
    $window.MinWidth = [Math]::Min($window.MinWidth, $area.Width)
    $window.MinHeight = [Math]::Min($window.MinHeight, $area.Height)
    $window.Width = [Math]::Min($window.Width, $area.Width)
    $window.Height = [Math]::Min($window.Height, $area.Height)

    $g = @{
        Window = $window; Session = $null; ByKey = @{}; ByIp = @{}; SeenKeys = @{}; EditingKey = $null
        HadHistory = ($script:Known.Count -gt 0); IsLaptop = (Test-IsLaptop); OuiJob = $null; LoadingSettings = $false
        UpnpPS = $null; UpnpSync = $null; UpnpHandle = $null; PrevSelf = $null; PrevTotal = $null; UpnpDisposing = (New-Object System.Collections.ArrayList)
    }
    $xamlNs = 'http://schemas.microsoft.com/winfx/2006/xaml'
    $nsm = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
    $nsm.AddNamespace('x', $xamlNs)
    foreach ($node in $xml.SelectNodes('//*[@x:Name]', $nsm)) {
        $name = $node.GetAttribute('Name', $xamlNs)
        $element = $window.FindName($name)
        if ($element) { $g[$name] = $element }
    }
    $script:Gui = $g

    # --- Lista ---
    $g.Devices = New-Object 'System.Collections.ObjectModel.ObservableCollection[MonitorRed.DeviceItem]'
    $g.DeviceGrid.ItemsSource = $g.Devices
    $g.View = [System.Windows.Data.CollectionViewSource]::GetDefaultView($g.Devices)
    $g.View.SortDescriptions.Add((New-Object System.ComponentModel.SortDescription('IsOnline', 'Descending')))
    $g.View.SortDescriptions.Add((New-Object System.ComponentModel.SortDescription('IpValue', 'Ascending')))
    $g.View.Filter = [Predicate[object]]{ param($d) Test-DeviceFilter $d }

    [void]$g.CbTypeFilter.Items.Add((New-ComboItem 'Todos los tipos' $null))
    [void]$g.CbType.Items.Add((New-ComboItem 'Automático' ''))
    foreach ($t in $script:DeviceTypes) {
        [void]$g.CbTypeFilter.Items.Add((New-ComboItem $t.Label $t.Key))
        [void]$g.CbType.Items.Add((New-ComboItem $t.Label $t.Key))
    }
    $g.CbTypeFilter.SelectedIndex = 0
    $g.ChkOffline.IsChecked = [bool]$script:Settings.ShowOffline

    # --- Redes ---
    $g.Networks = @([MonitorRed.Net]::GetLocalNetworks())
    foreach ($n in $g.Networks) { [void]$g.CbNetwork.Items.Add((New-ComboItem "$($n.Summary)  ($($n.LocalIp))" $n.LocalIp)) }
    if ($g.Networks.Count -gt 0) { $g.CbNetwork.SelectedIndex = 0 }
    $g.CbNetwork.Visibility = if ($g.Networks.Count -gt 1) { 'Visible' } else { 'Collapsed' }

    # --- Modos de medición ---
    $g.ModeItems = New-Object 'System.Collections.ObjectModel.ObservableCollection[MonitorRed.ModeItem]'
    foreach ($m in $script:MeasurementModes) {
        $item = New-Object MonitorRed.ModeItem
        $item.Id = $m.Id
        $item.Name = "$($m.Number). $($m.Name)"
        $item.Description = $m.Description
        $item.Scope = $m.Scope
        $item.Glyph = [string][char]$m.Glyph
        $item.Warning = $m.Warning
        $g.ModeItems.Add($item)
    }
    $g.ModeList.ItemsSource = $g.ModeItems
    [void]$g.CbRouterBrand.Items.Add((New-ComboItem 'Elige la marca...' ''))
    foreach ($b in $script:RouterBrandsPlanned) {
        $ready = [bool]($script:RouterConnectors | Where-Object { $_.Brand -eq $b })
        $label = if ($ready) { $b } else { "$b (próximamente)" }
        [void]$g.CbRouterBrand.Items.Add((New-ComboItem $label $b))
    }

    Import-KnownDevicesIntoList

    $g.Timer = New-Object System.Windows.Threading.DispatcherTimer
    $g.Timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $g.Timer.Add_Tick({ Update-ScanProgress })

    # Temporizador de medición del consumo (cada 2 s, mientras la ventana está abierta)
    $g.MeasureTimer = New-Object System.Windows.Threading.DispatcherTimer
    $g.MeasureTimer.Interval = [TimeSpan]::FromSeconds(2)
    $g.MeasureTimer.Add_Tick({ Update-Measurement })

    # --- Eventos ---
    $g.BtnScan.Add_Click({ Start-NetworkScan })
    $g.BtnSettings.Add_Click({ Show-Page 'PageSettings' })
    $g.BtnMeasureSettings.Add_Click({ Show-Page 'PageSettings' })
    $g.BtnBack.Add_Click({ Show-Page 'PageDevices' })
    $g.CbNetwork.Add_SelectionChanged({ if ($script:Gui.Session) { Start-NetworkScan } })
    $g.TxtSearch.Add_TextChanged({ Update-DeviceView })
    $g.CbTypeFilter.Add_SelectionChanged({ Update-DeviceView })
    $refreshOffline = {
        $script:Settings.ShowOffline = [bool]$script:Gui.ChkOffline.IsChecked
        Save-Settings
        Update-DeviceView
    }
    $g.ChkOffline.Add_Checked($refreshOffline)
    $g.ChkOffline.Add_Unchecked($refreshOffline)
    $g.DeviceGrid.Add_SelectionChanged({ Update-DetailPanel })
    $g.BtnExport.Add_Click({ Export-DeviceList })
    $g.BtnSaveDevice.Add_Click({ Save-DeviceEdit })
    $g.BtnResetDevice.Add_Click({ Reset-DeviceEdit })
    $g.TxtName.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { Save-DeviceEdit } })

    $g.PageSettings.AddHandler([System.Windows.Controls.Primitives.ToggleButton]::CheckedEvent, [System.Windows.RoutedEventHandler]{
        param($s, $e)
        if ($e.OriginalSource -is [System.Windows.Controls.RadioButton]) { Set-MeasurementMode ([string]$e.OriginalSource.Tag) }
    })
    $g.BtnSaveRouter.Add_Click({ Save-RouterSettings })
    $consent = {
        if ($script:Gui.LoadingSettings) { return }
        $script:Settings.InterceptConsent = [bool]$script:Gui.ChkIntercept.IsChecked
        Save-Settings
        Update-MeasurementUi
    }
    $g.ChkIntercept.Add_Checked($consent)
    $g.ChkIntercept.Add_Unchecked($consent)
    $g.BtnSupport.Add_Click({ Open-ExternalLink $script:SupportUrl })
    $g.BtnSupport.Visibility = if (Test-SupportConfigured) { 'Visible' } else { 'Collapsed' }
    $g.BtnOpenData.Add_Click({
        New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null
        Start-Process explorer.exe -ArgumentList "`"$script:DataDir`""
    })

    $window.Add_Closing({
        $g = $script:Gui
        if ($g.Session -is [MonitorRed.ScanSession]) { $g.Session.Cancel() }
        $g.Timer.Stop()
        $g.MeasureTimer.Stop()
        Stop-UpnpPoll
        Stop-InterceptCapture
        Stop-AdBanner
        Save-KnownDevices
    })

    $window.Add_ContentRendered({
        $script:Gui.MeasureTimer.Start()
        # La publicidad nunca debe impedir usar la app
        try { Start-AdBanner } catch { $script:Gui.AdBar.Visibility = 'Collapsed'; $script:Gui.AdState = 'NoDisponible'; $script:AdError = $_.Exception.Message }
        if (-not $script:AutoScan) { return }
        if (-not (Import-OuiDatabase)) { Start-OuiDownload }
        Start-NetworkScan
    })

    Show-Page 'PageDevices'
    Update-DeviceView
    Update-DetailPanel
    Update-MeasurementUi
    $window
}

function Show-MainWindow {
    $window = New-MainWindow
    [void]$window.ShowDialog()
}

#endregion

#region Inicio

try {
    if ($GenerarFabricantes) {
        Initialize-ScannerTypes
        $dest = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($GenerarFabricantes)
        $kind = Save-OuiDatabase $dest $Desde
        $from = if ($kind -eq 'ieee') { 'registro de la IEEE' } else { 'copia de Wireshark del registro de la IEEE' }
        Write-Host "Base de fabricantes ($from): $([MonitorRed.OuiDatabase]::Count) bloques de MAC → $dest" -ForegroundColor Green
    } elseif ($Escanear) {
        Invoke-ConsoleScan
    } else {
        Show-MainWindow
    }
} catch {
    if ($Escanear -or $GenerarFabricantes) {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show("Ocurrió un error:`n`n$($_.Exception.Message)", "$script:AppName - Error",
        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
}

#endregion
