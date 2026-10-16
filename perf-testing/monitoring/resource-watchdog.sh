#!/bin/bash
# Resource/health watchdog for native perf runs. Runs as its own small systemd
# --user unit (so it survives whatever it is watching), samples every
# INTERVAL seconds, writes a CSV time series, and on the first fatal condition
# writes <runDir>/ABORT_REASON, appends a "CRASH_REASON=..." line to the sweep
# log, and stops the load-generator unit so the host never reaches the kernel
# OOM killer (which, on this no-swap box, previously took VS Code down with it).
#
# Fatal conditions (first one wins, reason code in brackets):
#   [HOST_MEMORY_PRESSURE]  MemAvailable < ABORT_MEM_MB for 2 consecutive samples
#   [VALIDATOR_OOM_KILLED]  a p4p-besu unit died with Result=oom-kill (its cgroup MemoryMax hit)
#   [VALIDATOR_JVM_HEAP_OOM] a validator's JVM threw OutOfMemoryError (-Xmx too small; -XX:+ExitOnOutOfMemoryError exits it)
#   [VALIDATOR_DOWN]        a p4p-besu unit is no longer active for any other reason
#   [LOADGEN_OOM_KILLED]    the Caliper/registration unit died with Result=oom-kill
#   [KERNEL_OOM]            kernel OOM killer fired anywhere on the host since the watchdog started
#   [NODE_STUCK]            a validator's height lags the highest by >LAG_BLOCKS for 3 samples
#                           while the chain itself advances (e.g. Besu 24.12.0's SyncState /
#                           BftProcessor deadlock - the node looks alive but stops importing)
#   [CONSENSUS_STALL]       chain height unchanged for STALL_SECS (IBFT makes empty blocks every 2s, so this means no quorum)
#   [RPC_UNRESPONSIVE]      watched RPC failed 5 consecutive samples (after it was first seen up)
#   [NETWORK_NEVER_CAME_UP] no block height readable within STARTUP_SECS of watchdog start
#   [DRIVER_DIED]           the sweep driver unit itself died (watchdog then just exits)
#
# Usage: resource-watchdog.sh <nodeCount> <runDir> <rpcUrl> <sweepLog> <loadUnit> [driverUnit]
set -uo pipefail

N="$1"; RUN_DIR="$2"; RPC_URL="$3"; SWEEP_LOG="$4"; LOAD_UNIT="$5"; DRIVER_UNIT="${6:-}"
LOG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../network/generated/n${N}" && pwd)"
INTERVAL="${P4P_WATCH_INTERVAL:-3}"
ABORT_MEM_MB="${P4P_ABORT_MEM_MB:-600}"
STALL_SECS="${P4P_STALL_SECS:-30}"
STARTUP_SECS="${P4P_STARTUP_SECS:-180}"
RPC_FAIL_SAMPLES="${P4P_RPC_FAIL_SAMPLES:-5}"
LAG_BLOCKS="${P4P_LAG_BLOCKS:-10}"
META="$(dirname "${BASH_SOURCE[0]}")/../network/generated/n${N}/network-meta.json"
mapfile -t ALL_RPC < <(jq -r '.validators[].rpcUrl' "$META" 2>/dev/null)
FAULT_VICTIMS="${P4P_FAULT_VICTIMS:-}"   # space-separated 1-based validator indices crashed on purpose
# 1 = on NODE_STUCK, restart the wedged validator instead of aborting (round 2
# seeding only - unmeasured registration, where Besu 24.12.0's SyncState /
# BftProcessor / MainnetBlockImporter deadlock would otherwise throw away hours
# of work). Each restart is logged to watchdog.log and restarts.csv.
RESTART_STUCK="${P4P_RESTART_STUCK:-}"
# restarts take the restarted validator's RPC down for ~1 min; tolerate that
[ "$RESTART_STUCK" = 1 ] && RPC_FAIL_SAMPLES="${P4P_RPC_FAIL_SAMPLES:-60}"
UNIT_PREFIX="p4p-besu-n${N}-v"
CSV="${RUN_DIR}/resources.csv"
START_ISO="$(date '+%Y-%m-%d %H:%M:%S')"

mkdir -p "$RUN_DIR"
rm -f "${RUN_DIR}/ABORT_REASON"

cg_mem_mb() {  # <unit> -> MiB currently charged to its cgroup, or -1
    local cg
    cg=$(systemctl --user show -p ControlGroup --value "$1" 2>/dev/null)
    if [ -n "$cg" ] && [ -r "/sys/fs/cgroup${cg}/memory.current" ]; then
        echo $(( $(cat "/sys/fs/cgroup${cg}/memory.current") / 1048576 ))
    else
        echo -1
    fi
}

height_of() {  # <url> -> decimal height or -1
    local h
    h=$(curl -s -m 2 -X POST -H 'Content-Type: application/json' \
        --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' "$1" | jq -r '.result // empty' 2>/dev/null)
    [ -n "$h" ] && printf '%d' "$h" || echo -1
}

block_height() {
    curl -s -m 2 -X POST -H 'Content-Type: application/json' \
        --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' "$RPC_URL" \
        | grep -oE '"result":"0x[0-9a-fA-F]+"' | grep -oE '0x[0-9a-fA-F]+' | xargs -I{} printf '%d' {} 2>/dev/null
}

abort() {  # <code> <detail>
    local code="$1" detail="$2"
    # for hangs (as opposed to deaths) capture every live validator's JVM
    # threads first - a stalled IBFT processor thread is otherwise invisible
    if [ "$code" = CONSENSUS_STALL ] || [ "$code" = RPC_UNRESPONSIVE ] || [ "$code" = NODE_STUCK ]; then
        local i pid
        for ((i = 1; i <= N; i++)); do
            pid=$(systemctl --user show -p MainPID --value "${UNIT_PREFIX}${i}" 2>/dev/null)
            [ -n "$pid" ] && [ "$pid" != 0 ] && timeout 20 jcmd "$pid" Thread.print > "${RUN_DIR}/threaddump-v${i}.txt" 2>&1
        done
        detail="${detail}; thread dumps: threaddump-v*.txt"
    fi
    local line="[$(date '+%H:%M:%S')] CRASH_REASON=${code} :: ${detail}"
    echo "${code} :: ${detail}" > "${RUN_DIR}/ABORT_REASON"
    echo "$line" | tee -a "$SWEEP_LOG" >> "${RUN_DIR}/watchdog.log"
    # stop the load first (it's what's driving memory/CPU up); the sweep driver
    # sees ABORT_REASON and tears the network down after collecting what it can
    systemctl --user stop "$LOAD_UNIT" 2>/dev/null || true
    exit 0
}

header="ts,mem_avail_mb,load1,height"
for ((i = 1; i <= N; i++)); do header+=",v${i}_mb"; done
header+=",loadgen_mb"
echo "$header" > "$CSV"

low_mem_count=0; rpc_fail_count=0; last_height=-1; last_height_change=$(date +%s)
started_at=$(date +%s); seen_up=0
declare -A PEAK
declare -A LAGC
echo "[$(date '+%H:%M:%S')] watchdog started (n=${N}, abort if MemAvailable<${ABORT_MEM_MB}MB, stall>${STALL_SECS}s)" >> "${RUN_DIR}/watchdog.log"

while true; do
    now=$(date +%s)
    avail=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
    load1=$(cut -d' ' -f1 /proc/loadavg)
    height=$(block_height); height="${height:--1}"

    row="$(date '+%H:%M:%S'),${avail},${load1},${height}"
    for ((i = 1; i <= N; i++)); do
        m=$(cg_mem_mb "${UNIT_PREFIX}${i}")
        row+=",${m}"
        [ "$m" -gt "${PEAK[v$i]:-0}" ] && PEAK[v$i]=$m
    done
    lm=$(cg_mem_mb "$LOAD_UNIT"); row+=",${lm}"
    echo "$row" >> "$CSV"
    printf 'peak_mb' > "${RUN_DIR}/peak-mem.txt"
    for k in "${!PEAK[@]}"; do printf ' %s=%s' "$k" "${PEAK[$k]}" >> "${RUN_DIR}/peak-mem.txt"; done

    # --- validator liveness ---
    for ((i = 1; i <= N; i++)); do
        u="${UNIT_PREFIX}${i}"
        state=$(systemctl --user show -p ActiveState --value "$u" 2>/dev/null)
        # Area 2 kills these on purpose (SIGKILL -> Result=signal); only an
        # OOM on them is a real, unplanned failure
        if [[ " ${FAULT_VICTIMS} " == *" ${i} "* ]]; then
            if [ "$(systemctl --user show -p Result --value "$u" 2>/dev/null)" = "oom-kill" ]; then
                abort VALIDATOR_OOM_KILLED "fault-victim validator${i} (${u}) was OOM-killed (cgroup MemoryMax), not by the fault script"
            fi
            continue
        fi
        if [ "$state" != "active" ]; then
            result=$(systemctl --user show -p Result --value "$u" 2>/dev/null)
            memmax=$(systemctl --user show -p MemoryMax --value "$u" 2>/dev/null)
            if [ "$result" = "oom-kill" ]; then
                abort VALIDATOR_OOM_KILLED "validator${i} (${u}) exceeded its cgroup MemoryMax=$((memmax / 1048576))MB and was OOM-killed; last sample MemAvailable=${avail}MB"
            fi
            if grep -q 'OutOfMemoryError' "${LOG_DIR}/validator${i}.log" 2>/dev/null; then
                abort VALIDATOR_JVM_HEAP_OOM "validator${i} (${u}) JVM OutOfMemoryError: $(grep -m1 'OutOfMemoryError' "${LOG_DIR}/validator${i}.log" | cut -c1-200)"
            fi
            abort VALIDATOR_DOWN "validator${i} (${u}) state=${state:-gone} result=${result:-unknown} - see ${LOG_DIR}/validator${i}.log"
        fi
    done

    # --- seeding only: rolling graceful restart of a validator whose process
    # memory (cgroup anon) passes RESTART_ANON_MB, one at a time and only while
    # all others are up (3 of 4 keep quorum). Off-heap memory (RocksDB index/
    # filter data) grows with DB size and is not bounded by -Xmx; a restart
    # releases it. Restarts are logged to restarts.csv.
    if [ "$RESTART_STUCK" = 1 ] && [ $((now - ${last_mem_restart:-0})) -ge 300 ]; then
        down=0
        for ((i = 1; i <= N; i++)); do [ "$(systemctl --user show -p ActiveState --value "${UNIT_PREFIX}${i}")" = active ] || down=1; done
        if [ "$down" -eq 0 ]; then
            for ((i = 1; i <= N; i++)); do
                cg=$(systemctl --user show -p ControlGroup --value "${UNIT_PREFIX}${i}" 2>/dev/null)
                anon=$(awk '/^anon / {print int($2 / 1048576)}' "/sys/fs/cgroup${cg}/memory.stat" 2>/dev/null)
                if [ "${anon:-0}" -gt "${P4P_RESTART_ANON_MB:-3000}" ]; then
                    echo "[$(date '+%H:%M:%S')] MEMORY validator${i} anon ${anon}MB > ${P4P_RESTART_ANON_MB:-3000}MB - graceful restart (P4P_RESTART_STUCK=1)" | tee -a "$SWEEP_LOG" >> "${RUN_DIR}/watchdog.log"
                    echo "$(date '+%F %T'),validator${i},memory,${anon}MB" >> "${RUN_DIR}/restarts.csv"
                    bash "$(dirname "${BASH_SOURCE[0]}")/../network/node-ctl.sh" "$N" "$i" stop >/dev/null 2>&1
                    sleep 3
                    bash "$(dirname "${BASH_SOURCE[0]}")/../network/node-ctl.sh" "$N" "$i" start >/dev/null 2>&1
                    LAGC[$i]=-40
                    last_mem_restart=$now
                    break
                fi
            done
        fi
    fi

    # --- sweep driver gone (killed/crashed without stopping us) ---
    if [ -n "$DRIVER_UNIT" ] && [ "$(systemctl --user show -p ActiveState --value "$DRIVER_UNIT" 2>/dev/null)" != "active" ]; then
        abort DRIVER_DIED "${DRIVER_UNIT} is no longer active (result=$(systemctl --user show -p Result --value "$DRIVER_UNIT" 2>/dev/null))"
    fi

    # --- load generator OOM (stopping normally between steps is fine) ---
    if [ "$(systemctl --user show -p Result --value "$LOAD_UNIT" 2>/dev/null)" = "oom-kill" ]; then
        abort LOADGEN_OOM_KILLED "${LOAD_UNIT} (Caliper/registration) exceeded its cgroup MemoryMax and was OOM-killed"
    fi

    # --- kernel-level OOM anywhere on host ---
    if journalctl -k --since "$START_ISO" --no-pager -q 2>/dev/null | grep -q 'Out of memory: Killed process'; then
        abort KERNEL_OOM "$(journalctl -k --since "$START_ISO" --no-pager -q | grep 'Out of memory: Killed process' | tail -1)"
    fi

    # --- host memory pressure ---
    if [ "$avail" -lt "$ABORT_MEM_MB" ]; then
        low_mem_count=$((low_mem_count + 1))
        if [ "$low_mem_count" -ge 2 ]; then
            top=$(ps -eo rss,comm --sort=-rss | awk 'NR>1 && NR<=6 {printf "%s:%dMB ", $2, $1/1024}')
            abort HOST_MEMORY_PRESSURE "MemAvailable=${avail}MB < ${ABORT_MEM_MB}MB threshold for 2 samples; top RSS: ${top}"
        fi
    else
        low_mem_count=0
    fi

    # --- per-validator lag (a hung node can stay "active" while the chain moves on) ---
    if [ "$height" -gt 0 ] && [ "${#ALL_RPC[@]}" -eq "$N" ]; then
        lag_report=""; max_h=$height
        declare -A H
        for ((i = 1; i <= N; i++)); do
            [[ " ${FAULT_VICTIMS} " == *" ${i} "* ]] && continue
            H[$i]=$(height_of "${ALL_RPC[$((i - 1))]}")
            [ "${H[$i]}" -gt "$max_h" ] && max_h=${H[$i]}
        done
        for ((i = 1; i <= N; i++)); do
            [ -z "${H[$i]:-}" ] && continue
            if [ "${H[$i]}" -ge 0 ] && [ $((max_h - H[$i])) -gt "$LAG_BLOCKS" ]; then
                LAGC[$i]=$(( ${LAGC[$i]:-0} + 1 ))
                [ "${LAGC[$i]}" -ge 3 ] && lag_report+="validator${i} at ${H[$i]} vs ${max_h}; "
            elif [ "${LAGC[$i]:-0}" -lt 0 ]; then
                # post-restart grace (negative count) keeps running down while the
                # node boots (RPC down) or is still behind
                LAGC[$i]=$(( LAGC[$i] + 1 ))
            else
                LAGC[$i]=0
            fi
        done
        if [ -n "$lag_report" ] && [ "$RESTART_STUCK" = 1 ]; then
            for ((i = 1; i <= N; i++)); do
                [ "${LAGC[$i]:-0}" -ge 3 ] || continue
                pid=$(systemctl --user show -p MainPID --value "${UNIT_PREFIX}${i}" 2>/dev/null)
                [ -n "$pid" ] && [ "$pid" != 0 ] && timeout 20 jcmd "$pid" Thread.print > "${RUN_DIR}/threaddump-stuck-v${i}-$(date +%H%M%S).txt" 2>&1
                echo "[$(date '+%H:%M:%S')] NODE_STUCK validator${i} (${lag_report}) - restarting it (P4P_RESTART_STUCK=1)" | tee -a "$SWEEP_LOG" >> "${RUN_DIR}/watchdog.log"
                echo "$(date '+%F %T'),validator${i},${H[$i]:-?},${max_h}" >> "${RUN_DIR}/restarts.csv"
                bash "$(dirname "${BASH_SOURCE[0]}")/../network/node-ctl.sh" "$N" "$i" crash >/dev/null 2>&1
                sleep 3
                bash "$(dirname "${BASH_SOURCE[0]}")/../network/node-ctl.sh" "$N" "$i" start >/dev/null 2>&1
                LAGC[$i]=-20   # grace period while it restarts and catches up
            done
            lag_report=""
        fi
        unset H
        [ -n "$lag_report" ] && abort NODE_STUCK "${lag_report}chain still advancing - node alive but not importing blocks"
    fi

    # --- RPC + consensus progress ---
    if [ "$height" -le 0 ] && [ "$seen_up" -eq 0 ]; then
        # JVMs still booting - RPC down is expected, just bound how long
        if [ $((now - started_at)) -ge "$STARTUP_SECS" ]; then
            abort NETWORK_NEVER_CAME_UP "${RPC_URL} never answered eth_blockNumber within ${STARTUP_SECS}s of start"
        fi
    elif [ "$height" -lt 0 ]; then
        rpc_fail_count=$((rpc_fail_count + 1))
        if [ "$rpc_fail_count" -ge "$RPC_FAIL_SAMPLES" ]; then
            abort RPC_UNRESPONSIVE "${RPC_URL} failed eth_blockNumber for ${rpc_fail_count} consecutive samples (node GC-thrashing or wedged)"
        fi
    else
        rpc_fail_count=0; seen_up=1
        if [ "$height" -ne "$last_height" ]; then
            last_height=$height; last_height_change=$now
        elif [ $((now - last_height_change)) -ge "$STALL_SECS" ]; then
            abort CONSENSUS_STALL "block height stuck at ${height} for $((now - last_height_change))s (blockperiod=2s) - IBFT lost liveness"
        fi
    fi

    sleep "$INTERVAL"
done
