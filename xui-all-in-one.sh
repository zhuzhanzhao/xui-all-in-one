#!/usr/bin/env bash
set -Eeuo pipefail

# 3x-ui unified installer and inbound creator.
# Supported: panel, VMess/TCP, VLESS/REALITY, Mixed(SOCKS5/HTTP), Tunnel relay.

OFFICIAL_INSTALLER="https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh"
XUI_BIN="/usr/local/x-ui/x-ui"
TOOL_CONFIG="/root/.xui-all-in-one.env"
PROFILE_DIR="/root/3x-ui-profiles"
COOKIE_JAR=""
CSRF_TOKEN=""
PANEL_ROOT=""

red='\033[31m'; green='\033[32m'; yellow='\033[33m'; reset='\033[0m'
info() { printf '%b\n' "${green}$*${reset}"; }
warn() { printf '%b\n' "${yellow}$*${reset}"; }
fail() { printf '%b\n' "${red}错误：$*${reset}" >&2; exit 1; }
pause() { read -r -p "按回车返回菜单..." _; }

cleanup() {
  [[ -z "$COOKIE_JAR" ]] || rm -f "$COOKIE_JAR"
}
trap cleanup EXIT

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "请先执行 sudo -i，再运行本脚本"

install_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl jq openssl ca-certificates
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl jq openssl ca-certificates
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl jq openssl ca-certificates
  else
    fail "仅支持 Ubuntu/Debian/CentOS/RHEL 系统"
  fi
}

ensure_tools() {
  local missing=0
  for c in curl jq openssl; do command -v "$c" >/dev/null 2>&1 || missing=1; done
  (( missing == 0 )) || install_packages
  mkdir -p "$PROFILE_DIR"
  chmod 700 "$PROFILE_DIR"
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1024 && 10#$1 <= 65535 ))
}

ask_port() {
  local prompt="$1" value
  while true; do
    read -r -p "$prompt" value
    if ! valid_port "$value"; then
      warn "端口必须是 1024 到 65535 的数字" >&2
      continue
    fi
    if ss -lntup 2>/dev/null | awk '{print $5}' | grep -Eq "(^|:)${value}$"; then
      warn "端口 ${value} 已被占用，请换一个" >&2
      continue
    fi
    printf '%s' "$value"
    return
  done
}

ask_nonempty() {
  local prompt="$1" value
  while true; do
    read -r -p "$prompt" value
    [[ -n "$value" ]] && { printf '%s' "$value"; return; }
    warn "不能为空" >&2
  done
}

ask_password() {
  local prompt="$1" value
  while true; do
    read -r -s -p "$prompt" value; echo >&2
    (( ${#value} >= 8 )) && { printf '%s' "$value"; return; }
    warn "密码至少需要 8 位" >&2
  done
}

random_hex() { openssl rand -hex "$1"; }
random_alnum() {
  local length="$1" out
  out=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' || true)
  printf '%.*s' "$length" "$out"
}
new_uuid() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then cat /proc/sys/kernel/random/uuid; else "$XUI_BIN" uuid; fi
}

detect_public_ip() {
  local ip=""
  for url in https://api4.ipify.org https://ipv4.icanhazip.com https://4.ident.me; do
    ip=$(curl -4fsS --max-time 4 "$url" 2>/dev/null | tr -d '[:space:]') || true
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { printf '%s' "$ip"; return; }
  done
  printf '<服务器公网IP>'
}

save_tool_config() {
  umask 077
  {
    printf 'PANEL_USER=%q\n' "$PANEL_USER"
    printf 'PANEL_PASSWORD=%q\n' "$PANEL_PASSWORD"
  } > "$TOOL_CONFIG"
  chmod 600 "$TOOL_CONFIG"
}

load_tool_config() {
  [[ -f "$TOOL_CONFIG" ]] || return 1
  # This file is written only by this script and is root-readable only.
  # shellcheck disable=SC1090
  source "$TOOL_CONFIG"
  [[ -n "${PANEL_USER:-}" && -n "${PANEL_PASSWORD:-}" ]]
}

panel_setting() {
  "$XUI_BIN" setting -show true 2>/dev/null
}

panel_installed() {
  [[ -x "$XUI_BIN" ]] && systemctl list-unit-files 2>/dev/null | grep -q '^x-ui\.service'
}

open_local_firewall() {
  local port="$1" proto="$2"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "${port}/${proto}" >/dev/null
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null
    firewall-cmd --reload >/dev/null
  fi
}

install_panel() {
  if panel_installed; then
    warn "已检测到3x-ui，本操作不会重复安装。"
    if ! load_tool_config; then
      PANEL_USER=$(ask_nonempty "现有面板用户名: ")
      PANEL_PASSWORD=$(ask_password "现有面板密码（输入不显示）: ")
      save_tool_config
    fi
    systemctl restart x-ui
    return
  fi

  ensure_tools
  echo "=== 安装官方3x-ui ==="
  PANEL_USER=$(ask_nonempty "面板用户名: ")
  PANEL_PASSWORD=$(ask_password "面板密码（至少8位，输入不显示）: ")
  local panel_port
  panel_port=$(ask_port "面板端口（例如1997）: ")

  # Remove only a stale service unit left by an incomplete install. Never remove the DB here.
  if [[ ! -x "$XUI_BIN" ]] && systemctl list-unit-files 2>/dev/null | grep -q '^x-ui\.service'; then
    warn "发现未完成安装留下的服务文件，正在清理服务残留（不会删除数据库）。"
    systemctl disable --now x-ui >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/x-ui.service /lib/systemd/system/x-ui.service /usr/lib/systemd/system/x-ui.service
    systemctl daemon-reload
  fi

  local installer
  installer=$(mktemp /tmp/3x-ui-install.XXXXXX.sh)
  curl -fL --retry 3 --connect-timeout 15 "$OFFICIAL_INSTALLER" -o "$installer"
  chmod 700 "$installer"

  XUI_NONINTERACTIVE=1 \
  XUI_DB_TYPE=sqlite \
  XUI_USERNAME="$PANEL_USER" \
  XUI_PASSWORD="$PANEL_PASSWORD" \
  XUI_PANEL_PORT="$panel_port" \
  XUI_WEB_BASE_PATH="root" \
  XUI_SSL_MODE=none \
    bash "$installer"
  rm -f "$installer"

  [[ -x "$XUI_BIN" ]] || fail "3x-ui安装失败，请查看上方日志"
  "$XUI_BIN" setting -webBasePath "/"
  systemctl enable x-ui >/dev/null 2>&1 || true
  systemctl restart x-ui
  systemctl is-active --quiet x-ui || fail "3x-ui服务没有启动"
  save_tool_config
  open_local_firewall "$panel_port" tcp

  local ip
  ip=$(detect_public_ip)
  info "面板安装完成：http://${ip}:${panel_port}"
  warn "事实：本脚本为省去域名步骤，面板使用HTTP。请使用强密码，并在云防火墙限制面板端口来源IP。"
  warn "云服务商安全组仍需放行 TCP ${panel_port}；本脚本无法替你修改云厂商后台。"
}

ensure_panel_credentials() {
  panel_installed || fail "尚未安装3x-ui，请先选择菜单1"
  if ! load_tool_config; then
    PANEL_USER=$(ask_nonempty "面板用户名: ")
    PANEL_PASSWORD=$(ask_password "面板密码（输入不显示）: ")
    save_tool_config
  fi
}

refresh_panel_root() {
  local settings port path cert scheme="http"
  settings=$(panel_setting) || fail "无法读取面板设置"
  port=$(awk -F': ' '/^port: /{print $2; exit}' <<<"$settings")
  path=$(awk -F': ' '/^webBasePath:/{print $2; exit}' <<<"$settings")
  [[ -n "$port" ]] || fail "无法读取面板端口"
  cert=$("$XUI_BIN" setting -getCert true 2>/dev/null | awk -F': ' '/^cert:/{print $2; exit}' | tr -d '[:space:]')
  [[ -z "$cert" ]] || scheme="https"
  path="/${path#/}"; [[ "$path" == "/" ]] || path="${path%/}"
  if [[ "$path" == "/" ]]; then
    PANEL_ROOT="${scheme}://127.0.0.1:${port}"
  else
    PANEL_ROOT="${scheme}://127.0.0.1:${port}${path}"
  fi
}

json_success() { jq -e '.success == true' >/dev/null 2>&1 <<<"$1"; }

api_login() {
  ensure_tools
  ensure_panel_credentials
  refresh_panel_root
  [[ -z "$COOKIE_JAR" ]] || rm -f "$COOKIE_JAR"
  COOKIE_JAR=$(mktemp /tmp/xui-cookie.XXXXXX)
  local r body
  r=$(curl -kfsS -c "$COOKIE_JAR" -b "$COOKIE_JAR" "${PANEL_ROOT}/csrf-token") \
    || fail "无法连接本机面板：${PANEL_ROOT}"
  CSRF_TOKEN=$(jq -r '.obj // empty' <<<"$r")
  [[ -n "$CSRF_TOKEN" ]] || fail "无法取得登录CSRF令牌"
  body=$(jq -nc --arg u "$PANEL_USER" --arg p "$PANEL_PASSWORD" '{username:$u,password:$p}')
  r=$(curl -kfsS -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
    -H 'Content-Type: application/json' -H "X-CSRF-Token: ${CSRF_TOKEN}" \
    -d "$body" "${PANEL_ROOT}/login") || fail "面板登录请求失败"
  if ! json_success "$r"; then
    rm -f "$TOOL_CONFIG"
    fail "面板登录失败：$(jq -r '.msg // "用户名或密码错误"' <<<"$r")。已清除本脚本保存的旧密码，请重试。"
  fi
  r=$(curl -kfsS -c "$COOKIE_JAR" -b "$COOKIE_JAR" "${PANEL_ROOT}/csrf-token")
  CSRF_TOKEN=$(jq -r '.obj // empty' <<<"$r")
  [[ -n "$CSRF_TOKEN" ]] || fail "登录后无法取得CSRF令牌"
}

api_get() {
  curl -kfsS -c "$COOKIE_JAR" -b "$COOKIE_JAR" "$1"
}

api_post() {
  local endpoint="$1" body="$2"
  curl -kfsS -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
    -H 'Content-Type: application/json' -H "X-CSRF-Token: ${CSRF_TOKEN}" \
    -d "$body" "${PANEL_ROOT}${endpoint}"
}

common_payload() {
  local protocol="$1" remark="$2" port="$3" settings="$4" stream="$5" sniff="$6"
  jq -nc \
    --arg protocol "$protocol" --arg remark "$remark" --argjson port "$port" \
    --argjson settings "$settings" --argjson stream "$stream" --argjson sniff "$sniff" \
    '{up:0,down:0,total:0,remark:$remark,enable:true,expiryTime:0,
      trafficReset:"never",trafficResetDay:1,lastTrafficResetTime:0,
      listen:"",port:$port,protocol:$protocol,settings:$settings,
      streamSettings:$stream,sniffing:$sniff,tag:"",shareAddrStrategy:"node",
      shareAddr:"",subSortIndex:1,excludeFromSub:false,disableFlow:false}'
}

create_inbound() {
  local payload="$1" response
  response=$(api_post "/panel/api/inbounds/add" "$payload") || fail "创建入站请求失败"
  if ! json_success "$response"; then
    fail "创建失败：$(jq -r '.msg // "未知错误"' <<<"$response")"
  fi
}

save_profile() {
  local name="$1" content="$2" file="${PROFILE_DIR}/${name}.txt"
  umask 077
  printf '%s\n' "$content" > "$file"
  chmod 600 "$file"
  info "配置已保存：${file}"
}

create_vmess() {
  api_login
  local port remark uuid email subid ip settings stream payload link json b64
  port=$(ask_port "VMess端口（例如30001）: ")
  read -r -p "备注 [vmess-${port}]: " remark; remark=${remark:-vmess-${port}}
  uuid=$(new_uuid); email="user_$(random_hex 3)"; subid=$(random_alnum 16); ip=$(detect_public_ip)
  settings=$(jq -nc --arg id "$uuid" --arg email "$email" --arg sub "$subid" \
    '{clients:[{id:$id,security:"auto",alterId:0,email:$email,limitIp:0,totalGB:0,
      expiryTime:0,enable:true,tgId:0,subId:$sub,comment:"",reset:0}]}')
  stream='{"network":"tcp","security":"none","tcpSettings":{"acceptProxyProtocol":false,"header":{"type":"none"}}}'
  payload=$(common_payload vmess "$remark" "$port" "$settings" "$stream" '{"enabled":false}')
  create_inbound "$payload"
  open_local_firewall "$port" tcp
  json=$(jq -nc --arg ps "$remark" --arg add "$ip" --arg port "$port" --arg id "$uuid" \
    '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:"0",scy:"auto",net:"tcp",type:"none",host:"",path:"",tls:"",sni:"",alpn:""}')
  b64=$(printf '%s' "$json" | base64 | tr -d '\n')
  link="vmess://${b64}"
  save_profile "vmess-${port}" "${link}"
  info "VMess创建完成：${ip}:${port}"
  warn "事实：这是最简VMess/TCP，不使用TLS。云防火墙还需放行 TCP ${port}。"
}

create_vless_reality() {
  api_login
  local port remark remark_uri uuid email subid ip target sni sid keys private public settings stream payload link
  port=$(ask_port "VLESS端口（建议443或30002）: ")
  read -r -p "备注 [vless-reality-${port}]: " remark; remark=${remark:-vless-reality-${port}}
  read -r -p "REALITY伪装域名 [www.microsoft.com]: " sni; sni=${sni:-www.microsoft.com}
  target="${sni}:443"; uuid=$(new_uuid); email="user_$(random_hex 3)"; subid=$(random_alnum 16)
  sid=$(random_hex 8); ip=$(detect_public_ip)
  keys=$(api_get "${PANEL_ROOT}/panel/api/server/getNewX25519Cert")
  json_success "$keys" || fail "无法生成REALITY密钥"
  private=$(jq -r '.obj.privateKey' <<<"$keys"); public=$(jq -r '.obj.publicKey' <<<"$keys")
  settings=$(jq -nc --arg id "$uuid" --arg email "$email" --arg sub "$subid" \
    '{clients:[{id:$id,flow:"xtls-rprx-vision",email:$email,limitIp:0,totalGB:0,
      expiryTime:0,enable:true,tgId:0,subId:$sub,comment:"",reset:0}],
      decryption:"none",encryption:"none",fallbacks:[]}')
  stream=$(jq -nc --arg target "$target" --arg sni "$sni" --arg pri "$private" --arg pub "$public" --arg sid "$sid" \
    '{network:"tcp",security:"reality",tcpSettings:{acceptProxyProtocol:false,header:{type:"none"}},
      realitySettings:{show:false,xver:0,target:$target,serverNames:[$sni],privateKey:$pri,
        minClientVer:"",maxClientVer:"",maxTimediff:0,shortIds:[$sid],mldsa65Seed:"",
        settings:{publicKey:$pub,fingerprint:"chrome",serverName:$sni,spiderX:"/",mldsa65Verify:""}}}')
  payload=$(common_payload vless "$remark" "$port" "$settings" "$stream" \
    '{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false,"routeOnly":false}')
  create_inbound "$payload"
  open_local_firewall "$port" tcp
  remark_uri=$(jq -rn --arg v "$remark" '$v|@uri')
  link="vless://${uuid}@${ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${public}&sid=${sid}&type=tcp#${remark_uri}"
  save_profile "vless-reality-${port}" "$link"
  info "VLESS REALITY创建完成：${ip}:${port}"
  warn "云防火墙还需放行 TCP ${port}。伪装域名必须能从服务器正常访问。"
}

create_mixed_socks() {
  api_login
  local port remark user pass udp_choice udp settings payload ip profile
  port=$(ask_port "SOCKS5端口（例如36745）: ")
  read -r -p "备注 [socks-${port}]: " remark; remark=${remark:-socks-${port}}
  user=$(ask_nonempty "SOCKS5用户名: ")
  pass=$(ask_password "SOCKS5密码（至少8位，输入不显示）: ")
  read -r -p "启用UDP？[y/N]: " udp_choice
  [[ "$udp_choice" =~ ^[Yy]$ ]] && udp=true || udp=false
  settings=$(jq -nc --arg user "$user" --arg pass "$pass" --argjson udp "$udp" \
    '{auth:"password",accounts:[{user:$user,pass:$pass}],udp:$udp,ip:"127.0.0.1"}')
  payload=$(common_payload mixed "$remark" "$port" "$settings" '{}' '{"enabled":false}')
  create_inbound "$payload"
  open_local_firewall "$port" tcp
  [[ "$udp" == true ]] && open_local_firewall "$port" udp
  ip=$(detect_public_ip)
  profile="类型: SOCKS5\n地址: ${ip}\n端口: ${port}\n用户名: ${user}\n密码: ${pass}\nUDP: ${udp}"
  save_profile "socks-${port}" "$(printf '%b' "$profile")"
  info "SOCKS5创建完成：${ip}:${port}"
  warn "云防火墙需放行 TCP ${port}$([[ "$udp" == true ]] && printf ' 和 UDP %s' "$port")。"
}

create_tunnel() {
  api_login
  local listen_port target_ip target_port network remark settings payload test_ok=0
  listen_port=$(ask_port "中转机监听端口（例如20845）: ")
  target_ip=$(ask_nonempty "落地机IP或域名: ")
  while true; do
    read -r -p "落地机目标端口: " target_port
    valid_port "$target_port" && break
    warn "目标端口无效"
  done
  read -r -p "转发UDP？[y/N]: " _udp
  [[ "${_udp:-}" =~ ^[Yy]$ ]] && network="tcp,udp" || network="tcp"
  read -r -p "备注 [relay-${target_ip}-${target_port}]: " remark
  remark=${remark:-relay-${target_ip}-${target_port}}

  if timeout 5 bash -c "</dev/tcp/${target_ip}/${target_port}" 2>/dev/null; then
    test_ok=1
    info "前置检查：中转机可以连接目标 ${target_ip}:${target_port}"
  else
    warn "前置检查失败：当前无法从中转机连接目标 ${target_ip}:${target_port}。"
    read -r -p "仍然创建？输入 YES 继续: " _continue
    [[ "$_continue" == YES ]] || return
  fi

  settings=$(jq -nc --arg addr "$target_ip" --argjson p "$target_port" --arg net "$network" \
    '{rewriteAddress:$addr,rewritePort:$p,portMap:{},allowedNetwork:$net,followRedirect:false}')
  payload=$(common_payload tunnel "$remark" "$listen_port" "$settings" '{}' '{"enabled":false}')
  create_inbound "$payload"
  open_local_firewall "$listen_port" tcp
  [[ "$network" == "tcp,udp" ]] && open_local_firewall "$listen_port" udp
  info "Tunnel中转创建完成：本机:${listen_port} → ${target_ip}:${target_port}"
  warn "事实：Tunnel是裸转发，不会加密中转机到落地机之间的流量。"
  warn "云防火墙需放行中转机端口 ${listen_port}；落地机端口最好只允许中转机公网IP访问。"
  (( test_ok == 1 )) || warn "预测：目标连通性未解决前，这条中转不会工作。"
}

show_status() {
  panel_installed || { warn "3x-ui尚未安装"; return; }
  local settings ip
  settings=$(panel_setting); ip=$(detect_public_ip)
  echo "=== 3x-ui状态 ==="
  systemctl --no-pager --full status x-ui | sed -n '1,8p' || true
  echo
  echo "公网IP: ${ip}"
  awk -F': ' '/^(port|webBasePath):/{print}' <<<"$settings"
  echo "配置文件目录: ${PROFILE_DIR}"
}

main_menu() {
  ensure_tools
  while true; do
    cat <<'EOF'

========== 3x-ui 一体化工具 ==========
1. 安装/接管3x-ui面板
2. 一键创建VMess（TCP）
3. 一键创建VLESS（REALITY，推荐）
4. 一键创建SOCKS5（Mixed）
5. 一键创建Tunnel中转
6. 查看状态
0. 退出
======================================
EOF
    read -r -p "请选择: " choice
    case "$choice" in
      1) install_panel; pause ;;
      2) create_vmess; pause ;;
      3) create_vless_reality; pause ;;
      4) create_mixed_socks; pause ;;
      5) create_tunnel; pause ;;
      6) show_status; pause ;;
      0) exit 0 ;;
      *) warn "请输入0到6" ;;
    esac
  done
}

main_menu
