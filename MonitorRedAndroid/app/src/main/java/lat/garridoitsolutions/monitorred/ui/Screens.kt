package lat.garridoitsolutions.monitorred.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.Computer
import androidx.compose.material.icons.outlined.DeviceUnknown
import androidx.compose.material.icons.outlined.Favorite
import androidx.compose.material.icons.outlined.Kitchen
import androidx.compose.material.icons.outlined.Laptop
import androidx.compose.material.icons.outlined.Lightbulb
import androidx.compose.material.icons.outlined.NotificationsActive
import androidx.compose.material.icons.outlined.PhoneAndroid
import androidx.compose.material.icons.outlined.Print
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Router
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.SettingsInputAntenna
import androidx.compose.material.icons.outlined.Shield
import androidx.compose.material.icons.outlined.Speaker
import androidx.compose.material.icons.outlined.SportsEsports
import androidx.compose.material.icons.outlined.Storage
import androidx.compose.material.icons.outlined.TabletAndroid
import androidx.compose.material.icons.outlined.Tv
import androidx.compose.material.icons.outlined.Videocam
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuAnchorType
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import lat.garridoitsolutions.monitorred.data.AppSettings
import lat.garridoitsolutions.monitorred.model.DeviceType
import lat.garridoitsolutions.monitorred.monitor.AlertRules
import lat.garridoitsolutions.monitorred.monitor.DeviceItem

class Actions(
    val onScan: () -> Unit = {},
    val onOpen: (String) -> Unit = {},
    val onShow: (Page) -> Unit = {},
    val onBack: () -> Unit = {},
    val onSave: (key: String, name: String, typeKey: String) -> Unit = { _, _, _ -> },
    val onSettings: (AppSettings) -> Unit = {},
    val onTestNotification: () -> Unit = {},
    val onAskPermission: () -> Unit = {},
    val onSupport: () -> Unit = {},
    val onPrivacy: () -> Unit = {},
)

fun iconFor(type: DeviceType): ImageVector = when (type) {
    DeviceType.ROUTER -> Icons.Outlined.Router
    DeviceType.COMPUTER -> Icons.Outlined.Computer
    DeviceType.LAPTOP -> Icons.Outlined.Laptop
    DeviceType.PHONE -> Icons.Outlined.PhoneAndroid
    DeviceType.TABLET -> Icons.Outlined.TabletAndroid
    DeviceType.TV -> Icons.Outlined.Tv
    DeviceType.CONSOLE -> Icons.Outlined.SportsEsports
    DeviceType.SPEAKER -> Icons.Outlined.Speaker
    DeviceType.PRINTER -> Icons.Outlined.Print
    DeviceType.CAMERA -> Icons.Outlined.Videocam
    DeviceType.SMARTHOME -> Icons.Outlined.Lightbulb
    DeviceType.APPLIANCE -> Icons.Outlined.Kitchen
    DeviceType.NAS -> Icons.Outlined.Storage
    DeviceType.NETWORK -> Icons.Outlined.SettingsInputAntenna
    DeviceType.UNKNOWN -> Icons.Outlined.DeviceUnknown
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun App(state: UiState, actions: Actions) {
    val title = when (state.page) {
        Page.DEVICES -> "Monitor de Red"
        Page.DETAIL -> "Detalle del equipo"
        Page.SETTINGS -> "Ajustes"
    }
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(title, style = MaterialTheme.typography.titleLarge) },
                navigationIcon = {
                    if (state.page != Page.DEVICES) IconButton(onClick = actions.onBack) {
                        Icon(Icons.AutoMirrored.Outlined.ArrowBack, contentDescription = "Volver")
                    }
                },
                actions = {
                    if (state.page == Page.DEVICES) IconButton(onClick = { actions.onShow(Page.SETTINGS) }) {
                        Icon(Icons.Outlined.Settings, contentDescription = "Ajustes")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.surface),
            )
        },
    ) { padding ->
        Box(Modifier.padding(padding).fillMaxSize()) {
            when (state.page) {
                Page.DEVICES -> DevicesScreen(state, actions)
                Page.DETAIL -> state.selected?.let { DetailScreen(it, actions) } ?: DevicesScreen(state, actions)
                Page.SETTINGS -> SettingsScreen(state, actions)
            }
        }
    }
}

@Composable
fun DevicesScreen(state: UiState, actions: Actions) {
    LazyColumn(contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        item { SummaryCard(state, actions) }
        item {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("Mostrar desconectados", style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
                Switch(state.settings.showOffline, onCheckedChange = { actions.onSettings(state.settings.copy(showOffline = it)) })
            }
        }
        items(state.visibleItems, key = { it.key }) { DeviceRow(it) { actions.onOpen(it.key) } }
        if (state.visibleItems.isEmpty() && !state.scanning) {
            item {
                Text(
                    if (state.items.isEmpty()) "Todavía no se encontraron equipos." else "No hay equipos en línea.",
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(16.dp),
                )
            }
        }
    }
}

@Composable
private fun SummaryCard(state: UiState, actions: Actions) {
    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer)) {
        Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            state.network?.let {
                Text(
                    "Red ${it.summary}  ·  Router ${it.gateway.ifBlank { "no detectado" }}",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Row(verticalAlignment = Alignment.Bottom) {
                Text("${state.onlineCount}", style = Destacado, color = MaterialTheme.colorScheme.primary)
                Text(
                    if (state.onlineCount == 1) "  equipo en línea" else "  equipos en línea",
                    style = MaterialTheme.typography.titleMedium,
                    modifier = Modifier.padding(bottom = 4.dp),
                )
            }
            if (state.scanning) LinearProgressIndicator(progress = { state.progress / 100f }, modifier = Modifier.fillMaxWidth())
            Text(state.status, style = MaterialTheme.typography.bodyMedium)
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                if (state.houseDown.isNotEmpty()) Usage("Toda la casa", state.houseDown, state.houseUp, Modifier.weight(1f))
                Usage("Este teléfono", state.phoneDown, state.phoneUp, Modifier.weight(1f))
            }
            Button(onClick = actions.onScan, enabled = !state.scanning, modifier = Modifier.fillMaxWidth().height(54.dp)) {
                Icon(Icons.Outlined.Refresh, contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text(if (state.scanning) "Escaneando..." else "Escanear de nuevo", style = MaterialTheme.typography.labelLarge)
            }
        }
    }
}

@Composable
private fun Usage(label: String, down: String, up: String, modifier: Modifier) {
    Column(
        modifier.background(MaterialTheme.colorScheme.secondaryContainer, RoundedCornerShape(12.dp)).padding(12.dp),
    ) {
        Text(label, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text("↓ $down", style = MaterialTheme.typography.titleMedium)
        Text("↑ $up", style = MaterialTheme.typography.bodyLarge)
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun DeviceRow(d: DeviceItem, onClick: () -> Unit) {
    Card(
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
    ) {
        Row(Modifier.padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
            TypeIcon(d.type, d.online, 52)
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text(d.name, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text("${d.ip}  ·  ${d.type.label}", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(4.dp), modifier = Modifier.padding(top = 4.dp)) {
                    Text(statusText(d), style = MaterialTheme.typography.bodyMedium, color = if (d.online) Verde else MaterialTheme.colorScheme.onSurfaceVariant, fontWeight = FontWeight.Medium)
                    if (d.isNew) Badge("Nuevo", Color(0xFFFFF0C2), Ambar)
                    if (d.isGateway) Badge("Router", MaterialTheme.colorScheme.primaryContainer, MaterialTheme.colorScheme.onPrimaryContainer)
                    if (d.isSelf) Badge("Este teléfono", MaterialTheme.colorScheme.primaryContainer, MaterialTheme.colorScheme.onPrimaryContainer)
                }
            }
        }
    }
}

fun statusText(d: DeviceItem): String = if (d.online) {
    if (d.pingMs >= 0 && !d.isSelf) "En línea · ${d.pingMs} ms" else "En línea"
} else {
    val seen = AlertRules.formatLastSeen(d.lastSeen)
    if (seen.isNotEmpty()) "Desconectado · visto $seen" else "Desconectado"
}

@Composable
private fun Badge(text: String, bg: Color, fg: Color) {
    Text(
        text,
        style = MaterialTheme.typography.labelLarge,
        color = fg,
        modifier = Modifier.background(bg, RoundedCornerShape(8.dp)).padding(horizontal = 8.dp, vertical = 2.dp),
    )
}

@Composable
private fun TypeIcon(type: DeviceType, online: Boolean, sizeDp: Int) {
    Box(
        Modifier.size(sizeDp.dp).background(
            if (online) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.secondaryContainer,
            RoundedCornerShape(14.dp),
        ),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            iconFor(type),
            contentDescription = type.label,
            tint = if (online) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size((sizeDp * 0.55).dp),
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DetailScreen(d: DeviceItem, actions: Actions) {
    var name by remember(d.key) { mutableStateOf(d.customName.ifBlank { d.name }) }
    var typeKey by remember(d.key) { mutableStateOf(if (d.isCustomType) d.type.key else "") }
    var open by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            TypeIcon(d.type, d.online, 64)
            Spacer(Modifier.width(14.dp))
            Column {
                Text(d.name, style = MaterialTheme.typography.titleLarge)
                Text("${d.type.label}  ·  ${statusText(d)}", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        OutlinedTextField(
            value = name,
            onValueChange = { name = it },
            label = { Text("Nombre") },
            singleLine = true,
            textStyle = MaterialTheme.typography.bodyLarge,
            modifier = Modifier.fillMaxWidth(),
        )
        ExposedDropdownMenuBox(expanded = open, onExpandedChange = { open = it }) {
            val label = if (typeKey.isEmpty()) "Automático" else DeviceType.fromKey(typeKey).label
            OutlinedTextField(
                value = label,
                onValueChange = {},
                readOnly = true,
                label = { Text("Tipo de equipo") },
                trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(open) },
                textStyle = MaterialTheme.typography.bodyLarge,
                modifier = Modifier.fillMaxWidth().menuAnchor(ExposedDropdownMenuAnchorType.PrimaryNotEditable),
            )
            ExposedDropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                DropdownMenuItem(text = { Text("Automático") }, onClick = { typeKey = ""; open = false })
                for (t in DeviceType.entries) {
                    DropdownMenuItem(
                        text = { Text(t.label) },
                        leadingIcon = { Icon(iconFor(t), contentDescription = null) },
                        onClick = { typeKey = t.key; open = false },
                    )
                }
            }
        }
        Text(d.typeReason, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Button(
                onClick = { actions.onSave(d.key, if (name.trim() == d.autoName) "" else name, typeKey) },
                modifier = Modifier.weight(1f).height(52.dp),
            ) { Text("Guardar", style = MaterialTheme.typography.labelLarge) }
            OutlinedButton(
                onClick = { name = d.autoName; typeKey = ""; actions.onSave(d.key, "", "") },
                modifier = Modifier.weight(1f).height(52.dp),
            ) { Text("Restablecer", style = MaterialTheme.typography.labelLarge) }
        }
        Card(Modifier.fillMaxWidth(), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer)) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Info("Dirección IP", if (d.online) d.ip else "${d.ip} (la última vez)")
                Info("Nombre en la red", d.hostName.ifBlank { "No lo informa" })
                if (d.model.isNotBlank()) Info("Modelo", d.model)
                if (d.online && d.pingMs >= 0 && !d.isSelf) Info("Tiempo de respuesta", "${d.pingMs} ms")
                Info("Visto por primera vez", AlertRules.formatLastSeen(d.firstSeen).ifBlank { "—" })
                Info("Visto por última vez", AlertRules.formatLastSeen(d.lastSeen).ifBlank { "—" })
            }
        }
    }
}

@Composable
private fun Info(label: String, value: String) {
    Column {
        Text(label, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(value, style = MaterialTheme.typography.bodyLarge)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(state: UiState, actions: Actions) {
    val s = state.settings
    fun alerts(f: (lat.garridoitsolutions.monitorred.monitor.AlertSettings) -> lat.garridoitsolutions.monitorred.monitor.AlertSettings) =
        actions.onSettings(s.copy(alerts = f(s.alerts)))
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Section("Alertas")
        Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer)) {
            Column(Modifier.padding(vertical = 6.dp)) {
                SwitchRow("Avisarme cuando se conecte un equipo nuevo", "Uno que la app nunca había visto en esta red.", s.alerts.alertNew) { v -> alerts { it.copy(alertNew = v) } }
                HorizontalDivider()
                SwitchRow("Avisarme cuando un equipo se desconecte", "Se apagó o salió de la red.", s.alerts.alertOffline) { v -> alerts { it.copy(alertOffline = v) } }
                SwitchRow("Solo de los equipos a los que les puse nombre", null, s.alerts.namedOnly, enabled = s.alerts.alertOffline, indent = true) { v ->
                    alerts { it.copy(namedOnly = v) }
                }
            }
        }
        if (!state.canNotify) {
            Surface(color = Color(0xFFFFF0C2), shape = RoundedCornerShape(12.dp)) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Las notificaciones están desactivadas", style = MaterialTheme.typography.titleMedium, color = Ambar)
                    Text("Sin este permiso la app no puede avisarte.", style = MaterialTheme.typography.bodyMedium)
                    Button(onClick = actions.onAskPermission) { Text("Permitir notificaciones") }
                }
            }
        }
        OutlinedButton(onClick = actions.onTestNotification, modifier = Modifier.height(50.dp)) {
            Icon(Icons.Outlined.NotificationsActive, contentDescription = null)
            Spacer(Modifier.width(8.dp))
            Text("Probar la notificación", style = MaterialTheme.typography.labelLarge)
        }

        Section("Cada cuánto se revisa la red")
        Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer)) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("Con la app abierta, cada:", style = MaterialTheme.typography.bodyLarge)
                val choices = listOf(1, 2, 5)
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                    choices.forEachIndexed { i, m ->
                        SegmentedButton(
                            selected = s.foregroundMinutes == m,
                            onClick = { actions.onSettings(s.copy(foregroundMinutes = m)) },
                            shape = SegmentedButtonDefaults.itemShape(i, choices.size),
                        ) { Text("$m min") }
                    }
                }
            }
            HorizontalDivider()
            SwitchRow(
                "Revisar también con la app cerrada",
                "Android lo permite como máximo cada 15 minutos y solo con Wi-Fi. Si el teléfono está ahorrando batería puede tardar más.",
                s.background,
                enabled = s.alerts.enabled,
            ) { v -> actions.onSettings(s.copy(background = v)) }
        }
        Text(
            "Un equipo se da por desconectado cuando falta en 2 revisiones seguidas, para no avisar por un corte de un momento. Algunos teléfonos se desconectan del Wi-Fi solos cuando tienen la pantalla apagada.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        Section("Lo que Android no permite")
        Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer)) {
            Row(Modifier.padding(16.dp)) {
                Icon(Icons.Outlined.Shield, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
                Spacer(Modifier.width(12.dp))
                Text(
                    "Por privacidad, Android no deja que las apps vean la dirección MAC de los otros equipos ni cuánto internet usa cada uno. " +
                        "Por eso los equipos se reconocen por su nombre o su IP, y se muestra el consumo de toda la casa (si el router lo informa) y el de este teléfono.",
                    style = MaterialTheme.typography.bodyMedium,
                )
            }
        }

        Section("Acerca de")
        Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer)) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("Monitor de Red de Casa ${state.version}", style = MaterialTheme.typography.titleMedium)
                Text("Garrido IT Solutions. Los nombres y equipos de tu red se guardan solo en este teléfono: la app no los envía a ningún servidor.", style = MaterialTheme.typography.bodyMedium)
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Button(onClick = actions.onSupport) {
                        Icon(Icons.Outlined.Favorite, contentDescription = null)
                        Spacer(Modifier.width(6.dp))
                        Text("Apoyar a la app")
                    }
                    OutlinedButton(onClick = actions.onPrivacy) { Text("Privacidad") }
                }
            }
        }
        Spacer(Modifier.height(24.dp))
    }
}

@Composable
private fun Section(text: String) {
    Text(text, style = MaterialTheme.typography.titleLarge, modifier = Modifier.padding(top = 8.dp, start = 4.dp))
}

@Composable
private fun SwitchRow(
    title: String,
    subtitle: String?,
    checked: Boolean,
    enabled: Boolean = true,
    indent: Boolean = false,
    onChange: (Boolean) -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().clickable(enabled = enabled) { onChange(!checked) }
            .padding(start = if (indent) 36.dp else 16.dp, end = 16.dp, top = 12.dp, bottom = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Medium, color = if (enabled) Color.Unspecified else MaterialTheme.colorScheme.onSurfaceVariant)
            if (subtitle != null) Text(subtitle, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Spacer(Modifier.width(12.dp))
        Switch(checked = checked, onCheckedChange = onChange, enabled = enabled)
    }
}
