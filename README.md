# ssctl — 个人跨境代理一键部署与多端订阅管理工具

`ssctl` 是一个面向个人与多设备场景的自建代理服务端部署与订阅管理工具。只需维护一份私有配置文件（`private/.env`），即可在自有海外 VPS 上一键部署基于 **sing-box `VLESS + REALITY + Vision`（配合自有域名真实证书回落）** 的代理服务，并按需为每台设备生成独立的客户端配置与订阅链接。

### 核心特性

- **单一固定出口，精准国内外分流**：多台设备（macOS、Windows、Linux、iOS）共用同一台 VPS 的固定公网 IPv4 作为国际出口；国内流量与私有网段本地直连，海外流量走代理，不引入任何改变出口 IP 的第三方中转。
- **开箱即用的客户端防泄漏配置**：每次创建订阅会自动生成通用节点（`v2ray`）、`sing-box`、`mihomo (Clash.Meta)` 与 `Shadowrocket` 四种格式。其中 `sing-box.json` 与 `mihomo.yaml` 已内置虚拟网卡严格路由、国内外加密 DoH、IPv6 旁路阻断与海外 QUIC 自动降级，导入一条链接即可做到零国内 DNS 暴露。
- **按设备独立订阅，一键轮换作废**：初始部署支持零预设用户待机；日常通过 `ssctl add` 为每台设备分配独立凭据与 256 位随机订阅链接，一旦怀疑链接外泄，执行 `ssctl reset <name>` 即可同时作废旧节点与旧链接。
- **可选 Hysteria2 备用通道**：支持一键开启基于 QUIC 的 Hysteria2 备用入站（支持 UDP 端口跳跃与 `salamander` 混淆），在晚高峰 TCP 受限或高丢包网络下无缝切换。
- **轻量、幂等、故障自回滚**：基于原生 Bash 脚本与 `systemd` 构建，无容器或常驻面板开销，1 核 / 512 MB 低配机器即可稳定运行；所有变更先离线校验再原子切换，任一步骤失败自动回滚。

---

## 一、快速开始（服务端部署）

### 1.1 前置准备

1. **一台海外 VPS**：系统为 Debian 12、Ubuntu 22.04 或 Ubuntu 24.04（`amd64` 或 `arm64` 架构），具备固定公网 IPv4 地址与 `root` / `sudo` 权限。
2. **一个托管在 Cloudflare 的域名**：添加一条 A 记录将子域名（例如 `node.example.com`）指向 VPS 公网 IPv4，且代理状态必须设为 **DNS only（灰色云朵）**。
3. **Cloudflare API Token**：在 Cloudflare 后台创建一个具备对应域名 `Zone → DNS → Edit` 权限的 API 令牌，用于自动签发和续期 Let's Encrypt 证书（无需开放 80 端口）。

### 1.2 五步完成部署与创建订阅

在 VPS 上依次执行以下命令：

```bash
# 1. 克隆仓库并初始化私有配置目录（自动生成 REALITY 密钥对、short_id 与高熵订阅路径前缀）
git clone <repo-url> ss && cd ss
./ssctl init

# 2. 编辑配置文件，填入服务器 IP、子域名、证书邮箱与 Cloudflare Token
vi private/.env

# 3. 离线渲染并校验服务端与 4 种客户端配置（不改动系统环境）
./ssctl check

# 4. 一键部署服务端（完成防火墙收敛、BBR 优化、证书签发与服务启动，支持重复执行）
sudo ./ssctl deploy

# 5. 按设备创建订阅（省略名称则自动编号为 sub-1），立即输出 4 条专属客户端订阅链接
sudo ./ssctl add iphone
```

如果需要在终端直接用手机扫码导入，可追加 `--qr <类型>` 参数按需渲染单个二维码（支持 `v2ray`、`singbox`、`mihomo`、`sr`、`vless`、`hy2`）：

```bash
./ssctl show iphone --qr v2ray      # 渲染通用节点订阅二维码（适合 Shadowrocket / v2rayN）
./ssctl show iphone --qr singbox    # 渲染 sing-box 远程配置二维码（适合 iOS / macOS SFM）
```

> [!WARNING]
> **公网订阅凭据安全提醒**
> 当 `ENABLE_SUBSCRIPTION=true`（默认）时，生成的 HTTPS 订阅链接本身即包含完整代理凭据。**切勿将订阅链接或二维码截图、公开粘贴或转发他人**。若怀疑链接泄露，请立即执行 `sudo ./ssctl reset <name>` 同时作废旧凭据与旧链接；若追求纯离线使用，可在 `private/.env` 中将 `ENABLE_SUBSCRIPTION` 设为 `false` 并重新运行 `sudo ./ssctl deploy`。

### 1.3 核心配置项参考（`private/.env`）

完整参数模板与注释见 [`examples/env.example`](examples/env.example)，常用配置项如下：

| 类别 | 变量名 | 说明 |
| :--- | :--- | :--- |
| **基础与证书** | `SERVER_IP` / `SERVER_DOMAIN` | VPS 公网 IPv4 / 连接与订阅使用的子域名（Cloudflare 必须保持 DNS only） |
| | `ACME_EMAIL` / `CF_API_TOKEN` | 证书通知邮箱 / Cloudflare `Zone.DNS:Edit` API 令牌（可选配 `ACME_NOTIFY_HOOK`） |
| **版本与兼容** | `SINGBOX_VERSION` | 服务端锁定安装的官方 `sing-box` 版本号 |
| | `SINGBOX_CLIENT_COMPAT` | 客户端 `sing-box.json` 语法版本：默认 `1.14`；若移动端客户端版本低于 1.14 可设为 `1.12` |
| **订阅托管** | `ENABLE_SUBSCRIPTION` | 是否启用公网 HTTPS 订阅托管（默认 `true`；设为 `false` 则仅在本地 `private/out/` 生成配置文件） |
| | `SUB_PATH_PREFIX` / `SUBSCRIPTIONS` | `init` 自动生成的随机路径前缀 / `add`、`del` 自动维护的订阅列表（无需手改） |
| **备用协议** | `ENABLE_HY2` / `HY2_PORT` | 是否启用 Hysteria2 备用协议（默认 `false`）/ UDP 监听端口（默认 `8443`） |
| | `HY2_HOP_PORTS` / `HY2_OBFS` | 可选 UDP 端口跳跃范围（如 `20000-30000`）/ 是否开启 `salamander` 数据包混淆（默认 `false`）；修改后需重新执行 `sudo ./ssctl deploy` |
| **网络与日志** | `SERVER_IPV6` / `SERVER_LOG_LEVEL` | 服务端是否启用 IPv6（默认 `false`，强制 `ipv4_only` 防泄漏）/ 服务端日志级别（默认 `warn`） |
| | `DNS_DIRECT` / `DNS_REMOTE` | 国内域名直连加密 DoH（默认 `223.5.5.5`）/ 海外域名加密 DoH（默认 `1.1.1.1`） |
| | `RULESET_*` | 三端远程分流规则集地址（默认固定至已验证的上游 40 位不可变 Git Commit SHA） |

---

## 二、客户端选型与接入指南

建议**为每台设备单独创建一个订阅**（如 `mac`、`win`、`linux`、`ios`），便于独立查看状态或单独重置凭据。每条订阅均提供以下 4 种格式的链接（本地副本保存在 `private/out/<name>/`）：

- **`[1] v2ray`**：Base64 通用节点订阅（仅包含节点连接信息，分流与 DNS 依赖客户端软件自身设置）。
- **`[2] sing-box.json`**：`sing-box` 官方全托管 TUN 配置。
- **`[3] mihomo.yaml`**：`Clash.Meta (mihomo)` 系客户端全托管 TUN 配置。
- **`[4] shadowrocket.conf`**：iOS Shadowrocket 远程分流与加密 DNS 规则配置。

### 2.1 为什么优先推荐 `[2] sing-box.json` 或 `[3] mihomo.yaml`？

Claude（网页端、Desktop 客户端、Claude Code CLI）等对网络环境敏感的服务，会同时检测**出口 IP、DNS 解析出口所在地、IPv6 旁路以及 WebRTC 本地网卡泄漏**。

本项目生成的 `[2] sing-box.json` 与 `[3] mihomo.yaml` 属于**开箱即用的全托管配置**：已在配置文件内部锁定了虚拟网卡严格路由（`strict_route`）、海外域名远端 DoH 代理隧道解析、IPv6 彻底阻断、海外 `UDP 443` (QUIC) 本地拦截降级，以及启用 Hysteria2 时的主备自动测速策略组。客户端导入一条链接即可完整生效，无需手动逐项调整软件防泄漏开关。

| 平台 | 推荐级别 | 客户端软件 | 核心优势 | 常驻内存 | 导入的订阅格式 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **macOS** | **首选** | **SFM** (`sing-box` 官方) | 与服务端同源内核，原生系统扩展 (`strict_route` + `ipv4_only`) | 30~50 MB | `[2] sing-box.json` |
| | 备选 1 | **Clash Verge Rev** | 活跃开源 (`Tauri` + `mihomo`)，内置 `strict-route` 与 `fake-ip` | 60~90 MB | `[3] mihomo.yaml` |
| | 备选 2 | **FlClash** | 开源 (`Flutter` + `mihomo`)，界面轻量跨平台一致 | 60~100 MB | `[3] mihomo.yaml` |
| **Windows** | **首选** | **Clash Verge Rev** | 服务模式 + TUN 接管全系统与终端/WSL2，开机自启不弹 UAC | 50~80 MB | `[3] mihomo.yaml` |
| | 备选 1 | **v2rayN** (自定义配置) | 老牌开源，作为自定义配置导入 `sing-box.json` 可完整保留防泄漏规则 | 45~70 MB | `[2] sing-box.json` |
| | 备选 2 | **FlClash** | 不依赖系统 WebView2，开箱即用 | 70~100 MB | `[3] mihomo.yaml` |
| **Linux** | **首选** | **原生 `sing-box` CLI** | 官方 APT 源签名安装，`systemd` 守护 `tun0` 全局路由，零 GUI 开销 | 20~35 MB | `[2] sing-box.json` |
| | 备选 1 | **原生 `mihomo` CLI** | 单二进制配合 `.mrs` 高效规则集与 `fake-ip` | 30~45 MB | `[3] mihomo.yaml` |
| | 备选 2 | **Clash Verge Rev / FlClash** | 官方提供 `.deb` 安装包，带桌面托盘图标 | 80~120 MB | `[3] mihomo.yaml` |
| **iOS** | **首选 A** | **SFM** (`sing-box` 官方) | 100% 开源且与服务端同核，单条链接同时导入节点、分流与防泄漏策略 | < 50 MB | `[2] sing-box.json` |
| | **首选 B** | **Shadowrocket** | 按需连接成熟省电，需同时导入 `[1]` 节点订阅与 `[4]` 远程配置 | < 50 MB | `[1] v2ray` + `[4] shadowrocket.conf` |
| | 备选 | **Stash** | 兼容 `mihomo` 语法，单文件导入节点与分流规则 | < 50 MB | `[3] mihomo.yaml` |

---

### 2.2 各平台接入步骤

#### 1. macOS — SFM（首选）或 Clash Verge Rev
- **SFM**：前往 [SagerNet/sing-box Releases](https://github.com/SagerNet/sing-box/releases) 下载最新 `SFM-1.14.*-universal.dmg`（若使用低于 `1.14.0` 的 App Store 版本，可在服务端 `.env` 设置 `SINGBOX_CLIENT_COMPAT=1.12` 后执行 `sudo ./ssctl flush`）。打开软件进入 `Profiles` → `New` → `Type: Remote`，粘贴 `[2] sing-box.json` 订阅 URL（或点击 `ssctl show` 输出的 `sing-box://` 一键导入深链），在 `Dashboard` 中启动并勾选 `Start At Login`。
- **Clash Verge Rev**：在「订阅 (Profiles)」中粘贴 `[3] mihomo.yaml` 订阅链接导入，在设置中开启 **TUN 模式**。

#### 2. Windows — Clash Verge Rev（首选）或 v2rayN
- **Clash Verge Rev**：在「订阅 (Profiles)」中粘贴 `[3] mihomo.yaml` 订阅链接导入 → 进入「设置 (Settings)」点击 **服务模式 (Service Mode)** 右侧盾牌图标安装并启用 → 开启 **TUN (虚拟网卡) 模式**（此时可关闭“系统代理”，纯靠 TUN 即可接管桌面应用、命令行终端与 WSL2）。
- **v2rayN**：为完整生效本项目的 DNS 防泄漏与 QUIC 拦截规则，建议下载 `[2] sing-box.json` 并通过「服务器 → 添加自定义配置服务器」导入（核心选择 `sing-box` 并以管理员身份运行，同时关闭 v2rayN 顶栏自带的 Tun 按钮以避免创建双虚拟网卡）。若仅在常规“订阅分组”中导入 `[1] v2ray`，请务必在 v2rayN 路由设置中手动添加 `udp:443 -> block` 并将 DNS 设为 `ipv4_only`。

#### 3. Linux — 原生 `sing-box` CLI + systemd（首选）
```bash
# 1. 下载官方 APT 源 GPG 公钥并核验主钥指纹，确认无误后安装 sing-box
TMP_KEY="$(mktemp)"
curl -fsSL https://sing-box.app/gpg.key -o "${TMP_KEY}"
gpg --batch --with-colons --show-keys "${TMP_KEY}" | awk -F: '$1=="fpr"{print $10}' | grep -Fxq 2C317FBD5D886B4E89BAE8DA6D9152172A2B2F0C
sudo install -d -m 0755 /etc/apt/keyrings
sudo install -m 0644 "${TMP_KEY}" /etc/apt/keyrings/sagernet.asc
rm -f "${TMP_KEY}"
echo "Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc" | sudo tee /etc/apt/sources.list.d/sagernet.sources
sudo apt-get update && sudo apt-get install -y sing-box

# 2. 拉取专属 sing-box.json 订阅配置并启动 systemd 服务（自动创建 tun0 接管路由）
sudo curl -fsSL "<你的 [2] sing-box.json 订阅链接>" -o /etc/sing-box/config.json
sudo chmod 600 /etc/sing-box/config.json
sudo sing-box check -c /etc/sing-box/config.json
sudo systemctl enable --now sing-box
```

#### 4. iOS — SFM（首选 A）或 Shadowrocket（首选 B，需非国区 Apple ID）
- **SFM**：操作方式与 macOS 一致，直接导入 `[2] sing-box.json` 远程配置即可（若 App Store 版本为 1.12，在服务端设置 `SINGBOX_CLIENT_COMPAT=1.12` 后运行 `sudo ./ssctl flush`）。
- **Shadowrocket 完整导入与设置核对清单**：
  1. **添加节点订阅**：点击首页右上角 `+` → 类型选择 `Subscribe` → URL 粘贴 `[1] v2ray` 订阅链接（或扫描 `--qr v2ray` 二维码）。
  2. **启用远程分流配置**：进入底部「配置」标签页 → 点击右上角 `+` → 粘贴 `[4] shadowrocket.conf` 链接下载 → 点击该配置文件并选择 **「使用配置」**（若此前手动修改过本地配置，可点击右侧 `ⓘ` → **「更新」** 恢复标准参数）。
  3. **核对关键开关**（避免历史设置干扰分流或造成断流）：

| 菜单路径 | 推荐设置 | 作用说明 |
| :--- | :--- | :--- |
| **首页 → 全局路由** | **配置 (Config)** | 严格按 `shadowrocket.conf` 规则分流；下方若有「代理类型」保持默认 `None`。 |
| **首页 → VLESS 节点 `ⓘ`** | 流控 `xtls-rprx-vision`；**关闭多路复用 (Mux)** | Vision 负责消除 TLS-in-TLS 特征，不可与普通 Mux 混用；「允许不安全」保持关闭。 |
| **配置 → `shadowrocket.conf` `ⓘ`** | 保持远程默认（无需手改） | 配置文件已自动设定国内外加密 DoH、拦截明文 53 端口 DNS（`hijack-dns`）、禁用 IPv6、启用 `bypass-system` / `skip-proxy`（含 `*.local`、`*.lan`）及远程自更新 `update-url`。 |
| **设置 → 延迟测试方法** | **`CONNECT`**（或 `URL Test`） | 真正通过代理隧道请求测试连通性（默认的 `ICMP` 仅测服务器 Ping，无法反映代理状态）。 |
| **设置 → 按需连接** | **开启按需连接 + 始终连接**；**关闭睡眠时断开** | 锁屏、重启或 Wi-Fi 切换蜂窝网络时保持 VPN 无缝在线。 |
| **设置 → 隧道** | 开启强制路由与排除局域网；**关闭「包括所有网络」** | **切勿开启「包括所有网络」**，否则会劫持苹果推送 (APNs)、AirDrop 与 CarPlay 导致掉线耗电。 |
| **设置 → UDP** | **开启转发**；建议**开启「禁用 STUN」** | 放行非 443 UDP 语音/游戏与 Hysteria2；禁用 STUN 防止 WebRTC 暴露本地真实 IP。 |
| **设置 → TCP** | 开启「禁用 Nagle 算法」；**关闭「开启 Fast Open」** | 降低交互延迟；关闭 TFO 避免国内运营商丢弃带数据 SYN 包引发首连超时。 |
| **设置 → 订阅** | 开启「打开时更新」；**关闭「通过代理更新」** | 订阅域名已在规则中设为直连，关闭「通过代理更新」可确保旧节点失效时仍能直连拉取新订阅。 |
| **设置 → 证书 / 代理共享 / 日志** | 证书解密**关闭**；代理共享**关闭**；日志设为 `warning` 或 `error` | 避免 MITM 证书报错与后台额外耗电。 |

> **提示**：iOS Shadowrocket 在使用 VLESS 节点时，部分应用的非 443 UDP 流量未封装为 XUDP。若遇到语音通话异常或晚高峰运营商对 TCP 限速，可在服务端开启 `ENABLE_HY2=true`，并在客户端一键切换至同源生成的 `*-hy2` 节点。

---

### 2.3 连通性与防泄漏验证

客户端连接成功后，建议通过以下两步确认分流与防泄漏生效：

1. **终端国内外分流验证**：
   ```bash
   curl -4 -s https://myip.ipip.net   # 访问国内站点：应显示本地国内运营商 IP
   curl -4 -s https://api.ip.sb/ip    # 访问国际站点：应显示 VPS 的固定公网 IPv4
   ```
2. **浏览器防探测检查**：
   - 访问 `https://browserleaks.com/dns`：列表中**只能出现海外解析节点（如 Cloudflare United States）**，不应出现任何 `China` 或国内运营商 DNS。
   - 访问 `https://browserleaks.com/webrtc`：页面不应暴露本地公网 IPv4 或 IPv6 地址。

---

## 三、日常运维与故障排查

### 3.1 `ssctl` 命令速查

所有日常操作均通过 `./ssctl <子命令>` 完成（任意子命令均可加 `--help` 或执行 `./ssctl help <子命令>` 查看详细说明与影响范围）：

| 分类 | 命令 | 功能说明 |
| :--- | :--- | :--- |
| **部署与生命周期** | `./ssctl init` | 初始化 `private/` 目录，自动补全密钥与随机订阅前缀，并安装本地 Git 防泄漏钩子 |
| | `./ssctl check` | 离线渲染并校验服务端与 4 种客户端配置，不修改系统状态 |
| | `sudo ./ssctl deploy` | 一键部署或更新服务端（含防火墙、连接限流、BBR、证书与回落站），并同步公网订阅目录 |
| | `sudo ./ssctl upgrade <version>` | 先暂存候选版本完成配置预检，通过后升级二进制与配置；失败自动回滚版本与配置 |
| | `sudo ./ssctl uninstall [--purge-cert]` | 卸载服务、配置、Nginx 站点及防火墙/`nftables` 规则（保留 `private/`；加 `--purge-cert` 一并删除证书） |
| **订阅与客户端管理** | `sudo ./ssctl add [name] [--qr <type>]` | 新增一条订阅（省略名称自动编号 `sub-1`…），同步服务端并输出 4 种订阅链接 |
| | `./ssctl list` | 查看当前已创建的订阅列表及公网订阅托管开关状态 |
| | `./ssctl show <name> [--qr <type>]` | 查看指定订阅的 4 条专属链接、一键导入深链或渲染终端二维码 |
| | `sudo ./ssctl reset <name> [--qr <type>]` | 重置指定订阅的 UUID、Hysteria2 密码与订阅 Token（旧节点与旧链接立即同时作废） |
| | `sudo ./ssctl del <name>` | 吊销并删除指定订阅，立即断开该凭据连接并清理本地与公网产物 |
| | `sudo ./ssctl flush [name] [--local-only]` | 重新生成全部或指定订阅的客户端配置并原子同步至公网订阅目录（加 `--local-only` 仅更新本地副本） |
| **状态、日志与证书** | `sudo ./ssctl status` | 查看 `sing-box`、`nginx` 及防护/跳跃单元运行状态与 TLS 证书剩余天数（低于 20 天自动告警） |
| | `sudo ./ssctl logs` | 实时跟踪 `sing-box` 与 `nginx` 的 systemd 日志（Nginx 错误日志位于 `/var/log/nginx/error.log`） |
| | `sudo ./ssctl restart` | 重启 `nginx`、`sing-box` 及已启用的防护/端口跳跃单元并核验活跃状态 |
| | `sudo ./ssctl renew` | 强制重新签发 TLS 证书并按需重载服务（受 Let's Encrypt 速率限制，日常由定时任务自动续期，无需手跑） |

> 注：执行 `add`、`reset`、`del` 时会快速重启 `sing-box`（约 1 秒），期间在线客户端会短暂重连。

### 3.2 常见问题排查

- **拉取订阅链接返回 `404` 或超时**
  运行 `./ssctl list` 确认 `ENABLE_SUBSCRIPTION=true`；再运行 `./ssctl show <name>` 核对是否使用了最新链接（执行过 `reset` 后旧链接会立即失效并返回 `404`）。
- **SFM 导入 `sing-box.json` 提示配置字段不支持**
  检查客户端版本是否低于 `1.14.0`（如部分旧版 App Store 客户端）。若是旧版本，在 `private/.env` 中设置 `SINGBOX_CLIENT_COMPAT=1.12` 后运行 `sudo ./ssctl flush` 即可切换为兼容语法。
- **客户端首次启动无法下载分流规则集**
  `sing-box.json` 与 `mihomo.yaml` 已内置“经由代理隧道下载规则集”的机制；`Shadowrocket` 已内置 90+ 条高频国内域名后缀作为本地直连兜底，也可在 `private/.env` 中将 `RULESET_SR_CN_DOMAIN` 替换为可用的镜像地址后执行 `sudo ./ssctl flush`。
- **客户端连接超时，无法访问海外网站**
  1. 在 VPS 上运行 `sudo ./ssctl status` 与 `sudo ./ssctl logs` 查看服务是否正常监听；
  2. 检查 Cloudflare 控制台，确认连接子域名的代理状态为 **DNS only（灰色云朵）** 而非橙色云；
  3. 确认 VPS 与客户端设备系统时间准确（服务端 REALITY 限制客户端时钟偏差不超过 `2 分钟`，`deploy` 已在服务端自动启用 NTP）。
- **如何在排障时查看连接日志，或在稳定期彻底消除客户端 IP 记录？**
  为保护隐私，服务端默认设置 `SERVER_LOG_LEVEL=warn`（不记录访问的目标域名），并由 `journald` 按 `64 MB` 容量上限与 `7 天` 保留期自动轮转过期。需要注意：在 `warn` 级别下，`sing-box` 仍会以 `ERROR` 级别记录扫描器无效握手以及客户端连接超时关闭（含客户端公网 IP）。若稳定运行期希望彻底避免客户端 IP 落盘，可在 `private/.env` 中设为 `SERVER_LOG_LEVEL=fatal` 并执行 `sudo ./ssctl deploy`；排障时可临时改为 `info` 观察后改回。不建议执行 `journalctl --vacuum-time=1s` 清空全系统审计日志。
- **Nginx 错误日志偶发 `SSL_do_handshake() failed (...bad key share), client: 127.0.0.1` 是故障吗？**
  不是故障。当互联网扫描器向 `443` 端口发送畸形 TLS 1.3 握手包时，`sing-box` REALITY 会按设计将其原样透明回落给本机 `127.0.0.1:8443` 的 Nginx，由 OpenSSL 拒绝握手并记下回环地址，表明抗探测回落工作正常。
- **VPS 上同时运行了 Docker 容器**
  Docker 使用 `-p 0.0.0.0:端口` 发布容器时会直接操作 `iptables` 绕过 UFW 防火墙。同机运行 Docker 时，请将容器端口绑定在回环地址（如 `-p 127.0.0.1:8080:80`）或自行配置 `DOCKER-USER` 防火墙链。
- **如何迁移到新 VPS？**
  在新 VPS 上克隆本仓库，将旧机器的 `private/.env` 复制过来，修改其中的 `SERVER_IP` 并在 Cloudflare 更新 DNS A 记录，然后执行 `sudo ./ssctl deploy` 即可完整恢复所有订阅配置。由于客户端节点直接连接 `SERVER_IP`，订阅 URL 地址本身保持不变，各设备只需手动刷新一次订阅（拉取新 IP）即可恢复连接，无需重新导入或更换链接。

---

## 四、架构设计与开发指南（面向开发者）

本节介绍项目的技术选型、安全机制与代码结构，便于其他开发者审阅设计或参与贡献。

### 4.1 整体拓扑与组件职责

```text
客户端 (SFM / Clash Verge Rev / FlClash / v2rayN / sing-box CLI / Shadowrocket)
   │  出站 server = 直接填 VPS IP（DNS 与路由中将 SERVER_DOMAIN 与 SERVER_IP/32 显式直连防回环）
   │  TLS SNI     = 自有子域名（Cloudflare DNS only）
   ├─ 主通道 (TCP 443): VLESS + uTLS (chrome) + REALITY + xtls-rprx-vision
   │     ▼
   │  nftables (ssctl_guard) ──► 单源 IP 并发与新建 SYN 速率限流，防慢速连接耗尽
   │     ▼
   │  sing-box VLESS inbound (:443)
   │     ├─ REALITY + UUID 双层认证通过 ────────► 固定 IPv4 国际出口（经出站安全路由过滤）
   │     ├─ REALITY 握手通过但 UUID 无效 ───────► VLESS 层直接拒绝并关闭连接（不回落）
   │     └─ 普通 TLS 访问 / 订阅拉取 / 主动探测 ─► 127.0.0.1:8443 本机 Nginx (Let's Encrypt 真实证书)
   │                                              ├─ /<SUB_PATH_PREFIX>/<256位Token>/<格式> → 静态订阅 (200)
   │                                              └─ 根路径或任意猜测路径 ─────────────────► 多态伪装站 / 一致 404
   │
   └─ 备用通道 (UDP 8443，可选跳跃端口与 salamander 混淆): Hysteria2 (QUIC)
         ▼
      sing-box Hysteria2 inbound (:8443，可选 nftables ssctl_hy2 端口跳跃重定向)
         ├─ 密钥化派生密码认证通过 ────────────► 固定 IPv4 国际出口
         └─ 非法探测 ──────────────────────────► file 模式直接回落至同一静态站点目录
```

| 服务端组件 | 职责说明 | 安全与运行约束 |
| :--- | :--- | :--- |
| **`sing-box`** | 承载 VLESS REALITY Vision 主入站与可选 Hysteria2 入站 | 以非特权用户 `sing-box` 运行，仅授予 `CAP_NET_BIND_SERVICE` 能力并启用严格 `systemd` 沙箱；版本由 `SINGBOX_VERSION` 锁定 |
| **`Nginx`** | 提供 REALITY 真实 TLS 握手目标、回落静态站点与公网订阅文件托管 | 仅绑定 `127.0.0.1:8443`，不向公网暴露端口；开启 TLS 1.2/1.3 与 HTTP/2，收敛慢连接超时、禁用内部符号链接穿越（`disable_symlinks`），关闭 `access_log` 与目录枚举（Nginx `>= 1.19.4` 自动拒绝未知 SNI 握手） |
| **`acme.sh`** | 通过 Cloudflare DNS-01 签发并自动续期 Let's Encrypt ECC 证书 | 固定官方 `v3.1.0` 版本并校验 SHA256；续期后仅重载 Nginx（仅在启用 Hysteria2 时同步重启 `sing-box`，避免纯 REALITY 无故断连） |
| **`UFW` / `nftables` / `NTP`** | 最小化端口暴露面、入口连接限流、实现 UDP 端口跳跃与时钟同步 | UFW 默认拒绝入站并自动保留当前 SSH 端口；`table inet ssctl_guard` 对 VLESS 入口实施单源 IP 并发与新建连接限速防慢速耗尽；Hysteria2 端口跳跃使用独立 `table inet ssctl_hy2` 维护，关闭或卸载时幂等清理 |

### 4.2 协议选型与双向分流设计

1. **为什么采用 `VLESS + REALITY + Vision (Self-steal)` 作为主协议？**
   - 传统 `VLESS + TLS` 存在明显的 TLS-in-TLS 握手特征；引入 `xtls-rprx-vision` 可在内层 TLS 1.3 握手完成后切换直通转发以消除该特征，并在支持的 Linux TCP 路径下启用 `splice` 零拷贝转发。
   - 然而 `sing-box` 的普通 VLESS 入站不支持 `fallback` 回落，面对主动探测时无法返回正常网页。结合 **REALITY** 并将目标指向本机回环 Nginx（持有自有域名真实证书的 HTTPS 静态站），既消除了 TLS-in-TLS 特征，又保证了主动探测者看到的是完整真实的 HTTPS 站点，且 **SNI 域名与服务器 IP 的 DNS 解析完全一致**（无借用第三方大厂域名的特征矛盾）。
2. **客户端防回环与 QUIC 降级机制**
   - **防回环**：客户端节点出站 `server` 直接填写服务器 IPv4 地址，同时在三端配置（`sing-box`、`mihomo`、`Shadowrocket`）的 DNS 与路由规则顶部将 `SERVER_DOMAIN` 与 `SERVER_IP/32` 显式设为 `DIRECT`。这保证了无论处于 TUN 全局接管还是 SNI 嗅探覆写下，拉取远程订阅或解析节点域名都绝不会产生死锁回环。
   - **QUIC 抑制**：客户端在本地直接 `REJECT` 目标为非中国大陆 `UDP 443` 的流量（包括 `Global` 模式），促使浏览器立即从 HTTP/3 回退至 HTTP/2 (TCP)，发挥 Vision 的最佳吞吐性能；而语音、连麦、游戏等非 443 端口的 UDP 流量则正常放行。
3. **服务端出站防滥用与防 SSRF / DNS Rebinding（项目安全策略）**
   - 服务端 `90-route.json` 按严格顺序执行出站过滤：先拦截 `localhost`/`ip6-localhost`/`.local` 域名、`TCP 25`（防止垃圾邮件滥用导致 VPS 被封禁，保留 `465`/`587` 正常加密发信）、SMB/NetBIOS 与常见 BT 追踪器端口（`135`、`137:139`、`445`、`6881:6889`、`6969`）以及 `bittorrent` 协议（防止海外机房版权投诉）；随后对目标域名执行 `action: resolve` 预解析，拦截 `ip_is_private: true` 以及项目安全策略显式拒绝的特殊网段（含 `100.64.0.0/10` CGNAT/云元数据、`169.254.0.0/16`、多播/保留段、IPv6 本地与 `::ffff:0:0/96` 映射段、NAT64 前缀）和 VPS 自身公网 IP，阻断通过伪造域名解析（DNS Rebinding）或字面量拨号探测服务端本机与内网资源的路径。

### 4.3 工程可靠性与供应链安全

- **本机原地执行与事务级快照回滚**：`ssctl` 直接运行于目标 VPS 本机，`private/.env`（强制 `0600` 权限）是全系统唯一状态源。配置文件由纯数据键值解析器与键名白名单加载更新（不作为 Shell 脚本执行），所有写操作均由 `flock` 文件锁（`private/.ssctl.lock`）串行保护，并在整份校验通过后备份 `.env.bak` 并 `mv` 原子替换。`add`、`reset`、`del` 在变更前自动创建 `.env` 与 `private/out/` 的物理快照，一旦渲染、校验或服务端同步失败，立即无损还原至变更前状态。
- **零中断订阅发布与一致 `404` 隔离**：客户端订阅每次生成在带时间戳与 PID 的独立版本目录（`/var/lib/ssctl/releases/sub-web.<ts>.<pid>`），校验通过后通过 `mv -Tf` 原子切换 `/var/lib/ssctl/sub-web` 符号链接，确保用户拉取订阅全程无 `404` 窗口。Nginx 隐藏了订阅文件的 `Last-Modified` 时间戳，禁止文档根目录内任何符号链接穿越，并通过 `try_files $uri =404;` 使所有未命中合法 `<SUB_PATH_PREFIX>/<256位Token>/<文件名>` 的猜测或目录请求均返回与根站完全一致的内置 `404` 响应头与字节长度。
- **密钥化多态回落站点与凭据隔离**：若用户未在 `private/www/` 放置自定义网页（严禁包含符号链接），部署脚本会混入实例独有的 `REALITY_PRIVATE_KEY` 与随机路径前缀生成多套异构 HTML 骨架、样式与行业文案的静态页面，消除公开扫描器按域名复算特征的可能；同样地，Hysteria2 节点密码混入服务端实例密钥派生，即使单个客户端 VLESS UUID 外泄也无法离线推导出备用协议密码。
- **供应链强校验与不可变规则源**：安装 `sing-box` 时对官方 APT GPG 公钥执行单主钥检查、固定指纹（`2C317FBD5D886B4E89BAE8DA6D9152172A2B2F0C`）隔离环境最小化重导出与单块单主钥二次核验；离线安装包、`acme.sh` 与 CI 校验用 `mihomo` 内核均强制比对仓库内固定的 SHA256 校验表，客户端默认远程规则集固定至已核验的 40 位 Git Commit SHA，杜绝上游分支漂移风险。

### 4.4 仓库目录结构与开发协作指引

```text
.
├── README.md                  # 使用指南与架构说明（本文档）
├── AGENTS.md                  # 面向 AI Agent 的架构契约与既定技术事实基线
├── PLAN.md                    # 面向 AI Agent 的阶段进度、待办事项与验收基线
├── ssctl                      # 统一 CLI 入口（扁平化一级子命令）
├── examples/                  # 公开配置模板（env.example / host-facts.example.md）
├── templates/
│   ├── server/                # 服务端模板（sing-box 配置片段、Nginx 站点、systemd 单元、多态回落页骨架）
│   └── client/                # 客户端模板（sing-box.json、mihomo.yaml、shadowrocket.conf）
├── scripts/
│   ├── lib/                   # 公共函数库 (common.sh) 与官方二进制固定 SHA256 表
│   ├── 00-preflight.sh        # 系统环境、配置完整性、软链隔离、DNS/DoH 与端口预检
│   ├── 10-harden.sh           # UFW 防火墙收敛、VLESS 连接限流、端口跳跃与 NTP 时钟同步
│   ├── 20-optimize.sh         # BBR、文件句柄、网络缓冲区与 journald 容量/7天限额调优
│   ├── 30-cert.sh             # acme.sh DNS-01 证书签发与按需重载钩子
│   ├── 40-deploy-server.sh    # 服务端安装、多态站点渲染校验与 systemd/CapEff 核验
│   ├── 50-gen-clients.sh      # 四端订阅配置生成与符号链接原子发布
│   └── hooks/                 # 原生 Git 防泄漏钩子（install-hooks.sh / check-private-leak.sh）
├── .github/workflows/ci.yml   # 自动化测试流水线
└── private/                   # 私有实例目录（被 Git 忽略，由 ./ssctl init 创建）
```

#### 开发者本地调试与提交规范
1. **启用防泄漏钩子**：首次克隆后运行 `./ssctl init`（或 `bash scripts/hooks/install-hooks.sh`），会自动挂载无需额外依赖的 `pre-commit` 与 `commit-msg` 钩子，防止将 `private/` 中的真实 IP、域名、密钥或本地 `file:///` 绝对路径提交入库。
2. **本地静态检查与离线渲染验证**：修改脚本或模板后，无需 root 权限即可在开发机运行以下全套检查：
   ```bash
   shellcheck -x ssctl scripts/*.sh scripts/lib/*.sh scripts/hooks/*.sh
   ./ssctl check
   bash scripts/hooks/check-private-leak.sh
   ```
3. **与 AI Agent 协作开发**：本项目采用“人类开发者 + AI Agent”持续协作模式。[`AGENTS.md`](AGENTS.md) 凝练记录了所有不可违背的架构契约与底层技术事实，[`PLAN.md`](PLAN.md) 记录了阶段验收基线与待办事项。参与开发或使用 AI 辅助编码时，请以这两份文档作为上下文约束，并在改动用户可见行为时同步更新本 `README.md`。

---

## License

[MIT](LICENSE)
