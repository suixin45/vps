#!/usr/bin/env bash

# Batch-create nodes with the 233boy/sing-box management script.
# Scheme 1: TUIC + Hysteria2 + VLESS-REALITY + VLESS-HTTP2-REALITY
# Scheme 2: Hysteria2 + VLESS-REALITY
# Port rule: 20000 + MMDD * 10 + sequence number (1-4)

set -uo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "[错误] 请使用 root 用户运行此脚本。" >&2
  exit 1
fi

if command -v sb >/dev/null 2>&1; then
  SB_BIN="$(command -v sb)"
elif command -v sing-box >/dev/null 2>&1; then
  SB_BIN="$(command -v sing-box)"
else
  echo "[错误] 找不到 sb/sing-box 命令，请先确认 233boy 脚本已经安装。" >&2
  exit 1
fi

choice="${1:-}"
if [[ -z "$choice" ]]; then
  echo "请选择批量创建方案："
  echo "  1) TUIC + Hysteria2 + VLESS-REALITY + VLESS-HTTP2-REALITY"
  echo "  2) Hysteria2 + VLESS-REALITY"
  read -r -p "请输入 [1-2]: " choice
fi

case "$choice" in
  1)
    labels=("TUIC" "Hysteria2" "VLESS-REALITY" "VLESS-HTTP2-REALITY")
    protocols=("tuic" "hy" "reality" "rh2")
    ;;
  2)
    labels=("Hysteria2" "VLESS-REALITY")
    protocols=("hy" "reality")
    ;;
  *)
    echo "[错误] 方案只能是 1 或 2。" >&2
    exit 2
    ;;
esac

work_dir="$(mktemp -d /tmp/sb-batch-add.XXXXXX)" || exit 1
trap 'rm -rf -- "$work_dir"' EXIT

declare -a results
success_count=0
failure_count=0
date_md="$(date +%m%d)"
date_number=$((10#$date_md))
port_base=$((20000 + date_number * 10))

echo
echo "即将创建 ${#protocols[@]} 条节点。"
echo "今日日期: $(date +%m-%d)，端口范围: $((port_base + 1))-$((port_base + ${#protocols[@]}))"
echo "认证信息仍由 sb 自动生成。"

for i in "${!protocols[@]}"; do
  label="${labels[$i]}"
  protocol="${protocols[$i]}"
  port=$((port_base + i + 1))
  log_file="$work_dir/$i.log"

  echo
  echo "[$((i + 1))/${#protocols[@]}] 正在创建 $label，端口 $port ..."

  if command -v ss >/dev/null 2>&1 && ss -H -lntu 2>/dev/null | grep -Eq "[:.]${port}[[:space:]]"; then
    echo "[失败] 端口 $port 已被占用，未创建 $label。" >&2
    results+=("[失败] $label（端口 $port）|端口已被占用")
    failure_count=$((failure_count + 1))
    continue
  fi

  if "$SB_BIN" add "$protocol" "$port" 2>&1 | tee "$log_file"; then
    clean_file="$work_dir/$i.clean.log"
    sed -E $'s/\x1B\[[0-9;?]*[ -\/]*[@-~]//g' "$log_file" > "$clean_file"
    url="$(grep -Eo '(tuic|hysteria2|hy2|vless)://[^[:space:]]+' "$clean_file" | tail -n 1 || true)"

    if [[ -n "$url" ]]; then
      results+=("[成功] $label（端口 $port）|$url")
    else
      results+=("[成功] $label（端口 $port）|已创建，但未能从输出中提取链接；请运行: sb info")
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

if (( failure_count > 0 )); then
  exit 3
fi
