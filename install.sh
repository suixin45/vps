#!/bin/bash

# ==================================================
# 变量与颜色定义 (纯净 ANSI 风格)
# ==================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[!] 错误：请使用 root 权限运行此脚本！${NC}"
  exit 1
fi

# ==================================================
# 流量 API 核心功能函数库
# ==================================================

function check_installed() {
    if [ -f "/root/api_server.py" ] && [ -f "/etc/systemd/system/lowsla_api.service" ]; then
        return 0
    else
        return 1
    fi
}

function get_current_config() {
    if check_installed; then
        CUR_PORT=$(grep "^PORT =" /root/api_server.py | awk '{print $3}')
        CUR_TOKEN=$(grep "^TOKEN =" /root/api_server.py | awk -F '"' '{print $2}')
        CUR_LIMIT=$(grep "^TRAFFIC_LIMIT_GB =" /root/api_server.py | awk '{print $3}')
        
        # 提取清零日，兼容各种格式
        CUR_DAY=$(grep -i "MonthRotate" /etc/vnstat.conf 2>/dev/null | grep -oE "[0-9]+" | head -n 1)
        [ -z "$CUR_DAY" ] && CUR_DAY="未知"
        
        if systemctl is-active --quiet lowsla_api.service; then
            STATUS="${GREEN}[运行中 Active]${NC}"
        else
            STATUS="${RED}[已停止 Stopped]${NC}"
        fi
    fi
}

function show_header() {
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${GREEN}      高精度 VPS 综合管理与流量监控系统 (Pro版)       ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    
    if check_installed; then
        get_current_config
        echo -e " [*] 核心 API 状态 : ${STATUS}"
        echo -e " [*] 当前监听端口  : ${YELLOW}${CUR_PORT}${NC}"
        echo -e " [*] 当前鉴权 Token: ${YELLOW}${CUR_TOKEN}${NC}"
        echo -e " [*] 当前流量额度  : ${YELLOW}${CUR_LIMIT} GB${NC}"
        echo -e " [*] 每月清零日期  : ${YELLOW}${CUR_DAY}${NC} 号"
        echo -e "${CYAN}======================================================${NC}"
    else
        echo -e " [*] 核心 API 状态 : ${RED}未安装${NC}"
        echo -e "${CYAN}======================================================${NC}"
    fi
}

function do_install() {
    echo -e "\n${CYAN}[+] 开始配置 / 重装 API 服务...${NC}"
    
    DEF_PORT=${CUR_PORT:-45466}
    DEF_TOKEN=${CUR_TOKEN:-2b945047371c4d0c}
    DEF_LIMIT=${CUR_LIMIT:-1000}
    DEF_DAY=${CUR_DAY:-1}

    read -p " [+] 请输入 API 监听端口 [默认 ${DEF_PORT}]: " INPUT_PORT
    PORT=${INPUT_PORT:-$DEF_PORT}

    read -p " [+] 请输入 API 鉴权 Token [默认 ${DEF_TOKEN}]: " INPUT_TOKEN
    TOKEN=${INPUT_TOKEN:-$DEF_TOKEN}

    read -p " [+] 请输入每月总流量额度 (GB) [默认 ${DEF_LIMIT}]: " INPUT_LIMIT
    LIMIT=${INPUT_LIMIT:-$DEF_LIMIT}

    read -p " [+] 请输入每月流量清零日 (1-28) [默认 ${DEF_DAY}]: " INPUT_DAY
    RESET_DAY=${INPUT_DAY:-$DEF_DAY}

    echo -e "\n${GREEN} [1/4] 正在安装底层依赖 (vnstat, python3)...${NC}"
    apt-get update -y >/dev/null 2>&1
    apt-get install -y vnstat python3 curl >/dev/null 2>&1

    echo -e "${GREEN} [2/4] 正在配置底层账单日为 ${RESET_DAY} 号...${NC}"
    sed -i -E "s/^[#;]*\s*MonthRotate.*/MonthRotate ${RESET_DAY}/g" /etc/vnstat.conf
    systemctl restart vnstat

    echo -e "${GREEN} [3/4] 正在部署高精度 Python API 引擎...${NC}"
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
        except Exception:
            pass 
            
        response = {
            "data": {
                "traffic_limit": TRAFFIC_LIMIT_GB,
                "traffic_usage_raw": round(usage_gb, 4),
                "ipv4": [PUBLIC_IP],
                "ipv6": []
            }
        }
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

    echo -e "${GREEN} [4/4] 正在配置系统守护进程并拉起服务...${NC}"
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
    systemctl restart lowsla_api.service

    IPV4=$(curl -s4 v4.ident.me)
    
    echo -e "\n${GREEN} [+] 流量 API 部署完成！${NC}"
    echo -e " [+] 请在前端 PHP 将 \$api_url 修改为: ${YELLOW}http://${IPV4}:${PORT}/api/container/info${NC}"
    echo -n -e "\n 按回车键返回主菜单..."
    read
}

function do_test_api() {
    if ! check_installed; then
        echo -e "\n${RED} [!] 未安装服务，无法测试！${NC}"
    else
        echo -e "\n${CYAN} [+] 正在调用本地 API 获取实时数据...${NC}"
        get_current_config
        RESULT=$(curl -s --max-time 3 -H "X-Container-Hash: ${CUR_TOKEN}" http://127.0.0.1:${CUR_PORT})
        if [ -z "$RESULT" ]; then
            echo -e "${RED} [!] 请求失败或超时，请检查服务状态是否正常。${NC}"
        else
            echo -e "${GREEN} [+] API 返回结果：${NC}"
            echo "$RESULT" | python3 -m json.tool
        fi
    fi
    echo -n -e "\n 按回车键返回主菜单..."
    read
}

function do_check_vnstat() {
    echo -e "\n${CYAN} [+] 正在读取并翻译底层物理网卡报表...${NC}\n"
    if command -v vnstat >/dev/null 2>&1; then
        # 🟢 独家黑科技：基于中英文字符宽度的像素级等宽对齐替换
        vnstat -m | sed \
            -e 's/   month        rx      /    月份          下行  /g' \
            -e 's/       tx      /      上行     /g' \
            -e 's/    total    /    总计     /g' \
            -e 's/   avg. rate/   平均速率 /g' \
            -e 's/estimated/本月预估 /g' \
            -e 's/monthly/月度统计/g'
    else
        echo -e "${RED} [!] vnstat 未安装，请先执行安装 API 服务。${NC}"
    fi
    echo -n -e "\n 按回车键返回主菜单..."
    read
}

function do_uninstall() {
    if ! check_installed; then
        echo -e "\n${RED} [!] 未检测到安装，无需卸载！${NC}"
    else
        read -p " [?] 确定要彻底卸载流量监控 API 吗？[y/N]: " UNINSTALL_CONFIRM
        if [[ "$UNINSTALL_CONFIRM" =~ ^[Yy]$ ]]; then
            echo -e "\n${YELLOW} [-] 正在停止并移除服务...${NC}"
            systemctl stop lowsla_api.service >/dev/null 2>&1
            systemctl disable lowsla_api.service >/dev/null 2>&1
            rm -f /etc/systemd/system/lowsla_api.service
            systemctl daemon-reload
            
            echo -e "${YELLOW} [-] 正在删除核心脚本...${NC}"
            rm -f /root/api_server.py
            
            echo -e "${GREEN} [+] 卸载完成！(底层 vnstat 保留以备他用)${NC}"
        else
            echo -e "${GREEN} [*] 已取消卸载。${NC}"
        fi
    fi
    echo -n -e "\n 按回车键返回主菜单..."
    read
}

# ==================================================
# 主程序循环
# ==================================================
while true; do
    show_header
    echo -e " ${CYAN}--- 本地服务管理 ---${NC}"
    echo -e "  ${GREEN}1.${NC} 部署重装 API 接口"
    echo -e "  ${GREEN}2.${NC} 本地测试 API 数据"
    echo -e "  ${GREEN}3.${NC} 查看本地流量报表 "
    echo -e "  ${GREEN}4.${NC} 停止后台 API 进程"
    echo -e "  ${GREEN}5.${NC} 启动后台 API 进程"
    echo -e "  ${GREEN}6.${NC} 彻底卸载 API 服务"
    echo -e ""
    echo -e " ${CYAN}--- 极客专属扩展 ---${NC}"
    echo -e "  ${GREEN}7.${NC} 测速检测 IP 质量 "
    echo -e "  ${GREEN}8.${NC} 一键部署 Sing-Box"
    echo -e "  ${GREEN}9.${NC} 开启 WARP 纯净 IP"
    echo -e ""
    echo -e "  ${GREEN}0.${NC} 退出综合管理脚本 "
    echo -e "${CYAN}======================================================${NC}"
    read -p " 请输入选项 [0-9]: " OPTION

    case $OPTION in
        1) do_install ;;
        2) do_test_api ;;
        3) do_check_vnstat ;;
        4) 
            systemctl stop lowsla_api.service >/dev/null 2>&1
            echo -e "${GREEN} [*] 服务已停止！${NC}"; sleep 1 ;;
        5) 
            systemctl start lowsla_api.service >/dev/null 2>&1
            echo -e "${GREEN} [*] 服务已启动！${NC}"; sleep 1 ;;
        6) do_uninstall ;;
        7) 
            echo -e "\n${CYAN} [>] 正在启动 IP 质量检测 (Check.Place)...${NC}"
            bash <(curl -Ls https://Check.Place) -I
            echo -n -e "\n 按回车键返回主菜单..."
            read
            ;;
        8) 
            echo -e "\n${CYAN} [>] 正在拉取 sing-box 一键安装脚本...${NC}"
            bash <(wget -qO- -o- https://github.com/233boy/sing-box/raw/main/install.sh)
            echo -n -e "\n 按回车键返回主菜单..."
            read
            ;;
        9) 
            echo -e "\n${CYAN} [>] 正在执行 WARP 一键开启脚本...${NC}"
            bash <(curl -fsSL https://vpszdm.com/warp-google.sh)
            echo -n -e "\n 按回车键返回主菜单..."
            read
            ;;
        0) clear; echo -e "${GREEN} [*] 感谢使用，老板再见！${NC}"; exit 0 ;;
        *) echo -e "${RED} [!] 无效选项，请重新输入！${NC}"; sleep 1 ;;
    esac
done
