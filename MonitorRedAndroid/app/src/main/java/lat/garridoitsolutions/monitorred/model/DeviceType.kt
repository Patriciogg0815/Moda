package lat.garridoitsolutions.monitorred.model

// Tipos de equipo, las mismas reglas que la versión de Windows (MonitorRed/MonitorRed.ps1).
// La clave se guarda en los datos de la app; el ícono lo elige la interfaz.
enum class DeviceType(val key: String, val label: String) {
    ROUTER("router", "Router"),
    COMPUTER("computer", "Computadora"),
    LAPTOP("laptop", "Laptop"),
    PHONE("phone", "Teléfono"),
    TABLET("tablet", "Tablet"),
    TV("tv", "TV / Streaming"),
    CONSOLE("console", "Consola de juegos"),
    SPEAKER("speaker", "Parlante / Asistente"),
    PRINTER("printer", "Impresora"),
    CAMERA("camera", "Cámara"),
    SMARTHOME("smarthome", "Hogar inteligente"),
    APPLIANCE("appliance", "Electrodoméstico"),
    NAS("nas", "Almacenamiento (NAS)"),
    NETWORK("network", "Equipo de red"),
    UNKNOWN("unknown", "Desconocido");

    companion object {
        fun fromKey(key: String?): DeviceType = entries.firstOrNull { it.key == key } ?: UNKNOWN
    }
}

data class Guess(val type: DeviceType, val reason: String)

object DeviceRules {
    // Pistas en el nombre del equipo (host, mDNS, NetBIOS, UPnP). Se prueban en este orden.
    private val nameRules = listOf(
        DeviceType.CONSOLE to """xbox|playstation|\bps[345]\b|ps[345]-|nintendo|steam-?deck""",
        DeviceType.TV to """\btv\b|-tv|tv-|smart-?tv|bravia|roku|chromecast|fire-?tv|firestick|apple-?tv|webos|tizen|android-?tv|google-?tv|shield|vizio|hisense|vidaa|mi-?box|tivo|kodi|\[tv\]""",
        DeviceType.SPEAKER to """sonos|\becho\b|echo-|alexa|google-?home|nest-?(mini|audio|hub)|homepod|bose|\bjbl\b|denon|marantz|soundbar""",
        DeviceType.PRINTER to """printer|impresora|officejet|deskjet|laserjet|pagewide|epson|\bet-\d|brother|\bmfc-|\bdcp-|\bhl-|canon|pixma|xerox|lexmark|kyocera|ricoh""",
        DeviceType.CAMERA to """camera|camara|\bcam\b|-cam|cam-|ipcam|\bipc\b|hikvision|dahua|wyze|ezviz|reolink|imou|arlo|\bring-|blink|doorbell|timbre|tapo-?c\d""",
        DeviceType.NAS to """synology|diskstation|qnap|my-?cloud|truenas|freenas|unraid|\bnas\b|-nas""",
        DeviceType.APPLIANCE to """roomba|irobot|roborock|deebot|ecovacs|dyson|vacuum|aspiradora|washer|lavadora|dryer|secadora|fridge|refrigerador|nevera|heladera|\boven\b|horno|dishwasher|lavavajillas|aircon|\bac-|midea|haier|whirlpool|thinq|miele|electrolux|frigidaire""",
        DeviceType.TABLET to """ipad|galaxy-?tab|\btab\b|tab-|tablet|kindle|fire-?hd|mediapad|matepad""",
        DeviceType.LAPTOP to """laptop|notebook|macbook|thinkpad|ideapad|vivobook|zenbook|inspiron|latitude|pavilion|elitebook|probook|surface|galaxy-?book|chromebook""",
        DeviceType.PHONE to """iphone|android|galaxy|\bsm-[a-z]\d|pixel|redmi|xiaomi|\bpoco|motorola|\bmoto|huawei|honor|oneplus|oppo|\bvivo\b|realme|nokia|phone|celular|telefono""",
        DeviceType.COMPUTER to """desktop|\bpc\b|-pc|pc-|imac|mac-?mini|mac-?pro|workstation|raspberry|\bwin-|windows|ubuntu|debian|fedora|server|servidor""",
        DeviceType.SMARTHOME to """esp[_-]|esp32|esp8266|tasmota|shelly|sonoff|tuya|smartlife|smart-?plug|enchufe|\bkasa|\bhs1\d\d|\bkp\d{3}|tapo-?p\d|philips-?hue|\bhue\b|\bwiz\b|yeelight|meross|govee|broadlink|lifx|nanoleaf|ecobee|thermostat|termostato|netatmo|\bnest\b|switchbot|aqara|zigbee""",
        DeviceType.NETWORK to """repeater|repetidor|extender|\bap-|access-?point|\bmesh\b|\bdeco\b|eero|orbi|velop|unifi|mikrotik|powerline|tl-wa|\bre\d{3}\b""",
    ).map { (t, p) -> t to Regex(p) }

    // Pistas en el fabricante (lo informa el equipo por UPnP). Se usan si el nombre no dice nada.
    private val vendorRules = listOf(
        DeviceType.CONSOLE to """nintendo|sony interactive""",
        DeviceType.CAMERA to """hikvision|dahua|wyze|ezviz|reolink|\bring\b|arlo|axis communications|imou|hanwha|uniview""",
        DeviceType.PRINTER to """hewlett|\bhp inc|epson|canon|brother|xerox|lexmark|kyocera|ricoh|konica|zebra""",
        DeviceType.NAS to """synology|qnap|western digital|buffalo|asustor""",
        DeviceType.SPEAKER to """sonos|bose|harman|denon|sound united|bang & olufsen|amazon""",
        DeviceType.TV to """roku|vizio|hisense|\btcl\b|tp vision|funai|skyworth|sharp|vestel|tivo|nvidia|lg electronics|\bsony\b|google|samsung electronics""",
        DeviceType.APPLIANCE to """irobot|roborock|ecovacs|dyson|midea|haier|whirlpool|bsh hausger|miele|electrolux|lg innotek|daikin|\bgree\b""",
        DeviceType.SMARTHOME to """espressif|tuya|shelly|allterco|itead|signify|philips lighting|lifx|nanoleaf|ecobee|netatmo|nest labs|switchbot|wonder labs|lumi united|broadlink|meross|govee|wiz connected""",
        DeviceType.NETWORK to """tp-?link|netgear|d-link|ubiquiti|zyxel|tenda|mercusys|eero|linksys|belkin|cisco|mikrotik|huawei|zte|fiberhome|arcadyan|sagemcom|technicolor|askey|arris|hitron|cudy|totolink""",
    ).map { (t, p) -> t to Regex(p) }

    fun guess(host: HostInfo): Guess {
        if (host.isGateway) return Guess(DeviceType.ROUTER, "Es la puerta de enlace de la red (el router).")
        if (host.isSelf) return Guess(DeviceType.PHONE, "Es este teléfono.")

        val upnpText = StringBuilder()
        for (u in host.upnp) {
            val dt = u.deviceType
            val mfr = u.manufacturer
            if (Regex("InternetGatewayDevice|WANDevice|WANConnectionDevice").containsMatchIn(dt)) return Guess(DeviceType.ROUTER, "Se anuncia por UPnP como router.")
            if (dt.contains("ZonePlayer")) return Guess(DeviceType.SPEAKER, "Se anuncia por UPnP como parlante.")
            if (dt.contains("Printer")) return Guess(DeviceType.PRINTER, "Se anuncia por UPnP como impresora.")
            if (Regex("WLANAccessPoint|WFADevice").containsMatchIn(dt)) return Guess(DeviceType.NETWORK, "Se anuncia por UPnP como punto de acceso Wi-Fi.")
            if (Regex("MediaRenderer|dial", RegexOption.IGNORE_CASE).containsMatchIn(dt)) {
                if (Regex("sonos|bose|denon|marantz|yamaha|harman|jbl|bang", RegexOption.IGNORE_CASE).containsMatchIn(mfr)) {
                    return Guess(DeviceType.SPEAKER, "Reproductor multimedia UPnP de $mfr.")
                }
                return Guess(DeviceType.TV, "Se anuncia por UPnP como pantalla o reproductor multimedia.")
            }
            upnpText.append(' ').append(u.friendlyName).append(' ').append(u.modelName).append(' ').append(u.modelDescription)
        }

        val hay = listOf(host.mdnsName, host.netBiosName, host.dnsName, upnpText.toString())
            .filter { it.isNotBlank() }.joinToString(" ").replace(Regex("\\s+"), " ").lowercase()
        if (hay.isNotBlank()) {
            for ((type, rule) in nameRules) {
                val m = rule.find(hay) ?: continue
                val hint = m.value.trim(' ', '-', '[', ']')
                return Guess(type, "Por el nombre del equipo («$hint»).")
            }
        }

        val vendor = host.upnp.firstOrNull { it.manufacturer.isNotBlank() }?.manufacturer.orEmpty()
        if (vendor.isNotBlank()) {
            val v = vendor.lowercase()
            for ((type, rule) in vendorRules) {
                if (rule.containsMatchIn(v)) return Guess(type, "Por el fabricante que informa el equipo ($vendor). Es una estimación.")
            }
        }
        return Guess(DeviceType.UNKNOWN, "No hay datos suficientes para saber qué es. Puedes elegir el tipo a mano.")
    }

    fun shortHostName(name: String): String {
        val n = name.trim().trimEnd('.')
        if (n.isEmpty() || Regex("""^\d+(\.\d+){3}$""").matches(n)) return ""
        return n.substringBefore('.').ifEmpty { n }
    }

    // El mejor nombre que se averiguó: mDNS (Apple, Android, Chromecast), NetBIOS (Windows) o DNS del router
    fun bestHostName(host: HostInfo): String =
        listOf(host.mdnsName, host.netBiosName, shortHostName(host.dnsName)).firstOrNull { it.isNotBlank() }?.trim().orEmpty()

    fun mainUpnp(host: HostInfo): UpnpInfo? {
        var root: UpnpInfo? = null
        val important = Regex("MediaRenderer|InternetGatewayDevice|Printer|ZonePlayer")
        for (u in host.upnp) {
            if (u.friendlyName.isBlank() && u.modelName.isBlank()) continue
            if (root == null) root = u
            // El dispositivo más descriptivo (la TV antes que su servicio DIAL, etc.)
            if (important.containsMatchIn(u.deviceType) && !important.containsMatchIn(root.deviceType)) root = u
        }
        return root
    }

    fun autoName(host: HostInfo, type: DeviceType, selfName: String): String {
        if (host.isSelf) return "$selfName (este teléfono)"
        val upnp = mainUpnp(host)
        val vendor = upnp?.manufacturer.orEmpty()
        if (upnp != null && upnp.friendlyName.isNotBlank() && !Regex("^(uuid:|[0-9a-f-]{20,})", RegexOption.IGNORE_CASE).containsMatchIn(upnp.friendlyName)) {
            return upnp.friendlyName
        }
        val hostName = bestHostName(host)
        if (hostName.isNotBlank()) return hostName
        if (host.isGateway) return if (vendor.isNotBlank()) "Router $vendor" else "Router"
        if (type == DeviceType.UNKNOWN) return if (vendor.isNotBlank()) "Equipo $vendor" else "Equipo sin nombre"
        return if (vendor.isNotBlank()) "${type.label} $vendor" else type.label
    }
}
