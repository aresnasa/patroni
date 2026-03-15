# 🚨 Patroni 集群启动问题诊断和修复指南

## 📋 问题诊断

我们发现了以下问题：

### 1. ✅ 已修复：Helm 模板错误
**问题**: 遗留的 HAProxy 模板文件导致 Helm 模板编译失败
**解决**: 已删除以下文件：
- `charts/patroni-cluster/templates/haproxy-deployment.yaml`
- `charts/patroni-cluster/templates/haproxy-configmap.yaml`
- `charts/patroni-cluster/templates/haproxy-service.yaml`

### 2. ❌ 待解决：Kubernetes 集群未运行
**问题**: Docker Desktop 的 Kubernetes 功能未启用或未运行
**症状**: `kubectl get nodes` 命令无响应

---

## 🔧 修复步骤

### 步骤 1: 启用 Docker Desktop Kubernetes

1. **打开 Docker Desktop**
2. **进入设置** (Settings/Preferences)
3. **选择 Kubernetes 选项卡**
4. **勾选 "Enable Kubernetes"**
5. **点击 "Apply & Restart"**
6. **等待 Kubernetes 启动完成** (状态显示为绿色)

### 步骤 2: 验证 Kubernetes 状态

```bash
# 检查节点状态
kubectl get nodes

# 应该看到类似输出：
# NAME             STATUS   ROLES           AGE   VERSION
# docker-desktop   Ready    control-plane   1m    v1.x.x
```

### 步骤 3: 部署 Patroni 集群

```bash
# 进入项目目录
cd k8s-patroni-cluster

# 部署集群
./deploy.sh deploy

# 检查部署状态
./deploy.sh status

# 查看连接信息
./deploy.sh info
```

---

## 🎯 替代方案

如果 Docker Desktop Kubernetes 有问题，可以使用以下替代方案：

### 方案 1: 使用 minikube

```bash
# 安装 minikube (如果未安装)
brew install minikube

# 启动 minikube
minikube start

# 验证状态
kubectl get nodes

# 部署 Patroni
./deploy.sh deploy
```

### 方案 2: 使用 kind

```bash
# 安装 kind (如果未安装)
brew install kind

# 创建集群
kind create cluster --name patroni-test

# 验证状态
kubectl get nodes

# 部署 Patroni
./deploy.sh deploy
```

### 方案 3: 使用 Docker Compose (临时测试)

```bash
# 进入 Docker Compose 目录
cd ../patroni-cluster

# 启动集群
docker-compose up -d

# 检查状态
docker-compose ps

# 连接测试
psql -h localhost -p 15000 -U postgres
```

---

## 🔍 常见问题排查

### Q1: kubectl 命令无响应
**解决**: 检查 Docker Desktop 是否运行，Kubernetes 是否启用

### Q2: Helm 部署失败
**解决**: 运行 `helm template charts/patroni-cluster --debug` 检查模板错误

### Q3: Pod 一直处于 Pending 状态
**解决**: 检查资源配置，可能需要降低资源请求

### Q4: etcd 启动失败
**解决**: 检查存储类配置，确保 PVC 能正常创建

### Q5: PostgreSQL 连接失败
**解决**: 检查 Service 状态和网络策略

---

## 📊 部署验证清单

部署完成后，请验证以下项目：

- [ ] Kubernetes 集群运行正常
- [ ] 命名空间 `patroni-cluster` 已创建
- [ ] etcd 集群 3 个 Pod 都是 Running 状态
- [ ] PostgreSQL 集群 3 个 Pod 都是 Running 状态
- [ ] 负载均衡 Service 已创建
- [ ] 可以通过 `./deploy.sh info` 获取连接信息
- [ ] 可以通过 `./quick-test.sh` 验证集群功能

---

## 🚀 快速启动命令

```bash
# 1. 确保 Docker Desktop Kubernetes 已启用
kubectl get nodes

# 2. 部署集群
./deploy.sh all

# 3. 验证部署
./quick-test.sh

# 4. 查看连接信息
./deploy.sh info
```

---

**下一步**: 请按照上述步骤启用 Docker Desktop 的 Kubernetes 功能，然后重新运行部署命令。
