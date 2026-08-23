#!/bin/bash

# 确保脚本以 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo -e "\033[31m错误：请使用 root 权限运行此脚本！\033[0m"
  exit 1
fi

echo -e "\n\033[36m==================================================\033[0m"
echo -e "\033[1;33m 🚀 物理级降维打击 - 流量监控 API 一键部署脚本 🚀\033[0m"
echo -e "\033[36m==================================================\033[0m\n"

# 1. 交互式配置 (支持回车默认)
read -p "请输入 API 监听端口 [默认 45466]: " INPUT_PORT
PORT=${INPUT_PORT:-45466}

read -p "请输入 API 鉴权 Token [默认 2b945047371c4d0c]: " INPUT_TOKEN
TOKEN=${INPUT_TOKEN:-2b945047371c4d0c}

read -p "请输入每月总流量额度 (GB) [默认 1000]: " INPUT_LIMIT
LIMIT=${INPUT_LIMIT:-1000}

read -p "请输入每月流量清零日 (1-28) [默认 1]: " INPUT_DAY
RESET_DAY=${INPUT_DAY:-1}

echo -e "\n\033[32m[1/5] 正在安装底层依赖 (vnstat, python3)...\033[0m"
apt-get update -y >/dev/null 2>&1
apt-get install -y vnstat python3 curl >/dev/null 2>&1

echo -e "\033[32m[2/5] 正在配置 vnStat 账单清零日为每月 ${RESET_DAY} 号...\033[0m"
sed -i "s/MonthRotate .*/MonthRotate ${RESET_DAY}/g" /etc/vnstat.conf
systemctl restart vnstat

echo -e "\033[32m[3/5] 正在生成高精度 Python API 引擎...\033[0m"
cat << 'EOF' > /root/api_server.py
import http.server
import json
import socketserver
import subprocess
import urllib.request

PORT = __PORT__
TOKEN = "__TOKEN__"
TRAFFIC_LIMIT_GB = __LIMIT__

# 智能纯 IPv4 嗅探
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
            
            # 动态提取最新账单周期
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

# 将用户输入的变量无缝注入 Python 脚本
sed -i "s/__PORT__/${PORT}/g" /root/api_server.py
sed -i "s/__TOKEN__/${TOKEN}/g" /root/api_server.py
sed -i "s/__LIMIT__/${LIMIT}/g" /root/api_server.py

echo -e "\033[32m[4/5] 正在配置 Systemd 系统级守护进程...\033[0m"
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

echo -e "\033[32m[5/5] 正在拉起服务并设置开机自启...\033[0m"
systemctl daemon-reload
systemctl enable lowsla_api.service >/dev/null 2>&1
systemctl restart lowsla_api.service

# 获取本机真实外网IP用于最终展示
IPV4=$(curl -s4 v4.ident.me)

echo -e "\n\033[36m==================================================\033[0m"
echo -e "\033[1;32m ✅ 恭喜！服务端部署已完美完成！\033[0m"
echo -e "\033[36m--------------------------------------------------\033[0m"
echo -e " 📍 \033[33m监听端口\033[0m : ${PORT}"
echo -e " 🔑 \033[33m鉴权Token\033[0m: ${TOKEN}"
echo -e " 📦 \033[33m流量额度\033[0m : ${LIMIT} GB"
echo -e " 📅 \033[33m清零日期\033[0m : 每月 ${RESET_DAY} 号"
echo -e "\033[36m--------------------------------------------------\033[0m"
echo -e " 💡 请在前端 PHP 面板中，将 \$api_url 修改为："
echo -e " \033[1;35m\$api_url = \"http://${IPV4}:${PORT}/api/container/info\";\033[0m"
echo -e "\033[36m==================================================\033[0m\n"
