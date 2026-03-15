#!/bin/bash

# Patroni PostgreSQL K8s Cluster 部署脚本
# 版本: 1.0.0

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 默认配置
NAMESPACE="patroni-cluster"
CLUSTER_NAME="patroni-cluster"
TESTS_NAME="patroni-tests"
STORAGE_CLASS=""
WAIT_TIMEOUT="600s"

# 函数定义
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $1"
}

usage() {
    cat << EOF
使用方法: $0 [命令] [选项]

命令:
  deploy          部署 Patroni 集群
  test            部署测试套件
  all             部署集群和测试套件
  status          检查集群状态
  info            显示集群连接信息
  logs            查看日志
  cleanup         清理所有资源
  help            显示此帮助信息

选项:
  -n, --namespace NAMESPACE     设置命名空间 (默认: patroni-cluster)
  -s, --storage-class CLASS     设置存储类
  -w, --wait TIMEOUT           设置等待超时时间 (默认: 600s)
  -h, --help                   显示帮助信息

示例:
  $0 deploy                     # 部署 Patroni 集群
  $0 test                       # 部署测试套件
  $0 all -n my-namespace        # 部署到指定命名空间
  $0 status                     # 检查集群状态
  $0 info                       # 显示连接信息
  $0 cleanup                    # 清理所有资源

EOF
}

check_prerequisites() {
    log_info "检查前置条件..."
    
    # 检查 kubectl
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl 未安装，请先安装 kubectl"
        exit 1
    fi
    
    # 检查 helm
    if ! command -v helm &> /dev/null; then
        log_error "helm 未安装，请先安装 helm"
        exit 1
    fi
    
    # 检查 Kubernetes 连接
    if ! kubectl cluster-info &> /dev/null; then
        log_error "无法连接到 Kubernetes 集群"
        exit 1
    fi
    
    log_info "前置条件检查通过"
}

create_namespace() {
    log_info "创建命名空间: $NAMESPACE"
    
    # 检查命名空间是否已存在
    if kubectl get namespace "$NAMESPACE" &> /dev/null; then
        log_warn "命名空间 $NAMESPACE 已存在"
        
        # 检查是否有 Helm 管理标签
        HELM_MANAGED=$(kubectl get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || echo "")
        
        if [ "$HELM_MANAGED" != "Helm" ]; then
            log_warn "命名空间不是由 Helm 管理，添加必要的标签和注解..."
            
            # 添加 Helm 标签和注解
            kubectl label namespace "$NAMESPACE" \
                app.kubernetes.io/managed-by=Helm \
                app.kubernetes.io/name="$CLUSTER_NAME" \
                app.kubernetes.io/instance="$CLUSTER_NAME" \
                --overwrite
            
            kubectl annotate namespace "$NAMESPACE" \
                meta.helm.sh/release-name="$CLUSTER_NAME" \
                meta.helm.sh/release-namespace="$NAMESPACE" \
                --overwrite
            
            log_info "✅ 命名空间标签和注解已更新"
        fi
    else
        # 创建新的命名空间
        cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: $NAMESPACE
  labels:
    name: $NAMESPACE
    app.kubernetes.io/name: $CLUSTER_NAME
    app.kubernetes.io/instance: $CLUSTER_NAME
    app.kubernetes.io/managed-by: Helm
  annotations:
    meta.helm.sh/release-name: $CLUSTER_NAME
    meta.helm.sh/release-namespace: $NAMESPACE
EOF
        log_info "✅ 命名空间 $NAMESPACE 创建成功"
    fi
}

deploy_cluster() {
    log_info "部署 Patroni PostgreSQL 集群..."
    
    # 构建 helm 参数
    HELM_ARGS="--namespace $NAMESPACE --create-namespace"
    
    if [[ -n "$STORAGE_CLASS" ]]; then
        HELM_ARGS="$HELM_ARGS --set global.storageClass=$STORAGE_CLASS"
    fi
    
    # 部署集群
    helm upgrade --install "$CLUSTER_NAME" ./charts/patroni-cluster $HELM_ARGS
    
    log_info "等待 Patroni 集群就绪..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=patroni-cluster,app.kubernetes.io/component=postgresql -n "$NAMESPACE" --timeout="$WAIT_TIMEOUT" || {
        log_warn "等待超时，检查 pod 状态..."
        kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=patroni-cluster,app.kubernetes.io/component=postgresql
    }
    
    log_info "等待 etcd 集群就绪..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=patroni-cluster,app.kubernetes.io/component=etcd -n "$NAMESPACE" --timeout="$WAIT_TIMEOUT" || {
        log_warn "等待超时，检查 etcd pod 状态..."
        kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=patroni-cluster,app.kubernetes.io/component=etcd
    }
    
    log_info "等待服务就绪..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/component=postgresql -n "$NAMESPACE" --timeout="$WAIT_TIMEOUT" || {
        log_warn "PostgreSQL 服务等待超时"
    }
    
    log_info "✅ Patroni 集群部署完成"
}

deploy_tests() {
    log_info "部署测试套件..."
    
    # 构建 helm 参数
    HELM_ARGS="--namespace $NAMESPACE"
    HELM_ARGS="$HELM_ARGS --set targetCluster.name=$CLUSTER_NAME"
    HELM_ARGS="$HELM_ARGS --set targetCluster.namespace=$NAMESPACE"
    
    # 部署测试套件
    helm upgrade --install "$TESTS_NAME" ./charts/patroni-cluster-tests $HELM_ARGS
    
    log_info "✅ 测试套件部署完成"
}

check_status() {
    log_info "检查集群状态..."
    
    echo ""
    log_info "=== Namespace 状态 ==="
    kubectl get namespace "$NAMESPACE" 2>/dev/null || log_warn "命名空间 $NAMESPACE 不存在"
    
    echo ""
    log_info "=== etcd 集群状态 ==="
    kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=etcd -o wide 2>/dev/null || log_warn "etcd pods 不存在"
    
    echo ""
    log_info "=== PostgreSQL 集群状态 ==="
    kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=postgresql -o wide 2>/dev/null || log_warn "PostgreSQL pods 不存在"
    
    echo ""
    log_info "=== 负载均衡服务状态 ==="
    kubectl get services -n "$NAMESPACE" -l app.kubernetes.io/component=loadbalancer 2>/dev/null || log_warn "负载均衡服务不存在"
    
    echo ""
    log_info "=== 服务状态 ==="
    kubectl get services -n "$NAMESPACE" 2>/dev/null || log_warn "服务不存在"
    
    echo ""
    log_info "=== PVC 状态 ==="
    kubectl get pvc -n "$NAMESPACE" 2>/dev/null || log_warn "PVC 不存在"
    
    echo ""
    log_info "=== 测试 Pods 状态 ==="
    kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=patroni-cluster-tests 2>/dev/null || log_warn "测试 pods 不存在"
    
    # 检查 Patroni 集群健康状态
    echo ""
    log_info "=== Patroni 集群健康检查 ==="
    for i in 0 1 2; do
        pod_name="$CLUSTER_NAME-postgresql-$i"
        if kubectl get pod "$pod_name" -n "$NAMESPACE" &>/dev/null; then
            log_debug "检查 $pod_name 的 Patroni 状态..."
            kubectl exec "$pod_name" -n "$NAMESPACE" -c postgresql -- curl -s http://localhost:8008/patroni 2>/dev/null | jq -r '"Node: " + .patroni.scope + " | Role: " + .role + " | State: " + .state' 2>/dev/null || log_warn "无法获取 $pod_name 的 Patroni 状态"
        fi
    done
}

show_logs() {
    local component="${1:-postgresql}"
    
    log_info "显示 $component 组件日志..."
    
    case "$component" in
        "etcd")
            kubectl logs -n "$NAMESPACE" -l app.kubernetes.io/component=etcd --tail=50
            ;;
        "postgresql"|"patroni")
            kubectl logs -n "$NAMESPACE" -l app.kubernetes.io/component=postgresql --tail=50
            ;;
        "services")
            kubectl get services -n "$NAMESPACE" -l app.kubernetes.io/component=loadbalancer
            ;;
        "tests")
            kubectl logs -n "$NAMESPACE" -l app.kubernetes.io/name=patroni-cluster-tests --tail=100
            ;;
        "all")
            log_info "=== etcd 日志 ==="
            kubectl logs -n "$NAMESPACE" -l app.kubernetes.io/component=etcd --tail=20
            echo ""
            log_info "=== PostgreSQL 日志 ==="
            kubectl logs -n "$NAMESPACE" -l app.kubernetes.io/component=postgresql --tail=20
            echo ""
            log_info "=== 负载均衡服务状态 ==="
            kubectl get services -n "$NAMESPACE" -l app.kubernetes.io/component=loadbalancer
            echo ""
            log_info "=== 测试日志 ==="
            kubectl logs -n "$NAMESPACE" -l app.kubernetes.io/name=patroni-cluster-tests --tail=20
            ;;
        *)
            log_error "未知组件: $component"
            log_info "支持的组件: etcd, postgresql, services, tests, all"
            exit 1
            ;;
    esac
}

cleanup() {
    log_warn "清理所有资源..."
    
    read -p "确定要删除所有资源吗？这将删除命名空间 $NAMESPACE 中的所有内容 (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "取消清理操作"
        return
    fi
    
    log_info "删除测试套件..."
    helm uninstall "$TESTS_NAME" -n "$NAMESPACE" 2>/dev/null || log_warn "测试套件删除失败或不存在"
    
    log_info "删除 Patroni 集群..."
    helm uninstall "$CLUSTER_NAME" -n "$NAMESPACE" 2>/dev/null || log_warn "Patroni 集群删除失败或不存在"
    
    log_info "删除 PVC..."
    kubectl delete pvc --all -n "$NAMESPACE" 2>/dev/null || log_warn "PVC 删除失败或不存在"
    
    log_info "删除命名空间..."
    kubectl delete namespace "$NAMESPACE" 2>/dev/null || log_warn "命名空间删除失败或不存在"
    
    log_info "✅ 清理完成"
}

run_tests() {
    log_info "运行集群测试..."
    helm test "$CLUSTER_NAME" -n "$NAMESPACE"
}

show_info() {
    log_info "显示集群连接信息..."
    
    echo ""
    log_info "=== Patroni PostgreSQL 集群连接信息 ==="
    echo ""
    
    # 检查集群是否存在
    if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
        log_error "命名空间 $NAMESPACE 不存在"
        return 1
    fi
    
    # 显示服务信息
    echo "📋 集群服务:"
    kubectl get services -n "$NAMESPACE" -l app.kubernetes.io/component=loadbalancer --no-headers 2>/dev/null | while read -r name type cluster_ip external_ip port_info age; do
        echo "  • $name ($type): $cluster_ip"
    done
    echo ""
    
    # 显示连接命令
    echo "🔌 本地连接命令:"
    echo ""
    echo "主库连接 (读写):"
    echo "  kubectl port-forward -n $NAMESPACE svc/$CLUSTER_NAME-primary 5432:5432"
    echo "  psql -h localhost -p 5432 -U postgres -d postgres"
    echo ""
    echo "只读连接:"
    echo "  kubectl port-forward -n $NAMESPACE svc/$CLUSTER_NAME-readonly 5433:5433"
    echo "  psql -h localhost -p 5433 -U postgres -d postgres"
    echo ""
    echo "所有节点连接:"
    echo "  kubectl port-forward -n $NAMESPACE svc/$CLUSTER_NAME-all 5434:5434"
    echo "  psql -h localhost -p 5434 -U postgres -d postgres"
    echo ""
    
    # 显示集群状态
    echo "📊 集群状态:"
    pg_replicas=$(kubectl get statefulset "$CLUSTER_NAME-postgresql" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    pg_desired=$(kubectl get statefulset "$CLUSTER_NAME-postgresql" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "3")
    etcd_replicas=$(kubectl get statefulset "$CLUSTER_NAME-etcd" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    etcd_desired=$(kubectl get statefulset "$CLUSTER_NAME-etcd" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "3")
    
    echo "  • PostgreSQL: $pg_replicas/$pg_desired 副本就绪"
    echo "  • etcd: $etcd_replicas/$etcd_desired 副本就绪"
    echo ""
    
    # 显示管理命令
    echo "⚙️ 管理命令:"
    echo "  检查状态: ./deploy.sh status"
    echo "  查看日志: ./deploy.sh logs"
    echo "  运行测试: ./quick-test.sh"
    echo "  清理资源: ./deploy.sh cleanup"
}

# 主逻辑
main() {
    local command=""
    
    # 解析参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            deploy|test|all|status|logs|cleanup|info|help)
                command="$1"
                shift
                ;;
            -n|--namespace)
                NAMESPACE="$2"
                shift 2
                ;;
            -s|--storage-class)
                STORAGE_CLASS="$2"
                shift 2
                ;;
            -w|--wait)
                WAIT_TIMEOUT="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "未知参数: $1"
                usage
                exit 1
                ;;
        esac
    done
    
    # 如果没有指定命令，显示使用帮助
    if [[ -z "$command" ]]; then
        usage
        exit 1
    fi
    
    # 检查前置条件
    check_prerequisites
    
    # 执行命令
    case "$command" in
        "deploy")
            create_namespace
            deploy_cluster
            ;;
        "test")
            deploy_tests
            ;;
        "all")
            create_namespace
            deploy_cluster
            deploy_tests
            ;;
        "status")
            check_status
            ;;
        "logs")
            show_logs "${2:-all}"
            ;;
        "cleanup")
            cleanup
            ;;
        "info")
            show_info
            ;;
        "run-tests")
            run_tests
            ;;
        "help")
            usage
            ;;
        *)
            log_error "未知命令: $command"
            usage
            exit 1
            ;;
    esac
}

# 如果脚本被直接执行
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
