#!/usr/bin/env bash
# scripts/lib/common.sh — 公共库：纯数据 .env 解析与原子写入、flock 互斥锁、临时目录清理、格式校验及订阅凭据派生
set -euo pipefail

if [[ "${SINGTUN_COMMON_LOADED:-}" == "true" ]]; then
  return 0
fi
SINGTUN_COMMON_LOADED="true"

# 定位仓库根目录
COMMON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${COMMON_LIB_DIR}/../.." && pwd)"
PRIVATE_DIR="${SINGTUN_PRIVATE_DIR:-${REPO_ROOT}/private}"
ENV_FILE="${SINGTUN_ENV_FILE:-${PRIVATE_DIR}/.env}"
SINGBOX_CHECKSUM_FILE="${REPO_ROOT}/scripts/lib/singbox.sha256"
MIHOMO_CHECKSUM_FILE="${REPO_ROOT}/scripts/lib/mihomo.sha256"
MIHOMO_PINNED_VERSION="v1.19.33"

# ---- 默认配置常量（与 examples/env.example 保持一致）----
DEFAULT_SINGBOX_VERSION="1.14.4"
DEFAULT_SINGBOX_CLIENT_COMPAT="1.14"
DEFAULT_SERVER_IPV6="false"
DEFAULT_SERVER_LOG_LEVEL="warn"
DEFAULT_VLESS_PORT="443"
DEFAULT_REALITY_HANDSHAKE_PORT="8443"
DEFAULT_UTLS_FINGERPRINT="chrome"
DEFAULT_ENABLE_HY2="false"
DEFAULT_HY2_PORT="8443"
DEFAULT_HY2_OBFS="false"
DEFAULT_ENABLE_SUBSCRIPTION="true"
DEFAULT_DNS_DIRECT="223.5.5.5"
DEFAULT_DNS_REMOTE="1.1.1.1"
DEFAULT_RULESET_GEOSITE_CN="https://raw.githubusercontent.com/SagerNet/sing-geosite/23066e3b0833d1484916637dde2b5bae80178045/geosite-cn.srs"
DEFAULT_RULESET_GEOIP_CN="https://raw.githubusercontent.com/SagerNet/sing-geoip/eb32cd6ed4a16fcb3bf9a36ccebf28e45716ae84/geoip-cn.srs"
DEFAULT_RULESET_MIHOMO_GEOSITE_CN="https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/458e716abd80ff8c6aee2b7d15c4f94b20e9d279/geo/geosite/cn.mrs"
DEFAULT_RULESET_MIHOMO_GEOIP_CN="https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/458e716abd80ff8c6aee2b7d15c4f94b20e9d279/geo/geoip/cn.mrs"
DEFAULT_RULESET_SR_CN_DOMAIN="https://raw.githubusercontent.com/Loyalsoldier/surge-rules/d2ff19cde30a09df3e6a527cb3996ccd506cbfea/direct.txt"

export REPO_ROOT PRIVATE_DIR ENV_FILE SINGBOX_CHECKSUM_FILE MIHOMO_CHECKSUM_FILE MIHOMO_PINNED_VERSION \
  DEFAULT_SINGBOX_VERSION DEFAULT_SINGBOX_CLIENT_COMPAT DEFAULT_SERVER_IPV6 DEFAULT_SERVER_LOG_LEVEL \
  DEFAULT_VLESS_PORT DEFAULT_REALITY_HANDSHAKE_PORT DEFAULT_UTLS_FINGERPRINT \
  DEFAULT_ENABLE_HY2 DEFAULT_HY2_PORT DEFAULT_HY2_OBFS DEFAULT_ENABLE_SUBSCRIPTION \
  DEFAULT_DNS_DIRECT DEFAULT_DNS_REMOTE \
  DEFAULT_RULESET_GEOSITE_CN DEFAULT_RULESET_GEOIP_CN DEFAULT_RULESET_MIHOMO_GEOSITE_CN \
  DEFAULT_RULESET_MIHOMO_GEOIP_CN DEFAULT_RULESET_SR_CN_DOMAIN

# ---- 临时路径追踪与自动清理 ----
SINGTUN_TMP_PATHS=()
SINGTUN_TMP_GPG_HOMES=()
SINGTUN_LOADED_ENV_KEYS=()

_singtun_cleanup_tmp() {
  local gh p
  if command -v gpgconf >/dev/null 2>&1; then
    for gh in "${SINGTUN_TMP_GPG_HOMES[@]:-}"; do
      if [[ -n "${gh}" && -d "${gh}" ]]; then
        gpgconf --homedir "${gh}" --kill all >/dev/null 2>&1 || true
      fi
    done
  fi
  for p in "${SINGTUN_TMP_PATHS[@]:-}"; do
    if [[ -n "${p}" && ( -e "${p}" || -L "${p}" ) ]]; then
      rm -rf -- "${p}"
    fi
  done
}
trap _singtun_cleanup_tmp EXIT

register_cleanup_path() {
  local p="$1"
  SINGTUN_TMP_PATHS+=("${p}")
}

make_temp_dir() {
  local _out_var="$1"
  local _dir
  _dir="$(mktemp -d)"
  chmod 700 "${_dir}"
  SINGTUN_TMP_PATHS+=("${_dir}")
  printf -v "${_out_var}" '%s' "${_dir}"
}

make_temp_gpg_home() {
  local _out_var="$1"
  local _gh
  _gh="$(mktemp -d)"
  chmod 700 "${_gh}"
  SINGTUN_TMP_GPG_HOMES+=("${_gh}")
  SINGTUN_TMP_PATHS+=("${_gh}")
  printf -v "${_out_var}" '%s' "${_gh}"
}

make_temp_file() {
  local _out_var="$1"
  local _file
  _file="$(mktemp)"
  chmod 600 "${_file}"
  SINGTUN_TMP_PATHS+=("${_file}")
  printf -v "${_out_var}" '%s' "${_file}"
}

# ---- 日志函数 ----
log_info() {
  printf '\033[1;34m[INFO]\033[0m %s\n' "$*"
}

log_warn() {
  printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2
}

log_error() {
  printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
}

die() {
  log_error "$*"
  exit 1
}

# ---- 权限、互斥锁与依赖检查 ----
require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "此操作需要 root 权限，请使用 sudo 执行。"
  fi
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      die "缺少必需命令: ${cmd}"
    fi
  done
}

ensure_private_dir_permissions() {
  local existed="false"
  [[ -d "${PRIVATE_DIR}" ]] && existed="true"
  mkdir -p "${PRIVATE_DIR}"
  chmod 700 "${PRIVATE_DIR}" 2>/dev/null || true
  if [[ "${existed}" == "false" && "${EUID:-$(id -u)}" -eq 0 ]]; then
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]] && id -u "${SUDO_USER}" >/dev/null 2>&1; then
      local caller_grp
      caller_grp="$(id -gn "${SUDO_USER}")"
      chown "${SUDO_USER}:${caller_grp}" "${PRIVATE_DIR}" 2>/dev/null || true
    else
      local repo_ug=""
      repo_ug="$(stat -c '%u:%g' "${REPO_ROOT}" 2>/dev/null || true)"
      if [[ -n "${repo_ug}" && "${repo_ug%%:*}" != "0" ]]; then
        chown "${repo_ug}" "${PRIVATE_DIR}" 2>/dev/null || true
      fi
    fi
  fi
}

# 状态变更操作统一获取文件互斥锁，支持子进程重入
acquire_singtun_lock() {
  if [[ "${SINGTUN_LOCK_HELD:-false}" == "true" ]]; then
    return 0
  fi
  ensure_private_dir_permissions
  local lock_file="${PRIVATE_DIR}/.singtun.lock"
  exec 9>"${lock_file}"
  chmod 600 "${lock_file}" 2>/dev/null || true
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]] && id -u "${SUDO_USER}" >/dev/null 2>&1; then
      local caller_grp
      caller_grp="$(id -gn "${SUDO_USER}")"
      chown "${SUDO_USER}:${caller_grp}" "${lock_file}" 2>/dev/null || true
    else
      local priv_ug=""
      priv_ug="$(stat -c '%u:%g' "${PRIVATE_DIR}" 2>/dev/null || true)"
      if [[ -n "${priv_ug}" && "${priv_ug%%:*}" != "0" ]]; then
        chown "${priv_ug}" "${lock_file}" 2>/dev/null || true
      fi
    fi
  fi
  if command -v flock >/dev/null 2>&1; then
    if ! flock -w 30 9; then
      die "无法获取操作互斥锁 (${lock_file})：另一个 singtun 进程正在运行。"
    fi
  fi
  export SINGTUN_LOCK_HELD="true"
}

# 判断服务端是否已完成部署（沙箱/非 root 测试模式下不触碰宿主 /etc/sing-box）
is_server_deployed() {
  if [[ "${SINGTUN_ALLOW_NONROOT_SUB:-false}" == "true" ]]; then
    return 1
  fi
  if [[ -n "${SINGTUN_PRIVATE_DIR:-}" && "${SINGTUN_PRIVATE_DIR}" != "${REPO_ROOT}/private" ]]; then
    return 1
  fi
  [[ -f "/etc/sing-box/10-inbound-vless.json" ]] && systemctl is-enabled --quiet sing-box 2>/dev/null
}

# ---- 加载、校验与原子更新 private/.env（纯数据解析，禁止 Shell 代码执行）----
_stat_file_uid() {
  local target="$1"
  stat -L -c '%u' "${target}" 2>/dev/null || stat -L -f '%u' "${target}" 2>/dev/null || echo ""
}

is_allowed_singtun_env_key() {
  local key="$1"
  # 显式拦截运行环境、动态链接器、Shell 启动与代理劫持变量
  case "${key}" in
    PATH|LD_*|BASH*|ENV|IFS|HOME|USER|LOGNAME|UID|EUID|GID|GROUPS|SUDO_*|SHELL|SHELLOPTS|PS1|PS2|PS4|PROMPT_COMMAND|CDPATH|GLOBIGNORE|PYTHONPATH|PYTHONSTARTUP|PERL5OPT|PERL5LIB|RUBYOPT|NODE_OPTIONS|JAVA_TOOL_OPTIONS|OPENSSL_CONF|CURL_HOME|GIT_*|HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY|http_proxy|https_proxy|all_proxy|no_proxy|TMPDIR|TEMP|TMP|TERM|LANG|LC_*|SINGTUN_*|SSCTL_*)
      return 1
      ;;
  esac

  case "${key}" in
    SINGBOX_VERSION|SINGBOX_CLIENT_COMPAT|SINGBOX_DEB_SHA256_AMD64|SINGBOX_DEB_SHA256_ARM64|\
    SERVER_IP|SERVER_DOMAIN|SERVER_IPV6|SERVER_LOG_LEVEL|SSH_PORT|\
    ACME_EMAIL|CF_API_TOKEN|ACME_NOTIFY_HOOK|\
    VLESS_PORT|REALITY_HANDSHAKE_PORT|REALITY_PRIVATE_KEY|REALITY_PUBLIC_KEY|REALITY_SHORT_ID|UTLS_FINGERPRINT|\
    ENABLE_HY2|HY2_PORT|HY2_OBFS|HY2_HOP_PORTS|HY2_UP_MBPS|HY2_DOWN_MBPS|\
    ENABLE_SUBSCRIPTION|SUB_PATH_PREFIX|SUBSCRIPTIONS|\
    DNS_DIRECT|DNS_REMOTE|\
    RULESET_GEOSITE_CN|RULESET_GEOIP_CN|RULESET_MIHOMO_GEOSITE_CN|RULESET_MIHOMO_GEOIP_CN|RULESET_SR_CN_DOMAIN)
      return 0
      ;;
  esac

  if [[ "${key}" =~ ^(UUID|SUB_TOKEN)_[A-Z0-9_]+$ ]]; then
    return 0
  fi

  # 允许受约束的 acme.sh 续期通知钩子凭据键（严格限定大写字母数字前缀）
  if [[ "${key}" =~ ^(TELEGRAM|DISCORD|SLACK|BARK|GOTIFY|PUSHOVER|FEISHU|WEIXIN|WORKWEIXIN|DINGTALK|WEBHOOK|SMTP|MAILGUN|SENDGRID|NTFY|MATTERMOST|MATRIX)_[A-Z0-9_]+$ ]]; then
    return 0
  fi

  return 1
}

# 解析单行纯数据键值语法，结果写入调用方局部变量 _parsed_type (SKIP|KV)、_parsed_key、_parsed_val
_parse_env_data_line() {
  local raw_line="${1%$'\r'}"
  local file_label="$2"
  local line_no="$3"

  _parsed_type="SKIP"
  _parsed_key=""
  _parsed_val=""

  if [[ "${raw_line}" =~ ^[[:space:]]*(#.*)?$ ]]; then
    return 0
  fi

  local header_re='^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$'
  if [[ ! "${raw_line}" =~ ${header_re} ]]; then
    log_error "${file_label}:${line_no}: 非法配置行语法（仅允许 KEY=VALUE 纯数据赋值与 # 注释）"
    return 1
  fi

  local key="${BASH_REMATCH[2]}"
  local rhs="${BASH_REMATCH[3]}"
  local out=""

  if [[ "${rhs}" =~ ^[[:space:]]*(#.*)?$ ]]; then
    out=""
  elif [[ "${rhs:0:1}" == "'" ]]; then
    local len="${#rhs}" i=0 ch
    while (( i < len )); do
      if [[ "${rhs:i:1}" == "'" ]]; then
        i=$((i + 1))
        local closed=0
        while (( i < len )); do
          ch="${rhs:i:1}"
          if [[ "${ch}" == "'" ]]; then
            closed=1
            i=$((i + 1))
            break
          fi
          out+="${ch}"
          i=$((i + 1))
        done
        if (( closed == 0 )); then
          log_error "${file_label}:${line_no} (${key}): 单引号未闭合"
          return 1
        fi
      elif [[ "${rhs:i:2}" == "\\'" ]]; then
        out+="'"
        i=$((i + 2))
      else
        break
      fi
    done
    local tail="${rhs:i}"
    if [[ ! "${tail}" =~ ^[[:space:]]*(#.*)?$ ]]; then
      log_error "${file_label}:${line_no} (${key}): 单引号闭合后存在非法尾部字符"
      return 1
    fi
  elif [[ "${rhs:0:1}" == '"' ]]; then
    local len="${#rhs}" i=1 closed=0 ch next_ch
    while (( i < len )); do
      ch="${rhs:i:1}"
      if [[ "${ch}" == '"' ]]; then
        closed=1
        i=$((i + 1))
        break
      fi
      if [[ "${ch}" == "\\" ]]; then
        if (( i + 1 >= len )); then
          log_error "${file_label}:${line_no} (${key}): 双引号内存在悬空反斜杠"
          return 1
        fi
        next_ch="${rhs:i+1:1}"
        case "${next_ch}" in
          '"'|"\\")
            out+="${next_ch}"
            i=$((i + 2))
            ;;
          '$'|'`')
            log_error "${file_label}:${line_no} (${key}): 禁止在双引号中使用 \$ 或反引号（如需字面量请改用单引号）"
            return 1
            ;;
          *)
            log_error "${file_label}:${line_no} (${key}): 双引号中存在不支持的转义序列 \\${next_ch}"
            return 1
            ;;
        esac
      elif [[ "${ch}" == '$' || "${ch}" == '`' ]]; then
        log_error "${file_label}:${line_no} (${key}): 禁止命令替换或变量展开语法（\$ / 反引号）"
        return 1
      else
        out+="${ch}"
        i=$((i + 1))
      fi
    done
    if (( closed == 0 )); then
      log_error "${file_label}:${line_no} (${key}): 双引号未闭合"
      return 1
    fi
    local tail="${rhs:i}"
    if [[ ! "${tail}" =~ ^[[:space:]]*(#.*)?$ ]]; then
      log_error "${file_label}:${line_no} (${key}): 双引号闭合后存在非法尾部字符"
      return 1
    fi
  else
    local unquoted_re='^([A-Za-z0-9_./:@%+,=-]+)([[:space:]]+(#.*)?)?$'
    if [[ ! "${rhs}" =~ ${unquoted_re} ]]; then
      log_error "${file_label}:${line_no} (${key}): 无引号值包含非法字符或命令语法（含空格、&、?、; 等特殊字符的值请加引号）"
      return 1
    fi
    out="${BASH_REMATCH[1]}"
  fi

  _parsed_type="KV"
  _parsed_key="${key}"
  _parsed_val="${out}"
  return 0
}

# 整份校验并解析键值文件至调用方传入的数组名（先全量校验，失败零副作用）
parse_env_data_file() {
  local file="$1"
  local enforce_allowlist="$2"
  local -n _out_keys_ref="$3"
  local -n _out_vals_ref="$4"

  _out_keys_ref=()
  _out_vals_ref=()

  local label="${file}"
  local -a tmp_keys=()
  local -a tmp_vals=()
  local -A seen_keys=()
  local line="" line_no=0
  local _parsed_type="" _parsed_key="" _parsed_val=""

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line_no=$((line_no + 1))
    if ! _parse_env_data_line "${line}" "${label}" "${line_no}"; then
      return 1
    fi
    if [[ "${_parsed_type}" != "KV" ]]; then
      continue
    fi
    if [[ "${enforce_allowlist}" == "true" ]] && ! is_allowed_singtun_env_key "${_parsed_key}"; then
      log_error "${label}:${line_no}: 拒绝未授权或高危环境变量键名 '${_parsed_key}'"
      return 1
    fi
    if [[ -n "${seen_keys[${_parsed_key}]:-}" ]]; then
      log_error "${label}:${line_no}: 存在重复的配置键 '${_parsed_key}'（首次出现于第 ${seen_keys[${_parsed_key}]} 行）"
      return 1
    fi
    seen_keys["${_parsed_key}"]="${line_no}"
    tmp_keys+=("${_parsed_key}")
    tmp_vals+=("${_parsed_val}")
  done < "${file}"

  _out_keys_ref=("${tmp_keys[@]}")
  _out_vals_ref=("${tmp_vals[@]}")
  return 0
}

validate_env_data_file() {
  local file="$1"
  local enforce_allowlist="$2"
  local -a _v_keys=() _v_vals=()
  parse_env_data_file "${file}" "${enforce_allowlist}" _v_keys _v_vals || return 1
  (( ${#_v_keys[@]} == ${#_v_vals[@]} ))
}

list_env_file_keys() {
  local file="${1:-${ENV_FILE}}"
  [[ -f "${file}" ]] || return 0
  local -a keys=() vals=()
  local enforce="false"
  if [[ "${file}" == "${ENV_FILE}" || "${file}" == "${SINGTUN_ENV_FILE:-}" || "$(basename "${file}")" == ".env" ]]; then
    enforce="true"
  fi
  if ! parse_env_data_file "${file}" "${enforce}" keys vals || (( ${#keys[@]} != ${#vals[@]} )); then
    return 1
  fi
  local k
  for k in "${keys[@]}"; do
    printf '%s\n' "${k}"
  done
}

is_reserved_example_domain() {
  local domain="${1,,}"
  [[ "${domain}" =~ ^(.*\.)?(example\.(com|org|net)|localhost|invalid|test|example)$ ]]
}

is_reserved_example_email() {
  local email="${1,,}"
  local edom="${email#*@}"
  [[ "${edom}" != "${email}" ]] || return 1
  is_reserved_example_domain "${edom}"
}

derive_default_acme_email() {
  local d="${1,,}"
  local IFS='.'
  local -a labels=()
  read -r -a labels <<< "${d}"
  local n="${#labels[@]}"
  local base="${d}"
  if (( n >= 3 )); then
    local sld="${labels[n-2]}.${labels[n-1]}"
    case "${sld}" in
      co.uk|org.uk|ac.uk|gov.uk|com.cn|net.cn|org.cn|gov.cn|edu.cn|com.hk|com.tw|com.sg|com.au|co.jp|co.kr|eu.org)
        base="${d}"
        ;;
      *)
        base="${d#*.}"
        ;;
    esac
  fi
  printf 'admin@%s' "${base}"
}

apply_default_env_vars() {
  local k def_var
  for k in \
    SINGBOX_VERSION \
    SINGBOX_CLIENT_COMPAT \
    SERVER_IPV6 \
    SERVER_LOG_LEVEL \
    VLESS_PORT \
    REALITY_HANDSHAKE_PORT \
    UTLS_FINGERPRINT \
    ENABLE_HY2 \
    HY2_PORT \
    HY2_OBFS \
    ENABLE_SUBSCRIPTION \
    DNS_DIRECT \
    DNS_REMOTE \
    RULESET_GEOSITE_CN \
    RULESET_GEOIP_CN \
    RULESET_MIHOMO_GEOSITE_CN \
    RULESET_MIHOMO_GEOIP_CN \
    RULESET_SR_CN_DOMAIN; do
    if [[ -z "${!k:-}" ]]; then
      def_var="DEFAULT_${k}"
      printf -v "${k}" '%s' "${!def_var}"
      export "${k?}"
      SINGTUN_LOADED_ENV_KEYS+=("${k}")
    fi
  done

  if [[ -z "${ACME_EMAIL:-}" ]] && is_valid_domain "${SERVER_DOMAIN:-}"; then
    local derived_email
    derived_email="$(derive_default_acme_email "${SERVER_DOMAIN}")"
    printf -v ACME_EMAIL '%s' "${derived_email}"
    export ACME_EMAIL
    SINGTUN_LOADED_ENV_KEYS+=("ACME_EMAIL")
  fi
}

detect_public_ipv4() {
  local ip=""
  if [[ -n "${SINGTUN_PUBLIC_IPV4_OVERRIDE:-}" ]]; then
    ip="${SINGTUN_PUBLIC_IPV4_OVERRIDE}"
    if is_valid_ipv4 "${ip}" && ! is_non_public_ipv4 "${ip}" "true"; then
      printf '%s' "${ip}"
      return 0
    fi
    return 1
  fi

  if command -v ip >/dev/null 2>&1; then
    while IFS= read -r ip; do
      [[ -z "${ip}" ]] && continue
      if is_valid_ipv4 "${ip}" && ! is_non_public_ipv4 "${ip}" "true"; then
        printf '%s' "${ip}"
        return 0
      fi
    done < <(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)
  fi

  if command -v curl >/dev/null 2>&1; then
    local endpoint
    for endpoint in "https://api.ipify.org" "https://api.ip.sb/ip" "https://ipv4.icanhazip.com"; do
      ip="$(curl -4 -fsSL --max-time 3 "${endpoint}" 2>/dev/null | tr -d '[:space:]' || true)"
      if [[ -n "${ip}" ]] && is_valid_ipv4 "${ip}" && ! is_non_public_ipv4 "${ip}" "true"; then
        printf '%s' "${ip}"
        return 0
      fi
    done
  fi

  return 1
}

load_env() {
  if [[ ! -f "${ENV_FILE}" ]]; then
    die "未找到配置文件 ${ENV_FILE}，请先执行 './singtun init'（或 './singtun setup'）并填写参数。"
  fi

  local perm
  perm="$(stat -L -c '%a' "${ENV_FILE}" 2>/dev/null || stat -L -f '%Lp' "${ENV_FILE}" 2>/dev/null || echo "")"
  if [[ -n "${perm}" && "${perm}" != "600" ]]; then
    log_warn "${ENV_FILE} 权限为 ${perm}（应为 600），正在自动修正为 600..."
    chmod 600 "${ENV_FILE}"
  fi

  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    local env_uid repo_uid priv_uid sudo_uid=""
    env_uid="$(_stat_file_uid "${ENV_FILE}")"
    repo_uid="$(_stat_file_uid "${REPO_ROOT}")"
    priv_uid="$(_stat_file_uid "${PRIVATE_DIR}")"
    if [[ -n "${SUDO_USER:-}" ]] && id -u "${SUDO_USER}" >/dev/null 2>&1; then
      sudo_uid="$(id -u "${SUDO_USER}")"
    fi
    if [[ -n "${env_uid}" && "${env_uid}" != "0" && "${env_uid}" != "${sudo_uid}" && "${env_uid}" != "${repo_uid}" && "${env_uid}" != "${priv_uid}" ]]; then
      die "安全拦截：${ENV_FILE} 属主 UID (${env_uid}) 非 root、调用者或仓库属主，拒绝以 root 权限加载！"
    fi
  fi

  # 先在局部数组中完成整份纯数据语法与键名白名单校验，失败时绝不污染或清空当前进程环境
  local -a parsed_keys=() parsed_vals=()
  if ! parse_env_data_file "${ENV_FILE}" "true" parsed_keys parsed_vals; then
    die "加载 ${ENV_FILE} 失败：纯数据解析或键名安全校验未通过。"
  fi

  local _k
  if (( ${#SINGTUN_LOADED_ENV_KEYS[@]} > 0 )); then
    for _k in "${SINGTUN_LOADED_ENV_KEYS[@]}"; do
      if [[ -n "${_k}" ]]; then
        unset "${_k}" || true
      fi
    done
  fi
  while IFS='=' read -r _k _; do
    case "${_k}" in
      UUID_*|SUB_TOKEN_*)
        unset "${_k}" || true
        ;;
    esac
  done < <(env)

  SINGTUN_LOADED_ENV_KEYS=("${parsed_keys[@]}")
  local idx
  for (( idx = 0; idx < ${#parsed_keys[@]}; idx++ )); do
    printf -v "${parsed_keys[idx]}" '%s' "${parsed_vals[idx]}"
    export "${parsed_keys[idx]}"
  done
  apply_default_env_vars
}

_preserve_env_owner_and_mode() {
  local ref_file="$1"
  local target_file="$2"
  chmod 600 "${target_file}"
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    local ug=""
    if [[ -n "${ref_file}" && -f "${ref_file}" ]]; then
      ug="$(stat -c '%u:%g' "${ref_file}" 2>/dev/null || true)"
    fi
    if [[ -z "${ug}" && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]] && id -u "${SUDO_USER}" >/dev/null 2>&1; then
      ug="$(id -u "${SUDO_USER}"):$(id -g "${SUDO_USER}")"
    fi
    if [[ -z "${ug}" && -d "${PRIVATE_DIR}" ]]; then
      local priv_ug=""
      priv_ug="$(stat -c '%u:%g' "${PRIVATE_DIR}" 2>/dev/null || true)"
      if [[ -n "${priv_ug}" && "${priv_ug%%:*}" != "0" ]]; then
        ug="${priv_ug}"
      fi
    fi
    if [[ -n "${ug}" ]]; then
      chown "${ug}" "${target_file}" 2>/dev/null || true
    fi
  fi
}

env_file_has_key() {
  local key="$1"
  local file="${2:-${ENV_FILE}}"
  [[ -f "${file}" ]] || return 1
  local -a _hk_keys=() _hk_vals=()
  local enforce="false"
  if [[ "${file}" == "${ENV_FILE}" || "${file}" == "${SINGTUN_ENV_FILE:-}" || "$(basename "${file}")" == ".env" ]]; then
    enforce="true"
  fi
  parse_env_data_file "${file}" "${enforce}" _hk_keys _hk_vals || return 1
  local _k
  for _k in "${_hk_keys[@]}"; do
    [[ "${_k}" == "${key}" ]] && return 0
  done
  return 1
}

# 在单个临时文件中批量应用多键修改（SET:key=val / DEL:key），经同一纯数据解析器全量校验通过后才更新 .bak 并原子替换
env_file_apply_batch() {
  local file="$1"
  shift
  local work_file="${file}.batch.$$"
  local step_file="${file}.step.$$"
  local bak_file="${file}.bak"
  local had_orig="false"

  register_cleanup_path "${work_file}"
  register_cleanup_path "${step_file}"

  if [[ -f "${file}" ]]; then
    had_orig="true"
    cp -f "${file}" "${work_file}"
  else
    : > "${work_file}"
  fi

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
        mv -f "${step_file}" "${work_file}"
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
        mv -f "${step_file}" "${work_file}"
        ;;
      *)
        rm -f "${work_file}" "${step_file}"
        die "env_file_apply_batch 未知操作指令: ${spec}"
        ;;
    esac
  done

  local enforce_allowlist="false"
  if [[ "${file}" == "${ENV_FILE}" || "${file}" == "${SINGTUN_ENV_FILE:-}" || "$(basename "${file}")" == ".env" ]]; then
    enforce_allowlist="true"
  fi
  if ! validate_env_data_file "${work_file}" "${enforce_allowlist}"; then
    rm -f "${work_file}" "${step_file}"
    die "更新 ${file} 失败：候选内容未通过纯数据语法或键名白名单校验（原文件与备份未改动）！"
  fi

  if [[ "${had_orig}" == "true" ]]; then
    cp -f "${file}" "${bak_file}"
    _preserve_env_owner_and_mode "${file}" "${bak_file}"
    _preserve_env_owner_and_mode "${file}" "${work_file}"
  else
    _preserve_env_owner_and_mode "" "${work_file}"
  fi
  mv -f "${work_file}" "${file}"
}

env_file_set_var() {
  local key="$1" raw_val="$2" file="${3:-${ENV_FILE}}"
  env_file_apply_batch "${file}" "SET:${key}=${raw_val}"
}

env_file_del_var() {
  local key="$1" file="${2:-${ENV_FILE}}"
  [[ -f "${file}" ]] || return 0
  env_file_apply_batch "${file}" "DEL:${key}"
}

require_vars() {
  local var_name missing=0
  for var_name in "$@"; do
    if [[ -z "${!var_name:-}" ]]; then
      log_error "必填环境变量未设置或为空: ${var_name} (请检查 ${ENV_FILE})"
      missing=1
    fi
  done
  if [[ "${missing}" -ne 0 ]]; then
    die "环境变量校验失败，请补全 ${ENV_FILE} 后重试。"
  fi
}

# ---- OS 与架构检测 ----
detect_os() {
  local os_release="/etc/os-release"
  if [[ ! -f "${os_release}" ]]; then
    die "无法识别操作系统：缺少 ${os_release}"
  fi

  local id="" version_id=""
  # shellcheck disable=SC1090
  source "${os_release}"
  id="${ID:-}"
  version_id="${VERSION_ID:-}"

  case "${id}:${version_id}" in
    debian:12*)
      echo "debian12"
      ;;
    ubuntu:22.04*)
      echo "ubuntu2204"
      ;;
    ubuntu:24.04*)
      echo "ubuntu2404"
      ;;
    *)
      die "不支持的操作系统: ${id} ${version_id}（仅支持 Debian 12、Ubuntu 22.04 / 24.04）"
      ;;
  esac
}

detect_arch() {
  local machine
  machine="$(uname -m)"
  case "${machine}" in
    x86_64|amd64)
      echo "amd64"
      ;;
    aarch64|arm64)
      echo "arm64"
      ;;
    *)
      die "不支持的 CPU 架构: ${machine}（仅支持 amd64 / arm64）"
      ;;
  esac
}

# ---- 格式校验辅助函数 ----
is_valid_bool() {
  local val="$1"
  [[ "${val}" == "true" || "${val}" == "false" ]]
}

is_valid_log_level() {
  local lvl="$1"
  [[ "${lvl}" =~ ^(trace|debug|info|warn|error|fatal|panic)$ ]]
}

is_valid_singbox_compat() {
  local compat="$1"
  [[ "${compat}" == "1.14" || "${compat}" == "1.12" ]]
}

is_valid_semver() {
  local ver="$1"
  [[ "${ver}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# 订阅名称保留字与格式校验
is_reserved_sub_name() {
  local name="$1"
  case "${name}" in
    init|setup|deploy|add|list|ls|show|reset|rotate|del|delete|remove|rm|revoke|flush|check|status|logs|restart|renew|upgrade|uninstall|sub|all|help|none|default|singtun)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_valid_sub_name() {
  local name="$1"
  [[ "${name}" =~ ^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$ ]] && ! is_reserved_sub_name "${name}"
}

is_characteristic_sub_prefix() {
  local pfx="$1"
  [[ "${pfx}" =~ ^(sub|subscribe|subscription|proxy|clash|mihomo|singbox|singtun|v2ray|hy2|hysteria) ]]
}

is_valid_sub_prefix() {
  local pfx="$1"
  [[ "${pfx}" =~ ^[a-z0-9]{12,32}$ ]] && ! is_characteristic_sub_prefix "${pfx}"
}

is_valid_sub_token() {
  local tok="$1"
  [[ "${tok}" =~ ^[0-9a-f]{64}$ ]]
}

is_valid_sha256() {
  local sha="$1"
  [[ "${sha}" =~ ^[0-9a-fA-F]{64}$ ]]
}

is_valid_ipv4() {
  local ip="$1"
  if [[ ! "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    return 1
  fi
  local IFS='.'
  local -a octets
  read -r -a octets <<< "${ip}"
  local octet
  for octet in "${octets[@]}"; do
    if [[ ! "${octet}" =~ ^(0|[1-9][0-9]{0,2})$ ]] || (( octet > 255 )); then
      return 1
    fi
  done
  return 0
}

# 校验 IPv4 是否属于非公网/保留/多播网段（返回 0 表示禁止，返回 1 表示允许的公网地址或非法 IPv4）
is_non_public_ipv4() {
  local ip="$1"
  local reject_doc_net="${2:-false}"
  is_valid_ipv4 "${ip}" || return 1

  local IFS='.'
  local -a octets
  read -r -a octets <<< "${ip}"
  local o1=$((10#${octets[0]}))
  local o2=$((10#${octets[1]}))
  local o3=$((10#${octets[2]}))

  if (( o1 == 0 || o1 == 10 || o1 == 127 || o1 >= 224 )); then
    return 0
  fi
  if (( o1 == 100 && o2 >= 64 && o2 <= 127 )); then
    return 0
  fi
  if (( o1 == 169 && o2 == 254 )); then
    return 0
  fi
  if (( o1 == 172 && o2 >= 16 && o2 <= 31 )); then
    return 0
  fi
  if (( o1 == 192 && o2 == 0 && o3 == 0 )); then
    return 0
  fi
  if (( o1 == 192 && o2 == 168 )); then
    return 0
  fi
  if (( o1 == 198 && (o2 == 18 || o2 == 19) )); then
    return 0
  fi

  if [[ "${reject_doc_net}" == "true" ]]; then
    if (( (o1 == 192 && o2 == 0 && o3 == 2) || (o1 == 198 && o2 == 51 && o3 == 100) || (o1 == 203 && o2 == 0 && o3 == 113) )); then
      return 0
    fi
  fi

  return 1
}

# 加密 IP-DoH 静态白名单（证书必须包含对应裸 IP SAN，支持免域名 Bootstrap 的 https://<IP>/dns-query）
is_valid_dns_direct_ip() {
  local ip="$1"
  case "${ip}" in
    223.5.5.5|223.6.6.6) return 0 ;;
    *) return 1 ;;
  esac
}

is_valid_dns_remote_ip() {
  local ip="$1"
  case "${ip}" in
    1.1.1.1|1.0.0.1|8.8.8.8|8.8.4.4|9.9.9.9) return 0 ;;
    *) return 1 ;;
  esac
}

validate_dns_doh_env_vars() {
  if ! is_valid_ipv4 "${DNS_DIRECT:-}"; then
    die "DNS_DIRECT 不是合法的 IPv4 地址: ${DNS_DIRECT:-}"
  fi
  if ! is_valid_dns_direct_ip "${DNS_DIRECT}"; then
    die "DNS_DIRECT (${DNS_DIRECT}) 不在受支持的国内加密 IP-DoH 白名单内（仅支持 223.5.5.5 或 223.6.6.6，证书须含 IP SAN）。"
  fi
  if ! is_valid_ipv4 "${DNS_REMOTE:-}"; then
    die "DNS_REMOTE 不是合法的 IPv4 地址: ${DNS_REMOTE:-}"
  fi
  if ! is_valid_dns_remote_ip "${DNS_REMOTE}"; then
    die "DNS_REMOTE (${DNS_REMOTE}) 不在受支持的海外加密 IP-DoH 白名单内（仅支持 1.1.1.1、1.0.0.1、8.8.8.8、8.8.4.4、9.9.9.9）。"
  fi
}

is_valid_uuid() {
  local uuid="$1"
  [[ "${uuid}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

is_valid_domain() {
  local domain="$1"
  [[ "${domain}" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] && (( ${#domain} <= 253 ))
}

is_valid_email() {
  local email="$1"
  [[ "${email}" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$ ]] && (( ${#email} <= 254 ))
}

is_valid_acme_notify_hook() {
  local hook="$1"
  [[ "${hook}" =~ ^[a-z0-9_]{1,32}(,[a-z0-9_]{1,32})*$ ]]
}

is_valid_reality_key() {
  local key="$1"
  [[ "${key}" =~ ^[A-Za-z0-9_-]{43}=?$ ]]
}

derive_reality_public_key() {
  local priv_b64url="$1"
  is_valid_reality_key "${priv_b64url}" || return 1
  command -v openssl >/dev/null 2>&1 || return 1

  local b64="${priv_b64url//-/+}"
  b64="${b64//_//}"
  case $(( ${#b64} % 4 )) in
    0) ;;
    2) b64="${b64}==" ;;
    3) b64="${b64}=" ;;
    *) return 1 ;;
  esac

  local tmp_der tmp_pub der_bytes pub_bytes pub
  make_temp_file tmp_der
  make_temp_file tmp_pub

  if ! {
    printf '\x30\x2e\x02\x01\x00\x30\x05\x06\x03\x2b\x65\x6e\x04\x22\x04\x20'
    printf '%s' "${b64}" | base64 -d 2>/dev/null
  } > "${tmp_der}"; then
    rm -f -- "${tmp_der}" "${tmp_pub}"
    return 1
  fi

  der_bytes="$(wc -c < "${tmp_der}" | tr -d '[:space:]')"
  if [[ ! "${der_bytes}" =~ ^[0-9]+$ ]] || (( der_bytes != 48 )); then
    rm -f -- "${tmp_der}" "${tmp_pub}"
    return 1
  fi

  if ! openssl pkey -inform DER -in "${tmp_der}" -pubout -outform DER -out "${tmp_pub}" 2>/dev/null; then
    rm -f -- "${tmp_der}" "${tmp_pub}"
    return 1
  fi

  pub_bytes="$(wc -c < "${tmp_pub}" | tr -d '[:space:]')"
  if [[ ! "${pub_bytes}" =~ ^[0-9]+$ ]] || (( pub_bytes != 44 )); then
    rm -f -- "${tmp_der}" "${tmp_pub}"
    return 1
  fi

  pub="$(tail -c 32 "${tmp_pub}" | base64 | tr '+/' '-_' | tr -d '=\n')"
  rm -f -- "${tmp_der}" "${tmp_pub}"

  is_valid_reality_key "${pub}" || return 1
  printf '%s' "${pub}"
}

is_valid_utls_fingerprint() {
  local fp="$1"
  [[ "${fp}" =~ ^(chrome|firefox|edge|safari|360|qq|ios|android|random|randomized)$ ]]
}

# 校验客户端远程规则集 URL：强制 HTTPS 且禁止空格、引号与逗号（防止降级劫持及 YAML/Surge 规则语法注入）
is_valid_https_url() {
  local url="$1"
  local url_re='^https://[A-Za-z0-9._~:/?#@!$&()*+;=%-]+$'
  [[ "${url}" =~ ${url_re} ]]
}

is_immutable_ruleset_url() {
  local url="$1"
  [[ "${url}" =~ /[0-9a-fA-F]{40}/ ]]
}

validate_ruleset_urls() {
  local var_name val
  for var_name in RULESET_GEOSITE_CN RULESET_GEOIP_CN RULESET_MIHOMO_GEOSITE_CN RULESET_MIHOMO_GEOIP_CN RULESET_SR_CN_DOMAIN; do
    val="${!var_name:-}"
    [[ -z "${val}" ]] && continue
    if ! is_valid_https_url "${val}"; then
      die "${var_name} 必须以 https:// 开头且不含空格、引号或逗号: ${val}"
    fi
  done
}

# 只读检测宿主当前活跃的 SSH 监听端口（供 00-preflight / 10-harden / singtun uninstall 共用，防止误封锁 SSH）
detect_active_ssh_ports() {
  local -A seen=()
  local -a ports=()
  local p

  if command -v sshd >/dev/null 2>&1; then
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
      mkdir -p /run/sshd 2>/dev/null || true
    fi
    while IFS= read -r p; do
      if is_valid_port "${p}" && [[ -z "${seen[${p}]:-}" ]]; then
        seen["${p}"]=1
        ports+=("${p}")
      fi
    done < <(sshd -T 2>/dev/null | awk '/^port / {print $2}' || true)
  fi

  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet ssh.socket 2>/dev/null || systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
      while IFS= read -r p; do
        if is_valid_port "${p}" && [[ -z "${seen[${p}]:-}" ]]; then
          seen["${p}"]=1
          ports+=("${p}")
        fi
      done < <(
        systemctl show ssh.socket -p Listen --value 2>/dev/null \
          | awk '{for (i = 1; i <= NF; i++) { if ($i ~ /^[0-9]+$/) print $i; else if ($i !~ /^\// && $i ~ /:[0-9]+$/) { sub(/^.*:/, "", $i); print $i } }}' \
          || true
      )
    fi
  fi

  if command -v ss >/dev/null 2>&1; then
    while IFS= read -r p; do
      if is_valid_port "${p}" && [[ -z "${seen[${p}]:-}" ]]; then
        seen["${p}"]=1
        ports+=("${p}")
      fi
    done < <(ss -H -tlnp 2>/dev/null | awk '/"sshd"/ {split($4, a, ":"); print a[length(a)]}' || true)
  fi

  if (( ${#ports[@]} == 0 )); then
    ports=("22")
  fi

  printf '%s\n' "${ports[@]}"
}

assert_no_unreplaced_placeholders() {
  local file="$1"
  if grep -Eq '__[A-Z0-9_]+__' "${file}"; then
    die "渲染产物仍存在未替换的模板占位符: ${file}"
  fi
}

html_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  printf '%s' "${s}"
}

is_valid_short_id() {
  local sid="$1"
  [[ "${sid}" =~ ^[0-9a-fA-F]{1,16}$ ]] && (( ${#sid} % 2 == 0 ))
}

is_valid_port() {
  local port="$1"
  [[ "${port}" =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#${port} >= 1 && 10#${port} <= 65535 ))
}

is_valid_port_range() {
  local range="$1"
  if [[ ! "${range}" =~ ^([0-9]+)-([0-9]+)$ ]]; then
    return 1
  fi
  local start="${BASH_REMATCH[1]}"
  local end="${BASH_REMATCH[2]}"
  is_valid_port "${start}" && is_valid_port "${end}" && (( 10#${start} < 10#${end} ))
}

is_valid_mbps() {
  local val="$1"
  [[ "${val}" =~ ^[1-9][0-9]{0,5}$ ]] && (( 10#${val} >= 1 && 10#${val} <= 100000 ))
}

# 统一校验 Hysteria2 开关、混淆、端口、跳跃范围与上下行带宽参数（供 00/10/40/50 脚本共用）
validate_hy2_env_vars() {
  local enable_hy2="${ENABLE_HY2:-false}"
  if ! is_valid_bool "${enable_hy2}"; then
    die "ENABLE_HY2 必须为 true 或 false: ${enable_hy2}"
  fi

  local hy2_obfs="${HY2_OBFS:-false}"
  if ! is_valid_bool "${hy2_obfs}"; then
    die "HY2_OBFS 必须为 true 或 false: ${hy2_obfs}"
  fi

  if [[ "${enable_hy2}" == "true" ]]; then
    require_vars HY2_PORT
  fi

  if [[ -n "${HY2_PORT:-}" ]] && ! is_valid_port "${HY2_PORT}"; then
    die "HY2_PORT 不是合法端口号 (1-65535): ${HY2_PORT}"
  fi

  if [[ -n "${HY2_HOP_PORTS:-}" ]]; then
    if ! is_valid_port_range "${HY2_HOP_PORTS}"; then
      die "HY2_HOP_PORTS 格式非法（须形如 20000-30000 且起始小于结束）: ${HY2_HOP_PORTS}"
    fi
    if [[ -n "${HY2_PORT:-}" ]]; then
      local hop_start="${HY2_HOP_PORTS%-*}"
      local hop_end="${HY2_HOP_PORTS#*-}"
      if (( 10#${HY2_PORT} >= 10#${hop_start} && 10#${HY2_PORT} <= 10#${hop_end} )); then
        die "HY2_PORT (${HY2_PORT}) 不应包含在 HY2_HOP_PORTS (${HY2_HOP_PORTS}) 跳跃范围内。"
      fi
    fi
  fi

  if [[ -n "${HY2_UP_MBPS:-}" || -n "${HY2_DOWN_MBPS:-}" ]]; then
    if [[ -z "${HY2_UP_MBPS:-}" || -z "${HY2_DOWN_MBPS:-}" ]]; then
      die "HY2_UP_MBPS 与 HY2_DOWN_MBPS 须同时设置或同时留空（留空默认使用 BBR）。"
    fi
    if ! is_valid_mbps "${HY2_UP_MBPS}"; then
      die "HY2_UP_MBPS 格式非法（须为正整数 Mbps）: ${HY2_UP_MBPS}"
    fi
    if ! is_valid_mbps "${HY2_DOWN_MBPS}"; then
      die "HY2_DOWN_MBPS 格式非法（须为正整数 Mbps）: ${HY2_DOWN_MBPS}"
    fi
  fi
}

# ---- 官方安装包 SHA256 查询 ----
lookup_singbox_deb_sha256() {
  local ver="$1"
  local arch="$2"
  local env_override=""

  case "${arch}" in
    amd64)
      env_override="${SINGBOX_DEB_SHA256_AMD64:-}"
      ;;
    arm64)
      env_override="${SINGBOX_DEB_SHA256_ARM64:-}"
      ;;
  esac

  if [[ -n "${env_override}" ]]; then
    if [[ ! "${env_override}" =~ ^[0-9a-fA-F]{64}$ ]]; then
      die "环境变量中预设的 sing-box (${arch}) SHA256 格式非法: ${env_override}"
    fi
    printf '%s' "${env_override,,}"
    return 0
  fi

  if [[ -f "${SINGBOX_CHECKSUM_FILE}" ]]; then
    local deb_name="sing-box_${ver}_linux_${arch}.deb"
    awk -v target="${deb_name}" '$1 ~ /^[0-9a-fA-F]{64}$/ && $2 == target {print tolower($1); exit}' "${SINGBOX_CHECKSUM_FILE}"
  fi
}

lookup_mihomo_gz_sha256() {
  local ver="$1"
  local arch="$2"
  [[ -f "${MIHOMO_CHECKSUM_FILE}" ]] || return 0

  local gz_name=""
  case "${arch}" in
    amd64)
      gz_name="mihomo-linux-amd64-compatible-${ver}.gz"
      ;;
    arm64)
      gz_name="mihomo-linux-arm64-${ver}.gz"
      ;;
    *)
      return 0
      ;;
  esac
  awk -v target="${gz_name}" '$1 ~ /^[0-9a-fA-F]{64}$/ && $2 == target {print tolower($1); exit}' "${MIHOMO_CHECKSUM_FILE}"
}

# ---- 订阅遍历与凭据辅助函数 ----
sub_env_suffix() {
  local sub="$1"
  printf '%s' "${sub}" | tr '[:lower:]-' '[:upper:]_'
}

sub_uuid_var_name() {
  local sub="$1"
  printf 'UUID_%s' "$(sub_env_suffix "${sub}")"
}

sub_token_var_name() {
  local sub="$1"
  printf 'SUB_TOKEN_%s' "$(sub_env_suffix "${sub}")"
}

list_subscriptions() {
  local sub
  for sub in ${SUBSCRIPTIONS:-}; do
    printf '%s\n' "${sub}"
  done
}

has_subscription() {
  local candidate="$1"
  local s
  while IFS= read -r s; do
    [[ -n "${s}" && "${s}" == "${candidate}" ]] && return 0
  done < <(list_subscriptions)
  return 1
}

get_sub_uuid() {
  local sub="$1"
  local var_name
  var_name="$(sub_uuid_var_name "${sub}")"
  local uuid="${!var_name:-}"
  if [[ -z "${uuid}" ]]; then
    die "订阅 '${sub}' 缺少对应的环境变量 ${var_name}"
  fi
  if ! is_valid_uuid "${uuid}"; then
    die "订阅 '${sub}' 的 ${var_name} 格式非法: ${uuid}"
  fi
  printf '%s' "${uuid}"
}

get_sub_token() {
  local sub="$1"
  local var_name
  var_name="$(sub_token_var_name "${sub}")"
  local tok="${!var_name:-}"
  if [[ -z "${tok}" ]]; then
    die "订阅 '${sub}' 缺少对应的环境变量 ${var_name}"
  fi
  if ! is_valid_sub_token "${tok}"; then
    die "订阅 '${sub}' 的 ${var_name} 格式非法（须为 64 位小写十六进制字符串）"
  fi
  printf '%s' "${tok}"
}

# 基于实例 REALITY_PRIVATE_KEY 与订阅 UUID 同源密钥派生 Hysteria2 密码（脱离服务端 .env 无法由 UUID 离线推导）
derive_hy2_password() {
  local uuid="$1"
  local secret="${REALITY_PRIVATE_KEY:-}"
  [[ -n "${secret}" ]] || die "derive_hy2_password 需要已加载 REALITY_PRIVATE_KEY"
  printf '%s:%s:singtun-hy2-v2' "${secret}" "${uuid}" | sha256sum | awk '{print substr($1, 1, 32)}'
}

# 基于实例 REALITY_PRIVATE_KEY 确定性派生 Hysteria2 salamander 混淆密码
derive_hy2_obfs_password() {
  local secret="${REALITY_PRIVATE_KEY:-}"
  [[ -n "${secret}" ]] || die "derive_hy2_obfs_password 需要已加载 REALITY_PRIVATE_KEY"
  printf '%s:singtun-hy2-obfs-v1' "${secret}" | sha256sum | awk '{print substr($1, 1, 32)}'
}

# 订阅 URL 与节点链接共用构造函数（singtun 与 50-gen-clients.sh 统一复用）
urlencode_str() {
  local LC_ALL=C
  local s="$1"
  local i c
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    case "${c}" in
      [a-zA-Z0-9.~_-]) printf '%s' "${c}" ;;
      *) printf '%%%02X' "'${c}" ;;
    esac
  done
}

build_sub_base_url() {
  local tok="$1"
  if [[ "${VLESS_PORT}" == "443" ]]; then
    printf 'https://%s/%s/%s' "${SERVER_DOMAIN}" "${SUB_PATH_PREFIX}" "${tok}"
  else
    printf 'https://%s:%s/%s/%s' "${SERVER_DOMAIN}" "${VLESS_PORT}" "${SUB_PATH_PREFIX}" "${tok}"
  fi
}

build_vless_uri() {
  local sub="$1"
  local uuid="$2"
  local tag="${SERVER_DOMAIN}-${sub}"
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=%s&pbk=%s&sid=%s&type=tcp&headerType=none&packetEncoding=xudp#%s' \
    "${uuid}" \
    "${SERVER_IP}" \
    "${VLESS_PORT}" \
    "${SERVER_DOMAIN}" \
    "${UTLS_FINGERPRINT}" \
    "${REALITY_PUBLIC_KEY}" \
    "${REALITY_SHORT_ID}" \
    "${tag}"
}

build_hy2_uri() {
  local sub="$1"
  local uuid="$2"
  local pass tag mport_param="" obfs_param="" obfs_pass=""
  pass="$(derive_hy2_password "${uuid}")"
  tag="${SERVER_DOMAIN}-${sub}-hy2"
  if [[ -n "${HY2_HOP_PORTS:-}" ]]; then
    mport_param="&mport=${HY2_HOP_PORTS}"
  fi
  if [[ "${HY2_OBFS:-false}" == "true" ]]; then
    obfs_pass="$(derive_hy2_obfs_password)"
    obfs_param="&obfs=salamander&obfs-password=${obfs_pass}"
  fi
  printf 'hysteria2://%s@%s:%s?sni=%s&alpn=h3&insecure=0%s%s#%s' \
    "${pass}" \
    "${SERVER_IP}" \
    "${HY2_PORT}" \
    "${SERVER_DOMAIN}" \
    "${mport_param}" \
    "${obfs_param}" \
    "${tag}"
}

# 当 SERVER_IPV6=true 时，收集服务端本机全局单播 IPv6 地址（每行输出一个 <addr>/128；支持 SINGTUN_SELF_IPV6_OVERRIDE 测试覆写）
collect_server_self_ipv6_cidrs() {
  if [[ "${SERVER_IPV6:-false}" != "true" ]]; then
    return 0
  fi
  local v6_item v6_addr
  if [[ -n "${SINGTUN_SELF_IPV6_OVERRIDE:-}" ]]; then
    for v6_item in ${SINGTUN_SELF_IPV6_OVERRIDE}; do
      v6_item="${v6_item%%/*}"
      [[ -n "${v6_item}" ]] && printf '%s/128\n' "${v6_item}"
    done
  elif command -v ip >/dev/null 2>&1; then
    while IFS= read -r v6_addr; do
      [[ -n "${v6_addr}" ]] && printf '%s/128\n' "${v6_addr}"
    done < <(ip -6 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | sort -u || true)
  fi
}
