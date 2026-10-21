#!/bin/bash
# One-command live demo: 4 Besu validators + voting contract + the Next.js site,
# published to phones through a Cloudflare quick tunnel (public HTTPS URL, no
# account, works through the VM's NAT and on mobile data).
#
# Usage: demo/start-demo.sh [--new-election] [--lan]
#   --new-election  deploy a fresh VotingSystem contract (new join code, zero
#                   votes). Without it, the contract from the previous run is
#                   reused so a restart mid-demo keeps every vote.
#   --lan           skip the tunnel; serve on 0.0.0.0:$DEMO_PORT and put
#                   $DEMO_PUBLIC_URL (default http://<VM IP>:$DEMO_PORT) in
#                   the QR. Needs phones to reach the VM directly (bridged
#                   adapter or a VirtualBox port-forward).
#
# Env: DEMO_CANDIDATES  comma-separated names (default "Party A,Party B,Party C")
#      DEMO_PORT        web port (default 3000)
#      DEMO_MAX_VOTERS  auto-registration cap (default 500)
#
# Every long-running process is a memory-capped systemd --user unit in
# p4p-demo.slice, never a child of this shell: a Besu OOM inside the VS Code
# terminal's cgroup takes the whole editor down (see perf-testing/network/
# start-native.sh). Stop everything with demo/stop-demo.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO="$ROOT/demo"
STATE="$DEMO/.state"
SLICE="p4p-demo.slice"
PORT="${DEMO_PORT:-3000}"
CANDIDATES="${DEMO_CANDIDATES:-Party A,Party B,Party C}"
NEW_ELECTION=0
MODE=tunnel
for arg in "$@"; do
    case "$arg" in
        --new-election) NEW_ELECTION=1 ;;
        --lan) MODE=lan ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done
mkdir -p "$STATE" "$DEMO/bin"
chmod 700 "$STATE"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
rpc() {  # rpc <url> <method> [params-json]
    curl -s -m 3 -X POST -H 'Content-Type: application/json' \
        --data "{\"jsonrpc\":\"2.0\",\"method\":\"$2\",\"params\":${3:-[]},\"id\":1}" "$1"
}
height() {  # empty while the node is not answering yet
    local hex
    hex=$(rpc "$1" eth_blockNumber 2>/dev/null | jq -r '.result // empty' 2>/dev/null) || true
    [ -n "$hex" ] && printf '%d\n' "$hex" || true
}
unit_active() { systemctl --user is-active --quiet "$1"; }
run_unit() {  # run_unit <unit> <MemoryMax> [systemd-run args...] -- cmd...
    local unit="$1" mem="$2"; shift 2
    systemctl --user stop "$unit" 2>/dev/null || true
    systemctl --user reset-failed "$unit" 2>/dev/null || true
    systemd-run --user --quiet --unit="$unit" --slice="$SLICE" -p MemoryMax="$mem" -p MemorySwapMax=0 \
        --setenv=PATH="$PATH" ${JAVA_HOME:+--setenv=JAVA_HOME="$JAVA_HOME"} "$@"
}

for tool in besu forge cast jq curl node; do
    command -v "$tool" >/dev/null || die "$tool not found on PATH"
done

# ─── 1. Validators ───────────────────────────────────────────────────────────
BESU="$(command -v besu)"
BOOT_ENODE="enode://be4af04b365cdd1a9df45df2b2ded88fc00fb5437491df54df2456725586c035909853b34f6479ef32ffeb095c231cee5c127b7382833bb3f979bb63d814cc62@127.0.0.1:30303"
RPC_URLS=()
for i in 1 2 3 4; do
    rpc_port=$((8544 + i)); p2p_port=$((30302 + i)); unit="p4p-demo-besu$i"
    RPC_URLS+=("http://127.0.0.1:${rpc_port}")
    if unit_active "$unit"; then
        log "Validator $i already running ($unit)"
        continue
    fi
    if [ -n "$(height "http://127.0.0.1:${rpc_port}")" ]; then
        log "Validator $i: something already answers on :${rpc_port} - reusing it"
        continue
    fi
    [ -f "$ROOT/network/node$i/key" ] || die "network/node$i/key missing - generate the network first (README step 2)"
    log "Starting validator $i (RPC :${rpc_port}, unit $unit, 1 GiB heap)"
    bootnodes=(); [ "$i" -gt 1 ] && bootnodes=(--bootnodes="$BOOT_ENODE")
    run_unit "$unit" 2200M --working-directory="$ROOT" --setenv=BESU_OPTS="-Xmx1g" \
        "$BESU" \
        --data-path="network/node$i/data" \
        --genesis-file="network/node$i/genesis.json" \
        --node-private-key-file="network/node$i/key" \
        "${bootnodes[@]}" \
        --rpc-http-enabled --rpc-http-host=127.0.0.1 \
        --rpc-http-api=ETH,NET,IBFT,TXPOOL \
        --host-allowlist=localhost,127.0.0.1 \
        --rpc-http-port="$rpc_port" --p2p-port="$p2p_port" \
        --profile=ENTERPRISE --min-gas-price=0 \
        --logging=INFO
    [ "$i" -eq 1 ] && sleep 4
done

# "Live" means the head block was sealed in the last few seconds. A rising
# height alone is not enough: right after a restart the nodes import old blocks
# from each other while IBFT itself is still stuck.
chain_live() {
    local ts
    ts=$(rpc "${RPC_URLS[0]}" eth_getBlockByNumber '["latest",false]' 2>/dev/null \
        | jq -r '.result.timestamp // empty' 2>/dev/null) || true
    [ -n "$ts" ] && [ $(( $(date +%s) - $(printf '%d' "$ts") )) -le 8 ]
}
wait_live() {  # wait_live <seconds>
    local deadline=$(( $(date +%s) + $1 ))
    until chain_live; do
        [ "$(date +%s)" -ge "$deadline" ] && return 1
        sleep 2
    done
}

log "Waiting for the validators to seal new blocks..."
if ! wait_live 75; then
    # When the validators come up at different moments they can land in
    # different IBFT rounds, and the doubling round timeout (4s, 8s, ... 128s)
    # keeps them apart for minutes. Restarting all four together puts them back
    # in round 0 at the same time.
    log "IBFT rounds out of step - restarting all 4 validators together"
    systemctl --user restart p4p-demo-besu1 p4p-demo-besu2 p4p-demo-besu3 p4p-demo-besu4
    wait_live 150 || die "Chain not producing blocks - check: journalctl --user -u p4p-demo-besu2 -n 50"
fi
log "Chain live at block $(height "${RPC_URLS[0]}")"

# ─── 2. Contract ─────────────────────────────────────────────────────────────
DEPLOYER_KEY="$(grep -E '^DEPLOYER_PRIVATE_KEY=' "$ROOT/voting-contract/.env" | cut -d= -f2- | tr -d '"[:space:]')"
[ -n "$DEPLOYER_KEY" ] || die "DEPLOYER_PRIVATE_KEY missing in voting-contract/.env"
[[ "$DEPLOYER_KEY" == 0x* ]] || DEPLOYER_KEY="0x$DEPLOYER_KEY"

ELECTION="$STATE/election.env"
if [ "$NEW_ELECTION" -eq 0 ] && [ -f "$ELECTION" ]; then
    # shellcheck disable=SC1090
    source "$ELECTION"
    code=$(rpc "${RPC_URLS[0]}" eth_getCode "[\"$DEMO_CONTRACT_ADDRESS\",\"latest\"]" | jq -r '.result // "0x"')
    if [ "$code" = "0x" ]; then
        log "Previous contract $DEMO_CONTRACT_ADDRESS not on this chain - deploying a new election"
        NEW_ELECTION=1
    else
        log "Reusing election contract $DEMO_CONTRACT_ADDRESS (pass --new-election for a fresh one)"
    fi
else
    NEW_ELECTION=1
fi

if [ "$NEW_ELECTION" -eq 1 ]; then
    IFS=',' read -ra cands <<< "$CANDIDATES"
    log "Deploying VotingSystem with ${#cands[@]} candidates: $CANDIDATES"
    (cd "$ROOT/voting-contract" && forge build --quiet)
    out=$(cd "$ROOT/voting-contract" && forge create src/VotingSystem.sol:VotingSystem \
        --rpc-url "${RPC_URLS[0]}" --private-key "$DEPLOYER_KEY" \
        --legacy --gas-price 0 --broadcast --json --constructor-args "${#cands[@]}")
    addr=$(jq -r '.deployedTo' <<< "$out")
    txh=$(jq -r '.transactionHash' <<< "$out")
    [[ "$addr" == 0x* ]] || die "Deploy failed: $out"
    blk=$(cast receipt "$txh" blockNumber --rpc-url "${RPC_URLS[0]}")
    {
        echo "DEMO_CONTRACT_ADDRESS=$addr"
        echo "DEMO_DEPLOY_BLOCK=$blk"
        echo "DEMO_CANDIDATES=\"$CANDIDATES\""
        echo "DEMO_JOIN_CODE=$(openssl rand -hex 4)"
        echo "DEMO_ADMIN_TOKEN=$(openssl rand -hex 16)"
    } > "$ELECTION"
    chmod 600 "$ELECTION"
    # shellcheck disable=SC1090
    source "$ELECTION"
    log "Contract deployed at $addr (block $blk)"
fi

# ─── 3. Public URL ───────────────────────────────────────────────────────────
if [ "$MODE" = tunnel ]; then
    CLOUDFLARED="$DEMO/bin/cloudflared"
    if [ ! -x "$CLOUDFLARED" ]; then
        log "Downloading cloudflared to demo/bin/"
        curl -fsSL -o "$CLOUDFLARED" \
            https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
        chmod +x "$CLOUDFLARED"
    fi
    if unit_active p4p-demo-tunnel && [ -f "$STATE/public-url" ]; then
        PUBLIC_URL=$(cat "$STATE/public-url")
        log "Tunnel already running: $PUBLIC_URL"
    else
        log "Opening Cloudflare quick tunnel -> 127.0.0.1:$PORT"
        : > "$STATE/tunnel.log"
        run_unit p4p-demo-tunnel 256M \
            "$CLOUDFLARED" tunnel --no-autoupdate --url "http://127.0.0.1:$PORT" --logfile "$STATE/tunnel.log"
        PUBLIC_URL=""
        for _ in $(seq 1 30); do
            PUBLIC_URL=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$STATE/tunnel.log" | head -1 || true)
            [ -n "$PUBLIC_URL" ] && break
            sleep 1
        done
        [ -n "$PUBLIC_URL" ] || die "Tunnel did not report a URL - see $STATE/tunnel.log"
        echo "$PUBLIC_URL" > "$STATE/public-url"
    fi
    HOST=127.0.0.1
else
    vm_ip=$(hostname -I | awk '{print $1}')
    PUBLIC_URL="${DEMO_PUBLIC_URL:-http://${vm_ip}:${PORT}}"
    HOST=0.0.0.0
    systemctl --user stop p4p-demo-tunnel 2>/dev/null || true
fi

# ─── 4. Website ──────────────────────────────────────────────────────────────
FRONTEND="$ROOT/frontend"
if [ ! -f "$FRONTEND/.next/BUILD_ID" ] || \
   [ -n "$(find "$FRONTEND/app" "$FRONTEND/lib" "$FRONTEND/components" "$FRONTEND/package.json" -newer "$FRONTEND/.next/BUILD_ID" -print -quit)" ]; then
    log "Building the website (next build)..."
    systemctl --user reset-failed p4p-demo-build 2>/dev/null || true
    systemd-run --user --quiet --wait --pipe --unit=p4p-demo-build --slice="$SLICE" -p MemoryMax=3G \
        --working-directory="$FRONTEND" --setenv=PATH="$PATH" --setenv=NEXT_TELEMETRY_DISABLED=1 \
        npm run build
fi

# the contract admin is whoever deployed it; the website signs admin txs
# (registerVoter / openVoting / closeVoting) with that same key
ADMIN_KEY="$DEPLOYER_KEY"
ADMIN_ADDR=$(cast call "$DEMO_CONTRACT_ADDRESS" 'admin()(address)' --rpc-url "${RPC_URLS[0]}")
[ "$(cast wallet address "$ADMIN_KEY")" = "$ADMIN_ADDR" ] \
    || die "DEPLOYER_PRIVATE_KEY is not the admin ($ADMIN_ADDR) of the reused contract - run with --new-election"

WEB_ENV="$STATE/web.env"
{
    echo "NODE_ENV=production"
    echo "NEXT_TELEMETRY_DISABLED=1"
    echo "BESU_RPC_URLS=$(IFS=,; echo "${RPC_URLS[*]}")"
    echo "DEMO_CONTRACT_ADDRESS=$DEMO_CONTRACT_ADDRESS"
    echo "DEMO_DEPLOY_BLOCK=$DEMO_DEPLOY_BLOCK"
    echo "DEMO_CANDIDATES=$DEMO_CANDIDATES"
    echo "DEMO_JOIN_CODE=$DEMO_JOIN_CODE"
    echo "DEMO_ADMIN_TOKEN=$DEMO_ADMIN_TOKEN"
    echo "DEMO_ADMIN_PRIVATE_KEY=$ADMIN_KEY"
    echo "DEMO_PUBLIC_URL=$PUBLIC_URL"
    echo "DEMO_MAX_VOTERS=${DEMO_MAX_VOTERS:-500}"
} > "$WEB_ENV"
chmod 600 "$WEB_ENV"

log "Starting website on $HOST:$PORT (unit p4p-demo-web)"
run_unit p4p-demo-web 1G --working-directory="$FRONTEND" -p EnvironmentFile="$WEB_ENV" \
    "$(command -v node)" node_modules/next/dist/bin/next start -p "$PORT" -H "$HOST"

for _ in $(seq 1 30); do
    curl -sf -m 3 "http://127.0.0.1:$PORT/api/status" >/dev/null && break
    sleep 1
done
curl -sf -m 3 "http://127.0.0.1:$PORT/api/status" >/dev/null \
    || die "Website not answering - check: journalctl --user -u p4p-demo-web -n 50"

if [ "$MODE" = tunnel ]; then
    log "Waiting for the public URL to resolve (can take ~30s)..."
    ok=0
    for _ in $(seq 1 30); do
        curl -sf -m 5 "$PUBLIC_URL/api/status" >/dev/null && { ok=1; break; }
        sleep 2
    done
    [ "$ok" -eq 1 ] || echo "  (not reachable yet from this VM - usually fine within a minute)"
fi

PRESENTER="http://localhost:$PORT/demo?admin=$DEMO_ADMIN_TOKEN"
JOIN="$PUBLIC_URL/vote?code=$DEMO_JOIN_CODE"
printf '%s\n%s\n' "PRESENTER=$PRESENTER" "JOIN=$JOIN" > "$STATE/links.txt"
cat <<EOF

  ┌───────────────────────────────────────────────────────────────────────
  │ Demo is up.
  │
  │ Presenter screen (open on this VM, put it on the projector):
  │   $PRESENTER
  │
  │ Phones scan the QR on that screen, which points to:
  │   $JOIN
  │
  │ Contract: $DEMO_CONTRACT_ADDRESS   Candidates: $DEMO_CANDIDATES
  │ Logs:     journalctl --user -u p4p-demo-web -f
  │ Stop:     demo/stop-demo.sh         (add --all to stop the validators)
  └───────────────────────────────────────────────────────────────────────
EOF
