#!/bin/bash

# 快速验证脚本 - 验证 Patroni 集群是否正常工作
# 使用# 测试2: 检查 etcd 集群
echo ""
echo "测试 2: 检查 etcd 集群..."
etcd_ready=0
etcd_replicas=$(get_replica_count "etcd")
for ((i=0; i<etcd_replicas; i++)); do
    if kubectl get pod "$CLUSTER_NAME-etcd-$i" -n "$NAMESPACE" --no-headers 2>/dev/null | grep -q "Running"; then
        etcd_ready=$((etcd_ready + 1))
        log_info "etcd-$i 运行正常"
    else
        log_error "etcd-$i 未运行"
    fi
done

if [ "$etcd_ready" -eq "$etcd_replicas" ]; then
    log_info "etcd 集群运行正常 ($etcd_ready/$etcd_replicas 个节点)"
else
    log_error "etcd 集群异常 ($etcd_ready/$etcd_replicas 个节点就绪)"sh [namespace]

set -e

NAMESPACE="${1:-patroni-cluster}"
CLUSTER_NAME="patroni-cluster"

# 获取集群副本数
get_replica_count() {
    local component=$1
    kubectl get statefulset "$CLUSTER_NAME-$component" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "3"
}

# 颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[!]${NC} $1"
}

echo "🧪 开始快速验证 Patroni 集群..."
echo "命名空间: $NAMESPACE"
echo "集群名称: $CLUSTER_NAME"
echo ""

# 测试1: 检查命名空间
echo "测试 1: 检查命名空间..."
if kubectl get namespace "$NAMESPACE" &>/dev/null; then
    log_info "命名空间 $NAMESPACE 存在"
else
    log_error "命名空间 $NAMESPACE 不存在"
    exit 1
fi

# 测试2: 检查 etcd 集群
echo ""
echo "测试 2: 检查 etcd 集群..."
etcd_ready=0
for i in 0 1 2; do
    if kubectl get pod "$CLUSTER_NAME-etcd-$i" -n "$NAMESPACE" --no-headers 2>/dev/null | grep -q "Running"; then
        etcd_ready=$((etcd_ready + 1))
        log_info "etcd-$i 运行正常"
    else
        log_error "etcd-$i 未运行"
    fi
done

if [ $etcd_ready -ge 2 ]; then
    log_info "etcd 集群健康 ($etcd_ready/3 节点)"
else
    log_error "etcd 集群不健康，只有 $etcd_ready/3 节点运行"
fi

# 测试3: 检查 PostgreSQL 集群
echo ""
echo "测试 3: 检查 PostgreSQL 集群..."
pg_ready=0
leader_found=false
pg_replicas=$(get_replica_count "postgresql")

for ((i=0; i<pg_replicas; i++)); do
    pod_name="$CLUSTER_NAME-postgresql-$i"
    if kubectl get pod "$pod_name" -n "$NAMESPACE" --no-headers 2>/dev/null | grep -q "Running"; then
        pg_ready=$((pg_ready + 1))
        log_info "postgresql-$i 运行正常"
        
        # 检查角色
        role=$(kubectl exec "$pod_name" -n "$NAMESPACE" -c postgresql -- curl -s http://localhost:8008/patroni 2>/dev/null | jq -r '.role' 2>/dev/null || echo "unknown")
        if [ "$role" = "leader" ]; then
            leader_found=true
            log_info "postgresql-$i 是主节点 (leader)"
        elif [ "$role" = "replica" ]; then
            log_info "postgresql-$i 是副本节点 (replica)"
        else
            log_warn "postgresql-$i 角色未知: $role"
        fi
    else
        log_error "postgresql-$i 未运行"
    fi
done

if [ $pg_ready -eq $pg_replicas ]; then
    log_info "PostgreSQL 集群健康 ($pg_ready/$pg_replicas 节点)"
else
    log_warn "PostgreSQL 集群部分健康 ($pg_ready/$pg_replicas 节点)"
fi

if [ "$leader_found" = true ]; then
    log_info "找到主节点"
else
    log_error "未找到主节点"
fi

# 测试4: 检查负载均衡服务
echo ""
echo "测试 4: 检查负载均衡服务..."

primary_svc="${CLUSTER_NAME}-primary"
readonly_svc="${CLUSTER_NAME}-readonly"
all_svc="${CLUSTER_NAME}-all"

services_ok=0
total_services=3

for svc in "$primary_svc" "$readonly_svc" "$all_svc"; do
    if kubectl get service "$svc" -n "$NAMESPACE" &>/dev/null; then
        log_info "服务 $svc 存在"
        services_ok=$((services_ok + 1))
    else
        log_error "服务 $svc 不存在"
    fi
done

if [ $services_ok -eq $total_services ]; then
    log_info "所有负载均衡服务正常 ($services_ok/$total_services)"
else
    log_error "部分负载均衡服务异常 ($services_ok/$total_services)"
fi

# 测试5: 检查基础服务
echo ""
echo "测试 5: 检查基础服务..."
services=("$CLUSTER_NAME-etcd" "$CLUSTER_NAME-postgresql")
for service in "${services[@]}"; do
    if kubectl get service "$service" -n "$NAMESPACE" &>/dev/null; then
        log_info "服务 $service 存在"
    else
        log_error "服务 $service 不存在"
    fi
done

# 测试6: 数据库连接测试
echo ""
echo "测试 6: 数据库连接测试..."

# 端口转发到本地进行连接测试
log_info "启动端口转发进行连接测试..."
kubectl port-forward -n "$NAMESPACE" svc/"$CLUSTER_NAME-primary" 15432:5432 >/dev/null 2>&1 &
PORT_FORWARD_PID=$!

# 等待端口转发生效
sleep 3

# 测试连接
if timeout 10 bash -c "echo 'SELECT version();' | PGPASSWORD=postgres123 psql -h localhost -p 15432 -U postgres -d postgres" >/dev/null 2>&1; then
    log_info "数据库连接测试成功"
else
    log_error "数据库连接测试失败"
fi

# 清理端口转发
kill $PORT_FORWARD_PID 2>/dev/null || true

# 测试7: 检查 PVC
echo ""
echo "测试 7: 检查持久卷..."
pvc_count=$(kubectl get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)
if [ "$pvc_count" -gt 0 ]; then
    log_info "找到 $pvc_count 个持久卷"
    kubectl get pvc -n "$NAMESPACE" --no-headers | while read line; do
        pvc_name=$(echo $line | awk '{print $1}')
        pvc_status=$(echo $line | awk '{print $2}')
        if [ "$pvc_status" = "Bound" ]; then
            log_info "PVC $pvc_name: $pvc_status"
        else
            log_warn "PVC $pvc_name: $pvc_status"
        fi
    done
else
    log_warn "未找到持久卷 (可能使用 emptyDir)"
fi

# 总结
echo ""
echo "🎯 快速验证完成！"
echo ""

# 判断整体健康状况
if [ $etcd_ready -ge 2 ] && [ $pg_ready -ge 2 ] && [ "$leader_found" = true ]; then
    echo -e "${GREEN}✅ 集群状态: 健康${NC}"
    echo "可以开始使用集群进行测试和生产工作负载。"
    
    echo ""
    echo "📋 连接信息:"
    echo "• 主库连接 (读写): kubectl port-forward -n $NAMESPACE svc/$CLUSTER_NAME-primary 5432:5432"
    echo "• 副本连接 (只读): kubectl port-forward -n $NAMESPACE svc/$CLUSTER_NAME-readonly 5433:5433"
    echo "• 所有节点连接: kubectl port-forward -n $NAMESPACE svc/$CLUSTER_NAME-all 5434:5434"
    echo "• 默认用户名: postgres"
    echo "• 默认密码: postgres123"
    
else
    echo -e "${RED}❌ 集群状态: 不健康${NC}"
    echo "请检查以上错误信息并修复问题。"
    exit 1
fi
