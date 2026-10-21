#!/bin/bash
# Stops the demo website and tunnel. With --all, also stops the 4 validators.
# The election contract and its votes stay on-chain; start-demo.sh reuses them
# unless given --new-election.
set -uo pipefail

units=(p4p-demo-web p4p-demo-tunnel)
[ "${1:-}" = "--all" ] && units+=(p4p-demo-besu1 p4p-demo-besu2 p4p-demo-besu3 p4p-demo-besu4)
for u in "${units[@]}"; do
    systemctl --user stop "$u" 2>/dev/null && echo "stopped $u"
    systemctl --user reset-failed "$u" 2>/dev/null
done
rm -f "$(dirname "${BASH_SOURCE[0]}")/.state/public-url"
exit 0
