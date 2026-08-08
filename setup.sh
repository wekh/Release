#!/bin/bash

echo "========================================="
echo "  4网口小主机 - 完整安装脚本"
echo "  固定 IP: 192.168.1.56"
echo "========================================="
echo ""

# ========================================
# 第一步：设置固定 IP
# ========================================
CURRENT_IP="192.168.1.56"
CURRENT_GATEWAY="192.168.1.1"
DEFAULT_IFACE="enp1s0"

echo "📡 将配置以下网络："
echo "  管理网口: $DEFAULT_IFACE"
echo "  固定 IP: $CURRENT_IP"
echo "  网关: $CURRENT_GATEWAY"
echo ""

read -p "确认继续？(y/N): " confirm

if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo "已取消"
    exit 0
fi

# ========================================
# 第二步：加载内核模块
# ========================================
echo ""
echo "🔧 加载内核模块..."
modprobe bridge
modprobe 8021q
modprobe bonding

# ========================================
# 第三步：创建 br0（主网络）
# ========================================
echo ""
echo "🔧 创建 br0（主网络）..."

# 检查并清理旧的 br0
ip link set br0 down 2>/dev/null
brctl delbr br0 2>/dev/null
ip link delete br0 type bridge 2>/dev/null

# 创建网桥
brctl addbr br0
brctl stp br0 off
brctl setfd br0 0

# 添加物理网口（enp1s0 + enp2s0）
echo "  将 enp1s0 加入 br0..."
brctl addif br0 enp1s0 2>/dev/null || echo "  ⚠️  enp1s0 加入失败，请检查"

echo "  将 enp2s0 加入 br0..."
brctl addif br0 enp2s0 2>/dev/null || echo "  ⚠️  enp2s0 加入失败，请检查"

# 配置 br0 IP（固定 192.168.1.56）
ip addr flush dev br0 2>/dev/null
ip addr add 192.168.1.56/24 dev br0

# 启用
ip link set enp1s0 up 2>/dev/null
ip link set enp2s0 up 2>/dev/null
ip link set br0 up

# 设置默认路由
ip route del default 2>/dev/null
ip route add default via 192.168.1.1 dev br0

echo "✅ br0 配置完成，IP: 192.168.1.56"

# ========================================
# 第四步：迁移管理口
# ========================================
echo ""
echo "🔄 迁移管理口到 br0..."

# 清除原网卡的 IP
ip addr flush dev enp1s0 2>/dev/null
ip link set enp1s0 up 2>/dev/null
ip addr flush dev enp2s0 2>/dev/null
ip link set enp2s0 up 2>/dev/null

# 测试连接
if ping -c 2 192.168.1.1 >/dev/null 2>&1; then
    echo "✅ 网络正常，br0 工作正常"
else
    echo "⚠️  网络可能有问题，但继续..."
fi

# ========================================
# 第五步：创建 br1（IPTV 网络）
# ========================================
echo ""
echo "🔧 创建 br1（IPTV 网络）..."

# 检查并清理旧的 br1
ip link set br1 down 2>/dev/null
brctl delbr br1 2>/dev/null
ip link delete br1 type bridge 2>/dev/null

# 创建网桥
brctl addbr br1
brctl stp br1 off
brctl setfd br1 0

# 设置 MAC 地址
ip link set br1 address FC:57:03:4D:39:4E

# 禁用 IPv6
echo 1 > /proc/sys/net/ipv6/conf/br1/disable_ipv6
sysctl -w net.ipv6.conf.br1.disable_ipv6=1 2>/dev/null

# 添加物理网口（enp3s0 + enp4s0）
echo "  将 enp3s0 加入 br1..."
brctl addif br1 enp3s0 2>/dev/null || echo "  ⚠️  enp3s0 加入失败，请检查"

echo "  将 enp4s0 加入 br1..."
brctl addif br1 enp4s0 2>/dev/null || echo "  ⚠️  enp4s0 加入失败，请检查"

# 启用
ip link set enp3s0 up 2>/dev/null
ip link set enp4s0 up 2>/dev/null
ip link set br1 up
ip link set br1 multicast on
ip link set br1 promisc on

# DHCP 获取 IP
echo "📡 br1 通过 DHCP 获取 IP..."
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
    echo "❌ DHCP 失败！请检查 enp3s0 是否连接 IPTV 网络"
else
    echo "✅ br1 IP: $BR1_IP"
fi

# 组播路由
ip route add 224.0.0.0/4 dev br1 2>/dev/null

# ========================================
# 第六步：持久化配置
# ========================================
echo ""
echo "💾 写入持久化配置..."

cat > /etc/network/interfaces << 'EOF'
# /etc/network/interfaces
auto lo
iface lo inet loopback

# br0 - 主网络（管理口）
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
# 第七步：安装 rtp2httpd
# ========================================
echo ""
echo "🚀 安装 rtp2httpd..."

# 停止旧容器
docker stop rtp2httpd 2>/dev/null
docker rm rtp2httpd 2>/dev/null

# 拉取镜像
echo "拉取 rtp2httpd 镜像..."
docker pull ghcr.io/stackia/rtp2httpd:latest

# 创建启动脚本
cat > /usr/local/bin/rtp2httpd-start.sh << 'EOF'
#!/bin/bash
BR1_IP=$(ip addr show br1 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)

if [ -z "$BR1_IP" ]; then
    echo "br1 没有 IP，正在 DHCP..."
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

# 启动 rtp2httpd
/usr/local/bin/rtp2httpd-start.sh

# ========================================
# 第八步：验证
# ========================================
echo ""
echo "========================================="
echo "  ✅ 安装完成！"
echo "========================================="
echo ""
echo "📊 网络配置："
echo "┌─────────────────────────────────────────┐"
echo "│ br0 (主网络/管理口):                    │"
echo "│   IP: 192.168.1.56                     │"
echo "│   成员: enp1s0 (光猫上网口), enp2s0   │"
echo "├─────────────────────────────────────────┤"
echo "│ br1 (IPTV 网络):                       │"
BR1_IP=$(ip addr show br1 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
echo "│   IP: $BR1_IP                        │"
echo "│   MAC: FC:57:03:4D:39:4E             │"
echo "│   IPv6: 已禁用                        │"
echo "│   成员: enp3s0 (光猫IPTV口), enp4s0  │"
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
echo "  重启网络: systemctl restart networking"
echo "========================================="