package lat.garridoitsolutions.monitorred.net

import java.io.ByteArrayOutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.SocketTimeoutException
import java.util.concurrent.atomic.AtomicInteger

// Nombres de los equipos: NetBIOS (Windows, NAS, impresoras), mDNS (Apple, Android, Chromecast) y DNS
// del router. Es la misma forma de preguntar que la versión de Windows.
object NameQuery {
    private val nextId = AtomicInteger((System.nanoTime() and 0x7FFF).toInt())

    private fun exchange(ip: String, port: Int, query: ByteArray, timeoutMs: Int): ByteArray? {
        DatagramSocket().use { socket ->
            socket.soTimeout = timeoutMs
            val target = InetAddress.getByName(ip)
            socket.send(DatagramPacket(query, query.size, InetSocketAddress(target, port)))
            val end = System.currentTimeMillis() + timeoutMs
            val buf = ByteArray(2048)
            while (System.currentTimeMillis() < end) {
                val packet = DatagramPacket(buf, buf.size)
                try {
                    socket.receive(packet)
                } catch (_: SocketTimeoutException) {
                    return null
                }
                val data = packet.data.copyOf(packet.length)
                if (packet.address == target && data.size > 12 && data[0] == query[0] && data[1] == query[1]) return data
            }
        }
        return null
    }

    private fun writeId(packet: ByteArray) {
        val id = nextId.incrementAndGet() and 0xFFFF
        packet[0] = (id shr 8).toByte()
        packet[1] = id.toByte()
    }

    // Consulta NBSTAT (puerto 137)
    fun netBios(ip: String, timeoutMs: Int): String = runCatching {
        val q = ByteArray(50)
        writeId(q)
        q[5] = 1
        q[12] = 0x20
        q[13] = 'C'.code.toByte(); q[14] = 'K'.code.toByte() // "*" codificado
        for (i in 15 until 45) q[i] = 'A'.code.toByte()
        q[47] = 0x21 // NBSTAT
        q[49] = 0x01 // IN
        parseNetBios(exchange(ip, 137, q, timeoutMs))
    }.getOrDefault("")

    fun parseNetBios(r: ByteArray?): String {
        if (r == null || r.size < 57) return ""
        val count = r[56].toInt() and 0xFF
        for (i in 0 until count) {
            val off = 57 + i * 18
            if (off + 18 > r.size) break
            val suffix = r[off + 15].toInt() and 0xFF
            val flags = ((r[off + 16].toInt() and 0xFF) shl 8) or (r[off + 17].toInt() and 0xFF)
            if (suffix == 0 && (flags and 0x8000) == 0) return String(r, off, 15, Charsets.US_ASCII).trim()
        }
        return ""
    }

    // Pregunta mDNS directa al equipo (puerto 5353) por su nombre inverso ("iPhone-de-Ana.local")
    fun mdns(ip: String, timeoutMs: Int): String = runCatching {
        val o = ip.split('.')
        val q = buildQuery("${o[3]}.${o[2]}.${o[1]}.${o[0]}.in-addr.arpa", 12)
        val r = exchange(ip, 5353, q, timeoutMs) ?: return@runCatching ""
        cleanLocal(readFirstAnswerName(r, 12))
    }.getOrDefault("")

    fun buildQuery(name: String, qtype: Int): ByteArray {
        val b = ByteArrayOutputStream()
        b.write(byteArrayOf(0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0))
        for (label in name.split('.')) {
            if (label.isEmpty()) continue
            val l = label.toByteArray(Charsets.UTF_8)
            b.write(l.size)
            b.write(l)
        }
        b.write(0)
        b.write(qtype shr 8); b.write(qtype and 0xFF)
        b.write(0x80); b.write(0x01) // IN + respuesta unicast
        return b.toByteArray().also { writeId(it) }
    }

    fun readFirstAnswerName(r: ByteArray, wantedType: Int): String {
        fun u16(i: Int) = ((r[i].toInt() and 0xFF) shl 8) or (r[i + 1].toInt() and 0xFF)
        val qd = u16(4)
        val an = u16(6) + u16(8) + u16(10)
        val off = intArrayOf(12)
        repeat(qd) { readName(r, off); off[0] += 4 }
        var i = 0
        while (i < an && off[0] + 10 <= r.size) {
            readName(r, off)
            val type = u16(off[0])
            val len = u16(off[0] + 8)
            off[0] += 10
            if (type == wantedType) return readName(r, intArrayOf(off[0]))
            off[0] += len
            i++
        }
        return ""
    }

    // Lee un nombre DNS (con compresión). offset[0] queda después del nombre.
    fun readName(r: ByteArray, offset: IntArray): String {
        val sb = StringBuilder()
        var off = offset[0]
        var jumped = false
        var guard = 0
        while (off < r.size && guard++ < 64) {
            val len = r[off].toInt() and 0xFF
            if (len == 0) { off++; break }
            if ((len and 0xC0) == 0xC0) {
                if (off + 1 >= r.size) break
                val ptr = ((len and 0x3F) shl 8) or (r[off + 1].toInt() and 0xFF)
                if (!jumped) offset[0] = off + 2
                jumped = true
                off = ptr
                continue
            }
            off++
            if (off + len > r.size) break
            if (sb.isNotEmpty()) sb.append('.')
            sb.append(String(r, off, len, Charsets.UTF_8))
            off += len
        }
        if (!jumped) offset[0] = off
        return sb.toString()
    }

    fun cleanLocal(name: String): String {
        val n = name.trimEnd('.')
        return if (n.endsWith(".local", ignoreCase = true)) n.dropLast(6) else n
    }

    // Nombre que el router da al equipo (DNS inverso). Bloquea: se llama con un tiempo límite.
    fun reverseDns(ip: String): String = runCatching {
        val h = InetAddress.getByName(ip).canonicalHostName
        if (h == ip) "" else h
    }.getOrDefault("")
}
