#!/bin/bash

# Patroni 集群管理脚本

set -e

CLUSTER_DIR="/Users/aresnasa/MyProjects/py3/patroni/patroni-cluster"
COMPOSE_FILE="$CLUSTER_DIR/docker-compose.yml"

cd "$CLUSTER_DIR"

case "$1" in
    start)
        echo "启动 Patroni 集群..."
        docker-compose up -d
        echo "等待服务启动..."
        sleep 10
        echo "集群状态:"
        docker-compose ps
        ;;
    stop)
        echo "停止 Patroni 集群..."
        docker-compose down
        ;;
    restart)
        echo "重启 Patroni 集群..."
        docker-compose down
        docker-compose up -d
        ;;
    status)
        echo "=== Docker 容器状态 ==="
        docker-compose ps
        echo
        echo "=== Patroni 集群状态 ==="
        curl -s http://localhost:8008/cluster | python3 -m json.tool 2>/dev/null || echo "无法获取集群状态"
        ;;
    logs)
        if [ -z "$2" ]; then
            docker-compose logs -f
        else
            docker-compose logs -f "$2"
        fi
        ;;
    clean)
        echo "清理集群 (包括数据卷)..."
        docker-compose down -v
        docker system prune -f
        ;;
    failover)
        if [ -z "$2" ] || [ -z "$3" ]; then
            echo "用法: $0 failover <current_leader> <new_leader>"
            echo "例如: $0 failover postgres postgres"
            exit 1
        fi
        echo "执行故障转移: $2 -> $3"
        curl -s http://localhost:8008/failover -XPOST \
            -H "Content-Type: application/json" \
            -d "{\"leader\":\"$2\",\"candidate\":\"$3\"}"
        ;;
    connect)
        case "$2" in
            postgres1)
                echo "连接到PostgreSQL节点1 (直连)..."
                echo "psql -h localhost -p 15432 -U postgres"
                ;;
            postgres2)
                echo "连接到PostgreSQL节点2 (直连)..."
                echo "psql -h localhost -p 15433 -U postgres"
                ;;
            postgres3)
                echo "连接到PostgreSQL节点3 (直连)..."
                echo "psql -h localhost -p 15434 -U postgres"
                ;;
            primary)
                echo "连接到HAProxy主库代理..."
                echo "psql -h localhost -p 15000 -U postgres"
                ;;
            replica)
                echo "连接到HAProxy副本代理..."
                echo "psql -h localhost -p 15001 -U postgres"
                ;;
            all)
                echo "连接到HAProxy所有节点..."
                echo "psql -h localhost -p 15002 -U postgres"
                ;;
            *)
                echo "用法: $0 connect [postgres1|postgres2|postgres3|primary|replica|all]"
                echo "直连节点: $0 connect postgres1"
                echo "HAProxy主库: $0 connect primary"
                echo "HAProxy副本: $0 connect replica"
                echo "HAProxy所有: $0 connect all"
                ;;
        esac
        ;;
    health)
        echo "=== 健康检查 ==="
        echo "PostgreSQL节点状态:"
        for port in 8008 8009 8010; do
            curl -s http://localhost:$port/primary >/dev/null 2>&1 && echo " ✓ 节点 $port: 正常" || echo " ✗ 节点 $port: 异常"
        done
        
        echo "HAProxy 统计页面: http://localhost:17000"
        echo "Patroni API 端点: http://localhost:8008, 8009, 8010"
        echo "混沌工程工具: ./chaos-scripts/chaos.sh"
        echo "实时监控: ./chaos-scripts/monitor.sh"
        ;;
    monitor)
        echo "启动集群监控..."
        exec ./chaos-scripts/monitor.sh ${2:-5}
        ;;
    chaos)
        if [ -z "$2" ]; then
            echo "混沌工程命令列表:"
            ./chaos-scripts/chaos.sh help
        else
            shift
            ./chaos-scripts/chaos.sh "$@"
        fi
        ;;
    *)
        echo "Patroni 集群管理脚本"
        echo
        echo "用法: $0 <command> [options]"
        echo
        echo "命令:"
        echo "  start          启动集群"
        echo "  stop           停止集群"
        echo "  restart        重启集群"
        echo "  status         查看集群状态"
        echo "  logs [service] 查看日志 (可选指定服务名)"
        echo "  clean          清理集群和数据"
        echo "  failover <current> <new>  手动故障转移"
        echo "  connect <type> 显示连接命令"
        echo "  health         健康检查"
        echo "  monitor [interval] 启动实时监控"
        echo "  chaos <command> 混沌工程命令"
        echo
        echo "示例:"
        echo "  $0 start                    # 启动集群"
        echo "  $0 logs postgres1           # 查看postgres1日志"
        echo "  $0 connect postgres1        # 显示postgres1连接命令"
        echo "  $0 connect primary          # 显示HAProxy主库连接命令"
        echo "  $0 monitor 3                # 启动3秒间隔的监控"
        echo "  $0 chaos status             # 查看集群状态"
        echo "  $0 chaos random             # 执行随机故障注入"
        ;;
esac
