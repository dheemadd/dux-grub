#!/usr/bin/env bash
# dux-grub-sync.sh — sync the GRUB theme with Dux Shell (Fedora).
#
#  1. Gets the current wallpaper via Dux Shell IPC: `dms ipc call wallpaper get`
#  2. Reads matugen colours Dux Shell already generated (never runs matugen):
#       a) ~/.config/matugen/dux-grub/colors.conf  (our template, rendered by Dux)
#       b) fallback: ~/.cache/dms/dms-colors.json  (Dux Shell's colour cache)
#  3. Renders a 1920x1080 PNG background + 9-slice menu boxes with ImageMagick
#  4. Patches theme.txt colours, deploys via the sudoers-whitelisted helper
#  5. Runs `sudo grub2-mkconfig -o /boot/grub2/grub.cfg`
#
# Env overrides: DUX_GRUB_RES (default 1920x1080), DUX_GRUB_MKCONFIG=0 to skip step 5.
set -euo pipefail

SHARE_DIR="${DUX_GRUB_SHARE:-$HOME/.local/share/dux-grub}"
STAGE="$SHARE_DIR/theme"                     # rendered files, picked up by deploy helper
TEMPLATE_THEME="$SHARE_DIR/template/theme.txt"
ICONS_SRC="$SHARE_DIR/src/icons"
DEPLOY_HELPER="/usr/local/libexec/dux-grub-deploy"
MATUGEN_CONF="$HOME/.config/matugen/dux-grub/colors.conf"
DMS_COLORS="${XDG_CACHE_HOME:-$HOME/.cache}/dms/dms-colors.json"
RES="${DUX_GRUB_RES:-1920x1080}"
W="${RES%x*}"; H="${RES#*x}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

log() { echo "[dux-grub] $*"; }
die() { echo "[dux-grub] ERROR: $*" >&2; exit 1; }

# ImageMagick 7 ships `magick`; IM6 (older Fedora) ships `convert`.
if command -v magick >/dev/null; then IM=(magick); elif command -v convert >/dev/null; then IM=(convert); else die "ImageMagick not installed"; fi

# Serialise runs (path unit can fire twice per wallpaper change).
exec 9>"$SHARE_DIR/.lock"; flock 9

# --------------------------------------------------------------------------
# 1. Wallpaper from Dux Shell IPC
# --------------------------------------------------------------------------
get_wallpaper() {
    local wp=""
    if command -v dms >/dev/null; then
        wp="$(dms ipc call wallpaper get 2>/dev/null | tail -n1 | tr -d '\r' | sed 's/^"//; s/"$//')"
    fi
    wp="${wp/#file:\/\//}"; wp="${wp/#\~/$HOME}"
    printf '%s' "$wp"
}
WALLPAPER="$(get_wallpaper)"
log "wallpaper: ${WALLPAPER:-<none>}"

# --------------------------------------------------------------------------
# 2. Matugen colours (Material You roles)
# --------------------------------------------------------------------------
declare -A C=(   # dark defaults, overwritten by Dux Shell output
    [mode]=dark [primary]="#c2c1ff" [on_primary]="#2a2a60" [secondary]="#c6c4dd"
    [surface]="#131317" [on_surface]="#e5e1e7" [on_surface_variant]="#c7c5d0"
    [surface_container]="#201f23" [surface_container_high]="#2a292e"
    [surface_container_highest]="#353438" [outline]="#918f9a"
)
if [ -r "$MATUGEN_CONF" ]; then
    log "colours: $MATUGEN_CONF"
    while IFS='=' read -r k v; do
        [[ "$k" =~ ^[a-z_]+$ ]] && [ -n "${C[$k]+x}" ] && C[$k]="$v"
    done < "$MATUGEN_CONF"
elif [ -r "$DMS_COLORS" ] && command -v jq >/dev/null; then
    log "colours: $DMS_COLORS (fallback)"
    C[mode]="$(jq -r '.mode // "dark"' "$DMS_COLORS")"
    [ "${C[mode]}" = light ] || C[mode]=dark
    for k in "${!C[@]}"; do
        [ "$k" = mode ] && continue
        v="$(jq -r --arg m "${C[mode]}" --arg k "$k" '.colors[$m][$k] // empty' "$DMS_COLORS")"
        [ -n "$v" ] && C[$k]="$v"
    done
else
    log "no Dux Shell matugen output found, using default palette"
fi
for k in "${!C[@]}"; do   # reject anything that is not #rrggbb
    [ "$k" = mode ] || [[ "${C[$k]}" =~ ^#[0-9a-fA-F]{6}$ ]] || die "bad colour $k=${C[$k]}"
done

# --------------------------------------------------------------------------
# 3. Background image
# --------------------------------------------------------------------------
mkdir -p "$STAGE/icons"
SRC_IMG="$TMP/src.png"
if [[ "$WALLPAPER" =~ ^#[0-9a-fA-F]{6}$ ]]; then           # Dux solid-colour wallpaper
    "${IM[@]}" -size "${W}x${H}" "xc:$WALLPAPER" "$SRC_IMG"
elif [ -f "$WALLPAPER" ]; then
    case "${WALLPAPER,,}" in
        *.mp4|*.mkv|*.webm|*.mov|*.avi)
            command -v ffmpeg >/dev/null || die "ffmpeg needed for video wallpapers"
            ffmpeg -loglevel error -y -i "$WALLPAPER" -vframes 1 "$SRC_IMG" ;;
        *) "${IM[@]}" "${WALLPAPER}[0]" "$SRC_IMG" ;;          # [0] = first frame (gif)
    esac
else
    log "wallpaper unavailable, using surface colour"
    "${IM[@]}" -size "${W}x${H}" "xc:${C[surface]}" "$SRC_IMG"
fi

# Fill-crop to the GRUB resolution, strip metadata, force 8-bit RGB PNG
# (GRUB cannot read 16-bit/indexed/interlaced PNGs).
"${IM[@]}" "$SRC_IMG" -auto-orient -resize "${W}x${H}^" -gravity center -extent "${W}x${H}" \
    -strip -colorspace sRGB -type TrueColor -depth 8 "$TMP/sharp.png"

# Frosted panel behind the menu: blurred wallpaper tinted with surface_container,
# rounded corners, primary-coloured outline (mirrors the original Caelestia look).
PW=$((W * 5 / 8)); PH=$((H * 20 / 27)); PX=$(((W - PW) / 2)); PY=$(((H - PH) / 2)); R=16
"${IM[@]}" "$TMP/sharp.png" -crop "${PW}x${PH}+${PX}+${PY}" +repage -blur 0x30 \
    \( -size "${PW}x${PH}" "xc:${C[surface_container]}" -alpha set -channel A -evaluate set 75% +channel \) \
    -composite \( -size "${PW}x${PH}" xc:none -fill white -draw "roundrectangle 0,0 $((PW-1)),$((PH-1)) $R,$R" \) \
    -alpha set -compose DstIn -composite "$TMP/panel.png"
"${IM[@]}" "$TMP/sharp.png" "$TMP/panel.png" -geometry "+${PX}+${PY}" -compose over -composite \
    -fill none -stroke "${C[primary]}" -strokewidth 2 \
    -draw "roundrectangle $PX,$PY $((PX+PW-1)),$((PY+PH-1)) $R,$R" \
    -strip -type TrueColor -depth 8 "PNG24:$STAGE/background.png"
log "background rendered (${W}x${H})"

# --------------------------------------------------------------------------
# 4. 9-slice pixmaps for menu items / selection / timeout bar
#    name, fill colour, alpha, height
# --------------------------------------------------------------------------
nine_slice() {
    local name=$1 col=$2 alpha=$3 h=$4 r=12 mid=20
    (( r > h / 2 )) && r=$((h / 2))
    local cw=$(( r > 2 ? r : 2 )) ch=$((r + 2))
    (( ch * 2 >= h )) && ch=$(( (h - 1) / 2 > 0 ? (h - 1) / 2 : 1 ))
    local w=$((cw * 2 + mid)) box="$TMP/$name.png"
    "${IM[@]}" -size "${w}x${h}" xc:none -fill "$col" -draw "roundrectangle 0,0 $((w-1)),$((h-1)) $r,$r" \
        -channel A -evaluate multiply "$alpha" +channel "$box"
    local -A g=(
        [nw]="${cw}x${ch}+0+0"            [n]="${mid}x${ch}+${cw}+0"            [ne]="${cw}x${ch}+$((w-cw))+0"
        [w]="${cw}x$((h-2*ch))+0+${ch}"   [c]="${mid}x$((h-2*ch))+${cw}+${ch}"  [e]="${cw}x$((h-2*ch))+$((w-cw))+${ch}"
        [sw]="${cw}x${ch}+0+$((h-ch))"    [s]="${mid}x${ch}+${cw}+$((h-ch))"    [se]="${cw}x${ch}+$((w-cw))+$((h-ch))"
    )
    for s in "${!g[@]}"; do
        "${IM[@]}" "$box" -crop "${g[$s]}" +repage -depth 8 "PNG32:$STAGE/${name}_${s}.png"
    done
}
ITEM_H=54   # = max(30 + 2*item_padding, item_height) for the theme.txt defaults
nine_slice item       "${C[surface_container_high]}"    0.4 "$ITEM_H"
nine_slice select     "${C[surface_container_highest]}" 0.8 "$ITEM_H"
nine_slice timeout_bg "${C[surface_container_high]}"    1.0 12
nine_slice timeout_hl "${C[primary]}"                   1.0 12

# Icons are white; invert them when Dux Shell is in light mode so they stay readable.
if [ -d "$ICONS_SRC" ]; then
    for f in "$ICONS_SRC"/*.png; do
        if [ "${C[mode]}" = light ]; then "${IM[@]}" "$f" -channel RGB -negate +channel "PNG32:$STAGE/icons/${f##*/}"
        else cp -f "$f" "$STAGE/icons/"; fi
    done
fi

# --------------------------------------------------------------------------
# 5. theme.txt colours: Material You role -> GRUB key
#    item_color          <- on_surface_variant (unselected entries)
#    selected_item_color <- on_surface         (highlighted entry)
#    *(primary drives the panel outline + progress bar highlight)*
# --------------------------------------------------------------------------
[ -f "$TEMPLATE_THEME" ] || die "theme template missing: $TEMPLATE_THEME (run install.sh)"
sed -e "s|^\(\s*item_color\s*=\s*\).*|\1\"${C[on_surface_variant]}\"|" \
    -e "s|^\(\s*selected_item_color\s*=\s*\).*|\1\"${C[on_surface]}\"|" \
    "$TEMPLATE_THEME" > "$STAGE/theme.txt"
[ -f "$SHARE_DIR/template/font.pf2" ] && cp -f "$SHARE_DIR/template/font.pf2" "$STAGE/"
log "theme.txt patched (mode=${C[mode]}, primary=${C[primary]})"

# --------------------------------------------------------------------------
# 6. Deploy + regenerate grub.cfg (passwordless via /etc/sudoers.d/dux-grub)
# --------------------------------------------------------------------------
sudo -n "$DEPLOY_HELPER" || die "deploy failed — is /etc/sudoers.d/dux-grub installed?"
if [ "${DUX_GRUB_MKCONFIG:-1}" = 1 ]; then
    sudo -n /usr/sbin/grub2-mkconfig -o /boot/grub2/grub.cfg >/dev/null 2>&1 || die "grub2-mkconfig failed"
    log "grub.cfg regenerated"
fi
log "sync complete"
