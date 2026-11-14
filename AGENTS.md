# AGENTS.md — 架构契约与既定事实基线 (For AI Agents)

本文档是面向 **AI Agent** 的持续协作开发上下文基线，以凝练、准确的形式定义本项目的架构不变量、既定技术事实与工程红线。

- **项目定位**：基于单一状态文件 `private/.env`，一键部署个人跨境代理服务端并按需生成全平台客户端配置。
- **核心优先级**：**功能与安全第一**（稳定、抗探测、防泄漏、可回滚）> **性能与轻量第二**（原生 Bash + `systemd`，兼容 1C/512MB 低配机器，无常驻容器/语言运行时开销）。
- **核心技术壁垒**：
  1. **端到端单一固定出口与防泄漏闭环**：服务端安全路由 + 四端客户端同源渲染（OS TUN 路由层与规则层双层自指排除防断 SSH、全量免 Bootstrap 加密 IP-DoH + `:53` 劫持、双栈 IPv6 接管阻断、Private Relay 金丝雀阻断、海外 `UDP 443` QUIC 本地降级、`UDP 123` NTP 本地直连）。
  2. **单文件声明式状态与事务级可回滚运维**：唯一状态源 `private/.env` 纯数据键值解析器 + `flock` 串行锁 + 目录物理快照与 `sub-web` 软链原子切换/回滚 + `upgrade` 候选二进制隔离预检，零常驻面板、容器或数据库开销。
  3. **不可变供应链与真实回环验证**：GPG 单主钥指纹隔离重导出、官方二进制固定 SHA256、远程规则集固定 40 位 Commit SHA，配合双进程 REALITY 回落与动态 SSRF / DNS Rebinding CI 实测。
- **工程边界（Non-Goals）**：
  1. **不做常驻管理面**：严禁引入常驻 Web 管理面板、多租户计费/流量统计数据库或后台守护 Agent。
  2. **不污染固定出口 IP**：严禁引入任何改变或中转固定出口 IP 的组件（WARP、Psiphon、公共代理链、CDN/Argo 橙色云）。
  3. **不维护臃肿大杂烩规则集**：严禁内置去广告、流媒体解锁、审计屏蔽等高流失率/高冲突规则集。
  4. **不追逐长尾 SDK 域名**：严禁在脚本中硬编码追逐长尾垂直 App 或第三方广告/统计/P2P SDK 域名。
- **分流规则演进纪律**：
  1. **机制优先于枚举域名**：凡可通过协议、端口或地址段不变量收敛的问题（如 `UDP 123` NTP 本地直连、非大陆 `UDP 443` QUIC 抑制、私网/CGNAT 直连），严禁堆砌域名列表。
  2. **`OVERSEAS_PROXY_PRIORITY_SUFFIXES` 准入界线**：仅收录上游大陆规则历史 `@cn` 误判的核心海外基础设施后缀。
  3. **`SR_CN_FALLBACK_SUFFIXES` 准入界线**：仅服务于受规则语法限制无法绑定整份 `geosite-cn` 至国内 DoH 的 `Shadowrocket`，严格限缩于操作系统/Apple 核心国内服务、国家级支付清算、头部公有云/CDN 与国民级定位底座（总量控制在约 150 条以内），长尾国内域名交由远程不可变 `DOMAIN-SET` 兜底路由。
- **文档职责与文风约定（全仓仅维护以下三份 Markdown 文档，禁止新增其他文档或 `docs/` 目录）**：

| 文件 | 目标读者 | 核心职责 | 文风要求 |
| :--- | :--- | :--- | :--- |
| [`README.md`](README.md) | **项目使用者**（主）<br>**人类开发者**（次） | 部署与订阅上手、客户端接入、日常运维排障；提供架构设计与开发入门指引 | 章节逻辑清晰、表达准确、阅读节奏流畅、字词自然；先上手后原理，避免底层实现术语堆砌 |
| [`AGENTS.md`](AGENTS.md) | **AI Agent**（主） | 架构规范、已确定技术事实（路径/权限/算法/路由/覆写接口）与工程红线 | 准确凝练、高信息密度、直接陈述确定性事实，不写科普与过程性冗余 |
| [`PLAN.md`](PLAN.md) | **AI Agent**（主） | 当前待办事项、阶段依赖关系、已落地实现的产出物与验收断言基线 | 清单化、事实化，突出待完成项与阶段验收不变量 |

- **变更同步规则**：不维护 `CHANGELOG.md`（以 Git 提交历史为准）；任何用户可见行为变更必须同步更新 `README.md`；架构或技术事实变更须先更新 `AGENTS.md` 再同步 `PLAN.md`。仓库文档内链接一律使用**相对路径**（严禁出现 `file:///` 绝对路径）。

> [!IMPORTANT]
> **私有实例信息绝对隔离红线**
> - 真实部署实例事实（服务器 IP、域名、ASN、硬件、部署状态）仅记录于 `private/host-facts.md`；实例参数与密钥仅记录于 `private/.env`。
> - Agent 执行与具体服务器相关的任务前，**若 `private/host-facts.md` 存在，必须先读取**。
> - **严禁**将真实 IP、域名（含上级主域名）、UUID、派生密码、REALITY 私钥、API Token、`SUB_PATH_PREFIX`、`SUB_TOKEN_*` 或 Base64 节点密文写入 `private/` 以外的任何文件、提交信息或 Issue/PR。公开示例统一使用 `example.com` / `203.0.113.0/24` 等保留值。

---

## 1. 核心架构不变量

1. **单一固定出口**：多设备共用同一台海外 VPS 的固定公网 IPv4 作为唯一国际出口；**严禁**引入任何改变出口 IP 的组件（WARP、Psiphon、公共代理链、CDN/Argo 橙色云中转），并在三端客户端屏蔽 Apple iCloud Private Relay 金丝雀与控制面域名（`mask.icloud.com`、`mask-h2.icloud.com`、`mask-api.icloud.com`），避免 iOS/macOS Safari 激活 MASQUE (`UDP 443`) 造成死锁或改变出口 IP。
2. **双向分流与防回环**：
   - **客户端直连（DIRECT）**：中国大陆域名（`geosite-cn`）、中国大陆 IP（`geoip-cn`）、私有网段（LAN、`100.64.0.0/10` CGNAT/Tailscale、`169.254.0.0/16` Link-Local）、代理服务器自身 `SERVER_DOMAIN` 与 `SERVER_IP/32`（防止 TUN、系统代理或 SNI 嗅探覆写下刷新远程订阅产生回环）、`sing-box` 客户端本地 `bittorrent` 流量，以及三端统一前置的 **`UDP 123`（NTP 校时流量）**。三端客户端（`sing-box`、`mihomo`、`Shadowrocket`）统一将 `UDP 123 -> DIRECT` 置于 `SERVER_IPV6=false` 的 IPv6 阻断之后、`Global` 模式与海外前置代理规则之前（同时 `mihomo` 在 `fake-ip-filter` 中排除 `+.time.apple.com`、`ntp.*.gov`、`+.ntp.org` 等 NTP 通配），确保任何系统或 SDK 对全球任意 NTP 池（`time.apple.com`、`time.asia.apple.com`、`*.pool.ntp.org`、`ntp.nasa.gov` 等）的校时请求均本地直连，避免非 XUDP 客户端落入 `VLESS-XTLS-Vision` 触发 `flow mismatch` 或引入跨境 RTT 偏差。三端受管客户端（`sing-box` `tun.route_exclude_address`、`mihomo` `tun.route-exclude-address`、`Shadowrocket` `tun-excluded-routes` + `skip-proxy`）同步在 OS TUN 内核路由层排除服务端自身公网地址（`SERVER_IP/32`，且 `SERVER_IPV6=true` 时 `sing-box`/`mihomo` 同步排除本机全局 IPv6 `/128`），避免中途开关/重载 TUN 或切换 `Global` 模式时将直连 SSH 会话吸入隧道而被服务端 `90-route.json` 自指拦截；RFC1918 私网保持留在 `sing-box`/`mihomo` TUN 内以确保本地 `:53` DNS 劫持不被旁路。
   - **客户端抑制 Private Relay 与前置海外代理**：三端客户端在 `SERVER_DOMAIN` 防回环规则之后、`Global` 模式与 `CN DIRECT` 规则之前，① 对 Private Relay 金丝雀域名 `mask.icloud.com`、`mask-h2.icloud.com`、`mask-api.icloud.com` 返回 DNS `NXDOMAIN`（`sing-box` 原生 `predefined` / `mihomo` `rcode://name_error` + `fake-ip-filter`）并在路由层 `REJECT`；② 将上游 `geosite-cn`/`direct.txt` 中历史遗留 `@cn` 误判的 Google / `.google` / `gstatic.com` / `googleapis.com` / Firebase / `recaptcha.net` / `pki.goog` / `ampproject.org` / `android.com` 等核心海外后缀置于 `CN DIRECT` 之前，统一先拦截 `UDP 443` 抑制 QUIC、再经远端加密 DoH 解析并走 `PROXY`。
   - **客户端代理（PROXY）**：其余所有非中国大陆流量。
   - **客户端规则源**：默认全部锁定至已核验的上游 40 位不可变 Git Commit SHA（自定义为可变分支 URL 时 `00-preflight.sh` 输出非阻塞告警）：`sing-box` 使用官方 `.srs` 二进制规则集（严禁使用已移除的 `geosite`/`geoip` 字段；`1.14` 经顶层 `http_clients` 代理下载，`1.12` 兼容模式自动切换为 `download_detour`）；`mihomo` 使用 `MetaCubeX/meta-rules-dat` 的 `.mrs` 二进制规则集（`sing-box` 与 `mihomo` 均原生将整份 7 万+ 条 `geosite-cn` 绑定至国内加密 DoH）；`Shadowrocket` 使用 `Loyalsoldier/surge-rules` 的 `DOMAIN-SET`（`ENABLE_SUBSCRIPTION=true` 时按订阅注入 `[General] update-url`），因 Shadowrocket 规则语法不支持 `DOMAIN-SET -> 指定 DoH` 绑定，故由 `50-gen-clients.sh` 按底座准入边界同源注入 ~130 条**底座级**国内后缀（`SR_CN_FALLBACK_SUFFIXES`：头部互联网与公有云 CDN 含 `volces.com`/`alibabausercontent.com`/`myalicdn.com`、微信与银联支付清算 `weixin.com`/`weixinbridge.com`/`wechatpay.cn`/`95516.com`、国民级定位底座 `amap.com`/`autonavi.com` 及 Apple 国内直连 CDN 与系统核心子域含 `apps.apple.com`/`itunes.apple.com`/`mzstatic.com`/`cdn-apple.com`/`aaplimg.com`、`ls.apple.com`/`gs-loc-cn.apple.com`/`iphone-ld.apple.com`/`maps.apple.com`/`apple-mapkit.com`/`weatherkit.apple.com`/`weather-*.apple.com`、`time.apple.com`/`time.asia.apple.com`、`push.apple.com`/`ess.apple.com`/`configuration.apple.com`/`xp.apple.com`/`swallow.apple.com`/`pancake.apple.com`/`smp-device-content.apple.com`/`ipcdn.apple.com`/`init-p01md.apple.com`/`cds.apple.com`/`guzzoni.apple.com`/`smoot.apple.com`、`mesu.apple.com`/`sw*.apple.com`/`ocsp*.apple.com` 等）至 `[Rule]` 与 `[Host]` 国内 DoH；长尾非 `.cn` 国内域名则先经远端加密 `#proxy` DoH 安全解析并由远程 `DOMAIN-SET` 走 `DIRECT`（严禁将垂直 App 或第三方广告/统计 SDK 收录进 `SR_CN_FALLBACK_SUFFIXES`）。
   - **服务端出站安全拒绝顺序（项目安全策略）**：在 `90-route.json` 中依次拦截：① `localhost` / `ip6-localhost` / `.local` 域名 → ② `TCP 25`（防垃圾邮件封机，保留 `465`/`587`）→ ③ 高危 SMB/NetBIOS 与 BT 端口（独立拆分为单端口规则 `135`、`445`、`6969` 与端口段规则 `137:139`、`6881:6889`，避免同条规则按逻辑 `AND` 求交集失效）→ ④ `bittorrent` 协议（防 DMCA 投诉）→ ⑤ `action: resolve`（`SERVER_IPV6=false` 时强制 `strategy: ipv4_only`）→ ⑥ `ip_is_private: true` 及项目安全策略显式拒绝网段（`0.0.0.0/8`、`100.64.0.0/10` CGNAT/云元数据、`169.254.0.0/16`、`192.0.0.0/24`、`198.18.0.0/15`、`224.0.0.0/4` 多播、`240.0.0.0/4` 保留/广播、VPS 自身 `SERVER_IP/32` 及本机全局 IPv6 `/128`、IPv6 `::/128` / `::1/128` / `::ffff:0:0/96` IPv4 映射 / `64:ff9b::/96` 与 `64:ff9b:1::/48` NAT64 / `100::/64` / `fc00::/7` / `fe80::/10` / `ff00::/8`；`SERVER_IPV6=false` 时追加 `ip_version: 6` 拒绝）→ ⑦ 其余走 `direct`。
3. **DNS 与 IPv6 防泄漏**：
   - 三端客户端均采用免域名 Bootstrap 的加密 IP-DoH（零明文 UDP 53 配置，且统一启用 `:53` DNS 劫持防止应用硬编码明文 DNS 旁路）：国内域名与 `SERVER_DOMAIN` 由 `https://${DNS_DIRECT}/dns-query`（静态白名单 `223.5.5.5` | `223.6.6.6`）直连加密解析；非大陆域名在三端均经代理隧道由远端 DoH `https://${DNS_REMOTE}/dns-query`（静态白名单 `1.1.1.1` | `1.0.0.1` | `8.8.8.8` | `8.8.4.4` | `9.9.9.9`）解析（其中 `Shadowrocket` 在 `[General]` 显式声明 `https://${DNS_REMOTE}/dns-query#proxy`、备用 `#proxy` DoH、`dns-direct-fallback-proxy = false`、`hijack-dns = *:53`，并在 `[Host]` 中为 `SERVER_DOMAIN` 及国内/Apple 直连后缀指定 `server:https://${DNS_DIRECT}/dns-query`）；`00-preflight.sh` 在联网预检中执行真实 RFC 8484 `application/dns-message` 查询验收（校验 IP-SAN 证书、`HTTP 200` 与 `RCODE=NOERROR`）。
   - 当 `SERVER_IPV6=false`（默认）时，服务端与客户端 DNS 均强制禁用 IPv6（`ipv4_only` / `dns.ipv6: false`），客户端 TUN 同时分配 IPv6 地址（`fdfe:dcba:9876::1/126`）接管宿主双栈 IPv6 流量并在路由层本地 `REJECT`，杜绝原生 IPv6 绕过虚拟网卡泄漏。
   - 客户端节点出站 `server` **一律直接填写 `SERVER_IP`**，`SERVER_DOMAIN` 仅作 TLS SNI。
4. **QUIC 抑制与非 443 UDP 承载**：
   - 客户端在本地 `REJECT` 目标为非中国大陆 `UDP 443` 的流量（`sing-box.json` 规则同时覆盖 `Global` 全局模式），迫使浏览器秒级回退至 HTTP/2 (TCP)，使 `VLESS-XTLS-Vision` 在内层 TLS 1.3 握手完成后切换直通转发以消除 TLS-in-TLS 特征，并在支持的 Linux TCP 路径下启用 `splice` 零拷贝转发。
   - `UDP 123`（NTP）由客户端前置规则统一走本地 `DIRECT` 旁路；其余非 `443` 端口的 UDP 流量（语音、连麦、游戏）自然放行并随当前选中节点转发（VLESS 采用 `xudp` 封装；开启 `ENABLE_HY2=true` 时可由 Hysteria2 原生 QUIC 承载）。

---

## 2. 协议与组件契约

### 2.1 主协议：`VLESS + TCP + REALITY + Vision`（Self-steal 自有域名）
- **入站端口**：`VLESS_PORT`（默认 `443/tcp`），初始支持零订阅用户（`users: []`）待机，`tls.reality.max_time_difference` 设为 `"2m"`。
- **握手、双层认证与透明回落**：`sing-box` REALITY 通过单一 `tls.reality.handshake`（指向本机 `127.0.0.1:${REALITY_HANDSHAKE_PORT}`，默认 `8443`）同时承担真实 TLS 握手转发与未通过 REALITY 认证连接的透明回落；若客户端通过 REALITY 握手但携带未知或已吊销的 VLESS UUID，则在 VLESS 入站层直接拒绝并关闭连接（不回落至 Nginx）。Cloudflare 解析必须为 **DNS only（灰色云朵）**。
- **入口抗耗尽与本机 Nginx**：公网 `VLESS_PORT/tcp` 由独立 `nftables` 表 `table inet singtun_guard`（`singtun-vless-guard.service` 持久化）实施源 IP 级防护：先以带 `flags dynamic,timeout` 与 `timeout 1m` 的新建 `SYN` 速率限制（`120/second burst 240`，`update` 刷新）直接 `drop`，再对仅声明 `flags dynamic` 的动态集合执行 `add`（`ct count over 256` 触发 `reject with tcp reset`；由内核 `NFT_EXPR_GC` 在连接归零后自动回收，严禁叠加 `timeout` 以免内核返回 `EOPNOTSUPP`），防止慢连接耗尽回环握手槽位。本机 Nginx 仅监听 `127.0.0.1:${REALITY_HANDSHAKE_PORT}`（`ssl http2`，TLS 1.2/1.3，`server_tokens off`，`access_log off`，错误日志 `/var/log/nginx/error.log`，收敛 `client_header_timeout 10s` / `keepalive_timeout 15s` / `reset_timedout_connection on` 并调优 `LimitNOFILE=65535`、`worker_rlimit_nofile 65535` 与默认 `worker_connections 768 -> 4096`），不对公网直接暴露端口；当已安装 Nginx `>= 1.19.4` 时自动启用 `default_server` + `ssl_reject_handshake on;` 拒绝未知/空 SNI 握手，低版本（如 Ubuntu 22.04 `1.18.0`）保持真实证书单站点模式。
- **静态站点内容与防软链穿越（`/var/www/singtun-site`）**：若存在非空的 `private/www/`（排除 `.gitkeep`；预检与部署均严禁包含任何符号链接，文件权限设置采用防跟随 `chown -RP` + `find -type d/f chmod`）则原样部署；否则混入实例私有密钥（`REALITY_PRIVATE_KEY` + `SUB_PATH_PREFIX` + `SERVER_DOMAIN`）计算摘要，从多套完全异构的 HTML 骨架、CSS 样式、配色与行业文案池中生成无特征多态静态页（不输出任何公开可重算哈希指纹，严禁残留 `__[A-Z0-9_]+__` 占位符）。Nginx 根站与订阅块统一开启 `disable_symlinks on from=$document_root;`。
- **高熵公网订阅托管**：当 `ENABLE_SUBSCRIPTION=true`（默认）时，Nginx 通过 `location ^~ /${SUB_PATH_PREFIX}/` 映射至 `/var/lib/singtun/sub-web/`，启用 `autoindex off`、`access_log off`、`etag off`、`if_modified_since off`、`disable_symlinks on from=$document_root;`，返回 `Cache-Control: no-store`、`Referrer-Policy: no-referrer`、`X-Robots-Tag: noindex, nofollow` 并清空 `Last-Modified` 响应头，且通过 `try_files $uri =404;` 使任何猜错路径、目录或越界软链请求返回与根站完全一致的内置 `404` 响应头与页面。

### 2.2 备用协议：`Hysteria2`（`ENABLE_HY2=false` 默认关闭）
- **入站配置（`20-inbound-hy2.json`）**：监听 `HY2_PORT`（默认 `8443/udp`），复用 `/etc/singtun/cert/` 下同一张 Let's Encrypt 证书；`masquerade` 采用 `file` 模式直接复用 `/var/www/singtun-site` 静态站点目录（避免请求 `127.0.0.1` 触发 TLS SAN 不匹配 `502` 且彻底隔离公网订阅目录）；默认 `HY2_OBFS=false`（保持标准 QUIC / HTTP/3 外观，开启 `HY2_OBFS=true` 时在服务端与三端客户端同步注入同源派生的 `salamander` 混淆密码）。
- **端口跳跃（`HY2_HOP_PORTS`）**：配置形如 `20000-30000` 时，由独立 `nftables` 表 `table inet singtun_hy2`（限定 `fib daddr type local udp dport <start>-<end> redirect to :<HY2_PORT>`）与 `singtun-hy2-hop.service` 在 `sing-box` 端口就绪后持久化；关闭或卸载时幂等清理表、服务与 UFW 规则。
- **客户端策略组注入**：启用后，`sing-box.json` 自动生成 `proxy`（`selector`，默认选中 `vless-out`）、`auto`（`urltest`）、`vless-out`、`hy2-out`；`mihomo.yaml` 自动生成 `PROXY`（`select`，默认选中 `<SERVER_DOMAIN>-<name>`）与 `AUTO`（`url-test`）；`v2ray` Base64 订阅同步包含两条节点。

### 2.3 证书生命周期（`30-cert.sh`）
- **签发工具**：官方 `acme.sh v3.1.0` 归档包（强制校验固定 SHA256），通过 `CF_API_TOKEN`（仅需 `Zone.DNS:Edit`）执行 Cloudflare `dns_cf` 签发 ECC (`ec-256`) 证书。
- **安装路径与权限**：安装至 `/etc/singtun/cert/fullchain.pem` 与 `key.pem`；目录权限 `root:sing-box 0750`，私钥权限 `root:sing-box 0640`。
- **按需重载钩子（`/usr/local/libexec/singtun-cert-reload`）**：证书续期后在 Nginx 已启用时执行 `systemctl reload nginx`，且**仅当 `/etc/sing-box/*.json` 中包含 `hysteria2` 入站时**重启 `sing-box`（避免纯 REALITY 模式下无故断连）；重载或重启失败时记录 `daemon.err` 系统日志并以非零退出（使 `acme.sh v3.1.0` 的 `_installcert` 与 `renewAll` 返回退出码 `1`，`30-cert.sh` 同步拦截报错）。

---

## 3. 既定技术事实表（Established Technical Facts）

### 3.1 状态、锁与事务回滚
- **执行模型与唯一状态源**：`singtun` 直接在目标 VPS 本机原地执行（支持通过 `/usr/local/bin/singtun` 软链解析回仓库根目录）；`private/` 目录权限强制 `0700`，`private/.env` 为全系统唯一状态源（权限与初始化生成的 `private/host-facts.md` 均强制 `0600`；root 运行时校验属主必须为 `0`、合法 `SUDO_USER` 或仓库/`private/` 属主）。`load_env`、`env_file_has_key`、`env_file_apply_batch` 与 `list_env_file_keys` 共用同一纯数据键值解析器（严禁 `source` 执行 Shell 语法，拒绝 `$()`、反引号、未闭合引号与同名重复键，仅允许既定项目配置键、`UUID_*`/`SUB_TOKEN_*` 与受约束通知凭据键，拒绝覆盖 `PATH`/`LD_*`/`BASH*`/`SINGTUN_*`/`SSCTL_*` 等运行环境变量；整份校验通过后才导出环境或更新 `.env.bak` 并 `mv -f` 原子替换，校验失败时原文件与 `.env.bak` 零改动）。`load_env` 在导出后自动调用 `apply_default_env_vars` 补全全部 `DEFAULT_*` 运行时默认值（含非示例域名下的 `derive_default_acme_email` 默认邮箱推导）；`detect_public_ipv4` 优先从本机全局 IPv4 接口探测并回退只读公网 IP 接口（`00-preflight.sh` 完整预检同步拒绝 `@example.com` 等保留示例邮箱）。`30-cert.sh` 另使用专用原子辅助函数 `acme_account_apply_ops` 更新 `${ACME_HOME}/account.conf`（`0600` 临时文件 + `awk` + `mv -f`，保留其余 `acme.sh` 配置行且不触发 `.env` 白名单校验或生成 `.bak`）。
- **公网 `SERVER_IP` 校验**：`00-preflight.sh`、`40-deploy-server.sh` 与 `50-gen-clients.sh` 统一调用 `is_non_public_ipv4` 拒绝非公网 IPv4（`0.0.0.0/8`、`10.0.0.0/8`、`100.64.0.0/10`、`127.0.0.0/8`、`169.254.0.0/16`、`172.16.0.0/12`、`192.0.0.0/24`、`192.168.0.0/16`、`198.18.0.0/15`、`>=224.0.0.0`）；未跳过 OS/DNS 检查的完整预检下同步拒绝 RFC 5737 文档网段（`192.0.2.0/24`、`198.51.100.0/24`、`203.0.113.0/24`）。
- **并发锁**：所有写操作通过 `acquire_singtun_lock` 获取 `private/.singtun.lock`（FD 9，`flock -w 30`），通过 `SINGTUN_LOCK_HELD=true` 支持子进程重入。
- **订阅事务快照与软链直恢复**：`singtun add` / `reset` / `del` 执行前对 `private/.env`、`private/.env.bak`、`private/out/`、原 `/var/lib/singtun/sub-web` 软链目标及（已部署时）`/etc/sing-box` 创建完整快照，并在事务期内设置 `SINGTUN_DEFER_RELEASE_PRUNE=true` 延迟所有旧版本目录删除（含 `ENABLE_SUBSCRIPTION=false` 分支）；若后续同步或校验失败，直接从快照恢复本地文件并将 `sub-web` 原子切回原发布目录（清理未提交的新建目录，不依赖重跑失败脚本），每步严格检查返回码。
- **候选二进制暂存升级**：`singtun upgrade <version>` 先将目标 `.deb` 解压至临时隔离目录，以暂存的候选 `sing-box` 二进制完成服务端与客户端渲染配置 `sing-box check` 预检后，再通过临时 `policy-rc.d` 抑制维护脚本自动重启旧配置并完成包替换与原子部署；失败时完整回滚配置、软链与二进制。

### 3.2 凭据规范与派生算法
- **订阅名称（`name`）**：正则 `^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$`（长度 1–32，禁止下划线与首尾连字符，从源头杜绝环境变量后缀转换冲突）；拒绝保留字（`all`、`none`、`default`、`help`、`sub`、`init`、`deploy`、`add`、`list`、`ls`、`show`、`reset`、`rotate`、`del`、`delete`、`remove`、`rm`、`revoke`、`flush`、`check`、`status`、`logs`、`restart`、`renew`、`upgrade`、`uninstall`），且拒绝与 `.env` 中孤立的 `UUID_*` / `SUB_TOKEN_*` 冲突。
- **订阅变量映射**：后缀 `<SUFFIX> = toupper(tr '-' '_' <name>)`；对应 `UUID_<SUFFIX>`（标准 v4 UUID）与 `SUB_TOKEN_<SUFFIX>`（64 位小写十六进制，256-bit 熵）。
- **订阅路径前缀（`SUB_PATH_PREFIX`）**：`^[a-z0-9]{12,32}$` 且禁止以特征词开头（`init` 默认生成 `p<15位随机hex>`，共 16 位）。
- **REALITY 公私钥对校验与恢复**：`derive_reality_public_key` 通过 OpenSSL PKCS#8 X25519 DER 编码从 `REALITY_PRIVATE_KEY` 派生对应公钥；`00-preflight.sh` 与 `50-gen-clients.sh` 校验 `REALITY_PUBLIC_KEY` 必须与之严格匹配；`singtun init` 检测到合法 `REALITY_PRIVATE_KEY` 且 `REALITY_PUBLIC_KEY` 为空时，自动派生恢复公钥而不轮换私钥。
- **Hysteria2 密钥化密码与混淆同源派生公式**（`derive_hy2_password` / `derive_hy2_obfs_password`，防单条 VLESS `UUID` 泄露离线推导；`check-private-leak.sh` 同时拦截 `v2`、`v1` 与 `obfs` 派生值）：
  ```bash
  printf '%s:%s:singtun-hy2-v2' "${REALITY_PRIVATE_KEY}" "${uuid}" | sha256sum | awk '{print substr($1, 1, 32)}'
  printf '%s:singtun-hy2-obfs-v1' "${REALITY_PRIVATE_KEY}" | sha256sum | awk '{print substr($1, 1, 32)}'
  ```
- **公网订阅原子发布与版本保留**：渲染至 `/var/lib/singtun/releases/sub-web.<ts>.<pid>/<SUB_PATH_PREFIX>/<SUB_TOKEN>/`（含 `v2ray`、`sing-box.json`、`mihomo.yaml`、`shadowrocket.conf`；Nginx 仅映射 `/var/lib/singtun/sub-web` 软链，不映射 `releases/`），通过软链临时文件 + `mv -Tf /var/lib/singtun/sub-web` 原子切换；事务提交后保留当前软链目标及最近 1 个历史成功版本（最多 2 个）并清理更早目录；当 `ENABLE_SUBSCRIPTION=false` 且事务提交后移除软链并清空 `releases/`。

### 3.3 供应链锚点与运行沙箱
- **SagerNet APT GPG 主钥指纹**：固定为 `2C317FBD5D886B4E89BAE8DA6D9152172A2B2F0C`。校验函数拒绝含多个主钥（`pub`）的输入文件，在隔离临时 `GNUPGHOME` 中导入后按完整指纹最小化重导出至 `/etc/apt/keyrings/sagernet.asc`，并二次校验导出文件公钥块数量为 `1`、主钥（`pub`）数量为 `1` 且指纹精确匹配。
- **二进制 SHA256 校验表**：
  - `scripts/lib/singbox.sha256`：固定官方 GitHub Release `sing-box_<ver>_linux_<arch>.deb` SHA256（APT 不可用或回退时强校验）。
  - `scripts/lib/mihomo.sha256`：固定官方 `MetaCubeX/mihomo` Release（当前 `MIHOMO_PINNED_VERSION="v1.19.33"`）压缩包 SHA256，供 CI 与本地 `mihomo -t` 实测校验。
- **`sing-box.service` 安全基线**：以系统用户 `sing-box` 运行；`CapabilityBoundingSet=CAP_NET_BIND_SERVICE`、`AmbientCapabilities=CAP_NET_BIND_SERVICE`、`NoNewPrivileges=true`、`ProtectSystem=strict`、`ProtectHome=true`、`PrivateTmp=true`、`ProtectProc=invisible`、`TasksMax=4096`。部署后同时通过 `systemctl show` 与 `/proc/<MainPID>/status` 实测校验 `CapEff` 精确等于 `0x400`（仅 `CAP_NET_BIND_SERVICE`）。
- **UFW 防火墙标记**：`detect_active_ssh_ports` 仅在 `ssh.socket` 为 `active` 或 `enabled` 时查询其 `Listen` 地址，并采用 IPv6 安全的末段冒号解析提取端口号（防止将 IPv6 地址段误判为端口）；保留宿主当前 SSH 监听端口规则带注释 `# singtun-preserve-ssh`（预检与加固均拒绝代理端口与活跃 SSH 端口冲突，且 `prune_stale_ufw_rules` 在活跃 SSH 端口集合非空时清理已失效的旧 `# singtun-preserve-ssh` 规则）；代理端口带注释 `# singtun-vless-reality`、`# singtun-hy2`、`# singtun-hy2-hop`，端口变更或卸载时仅据此精确清理旧规则且跳过活跃 SSH 端口。

### 3.4 沙箱测试与环境覆写接口
在不具备 root 权限的开发机或 CI 环境中，各脚本支持以下环境变量覆写以执行隔离验证：
| 环境变量 | 作用 |
| :--- | :--- |
| `SINGTUN_PRIVATE_DIR` / `SINGTUN_ENV_FILE` | 覆写 `private/` 目录或 `.env` 文件路径（含 `check-private-leak.sh` 隔离测试） |
| `SKIP_OS_CHECK=true` / `SKIP_DNS_CHECK=true` / `SKIP_PORT_CHECK=true` | 在 `00-preflight.sh` 中按需跳过宿主发行版、公网 DNS 解析或本地端口监听检查（`singtun check` 默认开启） |
| `SINGTUN_CERT_DIR_OVERRIDE` / `SINGTUN_WEB_ROOT_OVERRIDE` | 在 `40-deploy-server.sh` 离线渲染检查中覆写证书目录与静态站点根目录路径 |
| `SINGTUN_NGINX_REJECT_UNKNOWN_SNI` | 覆写 Nginx 未知 SNI 握手拒绝检测策略（`auto` 默认按版本检测，`true`/`false` 供双分支测试） |
| `SINGTUN_SELF_IPV6_OVERRIDE` | 在 `SERVER_IPV6=true` 时由 `40-deploy-server.sh` 与 `50-gen-clients.sh` 读取，显式注入服务端本机公网 IPv6 地址以验证服务端 `/128` 自指拒绝及客户端自指排除 |
| `SINGTUN_ALLOW_NONROOT_SUB=true` | 允许非 root 用户执行 `add` / `reset` / `del` 并在本地更新 `.env` 与客户端产物（跳过线上 `40-deploy-server.sh`） |
| `SINGTUN_SUB_WEB_BASE_OVERRIDE` | 覆写 `/var/lib/singtun` 发布根目录（供非 root 验证 `sub-web` 软链原子切换与清理） |
| `SINGTUN_MIHOMO_BIN` / `SINGTUN_MIHOMO_WORKDIR` | 指定 `mihomo` 可执行文件与预置 `.mrs` 规则目录，在 `50-gen-clients.sh` 与 `singtun check` 中自动执行 `mihomo -d <workdir> -t -f mihomo.yaml` |
| `SINGTUN_SINGBOX_BIN` / `SINGTUN_STAGE_DEB_PATH_OVERRIDE` | 指定候选 `sing-box` 二进制路径或本地 `.deb` 暂存包路径，供 `singtun upgrade` 暂存预检与离线测试调用 |
| `SINGTUN_FAIL_AFTER_SUB_WEB_SWITCH=true` / `SINGTUN_FAIL_AFTER_SUB_SYNC=true` | 在 `sub-web` 软链切换后或订阅运行时同步完成后注入测试故障，验证全分支原软链与快照回滚 |
| `SINGTUN_ALLOW_NONROOT_UPGRADE_TEST=true` | 允许非 root 测试 `singtun upgrade` 暂存候选二进制预检与事务回滚 |
| `SINGTUN_SAGERNET_GPG_FPR_OVERRIDE` | 供 CI 负向测试注入错误 GPG 指纹验证拦截逻辑 |
| `SINGTUN_FORCE_PRODUCTION_CHECKS` | 设 `true` 时即便开启 `SKIP_OS_CHECK`/`SKIP_DNS_CHECK` 也强制执行生产级文档 IP 与 `@example.com` 保留邮箱拦截（供 CI 负向测试） |
| `SINGTUN_PUBLIC_IPV4_OVERRIDE` | 覆写 `detect_public_ipv4` 公网 IPv4 自动探测结果（供 `setup` 离线测试使用） |
| `SINGTUN_SETUP_CONFIG_ONLY` / `SINGTUN_SETUP_SKIP_DEPLOY` / `SINGTUN_SETUP_SKIP_DNS_CHECK` / `SINGTUN_SETUP_USE_STDIN` / `SINGTUN_SETUP_ALLOW_DOC_IP` | 供 CI 与非交互环境隔离测试 `singtun setup` 向导三档配置流程 |
| `SINGTUN_INSTALL_ALLOW_NONROOT_TEST` | 允许非 root 测试 `install.sh` 克隆、`/opt/singtun` 更新保留 `private/` 与软链安装 |

---

## 4. 仓库目录结构与命令契约

```text
.
├── AGENTS.md                  # AI Agent 架构契约与既定事实基线（本文件）
├── PLAN.md                    # AI Agent 阶段进度、待办事项与验收断言基线
├── README.md                  # 面向使用者与人类开发者的使用指南与架构说明
├── LICENSE                    # MIT
├── .gitignore                 # 忽略 private/ 及临时/密钥文件
├── singtun                    # 唯一 CLI 入口（扁平化一级子命令，支持软链调用）
├── install.sh                 # 一键引导安装/更新脚本（安装至 /opt/singtun，软链至 /usr/local/bin/singtun，支持 curl | sudo bash）
├── examples/                  # 公开配置模板（仅含 RFC 保留示例值）
│   ├── env.example
│   └── host-facts.example.md
├── templates/
│   ├── server/                # singbox/{00-log,05-dns,10-inbound-vless,20-inbound-hy2,90-route}.json, nginx/site.conf, systemd/sing-box.service, www/index.html
│   └── client/                # singbox/{05-experimental,10-dns,20-inbound-tun,30-outbound-vless,40-route}.json, mihomo.yaml, shadowrocket.conf
├── scripts/
│   ├── lib/common.sh          # 锁、纯数据解析与原子写 .env、格式校验、临时清理、订阅遍历与 URI/密钥化密码派生
│   ├── lib/singbox.sha256     # 官方 sing-box deb 包固定 SHA256 表
│   ├── lib/mihomo.sha256      # 官方 mihomo 压缩包固定 SHA256 表
│   ├── 00-preflight.sh        # 系统/架构、变量完整性、软链隔离、DNS A 记录、DoH 连通性与端口冲突预检
│   ├── 10-harden.sh           # UFW 最小暴露面、VLESS 连接限流 (singtun_guard)、Hysteria2 端口跳跃 (singtun_hy2) 与 NTP 同步
│   ├── 20-optimize.sh         # BBR、文件句柄、TCP/UDP 缓冲区与 journald 64MB/7天限额（兼容容器）
│   ├── 30-cert.sh             # acme.sh v3.1.0 + Cloudflare DNS-01 签发、安装与按需重载钩子
│   ├── 40-deploy-server.sh    # 官方 GPG/SHA256 校验安装 sing-box + Nginx，多态站点渲染校验与 systemd/CapEff 核验
│   ├── 50-gen-clients.sh      # 渲染各订阅产物（v2ray/links.txt/sing-box.json/mihomo.yaml/shadowrocket.conf/urls.txt）并软链发布
│   └── hooks/
│       ├── install-hooks.sh       # 幂等挂载原生 Git pre-commit 与 commit-msg 钩子
│       └── check-private-leak.sh  # 拦截 private/ 文件、敏感值（含上级域名、v2/v1/obfs 派生密码、Base64 与 sub:// 密文）及 file:/// 链接
├── .github/workflows/ci.yml   # ShellCheck + 供应链正负向测试 + 订阅全生命周期与回滚 + 多态站点/软链隔离 + 防 SSRF/Rebinding 动态测试
└── private/                   # ★ git 忽略，由 singtun init 初始化
    ├── .env                   # 唯一状态源（600）
    ├── host-facts.md          # 实例事实与真机验证记录（600）
    ├── www/                   # 可选自定义回落静态站点（严禁含符号链接）
    └── out/<name>/            # 生成的各订阅本地产物备份
```

### 4.1 `singtun` 一级子命令契约
所有用户操作通过 `./singtun <command>`（或已软链的 `singtun <command>`）完成（无二级子命令；所有命令均支持 `-h` / `--help` 及 `singtun help <command>`）：
- **生命周期**：`setup [--config-only]`（交互式引导向导：智能默认值、DNS 实时核验、三档部署菜单、`deploy` 封装与首条订阅创建）、`init`（幂等初始化并自动补全全部缺失默认项与密钥）、`deploy`（严格非交互；一键部署/重部署）、`upgrade <version>`（先暂存候选二进制完成配置预检，再替换二进制与配置；失败自动无损回滚）、`uninstall [--purge-cert]`（移除服务/配置/Nginx 调优/防火墙/`nftables` 表/sysctl，保留 `private/` 与宿主 SSH，默认保留证书）。
- **订阅管理**：`add [name] [--qr <type>]`（省略 `name` 自动编号 `sub-1`...）、`list`、`show <name> [--qr <type>]`、`reset <name> [--qr <type>]`（同时轮换 UUID、Hysteria2 派生密码与 Token）、`del <name>`、`flush [name] [--local-only]`。`--qr` 支持 `v2ray|singbox|mihomo|sr|vless|hy2`。
- **诊断与运维**：`check`、`status`（核查 `sing-box`/`nginx`/`singtun-vless-guard`/`singtun-hy2-hop` 状态及证书 `< 20` 天到期告警）、`logs`、`restart`、`renew`、`help [command]`。

### 4.2 代码与验证强制规范
1. **Bash 规范**：所有脚本必须以 `set -euo pipefail` 开头，通过 `shellcheck -x singtun install.sh scripts/*.sh scripts/lib/*.sh scripts/hooks/*.sh` 零警告；除显式交互入口 `singtun setup` 外，其余所有命令（含 `singtun deploy`）均无交互式阻塞提示。
2. **模板渲染**：JSON 配置一律通过 `jq` 构造或注入参数（严禁对 JSON 直接 `envsubst`），部署前必须通过 `sing-box check`（且无 `deprecated`/`warn` 输出）与 `nginx -t`。
3. **提交前必跑检查**：任何代码或文档修改完成后，Agent 必须执行 `bash scripts/hooks/check-private-leak.sh` 与 `./singtun check` 确认零回归。
