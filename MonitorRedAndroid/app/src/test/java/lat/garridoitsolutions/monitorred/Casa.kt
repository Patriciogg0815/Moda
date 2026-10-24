package lat.garridoitsolutions.monitorred

import lat.garridoitsolutions.monitorred.model.HostInfo
import lat.garridoitsolutions.monitorred.model.Ipv4
import lat.garridoitsolutions.monitorred.model.LocalNetwork
import lat.garridoitsolutions.monitorred.model.UpnpInfo

// Casa de ejemplo para las pruebas y las capturas (la misma de la versión de Windows, sin las MAC)
object Casa {
    val red = LocalNetwork(localIp = "192.168.1.10", prefix = 24, gateway = "192.168.1.1", interfaceName = "wlan0")

    fun host(ip: String, ping: Int = 5, mdns: String = "", netBios: String = "", dns: String = "", upnp: List<UpnpInfo> = emptyList()) =
        HostInfo(ip, Ipv4.toLong(ip), ping, isSelf = ip == red.localIp, isGateway = ip == red.gateway, dnsName = dns, netBiosName = netBios, mdnsName = mdns, upnp = upnp)

    fun upnp(type: String, name: String, maker: String, model: String, udn: String = "") =
        UpnpInfo(location = "http://x/desc.xml", udn = udn, deviceType = type, friendlyName = name, manufacturer = maker, modelName = model)

    val router = host("192.168.1.1", 1, upnp = listOf(upnp("urn:schemas-upnp-org:device:InternetGatewayDevice:1", "Archer C6", "TP-Link", "Archer C6", "uuid:router")))
    val telefono = host("192.168.1.10", 0, mdns = "Galaxy S23 de Patricio")
    val iphone = host("192.168.1.23", 18, mdns = "iPhone-de-Ana")
    val tv = host("192.168.1.31", 4, upnp = listOf(upnp("urn:schemas-upnp-org:device:MediaRenderer:1", "[TV] Samsung Q60 Series (55)", "Samsung Electronics", "QN55Q60B", "uuid:tv-sala")))
    val chromecast = host("192.168.1.32", 6, mdns = "Chromecast-Living")
    val sonos = host("192.168.1.40", 9, upnp = listOf(upnp("urn:schemas-upnp-org:device:ZonePlayer:1", "Sala - Sonos One", "Sonos, Inc.", "Sonos One", "uuid:sonos")))
    val impresora = host("192.168.1.44", 4, netBios = "HP-OFFICEJET")
    val laptop = host("192.168.1.81", 7, netBios = "LAPTOP-JUAN")
    val enchufe = host("192.168.1.61", 25, dns = "ESP_3F2A1B.lan")
    val redmi = host("192.168.1.80", 41, dns = "Redmi-Note-12.lan")
    val camara = host("192.168.1.70", 5, dns = "tapo-c200.lan")
    val playstation = host("192.168.1.50", 2, dns = "PS5-123.lan")
    val sinNombre = host("192.168.1.95", -1)

    val todos = listOf(router, telefono, iphone, tv, chromecast, sonos, impresora, laptop, enchufe, redmi, camara, playstation, sinNombre)
}
