# 🎯 Kubernetes Patroni PostgreSQL 集群项目概览

## 📁 项目结构

```
k8s-patroni-cluster/
├── 📄 README.md                          # 项目说明文档
├── 🚀 deploy.sh                          # 主部署脚本
├── 🧪 quick-test.sh                      # 快速验证脚本
├── ⚙️ Makefile                           # Make 构建文件
├── 📋 production-values.yaml.example     # 生产环境配置示例
├── 📊 PROJECT_OVERVIEW.md                # 项目概览（本文件）
│
├── charts/                               # Helm Charts 目录
│   ├── patroni-cluster/                  # 主集群 Chart
│   │   ├── Chart.yaml                    # Chart 元数据
│   │   ├── values.yaml                   # 默认配置
│   │   └── templates/                    # Kubernetes 模板
│   │       ├── _helpers.tpl              # Helm 辅助函数
│   │       ├── namespace.yaml            # 命名空间
│   │       ├── serviceaccount.yaml       # 服务账户和 RBAC
│   │       ├── secret.yaml               # 密钥配置
│   │       │
│   │       ├── etcd-statefulset.yaml     # etcd 集群
│   │       ├── etcd-service.yaml         # etcd 服务
│   │       │
│   │       ├── patroni-configmap.yaml    # Patroni 配置
│   │       ├── patroni-statefulset.yaml  # PostgreSQL + Patroni
│   │       ├── postgresql-service.yaml   # PostgreSQL 服务
│   │       │
│   │       ├── haproxy-configmap.yaml    # HAProxy 配置
│   │       ├── haproxy-deployment.yaml   # HAProxy 部署
│   │       ├── haproxy-service.yaml      # HAProxy 服务
│   │       │
│   │       └── tests/                    # 内置测试
│   │           └── test-connection.yaml  # 连接测试
│   │
│   └── patroni-cluster-tests/            # 测试套件 Chart
│       ├── Chart.yaml                    # 测试 Chart 元数据
│       ├── values.yaml                   # 测试配置
│       └── templates/                    # 测试模板
│           ├── _helpers.tpl              # 辅助函数
│           ├── rbac.yaml                 # 测试权限
│           ├── data-writer.yaml          # 数据写入器
│           ├── chaos-test.yaml           # 混沌测试
│           ├── monitor.yaml              # 集群监控
│           └── consistency-check.yaml    # 一致性检查
```

## 🏗️ 系统组件

### 核心组件 (patroni-cluster)

| 组件 | 版本 | 副本数 | 功能 |
|------|------|--------|------|
| **PostgreSQL** | 16-alpine | 3 | 主数据库服务 |
| **Patroni** | 4.0.6 | 3 | 高可用管理 |
| **etcd** | v3.5.15 | 3 | 分布式配置存储 |
| **HAProxy** | 3.0-alpine | 2 | 负载均衡器 |

### 测试组件 (patroni-cluster-tests)

| 组件 | 类型 | 功能 |
|------|------|------|
| **数据写入器** | Job | 持续写入测试数据 |
| **混沌测试** | Job | 故障注入和恢复测试 |
| **监控器** | Deployment | 实时集群状态监控 |
| **一致性检查** | Deployment | 数据一致性验证 |

## 🚀 部署流程

### 1. 环境准备
```bash
# 检查前置条件
kubectl cluster-info
helm version

# 设置环境变量（可选）
export NAMESPACE="my-patroni"
export RELEASE_NAME="my-cluster"
```

### 2. 快速部署
```bash
# 一键部署集群
./deploy.sh deploy

# 等待集群就绪并查看状态
./deploy.sh status

# 查看访问信息
./deploy.sh info
```

### 3. 部署测试套件
```bash
# 部署并运行测试
./deploy.sh test

# 或者使用 Makefile
make deploy-tests
```

### 4. 快速验证
```bash
# 执行快速功能验证
./quick-test.sh

# 或指定命名空间
./quick-test.sh my-patroni
```

## 🎛️ 配置选项

### 生产环境配置
```bash
# 复制生产环境配置模板
cp production-values.yaml.example production-values.yaml

# 编辑配置文件
vi production-values.yaml

# 使用生产配置部署
helm install my-cluster charts/patroni-cluster \
  -f production-values.yaml \
  --namespace production-db
```

### 主要配置参数

| 参数类别 | 关键配置 | 说明 |
|----------|----------|------|
| **资源** | cpu, memory, storage | 根据负载调整 |
| **安全** | 密码，网络策略，RBAC | 生产环境必须配置 |
| **存储** | storageClass, size | 选择合适的存储类型 |
| **网络** | 服务类型，负载均衡器 | 根据访问需求配置 |
| **监控** | Prometheus, 日志 | 可选启用监控集成 |

## 🧪 测试功能

### 基础测试
- ✅ Pod 状态检查
- ✅ 服务连通性验证
- ✅ 数据库连接测试
- ✅ Patroni 集群状态
- ✅ etcd 集群健康检查

### 高级测试
- 🌪️ 混沌工程测试
  - Pod 故障注入
  - 网络分区模拟
  - 资源压力测试
- 📊 持续监控
  - 实时状态监控
  - 故障转移检测
  - 性能指标收集
- 🔍 数据一致性验证
  - 跨节点数据校验
  - 复制延迟监控
  - 数据完整性检查

## 📊 监控和运维

### 日常运维命令
```bash
# 查看集群状态
kubectl get pods -n patroni-system

# 查看 Patroni 集群信息
kubectl exec patroni-cluster-postgresql-0 -c postgresql -- \
  curl -s http://localhost:8008/cluster

# 查看日志
kubectl logs -f patroni-cluster-postgresql-0 -c postgresql

# 备份数据库
kubectl exec patroni-cluster-postgresql-0 -c postgresql -- \
  pg_dump -U postgres postgres > backup.sql
```

### 故障排除
```bash
# 检查事件
kubectl get events -n patroni-system --sort-by='.lastTimestamp'

# 检查存储
kubectl get pvc -n patroni-system

# 重启服务
kubectl rollout restart statefulset/patroni-cluster-postgresql
```

## 🔧 自定义扩展

### 添加新的测试
1. 在 `charts/patroni-cluster-tests/templates/` 下创建新的测试模板
2. 在 `values.yaml` 中添加相应配置
3. 更新 RBAC 权限（如需要）

### 集成监控系统
1. 修改 `values.yaml` 启用监控
2. 配置 ServiceMonitor 资源
3. 添加 Prometheus 规则和 Grafana 仪表板

### 备份策略
1. 配置 CronJob 定期备份
2. 集成对象存储（S3, GCS 等）
3. 实现自动恢复流程

## 📋 最佳实践

### 生产环境建议
- 🔒 **安全**: 使用强密码，启用网络策略
- 💾 **存储**: 使用高性能 SSD 存储类
- 🎯 **资源**: 根据负载合理分配 CPU 和内存
- 🌐 **网络**: 配置适当的负载均衡和防火墙规则
- 📊 **监控**: 启用完整的监控和告警
- 🔄 **备份**: 实施定期备份和恢复测试

### 容量规划
- **小型环境**: 3 节点，每节点 2 CPU, 4GB 内存
- **中型环境**: 3 节点，每节点 4 CPU, 8GB 内存
- **大型环境**: 3+ 节点，每节点 8+ CPU, 16+ GB 内存

### 故障转移策略
- **自动故障转移**: Patroni 自动检测和切换
- **手动干预**: 通过 Patroni API 手动控制
- **灾难恢复**: 跨可用区部署和数据复制

## 🎯 使用场景

### 适用场景
- ✅ 需要高可用 PostgreSQL 的生产环境
- ✅ 微服务架构的数据库层
- ✅ 需要零停机维护的关键业务系统
- ✅ 容器化环境的数据库服务
- ✅ 云原生应用的持久化存储

### 技术优势
- 🚀 **快速部署**: 一键部署完整集群
- 🔄 **自动故障转移**: 秒级故障检测和切换
- 📈 **弹性扩展**: 支持水平和垂直扩展
- 🛡️ **数据安全**: 多重备份和加密保护
- 🔍 **全面监控**: 完整的监控和测试套件

## 📞 支持和贡献

### 获取帮助
- 📖 查看 README.md 详细文档
- 🐛 在 GitHub Issues 报告问题
- 💬 参与社区讨论

### 贡献代码
- 🍴 Fork 项目并创建分支
- ✨ 添加新功能或修复问题
- 🧪 确保测试通过
- 📝 提交 Pull Request

---

**项目维护**: Patroni Team  
**最后更新**: 2025-06-14  
**版本**: 1.0.0
