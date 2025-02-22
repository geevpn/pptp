#!/bin/bash

echo "正在卸载 PPTP VPN 服务器..."

# 检测系统类型
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS=$ID
else
    echo "无法检测系统类型，请手动卸载。"
    exit 1
fi

# 停止并禁用 pptpd 服务
echo "停止并禁用 pptpd 服务..."
systemctl stop pptpd 2>/dev/null
systemctl disable pptpd 2>/dev/null

# 关闭 ppp 相关接口
echo "关闭 ppp 相关接口..."
ip link set ppp0 down 2>/dev/null
ip link set ppp1 down 2>/dev/null

# 卸载 pptpd 软件包
echo "卸载 pptpd 软件包..."
if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    apt-get remove --purge -y pptpd
    apt-get autoremove -y
    apt-get clean
elif [[ "$OS" == "centos" || "$OS" == "rhel" ]]; then
    yum remove -y pptpd
    yum autoremove -y
    yum clean all
else
    echo "不支持的操作系统，请手动卸载 pptpd。"
    exit 1
fi

# 删除 pptpd 配置文件
echo "清理 pptpd 配置文件..."
rm -rf /etc/pptpd.conf
rm -rf /etc/ppp/pptpd-options
rm -rf /etc/ppp/chap-secrets
rm -rf /var/log/ppp.log
rm -rf /var/run/pptpd.pid

# 移除防火墙规则（如有）
echo "移除防火墙规则..."
iptables -D INPUT -p tcp --dport 1723 -j ACCEPT 2>/dev/null
iptables -D INPUT -p gre -j ACCEPT 2>/dev/null
iptables -D FORWARD -p gre -j ACCEPT 2>/dev/null
iptables -D FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
iptables-save > /etc/iptables.rules

# 重启网络服务
echo "重启网络服务..."
systemctl restart networking 2>/dev/null || systemctl restart NetworkManager 2>/dev/null

echo "PPTP VPN 服务器已成功卸载！"
