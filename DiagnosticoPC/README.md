# Diagnóstico PC

Revisa Windows en un minuto y muestra cada cosa en **rojo** (grave), **amarillo** (revisar) o **verde**
(bien), con un botón para arreglarla y una ventana con el **paso a paso** para hacerlo a mano. También
avisa junto al reloj cuando aparece un problema nuevo.

Nació del caso real de una laptop que se calentaba en la mochila porque no hibernaba bien y tenía
programas que no la dejaban suspenderse.

## Cómo usarla

1. Descarga `DiagnosticoPC.exe` (pestaña **Actions** → ejecución "Diagnóstico PC" → **Artifacts**, o en
   **Releases** cuando esté en `main`) y ábrelo con doble clic. Pide permiso de administrador.
   Como no está firmado, Windows puede mostrar "Windows protegió su PC": **Más información → Ejecutar de todas formas**.
2. Presiona **Analizar mi PC**.
3. Elige un resultado de la lista: arriba dice qué pasa; abajo están los botones **Arreglar**,
   **Ver el paso a paso** y **Volver a revisar**.

## Qué revisa

| Área | Revisiones | Arreglos automáticos |
|---|---|---|
| Energía | Hibernación (y si «Hibernar tras» está en «Nunca»), qué pasa al cerrar la tapa, programas que no dejan suspender (`powercfg /requests`), qué despierta la PC de madrugada, plan de energía | Activar la hibernación (1 hora con batería), suspender al cerrar la tapa, apagar temporizadores de reactivación, ignorar a un programa, quitar permiso de despertar a un dispositivo, plan Equilibrado |
| Temperatura | Sensores térmicos y veces que el procesador frenó (evento 37) | Limitar el procesador al 99 % (sin Turbo) |
| Programas | Uso de procesador y memoria por programa, programas del arranque (y los que ya no existen) | Cerrar un programa, quitarlo del arranque |
| Drivers | Dispositivos con error (código del Administrador de dispositivos), driver de video genérico o antiguo | Reinstalar o activar el dispositivo, volver a detectar el hardware, abrir drivers opcionales de Windows Update |
| Pantallas azules | Confirma si hubo (eventos 1001 y Kernel-Power 41, y los minidumps), código, causa probable y apagones de golpe | Según la causa: inicio rápido, drivers, prueba de memoria, revisión del disco, temperatura o reparación de Windows |
| Registro | Inicio rápido, volcado de memoria, Shell/Userinit cambiados, bloqueos del Administrador de tareas y del Editor del Registro, programas que se abren en su lugar | Restaurar los valores normales |
| Archivos de Windows | `Repair-WindowsImage -CheckHealth` | DISM `/RestoreHealth` + `sfc /scannow` |
| Disco, batería y seguridad | Espacio libre, salud (SMART, desgaste, errores), batería (capacidad y ciclos), antivirus, reinicio pendiente | Borrar temporales, revisar el disco al reiniciar, informe de batería, reiniciar |

Antes de cada cambio la app pide confirmación, crea un **punto de restauración** y guarda el valor
anterior. En **Herramientas y cambios** se puede **deshacer** cada cambio.

## Avisos

Pestaña **Avisos**: cada 2 a 30 minutos (5 por defecto) revisa pantallas azules, apagones, temperatura,
programas que usan mucho procesador durante varios minutos, memoria, disco y reactivaciones de
madrugada. Al cerrar la ventana sigue junto al reloj (se puede desactivar). La opción **Iniciar con
Windows** crea la tarea programada `DiagnosticoPC-Avisos`, que arranca la app con `-Avisos` (sin
ventana y sin preguntar por permisos). La edición de la Store no tiene esa opción.

## Archivos

| Archivo | Para qué sirve |
|---|---|
| `DiagnosticoPC.ps1` | Toda la app (PowerShell 5.1 + WPF). También funciona sin compilar |
| `Crear-EXE.ps1` | Compila el `.exe` con ps2exe (`-EdicionStore` para la Store) |
| `icono.ico` | Ícono de la app |
| `store/` | Kit para la Microsoft Store: manifiesto, logos, arte, privacidad y la ficha con todos los textos (`FICHA-TIENDA.md`) |

Datos de la app: `%APPDATA%\DiagnosticoPC\` (`ajustes.json`, `cambios.json`, `registro.txt` e informes).

Modo consola: `.\DiagnosticoPC.ps1 -Analizar [-Informe archivo.html]`.

## Pruebas

`.github/workflows/diagnostico-pc.yml` corre en Windows `.github/scripts/Probar-DiagnosticoPC.ps1`:
prueba la lógica (lectura de energía, pantallas azules, arranque, registro y energía con deshacer,
tarea de inicio, avisos), hace un análisis real del equipo de GitHub y llena la ventana con una laptop
de ejemplo para sacar las capturas. Después compila el `.exe`, la edición Store y el MSIX, y arma el
kit `MicrosoftStore-DiagnosticoPC-1.0.N`.
