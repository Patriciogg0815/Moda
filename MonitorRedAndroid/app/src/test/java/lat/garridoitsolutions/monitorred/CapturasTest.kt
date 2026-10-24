package lat.garridoitsolutions.monitorred

import androidx.compose.ui.test.hasScrollAction
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performScrollToIndex
import com.github.takahirom.roborazzi.captureRoboImage
import lat.garridoitsolutions.monitorred.data.AppSettings
import lat.garridoitsolutions.monitorred.monitor.AlertRules
import lat.garridoitsolutions.monitorred.monitor.AlertSettings
import lat.garridoitsolutions.monitorred.monitor.NetworkState
import lat.garridoitsolutions.monitorred.monitor.Round
import lat.garridoitsolutions.monitorred.ui.Actions
import lat.garridoitsolutions.monitorred.ui.App
import lat.garridoitsolutions.monitorred.ui.MonitorTheme
import lat.garridoitsolutions.monitorred.ui.Page
import lat.garridoitsolutions.monitorred.ui.UiState
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

// Capturas para la ficha de Google Play: la app real con la casa de ejemplo, en un teléfono de 1080 x 1920
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], qualifiers = "w360dp-h640dp-xxhdpi")
class CapturasTest {
    @get:Rule
    val compose = createComposeRule()

    private fun ejemplo(page: Page): UiState {
        val now = System.currentTimeMillis()
        val st = NetworkState(Casa.red.id)
        Round.apply(st, Casa.red, Casa.todos, true, false, AlertSettings(), "Galaxy S23 de Patricio", now - 3_600_000)
        st.devices["UPNP:uuid:tv-sala"]!!.customName = "TV de la sala"
        st.devices["IP:192.168.1.95"]!!.apply { customName = "Decodificador de cable"; customType = "tv" }
        val galaxy = Casa.host("192.168.1.85", 12, dns = "Galaxy-A54.lan")
        val r = Round.apply(st, Casa.red, Casa.todos + galaxy, true, true, AlertSettings(), "Galaxy S23 de Patricio", now)
        val aviso = AlertRules.format(r.alerts)!!
        return UiState(
            page = page,
            network = Casa.red,
            items = Round.items(st, now),
            status = "${aviso.title}: ${aviso.text}",
            houseDown = "2,4 MB/s", houseUp = "310 KB/s", phoneDown = "180 KB/s", phoneUp = "12 KB/s",
            settings = AppSettings(),
            selectedKey = "UPNP:uuid:tv-sala",
            version = "1.0",
        )
    }

    private fun capturar(state: UiState, nombre: String, scrollTo: Int? = null) {
        compose.setContent { MonitorTheme(dark = false) { App(state, Actions()) } }
        if (scrollTo != null) compose.onNode(hasScrollAction()).performScrollToIndex(scrollTo)
        compose.onRoot().captureRoboImage("build/capturas-play/$nombre.png")
    }

    @Test
    fun equipos() {
        val s = ejemplo(Page.DEVICES)
        assertTrue(s.items.any { it.isNew && it.name == "Galaxy-A54" })
        capturar(s, "1-equipos")
    }

    @Test
    fun lista() = capturar(ejemplo(Page.DEVICES), "2-lista", scrollTo = 12)

    @Test
    fun detalle() = capturar(ejemplo(Page.DETAIL), "3-detalle")

    @Test
    fun alertas() = capturar(ejemplo(Page.SETTINGS), "4-alertas")
}
