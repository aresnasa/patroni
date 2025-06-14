#!/bin/bash

# Patroni 集群综合故障测试脚本
# 测试数据一致性、故障转移和恢复能力

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/tmp/cluster_test.log"
TEST_RESULTS_FILE="/tmp/test_results.json"

# 测试配置
TEST_DURATION=${TEST_DURATION:-300}  # 测试持续时间(秒)
CHAOS_INTERVAL=${CHAOS_INTERVAL:-60}  # 故障注入间隔(秒)
DATA_WRITER_PID=""

log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a $LOG_FILE
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a $LOG_FILE
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a $LOG_FILE
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a $LOG_FILE
}

info() {
    echo -e "${PURPLE}[INFO]${NC} $1" | tee -a $LOG_FILE
}

# 检查依赖
check_dependencies() {
    log "检查依赖..."
    
    # 检查Python
    if ! command -v python3 &> /dev/null; then
        error "Python3 未安装"
        return 1
    fi
    
    # 检查psycopg2
    if ! python3 -c "import psycopg2" 2>/dev/null; then
        warning "psycopg2 未安装，正在安装..."
        pip3 install psycopg2-binary
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
    
    # 等待服务就绪
    log "等待服务就绪..."
    sleep 30
    
    # 检查etcd集群
    for i in {1..3}; do
        if docker exec patroni-etcd$i etcdctl endpoint health 2>/dev/null; then
            success "etcd$i 健康"
        else
            warning "etcd$i 可能有问题"
        fi
    done
    
    # 等待Patroni集群形成
    log "等待Patroni集群形成..."
    sleep 60
    
    # 检查集群状态
    check_cluster_status
    
    success "集群启动完成"
}

# 检查集群状态
check_cluster_status() {
    log "检查集群状态..."
    
    local leader_found=false
    local replica_count=0
    
    for port in 8008 8009 8010; do
        if curl -s http://localhost:$port/cluster > /dev/null 2>&1; then
            local role=$(curl -s http://localhost:$port/patroni | jq -r '.role // "unknown"')
            local state=$(curl -s http://localhost:$port/patroni | jq -r '.state // "unknown"')
            local name=$(curl -s http://localhost:$port/patroni | jq -r '.patroni.name // "unknown"')
            
            info "节点 $name (端口:$port): $role - $state"
            
            if [ "$role" = "leader" ]; then
                leader_found=true
            elif [ "$role" = "replica" ]; then
                ((replica_count++))
            fi
        else
            warning "节点 $port 不可访问"
        fi
    done
    
    if [ "$leader_found" = true ] && [ $replica_count -ge 1 ]; then
        success "集群状态正常: 1个主节点, ${replica_count}个副本"
        return 0
    else
        error "集群状态异常"
        return 1
    fi
}

# 启动数据写入器
start_data_writer() {
    log "启动数据写入器..."
    
    python3 data_writer.py > /tmp/data_writer.log 2>&1 &
    DATA_WRITER_PID=$!
    
    log "数据写入器已启动 (PID: $DATA_WRITER_PID)"
    
    # 等待数据写入器初始化
    sleep 10
    
    # 检查是否正常运行
    if kill -0 $DATA_WRITER_PID 2>/dev/null; then
        success "数据写入器运行正常"
        return 0
    else
        error "数据写入器启动失败"
        return 1
    fi
}

# 停止数据写入器
stop_data_writer() {
    if [ -n "$DATA_WRITER_PID" ] && kill -0 $DATA_WRITER_PID 2>/dev/null; then
        log "停止数据写入器..."
        kill -TERM $DATA_WRITER_PID
        
        # 等待优雅关闭
        for i in {1..10}; do
            if ! kill -0 $DATA_WRITER_PID 2>/dev/null; then
                success "数据写入器已停止"
                return 0
            fi
            sleep 1
        done
        
        # 强制杀死
        kill -KILL $DATA_WRITER_PID 2>/dev/null || true
        warning "强制停止数据写入器"
    fi
}

# 执行故障注入测试
run_chaos_tests() {
    local test_duration=$1
    local chaos_interval=$2
    local start_time=$(date +%s)
    local end_time=$((start_time + test_duration))
    
    log "开始故障注入测试 (持续${test_duration}秒, 间隔${chaos_interval}秒)"
    
    # 故障类型列表
    local chaos_types=(
        "stop_random_postgres"
        "restart_random_postgres" 
        "stop_primary"
        "network_partition"
        "cpu_stress"
        "memory_stress"
        "stop_random_etcd"
    )
    
    local test_count=0
    
    while [ $(date +%s) -lt $end_time ]; do
        ((test_count++))
        
        # 随机选择故障类型
        local chaos_type=${chaos_types[$((RANDOM % ${#chaos_types[@]}))]}
        
        log "执行故障测试 #$test_count: $chaos_type"
        
        # 记录故障前状态
        local before_state=$(curl -s http://localhost:8008/cluster 2>/dev/null || echo "{}")
        
        # 执行故障注入
        case $chaos_type in
            "stop_random_postgres")
                local target=$(printf "patroni-postgres%d" $((RANDOM % 3 + 1)))
                ./chaos-scripts/chaos.sh stop $target
                sleep 30
                ./chaos-scripts/chaos.sh restart $target
                ;;
            "restart_random_postgres")
                local target=$(printf "patroni-postgres%d" $((RANDOM % 3 + 1)))
                ./chaos-scripts/chaos.sh restart $target
                ;;
            "stop_primary")
                # 找到当前主节点并停止
                local primary=$(get_current_primary)
                if [ "$primary" != "unknown" ]; then
                    ./chaos-scripts/chaos.sh stop patroni-$primary
                    sleep 45  # 等待故障转移
                    ./chaos-scripts/chaos.sh restart patroni-$primary
                fi
                ;;
            "network_partition")
                local target=$(printf "patroni-postgres%d" $((RANDOM % 3 + 1)))
                ./chaos-scripts/chaos.sh network-partition $target
                sleep 30
                ./chaos-scripts/chaos.sh network-heal
                ;;
            "cpu_stress")
                local target=$(printf "patroni-postgres%d" $((RANDOM % 3 + 1)))
                ./chaos-scripts/chaos.sh cpu-stress $target 30
                ;;
            "memory_stress")
                local target=$(printf "patroni-postgres%d" $((RANDOM % 3 + 1)))
                ./chaos-scripts/chaos.sh memory-stress $target
                ;;
            "stop_random_etcd")
                local target=$(printf "patroni-etcd%d" $((RANDOM % 3 + 1)))
                docker stop $target
                sleep 20
                docker start $target
                ;;
        esac
        
        # 等待系统稳定
        sleep 10
        
        # 检查集群恢复状态
        local recovery_time=0
        local max_recovery_time=120
        
        while [ $recovery_time -lt $max_recovery_time ]; do
            if check_cluster_status > /dev/null 2>&1; then
                success "故障测试 #$test_count 完成, 集群已恢复 (用时${recovery_time}秒)"
                break
            fi
            sleep 5
            ((recovery_time+=5))
        done
        
        if [ $recovery_time -ge $max_recovery_time ]; then
            error "故障测试 #$test_count: 集群未在${max_recovery_time}秒内恢复"
        fi
        
        # 记录故障后状态
        local after_state=$(curl -s http://localhost:8008/cluster 2>/dev/null || echo "{}")
        
        # 等待下次故障注入
        local remaining_time=$((end_time - $(date +%s)))
        if [ $remaining_time -gt $chaos_interval ]; then
            log "等待${chaos_interval}秒后进行下次故障注入..."
            sleep $chaos_interval
        else
            log "测试时间即将结束，停止故障注入"
            break
        fi
    done
    
    success "故障注入测试完成，共执行 $test_count 次测试"
}

# 获取当前主节点
get_current_primary() {
    for port in 8008 8009 8010; do
        local role=$(curl -s http://localhost:$port/patroni 2>/dev/null | jq -r '.role // ""')
        if [ "$role" = "leader" ]; then
            local name=$(curl -s http://localhost:$port/patroni | jq -r '.patroni.name // "unknown"')
            echo $name
            return
        fi
    done
    echo "unknown"
}

# 验证数据一致性
verify_data_consistency() {
    log "执行最终数据一致性验证..."
    
    # 等待所有副本同步
    sleep 30
    
    # Python脚本进行数据一致性检查
    python3 -c "
import psycopg2
import json
import sys

connections = {
    'postgres1': {'host': 'localhost', 'port': 15432, 'database': 'postgres', 'user': 'postgres', 'password': 'postgres123'},
    'postgres2': {'host': 'localhost', 'port': 15433, 'database': 'postgres', 'user': 'postgres', 'password': 'postgres123'}, 
    'postgres3': {'host': 'localhost', 'port': 15434, 'database': 'postgres', 'user': 'postgres', 'password': 'postgres123'}
}

node_data = {}
accessible_nodes = []

for node_name, conn_info in connections.items():
    try:
        conn = psycopg2.connect(**conn_info)
        conn.autocommit = True
        
        with conn.cursor() as cur:
            # 检查表是否存在
            cur.execute(\"\"\"
                SELECT EXISTS (
                    SELECT FROM information_schema.tables 
                    WHERE table_name = 'test_transactions'
                )
            \"\"\")
            
            if cur.fetchone()[0]:
                # 获取统计信息
                cur.execute(\"\"\"
                    SELECT 
                        COUNT(*) as total_records,
                        MAX(sequence_num) as max_sequence,
                        MIN(sequence_num) as min_sequence
                    FROM test_transactions
                \"\"\")
                
                stats = cur.fetchone()
                node_data[node_name] = {
                    'total_records': stats[0],
                    'max_sequence': stats[1],
                    'min_sequence': stats[2],
                    'accessible': True
                }
                accessible_nodes.append(node_name)
            else:
                node_data[node_name] = {'accessible': False, 'error': 'Table not found'}
        
        conn.close()
        
    except Exception as e:
        node_data[node_name] = {'accessible': False, 'error': str(e)}

print('=== 数据一致性验证结果 ===')
print(f'可访问节点: {len(accessible_nodes)}')

if len(accessible_nodes) > 1:
    reference = node_data[accessible_nodes[0]]
    consistent = True
    
    for node_name in accessible_nodes:
        data = node_data[node_name]
        print(f'{node_name}: {data[\"total_records\"]} 条记录, 序列号: {data[\"min_sequence\"]}-{data[\"max_sequence\"]}')
        
        if (data['total_records'] != reference['total_records'] or 
            data['max_sequence'] != reference['max_sequence']):
            consistent = False
    
    if consistent:
        print('✅ 所有节点数据一致')
        sys.exit(0)
    else:
        print('❌ 数据不一致')
        sys.exit(1)
else:
    print(f'⚠️ 只有 {len(accessible_nodes)} 个节点可访问')
    if len(accessible_nodes) == 1:
        data = node_data[accessible_nodes[0]]
        print(f'{accessible_nodes[0]}: {data[\"total_records\"]} 条记录')
    sys.exit(2)
"
    
    local consistency_result=$?
    
    case $consistency_result in
        0)
            success "数据一致性验证通过"
            return 0
            ;;
        1)
            error "数据一致性验证失败"
            return 1
            ;;
        2)
            warning "数据一致性验证不完整（部分节点不可访问）"
            return 2
            ;;
        *)
            error "数据一致性验证异常"
            return 3
            ;;
    esac
}

# 生成测试报告
generate_test_report() {
    log "生成测试报告..."
    
    local test_end_time=$(date '+%Y-%m-%d %H:%M:%S')
    local data_writer_log="/tmp/data_writer.log"
    
    # 从数据写入器日志中提取统计信息
    local total_transactions=0
    local error_count=0
    
    if [ -f "$data_writer_log" ]; then
        total_transactions=$(grep -o "已写入 [0-9]* 笔事务" "$data_writer_log" | tail -1 | grep -o "[0-9]*" || echo "0")
        error_count=$(grep -c "写入事务失败" "$data_writer_log" || echo "0")
    fi
    
    # 生成JSON报告
    cat > $TEST_RESULTS_FILE << EOF
{
    "test_summary": {
        "start_time": "$TEST_START_TIME",
        "end_time": "$test_end_time",
        "duration_seconds": $TEST_DURATION,
        "chaos_interval_seconds": $CHAOS_INTERVAL
    },
    "data_operations": {
        "total_transactions": $total_transactions,
        "error_count": $error_count,
        "success_rate": $(echo "scale=2; ($total_transactions - $error_count) * 100 / $total_transactions" | bc -l 2>/dev/null || echo "0")
    },
    "cluster_status": "$(check_cluster_status > /dev/null 2>&1 && echo "healthy" || echo "unhealthy")",
    "data_consistency": "$(verify_data_consistency > /dev/null 2>&1 && echo "consistent" || echo "inconsistent")",
    "log_files": {
        "main_log": "$LOG_FILE",
        "data_writer_log": "$data_writer_log",
        "patroni_logs": "docker-compose logs"
    }
}
EOF

    log "测试报告已生成: $TEST_RESULTS_FILE"
    
    # 显示摘要
    echo -e "\n${PURPLE}=================== 测试摘要 ===================${NC}"
    echo -e "${BLUE}测试持续时间:${NC} $TEST_DURATION 秒"
    echo -e "${BLUE}故障注入间隔:${NC} $CHAOS_INTERVAL 秒"
    echo -e "${BLUE}写入事务总数:${NC} $total_transactions"
    echo -e "${BLUE}错误次数:${NC} $error_count"
    
    if [ $total_transactions -gt 0 ]; then
        local success_rate=$(echo "scale=2; ($total_transactions - $error_count) * 100 / $total_transactions" | bc -l 2>/dev/null || echo "0")
        echo -e "${BLUE}成功率:${NC} ${success_rate}%"
    fi
    
    echo -e "${BLUE}集群状态:${NC} $(check_cluster_status > /dev/null 2>&1 && echo -e "${GREEN}健康${NC}" || echo -e "${RED}异常${NC}")"
    echo -e "${BLUE}数据一致性:${NC} $(verify_data_consistency > /dev/null 2>&1 && echo -e "${GREEN}一致${NC}" || echo -e "${RED}不一致${NC}")"
    echo -e "${PURPLE}================================================${NC}\n"
}

# 清理函数
cleanup() {
    log "执行清理..."
    
    # 停止数据写入器
    stop_data_writer
    
    # 生成测试报告
    generate_test_report
    
    log "清理完成"
}

# 信号处理
trap cleanup EXIT INT TERM

# 主函数
main() {
    log "🚀 开始Patroni集群综合故障测试"
    
    TEST_START_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    
    # 检查参数
    if [ $# -gt 0 ]; then
        case $1 in
            -h|--help)
                echo "用法: $0 [TEST_DURATION] [CHAOS_INTERVAL]"
                echo "  TEST_DURATION: 测试持续时间(秒), 默认: 300"
                echo "  CHAOS_INTERVAL: 故障注入间隔(秒), 默认: 60"
                echo ""
                echo "环境变量:"
                echo "  TEST_DURATION: 测试持续时间"
                echo "  CHAOS_INTERVAL: 故障注入间隔"
                exit 0
                ;;
            *)
                TEST_DURATION=$1
                ;;
        esac
    fi
    
    if [ $# -gt 1 ]; then
        CHAOS_INTERVAL=$2
    fi
    
    log "测试配置: 持续时间=${TEST_DURATION}秒, 故障间隔=${CHAOS_INTERVAL}秒"
    
    # 执行测试步骤
    check_dependencies || exit 1
    start_cluster || exit 1
    start_data_writer || exit 1
    
    # 让数据写入器运行一段时间建立基线
    log "建立基线数据... (60秒)"
    sleep 60
    
    # 执行故障测试
    run_chaos_tests $TEST_DURATION $CHAOS_INTERVAL
    
    # 停止故障注入后让系统稳定
    log "等待系统稳定... (60秒)"
    sleep 60
    
    # 最终验证
    verify_data_consistency
    
    success "🎉 Patroni集群综合故障测试完成!"
}

# 运行主函数
main "$@"
