#!/bin/sh
# Prueba en un emulador de Android (la corre GitHub Actions): instala el APK, lo abre, espera el escaneo
# y revisa que la app no se haya cerrado por un error. Deja capturas y el registro en build/emulador.
set -e
PKG=lat.garridoitsolutions.monitorred
OUT=build/emulador
mkdir -p "$OUT"
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell pm grant $PKG android.permission.POST_NOTIFICATIONS
adb logcat -c
adb shell am start -W -n $PKG/.ui.MainActivity
sleep 100
adb exec-out screencap -p > "$OUT/1-al-abrir.png"
adb logcat -d > "$OUT/logcat.txt"
echo "--- Registro de la app ---"
grep -E "MonitorRed|AndroidRuntime" "$OUT/logcat.txt" || true
if grep -q "FATAL EXCEPTION" "$OUT/logcat.txt"; then
  echo "La app se cerró por un error"
  exit 1
fi
adb shell pidof $PKG > /dev/null || { echo "La app no está abierta"; exit 1; }
grep -q "Revisión de " "$OUT/logcat.txt" || { echo "No terminó ninguna revisión de la red"; exit 1; }
echo "La app abrió, escaneó la red y sigue funcionando."
