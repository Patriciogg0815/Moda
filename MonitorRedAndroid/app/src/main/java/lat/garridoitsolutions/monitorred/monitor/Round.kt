package lat.garridoitsolutions.monitorred.monitor

import lat.garridoitsolutions.monitorred.model.DeviceRules
import lat.garridoitsolutions.monitorred.model.DeviceType
import lat.garridoitsolutions.monitorred.model.HostInfo
import lat.garridoitsolutions.monitorred.model.LocalNetwork

// Un equipo que la app ya vio en esta red (se guarda en el teléfono)
data class KnownDevice(
    val key: String,
    var customName: String = "",
    var customType: String = "",
    var autoName: String = "",
    var autoType: String = DeviceType.UNKNOWN.key,
    var typeReason: String = "",
    var lastIp: String = "",
    var hostName: String = "",
    var vendor: String = "",
    var model: String = "",
    var firstSeen: Long = 0,
    var lastSeen: Long = 0,
    var pingMs: Int = -1,
    // Apareció cuando la app ya conocía la red (para la insignia "Nuevo")
    var arrivedNew: Boolean = false,
) {
    val displayName: String get() = customName.ifBlank { autoName.ifBlank { "Equipo sin nombre" } }
    val type: DeviceType get() = DeviceType.fromKey(customType.ifBlank { autoType })
}

// Todo lo que se recuerda de una red
data class NetworkState(
    val id: String,
    val devices: MutableMap<String, KnownDevice> = LinkedHashMap(),
    // Equipos en línea en la última revisión
    val online: MutableSet<String> = LinkedHashSet(),
    val pending: MutableMap<String, AlertInfo> = LinkedHashMap(),
    var rounds: Int = 0,
)

// Fila de la lista de equipos
data class DeviceItem(
    val key: String,
    val name: String,
    val autoName: String,
    val customName: String,
    val type: DeviceType,
    val isCustomType: Boolean,
    val typeReason: String,
    val ip: String,
    val ipValue: Long,
    val hostName: String,
    val vendor: String,
    val model: String,
    val online: Boolean,
    val pingMs: Int,
    val isSelf: Boolean,
    val isGateway: Boolean,
    val isNew: Boolean,
    val firstSeen: Long,
    val lastSeen: Long,
)

data class RoundResult(val alerts: Alerts, val newKeys: Set<String>)

object Round {
    const val SELF = "SELF"
    const val ROUTER = "ROUTER"
    private const val NEW_BADGE_MS = 24L * 60 * 60 * 1000

    /**
     * Identidad del equipo sin MAC (Android no la deja leer): el identificador UPnP, o si no su nombre
     * (mDNS, NetBIOS o DNS). Si no anuncia nada se reconoce por su IP (ver [apply]).
     */
    fun strongId(h: HostInfo): String? = when {
        h.isSelf -> SELF
        h.isGateway -> ROUTER
        h.mac.isNotBlank() -> "MAC:${h.mac.uppercase()}"
        h.upnp.any { it.udn.isNotBlank() } -> "UPNP:${h.upnp.first { it.udn.isNotBlank() }.udn.lowercase()}"
        DeviceRules.bestHostName(h).isNotBlank() -> "HOST:${DeviceRules.bestHostName(h).lowercase()}"
        else -> null
    }

    /**
     * Aplica el resultado de una revisión a lo que se recuerda de la red y decide qué avisar.
     * [sameNetworkAsBefore]: la revisión anterior fue en esta misma red (si no, no se avisan desconexiones).
     */
    fun apply(
        state: NetworkState,
        net: LocalNetwork,
        hosts: List<HostInfo>,
        scanOk: Boolean,
        sameNetworkAsBefore: Boolean,
        settings: AlertSettings,
        selfName: String,
        now: Long,
    ): RoundResult {
        val hadHistory = state.rounds > 0 && state.devices.isNotEmpty()
        val used = HashSet<String>()
        val newKeys = LinkedHashSet<String>()
        // Primero los que se identifican solos, para que el reconocimiento por IP no les quite el lugar
        val ordered = hosts.sortedBy { if (strongId(it) != null) 0 else 1 }
        for (h in ordered) {
            val key = resolveKey(state, h, used)
            used += key
            val guess = DeviceRules.guess(h)
            val upnp = DeviceRules.mainUpnp(h)
            val known = state.devices.getOrPut(key) {
                newKeys += key
                KnownDevice(key = key, firstSeen = now, arrivedNew = hadHistory && !h.isSelf && !h.isGateway)
            }
            known.lastIp = h.ip
            known.autoName = DeviceRules.autoName(h, guess.type, selfName)
            known.autoType = guess.type.key
            known.typeReason = guess.reason
            known.hostName = DeviceRules.bestHostName(h).ifBlank { known.hostName }
            upnp?.let {
                if (it.manufacturer.isNotBlank()) known.vendor = it.manufacturer
                val model = listOf(it.manufacturer, it.modelName).filter { s -> s.isNotBlank() }.joinToString(" ")
                if (model.isNotBlank()) known.model = model
            }
            known.pingMs = h.pingMs
            known.lastSeen = now
        }

        val missing = (state.online - used).filter { it != SELF && it != ROUTER }
            .mapNotNull { state.devices[it]?.let { d -> it to d.toAlertInfo() } }.toMap()
        val gatewaySeen = net.gateway.isBlank() || hosts.any { it.isGateway }
        val networkOk = scanOk && sameNetworkAsBefore && gatewaySeen && state.rounds > 0
        val newDevices = if (hadHistory) {
            newKeys.filter { it != SELF && it != ROUTER }.mapNotNull { k -> state.devices[k]?.let { k to it.toAlertInfo() } }.toMap()
        } else emptyMap()
        val alerts = AlertRules.decide(settings, newDevices, missing, used, state.pending, networkOk)

        state.online.clear()
        state.online += used
        state.rounds++
        return RoundResult(alerts, newKeys)
    }

    private fun resolveKey(state: NetworkState, h: HostInfo, used: Set<String>): String {
        val sid = strongId(h)
        if (sid != null && sid in state.devices) return sid
        // Mismo equipo en la misma IP: se reconoce aunque esta vez no haya dicho su nombre
        val byIp = state.devices.values.firstOrNull {
            it.lastIp == h.ip && it.key !in used && it.key != SELF && it.key != ROUTER && (sid == null || it.key.startsWith("IP:"))
        }
        if (byIp == null) return sid ?: "IP:${h.ip}"
        if (sid == null) return byIp.key
        // Se conocía solo por la IP y ahora dijo su nombre: se pasa a recordar por el nombre (con el nombre puesto a mano)
        state.devices.remove(byIp.key)
        state.devices[sid] = byIp.copy(key = sid)
        if (state.online.remove(byIp.key)) state.online += sid
        state.pending.remove(byIp.key)?.let { state.pending[sid] = it.copy(key = sid) }
        return sid
    }

    fun KnownDevice.toAlertInfo() = AlertInfo(
        key = key, name = displayName, ip = lastIp, ipValue = ipValueOf(lastIp), vendor = vendor,
        hasCustomName = customName.isNotBlank(), lastSeen = lastSeen,
    )

    fun items(state: NetworkState, now: Long): List<DeviceItem> = state.devices.values.map { d ->
        val online = d.key in state.online
        DeviceItem(
            key = d.key, name = d.displayName, autoName = d.autoName, customName = d.customName,
            type = d.type, isCustomType = d.customType.isNotBlank(),
            typeReason = if (d.customType.isNotBlank()) "Elegido por ti. La app había estimado: ${DeviceType.fromKey(d.autoType).label}." else d.typeReason,
            ip = d.lastIp, ipValue = ipValueOf(d.lastIp), hostName = d.hostName, vendor = d.vendor, model = d.model,
            online = online, pingMs = if (online) d.pingMs else -1,
            isSelf = d.key == SELF, isGateway = d.key == ROUTER,
            isNew = d.arrivedNew && now - d.firstSeen < NEW_BADGE_MS,
            firstSeen = d.firstSeen, lastSeen = d.lastSeen,
        )
    }.sortedWith(compareByDescending<DeviceItem> { it.online }.thenBy { it.ipValue })

    private fun ipValueOf(ip: String): Long = runCatching {
        ip.split('.').fold(0L) { acc, s -> (acc shl 8) or s.toLong() }
    }.getOrDefault(0L)
}
