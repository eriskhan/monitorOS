#!/bin/sh
# Hardware-free package verification; never operates on the host service manager.
set -eu

app_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
daemon=${1:?usage: install.sh DAEMON WORKER}
worker=${2:?usage: install.sh DAEMON WORKER}
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
trap 'exit 1' HUP INT TERM

# Only check-* actions may use this stub with a live root; they never write.
mkdir "$stage/stubs"
cat > "$stage/stubs/systemctl" <<'EOF'
#!/bin/sh
test "${TEST_MANAGER_FAILURE:-0}" = 0 || exit 1
case "$*" in
    *ActiveState*) echo "${TEST_ACTIVE:-inactive}";;
    *UnitFileState*) echo "${TEST_ENABLED:-disabled}";;
    *) exit 1;;
esac
EOF
chmod +x "$stage/stubs/systemctl"
guard() {
    PATH="$stage/stubs:$PATH" DESTDIR=/ sh "$app_dir/package.sh" "$1"
}
guard check-install
guard check-uninstall
for state in active activating deactivating reloading; do
    if TEST_ACTIVE=$state guard check-install; then
        echo "FAIL: allowed live replacement while $state" >&2
        exit 1
    fi
    if TEST_ACTIVE=$state guard check-uninstall; then
        exit 1
    fi
done
if TEST_ENABLED=enabled guard check-uninstall; then exit 1; fi
if TEST_ENABLED=enabled-runtime guard check-uninstall; then exit 1; fi
if TEST_MANAGER_FAILURE=1 guard check-install; then exit 1; fi
ln -s / "$stage/live-root-alias"
if TEST_ACTIVE=active PATH="$stage/stubs:$PATH" DESTDIR="$stage/live-root-alias" \
    sh "$app_dir/package.sh" check-install; then
    echo 'FAIL: alias of live root bypassed service guard' >&2
    exit 1
fi
if DESTDIR=relative-path sh "$app_dir/package.sh" check-install; then exit 1; fi

# Even an unavailable host manager cannot affect staging.
TEST_MANAGER_FAILURE=1 PATH="$stage/stubs:$PATH" \
    make -C "$app_dir" install DESTDIR="$stage" DAEMON="$daemon" WORKER="$worker"

make -C "$app_dir" install DESTDIR="$stage" DAEMON="$daemon" WORKER="$worker"
cmp "$daemon" "$stage/usr/bin/monitorosd"
cmp "$worker" "$stage/usr/lib/monitoros/imac5k-stream"
cmp "$app_dir/systemd/monitorosd.service" \
    "$stage/usr/lib/systemd/system/monitorosd.service"
cmp "$app_dir/systemd/monitoros-appliance.target" \
    "$stage/usr/lib/systemd/system/monitoros-appliance.target"
test "$(stat -c %a "$stage/usr/bin/monitorosd")" = 755
test "$(stat -c %a "$stage/usr/lib/monitoros/imac5k-stream")" = 755
test "$(stat -c %a "$stage/usr/lib/systemd/system/monitorosd.service")" = 644
test "$(stat -c %a "$stage/usr/lib/systemd/system/monitoros-appliance.target")" = 644
"$stage/usr/bin/monitorosd" --self-test
"$stage/usr/lib/monitoros/imac5k-stream" --self-test

# Preflight failures must leave every installed artifact intact.
for input in \
    "DAEMON=$stage/missing" \
    "WORKER=$stage/missing" \
    "UNIT=$stage/missing" \
    "TARGET=$stage/missing"
do
    if make -C "$app_dir" install DESTDIR="$stage" \
        DAEMON="$daemon" WORKER="$worker" "$input"; then
        echo 'FAIL: incomplete update accepted' >&2
        exit 1
    fi
    cmp "$daemon" "$stage/usr/bin/monitorosd"
    cmp "$worker" "$stage/usr/lib/monitoros/imac5k-stream"
    cmp "$app_dir/systemd/monitorosd.service" \
        "$stage/usr/lib/systemd/system/monitorosd.service"
    cmp "$app_dir/systemd/monitoros-appliance.target" \
        "$stage/usr/lib/systemd/system/monitoros-appliance.target"
done

# Exercise replacement, including an already-installed executable, then restore.
printf '#!/bin/sh\nexit 0\n' > "$stage/replacement"
chmod +x "$stage/replacement"
make -C "$app_dir" install DESTDIR="$stage" \
    DAEMON="$stage/replacement" WORKER="$worker"
cmp "$stage/replacement" "$stage/usr/bin/monitorosd"
make -C "$app_dir" install DESTDIR="$stage" DAEMON="$daemon" WORKER="$worker"

if command -v systemd-analyze >/dev/null 2>&1; then
    # Minimal dependency targets for the alternate root. The actual service
    # and ExecStart binary are the installed artifacts, not rewritten fixtures.
    for target in sysinit basic shutdown multi-user graphical; do
        printf '[Unit]\nDescription=Packaging test target\nDefaultDependencies=no\n' \
            > "$stage/usr/lib/systemd/system/$target.target"
    done
    systemd-analyze --root="$stage" --man=no --generators=no verify \
        /usr/lib/systemd/system/monitorosd.service \
        /usr/lib/systemd/system/monitoros-appliance.target
else
    echo 'systemd-analyze unavailable; skipping unit validation'
fi

if command -v systemctl >/dev/null 2>&1; then
    test "$(systemctl --root="$stage" is-enabled monitorosd.service)" = static
fi

grep -Fqx 'Wants=monitorosd.service' \
    "$stage/usr/lib/systemd/system/monitoros-appliance.target"
grep -Fqx 'Conflicts=graphical.target display-manager.service' \
    "$stage/usr/lib/systemd/system/monitoros-appliance.target"
grep -Fqx 'After=multi-user.target display-manager.service' \
    "$stage/usr/lib/systemd/system/monitoros-appliance.target"
grep -Fqx 'PartOf=monitoros-appliance.target' \
    "$stage/usr/lib/systemd/system/monitorosd.service"
grep -Fqx 'After=systemd-udevd.service display-manager.service' \
    "$stage/usr/lib/systemd/system/monitorosd.service"

# Uninstall must preserve unrelated files and tolerate an already-removed install.
touch "$stage/usr/lib/monitoros/unrelated-file"
make -C "$app_dir" uninstall DESTDIR="$stage"
make -C "$app_dir" uninstall DESTDIR="$stage"
test ! -e "$stage/usr/bin/monitorosd"
test ! -e "$stage/usr/lib/monitoros/imac5k-stream"
test ! -e "$stage/usr/lib/systemd/system/monitorosd.service"
test ! -e "$stage/usr/lib/systemd/system/monitoros-appliance.target"
test -f "$stage/usr/lib/monitoros/unrelated-file"
echo 'iMac staged install, appliance target validation, and uninstall passed'
