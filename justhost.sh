#!/bin/bash
# 备份原文件
cp /etc/netplan/50-cloud-init.yaml /etc/netplan/50-cloud-init.yaml.bak

# 生成新的 IPv4 地址列表，每个地址追加 /24 并添加12个空格和“- ”
new_ips=$(awk '!seen[$0]++ {print "            - "$1"/24"}' ip)

# 用 awk 替换 addresses 块中包含点号的 IPv4 地址
awk -v new_ips="$new_ips" '
/^ {12}addresses:/ {print; in_block=1; next}
in_block && /^ {12}-/ {
    if ($0 ~ /\./) next   # 跳过 IPv4 地址
    if (!printed) { print new_ips; printed=1 }
    print; next
}
in_block { 
    if (!printed) { print new_ips; printed=1 }
    in_block=0
}
{ print }
' /etc/netplan/50-cloud-init.yaml > /tmp/50-cloud-init.yaml

# 覆盖原文件
mv /tmp/50-cloud-init.yaml /etc/netplan/50-cloud-init.yaml

# 打印修改后的文件
cat /etc/netplan/50-cloud-init.yaml
chmod 600 /etc/netplan/50-cloud-init.yaml
sudo systemctl restart systemd-resolved

# 执行 netplan apply
netplan apply
