#!/usr/bin/env bash
# scripts/hooks/check-private-leak.sh — 拒绝任何包含 private/.env / private/host-facts.md 敏感值或本地绝对链接的提交
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${REPO_ROOT}/scripts/lib/common.sh"
PRIVATE_DIR="${SSCTL_PRIVATE_DIR:-${REPO_ROOT}/private}"
PRIVATE_ENV="${SSCTL_ENV_FILE:-${PRIVATE_DIR}/.env}"
PRIVATE_FACTS="${PRIVATE_DIR}/host-facts.md"
EXAMPLE_ENV="${REPO_ROOT}/examples/env.example"
EXAMPLE_FACTS="${REPO_ROOT}/examples/host-facts.example.md"
LOCAL_FILE_URI_PREFIX="file:"'///'

make_private_tmp() {
  make_temp_file "$1"
}

is_placeholder() {
  local val="$1"
  case "${val}" in
    ""|"true"|"false"|"chrome"|"firefox"|"safari"|"ios"|"edge"|"none"|"randomized"|"auto")
      return 0
      ;;
    *.md|*.sh|*.json|*.yaml|*.yml|*.conf|*.txt|*.png|*.service|*.srs|*.mrs|*.asc|*.deb|*.bak|*.err|*.example|*.local|*.lan)
      return 0
      ;;
    "co.uk"|"org.uk"|"ac.uk"|"gov.uk"|"com.cn"|"net.cn"|"org.cn"|"gov.cn"|"edu.cn"|"com.hk"|"com.tw"|"com.sg"|"com.au"|"co.jp"|"co.kr")
      return 0
      ;;
    "203.0.113."*|"198.51.100."*|"192.0.2."*|"127.0.0.1"|"1.1.1.1"|"1.0.0.1"|"223.5.5.5"|"223.6.6.6"|"8.8.8.8"|"8.8.4.4"|"9.9.9.9")
      return 0
      ;;
    "0.0.0.0"|"10.0.0.0"|"100.64.0.0"|"127.0.0.0"|"169.254.0.0"|"172.16.0.0"|"192.0.0.0"|"192.88.99.0"|"192.168.0.0"|"198.18.0.0"|"224.0.0.0"|"240.0.0.0"|"255.255.255.255")
      return 0
      ;;
    "2001:db8:"*|"2001:DB8:"*|"fdfe:dcba:9876:"*|"fc00:"*|"fd00:"*|"fe80:"*|"ff00:"*|"64:ff9b:"*|"::"*|"100::"*)
      return 0
      ;;
    *"example.com"*|*"example.org"*|*"example.net"*|"browserleaks.com"|"www.gstatic.com"|"myip.ipip.net"|"api.ip.sb"|"sing-box.app"|"deb.sagernet.org"|"raw.githubusercontent.com")
      return 0
      ;;
  esac
  # 长度过短的通用数字或短后缀（如端口号 22/443/8443）不作为特征串
  if (( ${#val} < 7 )); then
    return 0
  fi
  if [[ -f "${EXAMPLE_ENV}" ]] && grep -Fq -- "${val}" "${EXAMPLE_ENV}"; then
    return 0
  fi
  if [[ -f "${EXAMPLE_FACTS}" ]] && grep -Fq -- "${val}" "${EXAMPLE_FACTS}"; then
    return 0
  fi
  return 1
}

_fallback_parse_env_line() {
  local raw_line="${1%$'\r'}"
  _parsed_key=""
  _parsed_val=""

  [[ "${raw_line}" =~ ^[[:space:]]*# ]] && return 1
  [[ "${raw_line}" != *"="* ]] && return 1

  local key="${raw_line%%=*}"
  key="$(printf '%s' "${key}" | sed -E 's/^[[:space:]]*(export[[:space:]]+)?//; s/[[:space:]]+$//')"
  [[ -n "${key}" ]] || return 1

  local val="${raw_line#*=}"
  val="${val#"${val%%[![:space:]]*}"}"

  if [[ "${val}" == \"* ]]; then
    local out="" i=1 len="${#val}" ch next_ch
    while (( i < len )); do
      ch="${val:i:1}"
      if [[ "${ch}" == '"' ]]; then
        break
      elif [[ "${ch}" == "\\" && $((i + 1)) -lt len ]]; then
        next_ch="${val:i+1:1}"
        if [[ "${next_ch}" == '"' || "${next_ch}" == "\\" ]]; then
          out+="${next_ch}"
          i=$((i + 2))
          continue
        fi
      fi
      out+="${ch}"
      i=$((i + 1))
    done
    val="${out}"
  elif [[ "${val}" == \'* ]]; then
    local out="" i=1 len="${#val}" ch
    while (( i < len )); do
      ch="${val:i:1}"
      if [[ "${ch}" == "'" ]]; then
        break
      fi
      out+="${ch}"
      i=$((i + 1))
    done
    val="${out}"
  else
    if [[ "${val}" == \#* ]]; then
      val=""
    else
      val="$(printf '%s' "${val}" | sed -E 's/[[:space:]]+#.*$//')"
      val="${val%"${val##*[![:space:]]}"}"
    fi
  fi

  _parsed_key="${key}"
  _parsed_val="${val}"
  return 0
}

collect_sensitive_tokens() {
  local -a tokens=()

  if [[ -f "${PRIVATE_ENV}" ]]; then
    local line key val line_no=0 env_label="${PRIVATE_ENV}" env_domain="" env_port="443" env_sub_pfx="" env_reality_priv=""
    local _parsed_type="" _parsed_key="" _parsed_val=""
    local -a env_uuids=()
    while IFS= read -r line || [[ -n "${line}" ]]; do
      line_no=$((line_no + 1))
      if _parse_env_data_line "${line}" "${env_label}" "${line_no}" 2>/dev/null; then
        [[ "${_parsed_type}" == "KV" ]] || continue
        key="${_parsed_key}"
        val="${_parsed_val}"
      else
        _fallback_parse_env_line "${line}" || continue
        key="${_parsed_key}"
        val="${_parsed_val}"
      fi
      if [[ "${key}" == "VLESS_PORT" && -n "${val}" ]]; then
        env_port="${val}"
      fi
      case "${key}" in
        SERVER_IP|SERVER_DOMAIN|ACME_EMAIL|CF_API_TOKEN|REALITY_PRIVATE_KEY|REALITY_PUBLIC_KEY|REALITY_SHORT_ID|SUB_PATH_PREFIX|SUB_TOKEN_*|UUID_*|*_TOKEN|*_KEY|*_SECRET*|*_WEBHOOK*|*_PASSWORD*)
          if [[ "${key}" == "SERVER_DOMAIN" ]]; then
            env_domain="${val}"
          elif [[ "${key}" == "SUB_PATH_PREFIX" ]]; then
            env_sub_pfx="${val}"
          elif [[ "${key}" == "REALITY_PRIVATE_KEY" ]]; then
            env_reality_priv="${val}"
          fi
          if ! is_placeholder "${val}"; then
            tokens+=("${val}")
            if [[ "${key}" == "SERVER_DOMAIN" ]]; then
              local parent_dom="${val#*.}"
              while [[ "${parent_dom}" == *.* ]]; do
                if ! is_placeholder "${parent_dom}"; then
                  tokens+=("${parent_dom}")
                fi
                parent_dom="${parent_dom#*.}"
              done
            elif [[ "${key}" == UUID_* ]]; then
              local vless_b64_pfx
              env_uuids+=("${val}")
              # vless://<UUID>@ 共 45 字节（3 的整数倍），其 Base64 前 60 字符恒定，可拦截 Base64 节点订阅泄露
              vless_b64_pfx="$(printf 'vless://%s@' "${val}" | base64 | tr -d '\n=')"
              if (( ${#vless_b64_pfx} >= 24 )); then
                tokens+=("${vless_b64_pfx}")
              fi
            fi
          fi
          ;;
      esac
    done < "${PRIVATE_ENV}"

    # 无论 UUID_* 与 REALITY_PRIVATE_KEY 在 .env 中的先后顺序如何，统一派生并拦截新旧 Hysteria2 密码与混淆密码
    if [[ -n "${env_reality_priv}" ]] && ! is_placeholder "${env_reality_priv}"; then
      local hy2_obfs_pass
      hy2_obfs_pass="$(printf '%s:ssctl-hy2-obfs-v1' "${env_reality_priv}" | sha256sum | awk '{print substr($1, 1, 32)}')"
      tokens+=("${hy2_obfs_pass}")
    fi
    if (( ${#env_uuids[@]} > 0 )); then
      local u_val hy2_pass_v1 hy2_pass_v2
      for u_val in "${env_uuids[@]}"; do
        hy2_pass_v1="$(printf '%s:ssctl-hy2-v1' "${u_val}" | sha256sum | awk '{print substr($1, 1, 32)}')"
        tokens+=("${hy2_pass_v1}")
        if [[ -n "${env_reality_priv}" ]] && ! is_placeholder "${env_reality_priv}"; then
          hy2_pass_v2="$(printf '%s:%s:ssctl-hy2-v2' "${env_reality_priv}" "${u_val}" | sha256sum | awk '{print substr($1, 1, 32)}')"
          tokens+=("${hy2_pass_v2}")
        fi
      done
    fi

    # 拦截 sub://<Base64(v2ray_url)> 深链泄露：只要 SUB_PATH_PREFIX 非占位符，即按 3 字节整数倍截断 URL 前缀以获得恒定 Base64 头部特征
    if [[ -n "${env_domain}" && -n "${env_sub_pfx}" ]] && ! is_placeholder "${env_sub_pfx}"; then
      local raw_sub_url aligned_len sub_b64_pfx
      for raw_sub_url in "https://${env_domain}/${env_sub_pfx}/" "https://${env_domain}:${env_port}/${env_sub_pfx}/"; do
        aligned_len=$(( (${#raw_sub_url} / 3) * 3 ))
        if (( aligned_len >= 18 )); then
          sub_b64_pfx="$(printf '%s' "${raw_sub_url:0:aligned_len}" | base64 | tr -d '\n=')"
          if (( ${#sub_b64_pfx} >= 24 )); then
            tokens+=("${sub_b64_pfx}")
          fi
        fi
      done
    fi
  fi

  if [[ -f "${PRIVATE_FACTS}" ]]; then
    local item item_ip
    # 提取 host-facts.md 中的反引号标识符（如真实 IPv4/公网 IPv6、子域名、主域名）
    while IFS= read -r item; do
      if [[ "${item}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/32)?$ ]]; then
        item_ip="${item%/32}"
        if ! is_placeholder "${item_ip}"; then
          tokens+=("${item_ip}")
        fi
      elif [[ "${item}" == *:*:* && "${item}" =~ ^[23][0-9a-fA-F]{0,3}:[0-9a-fA-F:]{2,}(/(64|128))?$ ]]; then
        item_ip="${item%%/*}"
        if ! is_placeholder "${item_ip}"; then
          tokens+=("${item_ip}")
        fi
      elif [[ "${item}" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        if ! is_placeholder "${item}"; then
          tokens+=("${item}")
        fi
      fi
    done < <(awk -F'\x60' '{for (i = 2; i <= NF; i += 2) print $i}' "${PRIVATE_FACTS}" 2>/dev/null || true)
  fi

  if (( ${#tokens[@]} > 0 )); then
    printf '%s\n' "${tokens[@]}" | sort -u
  fi
}

# 使用 0600 模式临时特征文件配合 grep -Fqf 单次扫描（避免敏感值暴露于进程命令行，并大幅降低子进程开销）
scan_target_file() {
  local label="$1"
  local target_file="$2"
  local secrets_file="$3"

  local found=0
  if [[ -s "${secrets_file}" ]] && grep -aFqf "${secrets_file}" "${target_file}"; then
    printf '\033[1;31m[LEAK BLOCKED]\033[0m %s 中检测到私有敏感特征值！\n' "${label}" >&2
    found=1
  fi

  if grep -aEq "${LOCAL_FILE_URI_PREFIX}[A-Za-z0-9._~%-]" "${target_file}"; then
    printf '\033[1;31m[LINK BLOCKED]\033[0m %s 中检测到本地绝对路径链接 (%s...)，请改用相对路径！\n' "${label}" "${LOCAL_FILE_URI_PREFIX}" >&2
    found=1
  fi

  return "${found}"
}

check_staged() {
  local secrets_file="$1"
  local leaked=0
  local rel_file tmp_scan=""
  make_private_tmp tmp_scan

  while IFS= read -r rel_file; do
    [[ -z "${rel_file}" ]] && continue
    if [[ "${rel_file}" == private/* ]]; then
      printf '\033[1;31m[LEAK BLOCKED]\033[0m 严禁提交 private/ 目录下的私有文件: %s\n' "${rel_file}" >&2
      leaked=1
      continue
    fi

    # 直接读取 Git 暂存区索引对象而非工作区文件
    if git -C "${REPO_ROOT}" show ":${rel_file}" > "${tmp_scan}" 2>/dev/null; then
      if ! scan_target_file "暂存文件 ${rel_file}" "${tmp_scan}" "${secrets_file}"; then
        leaked=1
      fi
    fi
  done < <(git -C "${REPO_ROOT}" diff --cached --name-only --diff-filter=ACMR)

  return "${leaked}"
}

check_commit_msg() {
  local msg_file="$1"
  local secrets_file="$2"

  if [[ ! -f "${msg_file}" ]]; then
    printf '\033[1;31m[ERROR]\033[0m 未找到提交信息文件: %s\n' "${msg_file}" >&2
    return 1
  fi

  local tmp_scan=""
  make_private_tmp tmp_scan
  # 忽略 Git 默认以 # 开头的注释行
  grep -aEv '^[[:space:]]*#' "${msg_file}" > "${tmp_scan}" || true
  if ! scan_target_file "提交信息 (${msg_file})" "${tmp_scan}" "${secrets_file}"; then
    return 1
  fi
  return 0
}

collect_workspace_files() {
  if command -v git >/dev/null 2>&1 && git -C "${REPO_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "${REPO_ROOT}" ls-files -co --exclude-standard | sort -u
  else
    (cd "${REPO_ROOT}" && find . -type f -not -path './.git/*' -not -path './private/*' | sed 's|^\./||')
  fi
}

check_workspace() {
  local secrets_file="$1"
  local leaked=0
  local rel_file abs_file

  while IFS= read -r rel_file; do
    [[ -z "${rel_file}" ]] && continue
    if [[ "${rel_file}" == private/* ]]; then
      printf '\033[1;31m[LEAK BLOCKED]\033[0m 严禁追踪或暂存 private/ 目录下的私有文件: %s\n' "${rel_file}" >&2
      leaked=1
      continue
    fi

    abs_file="${REPO_ROOT}/${rel_file}"
    [[ ! -f "${abs_file}" ]] && continue

    if ! scan_target_file "文件 ${rel_file}" "${abs_file}" "${secrets_file}"; then
      leaked=1
    fi
  done < <(collect_workspace_files)

  return "${leaked}"
}

main() {
  local mode="${1:-workspace}"
  local secrets_file="" secret_count=0
  make_private_tmp secrets_file
  collect_sensitive_tokens > "${secrets_file}"
  if [[ -s "${secrets_file}" ]]; then
    secret_count="$(wc -l < "${secrets_file}" | tr -d '[:space:]')"
  fi

  local rc=0
  case "${mode}" in
    --staged)
      check_staged "${secrets_file}" || rc=$?
      ;;
    --commit-msg)
      local msg_file="${2:-}"
      if [[ -z "${msg_file}" ]]; then
        printf '\033[1;31m[ERROR]\033[0m 用法: %s --commit-msg <commit_msg_file>\n' "$0" >&2
        exit 1
      fi
      check_commit_msg "${msg_file}" "${secrets_file}" || rc=$?
      ;;
    workspace|"")
      check_workspace "${secrets_file}" || rc=$?
      ;;
    *)
      printf '\033[1;31m[ERROR]\033[0m 未知参数: %s（支持 --staged | --commit-msg <file> | 无参数扫描工作区）\n' "${mode}" >&2
      exit 1
      ;;
  esac

  if (( rc != 0 )); then
    printf '\033[1;31m[ERROR]\033[0m 私有信息与本地路径防泄漏检查未通过，已拒绝操作。\n' >&2
    exit 1
  fi

  printf '\033[1;32m[OK]\033[0m 防泄漏与规范检查通过（模式: %s，共核验 %d 项私有特征值）。\n' "${mode}" "${secret_count}"
}

main "$@"
