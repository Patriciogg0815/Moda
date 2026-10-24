package lat.garridoitsolutions.monitorred

import lat.garridoitsolutions.monitorred.data.Store
import lat.garridoitsolutions.monitorred.model.Ipv4
import lat.garridoitsolutions.monitorred.model.LocalNetwork
import lat.garridoitsolutions.monitorred.monitor.AlertSettings
import lat.garridoitsolutions.monitorred.monitor.NetworkState
import lat.garridoitsolutions.monitorred.monitor.Round
import lat.garridoitsolutions.monitorred.net.NameQuery
import lat.garridoitsolutions.monitorred.net.Upnp
import lat.garridoitsolutions.monitorred.ui.MainViewModel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class NetTest {
    @Test
    fun redes() {
        assertEquals("192.168.1.0/24", Casa.red.summary)
        assertEquals("192.168.1.1", Ipv4.toText(Casa.red.firstHost))
        assertEquals("192.168.1.254", Ipv4.toText(Casa.red.lastHost))
        val grande = LocalNetwork("10.0.37.5", 16, "10.0.0.1", "wlan0")
        assertTrue(grande.isLimited)
        assertEquals("10.0.37.0/24", grande.summary)
        assertEquals(1022, (LocalNetwork("10.0.4.9", 22, "10.0.4.1", "wlan0").let { it.lastHost - it.firstHost + 1 }).toInt())
    }

    @Test
    fun leeElNombreNetBios() {
        val r = ByteArray(57) + "SALA-PC".padEnd(15).toByteArray(Charsets.US_ASCII) + byteArrayOf(0, 0x04, 0x00)
        r[56] = 1
        assertEquals("SALA-PC", NameQuery.parseNetBios(r))
    }

    @Test
    fun leeElNombreMdns() {
        val q = NameQuery.buildQuery("23.1.168.192.in-addr.arpa", 12).toMutableList()
        q[2] = 0x84.toByte(); q[7] = 1
        q += listOf(0xC0, 0x0C, 0, 12, 0, 1, 0, 0, 0, 120).map { it.toByte() }
        val name = byteArrayOf(13) + "iPhone-de-Ana".toByteArray() + byteArrayOf(5) + "local".toByteArray() + byteArrayOf(0)
        q += listOf(0.toByte(), name.size.toByte())
        q += name.toList()
        assertEquals("iPhone-de-Ana", NameQuery.cleanLocal(NameQuery.readFirstAnswerName(q.toByteArray(), 12)))
    }

    @Test
    fun leeLaDescripcionUpnp() {
        val u = Upnp.parseDescription(
            "http://192.168.1.1:1900/igd.xml",
            """<root><device><deviceType>urn:schemas-upnp-org:device:InternetGatewayDevice:1</deviceType>
            <friendlyName>Archer C6</friendlyName><manufacturer>TP-Link</manufacturer><modelName>Archer C6</modelName><UDN>uuid:1234</UDN>
            <deviceList><device><serviceList><service><serviceType>urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1</serviceType>
            <controlURL>/ctl/CmnIfCfg</controlURL></service></serviceList></device></deviceList></device></root>""",
        )
        assertEquals("Archer C6", u.friendlyName)
        assertEquals("uuid:1234", u.udn)
        assertEquals("http://192.168.1.1:1900/ctl/CmnIfCfg", u.wanControlUrl)
        assertEquals("http://x/desc.xml", Upnp.header("HTTP/1.1 200 OK\r\nLocation: http://x/desc.xml\r\n", "LOCATION"))
    }

    @Test
    fun guardaYLeeLosEquipos() {
        val s = NetworkState(Casa.red.id)
        Round.apply(s, Casa.red, Casa.todos, true, false, AlertSettings(), "Galaxy S23", 1000)
        s.devices.values.first { it.key.startsWith("HOST:iphone") }.customName = "Teléfono de Ana"
        val leido = Store.fromJson(s.id, Store.toJson(s))
        assertEquals(s.devices, leido.devices)
        assertEquals(s.online, leido.online)
        assertEquals(1, leido.rounds)
    }

    @Test
    fun velocidades() {
        assertEquals("0 B/s", MainViewModel.formatRate(0.0))
        assertEquals("2 KB/s", MainViewModel.formatRate(2048.0))
        assertTrue(MainViewModel.formatRate(5.0 * 1024 * 1024).matches(Regex("5[.,]0 MB/s")))
        assertEquals("—", MainViewModel.formatRate(MainViewModel.rate(3000, 1000, 2.0)))
        assertEquals(1000.0, MainViewModel.rate(1000, 3000, 2.0), 0.001)
    }
}
