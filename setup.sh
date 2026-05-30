#!/bin/bash
# =============================================================
#  z-ui  -  realm 端口转发管理面板  (增强版 v2)
#  功能:
#    - 安装/卸载 realm、增删查转发规则(带备注)、服务管理
#    - 目标 IP 记忆复用: 新增转发时可选已存在 IP 或彻底新增
#    - 3x-ui(3.2.0+) 节点同步监控: 用 token 查询目标面板,
#      目标新增节点 -> 本地同端口自动新增; 目标删除 -> 本地删除
#    - 后台守护进程 24h 轮询, 崩溃/退出自动恢复(systemd)
#    - 同步日志: 新增失败(端口占用等)记录, 面板可查看
#  快捷命令: 安装后输入  z-ui  即可随时唤出本面板
# =============================================================

REALM_BIN="/usr/local/bin/realm"
REALM_DIR="/etc/realm"
CONF="${REALM_DIR}/config.toml"
RULES="${REALM_DIR}/rules.db"          # 转发规则: 端口|目标IP|目标端口|备注|来源
IPS="${REALM_DIR}/ips.db"              # 已记忆的目标IP: IP|备注
MONITORS="${REALM_DIR}/monitors.db"    # 监控目标: 名称|baseURL|token|备注
SYNC_LOG="${REALM_DIR}/sync.log"       # 同步日志
SYNC_CONF="${REALM_DIR}/sync.conf"     # 同步配置(轮询间隔等)
SERVICE="/etc/systemd/system/realm.service"
SYNC_SERVICE="/etc/systemd/system/realm-sync.service"
SELF_PATH="/usr/local/bin/z-ui"        # 脚本自身安装位置
LOCK_FILE="/run/realm-sync.lock"       # 防止同步重入

# 来源标记: manual=手动添加  sync:<监控名>=自动同步而来
DEFAULT_INTERVAL=60                     # 默认轮询间隔(秒)

# ---------- 颜色 ----------
G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; B='\033[0;36m'; P='\033[0;35m'; N='\033[0m'

need_root() {
  [ "$(id -u)" != "0" ] && { echo -e "${R}请用 root 运行(sudo -i)${N}"; exit 1; }
}

pause() { echo ""; read -p "按回车返回菜单..." _; }

# 确保数据文件存在
ensure_files() {
  mkdir -p "$REALM_DIR"
  touch "$RULES" "$IPS" "$MONITORS" "$SYNC_LOG"
  [ -f "$SYNC_CONF" ] || echo "INTERVAL=${DEFAULT_INTERVAL}" > "$SYNC_CONF"
}

# 写同步日志(同时回显, 守护进程里仅写文件)
logsync() {
  local msg="$1"
  local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[$ts] $msg" >> "$SYNC_LOG"
  # 控制日志体积: 超过 2000 行裁剪到 1000 行
  local lines; lines=$(wc -l < "$SYNC_LOG" 2>/dev/null || echo 0)
  if [ "$lines" -gt 2000 ]; then
    tail -n 1000 "$SYNC_LOG" > "${SYNC_LOG}.tmp" && mv "${SYNC_LOG}.tmp" "$SYNC_LOG"
  fi
}

# =============================================================
#  安装 realm
# =============================================================
install_realm() {
  if [ -x "$REALM_BIN" ]; then
    echo -e "${Y}realm 已安装,版本: $($REALM_BIN --version 2>/dev/null)${N}"
    return 0
  fi

  echo -e "${B}>>> 开始安装 realm ...${N}"
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64)  FILE="realm-x86_64-unknown-linux-gnu.tar.gz" ;;
    aarch64) FILE="realm-aarch64-unknown-linux-gnu.tar.gz" ;;
    *) echo -e "${R}未知架构 $ARCH,请手动安装${N}"; return 1 ;;
  esac

  GH_PATH="https://github.com/zhboner/realm/releases/latest/download/${FILE}"
  MIRRORS=(
    "https://gh-proxy.com/"
    "https://ghfast.top/"
    "https://gh.ddlc.top/"
    "https://ghproxy.net/"
    ""
  )

  local ok=0
  for prefix in "${MIRRORS[@]}"; do
    local url="${prefix}${GH_PATH}"
    echo -e "${B}>>> 尝试: ${url}${N}"
    if wget --timeout=20 --tries=2 -O /tmp/realm.tar.gz "$url" 2>/dev/null; then
      if tar -tzf /tmp/realm.tar.gz >/dev/null 2>&1; then
        echo -e "${G}>>> 下载成功${N}"; ok=1; break
      fi
    fi
    echo -e "${Y}>>> 该镜像失败,换下一个${N}"
  done

  if [ "$ok" -ne 1 ]; then
    if tar -tzf /tmp/realm.tar.gz >/dev/null 2>&1; then
      echo -e "${Y}>>> 使用已存在的 /tmp/realm.tar.gz${N}"
    else
      echo -e "${R}!!! 所有镜像失败。请手动上传后重试:${N}"
      echo "    本地下载: ${GH_PATH}"
      echo "    上传到机: scp ${FILE} root@本机IP:/tmp/realm.tar.gz"
      return 1
    fi
  fi

  tar -xzf /tmp/realm.tar.gz -C /tmp
  install -m 755 /tmp/realm "$REALM_BIN"
  ensure_files

  # 初始化空配置
  [ -f "$CONF" ] || cat > "$CONF" << 'EOF'
[network]
no_tcp = false
use_udp = true
EOF

  # 写 realm 主服务
  cat > "$SERVICE" << EOF
[Unit]
Description=realm port forwarding
After=network.target

[Service]
ExecStart=${REALM_BIN} -c ${CONF}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable realm >/dev/null 2>&1
  systemctl restart realm
  echo -e "${G}>>> realm 安装完成${N}"

  # 同时安装同步守护服务(默认不启动,等用户添加监控目标后再开)
  install_sync_service
}

# =============================================================
#  根据 rules.db 重建 config.toml 并重启
# =============================================================
rebuild_conf() {
  {
    echo "[network]"
    echo "no_tcp = false"
    echo "use_udp = true"
    echo ""
    while IFS='|' read -r lport rip rport note src; do
      [ -z "$lport" ] && continue
      echo "[[endpoints]]"
      local tag="$note"
      [ -n "$src" ] && [ "$src" != "manual" ] && tag="${note:+$note }[$src]"
      [ -n "$tag" ] && echo "# $tag"
      echo "listen = \"0.0.0.0:${lport}\""
      echo "remote = \"${rip}:${rport}\""
      echo ""
    done < "$RULES"
  } > "$CONF"
  systemctl restart realm 2>/dev/null
}

# =============================================================
#  目标 IP 记忆: 保存(去重)
# =============================================================
remember_ip() {
  local ip="$1" note="$2"
  [ -z "$ip" ] && return
  # 已存在则只在原本无备注、这次有备注时更新备注
  if grep -q "^${ip}|" "$IPS" 2>/dev/null; then
    if [ -n "$note" ]; then
      local old; old=$(grep "^${ip}|" "$IPS" | head -1 | cut -d'|' -f2)
      if [ -z "$old" ]; then
        sed -i "s|^${ip}|.*|${ip}|${note}|" "$IPS"
      fi
    fi
  else
    echo "${ip}|${note}" >> "$IPS"
  fi
}

# 选择目标 IP: 返回值写入全局 PICKED_IP
pick_ip() {
  PICKED_IP=""
  if [ ! -s "$IPS" ]; then
    read -p "目标IP(落地机/B的入口IP): " PICKED_IP
    [ -n "$PICKED_IP" ] && remember_ip "$PICKED_IP" ""
    return
  fi

  echo -e "${B}--- 已记忆的目标IP ---${N}"
  local i=1
  declare -a IP_ARR=()
  while IFS='|' read -r ip note; do
    [ -z "$ip" ] && continue
    IP_ARR+=("$ip")
    printf "  ${G}%-3s${N} %-18s %s\n" "$i" "$ip" "${note:+# $note}"
    i=$((i+1))
  done < "$IPS"
  echo -e "  ${Y}0${N}   彻底新增一个 IP"
  echo ""
  read -p "选择已有IP序号, 或输入0新增: " sel

  if [ "$sel" = "0" ] || [ -z "$sel" ]; then
    read -p "新目标IP: " PICKED_IP
    read -p "该IP备注(可选,如: 日本落地机): " newnote
    [ -n "$PICKED_IP" ] && remember_ip "$PICKED_IP" "$newnote"
  elif [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#IP_ARR[@]}" ]; then
    PICKED_IP="${IP_ARR[$((sel-1))]}"
    echo -e "${G}已选择: ${PICKED_IP}${N}"
  else
    echo -e "${R}无效选择${N}"
    PICKED_IP=""
  fi
}

# =============================================================
#  新增转发
# =============================================================
add_rule() {
  [ -x "$REALM_BIN" ] || { echo -e "${R}请先安装 realm(菜单1)${N}"; return 1; }

  echo -e "${B}=== 新增转发规则 ===${N}"
  read -p "本机监听端口(用户访问的端口): " lport

  # 选择/新增目标 IP
  pick_ip
  local rip="$PICKED_IP"

  read -p "目标端口(B上节点的端口): " rport
  read -p "备注(可选,直接回车跳过,如: TK直播-日本): " note

  if [ -z "$lport" ] || [ -z "$rip" ] || [ -z "$rport" ]; then
    echo -e "${R}端口和目标IP不能为空${N}"; return 1
  fi
  if ! [[ "$lport" =~ ^[0-9]+$ ]] || ! [[ "$rport" =~ ^[0-9]+$ ]]; then
    echo -e "${R}端口必须是数字${N}"; return 1
  fi

  if grep -q "^${lport}|" "$RULES" 2>/dev/null; then
    echo -e "${R}本机端口 ${lport} 已存在转发规则,请先删除或换端口${N}"; return 1
  fi

  echo "${lport}|${rip}|${rport}|${note}|manual" >> "$RULES"
  rebuild_conf

  if command -v ufw >/dev/null; then
    ufw allow "${lport}" >/dev/null 2>&1
  fi

  echo -e "${G}>>> 添加成功!  本机:${lport}  ->  ${rip}:${rport}  ${note:+[$note]}${N}"
}

# =============================================================
#  查看现有转发
# =============================================================
list_rules() {
  echo -e "${B}=== 现有转发规则 ===${N}"
  if [ ! -s "$RULES" ]; then
    echo -e "${Y}(暂无规则)${N}"
    return
  fi
  printf "${P}%-4s %-10s %-22s %-16s %-12s${N}\n" "序号" "本机端口" "目标地址" "备注" "来源"
  echo "------------------------------------------------------------------------------"
  local i=1
  while IFS='|' read -r lport rip rport note src; do
    [ -z "$lport" ] && continue
    local srcshow="$src"
    [ -z "$srcshow" ] && srcshow="manual"
    printf "%-4s %-10s %-22s %-16s %-12s\n" "$i" "$lport" "${rip}:${rport}" "${note:-—}" "$srcshow"
    i=$((i+1))
  done < "$RULES"
}

# =============================================================
#  删除转发
# =============================================================
del_rule() {
  list_rules
  [ ! -s "$RULES" ] && return
  echo ""
  read -p "输入要删除的序号(0取消): " idx
  [ "$idx" = "0" ] && return
  if ! [[ "$idx" =~ ^[0-9]+$ ]]; then echo -e "${R}请输入数字${N}"; return; fi

  local total; total=$(grep -c '^[0-9]' "$RULES")
  if [ "$idx" -lt 1 ] || [ "$idx" -gt "$total" ]; then
    echo -e "${R}序号超出范围${N}"; return
  fi

  local line; line=$(sed -n "${idx}p" "$RULES")
  local dport; dport=$(echo "$line" | cut -d'|' -f1)
  sed -i "${idx}d" "$RULES"
  rebuild_conf
  command -v ufw >/dev/null && ufw delete allow "${dport}" >/dev/null 2>&1
  echo -e "${G}>>> 已删除序号 ${idx} (端口 ${dport})${N}"
}

# =============================================================
#  ============  3x-ui 同步监控部分  ============
# =============================================================

# 检查依赖: 只硬性需要 curl; JSON 解析优先 jq, 没有则用 grep/sed 兜底
check_sync_deps() {
  # curl 是唯一硬依赖(拉取 API)
  if ! command -v curl >/dev/null 2>&1; then
    echo -e "${R}缺少 curl, 尝试自动安装...${N}"
    if command -v apt >/dev/null 2>&1; then
      apt update -y >/dev/null 2>&1; apt install -y curl >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
      yum install -y curl >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y curl >/dev/null 2>&1
    elif command -v apk >/dev/null 2>&1; then
      apk add curl >/dev/null 2>&1
    fi
  fi

  # jq 是可选项: 有则解析更稳, 没有就用兜底
  if ! command -v jq >/dev/null 2>&1; then
    echo -e "${Y}未检测到 jq(可选, 解析更稳)。尝试静默安装, 失败则用 grep 兜底...${N}"
    if command -v apt >/dev/null 2>&1; then
      apt install -y jq >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
      yum install -y jq >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y jq >/dev/null 2>&1
    elif command -v apk >/dev/null 2>&1; then
      apk add jq >/dev/null 2>&1
    fi
    if command -v jq >/dev/null 2>&1; then
      echo -e "${G}>>> jq 已安装${N}"
    else
      echo -e "${Y}>>> 无 jq, 将使用内置 grep/sed 解析(零依赖)${N}"
    fi
  fi

  # 只要有 curl 就算满足
  command -v curl >/dev/null 2>&1
}

# 纯 grep/sed 兜底解析(无 jq 时使用, 零依赖)
# 思路: 先抹掉带转义引号的字符串字段(消除嵌套JSON干扰), 再按 {} 切对象,
#       逐对象排除 enable:false, 抽取 port
# 输入: JSON 文本(stdin)   输出: 每行一个端口
_parse_ports_fallback() {
  sed 's/\\"/\x01/g' \
    | sed 's/"[a-zA-Z_]*":"[^"]*"//g' \
    | sed 's/\x01/"/g' \
    | grep -o '{[^{}]*}' \
    | while read -r obj; do
        echo "$obj" | grep -q '"enable":false' && continue
        local port
        port=$(echo "$obj" | grep -oE '"port":[0-9]+' | grep -oE '[0-9]+')
        [ -n "$port" ] && echo "$port"
      done | sort -n
}

# 从 3x-ui 拉取"启用中"的 inbound 端口列表
# 参数: baseURL token
# 输出: 每行一个端口号; 失败返回非0并在 stderr 给出原因
fetch_inbound_ports() {
  local base="$1" token="$2"
  base="${base%/}"   # 去掉结尾斜杠
  local url="${base}/panel/api/inbounds/list"

  # -k 容忍自签证书; token 走 Bearer 头
  local resp http
  resp=$(curl -sk --max-time 20 \
              -H "Authorization: Bearer ${token}" \
              -H "Accept: application/json" \
              -w $'\n%{http_code}' "$url" 2>/dev/null)
  http=$(echo "$resp" | tail -n1)
  resp=$(echo "$resp" | sed '$d')

  if [ "$http" != "200" ]; then
    echo "HTTP ${http} 访问 ${url} 失败(检查地址/端口/路径/token)" >&2
    return 1
  fi

  # 基本校验: 返回得像 JSON(含 obj 字段或以 { 开头)
  if ! echo "$resp" | grep -q '"obj"' && ! echo "$resp" | grep -q '^\s*{'; then
    echo "返回非预期内容(可能路径错误或被拦截): $(echo "$resp" | head -c 120)" >&2
    return 2
  fi
  # success:false 明确报错
  if echo "$resp" | grep -q '"success":false'; then
    local m; m=$(echo "$resp" | grep -oE '"msg":"[^"]*"' | head -1 | sed 's/"msg":"//; s/"$//')
    echo "API success=false: ${m}" >&2
    return 3
  fi

  # 优先 jq, 否则兜底
  if command -v jq >/dev/null 2>&1; then
    echo "$resp" | jq -r '.obj[]? | select(.enable != false) | .port' 2>/dev/null | grep -E '^[0-9]+$' | sort -n
  else
    echo "$resp" | _parse_ports_fallback
  fi
  return 0
}

# 对单个监控目标执行一次同步
# 参数: name baseURL token rip(转发目标IP) 
#   rip 即 realm 要把流量转去的落地IP(通常就是该3x-ui所在机器的IP)
sync_one_target() {
  local name="$1" base="$2" token="$3" rip="$4"

  local remote_ports
  remote_ports=$(fetch_inbound_ports "$base" "$token" 2>/tmp/sync_err)
  local rc=$?
  if [ $rc -ne 0 ]; then
    logsync "[${name}] 拉取失败: $(cat /tmp/sync_err 2>/dev/null)"
    return 1
  fi

  # 本地属于该监控来源的规则端口
  local src="sync:${name}"
  local local_ports
  local_ports=$(awk -F'|' -v s="$src" '$5==s{print $1}' "$RULES" 2>/dev/null)

  local changed=0

  # --- 新增: 远端有、本地无 ---
  local p
  for p in $remote_ports; do
    if ! echo "$local_ports" | grep -qx "$p"; then
      # 端口被其它规则占用?
      if grep -q "^${p}|" "$RULES" 2>/dev/null; then
        local owner; owner=$(grep "^${p}|" "$RULES" | head -1 | cut -d'|' -f5)
        logsync "[${name}] 新增失败: 本机端口 ${p} 已被来源[${owner}]占用, 跳过"
        continue
      fi
      # 操作系统层面端口是否已被别的进程监听?
      if command -v ss >/dev/null 2>&1 && ss -lntu 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${p}\$"; then
        logsync "[${name}] 新增失败: 本机端口 ${p} 已被系统其它进程监听, 跳过"
        continue
      fi
      echo "${p}|${rip}|${p}|自动同步|${src}" >> "$RULES"
      command -v ufw >/dev/null && ufw allow "${p}" >/dev/null 2>&1
      logsync "[${name}] 新增转发: 本机:${p} -> ${rip}:${p}"
      changed=1
    fi
  done

  # --- 删除: 本地(该来源)有、远端无 ---
  for p in $local_ports; do
    if ! echo "$remote_ports" | grep -qx "$p"; then
      sed -i "\|^${p}|${rip}|${p}|.*|${src}\$|d" "$RULES"
      # 兜底删除(防止特殊字符匹配不到): 按端口+来源删
      awk -F'|' -v s="$src" -v pp="$p" '!($1==pp && $5==s)' "$RULES" > "${RULES}.tmp" && mv "${RULES}.tmp" "$RULES"
      command -v ufw >/dev/null && ufw delete allow "${p}" >/dev/null 2>&1
      logsync "[${name}] 删除转发: 本机端口 ${p}(远端节点已移除)"
      changed=1
    fi
  done

  if [ "$changed" -eq 1 ]; then
    rebuild_conf
    logsync "[${name}] 配置已更新并重启 realm"
  fi
  return 0
}

# 同步所有监控目标(供守护进程 & 手动触发调用)
sync_all() {
  ensure_files
  # 加锁防重入
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    return 0
  fi

  if [ ! -s "$MONITORS" ]; then
    return 0
  fi
  while IFS='|' read -r name base token note; do
    [ -z "$name" ] && continue
    # note 字段里我们复用为"转发落地IP"(见 add_monitor)
    local rip="$note"
    [ -z "$rip" ] && { logsync "[${name}] 缺少落地IP配置, 跳过"; continue; }
    sync_one_target "$name" "$base" "$token" "$rip"
  done < "$MONITORS"

  flock -u 9
}

# 守护进程主循环
daemon_loop() {
  ensure_files
  local interval; interval=$(grep -E '^INTERVAL=' "$SYNC_CONF" 2>/dev/null | cut -d= -f2)
  [[ "$interval" =~ ^[0-9]+$ ]] || interval=$DEFAULT_INTERVAL
  logsync ">>> 同步守护进程启动, 轮询间隔 ${interval}s"
  while true; do
    # 每轮重新读间隔, 支持热修改
    interval=$(grep -E '^INTERVAL=' "$SYNC_CONF" 2>/dev/null | cut -d= -f2)
    [[ "$interval" =~ ^[0-9]+$ ]] || interval=$DEFAULT_INTERVAL
    sync_all
    sleep "$interval"
  done
}

# 安装同步守护 systemd 服务
install_sync_service() {
  cat > "$SYNC_SERVICE" << EOF
[Unit]
Description=realm 3x-ui sync daemon
After=network.target realm.service

[Service]
Type=simple
ExecStart=${SELF_PATH} --daemon
Restart=always
RestartSec=5
# 防止反复崩溃时疯狂重启: 10分钟内最多重启 100 次, 超过则进入失败态
StartLimitIntervalSec=600
StartLimitBurst=100

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

# 新增监控目标
add_monitor() {
  ensure_files
  if ! check_sync_deps; then
    echo -e "${R}缺少 curl 且自动安装失败, 无法使用同步功能${N}"; return 1
  fi

  echo -e "${B}=== 新增 3x-ui 监控目标 ===${N}"
  echo -e "${Y}提示: 需要 3x-ui 3.2.0+ 并已在面板生成 API token${N}"
  read -p "监控名称(自定义, 如 jp-node): " name
  read -p "面板地址(含端口与路径, 如 https://1.2.3.4:2053/abcd): " base
  read -p "API Token: " token
  read -p "转发落地IP(realm 把流量转去的IP, 通常就是该面板服务器IP): " rip

  if [ -z "$name" ] || [ -z "$base" ] || [ -z "$token" ] || [ -z "$rip" ]; then
    echo -e "${R}所有字段均不能为空${N}"; return 1
  fi
  if echo "$name" | grep -q '|'; then echo -e "${R}名称不能含 | 符号${N}"; return 1; fi
  if grep -q "^${name}|" "$MONITORS" 2>/dev/null; then
    echo -e "${R}监控名 ${name} 已存在${N}"; return 1
  fi

  echo -e "${B}>>> 正在测试连接...${N}"
  local ports
  ports=$(fetch_inbound_ports "$base" "$token" 2>/tmp/sync_err)
  if [ $? -ne 0 ]; then
    echo -e "${R}连接/鉴权失败: $(cat /tmp/sync_err)${N}"
    read -p "仍要保存该目标吗? (y/N): " c
    [ "$c" != "y" ] && [ "$c" != "Y" ] && { echo "已取消"; return 1; }
  else
    local cnt; cnt=$(echo "$ports" | grep -c '^[0-9]')
    echo -e "${G}>>> 连接成功! 检测到 ${cnt} 个启用中的节点端口${N}"
  fi

  # 落地IP 存到 note 字段(第4列)
  echo "${name}|${base%/}|${token}|${rip}" >> "$MONITORS"
  remember_ip "$rip" "$name(3x-ui)"
  echo -e "${G}>>> 监控目标已保存${N}"

  # 确保守护服务存在并启动
  install_sync_service
  systemctl enable realm-sync >/dev/null 2>&1
  systemctl restart realm-sync
  echo -e "${G}>>> 同步守护进程已启动(后台 24h 运行, 崩溃自动恢复)${N}"
  echo -e "${B}>>> 立即执行一次同步...${N}"
  sync_all
  echo -e "${G}>>> 完成, 可在菜单查看同步日志${N}"
}

# 查看监控目标
list_monitors() {
  echo -e "${B}=== 监控目标列表 ===${N}"
  if [ ! -s "$MONITORS" ]; then
    echo -e "${Y}(暂无监控目标)${N}"; return
  fi
  printf "${P}%-4s %-12s %-34s %-16s${N}\n" "序号" "名称" "面板地址" "落地IP"
  echo "----------------------------------------------------------------------------"
  local i=1
  while IFS='|' read -r name base token rip; do
    [ -z "$name" ] && continue
    printf "%-4s %-12s %-34s %-16s\n" "$i" "$name" "$base" "$rip"
    i=$((i+1))
  done < "$MONITORS"
}

# 删除监控目标(可选连带删除其同步出来的转发规则)
del_monitor() {
  list_monitors
  [ ! -s "$MONITORS" ] && return
  echo ""
  read -p "输入要删除的监控序号(0取消): " idx
  [ "$idx" = "0" ] && return
  [[ "$idx" =~ ^[0-9]+$ ]] || { echo -e "${R}请输入数字${N}"; return; }

  local total; total=$(grep -c '^[^|]' "$MONITORS")
  [ "$idx" -lt 1 ] || [ "$idx" -gt "$total" ] && { echo -e "${R}序号超出范围${N}"; return; }

  local line; line=$(sed -n "${idx}p" "$MONITORS")
  local name; name=$(echo "$line" | cut -d'|' -f1)

  read -p "是否同时删除该监控自动同步出来的所有转发规则? (y/N): " c
  sed -i "${idx}d" "$MONITORS"

  if [ "$c" = "y" ] || [ "$c" = "Y" ]; then
    local src="sync:${name}"
    # 放行规则回收
    awk -F'|' -v s="$src" '$5==s{print $1}' "$RULES" | while read -r p; do
      command -v ufw >/dev/null && ufw delete allow "${p}" >/dev/null 2>&1
    done
    awk -F'|' -v s="$src" '$5!=s' "$RULES" > "${RULES}.tmp" && mv "${RULES}.tmp" "$RULES"
    rebuild_conf
    logsync "[${name}] 监控目标及其同步规则已删除"
    echo -e "${G}>>> 已删除监控 ${name} 及其同步规则${N}"
  else
    logsync "[${name}] 监控目标已删除(保留已生成的转发规则)"
    echo -e "${G}>>> 已删除监控 ${name}(转发规则保留)${N}"
  fi

  # 若没有监控目标了, 停掉守护
  if [ ! -s "$MONITORS" ]; then
    systemctl stop realm-sync 2>/dev/null
    systemctl disable realm-sync >/dev/null 2>&1
    echo -e "${Y}>>> 已无监控目标, 同步守护进程已停止${N}"
  fi
}

# 立即手动同步一次
sync_now() {
  if [ ! -s "$MONITORS" ]; then
    echo -e "${Y}尚未配置任何监控目标${N}"; return
  fi
  echo -e "${B}>>> 正在同步所有监控目标...${N}"
  sync_all
  echo -e "${G}>>> 同步完成, 详见同步日志${N}"
}

# 查看同步日志
view_sync_log() {
  ensure_files
  echo -e "${B}=== 同步日志 (最近100行) ===${N}"
  if [ ! -s "$SYNC_LOG" ]; then
    echo -e "${Y}(暂无日志)${N}"
  else
    tail -n 100 "$SYNC_LOG"
  fi
  echo ""
  echo -e "${P}1${N}.实时跟踪日志(Ctrl+C退出)  ${P}2${N}.清空日志  ${P}回车${N}.返回"
  read -p "选择: " c
  case "$c" in
    1) echo -e "${B}(Ctrl+C 退出)${N}"; tail -f "$SYNC_LOG" ;;
    2) : > "$SYNC_LOG"; echo -e "${G}已清空${N}"; sleep 1 ;;
    *) : ;;
  esac
}

# 同步设置(轮询间隔 / 守护进程状态)
sync_settings() {
  ensure_files
  local interval; interval=$(grep -E '^INTERVAL=' "$SYNC_CONF" | cut -d= -f2)
  local dstate
  if systemctl is-active --quiet realm-sync 2>/dev/null; then
    dstate="${G}● 运行中${N}"
  else
    dstate="${R}● 已停止${N}"
  fi
  echo -e "${B}=== 同步设置 ===${N}"
  echo -e "  守护进程状态: ${dstate}"
  echo -e "  当前轮询间隔: ${B}${interval}${N} 秒"
  echo ""
  echo -e "  ${G}1${N}. 修改轮询间隔"
  echo -e "  ${G}2${N}. 启动守护进程"
  echo -e "  ${G}3${N}. 停止守护进程"
  echo -e "  ${G}4${N}. 重启守护进程"
  echo -e "  ${G}0${N}. 返回"
  read -p "选择: " c
  case "$c" in
    1) read -p "新的轮询间隔(秒, 建议>=30): " ni
       if [[ "$ni" =~ ^[0-9]+$ ]] && [ "$ni" -ge 5 ]; then
         echo "INTERVAL=${ni}" > "$SYNC_CONF"
         echo -e "${G}已设为 ${ni}s(守护进程下一轮生效)${N}"
       else
         echo -e "${R}无效值${N}"
       fi ;;
    2) install_sync_service; systemctl enable realm-sync >/dev/null 2>&1
       systemctl restart realm-sync; echo -e "${G}已启动${N}" ;;
    3) systemctl stop realm-sync; echo -e "${Y}已停止${N}" ;;
    4) systemctl restart realm-sync; echo -e "${G}已重启${N}" ;;
    *) : ;;
  esac
}

# 同步子菜单
sync_menu() {
  while true; do
    clear
    echo -e "${P}============================================${N}"
    echo -e "${P}        3x-ui 节点同步监控${N}"
    echo -e "${P}============================================${N}"
    local mcnt dstate
    mcnt=$(grep -c '^[^|]' "$MONITORS" 2>/dev/null || echo 0)
    if systemctl is-active --quiet realm-sync 2>/dev/null; then
      dstate="${G}● 运行中${N}"; else dstate="${R}● 已停止${N}"; fi
    echo -e "  监控目标: ${B}${mcnt}${N} 个     守护进程: ${dstate}"
    echo -e "${P}--------------------------------------------${N}"
    echo -e "  ${G}1${N}. 新增监控目标(3x-ui)"
    echo -e "  ${G}2${N}. 查看监控目标"
    echo -e "  ${G}3${N}. 删除监控目标"
    echo -e "  ${G}4${N}. 立即同步一次"
    echo -e "  ${G}5${N}. 查看同步日志"
    echo -e "  ${G}6${N}. 同步设置(间隔/守护)"
    echo -e "  ${G}0${N}. 返回主菜单"
    echo -e "${P}============================================${N}"
    read -p "请输入数字并回车: " opt
    case "$opt" in
      1) add_monitor; pause ;;
      2) list_monitors; pause ;;
      3) del_monitor; pause ;;
      4) sync_now; pause ;;
      5) view_sync_log ;;
      6) sync_settings; pause ;;
      0) return ;;
      *) echo -e "${R}无效选项${N}"; sleep 1 ;;
    esac
  done
}

# =============================================================
#  已记忆 IP 管理
# =============================================================
manage_ips() {
  while true; do
    clear
    echo -e "${B}=== 已记忆的目标IP ===${N}"
    if [ ! -s "$IPS" ]; then
      echo -e "${Y}(暂无)${N}"
    else
      printf "${P}%-4s %-18s %s${N}\n" "序号" "IP" "备注"
      echo "----------------------------------------"
      local i=1
      while IFS='|' read -r ip note; do
        [ -z "$ip" ] && continue
        printf "%-4s %-18s %s\n" "$i" "$ip" "${note:-—}"
        i=$((i+1))
      done < "$IPS"
    fi
    echo ""
    echo -e "  ${G}1${N}. 新增IP  ${G}2${N}. 删除IP  ${G}0${N}. 返回"
    read -p "选择: " c
    case "$c" in
      1) read -p "新IP: " ip; read -p "备注(可选): " nt
         [ -n "$ip" ] && remember_ip "$ip" "$nt" && echo -e "${G}已添加${N}"; sleep 1 ;;
      2) read -p "删除序号(0取消): " idx
         [ "$idx" = "0" ] && continue
         [[ "$idx" =~ ^[0-9]+$ ]] && sed -i "${idx}d" "$IPS" && echo -e "${G}已删除${N}"; sleep 1 ;;
      0) return ;;
      *) : ;;
    esac
  done
}

# =============================================================
#  服务控制
# =============================================================
svc_restart() { systemctl restart realm && echo -e "${G}已重启${N}"; }
svc_stop()    { systemctl stop realm && echo -e "${Y}已停止${N}"; }
svc_start()   { systemctl start realm && echo -e "${G}已启动${N}"; }
svc_log()     { echo -e "${B}(Ctrl+C 退出日志)${N}"; journalctl -u realm -f; }

# =============================================================
#  卸载
# =============================================================
uninstall_all() {
  echo -e "${R}=== 卸载 realm ===${N}"
  read -p "确认卸载?将删除所有转发规则与监控配置 (y/N): " c
  [ "$c" != "y" ] && [ "$c" != "Y" ] && { echo "已取消"; return; }
  systemctl stop realm 2>/dev/null
  systemctl disable realm 2>/dev/null
  systemctl stop realm-sync 2>/dev/null
  systemctl disable realm-sync 2>/dev/null
  rm -f "$SERVICE" "$SYNC_SERVICE"; systemctl daemon-reload
  rm -rf "$REALM_DIR" "$REALM_BIN"
  echo -e "${Y}realm 及全部规则/监控已卸载${N}"
  read -p "是否同时移除 z-ui 快捷命令? (y/N): " c2
  if [ "$c2" = "y" ] || [ "$c2" = "Y" ]; then
    rm -f "$SELF_PATH"
    echo -e "${Y}z-ui 命令已移除${N}"
  fi
}

# =============================================================
#  注册 z-ui 快捷命令
# =============================================================
register_shortcut() {
  local src; src="$(readlink -f "$0")"
  if [ "$src" != "$SELF_PATH" ]; then
    cp -f "$src" "$SELF_PATH"
    chmod +x "$SELF_PATH"
  fi
}

# =============================================================
#  服务状态(显示在菜单顶部)
# =============================================================
show_status() {
  local inst_state svc_state sync_state rule_cnt mon_cnt
  if [ -x "$REALM_BIN" ]; then inst_state="${G}已安装${N}"; else inst_state="${R}未安装${N}"; fi
  if systemctl is-active --quiet realm 2>/dev/null; then
    svc_state="${G}● 运行中${N}"
  else
    svc_state="${R}● 已停止${N}"
  fi
  if systemctl is-active --quiet realm-sync 2>/dev/null; then
    sync_state="${G}● 运行中${N}"
  else
    sync_state="${Y}● 未运行${N}"
  fi
  rule_cnt=$(grep -c '^[0-9]' "$RULES" 2>/dev/null || echo 0)
  mon_cnt=$(grep -c '^[^|]' "$MONITORS" 2>/dev/null || echo 0)

  echo -e "${P}============================================${N}"
  echo -e "${P}        realm 转发管理面板  (z-ui)${N}"
  echo -e "${P}============================================${N}"
  echo -e "  安装状态: ${inst_state}    realm服务: ${svc_state}"
  echo -e "  转发规则: ${B}${rule_cnt}${N} 条     监控目标: ${B}${mon_cnt}${N} 个"
  echo -e "  同步守护: ${sync_state}"
  echo -e "${P}--------------------------------------------${N}"
}

# =============================================================
#  主菜单
# =============================================================
menu() {
  while true; do
    clear
    show_status
    echo -e "  ${G}1${N}. 安装 / 更新 realm"
    echo -e "  ${G}2${N}. 新增转发规则"
    echo -e "  ${G}3${N}. 查看现有转发"
    echo -e "  ${G}4${N}. 删除指定转发"
    echo -e "  ${P}--------------------------------------------${N}"
    echo -e "  ${B}5${N}. ${B}3x-ui 节点同步监控${N} ★"
    echo -e "  ${B}6${N}. 管理已记忆的目标IP"
    echo -e "  ${P}--------------------------------------------${N}"
    echo -e "  ${G}7${N}. 重启 realm 服务"
    echo -e "  ${G}8${N}. 停止 realm 服务"
    echo -e "  ${G}9${N}. 启动 realm 服务"
    echo -e "  ${G}10${N}. 查看 realm 实时日志"
    echo -e "  ${P}--------------------------------------------${N}"
    echo -e "  ${R}11${N}. 卸载 realm"
    echo -e "  ${G}0${N}. 退出面板"
    echo -e "${P}============================================${N}"
    read -p "请输入数字并回车: " opt
    case "$opt" in
      1) install_realm; pause ;;
      2) add_rule; pause ;;
      3) list_rules; pause ;;
      4) del_rule; pause ;;
      5) sync_menu ;;
      6) manage_ips ;;
      7) svc_restart; pause ;;
      8) svc_stop; pause ;;
      9) svc_start; pause ;;
      10) svc_log ;;
      11) uninstall_all; pause ;;
      0) echo "已退出。下次输入 z-ui 再次进入。"; exit 0 ;;
      *) echo -e "${R}无效选项${N}"; sleep 1 ;;
    esac
  done
}

# =============================================================
#  入口
# =============================================================

# 守护进程模式(systemd 调用): 不进菜单, 只跑同步循环
if [ "$1" = "--daemon" ]; then
  daemon_loop
  exit 0
fi
# 供外部/定时器单次触发
if [ "$1" = "--sync-once" ]; then
  sync_all
  exit 0
fi

need_root
register_shortcut
ensure_files

# 首次运行(realm 还没装)→ 默认先执行安装,再进菜单
if [ ! -x "$REALM_BIN" ]; then
  echo -e "${Y}检测到首次运行,开始默认安装 realm...${N}"
  install_realm
  echo ""
  echo -e "${G}安装流程结束。以后随时输入  ${Y}z-ui${G}  即可进入管理面板。${N}"
  pause
fi

# 兼容旧版 rules.db(只有4列, 无来源列)→ 补上 manual 来源
if [ -s "$RULES" ] && ! grep -q '|manual$\|sync:' "$RULES" 2>/dev/null; then
  awk -F'|' 'NF>=3 && $1 ~ /^[0-9]/ {
    src=$5; if(src=="") src="manual";
    print $1"|"$2"|"$3"|"$4"|"src
  }' "$RULES" > "${RULES}.tmp" && mv "${RULES}.tmp" "$RULES"
fi

menu
