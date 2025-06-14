# Patroni PostgreSQL 高可用集群完整测试系统

这是一个完整的 Patroni PostgreSQL 高可用集群测试环境，包含持续数据写入、故障注入、监控和数据一致性验证功能。

## 🏗️ 系统架构

```
┌─────────────────────────────────────────────────────────────────┐
│                    完整测试系统架构                                    │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐         │
│  │   etcd1     │    │   etcd2     │    │   etcd3     │         │
│  │  (2379)     │    │  (2379)     │    │  (2379)     │         │
│  └─────────────┘    └─────────────┘    └─────────────┘         │
│           │                 │                 │                  │
│           └─────────────────┼─────────────────┘                  │
│                            │                                     │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐         │
│  │ postgres1   │    │ postgres2   │    │ postgres3   │         │
│  │ (15432)     │◄──►│ (15433)     │◄──►│ (15434)     │         │
│  │ replica     │    │  leader     │    │ replica     │         │
│  └─────────────┘    └─────────────┘    └─────────────┘         │
│           │                 │                 │                  │
│           └─────────────────┼─────────────────┘                  │
│                            │                                     │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │                   HAProxy 负载均衡器                          ││
│  │  15000 (主库) │ 15001 (副本) │ 15002 (所有) │ 17000 (统计)   ││
│  └─────────────────────────────────────────────────────────────┘│
│                            │                                     │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐         │
│  │ 数据写入器   │    │ 监控仪表板   │    │ 故障注入器   │         │
│  │(持续写入)   │    │(实时监控)   │    │(混沌测试)   │         │
│  └─────────────┘    └─────────────┘    └─────────────┘         │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## 📦 组件说明

### 🗄️ 数据库集群
- **etcd集群**: 3节点分布式协调服务 (端口 2379)
- **PostgreSQL集群**: 3节点Patroni管理的PostgreSQL (端口 15432-15434)
- **HAProxy**: 负载均衡和连接池 (端口 15000-15002, 17000)

### 🔧 测试工具
- **数据写入器** (`data_writer.py`): 持续写入测试数据
- **监控仪表板** (`monitor_dashboard.py`): 实时集群状态监控
- **故障注入器** (`chaos-scripts/`): 混沌工程故障模拟
- **一致性验证** (`verify_consistency.sh`): 数据一致性检查

### 📋 管理脚本
- **test_runner.sh**: 主启动脚本
- **comprehensive_test.sh**: 综合故障测试
- **manage.sh**: 集群管理工具

## 🚀 快速开始

### 1. 启动完整测试环境

```bash
# 启动集群 + 数据写入器
./test_runner.sh start

# 查看状态
./test_runner.sh status
```

### 2. 启动监控仪表板

```bash
# 启动交互式监控 (按 'q' 退出)
./test_runner.sh monitor
```

### 3. 开始故障测试

```bash
# 运行5分钟故障测试 (默认)
./test_runner.sh chaos

# 自定义测试时长 (10分钟, 30秒间隔)
TEST_DURATION=600 CHAOS_INTERVAL=30 ./test_runner.sh chaos
```

### 4. 验证数据一致性

```bash
# 数据一致性验证
./verify_consistency.sh

# 生成数据质量报告
./verify_consistency.sh report
```

## 📊 性能基准

正常情况下的预期性能:
- **写入速率**: 50-200 TPS (取决于硬件)
- **故障转移时间**: 10-30秒
- **数据同步延迟**: < 1秒
- **故障恢复时间**: 30-60秒

## 🌪️ 故障模拟类型

1. **节点故障**: 停止/重启PostgreSQL节点
2. **网络故障**: 网络分区、延迟、中断
3. **资源压力**: CPU、内存、磁盘IO压力测试
4. **服务故障**: etcd节点故障、HAProxy故障

## 🎯 测试目标验证

✅ 主节点故障时自动故障转移  
✅ 副本节点故障时服务不中断  
✅ 网络分区恢复后数据同步  
✅ 故障期间零数据丢失  
✅ 恢复后各节点数据一致  
✅ 序列号连续性保证

## 🔧 详细使用指南

查看完整文档获取详细的使用说明、配置选项和故障排除指南。

## 🤝 贡献

欢迎提交 Issue 和 Pull Request 来改进这个测试系统!
```bash
# 通过 Patroni REST API
curl http://localhost:8008/cluster

# 或通过 patronictl (如果安装了)
patronictl -c /path/to/patroni.yml list
```

### 手动故障转移
```bash
curl -s http://localhost:8008/failover -XPOST -d '{"leader":"patroni1","candidate":"patroni2"}'
```

### 停止集群
```bash
docker-compose down
```

### 完全清理 (包括数据)
```bash
docker-compose down -v
```

## 配置文件说明

- `docker-compose.yml`: Docker Compose 配置
- `haproxy.cfg`: HAProxy 负载均衡配置
- `patroni.yml`: Patroni 配置模板
- `entrypoint.sh`: 容器启动脚本

## 监控和日志

### 查看服务日志
```bash
# 查看所有服务日志
docker-compose logs -f

# 查看特定服务日志
docker-compose logs -f patroni1
docker-compose logs -f haproxy
```

### 健康检查
```bash
# 检查主库
curl http://localhost:8008/primary

# 检查副本
curl http://localhost:8008/replica

# 检查集群
curl http://localhost:8008/cluster
```

## 故障排除

### 常见问题

1. **etcd 连接失败**: 确保 etcd 集群完全启动
2. **PostgreSQL 启动失败**: 检查数据目录权限
3. **HAProxy 连接失败**: 确认 Patroni 节点健康状态

### 重新初始化集群
```bash
docker-compose down -v
docker-compose up -d
```

## 生产环境注意事项

1. 修改默认密码
2. 配置适当的资源限制
3. 设置数据持久化存储
4. 配置网络安全策略
5. 设置监控和告警
