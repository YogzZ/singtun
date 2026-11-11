#!/usr/bin/env bash
# scripts/20-optimize.sh — 内核网络与日志优化（BBR + fq、文件句柄、TCP/UDP 缓冲区与 journald 限额，幂等）
# 兼容 LXC / OpenVZ 等容器型 VPS：单项参数不可写或内核不支持 BBR 时仅告警，不中断部署。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

SYSCTL_FILE="/etc/sysctl.d/99-ssctl.conf"
LIMITS_FILE="/etc/security/limits.d/99-ssctl.conf"
BBR_MODULE_FILE="/etc/modules-load.d/ssctl-bbr.conf"
JOURNALD_DROPIN_FILE="/etc/systemd/journald.conf.d/99-ssctl.conf"

# 尝试启用 BBR 模块；返回 0 表示内核可用 bbr
ensure_bbr_available() {
  local avail_file="/proc/sys/net/ipv4/tcp_available_congestion_control"
  if [[ -r "${avail_file}" ]] && grep -qw bbr "${avail_file}"; then
    return 0
  fi
  if command -v modprobe >/dev/null 2>&1 && modprobe tcp_bbr 2>/dev/null; then
    printf 'tcp_bbr\n' > "${BBR_MODULE_FILE}"
  fi
  [[ -r "${avail_file}" ]] && grep -qw bbr "${avail_file}"
}

main() {
  require_root
  acquire_ssctl_lock
  detect_os >/dev/null
  detect_arch >/dev/null
  load_env

  log_info "开始配置内核网络与资源优化参数 (20-optimize)..."

  local virt="none"
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    virt="$(systemd-detect-virt --container 2>/dev/null || true)"
    [[ -z "${virt}" ]] && virt="none"
  fi
  if [[ "${virt}" != "none" ]]; then
    log_warn "检测到容器虚拟化环境 (${virt})：部分内核参数可能由宿主机控制，无法修改的项将跳过。"
  fi

  local -a settings=()
  if ensure_bbr_available; then
    settings+=("net.core.default_qdisc=fq" "net.ipv4.tcp_congestion_control=bbr")
  else
    log_warn "当前内核不支持或不允许启用 BBR，保持系统默认拥塞控制算法。"
  fi
  settings+=(
    "fs.file-max=1048576"
    "net.core.rmem_max=26214400"
    "net.core.wmem_max=26214400"
    "net.core.rmem_default=262144"
    "net.core.wmem_default=262144"
    "net.core.netdev_max_backlog=16384"
    "net.ipv4.tcp_rmem=4096 87380 26214400"
    "net.ipv4.tcp_wmem=4096 65536 26214400"
    "net.ipv4.tcp_fastopen=3"
    "net.ipv4.tcp_mtu_probing=1"
  )

  # 逐项应用：仅将实际写入成功的参数持久化，避免重启时 sysctl 报错
  local -a applied=()
  local kv key val skipped=0
  for kv in "${settings[@]}"; do
    key="${kv%%=*}"
    val="${kv#*=}"
    if sysctl -q -w "${key}=${val}" >/dev/null 2>&1; then
      applied+=("${key} = ${val}")
    else
      log_warn "无法设置内核参数 ${key}（可能为容器限制或内核不支持），已跳过。"
      skipped=$((skipped + 1))
    fi
  done

  {
    printf '# Managed by ssctl (20-optimize.sh)\n'
    printf '# BBR + fq、文件句柄、UDP/TCP 缓冲区（仅包含本机实际可写入的参数）\n'
    if (( ${#applied[@]} > 0 )); then
      printf '%s\n' "${applied[@]}"
    fi
  } > "${SYSCTL_FILE}"

  mkdir -p /etc/security/limits.d
  cat > "${LIMITS_FILE}" <<'EOF'
# Managed by ssctl (20-optimize.sh)
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

  mkdir -p "$(dirname "${JOURNALD_DROPIN_FILE}")"
  cat > "${JOURNALD_DROPIN_FILE}" <<'EOF'
# Managed by ssctl (20-optimize.sh) — 低配 VPS 日志体积上限与自动过期保护
[Journal]
SystemMaxUse=64M
RuntimeMaxUse=32M
MaxRetentionSec=7day
EOF
  if command -v systemctl >/dev/null 2>&1; then
    systemctl kill --kill-who=main --signal=SIGUSR2 systemd-journald >/dev/null 2>&1 || true
  fi

  local current_cc
  current_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")"
  log_info "当前 TCP 拥塞控制算法: ${current_cc}；已应用 ${#applied[@]} 项参数，跳过 ${skipped} 项。"
  log_info "内核与系统优化完成 (20-optimize 完成)。"
}

main "$@"
