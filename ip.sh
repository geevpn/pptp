#!/bin/bash
set -e

# IP 和网关列表
IPs=("1.1.1.1/32" "8.8.8.8/32")
GWs=("1.1.1.1" "8.8.8.8")

# 检查 root
[[ $EUID -ne 0 ]] && echo "请以 root 运行" && exit 1

# 安装 yq
if ! command -v yq &>/dev/null; then
  curl -sL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64" -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq || {
    echo "yq 安装失败" && exit 1;
  }
fi

# 获取配置文件和接口
CONF=$(ls /etc/netplan/*.yaml 2>/dev/null | head -n1)
[[ -z $CONF ]] && echo "未找到 Netplan 配置" && exit 1
IFACE=$(ip link show | awk -F': ' '/state UP/ {print $2; exit}')
[[ -z $IFACE ]] && echo "未检测到网络接口" && exit 1

# 备份配置
cp "$CONF" "${CONF}.bak.$(date +%F_%T)"

# 初始化 routes 和 routing-policy
yq -i ".network.ethernets.${IFACE}.routes = [] | .network.ethernets.${IFACE}.routing-policy = []" "$CONF"

# 添加 IP
for ip in "${IPs[@]}"; do
  if ! yq e ".network.ethernets.${IFACE}.addresses[]" "$CONF" | grep -qx "$ip"; then
    yq -i ".network.ethernets.${IFACE}.addresses += [\"$ip\"]" "$CONF"
    echo "添加 IP: $ip"
  else
    echo "IP 已存在: $ip"
  fi
done

# 添加网关
ID=100
for gw in "${GWs[@]}"; do
  if [[ $gw =~ : ]]; then
    yq -i ".network.ethernets.${IFACE}.dhcp6 = false | .network.ethernets.${IFACE}.routes += [{\"to\": \"default\", \"via\": \"$gw\", \"table\": $ID}] | \
    .network.ethernets.${IFACE}.routing-policy += [{\"from\": \"::/0\", \"table\": $ID}]" "$CONF"
  else
    yq -i ".network.ethernets.${IFACE}.routes += [{\"to\": \"default\", \"via\": \"$gw\", \"table\": $ID}] | \
    .network.ethernets.${IFACE}.routing-policy += [{\"from\": \"0.0.0.0/0\", \"table\": $ID}]" "$CONF"
  fi
  ((ID++))
  echo "添加网关: $gw (表: $ID)"
done

# 应用配置
netplan apply && echo "配置已应用"
