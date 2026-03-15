#!/bin/bash

# 修复现有 Patroni 命名空间的 Helm 标签和注解
# 使其可以被 Helm 管理

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_header() {
    echo -e "${BLUE}[FIX]${NC} $1"
}

# 配置
NAMESPACE=${NAMESPACE:-"patroni-cluster"}
RELEASE_NAME=${RELEASE_NAME:-"patroni-cluster"}

fix_namespace() {
    log_header "修复命名空间 $NAMESPACE 的 Helm 标签和注解..."
    
    # 检查命名空间是否存在
    if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
        log_error "命名空间 $NAMESPACE 不存在"
        return 1
    fi
    
    log_info "找到命名空间 $NAMESPACE，正在检查 Helm 管理状态..."
    
    # 检查当前标签
    CURRENT_MANAGED_BY=$(kubectl get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || echo "")
    CURRENT_RELEASE_NAME=$(kubectl get namespace "$NAMESPACE" -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null || echo "")
    
    echo "当前状态:"
    echo "  managed-by: ${CURRENT_MANAGED_BY:-"未设置"}"
    echo "  release-name: ${CURRENT_RELEASE_NAME:-"未设置"}"
    
    if [ "$CURRENT_MANAGED_BY" = "Helm" ] && [ "$CURRENT_RELEASE_NAME" = "$RELEASE_NAME" ]; then
        log_info "✅ 命名空间已正确配置为 Helm 管理"
        return 0
    fi
    
    log_warn "命名空间需要修复 Helm 标签和注解"
    
    # 添加/更新 Helm 标签
    log_info "添加 Helm 标签..."
    kubectl label namespace "$NAMESPACE" \
        app.kubernetes.io/managed-by=Helm \
        app.kubernetes.io/name="$RELEASE_NAME" \
        app.kubernetes.io/instance="$RELEASE_NAME" \
        helm.sh/chart="patroni-cluster-1.0.0" \
        --overwrite
    
    # 添加/更新 Helm 注解
    log_info "添加 Helm 注解..."
    kubectl annotate namespace "$NAMESPACE" \
        meta.helm.sh/release-name="$RELEASE_NAME" \
        meta.helm.sh/release-namespace="$NAMESPACE" \
        --overwrite
    
    log_info "✅ 命名空间 Helm 标签和注解已修复"
    
    # 验证修复结果
    FIXED_MANAGED_BY=$(kubectl get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || echo "")
    FIXED_RELEASE_NAME=$(kubectl get namespace "$NAMESPACE" -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null || echo "")
    
    echo "修复后状态:"
    echo "  managed-by: $FIXED_MANAGED_BY"
    echo "  release-name: $FIXED_RELEASE_NAME"
    
    if [ "$FIXED_MANAGED_BY" = "Helm" ] && [ "$FIXED_RELEASE_NAME" = "$RELEASE_NAME" ]; then
        log_info "🎉 命名空间修复成功！现在可以使用 Helm 管理了"
        return 0
    else
        log_error "❌ 命名空间修复失败"
        return 1
    fi
}

clean_failed_releases() {
    log_header "清理失败的 Helm releases..."
    
    # 检查是否有失败的 releases
    FAILED_RELEASES=$(helm list -n "$NAMESPACE" --failed --short 2>/dev/null || echo "")
    
    if [ -n "$FAILED_RELEASES" ]; then
        log_warn "发现失败的 releases: $FAILED_RELEASES"
        for release in $FAILED_RELEASES; do
            log_info "删除失败的 release: $release"
            helm uninstall "$release" -n "$NAMESPACE" 2>/dev/null || true
        done
    else
        log_info "没有发现失败的 releases"
    fi
}

check_existing_resources() {
    log_header "检查现有资源..."
    
    # 检查是否有现有的 Patroni 资源
    EXISTING_PODS=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=postgresql --no-headers 2>/dev/null | wc -l || echo "0")
    EXISTING_SERVICES=$(kubectl get services -n "$NAMESPACE" -l app.kubernetes.io/name --no-headers 2>/dev/null | wc -l || echo "0")
    EXISTING_PVCS=$(kubectl get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l || echo "0")
    
    echo "现有资源统计:"
    echo "  Pods: $EXISTING_PODS"
    echo "  Services: $EXISTING_SERVICES"
    echo "  PVCs: $EXISTING_PVCS"
    
    if [ "$EXISTING_PODS" -gt 0 ] || [ "$EXISTING_SERVICES" -gt 0 ] || [ "$EXISTING_PVCS" -gt 0 ]; then
        log_warn "⚠️ 发现现有资源，可能需要手动处理冲突"
        echo ""
        echo "如果遇到资源冲突，可以选择："
        echo "1. 删除现有资源: kubectl delete all --all -n $NAMESPACE"
        echo "2. 使用不同的命名空间部署新集群"
        echo "3. 继续尝试部署（Helm 会尝试接管现有资源）"
    else
        log_info "✅ 命名空间中没有现有资源，可以安全部署"
    fi
}

show_next_steps() {
    log_header "后续步骤建议"
    
    echo "命名空间已修复，现在可以："
    echo ""
    echo "1. 部署 Patroni 集群:"
    echo "   ./deploy.sh deploy"
    echo ""
    echo "2. 或者手动使用 Helm 部署:"
    echo "   helm install $RELEASE_NAME charts/patroni-cluster \\"
    echo "     --namespace $NAMESPACE \\"
    echo "     --set global.namespace=$NAMESPACE \\"
    echo "     --set namespace.create=false"
    echo ""
    echo "3. 部署测试套件:"
    echo "   ./deploy.sh test"
    echo ""
    echo "4. 检查集群状态:"
    echo "   ./deploy.sh status"
}

main() {
    case "${1}" in
        "fix")
            fix_namespace
            clean_failed_releases
            check_existing_resources
            show_next_steps
            ;;
        "clean")
            log_header "清理所有资源..."
            log_warn "这将删除命名空间 $NAMESPACE 中的所有资源！"
            read -p "确认删除? (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                kubectl delete all --all -n "$NAMESPACE" 2>/dev/null || true
                kubectl delete pvc --all -n "$NAMESPACE" 2>/dev/null || true
                kubectl delete configmap --all -n "$NAMESPACE" 2>/dev/null || true
                kubectl delete secret --all -n "$NAMESPACE" 2>/dev/null || true
                log_info "✅ 资源清理完成"
            else
                log_info "取消清理操作"
            fi
            ;;
        "status")
            log_header "检查命名空间状态..."
            if kubectl get namespace "$NAMESPACE" &> /dev/null; then
                echo "命名空间信息:"
                kubectl get namespace "$NAMESPACE" -o yaml
            else
                log_error "命名空间 $NAMESPACE 不存在"
            fi
            ;;
        *)
            echo "Patroni 集群命名空间修复工具"
            echo ""
            echo "用法: $0 {fix|clean|status}"
            echo ""
            echo "命令:"
            echo "  fix    - 修复命名空间的 Helm 标签和注解"
            echo "  clean  - 清理命名空间中的所有资源"
            echo "  status - 查看命名空间状态"
            echo ""
            echo "环境变量:"
            echo "  NAMESPACE     - 要修复的命名空间 (默认: patroni-cluster)"
            echo "  RELEASE_NAME  - Helm Release 名称 (默认: patroni-cluster)"
            echo ""
            echo "示例:"
            echo "  $0 fix                          # 修复默认命名空间"
            echo "  NAMESPACE=my-db $0 fix          # 修复指定命名空间"
            echo "  $0 clean                        # 清理资源"
            echo "  $0 status                       # 查看状态"
            echo ""
            echo "常见问题解决:"
            echo "1. Helm 安装失败 (ownership metadata 错误):"
            echo "   $0 fix"
            echo ""
            echo "2. 资源冲突:"
            echo "   $0 clean && $0 fix"
            echo ""
            echo "3. 重新开始:"
            echo "   $0 clean && kubectl delete namespace $NAMESPACE"
            exit 1
            ;;
    esac
}

main "$@"
