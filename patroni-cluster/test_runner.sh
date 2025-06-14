#!/bin/bash

# Patroni 集群完整测试启动脚本
# 启动集群、数据写入器、监控和故障注入

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="/tmp/patroni_test_logs"
mkdir -p $LOG_DIR

# PID文件
DATA_WRITER_PID_FILE="$LOG_DIR/data_writer.pid"
MONITOR_PID_FILE="$LOG_DIR/monitor.pid"

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

info() {
    echo -e "${PURPLE}[INFO]${NC} $1"
}

# 检查依赖
check_dependencies() {
    log "检查依赖..."
    
    # 检查Python3
    if ! command -v python3 &> /dev/null; then
        error "Python3 未安装"
        return 1
    fi
    
    # 检查并安装Python依赖
    local missing_packages=()
    
    if ! python3 -c "import psycopg2" 2>/dev/null; then
        missing_packages+=("psycopg2-binary")
    fi
    
    if ! python3 -c "import requests" 2>/dev/null; then
        missing_packages+=("requests")
    fi
    
    if ! python3 -c "import curses" 2>/dev/null; then
        warning "curses模块不可用，监控仪表板可能无法正常工作"
    fi
    
    if [ ${#missing_packages[@]} -gt 0 ]; then
        log "安装缺失的Python包: ${missing_packages[*]}"
        pip3 install "${missing_packages[@]}"
    fi
    
    # 检查Docker
    if ! command -v docker &> /dev/null; then
        error "Docker 未安装"
        return 1
    fi
    
    # 检查Docker Compose
    if ! command -v docker-compose &> /dev/null; then
        error "Docker Compose 未安装"
        return 1
    fi
    
    success "依赖检查完成"
    return 0
}

# 启动集群
start_cluster() {
    log "启动Patroni集群..."
    
    # 确保清理旧环境
    docker-compose down -v 2>/dev/null || true
    
    # 启动集群
    docker-compose up -d
    
    log "等待服务启动..."
    sleep 30
    
    # 检查etcd集群
    local etcd_ready=0
    for i in {1..3}; do
        if docker exec patroni-etcd$i etcdctl endpoint health &>/dev/null; then
            success "etcd$i 健康"
            ((etcd_ready++))
        else
            warning "etcd$i 状态异常"
        fi
    done
    
    if [ $etcd_ready -lt 2 ]; then
        error "etcd集群未正确启动 (只有$etcd_ready/3个节点健康)"
        return 1
    fi
    
    # 等待Patroni集群形成
    log "等待Patroni集群形成..."
    sleep 60
    
    # 检查集群状态
    local patroni_ready=0
    for port in 8008 8009 8010; do
        if curl -s http://localhost:$port/cluster >/dev/null 2>&1; then
            ((patroni_ready++))
        fi
    done
    
    if [ $patroni_ready -lt 2 ]; then
        error "Patroni集群未正确启动 (只有$patroni_ready/3个节点响应)"
        return 1
    fi
    
    success "集群启动完成"
    return 0
}

# 启动数据写入器
start_data_writer() {
    log "启动数据写入器..."
    
    # 停止现有的数据写入器
    stop_data_writer
    
    # 启动新的数据写入器
    nohup python3 data_writer.py > $LOG_DIR/data_writer.log 2>&1 &
    local pid=$!
    echo $pid > $DATA_WRITER_PID_FILE
    
    log "数据写入器已启动 (PID: $pid)"
    
    # 等待初始化
    sleep 10
    
    # 检查是否正常运行
    if kill -0 $pid 2>/dev/null; then
        success "数据写入器运行正常"
        return 0
    else
        error "数据写入器启动失败"
        return 1
    fi
}

# 停止数据写入器
stop_data_writer() {
    if [ -f $DATA_WRITER_PID_FILE ]; then
        local pid=$(cat $DATA_WRITER_PID_FILE)
        if kill -0 $pid 2>/dev/null; then
            log "停止数据写入器 (PID: $pid)..."
            kill -TERM $pid
            
            # 等待优雅关闭
            for i in {1..10}; do
                if ! kill -0 $pid 2>/dev/null; then
                    success "数据写入器已停止"
                    rm -f $DATA_WRITER_PID_FILE
                    return 0
                fi
                sleep 1
            done
            
            # 强制杀死
            kill -KILL $pid 2>/dev/null || true
            warning "强制停止数据写入器"
        fi
        rm -f $DATA_WRITER_PID_FILE
    fi
}

# 启动监控仪表板
start_monitor() {
    log "启动监控仪表板..."
    
    # 停止现有的监控
    stop_monitor
    
    # 启动新的监控
    nohup python3 monitor_dashboard.py > $LOG_DIR/monitor.log 2>&1 &
    local pid=$!
    echo $pid > $MONITOR_PID_FILE
    
    log "监控仪表板已启动 (PID: $pid)"
    
    # 检查是否正常运行
    sleep 2
    if kill -0 $pid 2>/dev/null; then
        success "监控仪表板运行正常"
        return 0
    else
        error "监控仪表板启动失败"
        return 1
    fi
}

# 停止监控仪表板
stop_monitor() {
    if [ -f $MONITOR_PID_FILE ]; then
        local pid=$(cat $MONITOR_PID_FILE)
        if kill -0 $pid 2>/dev/null; then
            log "停止监控仪表板 (PID: $pid)..."
            kill -TERM $pid 2>/dev/null || true
            sleep 2
            kill -KILL $pid 2>/dev/null || true
        fi
        rm -f $MONITOR_PID_FILE
    fi
}

# 显示状态
show_status() {
    log "显示当前状态..."
    
    echo -e "\n${PURPLE}================== 系统状态 ==================${NC}"
    
    # Docker容器状态
    echo -e "${BLUE}Docker 容器:${NC}"
    docker-compose ps 2>/dev/null || echo "  集群未启动"
    
    # 数据写入器状态
    echo -e "\n${BLUE}数据写入器:${NC}"
    if [ -f $DATA_WRITER_PID_FILE ]; then
        local pid=$(cat $DATA_WRITER_PID_FILE)
        if kill -0 $pid 2>/dev/null; then
            echo -e "  ${GREEN}✅ 运行中${NC} (PID: $pid)"
            
            # 显示最近的统计
            if [ -f $LOG_DIR/data_writer.log ]; then
                local last_stat=$(grep "已写入.*笔事务" $LOG_DIR/data_writer.log | tail -1)
                if [ -n "$last_stat" ]; then
                    echo "  最新统计: $last_stat"
                fi
            fi
        else
            echo -e "  ${RED}❌ 已停止${NC}"
        fi
    else
        echo -e "  ${RED}❌ 未启动${NC}"
    fi
    
    # 监控仪表板状态
    echo -e "\n${BLUE}监控仪表板:${NC}"
    if [ -f $MONITOR_PID_FILE ]; then
        local pid=$(cat $MONITOR_PID_FILE)
        if kill -0 $pid 2>/dev/null; then
            echo -e "  ${GREEN}✅ 运行中${NC} (PID: $pid)"
        else
            echo -e "  ${RED}❌ 已停止${NC}"
        fi
    else
        echo -e "  ${RED}❌ 未启动${NC}"
    fi
    
    # 集群状态
    echo -e "\n${BLUE}集群状态:${NC}"
    if curl -s http://localhost:8008/cluster >/dev/null 2>&1; then
        local cluster_info=$(curl -s http://localhost:8008/cluster | python3 -c "
import sys, json
data = json.load(sys.stdin)
leader_count = 0
replica_count = 0
for member in data.get('members', []):
    if member.get('role') == 'leader':
        leader_count += 1
    elif member.get('role') == 'replica':
        replica_count += 1

print(f'  Leader: {leader_count}, Replica: {replica_count}')
        " 2>/dev/null)
        
        echo -e "  ${GREEN}✅ 健康${NC}"
        echo "  $cluster_info"
    else
        echo -e "  ${RED}❌ 不可访问${NC}"
    fi
    
    # 显示日志文件位置
    echo -e "\n${BLUE}日志文件:${NC}"
    echo "  数据写入器: $LOG_DIR/data_writer.log"
    echo "  监控仪表板: $LOG_DIR/monitor.log"
    echo "  Docker容器: docker-compose logs"
    
    echo -e "${PURPLE}===============================================${NC}\n"
}

# 清理函数
cleanup() {
    log "执行清理..."
    
    stop_data_writer
    stop_monitor
    
    log "清理完成"
}

# 显示帮助
show_help() {
    cat << EOF
Patroni 集群完整测试工具

用法: $0 [命令] [选项]

命令:
  start          启动完整测试环境 (集群 + 数据写入器 + 监控)
  stop           停止所有组件
  restart        重启所有组件
  
  start-cluster  仅启动集群
  start-writer   仅启动数据写入器
  start-monitor  仅启动监控仪表板
  
  stop-writer    仅停止数据写入器
  stop-monitor   仅停止监控仪表板
  
  status         显示当前状态
  logs           显示日志
  chaos          启动综合故障测试
  
  monitor        启动交互式监控仪表板
  
选项:
  -h, --help     显示此帮助信息

示例:
  $0 start                    # 启动完整测试环境
  $0 chaos                    # 启动故障测试 (需要先启动环境)
  $0 monitor                  # 启动交互式监控
  $0 status                   # 查看状态
  $0 logs                     # 查看数据写入器日志
  
故障测试:
  $0 chaos                    # 使用默认参数 (5分钟, 60秒间隔)
  TEST_DURATION=600 $0 chaos  # 自定义测试时长 (10分钟)

EOF
}

# 显示日志
show_logs() {
    local log_type=${1:-writer}
    
    case $log_type in
        writer|data)
            if [ -f $LOG_DIR/data_writer.log ]; then
                log "显示数据写入器日志 (最后50行):"
                tail -50 $LOG_DIR/data_writer.log
            else
                warning "数据写入器日志文件不存在"
            fi
            ;;
        monitor)
            if [ -f $LOG_DIR/monitor.log ]; then
                log "显示监控仪表板日志 (最后50行):"
                tail -50 $LOG_DIR/monitor.log
            else
                warning "监控仪表板日志文件不存在"
            fi
            ;;
        docker)
            log "显示Docker容器日志:"
            docker-compose logs --tail=50
            ;;
        all)
            show_logs writer
            echo -e "\n${PURPLE}===========================================${NC}\n"
            show_logs monitor
            echo -e "\n${PURPLE}===========================================${NC}\n"
            show_logs docker
            ;;
        *)
            warning "未知日志类型: $log_type"
            echo "可用类型: writer, monitor, docker, all"
            ;;
    esac
}

# 信号处理
trap cleanup EXIT INT TERM

# 主函数
main() {
    local command=${1:-help}
    
    case $command in
        start)
            log "🚀 启动完整测试环境..."
            check_dependencies || exit 1
            start_cluster || exit 1
            start_data_writer || exit 1
            # start_monitor || exit 1  # 监控仪表板需要交互，单独启动
            success "🎉 完整测试环境启动完成!"
            echo ""
            info "下一步操作:"
            info "  1. 运行 '$0 monitor' 启动交互式监控仪表板"
            info "  2. 运行 '$0 chaos' 开始故障测试" 
            info "  3. 运行 '$0 status' 查看状态"
            ;;
        stop)
            log "🛑 停止所有组件..."
            stop_data_writer
            stop_monitor
            docker-compose down -v 2>/dev/null || true
            success "所有组件已停止"
            ;;
        restart)
            log "🔄 重启所有组件..."
            $0 stop
            sleep 5
            $0 start
            ;;
        start-cluster)
            check_dependencies || exit 1
            start_cluster || exit 1
            ;;
        start-writer)
            start_data_writer || exit 1
            ;;
        start-monitor)
            start_monitor || exit 1
            ;;
        stop-writer)
            stop_data_writer
            ;;
        stop-monitor)
            stop_monitor
            ;;
        status)
            show_status
            ;;
        logs)
            show_logs ${2:-writer}
            ;;
        chaos)
            log "🌪️ 启动综合故障测试..."
            if ! pgrep -f "data_writer.py" >/dev/null; then
                error "数据写入器未运行，请先运行 '$0 start'"
                exit 1
            fi
            ./comprehensive_test.sh
            ;;
        monitor)
            log "🔍 启动交互式监控仪表板..."
            python3 monitor_dashboard.py
            ;;
        help|-h|--help)
            show_help
            ;;
        *)
            error "未知命令: $command"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

# 运行主函数
main "$@"
