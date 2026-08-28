#!/bin/bash

# ==================================================
# 全局自检与 Suixin 专属环境固化
# ==================================================
if [ "$EUID" -ne 0 ]; then
  echo -e "\033[0;31m[!] 请使用 root 账号执行本程序！\033[0m"
  exit 1
fi

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
export DEBIAN_FRONTEND=noninteractive

SCRIPT_BIN="/usr/local/bin/suixin"
GITHUB_URL="https://raw.githubusercontent.com/suixin45/vps/main/install.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if [[ "$0" == *"bash"* ]] || [[ "$0" == *"/dev/fd/"* ]]; then
    clear
    echo -e "${CYAN}[*] 正在安装 Suixin VPS 管理工具...${NC}"
    TMP_FILE=$(mktemp)
    if curl -fsSL --retry 3 --connect-timeout 10 "$GITHUB_URL" -o "$TMP_FILE"; then
        if bash -n "$TMP_FILE"; then
            install -m 0755 "$TMP_FILE" "$SCRIPT_BIN"
            rm -f "$TMP_FILE"
            echo -e "${GREEN}[+] 安装完成！随时在终端输入 ${YELLOW}suixin${GREEN} 即可唤出面板！${NC}"
            sleep 1
            exec "$SCRIPT_BIN" "$@"
            exit 0
        else
            echo -e "${RED}[!] 下载的代码存在语法错误，更新中止！${NC}"
            rm -f "$TMP_FILE"
            exit 1
        fi
    else
        echo -e "${RED}[!] 核心代码拉取失败！${NC}"
        rm -f "$TMP_FILE"
        exit 1
    fi
fi

if ! command -v iptables >/dev/null 2>&1 || ! command -v bc >/dev/null 2>&1; then
    echo -e "${YELLOW}[!] 缺失基础依赖，正在自动安装...${NC}"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y >/dev/null 2>&1 || echo -e "${YELLOW}[!] 软件源更新失败，将尝试继续...${NC}"
        apt-get install -y iptables bc cron openssl >/dev/null 2>&1 || { echo -e "${RED}[!] 依赖安装失败！${NC}"; exit 1; }
    elif command -v yum >/dev/null 2>&1; then
        yum install -y iptables bc cronie openssl >/dev/null 2>&1 || { echo -e "${RED}[!] 依赖安装失败！${NC}"; exit 1; }
    fi
    clear
fi

QUOTA_DIR="/etc/suixin_quota"
DB_FILE="$QUOTA_DIR/users.db"
USAGE_FILE="$QUOTA_DIR/usage.db"
CRON_FILE="/etc/cron.d/suixin_quota"
LOCK_FILE="/var/lock/suixin_quota.lock"

mkdir -p "$QUOTA_DIR"
touch "$DB_FILE" "$USAGE_FILE"

CMDS=("iptables")
if command -v ip6tables >/dev/null 2>&1; then
    CMDS+=("ip6tables")
fi

# ==================================================
# 核心功能函数库
# ==================================================

function detect_233boy_ports() {
    local detected=""
    if [ -d "/etc/sing-box/conf" ]; then
        detected=$(ls /etc/sing-box/conf/*.json 2>/dev/null | grep -oE '[0-9]+' | sort -un | tr '\n' ' ' | sed 's/ $//')
    fi
    echo "$detected"
}

function check_installed() {
    if [ -f "/root/api_server.py" ] && [ -f "/etc/systemd/system/lowsla_api.service" ]; then return 0; else return 1; fi
}

function get_current_config() {
    if check_installed; then
        CUR_PORT=$(grep "^PORT =" /root/api_server.py | awk '{print $3}')
        CUR_TOKEN=$(grep "^TOKEN =" /root/api_server.py | awk -F '"' '{print $2}')
        CUR_LIMIT=$(grep "^TRAFFIC_LIMIT_GB =" /root/api_server.py | awk '{print $3}')
        CUR_DAY=$(grep -i "MonthRotate" /etc/vnstat.conf 2>/dev/null | grep -oE "[0-9]+" | head -n 1)
        [ -z "$CUR_DAY" ] && CUR_DAY="未知"
        if systemctl is-active --quiet lowsla_api.service; then
            STATUS="${GREEN}运行中${NC}"
        else
            STATUS="${RED}已停止${NC}"
        fi
    fi
}

function show_header() {
    clear
    echo -e "======================================================"
    echo -e "                 Suixin VPS 管理工具                  "
    echo -e "======================================================"
    
    local rule_count=$(grep -c "." "$DB_FILE" 2>/dev/null || echo "0")
    
    if check_installed; then
        get_current_config
        echo -e " API 服务：${STATUS}             监听端口：${CUR_PORT}"
        echo -e " 限额规则：${rule_count} 条                 API 重置日：每月 ${CUR_DAY} 日"
    else
        echo -e " API 服务：${RED}未安装${NC}               监听端口：未设置"
        echo -e " 限额规则：${rule_count} 条                 API 重置日：未设置"
    fi
    echo -e "======================================================"
}

function format_flow() {
    local b=$1
    if [ "$(echo "$b < 1073741824" | bc)" -eq 1 ]; then
        echo "$(echo "scale=2; $b/1048576" | bc) MB"
    else
        echo "$(echo "scale=2; $b/1073741824" | bc) GB"
    fi
}

function update_quota_cron() {
    cat << CRON > "$CRON_FILE"
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
@reboot root bash $SCRIPT_BIN restore_rules >/dev/null 2>&1
*/3 * * * * root bash $SCRIPT_BIN cron_check >/dev/null 2>&1
0 0 * * * root bash $SCRIPT_BIN cron_reset_daily >/dev/null 2>&1
CRON
    systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null
}

function clear_user_iptables() {
    local ports=$1
    for p in $ports; do
        for CMD in "${CMDS[@]}"; do
            for proto in tcp udp; do
                while $CMD -D INPUT -p $proto --dport $p -j "SB_${p}" 2>/dev/null; do :; done
                while $CMD -D OUTPUT -p $proto --sport $p -j "SB_${p}" 2>/dev/null; do :; done
            done
            $CMD -F "SB_${p}" 2>/dev/null
            $CMD -X "SB_${p}" 2>/dev/null
        done
    done
}

function restore_rules() {
    (
        flock -n 200 || exit 0
        [ ! -f "$DB_FILE" ] && exit 0
        while IFS="|" read -r uname ulimit ureset uports; do
            [ -z "$uname" ] && continue
            for p in $uports; do
                for CMD in "${CMDS[@]}"; do
                    $CMD -N "SB_${p}" 2>/dev/null || true
                    $CMD -C "SB_${p}" -j RETURN 2>/dev/null || $CMD -A "SB_${p}" -j RETURN
                    for proto in tcp udp; do
                        $CMD -C INPUT -p $proto --dport $p -j "SB_${p}" 2>/dev/null || $CMD -I INPUT -p $proto --dport $p -j "SB_${p}"
                        $CMD -C OUTPUT -p $proto --sport $p -j "SB_${p}" 2>/dev/null || $CMD -I OUTPUT -p $proto --sport $p -j "SB_${p}"
                    done
                done
            done
            local saved_bytes=$(grep "^${uname}|" "$USAGE_FILE" | cut -d'|' -f2)
            saved_bytes=${saved_bytes:-0}
            local used_gb=$(echo "scale=4; $saved_bytes/1073741824" | bc)
            if [ "$(echo "$used_gb >= $ulimit" | bc)" -eq 1 ]; then
                for p in $uports; do
                    for CMD in "${CMDS[@]}"; do
                        $CMD -C "SB_${p}" -j DROP 2>/dev/null || $CMD -I "SB_${p}" 1 -j DROP
                    done
                done
            fi
        done < "$DB_FILE"
    ) 200>"$LOCK_FILE"
}

function do_install() {
    echo -e "\n${CYAN}[*] 开始安装 / 重装 API 服务...${NC}"
    DEF_PORT=${CUR_PORT:-45466}
    DEF_TOKEN=${CUR_TOKEN:-2b945047371c4d0c}
    DEF_LIMIT=${CUR_LIMIT:-1000}
    DEF_DAY=${CUR_DAY:-1}

    read -p " [?] 请输入 API 监听端口 [默认 ${DEF_PORT}]: " INPUT_PORT
    PORT=${INPUT_PORT:-$DEF_PORT}
    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
        echo -e "${RED}[!] 端口必须是 1-65535 的数字！${NC}" && sleep 2 && return
    fi

    read -p " [?] 请输入鉴权 Token [默认 ${DEF_TOKEN}，输入 r 随机生成]: " INPUT_TOKEN
    if [ "$INPUT_TOKEN" = "r" ] || [ "$INPUT_TOKEN" = "R" ]; then
        if command -v openssl >/dev/null 2>&1; then
            TOKEN=$(openssl rand -hex 16)
        else
            echo -e "${RED}[!] 系统未安装 openssl，无法生成随机 Token！${NC}"
            sleep 2
            return
        fi
    else
        TOKEN=${INPUT_TOKEN:-$DEF_TOKEN}
    fi
    if ! [[ "$TOKEN" =~ ^[A-Za-z0-9_-]+$ ]]; then
        echo -e "${RED}[!] Token 仅限字母、数字、下划线和短横线！${NC}" && sleep 2 && return
    fi

    read -p " [?] 请输入流量额度 (GB) [默认 ${DEF_LIMIT}]: " INPUT_LIMIT
    LIMIT=${INPUT_LIMIT:-$DEF_LIMIT}
    if ! [[ "$LIMIT" =~ ^[0-9]+$ ]] || [ "$LIMIT" -lt 1 ]; then
        echo -e "${RED}[!] 额度必须是大于 0 的整数！${NC}" && sleep 2 && return
    fi

    read -p " [?] 请输入自动重置日 (1-28) [默认 ${DEF_DAY}]: " INPUT_DAY
    RESET_DAY=${INPUT_DAY:-$DEF_DAY}
    if ! [[ "$RESET_DAY" =~ ^[1-9]$|^1[0-9]$|^2[0-8]$ ]]; then
        echo -e "${RED}[!] 日期必须是 1-28 的数字！${NC}" && sleep 2 && return
    fi

    echo -e "\n[*] 正在配置环境..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get install -y vnstat python3 curl openssl >/dev/null 2>&1 || { echo -e "${RED}[!] 依赖组件安装失败！${NC}"; exit 1; }
    else
        yum install -y vnstat python3 curl openssl >/dev/null 2>&1 || { echo -e "${RED}[!] 依赖组件安装失败！${NC}"; exit 1; }
    fi

    sed -i -E "s/^[#;]*\s*MonthRotate.*/MonthRotate ${RESET_DAY}/g" /etc/vnstat.conf
    systemctl restart vnstat

    cat << 'EOF' > /root/api_server.py
import http.server
import json
import socketserver
import subprocess
import urllib.request

PORT = __PORT__
TOKEN = "__TOKEN__"
TRAFFIC_LIMIT_GB = __LIMIT__

try:
    req = urllib.request.Request("http://v4.ident.me", headers={'User-Agent': 'Mozilla/5.0'})
    PUBLIC_IP = urllib.request.urlopen(req, timeout=5).read().decode('utf-8').strip()
except Exception:
    PUBLIC_IP = "IP获取中..."

class APIHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.headers.get('X-Container-Hash') != TOKEN:
            self.send_error(403, "Forbidden")
            return
        self.send_response(200)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.end_headers()
        usage_gb = 0
        try:
            out = subprocess.check_output(["vnstat", "--json", "m"]).decode('utf-8')
            v_data = json.loads(out)
            for interface in v_data.get('interfaces', []):
                months = interface.get('traffic', {}).get('month', [])
                if months:
                    latest_month = months[-1]
                    usage_gb += (latest_month['rx'] + latest_month['tx']) / (1024 ** 3)
        except Exception: pass 
        response = {"data": {"traffic_limit": TRAFFIC_LIMIT_GB, "traffic_usage_raw": round(usage_gb, 4), "ipv4": [PUBLIC_IP], "ipv6": []}}
        self.wfile.write(json.dumps(response).encode('utf-8'))

class DualStackServer(socketserver.TCPServer):
    address_family = __import__('socket').AF_INET6
    allow_reuse_address = True

if __name__ == "__main__":
    with DualStackServer(("::", PORT), APIHandler) as httpd:
        httpd.serve_forever()
EOF

    sed -i "s/__PORT__/${PORT}/g" /root/api_server.py
    sed -i "s/__TOKEN__/${TOKEN}/g" /root/api_server.py
    sed -i "s/__LIMIT__/${LIMIT}/g" /root/api_server.py

    cat << 'EOF' > /etc/systemd/system/lowsla_api.service
[Unit]
Description=Custom Traffic API Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root
ExecStart=/usr/bin/python3 /root/api_server.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable lowsla_api.service >/dev/null 2>&1
    if systemctl restart lowsla_api.service; then
        IPV4=$(curl -s4 v4.ident.me 2>/dev/null)
        echo -e "${GREEN}[+] API 服务安装完成！${NC}"
        echo -e "    通信地址: ${YELLOW}http://${IPV4}:${PORT}/api/container/info${NC}"
        echo -e "    鉴权 Token: ${YELLOW}${TOKEN}${NC}"
    else
        echo -e "${RED}[!] API 服务启动失败！${NC}"
        exit 1
    fi
    echo -n -e "\n请按回车键继续..."
    read
}

function do_test_api() {
    if ! check_installed; then echo -e "\n${RED}[!] 未安装 API 服务！${NC}" && sleep 1 && return; fi
    echo -e "\n${CYAN}[*] 正在测试本地 API...${NC}"
    get_current_config
    RESULT=$(curl -s --max-time 3 -H "X-Container-Hash: ${CUR_TOKEN}" http://127.0.0.1:${CUR_PORT})
    if [ -z "$RESULT" ]; then 
        echo -e "${RED}[!] 请求失败！${NC}"
    else 
        echo -e "${GREEN}[+] API 返回结果：${NC}"
        if echo "$RESULT" | grep -q '^{'; then
            echo "$RESULT" | python3 -m json.tool
        else
            echo "$RESULT"
        fi
    fi
    echo -n -e "\n请按回车键继续..."
    read
}

function do_check_vnstat() {
    echo -e "\n${CYAN}[*] 正在拉取 vnStat 流量报表...${NC}\n"
    if command -v vnstat >/dev/null 2>&1; then 
        vnstat -m | sed -e 's/   month        rx      /    月份          下行  /g' -e 's/       tx      /      上行     /g' -e 's/    total    /    总计     /g' -e 's/   avg. rate/   平均速率 /g' -e 's/estimated/预估消耗 /g' -e 's/monthly/月统计报表/g'
    else 
        echo -e "${RED}[!] 未安装 vnStat！${NC}"
    fi
    echo -n -e "\n请按回车键继续..."
    read
}

function do_uninstall() {
    if ! check_installed; then echo -e "\n${RED}[!] 未安装 API 服务！${NC}" && sleep 1 && return; fi
    read -p " [?] 确定卸载 API 服务？[y/N]: " UNINSTALL_CONFIRM
    if [[ "$UNINSTALL_CONFIRM" =~ ^[Yy]$ ]]; then
        systemctl stop lowsla_api.service >/dev/null 2>&1
        systemctl disable lowsla_api.service >/dev/null 2>&1
        rm -f /etc/systemd/system/lowsla_api.service /root/api_server.py
        systemctl daemon-reload
        echo -e "${GREEN}[+] 卸载完成！${NC}"
    fi
    echo -n -e "\n请按回车键继续..."
    read
}

function quota_manage_user() {
    clear
    echo -e "${CYAN}======================================================"
    echo -e "                 管理流量限额规则                     "
    echo -e "======================================================${NC}"
    
    local action=""
    if [ ! -s "$DB_FILE" ]; then
        echo -e "${YELLOW}[!] 当前无规则，请新增规则。${NC}\n"
        action="add"
    else
        echo -e "[*] 已有流量规则："
        echo -e "------------------------------------------------------"
        local count=0
        declare -A USER_MAP
        while IFS="|" read -r u limit reset ports; do
            [ -z "$u" ] && continue
            ((count++))
            USER_MAP[$count]="$u"
            echo -e "  [${CYAN}${count}${NC}] 规则名称: ${YELLOW}${u}${NC} | 限额: ${limit}GB | 端口: ${ports}"
        done < "$DB_FILE"
        echo -e "------------------------------------------------------"
        read -p " [?] 请选择 [1: 新增规则, 2: 修改规则, 3: 删除规则, 0: 返回]: " choice
        case $choice in
            1) action="add" ;;
            2) action="modify" ;;
            3) action="delete" ;;
            0) return ;;
            *) echo -e "${RED}[!] 无效指令！${NC}" && sleep 1 && return ;;
        esac
    fi

    local uname=""
    local default_limit="500"
    local default_ports=""
    local default_reset="1"

    if [ "$action" == "delete" ]; then
        echo ""
        read -p " [?] 请输入要删除的序号 [1-${count}]: " sel_idx
        uname="${USER_MAP[$sel_idx]}"
        if [ -z "$uname" ]; then
            echo -e "${RED}[!] 找不到序号对应的规则！${NC}" && sleep 1 && return
        fi
        
        read -p " [?] 确定删除规则 ${uname}? [y/N]: " del_conf
        if [[ ! "$del_conf" =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}[*] 已取消删除。${NC}"
            sleep 1
            return
        fi

        echo -e " [*] 已选中: ${YELLOW}${uname}${NC}"
        default_ports=$(grep "^${uname}|" "$DB_FILE" | cut -d'|' -f4)
        
        (
            flock -x 200 || { echo -e "${RED}[!] 系统忙碌，请稍后再试！${NC}"; exit 1; }
            clear_user_iptables "$default_ports"
            sed -i "/^${uname}|/d" "$DB_FILE"
            sed -i "/^${uname}|/d" "$USAGE_FILE"
        ) 200>"$LOCK_FILE"
        update_quota_cron
        echo -e "${GREEN}[+] 规则名称 ${YELLOW}${uname}${GREEN} 已删除！${NC}"
        sleep 2
        return
    elif [ "$action" == "add" ]; then
        while true; do
            read -p " [?] 设定新规则名称 (如 suixin): " uname
            if ! [[ "$uname" =~ ^[A-Za-z0-9_-]{1,32}$ ]]; then
                echo -e "${RED}[!] 规则名称只能包含字母、数字、下划线和短横线！${NC}"
                sleep 2
                continue
            fi
            if grep -q "^${uname}|" "$DB_FILE"; then
                echo -e "${RED}[!] 该规则名称已存在！${NC}"
                continue
            fi
            break
        done
    elif [ "$action" == "modify" ]; then
        echo ""
        read -p " [?] 请输入要修改的序号 [1-${count}]: " sel_idx
        uname="${USER_MAP[$sel_idx]}"
        if [ -z "$uname" ]; then
            echo -e "${RED}[!] 找不到序号对应的规则！${NC}" && sleep 1 && return
        fi
        echo -e " [*] 已选中: ${YELLOW}${uname}${NC}"
        default_limit=$(grep "^${uname}|" "$DB_FILE" | cut -d'|' -f2)
        default_reset=$(grep "^${uname}|" "$DB_FILE" | cut -d'|' -f3)
        default_ports=$(grep "^${uname}|" "$DB_FILE" | cut -d'|' -f4)
    fi

    echo -e "\n--- 参数设定 ---"
    read -p " [?] 每月流量限额 (GB) [当前: ${default_limit}]: " ulimit
    ulimit=${ulimit:-$default_limit}
    if ! [[ "$ulimit" =~ ^[0-9]+$ ]] || [ "$ulimit" -lt 1 ]; then echo -e "${RED}[!] 限额必须为大于 0 的整数！${NC}" && sleep 2 && return; fi

    local auto_ports=($(detect_233boy_ports))
    local uports=""
    if [ ${#auto_ports[@]} -gt 0 ]; then
        echo -e " [*] 发现活跃端口，请选择绑定："
        for i in "${!auto_ports[@]}"; do
            echo -e "     [$(($i+1))] 端口: ${auto_ports[$i]}"
        done
        echo -e "     (当前端口: ${default_ports:-无})"
        read -p " [?] 请输入序号 (空格多选，直接回车默认全选): " port_sel
        if [ -z "$port_sel" ]; then
            if [ -n "$default_ports" ] && [ "$action" == "modify" ]; then
                uports="$default_ports"
            else
                uports="${auto_ports[*]}"
            fi
        else
            for sel in $port_sel; do
                if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -le "${#auto_ports[@]}" ] && [ "$sel" -gt 0 ]; then
                    uports="$uports ${auto_ports[$(($sel-1))]}"
                else
                    uports="$uports $sel"
                fi
            done
            uports=$(echo $uports | xargs)
        fi
    else
        read -p " [?] 绑定端口 (空格分隔) [当前端口: ${default_ports:-空}]: " uports
        uports=${uports:-$default_ports}
    fi
    
    if [ -z "$uports" ]; then echo -e "${RED}[!] 必须绑定端口！${NC}" && sleep 2 && return; fi

    for p in $uports; do
        if ! [[ "$p" =~ ^[0-9]+$ ]] || [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
            echo -e "${RED}[!] 端口 $p 格式非法，必须是 1-65535！${NC}" && sleep 2 && return
        fi
        if awk -F'|' -v p="$p" -v act="$action" -v uname="$uname" '
            BEGIN { conflict=0 }
            {
                if (act == "modify" && $1 == uname) next;
                split($4, ports);
                for (i in ports) {
                    if (ports[i] == p) { conflict=1; exit }
                }
            }
            END { exit !conflict }
        ' "$DB_FILE"; then
            echo -e "${RED}[!] 冲突：端口 $p 已被其他规则绑定！${NC}"
            sleep 3
            return
        fi
    done

    read -p " [?] 每月重置日 (1-28) [当前: ${default_reset}]: " ureset
    ureset=${ureset:-$default_reset}
    if ! [[ "$ureset" =~ ^[1-9]$|^1[0-9]$|^2[0-8]$ ]]; then echo -e "${RED}[!] 日期不合规！${NC}" && sleep 2 && return; fi

    (
        flock -x 200 || { echo -e "${RED}[!] 系统忙碌，请稍后再试！${NC}"; exit 1; }
        if [ "$action" == "modify" ]; then
            clear_user_iptables "$default_ports"
            sed -i "/^${uname}|/d" "$DB_FILE"
        fi
        echo "${uname}|${ulimit}|${ureset}|${uports}" >> "$DB_FILE"
        if ! grep -q "^${uname}|" "$USAGE_FILE"; then echo "${uname}|0" >> "$USAGE_FILE"; fi
        for p in $uports; do
            for CMD in "${CMDS[@]}"; do
                $CMD -N "SB_${p}" 2>/dev/null || true
                $CMD -C "SB_${p}" -j RETURN 2>/dev/null || $CMD -A "SB_${p}" -j RETURN
                for proto in tcp udp; do
                    $CMD -C INPUT -p $proto --dport $p -j "SB_${p}" 2>/dev/null || $CMD -I INPUT -p $proto --dport $p -j "SB_${p}"
                    $CMD -C OUTPUT -p $proto --sport $p -j "SB_${p}" 2>/dev/null || $CMD -I OUTPUT -p $proto --sport $p -j "SB_${p}"
                done
                $CMD -Z "SB_${p}" 2>/dev/null
            done
        done
    ) 200>"$LOCK_FILE"

    update_quota_cron
    echo -e "${GREEN}[+] 规则 ${YELLOW}${uname}${GREEN} 部署完成！${NC}"
    sleep 2
}

function quota_show_dashboard() {
    clear
    echo -e "======================================================"
    echo -e "                 查看流量限额状态                     "
    echo -e "======================================================"
    
    if [ ! -s "$DB_FILE" ]; then
        echo -e "${YELLOW}[!] 暂无流量规则。${NC}"
    else
        (
            flock -s 200 || exit 0
            local count=0
            while IFS="|" read -r uname ulimit ureset uports; do
                [ -z "$uname" ] && continue
                ((count++))
                local delta_bytes=0
                for p in $uports; do
                    for CMD in "${CMDS[@]}"; do
                        local b=$(${CMD}-save -c 2>/dev/null | grep -E "\-A SB_${p}\b" | awk -F'[:\\]]' '{sum+=$2} END {print sum+0}')
                        delta_bytes=$((delta_bytes + b))
                    done
                done
                
                local saved_bytes=$(grep "^${uname}|" "$USAGE_FILE" | cut -d'|' -f2)
                saved_bytes=${saved_bytes:-0}
                local total_bytes=$((saved_bytes + delta_bytes))
                local limit_bytes=$(echo "$ulimit * 1073741824" | bc)
                
                local remain_bytes=$((limit_bytes - total_bytes))
                if [ "$remain_bytes" -lt 0 ]; then remain_bytes=0; fi
                
                local used_str=$(format_flow "$total_bytes")
                local remain_str=$(format_flow "$remain_bytes")
                
                local status="${GREEN}正常${NC}"
                local first_port=$(echo $uports | awk '{print $1}')
                
                if iptables -C "SB_${first_port}" -j DROP 2>/dev/null || ip6tables -C "SB_${first_port}" -j DROP 2>/dev/null; then
                    status="${RED}已限制${NC}"
                fi
                
                echo -e " [${CYAN}${count}${NC}] ${YELLOW}${uname}${NC}"
                echo -e "     限额: ${ulimit} GB"
                echo -e "     已用: ${used_str}"
                echo -e "     剩余: ${remain_str}"
                echo -e "     状态: ${status}"
                echo -e "     端口: ${uports}"
                echo -e "     重置: 每月 ${ureset} 日"
                echo -e "------------------------------------------------------"
            done < "$DB_FILE"
        ) 200>"$LOCK_FILE"
    fi
    echo -n -e "请按回车键继续..."
    read
}

function quota_force_reset() {
    clear
    echo -e "${CYAN}======================================================"
    echo -e "                 重置流量并解除限制                   "
    echo -e "======================================================${NC}"
    if [ ! -s "$DB_FILE" ]; then
        echo -e "${YELLOW}[!] 暂无流量规则。${NC}" && sleep 2 && return
    fi
    
    echo -e "[*] 已有规则列表："
    local count=0
    declare -A USER_MAP
    while IFS="|" read -r u _ _ _; do
        [ -z "$u" ] && continue
        ((count++))
        USER_MAP[$count]="$u"
        echo -e "  [${CYAN}${count}${NC}] 规则名称: ${YELLOW}${u}${NC}"
    done < "$DB_FILE"
    echo ""

    read -p " [?] 请输入要重置的序号 [1-${count}]: " sel_idx
    local rname="${USER_MAP[$sel_idx]}"
    if [ -z "$rname" ]; then
        echo -e "${RED}[!] 找不到对应规则！${NC}" && sleep 1 && return
    fi
    
    (
        flock -x 200 || { echo -e "${RED}[!] 系统忙碌，请稍后再试！${NC}"; exit 1; }
        sed -i "/^${rname}|/d" "$USAGE_FILE"
        echo "${rname}|0" >> "$USAGE_FILE"
        
        ports=$(grep "^${rname}|" "$DB_FILE" | cut -d'|' -f4)
        for p in $ports; do
            for CMD in "${CMDS[@]}"; do
                $CMD -Z "SB_${p}" 2>/dev/null || true
                while $CMD -D "SB_${p}" -j DROP 2>/dev/null; do :; done
            done
        done
    ) 200>"$LOCK_FILE"
    
    echo -e "${GREEN}[+] 规则名称 ${YELLOW}${rname}${GREEN} 已重置流量并解除限制！${NC}"
    sleep 2
}

function cron_check() {
    (
        flock -n 200 || exit 0
        if ! command -v bc >/dev/null 2>&1 || [ ! -f "$DB_FILE" ]; then exit 0; fi

        while IFS="|" read -r uname ulimit ureset uports; do
            [ -z "$uname" ] && continue
            local delta_bytes=0
            for p in $uports; do
                for CMD in "${CMDS[@]}"; do
                    local b=$(${CMD}-save -c 2>/dev/null | grep -E "\-A SB_${p}\b" | awk -F'[:\\]]' '{sum+=$2} END {print sum+0}')
                    delta_bytes=$((delta_bytes + b))
                    $CMD -Z "SB_${p}" 2>/dev/null
                done
            done
            
            local saved_bytes=$(grep "^${uname}|" "$USAGE_FILE" | cut -d'|' -f2)
            saved_bytes=${saved_bytes:-0}
            local new_total=$((saved_bytes + delta_bytes))
            sed -i "/^${uname}|/d" "$USAGE_FILE"
            echo "${uname}|${new_total}" >> "$USAGE_FILE"
            
            local used_gb=$(echo "scale=4; $new_total/1073741824" | bc)
            if [ "$(echo "$used_gb >= $ulimit" | bc)" -eq 1 ]; then
                for p in $uports; do
                    for CMD in "${CMDS[@]}"; do
                        $CMD -C "SB_${p}" -j DROP 2>/dev/null || $CMD -I "SB_${p}" 1 -j DROP
                    done
                done
            fi
        done < "$DB_FILE"
    ) 200>"$LOCK_FILE"
}

function cron_reset_daily() {
    (
        flock -n 200 || exit 0
        [ ! -f "$DB_FILE" ] && exit 0
        local today=$(date +%d)
        today=$((10#$today))
        
        while IFS="|" read -r uname ulimit ureset uports; do
            [ -z "$uname" ] && continue
            if [ "$today" -eq "$ureset" ]; then
                sed -i "/^${uname}|/d" "$USAGE_FILE"
                echo "${uname}|0" >> "$USAGE_FILE"
                for p in $uports; do
                    for CMD in "${CMDS[@]}"; do
                        $CMD -Z "SB_${p}" 2>/dev/null || true
                        while $CMD -D "SB_${p}" -j DROP 2>/dev/null; do :; done
                    done
                done
            fi
        done < "$DB_FILE"
    ) 200>"$LOCK_FILE"
}

if [ "$1" == "restore_rules" ]; then restore_rules; exit 0; fi
if [ "$1" == "cron_check" ]; then cron_check; exit 0; fi
if [ "$1" == "cron_reset_daily" ]; then cron_reset_daily; exit 0; fi

while true; do
    show_header
    echo -e " API 服务"
    echo -e "  1. 安装 / 重装 API 服务"
    echo -e "  2. 测试本地 API"
    echo -e "  3. 查看 vnStat 流量报表"
    echo -e "  4. 停止 API 服务"
    echo -e "  5. 启动 API 服务"
    echo -e "  6. 卸载 API 服务"
    echo -e ""
    echo -e " 流量限额"
    echo -e "  7. 管理流量限额规则"
    echo -e "  8. 查看流量限额状态"
    echo -e "  9. 重置流量并解除限制"
    echo -e ""
    echo -e " 扩展工具"
    echo -e "  10. 检测 IP 质量"
    echo -e "  11. 安装 Sing-Box"
    echo -e "  12. 安装 WARP"
    echo -e ""
    echo -e "  0. 退出"
    echo -e "------------------------------------------------------"
    read -p " 请选择 [0-12]: " OPTION

    case $OPTION in
        1) do_install ;;
        2) do_test_api ;;
        3) do_check_vnstat ;;
        4) 
            if systemctl stop lowsla_api.service >/dev/null 2>&1; then
                echo -e "${GREEN}[+] API 服务已停止！${NC}"
            else
                echo -e "${RED}[!] API 服务停止失败！${NC}"
            fi
            sleep 1 ;;
        5) 
            if systemctl start lowsla_api.service >/dev/null 2>&1; then
                echo -e "${GREEN}[+] API 服务已启动！${NC}"
            else
                echo -e "${RED}[!] API 服务启动失败！${NC}"
            fi
            sleep 1 ;;
        6) do_uninstall ;;
        7) quota_manage_user ;;
        8) quota_show_dashboard ;;
        9) quota_force_reset ;;
        10) 
            echo -e "\n${CYAN}[*] 正在启动 IP 质量检测 (Check.Place)...${NC}"
            bash <(curl -Ls https://Check.Place) -I
            echo -n -e "\n请按回车键继续..."
            read
            ;;
        11) 
            echo -e "\n${CYAN}[*] 正在安装 Sing-Box...${NC}"
            bash <(wget -qO- -o- https://github.com/233boy/sing-box/raw/main/install.sh)
            echo -n -e "\n请按回车键继续..."
            read
            ;;
        12) 
            echo -e "\n${CYAN}[*] 正在安装 WARP...${NC}"
            bash <(curl -fsSL https://vpszdm.com/warp-google.sh)
            echo -n -e "\n请按回车键继续..."
            read
            ;;
        0) clear; echo -e "${GREEN}[+] 已退出 Suixin${NC}"; exit 0 ;;
        *) echo -e "${RED}[!] 无效选项，请重新输入！${NC} "; sleep 1 ;;
    esac
done
