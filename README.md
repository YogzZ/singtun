# singtun

基于 `sing-box` 的个人跨境代理一键部署与订阅管理工具，旨在通过单一配置文件（`private/.env`）在海外 VPS 上快速构建安全、抗探测、防泄漏的固定出口代理服务，并为全平台客户端提供开箱即用的订阅配置。

### 核心特性

- **单一固定出口**：默认采用 `VLESS + REALITY + Vision`（自有域名真实证书回落），支持可选 `Hysteria2` 备用通道；多设备共用同一台 VPS 的固定公网 IPv4 作为唯一出口。
- **开箱即用防泄漏**：客户端订阅内置国内外加密 DoH、严格虚拟网卡路由、IPv6 旁路阻断、`UDP 123` (NTP) 直连与海外 `UDP 443` (QUIC) 自动降级。
- **按设备独立订阅**：通过 `singtun add` 为每台设备分配独立凭据与 256 位随机订阅链接，支持 `singtun reset <name>` 一键轮换作废。
- **轻量、幂等、可回滚**：基于原生 Bash 与 `systemd`，1C/512MB 低配 VPS 即可稳定运行；所有变更先校验后原子切换，失败自动回滚。

---

## 一、快速开始（服务端部署）

### 前置准备

1. **一台海外 VPS**：Debian 12 / Ubuntu 22.04 / Ubuntu 24.04（`amd64` 或 `arm64`），具备固定公网 IPv4 与 `root` / `sudo` 权限。
2. **Cloudflare 托管域名**：添加一条 A 记录将子域名（如 `node.example.com`）指向 VPS IPv4，代理状态必须保持 **DNS only（灰色云朵）**。
3. **Cloudflare API Token**：具备对应域名 `Zone → DNS → Edit` 权限，用于自动签发和续期 TLS 证书（无需开放 80 端口）。

### 一键部署与创建订阅

**方式一：一条命令引导安装（推荐）**

登录海外 VPS 后执行以下命令，脚本将自动安装至 `/opt/singtun`、注册 `singtun` 命令并启动交互式配置与部署向导：

```bash
curl -fsSL https://raw.githubusercontent.com/YogzZ/singtun/main/install.sh | sudo bash
```

> 仅更新仓库代码（保留 `private/` 私有配置与证书）：
> ```bash
> curl -fsSL https://raw.githubusercontent.com/YogzZ/singtun/main/install.sh | sudo bash -s -- --update
> ```

**方式二：手动克隆部署**

```bash
git clone https://github.com/YogzZ/singtun.git /opt/singtun && cd /opt/singtun
sudo ./singtun setup
```

需要终端扫码导入时，可使用 `--qr singbox` 渲染二维码：

```bash
./singtun show <订阅名> --qr singbox
```

> [!WARNING]
> **公网订阅凭据安全提醒**
> 默认启用公网订阅托管（`ENABLE_SUBSCRIPTION=true`），订阅链接与二维码本身即包含完整代理凭据，请勿公开分享或转发。若怀疑泄露，立即执行 `sudo ./singtun reset <name>` 作废旧凭据与旧链接。

---

## 二、客户端安装与配置

全平台统一推荐安装官方 **`sing-box`** 客户端，并导入服务端生成的 **`[2] sing-box.json`** 远程配置链接（或通过 `sing-box://` 深链 / `--qr singbox` 二维码一键导入）：

| 平台 | 推荐客户端 | 官方下载与文档 |
| :--- | :--- | :--- |
| **Windows / Linux (桌面)** | **sing-box for Desktop (`SFW`)** | [官方桌面端文档](https://sing-box.sagernet.org/clients/desktop/) |
| **macOS / iOS** | **sing-box for Apple (`SFM`)** | [官方 Apple 端文档](https://sing-box.sagernet.org/clients/apple/) / [GitHub Releases](https://github.com/SagerNet/sing-box/releases) |
| **Android** | **sing-box for Android (`SFA`)** | [官方 Android 端文档](https://sing-box.sagernet.org/clients/android/) |
| **Linux (CLI / 无头)** | **原生 `sing-box` CLI** | [官方包管理器安装指南](https://sing-box.sagernet.org/installation/package-manager/) |

### 连通性与防泄漏验证

连接后可在终端或浏览器快速验证分流与 DNS 是否正常：

```bash
curl -4 -s https://myip.ipip.net   # 国内站点：应显示本地运营商 IP
curl -4 -s https://api.ip.sb/ip    # 国际站点：应显示 VPS 公网 IPv4
```

- DNS 泄漏检测：访问 `https://browserleaks.com/dns`，列表中应仅出现海外解析节点，不应出现国内运营商 DNS。
- WebRTC 泄漏检测：访问 `https://browserleaks.com/webrtc`，页面不应暴露本地真实公网 IP。

---

## 三、延伸文档

- **日常运维与问题排查**：[`docs/operations.md`](docs/operations.md) — `singtun` 全命令速查、`private/.env` 配置项参考、常见问题排查与 VPS 迁移指南。
- **架构设计与开发指南**：[`docs/architecture.md`](docs/architecture.md) — 系统拓扑图、协议选型、防泄漏与供应链安全机制、设计边界及本地开发提交规范。

---

## License

[MIT](LICENSE)
