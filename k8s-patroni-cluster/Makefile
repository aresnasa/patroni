# Patroni Kubernetes Cluster Makefile
# 简化常用操作

.PHONY: help deploy test status logs cleanup quick-test lint

# 默认配置
NAMESPACE ?= patroni-cluster
STORAGE_CLASS ?= 
TIMEOUT ?= 600s

# 颜色定义
GREEN := \033[0;32m
YELLOW := \033[1;33m
RED := \033[0;31m
NC := \033[0m # No Color

help: ## 显示帮助信息
	@echo "$(GREEN)Patroni Kubernetes 集群管理$(NC)"
	@echo ""
	@echo "$(YELLOW)可用命令:$(NC)"
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  $(GREEN)%-15s$(NC) %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo ""
	@echo "$(YELLOW)环境变量:$(NC)"
	@echo "  NAMESPACE     目标命名空间 (默认: $(NAMESPACE))"
	@echo "  STORAGE_CLASS 存储类名称 (默认: 默认存储类)"
	@echo "  TIMEOUT       等待超时时间 (默认: $(TIMEOUT))"
	@echo ""
	@echo "$(YELLOW)示例:$(NC)"
	@echo "  make deploy NAMESPACE=production"
	@echo "  make test STORAGE_CLASS=fast-ssd"
	@echo "  make status NAMESPACE=staging"

deploy: ## 部署 Patroni 集群
	@echo "$(GREEN)部署 Patroni 集群到命名空间: $(NAMESPACE)$(NC)"
	./deploy.sh deploy -n $(NAMESPACE) $(if $(STORAGE_CLASS),-s $(STORAGE_CLASS)) -w $(TIMEOUT)

test: ## 部署测试套件
	@echo "$(GREEN)部署测试套件到命名空间: $(NAMESPACE)$(NC)"
	./deploy.sh test -n $(NAMESPACE)

all: ## 部署集群和测试套件
	@echo "$(GREEN)部署完整系统到命名空间: $(NAMESPACE)$(NC)"
	./deploy.sh all -n $(NAMESPACE) $(if $(STORAGE_CLASS),-s $(STORAGE_CLASS)) -w $(TIMEOUT)

status: ## 检查集群状态
	@echo "$(GREEN)检查集群状态...$(NC)"
	./deploy.sh status -n $(NAMESPACE)

quick-test: ## 运行快速验证测试
	@echo "$(GREEN)运行快速验证测试...$(NC)"
	./quick-test.sh $(NAMESPACE)

logs: ## 查看所有组件日志
	@echo "$(GREEN)查看组件日志...$(NC)"
	./deploy.sh logs all -n $(NAMESPACE)

logs-postgresql: ## 查看 PostgreSQL 日志
	./deploy.sh logs postgresql -n $(NAMESPACE)

logs-etcd: ## 查看 etcd 日志
	./deploy.sh logs etcd -n $(NAMESPACE)

logs-haproxy: ## 查看 HAProxy 日志
	./deploy.sh logs haproxy -n $(NAMESPACE)

logs-tests: ## 查看测试日志
	./deploy.sh logs tests -n $(NAMESPACE)

connect-primary: ## 连接主数据库 (端口转发)
	@echo "$(GREEN)连接主数据库 (端口 5432)...$(NC)"
	@echo "$(YELLOW)用户名: postgres, 密码: postgres123$(NC)"
	kubectl port-forward -n $(NAMESPACE) svc/patroni-cluster-haproxy 5432:5000

connect-replica: ## 连接副本数据库 (端口转发)
	@echo "$(GREEN)连接副本数据库 (端口 5433)...$(NC)"
	@echo "$(YELLOW)用户名: postgres, 密码: postgres123$(NC)"
	kubectl port-forward -n $(NAMESPACE) svc/patroni-cluster-haproxy 5433:5001

haproxy-stats: ## 查看 HAProxy 统计页面
	@echo "$(GREEN)启动 HAProxy 统计页面 (端口 7000)...$(NC)"
	@echo "$(YELLOW)访问: http://localhost:7000/stats$(NC)"
	@echo "$(YELLOW)用户名: admin, 密码: admin123$(NC)"
	kubectl port-forward -n $(NAMESPACE) svc/patroni-cluster-haproxy 7000:7000

scale-up: ## 扩容到5个节点
	@echo "$(GREEN)扩容集群到5个节点...$(NC)"
	helm upgrade patroni-cluster ./charts/patroni-cluster \
		--set cluster.replicas=5 \
		-n $(NAMESPACE)

scale-down: ## 缩容到2个节点
	@echo "$(YELLOW)缩容集群到2个节点...$(NC)"
	helm upgrade patroni-cluster ./charts/patroni-cluster \
		--set cluster.replicas=2 \
		-n $(NAMESPACE)

backup: ## 创建数据库备份
	@echo "$(GREEN)创建数据库备份...$(NC)"
	kubectl exec -it patroni-cluster-postgresql-0 -n $(NAMESPACE) -c postgresql -- \
		pg_dump -U postgres -d postgres > backup-$$(date +%Y%m%d-%H%M%S).sql
	@echo "$(GREEN)备份完成$(NC)"

restart-cluster: ## 重启整个集群
	@echo "$(YELLOW)重启 Patroni 集群...$(NC)"
	kubectl rollout restart statefulset/patroni-cluster-postgresql -n $(NAMESPACE)
	kubectl rollout restart statefulset/patroni-cluster-etcd -n $(NAMESPACE)
	kubectl rollout restart deployment/patroni-cluster-haproxy -n $(NAMESPACE)

chaos-pod-kill: ## 混沌测试: 随机删除一个 PostgreSQL pod
	@echo "$(RED)混沌测试: 删除随机 PostgreSQL pod...$(NC)"
	@POD=$$(kubectl get pods -n $(NAMESPACE) -l app.kubernetes.io/component=postgresql --no-headers | shuf -n 1 | awk '{print $$1}'); \
	echo "删除 pod: $$POD"; \
	kubectl delete pod $$POD -n $(NAMESPACE)

run-helm-tests: ## 运行 Helm 测试
	@echo "$(GREEN)运行 Helm 测试...$(NC)"
	helm test patroni-cluster -n $(NAMESPACE)

cleanup: ## 清理所有资源
	@echo "$(RED)清理命名空间: $(NAMESPACE)$(NC)"
	./deploy.sh cleanup -n $(NAMESPACE)

lint: ## 检查 Helm Chart 语法
	@echo "$(GREEN)检查 Helm Chart 语法...$(NC)"
	helm lint ./charts/patroni-cluster
	helm lint ./charts/patroni-cluster-tests

template: ## 生成 Kubernetes 清单文件
	@echo "$(GREEN)生成 Kubernetes 清单文件...$(NC)"
	helm template patroni-cluster ./charts/patroni-cluster \
		--namespace $(NAMESPACE) \
		$(if $(STORAGE_CLASS),--set global.storageClass=$(STORAGE_CLASS)) \
		> manifests.yaml
	@echo "$(GREEN)清单文件已生成: manifests.yaml$(NC)"

debug: ## 调试模式部署 (干运行)
	@echo "$(GREEN)调试模式部署...$(NC)"
	helm install patroni-cluster ./charts/patroni-cluster \
		--namespace $(NAMESPACE) \
		$(if $(STORAGE_CLASS),--set global.storageClass=$(STORAGE_CLASS)) \
		--dry-run --debug

monitoring-port-forward: ## 启动监控端口转发
	@echo "$(GREEN)启动监控端口转发...$(NC)"
	kubectl port-forward -n $(NAMESPACE) \
		svc/patroni-cluster-tests-monitoring 8080:80 &
	@echo "$(YELLOW)监控访问地址: http://localhost:8080$(NC)"

install-dependencies: ## 安装依赖工具
	@echo "$(GREEN)检查并安装依赖工具...$(NC)"
	@command -v kubectl >/dev/null 2>&1 || { echo "$(RED)kubectl 未安装$(NC)"; exit 1; }
	@command -v helm >/dev/null 2>&1 || { echo "$(RED)helm 未安装$(NC)"; exit 1; }
	@command -v jq >/dev/null 2>&1 || { echo "$(YELLOW)建议安装 jq 以获得更好的体验$(NC)"; }
	@echo "$(GREEN)依赖检查完成$(NC)"

# 开发用快捷命令
dev-deploy: install-dependencies deploy quick-test ## 开发环境一键部署和测试

production-deploy: ## 生产环境部署 (使用生产配置)
	@echo "$(GREEN)生产环境部署...$(NC)"
	@if [ ! -f production-values.yaml ]; then \
		echo "$(YELLOW)复制生产配置模板...$(NC)"; \
		cp production-values.yaml.example production-values.yaml; \
		echo "$(RED)请先编辑 production-values.yaml 配置文件！$(NC)"; \
		exit 1; \
	fi
	helm upgrade --install patroni-cluster ./charts/patroni-cluster \
		-f production-values.yaml \
		-n $(NAMESPACE) --create-namespace

info: ## 显示集群信息
	@echo "$(GREEN)=== 集群信息 ===$(NC)"
	@echo "命名空间: $(NAMESPACE)"
	@echo "集群名称: patroni-cluster"
	@echo ""
	@echo "$(GREEN)=== 服务端点 ===$(NC)"
	@kubectl get svc -n $(NAMESPACE) --no-headers 2>/dev/null | while read line; do \
		echo "$$line"; \
	done || echo "$(RED)命名空间不存在或无服务$(NC)"
	@echo ""
	@echo "$(GREEN)=== 快速连接命令 ===$(NC)"
	@echo "主库: make connect-primary NAMESPACE=$(NAMESPACE)"
	@echo "副本: make connect-replica NAMESPACE=$(NAMESPACE)"
	@echo "统计: make haproxy-stats NAMESPACE=$(NAMESPACE)"

# 设置默认目标
.DEFAULT_GOAL := help
