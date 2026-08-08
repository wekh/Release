#!/bin/bash

echo "========================================="
echo "  4网口小主机 - 完整网络配置脚本"
echo "  包含：清除旧配置 + 新建桥接 + rtp2httpd"
echo "========================================="

# ========================================
# 第一部分：清除所有旧配置
# ========================================
echo ""
echo "🗑️  清除旧配置..."
echo ""

# 1. 停止并删除旧容器
echo "停止 rtp2httpd 容器..."
docker stop rtp2httpd 2>/dev/null
docker rm rtp2httpd 2>/dev/null

# 2. 停止并删除旧的网络配置
echo "停止旧的网络服务..."
systemctl stop networking 2>/dev/null
systemctl stop systemd-networkd 2>/dev/null
systemctl stop NetworkManager 2>/dev/null

# 3. 删除旧的网桥
echo "删除旧的网桥配置..."
ip link set br0 down 2>/dev/null
ip link set br1 down 2>/dev/null
brctl delbr br0 2>/dev/null
brctl delbr br1 2>/dev/null
ip link delete br0 type bridge 2>/dev/null
ip link delete br1 type bridge 2>/dev/null

# 4. 恢复物理网口（移除所有IP和配置）
echo "恢复物理网口..."
for iface in enp1s0 enp2s0 enp3s0 enp4s0; do
    ip addr flush dev $iface 2>/dev/null
    ip link set $iface down 2>/dev/null
done

# 5. 清除旧的网络配置文件
echo "清除旧的网络配置文件..."
rm -f /etc/network/interfaces.d/br0 2>/dev/null
rm -f /etc/network/interfaces.d/br1 2>/dev/null
rm -f /etc/network/interfaces.d/enp* 2>/dev/null

# 6. 删除旧的 DHCP 租约
echo "清除 DHCP 租约..."
rm -f /var/lib/dhcp/dhclient.leases 2>/dev/null
rm -f /var/lib/dhcpcd/* 2>/dev/null

echo "✅ 旧配置已清除"
sleep 2

# ========================================
# 第二部分：创建新的网络配置
# ========================================
echo ""
echo "========================================="
echo "  开始创建新的网络配置"
echo "========================================="

# 1. 加载 bridge 内核模块
echo ""
echo "🔧 加载 bridge 内核模块..."
modprobe bridge
modprobe 8021q

# 2. 创建 br0（主网络，上网用）
echo ""
echo "🔧 创建 br0（主网络）..."
brctl addbr br0
brctl stp br0 off
brctl setfd br0 0

# 3. 将 enp1s0 和 enp2s0 加入 br0
echo "将 enp1s0 和 enp2s0 加入 br0..."
brctl addif br0 enp1s0
brctl addif br0 enp2s0

# 4. 配置 br0 的 MAC 地址（使用 enp1s0 的 MAC）
MAC_BR0=$(cat /sys/class/net/enp1s0/address)
ip link set br0 address $MAC_BR0

# 5. 配置 br0 的静态 IP
echo "配置 br0 静态 IP: 192.168.1.56..."
ip addr flush dev br0 2>/dev/null
ip addr add 192.168.1.56/24 dev br0

# 6. 启用 br0 和物理网口
ip link set enp1s0 up
ip link set enp2s0 up
ip link set br0 up

# 7. 配置 br0 的默认路由
ip route del default 2>/dev/null
ip route add default via 192.168.1.1 dev br0

echo "✅ br0 配置完成，IP: 192.168.1.56"

# ========================================
# 8. 创建 br1（IPTV 网络）
# ========================================
echo ""
echo "🔧 创建 br1（IPTV 网络）..."

# 8.1 创建 br1
brctl addbr br1
brctl stp br1 off
brctl setfd br1 0

# 8.2 设置 MAC 地址为 FC:57:03:4D:39:4E
ip link set br1 address FC:57:03:4D:39:4E

# 8.3 禁止 IPv6
echo 1 > /proc/sys/net/ipv6/conf/br1/disable_ipv6
sysctl -w net.ipv6.conf.br1.disable_ipv6=1

# 8.4 将 enp3s0 和 enp4s0 加入 br1
echo "将 enp3s0 和 enp4s0 加入 br1..."
brctl addif br1 enp3s0
brctl addif br1 enp4s0

# 8.5 启用 br1 和物理网口
ip link set enp3s0 up
ip link set enp4s0 up
ip link set br1 up

# 8.6 开启组播和混杂模式（IPTV 需要）
ip link set br1 multicast on
ip link set br1 promisc on
ip link set enp3s0 multicast on
ip link set enp3s0 promisc on
ip link set enp4s0 multicast on
ip link set enp4s0 promisc on

# 8.7 通过 DHCP 获取 IP
echo "📡 br1 通过 DHCP 获取 IP..."
dhclient -r br1 2>/dev/null
dhclient -v br1 2>/dev/null || /sbin/dhclient -v br1 2>/dev/null
sleep 5

# 8.8 获取 IP
BR1_IP=$(ip addr show br1 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)

if [ -z "$BR1_IP" ]; then
    echo "⚠️ DHCP 失败，尝试 dhcpcd..."
    systemctl start dhcpcd 2>/dev/null
    dhcpcd -n br1 2>/dev/null
    sleep 3
    BR1_IP=$(ip addr show br1 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
fi

if [ -z "$BR1_IP" ]; then
    echo "❌ DHCP 失败！请检查 enp3s0 是否连接 IPTV 网络"
    echo "手动运行: dhclient -v br1"
else
    echo "✅ br1 配置完成，IP: $BR1_IP"
fi

# 8.9 添加组播路由
ip route add 224.0.0.0/4 dev br1 2>/dev/null

# ========================================
# 9. 配置持久化（重启后生效）
# ========================================
echo ""
echo "🔧 配置持久化（重启后生效）..."

# 9.1 创建 /etc/network/interfaces 配置
cat > /etc/network/interfaces << 'EOF'
# /etc/network/interfaces
auto lo
iface lo inet loopback

# br0 - 主网络
auto br0
iface br0 inet static
    address 192.168.1.56
    netmask 255.255.255.0
    gateway 192.168.1.1
    bridge_ports enp1s0 enp2s0
    bridge_stp off
    bridge_fd 0
    bridge_maxwait 0

# br1 - IPTV 网络
auto br1
iface br1 inet dhcp
    bridge_ports enp3s0 enp4s0
    bridge_stp off
    bridge_fd 0
    bridge_maxwait 0
    hwaddress FC:57:03:4D:39:4E
    pre-up echo 1 > /proc/sys/net/ipv6/conf/br1/disable_ipv6
    pre-up ip link set br1 multicast on
    pre-up ip link set br1 promisc on
EOF

# 9.2 创建系统启动脚本（确保 IPTV 配置）
cat > /usr/local/bin/iptv-setup.sh << 'EOF'
#!/bin/bash
# IPTV 网络配置启动脚本

# 启用 br1
ip link set br1 up
ip link set br1 multicast on
ip link set br1 promisc on

# 禁用 IPv6
echo 1 > /proc/sys/net/ipv6/conf/br1/disable_ipv6

# 获取 DHCP IP
dhclient -v br1 2>/dev/null || /sbin/dhclient -v br1 2>/dev/null

# 添加组播路由
ip route add 224.0.0.0/4 dev br1 2>/dev/null

# 启动 rtp2httpd
sleep 2
/usr/local/bin/rtp2httpd-start.sh
EOF

chmod +x /usr/local/bin/iptv-setup.sh

# ========================================
# 第三部分：启动 rtp2httpd
# ========================================
echo ""
echo "🚀 启动 rtp2httpd 服务..."

# 创建 rtp2httpd 启动脚本
cat > /usr/local/bin/rtp2httpd-start.sh << 'EOF'
#!/bin/bash
BR1_IP=$(ip addr show br1 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)

if [ -z "$BR1_IP" ]; then
    echo "br1 没有 IP，正在 DHCP..."
    dhclient -v br1
    sleep 3
    BR1_IP=$(ip addr show br1 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
fi

docker stop rtp2httpd 2>/dev/null
docker rm rtp2httpd 2>/dev/null

docker run -d \
  --name rtp2httpd \
  --network=host \
  --cap-add=NET_ADMIN \
  --ulimit memlock=-1:-1 \
  --restart always \
  ghcr.io/stackia/rtp2httpd:latest \
  --noconfig \
  --verbose 2 \
  --listen 5140 \
  --maxclients 5 \
  --upstream-interface-multicast br1

echo "rtp2httpd 启动成功，br1 IP: $BR1_IP"
EOF

chmod +x /usr/local/bin/rtp2httpd-start.sh

# 启动 rtp2httpd
/usr/local/bin/rtp2httpd-start.sh

# ========================================
# 第四部分：验证
# ========================================
echo ""
echo "========================================="
echo "  ✅ 配置完成！"
echo "========================================="

echo ""
echo "📊 网络配置："
echo "┌─────────────────────────────────────────────┐"
echo "│ br0 (上网)：                               │"
echo "│   IP: 192.168.1.56                         │"
echo "│   成员: enp1s0 (光猫上网口), enp2s0 (电脑)  │"
echo "├─────────────────────────────────────────────┤"
echo "│ br1 (IPTV)：                               │"
BR1_IP=$(ip addr show br1 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
echo "│   IP: $BR1_IP                              │"
echo "│   MAC: FC:57:03:4D:39:4E                  │"
echo "│   IPv6: 已禁用                             │"
echo "│   成员: enp3s0 (光猫IPTV口), enp4s0 (机顶盒)│"
echo "└─────────────────────────────────────────────┘"

echo ""
echo "📊 服务状态："
docker ps | grep rtp2httpd

echo ""
echo "📋 端口监听："
ss -uln | grep 5140 || echo "⚠️ 端口 5140 未监听"

echo ""
echo "📝 容器日志："
docker logs rtp2httpd --tail 10

echo ""
echo "🌐 访问地址："
echo "  状态页面: http://192.168.1.56:5140/status"
if [ -n "$BR1_IP" ]; then
    echo "  RTP 流:   rtp://$BR1_IP:5140"
fi

echo ""
echo "📌 管理命令："
echo "  查看日志: docker logs -f rtp2httpd"
echo "  重启服务: docker restart rtp2httpd"
echo "  停止服务: docker stop rtp2httpd"
echo "  重启网络: /usr/local/bin/iptv-setup.sh"
echo ""
echo "========================================="
echo "✅ 所有配置完成！"
echo "========================================="
