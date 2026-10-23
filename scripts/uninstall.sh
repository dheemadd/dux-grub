#!/usr/bin/env bash
# Remove dux-grub. Run: sudo ./scripts/uninstall.sh
set -euo pipefail
[ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] || { echo "Run with sudo from your user account." >&2; exit 1; }
U="$SUDO_USER"; UH=$(getent passwd "$U" | cut -d: -f6)
sudo -u "$U" XDG_RUNTIME_DIR="/run/user/$(id -u "$U")" systemctl --user disable --now dux-grub-sync.path 2>/dev/null || true
rm -f "$UH/.config/systemd/user/dux-grub-sync."{service,path} "$UH/.config/matugen/dms/configs/dux-grub.toml"
rm -rf "$UH/.local/share/dux-grub" "$UH/.config/matugen/dux-grub" /boot/grub2/themes/dux-grub
rm -f /usr/local/libexec/dux-grub-deploy /etc/sudoers.d/dux-grub
sed -i 's|^GRUB_THEME="/boot/grub2/themes/dux-grub.*|#GRUB_THEME=|' /etc/default/grub
grub2-mkconfig -o /boot/grub2/grub.cfg
echo "dux-grub removed."
