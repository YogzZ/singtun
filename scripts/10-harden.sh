#!/usr/bin/env bash
# scripts/10-harden.sh — UFW 最小暴露面收敛、VLESS 连接限流、Hysteria2 端口跳跃（nftables）与 NTP 时钟同步
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

prune_stale_ufw_rules() {
  local enable_hy2="${ENABLE_HY2:-false}"
  local cur_hy2_udp=""
  local cur_hy2_hop_udp=""
  local -A ssh_tcp_map=()
  local sp
  while IFS= read -r sp; do
    [[ -n "${sp}" ]] && ssh_tcp_map["${sp}/tcp"]=1
  done < <(detect_active_ssh_ports)

  if [[ "${enable_hy2}" == "true" ]]; then
    cur_hy2_udp="${HY2_PORT}/udp"
    if [[ -n "${HY2_HOP_PORTS:-}" ]] && is_valid_port_range "${HY2_HOP_PORTS}"; then
      cur_hy2_hop_udp="${HY2_HOP_PORTS//-/:}/udp"
    fi
  fi

  # 按注释扫描并清理已变更或已关闭的旧端口放行规则（绝不触碰当前活跃 SSH 端口）
  local old_port_proto
  if (( ${#ssh_tcp_map[@]} > 0 )); then
    while IFS= read -r old_port_proto; do
      [[ -z "${old_port_proto}" || -n "${ssh_tcp_map[${old_port_proto}]:-}" ]] && continue
      ufw delete allow "${old_port_proto}" >/dev/null 2>&1 || true
      log_info "已清理旧 SSH UFW 保留规则: ${old_port_proto}"
    done < <(
      ufw status 2>/dev/null \
        | awk '/# ssctl-preserve-ssh([[:space:]]|$)/ && $1 ~ /^[0-9]+\/tcp$/ {print $1}' \
        | sort -u || true
    )
  fi

  while IFS= read -r old_port_proto; do
    [[ -z "${old_port_proto}" || -n "${ssh_tcp_map[${old_port_proto}]:-}" ]] && continue
    ufw delete allow "${old_port_proto}" >/dev/null 2>&1 || true
    log_info "已清理旧 VLESS_PORT UFW 放行规则: ${old_port_proto}"
  done < <(
    ufw status 2>/dev/null \
      | awk -v cur="${VLESS_PORT}/tcp" '/# ssctl-vless-reality([[:space:]]|$)/ && $1 ~ /^[0-9]+\/tcp$/ && $1 != cur {print $1}' \
      | sort -u || true
  )

  while IFS= read -r old_port_proto; do
    [[ -z "${old_port_proto}" ]] && continue
    ufw delete allow "${old_port_proto}" >/dev/null 2>&1 || true
    log_info "已清理旧 Hysteria2 UFW 放行规则: ${old_port_proto}"
  done < <(
    ufw status 2>/dev/null \
      | awk -v cur="${cur_hy2_udp}" '/# ssctl-hy2([[:space:]]|$)/ && $1 ~ /^[0-9]+\/udp$/ && $1 != cur {print $1}' \
      | sort -u || true
  )

  while IFS= read -r old_port_proto; do
    [[ -z "${old_port_proto}" ]] && continue
    ufw delete allow "${old_port_proto}" >/dev/null 2>&1 || true
    log_info "已清理旧 Hysteria2 端口跳跃 UFW 放行规则: ${old_port_proto}"
  done < <(
    ufw status 2>/dev/null \
      | awk -v cur="${cur_hy2_hop_udp}" '/# ssctl-hy2-hop([[:space:]]|$)/ && $1 ~ /^[0-9]+:[0-9]+\/udp$/ && $1 != cur {print $1}' \
      | sort -u || true
  )
}

configure_ufw() {
  log_info "配置 UFW 防火墙最小暴露面..."
  ufw default deny incoming
  ufw default allow outgoing

  local p
  while IFS= read -r p; do
    [[ -z "${p}" ]] && continue
    if [[ "${p}" == "${VLESS_PORT}" ]]; then
      die "VLESS_PORT (${VLESS_PORT}) 与当前活跃 SSH 端口冲突，拒绝覆盖 SSH 防火墙保护规则！"
    fi
    ufw allow "${p}/tcp" comment 'ssctl-preserve-ssh'
  done < <(detect_active_ssh_ports)

  ufw allow "${VLESS_PORT}/tcp" comment 'ssctl-vless-reality'

  local enable_hy2="${ENABLE_HY2:-false}"
  if [[ "${enable_hy2}" == "true" ]]; then
    require_vars HY2_PORT
    ufw allow "${HY2_PORT}/udp" comment 'ssctl-hy2'

    if [[ -n "${HY2_HOP_PORTS:-}" ]]; then
      if ! is_valid_port_range "${HY2_HOP_PORTS}"; then
        die "HY2_HOP_PORTS 格式非法: ${HY2_HOP_PORTS}"
      fi
      ufw allow "${HY2_HOP_PORTS//-/:}/udp" comment 'ssctl-hy2-hop'
    fi
  fi

  ufw --force enable

  if [[ "${SSCTL_DEFER_UFW_PRUNE:-false}" != "true" ]]; then
    prune_stale_ufw_rules
  fi

  log_info "UFW 已启用并收敛端口。"
}

configure_vless_conn_guard() {
  local nft_file="/etc/ssctl/vless-guard.nft"
  local unit_file="/etc/systemd/system/ssctl-vless-guard.service"

  if ! is_valid_port "${VLESS_PORT}"; then
    die "VLESS_PORT 不是合法端口号: ${VLESS_PORT}"
  fi

  if ! command -v nft >/dev/null 2>&1; then
    log_info "正在安装 nftables 以配置 VLESS 入站并发连接与速率保护..."
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1
    apt-get install -y -qq nftables
  fi

  mkdir -p /etc/ssctl
  local ipv6_sets="" ipv6_rules=""
  if [[ "${SERVER_IPV6:-false}" == "true" ]]; then
    ipv6_sets="    # ct count (nft_connlimit) 自带内核 NFT_EXPR_GC 连接归零自动回收，禁止叠加 timeout（否则内核返回 EOPNOTSUPP）
    set vless_conn_v6 {
        type ipv6_addr
        size 65535
        flags dynamic
    }
    set vless_rate_v6 {
        type ipv6_addr
        size 65535
        flags dynamic,timeout
        timeout 1m
    }
"
    ipv6_rules="        tcp dport ${VLESS_PORT} tcp flags & (fin|syn|rst|ack) == syn update @vless_rate_v6 { ip6 saddr & ffff:ffff:ffff:ffff:: limit rate over 120/second burst 240 packets } drop
        tcp dport ${VLESS_PORT} ct state new add @vless_conn_v6 { ip6 saddr & ffff:ffff:ffff:ffff:: ct count over 256 } reject with tcp reset
"
  fi

  cat > "${nft_file}" <<EOF
#!/usr/sbin/nft -f
# Managed by ssctl (10-harden.sh) — VLESS 入站单源并发与 SYN 洪水保护独立表（严禁使用全局 flush ruleset）
table inet ssctl_guard
delete table inet ssctl_guard

table inet ssctl_guard {
    # ct count (nft_connlimit) 自带内核 NFT_EXPR_GC 连接归零自动回收，禁止叠加 timeout（否则内核返回 EOPNOTSUPP）
    set vless_conn_v4 {
        type ipv4_addr
        size 65535
        flags dynamic
    }
    set vless_rate_v4 {
        type ipv4_addr
        size 65535
        flags dynamic,timeout
        timeout 1m
    }
${ipv6_sets}    chain input {
        type filter hook input priority filter - 5; policy accept;
        iifname "lo" accept
        tcp dport ${VLESS_PORT} tcp flags & (fin|syn|rst|ack) == syn update @vless_rate_v4 { ip saddr limit rate over 120/second burst 240 packets } drop
        tcp dport ${VLESS_PORT} ct state new add @vless_conn_v4 { ip saddr ct count over 256 } reject with tcp reset
${ipv6_rules}    }
}
EOF
  chmod 644 "${nft_file}"

  nft -f "${nft_file}"

  cat > "${unit_file}" <<EOF
# Managed by ssctl (10-harden.sh) — Persist VLESS per-IP connection & SYN guard without flushing UFW
[Unit]
Description=ssctl VLESS Per-IP Connection Guard (nftables table inet ssctl_guard)
After=network.target ufw.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f ${nft_file}
ExecStop=-/usr/sbin/nft delete table inet ssctl_guard

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "${unit_file}"
  systemctl daemon-reload
  systemctl enable --now ssctl-vless-guard.service
  log_info "VLESS 入站抗连接耗尽保护已启用: TCP :${VLESS_PORT} 单源并发 <= 256, SYN <= 120/s (table inet ssctl_guard)"
}

configure_hy2_port_hopping() {
  local nft_file="/etc/ssctl/hy2-hop.nft"
  local unit_file="/etc/systemd/system/ssctl-hy2-hop.service"
  local enable_hy2="${ENABLE_HY2:-false}"

  if [[ "${enable_hy2}" != "true" || -z "${HY2_HOP_PORTS:-}" ]]; then
    if [[ -f "${unit_file}" ]] || systemctl is-active --quiet ssctl-hy2-hop.service 2>/dev/null; then
      systemctl disable --now ssctl-hy2-hop.service >/dev/null 2>&1 || true
      rm -f "${unit_file}"
      systemctl daemon-reload
    fi
    rm -f "${nft_file}"
    if command -v nft >/dev/null 2>&1; then
      if nft list table inet ssctl_hy2 >/dev/null 2>&1; then
        nft delete table inet ssctl_hy2 >/dev/null 2>&1 || true
        log_info "已移除 Hysteria2 端口跳跃 nftables 表 (inet ssctl_hy2)。"
      fi
    fi
    return 0
  fi

  if ! is_valid_port_range "${HY2_HOP_PORTS}"; then
    die "HY2_HOP_PORTS 格式非法: ${HY2_HOP_PORTS}"
  fi
  local hop_start="${HY2_HOP_PORTS%-*}"
  local hop_end="${HY2_HOP_PORTS#*-}"

  if ! command -v nft >/dev/null 2>&1; then
    log_info "正在安装 nftables 以配置 Hysteria2 端口跳跃..."
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1
    apt-get install -y -qq nftables
  fi

  mkdir -p /etc/ssctl
  local nfproto_match="meta nfproto ipv4 "
  if [[ "${SERVER_IPV6:-false}" == "true" ]]; then
    nfproto_match=""
  fi
  cat > "${nft_file}" <<EOF
#!/usr/sbin/nft -f
# Managed by ssctl (10-harden.sh) — Hysteria2 UDP 端口跳跃独立表（严禁使用全局 flush ruleset）
table inet ssctl_hy2
delete table inet ssctl_hy2

table inet ssctl_hy2 {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        ${nfproto_match}fib daddr type local udp dport ${hop_start}-${hop_end} redirect to :${HY2_PORT}
    }
}
EOF
  chmod 644 "${nft_file}"

  nft -f "${nft_file}"

  cat > "${unit_file}" <<EOF
# Managed by ssctl (10-harden.sh) — Persist Hysteria2 UDP port hopping without flushing UFW
[Unit]
Description=ssctl Hysteria2 UDP Port Hopping (nftables table inet ssctl_hy2)
After=network.target ufw.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f ${nft_file}
ExecStop=-/usr/sbin/nft delete table inet ssctl_hy2

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "${unit_file}"
  systemctl daemon-reload
  systemctl enable --now ssctl-hy2-hop.service
  log_info "Hysteria2 端口跳跃已启用: UDP ${hop_start}-${hop_end} -> :${HY2_PORT} (table inet ssctl_hy2)"
}

configure_ntp() {
  log_info "启用 NTP 系统时钟同步..."
  local units
  units="$(systemctl list-unit-files 2>/dev/null | awk '{print $1}' || true)"

  if grep -Fxq "chrony.service" <<< "${units}"; then
    systemctl enable --now chrony
  elif grep -Fxq "systemd-timesyncd.service" <<< "${units}"; then
    systemctl enable --now systemd-timesyncd
  else
    log_info "未检测到 chrony 或 systemd-timesyncd，正在安装 systemd-timesyncd..."
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1
    apt-get install -y -qq systemd-timesyncd
    systemctl enable --now systemd-timesyncd
  fi

  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-ntp true || true

    local _ ntp_sync="no"
    for _ in 1 2 3 4 5; do
      ntp_sync="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo "unknown")"
      if [[ "${ntp_sync}" == "yes" ]]; then
        break
      fi
      sleep 1
    done

    if [[ "${ntp_sync}" == "yes" ]]; then
      log_info "NTP 时间同步已就绪 (NTPSynchronized=yes)。"
    else
      log_warn "NTP 服务已启用，但当前尚未完成首次时钟同步 (NTPSynchronized=${ntp_sync})；请稍后通过 'timedatectl status' 确认同步正常（REALITY 对时间偏差敏感）。"
    fi
  fi
}

main() {
  require_root
  acquire_ssctl_lock
  detect_os >/dev/null
  detect_arch >/dev/null
  load_env
  require_vars VLESS_PORT
  validate_hy2_env_vars

  # 幂等清理早期版本遗留的孤立文件
  rm -f /etc/ssctl/ssh_port

  if [[ "${1:-}" == "--post-deploy-sync" || "${1:-}" == "--prune-stale-ufw" ]]; then
    configure_vless_conn_guard
    configure_hy2_port_hopping
    prune_stale_ufw_rules
    return 0
  fi

  log_info "安装基础依赖组件 (ufw, ca-certificates, curl)..."
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1
  apt-get update -qq
  apt-get install -y -qq ufw ca-certificates curl

  configure_ufw
  if [[ "${SSCTL_DEFER_UFW_PRUNE:-false}" != "true" ]]; then
    configure_vless_conn_guard
    configure_hy2_port_hopping
  fi
  configure_ntp

  log_info "防火墙收敛、连接防护与时钟同步完成 (10-harden 完成)。"
}

main "$@"
