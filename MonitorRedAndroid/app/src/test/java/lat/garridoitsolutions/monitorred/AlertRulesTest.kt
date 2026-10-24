package lat.garridoitsolutions.monitorred

import lat.garridoitsolutions.monitorred.monitor.AlertInfo
import lat.garridoitsolutions.monitorred.monitor.AlertRules
import lat.garridoitsolutions.monitorred.monitor.AlertSettings
import lat.garridoitsolutions.monitorred.monitor.Alerts
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

// Mismas pruebas que las alertas de la versión de Windows (.github/scripts/Probar-MonitorRed.ps1)
class AlertRulesTest {
    private val now = System.currentTimeMillis()
    private val tablet = AlertInfo("HOST:ipad", "Tablet de Sofía", "192.168.1.27", 27, "Apple", hasCustomName = true, lastSeen = now)
    private val movil = AlertInfo("HOST:iphone-de-ana", "iPhone-de-Ana", "192.168.1.23", 23)
    private val redmi = AlertInfo("HOST:redmi-note-12", "Redmi-Note-12", "192.168.1.80", 80, "Xiaomi")

    @Test
    fun unaSolaFaltaNoAvisa_dosSeguidasSi() {
        val pending = mutableMapOf<String, AlertInfo>()
        var a = AlertRules.decide(AlertSettings(), emptyMap(), mapOf(tablet.key to tablet), emptySet(), pending, true)
        assertTrue(a.offline.isEmpty() && tablet.key in pending)
        a = AlertRules.decide(AlertSettings(), emptyMap(), emptyMap(), emptySet(), pending, true)
        assertEquals(listOf(tablet), a.offline)
        assertTrue(pending.isEmpty())
        val m = AlertRules.format(a, now)!!
        assertEquals("Se desconectó «Tablet de Sofía»", m.title)
        assertTrue(m.text, m.text.startsWith("Se apagó o salió de la red. Visto por última vez: hoy "))
        assertTrue(m.isOffline)
    }

    @Test
    fun siVuelveAAparecerNoAvisa() {
        val pending = mutableMapOf<String, AlertInfo>()
        AlertRules.decide(AlertSettings(), emptyMap(), mapOf(movil.key to movil), emptySet(), pending, true)
        val a = AlertRules.decide(AlertSettings(), emptyMap(), emptyMap(), setOf(movil.key), pending, true)
        assertTrue(a.offline.isEmpty() && pending.isEmpty())
    }

    @Test
    fun redNoConfiableNoAvisaDesconexiones() {
        val pending = mutableMapOf(movil.key to movil)
        val a = AlertRules.decide(AlertSettings(), emptyMap(), mapOf(tablet.key to tablet), emptySet(), pending, false)
        assertTrue(a.offline.isEmpty() && pending.isEmpty())
    }

    @Test
    fun soloLosQueTienenNombre() {
        val pending = mutableMapOf(movil.key to movil, tablet.key to tablet)
        val a = AlertRules.decide(AlertSettings(namedOnly = true), emptyMap(), emptyMap(), emptySet(), pending, true)
        assertEquals(listOf("Tablet de Sofía"), a.offline.map { it.name })
    }

    @Test
    fun equipoNuevo() {
        val a = AlertRules.decide(AlertSettings(), mapOf(redmi.key to redmi), emptyMap(), emptySet(), mutableMapOf(), false)
        val m = AlertRules.format(a, now)!!
        assertEquals("Se conectó un equipo nuevo", m.title)
        assertEquals("«Redmi-Note-12» · IP 192.168.1.80 · Xiaomi", m.text)
        val off = AlertRules.decide(AlertSettings(alertNew = false), mapOf(redmi.key to redmi), emptyMap(), emptySet(), mutableMapOf(), true)
        assertNull(AlertRules.format(off, now))
        assertTrue(!AlertSettings(alertNew = false, alertOffline = false).enabled)
    }

    @Test
    fun variosEnUnSoloAviso() {
        val m = AlertRules.format(Alerts(listOf(redmi, movil), listOf(tablet)), now)!!
        assertEquals("Cambios en tu red", m.title)
        assertEquals("Se conectó: «Redmi-Note-12», «iPhone-de-Ana». Se desconectó: «Tablet de Sofía».", m.text)
        val muchos = (1..40).map { AlertInfo("k$it", "Equipo con un nombre bastante largo $it", "192.168.1.$it", it.toLong()) }
        val m2 = AlertRules.format(Alerts(muchos, emptyList()), now)!!
        assertEquals("Se conectaron 40 equipos nuevos", m2.title)
        assertTrue(m2.text.length <= 250 && m2.text.endsWith("…"))
        val largo = AlertRules.format(Alerts(emptyList(), listOf(AlertInfo("x", "Televisor ".repeat(10).trim(), "192.168.1.5"))), now)!!
        assertTrue(largo.title.length <= 63)
        assertEquals("Se apagó o salió de la red. IP 192.168.1.5", largo.text)
    }
}
