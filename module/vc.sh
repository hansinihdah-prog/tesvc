#!/system/bin/sh
# vc.sh - ubah tinggi suara voice changer tanpa pasang ulang modul.
#
#   su -c "sh /data/adb/modules/vcpitch/vc.sh 5"       suara cewek (bawaan)
#   su -c "sh /data/adb/modules/vcpitch/vc.sh 8"       lebih tinggi
#   su -c "sh /data/adb/modules/vcpitch/vc.sh -4"      lebih berat
#   su -c "sh /data/adb/modules/vcpitch/vc.sh 0"       mati (suara asli)
#   su -c "sh /data/adb/modules/vcpitch/vc.sh status"
#
# Nilai dibaca ulang setiap aplikasi mulai merekam: akhiri panggilan / keluar
# dari voice chat lalu masuk lagi. Kalau tidak berubah, reboot.

CONF=/data/adb/modules/vcpitch/system/vendor/etc/vcpitch.conf
PROP=debug.vcpitch.semitones

case "$1" in
  '' | status)
    echo "file modul        : $(cat "$CONF" 2>/dev/null)"
    echo "terlihat efek     : $(cat /vendor/etc/vcpitch.conf 2>/dev/null)"
    echo "properti          : $(getprop $PROP)"
    exit 0
    ;;
  off) N=0 ;;
  *[!0-9+-]*)
    echo "pakai angka -12..12, contoh: vc.sh 5  |  vc.sh 0 untuk mati"
    exit 1
    ;;
  *) N="${1#+}" ;;
esac

if [ "$N" -lt -12 ] || [ "$N" -gt 12 ]; then
  echo "angka harus antara -12 dan 12"
  exit 1
fi

# tulis di tempat (bukan ganti file) supaya label SELinux dan mount tetap sama
echo "$N" > "$CONF" || { echo "gagal menulis $CONF"; exit 1; }
setprop $PROP "$N"
echo "pitch diatur ke $N semitone. Tutup lalu buka lagi mic di aplikasinya."
