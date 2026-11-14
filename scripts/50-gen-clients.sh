#!/usr/bin/env bash
# scripts/50-gen-clients.sh — 为每条订阅生成 4 种客户端格式（v2ray Base64 / sing-box JSON / mihomo YAML / Shadowrocket conf），并通过符号链接原子发布
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

CLIENT_TPL_DIR="${REPO_ROOT}/templates/client"
OUT_ROOT="${PRIVATE_DIR}/out"
SUB_WEB_BASE="${SINGTUN_SUB_WEB_BASE_OVERRIDE:-/var/lib/singtun}"
SUB_WEB_LINK="${SUB_WEB_BASE}/sub-web"
SUB_RELEASES_DIR="${SUB_WEB_BASE}/releases"

DEFAULT_RULESET_SR_CN_DOMAIN="https://raw.githubusercontent.com/Loyalsoldier/surge-rules/d2ff19cde30a09df3e6a527cb3996ccd506cbfea/direct.txt"
DEFAULT_RULESET_MIHOMO_GEOSITE_CN="https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/458e716abd80ff8c6aee2b7d15c4f94b20e9d279/geo/geosite/cn.mrs"
DEFAULT_RULESET_MIHOMO_GEOIP_CN="https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/458e716abd80ff8c6aee2b7d15c4f94b20e9d279/geo/geoip/cn.mrs"

verify_mihomo_gz() {
  local gz_file="$1"
  local ver="$2"
  local arch="$3"

  local expected_sha
  expected_sha="$(lookup_mihomo_gz_sha256 "${ver}" "${arch}")"
  if [[ -z "${expected_sha}" ]]; then
    die "未找到 mihomo (${ver}, ${arch}) 的预设 SHA256（请检查 ${MIHOMO_CHECKSUM_FILE}），拒绝无校验使用！"
  fi

  local actual_sha
  actual_sha="$(sha256sum "${gz_file}" | awk '{print tolower($1)}')"
  if [[ "${actual_sha}" != "${expected_sha}" ]]; then
    die "mihomo 压缩包 SHA256 校验失败！预期: ${expected_sha}，实际: ${actual_sha}"
  fi
}

build_client_hy2_outbound_json() {
  local uuid="$1"
  local pass obfs_enabled="false" obfs_pass=""
  pass="$(derive_hy2_password "${uuid}")"
  if [[ "${HY2_OBFS:-false}" == "true" ]]; then
    obfs_enabled="true"
    obfs_pass="$(derive_hy2_obfs_password)"
  fi
  local hop_range=""
  if [[ -n "${HY2_HOP_PORTS:-}" ]]; then
    hop_range="${HY2_HOP_PORTS//-/:}"
  fi
  local up_mbps="${HY2_UP_MBPS:-0}"
  local down_mbps="${HY2_DOWN_MBPS:-0}"

  SUB_HY2_PASS="${pass}" SUB_HY2_OBFS="${obfs_pass}" jq -n \
    --arg server "${SERVER_IP}" \
    --argjson server_port "${HY2_PORT:-8443}" \
    --arg hop_range "${hop_range}" \
    --argjson up_mbps "${up_mbps}" \
    --argjson down_mbps "${down_mbps}" \
    --arg server_name "${SERVER_DOMAIN}" \
    --argjson obfs_on "${obfs_enabled}" \
    '{
      type: "hysteria2",
      tag: "hy2-out",
      server: $server,
      password: $ENV.SUB_HY2_PASS,
      tls: {
        enabled: true,
        server_name: $server_name,
        alpn: ["h3"]
      }
    }
    | if $obfs_on then
        . + {obfs: {type: "salamander", password: $ENV.SUB_HY2_OBFS}}
      else
        .
      end
    | if ($hop_range != "") then
        . + {server_ports: [$hop_range], hop_interval: "30s"}
      else
        . + {server_port: $server_port}
      end
    | if ($up_mbps > 0 and $down_mbps > 0) then
        . + {up_mbps: $up_mbps, down_mbps: $down_mbps}
      else
        .
      end'
}

# Apple iCloud Private Relay 金丝雀与控制面域名（按官方网络规范返回 NXDOMAIN 并在路由层 REJECT，防止 iOS/macOS Safari 启用 MASQUE UDP 443 死锁或改变固定出口）
PRIVATE_RELAY_CANARY_DOMAINS=(
  "mask.icloud.com"
  "mask-h2.icloud.com"
  "mask-api.icloud.com"
)

# 上游 geosite-cn / direct.txt 历史遗留 @cn 误判的海外核心域名后缀（三端同源前置：远端加密 DoH + UDP 443 REJECT + PROXY）
OVERSEAS_PROXY_PRIORITY_SUFFIXES=(
  "google" "google.com" "gstatic.com" "googleapis.com"
  "googleusercontent.com" "ggpht.com" "1e100.net"
  "gvt1.com" "gvt2.com" "gvt3.com"
  "appspot.com" "firebaseio.com" "firebaseapp.com"
  "crashlytics.com" "app-analytics-services.com" "app-measurement.com"
  "googletagmanager.com" "googletagservices.com" "google-analytics.com"
  "googlesyndication.com" "doubleclick.net" "2mdn.net"
  "recaptcha.net" "pki.goog" "ampproject.org" "android.com"
)

render_sub_singbox_json() {
  local uuid="$1"
  local out_file="$2"

  local dns_strategy="ipv4_only"
  local reject_ipv6="true"
  if [[ "${SERVER_IPV6:-false}" == "true" ]]; then
    dns_strategy="prefer_ipv4"
    reject_ipv6="false"
  fi

  local compat_mode="${SINGBOX_CLIENT_COMPAT:-1.14}"
  local enable_hy2="false"
  local hy2_outbound="null"
  if [[ "${ENABLE_HY2:-false}" == "true" ]]; then
    require_vars HY2_PORT
    enable_hy2="true"
    hy2_outbound="$(build_client_hy2_outbound_json "${uuid}")"
  fi

  local canary_json overseas_suffixes_json
  canary_json="$(printf '%s\n' "${PRIVATE_RELAY_CANARY_DOMAINS[@]}" | jq -R . | jq -s .)"
  overseas_suffixes_json="$(printf '%s\n' "${OVERSEAS_PROXY_PRIORITY_SUFFIXES[@]}" | jq -R . | jq -s .)"

  local -a self_cidrs=("${SERVER_IP}/32")
  local v6_cidr
  while IFS= read -r v6_cidr; do
    [[ -n "${v6_cidr}" ]] && self_cidrs+=("${v6_cidr}")
  done < <(collect_server_self_ipv6_cidrs)
  local self_cidrs_json
  self_cidrs_json="$(printf '%s\n' "${self_cidrs[@]}" | jq -R . | jq -sc .)"

  SUB_UUID="${uuid}" HY2_OUTBOUND_JSON="${hy2_outbound}" jq -s \
    --arg dns_remote "${DNS_REMOTE}" \
    --arg dns_direct "${DNS_DIRECT}" \
    --arg dns_strategy "${dns_strategy}" \
    --argjson reject_ipv6 "${reject_ipv6}" \
    --arg server_ip "${SERVER_IP}" \
    --argjson self_cidrs "${self_cidrs_json}" \
    --argjson server_port "${VLESS_PORT}" \
    --arg server_domain "${SERVER_DOMAIN}" \
    --arg utls_fp "${UTLS_FINGERPRINT}" \
    --arg reality_pub "${REALITY_PUBLIC_KEY}" \
    --arg reality_sid "${REALITY_SHORT_ID}" \
    --arg geosite_cn_url "${RULESET_GEOSITE_CN}" \
    --arg geoip_cn_url "${RULESET_GEOIP_CN}" \
    --arg compat "${compat_mode}" \
    --argjson enable_hy2 "${enable_hy2}" \
    --argjson canary_domains "${canary_json}" \
    --argjson overseas_proxy_suffixes "${overseas_suffixes_json}" \
    '(
      .[3].outbounds[0]
      | .server = $server_ip
      | .server_port = $server_port
      | .uuid = $ENV.SUB_UUID
      | .tls.server_name = $server_domain
      | .tls.utls.fingerprint = $utls_fp
      | .tls.reality.public_key = $reality_pub
      | .tls.reality.short_id = $reality_sid
    ) as $vless_base
    | {
      log: {
        level: "info",
        timestamp: true
      },
      experimental: .[0].experimental,
      dns: (
        .[1].dns
        | .servers |= map(
            if .tag == "dns-remote" then .server = $dns_remote
            elif .tag == "dns-direct" then .server = $dns_direct
            else .
            end
          )
        | .rules |= (
            map(
              if (.action == "predefined" and .rcode == "NXDOMAIN") then
                .domain = $canary_domains
              elif (.server == "dns-remote" and has("domain_suffix")) then
                .domain_suffix = $overseas_proxy_suffixes
              else .
              end
            )
            | [{"domain": [$server_domain], "server": "dns-direct"}] + .
          )
        | .strategy = $dns_strategy
      ),
      inbounds: (
        .[2].inbounds
        | .[0].route_exclude_address = $self_cidrs
      ),
      outbounds: (
        if $enable_hy2 then
          [
            {
              type: "selector",
              tag: "proxy",
              outbounds: ["vless-out", "hy2-out", "auto"],
              default: "vless-out"
            },
            {
              type: "urltest",
              tag: "auto",
              outbounds: ["vless-out", "hy2-out"],
              url: "https://www.gstatic.com/generate_204",
              interval: "3m",
              tolerance: 50
            },
            ($vless_base | .tag = "vless-out"),
            ($ENV.HY2_OUTBOUND_JSON | fromjson),
            .[3].outbounds[1]
          ]
        else
          [
            $vless_base,
            .[3].outbounds[1]
          ]
        end
      ),
      http_clients: .[4].http_clients,
      route: (
        .[4].route
        | .default_domain_resolver.strategy = $dns_strategy
        | .rule_set |= map(
            if .tag == "geosite-cn" then .url = $geosite_cn_url
            elif .tag == "geoip-cn" then .url = $geoip_cn_url
            else .
            end
          )
        | .rules |= (
            map(
              if (.action == "reject" and has("domain")) then
                .domain = $canary_domains
              elif (.action == "reject" and .network == "udp" and .port == 443 and has("domain_suffix")) then
                .domain_suffix = $overseas_proxy_suffixes
              elif (.outbound == "proxy" and has("domain_suffix")) then
                .domain_suffix = $overseas_proxy_suffixes
              else .
              end
            )
            | (
                [to_entries[] | select((.value.ip_cidr // [] | index("100.64.0.0/10") != null) and .value.outbound == "direct") | .key][0]
                // error("route.rules 缺少 100.64.0.0/10 direct 锚点规则")
              ) as $anchor_idx
            | .[0:($anchor_idx + 1)]
              + [
                  {"domain": [$server_domain], "outbound": "direct"},
                  {"ip_cidr": $self_cidrs, "outbound": "direct"}
                ]
              + (if $reject_ipv6 then [{"ip_version": 6, "action": "reject"}] else [] end)
              + .[($anchor_idx + 1):]
          )
      )
    }
    | if $compat == "1.12" then
        del(.http_clients)
        | del(.route.default_http_client)
        | .route.rule_set |= map(del(.http_client) | . + {"download_detour": "proxy"})
      else
        .
      end' \
    "${CLIENT_TPL_DIR}/singbox/05-experimental.json" \
    "${CLIENT_TPL_DIR}/singbox/10-dns.json" \
    "${CLIENT_TPL_DIR}/singbox/20-inbound-tun.json" \
    "${CLIENT_TPL_DIR}/singbox/30-outbound-vless.json" \
    "${CLIENT_TPL_DIR}/singbox/40-route.json" > "${out_file}"
}

# Shadowrocket 国内底座基础设施与高频 CDN 后缀单一权威列表（同时渲染 [Rule] 兜底直连与 [Host] 国内加密 DoH）
# 准入边界：仅收录操作系统/Apple 核心国内服务、国家级支付清算、头部公有云/CDN 与国民级定位底座；
# 严禁收录长尾垂直应用或第三方广告/统计/P2P SDK 域名（长尾域名交由远程不可变 DOMAIN-SET 路由）。
SR_CN_FALLBACK_SUFFIXES=(
  # 百度
  "baidu.com" "bdstatic.com" "bdimg.com" "baidubce.com"
  # 腾讯 / 微信
  "qq.com" "weixin.qq.com" "weixin.com" "weixinbridge.com" "wechat.com" "servicewechat.com" "tenpay.com" "wechatpay.cn"
  "gtimg.cn" "gtimg.com" "qpic.cn" "qlogo.cn" "myqcloud.com" "tencent-cloud.net"
  # 阿里 / 淘宝 / 支付宝
  "taobao.com" "tmall.com" "alicdn.com" "alikunlun.com" "alikunlun.net"
  "tbcache.com" "mmstat.com" "alipay.com" "alipayobjects.com" "aliyuncs.com"
  "aliyun.com" "alibaba.com" "alibabausercontent.com" "myalicdn.com" "1688.com" "dingtalk.com"
  # 字节跳动 / 抖音 / 火山引擎
  "bytedance.com" "douyin.com" "douyinvod.com" "douyinpic.com" "douyincdn.com"
  "byteimg.com" "bytednsdoc.com" "pstatp.com" "snssdk.com" "amemv.com"
  "toutiao.com" "feishu.cn" "volces.com"
  # 哔哩哔哩
  "bilibili.com" "bilivideo.com" "bilivideo.cn" "biliapi.net" "biliapi.com" "hdslb.com"
  # 小红书 / 快手
  "xiaohongshu.com" "xhscdn.com" "kuaishou.com" "kwaicdn.com" "yximgs.com"
  # 京东 / 拼多多 / 美团
  "jd.com" "jd.hk" "360buy.com" "360buyimg.com" "jcloudcs.com"
  "pinduoduo.com" "yangkeduo.com" "pddpic.com"
  "meituan.com" "meituan.net" "dianping.com" "dpfile.com" "sankuai.com"
  # 网易 / 新浪 / 微博 / 知乎 / 豆瓣 / CSDN
  "163.com" "126.com" "126.net" "127.net" "netease.com"
  "sina.com.cn" "sinaimg.cn" "weibo.com" "weibo.cn" "weibocdn.com"
  "zhihu.com" "zhimg.com" "douban.com" "doubanio.com" "csdn.net"
  # 支付清算与国民级定位地图底座
  "95516.com" "amap.com" "autonavi.com"
  # 长视频 / 出行 / 终端厂商
  "iqiyi.com" "iqiyipic.com" "youku.com" "ykimg.com" "mgtv.com"
  "ctrip.com" "c-ctrip.com" "12306.cn"
  "xiaomi.com" "xiaomi.net" "mi.com" "mi-img.com" "miui.com"
  "huawei.com" "vmall.com" "dbankcdn.com" "hicloud.com" "apple.com.cn"
  # Apple App Store 与软件/静态资源下载 CDN（上游 DOMAIN-SET 判直连，同步走国内 DoH 命中大陆 CDN 边缘节点）
  "apps.apple.com" "itunes.apple.com" "mzstatic.com" "cdn-apple.com" "aaplimg.com"
  # Apple 定位、地图与全量天气（含 iOS 16+ WeatherKit，避免海外代理解析导致地理定位漂移或天气源失败）
  "ls.apple.com" "gs-loc.apple.com" "gs-loc-cn.apple.com" "iphone-ld.apple.com" "maps.apple.com" "apple-mapkit.com"
  "weatherkit.apple.com" "weather-data.apple.com" "weather-edge.apple.com" "weather-map.apple.com" "weather-map2.apple.com"
  # Apple 系统校时 (NTP UDP 123，避免落入 VLESS Vision 触发 UDP flow mismatch)、推送与账号配置初始化
  "time.apple.com" "time.asia.apple.com" "push.apple.com" "ess.apple.com" "configuration.apple.com" "xp.apple.com"
  "swallow.apple.com" "pancake.apple.com" "smp-device-content.apple.com" "ipcdn.apple.com" "init-p01md.apple.com" "cds.apple.com"
  "guzzoni.apple.com" "smoot.apple.com"
  # Apple 系统更新、固件分发与证书 OCSP/CRL 吊销校验
  "mesu.apple.com" "appldnld.apple.com" "swscan.apple.com" "swdist.apple.com" "swcdn.apple.com" "oscdn.apple.com"
  "ocsp.apple.com" "ocsp2.apple.com" "crl.apple.com" "certs.apple.com" "valid.apple.com"
  # Apple Game Center、官网商城支持与音乐/播客国内 CDN
  "gc.apple.com" "store.apple.com" "support.apple.com" "music.apple.com" "podcasts.apple.com"
)

render_mihomo_yaml() {
  local sub="$1"
  local uuid="$2"
  local out_file="$3"

  local ipv6_bool="false"
  local mihomo_ipv6_rule="- IP-CIDR6,::/0,REJECT,no-resolve"
  if [[ "${SERVER_IPV6:-false}" == "true" ]]; then
    ipv6_bool="true"
    mihomo_ipv6_rule="# SERVER_IPV6=true: 允许 IPv6 按规则分流"
  fi

  local node_tag="${SERVER_DOMAIN}-${sub}"
  local mihomo_geosite_url="${RULESET_MIHOMO_GEOSITE_CN:-${DEFAULT_RULESET_MIHOMO_GEOSITE_CN}}"
  local mihomo_geoip_url="${RULESET_MIHOMO_GEOIP_CN:-${DEFAULT_RULESET_MIHOMO_GEOIP_CN}}"

  local mihomo_hy2_proxy_block="  # ENABLE_HY2=false: 未启用 Hysteria2 备用节点"
  local mihomo_proxy_groups_block="  - name: PROXY
    type: select
    proxies:
      - \"${node_tag}\"
      - DIRECT"

  if [[ "${ENABLE_HY2:-false}" == "true" ]]; then
    require_vars HY2_PORT
    local hy2_tag="${SERVER_DOMAIN}-${sub}-hy2"
    local hy2_pass
    hy2_pass="$(derive_hy2_password "${uuid}")"
    mihomo_hy2_proxy_block="  - name: \"${hy2_tag}\"
    type: hysteria2
    server: \"${SERVER_IP}\"
    port: ${HY2_PORT}"
    if [[ -n "${HY2_HOP_PORTS:-}" ]]; then
      mihomo_hy2_proxy_block+=$'\n'"    ports: ${HY2_HOP_PORTS}"
      mihomo_hy2_proxy_block+=$'\n'"    hop-interval: 30"
    fi
    if [[ -n "${HY2_UP_MBPS:-}" && -n "${HY2_DOWN_MBPS:-}" ]]; then
      mihomo_hy2_proxy_block+=$'\n'"    up: \"${HY2_UP_MBPS} Mbps\""
      mihomo_hy2_proxy_block+=$'\n'"    down: \"${HY2_DOWN_MBPS} Mbps\""
    fi
    if [[ "${HY2_OBFS:-false}" == "true" ]]; then
      local hy2_obfs_pass
      hy2_obfs_pass="$(derive_hy2_obfs_password)"
      mihomo_hy2_proxy_block+=$'\n'"    obfs: salamander"
      mihomo_hy2_proxy_block+=$'\n'"    obfs-password: \"${hy2_obfs_pass}\""
    fi
    mihomo_hy2_proxy_block+=$'\n'"    password: \"${hy2_pass}\"
    sni: \"${SERVER_DOMAIN}\"
    alpn:
      - h3
    skip-cert-verify: false
    udp: true"

    mihomo_proxy_groups_block="  - name: PROXY
    type: select
    proxies:
      - \"${node_tag}\"
      - \"${hy2_tag}\"
      - AUTO
      - DIRECT
  - name: AUTO
    type: url-test
    url: https://www.gstatic.com/generate_204
    interval: 180
    tolerance: 50
    proxies:
      - \"${node_tag}\"
      - \"${hy2_tag}\""
  fi

  local mihomo_fake_ip_canaries="" mihomo_ns_policy_overrides="" mihomo_private_relay_rules="" mihomo_overseas_priority_rules=""
  local dom sfx
  for dom in "${PRIVATE_RELAY_CANARY_DOMAINS[@]}"; do
    [[ -n "${mihomo_fake_ip_canaries}" ]] && mihomo_fake_ip_canaries+=$'\n'
    mihomo_fake_ip_canaries+="    - \"${dom}\""
    [[ -n "${mihomo_ns_policy_overrides}" ]] && mihomo_ns_policy_overrides+=$'\n'
    mihomo_ns_policy_overrides+="    \"${dom}\": \"rcode://name_error\""
    [[ -n "${mihomo_private_relay_rules}" ]] && mihomo_private_relay_rules+=$'\n'
    mihomo_private_relay_rules+="  - DOMAIN,${dom},REJECT"
  done
  for sfx in "${OVERSEAS_PROXY_PRIORITY_SUFFIXES[@]}"; do
    [[ -n "${mihomo_ns_policy_overrides}" ]] && mihomo_ns_policy_overrides+=$'\n'
    mihomo_ns_policy_overrides+="    \"+.${sfx}\":"$'\n'"      - \"https://${DNS_REMOTE}/dns-query#PROXY\""
    [[ -n "${mihomo_overseas_priority_rules}" ]] && mihomo_overseas_priority_rules+=$'\n'
    mihomo_overseas_priority_rules+="  - AND,((NETWORK,UDP),(DST-PORT,443),(DOMAIN-SUFFIX,${sfx})),REJECT"$'\n'"  - DOMAIN-SUFFIX,${sfx},PROXY"
  done

  local mihomo_tun_route_exclude="    - ${SERVER_IP}/32"
  local mihomo_self_ip_direct_rules="  - IP-CIDR,${SERVER_IP}/32,DIRECT,no-resolve"
  local v6_cidr
  while IFS= read -r v6_cidr; do
    if [[ -n "${v6_cidr}" ]]; then
      mihomo_tun_route_exclude+=$'\n'"    - ${v6_cidr}"
      mihomo_self_ip_direct_rules+=$'\n'"  - IP-CIDR6,${v6_cidr},DIRECT,no-resolve"
    fi
  done < <(collect_server_self_ipv6_cidrs)

  shopt -u patsub_replacement 2>/dev/null || true
  local tpl
  tpl="$(<"${CLIENT_TPL_DIR}/mihomo.yaml")"
  tpl="${tpl//__MIHOMO_TUN_ROUTE_EXCLUDE__/"${mihomo_tun_route_exclude}"}"
  tpl="${tpl//__MIHOMO_SELF_IP_DIRECT_RULES__/"${mihomo_self_ip_direct_rules}"}"
  tpl="${tpl//__MIHOMO_FAKE_IP_FILTER_CANARIES__/"${mihomo_fake_ip_canaries}"}"
  tpl="${tpl//__MIHOMO_NAMESERVER_POLICY_OVERRIDES__/"${mihomo_ns_policy_overrides}"}"
  tpl="${tpl//__MIHOMO_PRIVATE_RELAY_RULES__/"${mihomo_private_relay_rules}"}"
  tpl="${tpl//__MIHOMO_OVERSEAS_PRIORITY_RULES__/"${mihomo_overseas_priority_rules}"}"
  tpl="${tpl//__MIHOMO_HY2_PROXY_BLOCK__/"${mihomo_hy2_proxy_block}"}"
  tpl="${tpl//__MIHOMO_PROXY_GROUPS_BLOCK__/"${mihomo_proxy_groups_block}"}"
  tpl="${tpl//__IPV6_BOOL__/"${ipv6_bool}"}"
  tpl="${tpl//__DNS_DIRECT__/"${DNS_DIRECT}"}"
  tpl="${tpl//__DNS_REMOTE__/"${DNS_REMOTE}"}"
  tpl="${tpl//__NODE_TAG__/"${node_tag}"}"
  tpl="${tpl//__SERVER_IP__/"${SERVER_IP}"}"
  tpl="${tpl//__VLESS_PORT__/"${VLESS_PORT}"}"
  tpl="${tpl//__SUB_UUID__/"${uuid}"}"
  tpl="${tpl//__SERVER_DOMAIN__/"${SERVER_DOMAIN}"}"
  tpl="${tpl//__UTLS_FP__/"${UTLS_FINGERPRINT}"}"
  tpl="${tpl//__REALITY_PUB__/"${REALITY_PUBLIC_KEY}"}"
  tpl="${tpl//__REALITY_SID__/"${REALITY_SHORT_ID}"}"
  tpl="${tpl//__RULESET_MIHOMO_GEOSITE_CN__/"${mihomo_geosite_url}"}"
  tpl="${tpl//__RULESET_MIHOMO_GEOIP_CN__/"${mihomo_geoip_url}"}"
  tpl="${tpl//__MIHOMO_IPV6_RULE__/"${mihomo_ipv6_rule}"}"
  printf '%s\n' "${tpl}" > "${out_file}"
  assert_no_unreplaced_placeholders "${out_file}"
}

render_shadowrocket_conf() {
  local tok="$1"
  local out_file="$2"
  local ipv6_bool="false"
  local sr_ipv6_rule="IP-CIDR6,::/0,REJECT,no-resolve"
  if [[ "${SERVER_IPV6:-false}" == "true" ]]; then
    ipv6_bool="true"
    sr_ipv6_rule="# SERVER_IPV6=true: 允许 IPv6 流量按规则分流"
  fi
  local sr_cn_domain_url="${RULESET_SR_CN_DOMAIN:-${DEFAULT_RULESET_SR_CN_DOMAIN}}"
  local sr_update_url_line="# ENABLE_SUBSCRIPTION=false: 未开放公网订阅托管，省略 update-url"
  if [[ "${ENABLE_SUBSCRIPTION:-true}" == "true" ]]; then
    sr_update_url_line="update-url = $(build_sub_base_url "${tok}")/shadowrocket.conf"
  fi

  local sr_rule_lines="" sr_host_lines="" sfx
  local doh_direct_target="server:https://${DNS_DIRECT}/dns-query"
  for sfx in "${SR_CN_FALLBACK_SUFFIXES[@]}"; do
    if [[ -n "${sr_rule_lines}" ]]; then
      sr_rule_lines+=$'\n'
      sr_host_lines+=$'\n'
    fi
    sr_rule_lines+="DOMAIN-SUFFIX,${sfx},DIRECT"
    if [[ "${sfx}" != *.cn && "${sfx}" != "weixin.qq.com" && "${sfx}" != "${SERVER_DOMAIN}" ]]; then
      sr_host_lines+="${sfx} = ${doh_direct_target}"$'\n'"*.${sfx} = ${doh_direct_target}"
    else
      sr_host_lines+="*.${sfx} = ${doh_direct_target}"
    fi
  done

  local sr_private_relay_rules="" sr_overseas_priority_rules="" dom
  for dom in "${PRIVATE_RELAY_CANARY_DOMAINS[@]}"; do
    [[ -n "${sr_private_relay_rules}" ]] && sr_private_relay_rules+=$'\n'
    sr_private_relay_rules+="DOMAIN,${dom},REJECT"
  done
  for sfx in "${OVERSEAS_PROXY_PRIORITY_SUFFIXES[@]}"; do
    [[ -n "${sr_overseas_priority_rules}" ]] && sr_overseas_priority_rules+=$'\n'
    sr_overseas_priority_rules+="AND,((PROTOCOL,UDP),(DST-PORT,443),(DOMAIN-SUFFIX,${sfx})),REJECT"$'\n'"DOMAIN-SUFFIX,${sfx},PROXY"
  done

  local dns_remote_fallback="8.8.8.8"
  if [[ "${DNS_REMOTE}" == "8.8.8.8" ]]; then
    dns_remote_fallback="1.1.1.1"
  fi
  local sr_dns_remote_rules="IP-CIDR,${DNS_REMOTE}/32,PROXY,no-resolve"$'\n'"IP-CIDR,${dns_remote_fallback}/32,PROXY,no-resolve"

  local sr_self_ip_direct_rules="IP-CIDR,${SERVER_IP}/32,DIRECT,no-resolve"
  local v6_cidr
  while IFS= read -r v6_cidr; do
    if [[ -n "${v6_cidr}" ]]; then
      sr_self_ip_direct_rules+=$'\n'"IP-CIDR6,${v6_cidr},DIRECT,no-resolve"
    fi
  done < <(collect_server_self_ipv6_cidrs)

  shopt -u patsub_replacement 2>/dev/null || true
  local tpl
  tpl="$(<"${CLIENT_TPL_DIR}/shadowrocket.conf")"
  tpl="${tpl//__SR_UPDATE_URL_LINE__/"${sr_update_url_line}"}"
  tpl="${tpl//__SR_SELF_IP_DIRECT_RULES__/"${sr_self_ip_direct_rules}"}"
  tpl="${tpl//__SR_PRIVATE_RELAY_RULES__/"${sr_private_relay_rules}"}"
  tpl="${tpl//__SR_OVERSEAS_PRIORITY_RULES__/"${sr_overseas_priority_rules}"}"
  tpl="${tpl//__SR_CN_DOMAIN_SUFFIX_RULES__/"${sr_rule_lines}"}"
  tpl="${tpl//__SR_CN_HOST_DIRECT_LINES__/"${sr_host_lines}"}"
  tpl="${tpl//__SR_DNS_REMOTE_RULES__/"${sr_dns_remote_rules}"}"
  tpl="${tpl//__DNS_DIRECT__/"${DNS_DIRECT}"}"
  tpl="${tpl//__DNS_REMOTE_FALLBACK__/"${dns_remote_fallback}"}"
  tpl="${tpl//__DNS_REMOTE__/"${DNS_REMOTE}"}"
  tpl="${tpl//__IPV6_BOOL__/"${ipv6_bool}"}"
  tpl="${tpl//__SR_IPV6_RULE__/"${sr_ipv6_rule}"}"
  tpl="${tpl//__SERVER_IP__/"${SERVER_IP}"}"
  tpl="${tpl//__SERVER_DOMAIN__/"${SERVER_DOMAIN}"}"
  tpl="${tpl//__RULESET_SR_CN_DOMAIN__/"${sr_cn_domain_url}"}"
  printf '%s\n' "${tpl}" > "${out_file}"
  assert_no_unreplaced_placeholders "${out_file}"
}

render_urls_summary() {
  local sub="$1"
  local tok="$2"
  local vless_uri="$3"
  local hy2_uri="$4"
  local out_file="$5"

  local base_url v2ray_url sb_url mihomo_url sr_url
  base_url="$(build_sub_base_url "${tok}")"
  v2ray_url="${base_url}/v2ray"
  sb_url="${base_url}/sing-box.json"
  mihomo_url="${base_url}/mihomo.yaml"
  sr_url="${base_url}/shadowrocket.conf"

  local sb_enc mihomo_enc v2ray_b64
  sb_enc="$(urlencode_str "${sb_url}")"
  mihomo_enc="$(urlencode_str "${mihomo_url}")"
  v2ray_b64="$(printf '%s' "${v2ray_url}" | base64 | tr -d '\n=')"

  cat > "${out_file}" <<EOF
# Subscription: ${sub}
# Security Warning: Subscription URLs contain full proxy credentials. Do NOT share publicly; run 'sudo ./singtun reset ${sub}' immediately if leaked.
ENABLE_SUBSCRIPTION=${ENABLE_SUBSCRIPTION:-true}
ENABLE_HY2=${ENABLE_HY2:-false}

[HTTPS Subscription URLs]
v2ray_base64      = ${v2ray_url}
singbox_json      = ${sb_url}
mihomo_yaml       = ${mihomo_url}
shadowrocket_conf = ${sr_url}

[One-Click Client Deep Links]
singbox_import      = sing-box://import-remote-profile?url=${sb_enc}#${SERVER_DOMAIN}-${sub}
clash_import        = clash://install-config?url=${mihomo_enc}&name=${SERVER_DOMAIN}-${sub}
shadowrocket_sub    = sub://${v2ray_b64}#${SERVER_DOMAIN}-${sub}
shadowrocket_config = shadowrocket://config/add/${sr_url}

[Fallback Raw Node URI]
vless_uri = ${vless_uri}
EOF
  if [[ -n "${hy2_uri}" ]]; then
    printf 'hy2_uri   = %s\n' "${hy2_uri}" >> "${out_file}"
  fi
}

validate_singbox_config_strict() {
  local cfg_file="$1"
  local sb_bin="${SINGTUN_SINGBOX_BIN:-sing-box}"
  local compat_mode="${SINGBOX_CLIENT_COMPAT:-1.14}"
  local check_out=""
  if ! check_out="$("${sb_bin}" check -c "${cfg_file}" 2>&1)"; then
    log_error "${check_out}"
    die "客户端配置未通过 sing-box check: ${cfg_file}"
  fi
  if [[ "${compat_mode}" == "1.14" ]] && grep -Eiq '(deprecated|warn)' <<< "${check_out}"; then
    log_error "${check_out}"
    die "客户端配置存在 sing-box 弃用或警告项: ${cfg_file}"
  fi
}

validate_mihomo_config_if_available() {
  local cfg_file="$1"
  local mihomo_bin="${SINGTUN_MIHOMO_BIN:-}"
  if [[ -z "${mihomo_bin}" ]] && command -v mihomo >/dev/null 2>&1; then
    mihomo_bin="$(command -v mihomo)"
  fi
  if [[ -z "${mihomo_bin}" || ! -x "${mihomo_bin}" ]]; then
    return 0
  fi

  local workdir="${SINGTUN_MIHOMO_WORKDIR:-}"
  if [[ -z "${workdir}" || ! -f "${workdir}/rules/geosite-cn.mrs" || ! -f "${workdir}/rules/geoip-cn.mrs" ]]; then
    return 0
  fi

  local mh_out=""
  if ! mh_out="$("${mihomo_bin}" -d "${workdir}" -t -f "${cfg_file}" 2>&1)"; then
    log_error "${mh_out}"
    die "客户端 mihomo.yaml 未通过 mihomo -t 内核校验: ${cfg_file}"
  fi
}

# 五重安全防护清理 private/out/ 下已删除订阅的目录
prune_stale_sub_dirs() {
  [[ -d "${OUT_ROOT}" ]] || return 0
  local real_out
  real_out="$(readlink -f "${OUT_ROOT}")"
  if [[ -z "${real_out}" || "${real_out}" == "/" ]]; then
    die "OUT_ROOT 解析路径异常，中止清理: ${real_out:-empty}"
  fi

  local entry base real_entry
  shopt -s nullglob
  for entry in "${OUT_ROOT}"/*; do
    if [[ -L "${entry}" || ! -d "${entry}" ]]; then
      continue
    fi
    base="$(basename "${entry}")"
    if has_subscription "${base}"; then
      continue
    fi
    if ! is_valid_sub_name "${base}"; then
      log_warn "跳过清理名称不符合订阅命名规范的目录: ${entry}"
      continue
    fi
    real_entry="$(readlink -f "${entry}")"
    if [[ -z "${real_entry}" || "${real_entry}" != "${real_out}/"* || "${real_entry}" == "${real_out}" ]]; then
      log_warn "跳过路径异常的目录: ${entry} -> ${real_entry:-?}"
      continue
    fi
    rm -rf -- "${real_entry}"
    log_info "已清理已移除订阅的本地产物目录: ${real_entry}"
  done
  shopt -u nullglob
}

# 收敛公网订阅历史版本目录：ENABLE_SUBSCRIPTION=false 时清空全部；为 true 时保留当前软链目标 + 最近 1 个历史成功版本（最多 2 个）
finalize_public_releases() {
  local enable_sub="${ENABLE_SUBSCRIPTION:-true}"
  local keep_max="${SINGTUN_SUB_RELEASE_KEEP:-2}"

  if [[ "${enable_sub}" != "true" ]]; then
    if [[ -L "${SUB_WEB_LINK}" || -e "${SUB_WEB_LINK}" ]]; then
      rm -rf -- "${SUB_WEB_LINK}"
    fi
    if [[ -d "${SUB_RELEASES_DIR}" ]]; then
      local rel
      shopt -s nullglob
      for rel in "${SUB_RELEASES_DIR}"/sub-web.*; do
        [[ -d "${rel}" && ! -L "${rel}" ]] && rm -rf -- "${rel}"
      done
      shopt -u nullglob
    fi
    return 0
  fi

  [[ -d "${SUB_RELEASES_DIR}" ]] || return 0
  local cur_target=""
  if [[ -L "${SUB_WEB_LINK}" ]]; then
    cur_target="$(readlink "${SUB_WEB_LINK}" 2>/dev/null || true)"
  fi

  local -a all_rels=()
  local d
  shopt -s nullglob
  for d in "${SUB_RELEASES_DIR}"/sub-web.*; do
    if [[ -d "${d}" && ! -L "${d}" ]]; then
      all_rels+=("${d}")
    fi
  done
  shopt -u nullglob
  (( ${#all_rels[@]} > 0 )) || return 0

  local -a sorted_rels=()
  mapfile -t sorted_rels < <(printf '%s\n' "${all_rels[@]}" | LC_ALL=C sort -r)

  local kept=0
  local -A keep_map=()
  if [[ -n "${cur_target}" && -d "${cur_target}" ]]; then
    keep_map["${cur_target}"]=1
    kept=1
  fi
  for d in "${sorted_rels[@]}"; do
    if (( kept >= keep_max )); then
      break
    fi
    if [[ -z "${keep_map[${d}]:-}" ]]; then
      keep_map["${d}"]=1
      kept=$((kept + 1))
    fi
  done

  for d in "${sorted_rels[@]}"; do
    if [[ -z "${keep_map[${d}]:-}" ]]; then
      rm -rf -- "${d}"
    fi
  done
}

# 基于版本化目录 + ln -sfn + mv -Tf 的符号链接原子发布（兼容 coreutils 8.32，零 404 窗口；事务期延迟清理旧目录）
publish_public_subscriptions() {
  local enable_sub="${ENABLE_SUBSCRIPTION:-true}"
  local defer_prune="${SINGTUN_DEFER_RELEASE_PRUNE:-false}"

  if [[ "${enable_sub}" != "true" ]]; then
    if [[ -L "${SUB_WEB_LINK}" || -e "${SUB_WEB_LINK}" ]]; then
      rm -rf -- "${SUB_WEB_LINK}"
    fi
    if [[ "${SINGTUN_FAIL_AFTER_SUB_WEB_SWITCH:-false}" == "true" ]]; then
      die "注入测试故障：关闭公网订阅移除软链后触发失败"
    fi
    if [[ "${defer_prune}" == "true" ]]; then
      log_info "ENABLE_SUBSCRIPTION=false：已移除公网静态订阅软链（事务期内保留历史版本目录以便回滚）。"
    else
      finalize_public_releases
      log_info "ENABLE_SUBSCRIPTION=false：已移除公网静态订阅软链并清空发布目录。"
    fi
    return 0
  fi

  if ! is_valid_sub_prefix "${SUB_PATH_PREFIX:-}"; then
    die "SUB_PATH_PREFIX 未设置或格式非法: ${SUB_PATH_PREFIX:-}"
  fi

  mkdir -p "${SUB_WEB_BASE}" "${SUB_RELEASES_DIR}"
  chmod 755 "${SUB_WEB_BASE}"

  local web_group=""
  if [[ "${EUID:-$(id -u)}" -eq 0 ]] && getent group www-data >/dev/null 2>&1; then
    web_group="www-data"
    chown root:"${web_group}" "${SUB_RELEASES_DIR}"
  fi
  chmod 750 "${SUB_RELEASES_DIR}"

  local new_rel rel_ts
  rel_ts="$(date +%s%N)"
  new_rel="${SUB_RELEASES_DIR}/sub-web.${rel_ts}.$$"
  mkdir -p "${new_rel}/${SUB_PATH_PREFIX}"

  local sub tok src_dir dst_dir
  while IFS= read -r sub; do
    [[ -z "${sub}" ]] && continue
    tok="$(get_sub_token "${sub}")"
    src_dir="${OUT_ROOT}/${sub}"
    dst_dir="${new_rel}/${SUB_PATH_PREFIX}/${tok}"
    mkdir -p "${dst_dir}"
    cp -f "${src_dir}/v2ray" "${dst_dir}/v2ray"
    cp -f "${src_dir}/sing-box.json" "${dst_dir}/sing-box.json"
    cp -f "${src_dir}/mihomo.yaml" "${dst_dir}/mihomo.yaml"
    cp -f "${src_dir}/shadowrocket.conf" "${dst_dir}/shadowrocket.conf"
  done < <(list_subscriptions)

  if [[ -n "${web_group}" ]]; then
    chown -R root:"${web_group}" "${new_rel}"
  fi
  find "${new_rel}" -type d -exec chmod 750 {} +
  find "${new_rel}" -type f -exec chmod 640 {} +

  # 若历史遗留为普通目录，首次迁移为符号链接
  if [[ -d "${SUB_WEB_LINK}" && ! -L "${SUB_WEB_LINK}" ]]; then
    rm -rf -- "${SUB_WEB_LINK}"
  fi

  local tmp_link="${SUB_WEB_BASE}/sub-web.tmp.$$"
  ln -sfn "${new_rel}" "${tmp_link}"
  mv -Tf "${tmp_link}" "${SUB_WEB_LINK}"

  if [[ "${SINGTUN_FAIL_AFTER_SUB_WEB_SWITCH:-false}" == "true" ]]; then
    die "注入测试故障：公网订阅软链切换完成后触发失败"
  fi

  if [[ "${defer_prune}" != "true" ]]; then
    finalize_public_releases
  fi

  log_info "公网静态订阅目录已完成符号链接原子切换 -> ${new_rel}"
}

render_single_subscription() {
  local sub="$1"
  local has_singbox="$2"
  local dest_root="${3:-${OUT_ROOT}}"

  local uuid tok sub_dir tmp_sub_dir json_file mihomo_file sr_file links_file v2ray_file urls_file vless_uri hy2_uri
  uuid="$(get_sub_uuid "${sub}")"
  tok="$(get_sub_token "${sub}")"
  sub_dir="${dest_root}/${sub}"
  make_temp_dir tmp_sub_dir

  json_file="${tmp_sub_dir}/sing-box.json"
  mihomo_file="${tmp_sub_dir}/mihomo.yaml"
  sr_file="${tmp_sub_dir}/shadowrocket.conf"
  links_file="${tmp_sub_dir}/links.txt"
  v2ray_file="${tmp_sub_dir}/v2ray"
  urls_file="${tmp_sub_dir}/urls.txt"

  render_sub_singbox_json "${uuid}" "${json_file}"
  if [[ "${has_singbox}" == "true" ]]; then
    validate_singbox_config_strict "${json_file}"
  fi

  render_mihomo_yaml "${sub}" "${uuid}" "${mihomo_file}"
  validate_mihomo_config_if_available "${mihomo_file}"

  render_shadowrocket_conf "${tok}" "${sr_file}"

  vless_uri="$(build_vless_uri "${sub}" "${uuid}")"
  hy2_uri=""
  if [[ "${ENABLE_HY2:-false}" == "true" ]]; then
    require_vars HY2_PORT
    hy2_uri="$(build_hy2_uri "${sub}" "${uuid}")"
    printf '%s\n%s\n' "${vless_uri}" "${hy2_uri}" > "${links_file}"
  else
    printf '%s\n' "${vless_uri}" > "${links_file}"
  fi
  base64 < "${links_file}" | tr -d '\n' > "${v2ray_file}"

  render_urls_summary "${sub}" "${tok}" "${vless_uri}" "${hy2_uri}" "${urls_file}"

  chmod 600 "${json_file}" "${mihomo_file}" "${sr_file}" "${links_file}" "${v2ray_file}" "${urls_file}"
  mkdir -p "${dest_root}" "${sub_dir}"
  chmod 700 "${dest_root}" "${sub_dir}"
  mv -f "${json_file}" "${mihomo_file}" "${sr_file}" "${links_file}" "${v2ray_file}" "${urls_file}" "${sub_dir}/"
  chmod 600 "${sub_dir}/sing-box.json" "${sub_dir}/mihomo.yaml" "${sub_dir}/shadowrocket.conf" \
    "${sub_dir}/links.txt" "${sub_dir}/v2ray" "${sub_dir}/urls.txt"
  rm -rf -- "${tmp_sub_dir}"
  if [[ "${dest_root}" == "${OUT_ROOT}" ]]; then
    log_info "已生成订阅 [${sub}] 本地配置 -> ${sub_dir}/"
  fi
}

main() {
  if [[ "${1:-}" == "--verify-mihomo-gz-only" ]]; then
    local gz_path="${2:-}" ver="${3:-}" arch="${4:-}"
    [[ -f "${gz_path}" && -n "${ver}" && -n "${arch}" ]] || die "用法: $0 --verify-mihomo-gz-only <gz_path> <version> <arch>"
    verify_mihomo_gz "${gz_path}" "${ver}" "${arch}"
    log_info "mihomo 压缩包 SHA256 校验通过: ${gz_path}"
    return 0
  fi

  if [[ "${1:-}" == "--finalize-releases" ]]; then
    acquire_singtun_lock
    load_env
    if [[ "${EUID:-$(id -u)}" -eq 0 || -n "${SINGTUN_SUB_WEB_BASE_OVERRIDE:-}" ]]; then
      finalize_public_releases
    fi
    return 0
  fi

  local has_singbox="false"
  local sb_bin="${SINGTUN_SINGBOX_BIN:-}"
  if [[ -n "${sb_bin}" ]]; then
    [[ -x "${sb_bin}" ]] || die "指定的 SINGTUN_SINGBOX_BIN 不可执行: ${sb_bin}"
    has_singbox="true"
  elif command -v sing-box >/dev/null 2>&1; then
    has_singbox="true"
  fi

  local local_only="false"
  local target_sub=""
  while (( $# > 0 )); do
    case "$1" in
      --local-only)
        local_only="true"
        shift
        ;;
      -*)
        die "未知选项: $1（用法: ./singtun flush [name] [--local-only]）"
        ;;
      *)
        if [[ -n "${target_sub}" ]]; then
          die "多余的位置参数: $1（用法: ./singtun flush [name] [--local-only]）"
        fi
        target_sub="$1"
        shift
        ;;
    esac
  done

  if [[ "${local_only}" != "true" && "${EUID:-$(id -u)}" -ne 0 && -z "${SINGTUN_SUB_WEB_BASE_OVERRIDE:-}" && "${SINGTUN_ALLOW_NONROOT_UPGRADE_TEST:-false}" != "true" ]] && is_server_deployed; then
    die "检测到服务端已部署，同步公网订阅目录需 root 权限，请使用: sudo ./singtun flush（若仅需重新生成本地 private/out/，请追加 --local-only）"
  fi

  acquire_singtun_lock
  load_env
  require_cmd jq base64
  require_vars \
    SERVER_IP \
    SERVER_DOMAIN \
    SERVER_IPV6 \
    VLESS_PORT \
    REALITY_PRIVATE_KEY \
    REALITY_PUBLIC_KEY \
    REALITY_SHORT_ID \
    UTLS_FINGERPRINT \
    SUB_PATH_PREFIX \
    DNS_DIRECT \
    DNS_REMOTE \
    RULESET_GEOSITE_CN \
    RULESET_GEOIP_CN

  is_valid_ipv4 "${SERVER_IP}" || die "SERVER_IP 非合法 IPv4 地址: ${SERVER_IP}"
  if declare -F is_non_public_ipv4 >/dev/null 2>&1 && is_non_public_ipv4 "${SERVER_IP}" false; then
    die "SERVER_IP 不能使用内网、环回、CGNAT 或保留 IPv4 地址: ${SERVER_IP}"
  fi
  is_valid_domain "${SERVER_DOMAIN}" || die "SERVER_DOMAIN 格式非法: ${SERVER_DOMAIN}"
  is_valid_port "${VLESS_PORT}" || die "VLESS_PORT 端口非法: ${VLESS_PORT}"
  is_valid_reality_key "${REALITY_PRIVATE_KEY}" || die "REALITY_PRIVATE_KEY 格式非法"
  is_valid_reality_key "${REALITY_PUBLIC_KEY}" || die "REALITY_PUBLIC_KEY 格式非法"
  if declare -F derive_reality_public_key >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1; then
    local expected_reality_pub=""
    if ! expected_reality_pub="$(derive_reality_public_key "${REALITY_PRIVATE_KEY}")" || [[ -z "${expected_reality_pub}" ]]; then
      die "无法从 REALITY_PRIVATE_KEY 派生公钥，请检查 REALITY_PRIVATE_KEY 是否为合法 X25519 私钥"
    fi
    if [[ "${REALITY_PUBLIC_KEY}" != "${expected_reality_pub}" ]]; then
      die "REALITY_PUBLIC_KEY 与 REALITY_PRIVATE_KEY 不匹配，请核对或运行 './singtun init' 恢复匹配的公钥"
    fi
  fi
  is_valid_short_id "${REALITY_SHORT_ID}" || die "REALITY_SHORT_ID 必须为 2-16 位偶数长度十六进制字符串: ${REALITY_SHORT_ID}"
  is_valid_utls_fingerprint "${UTLS_FINGERPRINT}" || die "UTLS_FINGERPRINT 非法: ${UTLS_FINGERPRINT}"
  is_valid_sub_prefix "${SUB_PATH_PREFIX}" || die "SUB_PATH_PREFIX 格式非法或包含特征前缀: ${SUB_PATH_PREFIX}"

  local compat_mode="${SINGBOX_CLIENT_COMPAT:-1.14}"
  if ! is_valid_singbox_compat "${compat_mode}"; then
    die "SINGBOX_CLIENT_COMPAT 仅支持 1.14 或 1.12: ${compat_mode}"
  fi
  validate_dns_doh_env_vars
  validate_ruleset_urls
  validate_hy2_env_vars

  mkdir -p "${OUT_ROOT}"
  chmod 700 "${OUT_ROOT}"

  local stage_out_root=""
  make_temp_dir stage_out_root
  local -a staged_subs=()
  local sub
  local generated_count=0
  local total_subs=0

  while IFS= read -r sub; do
    [[ -z "${sub}" ]] && continue
    if ! is_valid_sub_name "${sub}"; then
      die "订阅名 '${sub}' 格式非法或属于系统保留字"
    fi
    total_subs=$((total_subs + 1))
    if [[ -n "${target_sub}" && "${sub}" != "${target_sub}" ]]; then
      # 若非仅本地模式且其他订阅尚未生成本地文件，自动补齐渲染以保障公网原子发布完整
      local other_dir="${OUT_ROOT}/${sub}"
      if [[ "${local_only}" != "true" ]] && [[ ! -f "${other_dir}/v2ray" || ! -f "${other_dir}/sing-box.json" || ! -f "${other_dir}/mihomo.yaml" || ! -f "${other_dir}/shadowrocket.conf" ]]; then
        render_single_subscription "${sub}" "${has_singbox}" "${stage_out_root}"
        staged_subs+=("${sub}")
      fi
      continue
    fi

    render_single_subscription "${sub}" "${has_singbox}" "${stage_out_root}"
    staged_subs+=("${sub}")
    generated_count=$((generated_count + 1))
  done < <(list_subscriptions)

  if [[ -n "${target_sub}" ]] && (( generated_count == 0 )); then
    die "未找到匹配的订阅 '${target_sub}'（当前 SUBSCRIPTIONS=\"${SUBSCRIPTIONS:-}\"）"
  fi

  for sub in "${staged_subs[@]}"; do
    local src_sub="${stage_out_root}/${sub}"
    local dst_sub="${OUT_ROOT}/${sub}"
    local tmp_dst="${OUT_ROOT}/.${sub}.stage.$$"
    local old_dst="${OUT_ROOT}/.${sub}.old.$$"
    rm -rf -- "${tmp_dst}" "${old_dst}"
    register_cleanup_path "${tmp_dst}"
    mkdir -p "${tmp_dst}"
    chmod 700 "${tmp_dst}"
    cp -f "${src_sub}/sing-box.json" "${src_sub}/mihomo.yaml" "${src_sub}/shadowrocket.conf" \
      "${src_sub}/links.txt" "${src_sub}/v2ray" "${src_sub}/urls.txt" "${tmp_dst}/"
    chmod 600 "${tmp_dst}/sing-box.json" "${tmp_dst}/mihomo.yaml" "${tmp_dst}/shadowrocket.conf" \
      "${tmp_dst}/links.txt" "${tmp_dst}/v2ray" "${tmp_dst}/urls.txt"
    if [[ -e "${dst_sub}" || -L "${dst_sub}" ]]; then
      mv -Tf "${dst_sub}" "${old_dst}"
    fi
    if ! mv -Tf "${tmp_dst}" "${dst_sub}"; then
      if [[ -e "${old_dst}" || -L "${old_dst}" ]]; then
        mv -Tf "${old_dst}" "${dst_sub}" 2>/dev/null || true
      fi
      die "原子替换订阅输出目录失败: ${dst_sub}"
    fi
    rm -rf -- "${old_dst}"
    log_info "已生成订阅 [${sub}] 本地配置 -> ${dst_sub}/"
  done

  if [[ -z "${target_sub}" ]]; then
    prune_stale_sub_dirs
  fi

  # 通过 sudo 或以 root 执行时，将本地 private/out 归属恢复为非 root 调用者或 private/仓库属主（禁止跟随符号链接）
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    local ug="" cand_ug=""
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]] && id -u "${SUDO_USER}" >/dev/null 2>&1; then
      ug="$(id -u "${SUDO_USER}"):$(id -g "${SUDO_USER}")"
    else
      cand_ug="$(stat -c '%u:%g' "${PRIVATE_DIR}" 2>/dev/null || true)"
      if [[ -n "${cand_ug}" && "${cand_ug%%:*}" != "0" ]]; then
        ug="${cand_ug}"
      else
        cand_ug="$(stat -c '%u:%g' "${REPO_ROOT}" 2>/dev/null || true)"
        if [[ -n "${cand_ug}" && "${cand_ug%%:*}" != "0" ]]; then
          ug="${cand_ug}"
        fi
      fi
    fi
    if [[ -n "${ug}" ]]; then
      chown -RP "${ug}" "${OUT_ROOT}"
    fi
  fi

  if [[ "${local_only}" != "true" ]]; then
    if is_server_deployed; then
      if [[ "${ENABLE_HY2:-false}" == "true" && ! -f "/etc/sing-box/20-inbound-hy2.json" ]]; then
        log_warn "当前 ENABLE_HY2=true，但服务端尚未部署 /etc/sing-box/20-inbound-hy2.json（或未放行防火墙）；请运行 'sudo ./singtun deploy' 使 Hysteria2 服务端生效。"
      elif [[ "${ENABLE_HY2:-false}" == "true" && -n "${HY2_HOP_PORTS:-}" && ! -f "/etc/systemd/system/singtun-hy2-hop.service" ]]; then
        log_warn "当前已配置 HY2_HOP_PORTS=${HY2_HOP_PORTS}，但服务端尚未部署端口跳跃规则 (singtun-hy2-hop.service)；请运行 'sudo ./singtun deploy' 同步防火墙与 nftables。"
      elif [[ "${ENABLE_HY2:-false}" == "true" && "${HY2_OBFS:-false}" == "true" ]] && [[ -r "/etc/sing-box/20-inbound-hy2.json" ]] && ! grep -Fq '"salamander"' "/etc/sing-box/20-inbound-hy2.json"; then
        log_warn "当前 HY2_OBFS=true，但服务端 /etc/sing-box/20-inbound-hy2.json 尚未启用 salamander 混淆；请运行 'sudo ./singtun deploy' 同步服务端配置。"
      elif [[ "${ENABLE_HY2:-false}" == "true" && "${HY2_OBFS:-false}" != "true" ]] && [[ -r "/etc/sing-box/20-inbound-hy2.json" ]] && grep -Fq '"salamander"' "/etc/sing-box/20-inbound-hy2.json"; then
        log_warn "当前 HY2_OBFS=false，但服务端 /etc/sing-box/20-inbound-hy2.json 仍启用着 salamander 混淆；请运行 'sudo ./singtun deploy' 同步服务端配置。"
      elif [[ "${ENABLE_HY2:-false}" != "true" && ( -f "/etc/sing-box/20-inbound-hy2.json" || -f "/etc/systemd/system/singtun-hy2-hop.service" ) ]]; then
        log_warn "当前 ENABLE_HY2=false，但服务端仍残留 Hysteria2 入站或端口跳跃配置；请运行 'sudo ./singtun deploy' 关闭服务端入站并收敛防火墙。"
      fi
    fi
    if [[ "${EUID:-$(id -u)}" -eq 0 || -n "${SINGTUN_SUB_WEB_BASE_OVERRIDE:-}" ]]; then
      publish_public_subscriptions
    else
      log_warn "当前非 root 运行，已仅更新本地 ${OUT_ROOT}（公网订阅静态目录需使用 sudo 同步）。"
    fi
  fi

  if (( total_subs == 0 )); then
    log_info "当前暂无活跃订阅 (SUBSCRIPTIONS 为空)；已清理过期产物目录。"
  else
    log_info "订阅配置生成完成 (本次处理 ${generated_count}/${total_subs} 条订阅，本地目录: ${OUT_ROOT})。"
  fi
}

main "$@"
