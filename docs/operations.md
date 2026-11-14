# 日常运维与故障排查

本文档包含 `singtun` 的常用命令、`private/.env` 核心配置说明、常见问题排查与服务端迁移指引。

- 返回快速开始：[`README.md`](../README.md)
- 查看架构设计与开发指南：[`docs/architecture.md`](architecture.md)

---

## 一、`singtun` 命令速查

所有日常操作均通过 `./singtun <子命令>`（或已注册的全局命令 `singtun`）完成，任意子命令均可加 `--help` 或执行 `./singtun help <子命令>` 查看详细说明与影响范围：

| 分类 | 命令 | 功能说明 |
| :--- | :--- | :--- |
| **部署与生命周期** | `sudo ./singtun setup [--config-only]` | 交互式引导配置（自动探测公网 IP、校验 DNS、三档方案选择），写入后一键部署并引导创建首条订阅 |
| | `./singtun init` | 初始化 `private/` 目录，自动补全密钥、随机前缀与全量默认项，并安装本地 Git 防泄漏钩子 |
| | `./singtun check` | 离线渲染并校验服务端与 4 种客户端配置，不修改系统状态 |
| | `sudo ./singtun deploy` | 一键部署或更新服务端（含防火墙、连接限流、BBR、证书与回落站），并同步公网订阅目录 |
| | `sudo ./singtun upgrade <version>` | 先暂存候选版本完成配置预检，通过后升级二进制与配置；失败自动回滚版本与配置 |
| | `sudo ./singtun uninstall [--purge-cert]` | 卸载服务、配置、Nginx 站点及防火墙/`nftables` 规则（保留 `private/`；加 `--purge-cert` 一并删除证书） |
| **订阅与客户端管理** | `sudo ./singtun add [name] [--qr <type>]` | 新增一条订阅（省略名称自动编号 `sub-1`…），同步服务端并输出 4 种订阅链接 |
| | `./singtun list` | 查看当前已创建的订阅列表及公网订阅托管开关状态 |
| | `./singtun show <name> [--qr <type>]` | 查看指定订阅的 4 条专属链接、一键导入深链或渲染终端二维码 |
| | `sudo ./singtun reset <name> [--qr <type>]` | 重置指定订阅的 UUID、Hysteria2 密码与订阅 Token（旧节点与旧链接立即同时作废） |
| | `sudo ./singtun del <name>` | 吊销并删除指定订阅，立即断开该凭据连接并清理本地与公网产物 |
| | `sudo ./singtun flush [name] [--local-only]` | 重新生成全部或指定订阅的客户端配置并原子同步至公网订阅目录（加 `--local-only` 仅更新本地副本） |
| **状态、日志与证书** | `sudo ./singtun status` | 查看 `sing-box`、`nginx` 及防护/跳跃单元运行状态与 TLS 证书剩余天数（低于 20 天自动告警） |
| | `sudo ./singtun logs` | 实时跟踪 `sing-box` 与 `nginx` 的 systemd 日志（Nginx 错误日志位于 `/var/log/nginx/error.log`） |
| | `sudo ./singtun restart` | 重启 `nginx`、`sing-box` 及已启用的防护/端口跳跃单元并核验活跃状态 |
| | `sudo ./singtun renew` | 强制重新签发 TLS 证书并按需重载服务（受 Let's Encrypt 速率限制，日常由定时任务自动续期，无需手跑） |

> 注：执行 `add`、`reset`、`del` 时会快速重启 `sing-box`（约 1 秒），期间在线客户端会短暂重连。

---

## 二、核心配置项参考（`private/.env`）

完整参数模板与注释见 [`examples/env.example`](../examples/env.example)，常用配置项如下（修改后按需执行 `sudo ./singtun deploy` 或 `sudo ./singtun flush` 生效）：

| 类别 | 变量名 | 说明 |
| :--- | :--- | :--- |
| **基础与证书** | `SERVER_IP` / `SERVER_DOMAIN` | VPS 公网 IPv4 / 连接与订阅使用的子域名（Cloudflare 必须保持 DNS only） |
| | `ACME_EMAIL` / `CF_API_TOKEN` | 证书通知邮箱 / Cloudflare `Zone.DNS:Edit` API 令牌（可选配 `ACME_NOTIFY_HOOK`） |
| **版本与兼容** | `SINGBOX_VERSION` | 服务端锁定安装的官方 `sing-box` 版本号 |
| | `SINGBOX_CLIENT_COMPAT` | 客户端 `sing-box.json` 语法版本：默认 `1.14`；若移动端客户端版本低于 1.14 可设为 `1.12` |
| **订阅托管** | `ENABLE_SUBSCRIPTION` | 是否启用公网 HTTPS 订阅托管（默认 `true`；设为 `false` 则仅在本地 `private/out/` 生成配置文件） |
| | `SUB_PATH_PREFIX` / `SUBSCRIPTIONS` | `init` 自动生成的随机路径前缀 / `add`、`del` 自动维护的订阅列表（无需手改） |
| **备用协议** | `ENABLE_HY2` / `HY2_PORT` | 是否启用 Hysteria2 备用协议（默认 `false`）/ UDP 监听端口（默认 `8443`） |
| | `HY2_HOP_PORTS` / `HY2_OBFS` | 可选 UDP 端口跳跃范围（如 `20000-30000`）/ 是否开启 `salamander` 数据包混淆（默认 `false`）；修改后需重新执行 `sudo ./singtun deploy` |
| **网络与日志** | `SERVER_IPV6` / `SERVER_LOG_LEVEL` | 服务端是否启用 IPv6（默认 `false`，强制 `ipv4_only` 防泄漏）/ 服务端日志级别（默认 `warn`） |
| | `DNS_DIRECT` / `DNS_REMOTE` | 国内域名直连加密 DoH（默认 `223.5.5.5`）/ 海外域名加密 DoH（默认 `1.1.1.1`） |
| | `RULESET_*` | 三端远程分流规则集地址（默认固定至已验证的上游 40 位不可变 Git Commit SHA） |

---

## 三、常见问题排查

- **拉取订阅链接返回 `404` 或超时**
  运行 `./singtun list` 确认 `ENABLE_SUBSCRIPTION=true`；再运行 `./singtun show <name>` 核对是否使用了最新链接（执行过 `reset` 后旧链接会立即失效并返回 `404`）。

- **客户端导入 `sing-box.json` 提示配置字段不支持**
  检查客户端版本是否低于 `1.14.0`（如部分旧版 App Store 客户端）。若是旧版本，在 `private/.env` 中设置 `SINGBOX_CLIENT_COMPAT=1.12` 后运行 `sudo ./singtun flush` 即可切换为兼容语法。

- **客户端首次启动无法下载分流规则集**
  `sing-box.json`（及 `mihomo.yaml`）已内置“经由代理隧道下载规则集”的机制；若网络环境特殊，可在 `private/.env` 中替换对应 `RULESET_*` 镜像地址后执行 `sudo ./singtun flush`。

- **iOS / macOS Safari 启用代理后网页卡死或 Google 登录/静态资源加载超时**
  新版客户端配置已前置抑制 iCloud 专用代理（Private Relay）探针域名（不影响 iCloud 云盘/相册等正常功能），并将 Google / `.google` / `gstatic` / `googleapis` / Firebase 等易受上游历史直连规则影响的后缀前置走代理与远端加密 DoH。若在更新前曾导入过旧配置，请在客户端内手动刷新订阅/远程配置并重连代理。

- **客户端连接超时，无法访问海外网站**
  1. 在 VPS 上运行 `sudo ./singtun status` 与 `sudo ./singtun logs` 查看服务是否正常监听；
  2. 检查 Cloudflare 控制台，确认连接子域名的代理状态为 **DNS only（灰色云朵）** 而非橙色云；
  3. 确认 VPS 与客户端设备系统时间准确（服务端 REALITY 限制客户端时钟偏差不超过 `2 分钟`，`deploy` 已在服务端自动启用 NTP）。

- **如何在排障时查看连接日志，或在稳定期彻底消除客户端 IP 记录？**
  为保护隐私，服务端默认设置 `SERVER_LOG_LEVEL=warn`（不记录访问的目标域名），并由 `journald` 按 `64 MB` 容量上限与 `7 天` 保留期自动轮转过期。需要注意：在 `warn` 级别下，`sing-box` 仍会以 `ERROR` 级别记录扫描器无效握手以及客户端连接超时关闭（含客户端公网 IP）。若稳定运行期希望彻底避免客户端 IP 落盘，可在 `private/.env` 中设为 `SERVER_LOG_LEVEL=fatal` 并执行 `sudo ./singtun deploy`；排障时可临时改为 `info` 观察后改回。不建议执行 `journalctl --vacuum-time=1s` 清空全系统审计日志。

- **Nginx 错误日志偶发 `SSL_do_handshake() failed (...bad key share), client: 127.0.0.1` 是故障吗？**
  不是故障。当互联网扫描器向 `443` 端口发送畸形 TLS 1.3 握手包时，`sing-box` REALITY 会按设计将其原样透明回落给本机 `127.0.0.1:8443` 的 Nginx，由 OpenSSL 拒绝握手并记下回环地址，表明抗探测回落工作正常。

- **VPS 上同时运行了 Docker 容器**
  Docker 使用 `-p 0.0.0.0:端口` 发布容器时会直接操作 `iptables` 绕过 UFW 防火墙。同机运行 Docker 时，请将容器端口绑定在回环地址（如 `-p 127.0.0.1:8080:80`）或自行配置 `DOCKER-USER` 防火墙链。

- **如何迁移到新 VPS？**
  在新 VPS 上克隆本仓库，将旧机器的 `private/.env` 复制过来，修改其中的 `SERVER_IP` 并在 Cloudflare 更新 DNS A 记录，然后执行 `sudo ./singtun deploy` 即可完整恢复所有订阅配置。由于客户端节点直接连接 `SERVER_IP`，订阅 URL 地址本身保持不变，各设备只需手动刷新一次订阅（拉取新 IP）即可恢复连接，无需重新导入或更换链接。
