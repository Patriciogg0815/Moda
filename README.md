# Respaldo de Drivers para Windows

Aplicación para **guardar todos los drivers de un equipo, organizados por categoría**, y **volver a
instalarlos después de formatear**, sin tener que buscarlos uno por uno en internet (muchas veces los
fabricantes ya no los publican).

## Requisitos

- Windows 10 (versión 1607 o superior) u 11.
- Permisos de administrador (la app los pide sola).
- No necesita instalar nada: usa PowerShell, la interfaz gráfica de Windows (WPF) y las herramientas
  de Windows (`DISM` y `pnputil`).

## Cómo se usa

Al abrir la app aparece la **pantalla de inicio** con dos opciones grandes:

- **Respaldar drivers** (paso 1, antes de formatear)
- **Restaurar drivers** (paso 2, después de formatear)

Debajo se ve el estado del equipo, por ejemplo "3 dispositivos sin driver". Si la app encuentra un
respaldo en su misma carpeta, muestra un aviso con el botón **Restaurar ahora**.

### 1. Antes de formatear: respaldar

1. Copia la carpeta `RespaldoDrivers` a una **USB** (o a un disco que no vayas a formatear).
2. Doble clic en **`Iniciar-RespaldoDrivers.bat`** y acepta el permiso de administrador.
3. Elige **Respaldar drivers**. La app analiza el equipo y muestra:
   - a la izquierda, las **categorías** con su ícono, una casilla y cuántos drivers tiene;
   - a la derecha, los **drivers de la categoría elegida**: fabricante, dispositivo, versión y fecha.
4. Desmarca lo que no quieras guardar, revisa **Guardar en** (por defecto propone la USB) y presiona
   **Respaldar N drivers**. Una ventana muestra el progreso y, al terminar, el resultado con el botón
   **Abrir carpeta**.

Se crea una carpeta como esta:

```
Drivers_HP_ProBook 450 G8_2026-10-23\
├── 01 - Chipset y Sistema\
│   └── Intel - HeciClient - 2306.4.3.0\
├── 02 - Almacenamiento (SATA-NVMe)\
├── 04 - Video y Graficos\
│   └── Intel Corporation - iigd_dch - 31.0.101.4502\
├── 05 - Audio\
├── 06 - Red (Ethernet y WiFi)\
├── 07 - Bluetooth\
├── ...
├── respaldo.json                 ← índice que usa la app para reinstalar
├── inventario.csv                ← lista de drivers (se abre con Excel)
├── LEEME.txt                     ← datos del equipo e instrucciones
├── registro_respaldo.txt
├── RespaldoDrivers.ps1           ← copia de la app, lista para usar tras formatear
└── Iniciar-RespaldoDrivers.bat
```

### 2. Después de formatear: restaurar

1. Conecta la USB, abre la carpeta del respaldo y haz doble clic en **`Iniciar-RespaldoDrivers.bat`**.
2. En la pantalla de inicio presiona **Restaurar ahora** (o **Restaurar drivers** y luego **Buscar respaldo...**).
3. Revisa las categorías y presiona **Instalar N drivers**. La columna **Estado** de cada driver muestra
   *Instalado*, *Sin cambios* o *Error*.
4. Al terminar se muestra cuántos dispositivos quedaban sin driver antes y cuántos quedan ahora, con el
   botón **Reiniciar ahora**.

Los drivers se instalan en orden: primero chipset y almacenamiento, luego USB, video, audio, red, etc.
La categoría **Firmware y BIOS** viene desmarcada por seguridad (actualiza el BIOS al reiniciar);
márcala solo si sabes que la necesitas.

También puedes cargar cualquier carpeta con drivers descargados del fabricante (archivos `.inf`),
aunque no tenga `respaldo.json`.

## Categorías

| Carpeta | Tipos de dispositivo |
|---|---|
| 01 - Chipset y Sistema | Chipset, ME/MEI, ACPI, procesador |
| 02 - Almacenamiento (SATA-NVMe) | Controladoras SATA/RAID/NVMe, Intel RST/VMD |
| 03 - USB y Thunderbolt | Controladoras y dispositivos USB |
| 04 - Video y Graficos | Tarjetas de video Intel / AMD / NVIDIA |
| 05 - Audio | Realtek, Conexant, audio HDMI |
| 06 - Red (Ethernet y WiFi) | Tarjetas de red, WiFi, módems |
| 07 - Bluetooth | Adaptadores Bluetooth |
| 08 - Teclado, Mouse y Touchpad | Touchpad, teclados, HID |
| 09 - Camaras y Escaneres | Webcam, escáneres |
| 10 - Lectores de Tarjetas | SD, smart card |
| 11 - Biometricos y Seguridad | Lector de huella, TPM |
| 12 a 16 | Sensores, batería, puertos COM, impresoras, monitores |
| 17 - Firmware y BIOS | Actualizaciones de firmware (desmarcado al instalar) |
| 18 - Componentes de Software | Paneles y servicios de los drivers DCH |
| 19 - Extensiones de Drivers | Personalizaciones del fabricante del equipo |
| 99 - Otros | Cualquier otra clase |

## Uso por línea de comandos (opcional)

```powershell
# Respaldar todo en E:\ (crea E:\Drivers_<Fabricante>_<Modelo>_<fecha>)
powershell -ExecutionPolicy Bypass -File .\RespaldoDrivers.ps1 -Respaldar "E:\"

# Instalar todo desde un respaldo (excepto firmware)
powershell -ExecutionPolicy Bypass -File .\RespaldoDrivers.ps1 -Restaurar "E:\Drivers_HP_ProBook 450 G8_2026-10-23"
```

## Crear un .exe (opcional)

Si prefieres un único ejecutable, en Windows ejecuta:

```powershell
powershell -ExecutionPolicy Bypass -File .\RespaldoDrivers\Crear-EXE.ps1
```

Genera `RespaldoDrivers.exe` (usa el módulo [ps2exe](https://github.com/MScholtes/PS2EXE)). El `.exe`
también se copia dentro de cada respaldo.

## Cómo funciona

- **Respaldo:** `Get-WindowsDriver -Online` lista los drivers de terceros instalados (los que Windows
  no trae de fábrica) con su clase de dispositivo, que define la categoría. Cada driver se exporta con
  `pnputil /export-driver`; si falla, se copia su carpeta del almacén de drivers de Windows.
- **Instalación:** `pnputil /add-driver <carpeta>\*.inf /subdirs /install` por cada driver marcado y al
  final `pnputil /scan-devices` para que Windows detecte el hardware.

## Limitaciones

- Respalda **drivers**, no programas: utilidades como NVIDIA App, Realtek Audio Console o software de
  impresoras se instalan aparte (en drivers modernos muchas se descargan solas desde la Microsoft Store).
- Los drivers sirven para el mismo Windows y arquitectura (por ejemplo, x64). La app avisa si el respaldo
  es de otro modelo de equipo o de otra arquitectura.
- Si Windows ya instaló un driver más nuevo, `pnputil` lo deja como está ("Sin cambios").
