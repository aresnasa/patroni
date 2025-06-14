#!/bin/bash

# 自动化数据一致性验证脚本
# 在故障期间和恢复后验证数据一致性

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# 数据一致性验证
verify_consistency() {
    log "执行数据一致性验证..."
    
    python3 -c "
import psycopg2
import json
import sys
import hashlib
from datetime import datetime

connections = {
    'postgres1': {'host': 'localhost', 'port': 15432, 'database': 'postgres', 'user': 'postgres', 'password': 'postgres123'},
    'postgres2': {'host': 'localhost', 'port': 15433, 'database': 'postgres', 'user': 'postgres', 'password': 'postgres123'}, 
    'postgres3': {'host': 'localhost', 'port': 15434, 'database': 'postgres', 'user': 'postgres', 'password': 'postgres123'}
}

def get_node_data(node_name, conn_info):
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
            
            if not cur.fetchone()[0]:
                return {'accessible': False, 'error': 'Table not found'}
            
            # 获取统计信息
            cur.execute(\"\"\"
                SELECT 
                    COUNT(*) as total_records,
                    MAX(sequence_num) as max_sequence,
                    MIN(sequence_num) as min_sequence,
                    COUNT(DISTINCT checksum) as unique_checksums,
                    MAX(timestamp) as last_transaction
                FROM test_transactions
            \"\"\")
            
            stats = cur.fetchone()
            
            # 获取数据摘要 (前10和后10条记录的校验和)
            cur.execute(\"\"\"
                (SELECT sequence_num, checksum FROM test_transactions 
                 ORDER BY sequence_num ASC LIMIT 10)
                UNION ALL
                (SELECT sequence_num, checksum FROM test_transactions 
                 ORDER BY sequence_num DESC LIMIT 10)
                ORDER BY sequence_num
            \"\"\")
            
            records = cur.fetchall()
            
            # 计算数据指纹
            fingerprint_data = ''.join([f'{r[0]}:{r[1]}' for r in records])
            fingerprint = hashlib.md5(fingerprint_data.encode()).hexdigest()
            
            # 检查是否有重复的sequence_num
            cur.execute(\"\"\"
                SELECT sequence_num, COUNT(*) 
                FROM test_transactions 
                GROUP BY sequence_num 
                HAVING COUNT(*) > 1
                LIMIT 5
            \"\"\")
            
            duplicates = cur.fetchall()
            
            # 检查序列号连续性
            cur.execute(\"\"\"
                SELECT COUNT(*) as gaps FROM (
                    SELECT sequence_num, 
                           sequence_num - LAG(sequence_num) OVER (ORDER BY sequence_num) as gap
                    FROM test_transactions
                ) t WHERE gap > 1
            \"\"\")
            
            gaps = cur.fetchone()[0]
            
            conn.close()
            
            return {
                'accessible': True,
                'total_records': stats[0],
                'max_sequence': stats[1],
                'min_sequence': stats[2],
                'unique_checksums': stats[3],
                'last_transaction': stats[4],
                'fingerprint': fingerprint,
                'duplicates': duplicates,
                'sequence_gaps': gaps
            }
        
    except Exception as e:
        return {'accessible': False, 'error': str(e)}

print('=' * 60)
print('数据一致性验证报告')
print('=' * 60)
print(f'验证时间: {datetime.now().strftime(\"%Y-%m-%d %H:%M:%S\")}')
print()

node_data = {}
accessible_nodes = []

# 收集所有节点数据
for node_name, conn_info in connections.items():
    print(f'正在检查 {node_name}...', end=' ')
    data = get_node_data(node_name, conn_info)
    node_data[node_name] = data
    
    if data['accessible']:
        accessible_nodes.append(node_name)
        print('✅')
    else:
        print(f'❌ ({data[\"error\"]})')

print(f'\\n可访问节点: {len(accessible_nodes)}/{len(connections)}')

if len(accessible_nodes) == 0:
    print('❌ 所有节点都不可访问!')
    sys.exit(1)

# 详细分析
print('\\n节点详细信息:')
print('-' * 80)
print(f'{'节点':^12} {'记录数':^10} {'序列范围':^15} {'唯一校验':^10} {'序列跳跃':^10} {'状态':^8}')
print('-' * 80)

reference_node = accessible_nodes[0] if accessible_nodes else None
reference_data = node_data[reference_node] if reference_node else None

consistent = True
consistency_issues = []

for node_name in connections.keys():
    data = node_data[node_name]
    
    if data['accessible']:
        sequence_range = f'{data[\"min_sequence\"]}-{data[\"max_sequence\"]}'
        status = '正常'
        
        # 与参考节点比较
        if reference_data and node_name != reference_node:
            if data['total_records'] != reference_data['total_records']:
                consistent = False
                status = '记录数不同'
                consistency_issues.append(f'{node_name}: 记录数 {data[\"total_records\"]} vs {reference_data[\"total_records\"]}')
            
            if data['max_sequence'] != reference_data['max_sequence']:
                consistent = False
                status = '序列号不同'
                consistency_issues.append(f'{node_name}: 最大序列号 {data[\"max_sequence\"]} vs {reference_data[\"max_sequence\"]}')
            
            if data['fingerprint'] != reference_data['fingerprint']:
                consistent = False
                status = '数据指纹不同'
                consistency_issues.append(f'{node_name}: 数据指纹不匹配')
        
        # 检查数据质量问题
        if data['duplicates']:
            status = '有重复序列'
            consistency_issues.append(f'{node_name}: 发现重复序列号')
        
        if data['sequence_gaps'] > 0:
            status = f'{data[\"sequence_gaps\"]}个跳跃'
            consistency_issues.append(f'{node_name}: {data[\"sequence_gaps\"]} 个序列号跳跃')
        
        print(f'{node_name:^12} {data[\"total_records\"]:^10} {sequence_range:^15} {data[\"unique_checksums\"]:^10} {data[\"sequence_gaps\"]:^10} {status:^8}')
        
    else:
        print(f'{node_name:^12} {'N/A':^10} {'N/A':^15} {'N/A':^10} {'N/A':^10} {'不可访问':^8}')

print('-' * 80)

# 一致性总结
print()
if len(accessible_nodes) == 1:
    print('⚠️ 只有一个节点可访问，无法进行一致性比较')
    if reference_data['sequence_gaps'] == 0 and not reference_data['duplicates']:
        print('✅ 可访问节点的数据质量良好')
    else:
        print('❌ 可访问节点存在数据质量问题')
elif consistent and len(consistency_issues) == 0:
    print('✅ 所有节点数据完全一致且质量良好')
    sys.exit(0)
else:
    print('❌ 发现数据一致性或质量问题:')
    for issue in consistency_issues:
        print(f'   • {issue}')

print()
print('详细指纹信息:')
for node_name in accessible_nodes:
    data = node_data[node_name]
    print(f'  {node_name}: {data[\"fingerprint\"]}')

if consistent:
    print('\\n✅ 数据一致性验证通过')
    sys.exit(0)
else:
    print('\\n❌ 数据一致性验证失败')
    sys.exit(1)
"
    
    return $?
}

# 生成数据质量报告
generate_quality_report() {
    log "生成数据质量报告..."
    
    local report_file="/tmp/data_quality_report_$(date +%Y%m%d_%H%M%S).json"
    
    python3 -c "
import psycopg2
import json
import sys
from datetime import datetime, timedelta

try:
    # 连接主库
    conn = psycopg2.connect(
        host='localhost', port=15000, database='postgres', 
        user='postgres', password='postgres123'
    )
    conn.autocommit = True
    
    with conn.cursor() as cur:
        # 检查表是否存在
        cur.execute(\"\"\"
            SELECT EXISTS (
                SELECT FROM information_schema.tables 
                WHERE table_name = 'test_transactions'
            )
        \"\"\")
        
        if not cur.fetchone()[0]:
            print(json.dumps({'error': 'test_transactions table not found'}))
            sys.exit(1)
        
        # 基础统计
        cur.execute(\"\"\"
            SELECT 
                COUNT(*) as total_records,
                MAX(sequence_num) as max_sequence,
                MIN(sequence_num) as min_sequence,
                MAX(timestamp) as last_transaction,
                MIN(timestamp) as first_transaction
            FROM test_transactions
        \"\"\")
        
        basic_stats = cur.fetchone()
        
        # 时间段统计
        cur.execute(\"\"\"
            SELECT 
                DATE_TRUNC('minute', timestamp) as minute,
                COUNT(*) as count
            FROM test_transactions 
            WHERE timestamp > NOW() - INTERVAL '10 minutes'
            GROUP BY DATE_TRUNC('minute', timestamp)
            ORDER BY minute DESC
            LIMIT 10
        \"\"\")
        
        time_stats = cur.fetchall()
        
        # 节点统计
        cur.execute(\"\"\"
            SELECT 
                node_name,
                COUNT(*) as count,
                MAX(sequence_num) as max_seq,
                MAX(timestamp) as last_write
            FROM test_transactions 
            GROUP BY node_name
            ORDER BY node_name
        \"\"\")
        
        node_stats = cur.fetchall()
        
        # 数据质量检查
        cur.execute(\"\"\"
            SELECT 
                COUNT(CASE WHEN sequence_num IS NULL THEN 1 END) as null_sequences,
                COUNT(CASE WHEN checksum IS NULL THEN 1 END) as null_checksums,
                COUNT(CASE WHEN data IS NULL THEN 1 END) as null_data
            FROM test_transactions
        \"\"\")
        
        quality_stats = cur.fetchone()
        
        # 重复检查
        cur.execute(\"\"\"
            SELECT sequence_num, COUNT(*) as count
            FROM test_transactions 
            GROUP BY sequence_num 
            HAVING COUNT(*) > 1
            ORDER BY count DESC
            LIMIT 5
        \"\"\")
        
        duplicates = cur.fetchall()
        
        # 故障事件统计
        cur.execute(\"\"\"
            SELECT 
                event_type,
                COUNT(*) as count
            FROM failure_log 
            WHERE timestamp > NOW() - INTERVAL '1 hour'
            GROUP BY event_type
            ORDER BY count DESC
        \"\"\")
        
        failure_stats = cur.fetchall()
        
        # 生成报告
        report = {
            'timestamp': datetime.now().isoformat(),
            'basic_statistics': {
                'total_records': basic_stats[0],
                'max_sequence': basic_stats[1],
                'min_sequence': basic_stats[2],
                'last_transaction': basic_stats[3].isoformat() if basic_stats[3] else None,
                'first_transaction': basic_stats[4].isoformat() if basic_stats[4] else None,
                'duration_minutes': ((basic_stats[3] - basic_stats[4]).total_seconds() / 60) if basic_stats[3] and basic_stats[4] else 0
            },
            'time_distribution': [
                {
                    'minute': row[0].isoformat(),
                    'count': row[1]
                } for row in time_stats
            ],
            'node_statistics': [
                {
                    'node_name': row[0],
                    'count': row[1],
                    'max_sequence': row[2],
                    'last_write': row[3].isoformat() if row[3] else None
                } for row in node_stats
            ],
            'data_quality': {
                'null_sequences': quality_stats[0],
                'null_checksums': quality_stats[1], 
                'null_data': quality_stats[2],
                'duplicates': [
                    {
                        'sequence_num': row[0],
                        'count': row[1]
                    } for row in duplicates
                ]
            },
            'failure_events': [
                {
                    'event_type': row[0],
                    'count': row[1]
                } for row in failure_stats
            ]
        }
        
        print(json.dumps(report, indent=2))
    
    conn.close()
    
except Exception as e:
    print(json.dumps({'error': str(e)}))
    sys.exit(1)
" > "$report_file"
    
    if [ $? -eq 0 ]; then
        success "数据质量报告已生成: $report_file"
        
        # 显示摘要
        python3 -c "
import json
import sys

try:
    with open('$report_file', 'r') as f:
        report = json.load(f)
    
    if 'error' in report:
        print(f'报告生成错误: {report[\"error\"]}')
        sys.exit(1)
    
    stats = report['basic_statistics']
    quality = report['data_quality']
    
    print()
    print('📊 数据质量摘要:')
    print(f'   总记录数: {stats[\"total_records\"]:,}')
    print(f'   序列范围: {stats[\"min_sequence\"]} - {stats[\"max_sequence\"]}')
    print(f'   测试时长: {stats[\"duration_minutes\"]:.1f} 分钟')
    
    if quality['null_sequences'] > 0 or quality['null_checksums'] > 0 or quality['duplicates']:
        print('⚠️ 数据质量问题:')
        if quality['null_sequences'] > 0:
            print(f'   空序列号: {quality[\"null_sequences\"]}')
        if quality['null_checksums'] > 0:
            print(f'   空校验和: {quality[\"null_checksums\"]}')
        if quality['duplicates']:
            print(f'   重复序列: {len(quality[\"duplicates\"])} 个')
    else:
        print('✅ 数据质量良好')
    
    print(f'\\n节点分布:')
    for node in report['node_statistics']:
        print(f'   {node[\"node_name\"]}: {node[\"count\"]:,} 条记录')
        
except Exception as e:
    print(f'解析报告失败: {e}')
"
    else
        error "数据质量报告生成失败"
        return 1
    fi
}

# 主函数
main() {
    local action=${1:-verify}
    
    case $action in
        verify|check)
            verify_consistency
            ;;
        report|quality)
            generate_quality_report
            ;;
        both|all)
            verify_consistency
            echo ""
            generate_quality_report
            ;;
        -h|--help|help)
            cat << EOF
数据一致性验证工具

用法: $0 [动作]

动作:
  verify, check    执行数据一致性验证 (默认)
  report, quality  生成数据质量报告
  both, all        执行验证和生成报告
  help            显示此帮助

示例:
  $0               # 执行一致性验证
  $0 verify        # 执行一致性验证
  $0 report        # 生成质量报告
  $0 both          # 执行验证并生成报告

EOF
            ;;
        *)
            error "未知动作: $action"
            echo "运行 '$0 help' 查看帮助"
            exit 1
            ;;
    esac
}

main "$@"
