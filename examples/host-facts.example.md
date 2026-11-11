# host-facts.md — 本实例专属事实（模板）

> 复制为 `private/host-facts.md` 后填写。示例值均为文档保留地址。

## 1. 服务器事实

| 属性类别 | 参数项 | 已验证事实 |
| :--- | :--- | :--- |
| **网络与定位** | 公网 IPv4 | `203.0.113.10` |
| | IPv6 状态 | 可用 / 不可用 |
| | ASN / 组织 | `ASxxxxx` / Example Inc |
| | 物理位置 | 城市 / 国家 |
| **IP 质量体检** | 欺诈与滥用评分 | Scamalytics / AbuseIPDB / 黑名单 |
| | 解锁状态 | Reddit / YouTube / ChatGPT / Netflix ... |
| **硬件与系统** | 虚拟化与配置 | KVM / N vCPU / N GiB RAM |
| | 操作系统 | Debian 12 / Ubuntu 22.04 / 24.04 LTS |
| | TCP 拥塞控制 | bbr / cubic |
| | 端口占用现状 | SSH / 443 / 8443 |
| **跨境链路** | 客户端 -> VPS | 平均延迟 / 丢包率 |

## 2. 域名与证书

- 主域名：`example.com`（DNS 托管：Cloudflare，DNS only）
- 连接子域名：`node.example.com`

## 3. 本实例部署进度

- [ ] 硬件与网络核查
- [ ] IP 质量体检
- [ ] 系统优化 / 加固
- [ ] 服务端部署
- [ ] 客户端联调
