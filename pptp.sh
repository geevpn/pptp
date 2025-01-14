#!/bin/bash

# ===================== 配置 =====================
USERS=19
USER_BASE="pptp"
IP_BASE="10.10.10."
VPN_LOCAL="10.10.10.254"
VPN_REMOTE="10.10.10.1-253"
PASSWORD="299792458"
DNS="8.8.8.8,1.1.1.1"
PUBLIC_IPS=("1.1.1.1" "8.8.8.8")

# 校验 IP 数量是否足够
[ ${#PUBLIC_IPS[@]} -lt $USERS ] && { echo "不足的 PUBLIC_IPS"; exit 1; }

# ===================== 功能 =====================
check_root() {
    [ "$EUID" -ne 0 ] && { echo "请使用 root 权限运行。"; exit 1; }
}

auto_iface() {
    IFACE=$(ip link show | awk -F': ' '/state UP/ {print $2; exit}')
    if [[ -z $IFACE ]]; then
        echo "未检测到活动网络接口，请检查网络连接。"
        exit 1
    fi
    echo "使用的网络接口: $IFACE"
}

install_pkgs() {
    echo "安装必要包..."
    apt-get update -y && apt-get install -y pptpd iptables iptables-persistent
}

config_pptp() {
    echo "配置 PPTP..."
    cat > /etc/pptpd.conf <<EOF
option /etc/ppp/pptpd-options
logwtmp
localip $VPN_LOCAL
remoteip $VPN_REMOTE
EOF

    cat > /etc/ppp/pptpd-options <<EOF
name pptpd
require-mschap-v2
require-mppe-128
$(echo -e "ms-dns ${DNS//,/\\nms-dns }")
proxyarp
lock
mtu 1400
EOF

    echo "# user server password IP" > /etc/ppp/chap-secrets
    for ((i=1; i<=USERS; i++)); do
        echo "${USER_BASE}$(printf "%03d" $i) pptpd $PASSWORD ${IP_BASE}$i" >> /etc/ppp/chap-secrets
    done
}

config_iptables() {
    echo "配置防火墙..."
    iptables -F && iptables -X && iptables -t nat -F && iptables -t nat -X
    iptables -P INPUT ACCEPT && iptables -P FORWARD ACCEPT && iptables -P OUTPUT ACCEPT

    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A INPUT -p tcp --dport 22 -j ACCEPT
    iptables -A INPUT -p tcp --dport 1723 -j ACCEPT
    iptables -A INPUT -p gre -j ACCEPT
    iptables -A FORWARD -i ppp+ -o "$IFACE" -j ACCEPT
    iptables -A FORWARD -i "$IFACE" -o ppp+ -j ACCEPT

    for ((i=1; i<=USERS; i++)); do
        iptables -t nat -A POSTROUTING -s ${IP_BASE}$i -o "$IFACE" -j SNAT --to-source ${PUBLIC_IPS[$((i-1))]}
    done

    sysctl -w net.ipv4.ip_forward=1
    grep -q "^net.ipv4.ip_forward" /etc/sysctl.conf && sed -i 's/^#\?net.ipv4.ip_forward.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -p

    netfilter-persistent save && netfilter-persistent reload
}

restart_pptp() {
    echo "重启 PPTP 服务..."
    systemctl restart pptpd && systemctl enable pptpd
}

echo_result() {
    echo "PPTP 配置完成。用户信息如下："
    printf "%-15s %-15s %-15s %-15s\n" "用户" "密码" "内网 IP" "外网 IP"
    for ((i=1; i<=USERS; i++)); do
        USER="${USER_BASE}$(printf "%03d" $i)"
        INTERNAL_IP="${IP_BASE}$i"
        EXTERNAL_IP="${PUBLIC_IPS[$((i-1))]}"
        printf "%-15s %-15s %-15s %-15s\n" "$USER" "$PASSWORD" "$INTERNAL_IP" "$EXTERNAL_IP"
    done
}

# ===================== 执行 =====================
check_root
auto_iface
install_pkgs
config_pptp
config_iptables
restart_pptp
echo_result

(crontab -l 2>/dev/null | grep -q "systemctl restart pptpd" || (crontab -l 2>/dev/null; echo "0 * * * * systemctl restart pptpd") | crontab -)