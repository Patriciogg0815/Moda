package lat.garridoitsolutions.monitorred

import android.app.Application
import lat.garridoitsolutions.monitorred.monitor.Notifier
import lat.garridoitsolutions.monitorred.monitor.WatchWorker

class MonitorApp : Application() {
    override fun onCreate() {
        super.onCreate()
        Notifier.createChannel(this)
        WatchWorker.schedule(this)
    }
}
