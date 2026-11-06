#!/system/bin/sh
# patch_effects.sh - systemless patcher for the AIDL audio_effects_config(.xml/_sec.xml)
#
# Usage (sourced):  vcp_patch_xml <source.xml> <destination.xml>
# Uses: SOURCES (space separated capture sources, e.g. "voice_communication mic")
#
# Adds, without touching the original file:
#   - <library name="vcpitch" .../> to <libraries>
#   - <effect name="vcpitch" .../> to <effects>
#   - <apply effect="vcpitch"/> as the LAST effect of each wanted capture stream
#     (after echo cancellation / noise suppression), creating the stream or the
#     whole <preprocess> block if it does not exist.
# Every line it adds contains the word "vcpitch", so re-running it on an
# already patched file first strips the old lines (idempotent). XML comments
# are skipped, so commented-out samples in the stock file are never edited.

VCP_LIB_LINE='        <library name="vcpitch" path="libvcpitch.so"/>'
VCP_EFFECT_LINE='        <effect name="vcpitch" library="vcpitch" uuid="c1a94e7b-6f23-4d85-b0e2-3a97d5f1c842" type="5d3f7a1e-2b64-4c8e-9a10-7e4b2c6d8f31"/>'
VCP_APPLY_LINE='            <apply effect="vcpitch"/>'

# emit_stream <source-name>  -> writes a whole <stream> block to $_dst
vcp_emit_stream() {
  printf '%s\n' "        <stream type=\"$1\"> <!-- vcpitch -->" >> "$_dst"
  printf '%s\n' "$VCP_APPLY_LINE" >> "$_dst"
  printf '%s\n' "        </stream> <!-- vcpitch -->" >> "$_dst"
}

vcp_patch_xml() {
  _src="$1"
  _dst="$2"
  mkdir -p "${_dst%/*}" || return 1

  # ---- pass 1: what already exists (outside comments)? ----
  _has_pre=0
  _in_c=0
  for _s in $SOURCES; do eval "_has_$_s=0"; done
  while IFS= read -r _l || [ -n "$_l" ]; do
    case "$_l" in *vcpitch*) continue ;; esac
    if [ "$_in_c" = 1 ]; then
      case "$_l" in *"-->"*) _in_c=0 ;; esac
      continue
    fi
    case "$_l" in
      *"<!--"*)
        case "$_l" in *"-->"*) ;; *) _in_c=1 ;; esac
        continue
        ;;
    esac
    case "$_l" in *"<preprocess"*) _has_pre=1 ;; esac
    case "$_l" in
      *"<stream"*)
        for _s in $SOURCES; do
          case "$_l" in
            *"type=\"$_s\""* | *"type='$_s'"*) eval "_has_$_s=1" ;;
          esac
        done
        ;;
    esac
  done < "$_src"

  # ---- pass 2: write the patched copy ----
  : > "$_dst" || return 1
  _in_c=0
  _cur=""
  _done_lib=0
  _done_fx=0
  while IFS= read -r _l || [ -n "$_l" ]; do
    case "$_l" in *vcpitch*) continue ;; esac

    if [ "$_in_c" = 1 ]; then
      printf '%s\n' "$_l" >> "$_dst"
      case "$_l" in *"-->"*) _in_c=0 ;; esac
      continue
    fi
    case "$_l" in
      *"<!--"*)
        printf '%s\n' "$_l" >> "$_dst"
        case "$_l" in *"-->"*) ;; *) _in_c=1 ;; esac
        continue
        ;;
    esac

    case "$_l" in
      *"<libraries>"*)
        printf '%s\n' "$_l" >> "$_dst"
        printf '%s\n' "$VCP_LIB_LINE" >> "$_dst"
        _done_lib=1
        ;;
      *"</effects>"*)
        printf '%s\n' "$VCP_EFFECT_LINE" >> "$_dst"
        printf '%s\n' "$_l" >> "$_dst"
        _done_fx=1
        ;;
      *"<stream"*)
        printf '%s\n' "$_l" >> "$_dst"
        for _s in $SOURCES; do
          case "$_l" in
            *"type=\"$_s\""* | *"type='$_s'"*)
              case "$_l" in *"/>"*) ;; *) _cur="$_s" ;; esac
              ;;
          esac
        done
        ;;
      *"</stream>"*)
        if [ -n "$_cur" ]; then
          printf '%s\n' "$VCP_APPLY_LINE" >> "$_dst"
          _cur=""
        fi
        printf '%s\n' "$_l" >> "$_dst"
        ;;
      *"</preprocess>"*)
        for _s in $SOURCES; do
          eval "_h=\$_has_$_s"
          [ "$_h" = 1 ] || vcp_emit_stream "$_s"
        done
        printf '%s\n' "$_l" >> "$_dst"
        ;;
      *"</audio_effects_conf>"*)
        if [ "$_has_pre" = 0 ]; then
          printf '%s\n' "    <preprocess> <!-- vcpitch -->" >> "$_dst"
          for _s in $SOURCES; do vcp_emit_stream "$_s"; done
          printf '%s\n' "    </preprocess> <!-- vcpitch -->" >> "$_dst"
        fi
        printf '%s\n' "$_l" >> "$_dst"
        ;;
      *)
        printf '%s\n' "$_l" >> "$_dst"
        ;;
    esac
  done < "$_src"

  # sanity: library + effect + at least one apply must have been written
  [ "$_done_lib" = 1 ] && [ "$_done_fx" = 1 ] || return 2
  grep -q '<apply effect="vcpitch"/>' "$_dst" || return 3
  return 0
}
