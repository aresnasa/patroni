#!/bin/bash
set -e

# 安装 Patroni 相关依赖
apk add --no-cache \
    python3 \
    python3-dev \
    py3-pip \
    gcc \
    musl-dev \
    libffi-dev \
    openssl-dev \
    linux-headers \
    netcat-openbsd

# 安装 Patroni
pip3 install --break-system-packages patroni[etcd3] psycopg2-binary

# 创建必要的目录
mkdir -p /var/lib/postgresql/archive
mkdir -p /var/run/postgresql
mkdir -p /etc/patroni

# 设置权限
chown -R postgres:postgres /var/lib/postgresql
chown -R postgres:postgres /var/run/postgresql
chmod 700 /var/lib/postgresql/data || true

# 等待 etcd 集群服务可用
echo "等待 etcd 集群启动..."
until nc -z etcd1 2379 && nc -z etcd2 2379 && nc -z etcd3 2379; do
  echo "等待 etcd 集群..."
  sleep 2
done
echo "etcd 集群已就绪"

# 启动 Patroni
echo "启动 Patroni..."
exec su-exec postgres patroni /etc/patroni/patroni.yml
