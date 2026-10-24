package lat.garridoitsolutions.monitorred.ui

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.runtime.getValue
import lat.garridoitsolutions.monitorred.monitor.Notifier

class MainActivity : ComponentActivity() {
    private val vm: MainViewModel by viewModels()

    private val askNotifications = registerForActivityResult(ActivityResultContracts.RequestPermission()) {
        vm.refreshPermission()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        Notifier.createChannel(this)
        vm.setVersion(runCatching { packageManager.getPackageInfo(packageName, 0).versionName }.getOrNull().orEmpty())
        handleIntent(intent)

        // La primera vez pide el permiso de notificaciones (Android 13 o más nuevo), para las alertas
        val settings = vm.state.value.settings
        if (Build.VERSION.SDK_INT >= 33 && !settings.askedNotifications) {
            vm.updateSettings(settings.copy(askedNotifications = true))
            askNotifications.launch(Manifest.permission.POST_NOTIFICATIONS)
        }

        lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onStart(owner: LifecycleOwner) = vm.onForeground()
            override fun onStop(owner: LifecycleOwner) = vm.onBackground()
        })

        val actions = Actions(
            onScan = vm::scan,
            onOpen = vm::openDevice,
            onShow = vm::show,
            onBack = { vm.back() },
            onSave = { key, name, type -> vm.saveDevice(key, name, type); vm.back() },
            onSettings = vm::updateSettings,
            onTestNotification = vm::testNotification,
            onAskPermission = ::askPermission,
            onSupport = { open("https://ko-fi.com/garridoitsolutions") },
            onPrivacy = { open(PRIVACY_URL) },
        )
        setContent {
            MonitorTheme {
                val state by vm.state.collectAsStateWithLifecycle()
                BackHandler(enabled = state.page != Page.DEVICES) { vm.back() }
                App(state, actions)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        val key = intent?.getStringExtra(Notifier.EXTRA_DEVICE)?.takeIf { it.isNotBlank() } ?: return
        intent.removeExtra(Notifier.EXTRA_DEVICE)
        vm.openFromNotification(key)
    }

    private fun askPermission() {
        if (Build.VERSION.SDK_INT >= 33 && shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS)) {
            askNotifications.launch(Manifest.permission.POST_NOTIFICATIONS)
        } else {
            // Si ya se negó dos veces, Android solo deja activarlo desde sus ajustes
            startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, packageName))
        }
    }

    private fun open(url: String) {
        runCatching { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }
    }

    companion object {
        const val PRIVACY_URL = "https://garridoitsolutions.lat/monitorred-privacidad"
    }
}
