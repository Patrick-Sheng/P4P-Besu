#!/bin/bash
# Round 2 monitoring stack (plan Section 6.1 step 4): Prometheus, Grafana and
# node_exporter from the release tarballs in ~/p4p-monitoring (no root needed),
# each as its own memory-capped systemd --user unit in p4p-mon.slice so a
# Besu OOM can't take them down and vice versa.
#
#   Prometheus  http://127.0.0.1:9090  scrape 15s; targets: node_exporter +
#               every validator's --metrics-port (9000 + N*100 + i, set by
#               start-native.sh with P4P_METRICS=1)
#   Grafana     http://127.0.0.1:3000  (admin/admin), dashboards 16455 (Besu
#               Full) and 1860 (Node Exporter Full) provisioned
#   node_exporter :9100
#
# Usage: scripts/r2-monitoring.sh start <nodeCount> | stop | status
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
MON="${P4P_MON_HOME:-$HOME/p4p-monitoring}"
DATA="${MON}/data"
PROM="${MON}/prometheus-2.53.2.linux-amd64"
NODEX="${MON}/node_exporter-1.8.2.linux-amd64"
GRAF="${MON}/grafana-v11.2.0"
UNITS=(p4p-mon-prometheus p4p-mon-grafana p4p-mon-nodeexp)

case "${1:-}" in
stop)
    systemctl --user stop "${UNITS[@]}" 2>/dev/null || true
    systemctl --user reset-failed "${UNITS[@]}" 2>/dev/null || true
    echo "monitoring stopped"; exit 0 ;;
status)
    for u in "${UNITS[@]}"; do printf '%-22s %s\n' "$u" "$(systemctl --user is-active "$u")"; done
    curl -s 'http://127.0.0.1:9090/api/v1/targets' | jq -r '.data.activeTargets[] | "\(.labels.job) \(.labels.instance) \(.health)"' 2>/dev/null
    exit 0 ;;
start) ;;
*) echo "Usage: $0 start <nodeCount> | stop | status" >&2; exit 1 ;;
esac

N="${2:?start needs <nodeCount>}"
mkdir -p "${DATA}/prometheus" "${DATA}/grafana" "${MON}/conf/provisioning/datasources" "${MON}/conf/provisioning/dashboards"

targets=""
for ((i = 0; i < N; i++)); do targets+="'127.0.0.1:$((9000 + N * 100 + i))', "; done
cat > "${MON}/conf/prometheus.yml" <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s
scrape_configs:
  - job_name: node
    static_configs:
      - targets: ['127.0.0.1:9100']
  - job_name: besu
    static_configs:
      - targets: [${targets%, }]
EOF

cat > "${MON}/conf/provisioning/datasources/prometheus.yml" <<EOF
apiVersion: 1
datasources:
  - name: Prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://127.0.0.1:9090
    isDefault: true
EOF
cat > "${MON}/conf/provisioning/dashboards/p4p.yml" <<EOF
apiVersion: 1
providers:
  - name: p4p
    type: file
    options:
      path: ${MON}/conf/dashboards
EOF
mkdir -p "${MON}/conf/dashboards"
# provisioned dashboards can't prompt for __inputs: bind the datasource placeholder
sed 's/\${DS_PROMETHEUS}/prometheus/g' "${MON}/dashboards/16455.json" > "${MON}/conf/dashboards/besu-16455.json"
cp "${MON}/dashboards/1860.json" "${MON}/conf/dashboards/node-1860.json"

systemctl --user stop "${UNITS[@]}" 2>/dev/null || true
systemctl --user reset-failed "${UNITS[@]}" 2>/dev/null || true
run() {  # <unit> <memMB> <cmd...>
    local u="$1" m="$2"; shift 2
    systemd-run --user --quiet --unit="$u" --slice=p4p-mon.slice -p MemoryMax="${m}M" -p MemorySwapMax=0 \
        -p StandardOutput="append:${DATA}/${u}.log" -p StandardError="append:${DATA}/${u}.log" "$@"
}
run p4p-mon-nodeexp 64 "${NODEX}/node_exporter" --web.listen-address=127.0.0.1:9100
run p4p-mon-prometheus 400 "${PROM}/prometheus" --config.file="${MON}/conf/prometheus.yml" \
    --storage.tsdb.path="${DATA}/prometheus" --storage.tsdb.retention.time=30d --web.listen-address=127.0.0.1:9090 --web.enable-admin-api
run p4p-mon-grafana 300 --setenv=GF_PATHS_PROVISIONING="${MON}/conf/provisioning" --setenv=GF_PATHS_DATA="${DATA}/grafana" \
    --setenv=GF_SERVER_HTTP_ADDR=127.0.0.1 --setenv=GF_ANALYTICS_REPORTING_ENABLED=false --setenv=GF_ANALYTICS_CHECK_FOR_UPDATES=false \
    "${GRAF}/bin/grafana" server --homepath="${GRAF}"
echo "monitoring started for n=${N}: Prometheus :9090, Grafana :3000, node_exporter :9100"
