#!/bin/bash

echo "========================================="
echo "  安全清理脚本 - 先脱离网桥"
echo "========================================="
echo ""

# ========================================
# 第一步：检测当前连接信息
# ========================================
echo "📡 检测当前网络连接..."

# 获取当前默认网卡
DEFAULT_IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
if [ -z "$DEFAULT_IFACE" ]; then
    DEFAULT_IFACE=$(ip route | grep -E "^[0-9]+\." | head -1 | awk '{print $3}')
fi

# 获取当前网卡 IP
CURRENT_IP=$(ip addr show $DEFAULT_IFACE | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
CURRENT_GATEWAY=$(ip route | grep default | awk '{print $3}' | head -1)

echo "  当前网卡: $DEFAULT_IFACE"
echo "  当前 IP: $CURRENT_IP"
echo "  当前网关: $CURRENT_GATEWAY"

if [ -z "$CURRENT_IP" ]; then
    echo "❌ 无法获取当前 IP"
    exit 1
fi

echo ""
echo "⚠️  将保留网卡 $DEFAULT_IFACE 的 IP: $CURRENT_IP"
read -p "确认继续？(y/N): " confirm

if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo "已取消"
    exit 0
fi

# ========================================
# 第二步：先把当前网卡从网桥中移出
# ========================================
echo ""
echo "🔧 将 $DEFAULT_IFACE 从网桥中移出..."

# 检查当前网卡是否在某个网桥中
BRIDGE_NAME=$(brctl show | grep -E "\b${DEFAULT_IFACE}\b" | awk '{print $1}' | head -1)

if [ -n "$BRIDGE_NAME" ]; then
    echo "  $DEFAULT_IFACE 在网桥 $BRIDGE_NAME 中，正在移出..."
    
    # 从网桥中移出
    brctl delif $BRIDGE_NAME $DEFAULT_IFACE 2>/dev/null
    
    # 等待一秒
    sleep 1
    
    # 重新配置 IP
    ip addr flush dev $DEFAULT_IFACE 2>/dev/null
    ip addr add $CURRENT_IP/24 dev $DEFAULT_IFACE
    ip link set $DEFAULT_IFACE up
    ip route add default via $CURRENT_GATEWAY dev $DEFAULT_IFACE 2>/dev/null
    
    echo "  ✅ $DEFAULT_IFACE 已从 $BRIDGE_NAME 移出，IP 已恢复"
else
    echo "  $DEFAULT_IFACE 不在任何网桥中，跳过"
fi

# ========================================
# 第三步：测试连接是否正常
# ========================================
echo ""
echo "🧪 测试连接..."
if ping -c 2 $CURRENT_GATEWAY >/dev/null 2>&1; then
    echo "  ✅ 网络正常，SSH 连接安全"
else
    echo "  ⚠️  网关不通，请检查"
fi

# ========================================
# 第四步：写入 /etc/network/interfaces
# ========================================
echo ""
echo "💾 保存配置到 /etc/network/interfaces..."

cat > /etc/network/interfaces << EOF
# /etc/network/interfaces
auto lo
iface lo inet loopback

# 管理网口 $DEFAULT_IFACE - 保留当前 IP
auto $DEFAULT_IFACE
iface $DEFAULT_IFACE inet static
    address $CURRENT_IP
    netmask 255.255.255.0
    gateway $CURRENT_GATEWAY
    dns-nameservers 8.8.8.8 114.114.114.114
EOF

echo "  ✅ 配置已保存"

# ========================================
# 第五步：开始清理（现在安全了）
# ========================================
echo ""
echo "========================================="
echo "  🗑️  开始清理网络"
echo "========================================="

# 1. 停止容器
echo "停止容器..."
docker stop rtp2httpd 2>/dev/null
docker rm rtp2httpd 2>/dev/null

# 2. 删除网桥（当前网卡已经不在网桥中）
echo "删除网桥..."
for br in $(brctl show | grep -v "bridge name" | awk '{print $1}'); do
    echo "  删除网桥: $br"
    # 先把所有端口移出
    for port in $(brctl show $br | grep -v "bridge name" | awk '{print $4}' | grep -v "^$"); do
        brctl delif $br $port 2>/dev/null
    done
    ip link set $br down 2>/dev/null
    brctl delbr $br 2>/dev/null
    ip link delete $br type bridge 2>/dev/null
done

# 3. 清理其他网口（保留当前网卡）
echo "清理其他网口..."
for iface in $(ip link show | grep -E "^[0-9]+: enp|^[0-9]+: eth" | awk -F': ' '{print $2}'); do
    if [ "$iface" != "$DEFAULT_IFACE" ]; then
        echo "  清理 $iface"
        ip addr flush dev $iface 2>/dev/null
        ip link set $iface down 2>/dev/null
    fi
done

# 4. 删除配置文件
echo "删除配置文件..."
rm -f /etc/network/interfaces.d/* 2>/dev/null
rm -f /usr/local/bin/*setup.sh 2>/dev/null
rm -f /usr/local/bin/*start.sh 2>/dev/null

# 5. 清除 DHCP 租约
echo "清除 DHCP 租约..."
rm -f /var/lib/dhcp/dhclient.leases 2>/dev/null
rm -f /var/lib/dhcpcd/* 2>/dev/null

# 6. 清除路由
echo "清除路由..."
ip route del 224.0.0.0/4 2>/dev/null

# ========================================
# 第六步：再次确保 IP 正常
# ========================================
echo ""
echo "🔄 再次确认 IP..."
ip addr flush dev $DEFAULT_IFACE 2>/dev/null
ip addr add $CURRENT_IP/24 dev $DEFAULT_IFACE
ip link set $DEFAULT_IFACE up
ip route add default via $CURRENT_GATEWAY dev $DEFAULT_IFACE 2>/dev/null

# ========================================
# 第七步：验证
# ========================================
echo ""
echo "========================================="
echo "  ✅ 清理完成！"
echo "========================================="
echo ""
echo "📊 当前网络状态："
echo ""
echo "--- 管理网口: $DEFAULT_IFACE ---"
ip addr show $DEFAULT_IFACE | grep inet
echo ""
echo "--- 网关 ---"
ip route | grep default
echo ""
echo "--- 网桥 ---"
brctl show 2>/dev/null || echo "  无网桥"
echo ""
echo "========================================="
echo "📌 后续操作："
echo "  1. SSH 连接保持: $CURRENT_IP"
echo "  2. 现在可以安全运行设置脚本"
echo "========================================="
