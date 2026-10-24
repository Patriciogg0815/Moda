package lat.garridoitsolutions.monitorred.ui

import android.app.Application
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.TrafficStats
import android.os.SystemClock
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import lat.garridoitsolutions.monitorred.data.AppSettings
import lat.garridoitsolutions.monitorred.data.Store
import lat.garridoitsolutions.monitorred.model.LocalNetwork
import lat.garridoitsolutions.monitorred.model.UpnpInfo
import lat.garridoitsolutions.monitorred.monitor.AlertInfo
import lat.garridoitsolutions.monitorred.monitor.AlertRules
import lat.garridoitsolutions.monitorred.monitor.Alerts
import lat.garridoitsolutions.monitorred.monitor.DeviceItem
import lat.garridoitsolutions.monitorred.monitor.Monitor
import lat.garridoitsolutions.monitorred.monitor.Notifier
import lat.garridoitsolutions.monitorred.monitor.Round
import lat.garridoitsolutions.monitorred.monitor.RoundOutcome
import lat.garridoitsolutions.monitorred.monitor.WatchWorker
import lat.garridoitsolutions.monitorred.net.NetworkInfo
import lat.garridoitsolutions.monitorred.net.Upnp
import java.text.DecimalFormat
import java.text.DecimalFormatSymbols
import java.util.Locale

enum class Page { DEVICES, DETAIL, SETTINGS }

data class UiState(
    val page: Page = Page.DEVICES,
    val network: LocalNetwork? = null,
    val noNetwork: Boolean = false,
    val items: List<DeviceItem> = emptyList(),
    val scanning: Boolean = false,
    val progress: Int = 0,
    val status: String = "Preparando...",
    val houseDown: String = "",
    val houseUp: String = "",
    val phoneDown: String = "—",
    val phoneUp: String = "—",
    val settings: AppSettings = AppSettings(),
    val selectedKey: String? = null,
    val canNotify: Boolean = true,
    val version: String = "",
) {
    val onlineCount: Int get() = items.count { it.online }
    val selected: DeviceItem? get() = items.firstOrNull { it.key == selectedKey }
    val visibleItems: List<DeviceItem> get() = if (settings.showOffline) items else items.filter { it.online }
}

class MainViewModel(app: Application) : AndroidViewModel(app) {
    private val store = Store(app)
    private val _state = MutableStateFlow(UiState(settings = store.settings()))
    val state: StateFlow<UiState> = _state

    private var gateways: List<UpnpInfo> = emptyList()
    private var watchJob: Job? = null
    private var trafficJob: Job? = null
    private var wifiCallback: ConnectivityManager.NetworkCallback? = null
    private var lastShown: RoundOutcome? = null

    init {
        val net = NetworkInfo.current(app)
        if (net != null) {
            val st = store.load(net.id)
            st.online.clear() // hasta escanear no se sabe quién está en línea
            _state.update { it.copy(network = net, items = Round.items(st, System.currentTimeMillis())) }
        }
        WatchWorker.schedule(app)
        // Las revisiones de segundo plano también actualizan la pantalla
        viewModelScope.launch {
            Monitor.rounds.collect {
                if (it === lastShown) return@collect
                if (!_state.value.scanning) {
                    show(it, "")
                } else {
                    // La pantalla espera su turno para escanear: mientras tanto muestra lo que se encontró
                    gateways = it.gateways
                    _state.update { st -> st.copy(network = it.network, items = Round.items(it.state, System.currentTimeMillis())) }
                }
            }
        }
    }

    fun setVersion(v: String) = _state.update { it.copy(version = v) }
    fun refreshPermission() = _state.update { it.copy(canNotify = Notifier.canNotify(getApplication())) }

    // Mientras la app está a la vista: escanea al entrar y luego cada pocos minutos, y mide el consumo
    fun onForeground() {
        refreshPermission()
        if (watchJob?.isActive != true) {
            watchJob = viewModelScope.launch {
                while (isActive) {
                    scan()
                    delay(_state.value.settings.foregroundMinutes * 60_000L)
                }
            }
        }
        if (trafficJob?.isActive != true) trafficJob = viewModelScope.launch { measureTraffic() }
        watchWifi()
    }

    fun onBackground() {
        watchJob?.cancel()
        trafficJob?.cancel()
        wifiCallback?.let { runCatching { connectivity().unregisterNetworkCallback(it) } }
        wifiCallback = null
    }

    private fun connectivity() = getApplication<Application>().getSystemService(ConnectivityManager::class.java)

    // Si al abrir la app el teléfono todavía no estaba en el Wi-Fi, escanea apenas se conecta
    private fun watchWifi() {
        if (wifiCallback != null) return
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                viewModelScope.launch {
                    delay(1500)
                    val st = _state.value
                    if (st.noNetwork || st.network == null || NetworkInfo.current(getApplication())?.id != st.network.id) scan()
                }
            }
        }
        val request = NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build()
        if (runCatching { connectivity().registerNetworkCallback(request, cb) }.isSuccess) wifiCallback = cb
    }

    fun scan() {
        if (_state.value.scanning) return
        viewModelScope.launch {
            _state.update { it.copy(scanning = true, progress = 0, status = "Buscando equipos...") }
            val started = SystemClock.elapsedRealtime()
            val outcome = withContext(Dispatchers.IO) {
                Monitor.runRound(getApplication()) { p, phase -> _state.update { it.copy(progress = p, status = phase) } }
            }
            if (outcome == null) {
                _state.update {
                    it.copy(scanning = false, noNetwork = true, status = "El teléfono no está conectado al Wi-Fi. Conéctate a la red de la casa y presiona «Escanear de nuevo».")
                }
                return@launch
            }
            show(outcome, " en ${(SystemClock.elapsedRealtime() - started) / 1000} s")
        }
    }

    private fun show(outcome: RoundOutcome, duration: String) {
        lastShown = outcome
        gateways = outcome.gateways
        val items = Round.items(outcome.state, System.currentTimeMillis())
        val n = items.count { it.online }
        val alert = AlertRules.format(outcome.alerts)
        val status = when {
            outcome.error.isNotEmpty() -> "El escaneo se detuvo por un error: ${outcome.error}"
            alert != null -> "${alert.title}: ${alert.text}"
            else -> "Escaneo terminado$duration: $n ${if (n == 1) "equipo conectado" else "equipos conectados"}. Toca un equipo para ponerle nombre."
        }
        _state.update { it.copy(scanning = false, noNetwork = false, network = outcome.network, items = items, progress = 100, status = status) }
    }

    fun openDevice(key: String) = _state.update { it.copy(selectedKey = key, page = Page.DETAIL) }

    // Al tocar una notificación: abre ese equipo (si está desconectado, muestra también los desconectados)
    fun openFromNotification(key: String) {
        val item = _state.value.items.firstOrNull { it.key == key }
        if (item != null && !item.online && !_state.value.settings.showOffline) updateSettings(_state.value.settings.copy(showOffline = true))
        openDevice(key)
    }

    fun show(page: Page) = _state.update { it.copy(page = page) }

    fun back(): Boolean {
        if (_state.value.page == Page.DEVICES) return false
        _state.update { it.copy(page = Page.DEVICES) }
        return true
    }

    fun saveDevice(key: String, name: String, typeKey: String) {
        val net = _state.value.network ?: return
        viewModelScope.launch {
            val st = withContext(Dispatchers.IO) { Monitor.saveDevice(getApplication(), net.id, key, name, typeKey) }
            val online = _state.value.items.filter { it.online }.map { it.key }.toSet()
            st.online.clear(); st.online += online
            _state.update { it.copy(items = Round.items(st, System.currentTimeMillis())) }
        }
    }

    fun updateSettings(s: AppSettings) {
        store.saveSettings(s)
        _state.update { it.copy(settings = s) }
        WatchWorker.schedule(getApplication())
    }

    fun testNotification() {
        val sample = AlertInfo(key = "", name = "Equipo de ejemplo", ip = "192.168.1.99", vendor = "Samsung")
        AlertRules.format(Alerts(listOf(sample), emptyList()))?.let { Notifier.show(getApplication(), it) }
        refreshPermission()
    }

    private suspend fun measureTraffic() {
        var prevPhone: Pair<Long, Long>? = null
        var prevHouse: Pair<Long, Long>? = null
        var prevTime = SystemClock.elapsedRealtime()
        while (true) {
            val now = SystemClock.elapsedRealtime()
            val secs = (now - prevTime) / 1000.0
            val phone = TrafficStats.getTotalRxBytes() to TrafficStats.getTotalTxBytes()
            val gw = gateways.firstOrNull()
            val house = if (gw != null) withContext(Dispatchers.IO) {
                Upnp.totalBytes(gw.wanControlUrl, gw.wanServiceType, true, 1500) to Upnp.totalBytes(gw.wanControlUrl, gw.wanServiceType, false, 1500)
            } else null
            _state.update {
                it.copy(
                    phoneDown = prevPhone?.let { p -> formatRate(rate(p.first, phone.first, secs)) } ?: it.phoneDown,
                    phoneUp = prevPhone?.let { p -> formatRate(rate(p.second, phone.second, secs)) } ?: it.phoneUp,
                    houseDown = if (house == null || house.first < 0) "" else prevHouse?.let { p -> formatRate(rate(p.first, house.first, secs)) } ?: it.houseDown,
                    houseUp = if (house == null || house.second < 0) "" else prevHouse?.let { p -> formatRate(rate(p.second, house.second, secs)) } ?: it.houseUp,
                )
            }
            prevPhone = phone
            prevHouse = house?.takeIf { h -> h.first >= 0 && h.second >= 0 }
            prevTime = now
            delay(2000)
        }
    }

    companion object {
        // Velocidad en bytes/s; -1 si el contador retrocedió (el router se reinició)
        fun rate(prev: Long, now: Long, secs: Double): Double =
            if (now < prev || secs <= 0) -1.0 else (now - prev) / secs

        fun formatRate(bps: Double): String {
            if (bps < 0) return "—"
            val dec = DecimalFormat("0.0", DecimalFormatSymbols(Locale.forLanguageTag("es-EC")))
            return when {
                bps < 1024 -> "${bps.toInt()} B/s"
                bps < 1024 * 1024 -> "${(bps / 1024).toInt()} KB/s"
                else -> "${dec.format(bps / 1024 / 1024)} MB/s"
            }
        }
    }
}
