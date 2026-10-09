#!/bin/bash
# Generic command stub for testing fullupdate.sh without touching the system.
# Logs every call to $STUB_LOG. Behaviour per exact command line comes from
# files in $STUB_CFG named <key>.out / .err / .rc, optionally suffixed with
# the call number (<key>.rc.2 applies to the 2nd identical call).
# <key> = command name + args joined by "_", with path-like args reduced to basename.
name=$(basename "$0")
echo "$name $*" >> "$STUB_LOG"

case "$name" in
    sudo)
        case "$1" in
            -k | -v) exit 0 ;;
        esac
        exec "$@" # run the (stubbed) command
        ;;
    caffeinate) exit 0 ;;
esac

key="$name"
for a in "$@"; do
    case "$a" in */*) a=$(basename "$a") ;; esac
    key="${key}_$a"
done
count_file="$STUB_CFG/$key.count"
n=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$count_file"

for f in "$STUB_CFG/$key.out.$n" "$STUB_CFG/$key.out"; do
    if [ -f "$f" ]; then cat "$f"; break; fi
done
for f in "$STUB_CFG/$key.err.$n" "$STUB_CFG/$key.err"; do
    if [ -f "$f" ]; then cat "$f" >&2; break; fi
done
rc=0
for f in "$STUB_CFG/$key.rc.$n" "$STUB_CFG/$key.rc"; do
    if [ -f "$f" ]; then rc=$(cat "$f"); break; fi
done
exit "$rc"
