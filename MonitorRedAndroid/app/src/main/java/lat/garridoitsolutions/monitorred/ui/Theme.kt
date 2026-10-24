package lat.garridoitsolutions.monitorred.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

// Verde azulado del logo del Monitor de Red
val Marca = Color(0xFF0F7F7A)
val Verde = Color(0xFF0F7B0F)
val Ambar = Color(0xFF8A5A00)

private val Claro = lightColorScheme(
    primary = Marca,
    onPrimary = Color.White,
    primaryContainer = Color(0xFFD3F1EE),
    onPrimaryContainer = Color(0xFF00201E),
    secondaryContainer = Color(0xFFE3EEED),
    background = Color(0xFFF5F7F7),
    surface = Color(0xFFF5F7F7),
    surfaceContainer = Color.White,
    surfaceContainerLow = Color.White,
    onSurface = Color(0xFF151A1A),
    onSurfaceVariant = Color(0xFF3F4948),
)

private val Oscuro = darkColorScheme(
    primary = Color(0xFF6FD6CE),
    onPrimary = Color(0xFF003734),
    primaryContainer = Color(0xFF00504C),
    onPrimaryContainer = Color(0xFFD3F1EE),
)

// Letra un poco más grande que la normal: se lee fácil sin anteojos
private val Letras = Typography().let { t ->
    t.copy(
        titleLarge = t.titleLarge.copy(fontSize = 24.sp, fontWeight = FontWeight.SemiBold),
        titleMedium = t.titleMedium.copy(fontSize = 19.sp, fontWeight = FontWeight.SemiBold),
        bodyLarge = t.bodyLarge.copy(fontSize = 17.sp, lineHeight = 24.sp),
        bodyMedium = t.bodyMedium.copy(fontSize = 16.sp, lineHeight = 22.sp),
        labelLarge = t.labelLarge.copy(fontSize = 16.sp, fontWeight = FontWeight.SemiBold),
    )
}

@Composable
fun MonitorTheme(dark: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = if (dark) Oscuro else Claro, typography = Letras, content = content)
}

val Destacado = TextStyle(fontSize = 30.sp, fontWeight = FontWeight.Bold)
