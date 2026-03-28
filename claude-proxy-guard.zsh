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

  PROXY_TOOL=$(grep '^PROXY_TOOL=' "$config_file" | cut -d= -f2)
  EXPECTED_COUNTRY=$(grep '^EXPECTED_COUNTRY=' "$config_file" | cut -d= -f2)
  FALLBACK_ENABLED=$(grep '^FALLBACK_ENABLED=' "$config_file" | cut -d= -f2)

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

  local cached_ts=$(grep '^_CPG_TIMESTAMP=' "$cache_file" | cut -d= -f2)
  local cached_pids=$(grep '^_CPG_PROXY_PIDS=' "$cache_file" | cut -d= -f2)
  local cached_result=$(grep '^_CPG_RESULT=' "$cache_file" | cut -d= -f2)

  local now=$(date +%s)
  local age=$(( now - ${cached_ts:-0} ))
  (( age >= 300 )) && return 1
  [[ "$cached_pids" != "$CPG_PROXY_PIDS" ]] && return 1
  [[ "$cached_result" != "PASS" ]] && return 1

  return 0
}

_cpg_cache_write() {
  local result="$1"
  mkdir -p "$_cpg_cache_dir"
  cat > "$_cpg_cache_dir/result" <<EOF
_CPG_TIMESTAMP=$(date +%s)
_CPG_PROXY_PIDS=$CPG_PROXY_PIDS
_CPG_RESULT=$result
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
# Per-Domain Exit IP Verification (Task 6)
# ============================================================================

# Cloudflare domains (verified via /cdn-cgi/trace)
_cpg_cf_domains=(
  api.anthropic.com
  anthropic.com
  claude.ai
  claude.com
  platform.claude.com
  mcp-proxy.anthropic.com
  clau.de
  www.claudeusercontent.com
)

# IATA codes per country for L2 fallback
typeset -A _cpg_iata_codes
_cpg_iata_codes=(
  JP "NRT KIX"
  US "LAX SFO SEA ORD IAD EWR ATL DFW MIA"
  SG "SIN"
  HK "HKG"
)

# China mainland GKE regions (for statsigapi.net rejection)
_cpg_china_gke_regions="gke-asia-east2"

_cpg_verify_cf_domain() {
  local domain="$1"
  local expected="$EXPECTED_COUNTRY"
  local result_file="$_cpg_cache_dir/tmp_${domain//\./_}"

  # L1: /cdn-cgi/trace
  local trace
  trace=$(curl -s --connect-timeout 5 "https://$domain/cdn-cgi/trace" 2>/dev/null)

  if [[ -n "$trace" ]] && echo "$trace" | grep -q "^loc="; then
    local ip=$(echo "$trace" | grep "^ip=" | cut -d= -f2)
    local loc=$(echo "$trace" | grep "^loc=" | cut -d= -f2)
    local colo=$(echo "$trace" | grep "^colo=" | cut -d= -f2)

    if [[ "$loc" == "$expected" ]]; then
      echo "PASS|$domain|$ip|$loc/$colo" > "$result_file"
      return 0
    else
      echo "FAIL|$domain|$ip|$loc/$colo" > "$result_file"
      return 1
    fi
  fi

  # L2: cf-ray header (strip \r from HTTP CRLF)
  local headers
  headers=$(curl -sI --connect-timeout 5 "https://$domain" 2>/dev/null)
  local cf_ray=$(echo "$headers" | tr -d '\r' | grep -i "^cf-ray:" | sed 's/.*-\([A-Z]*\).*/\1/')

  if [[ -n "$cf_ray" ]]; then
    local valid_codes="${_cpg_iata_codes[$expected]}"
    if [[ -n "$valid_codes" ]] && echo "$valid_codes" | grep -qw "$cf_ray"; then
      echo "PASS|$domain|cf-ray|$expected/$cf_ray~" > "$result_file"
      return 0
    else
      echo "FAIL|$domain|cf-ray|??/$cf_ray" > "$result_file"
      return 1
    fi
  fi

  # L3: defer to shared ipinfo.io result (checked once in orchestrator)
  echo "DEFER|$domain|L3|pending" > "$result_file"
  return 1
}

_cpg_verify_statsig() {
  local result_file="$_cpg_cache_dir/tmp_statsigapi_net"
  local headers
  headers=$(curl -sI --connect-timeout 5 "https://statsigapi.net" 2>/dev/null)
  local region=$(echo "$headers" | grep -i "^x-statsig-region:" | awk '{print $2}' | tr -d '\r')

  if [[ -z "$region" ]]; then
    echo "FAIL|statsigapi.net|no-region|N/A" > "$result_file"
    return 1
  fi

  if echo "$_cpg_china_gke_regions" | grep -qw "$region"; then
    echo "FAIL|statsigapi.net|$region|CN" > "$result_file"
    return 1
  fi

  echo "PASS|statsigapi.net|$region|ok" > "$result_file"
  return 0
}

_cpg_verify_all_domains() {
  rm -f "$_cpg_cache_dir"/tmp_*(N) 2>/dev/null
  mkdir -p "$_cpg_cache_dir"

  # Launch all checks in parallel
  for domain in "${_cpg_cf_domains[@]}"; do
    _cpg_verify_cf_domain "$domain" &
  done
  _cpg_verify_statsig &
  wait

  # Collect results
  local all_pass=true

  echo "[Proxy Guard] 出口验证:"

  for domain in "${_cpg_cf_domains[@]}"; do
    local rfile="$_cpg_cache_dir/tmp_${domain//\./_}"
    if [[ -f "$rfile" ]]; then
      local line=$(cat "$rfile")
      local rstatus=$(echo "$line" | cut -d'|' -f1)
      local dname=$(echo "$line" | cut -d'|' -f2)
      local ip=$(echo "$line" | cut -d'|' -f3)
      local geo=$(echo "$line" | cut -d'|' -f4)

      if [[ "$rstatus" == "PASS" ]]; then
        printf "  %-30s %-20s %s ✓\n" "$dname" "$ip" "$geo"
      elif [[ "$rstatus" != "DEFER" ]]; then
        printf "  %-30s %-20s %s ✗\n" "$dname" "$ip" "$geo"
        all_pass=false
      fi
    else
      printf "  %-30s %-20s %s ✗\n" "$domain" "error" "N/A"
      all_pass=false
    fi
  done

  # statsigapi.net
  local rfile="$_cpg_cache_dir/tmp_statsigapi_net"
  if [[ -f "$rfile" ]]; then
    local line=$(cat "$rfile")
    local rstatus=$(echo "$line" | cut -d'|' -f1)
    local region=$(echo "$line" | cut -d'|' -f3)
    if [[ "$rstatus" == "PASS" ]]; then
      printf "  %-30s %-20s %s ✓\n" "statsigapi.net" "$region" "ok"
    else
      printf "  %-30s %-20s %s ✗\n" "statsigapi.net" "$region" "fail"
      all_pass=false
    fi
  fi

  # L3 fallback: if any domains deferred, run ipinfo.io ONCE
  local has_deferred=false
  for domain in "${_cpg_cf_domains[@]}"; do
    local rfile="$_cpg_cache_dir/tmp_${domain//\./_}"
    [[ -f "$rfile" ]] && grep -q "^DEFER" "$rfile" && has_deferred=true && break
  done

  if $has_deferred && [[ "$FALLBACK_ENABLED" == "true" ]]; then
    local ipinfo
    ipinfo=$(curl -s --connect-timeout 5 "https://ipinfo.io/json" 2>/dev/null)
    local l3_country=$(echo "$ipinfo" | grep '"country"' | cut -d'"' -f4)
    local l3_ip=$(echo "$ipinfo" | grep '"ip"' | cut -d'"' -f4)
    local l3_pass=false
    [[ "$l3_country" == "$EXPECTED_COUNTRY" ]] && l3_pass=true

    for domain in "${_cpg_cf_domains[@]}"; do
      local rfile="$_cpg_cache_dir/tmp_${domain//\./_}"
      if [[ -f "$rfile" ]] && grep -q "^DEFER" "$rfile"; then
        if $l3_pass; then
          echo "PASS|$domain|$l3_ip|$l3_country/ipinfo~" > "$rfile"
          printf "  %-30s %-20s %s ✓\n" "$domain" "$l3_ip" "$l3_country/ipinfo~"
        else
          echo "FAIL|$domain|$l3_ip|$l3_country/ipinfo" > "$rfile"
          printf "  %-30s %-20s %s ✗\n" "$domain" "$l3_ip" "$l3_country/ipinfo"
          all_pass=false
        fi
      fi
    done
  elif $has_deferred; then
    for domain in "${_cpg_cf_domains[@]}"; do
      local rfile="$_cpg_cache_dir/tmp_${domain//\./_}"
      if [[ -f "$rfile" ]] && grep -q "^DEFER" "$rfile"; then
        printf "  %-30s %-20s %s ✗\n" "$domain" "no-trace" "N/A"
        all_pass=false
      fi
    done
  fi

  # downloads.claude.ai (covered by claude.ai)
  local claude_ai_file="$_cpg_cache_dir/tmp_claude_ai"
  if [[ -f "$claude_ai_file" ]]; then
    local claude_ai_status=$(cat "$claude_ai_file" | cut -d'|' -f1)
    if [[ "$claude_ai_status" == "PASS" ]]; then
      printf "  %-30s %-20s %s ✓\n" "downloads.claude.ai" "(由 claude.ai 覆盖)" ""
    else
      printf "  %-30s %-20s %s ✗\n" "downloads.claude.ai" "(claude.ai 失败)" ""
      all_pass=false
    fi
  fi

  # Collect failure info BEFORE cleanup
  local failures=""
  if ! $all_pass; then
    for domain in "${_cpg_cf_domains[@]}" "statsigapi.net"; do
      local rfile="$_cpg_cache_dir/tmp_${domain//\./_}"
      [[ ! -f "$rfile" ]] && continue
      local line=$(cat "$rfile")
      local rstatus=$(echo "$line" | cut -d'|' -f1)
      if [[ "$rstatus" == "FAIL" ]]; then
        local geo=$(echo "$line" | cut -d'|' -f4)
        failures="$failures\n  $domain → $geo (期望 $EXPECTED_COUNTRY)"
      fi
    done
  fi

  # Clean up tmp files
  rm -f "$_cpg_cache_dir"/tmp_*(N) 2>/dev/null

  if $all_pass; then
    return 0
  else
    echo ""
    echo "[Proxy Guard] 错误：以下域名出口不在 $EXPECTED_COUNTRY，请检查代理规则"
    echo "$failures"
    return 1
  fi
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
  _cpg_verify_all_domains || return 1

  _cpg_cache_write "PASS"
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
