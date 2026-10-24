package lat.garridoitsolutions.monitorred

import lat.garridoitsolutions.monitorred.model.DeviceRules
import lat.garridoitsolutions.monitorred.model.DeviceType
import lat.garridoitsolutions.monitorred.monitor.AlertSettings
import lat.garridoitsolutions.monitorred.monitor.NetworkState
import lat.garridoitsolutions.monitorred.monitor.Round
import lat.garridoitsolutions.monitorred.monitor.RoundResult
import lat.garridoitsolutions.monitorred.model.HostInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RoundTest {
    private var now = 1_700_000_000_000L
    private val state = NetworkState(Casa.red.id)

    private fun round(hosts: List<HostInfo>, same: Boolean = true, ok: Boolean = true, settings: AlertSettings = AlertSettings()): RoundResult {
        now += 120_000
        return Round.apply(state, Casa.red, hosts, ok, same, settings, "Galaxy S23", now)
    }

    @Test
    fun tiposDeLaCasaDeEjemplo() {
        val esperado = mapOf(
            Casa.router to DeviceType.ROUTER, Casa.telefono to DeviceType.PHONE, Casa.iphone to DeviceType.PHONE,
            Casa.tv to DeviceType.TV, Casa.chromecast to DeviceType.TV, Casa.sonos to DeviceType.SPEAKER,
            Casa.impresora to DeviceType.PRINTER, Casa.laptop to DeviceType.LAPTOP, Casa.enchufe to DeviceType.SMARTHOME,
            Casa.redmi to DeviceType.PHONE, Casa.camara to DeviceType.CAMERA, Casa.playstation to DeviceType.CONSOLE,
            Casa.sinNombre to DeviceType.UNKNOWN,
        )
        for ((h, t) in esperado) assertEquals(h.ip, t, DeviceRules.guess(h).type)
        assertEquals("[TV] Samsung Q60 Series (55)", DeviceRules.autoName(Casa.tv, DeviceType.TV, "x"))
        assertEquals("Redmi-Note-12", DeviceRules.autoName(Casa.redmi, DeviceType.PHONE, "x"))
        assertEquals("Galaxy S23 (este teléfono)", DeviceRules.autoName(Casa.telefono, DeviceType.PHONE, "Galaxy S23"))
        assertEquals("Equipo sin nombre", DeviceRules.autoName(Casa.sinNombre, DeviceType.UNKNOWN, "x"))
    }

    @Test
    fun laPrimeraRevisionNoAvisa_luegoEquipoNuevoYDesconectado() {
        val r1 = round(Casa.todos, same = false)
        assertTrue(r1.alerts.isEmpty)
        assertEquals(Casa.todos.size, state.devices.size)
        assertTrue(Round.items(state, now).none { it.isNew })

        // Llega un Galaxy nuevo y el Redmi deja de aparecer
        val galaxy = Casa.host("192.168.1.85", 12, dns = "Galaxy-A54.lan")
        val ronda = Casa.todos - Casa.redmi + galaxy
        val r2 = round(ronda)
        assertEquals(listOf("Galaxy-A54"), r2.alerts.new.map { it.name })
        assertTrue("todavía no se avisa el Redmi", r2.alerts.offline.isEmpty())
        assertTrue(Round.items(state, now).first { it.name == "Galaxy-A54" }.isNew)

        val r3 = round(ronda)
        assertTrue(r3.alerts.new.isEmpty())
        assertEquals(listOf("Redmi-Note-12"), r3.alerts.offline.map { it.name })
        assertFalse(Round.items(state, now).first { it.name == "Redmi-Note-12" }.online)
    }

    @Test
    fun seReconocePorLaIpAunqueEstaVezNoDigaSuNombre() {
        round(Casa.todos, same = false)
        // El iPhone no contestó por mDNS: sigue en la misma IP, es el mismo equipo (no es "nuevo")
        val sinNombre = Casa.iphone.copy(mdnsName = "")
        val r = round(Casa.todos - Casa.iphone + sinNombre)
        assertTrue(r.alerts.isEmpty)
        assertEquals(Casa.todos.size, state.devices.size)
        assertTrue("HOST:iphone-de-ana" in state.online)
    }

    @Test
    fun unEquipoSinNombreQueLuegoLoDiceConservaSuNombrePuesto() {
        round(Casa.todos, same = false)
        state.devices["IP:192.168.1.95"]!!.customName = "Decodificador"
        val conNombre = Casa.sinNombre.copy(dnsName = "decoder-tv.lan")
        val r = round(Casa.todos - Casa.sinNombre + conNombre)
        assertTrue(r.alerts.isEmpty)
        assertEquals("Decodificador", state.devices["HOST:decoder-tv"]!!.customName)
        assertFalse("IP:192.168.1.95" in state.devices)
    }

    @Test
    fun otraRedOElRouterCaidoNoAvisanDesconexiones() {
        round(Casa.todos, same = false)
        val r1 = round(listOf(Casa.telefono), same = false)
        val r2 = round(listOf(Casa.telefono))
        assertTrue(r1.alerts.isEmpty && r2.alerts.isEmpty)

        round(Casa.todos)
        val sinRouter = Casa.todos - Casa.router - Casa.tv
        round(sinRouter)
        val r3 = round(sinRouter)
        assertTrue("sin router no se avisa", r3.alerts.offline.isEmpty())
    }
}
