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
    echo -e "${CYAN}[*] 正在安装 Suixin VPS 工具箱...${NC}"
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
        apt-get update -y >/dev/null 2>&1
        apt-get install -y iptables bc cron openssl ss >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y iptables bc cronie openssl iproute >/dev/null 2>&1
    fi
    clear
fi

# ==================================================
# 核心功能函数库
# ==================================================

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
    echo -e "                  Suixin VPS 工具箱                   "
    echo -e "======================================================"
    
    if check_installed; then
        get_current_config
        echo -e " 流量 API：${STATUS}"
        echo -e " 监听端口：${CUR_PORT}"
        echo -e " 流量额度：${CUR_LIMIT} GB"
        echo -e " 账单重置：每月 ${CUR_DAY} 日"
    else
        echo -e " 流量 API：${RED}未安装${NC}"
    fi
    echo -e "======================================================"
}

function do_install() {
    echo -e "\n${CYAN}[*] 开始安装 / 重装 API 服务...${NC}"
    DEF_PORT=${CUR_PORT:-45466}
    DEF_TOKEN=${CUR_TOKEN:-2b945047371c4d0c}
    DEF_LIMIT=${CUR_LIMIT:-1000}
    DEF_DAY=${CUR_DAY:-1}

    # 为了防止端口检测误报，安装前先平滑停止旧服务
    if check_installed; then
        systemctl stop lowsla_api.service 2>/dev/null
    fi

    read -p " [?] 请输入 API 监听端口 [默认 ${DEF_PORT}]: " INPUT_PORT
    PORT=${INPUT_PORT:-$DEF_PORT}
    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
        echo -e "${RED}[!] 端口必须是 1-65535 的数字！${NC}" && sleep 2 && return
    fi
    
    # 底层强化：严格探测端口是否被其他程序（如 Nginx）抢占
    if command -v ss >/dev/null 2>&1; then
        if ss -tuln | grep -q ":$PORT "; then
            echo -e "${RED}[!] 端口 $PORT 已被其他服务占用，请更换端口！${NC}"
            sleep 2; return
        fi
    fi

    read -p " [?] 请输入鉴权 Token [默认 ${DEF_TOKEN}，输入 r 随机生成]: " INPUT_TOKEN
    if [ "$INPUT_TOKEN" = "r" ] || [ "$INPUT_TOKEN" = "R" ]; then
        if command -v openssl >/dev/null 2>&1; then
            TOKEN=$(openssl rand -hex 16)
        else
            echo -e "${RED}[!] 系统未安装 openssl，无法生成随机 Token！${NC}"
            sleep 2; return
        fi
    else
        TOKEN=${INPUT_TOKEN:-$DEF_TOKEN}
    fi
    if ! [[ "$TOKEN" =~ ^[A-Za-z0-9_-]+$ ]]; then
        echo -e "${RED}[!] Token 仅限字母、数字、下划线和短横线！${NC}" && sleep 2 && return
    fi

    read -p " [?] 请输入总流量额度 (GB) [默认 ${DEF_LIMIT}]: " INPUT_LIMIT
    LIMIT=${INPUT_LIMIT:-$DEF_LIMIT}
    if ! [[ "$LIMIT" =~ ^[0-9]+$ ]] || [ "$LIMIT" -lt 1 ]; then
        echo -e "${RED}[!] 额度必须是大于 0 的整数！${NC}" && sleep 2 && return
    fi

    read -p " [?] 请输入每月账单重置日 (1-28) [默认 ${DEF_DAY}]: " INPUT_DAY
    RESET_DAY=${INPUT_DAY:-$DEF_DAY}
    if ! [[ "$RESET_DAY" =~ ^[1-9]$|^1[0-9]$|^2[0-8]$ ]]; then
        echo -e "${RED}[!] 日期必须是 1-28 的数字！${NC}" && sleep 2 && return
    fi

    echo -e "\n[*] 正在配置环境..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get install -y vnstat python3 curl openssl >/dev/null 2>&1 || { echo -e "${RED}[!] 依赖安装失败！${NC}"; exit 1; }
    else
        yum install -y vnstat python3 curl openssl >/dev/null 2>&1 || { echo -e "${RED}[!] 依赖安装失败！${NC}"; exit 1; }
    fi

    # 关键：彻底对齐商家的账单日周期
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
        # 底层强化：增加最大请求超时，防止在死锁 IP 上无限转圈
        IPV4=$(curl -s4 --max-time 3 v4.ident.me 2>/dev/null)
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

function show_connection_info() {
    if ! check_installed; then echo -e "\n${RED}[!] 未安装 API 服务！${NC}" && sleep 1 && return; fi
    get_current_config
    echo -e "\n${CYAN}[*] 正在获取公网环境...${NC}"
    IPV4=$(curl -s4 --max-time 3 v4.ident.me 2>/dev/null)
    
    echo -e "\n${GREEN}[+] 当前 API 鉴权信息：${NC}"
    echo -e "    通信地址: ${YELLOW}http://${IPV4}:${CUR_PORT}/api/container/info${NC}"
    echo -e "    鉴权 Token: ${YELLOW}${CUR_TOKEN}${NC}"
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

# ==================================================
# 主程序循环
# ==================================================
while true; do
    show_header
    echo -e " 流量 API 管理"
    echo -e "  1. 安装或重新配置"
    echo -e "  2. 查看连接信息"
    echo -e "  3. 测试 API 接口"
    echo -e "  4. 查看流量统计"
    echo -e "  5. 启动 API 服务"
    echo -e "  6. 停止 API 服务"
    echo -e "  7. 重启 API 服务"
    echo -e "  8. 卸载 API 服务"
    echo -e ""
    echo -e " 网络工具"
    echo -e "  9. 检测 IP 质量"
    echo -e " 10. 安装 Sing-box"
    echo -e " 11. 安装 WARP"
    echo -e ""
    echo -e "  0. 退出"
    echo -e "------------------------------------------------------"
    read -p " 请选择功能 [0-11]: " OPTION

    case $OPTION in
        1) do_install ;;
        2) show_connection_info ;;
        3) do_test_api ;;
        4) do_check_vnstat ;;
        5) 
            if systemctl start lowsla_api.service >/dev/null 2>&1; then
                echo -e "${GREEN}[+] API 服务已启动！${NC}"
            else
                echo -e "${RED}[!] API 服务启动失败！${NC}"
            fi
            sleep 1 ;;
        6) 
            if systemctl stop lowsla_api.service >/dev/null 2>&1; then
                echo -e "${GREEN}[+] API 服务已停止！${NC}"
            else
                echo -e "${RED}[!] API 服务停止失败！${NC}"
            fi
            sleep 1 ;;
        7) 
            if systemctl restart lowsla_api.service >/dev/null 2>&1; then
                echo -e "${GREEN}[+] API 服务已重启！${NC}"
            else
                echo -e "${RED}[!] API 服务重启失败！${NC}"
            fi
            sleep 1 ;;
        8) do_uninstall ;;
        9) 
            echo -e "\n${CYAN}[*] 正在启动 IP 质量检测 (Check.Place)...${NC}"
            bash <(curl -Ls https://Check.Place) -I
            echo -n -e "\n请按回车键继续..."
            read
            ;;
        10) 
            echo -e "\n${CYAN}[*] 正在安装 Sing-Box...${NC}"
            bash <(wget -qO- -o- https://github.com/233boy/sing-box/raw/main/install.sh)
            echo -n -e "\n请按回车键继续..."
            read
            ;;
        11) 
            echo -e "\n${CYAN}[*] 正在安装 WARP...${NC}"
            bash <(curl -fsSL https://vpszdm.com/warp-google.sh)
            echo -n -e "\n请按回车键继续..."
            read
            ;;
        0) clear; echo -e "${GREEN}[+] 已退出 Suixin 工具箱${NC}"; exit 0 ;;
        *) echo -e "${RED}[!] 无效选项，请重新输入！${NC}"; sleep 1 ;;
    esac
done
