#!/usr/bin/env zsh
# Claude Proxy Guard v1.0
# Verifies proxy is active and Claude traffic exits from expected country

# ============================================================================
# Config Loading + First-Run Setup (Task 2)
# ============================================================================

_cpg_load_config() {
  local config_file="$HOME/.claude-proxy-guard.conf"

  if [[ ! -f "$config_file" ]]; then
    _cpg_first_run_setup
    [[ ! -f "$config_file" ]] && return 1
  fi

  source "$config_file"

  if [[ ! "$EXPECTED_COUNTRY" =~ ^[A-Z]{2}$ ]]; then
    echo "[Proxy Guard] 错误：EXPECTED_COUNTRY=\"$EXPECTED_COUNTRY\" 格式非法（需要 2 位大写字母，如 JP）"
    return 1
  fi

  return 0
}

_cpg_first_run_setup() {
  local config_file="$HOME/.claude-proxy-guard.conf"

  echo "[Claude Proxy Guard] 首次配置"
  echo ""

  echo "请选择常用代理工具："
  echo "  1) Surge"
  echo "  2) Clash Verge"
  echo "  3) 两个都检测（任一在跑即可）"
  echo ""
  local choice
  read "choice?选择 [1/2/3]: "
  local proxy_tool
  case "$choice" in
    1) proxy_tool="surge" ;;
    2) proxy_tool="clash" ;;
    3) proxy_tool="both" ;;
    *) echo "无效选择"; return 1 ;;
  esac

  local country
  read "country?期望出口国家（默认 JP，直接回车使用默认值）: "
  country="${country:-JP}"
  country="${(U)country}"

  if [[ ! "$country" =~ ^[A-Z]{2}$ ]]; then
    echo "国家代码格式错误（需要 2 位字母）"
    return 1
  fi

  echo ""
  echo "[可选] 是否启用 fallback 验证？"
  echo "  需要在代理规则中添加一条："
  echo "    Surge:  DOMAIN,ipinfo.io,<你的Claude策略组名>"
  echo "    Clash:  - DOMAIN,ipinfo.io,<你的Claude策略组名>"
  local fallback_choice
  read "fallback_choice?添加后输入 y，跳过输入 n [n]: "
  local fallback_enabled="false"
  [[ "$fallback_choice" == "y" || "$fallback_choice" == "Y" ]] && fallback_enabled="true"

  cat > "$config_file" <<EOF
# Claude Proxy Guard 配置
# 代理工具：surge | clash | both（both = 任一在跑即可，OR 逻辑）
PROXY_TOOL=$proxy_tool

# 期望的出口国家代码（ISO 3166-1 alpha-2，如 JP、US、SG）
EXPECTED_COUNTRY=$country

# fallback 验证是否已启用（用户已在代理规则中添加 ipinfo.io 路由）
FALLBACK_ENABLED=$fallback_enabled
EOF

  chmod 600 "$config_file"
  echo ""
  echo "配置已保存到 $config_file"
}

# ============================================================================
# Proxy Process Detection (Task 3)
# ============================================================================

_cpg_check_proxy_process() {
  local tool="$PROXY_TOOL"
  local surge_pid="" clash_pid="" found_pids=""

  if [[ "$tool" == "surge" || "$tool" == "both" ]]; then
    surge_pid=$(pgrep -x "Surge" 2>/dev/null | head -1)
  fi

  if [[ "$tool" == "clash" || "$tool" == "both" ]]; then
    clash_pid=$(pgrep -f "clash-verge|mihomo" 2>/dev/null | head -1)
  fi

  [[ -n "$surge_pid" ]] && found_pids="$surge_pid"
  if [[ -n "$clash_pid" ]]; then
    [[ -n "$found_pids" ]] && found_pids="$found_pids,$clash_pid" || found_pids="$clash_pid"
  fi

  if [[ -z "$found_pids" ]]; then
    case "$tool" in
      surge) echo "[Proxy Guard] 错误：未检测到 Surge 进程" ;;
      clash) echo "[Proxy Guard] 错误：未检测到 Clash Verge 进程" ;;
      both)  echo "[Proxy Guard] 错误：未检测到 Surge 或 Clash Verge 进程" ;;
    esac
    echo "[Proxy Guard] 请先启动代理后再运行 claude"
    return 1
  fi

  [[ -n "$surge_pid" ]] && echo "[Proxy Guard] Surge 运行中 (PID: $surge_pid) ✓"
  [[ -n "$clash_pid" ]] && echo "[Proxy Guard] Clash Verge 运行中 (PID: $clash_pid) ✓"

  CPG_PROXY_PIDS="$found_pids"
  return 0
}

# ============================================================================
# Cache Logic (Task 4)
# ============================================================================

_cpg_cache_dir="$HOME/.cache/claude-proxy-guard"

_cpg_cache_valid() {
  local cache_file="$_cpg_cache_dir/result"
  [[ ! -f "$cache_file" ]] && return 1

  source "$cache_file"

  local now=$(date +%s)
  local age=$(( now - ${TIMESTAMP:-0} ))
  (( age >= 300 )) && return 1

  [[ "$PROXY_PIDS" != "$CPG_PROXY_PIDS" ]] && return 1
  [[ "$RESULT" != "PASS" ]] && return 1

  return 0
}

_cpg_cache_write() {
  local result="$1"
  mkdir -p "$_cpg_cache_dir"
  cat > "$_cpg_cache_dir/result" <<EOF
TIMESTAMP=$(date +%s)
PROXY_PIDS=$CPG_PROXY_PIDS
RESULT=$result
EOF
  chmod 600 "$_cpg_cache_dir/result"
}

# ============================================================================
# Network Pre-Check (Task 5)
# ============================================================================

_cpg_network_precheck() {
  if ! curl --connect-timeout 2 -sI "https://api.anthropic.com" >/dev/null 2>&1; then
    echo "[Proxy Guard] 错误：无法连接到 api.anthropic.com（网络不可用或代理未正确配置）"
    return 1
  fi
  return 0
}

# ============================================================================
# Run Checks (Stub for Task 7)
# ============================================================================

_cpg_run_checks() {
  local force=false
  [[ "$1" == "--force" ]] && force=true

  _cpg_load_config || return 1
  _cpg_check_proxy_process || return 1

  if ! $force && _cpg_cache_valid; then
    echo "[Proxy Guard] 缓存有效，跳过验证 ✓"
    return 0
  fi

  _cpg_network_precheck || return 1

  # Domain verification will be added in Task 6
  echo "[Proxy Guard] 域名验证待实现..."
  return 0
}

# ============================================================================
# Main claude() function (Task 1)
# ============================================================================

claude() {
  case "$1" in
    --guard-reset)
      _cpg_first_run_setup
      return 0
      ;;
    --guard-status)
      _cpg_run_checks --force
      return $?
      ;;
  esac

  _cpg_run_checks || return 1

  echo "[Proxy Guard] 全部通过，启动 Claude Code..."
  echo ""

  command claude "$@"
}
