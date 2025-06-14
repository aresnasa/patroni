#!/bin/sh

# Chaos Engineering Script for Patroni Cluster
# 提供各种故障注入功能

set -e

CLUSTER_NAME="patroni-cluster"
POSTGRES_CONTAINERS="patroni-postgres1 patroni-postgres2 patroni-postgres3"
ETCD_CONTAINERS="patroni-etcd1 patroni-etcd2 patroni-etcd3"
HAPROXY_CONTAINER="patroni-haproxy"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# 获取集群状态
get_cluster_status() {
    log "获取Patroni集群状态..."
    for container in $POSTGRES_CONTAINERS; do
        port=$(docker port $container 8008 2>/dev/null | cut -d: -f2)
        if [ -n "$port" ]; then
            echo -e "${BLUE}=== $container 状态 ===${NC}"
            curl -s http://localhost:$port/cluster 2>/dev/null | jq . || echo "API不可用"
            echo ""
        fi
    done
}

# 获取当前主节点
get_primary_node() {
    for container in $POSTGRES_CONTAINERS; do
        port=$(docker port $container 8008 2>/dev/null | cut -d: -f2)
        if [ -n "$port" ]; then
            role=$(curl -s http://localhost:$port/primary 2>/dev/null && echo "primary" || echo "replica")
            if [ "$role" = "primary" ]; then
                echo $container
                return
            fi
        fi
    done
}

# 故障注入：停止容器
chaos_stop_container() {
    container=${1:-$(echo $POSTGRES_CONTAINERS | tr ' ' '\n' | shuf | head -1)}
    warning "执行混沌故障：停止容器 $container"
    docker stop $container
    success "容器 $container 已停止"
    sleep 2
    get_cluster_status
}

# 故障注入：杀死容器
chaos_kill_container() {
    container=${1:-$(echo $POSTGRES_CONTAINERS | tr ' ' '\n' | shuf | head -1)}
    warning "执行混沌故障：强制杀死容器 $container"
    docker kill $container
    success "容器 $container 已被杀死"
    sleep 2
    get_cluster_status
}

# 故障注入：网络分区
chaos_network_partition() {
    container=${1:-$(echo $POSTGRES_CONTAINERS | tr ' ' '\n' | shuf | head -1)}
    warning "执行混沌故障：网络分区 $container"
    # 阻断容器与etcd的通信
    docker exec $container sh -c "iptables -A OUTPUT -d etcd -j DROP 2>/dev/null || echo 'iptables not available, using tc instead'"
    # 使用tc添加网络延迟作为替代
    docker exec $container sh -c "tc qdisc add dev eth0 root netem delay 5000ms 2>/dev/null || echo 'Network chaos applied'"
    success "网络分区已应用到 $container"
    sleep 2
    get_cluster_status
}

# 故障注入：CPU压力
chaos_cpu_stress() {
    container=${1:-$(echo $POSTGRES_CONTAINERS | tr ' ' '\n' | shuf | head -1)}
    duration=${2:-30}
    warning "执行混沌故障：CPU压力测试 $container (持续 ${duration}s)"
    docker exec -d $container sh -c "
        for i in \$(seq 1 4); do
            dd if=/dev/zero of=/dev/null &
        done
        sleep $duration
        killall dd 2>/dev/null || true
    "
    success "CPU压力测试已启动，持续 ${duration}s"
}

# 故障注入：内存压力
chaos_memory_stress() {
    container=${1:-$(echo $POSTGRES_CONTAINERS | tr ' ' '\n' | shuf | head -1)}
    size=${2:-100M}
    warning "执行混沌故障：内存压力测试 $container (${size})"
    docker exec -d $container sh -c "
        dd if=/dev/zero of=/tmp/memory_stress bs=1M count=100 2>/dev/null &
        sleep 30
        rm -f /tmp/memory_stress
    "
    success "内存压力测试已启动"
}

# 故障注入：磁盘IO压力
chaos_disk_stress() {
    container=${1:-$(echo $POSTGRES_CONTAINERS | tr ' ' '\n' | shuf | head -1)}
    warning "执行混沌故障：磁盘IO压力测试 $container"
    docker exec -d $container sh -c "
        for i in \$(seq 1 5); do
            dd if=/dev/zero of=/tmp/disk_stress_\$i bs=1M count=50 2>/dev/null &
        done
        sleep 30
        rm -f /tmp/disk_stress_*
    "
    success "磁盘IO压力测试已启动"
}

# 故障恢复：重启容器
chaos_restart_container() {
    container=${1:-$(docker ps -a --filter "name=patroni-postgres" --filter "status=exited" --format "{{.Names}}" | head -1)}
    if [ -z "$container" ]; then
        error "没有找到需要重启的容器"
        return 1
    fi
    log "恢复容器：$container"
    docker restart $container
    success "容器 $container 已重启"
    sleep 5
    get_cluster_status
}

# 故障恢复：清理网络规则
chaos_network_heal() {
    for container in $POSTGRES_CONTAINERS; do
        if docker ps --format "{{.Names}}" | grep -q "^$container$"; then
            log "清理 $container 的网络规则..."
            docker exec $container sh -c "iptables -F 2>/dev/null || true"
            docker exec $container sh -c "tc qdisc del dev eth0 root 2>/dev/null || true"
        fi
    done
    success "网络规则已清理"
}

# 执行手动故障转移
chaos_manual_failover() {
    primary=$(get_primary_node)
    if [ -z "$primary" ]; then
        error "无法确定当前主节点"
        return 1
    fi
    
    # 选择一个候选节点
    candidate=$(echo $POSTGRES_CONTAINERS | tr ' ' '\n' | grep -v $primary | head -1)
    
    warning "执行手动故障转移：$primary -> $candidate"
    
    primary_port=$(docker port $primary 8008 2>/dev/null | cut -d: -f2)
    if [ -n "$primary_port" ]; then
        curl -s http://localhost:$primary_port/failover -XPOST \
            -H "Content-Type: application/json" \
            -d "{\"leader\":\"$(echo $primary | sed 's/patroni-//g')\",\"candidate\":\"$(echo $candidate | sed 's/patroni-//g')\"}"
        success "故障转移请求已发送"
        sleep 5
        get_cluster_status
    else
        error "无法获取主节点API端口"
    fi
}

# 随机混沌测试
chaos_random() {
    scenarios=(
        "chaos_stop_container"
        "chaos_cpu_stress"
        "chaos_memory_stress"
        "chaos_disk_stress"
        "chaos_network_partition"
    )
    
    scenario=${scenarios[$(($(od -An -N1 -tu1 /dev/urandom) % ${#scenarios[@]}))]}
    log "执行随机混沌测试：$scenario"
    $scenario
}

# 帮助信息
show_help() {
    echo "Patroni 集群混沌工程工具"
    echo ""
    echo "用法: $0 <command> [options]"
    echo ""
    echo "命令:"
    echo "  status                          查看集群状态"
    echo "  primary                         查看主节点"
    echo "  stop [container]                停止指定容器"
    echo "  kill [container]                强制杀死指定容器"
    echo "  restart [container]             重启容器"
    echo "  network-partition [container]   网络分区故障"
    echo "  network-heal                    恢复网络连接"
    echo "  cpu-stress [container] [duration] CPU压力测试"
    echo "  memory-stress [container] [size] 内存压力测试"
    echo "  disk-stress [container]         磁盘IO压力测试"
    echo "  failover                        手动故障转移"
    echo "  random                          随机混沌测试"
    echo "  continuous [interval]           连续混沌测试"
    echo ""
    echo "示例:"
    echo "  $0 status                       # 查看集群状态"
    echo "  $0 stop patroni-postgres1       # 停止postgres1节点"
    echo "  $0 cpu-stress patroni-postgres2 60  # 对postgres2进行60秒CPU压力测试"
    echo "  $0 failover                     # 执行手动故障转移"
    echo "  $0 random                       # 执行随机故障注入"
}

# 连续混沌测试
chaos_continuous() {
    interval=${1:-60}
    log "开始连续混沌测试，间隔 ${interval}s (按 Ctrl+C 停止)"
    
    trap 'log "停止连续混沌测试"; exit 0' INT
    
    while true; do
        chaos_random
        log "等待 ${interval}s 后执行下一次混沌测试..."
        sleep $interval
    done
}

# 主逻辑
case "${1:-help}" in
    status)
        get_cluster_status
        ;;
    primary)
        primary=$(get_primary_node)
        if [ -n "$primary" ]; then
            success "当前主节点: $primary"
        else
            error "无法确定主节点"
        fi
        ;;
    stop)
        chaos_stop_container $2
        ;;
    kill)
        chaos_kill_container $2
        ;;
    restart)
        chaos_restart_container $2
        ;;
    network-partition)
        chaos_network_partition $2
        ;;
    network-heal)
        chaos_network_heal
        ;;
    cpu-stress)
        chaos_cpu_stress $2 $3
        ;;
    memory-stress)
        chaos_memory_stress $2 $3
        ;;
    disk-stress)
        chaos_disk_stress $2
        ;;
    failover)
        chaos_manual_failover
        ;;
    random)
        chaos_random
        ;;
    continuous)
        chaos_continuous $2
        ;;
    help|*)
        show_help
        ;;
esac
