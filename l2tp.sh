#!/bin/bash
set -euo pipefail

# 全局变量
IP_FILE="ip"
IP_BASE="100.0.0"
IP_MIN="100.0.0.1"
IP_MAX="100.0.0.253"
LOCAL_IP="100.0.0.254"
PSK="3r3fb7X359tz8A3u"
PPP_PASS="299792458"
DNS1="8.8.8.8"
DNS2="8.8.4.4"
DEF_PREFIX="l2tp"
EXT_IF="eth0"

# 检查是否以 root 权限运行
check_root() {
    [ "$(id -u)" -eq 0 ] || { echo "请使用 root 权限运行"; exit 1; }
}

# 获取指定网卡第一个 IPv4 地址
get_ip() {
    local ip
    ip=$(ip -o -4 addr show "$EXT_IF" | awk '{print $4}' | cut -d/ -f1 | head -n1)
    [ -z "$ip" ] && { echo "无法获取 $EXT_IF 的 IP 地址"; exit 1; }
    echo "$ip"
}

# 获取国家代码（失败时使用默认前缀）
get_prefix() {
    local lip="$1" cc
    cc=$(curl -s "https://ipinfo.io/${lip}/json" | grep -oP '"country":\s*"\K[^"]+')
    echo "${cc:-$DEF_PREFIX}_"
}

# 安装必要软件
install_pkgs() {
    apt-get update -qq
    apt-get install -y strongswan xl2tpd
}

# 配置 ipsec
config_ipsec() {
    cat >/etc/ipsec.conf <<'EOF'
config setup
    strictcrlpolicy=no
    uniqueids=yes

conn L2TP-PSK
    keyexchange=ikev1
    authby=secret
    pfs=no
    rekey=no
    ikelifetime=8h
    keylife=1h
    left=%any
    leftsubnet=0.0.0.0/0
    leftfirewall=yes
    leftprotoport=17/1701
    right=%any
    rightprotoport=17/%any
    auto=add
    dpdaction=clear
    dpddelay=300s
EOF

    cat >/etc/ipsec.secrets <<EOF
: PSK "$PSK"
EOF
}

# 配置 xl2tpd 与 PPP
config_l2tp() {
    cat >/etc/xl2tpd/xl2tpd.conf <<EOF
[lns default]
ip range = ${IP_MIN}-${IP_MAX}
local ip = $LOCAL_IP
require chap = yes
refuse pap = yes
require authentication = yes
name = L2TP-VPN
ppp debug = no
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
EOF

    cat >/etc/ppp/options.xl2tpd <<EOF
ipcp-accept-local
ipcp-accept-remote
ms-dns $DNS1
ms-dns $DNS2
noccp
auth
noipv6
idle 1800
mtu 1410
mru 1410
connect-delay 5000
EOF
}

# 配置 NAT 与生成 chap-secrets，同时统一输出 NAT 映射表
config_nat() {
    local pref="$1" min max i curr ip ext user
    local -a rules=()

    min=$(echo "$IP_MIN" | awk -F. '{print $4}')
    max=$(echo "$IP_MAX" | awk -F. '{print $4}')
    mapfile -t arr < "$IP_FILE"

    echo "共找到 ${#arr[@]} 个外网 IP，内网 IP 范围: ${IP_BASE}.${min} - ${IP_BASE}.${max}"

    # 清空 chap-secrets 文件
    : > /etc/ppp/chap-secrets

    # 清理现有 iptables 规则，避免重复添加
    iptables -F && iptables -X && iptables -t nat -F && iptables -t nat -X
    iptables -P INPUT ACCEPT && iptables -P FORWARD ACCEPT && iptables -P OUTPUT ACCEPT

    # 允许已建立的连接及本地回环
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -i lo -j ACCEPT

    # 允许 L2TP 连接
    iptables -A INPUT -p udp --dport 1701 -j ACCEPT
    iptables -A OUTPUT -p udp --sport 1701 -j ACCEPT

    for ((i=0; i<${#arr[@]}; i++)); do
        curr=$((min + i))
        (( curr > max )) && { echo "[错误] 内网 IP 范围超出限制: ${IP_BASE}.${curr}"; break; }
        ip="${IP_BASE}.${curr}"
        user=$(printf "%s%03d" "$pref" $((i+1)))
        echo -e "$user\t*\t$PPP_PASS\t$ip" >> /etc/ppp/chap-secrets
        ext=${arr[i]}
        
        # 添加 NAT 规则（避免重复）
        if ! iptables -t nat -C POSTROUTING -s "$ip" -o "$EXT_IF" -j SNAT --to-source "$ext" -m comment --comment "VPN_NAT" 2>/dev/null; then
            iptables -t nat -A POSTROUTING -s "$ip" -o "$EXT_IF" -j SNAT --to-source "$ext" -m comment --comment "VPN_NAT"
        fi
        rules+=("$ip --> $ext")
    done

    # 启用 IP 转发
    sysctl -w net.ipv4.ip_forward=1
    grep -q "^net.ipv4.ip_forward" /etc/sysctl.conf && \
        sed -i 's/^#\?net.ipv4.ip_forward.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf || \
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -p

    # 允许 VPN 客户端访问外网
    iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
    
    # 持久化防火墙规则
    netfilter-persistent save && netfilter-persistent reload

    # 输出 NAT 规则
    echo -e "\n=== NAT 规则列表 ==="
    echo "内网IP         --> 外网IP"
    echo "-------------------------------"
    for rule in "${rules[@]}"; do
        printf "%-15s %s\n" ${rule%% -->*} "${rule##*--> }"
    done
    echo "-------------------------------"

    # 输出 /etc/ppp/chap-secrets 内容
    echo -e "\n=== /etc/ppp/chap-secrets 内容 ==="
    cat /etc/ppp/chap-secrets
}


# 主流程
main() {
    check_root
    [ -f "$IP_FILE" ] || { echo "缺少 IP 文件"; exit 1; }
    local lip prefix
    prefix=$(get_prefix $(get_ip))
    echo "用户名前缀: $prefix"
    install_pkgs
    config_ipsec
    config_l2tp
    config_nat "$prefix"
    systemctl restart ipsec
    systemctl restart xl2tpd
}

main
