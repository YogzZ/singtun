# 架构设计与开发指南

本文档面向人类开发者与技术审阅者，介绍 `singtun` 的整体拓扑、协议选型、安全边界、供应链校验与本地开发调试规范。

- 返回快速开始：[`README.md`](../README.md)
- 查看日常运维与排查：[`docs/operations.md`](operations.md)

---

## 一、整体拓扑与组件职责

```text
客户端 (官方 sing-box SFW/SFM/SFA/CLI | 其他兼容订阅格式)
   │  出站 server = 直接填 VPS IP（DNS 与路由中将 SERVER_DOMAIN 与 SERVER_IP/32 显式直连防回环）
   │  TLS SNI     = 自有子域名（Cloudflare DNS only）
   ├─ 主通道 (TCP 443): VLESS + uTLS (chrome) + REALITY + xtls-rprx-vision
   │     ▼
   │  nftables (singtun_guard) ──► 单源 IP 并发与新建 SYN 速率限流，防慢速连接耗尽
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
      sing-box Hysteria2 inbound (:8443，可选 nftables singtun_hy2 端口跳跃重定向)
         ├─ 密钥化派生密码认证通过 ────────────► 固定 IPv4 国际出口
         └─ 非法探测 ──────────────────────────► file 模式直接回落至同一静态站点目录
```

| 服务端组件 | 职责说明 | 安全与运行约束 |
| :--- | :--- | :--- |
| **`sing-box`** | 承载 VLESS REALITY Vision 主入站与可选 Hysteria2 入站 | 以非特权用户 `sing-box` 运行，仅授予 `CAP_NET_BIND_SERVICE` 能力并启用严格 `systemd` 沙箱；版本由 `SINGBOX_VERSION` 锁定 |
| **`Nginx`** | 提供 REALITY 真实 TLS 握手目标、回落静态站点与公网订阅文件托管 | 仅绑定 `127.0.0.1:8443`，不向公网暴露端口；开启 TLS 1.2/1.3 与 HTTP/2，收敛慢连接超时、禁用内部符号链接穿越（`disable_symlinks`），关闭 `access_log` 与目录枚举（Nginx `>= 1.19.4` 自动拒绝未知 SNI 握手） |
| **`acme.sh`** | 通过 Cloudflare DNS-01 签发并自动续期 Let's Encrypt ECC 证书 | 固定官方 `v3.1.0` 版本并校验 SHA256；续期后仅重载 Nginx（仅在启用 Hysteria2 时同步重启 `sing-box`，避免纯 REALITY 无故断连） |
| **`UFW` / `nftables` / `NTP`** | 最小化端口暴露面、入口连接限流、实现 UDP 端口跳跃与时钟同步 | UFW 默认拒绝入站并自动保留当前 SSH 端口；`table inet singtun_guard` 对 VLESS 入口实施单源 IP 并发与新建连接限速防慢速耗尽；Hysteria2 端口跳跃使用独立 `table inet singtun_hy2` 维护，关闭或卸载时幂等清理 |

---

## 二、协议选型与双向分流设计

1. **为什么采用 `VLESS + REALITY + Vision (Self-steal)` 作为主协议？**
   - 传统 `VLESS + TLS` 存在明显的 TLS-in-TLS 握手特征；引入 `xtls-rprx-vision` 可在内层 TLS 1.3 握手完成后切换直通转发以消除该特征，并在支持的 Linux TCP 路径下启用 `splice` 零拷贝转发。
   - 然而 `sing-box` 的普通 VLESS 入站不支持 `fallback` 回落，面对主动探测时无法返回正常网页。结合 **REALITY** 并将目标指向本机回环 Nginx（持有自有域名真实证书的 HTTPS 静态站），既消除了 TLS-in-TLS 特征，又保证了主动探测者看到的是完整真实的 HTTPS 站点，且 **SNI 域名与服务器 IP 的 DNS 解析完全一致**（无借用第三方大厂域名的特征矛盾）。

2. **客户端防回环、NTP 直连与 QUIC 降级机制**
   - **防回环**：客户端节点出站 `server` 直接填写服务器 IPv4 地址，同时在客户端配置（`sing-box`、`mihomo`、`Shadowrocket`）的 OS TUN 路由排除表、DNS 与路由规则顶部将 `SERVER_DOMAIN` 与 `SERVER_IP/32`（开启 IPv6 时含 `/128`）显式设为 `DIRECT`。这保证了无论处于 TUN 全局接管还是 SNI 嗅探覆写下，拉取远程订阅、解析节点域名或保持直连 SSH 会话都绝不会产生死锁回环。
   - **NTP (`UDP 123`) 本地直连**：在 `IPv6` 阻断之后、`Global` 模式与海外规则之前统一将 `UDP 123` 设为本地 `DIRECT`。校时数据包不承载用户访问意图，直连可消除跨境代理带来的 RTT 偏差，也避免部分不支持 XUDP 的客户端将 `UDP 123` 送入 VLESS Vision 触发服务端 `flow mismatch` 拒绝。
   - **QUIC 抑制**：客户端在本地直接 `REJECT` 目标为非中国大陆 `UDP 443` 的流量（包括 `Global` 模式），促使浏览器立即从 HTTP/3 回退至 HTTP/2 (TCP)，发挥 Vision 的最佳吞吐性能；而语音、连麦、游戏等其余非 443 UDP 流量则随选中节点正常放行。

3. **服务端出站防滥用与防 SSRF / DNS Rebinding（项目安全策略）**
   - 服务端 `90-route.json` 按严格顺序执行出站过滤：先拦截 `localhost`/`ip6-localhost`/`.local` 域名、`TCP 25`（防止垃圾邮件滥用导致 VPS 被封禁，保留 `465`/`587` 正常加密发信）、SMB/NetBIOS 与常见 BT 追踪器端口（`135`、`137:139`、`445`、`6881:6889`、`6969`）以及 `bittorrent` 协议（防止海外机房版权投诉）；随后对目标域名执行 `action: resolve` 预解析，拦截 `ip_is_private: true` 以及项目安全策略显式拒绝的特殊网段（含 `100.64.0.0/10` CGNAT/云元数据、`169.254.0.0/16`、多播/保留段、IPv6 本地与 `::ffff:0:0/96` 映射段、NAT64 前缀）和 VPS 自身公网 IP，阻断通过伪造域名解析（DNS Rebinding）或字面量拨号探测服务端本机与内网资源的路径。

---

## 三、工程可靠性与供应链安全

- **本机原地执行与事务级快照回滚**：`singtun` 直接运行于目标 VPS 本机，`private/.env`（强制 `0600` 权限）是全系统唯一状态源。配置文件由纯数据键值解析器与键名白名单加载更新（不作为 Shell 脚本执行），所有写操作均由 `flock` 文件锁（`private/.singtun.lock`）串行保护，并在整份校验通过后备份 `.env.bak` 并 `mv` 原子替换。`add`、`reset`、`del` 在变更前自动创建 `.env` 与 `private/out/` 的物理快照，一旦渲染、校验或服务端同步失败，立即无损还原至变更前状态。
- **零中断订阅发布与一致 `404` 隔离**：客户端订阅每次生成在带时间戳与 PID 的独立版本目录（`/var/lib/singtun/releases/sub-web.<ts>.<pid>`），校验通过后通过 `mv -Tf` 原子切换 `/var/lib/singtun/sub-web` 符号链接，确保用户拉取订阅全程无 `404` 窗口。Nginx 隐藏了订阅文件的 `Last-Modified` 时间戳，禁止文档根目录内任何符号链接穿越，并通过 `try_files $uri =404;` 使所有未命中合法 `<SUB_PATH_PREFIX>/<256位Token>/<文件名>` 的猜测或目录请求均返回与根站完全一致的内置 `404` 响应头与字节长度。
- **密钥化多态回落站点与凭据隔离**：若用户未在 `private/www/` 放置自定义网页（严禁包含符号链接），部署脚本会混入实例独有的 `REALITY_PRIVATE_KEY` 与随机路径前缀生成多套异构 HTML 骨架、样式与行业文案的静态页面，消除公开扫描器按域名复算特征的可能；同样地，Hysteria2 节点密码混入服务端实例密钥派生，即使单个客户端 VLESS UUID 外泄也无法离线推导出备用协议密码。
- **供应链强校验与不可变规则源**：安装 `sing-box` 时对官方 APT GPG 公钥执行单主钥检查、固定指纹（`2C317FBD5D886B4E89BAE8DA6D9152172A2B2F0C`）隔离环境最小化重导出与单块单主钥二次核验；离线安装包、`acme.sh` 与 CI 校验用 `mihomo` 内核均强制比对仓库内固定的 SHA256 校验表，客户端默认远程规则集固定至已核验的 40 位 Git Commit SHA，杜绝上游分支漂移风险。

---

## 四、设计边界与长期维护原则

为了保证 `singtun` 在长期演进中始终保持清晰、可审阅且易于单人或小团队持续维护，项目确立了明确的架构壁垒与工程边界：

1. **核心定位与差异化壁垒**
   - **服务端与客户端同源闭环**：区别于只管安装服务端的轻量脚本，也不同于重面板方案，`singtun` 将服务端抗探测加固、防回环/防 SSRF 出站过滤与全平台客户端防泄漏规则视为同一整体同源渲染。
   - **单文件状态与零常驻开销**：全系统仅依赖 `private/.env` 单一状态源，通过无 `source` 执行风险的纯数据解析器、`flock` 锁、目录快照与公网订阅软链原子切换保证运维可靠性，无常驻 Web 面板、容器或数据库消耗低配 VPS 内存。
   - **真实回环测试驱动**：从 APT GPG 单主钥指纹校验、二进制 SHA256 到双进程 REALITY 回落与 DNS Rebinding 阻断，核心安全不变量均有离线单测与 GitHub CI 实测守护。

2. **明确不做的事（Non-Goals）**
   - **不做常驻 Web 管理面板或多租户计费系统**：不引入后台常驻管理进程、可视化图表数据库或复杂的流量配额系统。
   - **不集成改变出口 IP 的组件**：不接入 WARP、Psiphon、Cloudflare Argo/橙色云或任何多跳中转代理链，严格保证单一固定洁净出口 IP。
   - **不维护去广告、流媒体解锁或细分分流规则包**：这些规则变化极快且冲突率高，项目仅聚焦「国内直连 / 海外代理 / 私有与协议保护」的最小可用边界。
   - **不在生成脚本中无边界追逐长尾域名**：不把单个垂直 App 或第三方广告/统计/P2P SDK 域名硬编码进脚本来修补局部体验问题。

3. **规则演进与不可变依赖维护（Pin-and-Bump）**
   - **机制收敛优先于域名堆砌**：遇到跨协议或共性分流问题时，优先寻找协议、端口或地址段机制一次性解决（例如统一以 `UDP 123 -> DIRECT` 收敛全网 NTP 校时，统一拦截海外 `UDP 443` 抑制 QUIC）。
   - **内置后缀严格准入**：海外前置后缀仅保留上游 `@cn` 历史误判的 Google/Firebase 等核心基础设施；Shadowrocket 国内 `[Host]` 兜底列表仅准入系统/Apple 核心服务、国家级支付清算、头部公有云 CDN 与国民级定位底座，长尾非 `.cn` 国内域名交由不可变远程 `DOMAIN-SET` 路由。
   - **上游依赖定期锁定更新**：服务端 `sing-box`、CI 校验用 `mihomo`、`acme.sh` 与三端远程规则集均默认锁定固定版本、SHA256 或 40 位 Git Commit SHA。日常不随上游漂移，仅在定期维护窗口统一核验新版、更新锁定值并经 `./singtun check` 与完整 CI 验证后放行。

---

## 五、仓库目录结构与开发协作指引

```text
.
├── README.md                  # 精简快速开始与客户端入口
├── AGENTS.md                  # 面向 AI Agent 的架构契约与既定技术事实基线
├── PLAN.md                    # 面向 AI Agent 的阶段进度、待办事项与验收基线
├── docs/
│   ├── operations.md          # 日常运维、配置参考与故障排查
│   └── architecture.md        # 架构设计、安全机制与开发指南（本文档）
├── singtun                    # 唯一 CLI 入口（扁平化一级子命令，支持软链调用）
├── install.sh                 # curl 一键引导安装与更新脚本（安装至 /opt/singtun 并软链 singtun）
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
└── private/                   # 私有实例目录（被 Git 忽略，由 ./singtun init 创建）
```

### 开发者本地调试与提交规范

1. **启用防泄漏钩子**：首次克隆后运行 `./singtun init`（或 `bash scripts/hooks/install-hooks.sh`），会自动挂载无需额外依赖的 `pre-commit` 与 `commit-msg` 钩子，防止将 `private/` 中的真实 IP、域名、密钥或本地 `file:///` 绝对路径提交入库。
2. **本地静态检查与离线渲染验证**：修改脚本或模板后，无需 root 权限即可在开发机运行以下全套检查：
   ```bash
   shellcheck -x singtun install.sh scripts/*.sh scripts/lib/*.sh scripts/hooks/*.sh
   ./singtun check
   bash scripts/hooks/check-private-leak.sh
   ```
3. **与 AI Agent 协作开发**：本项目采用“人类开发者 + AI Agent”持续协作模式。[`AGENTS.md`](../AGENTS.md) 凝练记录了所有不可违背的架构契约与底层技术事实，[`PLAN.md`](../PLAN.md) 记录了阶段验收基线与待办事项。参与开发或使用 AI 辅助编码时，请以这两份文档作为上下文约束，并在改动用户可见行为时同步更新对应文档。
