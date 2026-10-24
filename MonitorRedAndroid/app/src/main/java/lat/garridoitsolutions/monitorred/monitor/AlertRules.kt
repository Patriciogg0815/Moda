package lat.garridoitsolutions.monitorred.monitor

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit

data class AlertInfo(
    val key: String,
    val name: String,
    val ip: String,
    val ipValue: Long = 0,
    val vendor: String = "",
    val hasCustomName: Boolean = false,
    // Última vez que se vio (milisegundos), 0 si no se sabe
    val lastSeen: Long = 0,
)

data class Alerts(val new: List<AlertInfo>, val offline: List<AlertInfo>) {
    val isEmpty: Boolean get() = new.isEmpty() && offline.isEmpty()
}

data class AlertMessage(val title: String, val text: String, val key: String, val isOffline: Boolean)

data class AlertSettings(val alertNew: Boolean = true, val alertOffline: Boolean = true, val namedOnly: Boolean = false) {
    val enabled: Boolean get() = alertNew || alertOffline
}

// Mismas reglas que la versión de Windows (Get-NetworkAlerts y Format-AlertMessage en MonitorRed.ps1)
object AlertRules {
    /**
     * Decide qué avisar al terminar una revisión de la red.
     * [pending] son las desconexiones por confirmar y se modifica: un equipo se da por desconectado
     * recién cuando falta en 2 revisiones seguidas, para no avisar por un corte de un momento.
     * Si [networkOk] es false (otra red, error, el router no respondió) no se avisa ninguna desconexión,
     * porque parecería que se apagaron todos los equipos.
     */
    fun decide(
        settings: AlertSettings,
        newDevices: Map<String, AlertInfo>,
        missing: Map<String, AlertInfo>,
        seen: Set<String>,
        pending: MutableMap<String, AlertInfo>,
        networkOk: Boolean,
    ): Alerts {
        val offline = mutableListOf<AlertInfo>()
        if (networkOk) {
            for (key in pending.keys.toList()) {
                val info = pending.remove(key) ?: continue
                if (key in seen) continue
                if (settings.alertOffline && (!settings.namedOnly || info.hasCustomName)) offline += info
            }
            pending.putAll(missing)
        } else {
            pending.clear()
        }
        val new = if (settings.alertNew) newDevices.values.sortedBy { it.ipValue } else emptyList()
        return Alerts(new, offline.sortedBy { it.name })
    }

    fun limit(text: String, max: Int): String = if (text.length <= max) text else text.take(max - 1).trimEnd() + "…"

    fun format(alerts: Alerts, now: Long = System.currentTimeMillis()): AlertMessage? {
        if (alerts.isEmpty) return null
        fun names(list: List<AlertInfo>) = list.joinToString(", ") { "«${it.name}»" }
        val first = alerts.new.firstOrNull() ?: alerts.offline.first()
        val (title, text) = when {
            alerts.new.isNotEmpty() && alerts.offline.isNotEmpty() ->
                "Cambios en tu red" to "Se conectó: ${names(alerts.new)}. Se desconectó: ${names(alerts.offline)}."
            alerts.new.size == 1 ->
                "Se conectó un equipo nuevo" to "«${first.name}» · IP ${first.ip}" + (if (first.vendor.isNotBlank()) " · ${first.vendor}" else "")
            alerts.new.size > 1 ->
                "Se conectaron ${alerts.new.size} equipos nuevos" to names(alerts.new)
            alerts.offline.size == 1 -> {
                val seen = formatLastSeen(first.lastSeen, now)
                "Se desconectó «${first.name}»" to "Se apagó o salió de la red. " + (if (seen.isNotEmpty()) "Visto por última vez: $seen · " else "") + "IP ${first.ip}"
            }
            else -> "Se desconectaron ${alerts.offline.size} equipos" to names(alerts.offline)
        }
        return AlertMessage(limit(title, 63), limit(text, 250), first.key, alerts.new.isEmpty())
    }

    fun formatLastSeen(millis: Long, now: Long = System.currentTimeMillis(), zone: ZoneId = ZoneId.systemDefault()): String {
        if (millis <= 0) return ""
        val t = Instant.ofEpochMilli(millis).atZone(zone)
        val days = ChronoUnit.DAYS.between(t.toLocalDate(), Instant.ofEpochMilli(now).atZone(zone).toLocalDate())
        val hour = t.format(DateTimeFormatter.ofPattern("HH:mm"))
        return when {
            days <= 0 -> "hoy $hour"
            days == 1L -> "ayer $hour"
            days < 30 -> "hace $days días"
            else -> t.format(DateTimeFormatter.ofPattern("dd/MM/yyyy"))
        }
    }
}
