#!/usr/bin/env bash
# scripts/00-preflight.sh — 系统环境、配置项合法性、软链隔离、DNS/DoH 连通性与端口冲突预检
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

check_nginx_conflicts() {
  if [[ -d "/www/server/nginx" || -x "/usr/local/nginx/sbin/nginx" ]]; then
    die "检测到非系统 APT 管理的 Nginx 目录（如宝塔 /www/server/nginx 或自编译 /usr/local/nginx），为避免破坏现有环境已中止部署。"
  fi

  if command -v nginx >/dev/null 2>&1; then
    local nginx_bin
    nginx_bin="$(readlink -f "$(command -v nginx)" 2>/dev/null || command -v nginx)"
    if [[ "${nginx_bin}" != "/usr/sbin/nginx" ]]; then
      die "当前 PATH 中的 nginx (${nginx_bin}) 非系统官方包 (/usr/sbin/nginx)，请先移除第三方 Nginx 冲突。"
    fi
  fi
}

check_docker_ufw_bypass() {
  if command -v docker >/dev/null 2>&1 || systemctl is-active --quiet docker 2>/dev/null; then
    log_warn "检测到本机已安装 Docker：Docker 发布端口（-p 0.0.0.0:...）会直接写 iptables/nftables 并绕过 UFW。运行容器时请仅绑定 127.0.0.1，或在 DOCKER-USER 链中限制入站。"
  fi
}

check_low_memory_swap() {
  [[ -r /proc/meminfo ]] || return 0
  local mem_kb swap_kb
  mem_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo "")"
  swap_kb="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo "")"
  if [[ "${mem_kb}" =~ ^[0-9]+$ && "${swap_kb}" =~ ^[0-9]+$ ]]; then
    if (( mem_kb < 786432 && swap_kb == 0 )); then
      log_warn "检测到物理内存低于 768 MiB ($(( mem_kb / 1024 )) MiB) 且未启用 Swap：在执行 apt 更新或并发校验时可能触发 OOM，建议配置 512M–1G Swap。"
    fi
  fi
}

check_public_ip_consistency() {
  local matched="false"
  if command -v ip >/dev/null 2>&1; then
    if ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "${SERVER_IP}"; then
      matched="true"
    fi
  fi

  if [[ "${matched}" == "false" ]] && command -v curl >/dev/null 2>&1; then
    local egress_ip=""
    egress_ip="$(curl -4 -fsSL --max-time 4 https://api.ipify.org 2>/dev/null || true)"
    if [[ -n "${egress_ip}" ]]; then
      if [[ "${egress_ip}" == "${SERVER_IP}" ]]; then
        matched="true"
      else
        log_warn "本机探测公网出口 IPv4 (${egress_ip}) 与 SERVER_IP (${SERVER_IP}) 不一致！请确认未填错服务器 IP。"
        return 0
      fi
    fi
  fi

  if [[ "${matched}" == "false" ]]; then
    log_warn "本机网卡未直接绑定 SERVER_IP (${SERVER_IP})；若服务器位于云厂商 1:1 NAT 后属正常现象，否则请核对 SERVER_IP。"
  fi
}

verify_doh_rfc8484_endpoint() {
  local label="$1"
  local ip="$2"
  if ! command -v curl >/dev/null 2>&1; then
    log_warn "未安装 curl，跳过 ${label} (https://${ip}/dns-query) 的 RFC 8484 DoH 联网查询校验。"
    return 0
  fi

  local tmp_dir resp_file http_code
  make_temp_dir tmp_dir
  resp_file="${tmp_dir}/doh.bin"

  # RFC 8484 Wireformat GET: ID=0x0000, RD=1, QNAME=example.com., QTYPE=A, QCLASS=IN
  local q_b64url="AAABAAABAAAAAAAAB2V4YW1wbGUDY29tAAABAAE"
  http_code="$(curl -fsS --max-time 8 \
    -H 'Accept: application/dns-message' \
    "https://${ip}/dns-query?dns=${q_b64url}" \
    -o "${resp_file}" -w '%{http_code}' 2>/dev/null || echo "000")"

  if [[ "${http_code}" != "200" || ! -s "${resp_file}" ]]; then
    die "${label} 加密 DoH 端点 (https://${ip}/dns-query) 联网查询失败 (HTTP ${http_code})！请检查网络连通性与 TLS IP-SAN 证书验证。"
  fi

  local -a hdr_bytes=()
  read -r -a hdr_bytes < <(od -An -tu1 -N 12 "${resp_file}" 2>/dev/null | tr -s ' \n' ' '; printf '\n')
  if (( ${#hdr_bytes[@]} < 12 )); then
    die "${label} 加密 DoH 端点 (https://${ip}/dns-query) 返回报文长度不足 12 字节，非合法 DNS 响应。"
  fi

  local flags_hi="${hdr_bytes[2]}"
  local flags_lo="${hdr_bytes[3]}"
  local ancount=$(( (hdr_bytes[6] << 8) + hdr_bytes[7] ))
  local qr=$(( (flags_hi >> 7) & 1 ))
  local rcode=$(( flags_lo & 15 ))

  if (( qr != 1 || rcode != 0 || ancount < 1 )); then
    die "${label} 加密 DoH 端点 (https://${ip}/dns-query) DNS 响应异常 (QR=${qr}, RCODE=${rcode}, ANCOUNT=${ancount})！"
  fi
  log_info "${label} 加密 DoH 联网查询校验通过: https://${ip}/dns-query (HTTP 200, RCODE=NOERROR, ANCOUNT=${ancount})"
}

main() {
  log_info "开始执行部署前环境预检 (00-preflight)..."

  # 1. 系统与架构检查（check 模式下支持跳过宿主系统限制）
  if [[ "${SKIP_OS_CHECK:-false}" == "true" ]]; then
    log_info "已通过 SKIP_OS_CHECK=true 跳过宿主操作系统与架构检查。"
  else
    local os_id arch_id
    os_id="$(detect_os)"
    arch_id="$(detect_arch)"
    log_info "操作系统与架构检测通过: ${os_id} (${arch_id})"
  fi

  # 2. 加载并检查必填环境变量
  load_env
  require_vars \
    SINGBOX_VERSION \
    SERVER_IP \
    SERVER_DOMAIN \
    SERVER_IPV6 \
    ACME_EMAIL \
    CF_API_TOKEN \
    VLESS_PORT \
    REALITY_HANDSHAKE_PORT \
    REALITY_PRIVATE_KEY \
    REALITY_PUBLIC_KEY \
    REALITY_SHORT_ID \
    UTLS_FINGERPRINT \
    SUB_PATH_PREFIX \
    DNS_DIRECT \
    DNS_REMOTE \
    RULESET_GEOSITE_CN \
    RULESET_GEOIP_CN

  # 3. 校验版本号、客户端兼容开关与布尔开关
  if ! is_valid_semver "${SINGBOX_VERSION}"; then
    die "SINGBOX_VERSION 格式非法（须形如 x.y.z）: ${SINGBOX_VERSION}"
  fi

  local client_compat="${SINGBOX_CLIENT_COMPAT:-1.14}"
  if ! is_valid_singbox_compat "${client_compat}"; then
    die "SINGBOX_CLIENT_COMPAT 仅支持 1.14 或 1.12: ${client_compat}"
  fi

  local enable_sub="${ENABLE_SUBSCRIPTION:-true}"
  if ! is_valid_bool "${enable_sub}"; then
    die "ENABLE_SUBSCRIPTION 必须为 true 或 false: ${enable_sub}"
  fi

  if is_characteristic_sub_prefix "${SUB_PATH_PREFIX}"; then
    die "SUB_PATH_PREFIX 不得以明显特征词开头 (${SUB_PATH_PREFIX})，请通过 './ssctl init' 使用随机前缀。"
  fi
  if ! is_valid_sub_prefix "${SUB_PATH_PREFIX}"; then
    die "SUB_PATH_PREFIX 格式非法（须为 12-32 位小写字母数字随机串，严禁含斜杠或特殊字符）: ${SUB_PATH_PREFIX}"
  fi

  if [[ -n "${SINGBOX_DEB_SHA256_AMD64:-}" ]] && ! is_valid_sha256 "${SINGBOX_DEB_SHA256_AMD64}"; then
    die "SINGBOX_DEB_SHA256_AMD64 格式非法（须为 64 位十六进制 SHA256）: ${SINGBOX_DEB_SHA256_AMD64}"
  fi
  if [[ -n "${SINGBOX_DEB_SHA256_ARM64:-}" ]] && ! is_valid_sha256 "${SINGBOX_DEB_SHA256_ARM64}"; then
    die "SINGBOX_DEB_SHA256_ARM64 格式非法（须为 64 位十六进制 SHA256）: ${SINGBOX_DEB_SHA256_ARM64}"
  fi

  if ! is_valid_bool "${SERVER_IPV6}"; then
    die "SERVER_IPV6 必须为 true 或 false: ${SERVER_IPV6}"
  fi

  local server_log_level="${SERVER_LOG_LEVEL:-warn}"
  if ! is_valid_log_level "${server_log_level}"; then
    die "SERVER_LOG_LEVEL 格式非法（须为 trace|debug|info|warn|error|fatal|panic）: ${server_log_level}"
  fi
  if [[ "${server_log_level}" =~ ^(trace|debug|info)$ ]]; then
    log_warn "当前 SERVER_LOG_LEVEL=${server_log_level} 会将访问的目标域名持久记录到 systemd journal；排障结束后建议改回 warn。"
  fi

  local enable_hy2="${ENABLE_HY2:-false}"
  validate_hy2_env_vars

  # 4. 校验 IP、DNS、端口、跳跃范围、REALITY 参数与各订阅凭据
  if ! is_valid_ipv4 "${SERVER_IP}"; then
    die "SERVER_IP 不是合法的 IPv4 地址: ${SERVER_IP}"
  fi
  local reject_doc_ip="false"
  if [[ "${SKIP_OS_CHECK:-false}" != "true" && "${SKIP_DNS_CHECK:-false}" != "true" ]]; then
    reject_doc_ip="true"
  fi
  if is_non_public_ipv4 "${SERVER_IP}" "${reject_doc_ip}"; then
    die "SERVER_IP 不能为内网、回环、保留或文档示例地址: ${SERVER_IP}"
  fi
  if ! is_valid_domain "${SERVER_DOMAIN}"; then
    die "SERVER_DOMAIN 不是合法的小写域名（如 node.example.com）: ${SERVER_DOMAIN}"
  fi
  if ! is_valid_email "${ACME_EMAIL}"; then
    die "ACME_EMAIL 不是合法的邮箱地址: ${ACME_EMAIL}"
  fi
  if [[ -n "${ACME_NOTIFY_HOOK:-}" ]] && ! is_valid_acme_notify_hook "${ACME_NOTIFY_HOOK}"; then
    die "ACME_NOTIFY_HOOK 格式非法（仅允许小写字母、数字、下划线及逗号分隔的官方钩子名）: ${ACME_NOTIFY_HOOK}"
  fi
  validate_dns_doh_env_vars
  validate_ruleset_urls

  local rs_var rs_val
  for rs_var in RULESET_GEOSITE_CN RULESET_GEOIP_CN RULESET_MIHOMO_GEOSITE_CN RULESET_MIHOMO_GEOIP_CN RULESET_SR_CN_DOMAIN; do
    rs_val="${!rs_var:-}"
    [[ -z "${rs_val}" ]] && continue
    if ! is_immutable_ruleset_url "${rs_val}"; then
      log_warn "${rs_var} 当前使用可变分支或未固定 40 位 Commit SHA (${rs_val})；高安全场景建议固定 Commit SHA 防止上游规则分支被投毒。"
    fi
  done

  if [[ -d "${PRIVATE_DIR}/www" ]]; then
    local bad_www_link=""
    bad_www_link="$(find "${PRIVATE_DIR}/www" -type l -print -quit 2>/dev/null || true)"
    if [[ -n "${bad_www_link}" ]]; then
      die "安全拦截：自定义静态站点目录 (${PRIVATE_DIR}/www) 内禁止包含符号链接 (${bad_www_link})！"
    fi
  fi

  local port_var
  for port_var in VLESS_PORT REALITY_HANDSHAKE_PORT; do
    if ! is_valid_port "${!port_var}"; then
      die "${port_var} 不是合法端口号 (1-65535): ${!port_var}"
    fi
  done

  if [[ "${VLESS_PORT}" == "${REALITY_HANDSHAKE_PORT}" ]]; then
    die "VLESS_PORT (${VLESS_PORT}) 不能与 REALITY_HANDSHAKE_PORT (${REALITY_HANDSHAKE_PORT}) 相同"
  fi

  if ! is_valid_reality_key "${REALITY_PRIVATE_KEY}"; then
    die "REALITY_PRIVATE_KEY 格式非法（须为 43 位 URL-safe Base64 X25519 私钥）"
  fi
  if ! is_valid_reality_key "${REALITY_PUBLIC_KEY}"; then
    die "REALITY_PUBLIC_KEY 格式非法（须为 43 位 URL-safe Base64 X25519 公钥）"
  fi
  if command -v openssl >/dev/null 2>&1; then
    local expected_reality_pub=""
    if ! expected_reality_pub="$(derive_reality_public_key "${REALITY_PRIVATE_KEY}")"; then
      die "无法由 REALITY_PRIVATE_KEY 派生 X25519 公钥，请检查私钥格式是否有效！"
    fi
    if [[ "${REALITY_PUBLIC_KEY}" != "${expected_reality_pub}" ]]; then
      die "REALITY_PUBLIC_KEY 与 REALITY_PRIVATE_KEY 不匹配（当前: ${REALITY_PUBLIC_KEY}，预期: ${expected_reality_pub}）；请修正或清空 REALITY_PUBLIC_KEY 后重跑 ./ssctl init 自动修复。"
    fi
  fi
  if ! is_valid_utls_fingerprint "${UTLS_FINGERPRINT}"; then
    die "UTLS_FINGERPRINT 不在受支持的指纹列表内 (chrome|firefox|edge|safari|360|qq|ios|android|random|randomized): ${UTLS_FINGERPRINT}"
  fi
  if ! is_valid_short_id "${REALITY_SHORT_ID}"; then
    die "REALITY_SHORT_ID 必须为 2-16 位偶数长度十六进制字符串: ${REALITY_SHORT_ID}"
  fi

  local sub sub_count=0 sub_uuid sub_tok
  local -A seen_subs=()
  local -A seen_uuids=()
  local -A seen_tokens=()
  local -A active_suffixes=()
  while IFS= read -r sub; do
    [[ -z "${sub}" ]] && continue
    if is_reserved_sub_name "${sub}"; then
      die "订阅名 '${sub}' 为系统保留字，请更换其他名称。"
    fi
    if ! is_valid_sub_name "${sub}"; then
      die "订阅名 '${sub}' 格式非法（仅允许小写字母、数字与非首尾短横线，长度 1-32）"
    fi
    if [[ -n "${seen_subs[${sub}]:-}" ]]; then
      die "SUBSCRIPTIONS 中存在重复订阅名: ${sub}"
    fi
    seen_subs["${sub}"]=1
    active_suffixes["$(sub_env_suffix "${sub}")"]=1

    sub_uuid="$(get_sub_uuid "${sub}")"
    sub_tok="$(get_sub_token "${sub}")"
    if [[ -n "${seen_uuids[${sub_uuid}]:-}" ]]; then
      die "订阅 '${sub}' 与其他订阅共用了相同的 UUID (${sub_uuid})，请保持每条订阅独立凭据！"
    fi
    if [[ -n "${seen_tokens[${sub_tok}]:-}" ]]; then
      die "订阅 '${sub}' 与其他订阅共用了相同的 SUB_TOKEN，请保持每条订阅独立令牌！"
    fi
    seen_uuids["${sub_uuid}"]=1
    seen_tokens["${sub_tok}"]=1
    sub_count=$((sub_count + 1))
  done < <(list_subscriptions)

  # 检查 .env 中是否存在未归属任何活跃订阅的孤立 UUID_* / SUB_TOKEN_* 变量
  if [[ -f "${ENV_FILE}" ]]; then
    local env_key sfx
    while IFS= read -r env_key; do
      [[ -z "${env_key}" ]] && continue
      case "${env_key}" in
        UUID_*)
          sfx="${env_key#UUID_}"
          ;;
        SUB_TOKEN_*)
          sfx="${env_key#SUB_TOKEN_}"
          ;;
        SSH_PORT)
          log_warn "${ENV_FILE} 中存在已废弃的历史键 SSH_PORT（当前由 10-harden.sh 自动探测活跃 SSH 监听端口），建议移除。"
          continue
          ;;
        *)
          continue
          ;;
      esac
      if [[ -z "${active_suffixes[${sfx}]:-}" ]]; then
        log_warn "${ENV_FILE} 中存在不属于当前 SUBSCRIPTIONS 的孤立变量 ${env_key}，建议清理避免后续命名冲突。"
      fi
    done < <(list_env_file_keys "${ENV_FILE}")
  fi

  if (( sub_count == 0 )); then
    log_info "当前 SUBSCRIPTIONS 为空（零预设用户待机）；部署完成后可通过 'sudo ./ssctl add [name]' 按需创建订阅。"
  else
    log_info "已校验 ${sub_count} 条订阅的名称、独立 UUID 与 256-bit 订阅令牌合法。"
  fi

  # 5. 校验域名 A 记录是否指向 SERVER_IP（确保 Cloudflare 为 DNS only）
  if [[ "${SKIP_DNS_CHECK:-false}" == "true" ]]; then
    log_warn "已通过 SKIP_DNS_CHECK=true 跳过域名解析检查。"
  else
    local resolved_ips=""
    if command -v dig >/dev/null 2>&1; then
      resolved_ips="$(dig +short A "${SERVER_DOMAIN}" @1.1.1.1 2>/dev/null | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true)"
    fi
    if [[ -z "${resolved_ips}" ]] && command -v getent >/dev/null 2>&1; then
      resolved_ips="$(getent ahostsv4 "${SERVER_DOMAIN}" 2>/dev/null | awk '{print $1}' | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true)"
    fi
    if [[ -z "${resolved_ips}" ]] && command -v host >/dev/null 2>&1; then
      resolved_ips="$(host -t A "${SERVER_DOMAIN}" 2>/dev/null | awk '/has address/ {print $4}' | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true)"
    fi

    if [[ -z "${resolved_ips}" ]] && ! command -v dig >/dev/null 2>&1 && ! command -v getent >/dev/null 2>&1 && ! command -v host >/dev/null 2>&1; then
      log_warn "未找到 dig / getent / host，无法自动核验 ${SERVER_DOMAIN} 的 DNS A 记录。"
    elif [[ -n "${resolved_ips}" ]]; then
      if [[ "${resolved_ips}" != "${SERVER_IP}" ]]; then
        die "域名 ${SERVER_DOMAIN} 当前 A 记录解析为 [${resolved_ips}]，与 SERVER_IP (${SERVER_IP}) 不一致！请确认 DNS 已生效且 Cloudflare Proxy 状态为 'DNS only'（灰色云朵）。"
      fi
      log_info "域名解析校验通过: ${SERVER_DOMAIN} -> ${SERVER_IP} (DNS only)"
    else
      die "无法解析域名 ${SERVER_DOMAIN} 的 A 记录，请先在 Cloudflare 添加指向 ${SERVER_IP} 的 A 记录（DNS only）。"
    fi

    verify_doh_rfc8484_endpoint "DNS_DIRECT" "${DNS_DIRECT}"
    verify_doh_rfc8484_endpoint "DNS_REMOTE" "${DNS_REMOTE}"

    if [[ "${SKIP_OS_CHECK:-false}" != "true" ]]; then
      check_public_ip_consistency
    fi
  fi

  # 6. 检查已有 Nginx/面板冲突、Docker 绕过 UFW 风险、低内存无 Swap 提示与端口占用（已被本项目 sing-box / nginx 占用视为正常）
  if [[ "${SKIP_OS_CHECK:-false}" != "true" ]]; then
    check_docker_ufw_bypass
    check_low_memory_swap
  fi

  if [[ "${SKIP_PORT_CHECK:-false}" != "true" ]]; then
    if [[ "${SKIP_OS_CHECK:-false}" != "true" ]]; then
      check_nginx_conflicts
    fi

    local ssh_p
    while IFS= read -r ssh_p; do
      [[ -z "${ssh_p}" ]] && continue
      if [[ "${VLESS_PORT}" == "${ssh_p}" || "${REALITY_HANDSHAKE_PORT}" == "${ssh_p}" ]]; then
        die "代理端口 (VLESS_PORT=${VLESS_PORT} / REALITY_HANDSHAKE_PORT=${REALITY_HANDSHAKE_PORT}) 与当前活跃 SSH 端口 (${ssh_p}) 冲突，已中止以防断开远程连接！"
      fi
    done < <(detect_active_ssh_ports)

    if command -v ss >/dev/null 2>&1; then
      local is_root="false"
      if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        is_root="true"
      fi

      local vless_listeners
      vless_listeners="$(ss -H -tlnp "sport = :${VLESS_PORT}" 2>/dev/null || true)"
      if [[ -n "${vless_listeners}" ]] && ! grep -q "sing-box" <<< "${vless_listeners}"; then
        if [[ "${is_root}" == "true" ]] || grep -q "users:((" <<< "${vless_listeners}" || ! systemctl is-active --quiet sing-box 2>/dev/null; then
          log_error "${vless_listeners}"
          die "TCP 端口 ${VLESS_PORT} 已被其他非 sing-box 进程占用（详情见上方输出）。"
        fi
      fi

      local handshake_listeners
      handshake_listeners="$(ss -H -tlnp "sport = :${REALITY_HANDSHAKE_PORT}" 2>/dev/null || true)"
      if [[ -n "${handshake_listeners}" ]] && ! grep -q "nginx" <<< "${handshake_listeners}"; then
        if [[ "${is_root}" == "true" ]] || grep -q "users:((" <<< "${handshake_listeners}" || ! systemctl is-active --quiet nginx 2>/dev/null; then
          log_error "${handshake_listeners}"
          die "TCP 端口 ${REALITY_HANDSHAKE_PORT} 已被其他非 nginx 进程占用（详情见上方输出）。"
        fi
      fi

      if [[ "${enable_hy2}" == "true" ]]; then
        local hy2_listeners
        hy2_listeners="$(ss -H -ulnp "sport = :${HY2_PORT}" 2>/dev/null || true)"
        if [[ -n "${hy2_listeners}" ]] && ! grep -q "sing-box" <<< "${hy2_listeners}"; then
          if [[ "${is_root}" == "true" ]] || grep -q "users:((" <<< "${hy2_listeners}" || ! systemctl is-active --quiet sing-box 2>/dev/null; then
            log_error "${hy2_listeners}"
            die "UDP 端口 ${HY2_PORT} 已被其他非 sing-box 进程占用（详情见上方输出）。"
          fi
        fi

        if [[ -n "${HY2_HOP_PORTS:-}" ]]; then
          local hop_start="${HY2_HOP_PORTS%-*}"
          local hop_end="${HY2_HOP_PORTS#*-}"
          local hop_conflicts=""
          hop_conflicts="$(
            ss -H -ulnp 2>/dev/null | awk -v s="${hop_start}" -v e="${hop_end}" '
              NF >= 4 {
                port = $4
                sub(/^.*:/, "", port)
                if (port ~ /^[0-9]+$/) {
                  p = port + 0
                  if (p >= s + 0 && p <= e + 0 && $0 !~ /sing-box/) {
                    print $0
                  }
                }
              }
            ' || true
          )"
          if [[ -n "${hop_conflicts}" ]]; then
            log_error "${hop_conflicts}"
            die "HY2_HOP_PORTS (${HY2_HOP_PORTS}) 跳跃范围内存在已被占用的本地 UDP 端口（详情见上方输出）。"
          fi
          log_info "端口可用性检查通过 (TCP ${VLESS_PORT}, 127.0.0.1:${REALITY_HANDSHAKE_PORT}, UDP ${HY2_PORT}, 跳跃 UDP ${HY2_HOP_PORTS})"
        else
          log_info "端口可用性检查通过 (TCP ${VLESS_PORT}, 127.0.0.1:${REALITY_HANDSHAKE_PORT}, UDP ${HY2_PORT})"
        fi
      else
        log_info "端口可用性检查通过 (TCP ${VLESS_PORT}, 127.0.0.1:${REALITY_HANDSHAKE_PORT})"
      fi
    fi
  fi

  # 7. 检查系统时间同步状态（REALITY 对时间差敏感）
  if [[ "${SKIP_OS_CHECK:-false}" != "true" ]] && command -v timedatectl >/dev/null 2>&1; then
    local ntp_sync
    ntp_sync="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo "unknown")"
    if [[ "${ntp_sync}" == "yes" ]]; then
      log_info "系统时钟同步状态正常 (NTPSynchronized=yes)"
    else
      log_warn "当前 NTPSynchronized=${ntp_sync}；将在 10-harden.sh 中启用 NTP 同步（REALITY 要求时钟误差在合理范围内）。"
    fi
  fi

  log_info "预检全部通过 (00-preflight 完成)。"
}

main "$@"
