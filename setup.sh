#!/bin/bash

echo "========================================="
echo "  4网口小主机 - 纯安装脚本"
echo "  不清理，直接创建网桥 + rtp2httpd"
echo "  固定 IP: 192.168.1.56"
echo "========================================="
echo ""

# ========================================
# 检查当前网络
# ========================================
echo "📡 检查当前网络..."
CURRENT_IP=$(ip addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v 127.0.0.1 | head -1)
echo "  当前 IP: $CURRENT_IP"
echo ""

if [ -z "$CURRENT_IP" ]; then
    echo "❌ 无法获取当前 IP"
    exit 1
fi

read -p "确认继续？(y/N): " confirm
if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo "已取消"
    exit 0
fi

# ========================================
# 1. 加载内核模块
# ========================================
echo ""
echo "🔧 加载内核模块..."
modprobe bridge
modprobe 8021q

# ========================================
# 2. 创建 br0（主网络）
# ========================================
echo ""
echo "🔧 创建 br0（主网络）..."

# 如果 br0 已存在，先删除
if ip link show br0 >/dev/null 2>&1; then
    echo "  br0 已存在，先删除..."
    ip link set br0 down 2>/dev/null
    brctl delbr br0 2>/dev/null
    ip link delete br0 type bridge 2>/dev/null
fi

# 创建网桥
brctl addbr br0
brctl stp br0 off
brctl setfd br0 0

# 添加物理网口
echo "  将 enp1s0 加入 br0..."
brctl addif br0 enp1s0 2>/dev/null || echo "  ⚠️  enp1s0 加入失败"
echo "  将 enp2s0 加入 br0..."
brctl addif br0 enp2s0 2>/dev/null || echo "  ⚠️  enp2s0 加入失败"

# 配置 IP
ip addr flush dev br0 2>/dev/null
ip addr add 192.168.1.56/24 dev br0

# 启用
ip link set enp1s0 up 2>/dev/null
ip link set enp2s0 up 2>/dev/null
ip link set br0 up

# 设置路由
ip route del default 2>/dev/null
ip route add default via 192.168.1.1 dev br0

echo "✅ br0 配置完成，IP: 192.168.1.56"

# ========================================
# 3. 创建 br1（IPTV 网络）
# ========================================
echo ""
echo "🔧 创建 br1（IPTV 网络）..."

# 如果 br1 已存在，先删除
if ip link show br1 >/dev/null 2>&1; then
    echo "  br1 已存在，先删除..."
    ip link set br1 down 2>/dev/null
    brctl delbr br1 2>/dev/null
    ip link delete br1 type bridge 2>/dev/null
fi

# 创建网桥
brctl addbr br1
brctl stp br1 off
brctl setfd br1 0

# 设置 MAC
ip link set br1 address FC:57:03:4D:39:4E

# 禁用 IPv6
echo 1 > /proc/sys/net/ipv6/conf/br1/disable_ipv6
sysctl -w net.ipv6.conf.br1.disable_ipv6=1 2>/dev/null

# 添加物理网口
echo "  将 enp3s0 加入 br1..."
brctl addif br1 enp3s0 2>/dev/null || echo "  ⚠️  enp3s0 加入失败"
echo "  将 enp4s0 加入 br1..."
brctl addif br1 enp4s0 2>/dev/null || echo "  ⚠️  enp4s0 加入失败"

# 启用
ip link set enp3s0 up 2>/dev/null
ip link set enp4s0 up 2>/dev/null
ip link set br1 up
ip link set br1 multicast on
ip link set br1 promisc on

# DHCP 获取 IP
echo "📡 br1 DHCP 获取 IP..."
dhclient -r br1 2>/dev/null
dhclient -v br1 2>/dev/null || /sbin/dhclient -v br1 2>/dev/null
sleep 5

BR1_IP=$(ip addr show br1 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
if [ -z "$BR1_IP" ]; then
    echo "⚠️  DHCP 失败，尝试 dhcpcd..."
    systemctl start dhcpcd 2>/dev/null
    dhcpcd -n br1 2>/dev/null
    sleep 3
    BR1_IP=$(ip addr show br1 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
fi

if [ -z "$BR1_IP" ]; then
    echo "❌ DHCP 失败！请检查 enp3s0 是否连接 IPTV"
else
    echo "✅ br1 IP: $BR1_IP"
fi

# 组播路由
ip route add 224.0.0.0/4 dev br1 2>/dev/null

# ========================================
# 4. 持久化配置
# ========================================
echo ""
echo "💾 写入持久化配置..."

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
    dns-nameservers 8.8.8.8 114.114.114.114
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

echo "✅ 持久化配置已写入"

# ========================================
# 5. 安装 rtp2httpd
# ========================================
echo ""
echo "🚀 安装 rtp2httpd..."

# 停止旧容器
docker stop rtp2httpd 2>/dev/null
docker rm rtp2httpd 2>/dev/null

# 创建启动脚本
cat > /usr/local/bin/rtp2httpd-start.sh << 'EOF'
#!/bin/bash
BR1_IP=$(ip addr show br1 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
if [ -z "$BR1_IP" ]; then
    dhclient -v br1 2>/dev/null || /sbin/dhclient -v br1 2>/dev/null
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
echo "✅ rtp2httpd 启动成功，br1 IP: $BR1_IP"
EOF

chmod +x /usr/local/bin/rtp2httpd-start.sh

# 拉取镜像
echo "拉取 rtp2httpd 镜像..."
docker pull ghcr.io/stackia/rtp2httpd:latest

# 启动
/usr/local/bin/rtp2httpd-start.sh

# ========================================
# 6. 验证
# ========================================
echo ""
echo "========================================="
echo "  ✅ 安装完成！"
echo "========================================="

BR1_IP=$(ip addr show br1 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)

echo ""
echo "📊 网络配置："
echo "┌─────────────────────────────────────────┐"
echo "│ br0 (主网络/管理口):                    │"
echo "│   IP: 192.168.1.56                     │"
echo "│   成员: enp1s0 + enp2s0               │"
echo "├─────────────────────────────────────────┤"
echo "│ br1 (IPTV 网络):                       │"
echo "│   IP: $BR1_IP                          │"
echo "│   MAC: FC:57:03:4D:39:4E              │"
echo "│   IPv6: 已禁用                         │"
echo "│   成员: enp3s0 + enp4s0               │"
echo "└─────────────────────────────────────────┘"

echo ""
echo "📊 服务状态："
docker ps | grep rtp2httpd

echo ""
echo "📋 端口监听："
ss -uln | grep 5140 || echo "⚠️  端口 5140 未监听"

echo ""
echo "📝 容器日志："
docker logs rtp2httpd --tail 10

echo ""
echo "🌐 访问地址："
echo "  状态页面: http://192.168.1.56:8080/status"
if [ -n "$BR1_IP" ]; then
    echo "  RTP 流:   rtp://$BR1_IP:5140"
fi

echo ""
echo "📌 管理命令："
echo "  查看日志: docker logs -f rtp2httpd"
echo "  重启服务: docker restart rtp2httpd"
echo "  停止服务: docker stop rtp2httpd"

# ========================================
# 7. 自动重启
# ========================================
echo ""
echo "========================================="
echo "  🔄 系统将在 10 秒后重启..."
echo "  按 Ctrl+C 取消重启"
echo "========================================="

sleep 10

# 使用完整路径重启
/sbin/reboot
