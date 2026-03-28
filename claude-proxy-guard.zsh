#!/usr/bin/env zsh
# Claude Proxy Guard v1.1
# Verifies proxy is active and Claude traffic exits from expected country

# ============================================================================
# Config Loading + First-Run Setup
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
  DOMESTIC_IP_ENABLED=$(grep '^DOMESTIC_IP_ENABLED=' "$config_file" | cut -d= -f2)
  DOMESTIC_IP_ENABLED="${DOMESTIC_IP_ENABLED:-false}"

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

  echo ""
  echo "期望出口国家（ISO 3166-1 两位代码）:"
  echo "  JP=日本  US=美国  SG=新加坡  HK=香港"
  echo "  KR=韩国  TW=台湾  GB=英国    DE=德国"
  echo ""
  local country
  read "country?输入代码（默认 JP，直接回车使用默认值）: "
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

  echo ""
  echo "[可选] 是否启用国内出口 IP 显示？"
  echo "  需要在代理规则中添加一条："
  echo "    Surge:  DOMAIN,myip.ipip.net,DIRECT"
  echo "    Clash:  - DOMAIN,myip.ipip.net,DIRECT"
  local domestic_choice
  read "domestic_choice?添加后输入 y，跳过输入 n [n]: "
  local domestic_ip_enabled="false"
  [[ "$domestic_choice" == "y" || "$domestic_choice" == "Y" ]] && domestic_ip_enabled="true"

  cat > "$config_file" <<EOF
# Claude Proxy Guard 配置
# 代理工具：surge | clash | both（both = 任一在跑即可，OR 逻辑）
PROXY_TOOL=$proxy_tool

# 期望的出口国家代码（ISO 3166-1 alpha-2，如 JP、US、SG）
EXPECTED_COUNTRY=$country

# fallback 验证是否已启用（用户已在代理规则中添加 ipinfo.io 路由）
FALLBACK_ENABLED=$fallback_enabled

# 国内出口 IP 显示（需要 DOMAIN,myip.ipip.net,DIRECT 规则）
DOMESTIC_IP_ENABLED=$domestic_ip_enabled
EOF

  chmod 600 "$config_file"
  echo ""
  echo "配置已保存到 $config_file"
}

# ============================================================================
# Proxy Process Detection
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
# Local + Domestic IP Info
# ============================================================================

_cpg_show_local_info() {
  echo "[Proxy Guard] 本机信息:"

  # LAN IP
  local lan_ip=$(ipconfig getifaddr en0 2>/dev/null)
  [[ -z "$lan_ip" ]] && lan_ip=$(ipconfig getifaddr en1 2>/dev/null)
  [[ -z "$lan_ip" ]] && lan_ip="未知"
  printf "  局域网 IP:   %s\n" "$lan_ip"

  # Domestic IP (requires DIRECT rule for myip.ipip.net)
  if [[ "$DOMESTIC_IP_ENABLED" == "true" ]]; then
    local domestic_raw
    domestic_raw=$(curl -s --connect-timeout 3 "https://myip.ipip.net" 2>/dev/null)
    if [[ -n "$domestic_raw" ]]; then
      # Format: "当前 IP：x.x.x.x  来自于：中国 上海 电信"
      local domestic_ip=$(echo "$domestic_raw" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
      local domestic_loc=$(echo "$domestic_raw" | sed 's/.*来自于：//' | tr -d '\n')
      printf "  国内出口 IP: %s (%s)\n" "$domestic_ip" "$domestic_loc"
    else
      printf "  国内出口 IP: (获取失败)\n"
    fi
  else
    printf "  国内出口 IP: (未启用，运行 claude --guard-reset 配置)\n"
  fi
}

# ============================================================================
# Proxy Config DIRECT Rule Check
# ============================================================================

_cpg_check_direct_rule() {
  local domain="$1"
  local found=false

  # Scan Surge profiles
  local surge_dir="$HOME/Library/Application Support/Surge/Profiles"
  if [[ -d "$surge_dir" ]]; then
    if grep -rql "DOMAIN.*${domain}.*DIRECT" "$surge_dir" 2>/dev/null; then
      found=true
    fi
  fi

  # Scan Clash Verge configs
  local clash_dir="$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"
  if [[ -d "$clash_dir" ]] && ! $found; then
    if grep -rql "${domain}.*DIRECT\|${domain}" "$clash_dir"/*.yaml 2>/dev/null; then
      found=true
    fi
  fi

  if ! $found && [[ "$DOMESTIC_IP_ENABLED" == "true" ]]; then
    echo ""
    echo "[Proxy Guard] 提示：未在代理配置中找到 $domain 的 DIRECT 规则"
    echo "[Proxy Guard] 请在当前活跃的配置中添加："
    echo "  Surge:  DOMAIN,$domain,DIRECT"
    echo "  Clash:  - DOMAIN,$domain,DIRECT"
    echo ""
  fi
}

# ============================================================================
# Network Pre-Check
# ============================================================================

_cpg_network_precheck() {
  if ! curl --connect-timeout 2 -sI "https://api.anthropic.com" >/dev/null 2>&1; then
    echo "[Proxy Guard] 错误：无法连接到 api.anthropic.com（网络不可用或代理未正确配置）"
    return 1
  fi
  return 0
}

# ============================================================================
# Cache Logic (reworked: cache results, always display + confirm)
# ============================================================================

_cpg_cache_dir="$HOME/.cache/claude-proxy-guard"

_cpg_cache_valid() {
  local cache_file="$_cpg_cache_dir/result"
  local display_file="$_cpg_cache_dir/display"
  [[ ! -f "$cache_file" ]] && return 1
  [[ ! -f "$display_file" ]] && return 1

  local cached_ts=$(grep '^_CPG_TIMESTAMP=' "$cache_file" | cut -d= -f2)
  local cached_pids=$(grep '^_CPG_PROXY_PIDS=' "$cache_file" | cut -d= -f2)
  local cached_result=$(grep '^_CPG_RESULT=' "$cache_file" | cut -d= -f2)

  local now=$(date +%s)
  local age=$(( now - ${cached_ts:-0} ))
  (( age >= 300 )) && return 1
  [[ "$cached_pids" != "$CPG_PROXY_PIDS" ]] && return 1
  [[ "$cached_result" != "PASS" ]] && return 1

  # Export cache age for display
  CPG_CACHE_AGE_MIN=$(( age / 60 ))
  CPG_CACHE_AGE_SEC=$(( age % 60 ))
  return 0
}

_cpg_cache_write() {
  local result="$1"
  local display="$2"
  mkdir -p "$_cpg_cache_dir"
  cat > "$_cpg_cache_dir/result" <<EOF
_CPG_TIMESTAMP=$(date +%s)
_CPG_PROXY_PIDS=$CPG_PROXY_PIDS
_CPG_RESULT=$result
EOF
  chmod 600 "$_cpg_cache_dir/result"

  # Save display output for cache reuse
  echo "$display" > "$_cpg_cache_dir/display"
  chmod 600 "$_cpg_cache_dir/display"
}

# ============================================================================
# User Confirmation
# ============================================================================

_cpg_user_confirm() {
  local confirm
  echo ""
  echo "[Proxy Guard] 提示: --guard-status 查看状态 | --guard-reset 重新配置"
  read "confirm?[Proxy Guard] Enter 继续 / n 重新检测 / q 退出: "
  case "$confirm" in
    n|N) return 1 ;;   # re-check
    q|Q) return 2 ;;   # abort
    *)   return 0 ;;   # proceed
  esac
}

# ============================================================================
# Per-Domain Exit IP Verification
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

  # L3: defer to shared ipinfo.io result
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

  # Collect results into display buffer
  local all_pass=true
  local display=""

  display+="[Proxy Guard] 代理出口验证:\n"

  for domain in "${_cpg_cf_domains[@]}"; do
    local rfile="$_cpg_cache_dir/tmp_${domain//\./_}"
    if [[ -f "$rfile" ]]; then
      local line=$(cat "$rfile")
      local rstatus=$(echo "$line" | cut -d'|' -f1)
      local dname=$(echo "$line" | cut -d'|' -f2)
      local ip=$(echo "$line" | cut -d'|' -f3)
      local geo=$(echo "$line" | cut -d'|' -f4)

      if [[ "$rstatus" == "PASS" ]]; then
        display+="$(printf "  %-30s %-20s %s ✓" "$dname" "$ip" "$geo")\n"
      elif [[ "$rstatus" != "DEFER" ]]; then
        display+="$(printf "  %-30s %-20s %s ✗" "$dname" "$ip" "$geo")\n"
        all_pass=false
      fi
    else
      display+="$(printf "  %-30s %-20s %s ✗" "$domain" "error" "N/A")\n"
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
      display+="$(printf "  %-30s %-20s %s ✓" "statsigapi.net" "$region" "ok")\n"
    else
      display+="$(printf "  %-30s %-20s %s ✗" "statsigapi.net" "$region" "fail")\n"
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
    local l3_result
    l3_result=$(curl -s --connect-timeout 5 "http://ip-api.com/json?fields=query,countryCode" 2>/dev/null)
    local l3_country=$(echo "$l3_result" | grep -o '"countryCode":"[^"]*"' | cut -d'"' -f4)
    local l3_ip=$(echo "$l3_result" | grep -o '"query":"[^"]*"' | cut -d'"' -f4)
    local l3_pass=false
    [[ "$l3_country" == "$EXPECTED_COUNTRY" ]] && l3_pass=true

    for domain in "${_cpg_cf_domains[@]}"; do
      local rfile="$_cpg_cache_dir/tmp_${domain//\./_}"
      if [[ -f "$rfile" ]] && grep -q "^DEFER" "$rfile"; then
        if $l3_pass; then
          echo "PASS|$domain|$l3_ip|$l3_country/fallback~" > "$rfile"
          display+="$(printf "  %-30s %-20s %s ✓" "$domain" "$l3_ip" "$l3_country/fallback~")\n"
        else
          echo "FAIL|$domain|$l3_ip|$l3_country/fallback" > "$rfile"
          display+="$(printf "  %-30s %-20s %s ✗" "$domain" "$l3_ip" "$l3_country/fallback")\n"
          all_pass=false
        fi
      fi
    done
  elif $has_deferred; then
    for domain in "${_cpg_cf_domains[@]}"; do
      local rfile="$_cpg_cache_dir/tmp_${domain//\./_}"
      if [[ -f "$rfile" ]] && grep -q "^DEFER" "$rfile"; then
        echo "FAIL|$domain|no-trace|N/A" > "$rfile"
        display+="$(printf "  %-30s %-20s %s ✗" "$domain" "no-trace" "N/A")\n"
        all_pass=false
      fi
    done
  fi

  # downloads.claude.ai (covered by claude.ai)
  local claude_ai_file="$_cpg_cache_dir/tmp_claude_ai"
  if [[ -f "$claude_ai_file" ]]; then
    local claude_ai_rstatus=$(cat "$claude_ai_file" | cut -d'|' -f1)
    if [[ "$claude_ai_rstatus" == "PASS" ]]; then
      display+="$(printf "  %-30s %-20s %s ✓" "downloads.claude.ai" "(由 claude.ai 覆盖)" "")\n"
    else
      display+="$(printf "  %-30s %-20s %s ✗" "downloads.claude.ai" "(claude.ai 失败)" "")\n"
      all_pass=false
    fi
  fi

  # Geo info for unique exit IPs (batch query ip-api.com)
  local unique_ips=()
  for domain in "${_cpg_cf_domains[@]}"; do
    local rfile="$_cpg_cache_dir/tmp_${domain//\./_}"
    [[ ! -f "$rfile" ]] && continue
    local line=$(cat "$rfile")
    local rstatus=$(echo "$line" | cut -d'|' -f1)
    [[ "$rstatus" != "PASS" ]] && continue
    local ip=$(echo "$line" | cut -d'|' -f3)
    [[ "$ip" == "cf-ray" ]] && continue
    # Deduplicate
    local already=false
    for existing in "${unique_ips[@]}"; do
      [[ "$existing" == "$ip" ]] && already=true && break
    done
    $already || unique_ips+=("$ip")
  done

  if (( ${#unique_ips[@]} > 0 )); then
    # Build JSON array for batch query
    local batch_json="["
    local first=true
    for ip in "${unique_ips[@]}"; do
      $first || batch_json+=","
      batch_json+="{\"query\":\"$ip\"}"
      first=false
    done
    batch_json+="]"

    local geo_result
    geo_result=$(curl -s --connect-timeout 5 \
      "http://ip-api.com/batch?lang=zh-CN&fields=query,country,regionName,city,isp" \
      -X POST -d "$batch_json" 2>/dev/null)

    if [[ -n "$geo_result" ]] && echo "$geo_result" | grep -q '"query"'; then
      display+="[Proxy Guard] 出口 IP 地理信息:\n"
      for ip in "${unique_ips[@]}"; do
        # Extract fields for this IP from batch result
        # Use simple grep since jq may not be available
        local entry=$(echo "$geo_result" | tr '}' '\n' | grep "\"$ip\"")
        local gcountry=$(echo "$entry" | grep -o '"country":"[^"]*"' | cut -d'"' -f4)
        local gregion=$(echo "$entry" | grep -o '"regionName":"[^"]*"' | cut -d'"' -f4)
        local gcity=$(echo "$entry" | grep -o '"city":"[^"]*"' | cut -d'"' -f4)
        local gisp=$(echo "$entry" | grep -o '"isp":"[^"]*"' | cut -d'"' -f4)

        local ip_display="$ip"
        # Truncate long IPv6 for display
        if (( ${#ip_display} > 20 )); then
          ip_display="${ip_display:0:17}..."
        fi
        display+="$(printf "  %-22s → %s %s %s / %s" "$ip_display" "$gcountry" "$gregion" "$gcity" "$gisp")\n"
      done
    fi
  fi

  # Collect failure info BEFORE cleanup
  if ! $all_pass; then
    display+="\n[Proxy Guard] 错误：以下域名出口不在 $EXPECTED_COUNTRY，请检查代理规则\n"
    for domain in "${_cpg_cf_domains[@]}" "statsigapi.net"; do
      local rfile="$_cpg_cache_dir/tmp_${domain//\./_}"
      [[ ! -f "$rfile" ]] && continue
      local line=$(cat "$rfile")
      local rstatus=$(echo "$line" | cut -d'|' -f1)
      if [[ "$rstatus" == "FAIL" ]]; then
        local geo=$(echo "$line" | cut -d'|' -f4)
        display+="  $domain → $geo (期望 $EXPECTED_COUNTRY)\n"
      fi
    done
  fi

  # Clean up tmp files
  rm -f "$_cpg_cache_dir"/tmp_*(N) 2>/dev/null

  # Store display for cache reuse
  CPG_DISPLAY_OUTPUT="$display"

  if $all_pass; then
    return 0
  else
    return 1
  fi
}

# ============================================================================
# Run Checks (reworked: always show info + confirm)
# ============================================================================

_cpg_run_checks() {
  local force=false
  local status_only=false
  [[ "$1" == "--force" ]] && force=true
  [[ "$1" == "--status" ]] && { force=true; status_only=true; }

  _cpg_load_config || return 1
  _cpg_check_proxy_process || return 1

  # Show local info (always fresh)
  _cpg_show_local_info

  # Check domestic IP DIRECT rule
  if [[ "$DOMESTIC_IP_ENABLED" == "true" ]]; then
    _cpg_check_direct_rule "myip.ipip.net"
  fi

  local display=""
  local check_passed=true

  if ! $force && _cpg_cache_valid; then
    # Cache hit: show cached results with age
    display=$(cat "$_cpg_cache_dir/display")
    echo ""
    echo "[Proxy Guard] 代理出口验证 (缓存 ${CPG_CACHE_AGE_MIN}分${CPG_CACHE_AGE_SEC}秒前):"
    # Strip the header line from cached display, print the rest
    echo "$display" | tail -n +2
  else
    # Cache miss: run full verification
    _cpg_network_precheck || return 1
    _cpg_verify_all_domains
    check_passed=$?

    # Print the display output
    echo ""
    echo -e "$CPG_DISPLAY_OUTPUT"

    if [[ $check_passed -eq 0 ]]; then
      _cpg_cache_write "PASS" "$CPG_DISPLAY_OUTPUT"
    fi
  fi

  # Status-only mode: don't ask for confirmation
  if $status_only; then
    return $check_passed
  fi

  # Verification failed: block, but show hints
  if [[ $check_passed -ne 0 ]]; then
    echo ""
    echo "[Proxy Guard] 提示: --guard-status 查看状态 | --guard-reset 重新配置"
    return 1
  fi

  # User confirmation
  _cpg_user_confirm
  local confirm_result=$?

  if [[ $confirm_result -eq 1 ]]; then
    # User wants re-check: invalidate cache and recurse
    rm -f "$_cpg_cache_dir/result" "$_cpg_cache_dir/display" 2>/dev/null
    echo ""
    _cpg_run_checks --force
    return $?
  elif [[ $confirm_result -eq 2 ]]; then
    # User wants to quit
    echo "[Proxy Guard] 已取消"
    return 1
  fi

  return 0
}

# ============================================================================
# Main claude() function
# ============================================================================

claude() {
  case "$1" in
    --guard-reset)
      _cpg_first_run_setup
      return 0
      ;;
    --guard-status)
      _cpg_run_checks --status
      return $?
      ;;
  esac

  _cpg_run_checks || return 1

  echo "[Proxy Guard] 全部通过，启动 Claude Code..."
  echo ""

  command claude "$@"
}
