#!/usr/bin/env bash
# scripts/30-cert.sh — acme.sh + Cloudflare DNS-01 证书签发、安装与续期自动重载
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# 官方 Release 固定版本与归档 SHA256
# 获取日期: 2026-11-09
# 获取方法: curl -fsSL https://github.com/acmesh-official/acme.sh/archive/refs/tags/3.1.0.tar.gz | sha256sum
ACME_VERSION="3.1.0"
ACME_TARBALL_SHA256="5bc8a72095e16a1a177d1a516728bbd3436abf8060232d5d36b462fce74447aa"
ACME_HOME="/root/.acme.sh"
ACME_BIN="${ACME_HOME}/acme.sh"
CERT_DIR="/etc/ssctl/cert"
FULLCHAIN_PATH="${CERT_DIR}/fullchain.pem"
KEY_PATH="${CERT_DIR}/key.pem"
SERVICE_GROUP="sing-box"
CERT_RELOAD_HOOK="/usr/local/libexec/ssctl-cert-reload"

ensure_service_group() {
  if ! getent group "${SERVICE_GROUP}" >/dev/null 2>&1; then
    groupadd --system "${SERVICE_GROUP}"
  fi
}

verify_acme_tarball() {
  local tarball="$1"
  local expected_sha="$2"

  if [[ -z "${expected_sha}" || ! "${expected_sha}" =~ ^[0-9a-fA-F]{64}$ ]]; then
    die "ACME_TARBALL_SHA256 未设置或格式非法，拒绝无校验安装 acme.sh！"
  fi

  local actual_sha
  actual_sha="$(sha256sum "${tarball}" | awk '{print tolower($1)}')"
  if [[ "${actual_sha}" != "${expected_sha,,}" ]]; then
    die "acme.sh v${ACME_VERSION} 归档 SHA256 校验失败！预期: ${expected_sha,,}，实际: ${actual_sha}"
  fi
}

install_reload_hook() {
  mkdir -p "$(dirname "${CERT_RELOAD_HOOK}")"
  cat > "${CERT_RELOAD_HOOK}" <<EOF
#!/usr/bin/env bash
# Managed by ssctl (30-cert.sh) — 证书续期自动重载钩子
set -euo pipefail

log_reload_err() {
  local msg="\$1"
  printf '[ssctl-cert-reload] ERROR: %s\n' "\${msg}" >&2
  if command -v logger >/dev/null 2>&1; then
    logger -t ssctl-cert-reload -p daemon.err "\${msg}" || true
  fi
}

chown root:${SERVICE_GROUP} "${FULLCHAIN_PATH}" "${KEY_PATH}"
chmod 644 "${FULLCHAIN_PATH}"
chmod 640 "${KEY_PATH}"

# 首次部署时 30-cert.sh 先于 40-deploy-server.sh 运行，此时 nginx 尚未启用；启用后重载失败必须显式返回非零并记入系统错误日志
if systemctl is-active --quiet nginx 2>/dev/null || systemctl is-enabled --quiet nginx 2>/dev/null; then
  if ! systemctl reload nginx; then
    log_reload_err "systemctl reload nginx 失败（新证书未能加载至 Nginx）"
    exit 1
  fi
fi

# REALITY 模式下 sing-box 不读取证书；仅当已部署 Hysteria2 等读取证书的入站时才重启 sing-box
if grep -qs '"type":[[:space:]]*"hysteria2"' /etc/sing-box/*.json 2>/dev/null; then
  if ! systemctl restart sing-box; then
    log_reload_err "systemctl restart sing-box 失败（Hysteria2 新证书未能加载）"
    exit 1
  fi
fi
EOF
  chown root:root "${CERT_RELOAD_HOOK}"
  chmod 755 "${CERT_RELOAD_HOOK}"
}

run_acme_bin() {
  local bin_path="$1"
  shift
  # 清理 sudo 透传环境变量并固定 HOME=/root，防止 sudo ./ssctl deploy / renew 被 acme.sh 拒绝
  env -u SUDO_USER -u SUDO_UID -u SUDO_GID -u SUDO_COMMAND HOME="/root" "${bin_path}" "$@"
}

run_acme() {
  run_acme_bin "${ACME_BIN}" --home "${ACME_HOME}" "$@"
}

install_acme_sh() {
  if [[ -x "${ACME_BIN}" ]]; then
    if command -v systemctl >/dev/null 2>&1; then
      systemctl enable --now cron >/dev/null 2>&1 || true
    fi
    if command -v crontab >/dev/null 2>&1 && ! crontab -l 2>/dev/null | grep -Fq "acme.sh"; then
      run_acme --install-cronjob >/dev/null 2>&1 || true
    fi
    log_info "acme.sh 已安装: $( run_acme --version | tr '\n' ' ' )"
    return 0
  fi

  log_info "从官方 GitHub Release 下载并校验 acme.sh v${ACME_VERSION}..."
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1
  apt-get install -y -qq curl ca-certificates openssl cron socat
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now cron >/dev/null 2>&1 || true
  fi

  local tmp_dir
  make_temp_dir tmp_dir

  local tarball="${tmp_dir}/acme.sh.tar.gz"
  local download_url="https://github.com/acmesh-official/acme.sh/archive/refs/tags/${ACME_VERSION}.tar.gz"
  curl -fsSL "${download_url}" -o "${tarball}"

  verify_acme_tarball "${tarball}" "${ACME_TARBALL_SHA256}"

  tar -xzf "${tarball}" -C "${tmp_dir}"
  (
    cd "${tmp_dir}/acme.sh-${ACME_VERSION}"
    run_acme_bin ./acme.sh --install \
      --home "${ACME_HOME}" \
      --accountemail "${ACME_EMAIL}" \
      --nocron
  )

  run_acme --install-cronjob
  run_acme --set-default-ca --server letsencrypt
  log_info "acme.sh v${ACME_VERSION} 校验并安装完成。"
}

acme_account_apply_ops() {
  local account_conf="$1"
  shift
  [[ -f "${account_conf}" ]] || return 0

  local account_dir work_file step_file
  account_dir="$(dirname "${account_conf}")"
  work_file="$(mktemp "${account_dir}/.account.conf.tmp.XXXXXX")"
  chmod 600 "${work_file}"
  register_cleanup_path "${work_file}"
  make_temp_file step_file

  cp -f "${account_conf}" "${work_file}"
  chmod 600 "${work_file}"

  local spec op rest key val
  for spec in "$@"; do
    op="${spec%%:*}"
    rest="${spec#*:}"
    case "${op}" in
      SET)
        key="${rest%%=*}"
        val="${rest#*=}"
        K="${key}" V="${val}" awk '
          BEGIN {
            k = ENVIRON["K"]
            v = ENVIRON["V"]
            done = 0
            pat = "^[[:space:]]*(export[[:space:]]+)?" k "="
          }
          $0 ~ pat {
            if (!done) {
              print k "=" v
              done = 1
            }
            next
          }
          { print }
          END {
            if (!done) {
              print k "=" v
            }
          }
        ' "${work_file}" > "${step_file}"
        chmod 600 "${step_file}"
        mv -f "${step_file}" "${work_file}"
        make_temp_file step_file
        ;;
      DEL)
        key="${rest}"
        K="${key}" awk '
          BEGIN {
            k = ENVIRON["K"]
            pat = "^[[:space:]]*(export[[:space:]]+)?" k "="
          }
          $0 !~ pat { print }
        ' "${work_file}" > "${step_file}"
        chmod 600 "${step_file}"
        mv -f "${step_file}" "${work_file}"
        make_temp_file step_file
        ;;
      *)
        rm -f -- "${work_file}" "${step_file}"
        die "acme_account_apply_ops 未知操作指令: ${spec}"
        ;;
    esac
  done

  chmod 600 "${work_file}"
  mv -f "${work_file}" "${account_conf}"
  chmod 600 "${account_conf}"
}

sync_acme_cf_token() {
  local account_conf="${ACME_HOME}/account.conf"
  if [[ -f "${account_conf}" && -n "${CF_API_TOKEN:-}" ]]; then
    local escaped_tok="'${CF_API_TOKEN//\'/\'\\\'\'}'"
    acme_account_apply_ops "${account_conf}" "SET:SAVED_CF_Token=${escaped_tok}"
  fi
}

configure_acme_notify() {
  local account_conf="${ACME_HOME}/account.conf"
  if [[ -n "${ACME_NOTIFY_HOOK:-}" ]]; then
    if ! is_valid_acme_notify_hook "${ACME_NOTIFY_HOOK}"; then
      die "ACME_NOTIFY_HOOK 格式非法（仅允许小写字母、数字、下划线及逗号分隔的官方钩子名）: ${ACME_NOTIFY_HOOK}"
    fi
    log_info "配置 acme.sh 续期告警通知钩子 (${ACME_NOTIFY_HOOK})..."
    run_acme --set-notify --notify-hook "${ACME_NOTIFY_HOOK}"
  elif [[ -f "${account_conf}" ]] && grep -Eq '^[[:space:]]*(export[[:space:]]+)?SAVED_NOTIFY_HOOK=' "${account_conf}"; then
    log_info "检测到 ACME_NOTIFY_HOOK 已留空，正在清理 acme.sh 历史通知钩子配置..."
    acme_account_apply_ops "${account_conf}" \
      "DEL:SAVED_NOTIFY_HOOK" \
      "DEL:SAVED_NOTIFY_LEVEL" \
      "DEL:SAVED_NOTIFY_MODE" \
      "DEL:SAVED_NOTIFY_SOURCE"
  fi
}

cert_is_valid() {
  if [[ ! -s "${FULLCHAIN_PATH}" || ! -s "${KEY_PATH}" ]]; then
    return 1
  fi
  # 检查证书是否包含目标域名且距过期大于 30 天 (2592000 秒)
  if ! openssl x509 -in "${FULLCHAIN_PATH}" -noout -checkend 2592000 >/dev/null 2>&1; then
    return 1
  fi
  local escaped_domain="${SERVER_DOMAIN//./\\.}"
  if ! openssl x509 -in "${FULLCHAIN_PATH}" -noout -ext subjectAltName 2>/dev/null \
    | grep -Eq "(^|[[:space:],])DNS:${escaped_domain}($|[[:space:],])"; then
    return 1
  fi
  return 0
}

fix_cert_permissions() {
  mkdir -p "${CERT_DIR}"
  chown root:"${SERVICE_GROUP}" "${CERT_DIR}"
  chmod 750 "${CERT_DIR}"
  if [[ -f "${FULLCHAIN_PATH}" ]]; then
    chown root:"${SERVICE_GROUP}" "${FULLCHAIN_PATH}"
    chmod 644 "${FULLCHAIN_PATH}"
  fi
  if [[ -f "${KEY_PATH}" ]]; then
    chown root:"${SERVICE_GROUP}" "${KEY_PATH}"
    chmod 640 "${KEY_PATH}"
  fi
}

install_cert_via_acme() {
  local tmp_dir log_file
  make_temp_dir tmp_dir
  log_file="${tmp_dir}/install-cert.log"
  # 同时拦截 acme.sh v3.1.0 的非零返回码与 "Reload error for" 错误输出（兼容新旧行为）
  if ! run_acme --install-cert -d "${SERVER_DOMAIN}" --ecc \
    --fullchain-file "${FULLCHAIN_PATH}" \
    --key-file "${KEY_PATH}" \
    --reloadcmd "${CERT_RELOAD_HOOK}" 2>&1 | tee "${log_file}"; then
    die "acme.sh --install-cert 安装证书或执行重载钩子失败！"
  fi
  if grep -Fq "Reload error for" "${log_file}"; then
    die "证书已写入，但服务重载钩子 (${CERT_RELOAD_HOOK}) 执行失败！"
  fi
}

main() {
  local force_renew="false"
  if [[ "${1:-}" == "--force" ]]; then
    force_renew="true"
  fi

  require_root
  acquire_ssctl_lock
  detect_os >/dev/null
  detect_arch >/dev/null
  load_env
  require_vars SERVER_DOMAIN ACME_EMAIL CF_API_TOKEN
  if ! is_valid_domain "${SERVER_DOMAIN}"; then
    die "SERVER_DOMAIN 不是合法的小写域名: ${SERVER_DOMAIN}"
  fi
  if ! is_valid_email "${ACME_EMAIL}"; then
    die "ACME_EMAIL 不是合法的邮箱地址: ${ACME_EMAIL}"
  fi

  ensure_service_group
  install_reload_hook
  install_acme_sh
  sync_acme_cf_token
  configure_acme_notify

  if [[ "${force_renew}" == "false" ]] && cert_is_valid; then
    local domain_conf="${ACME_HOME}/${SERVER_DOMAIN}_ecc/${SERVER_DOMAIN}.conf"
    local reload_b64
    reload_b64="$(printf '%s' "${CERT_RELOAD_HOOK}" | base64 | tr -d '\n')"
    if [[ -f "${domain_conf}" ]] \
      && ! grep -Fq "${CERT_RELOAD_HOOK}" "${domain_conf}" \
      && ! grep -Fq "${reload_b64}" "${domain_conf}"; then
      log_info "更新已有证书的续期重载钩子为按需重载模式..."
      install_cert_via_acme
    else
      log_info "证书已存在且有效 (${FULLCHAIN_PATH})，跳过重新签发。"
    fi
    fix_cert_permissions
    return 0
  fi

  export CF_Token="${CF_API_TOKEN}"
  local issue_args=(
    --issue
    --dns dns_cf
    -d "${SERVER_DOMAIN}"
    --keylength ec-256
    --server letsencrypt
  )
  if [[ "${force_renew}" == "true" ]]; then
    issue_args+=(--force)
  fi

  log_info "正在通过 Cloudflare DNS-01 为 ${SERVER_DOMAIN} 申请 Let's Encrypt ECC 证书..."
  # acme.sh 在证书未到期且未传 --force 时可能返回 2（代表跳过），属于正常情况
  local rc=0
  run_acme "${issue_args[@]}" || rc=$?
  if (( rc != 0 && rc != 2 )); then
    die "acme.sh 证书签发失败 (exit code: ${rc})"
  fi

  mkdir -p "${CERT_DIR}"
  log_info "正在安装证书至 ${CERT_DIR} 并注册自动重载钩子..."
  install_cert_via_acme

  fix_cert_permissions
  log_info "证书签发与安装完成 (30-cert 完成)。"
}

main "$@"
