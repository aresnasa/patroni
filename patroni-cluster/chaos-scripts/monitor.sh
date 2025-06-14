#!/bin/bash

# Patroni 集群监控脚本

set -e

MONITOR_INTERVAL=${1:-5}
LOG_FILE="/tmp/patroni_monitor.log"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_with_timestamp() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a $LOG_FILE
}

monitor_cluster() {
    clear
    echo -e "${BLUE}======== Patroni 集群实时监控 ========${NC}"
    echo -e "${BLUE}监控间隔: ${MONITOR_INTERVAL}s | 日志文件: $LOG_FILE${NC}"
    echo -e "${BLUE}按 Ctrl+C 停止监控${NC}"
    echo ""
    
    while true; do
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        echo -e "${BLUE}[$timestamp] 集群状态检查${NC}"
        
        # 检查容器状态
        echo -e "${YELLOW}=== 容器状态 ===${NC}"
        docker ps --filter "name=patroni-" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | \
        while read line; do
            if echo "$line" | grep -q "Up"; then
                echo -e "${GREEN}$line${NC}"
            else
                echo -e "${RED}$line${NC}"
                log_with_timestamp "容器异常: $line"
            fi
        done
        
        echo ""
        echo -e "${YELLOW}=== Patroni 集群信息 ===${NC}"
        
        # 检查每个PostgreSQL节点
        for port in 8008 8009 8010; do
            node_info=$(curl -s --connect-timeout 2 http://localhost:$port/patroni 2>/dev/null)
            if [ $? -eq 0 ] && [ -n "$node_info" ]; then
                name=$(echo "$node_info" | jq -r '.patroni.name // "unknown"')
                role=$(echo "$node_info" | jq -r '.role // "unknown"')
                state=$(echo "$node_info" | jq -r '.state // "unknown"')
                
                if [ "$role" = "primary" ]; then
                    echo -e "${GREEN}节点 $name (端口:$port): $role - $state${NC}"
                else
                    echo -e "${BLUE}节点 $name (端口:$port): $role - $state${NC}"
                fi
                
                # 检查复制延迟
                if [ "$role" = "replica" ]; then
                    lag=$(echo "$node_info" | jq -r '.xlog.received_location // 0')
                    echo -e "  ${YELLOW}复制位置: $lag${NC}"
                fi
            else
                echo -e "${RED}节点 (端口:$port): API 不可达${NC}"
                log_with_timestamp "节点 API 不可达: 端口 $port"
            fi
        done
        
        echo ""
        echo -e "${YELLOW}=== HAProxy 状态 ===${NC}"
        haproxy_status=$(curl -s --connect-timeout 2 http://localhost:17000 2>/dev/null && echo "OK" || echo "FAILED")
        if [ "$haproxy_status" = "OK" ]; then
            echo -e "${GREEN}HAProxy 统计页面: 可访问 (http://localhost:17000)${NC}"
        else
            echo -e "${RED}HAProxy 统计页面: 不可访问${NC}"
            log_with_timestamp "HAProxy 统计页面不可访问"
        fi
        
        # 测试数据库连接
        echo ""
        echo -e "${YELLOW}=== 数据库连接测试 ===${NC}"
        for port in 15432 15433 15434; do
            timeout 3 nc -z localhost $port 2>/dev/null
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}PostgreSQL 端口 $port: 连接正常${NC}"
            else
                echo -e "${RED}PostgreSQL 端口 $port: 连接失败${NC}"
                log_with_timestamp "PostgreSQL 连接失败: 端口 $port"
            fi
        done
        
        # HAProxy连接测试
        timeout 3 nc -z localhost 15000 2>/dev/null
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}HAProxy PostgreSQL 代理: 连接正常${NC}"
        else
            echo -e "${RED}HAProxy PostgreSQL 代理: 连接失败${NC}"
            log_with_timestamp "HAProxy 代理连接失败"
        fi
        
        echo ""
        echo -e "${BLUE}下次检查时间: $(date -d "+${MONITOR_INTERVAL} seconds" '+%H:%M:%S')${NC}"
        echo "----------------------------------------"
        
        sleep $MONITOR_INTERVAL
    done
}

# 信号处理
trap 'echo -e "\n${YELLOW}监控已停止${NC}"; exit 0' INT

# 开始监控
monitor_cluster
