#!/bin/bash
# Round 2 (election-scale plan) phase driver for the 4-validator chain that
# carries Areas 4, 3 and 2. One phase per invocation; launch through
# scripts/run-r2.sh <phase> (detached systemd unit), never an editor terminal.
#
# Phases (plan section in brackets), in run order:
#   smoke      [6.1, 6.2] fresh chain, monitoring, collector, run-notes; 10k
#              registrations + 10k votes at 50/s; tallies; disk projection to
#              5M (fails if it doesn't fit with a 15 GB margin); wipe
#   seed       [6.1, 6.3] fresh chain + deploy; register 5,500,000 voters
#              (resumable); clean stop; snapshot "seeded"
#   calibrate  [6.4] seeded state; reserve voters at 50..250 votes/s, 5 min
#              each; max sustainable rate -> soak rate; restore "seeded"
#   soak       [7, 8] 20 rounds x 250,000 votes at the soak rate; 27 attack
#              replays alongside the soak near 1M, 3M and 5M votes
#              (P4P_SOAK_FROM_ROUND resumes a stopped soak)
#   double     [8] mass double-vote check, 1,000 random soak voters
#   area2      [9] crash f=1 for 10 min under load; quorum loss for 5 min
#   verify     [10] pool empty, heads agree, tallies == expected, archive
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."   # -> perf-testing/
PERF_DIR="$(pwd)"
PHASE="${1:?Usage: r2-run.sh smoke|seed|calibrate|soak|double|area2|verify}"

RESULTS="${PERF_DIR}/reports/r2-soak"
RUN_DIR="${RESULTS}/${PHASE}-$(date '+%Y%m%d-%H%M%S')"
mkdir -p "$RUN_DIR"
LOG="${RUN_DIR}/run.log"
INDEX="${RESULTS}/r2-index.log"
NOTES="${RESULTS}/run-notes.md"
source "${PERF_DIR}/scripts/r2-lib.sh"
source ~/.nvm/nvm.sh >/dev/null
nvm use 22 >/dev/null

# Scaled to 2023 turnout (user decision 2026-10-15, to shorten the run): 2.8M
# soak votes in 14 x 200k rounds, attack checkpoints at 1M / 2M / 2.8M; 500k
# reserve voters (calibration <= 285k, Area 2 at 150/s ~405k)
SOAK_VOTERS=2800000
RESERVE_FROM=2800000
TOTAL_VOTERS=3300000
ROUND_VOTES=200000
ROUNDS="${P4P_SOAK_ROUNDS:-14}"   # P4P_SOAK_ROUNDS ends the soak early (2026-10-16: stop at 1M = round 5)
ATTACK_ROUNDS=" 5 10 14 "

ABORTED=""
CURRENT_STEP="init"
RESULT_NOTE=""

finish() {
    local rc=$?
    set +e
    systemctl --user stop "$ATTACK_UNIT" "$LOAD_UNIT" "p4p-sampler-n${N}" 2>/dev/null
    [ -z "$ABORTED" ] && [ -f "${RUN_DIR}/ABORT_REASON" ] && ABORTED="$(cat "${RUN_DIR}/ABORT_REASON")"
    if [ -z "$ABORTED" ] && [ "$rc" -ne 0 ]; then ABORTED="DRIVER_ERROR :: step '${CURRENT_STEP}' exited ${rc}"; fi
    if [ -n "$ABORTED" ]; then
        log "RESULT: ABORTED during '${CURRENT_STEP}' - ${ABORTED}"
        echo "$(date '+%F %T') ${PHASE} ABORTED step='${CURRENT_STEP}' reason='${ABORTED}' dir=${RUN_DIR}" >> "$INDEX"
        # leave the chain as it is for inspection; watchdog off so it can't fire again
        watchdog_stop
    else
        log "RESULT: COMPLETED ${RESULT_NOTE}"
        echo "$(date '+%F %T') ${PHASE} COMPLETED ${RESULT_NOTE} dir=${RUN_DIR}" >> "$INDEX"
    fi
}
trap finish EXIT

fail() { ABORTED="$1"; log "CRASH_REASON=${ABORTED}"; exit 3; }
need_net() { [ -f "$R2_NET" ] || fail "NO_CONTRACT_CONFIG :: ${R2_NET} missing - run seed (or restore a snapshot) first"; }

monitoring_up() {
    bash "${PERF_DIR}/scripts/r2-monitoring.sh" start "$N" >> "$LOG" 2>&1
    sleep 40
    local up
    up=$(curl -s 'http://127.0.0.1:9090/api/v1/targets' | jq '[.data.activeTargets[] | select(.health == "up")] | length')
    log "Prometheus targets UP: ${up}/$((N + 1)); Grafana health: $(curl -s http://127.0.0.1:3000/api/health | jq -c . 2>/dev/null)"
    [ "${up:-0}" -eq $((N + 1)) ] || log "WARNING: not every Prometheus target is UP (see scripts/r2-monitoring.sh status)"
}

write_notes() {  # appends this phase's environment to run-notes.md
    {
        echo ""
        echo "## ${PHASE} - started $(date '+%F %T %Z')"
        echo ""
        echo "- Git commit: $(git -C "$PERF_DIR" rev-parse --short HEAD) ($(git -C "$PERF_DIR" status --porcelain | wc -l) uncommitted changes)"
        echo "- Besu: $(besu --version 2>/dev/null | head -1)"
        echo "- VM: $(nproc) vCPU ($(lscpu | awk -F: '/Model name/ {gsub(/^ +/, "", $2); print $2}')), MemTotal $(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo) MiB, swap $(awk '/SwapTotal/ {print int($2/1024)}' /proc/meminfo) MiB, disk free $(disk_free_gb) GB"
        echo "- Genesis: chainId $(jq .config.chainId "${GEN_DIR}/config/genesis.json"), ibft2 $(jq -c .config.ibft2 "${GEN_DIR}/config/genesis.json"), gasLimit $(jq -r .gasLimit "${GEN_DIR}/config/genesis.json")"
        [ -f "$R2_NET" ] && echo "- Contract: $(jq -r '.voting.contracts.VotingSystem.address' "$R2_NET")"
        echo "- Validator launch (validator1):"
        echo '  ```'
        echo "  env: $(systemctl --user show -p Environment --value "p4p-besu-n${N}-v1" | sed -E 's/PATH=[^ ]*//')"
        echo "  $(systemctl --user show -p ExecStart --value "p4p-besu-n${N}-v1" | sed -E 's/.*argv\[\]=([^;]*);.*/\1/')"
        echo '  ```'
    } >> "$NOTES"
}

# ------------------------------------------------------------------ smoke ---
phase_smoke() {
    CURRENT_STEP="preflight"
    chain_up fresh || fail "CHAIN_START_FAILED"
    watchdog_start 60
    deploy || fail "DEPLOY_FAILED"
    monitoring_up
    collector_start "${RUN_DIR}/collector.csv" 60
    write_notes

    CURRENT_STEP="smoke: register 10k"
    local d0 d1 d2 i
    sleep 10
    d0=(); for i in 1 2 3 4; do d0+=("$(db_mb "$i")"); done
    local h0; h0=$(height_of 1)
    gen register --from=0 --to=10000 --window=500 --state="${RUN_DIR}/register.progress" >> "$LOG" 2>&1 || { check_abort; fail "REGISTER_FAILED"; }
    sleep 30
    d1=(); for i in 1 2 3 4; do d1+=("$(db_mb "$i")"); done
    local h1; h1=$(height_of 1)

    CURRENT_STEP="smoke: 10k votes at 50/s"
    gen vote --from=0 --count=10000 --rate=50 --out="${RUN_DIR}/smoke-votes.csv" --label=smoke >> "$LOG" 2>&1 || { check_abort; fail "VOTE_FAILED"; }
    sleep 30
    d2=(); for i in 1 2 3 4; do d2+=("$(db_mb "$i")"); done
    local h2; h2=$(height_of 1)
    log "Smoke votes: $(jq -c '{ok, reverted, dropped, sendErrors, successPct, sendRate, throughput, latencyMs}' "${RUN_DIR}/smoke-votes.csv.summary.json")"

    CURRENT_STEP="smoke: checks"
    gen tally --expect-to=10000 > "${RUN_DIR}/tally.json" 2>>"$LOG"
    local match; match=$(jq -r '.match and .agree' "${RUN_DIR}/tally.json")
    log "Tallies $(jq -c '.nodes[0].tallies' "${RUN_DIR}/tally.json") expected $(jq -c .expected "${RUN_DIR}/tally.json"), all nodes agree + match: ${match}"
    log "Collector rows: $(( $(wc -l < "${RUN_DIR}/collector.csv") - 1 )); Prometheus besu tx metric samples: $(curl -s 'http://127.0.0.1:9090/api/v1/query?query=count(besu_transaction_pool_transactions)' | jq -r '.data.result[0].value[1] // "none"')"
    [ "$match" = true ] || fail "SMOKE_TALLY_MISMATCH :: see tally.json"

    # disk growth per 10k (average of the 4 validators) -> projection to 5M (plan 6.2 step 3)
    local reg_mb=0 vote_mb=0
    for i in 0 1 2 3; do reg_mb=$((reg_mb + d1[i] - d0[i])); vote_mb=$((vote_mb + d2[i] - d1[i])); done
    local proj
    proj=$(echo "scale=12; reg=${reg_mb}/4/10000; vote=${vote_mb}/4/10000;
        chain=4*(reg*${TOTAL_VOTERS} + vote*(${SOAK_VOTERS}+300000))/1024; snap=4*reg*${TOTAL_VOTERS}/1024;
        print reg*1048576, \" \", vote*1048576, \" \", chain, \" \", snap" | bc -l)
    read -r reg_b vote_b chain_gb snap_gb <<< "$proj"
    local free; free=$(disk_free_gb)
    log "Disk: per validator ${reg_b%.*} B/registration, ${vote_b%.*} B/vote (blocks ${h0}->${h1}->${h2}); projection: chain ${chain_gb} GB (4 validators) + snapshot ${snap_gb} GB = $(echo "$chain_gb + $snap_gb" | bc) GB vs ${free} GB free (need +15 GB margin)"
    echo "reg_bytes=${reg_b},vote_bytes=${vote_b},chain_gb=${chain_gb},snapshot_gb=${snap_gb},free_gb=${free}" > "${RUN_DIR}/disk-projection.txt"
    if [ "$(echo "$chain_gb + $snap_gb + 15 > $free" | bc)" -eq 1 ]; then
        fail "DISK_PROJECTION_DOES_NOT_FIT :: need $(echo "$chain_gb + $snap_gb + 15" | bc) GB, have ${free} GB"
    fi

    CURRENT_STEP="smoke: wipe"
    collector_stop
    chain_down
    RESULT_NOTE="smoke passed; projection chain ${chain_gb} GB + snapshot ${snap_gb} GB fits in ${free} GB"
}

# ------------------------------------------------------------------- seed ---
phase_seed() {
    CURRENT_STEP="preflight"
    local resume=""
    [ -f "${RESULTS}/state/register.progress" ] && [ -f "$R2_NET" ] && resume=1
    if [ -n "$resume" ]; then
        log "Resuming seeding on the existing chain (progress $(cat "${RESULTS}/state/register.progress"))"
        chain_up keep || fail "CHAIN_START_FAILED"
    else
        chain_up fresh || fail "CHAIN_START_FAILED"
    fi
    # seeding is unmeasured: restart a validator wedged by the Besu 24.12.0
    # sync/import deadlock instead of aborting hours of registration
    P4P_RESTART_STUCK=1 P4P_RESTART_ANON_MB=2500 watchdog_start 60
    [ -n "$resume" ] || deploy || fail "DEPLOY_FAILED"
    monitoring_up
    collector_start "${RUN_DIR}/collector.csv" 120
    write_notes

    CURRENT_STEP="seed: register ${TOTAL_VOTERS}"
    local t0 h0 h1; t0=$(date +%s); h0=$(height_of 1)
    log "Registering voters 0..${TOTAL_VOTERS} (window ${P4P_REG_WINDOW:-500})"
    gen register --from=0 --to="$TOTAL_VOTERS" --window="${P4P_REG_WINDOW:-500}" --state="${RESULTS}/state/register.progress" >> "$LOG" 2>&1 \
        || { check_abort; fail "REGISTER_FAILED :: see run.log (resumable: rerun seed)"; }
    h1=$(height_of 1)
    local secs=$(( $(date +%s) - t0 ))
    log "Seeding done: ${secs}s ($(echo "scale=1; ${TOTAL_VOTERS} / ${secs}" | bc) regs/s over this run), blocks ${h0}..${h1}, mean block time $(mean_block_time "$h0" "$h1")s"
    for i in 1 2 3 4; do log "  validator${i} DB $(db_mb "$i") MB"; done
    gen tally > "${RUN_DIR}/tally.json" 2>>"$LOG"
    for idx in 0 2749999 5499999; do gen state --index="$idx" >> "$LOG" 2>&1; done

    CURRENT_STEP="seed: snapshot"
    collector_stop
    chain_down
    sleep 5
    snapshot_save seeded || fail "SNAPSHOT_FAILED"
    rm -f "${RESULTS}/state/register.progress"
    RESULT_NOTE="seeded ${TOTAL_VOTERS} voters in ${secs}s; snapshot saved"
}

# -------------------------------------------------------------- calibrate ---
step_verdict() {  # <summary.json> <fromBlock> <toBlock> <phaseName> -> echoes "verdict|reasons|bt|slope"
    local s="$1" bt slope p95 succ reasons=""
    bt=$(mean_block_time "$2" "$3")
    slope=$(bash "${PERF_DIR}/monitoring/r2-phase-stats.sh" "${RUN_DIR}/samples.csv" "$4" | tr ' ' '\n' | awk -F= '$1 == "pool_slope" {print $2}')
    p95=$(jq -r '.latencyMs.p95 // 999999' "$s"); succ=$(jq -r '.successPct' "$s")
    [ "$(echo "$succ < 99.9" | bc)" -eq 1 ] && reasons+="success_${succ}pct;"
    [ "$p95" -gt 6000 ] && reasons+="p95_${p95}ms;"
    [ "$(echo "${slope:-0} > 1.0" | bc)" -eq 1 ] && reasons+="pool_rising_${slope}tx/s;"
    [ "$(echo "$bt < 2.0 || $bt > 2.2" | bc)" -eq 1 ] && reasons+="block_time_${bt}s;"
    echo "$([ -z "$reasons" ] && echo SUSTAINABLE || echo UNSUSTAINABLE)|${reasons}|${bt}|${slope}"
}
sampler_start() {
    systemctl --user stop "p4p-sampler-n${N}" 2>/dev/null; systemctl --user reset-failed "p4p-sampler-n${N}" 2>/dev/null
    systemd-run --user --quiet --unit="p4p-sampler-n${N}" --slice=p4p-mon.slice -p MemoryMax=64M --setenv=PATH="$PATH" \
        --setenv=P4P_SAMPLE_INTERVAL="${1:-5}" bash "${PERF_DIR}/monitoring/r2-sampler.sh" "$N" "$RUN_DIR" "$(rpc_url 1)"
}

phase_calibrate() {
    CURRENT_STEP="restart seeded"
    # seed leaves the chain stopped cleanly on exactly the snapshot; only copy
    # it back if something ran on the data since
    if [ "$(cat "${R2_STATE}/data-state" 2>/dev/null)" != seeded ]; then
        snapshot_restore seeded || fail "RESTORE_FAILED"
    fi
    chain_up keep || fail "CHAIN_START_FAILED"
    need_net
    watchdog_start 60
    monitoring_up
    collector_start "${RUN_DIR}/collector.csv" 60
    sampler_start 5
    write_notes
    echo "rate,sent,ok,reverted,dropped,send_errors,success_pct,send_rate,throughput,p50_ms,p95_ms,p99_ms,mean_block_s,pool_slope,verdict,reasons" > "${RUN_DIR}/calibration.csv"
    local cursor=$RESERVE_FROM max=0 rate
    for rate in ${P4P_CAL_STEPS:-50 75 100 125 150 200 250}; do
        CURRENT_STEP="calibrate ${rate}/s"
        echo "cal-${rate}" > "${RUN_DIR}/phase"
        local count=$(( rate * ${P4P_CAL_SECS:-300} )) b0 b1
        b0=$(height_of 1)
        gen vote --from="$cursor" --count="$count" --rate="$rate" --out="${RUN_DIR}/cal-${rate}.csv" --label="cal-${rate}" --drain-secs=120 >> "$LOG" 2>&1 || { check_abort; fail "VOTE_FAILED"; }
        b1=$(height_of 1)
        echo "drain-${rate}" > "${RUN_DIR}/phase"
        cursor=$((cursor + count))
        local v; v=$(step_verdict "${RUN_DIR}/cal-${rate}.csv.summary.json" "$b0" "$b1" "cal-${rate}")
        IFS='|' read -r verdict reasons bt slope <<< "$v"
        jq -r --arg bt "$bt" --arg sl "$slope" --arg v "$verdict" --arg r "$reasons" \
            '[.targetRate,.sent,.ok,.reverted,.dropped,.sendErrors,.successPct,.sendRate,.throughput,.latencyMs.p50,.latencyMs.p95,.latencyMs.p99,$bt,$sl,$v,$r] | @csv' \
            "${RUN_DIR}/cal-${rate}.csv.summary.json" >> "${RUN_DIR}/calibration.csv"
        log "Calibration ${rate} votes/s: ${verdict} ${reasons} | $(jq -c '{successPct, sendRate, throughput, p95: .latencyMs.p95}' "${RUN_DIR}/cal-${rate}.csv.summary.json") block ${bt}s pool slope ${slope}"
        [ "$verdict" = SUSTAINABLE ] && max=$rate || break
        # let any backlog clear before the next step
        for _ in $(seq 1 60); do [ "$(pool_of 1)" -le 0 ] && break; sleep 2; done
    done
    local soak
    # 150 when sustainable (user decision 2026-10-15, shortens the soak);
    # otherwise the plan's rule: 100 with >= 25 % headroom, else 80 % of max
    if [ "$max" -ge 150 ]; then soak=150; elif [ "$max" -ge 125 ]; then soak=100; else soak=$(( max * 80 / 100 )); fi
    mkdir -p "${RESULTS}/state"; echo "$soak" > "${RESULTS}/state/soak-rate"
    log "Max sustainable ${max} votes/s -> soak rate ${soak} votes/s (rule: 150 if sustainable, 100 if >= 125, else 80% of max)"

    CURRENT_STEP="restore seeded"
    collector_stop
    systemctl --user stop "p4p-sampler-n${N}" 2>/dev/null
    chain_down
    sleep 5
    snapshot_restore seeded || fail "RESTORE_FAILED"
    RESULT_NOTE="max sustainable ${max}/s, soak rate ${soak}/s; seeded snapshot restored"
    [ "$soak" -ge 1 ] || fail "NO_SUSTAINABLE_RATE :: even ${P4P_CAL_STEPS%% *}/s failed on the seeded state"
}

# ------------------------------------------------------------ attacks (3) ---
# 27 replays (3 attacks x 9) at one checkpoint, run alongside soak traffic in
# their own unit. Writes attacks-<label>.csv: attack,rep,result,start_ms,end_ms,detail
run_attacks() {  # <label>
    local label="$1" csv="${RUN_DIR}/attacks-${1}.csv" attack rep t0 t1 rc res detail
    # the attack scripts resolve the contract ABI relative to <config dir>/.. (round 1
    # kept configs in caliper/networks/), so hand them a copy there
    local netcfg="${PERF_DIR}/caliper/networks/besu-n4-r2.json"
    cp "$R2_NET" "$netcfg"
    echo "attack,rep,result,start_ms,end_ms,detail" > "$csv"
    # P4P_ATTACK_RESUME_CSV: attempts already completed in an interrupted checkpoint
    # are copied over (with their logs) and not repeated
    local prev="${P4P_ATTACK_RESUME_CSV:-}"
    for attack in double-vote equivocation replay; do
        for rep in $(seq 1 9); do
            if [ -n "$prev" ] && grep -q "^${attack},${rep},\(PASS\|FAIL\)," "$prev"; then
                # row only: its log stays in the earlier run dir (verify reads every
                # soak-* dir, so a copied log would double-count that attacker's vote)
                grep "^${attack},${rep}," "$prev" >> "$csv"
                continue
            fi
            t0=$(date +%s%3N)
            run_unit "$ATTACK_UNIT" "${PERF_DIR}/fault-injection" node "malicious/${attack}.js" "$netcfg" > "${RUN_DIR}/attack-${label}-${attack}-${rep}.log" 2>&1
            rc=$?; t1=$(date +%s%3N)
            res=$([ "$rc" -eq 0 ] && echo PASS || echo FAIL)
            detail=$(grep -m1 -E 'rejected|never confirmed|replay rejected' "${RUN_DIR}/attack-${label}-${attack}-${rep}.log" | tr ',\n' '; ' | cut -c1-160)
            echo "${attack},${rep},${res},${t0},${t1},\"${detail}\"" >> "$csv"
        done
    done
}

# legit latency p95 (ms) for soak txs sent in [fromMs, toMs) from round CSVs
legit_p95() {  # <fromMs> <toMs>
    cat "${RUN_DIR}"/soak-r*.csv 2>/dev/null | awk -F, -v a="$1" -v b="$2" '$3 >= a && $3 < b && $7 == "ok" {print $5}' | sort -n \
        | awk '{v[NR] = $1} END {if (NR == 0) {print "-"; exit} i = int(NR * 0.95 + 0.999); if (i < 1) i = 1; print v[i]}'
}

# Host episodes (slow blocks / growing pool), recorded instead of aborting
# (user decision 2026-10-16). One row per detection, with the latest in-run CPU probe.
episode() {  # <kind> <detail> <round> <pool>
    local probe; probe=$(awk -F, 'NR > 1 && $11 != "" {p = $11} END {print p}' "${RUN_DIR}/samples.csv" 2>/dev/null)
    [ -f "${RUN_DIR}/episodes.csv" ] || echo "time,round,kind,detail,pool,last_cpu_probe_ms" > "${RUN_DIR}/episodes.csv"
    echo "$(date '+%F %T'),$3,$1,\"$2\",$4,${probe}" >> "${RUN_DIR}/episodes.csv"
    log "EPISODE ${1} (round ${3}): ${2}; pool ${4}; last CPU probe ${probe} ms - recorded, not aborting"
}

# --------------------------------------------------------------- soak (4) ---
phase_soak() {
    local rate; rate=$(cat "${RESULTS}/state/soak-rate" 2>/dev/null) || fail "NO_SOAK_RATE :: run calibrate first"
    rate="${P4P_SOAK_RATE:-$rate}"
    local from_round="${P4P_SOAK_FROM_ROUND:-1}"
    CURRENT_STEP="restart"
    chain_up keep || fail "CHAIN_START_FAILED"
    need_net
    watchdog_start 180   # host episodes stretch blocks; IBFT round timeout alone reaches 64 s
    monitoring_up
    collector_start "${RUN_DIR}/soak-metrics.csv" 120
    sampler_start 15
    write_notes
    echo "- Soak: ${ROUNDS} rounds x ${ROUND_VOTES} votes at ${rate} votes/s from round ${from_round}" >> "$NOTES"
    local CK="${RUN_DIR}/checkpoints.csv"
    echo "round,cumulative_votes,start,end,sent,ok,reverted,dropped,send_errors,success_pct,send_rate,throughput,p50_ms,p95_ms,p99_ms,mean_block_s,pool_end,heap_after_gc_mb,node1_db_gb,disk_free_gb,swap_mb,heads_agree" > "$CK"

    # Warm-up ramp ("round 0", user decision 2026-10-16): freshly started JVMs need
    # ~2x CPU for their first minutes (JIT, cold caches); hitting them with the full
    # soak rate at once caused a backlog spiral on a slowed host. 3 min each at
    # 30/60/90 votes/s from the top of the reserve range (Area 2 stays below 3.2M),
    # written to soak-r00.csv so verification counts these votes.
    if [ "$from_round" -gt 1 ]; then
        # resumed soak: the interrupted round's voters may already have voted
        CURRENT_STEP="resume scan round ${from_round}"
        gen voted-scan --from=$(( (from_round - 1) * ROUND_VOTES )) --to=$(( from_round * ROUND_VOTES )) --out="${RUN_DIR}/skip-r${from_round}.txt" >> "$LOG" 2>&1 \
            || fail "RESUME_SCAN_FAILED"
        log "Resume: $(wc -l < "${RUN_DIR}/skip-r${from_round}.txt") voters of round ${from_round} already Voted - they will be skipped"
    fi
    CURRENT_STEP="warm-up ramp"
    echo "soak-warmup" > "${RUN_DIR}/phase"
    local wc; wc=$(cat "${RESULTS}/state/warmup-cursor" 2>/dev/null || echo 3200000)
    local wrate
    for wrate in ${P4P_WARMUP_STEPS:-30 60 90}; do
        log "Warm-up: ${wrate} votes/s for 3 min (voters ${wc}..$((wc + wrate * 180)))"
        gen vote --from="$wc" --count=$((wrate * 180)) --rate="$wrate" --out="${RUN_DIR}/soak-r00.csv" --label="warmup-${wrate}" --drain-secs=120 >> "$LOG" 2>&1 \
            || { check_abort; fail "GENERATOR_FAILED :: warm-up ${wrate}/s"; }
        wc=$((wc + wrate * 180)); echo "$wc" > "${RESULTS}/state/warmup-cursor"
        log "Warm-up ${wrate}/s: $(jq -c '{ok, dropped, successPct, p95: .latencyMs.p95}' "${RUN_DIR}/soak-r00.csv.summary.json")"
        check_abort
    done
    for _ in $(seq 1 60); do [ "$(pool_of 1)" -le 0 ] && break; sleep 2; done

    local low_success=0 r
    for ((r = from_round; r <= ROUNDS; r++)); do
        CURRENT_STEP="soak round ${r}"
        echo "soak-r${r}" > "${RUN_DIR}/phase"
        local from=$(( (r - 1) * ROUND_VOTES )) out="${RUN_DIR}/soak-r$(printf '%02d' "$r").csv"
        local b0 t0 round_secs; b0=$(height_of 1); t0=$(date +%s); round_secs=$(( ROUND_VOTES / rate ))
        log "Round ${r}/${ROUNDS}: voters ${from}..$((from + ROUND_VOTES)) at ${rate}/s (~$((round_secs / 60)) min)"
        echo "- Round ${r}: start $(date '+%F %T')" >> "$NOTES"
        local skiparg=""
        [ -s "${RUN_DIR}/skip-r${r}.txt" ] && skiparg="--skip-file=${RUN_DIR}/skip-r${r}.txt"
        gen vote --from="$from" --count="$ROUND_VOTES" --rate="$rate" --out="$out" --label="soak-r${r}" --drain-secs=300 $skiparg >> "$LOG" 2>&1 &
        local genpid=$! attack_pid="" attack_label=""
        # watch the round: abort criteria (plan Section 12) + attack checkpoint
        local pool_hist=() last_h=$b0 last_h_t=$t0
        while kill -0 "$genpid" 2>/dev/null; do
            sleep 60
            check_abort
            local now el free sw pool h
            now=$(date +%s); el=$((now - t0)); free=$(disk_free_gb); sw=$(swap_mb); pool=$(pool_of 1); h=$(height_of 1)
            [ "$free" -lt 10 ] && fail "DISK_BELOW_10GB :: ${free} GB free in round ${r}"
            [ "$sw" -gt 2048 ] && fail "SWAP_ABOVE_2GB :: ${sw} MB in round ${r}"
            [ "${pool:-0}" -gt 50000 ] && fail "POOL_NEAR_CAP :: pool ${pool} of ${R2_POOL} - votes would start being evicted (round ${r})"
            # block time > 6 s for 5 min
            if [ $((now - last_h_t)) -ge 300 ]; then
                if [ $(( (now - last_h_t) / (h - last_h + (h == last_h)) )) -gt 6 ]; then
                    # user decision 2026-10-16: slow-block periods caused by the host
                    # halving the VM's CPU are recorded, not aborted on
                    episode "slow_blocks" "$((h - last_h)) blocks in $((now - last_h_t))s" "$r" "$pool"
                fi
                last_h=$h; last_h_t=$now
            fi
            # pool growing continuously for > 10 min (11 rising one-minute samples)
            pool_hist+=("$pool"); [ "${#pool_hist[@]}" -gt 11 ] && pool_hist=("${pool_hist[@]:1}")
            if [ "${#pool_hist[@]}" -eq 11 ] && [ "$el" -lt "$round_secs" ]; then
                local rising=1 k
                for ((k = 1; k < 11; k++)); do [ "${pool_hist[k]}" -le "${pool_hist[k-1]}" ] && rising=0; done
                [ "$rising" -eq 1 ] && [ "${pool_hist[10]}" -gt $((rate * 10)) ] && \
                    episode "pool_growing_10min" "pool ${pool_hist[0]} -> ${pool_hist[10]}" "$r" "$pool"
            fi
            # Area 3 checkpoint: start the 27 replays ~15 min before the round's sends end
            if [[ "$ATTACK_ROUNDS" == *" ${r} "* ]] && [ -z "$attack_pid" ] && [ "$el" -ge $((round_secs - 900)) ]; then
                attack_label="$(awk -v v=$(( r * ROUND_VOTES )) 'BEGIN {printf "%gM", v / 1000000}')"
                log "Area 3 checkpoint ${attack_label}: replaying 27 attacks alongside soak traffic"
                echo "- Area 3 checkpoint ${attack_label}: attacks start $(date '+%F %T')" >> "$NOTES"
                run_attacks "$attack_label" &
                attack_pid=$!
            fi
        done
        wait "$genpid"; local grc=$?
        [ -n "$attack_pid" ] && { wait "$attack_pid"; summarize_attacks "$attack_label"; }
        check_abort
        [ "$grc" -ne 0 ] && fail "GENERATOR_FAILED :: round ${r} exit ${grc}"

        local b1 s; b1=$(height_of 1); s="${out}.summary.json"
        local bt heads hp agree=true i hh
        bt=$(mean_block_time "$b0" "$b1")
        hp=$(( $(height_of 1) - 2 )); heads=$(hash_at 1 "$hp")
        for i in 2 3 4; do hh=$(hash_at "$i" "$hp"); [ "$hh" != "$heads" ] && agree=false; done
        [ "$agree" = true ] || fail "HASH_MISMATCH :: validators disagree at block ${hp} after round ${r}"
        local last; last=$(tail -1 "${RUN_DIR}/soak-metrics.csv")
        local heap; heap=$(echo "$last" | awk -F, '{print $12}')   # heap1_mb column (ts..peers=7, db1..4, heap1)
        jq -r --arg r "$r" --arg cum "$(( r * ROUND_VOTES ))" --arg bt "$bt" --arg pool "$(pool_of 1)" --arg heap "$heap" \
            --arg db "$(echo "scale=2; $(db_mb 1) / 1024" | bc)" --arg free "$(disk_free_gb)" --arg sw "$(swap_mb)" --arg agree "$agree" \
            '[$r, $cum, (.startMs/1000|todate), (.endMs/1000|todate), .sent, .ok, .reverted, .dropped, .sendErrors, .successPct, .sendRate, .throughput,
              .latencyMs.p50, .latencyMs.p95, .latencyMs.p99, $bt, $pool, $heap, $db, $free, $sw, $agree] | @csv' "$s" >> "$CK"
        log "Round ${r} done: $(jq -c '{ok, dropped, sendErrors, successPct, sendRate, throughput, p95: .latencyMs.p95}' "$s") block ${bt}s heap ${heap}MB disk free $(disk_free_gb)GB"
        echo "- Round ${r}: end $(date '+%F %T') ($(jq -r .ok "$s") ok, p95 $(jq -r .latencyMs.p95 "$s") ms)" >> "$NOTES"
        if [ "$(echo "$(jq -r .successPct "$s") < 99" | bc)" -eq 1 ]; then
            low_success=$((low_success + 1))
            [ "$low_success" -ge 2 ] && fail "SUCCESS_BELOW_99_TWICE :: rounds $((r - 1)) and ${r}"
        else
            low_success=0
        fi
    done
    RESULT_NOTE="soak ${ROUNDS} rounds at ${rate}/s complete"
    collector_stop
    systemctl --user stop "p4p-sampler-n${N}" 2>/dev/null
    # chain stays up for the double-vote check and Area 2
}

summarize_attacks() {  # <label> -> attacks-summary.csv row
    local label="$1" csv="${RUN_DIR}/attacks-${1}.csv" s e pass
    pass=$(grep -c ',PASS,' "$csv"); s=$(awk -F, 'NR == 2 {print $4}' "$csv"); e=$(awk -F, 'END {print $5}' "$csv")
    local before during
    before=$(legit_p95 $((s - 300000)) "$s"); during=$(legit_p95 "$s" "$e")
    [ -f "${RUN_DIR}/attacks-summary.csv" ] || echo "checkpoint,blocked,total,unexpected,legit_p95_5min_before_ms,legit_p95_during_ms,start,end" > "${RUN_DIR}/attacks-summary.csv"
    echo "${label},${pass},27,\"$(awk -F, '$3 == "FAIL" {printf "%s#%s ", $1, $2}' "$csv")\",${before},${during},$(date -d "@$((s / 1000))" '+%T'),$(date -d "@$((e / 1000))" '+%T')" >> "${RUN_DIR}/attacks-summary.csv"
    log "Area 3 checkpoint ${label}: ${pass}/27 attacks blocked; legit p95 ${before} ms (5 min before) -> ${during} ms (during replay)"
}

# ------------------------------------------------- soak-attacks <label> (3) ---
# Reruns an Area 3 checkpoint against the current chain with live traffic: 90/s
# (soak rate) from unused soak voters (state/extra-cursor, default 1,000,000),
# attacks start after 2 min of traffic, traffic stops when they finish.
phase_soak_attacks() {
    need_net
    local label="${P4P_ATTACK_LABEL:-1M}" rate; rate="${P4P_ATTACK_TRAFFIC_RATE:-$(cat "${RESULTS}/state/soak-rate")}"
    # restart: a previous halt (Besu sync/consensus stall) needs fresh validators
    chain_up keep || fail "CHAIN_START_FAILED"
    watchdog_start 180
    sampler_start 15
    write_notes
    local from; from=$(cat "${RESULTS}/state/extra-cursor" 2>/dev/null || echo 1000000)
    local count=$(( rate * 1500 ))
    CURRENT_STEP="checkpoint ${label}: traffic"
    echo "attacks-${label}" > "${RUN_DIR}/phase"
    log "Checkpoint ${label}: live traffic ${rate}/s from voter ${from}; 27 attacks start after 2 min"
    gen vote --from="$from" --count="$count" --rate="$rate" --out="${RUN_DIR}/soak-r90.csv" --label="checkpoint-${label}" --drain-secs=120 >> "$LOG" 2>&1 &
    local gp=$!
    sleep 120
    CURRENT_STEP="checkpoint ${label}: attacks"
    log "Area 3 checkpoint ${label}: replaying 27 attacks alongside live traffic"
    run_attacks "$label"
    systemctl --user stop "$LOAD_UNIT" 2>/dev/null   # traffic only needed while attacks run
    wait "$gp" 2>/dev/null
    local sent; sent=$(awk -F, 'NR > 1 {n++} END {print n + 0}' "${RUN_DIR}/soak-r90.csv")
    echo $(( from + count )) > "${RESULTS}/state/extra-cursor"
    summarize_attacks "$label"
    RESULT_NOTE="checkpoint ${label}: $(grep -c ',PASS,' "${RUN_DIR}/attacks-${label}.csv")/27 attacks blocked; ${sent} live votes recorded"
    systemctl --user stop "p4p-sampler-n${N}" 2>/dev/null
}

# ------------------------------------------------------------- double (3) ---
phase_double() {
    need_net
    CURRENT_STEP="mass double vote"
    [ "$(height_of 1)" -gt 0 ] || { chain_up keep || fail "CHAIN_START_FAILED"; }
    watchdog_start 60
    # the soak was cut to 1M votes (user decision 2026-10-16): pick only voters it reached
    gen double --sample=1000 --range="${P4P_DOUBLE_RANGE:-0:${SOAK_VOTERS}}" --out="${RUN_DIR}/double-vote.csv" >> "$LOG" 2>&1
    local rc=$?
    log "Mass double vote: $(jq -c '{counts, talliesUnchanged, allBlocked}' "${RUN_DIR}/double-vote.csv.summary.json" 2>/dev/null)"
    [ "$rc" -eq 0 ] || fail "DOUBLE_VOTE_CHECK_FAILED :: see double-vote.csv.summary.json"
    RESULT_NOTE="1000/1000 double votes reverted, tallies unchanged"
}

# --------------------------------------------------------------- area2 (2) ---
wait_rejoin() {  # <validator> -> seconds until it is within 1 block of validator 1 (max 1800)
    local v="$1" t0; t0=$(date +%s)
    while [ $(( $(date +%s) - t0 )) -lt 1800 ]; do
        local hv h1; hv=$(height_of "$v"); h1=$(height_of 1)
        [ "$hv" -ge 0 ] && [ $((h1 - hv)) -le 1 ] && { echo $(( $(date +%s) - t0 )); return; }
        sleep 2
    done
    echo "timeout"
}

phase_area2() {
    need_net
    # simplified finish (user decision 2026-10-16): P4P_A2_RATE / *_SECS override the plan's
    # soak-rate load, 5 min pre-crash, 10 min crash and 3 + 5 min quorum-loss timings
    local rate="${P4P_A2_RATE:-$(cat "${RESULTS}/state/soak-rate")}"
    local pre="${P4P_A2_PRE_SECS:-300}" down="${P4P_A2_CRASH_SECS:-600}" post="${P4P_A2_POST_SECS:-600}"
    local qpre="${P4P_A2_QPRE_SECS:-180}" qhold="${P4P_A2_QHOLD_SECS:-300}" qpost="${P4P_A2_QPOST_SECS:-720}"
    [ "$(height_of 1)" -gt 0 ] || { chain_up keep || fail "CHAIN_START_FAILED"; }
    sampler_start 5
    collector_start "${RUN_DIR}/collector.csv" 30
    write_notes
    local cursor; cursor=$(cat "${RESULTS}/state/reserve-cursor" 2>/dev/null || echo $RESERVE_FROM)

    # --- 9.1 crash f = 1 under load ---
    CURRENT_STEP="9.1 crash validator 4"
    watchdog_start 60 "4"
    local count=$((rate * (pre + down + post))) t_start
    log "9.1: ${count} reserve votes at ${rate}/s to validators 1-3; crash validator 4 at +${pre}s for ${down}s"
    t_start=$(date +%s%3N)
    gen vote --from="$cursor" --count="$count" --rate="$rate" --out="${RUN_DIR}/a2-crash.csv" --label=a2-crash --send-to=1,2,3 --drain-secs=300 >> "$LOG" 2>&1 &
    local gp=$!
    sleep "$pre"
    local crash_ms h_crash; crash_ms=$(date +%s%3N); h_crash=$(height_of 1)
    bash "${PERF_DIR}/network/node-ctl.sh" "$N" 4 crash >> "$LOG" 2>&1
    log "9.1: validator 4 crashed (SIGKILL) at block ${h_crash}"
    sleep "$down"
    local h_before_restart restart_ms; h_before_restart=$(height_of 1); restart_ms=$(date +%s%3N)
    bash "${PERF_DIR}/network/node-ctl.sh" "$N" 4 start >> "$LOG" 2>&1
    local rejoin; rejoin=$(wait_rejoin 4)
    log "9.1: chain advanced ${h_crash} -> ${h_before_restart} while validator 4 was down ($((h_before_restart - h_crash)) blocks in ${down} s); validator 4 reached head ${rejoin}s after restart"
    wait "$gp"
    cursor=$((cursor + count)); echo "$cursor" > "${RESULTS}/state/reserve-cursor"
    local before during after
    before=$(awk -F, -v a=$((crash_ms - 300000)) -v b="$crash_ms" '$3>=a && $3<b && $7=="ok" {print $5}' "${RUN_DIR}/a2-crash.csv" | sort -n | awk '{v[NR]=$1} END {print (NR ? v[int(NR*0.95+0.999)] : "-")}')
    during=$(awk -F, -v a="$crash_ms" -v b="$restart_ms" '$3>=a && $3<b && $7=="ok" {print $5}' "${RUN_DIR}/a2-crash.csv" | sort -n | awk '{v[NR]=$1} END {print (NR ? v[int(NR*0.95+0.999)] : "-")}')
    after=$(awk -F, -v a="$restart_ms" '$3>=a && $7=="ok" {print $5}' "${RUN_DIR}/a2-crash.csv" | sort -n | awk '{v[NR]=$1} END {print (NR ? v[int(NR*0.95+0.999)] : "-")}')
    local s="${RUN_DIR}/a2-crash.csv.summary.json"
    log "9.1 result: $(jq -c '{sent, ok, reverted, dropped, sendErrors, successPct}' "$s"); p95 before/during/after crash ${before}/${during}/${after} ms; rejoin ${rejoin}s"
    echo "test,blocks_while_down,failed_votes,p95_before_ms,p95_down_ms,p95_after_ms,rejoin_s" > "${RUN_DIR}/a2-crash-result.csv"
    echo "crash-f1,$((h_before_restart - h_crash)),$(( $(jq '.reverted + .dropped + .sendErrors' "$s") )),${before},${during},${after},${rejoin}" >> "${RUN_DIR}/a2-crash-result.csv"
    sleep 60

    # --- 9.2 quorum loss ---
    CURRENT_STEP="9.2 quorum loss"
    watchdog_start 100000 "3 4"
    count=$((rate * (qpre + qhold + qpost)))
    log "9.2: ${count} reserve votes at ${rate}/s to validators 1-2; crash validators 3+4 at +${qpre}s for ${qhold}s"
    gen vote --from="$cursor" --count="$count" --rate="$rate" --out="${RUN_DIR}/a2-quorum.csv" --label=a2-quorum --send-to=1,2 --drain-secs=900 >> "$LOG" 2>&1 &
    gp=$!
    sleep "$qpre"
    local h_halt; h_halt=$(height_of 1)
    bash "${PERF_DIR}/network/node-ctl.sh" "$N" 3 crash >> "$LOG" 2>&1
    bash "${PERF_DIR}/network/node-ctl.sh" "$N" 4 crash >> "$LOG" 2>&1
    local halt_ms; halt_ms=$(date +%s%3N)
    log "9.2: validators 3 and 4 crashed at block ${h_halt}; holding ${qhold}s"
    sleep 20
    local h_hold0; h_hold0=$(height_of 1)
    sleep $((qhold - 20))
    local h_hold1 h2_hold1 hash1 hash2 pool_peak
    h_hold1=$(height_of 1); h2_hold1=$(height_of 2); hash1=$(hash_at 1 "$h_hold1"); hash2=$(hash_at 2 "$h_hold1"); pool_peak=$(pool_of 1)
    local halted=$([ "$h_hold1" -eq "$h_hold0" ] && echo yes || echo no) fork=$([ "$hash1" = "$hash2" ] && [ "$h_hold1" -eq "$h2_hold1" ] && echo no || echo yes)
    log "9.2: during hold heights ${h_hold0} -> ${h_hold1} (halted: ${halted}); v1/v2 at ${h_hold1}/${h2_hold1}, same hash: $([ "$fork" = no ] && echo yes || echo NO); pool on v1 ${pool_peak}"
    local restart2_ms; restart2_ms=$(date +%s%3N)
    bash "${PERF_DIR}/network/node-ctl.sh" "$N" 3 start >> "$LOG" 2>&1
    bash "${PERF_DIR}/network/node-ctl.sh" "$N" 4 start >> "$LOG" 2>&1
    local first_block="timeout" t0; t0=$(date +%s)
    while [ $(( $(date +%s) - t0 )) -lt 1800 ]; do
        [ "$(height_of 1)" -gt "$h_hold1" ] && { first_block=$(( $(date +%s) - t0 )); break; }
        sleep 1
    done
    log "9.2: first new block ${first_block}s after restarting validators 3 and 4"
    local backlog="timeout"; t0=$(date +%s)
    # backlog cleared = pool back to roughly one block of steady-state traffic
    while [ $(( $(date +%s) - t0 )) -lt 1800 ]; do
        [ "$(pool_of 1)" -le $((rate * 4)) ] && { backlog=$(( $(date +%s) - t0 )); break; }
        sleep 2
    done
    log "9.2: pool backlog (peak ${pool_peak}) cleared ${backlog}s after restart"
    local rj3 rj4; rj3=$(wait_rejoin 3); rj4=$(wait_rejoin 4)
    wait "$gp"
    cursor=$((cursor + count)); echo "$cursor" > "${RESULTS}/state/reserve-cursor"
    s="${RUN_DIR}/a2-quorum.csv.summary.json"
    local lost_halt
    lost_halt=$(awk -F, -v a="$halt_ms" -v b="$restart2_ms" '$3>=a && $3<b && $7!="ok" {n++} END {print n+0}' "${RUN_DIR}/a2-quorum.csv")
    local sent_halt
    sent_halt=$(awk -F, -v a="$halt_ms" -v b="$restart2_ms" '$3>=a && $3<b {n++} END {print n+0}' "${RUN_DIR}/a2-quorum.csv")
    log "9.2 result: $(jq -c '{sent, ok, reverted, dropped, sendErrors, successPct}' "$s"); ${sent_halt} votes sent during the halt, ${lost_halt} not confirmed"
    echo "test,halted,fork,pool_peak,first_block_s,backlog_clear_s,v3_rejoin_s,v4_rejoin_s,sent_during_halt,lost_during_halt,failed_total" > "${RUN_DIR}/a2-quorum-result.csv"
    echo "quorum-loss,${halted},${fork},${pool_peak},${first_block},${backlog},${rj3},${rj4},${sent_halt},${lost_halt},$(( $(jq '.reverted + .dropped + .sendErrors' "$s") ))" >> "${RUN_DIR}/a2-quorum-result.csv"
    watchdog_start 60
    collector_stop
    systemctl --user stop "p4p-sampler-n${N}" 2>/dev/null
    RESULT_NOTE="crash-f1 + quorum-loss done"
}

# -------------------------------------------------------------- verify (10) ---
phase_verify() {
    need_net
    CURRENT_STEP="wait pool empty"
    [ "$(height_of 1)" -gt 0 ] || { chain_up keep || fail "CHAIN_START_FAILED"; }
    local i t0; t0=$(date +%s)
    while [ $(( $(date +%s) - t0 )) -lt 1800 ]; do
        local tot=0; for i in 1 2 3 4; do tot=$((tot + $(pool_of "$i"))); done
        [ "$tot" -le 0 ] && break; sleep 5
    done
    log "Pools empty after $(( $(date +%s) - t0 ))s"
    CURRENT_STEP="heads + tallies"
    sleep 6
    run_unit "$LOAD_UNIT" "$PERF_DIR" node loadgen/verify.js --net="$R2_NET" --scan-to="$TOTAL_VOTERS" --results="$RESULTS" --out="${RUN_DIR}/verify.json" >> "$LOG" 2>&1
    local rc=$?
    log "Verify: $(jq -c '{pass, headsAgree, talliesMatchVotedSet, noConfirmedVoteLost, talliesMatch, votedInGeneratorRange, generatorOk, votedButNoOkRow: .votedButNoOkRow.count}' "${RUN_DIR}/verify.json" 2>/dev/null)"
    for i in 1 2 3 4; do log "  validator${i} final DB $(db_mb "$i") MB"; done
    CURRENT_STEP="archive"
    mkdir -p "${RUN_DIR}/node-logs"
    for i in 1 2 3 4; do gzip -c "${GEN_DIR}/validator${i}.log" > "${RUN_DIR}/node-logs/validator${i}.log.gz"; done
    curl -s -XPOST 'http://127.0.0.1:9090/api/v1/admin/tsdb/snapshot' > "${RUN_DIR}/prometheus-snapshot.json"
    log "Prometheus snapshot: $(jq -r '.data.name // .error // "admin API off"' "${RUN_DIR}/prometheus-snapshot.json")"
    [ "$rc" -eq 0 ] || fail "VERIFICATION_FAILED :: see verify.json"
    RESULT_NOTE="verification passed"
}

log "=== Round 2 phase '${PHASE}' (run dir ${RUN_DIR}) ==="
# measured phases need a full-speed host; re-probe a few times so a transient
# blip (e.g. just after VM boot) doesn't fail the phase
for attempt in 1 2 3; do
    CPU_BENCH=$(bash "${PERF_DIR}/monitoring/cpu-bench.sh")
    log "CPU probe: ${CPU_BENCH}s (normal ~1.15s)"
    [ "$(echo "$CPU_BENCH <= ${P4P_CPU_BENCH_MAX:-1.5}" | bc)" -eq 1 ] && break
    [ "$attempt" -lt 3 ] && sleep 15
done
# measured phases need a full-speed host (normal ~1.15 s); seeding is unmeasured
case "$PHASE" in seed) BENCH_MAX="${P4P_CPU_BENCH_MAX:-2.5}" ;; *) BENCH_MAX="${P4P_CPU_BENCH_MAX:-1.5}" ;; esac
[ "$(echo "$CPU_BENCH > $BENCH_MAX" | bc)" -eq 1 ] && fail "HOST_SLOW :: CPU probe ${CPU_BENCH}s > ${BENCH_MAX}s - host throttled or power-limited (check Windows power mode / VirtualBox efficiency mode)"
case "$PHASE" in
smoke) phase_smoke ;;
seed) phase_seed ;;
calibrate) phase_calibrate ;;
soak) phase_soak ;;
soak-attacks) phase_soak_attacks ;;
double) phase_double ;;
area2) phase_area2 ;;
verify) phase_verify ;;
*) fail "UNKNOWN_PHASE ${PHASE}" ;;
esac
