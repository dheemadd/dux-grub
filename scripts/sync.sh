#!/usr/bin/env bash
# Compatibility wrapper: the Caelestia hook was replaced by dux-grub-sync.sh.
exec "$(dirname "$(readlink -f "$0")")/dux-grub-sync.sh" "$@"
