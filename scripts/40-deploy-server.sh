#!/usr/bin/env bash
# scripts/40-deploy-server.sh — 校验安装固定版本 sing-box 与 Nginx，渲染服务端配置与多态回落站，完成能力核验与原子部署
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

SERVER_TPL_DIR="${REPO_ROOT}/templates/server"
SINGBOX_ETC_DIR="/etc/sing-box"
NGINX_SITE_AVAILABLE="/etc/nginx/sites-available/singtun-reality.conf"
NGINX_SITE_ENABLED="/etc/nginx/sites-enabled/singtun-reality.conf"
WEB_ROOT="/var/www/singtun-site"
SYSTEMD_OVERRIDE_DIR="/etc/systemd/system/sing-box.service.d"
# SagerNet 官方 APT 仓库签名公钥主指纹 (Project S <contact@sagernet.org>)
# 获取方法: gpg --batch --with-colons --show-keys /etc/apt/keyrings/sagernet.asc
SAGERNET_GPG_FINGERPRINT="${SINGTUN_SAGERNET_GPG_FPR_OVERRIDE:-2C317FBD5D886B4E89BAE8DA6D9152172A2B2F0C}"

build_users_json() {
  local lines="" sub uuid
  while IFS= read -r sub; do
    [[ -z "${sub}" ]] && continue
    uuid="$(get_sub_uuid "${sub}")"
    lines+="${sub}"$'\t'"${uuid}"$'\n'
  done < <(list_subscriptions)
  printf '%s' "${lines}" | jq -Rn '[inputs | select(length > 0) | split("\t") | {"name": .[0], "uuid": .[1], "flow": "xtls-rprx-vision"}]'
}

build_hy2_users_json() {
  local lines="" sub uuid pass
  while IFS= read -r sub; do
    [[ -z "${sub}" ]] && continue
    uuid="$(get_sub_uuid "${sub}")"
    pass="$(derive_hy2_password "${uuid}")"
    lines+="${sub}"$'\t'"${pass}"$'\n'
  done < <(list_subscriptions)
  printf '%s' "${lines}" | jq -Rn '[inputs | select(length > 0) | split("\t") | {"name": .[0], "password": .[1]}]'
}

render_singbox_server_config() {
  local out_dir="$1"
  mkdir -p "${out_dir}"

  local users_json
  users_json="$(build_users_json)"

  local listen_addr="0.0.0.0"
  local dns_strategy="ipv4_only"
  local reject_ipv6="true"
  if [[ "${SERVER_IPV6:-false}" == "true" ]]; then
    listen_addr="::"
    dns_strategy="prefer_ipv4"
    reject_ipv6="false"
  fi

  local log_level="${SERVER_LOG_LEVEL:-warn}"
  if ! is_valid_log_level "${log_level}"; then
    die "SERVER_LOG_LEVEL 格式非法: ${log_level}"
  fi

  # 00-log.json (默认 warn 避免持久记录访问域名)
  jq \
    --arg level "${log_level}" \
    '.log.level = $level' \
    "${SERVER_TPL_DIR}/singbox/00-log.json" > "${out_dir}/00-log.json"

  # 05-dns.json
  jq \
    --arg strategy "${dns_strategy}" \
    '.dns.strategy = $strategy' \
    "${SERVER_TPL_DIR}/singbox/05-dns.json" > "${out_dir}/05-dns.json"

  # 10-inbound-vless.json（私钥与用户列表经进程环境传入 jq，避免泄露至 /proc/<pid>/cmdline）
  USERS_JSON="${users_json}" REALITY_PRIV="${REALITY_PRIVATE_KEY}" jq \
    --arg listen "${listen_addr}" \
    --argjson listen_port "${VLESS_PORT}" \
    --arg server_name "${SERVER_DOMAIN}" \
    --argjson handshake_port "${REALITY_HANDSHAKE_PORT}" \
    --arg short_id "${REALITY_SHORT_ID}" \
    '.inbounds[0].listen = $listen
     | .inbounds[0].listen_port = $listen_port
     | .inbounds[0].users = ($ENV.USERS_JSON | fromjson)
     | .inbounds[0].tls.server_name = $server_name
     | .inbounds[0].tls.reality.handshake.server_port = $handshake_port
     | .inbounds[0].tls.reality.private_key = $ENV.REALITY_PRIV
     | .inbounds[0].tls.reality.short_id = [$short_id]' \
    "${SERVER_TPL_DIR}/singbox/10-inbound-vless.json" > "${out_dir}/10-inbound-vless.json"

  # 20-inbound-hy2.json (仅在 ENABLE_HY2=true 时生成)
  validate_hy2_env_vars
  rm -f "${out_dir}/20-inbound-hy2.json"
  if [[ "${ENABLE_HY2:-false}" == "true" ]]; then
    require_vars HY2_PORT
    local hy2_users_json cert_dir masq_dir hy2_obfs_enabled="false" hy2_obfs_pass=""
    hy2_users_json="$(build_hy2_users_json)"
    cert_dir="${SINGTUN_CERT_DIR_OVERRIDE:-/etc/singtun/cert}"
    masq_dir="${SINGTUN_WEB_ROOT_OVERRIDE:-${WEB_ROOT}}"
    if [[ "${HY2_OBFS:-false}" == "true" ]]; then
      hy2_obfs_enabled="true"
      hy2_obfs_pass="$(derive_hy2_obfs_password)"
    fi
    HY2_USERS_JSON="${hy2_users_json}" HY2_OBFS_PASS="${hy2_obfs_pass}" jq \
      --arg listen "${listen_addr}" \
      --argjson listen_port "${HY2_PORT}" \
      --arg masq_dir "${masq_dir}" \
      --arg cert_path "${cert_dir}/fullchain.pem" \
      --arg key_path "${cert_dir}/key.pem" \
      --argjson obfs_on "${hy2_obfs_enabled}" \
      '.inbounds[0].listen = $listen
       | .inbounds[0].listen_port = $listen_port
       | .inbounds[0].users = ($ENV.HY2_USERS_JSON | fromjson)
       | .inbounds[0].masquerade.directory = $masq_dir
       | .inbounds[0].tls.certificate_path = $cert_path
       | .inbounds[0].tls.key_path = $key_path
       | if $obfs_on then
           .inbounds[0].obfs = {"type": "salamander", "password": $ENV.HY2_OBFS_PASS}
         else
           del(.inbounds[0].obfs)
         end' \
      "${SERVER_TPL_DIR}/singbox/20-inbound-hy2.json" > "${out_dir}/20-inbound-hy2.json"
  fi

  # 90-route.json（注入项目策略级特殊网段与本机公网地址拒绝）
  local -a self_cidrs=("${SERVER_IP}/32")
  local v6_cidr
  while IFS= read -r v6_cidr; do
    [[ -n "${v6_cidr}" ]] && self_cidrs+=("${v6_cidr}")
  done < <(collect_server_self_ipv6_cidrs)
  local self_cidrs_json
  self_cidrs_json="$(printf '%s\n' "${self_cidrs[@]}" | jq -R . | jq -sc .)"

  jq \
    --arg strategy "${dns_strategy}" \
    --argjson reject_ipv6 "${reject_ipv6}" \
    --argjson self_cidrs "${self_cidrs_json}" \
    '.route.default_domain_resolver.strategy = $strategy
     | (.route.rules[] | select(.action == "resolve")).strategy = $strategy
     | (.route.rules[] | select(has("ip_cidr") and .action == "reject")).ip_cidr |= (. + $self_cidrs | unique)
     | if $reject_ipv6 then
         .route.rules += [{"ip_version": 6, "action": "reject"}]
       else
         .
       end' \
    "${SERVER_TPL_DIR}/singbox/90-route.json" > "${out_dir}/90-route.json"
}

nginx_supports_ssl_reject_handshake() {
  local mode="${SINGTUN_NGINX_REJECT_UNKNOWN_SNI:-auto}"
  case "${mode}" in
    true)  return 0 ;;
    false) return 1 ;;
    auto)  ;;
    *)     die "SINGTUN_NGINX_REJECT_UNKNOWN_SNI 必须为 auto、true 或 false: ${mode}" ;;
  esac

  if ! command -v nginx >/dev/null 2>&1; then
    return 1
  fi

  local ver_raw major minor patch
  ver_raw="$(nginx -v 2>&1 || true)"
  if [[ "${ver_raw}" =~ nginx/([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    patch="${BASH_REMATCH[3]}"
    if (( 10#${major} > 1 )) \
      || (( 10#${major} == 1 && 10#${minor} > 19 )) \
      || (( 10#${major} == 1 && 10#${minor} == 19 && 10#${patch} >= 4 )); then
      return 0
    fi
  fi
  return 1
}

render_nginx_site_config() {
  local out_file="$1"
  mkdir -p "$(dirname "${out_file}")"

  local enable_sub="${ENABLE_SUBSCRIPTION:-true}"
  if ! is_valid_bool "${enable_sub}"; then
    die "ENABLE_SUBSCRIPTION 必须为 true 或 false: ${enable_sub}"
  fi

  local unknown_sni_block="# Nginx < 1.19.4 未内置 ssl_reject_handshake，保持真实证书单站点模式"
  local main_listen_opts="ssl http2 default_server"
  if nginx_supports_ssl_reject_handshake; then
    unknown_sni_block="server {
    listen 127.0.0.1:${REALITY_HANDSHAKE_PORT} ssl http2 default_server;
    server_name _;
    client_header_timeout 10s;
    keepalive_timeout 5s;
    reset_timedout_connection on;
    ssl_reject_handshake on;
}
"
    main_listen_opts="ssl http2"
  fi

  local sub_block="    # ENABLE_SUBSCRIPTION=false: 公网订阅托管已关闭"
  if [[ "${enable_sub}" == "true" ]]; then
    if ! is_valid_sub_prefix "${SUB_PATH_PREFIX:-}"; then
      die "SUB_PATH_PREFIX 未设置或格式非法: ${SUB_PATH_PREFIX:-}"
    fi
    sub_block="    location ^~ /${SUB_PATH_PREFIX}/ {
        root /var/lib/singtun/sub-web;
        disable_symlinks on from=\$document_root;
        autoindex off;
        access_log off;
        etag off;
        if_modified_since off;
        default_type text/plain;
        types {
            text/plain                 conf txt;
            application/json           json;
            text/yaml                  yaml yml;
        }
        # 仅与根站相同的 3 项安全头加 always，其余响应头仅对 200 生效，确保猜错路径返回与根站逐字节一致的 404 头
        add_header X-Content-Type-Options \"nosniff\" always;
        add_header X-Frame-Options \"DENY\" always;
        add_header Referrer-Policy \"no-referrer\" always;
        add_header X-Robots-Tag \"noindex, nofollow\";
        add_header Cache-Control \"no-store\";
        add_header Last-Modified \"\";
        add_header Profile-Update-Interval \"24\";
        try_files \$uri =404;
    }"
  fi

  shopt -u patsub_replacement 2>/dev/null || true
  local tpl
  tpl="$(<"${SERVER_TPL_DIR}/nginx/site.conf")"
  tpl="${tpl//__NGINX_UNKNOWN_SNI_SERVER_BLOCK__/"${unknown_sni_block}"}"
  tpl="${tpl//__NGINX_MAIN_LISTEN_OPTS__/"${main_listen_opts}"}"
  tpl="${tpl//__REALITY_HANDSHAKE_PORT__/"${REALITY_HANDSHAKE_PORT}"}"
  tpl="${tpl//__SERVER_DOMAIN__/"${SERVER_DOMAIN}"}"
  tpl="${tpl//__NGINX_SUB_LOCATION_BLOCK__/"${sub_block}"}"
  printf '%s\n' "${tpl}" > "${out_file}"
  assert_no_unreplaced_placeholders "${out_file}"
}

render_fallback_site() {
  local out_www_dir="$1"
  mkdir -p "${out_www_dir}"

  # private/www/ 存在且包含非 .gitkeep 文件时优先部署自定义静态站点（严格拒绝任何符号链接防越权暴露）
  local custom_www_dir="${PRIVATE_DIR}/www"
  if [[ -d "${custom_www_dir}" ]]; then
    local bad_link=""
    bad_link="$(find "${custom_www_dir}" -type l -print -quit 2>/dev/null || true)"
    if [[ -n "${bad_link}" ]]; then
      die "安全拦截：自定义静态站点目录 (${custom_www_dir}) 内禁止包含符号链接 (${bad_link})！"
    fi
    if [[ -n "$(find "${custom_www_dir}" -mindepth 1 ! -name '.gitkeep' -print -quit 2>/dev/null || true)" ]]; then
      cp -RP "${custom_www_dir}/." "${out_www_dir}/"
      rm -f "${out_www_dir}/.gitkeep"
      if [[ -n "$(find "${out_www_dir}" -type l -print -quit 2>/dev/null || true)" ]]; then
        die "安全拦截：静态站点暂存目录中检测到异常符号链接！"
      fi
      return 0
    fi
  fi

  # 基于实例私有密钥加盐摘要确定性生成多态无特征静态页（外部扫描器无法从域名/SNI 反推预期结构或哈希）
  local digest idx_theme idx_color idx_width idx_font idx_layout idx_pad host_label
  digest="$(printf '%s:%s:%s:singtun-site-v2' "${REALITY_PRIVATE_KEY:-}" "${SUB_PATH_PREFIX:-}" "${SERVER_DOMAIN}" | sha256sum | awk '{print $1}')"
  idx_theme=$(( 16#${digest:0:2} % 8 ))
  idx_color=$(( 16#${digest:2:2} % 6 ))
  idx_width=$(( 520 + (16#${digest:4:2} % 7) * 36 ))
  idx_font=$(( 16#${digest:6:2} % 4 ))
  idx_layout=$(( 16#${digest:8:2} % 4 ))
  idx_pad=$(( 7 + (16#${digest:10:2} % 6) ))
  host_label="${SERVER_DOMAIN%%.*}"

  local -a colors=("#1d4ed8" "#0f766e" "#4338ca" "#334155" "#0369a1" "#15803d")
  local -a fonts=(
    'system-ui, -apple-system, "Segoe UI", Roboto, sans-serif'
    '"Inter", -apple-system, BlinkMacSystemFont, "Helvetica Neue", Arial, sans-serif'
    'ui-sans-serif, system-ui, "Segoe UI", Helvetica, Arial, sans-serif'
    'Georgia, "Noto Serif", Cambria, "Times New Roman", serif'
  )
  local -a titles=(
    "${host_label} — Index"
    "${SERVER_DOMAIN}"
    "Notes · ${host_label}"
    "${SERVER_DOMAIN} / Docs"
    "Reference (${host_label})"
    "${host_label} Archive"
    "${SERVER_DOMAIN} — Overview"
    "Static Root · ${host_label}"
  )
  local -a headings=(
    "Reference Index"
    "Content Archive"
    "Workspace Overview"
    "Registered Hostname"
    "Technical Specifications"
    "Asset Directory"
    "Documentation Root"
    "Static Mirror"
  )
  local -a subtitles=(
    "Maintained at ${SERVER_DOMAIN}"
    "Read-only static endpoint"
    "Internal publishing node · ${host_label}"
    "Hostname ${SERVER_DOMAIN}"
    "Plain-text & HTML repository"
    "Direct permalink access only"
    "Published under ${SERVER_DOMAIN}"
    "Static document index"
  )
  local -a paragraphs=(
    "This endpoint hosts static reference documents and archived notes. Directory browsing is disabled."
    "No interactive web service runs on this host. Published resources are addressed via direct URLs."
    "Static web root for ${SERVER_DOMAIN}. Use exact document permalinks when retrieving archived files."
    "This hostname is reserved for static documentation snapshots and read-only assets."
    "Pages on this host are rendered from static sources and updated without client-side scripts."
    "Default landing page for ${SERVER_DOMAIN}. Unindexed paths return standard not-found responses."
    "Read-only static storage endpoint. Contact the domain administrator if an active page was expected."
    "Minimal static index for ${host_label}. Automated directory listing is turned off."
  )

  local color="${colors[${idx_color}]}"
  local font_stack="${fonts[${idx_font}]}"
  local title_esc heading_esc subtitle_esc paragraph_esc domain_esc
  title_esc="$(html_escape "${titles[${idx_theme}]}")"
  heading_esc="$(html_escape "${headings[${idx_theme}]}")"
  subtitle_esc="$(html_escape "${subtitles[${idx_theme}]}")"
  paragraph_esc="$(html_escape "${paragraphs[${idx_theme}]}")"
  domain_esc="$(html_escape "${SERVER_DOMAIN}")"

  local styles="" body_html=""
  case "${idx_layout}" in
    0)
      styles="    :root { color-scheme: light dark; }
    body { font-family: ${font_stack}; max-width: ${idx_width}px; margin: ${idx_pad}vh auto; padding: 0 22px; line-height: 1.62; }
    header { border-bottom: 2px solid ${color}; padding-bottom: 0.7rem; margin-bottom: 1.4rem; }
    h1 { font-size: 1.4rem; margin: 0 0 0.3rem 0; }
    header p { font-size: 0.9rem; opacity: 0.7; margin: 0; }
    section p { opacity: 0.88; margin: 0; }"
      body_html="  <main>
    <header>
      <h1>${heading_esc}</h1>
      <p>${subtitle_esc}</p>
    </header>
    <section>
      <p>${paragraph_esc}</p>
    </section>
  </main>"
      ;;
    1)
      styles="    :root { color-scheme: light dark; }
    body { font-family: ${font_stack}; max-width: ${idx_width}px; margin: ${idx_pad}vh auto; padding: 0 26px; line-height: 1.7; }
    article { border-left: 3px solid ${color}; padding-left: 1.25rem; }
    h1 { font-size: 1.35rem; margin: 0 0 0.6rem 0; }
    p { margin: 0 0 1rem 0; opacity: 0.86; }
    small { display: block; opacity: 0.62; font-size: 0.84rem; }"
      body_html="  <article>
    <h1>${heading_esc}</h1>
    <p>${paragraph_esc}</p>
    <small>${subtitle_esc}</small>
  </article>"
      ;;
    2)
      styles="    :root { color-scheme: light dark; }
    body { font-family: ${font_stack}; max-width: ${idx_width}px; margin: ${idx_pad}vh auto; padding: 0 20px; line-height: 1.6; }
    h2 { font-size: 1.28rem; color: ${color}; margin: 0 0 0.75rem 0; }
    p { margin: 0 0 1.2rem 0; opacity: 0.85; }
    dl { display: grid; grid-template-columns: auto 1fr; gap: 0.35rem 1rem; font-size: 0.88rem; opacity: 0.74; margin: 0; }
    dt { font-weight: 600; }
    dd { margin: 0; }"
      body_html="  <div>
    <h2>${heading_esc}</h2>
    <p>${paragraph_esc}</p>
    <dl>
      <dt>Host</dt><dd>${domain_esc}</dd>
      <dt>Mode</dt><dd>Static read-only</dd>
    </dl>
  </div>"
      ;;
    *)
      styles="    :root { color-scheme: light dark; }
    body { font-family: ${font_stack}; max-width: ${idx_width}px; margin: ${idx_pad}vh auto; padding: 0 24px; line-height: 1.66; }
    section { padding: 1.2rem 0; border-top: 1px solid ${color}; border-bottom: 1px solid rgba(127,127,127,0.25); }
    h1 { font-size: 1.38rem; margin: 0 0 0.5rem 0; }
    p { margin: 0 0 0.9rem 0; opacity: 0.86; }
    footer { font-size: 0.85rem; opacity: 0.65; }"
      body_html="  <section>
    <h1>${heading_esc}</h1>
    <p>${paragraph_esc}</p>
    <footer><span>${subtitle_esc}</span></footer>
  </section>"
      ;;
  esac

  # 关闭 Bash 5.2 的 patsub_replacement，避免替换串中的 & 被解释为匹配文本
  shopt -u patsub_replacement 2>/dev/null || true
  local html
  html="$(<"${SERVER_TPL_DIR}/www/index.html")"
  html="${html//__SITE_LANG__/en}"
  html="${html//__SITE_TITLE__/"${title_esc}"}"
  html="${html//__SITE_STYLES__/"${styles}"}"
  html="${html//__SITE_BODY__/"${body_html}"}"
  printf '%s\n' "${html}" > "${out_www_dir}/index.html"

  assert_no_unreplaced_placeholders "${out_www_dir}/index.html"
}

ensure_singbox_user() {
  if ! getent group sing-box >/dev/null 2>&1; then
    groupadd --system sing-box
  fi
  if ! id -u sing-box >/dev/null 2>&1; then
    useradd --system --gid sing-box --no-create-home --shell /usr/sbin/nologin sing-box
  fi
}

match_apt_singbox_version() {
  local target_ver="$1"
  local escaped_ver="${target_ver//./\\.}"
  apt-cache madison sing-box 2>/dev/null \
    | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}' \
    | grep -E "^${escaped_ver}(-[0-9]+)?$" \
    | head -n 1 || true
}

verify_singbox_deb() {
  local deb_file="$1"
  local ver="$2"
  local arch="$3"

  local expected_sha
  expected_sha="$(lookup_singbox_deb_sha256 "${ver}" "${arch}")"
  if [[ -z "${expected_sha}" ]]; then
    die "未找到 sing-box_${ver}_linux_${arch}.deb 的预设 SHA256（请检查 ${SINGBOX_CHECKSUM_FILE} 或在 .env 设置 SINGBOX_DEB_SHA256_${arch^^}），拒绝无校验安装！"
  fi

  local actual_sha
  actual_sha="$(sha256sum "${deb_file}" | awk '{print tolower($1)}')"
  if [[ "${actual_sha}" != "${expected_sha}" ]]; then
    die "sing-box deb 包 SHA256 校验失败！预期: ${expected_sha}，实际: ${actual_sha}"
  fi
}

verify_sagernet_gpg_key() {
  local key_file="$1"
  local expected_fpr="${SAGERNET_GPG_FINGERPRINT^^}"
  if [[ -z "${expected_fpr}" || ! "${expected_fpr}" =~ ^[0-9A-F]{40}$ ]]; then
    die "预设 SAGERNET_GPG_FINGERPRINT 格式非法: ${SAGERNET_GPG_FINGERPRINT}"
  fi

  require_cmd gpg
  local colons pub_count actual_fpr
  colons="$(gpg --batch --no-tty --with-colons --show-keys "${key_file}" 2>/dev/null || true)"
  pub_count="$(awk -F: '$1 == "pub" {c++} END {print c+0}' <<< "${colons}")"
  if (( pub_count != 1 )); then
    die "SagerNet GPG 公钥文件必须且仅能包含 1 把主公钥（实际检测到: ${pub_count}），拒绝信任！"
  fi

  actual_fpr="$(awk -F: '$1 == "pub" {in_pub=1; next} in_pub && $1 == "fpr" {print toupper($10); exit}' <<< "${colons}")"
  if [[ "${actual_fpr}" != "${expected_fpr}" ]]; then
    die "SagerNet APT GPG 公钥指纹校验失败！预期: ${expected_fpr}，实际: ${actual_fpr:-无法解析}"
  fi
}

export_clean_sagernet_gpg_key() {
  local in_file="$1"
  local out_file="$2"
  local expected_fpr="${SAGERNET_GPG_FINGERPRINT^^}"

  # 1. 拦截单块多钥与二进制多钥并核对主公钥指纹
  verify_sagernet_gpg_key "${in_file}"

  # 2. 导入隔离临时 GNUPGHOME，仅按预期指纹最小化重新导出，剥离任何额外拼接块与第三方签名
  local tmp_gnupg
  make_temp_gpg_home tmp_gnupg
  gpg --batch --no-tty --homedir "${tmp_gnupg}" --import "${in_file}" >/dev/null 2>&1
  mkdir -p "$(dirname "${out_file}")"
  gpg --batch --no-tty --homedir "${tmp_gnupg}" \
    --armor --export-options export-minimal \
    --export "0x${expected_fpr}" > "${out_file}"
  if command -v gpgconf >/dev/null 2>&1; then
    gpgconf --homedir "${tmp_gnupg}" --kill all >/dev/null 2>&1 || true
  fi

  # 3. 对最终写出的 keyring 执行复核：确保非空、仅单个 PGP 块且单主钥指纹完全一致
  [[ -s "${out_file}" ]] || die "重新导出的 SagerNet GPG 公钥为空！"
  local block_count
  block_count="$(grep -c '^-----BEGIN PGP PUBLIC KEY BLOCK-----' "${out_file}" || true)"
  if (( block_count != 1 )); then
    die "重新导出的 SagerNet GPG 公钥块数量异常: ${block_count}"
  fi
  verify_sagernet_gpg_key "${out_file}"
}

setup_sagernet_apt_repo() {
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1
  local tmp_gpg_raw tmp_gpg_clean
  make_temp_file tmp_gpg_raw
  make_temp_file tmp_gpg_clean
  curl -fsSL https://sing-box.app/gpg.key -o "${tmp_gpg_raw}"
  export_clean_sagernet_gpg_key "${tmp_gpg_raw}" "${tmp_gpg_clean}"

  mkdir -p /etc/apt/keyrings
  install -m 644 -o root -g root "${tmp_gpg_clean}" /etc/apt/keyrings/sagernet.asc

  cat > /etc/apt/sources.list.d/sagernet.sources <<'EOF'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF

  apt-get update -qq
}

# 将目标版本 deb 包下载并仅解压至隔离目录（不执行包维护脚本、不触碰运行中二进制），用于升级前离线预检
stage_singbox_candidate_deb() {
  local target_ver="$1"
  local stage_dir="$2"
  if ! is_valid_semver "${target_ver}"; then
    die "目标 sing-box 版本格式非法（须形如 x.y.z）: ${target_ver}"
  fi
  require_cmd dpkg-deb
  mkdir -p "${stage_dir}"
  chmod 700 "${stage_dir}"

  local staged_deb="${stage_dir}/sing-box.deb"
  if [[ -n "${SINGTUN_STAGE_DEB_PATH_OVERRIDE:-}" ]]; then
    [[ -f "${SINGTUN_STAGE_DEB_PATH_OVERRIDE}" ]] || die "预设测试 deb 包不存在: ${SINGTUN_STAGE_DEB_PATH_OVERRIDE}"
    cp -f "${SINGTUN_STAGE_DEB_PATH_OVERRIDE}" "${staged_deb}"
  else
    local arch_id
    arch_id="$(detect_arch)"
    setup_sagernet_apt_repo
    local exact_pkg_ver
    exact_pkg_ver="$(match_apt_singbox_version "${target_ver}")"
    if [[ -n "${exact_pkg_ver}" ]]; then
      local dl_dir
      make_temp_dir dl_dir
      if id -u _apt >/dev/null 2>&1; then
        chown _apt:root "${dl_dir}"
      fi
      chmod 700 "${dl_dir}"
      (
        cd "${dl_dir}"
        apt-get download -qq "sing-box=${exact_pkg_ver}"
      )
      local fetched_deb=""
      shopt -s nullglob
      for fetched_deb in "${dl_dir}"/sing-box_*.deb; do
        break
      done
      shopt -u nullglob
      [[ -n "${fetched_deb}" && -f "${fetched_deb}" && ! -L "${fetched_deb}" ]] || die "APT 下载 sing-box=${exact_pkg_ver} 失败！"
      install -m 600 -o root -g root "${fetched_deb}" "${staged_deb}"
      rm -rf -- "${dl_dir}"
    else
      log_info "APT 索引未包含固定版本 ${target_ver}，改从 SagerNet 官方 GitHub Release 下载对应 deb 包并强制校验 SHA256..."
      local deb_name="sing-box_${target_ver}_linux_${arch_id}.deb"
      local base_url="https://github.com/SagerNet/sing-box/releases/download/v${target_ver}"
      curl -fsSL "${base_url}/${deb_name}" -o "${staged_deb}"
      verify_singbox_deb "${staged_deb}" "${target_ver}" "${arch_id}"
    fi
  fi

  rm -rf "${stage_dir}/rootfs"
  mkdir -p "${stage_dir}/rootfs"
  dpkg-deb -x "${staged_deb}" "${stage_dir}/rootfs"

  local cand_bin="${stage_dir}/rootfs/usr/bin/sing-box"
  if [[ ! -x "${cand_bin}" ]]; then
    die "候选安装包中未找到可执行文件 /usr/bin/sing-box (${staged_deb})"
  fi
  local cand_ver
  cand_ver="$("${cand_bin}" version 2>/dev/null | awk '/^sing-box version/ {print $3}' || true)"
  if [[ "${cand_ver}" != "${target_ver}" ]]; then
    die "候选 sing-box 二进制汇报版本 (${cand_ver:-?}) 与目标版本 (${target_ver}) 不匹配！"
  fi
  log_info "候选 sing-box ${target_ver} 二进制已暂存并校验版本匹配: ${cand_bin}"
}

# 安装已校验的暂存 deb 包，期间抑制包维护脚本自动重启旧配置（由后续 deploy_singbox_and_verify 原子切换并重启）
install_staged_singbox_deb() {
  local staged_deb="$1"
  [[ -f "${staged_deb}" ]] || die "未找到已暂存的 sing-box deb 包: ${staged_deb}"

  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1
  apt-mark unhold sing-box >/dev/null 2>&1 || true

  local policy_rc="/usr/sbin/policy-rc.d"
  local created_policy="false"
  if [[ ! -e "${policy_rc}" && ! -L "${policy_rc}" ]]; then
    printf '#!/bin/sh\nexit 101\n' > "${policy_rc}"
    chmod 755 "${policy_rc}"
    register_cleanup_path "${policy_rc}"
    created_policy="true"
  fi

  local dpkg_rc=0
  dpkg -i --force-downgrade "${staged_deb}" || dpkg_rc=$?

  if [[ "${created_policy}" == "true" ]]; then
    rm -f "${policy_rc}"
  fi

  if (( dpkg_rc != 0 )); then
    die "安装暂存 sing-box deb 包失败 (exit code: ${dpkg_rc})"
  fi

  apt-mark hold sing-box >/dev/null 2>&1 || true
  log_info "已锁定 sing-box 版本: $(sing-box version | head -n 1)"
}

install_or_switch_singbox_version() {
  local target_ver="${1:-${SINGBOX_VERSION}}"
  if ! is_valid_semver "${target_ver}"; then
    die "目标 sing-box 版本格式非法（须形如 x.y.z）: ${target_ver}"
  fi

  local current_ver=""
  if command -v sing-box >/dev/null 2>&1; then
    current_ver="$(sing-box version 2>/dev/null | awk '/^sing-box version/ {print $3}' || true)"
  fi

  if [[ "${current_ver}" == "${target_ver}" ]]; then
    apt-mark hold sing-box >/dev/null 2>&1 || true
    log_info "sing-box 已安装且版本匹配 (${target_ver})。"
    return 0
  fi

  log_info "配置 SagerNet 官方 APT 仓库并安装/切换 sing-box ${target_ver} (当前: ${current_ver:-未安装})..."
  local stage_dir
  make_temp_dir stage_dir
  stage_singbox_candidate_deb "${target_ver}" "${stage_dir}"
  install_staged_singbox_deb "${stage_dir}/sing-box.deb"
}

install_dependencies_and_singbox() {
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1
  apt-get update -qq
  apt-get install -y -qq curl ca-certificates gnupg jq nginx qrencode

  ensure_singbox_user
  install_or_switch_singbox_version "${SINGBOX_VERSION}"
}

deploy_nginx() {
  log_info "部署本机 Nginx 回落站点 (127.0.0.1:${REALITY_HANDSHAKE_PORT})..."

  # 1. 新站点内容渲染到同一文件系统下的全新暂存目录（严格无符号链接，不跟随软链执行 chmod）
  local www_new="${WEB_ROOT}.singtun-new"
  local www_old="${WEB_ROOT}.singtun-old"
  rm -rf "${www_new}" "${www_old}"
  register_cleanup_path "${www_new}"
  render_fallback_site "${www_new}"
  find "${www_new}" -type l -delete
  chown -RP www-data:www-data "${www_new}"
  find "${www_new}" -type d -exec chmod 0755 {} +
  find "${www_new}" -type f -exec chmod 0644 {} +

  # 2. 渲染站点配置到临时文件并备份当前配置
  local nginx_bak_dir site_tmp
  make_temp_dir nginx_bak_dir
  make_temp_file site_tmp
  render_nginx_site_config "${site_tmp}"
  assert_no_unreplaced_placeholders "${site_tmp}"

  local had_site="false" had_main_conf="false" had_tuning_conf="false"
  local nginx_main_conf="/etc/nginx/nginx.conf"
  local nginx_tuning_conf="/etc/nginx/modules-enabled/99-singtun-tuning.conf"
  local nginx_systemd_dir="/etc/systemd/system/nginx.service.d"
  local nginx_systemd_dropin="${nginx_systemd_dir}/singtun.conf"
  if [[ -f "${NGINX_SITE_AVAILABLE}" ]]; then
    cp -a "${NGINX_SITE_AVAILABLE}" "${nginx_bak_dir}/site.conf"
    had_site="true"
  fi
  if [[ -f "${nginx_main_conf}" ]]; then
    cp -a "${nginx_main_conf}" "${nginx_bak_dir}/nginx.conf"
    had_main_conf="true"
  fi
  if [[ -f "${nginx_tuning_conf}" ]]; then
    cp -a "${nginx_tuning_conf}" "${nginx_bak_dir}/tuning.conf"
    had_tuning_conf="true"
  fi

  # 3. 提升 Nginx 文件描述符上限与单 worker 并发容量（防止 1C 低配机默认 768 连接池被慢速探测耗尽）
  mkdir -p "${nginx_systemd_dir}"
  local desired_ng_dropin=$'# Managed by singtun (40-deploy-server.sh)\n[Service]\nLimitNOFILE=65535'
  if [[ ! -f "${nginx_systemd_dropin}" ]] || [[ "$(<"${nginx_systemd_dropin}")" != "${desired_ng_dropin}" ]]; then
    printf '%s\n' "${desired_ng_dropin}" > "${nginx_systemd_dropin}"
    chmod 644 "${nginx_systemd_dropin}"
    systemctl daemon-reload
  fi
  if [[ -d "/etc/nginx/modules-enabled" ]]; then
    printf '# Managed by singtun (40-deploy-server.sh)\nworker_rlimit_nofile 65535;\n' > "${nginx_tuning_conf}"
    chmod 644 "${nginx_tuning_conf}"
  fi
  if [[ -f "${nginx_main_conf}" ]] && grep -Eq '^[[:space:]]*worker_connections[[:space:]]+768;' "${nginx_main_conf}"; then
    sed -i -E 's/^([[:space:]]*)worker_connections[[:space:]]+768;.*$/\1worker_connections 4096; # singtun-tuned-from-768/' "${nginx_main_conf}"
  fi

  # 4. 安装新配置与站点内容
  install -m 644 -o root -g root "${site_tmp}" "${NGINX_SITE_AVAILABLE}"
  # 移除默认站点，防止 Nginx 监听公网 80 端口
  rm -f /etc/nginx/sites-enabled/default
  ln -sfn "${NGINX_SITE_AVAILABLE}" "${NGINX_SITE_ENABLED}"

  if [[ -d "${WEB_ROOT}" ]]; then
    mv "${WEB_ROOT}" "${www_old}"
  fi
  mv "${www_new}" "${WEB_ROOT}"

  # 5. 校验并重载；失败则恢复上一份可用配置与站点内容
  if ! nginx -t || ! { systemctl enable --now nginx && systemctl reload nginx; }; then
    log_error "Nginx 配置校验或重载失败，正在回滚至上一份可用配置..."
    if [[ "${had_site}" == "true" ]]; then
      cp -a "${nginx_bak_dir}/site.conf" "${NGINX_SITE_AVAILABLE}"
    else
      rm -f "${NGINX_SITE_ENABLED}" "${NGINX_SITE_AVAILABLE}"
    fi
    if [[ "${had_main_conf}" == "true" ]]; then
      cp -a "${nginx_bak_dir}/nginx.conf" "${nginx_main_conf}"
    fi
    if [[ "${had_tuning_conf}" == "true" ]]; then
      cp -a "${nginx_bak_dir}/tuning.conf" "${nginx_tuning_conf}"
    else
      rm -f "${nginx_tuning_conf}"
    fi
    rm -rf "${WEB_ROOT}"
    if [[ -d "${www_old}" ]]; then
      mv "${www_old}" "${WEB_ROOT}"
    fi
    if nginx -t >/dev/null 2>&1; then
      systemctl reload nginx 2>/dev/null || true
    fi
    die "Nginx 部署失败，已回滚。"
  fi

  rm -rf "${www_old}"
}

check_listeners() {
  if ! command -v ss >/dev/null 2>&1; then
    return 0
  fi

  local enable_hy2="${ENABLE_HY2:-false}"
  local _ hs_lines
  for _ in 1 2 3 4 5; do
    local nginx_ok="false" sb_ok="false" hy2_ok="true"
    hs_lines="$(ss -H -tln "sport = :${REALITY_HANDSHAKE_PORT}" 2>/dev/null || true)"
    if [[ -n "${hs_lines}" ]] \
      && grep -Fq "127.0.0.1:${REALITY_HANDSHAKE_PORT}" <<< "${hs_lines}" \
      && awk -v expected_addr="127.0.0.1:${REALITY_HANDSHAKE_PORT}" 'NF > 0 && $4 != expected_addr {bad=1} END {exit bad+0}' <<< "${hs_lines}"; then
      nginx_ok="true"
    fi
    if ss -H -tln "sport = :${VLESS_PORT}" 2>/dev/null | grep -Eq ":${VLESS_PORT}([[:space:]]|$)"; then
      sb_ok="true"
    fi
    if [[ "${enable_hy2}" == "true" ]]; then
      hy2_ok="false"
      if ss -H -uln "sport = :${HY2_PORT}" 2>/dev/null | grep -Eq ":${HY2_PORT}([[:space:]]|$)"; then
        hy2_ok="true"
      fi
    fi
    if [[ "${nginx_ok}" == "true" && "${sb_ok}" == "true" && "${hy2_ok}" == "true" ]]; then
      return 0
    fi
    sleep 1
  done

  hs_lines="$(ss -H -tln "sport = :${REALITY_HANDSHAKE_PORT}" 2>/dev/null || true)"
  if ! grep -Fq "127.0.0.1:${REALITY_HANDSHAKE_PORT}" <<< "${hs_lines}"; then
    log_error "Nginx 未在 127.0.0.1:${REALITY_HANDSHAKE_PORT} 正常监听！"
  elif ! awk -v expected_addr="127.0.0.1:${REALITY_HANDSHAKE_PORT}" 'NF > 0 && $4 != expected_addr {bad=1} END {exit bad+0}' <<< "${hs_lines}"; then
    log_error "检测到 REALITY_HANDSHAKE_PORT (${REALITY_HANDSHAKE_PORT}) 暴露在非回环地址: ${hs_lines}"
  fi
  if ! ss -H -tln "sport = :${VLESS_PORT}" 2>/dev/null | grep -Eq ":${VLESS_PORT}([[:space:]]|$)"; then
    log_error "sing-box 未在 TCP ${VLESS_PORT} 正常监听！"
  fi
  if [[ "${enable_hy2}" == "true" ]] && ! ss -H -uln "sport = :${HY2_PORT}" 2>/dev/null | grep -Eq ":${HY2_PORT}([[:space:]]|$)"; then
    log_error "sing-box 未在 UDP ${HY2_PORT} (Hysteria2) 正常监听！"
  fi
  return 1
}

rollback_singbox() {
  local backup_dir="$1"
  log_error "sing-box 部署或运行校验失败，正在回滚至上一份可用配置..."
  if [[ -n "${backup_dir}" && -d "${backup_dir}" ]]; then
    rm -rf "${SINGBOX_ETC_DIR}"
    mv "${backup_dir}" "${SINGBOX_ETC_DIR}"
    if compgen -G "${SINGBOX_ETC_DIR}/*.json" >/dev/null 2>&1; then
      systemctl restart sing-box 2>/dev/null || true
    fi
  fi
}

deploy_singbox_and_verify() {
  log_info "渲染并校验 sing-box 服务端配置..."
  local staging_dir
  make_temp_dir staging_dir

  render_singbox_server_config "${staging_dir}"
  local check_out=""
  if ! check_out="$(sing-box check -C "${staging_dir}" 2>&1)"; then
    log_error "${check_out}"
    die "服务端配置未通过 sing-box check 校验！"
  fi
  if grep -Eiq '(deprecated|warn)' <<< "${check_out}"; then
    log_error "${check_out}"
    die "服务端配置存在 sing-box 弃用或警告项！"
  fi
  log_info "sing-box check 校验通过（零弃用警告）。"

  local backup_dir=""
  if [[ -d "${SINGBOX_ETC_DIR}" ]]; then
    backup_dir="/etc/sing-box.bak.$$"
    rm -rf "${backup_dir}"
    cp -a "${SINGBOX_ETC_DIR}" "${backup_dir}"
    register_cleanup_path "${backup_dir}"
  fi

  mkdir -p "${SINGBOX_ETC_DIR}"
  rm -f "${SINGBOX_ETC_DIR}"/*.json
  cp -f "${staging_dir}"/*.json "${SINGBOX_ETC_DIR}/"
  chown -R root:sing-box "${SINGBOX_ETC_DIR}"
  chmod 750 "${SINGBOX_ETC_DIR}"
  chmod 640 "${SINGBOX_ETC_DIR}"/*.json

  # 安装 systemd 覆盖配置（非 root + CAP_NET_BIND_SERVICE + 沙箱加固，仅在内容变化时 daemon-reload）
  mkdir -p "${SYSTEMD_OVERRIDE_DIR}"
  if [[ ! -f "${SYSTEMD_OVERRIDE_DIR}/override.conf" ]] || ! cmp -s "${SERVER_TPL_DIR}/systemd/sing-box.service" "${SYSTEMD_OVERRIDE_DIR}/override.conf"; then
    cp -f "${SERVER_TPL_DIR}/systemd/sing-box.service" "${SYSTEMD_OVERRIDE_DIR}/override.conf"
    systemctl daemon-reload
  fi
  if ! systemctl is-enabled --quiet sing-box 2>/dev/null; then
    systemctl enable sing-box
  fi

  # 重启后统一校验存活状态 (is-active) 与端口监听，失败自动回滚
  if ! systemctl restart sing-box; then
    rollback_singbox "${backup_dir}"
    die "sing-box systemctl restart 失败，已执行回滚。"
  fi

  sleep 1
  if ! systemctl is-active --quiet sing-box; then
    journalctl -u sing-box -n 25 --no-pager >&2 || true
    rollback_singbox "${backup_dir}"
    die "sing-box 启动后进程退出 (非 active 状态)，已执行回滚。"
  fi

  if ! check_listeners; then
    journalctl -u sing-box -n 25 --no-pager >&2 || true
    rollback_singbox "${backup_dir}"
    die "服务端端口监听核验未通过，已执行回滚。"
  fi

  # 校验 systemd 单元与运行中进程 /proc/<pid>/status 的实际生效能力集已精确收敛为仅 CAP_NET_BIND_SERVICE (0x400)
  local cap_bound cap_ambient main_pid cap_eff
  cap_bound="$(systemctl show sing-box -p CapabilityBoundingSet --value 2>/dev/null || true)"
  cap_ambient="$(systemctl show sing-box -p AmbientCapabilities --value 2>/dev/null || true)"
  if [[ "${cap_bound}" != "cap_net_bind_service" || "${cap_ambient}" != "cap_net_bind_service" ]]; then
    rollback_singbox "${backup_dir}"
    die "sing-box 生效能力集未收敛（Bounding: ${cap_bound:-?}；Ambient: ${cap_ambient:-?}），请检查 ${SYSTEMD_OVERRIDE_DIR}/override.conf。"
  fi

  main_pid="$(systemctl show sing-box -p MainPID --value 2>/dev/null || true)"
  if [[ -z "${main_pid}" || "${main_pid}" == "0" || ! -r "/proc/${main_pid}/status" ]]; then
    rollback_singbox "${backup_dir}"
    die "无法读取运行中 sing-box 进程 (MainPID=${main_pid:-?}) 的 /proc 状态以核验 CapEff，已执行回滚。"
  fi
  cap_eff="$(awk '/^CapEff:/ {print tolower($2)}' "/proc/${main_pid}/status" 2>/dev/null || true)"
  if [[ ! "${cap_eff}" =~ ^[0-9a-f]+$ ]] || (( 16#${cap_eff} != 16#400 )); then
    rollback_singbox "${backup_dir}"
    die "sing-box 进程实测 CapEff 异常 (${cap_eff:-?})，预期仅为 CAP_NET_BIND_SERVICE (0x400)，已执行回滚。"
  fi

  if [[ -n "${backup_dir}" && -d "${backup_dir}" ]]; then
    rm -rf "${backup_dir}"
  fi
  if [[ "${ENABLE_HY2:-false}" == "true" ]]; then
    log_info "端口监听与进程存活核验通过: Nginx (127.0.0.1:${REALITY_HANDSHAKE_PORT}), sing-box (TCP ${VLESS_PORT}, UDP ${HY2_PORT})"
  else
    log_info "端口监听与进程存活核验通过: Nginx (127.0.0.1:${REALITY_HANDSHAKE_PORT}), sing-box (TCP ${VLESS_PORT})"
  fi
}

main() {
  if [[ "${1:-}" == "--verify-deb-only" ]]; then
    local deb_path="${2:-}" ver="${3:-}" arch="${4:-}"
    [[ -f "${deb_path}" && -n "${ver}" && -n "${arch}" ]] || die "用法: $0 --verify-deb-only <deb_path> <version> <arch>"
    verify_singbox_deb "${deb_path}" "${ver}" "${arch}"
    log_info "sing-box deb 哈希校验通过: ${deb_path}"
    return 0
  fi

  if [[ "${1:-}" == "--verify-gpg-only" ]]; then
    local gpg_path="${2:-}"
    [[ -f "${gpg_path}" ]] || die "用法: $0 --verify-gpg-only <gpg_key_path>"
    verify_sagernet_gpg_key "${gpg_path}"
    log_info "SagerNet GPG 公钥指纹校验通过: ${gpg_path}"
    return 0
  fi

  if [[ "${1:-}" == "--export-clean-gpg" ]]; then
    local gpg_in="${2:-}" gpg_out="${3:-}"
    [[ -f "${gpg_in}" && -n "${gpg_out}" ]] || die "用法: $0 --export-clean-gpg <in_gpg_path> <out_gpg_path>"
    export_clean_sagernet_gpg_key "${gpg_in}" "${gpg_out}"
    log_info "SagerNet GPG 公钥校验并净化导出完成: ${gpg_out}"
    return 0
  fi

  load_env
  require_vars \
    SINGBOX_VERSION \
    SERVER_IP \
    SERVER_DOMAIN \
    SERVER_IPV6 \
    VLESS_PORT \
    REALITY_HANDSHAKE_PORT \
    REALITY_PRIVATE_KEY \
    REALITY_SHORT_ID \
    SUB_PATH_PREFIX

  if ! is_valid_ipv4 "${SERVER_IP}"; then
    die "SERVER_IP 不是合法的 IPv4 地址: ${SERVER_IP}"
  fi
  if is_non_public_ipv4 "${SERVER_IP}" "false"; then
    die "SERVER_IP 不能为内网、回环、保留或广播地址: ${SERVER_IP}"
  fi
  if ! is_valid_domain "${SERVER_DOMAIN}"; then
    die "SERVER_DOMAIN 不是合法的小写域名（如 node.example.com）: ${SERVER_DOMAIN}"
  fi

  if [[ "${1:-}" == "--render-only" ]]; then
    local target_dir="${2:-}"
    if [[ -z "${target_dir}" ]]; then
      die "用法: $0 --render-only <target_dir>"
    fi
    require_cmd jq
    render_singbox_server_config "${target_dir}/singbox"
    render_nginx_site_config "${target_dir}/nginx/site.conf"
    render_fallback_site "${target_dir}/www"
    log_info "服务端配置（sing-box + Nginx + 静态站点）已渲染至: ${target_dir}"
    return 0
  fi

  if [[ "${1:-}" == "--sync-singbox-only" ]]; then
    require_root
    acquire_singtun_lock
    require_cmd jq sing-box
    deploy_singbox_and_verify
    log_info "sing-box 入站订阅用户同步完成（已重启 sing-box）。"
    return 0
  fi

  if [[ "${1:-}" == "--install-singbox-version" ]]; then
    local req_ver="${2:-}"
    [[ -n "${req_ver}" ]] || die "用法: $0 --install-singbox-version <version>"
    require_root
    acquire_singtun_lock
    detect_os >/dev/null
    detect_arch >/dev/null
    install_or_switch_singbox_version "${req_ver}"
    return 0
  fi

  if [[ "${1:-}" == "--stage-singbox" ]]; then
    local req_ver="${2:-}" stage_dir="${3:-}"
    [[ -n "${req_ver}" && -n "${stage_dir}" ]] || die "用法: $0 --stage-singbox <version> <stage_dir>"
    if [[ -z "${SINGTUN_STAGE_DEB_PATH_OVERRIDE:-}" ]]; then
      require_root
      detect_os >/dev/null
    fi
    acquire_singtun_lock
    stage_singbox_candidate_deb "${req_ver}" "${stage_dir}"
    return 0
  fi

  if [[ "${1:-}" == "--upgrade-singbox" ]]; then
    local staged_deb="${2:-}"
    require_root
    acquire_singtun_lock
    detect_os >/dev/null
    detect_arch >/dev/null
    ensure_singbox_user
    require_cmd jq
    if [[ -n "${staged_deb}" ]]; then
      install_staged_singbox_deb "${staged_deb}"
    else
      install_or_switch_singbox_version "${SINGBOX_VERSION}"
    fi
    if is_server_deployed; then
      deploy_singbox_and_verify
      bash "${SCRIPT_DIR}/50-gen-clients.sh"
    else
      bash "${SCRIPT_DIR}/50-gen-clients.sh" --local-only
    fi
    log_info "sing-box 升级与配置同步完成 (${SINGBOX_VERSION})。"
    return 0
  fi

  require_root
  acquire_singtun_lock
  detect_os >/dev/null
  detect_arch >/dev/null

  install_dependencies_and_singbox
  deploy_nginx
  deploy_singbox_and_verify
  bash "${SCRIPT_DIR}/50-gen-clients.sh"

  log_info "服务端部署完成 (40-deploy-server 完成)。"
}

main "$@"
