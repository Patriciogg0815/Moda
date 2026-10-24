package lat.garridoitsolutions.monitorred.model

// Lo que averiguó el escáner sobre una IP de la red
data class HostInfo(
    val ip: String,
    val ipValue: Long,
    val pingMs: Int = -1,
    val isSelf: Boolean = false,
    val isGateway: Boolean = false,
    // Android 10 o más nuevo no deja leer la MAC de los demás equipos: casi siempre queda vacía
    val mac: String = "",
    val dnsName: String = "",
    val netBiosName: String = "",
    val mdnsName: String = "",
    val upnp: List<UpnpInfo> = emptyList(),
)

data class UpnpInfo(
    val location: String,
    val udn: String = "",
    val deviceType: String = "",
    val friendlyName: String = "",
    val manufacturer: String = "",
    val modelName: String = "",
    val modelDescription: String = "",
    val wanControlUrl: String = "",
    val wanServiceType: String = "",
)

data class LocalNetwork(
    val localIp: String,
    val prefix: Int,
    val gateway: String,
    val interfaceName: String,
) {
    val firstHost: Long get() = Ipv4.networkStart(Ipv4.toLong(localIp), effectivePrefix) + 1
    val lastHost: Long get() = Ipv4.networkStart(Ipv4.toLong(localIp), effectivePrefix) + Ipv4.size(effectivePrefix) - 2
    // Las redes muy grandes se escanean solo en la parte de este teléfono (/24), como en Windows
    val effectivePrefix: Int get() = when {
        prefix < 22 -> 24
        prefix > 30 -> 30
        else -> prefix
    }
    val isLimited: Boolean get() = prefix < 22
    val summary: String get() = "${Ipv4.toText(Ipv4.networkStart(Ipv4.toLong(localIp), effectivePrefix))}/$effectivePrefix"
    // Identifica la red para guardar sus equipos por separado
    val id: String get() = "$gateway|$summary"
}

object Ipv4 {
    fun toLong(ip: String): Long {
        val p = ip.trim().split('.')
        require(p.size == 4) { "IP no válida: $ip" }
        return p.fold(0L) { acc, s -> (acc shl 8) or (s.toInt().also { require(it in 0..255) }).toLong() }
    }

    fun toText(v: Long): String = "${(v shr 24) and 255}.${(v shr 16) and 255}.${(v shr 8) and 255}.${v and 255}"
    fun size(prefix: Int): Long = 1L shl (32 - prefix)
    fun networkStart(ip: Long, prefix: Int): Long = ip and (0xFFFFFFFFL shl (32 - prefix)) and 0xFFFFFFFFL
}
