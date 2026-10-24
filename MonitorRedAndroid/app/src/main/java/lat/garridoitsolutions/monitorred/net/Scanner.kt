package lat.garridoitsolutions.monitorred.net

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import lat.garridoitsolutions.monitorred.model.HostInfo
import lat.garridoitsolutions.monitorred.model.Ipv4
import lat.garridoitsolutions.monitorred.model.LocalNetwork
import lat.garridoitsolutions.monitorred.model.UpnpInfo
import java.io.File
import java.io.IOException
import java.net.ConnectException
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

data class ScanResult(
    val network: LocalNetwork,
    val hosts: List<HostInfo>,
    // Routers que informan por UPnP el consumo total de internet
    val gateways: List<UpnpInfo>,
    val error: String = "",
)

object NetworkInfo {
    // Red Wi-Fi (o cable) a la que está conectado el teléfono. No hace falta permiso de ubicación.
    fun current(context: Context): LocalNetwork? {
        val cm = context.getSystemService(ConnectivityManager::class.java) ?: return null
        @Suppress("DEPRECATION")
        val candidates = listOfNotNull(cm.activeNetwork) + cm.allNetworks.toList()
        for (n in candidates.distinct()) {
            val caps = cm.getNetworkCapabilities(n) ?: continue
            if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) && !caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) continue
            val lp = cm.getLinkProperties(n) ?: continue
            return fromLinkProperties(lp) ?: continue
        }
        return null
    }

    private fun fromLinkProperties(lp: LinkProperties): LocalNetwork? {
        val la = lp.linkAddresses.firstOrNull { it.address is Inet4Address } ?: return null
        val gw = lp.routes.firstOrNull { it.isDefaultRoute && it.gateway is Inet4Address }?.gateway?.hostAddress.orEmpty()
        return LocalNetwork(la.address.hostAddress ?: return null, la.prefixLength, gw, lp.interfaceName ?: "wlan0")
    }
}

class Scanner(private val context: Context) {
    // Puertos que casi todos los equipos tienen abiertos o cerrados (un "cerrado" también prueba que el equipo existe)
    private val probePorts = intArrayOf(80, 443, 62078, 8080, 445, 139, 22, 554, 8008, 9100, 7000, 5000)
    private val dnsScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    suspend fun scan(net: LocalNetwork, selfName: String, onProgress: (Int, String) -> Unit = { _, _ -> }): ScanResult = coroutineScope {
        val alive = ConcurrentHashMap<String, Int>()
        alive[net.localIp] = 0

        // UPnP en paralelo con el barrido
        val upnpJob = async(Dispatchers.IO) { withMulticast { Upnp.discover(5000) } }

        onProgress(0, "Buscando equipos...")
        val first = net.firstHost
        val last = net.lastHost
        val total = (last - first + 1).toInt().coerceAtLeast(1)
        val done = AtomicInteger()
        val gate = Semaphore(48)
        (first..last).map { v ->
            async(Dispatchers.IO) {
                gate.withPermit {
                    val ip = Ipv4.toText(v)
                    if (ip != net.localIp) {
                        val ms = probe(ip)
                        if (ms >= 0) alive[ip] = ms
                    }
                    onProgress(done.incrementAndGet() * 70 / total, "Buscando equipos...")
                }
            }
        }.awaitAll()

        // Teléfonos con Android 9 o anterior: la tabla ARP agrega equipos que no responden y sus MAC
        val macs = readArpTable()
        for ((ip, _) in macs) {
            val v = runCatching { Ipv4.toLong(ip) }.getOrNull() ?: continue
            if (v in first..last) alive.putIfAbsent(ip, -1)
        }

        val upnp = upnpJob.await()
        for (ip in upnp.keys) {
            val v = runCatching { Ipv4.toLong(ip) }.getOrNull() ?: continue
            if (v in first..last) alive.putIfAbsent(ip, -1)
        }

        onProgress(72, "Averiguando los nombres de los equipos...")
        val named = AtomicInteger()
        val names = Semaphore(24)
        val hosts = alive.entries.map { (ip, ms) ->
            async(Dispatchers.IO) {
                names.withPermit {
                    val isSelf = ip == net.localIp
                    // El DNS inverso no se puede interrumpir: se espera como máximo 2,5 s y se sigue sin él
                    val dnsLookup = dnsScope.async { NameQuery.reverseDns(ip) }
                    val dns = async { withTimeoutOrNull(2500) { dnsLookup.await() }.orEmpty() }
                    val nb = async { if (isSelf) "" else NameQuery.netBios(ip, 900) }
                    val md = async { if (isSelf) "" else NameQuery.mdns(ip, 900) }
                    val descriptions = upnp[ip].orEmpty().map { loc -> async { Upnp.fetchDescription(loc, 2500) } }
                    val h = HostInfo(
                        ip = ip,
                        ipValue = Ipv4.toLong(ip),
                        pingMs = ms,
                        isSelf = isSelf,
                        isGateway = ip == net.gateway,
                        mac = macs[ip].orEmpty(),
                        dnsName = dns.await(),
                        netBiosName = nb.await(),
                        mdnsName = if (isSelf) selfName else md.await(),
                        upnp = descriptions.awaitAll(),
                    )
                    onProgress(72 + named.incrementAndGet() * 28 / alive.size.coerceAtLeast(1), "Averiguando los nombres de los equipos...")
                    h
                }
            }
        }.awaitAll()

        onProgress(100, "Listo")
        ScanResult(
            network = net,
            hosts = hosts.sortedBy { it.ipValue },
            gateways = hosts.flatMap { it.upnp }.filter { it.wanControlUrl.isNotEmpty() },
        )
    }

    // Tiempo de respuesta en ms, o -1 si no hay equipo en esa IP
    private suspend fun probe(ip: String): Int = withContext(Dispatchers.IO) {
        val start = System.nanoTime()
        val addr = runCatching { InetAddress.getByName(ip) }.getOrNull() ?: return@withContext -1
        if (runCatching { addr.isReachable(600) }.getOrDefault(false)) return@withContext elapsedMs(start)
        val hit = probePorts.map { port -> async { tcpAnswers(ip, port, 450) } }.awaitAll().any { it }
        if (hit) elapsedMs(start) else -1
    }

    private fun elapsedMs(start: Long) = ((System.nanoTime() - start) / 1_000_000).toInt()

    // true si el equipo contestó (aceptó la conexión o la rechazó)
    private fun tcpAnswers(ip: String, port: Int, timeoutMs: Int): Boolean = try {
        Socket().use { it.connect(InetSocketAddress(ip, port), timeoutMs) }
        true
    } catch (e: ConnectException) {
        e.message.orEmpty().contains("ECONNREFUSED") || e.message.orEmpty().contains("refused", ignoreCase = true)
    } catch (_: IOException) {
        false
    }

    private fun readArpTable(): Map<String, String> = runCatching {
        File("/proc/net/arp").readLines().drop(1).mapNotNull { line ->
            val p = line.trim().split(Regex("\\s+"))
            if (p.size < 4 || p[2] != "0x2" || p[3] == "00:00:00:00:00:00") null else p[0] to p[3].uppercase()
        }.toMap()
    }.getOrDefault(emptyMap())

    private fun <T> withMulticast(block: () -> T): T {
        val wifi = context.applicationContext.getSystemService(WifiManager::class.java)
        val lock = wifi?.createMulticastLock("MonitorRed-UPnP")?.apply { setReferenceCounted(false); acquire() }
        try {
            return block()
        } finally {
            runCatching { lock?.release() }
        }
    }
}
