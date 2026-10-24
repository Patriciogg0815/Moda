package lat.garridoitsolutions.monitorred.monitor

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import lat.garridoitsolutions.monitorred.R
import lat.garridoitsolutions.monitorred.data.Store
import lat.garridoitsolutions.monitorred.model.LocalNetwork
import lat.garridoitsolutions.monitorred.model.UpnpInfo
import lat.garridoitsolutions.monitorred.net.NetworkInfo
import lat.garridoitsolutions.monitorred.net.Scanner
import lat.garridoitsolutions.monitorred.ui.MainActivity
import java.util.concurrent.TimeUnit

data class RoundOutcome(
    val network: LocalNetwork,
    val state: NetworkState,
    val gateways: List<UpnpInfo>,
    val alerts: Alerts,
    val error: String,
)

// Una revisión de la red: escanea, compara con lo que se recuerda y avisa. La usan la pantalla y el
// trabajo en segundo plano; el candado evita que corran 2 a la vez.
object Monitor {
    private val lock = Mutex()
    private val _rounds = MutableSharedFlow<RoundOutcome>(extraBufferCapacity = 1)

    // Cada revisión terminada (también las de segundo plano), para que la pantalla se actualice sola
    val rounds: SharedFlow<RoundOutcome> = _rounds

    fun selfName(context: Context): String =
        Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME)?.takeIf { it.isNotBlank() } ?: Build.MODEL

    suspend fun runRound(context: Context, onProgress: (Int, String) -> Unit = { _, _ -> }): RoundOutcome? = lock.withLock {
        val app = context.applicationContext
        val net = NetworkInfo.current(app) ?: return@withLock null
        val store = Store(app)
        val settings = store.settings()
        val selfName = selfName(app)
        val scan = runCatching { Scanner(app).scan(net, selfName, onProgress) }
        val state = store.load(net.id)
        val result = Round.apply(
            state = state, net = net, hosts = scan.getOrNull()?.hosts.orEmpty(), scanOk = scan.isSuccess,
            sameNetworkAsBefore = store.lastNetworkId == net.id, settings = settings.alerts,
            selfName = selfName, now = System.currentTimeMillis(),
        )
        store.save(state)
        store.lastNetworkId = net.id
        Log.i("MonitorRed", "Revisión de ${net.summary}: ${result.newKeys.size} nuevos, ${state.online.size} en línea, " +
            "alertas: ${result.alerts.new.size} nuevos / ${result.alerts.offline.size} desconectados" +
            (scan.exceptionOrNull()?.let { " · error: $it" } ?: ""))
        AlertRules.format(result.alerts)?.let { Notifier.show(app, it) }
        RoundOutcome(net, state, scan.getOrNull()?.gateways.orEmpty(), result.alerts, scan.exceptionOrNull()?.message.orEmpty())
            .also { _rounds.tryEmit(it) }
    }

    suspend fun saveDevice(context: Context, networkId: String, key: String, name: String, typeKey: String): NetworkState = lock.withLock {
        val store = Store(context)
        val state = store.load(networkId)
        state.devices[key]?.let {
            it.customName = name.trim()
            it.customType = typeKey
        }
        store.save(state)
        state
    }
}

object Notifier {
    private const val CHANNEL = "alertas"
    const val EXTRA_DEVICE = "equipo"

    fun createChannel(context: Context) {
        val channel = NotificationChannel(CHANNEL, "Alertas de la red", NotificationManager.IMPORTANCE_DEFAULT).apply {
            description = "Cuando se conecta un equipo nuevo o un equipo se desconecta"
        }
        context.getSystemService(NotificationManager::class.java)?.createNotificationChannel(channel)
    }

    fun canNotify(context: Context): Boolean =
        (Build.VERSION.SDK_INT < 33 || ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) &&
            NotificationManagerCompat.from(context).areNotificationsEnabled()

    fun show(context: Context, msg: AlertMessage) {
        if (!canNotify(context)) return
        createChannel(context)
        val open = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra(EXTRA_DEVICE, msg.key)
        val pending = PendingIntent.getActivity(context, msg.key.hashCode(), open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val n = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_notificacion)
            .setColor(ContextCompat.getColor(context, R.color.marca))
            .setContentTitle(msg.title)
            .setContentText(msg.text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(msg.text))
            .setContentIntent(pending)
            .setAutoCancel(true)
            .build()
        try {
            NotificationManagerCompat.from(context).notify(msg.key.hashCode(), n)
        } catch (_: SecurityException) {
        }
    }
}

// Revisión en segundo plano. Android la corre como mínimo cada 15 minutos y solo con Wi-Fi.
class WatchWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val s = Store(applicationContext).settings()
        if (s.background && s.alerts.enabled) Monitor.runRound(applicationContext)
        return Result.success()
    }

    companion object {
        private const val NAME = "vigilancia"

        fun schedule(context: Context) {
            val s = Store(context).settings()
            val wm = WorkManager.getInstance(context)
            if (!s.background || !s.alerts.enabled) {
                wm.cancelUniqueWork(NAME)
                return
            }
            val request = PeriodicWorkRequestBuilder<WatchWorker>(15, TimeUnit.MINUTES)
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.UNMETERED).build())
                .build()
            wm.enqueueUniquePeriodicWork(NAME, ExistingPeriodicWorkPolicy.KEEP, request)
        }
    }
}
