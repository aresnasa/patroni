# Patroni PostgreSQL Kubernetes 高可用集群

这是一个完整的 Kubernetes 环境下的 Patroni PostgreSQL 高可用集群解决方案，包含集群部署和全面的测试套件。

## 🏗️ 系统架构

```
┌─────────────────────────────────────────────────────────────────┐
│                    Kubernetes Patroni Cluster                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐         │
│  │   etcd-0    │    │   etcd-1    │    │   etcd-2    │         │
│  │  (v3.5.15)  │    │  (v3.5.15)  │    │  (v3.5.15)  │         │
│  └─────────────┘    └─────────────┘    └─────────────┘         │
│           │                 │                 │                  │
│           └─────────────────┼─────────────────┘                  │
│                            │                                     │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐         │
│  │postgresql-0 │    │postgresql-1 │    │postgresql-2 │         │
│  │ (PG 16 +    │◄──►│ (PG 16 +    │◄──►│ (PG 16 +    │         │
│  │ Patroni 4.0.6)   │ Patroni 4.0.6)   │ Patroni 4.0.6)       │
│  └─────────────┘    └─────────────┘    └─────────────┘         │
│           │                 │                 │                  │
│           └─────────────────┼─────────────────┘                  │
│                            │                                     │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │          Kubernetes Load Balancer Services                  ││
│  │  primary (5432) │ readonly (5433) │ all (5434)              ││
│  │  主库读写服务     │  只读副本服务     │  所有节点服务           ││
│  └─────────────────────────────────────────────────────────────┘│
│                            │                                     │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐         │
│  │ 数据写入器   │    │ 监控系统     │    │ 混沌测试     │         │
│  │(持续写入)   │    │(实时监控)   │    │(故障注入)   │         │
│  └─────────────┘    └─────────────┘    └─────────────┘         │
└─────────────────────────────────────────────────────────────────┘
```

## 🚀 快速开始

### 前置条件

- Kubernetes 集群 (v1.20+)
- kubectl 命令行工具
- Helm 3.0+
- 至少 8GB 可用内存和 4 CPU 核心
- 支持 PersistentVolume 的存储类 (可选)

### 一键部署

```bash
# 克隆项目
git clone <repository-url>
cd k8s-patroni-cluster

# 给部署脚本执行权限
chmod +x deploy.sh

# 部署集群和测试套件
./deploy.sh all

# 或者分步部署
./deploy.sh deploy    # 仅部署集群
./deploy.sh test      # 仅部署测试套件
```

### 自定义部署

```bash
# 使用自定义命名空间和存储类
./deploy.sh all -n my-cluster -s fast-ssd

# 仅部署到特定命名空间
./deploy.sh deploy --namespace production-db
```

## 📦 组件版本

| 组件 | 版本 | 说明 |
|------|------|------|
| PostgreSQL | 16-alpine | 主数据库 |
| Patroni | 4.0.6 | 高可用管理器 |
| etcd | 3.5.15 | 分布式协调服务 |
| HAProxy | 3.0-alpine | 负载均衡器 |
| Python | 3.11-alpine | 测试工具基础镜像 |

## 🔧 配置说明

### 主集群配置 (values.yaml)

```yaml
# PostgreSQL 配置
postgresql:
  version: "16"
  username: postgres
  password: postgres123
  
# Patroni 配置
patroni:
  version: "4.0.6"
  scope: postgres-cluster
  ttl: 30
  
# 存储配置
persistence:
  enabled: true
  size: 20Gi
  
# 资源配置
resources:
  limits:
    cpu: 2
    memory: 2Gi
  requests:
    cpu: 500m
    memory: 1Gi
```

### 测试套件配置

```yaml
# 数据写入器
dataWriter:
  enabled: true
  duration: 300    # 测试时长(秒)
  interval: 1      # 写入间隔(秒)
  
# 混沌测试
chaosTests:
  enabled: true
  duration: 600    # 测试时长(秒)
  interval: 60     # 故障间隔(秒)
  chaosTypes:
    - podKill
    - networkPartition
    - cpuStress
    - memoryStress

# 监控
monitoring:
  enabled: true
  interval: 10     # 监控间隔(秒)
```

## 🛠️ 管理操作

### 查看集群状态

```bash
# 查看整体状态
./deploy.sh status

# 查看特定组件
kubectl get pods -n patroni-cluster -l app.kubernetes.io/component=postgresql
kubectl get pods -n patroni-cluster -l app.kubernetes.io/component=etcd
kubectl get pods -n patroni-cluster -l app.kubernetes.io/component=haproxy
```

### 查看日志

```bash
# 查看所有组件日志
./deploy.sh logs all

# 查看特定组件
./deploy.sh logs postgresql
./deploy.sh logs etcd
./deploy.sh logs haproxy
./deploy.sh logs tests
```

### 连接数据库

```bash
# 获取负载均衡服务信息
kubectl get svc -n patroni-cluster -l app.kubernetes.io/component=loadbalancer

# 端口转发到本地 - 主库连接 (读写)
kubectl port-forward -n patroni-cluster svc/patroni-cluster-primary 5432:5432
psql -h localhost -p 5432 -U postgres -d postgres

# 端口转发到本地 - 副本连接 (只读)
kubectl port-forward -n patroni-cluster svc/patroni-cluster-readonly 5433:5433
psql -h localhost -p 5433 -U postgres -d postgres

# 端口转发到本地 - 所有节点连接
kubectl port-forward -n patroni-cluster svc/patroni-cluster-all 5434:5434
psql -h localhost -p 5434 -U postgres -d postgres
```

### 扩缩容操作

```bash
# 扩容到5个节点
helm upgrade patroni-cluster ./charts/patroni-cluster \
  --set cluster.replicas=5 \
  -n patroni-cluster

# 缩容到2个节点  
helm upgrade patroni-cluster ./charts/patroni-cluster \
  --set cluster.replicas=2 \
  -n patroni-cluster
```

## 🧪 测试功能

### 内置测试套件

1. **数据写入器** - 持续写入测试数据，验证数据一致性
2. **混沌测试** - 模拟各种故障场景
3. **监控系统** - 实时监控集群状态
4. **一致性检查** - 验证节点间数据一致性

### 运行基础测试

```bash
# 运行 Helm 测试
helm test patroni-cluster -n patroni-cluster

# 查看测试结果
kubectl logs -n patroni-cluster patroni-cluster-test
```

### 监控测试进度

```bash
# 查看数据写入器日志
kubectl logs -n patroni-cluster -l app.kubernetes.io/component=data-writer -f

# 查看监控系统日志
kubectl logs -n patroni-cluster -l app.kubernetes.io/component=monitoring -f

# 查看混沌测试日志
kubectl logs -n patroni-cluster -l app.kubernetes.io/component=chaos-tests -f
```

## 🌪️ 故障测试

### 手动故障注入

```bash
# 删除主节点 pod
kubectl delete pod patroni-cluster-postgresql-0 -n patroni-cluster

# 模拟网络分区
kubectl exec -it patroni-cluster-postgresql-1 -n patroni-cluster -- \
  iptables -A INPUT -s <other-node-ip> -j DROP

# 施加 CPU 压力
kubectl exec -it patroni-cluster-postgresql-2 -n patroni-cluster -- \
  stress --cpu 4 --timeout 60s
```

### 自动故障恢复验证

系统会自动检测并报告：
- 主节点故障转移时间
- 数据丢失情况
- 节点恢复时间
- 服务可用性

## 📊 监控指标

### Patroni 集群指标

- 节点角色 (leader/replica)
- 节点状态 (running/stopped/starting)
- 复制延迟
- 时间线变化

### 数据库指标

- 连接数
- 事务速率
- 数据一致性
- 查询性能

### 系统指标

- CPU 使用率
- 内存使用率
- 磁盘 I/O
- 网络延迟

## 🔐 安全配置

### 密码管理

```bash
# 更新数据库密码
kubectl create secret generic patroni-cluster-secret \
  --from-literal=superuser-password=new-password \
  --from-literal=replication-password=new-repl-password \
  -n patroni-cluster --dry-run=client -o yaml | kubectl apply -f -

# 重启集群以应用新密码
kubectl rollout restart statefulset/patroni-cluster-postgresql -n patroni-cluster
```

### 网络策略

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: patroni-cluster-network-policy
  namespace: patroni-cluster
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: patroni-cluster
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: allowed-namespace
```

## 🚨 故障排除

### 常见问题

1. **Pod 启动失败**
   ```bash
   # 检查事件
   kubectl describe pod <pod-name> -n patroni-cluster
   
   # 检查日志
   kubectl logs <pod-name> -n patroni-cluster
   ```

2. **etcd 集群连接问题**
   ```bash
   # 检查 etcd 健康状态
   kubectl exec -it patroni-cluster-etcd-0 -n patroni-cluster -- \
     etcdctl endpoint health --cluster
   ```

3. **Patroni 无法选举主节点**
   ```bash
   # 检查 Patroni 配置
   kubectl exec -it patroni-cluster-postgresql-0 -n patroni-cluster -- \
     curl localhost:8008/config
   ```

4. **数据不一致**
   ```bash
   # 检查复制状态
   kubectl exec -it patroni-cluster-postgresql-0 -n patroni-cluster -- \
     psql -U postgres -c "SELECT * FROM pg_stat_replication;"
   ```

### 紧急恢复

```bash
# 完全重建集群 (注意：会丢失数据)
./deploy.sh cleanup
./deploy.sh all

# 从备份恢复 (需要提前配置备份)
kubectl exec -it patroni-cluster-postgresql-0 -n patroni-cluster -- \
  pg_basebackup -h backup-server -D /var/lib/postgresql/data/pgdata
```

## 🔄 升级指南

### 升级 Patroni

```bash
# 升级到新版本
helm upgrade patroni-cluster ./charts/patroni-cluster \
  --set postgresql.patroni.image.tag=4.1.0 \
  -n patroni-cluster
```

### 升级 PostgreSQL

```bash
# 主版本升级需要谨慎操作
# 建议先备份数据，然后重新部署
```

## 📈 性能优化

### 数据库参数调优

```yaml
postgresql:
  patroni:
    parameters:
      max_connections: 500
      shared_buffers: 512MB
      effective_cache_size: 2GB
      work_mem: 8MB
      maintenance_work_mem: 128MB
```

### 资源优化

```yaml
resources:
  limits:
    cpu: 4
    memory: 4Gi
  requests:
    cpu: 1
    memory: 2Gi
```

## 🤝 贡献指南

1. Fork 项目
2. 创建功能分支
3. 提交更改
4. 创建 Pull Request

## 📄 许可证

[MIT License](LICENSE)

## 📞 支持

如有问题或建议，请创建 Issue 或联系维护团队。

---

## 🎯 测试验证清单

- [ ] 集群部署成功
- [ ] 所有 Pod 运行正常
- [ ] etcd 集群健康
- [ ] PostgreSQL 主从复制正常
- [ ] HAProxy 负载均衡工作
- [ ] 故障转移功能正常
- [ ] 数据一致性验证通过
- [ ] 监控系统正常运行
- [ ] 性能测试满足要求

---

**🎉 恭喜！您已成功部署 Patroni PostgreSQL Kubernetes 高可用集群！**
