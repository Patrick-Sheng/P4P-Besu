#!/bin/bash
# Stops a native network started by start-native.sh (systemd --user units
# p4p-besu-n<N>-v*). Falls back to the PID file for networks started by the
# older pre-systemd version of start-native.sh.
# Usage: ./stop-native.sh <nodeCount>
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

N="${1:?Usage: ./stop-native.sh <nodeCount>}"
PID_FILE="generated/n${N}/native-pids.txt"

mapfile -t UNITS < <(systemctl --user list-units --all --plain --no-legend "p4p-besu-n${N}-v*" 2>/dev/null | awk '{print $1}')
if [ "${#UNITS[@]}" -gt 0 ]; then
    systemctl --user stop "${UNITS[@]}" || true
    systemctl --user reset-failed "${UNITS[@]}" 2>/dev/null || true
    echo "Stopped units: ${UNITS[*]}"
elif [ -f "$PID_FILE" ]; then
    while read -r pid; do
        [ -n "$pid" ] && [ "$pid" != "0" ] && kill "$pid" 2>/dev/null && echo "Stopped PID $pid"
    done < "$PID_FILE"
    sleep 2
    while read -r pid; do
        [ -n "$pid" ] && [ "$pid" != "0" ] && kill -9 "$pid" 2>/dev/null || true
    done < "$PID_FILE"
else
    echo "No units or PID file for n=${N} - nothing to stop" >&2
fi

rm -f "$PID_FILE"
echo "n=${N} native network stopped."
