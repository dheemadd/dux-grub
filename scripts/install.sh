#!/usr/bin/env bash
# Install dux-grub on Fedora for the invoking user. Run: sudo ./scripts/install.sh
set -euo pipefail
[ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] || { echo "Run with sudo from your user account." >&2; exit 1; }
U="$SUDO_USER"; UH=$(getent passwd "$U" | cut -d: -f6)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHARE="$UH/.local/share/dux-grub"
as_user() { sudo -u "$U" XDG_RUNTIME_DIR="/run/user/$(id -u "$U")" "$@"; }

echo "1. Staging files in $SHARE"
as_user mkdir -p "$SHARE"/{scripts,template,matugen,src,theme} "$UH/.config/matugen/dms/configs" "$UH/.config/systemd/user"
as_user cp -r "$ROOT/src/icons" "$SHARE/src/"
as_user cp "$ROOT/theme/theme.txt" "$ROOT/theme/font.pf2" "$SHARE/template/"
as_user cp "$ROOT/scripts/dux-grub-sync.sh" "$SHARE/scripts/"; chmod +x "$SHARE/scripts/dux-grub-sync.sh"
as_user cp "$ROOT/matugen/dux-grub-colors.conf" "$SHARE/matugen/"
sed -e "s|@SHARE_DIR@|$SHARE|" -e "s|@HOME@|$UH|" "$ROOT/matugen/dux-grub.toml" | as_user tee "$UH/.config/matugen/dms/configs/dux-grub.toml" >/dev/null

echo "2. Root deploy helper + sudoers drop-in"
install -D -m 0755 -o root -g root "$ROOT/scripts/dux-grub-deploy" /usr/local/libexec/dux-grub-deploy
sed "s/%USERNAME%/$U/g" "$ROOT/etc/sudoers.d/dux-grub" > /tmp/dux-grub.sudoers
visudo -cf /tmp/dux-grub.sudoers && install -m 0440 -o root -g root /tmp/dux-grub.sudoers /etc/sudoers.d/dux-grub
rm -f /tmp/dux-grub.sudoers

echo "3. /etc/default/grub (theme + graphical terminal)"
set_kv() { grep -q "^$1=" /etc/default/grub && sed -i "s|^$1=.*|$1=$2|" /etc/default/grub || echo "$1=$2" >> /etc/default/grub; }
set_kv GRUB_THEME '"/boot/grub2/themes/dux-grub/theme.txt"'
set_kv GRUB_TERMINAL_OUTPUT '"gfxterm"'
set_kv GRUB_GFXMODE '"1920x1080,auto"'

echo "4. systemd user units"
as_user cp "$ROOT/scripts/dux-grub-sync.service" "$ROOT/scripts/dux-grub-sync.path" "$UH/.config/systemd/user/"
as_user systemctl --user daemon-reload && as_user systemctl --user enable --now dux-grub-sync.path || \
  echo "   (run 'systemctl --user enable --now dux-grub-sync.path' after login)"

echo "5. Initial sync"
as_user "$SHARE/scripts/dux-grub-sync.sh"
echo "Done. Change your wallpaper in Dux Shell and GRUB will follow."
