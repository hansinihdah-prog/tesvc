# VC Pitch Up (AIDL) - voice changer suara cewek untuk Samsung A05 (Android 15)

Efek audio *preprocess* berbasis kerangka efek AOSP (`EffectImpl`) yang dimuat
oleh layanan efek MediaTek (`android.hardware.audio.effect` AIDL V2). Menaikkan
nada mic (default +5 semitone) untuk sumber `voice_communication` (panggilan,
voice chat game) dan `mic` (voice note).

> Belum pernah dijalankan di HP. Logika DSP-nya sudah diuji di komputer, dan
> patcher konfigurasi sudah diuji pada file asli HP. Library-nya baru bisa
> dibuktikan setelah dikompilasi di GitHub Actions dan dites di A05.

## 1. Build di GitHub Actions

1. Buat repo **privat** baru di GitHub, misalnya `vcpitch-aidl`.
2. Unggah seluruh isi folder ini. Folder tersembunyi `.github` kadang tidak ikut
   terunggah dari HP. Kalau tab **Actions** kosong, buat file secara manual:
   *Add file -> Create new file*, nama `.github/workflows/build.yml`, lalu tempel
   isi `WORKFLOW_build.yml`.
3. Tab **Actions** -> **Build VC Pitch Up (AIDL)** -> **Run workflow**.
4. Setelah selesai, buka run-nya, bagian **Artifacts**, unduh `vcpitch-aidl`.
   Di dalamnya ada `VCPitchUp-AIDL-v2.0.zip` (modul) dan `build.log`.
5. Kalau gagal: buka log langkah **Build library dan modul**, salin sekitar 60
   baris terakhir sebelum tulisan `GAGAL:` (atau baris `error:` pertama), kirim
   ke saya. Build pertama kemungkinan masih butuh perbaikan kecil.

## 2. (Disarankan) Pemeriksaan simbol ketat dengan library asli HP

Tanpa langkah ini, build memakai library kosong sebagai pengganti dan **tidak**
bisa memastikan simbolnya cocok dengan HP. Dengan library asli, linker menolak
build bila ada ketidakcocokan, jadi masalah ketahuan sebelum dipasang.

Di Termux, salin library dari HP:

```
mkdir -p /sdcard/Download/devlibs/arm64 /sdcard/Download/devlibs/arm32
for f in libc++.so libbase.so libbinder_ndk.so libcutils.so liblog.so libutils.so \
         libfmq.so libaudioaidlcommon.so libaudioutils.so \
         android.hardware.audio.effect-V2-ndk.so \
         android.media.audio.common.types-V3-ndk.so \
         android.hardware.common-V2-ndk.so android.hardware.common.fmq-V1-ndk.so; do
  p=$(su -c "find /vendor/lib64 /system/lib64 /apex/*/lib64 -name $f 2>/dev/null | head -1")
  [ -n "$p" ] && su -c "cp $p /sdcard/Download/devlibs/arm64/" || echo "tidak ketemu (64): $f"
  p=$(su -c "find /vendor/lib /system/lib /apex/*/lib -name $f 2>/dev/null | head -1")
  [ -n "$p" ] && su -c "cp $p /sdcard/Download/devlibs/arm32/" || echo "tidak ketemu (32): $f"
done
```

Taruh isi `devlibs/arm64` dan `devlibs/arm32` ke folder dengan nama sama di repo,
lalu jalankan ulang workflow. Log akan menulis *mode ketat* bila semuanya lengkap.

## 3. Pasang dan tes

1. ReSukiSU -> **Modul** -> pasang `VCPitchUp-AIDL-v2.0.zip` -> **reboot**.
2. Rekam VN atau mulai panggilan WhatsApp ke teman.
3. Kalau suara tidak berubah, ambil log:
   ```
   su -c "logcat -d | grep -i -E 'vcpitch|AHAL_VcPitch|EffectFactory|AHAL_EffectConfig'" > /sdcard/Download/vc_log3.txt
   su -c "sleep 20; dumpsys media.audio_flinger > /sdcard/Download/vc_flinger2.txt"
   ```
   (jalankan perintah kedua, lalu dalam 20 detik rekam VN dan tahan).

Mengatur nada (-12..12, 0 = mati):

```
su -c "sh /data/adb/modules/vcpitch/vc.sh 8"
```

## 4. Kalau audio bermasalah

- Matikan modul: `su -c "touch /data/adb/modules/vcpitch/disable"` lalu reboot.
- Kalau HP tidak bisa masuk normal: boot ke mode aman KernelSU/ReSukiSU
  (tekan Volume Bawah berulang kali saat logo boot) atau hapus folder
  `/data/adb/modules/vcpitch` lewat recovery.

## 5. Catatan teknis

- Library menyertakan `EffectImpl`, `EffectThread`, dan `EffectContext` dari AOSP
  (`android-15.0.0_r1`) dan mengekspor hanya `createEffect`, `queryEffect`,
  `destroyEffect`, persis seperti library efek AOSP lain.
- Header libc++ NDK diubah dari `std::__ndk1` ke `std::__1` agar tipe std yang
  lewat batas library sama dengan libc++ milik HP (library HP memakai `__1`).
- Efek memakai tipe UUID khusus (`5d3f7a1e-...`) lewat atribut `type` di
  `audio_effects_config(.xml/_sec.xml)`, seperti `extension_effect` di AOSP.
- DSP: WSOLA (time-stretch) + resampling, latensi sekitar 30-40 ms.
- Pengaturan nada dibaca dari `/vendor/etc/vcpitch.conf`, lalu properti
  `debug.vcpitch.semitones`, lalu bawaan +5.
