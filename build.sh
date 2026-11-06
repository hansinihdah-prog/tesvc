#!/usr/bin/env bash
# build.sh - kompilasi libvcpitch.so (efek audio AIDL V2) untuk arm64 + arm32
# lalu rakit modul KernelSU/ReSukiSU.
#
# Dijalankan di GitHub Actions (ubuntu-24.04 sudah punya NDK, Android SDK
# build-tools (aidl), git dan zip). Bisa juga dijalankan di Linux lain bila
# ANDROID_NDK_HOME dan ANDROID_HOME diset.
#
# Opsional: taruh library asli dari HP di devlibs/arm64 dan devlibs/arm32
# (lihat README.md). Bila lengkap, linker memeriksa SEMUA simbol terhadap
# library asli itu (-z defs), jadi ketidakcocokan ABI ketahuan saat build.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-$ROOT/work}"
OUT="${OUT:-$ROOT/out}"
DEVLIBS="${DEVLIBS:-$ROOT/devlibs}"
AOSP_TAG="${AOSP_TAG:-android-15.0.0_r1}"
AOSP_URL="${AOSP_URL:-https://android.googlesource.com/platform}"
EFFECT_VER="${EFFECT_VER:-2}"   # android.hardware.audio.effect (vintf manifest HP: versi 2)
TYPES_VER="${TYPES_VER:-3}"     # android.media.audio.common.types (NEEDED di libpreprocessingaidl_mtk.so: V3)
COMMON_VER="${COMMON_VER:-2}"   # android.hardware.common (NEEDED: V2)
FMQ_VER="${FMQ_VER:-1}"         # android.hardware.common.fmq (NEEDED: V1)
API="${ANDROID_API:-35}"
MODULE_VERSION="${MODULE_VERSION:-v2.0}"
ABIS="${ABIS:-arm64 arm32}"

log() { printf '\n=== %s\n' "$*"; }
die() { printf '\nGAGAL: %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------ toolchain
NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_LATEST_HOME:-}}"
{ [ -n "$NDK" ] && [ -d "$NDK" ]; } || die "NDK tidak ditemukan (set ANDROID_NDK_HOME)"
LLVM="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
SYSROOT="$LLVM/sysroot"
[ -x "$LLVM/bin/clang++" ] || die "clang++ tidak ada di $LLVM/bin"

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}"
AIDL="$(ls -d "$SDK"/build-tools/*/aidl 2>/dev/null | sort -V | tail -n 1 || true)"
{ [ -n "$AIDL" ] && [ -x "$AIDL" ]; } || die "aidl tidak ditemukan di $SDK/build-tools"

log "NDK   : $NDK"
log "aidl  : $AIDL"
log "tag   : $AOSP_TAG"
"$LLVM/bin/clang++" --version | head -n 1

mkdir -p "$WORK" "$OUT"

# ----------------------------------------------------------- sumber AOSP
fetch() { # fetch <repo> <nama-dir> [dir-sparse...]
    local repo="$1" dest="$WORK/aosp/$2"
    shift 2
    [ -d "$dest/.git" ] && return 0
    rm -rf "$dest"
    mkdir -p "$(dirname "$dest")"
    log "git clone $repo @ $AOSP_TAG"
    if git clone --quiet --depth 1 --filter=blob:none --sparse --branch "$AOSP_TAG" \
        "$AOSP_URL/$repo" "$dest" 2>/dev/null; then
        if [ "$#" -gt 0 ]; then git -C "$dest" sparse-checkout set "$@"; fi
    else
        rm -rf "$dest"
        git clone --quiet --depth 1 --branch "$AOSP_TAG" "$AOSP_URL/$repo" "$dest" ||
            die "clone $repo gagal (tag $AOSP_TAG ada?)"
    fi
}

fetch hardware/interfaces hi audio/aidl common/aidl common/fmq/aidl
fetch system/hardware/interfaces shi media
fetch system/libfmq libfmq
fetch system/libbase libbase
fetch system/core core libcutils libutils libsystem
fetch system/logging logging liblog
fetch system/media media audio_effects audio_utils audio

HI="$WORK/aosp/hi"
SHI="$WORK/aosp/shi"

snap() { # snap <root> <paket> <versi>
    find "$1" -type d -path "*/aidl_api/$2/$3" 2>/dev/null | head -n 1 || true
}
EFF_DIR="$(snap "$HI" android.hardware.audio.effect "$EFFECT_VER")"
TYPES_DIR="$(snap "$SHI" android.media.audio.common.types "$TYPES_VER")"
COMMON_DIR="$(snap "$HI" android.hardware.common "$COMMON_VER")"
FMQ_DIR="$(snap "$HI" android.hardware.common.fmq "$FMQ_VER")"
for v in EFF_DIR TYPES_DIR COMMON_DIR FMQ_DIR; do
    [ -n "${!v}" ] && [ -d "${!v}" ] || die "snapshot AIDL $v tidak ditemukan di tag $AOSP_TAG (versi dibeku yang ada: $(ls "$HI/audio/aidl/aidl_api/android.hardware.audio.effect" 2>/dev/null | tr '\n' ' '))"
    log "$v = ${!v#$WORK/}"
done

# --------------------------------------------------- generate header AIDL (NDK)
GEN="$WORK/gen"
rm -rf "$GEN"
mkdir -p "$GEN/include" "$GEN/src"
INC_AIDL=(-I "$EFF_DIR" -I "$TYPES_DIR" -I "$COMMON_DIR" -I "$FMQ_DIR")

gen_dir() { # gen_dir <dir-snapshot> <versi>
    local dir="$1" ver="$2" hash="" f
    local hashargs=()
    if [ -f "$dir/.hash" ]; then
        hash="$(tr -d '[:space:]' <"$dir/.hash")"
        hashargs=(--hash "$hash")
    fi
    while IFS= read -r f; do
        "$AIDL" --lang=ndk --structured --stability=vintf --version "$ver" "${hashargs[@]}" \
            "${INC_AIDL[@]}" -o "$GEN/src" -h "$GEN/include" "$f" ||
            die "aidl gagal untuk $f"
    done < <(find "$dir" -name '*.aidl' | sort)
}
log "generate header AIDL"
gen_dir "$EFF_DIR" "$EFFECT_VER"
gen_dir "$TYPES_DIR" "$TYPES_VER"
gen_dir "$COMMON_DIR" "$COMMON_VER"
gen_dir "$FMQ_DIR" "$FMQ_VER"
NH="$(find "$GEN/include" -name '*.h' | wc -l)"
[ "$NH" -gt 0 ] || die "tidak ada header AIDL yang dihasilkan"
log "$NH header AIDL dihasilkan"

# ------------------------------------------------------------- include path
INCS=()
add_inc() {
    if [ -d "$1" ]; then INCS+=("-I$1"); else echo "peringatan: dir include tidak ada: ${1#$WORK/}"; fi
}
add_inc "$GEN/include"
add_inc "$ROOT/src"
add_inc "$HI/audio/aidl/default"
add_inc "$HI/audio/aidl/default/include"
add_inc "$HI/audio/aidl/common/include"
add_inc "$WORK/aosp/libfmq/include"
add_inc "$WORK/aosp/libbase/include"
add_inc "$WORK/aosp/core/libcutils/include"
add_inc "$WORK/aosp/core/libutils/include"
add_inc "$WORK/aosp/core/libsystem/include"
add_inc "$WORK/aosp/logging/liblog/include"
add_inc "$WORK/aosp/media/audio_effects/include"
add_inc "$WORK/aosp/media/audio_utils/include"
add_inc "$WORK/aosp/media/audio/include"

SRCS=(
    "$HI/audio/aidl/default/EffectImpl.cpp"
    "$HI/audio/aidl/default/EffectThread.cpp"
    "$HI/audio/aidl/default/EffectContext.cpp"
    "$ROOT/src/VcPitchSw.cpp"
)
for s in "${SRCS[@]}"; do [ -f "$s" ] || die "sumber tidak ada: ${s#$WORK/}"; done

# Library yang dimuat HP (NEEDED di libpreprocessingaidl_mtk.so milik MediaTek).
NEEDED=(
    libc++.so
    libbase.so
    libbinder_ndk.so
    libcutils.so
    liblog.so
    libutils.so
    libfmq.so
    libaudioaidlcommon.so
    libaudioutils.so
    "android.hardware.audio.effect-V${EFFECT_VER}-ndk.so"
    "android.media.audio.common.types-V${TYPES_VER}-ndk.so"
    "android.hardware.common-V${COMMON_VER}-ndk.so"
    "android.hardware.common.fmq-V${FMQ_VER}-ndk.so"
)

# --------------------------------------------------------------- build per ABI
build_abi() { # build_abi <abi> <triple-clang> <triple-sysroot>
    local abi="$1" triple="$2" sysroot_triple="$3"
    local obj="$WORK/obj/$abi" stub="$WORK/stub/$abi" out="$OUT/$abi" cxxdir="$WORK/libcxx/$abi"
    rm -rf "$obj" "$stub" "$cxxdir" "$out"
    mkdir -p "$obj" "$stub" "$out" "$cxxdir/generic"
    local cxx=("$LLVM/bin/clang++" "--target=${triple}${API}" "--sysroot=$SYSROOT")

    # libc++ platform memakai namespace std::__1, header libc++ NDK memakai
    # std::__ndk1. Samakan, supaya tipe std::* yang lewat batas library
    # (string, vector, optional, ...) identik dengan yang dipakai library HP.
    cp -r "$SYSROOT/usr/include/c++/v1/." "$cxxdir/generic/"
    local isys=(-isystem "$cxxdir/generic")
    if [ -d "$SYSROOT/usr/include/$sysroot_triple/c++/v1" ]; then
        mkdir -p "$cxxdir/arch"
        cp -r "$SYSROOT/usr/include/$sysroot_triple/c++/v1/." "$cxxdir/arch/"
        isys=(-isystem "$cxxdir/arch" "${isys[@]}")
    fi
    { grep -rl "__ndk1" "$cxxdir" || true; } | xargs -r sed -i 's/__ndk1/__1/g'
    if grep -rq "__ndk1" "$cxxdir"; then die "[$abi] masih ada __ndk1 di header libc++"; fi
    grep -rh "_LIBCPP_ABI_NAMESPACE" "$cxxdir" | grep -m1 "define" || true

    local flags=(
        -std=c++20 -O2 -fPIC -fno-exceptions -fno-rtti
        -ffunction-sections -fdata-sections -w
        -nostdinc++ "${isys[@]}"
        -D__ANDROID_VENDOR__ -D__ANDROID_VNDK__ -DANDROID_STRICT
        "${INCS[@]}"
    )

    local objs=() s o
    for s in "${SRCS[@]}"; do
        o="$obj/$(basename "${s%.cpp}").o"
        log "[$abi] c++ $(basename "$s")"
        "${cxx[@]}" "${flags[@]}" -c "$s" -o "$o" || die "kompilasi gagal: $(basename "$s") ($abi)"
        objs+=("$o")
    done

    # library yang di-link: asli dari HP bila ada, kalau tidak stub kosong
    # (stub hanya menaruh entri NEEDED yang benar; simbol diselesaikan di HP).
    local libs=() strict=1 n
    for n in "${NEEDED[@]}"; do
        if [ -f "$DEVLIBS/$abi/$n" ]; then
            libs+=("$DEVLIBS/$abi/$n")
        else
            printf 'void vcp_stub(void){}\n' |
                "${cxx[@]}" -x c - -shared -nostdlib -Wl,-soname,"$n" -o "$stub/$n" ||
                die "gagal membuat stub $n"
            libs+=("$stub/$n")
            strict=0
        fi
    done
    local zflag="-Wl,-z,undefs"
    if [ "$strict" = 1 ]; then
        zflag="-Wl,-z,defs"
        log "[$abi] mode ketat: semua simbol diperiksa terhadap library asli HP"
    else
        log "[$abi] mode longgar: simbol tidak diperiksa (devlibs/$abi belum lengkap)"
    fi

    local so="$out/libvcpitch.so"
    log "[$abi] link"
    "${cxx[@]}" -shared -nostdlib++ "${objs[@]}" -o "$so" \
        -Wl,-soname,libvcpitch.so \
        -Wl,--version-script="$ROOT/src/vcpitch.map" \
        -Wl,--gc-sections -Wl,-z,max-page-size=16384 -Wl,-z,noexecstack \
        -Wl,--build-id=none -Wl,--allow-shlib-undefined \
        -Wl,--no-as-needed "${libs[@]}" "$zflag" ||
        die "link gagal ($abi). Bila mode ketat: ada simbol yang tidak cocok dengan library HP, lihat log di atas."

    "$LLVM/bin/llvm-strip" --strip-unneeded "$so"

    local exports
    exports="$("$LLVM/bin/llvm-nm" -D --defined-only "$so" | awk '{print $NF}')"
    local sym
    for sym in createEffect queryEffect destroyEffect; do
        grep -qx "$sym" <<<"$exports" || die "[$abi] simbol $sym tidak diekspor"
    done
    "$LLVM/bin/llvm-readelf" -d "$so" | grep -E "NEEDED|SONAME" | tee "$out/needed.txt"
    "$LLVM/bin/llvm-nm" -D --undefined-only "$so" | awk '{print $NF}' | sort >"$out/undefined.txt"
    log "[$abi] OK: $(wc -c <"$so") byte, $(wc -l <"$out/undefined.txt") simbol tak terdefinisi"
}

for abi in $ABIS; do
    case "$abi" in
        arm64) build_abi arm64 aarch64-linux-android aarch64-linux-android ;;
        arm32) build_abi arm32 armv7a-linux-androideabi arm-linux-androideabi ;;
        *) die "ABI tidak dikenal: $abi" ;;
    esac
done

# ------------------------------------------------------------------ modul zip
log "rakit modul"
PKG="$WORK/pkg"
rm -rf "$PKG"
cp -r "$ROOT/module" "$PKG"
mkdir -p "$PKG/system/vendor/lib64/soundfx" "$PKG/system/vendor/lib/soundfx"
[ -f "$OUT/arm64/libvcpitch.so" ] && cp "$OUT/arm64/libvcpitch.so" "$PKG/system/vendor/lib64/soundfx/"
[ -f "$OUT/arm32/libvcpitch.so" ] && cp "$OUT/arm32/libvcpitch.so" "$PKG/system/vendor/lib/soundfx/"
rmdir "$PKG/system/vendor/lib64/soundfx" "$PKG/system/vendor/lib/soundfx" 2>/dev/null || true
sed -i "s/^version=.*/version=${MODULE_VERSION}/" "$PKG/module.prop"
chmod 755 "$PKG"/*.sh "$PKG/META-INF/com/google/android/update-binary"
ZIP="$OUT/VCPitchUp-AIDL-${MODULE_VERSION}.zip"
rm -f "$ZIP"
(cd "$PKG" && zip -r -X -9 "$ZIP" . >/dev/null)
unzip -l "$ZIP"
log "SELESAI: $ZIP"
