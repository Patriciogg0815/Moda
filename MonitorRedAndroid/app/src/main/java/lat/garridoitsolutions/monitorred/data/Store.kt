package lat.garridoitsolutions.monitorred.data

import android.content.Context
import android.content.SharedPreferences
import lat.garridoitsolutions.monitorred.monitor.AlertInfo
import lat.garridoitsolutions.monitorred.monitor.AlertSettings
import lat.garridoitsolutions.monitorred.monitor.KnownDevice
import lat.garridoitsolutions.monitorred.monitor.NetworkState
import org.json.JSONArray
import org.json.JSONObject

data class AppSettings(
    val alerts: AlertSettings = AlertSettings(),
    // Revisión en segundo plano (Android permite como mínimo cada 15 minutos)
    val background: Boolean = true,
    // Con la app abierta, revisar cada tantos minutos
    val foregroundMinutes: Int = 2,
    val showOffline: Boolean = false,
    // Ya se explicó el permiso de notificaciones
    val askedNotifications: Boolean = false,
)

// Datos de la app en el teléfono: ajustes y, por cada red, los equipos vistos. Nada sale del teléfono.
class Store(context: Context) {
    private val prefs: SharedPreferences = context.applicationContext.getSharedPreferences("monitor", Context.MODE_PRIVATE)

    fun settings(): AppSettings = AppSettings(
        alerts = AlertSettings(
            alertNew = prefs.getBoolean("alertNew", true),
            alertOffline = prefs.getBoolean("alertOffline", true),
            namedOnly = prefs.getBoolean("alertNamedOnly", false),
        ),
        background = prefs.getBoolean("background", true),
        foregroundMinutes = prefs.getInt("foregroundMinutes", 2).coerceIn(1, 15),
        showOffline = prefs.getBoolean("showOffline", false),
        askedNotifications = prefs.getBoolean("askedNotifications", false),
    )

    fun saveSettings(s: AppSettings) {
        prefs.edit()
            .putBoolean("alertNew", s.alerts.alertNew)
            .putBoolean("alertOffline", s.alerts.alertOffline)
            .putBoolean("alertNamedOnly", s.alerts.namedOnly)
            .putBoolean("background", s.background)
            .putInt("foregroundMinutes", s.foregroundMinutes)
            .putBoolean("showOffline", s.showOffline)
            .putBoolean("askedNotifications", s.askedNotifications)
            .apply()
    }

    // Red de la última revisión (si cambia, no se avisan desconexiones)
    var lastNetworkId: String
        get() = prefs.getString("lastNetworkId", "").orEmpty()
        set(v) { prefs.edit().putString("lastNetworkId", v).apply() }

    fun load(networkId: String): NetworkState {
        val text = prefs.getString("net:$networkId", null) ?: return NetworkState(networkId)
        return runCatching { fromJson(networkId, JSONObject(text)) }.getOrDefault(NetworkState(networkId))
    }

    fun save(state: NetworkState) {
        prefs.edit().putString("net:${state.id}", toJson(state).toString()).commit()
    }

    companion object {
        fun toJson(s: NetworkState): JSONObject {
            val devices = JSONObject()
            for (d in s.devices.values) {
                devices.put(d.key, JSONObject()
                    .put("customName", d.customName).put("customType", d.customType)
                    .put("autoName", d.autoName).put("autoType", d.autoType).put("typeReason", d.typeReason)
                    .put("lastIp", d.lastIp).put("hostName", d.hostName).put("vendor", d.vendor).put("model", d.model)
                    .put("firstSeen", d.firstSeen).put("lastSeen", d.lastSeen).put("pingMs", d.pingMs)
                    .put("arrivedNew", d.arrivedNew))
            }
            val pending = JSONObject()
            for ((k, a) in s.pending) {
                pending.put(k, JSONObject().put("name", a.name).put("ip", a.ip).put("ipValue", a.ipValue)
                    .put("vendor", a.vendor).put("hasCustomName", a.hasCustomName).put("lastSeen", a.lastSeen))
            }
            return JSONObject().put("devices", devices).put("online", JSONArray(s.online.toList()))
                .put("pending", pending).put("rounds", s.rounds)
        }

        fun fromJson(id: String, o: JSONObject): NetworkState {
            val s = NetworkState(id, rounds = o.optInt("rounds"))
            val devices = o.optJSONObject("devices") ?: JSONObject()
            for (k in devices.keys()) {
                val d = devices.getJSONObject(k)
                s.devices[k] = KnownDevice(
                    key = k,
                    customName = d.optString("customName"), customType = d.optString("customType"),
                    autoName = d.optString("autoName"), autoType = d.optString("autoType", "unknown"),
                    typeReason = d.optString("typeReason"), lastIp = d.optString("lastIp"),
                    hostName = d.optString("hostName"), vendor = d.optString("vendor"), model = d.optString("model"),
                    firstSeen = d.optLong("firstSeen"), lastSeen = d.optLong("lastSeen"), pingMs = d.optInt("pingMs", -1),
                    arrivedNew = d.optBoolean("arrivedNew"),
                )
            }
            val online = o.optJSONArray("online") ?: JSONArray()
            for (i in 0 until online.length()) s.online += online.getString(i)
            val pending = o.optJSONObject("pending") ?: JSONObject()
            for (k in pending.keys()) {
                val a = pending.getJSONObject(k)
                s.pending[k] = AlertInfo(
                    key = k, name = a.optString("name"), ip = a.optString("ip"), ipValue = a.optLong("ipValue"),
                    vendor = a.optString("vendor"), hasCustomName = a.optBoolean("hasCustomName"), lastSeen = a.optLong("lastSeen"),
                )
            }
            return s
        }
    }
}
