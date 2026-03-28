# Claude Proxy Guard

[中文](#中文) | [English](#english)

---

<a id="中文"></a>

## 中文

每次运行 `claude` 前，自动检查代理是否就绪、所有 Claude 相关流量是否从期望国家（默认日本）出口。异常则阻断启动。

```
[Proxy Guard] Surge 运行中 (PID: 12345) ✓
[Proxy Guard] 本机信息:
  局域网 IP:   192.168.1.100
  国内出口 IP: 203.x.x.x (中国 某省 某市 运营商)
[Proxy Guard] 代理出口验证:
  api.anthropic.com         xx.xx.xx.xx    JP/NRT ✓
  claude.ai                 xx.xx.xx.xx    JP/NRT ✓
  ...（10 个域名）
[Proxy Guard] 出口 IP 地理信息:
  xx.xx.xx.xx              → 日本 东京都 / ISP名称
[Proxy Guard] 提示: --guard-status 查看状态 | --guard-reset 重新配置
[Proxy Guard] Enter 继续 / n 重新检测 / q 退出:
```

### 安装

```bash
git clone https://github.com/justwjx/claude-proxy-guard.git
cd claude-proxy-guard
./install.sh
```

打开新终端，运行 `claude`，首次启动会引导你完成配置。

### 卸载

```bash
cd claude-proxy-guard
./uninstall.sh
```

### 代理规则配置

需要在代理中配置 Claude 相关域名的路由规则，以及一条 DIRECT 规则来显示国内出口 IP。

#### 1. Claude 域名代理规则（必须）

确保所有 Claude 相关域名走代理。将 `<策略组>` 替换为你的代理策略组名（如 `Proxy`、`Anthropic`、`日本` 等）。

**Surge** — 在 `[Rule]` 段添加：

```ini
# Anthropic / Claude
DOMAIN-SUFFIX,anthropic.com,<策略组>
DOMAIN-SUFFIX,claude.ai,<策略组>
DOMAIN-SUFFIX,claude.com,<策略组>
DOMAIN-SUFFIX,claudeusercontent.com,<策略组>
DOMAIN-SUFFIX,clau.de,<策略组>
```

**Clash Verge** — 在 `rules` 中添加：

```yaml
# Anthropic / Claude
- DOMAIN-SUFFIX,anthropic.com,<策略组>
- DOMAIN-SUFFIX,claude.ai,<策略组>
- DOMAIN-SUFFIX,claude.com,<策略组>
- DOMAIN-SUFFIX,claudeusercontent.com,<策略组>
- DOMAIN-SUFFIX,clau.de,<策略组>
```

> 5 条 `DOMAIN-SUFFIX` 规则覆盖全部 10 个检测域名（含子域名如 `api.anthropic.com`、`platform.claude.com` 等）。

#### 2. 辅助规则（推荐/可选）

**Surge：**

```ini
# Claude Proxy Guard - 国内 IP 检测
DOMAIN,myip.ipip.net,DIRECT

# [可选] 降级验证 - 将 ip-api.com 路由到与 Claude 相同的策略组：
# DOMAIN,ip-api.com,<策略组>
```

**Clash Verge：**

```yaml
# Claude Proxy Guard - 国内 IP 检测
- DOMAIN,myip.ipip.net,DIRECT

# [可选] 降级验证 - 将 ip-api.com 路由到与 Claude 相同的策略组：
# - DOMAIN,ip-api.com,<策略组>
```

#### 快速参考

| 规则 | 用途 | 是否必须 |
|------|------|----------|
| `DOMAIN-SUFFIX,anthropic.com,<策略组>` | API、MCP、官网等 | 必须 |
| `DOMAIN-SUFFIX,claude.ai,<策略组>` | Claude Web、插件下载 | 必须 |
| `DOMAIN-SUFFIX,claude.com,<策略组>` | 文档、OAuth | 必须 |
| `DOMAIN-SUFFIX,claudeusercontent.com,<策略组>` | 用户内容 | 必须 |
| `DOMAIN-SUFFIX,clau.de,<策略组>` | 短链接 | 必须 |
| `DOMAIN,myip.ipip.net,DIRECT` | 显示国内出口 IP | 推荐 |
| `DOMAIN,ip-api.com,<策略组>` | 降级验证 | 可选 |

### 工作原理

1. **进程检查** — Surge 或 Clash Verge 是否在运行
2. **逐域名验证** — 对 10 个 Claude 相关域名请求 `https://{domain}/cdn-cgi/trace`（Cloudflare 内置端点）。请求自然遵循代理的规则路由，返回的 `ip` 和 `loc` 字段就是该域名真实的出口信息
3. **地理查询** — 批量查询 `ip-api.com` 获取出口 IP 的城市和 ISP
4. **人工确认** — 展示所有信息，等待用户按 Enter 确认

### 检测域名

| 域名 | 用途 | 检测方式 |
|------|------|----------|
| `api.anthropic.com` | API 调用 | cdn-cgi/trace |
| `anthropic.com` | 官网 | cdn-cgi/trace |
| `claude.ai` | Claude Web | cdn-cgi/trace |
| `claude.com` | Claude 文档 | cdn-cgi/trace |
| `platform.claude.com` | OAuth 认证 | cdn-cgi/trace |
| `mcp-proxy.anthropic.com` | MCP 代理 | cdn-cgi/trace |
| `clau.de` | 短链接 | cdn-cgi/trace |
| `www.claudeusercontent.com` | 用户内容 | cdn-cgi/trace |
| `statsigapi.net` | 功能开关 | x-statsig-region 响应头 |
| `downloads.claude.ai` | 插件下载 | 由 claude.ai 规则覆盖 |

### 降级策略

当 `/cdn-cgi/trace` 不可用时：

| 层级 | 方式 | 精度 |
|------|------|------|
| L1 | `/cdn-cgi/trace` | 精确（出口 IP + 国家） |
| L2 | `cf-ray` 响应头 | 近似（机房 IATA 码） |
| L3 | `ip-api.com` | 单点检测（需添加代理规则） |

### 命令

| 命令 | 作用 |
|------|------|
| `claude` | 正常启动，带代理验证 + 确认 |
| `claude --guard-status` | 仅查看状态，不启动 |
| `claude --guard-reset` | 重新配置 |

其他参数原样传递给真实 `claude` 二进制。

### 缓存

验证结果缓存 5 分钟。以下情况自动失效：

- 超过 5 分钟
- 代理进程 PID 变化（重启或切换）

即使命中缓存，**仍会显示结果并要求 Enter 确认** — 缓存只跳过网络请求，不跳过人工把关。

### 系统要求

- macOS
- zsh（macOS 默认 shell）
- [Surge](https://nssurge.com/) 或 [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev)

---

<a id="english"></a>

## English

Checks that your proxy is active and all Claude-related traffic exits from the expected country (default: Japan) before every `claude` launch. Blocks startup if anything looks wrong.

```
[Proxy Guard] Surge running (PID: 12345) ✓
[Proxy Guard] Local info:
  LAN IP:      192.168.1.100
  Domestic IP: 203.x.x.x (China, Province, City, ISP)
[Proxy Guard] Proxy exit verification:
  api.anthropic.com         xx.xx.xx.xx    JP/NRT ✓
  claude.ai                 xx.xx.xx.xx    JP/NRT ✓
  ... (10 domains)
[Proxy Guard] Exit IP geo info:
  xx.xx.xx.xx              → Japan, Tokyo / ISP Name
[Proxy Guard] Hint: --guard-status check status | --guard-reset reconfigure
[Proxy Guard] Enter to continue / n to re-check / q to quit:
```

### Install

```bash
git clone https://github.com/justwjx/claude-proxy-guard.git
cd claude-proxy-guard
./install.sh
```

Open a new terminal, run `claude` — first launch guides you through setup.

### Uninstall

```bash
cd claude-proxy-guard
./uninstall.sh
```

### Proxy Rules

You need proxy rules for Claude domains and one DIRECT rule for domestic IP display.

#### 1. Claude Domain Rules (Required)

Make sure all Claude-related domains go through your proxy. Replace `<policy>` with your proxy policy group name (e.g. `Proxy`, `Anthropic`, `Japan`).

**Surge** — Add to `[Rule]` section:

```ini
# Anthropic / Claude
DOMAIN-SUFFIX,anthropic.com,<policy>
DOMAIN-SUFFIX,claude.ai,<policy>
DOMAIN-SUFFIX,claude.com,<policy>
DOMAIN-SUFFIX,claudeusercontent.com,<policy>
DOMAIN-SUFFIX,clau.de,<policy>
```

**Clash Verge** — Add to `rules`:

```yaml
# Anthropic / Claude
- DOMAIN-SUFFIX,anthropic.com,<policy>
- DOMAIN-SUFFIX,claude.ai,<policy>
- DOMAIN-SUFFIX,claude.com,<policy>
- DOMAIN-SUFFIX,claudeusercontent.com,<policy>
- DOMAIN-SUFFIX,clau.de,<policy>
```

> 5 `DOMAIN-SUFFIX` rules cover all 10 verified domains (including subdomains like `api.anthropic.com`, `platform.claude.com`, etc).

#### 2. Helper Rules (Recommended/Optional)

**Surge:**

```ini
DOMAIN,myip.ipip.net,DIRECT
# (Optional) DOMAIN,ip-api.com,<policy>
```

**Clash Verge:**

```yaml
- DOMAIN,myip.ipip.net,DIRECT
# (Optional) - DOMAIN,ip-api.com,<policy>
```

#### Quick Reference

| Rule | Purpose | Required? |
|------|---------|-----------|
| `DOMAIN-SUFFIX,anthropic.com,<policy>` | API, MCP, website | Required |
| `DOMAIN-SUFFIX,claude.ai,<policy>` | Claude Web, plugin downloads | Required |
| `DOMAIN-SUFFIX,claude.com,<policy>` | Docs, OAuth | Required |
| `DOMAIN-SUFFIX,claudeusercontent.com,<policy>` | User content | Required |
| `DOMAIN-SUFFIX,clau.de,<policy>` | Short links | Required |
| `DOMAIN,myip.ipip.net,DIRECT` | Show domestic exit IP | Recommended |
| `DOMAIN,ip-api.com,<policy>` | Fallback verification | Optional |

### How It Works

1. **Process check** — Is Surge or Clash Verge running?
2. **Per-domain verification** — Requests `https://{domain}/cdn-cgi/trace` for each of 10 Claude domains. The request follows your proxy's rule-based routing, so the returned `ip` and `loc` fields reflect that domain's actual exit point.
3. **Geo lookup** — Batch queries `ip-api.com` for city/ISP on unique exit IPs.
4. **Human confirmation** — Displays everything, waits for Enter.

### Verified Domains

| Domain | Purpose | Method |
|--------|---------|--------|
| `api.anthropic.com` | API calls | cdn-cgi/trace |
| `anthropic.com` | Website | cdn-cgi/trace |
| `claude.ai` | Claude Web | cdn-cgi/trace |
| `claude.com` | Docs | cdn-cgi/trace |
| `platform.claude.com` | OAuth | cdn-cgi/trace |
| `mcp-proxy.anthropic.com` | MCP proxy | cdn-cgi/trace |
| `clau.de` | Short links | cdn-cgi/trace |
| `www.claudeusercontent.com` | User content | cdn-cgi/trace |
| `statsigapi.net` | Feature flags | x-statsig-region header |
| `downloads.claude.ai` | Plugin downloads | Covered by claude.ai rule |

### Fallback Chain

| Level | Method | Precision |
|-------|--------|-----------|
| L1 | `/cdn-cgi/trace` | Exact (exit IP + country) |
| L2 | `cf-ray` header | Approximate (datacenter IATA code) |
| L3 | `ip-api.com` | Single-point (requires proxy rule) |

### Commands

| Command | Action |
|---------|--------|
| `claude` | Launch with proxy verification + confirmation |
| `claude --guard-status` | Show status only |
| `claude --guard-reset` | Reconfigure |

All other arguments pass through to the real `claude` binary.

### Cache

Results cached for 5 minutes. Auto-invalidates when time expires or proxy PID changes. Even with cache, **results are always displayed and Enter is required** — cache skips network requests, not human confirmation.

### Requirements

- macOS
- zsh (default on macOS)
- [Surge](https://nssurge.com/) or [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev)
