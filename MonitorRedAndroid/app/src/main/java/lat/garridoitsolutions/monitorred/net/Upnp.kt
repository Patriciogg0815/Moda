package lat.garridoitsolutions.monitorred.net

import lat.garridoitsolutions.monitorred.model.UpnpInfo
import java.net.DatagramPacket
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.MulticastSocket
import java.net.SocketTimeoutException
import java.net.URI
import java.net.URL

// UPnP: TVs, consolas, parlantes, impresoras y el router se anuncian por SSDP con su nombre y modelo.
// El router además puede informar los bytes totales de internet (consumo de toda la casa).
object Upnp {
    private const val GROUP = "239.255.255.250"

    // Busca dispositivos durante unos segundos. Devuelve IP -> direcciones de su descripción (LOCATION).
    // En Android hace falta un MulticastLock activo mientras se llama (lo toma el escáner).
    fun discover(timeoutMs: Int): Map<String, List<String>> {
        val found = LinkedHashMap<String, MutableList<String>>()
        runCatching {
            MulticastSocket(null as InetSocketAddress?).use { socket ->
                socket.reuseAddress = true
                socket.bind(InetSocketAddress(0))
                socket.timeToLive = 2
                socket.soTimeout = 300
                val group = InetSocketAddress(InetAddress.getByName(GROUP), 1900)
                for (st in listOf("ssdp:all", "upnp:rootdevice", "urn:schemas-upnp-org:device:InternetGatewayDevice:1")) {
                    val msg = "M-SEARCH * HTTP/1.1\r\nHOST: $GROUP:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: $st\r\n\r\n".toByteArray()
                    socket.send(DatagramPacket(msg, msg.size, group))
                }
                val end = System.currentTimeMillis() + timeoutMs
                val buf = ByteArray(4096)
                while (System.currentTimeMillis() < end) {
                    val packet = DatagramPacket(buf, buf.size)
                    try {
                        socket.receive(packet)
                    } catch (_: SocketTimeoutException) {
                        continue
                    }
                    val text = String(packet.data, 0, packet.length, Charsets.UTF_8)
                    val location = header(text, "LOCATION")
                    if (location.isEmpty()) continue
                    val ip = packet.address.hostAddress ?: continue
                    val list = found.getOrPut(ip) { mutableListOf() }
                    if (location !in list && list.size < 4) list.add(location)
                }
            }
        }
        return found
    }

    fun header(text: String, name: String): String =
        Regex("^$name\\s*:\\s*(.*?)\\s*$", setOf(RegexOption.IGNORE_CASE, RegexOption.MULTILINE)).find(text)?.groupValues?.get(1).orEmpty()

    fun fetchDescription(location: String, timeoutMs: Int): UpnpInfo = runCatching {
        val conn = URL(location).openConnection() as HttpURLConnection
        conn.connectTimeout = timeoutMs
        conn.readTimeout = timeoutMs
        conn.setRequestProperty("User-Agent", "MonitorRed/1.0 UPnP/1.1")
        val xml = conn.inputStream.use { input ->
            val bytes = input.readNBytesCompat(262144)
            String(bytes, Charsets.UTF_8)
        }
        conn.disconnect()
        parseDescription(location, xml)
    }.getOrDefault(UpnpInfo(location))

    fun parseDescription(location: String, xml: String): UpnpInfo {
        var control = ""
        var serviceType = ""
        for (s in Regex("<service>(.*?)</service>", setOf(RegexOption.DOT_MATCHES_ALL, RegexOption.IGNORE_CASE)).findAll(xml)) {
            val st = tag(s.groupValues[1], "serviceType")
            if (!st.contains("WANCommonInterfaceConfig", ignoreCase = true)) continue
            val c = tag(s.groupValues[1], "controlURL")
            if (c.isEmpty()) continue
            val base = tag(xml, "URLBase").ifEmpty { location }
            control = runCatching { URI(base).resolve(c).toString() }.getOrDefault(c)
            serviceType = st
            break
        }
        return UpnpInfo(
            location = location,
            udn = tag(xml, "UDN"),
            deviceType = tag(xml, "deviceType"),
            friendlyName = tag(xml, "friendlyName"),
            manufacturer = tag(xml, "manufacturer"),
            modelName = tag(xml, "modelName"),
            modelDescription = tag(xml, "modelDescription"),
            wanControlUrl = control,
            wanServiceType = serviceType,
        )
    }

    private fun tag(xml: String, tag: String): String {
        val m = Regex("<$tag>\\s*(.*?)\\s*</$tag>", setOf(RegexOption.DOT_MATCHES_ALL, RegexOption.IGNORE_CASE)).find(xml) ?: return ""
        return decode(m.groupValues[1]).trim()
    }

    private fun decode(s: String): String =
        s.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&apos;", "'").replace("&amp;", "&")

    // Bytes totales de internet que pasaron por el router desde que se encendió, o -1 si no responde.
    fun totalBytes(controlUrl: String, serviceType: String, received: Boolean, timeoutMs: Int): Long = runCatching {
        val action = if (received) "GetTotalBytesReceived" else "GetTotalBytesSent"
        val tagName = if (received) "NewTotalBytesReceived" else "NewTotalBytesSent"
        val body = "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" " +
            "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:$action xmlns:u=\"$serviceType\"></u:$action></s:Body></s:Envelope>"
        val conn = URL(controlUrl).openConnection() as HttpURLConnection
        conn.requestMethod = "POST"
        conn.connectTimeout = timeoutMs
        conn.readTimeout = timeoutMs
        conn.doOutput = true
        conn.setRequestProperty("Content-Type", "text/xml; charset=\"utf-8\"")
        conn.setRequestProperty("SOAPACTION", "\"$serviceType#$action\"")
        conn.outputStream.use { it.write(body.toByteArray()) }
        val xml = conn.inputStream.use { String(it.readBytes(), Charsets.UTF_8) }
        conn.disconnect()
        tag(xml, tagName).toLongOrNull()?.takeIf { it >= 0 } ?: -1L
    }.getOrDefault(-1L)

    private fun java.io.InputStream.readNBytesCompat(max: Int): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        val buf = ByteArray(8192)
        while (out.size() < max) {
            val n = read(buf, 0, minOf(buf.size, max - out.size()))
            if (n < 0) break
            out.write(buf, 0, n)
        }
        return out.toByteArray()
    }
}
