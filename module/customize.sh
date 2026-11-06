#!/system/bin/sh
# VC Pitch Up (AIDL) - installer untuk KernelSU / ReSukiSU / Magisk
SKIPUNZIP=0

# Sumber mic yang dikenai voice changer:
#   voice_communication = panggilan WhatsApp, voice chat game
#   mic                 = voice note WhatsApp, perekam suara biasa
SOURCES="voice_communication mic"

ui_print "- VC Pitch Up (AIDL): voice changer suara tinggi"
ui_print "- Sumber mic: $SOURCES"

case "$ARCH" in
  arm | arm64) ;;
  *) abort "! Arsitektur tidak didukung: $ARCH (butuh arm/arm64)" ;;
esac

. "$MODPATH/patch_effects.sh"

# --- 1) library efek: simpan hanya ABI yang ada di perangkat ---
for d in lib lib64; do
  if [ -d "/vendor/$d" ] && [ -d "$MODPATH/system/vendor/$d" ]; then
    set_perm_recursive "$MODPATH/system/vendor/$d" 0 0 0755 0644 u:object_r:vendor_file:s0
  else
    rm -rf "$MODPATH/system/vendor/$d"
  fi
done

# --- 2) file pengaturan nada (dibaca efek setiap mulai merekam) ---
mkdir -p "$MODPATH/system/vendor/etc"
echo 5 > "$MODPATH/system/vendor/etc/vcpitch.conf"
set_perm "$MODPATH/system/vendor/etc/vcpitch.conf" 0 0 0644 u:object_r:vendor_configs_file:s0

# --- 3) patch konfigurasi efek AIDL (salinan systemless, file asli tidak diubah) ---
FOUND=0
for f in /vendor/etc/audio_effects_config.xml \
         /vendor/etc/audio_effects_config_sec.xml \
         /odm/etc/audio_effects_config.xml \
         /odm/etc/audio_effects_config_sec.xml \
         /system/etc/audio_effects_config.xml \
         /system_ext/etc/audio_effects_config.xml \
         /product/etc/audio_effects_config.xml; do
  [ -f "$f" ] || continue
  case "$f" in
    /system/*) dst="$MODPATH$f"; ctx=u:object_r:system_file:s0 ;;
    *) dst="$MODPATH/system$f"; ctx=u:object_r:vendor_configs_file:s0 ;;
  esac
  if vcp_patch_xml "$f" "$dst"; then
    set_perm "$dst" 0 0 0644 "$ctx"
    FOUND=$((FOUND + 1))
    ui_print "  - dipatch: $f"
  else
    rm -f "$dst"
    ui_print "  ! gagal mem-patch: $f"
  fi
done

[ "$FOUND" -gt 0 ] || abort "! audio_effects_config.xml tidak ditemukan / gagal dipatch"

set_perm "$MODPATH/vc.sh" 0 0 0755
rm -f "$MODPATH/patch_effects.sh"

ui_print "- Selesai. REBOOT dulu, lalu tes di WhatsApp / ML / Roblox."
ui_print "- Atur nada: su -c \"sh /data/adb/modules/vcpitch/vc.sh 5\" (-12..12, 0 = mati)"
