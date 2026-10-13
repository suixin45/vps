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
SCRIPT_SHORT_BIN="/usr/local/bin/sx"
SCRIPT_FALLBACK_BIN="/usr/bin/suixin"
SCRIPT_SHORT_FALLBACK_BIN="/usr/bin/sx"
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
            ln -sfn "$SCRIPT_BIN" "$SCRIPT_SHORT_BIN"
            ln -sfn "$SCRIPT_BIN" "$SCRIPT_FALLBACK_BIN"
            ln -sfn "$SCRIPT_BIN" "$SCRIPT_SHORT_FALLBACK_BIN"
            rm -f "$TMP_FILE"
            hash -r 2>/dev/null || true
            echo -e "${GREEN}[+] 安装完成！输入 ${YELLOW}suixin${GREEN} 或 ${YELLOW}sx${GREEN} 即可唤出面板！${NC}"
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

# 正常启动时自动修复短命令入口，确保更新或重启后仍可使用 sx。
if [ -x "$SCRIPT_BIN" ] && { [ ! -L "$SCRIPT_SHORT_BIN" ] || [ "$(readlink -f "$SCRIPT_SHORT_BIN" 2>/dev/null)" != "$SCRIPT_BIN" ]; }; then
    ln -sfn "$SCRIPT_BIN" "$SCRIPT_SHORT_BIN" 2>/dev/null || true
fi
if [ -x "$SCRIPT_BIN" ]; then
    ln -sfn "$SCRIPT_BIN" "$SCRIPT_FALLBACK_BIN" 2>/dev/null || true
    ln -sfn "$SCRIPT_BIN" "$SCRIPT_SHORT_FALLBACK_BIN" 2>/dev/null || true
fi

if ! command -v vnstat >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    echo -e "${YELLOW}[!] 缺失基础依赖，正在自动安装...${NC}"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y >/dev/null 2>&1 || true
        apt-get install -y vnstat python3 curl openssl iproute2 >/dev/null 2>&1 || { echo -e "${RED}[!] 依赖安装失败！${NC}"; exit 1; }
    elif command -v yum >/dev/null 2>&1; then
        yum install -y vnstat python3 curl openssl iproute >/dev/null 2>&1 || { echo -e "${RED}[!] 依赖安装失败！${NC}"; exit 1; }
    fi
    clear
fi

# ==================================================
# 流量 API 核心功能函数库
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
            STATUS="运行中"
        else
            STATUS="已停止"
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
        if [ "$STATUS" == "运行中" ]; then
            echo -e " 流量 API：${GREEN}${STATUS}${NC}"
        else
            echo -e " 流量 API：${RED}${STATUS}${NC}"
        fi
        echo -e " 监听端口：${CUR_PORT}"
        echo -e " 流量额度：${CUR_LIMIT} GB"
        echo -e " 每月重置：${CUR_DAY} 日"
    else
        echo -e " 流量 API：${RED}未安装${NC}"
        echo -e " 监听端口：未设置"
        echo -e " 流量额度：未设置"
        echo -e " 每月重置：未设置"
    fi
    echo -e "======================================================"
}

function do_install() {
    echo -e "\n${CYAN}[*] 开始配置 API 服务...${NC}"
    
    DEF_PORT=${CUR_PORT:-45466}
    DEF_TOKEN=${CUR_TOKEN:-2b945047371c4d0c}
    DEF_LIMIT=${CUR_LIMIT:-1000}
    DEF_DAY=${CUR_DAY:-1}

    read -p " [?] 请输入监听端口 [默认 ${DEF_PORT}]: " INPUT_PORT
    PORT=${INPUT_PORT:-$DEF_PORT}
    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
        echo -e "${RED}[!] 端口必须是 1-65535 的数字！${NC}" && sleep 2 && return
    fi

    # 优化：提前停止服务，避免端口检测误伤自己
    systemctl stop lowsla_api.service >/dev/null 2>&1
    if ss -tuln 2>/dev/null | grep -q ":${PORT} "; then
        echo -e "${RED}[!] 端口 ${PORT} 已被其他程序占用，请更换端口！${NC}"
        sleep 2
        return
    fi

    read -p " [?] 请输入鉴权 Token [默认 ${DEF_TOKEN}，输入 r 随机]: " INPUT_TOKEN
    if [ "$INPUT_TOKEN" = "r" ] || [ "$INPUT_TOKEN" = "R" ]; then
        if command -v openssl >/dev/null 2>&1; then
            TOKEN=$(openssl rand -hex 16)
        else
            echo -e "${RED}[!] 系统未安装 openssl，无法生成随机 Token！${NC}" && sleep 2 && return
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

    read -p " [?] 请输入账单重置日 (1-28) [默认 ${DEF_DAY}]: " INPUT_DAY
    RESET_DAY=${INPUT_DAY:-$DEF_DAY}
    if ! [[ "$RESET_DAY" =~ ^[1-9]$|^1[0-9]$|^2[0-8]$ ]]; then
        echo -e "${RED}[!] 日期必须是 1-28 的数字！${NC}" && sleep 2 && return
    fi

    echo -e "\n[*] 正在配置环境..."
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
    PUBLIC_IP = "获取失败"

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
        echo -e "${GREEN}[+] API 服务安装成功！${NC}"
        do_view_info "install_mode"
    else
        echo -e "${RED}[!] API 服务启动失败！${NC}"
    fi
    echo -n -e "\n请按回车键继续..."
    read
}

function do_view_info() {
    if ! check_installed; then
        if [ "$1" != "install_mode" ]; then echo -e "\n${RED}[!] 未安装 API 服务！${NC}" && sleep 1; fi
        return
    fi
    
    get_current_config
    # 优化：增加 IP 获取超时断言，防止纯 IPv6 机器死锁
    IPV4=$(curl -s4 --max-time 3 v4.ident.me 2>/dev/null)
    [ -z "$IPV4" ] && IPV4="获取超时或仅支持IPv6"
    
    if [ "$1" != "install_mode" ]; then echo -e "\n${CYAN}--- API 连接信息 ---${NC}"; fi
    echo -e " 接口地址: ${YELLOW}http://${IPV4}:${CUR_PORT}/api/container/info${NC}"
    echo -e " 鉴权 Token: ${YELLOW}${CUR_TOKEN}${NC}"
    
    if [ "$1" != "install_mode" ]; then
        echo -n -e "\n请按回车键继续..."
        read
    fi
}

function do_test_api() {
    if ! check_installed; then echo -e "\n${RED}[!] 未安装 API 服务！${NC}" && sleep 1 && return; fi
    echo -e "\n${CYAN}[*] 正在测试 API 接口...${NC}"
    get_current_config
    RESULT=$(curl -s --max-time 3 -H "X-Container-Hash: ${CUR_TOKEN}" http://127.0.0.1:${CUR_PORT})
    if [ -z "$RESULT" ]; then
        echo -e "${RED}[!] 请求失败或超时！${NC}"
    else
        echo -e "${GREEN}[+] 接口返回：${NC}"
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
    echo -e "\n${CYAN}[*] 正在拉取底层流量报表...${NC}\n"
    if command -v vnstat >/dev/null 2>&1; then
        vnstat -m | sed \
            -e 's/   month        rx      /    月份          下行  /g' \
            -e 's/       tx      /      上行     /g' \
            -e 's/    total    /    总计     /g' \
            -e 's/   avg. rate/   平均速率 /g' \
            -e 's/estimated/预估消耗 /g' \
            -e 's/monthly/月统计报表/g'
    else
        echo -e "${RED}[!] 未安装 vnstat！${NC}"
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

function do_batch_add_nodes() {
    local sb_bin choice date_md date_number scheme1_port_base scheme2_port_base
    local scheme_base port_base work_dir label protocol port log_file clean_file url
    local success_count=0
    local failure_count=0
    local i result status detail add_status
    local -a labels protocols results

    if command -v sb >/dev/null 2>&1; then
        sb_bin="$(command -v sb)"
    elif [ -f /etc/sing-box/sh/sing-box.sh ]; then
        sb_bin="/etc/sing-box/sh/sing-box.sh"
    else
        echo -e "\n${RED}[!] 找不到 233boy Sing-box 管理脚本，请先运行第 10 项安装。${NC}"
        echo -n -e "\n请按回车键继续..."
        read
        return
    fi

    date_md="$(date +%m%d)"
    date_number=$((10#$date_md))
    scheme1_port_base=$((40000 + date_number * 10))
    scheme2_port_base=$((20000 + date_number * 10))

    clear
    echo -e "${CYAN}请选择批量创建方案（今日 $(date +%m-%d)）：${NC}"
    echo
    echo "[1] 方案一（4条）"
    printf '    %-24s %s\n' "TUIC" "$((scheme1_port_base + 1))"
    printf '    %-24s %s\n' "Hysteria2" "$((scheme1_port_base + 2))"
    printf '    %-24s %s\n' "VLESS-REALITY" "$((scheme1_port_base + 3))"
    printf '    %-24s %s\n' "VLESS-HTTP2-REALITY" "$((scheme1_port_base + 4))"
    echo
    echo "[2] 方案二（2条）"
    printf '    %-24s %s\n' "Hysteria2" "$((scheme2_port_base + 1))"
    printf '    %-24s %s\n' "VLESS-REALITY" "$((scheme2_port_base + 2))"
    echo
    read -p "请输入 [1-2，回车返回]: " choice

    case "$choice" in
        1)
            labels=("TUIC" "Hysteria2" "VLESS-REALITY" "VLESS-HTTP2-REALITY")
            protocols=("tuic" "hy" "reality" "rh2")
            scheme_base=40000
            ;;
        2)
            labels=("Hysteria2" "VLESS-REALITY")
            protocols=("hy" "reality")
            scheme_base=20000
            ;;
        "") return ;;
        *)
            echo -e "${RED}[!] 方案只能是 1 或 2。${NC}"
            sleep 1
            return
            ;;
    esac

    port_base=$((scheme_base + date_number * 10))
    work_dir="$(mktemp -d /tmp/suixin-sb-add.XXXXXX)" || {
        echo -e "${RED}[!] 无法创建临时目录。${NC}"
        sleep 1
        return
    }

    echo
    echo -e "${CYAN}[*] 即将创建 ${#protocols[@]} 条节点，端口范围 $((port_base + 1))-$((port_base + ${#protocols[@]}))。${NC}"

    for i in "${!protocols[@]}"; do
        label="${labels[$i]}"
        protocol="${protocols[$i]}"
        port=$((port_base + i + 1))
        log_file="$work_dir/$i.log"

        echo
        echo -e "${CYAN}[$((i + 1))/${#protocols[@]}] 正在创建 $label，端口 $port ...${NC}"

        if command -v ss >/dev/null 2>&1 && ss -H -lntu 2>/dev/null | grep -Eq "[:.]${port}[[:space:]]"; then
            echo -e "${RED}[失败] 端口 $port 已被占用，未创建 $label。${NC}"
            results+=("[失败] $label（端口 $port）|端口已被占用")
            failure_count=$((failure_count + 1))
            continue
        fi

        "$sb_bin" add "$protocol" "$port" >"$log_file" 2>&1
        add_status=$?
        cat "$log_file"

        if [ "$add_status" -eq 0 ]; then
            clean_file="$work_dir/$i.clean.log"
            sed -E $'s/\x1B\[[0-9;?]*[ -\/]*[@-~]//g' "$log_file" > "$clean_file"
            url="$(grep -Eo '(tuic|hysteria2|hy2|vless)://[^[:space:]]+' "$clean_file" | tail -n 1 || true)"

            if [ -n "$url" ]; then
                results+=("[成功] $label（端口 $port）|$url")
            else
                results+=("[成功] $label（端口 $port）|已创建，但未能提取链接；请运行 sb info 查看")
            fi
            success_count=$((success_count + 1))
        else
            results+=("[失败] $label（端口 $port）|创建命令执行失败，请查看上方输出")
            failure_count=$((failure_count + 1))
        fi
    done

    echo
    echo "================ 新建节点汇总 ================"
    for result in "${results[@]}"; do
        status="${result%%|*}"
        detail="${result#*|}"
        echo "$status"
        echo "$detail"
        echo
    done
    echo "成功: $success_count，失败: $failure_count"
    echo "==============================================="

    rm -rf -- "$work_dir"
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
    echo -e " 11. 创建 Sing-box"
    echo -e " 12. 安装 WARP"
    echo -e ""
    echo -e "  0. 退出"
    echo -e "------------------------------------------------------"
    read -p " 请选择功能 [0-12]: " OPTION

    case $OPTION in
        1) do_install ;;
        2) do_view_info ;;
        3) do_test_api ;;
        4) do_check_vnstat ;;
        5) 
            if systemctl start lowsla_api.service >/dev/null 2>&1; then echo -e "${GREEN}[+] 服务已启动！${NC}"; else echo -e "${RED}[!] 启动失败！${NC}"; fi
            sleep 1 ;;
        6) 
            if systemctl stop lowsla_api.service >/dev/null 2>&1; then echo -e "${GREEN}[+] 服务已停止！${NC}"; else echo -e "${RED}[!] 停止失败！${NC}"; fi
            sleep 1 ;;
        7) 
            if systemctl restart lowsla_api.service >/dev/null 2>&1; then echo -e "${GREEN}[+] 服务已重启！${NC}"; else echo -e "${RED}[!] 重启失败！${NC}"; fi
            sleep 1 ;;
        8) do_uninstall ;;
        9) 
            echo -e "\n${CYAN}[*] 正在启动 IP 质量检测 (Check.Place)...${NC}"
            bash <(curl -Ls https://Check.Place) -I
            echo -n -e "\n请按回车键继续..."
            read ;;
        10) 
            echo -e "\n${CYAN}[*] 正在拉取 Sing-box...${NC}"
            bash <(wget -qO- -o- https://github.com/233boy/sing-box/raw/main/install.sh)
            echo -n -e "\n请按回车键继续..."
            read ;;
        11) do_batch_add_nodes ;;
        12) 
            echo -e "\n${CYAN}[*] 正在拉取 WARP...${NC}"
            bash <(curl -fsSL https://vpszdm.com/warp-google.sh)
            echo -n -e "\n请按回车键继续..."
            read ;;
        0) clear; exit 0 ;;
        *) echo -e "${RED}[!] 无效选项！${NC}"; sleep 1 ;;
    esac
done
