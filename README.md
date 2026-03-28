# Claude Proxy Guard

Every time you run `claude`, this tool checks that your proxy is active and all Claude-related traffic exits from the expected country (default: Japan). If anything looks wrong, it blocks the launch.

```
[Proxy Guard] Surge 运行中 (PID: 879) ✓
[Proxy Guard] 本机信息:
  局域网 IP:   172.16.8.140
  国内出口 IP: 116.147.68.107 (中国 江苏 徐州 联通)
[Proxy Guard] 代理出口验证:
  api.anthropic.com         2a0e:aa00:...  JP/NRT ✓
  claude.ai                 126.36.212.186 JP/NRT ✓
  ...（10 domains）
[Proxy Guard] 出口 IP 地理信息:
  126.36.212.186           → 日本 东京都 Minato / SoftBank Corp.
[Proxy Guard] 提示: --guard-status 查看状态 | --guard-reset 重新配置
[Proxy Guard] Enter 继续 / n 重新检测 / q 退出:
```

## Install

```bash
git clone https://github.com/justwjx/claude-proxy-guard.git
cd claude-proxy-guard
./install.sh
```

Open a new terminal, run `claude` — first launch will guide you through setup.

## Uninstall

```bash
cd claude-proxy-guard
./uninstall.sh
```

## Proxy Rules Setup

The tool needs two optional DIRECT rules in your proxy config to display local network info. Without them, everything still works — you just won't see domestic IP.

### Surge

Add these to the `[Rule]` section of your **active profile** (before `FINAL`):

```ini
# Claude Proxy Guard - domestic IP detection
DOMAIN,myip.ipip.net,DIRECT

# (Optional) Fallback verification via ipinfo.io
# Route through same policy as Claude traffic:
# DOMAIN,ipinfo.io,Anthropic
```

### Clash Verge

Add to `rules` in your **active config** (before catch-all):

```yaml
# Claude Proxy Guard - domestic IP detection
- DOMAIN,myip.ipip.net,DIRECT

# (Optional) Fallback verification via ipinfo.io
# Route through same policy as Claude traffic:
# - DOMAIN,ipinfo.io,Anthropic
```

### Quick Copy

| Rule | Purpose | Required? |
|------|---------|-----------|
| `DOMAIN,myip.ipip.net,DIRECT` | Show domestic exit IP | Recommended |
| `DOMAIN,ipinfo.io,<Claude策略组>` | Fallback when Cloudflare trace unavailable | Optional |

## How It Works

1. **Process check** — Surge or Clash Verge running?
2. **Per-domain verification** — For each of 10 Claude-related domains, requests `https://{domain}/cdn-cgi/trace` (Cloudflare built-in endpoint). The request naturally follows your proxy's rule-based routing, so the returned `ip` and `loc` fields reflect the actual exit point for that domain.
3. **Geo lookup** — Batch queries `ip-api.com` for city/ISP details on unique exit IPs.
4. **Human confirmation** — Shows everything, waits for Enter.

### Verified Domains

| Domain | Purpose |
|--------|---------|
| `api.anthropic.com` | API calls |
| `anthropic.com` | Website |
| `claude.ai` | Claude Web |
| `claude.com` | Claude Docs |
| `platform.claude.com` | OAuth |
| `mcp-proxy.anthropic.com` | MCP proxy |
| `clau.de` | Short links |
| `www.claudeusercontent.com` | User content |
| `statsigapi.net` | Feature flags (via `x-statsig-region` header) |
| `downloads.claude.ai` | Plugin downloads (covered by `claude.ai` rule) |

### Fallback Chain

If Cloudflare `/cdn-cgi/trace` is unavailable for a domain:

1. **L1**: `/cdn-cgi/trace` → exact exit IP + country
2. **L2**: `cf-ray` response header → datacenter IATA code (approximate)
3. **L3**: `ipinfo.io` → single-point check (requires DIRECT rule, see above)

## Commands

| Command | Action |
|---------|--------|
| `claude` | Normal launch with proxy verification + confirmation |
| `claude --guard-status` | Show full status without launching |
| `claude --guard-reset` | Re-run first-time setup |

All other arguments pass through to the real `claude` binary.

## Cache

Verification results are cached for 5 minutes to avoid re-checking 10 domains on every launch. The cache auto-invalidates when:

- 5 minutes elapsed
- Proxy process PID changes (restart or switch)

Even with cache, you **always see the results and must press Enter** — the cache only skips the network requests, not the human confirmation.

## Requirements

- macOS
- zsh (default shell on macOS)
- [Surge](https://nssurge.com/) or [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev)
- `curl`, `pgrep` (macOS built-in)
