#!/bin/sh
# Copy/remove only monitorOS artifacts. Never stop, enable, or start services.
set -eu

action=${1:?usage: package.sh install|uninstall|check-install|check-uninstall}
case "$action" in install|uninstall|check-install|check-uninstall) ;; *) exit 2;; esac
case "${DESTDIR:-}" in ''|/*) ;; *) echo 'DESTDIR must be empty or absolute' >&2; exit 1;; esac
root=$(realpath -m -- "${DESTDIR:-/}")

# A staging root never talks to the host manager. Canonicalize first so '/' and
# aliases of '/' cannot accidentally bypass the live-install checks.
if [ "$root" = / ]; then
    state=$(systemctl show monitorosd.service --property=ActiveState --value)
    case "$state" in
        inactive|failed) ;;
        *) echo "Refusing $action: monitorosd is $state; run sudo systemctl stop monitorosd.service first" >&2; exit 1;;
    esac
    case "$action" in
        *uninstall)
            enabled=$(systemctl show monitorosd.service --property=UnitFileState --value)
            case "$enabled" in
                enabled|enabled-runtime)
                    echo 'Disable monitorosd first: sudo systemctl disable --now monitorosd.service' >&2
                    exit 1;;
            esac;;
    esac
fi
case "$action" in check-*) exit 0;; esac

if [ "$action" = uninstall ]; then
    rm -f -- "$root/usr/bin/monitorosd" "$root/usr/lib/monitoros/imac5k-stream" \
        "$root/usr/lib/systemd/system/monitorosd.service" \
        "$root/usr/lib/systemd/system/monitoros-appliance.target"
    exit 0
fi

daemon=${DAEMON:?DAEMON executable required}
worker=${WORKER:?WORKER executable required}
unit=${UNIT:-systemd/monitorosd.service}
target=${TARGET:-systemd/monitoros-appliance.target}
# Validate the complete input set before replacing any installed file.
for binary in "$daemon" "$worker"; do
    if [ ! -f "$binary" ] || [ ! -x "$binary" ]; then
        echo "Missing executable $binary; run make build first" >&2
        exit 1
    fi
done
test -f "$unit" && test -r "$unit" || { echo "Missing service unit $unit" >&2; exit 1; }
test -f "$target" && test -r "$target" || { echo "Missing appliance target $target" >&2; exit 1; }

temporary=
trap 'test -z "$temporary" || rm -f -- "$temporary"' EXIT
trap 'exit 1' HUP INT TERM
copy_file() {
    source=$1 destination=$2 mode=$3
    mkdir -p -- "$(dirname -- "$destination")"
    temporary=$(mktemp "$destination.XXXXXX")
    install -m "$mode" -- "$source" "$temporary"
    mv -f -- "$temporary" "$destination"
    temporary=
}
# Each file is replaced by rename; the four-file update is not a transaction.
# Keep the service stopped until installation and daemon-reload both succeed.
copy_file "$daemon" "$root/usr/bin/monitorosd" 0755
copy_file "$worker" "$root/usr/lib/monitoros/imac5k-stream" 0755
copy_file "$unit" "$root/usr/lib/systemd/system/monitorosd.service" 0644
copy_file "$target" "$root/usr/lib/systemd/system/monitoros-appliance.target" 0644
