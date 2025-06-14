#!/usr/bin/env python3
"""
PostgreSQL 持续数据写入器
用于测试Patroni集群在故障期间的数据一致性和同步能力
"""

import os
import sys
import time
import json
import random
import psycopg2
import logging
import threading
from datetime import datetime, timedelta
from psycopg2.extras import RealDictCursor
import signal

# 配置日志
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler('/tmp/data_writer.log')
    ]
)
logger = logging.getLogger(__name__)

class DataWriter:
    def __init__(self):
        self.running = True
        self.connections = {
            'primary': {
                'host': 'localhost',
                'port': 15000,  # HAProxy primary
                'database': 'postgres',
                'user': 'postgres',
                'password': 'postgres123'
            },
            'replica': {
                'host': 'localhost', 
                'port': 15001,  # HAProxy replica
                'database': 'postgres',
                'user': 'postgres',
                'password': 'postgres123'
            },
            'direct1': {
                'host': 'localhost',
                'port': 15432,  # Direct postgres1
                'database': 'postgres',
                'user': 'postgres',
                'password': 'postgres123'
            },
            'direct2': {
                'host': 'localhost',
                'port': 15433,  # Direct postgres2
                'database': 'postgres',
                'user': 'postgres',
                'password': 'postgres123'
            },
            'direct3': {
                'host': 'localhost',
                'port': 15434,  # Direct postgres3
                'database': 'postgres',
                'user': 'postgres',
                'password': 'postgres123'
            }
        }
        self.write_count = 0
        self.error_count = 0
        self.start_time = datetime.now()
        
    def get_connection(self, conn_name, autocommit=True):
        """获取数据库连接"""
        try:
            conn = psycopg2.connect(**self.connections[conn_name])
            if autocommit:
                conn.autocommit = True
            return conn
        except Exception as e:
            logger.error(f"连接 {conn_name} 失败: {e}")
            return None
            
    def init_tables(self):
        """初始化测试表"""
        logger.info("初始化测试表...")
        
        # 等待数据库就绪
        max_retries = 30
        for i in range(max_retries):
            conn = self.get_connection('primary')
            if conn:
                break
            logger.info(f"等待数据库就绪... ({i+1}/{max_retries})")
            time.sleep(5)
        
        if not conn:
            logger.error("无法连接到数据库")
            return False
            
        try:
            with conn.cursor() as cur:
                # 创建测试表
                cur.execute("""
                    CREATE TABLE IF NOT EXISTS test_transactions (
                        id SERIAL PRIMARY KEY,
                        transaction_id UUID DEFAULT gen_random_uuid(),
                        timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                        node_name VARCHAR(50),
                        data JSONB,
                        sequence_num INTEGER,
                        checksum VARCHAR(64)
                    )
                """)
                
                # 创建索引
                cur.execute("""
                    CREATE INDEX IF NOT EXISTS idx_test_transactions_timestamp 
                    ON test_transactions(timestamp)
                """)
                
                cur.execute("""
                    CREATE INDEX IF NOT EXISTS idx_test_transactions_sequence 
                    ON test_transactions(sequence_num)
                """)
                
                # 创建同步状态表
                cur.execute("""
                    CREATE TABLE IF NOT EXISTS sync_status (
                        node_name VARCHAR(50) PRIMARY KEY,
                        last_sequence INTEGER DEFAULT 0,
                        last_update TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                        is_primary BOOLEAN DEFAULT FALSE
                    )
                """)
                
                # 创建故障日志表
                cur.execute("""
                    CREATE TABLE IF NOT EXISTS failure_log (
                        id SERIAL PRIMARY KEY,
                        timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                        event_type VARCHAR(50),
                        node_name VARCHAR(50),
                        description TEXT,
                        metadata JSONB
                    )
                """)
                
                logger.info("测试表初始化完成")
                return True
                
        except Exception as e:
            logger.error(f"初始化表失败: {e}")
            return False
        finally:
            conn.close()
            
    def get_current_primary(self):
        """获取当前主节点信息"""
        for node_name, conn_info in [
            ('postgres1', self.connections['direct1']),
            ('postgres2', self.connections['direct2']), 
            ('postgres3', self.connections['direct3'])
        ]:
            try:
                conn = psycopg2.connect(**conn_info)
                conn.autocommit = True
                with conn.cursor() as cur:
                    cur.execute("SELECT pg_is_in_recovery()")
                    is_replica = cur.fetchone()[0]
                    if not is_replica:
                        conn.close()
                        return node_name
                conn.close()
            except:
                continue
        return "unknown"
        
    def write_transaction(self):
        """写入一笔事务"""
        try:
            conn = self.get_connection('primary')
            if not conn:
                self.error_count += 1
                return False
                
            current_primary = self.get_current_primary()
            sequence_num = self.write_count + 1
            
            # 生成测试数据
            test_data = {
                'operation': random.choice(['insert', 'update', 'delete', 'select']),
                'amount': round(random.uniform(1.0, 10000.0), 2),
                'account_id': random.randint(1000, 9999),
                'metadata': {
                    'client_ip': f"192.168.1.{random.randint(1, 254)}",
                    'user_agent': random.choice(['web', 'mobile', 'api']),
                    'session_id': f"sess_{random.randint(100000, 999999)}"
                }
            }
            
            # 计算校验和
            import hashlib
            checksum = hashlib.sha256(json.dumps(test_data, sort_keys=True).encode()).hexdigest()
            
            with conn.cursor() as cur:
                cur.execute("""
                    INSERT INTO test_transactions 
                    (node_name, data, sequence_num, checksum)
                    VALUES (%s, %s, %s, %s)
                    RETURNING id, transaction_id, timestamp
                """, (current_primary, json.dumps(test_data), sequence_num, checksum))
                
                result = cur.fetchone()
                
                # 更新同步状态
                cur.execute("""
                    INSERT INTO sync_status (node_name, last_sequence, is_primary)
                    VALUES (%s, %s, TRUE)
                    ON CONFLICT (node_name) DO UPDATE SET
                        last_sequence = EXCLUDED.last_sequence,
                        last_update = CURRENT_TIMESTAMP,
                        is_primary = EXCLUDED.is_primary
                """, (current_primary, sequence_num))
                
            self.write_count += 1
            
            if self.write_count % 100 == 0:
                logger.info(f"已写入 {self.write_count} 笔事务, 当前主节点: {current_primary}")
                
            conn.close()
            return True
            
        except Exception as e:
            self.error_count += 1
            logger.error(f"写入事务失败: {e}")
            return False
            
    def verify_data_consistency(self):
        """验证数据一致性"""
        logger.info("开始验证数据一致性...")
        
        # 从所有节点读取数据
        node_data = {}
        
        for node_name, conn_key in [
            ('postgres1', 'direct1'),
            ('postgres2', 'direct2'),
            ('postgres3', 'direct3')
        ]:
            try:
                conn = self.get_connection(conn_key)
                if not conn:
                    continue
                    
                with conn.cursor(cursor_factory=RealDictCursor) as cur:
                    # 检查表是否存在
                    cur.execute("""
                        SELECT EXISTS (
                            SELECT FROM information_schema.tables 
                            WHERE table_name = 'test_transactions'
                        )
                    """)
                    
                    if not cur.fetchone()[0]:
                        logger.warning(f"{node_name}: test_transactions表不存在")
                        continue
                        
                    # 获取统计信息
                    cur.execute("""
                        SELECT 
                            COUNT(*) as total_records,
                            MAX(sequence_num) as max_sequence,
                            MIN(sequence_num) as min_sequence,
                            COUNT(DISTINCT checksum) as unique_checksums
                        FROM test_transactions
                    """)
                    
                    stats = cur.fetchone()
                    
                    # 获取最近的记录
                    cur.execute("""
                        SELECT sequence_num, checksum, timestamp
                        FROM test_transactions 
                        ORDER BY sequence_num DESC 
                        LIMIT 10
                    """)
                    
                    recent_records = cur.fetchall()
                    
                    node_data[node_name] = {
                        'stats': dict(stats),
                        'recent_records': [dict(r) for r in recent_records],
                        'accessible': True
                    }
                    
                conn.close()
                
            except Exception as e:
                logger.error(f"从 {node_name} 读取数据失败: {e}")
                node_data[node_name] = {'accessible': False, 'error': str(e)}
                
        # 分析一致性
        logger.info("=== 数据一致性报告 ===")
        
        accessible_nodes = [name for name, data in node_data.items() if data.get('accessible')]
        
        if not accessible_nodes:
            logger.error("所有节点都不可访问!")
            return False
            
        # 比较统计信息
        reference_stats = node_data[accessible_nodes[0]]['stats']
        consistent = True
        
        for node_name in accessible_nodes:
            stats = node_data[node_name]['stats']
            logger.info(f"{node_name}: {stats['total_records']} 条记录, "
                       f"序列号范围: {stats['min_sequence']}-{stats['max_sequence']}")
            
            if stats != reference_stats:
                consistent = False
                logger.warning(f"{node_name} 数据不一致!")
                
        if consistent and len(accessible_nodes) > 1:
            logger.info("✅ 所有可访问节点数据一致")
        elif len(accessible_nodes) == 1:
            logger.info(f"⚠️ 只有 {accessible_nodes[0]} 可访问")
        else:
            logger.error("❌ 数据不一致")
            
        return consistent
        
    def log_failure_event(self, event_type, node_name, description, metadata=None):
        """记录故障事件"""
        try:
            conn = self.get_connection('primary')
            if not conn:
                return
                
            with conn.cursor() as cur:
                cur.execute("""
                    INSERT INTO failure_log (event_type, node_name, description, metadata)
                    VALUES (%s, %s, %s, %s)
                """, (event_type, node_name, description, json.dumps(metadata or {})))
                
            conn.close()
            logger.info(f"记录故障事件: {event_type} - {node_name} - {description}")
            
        except Exception as e:
            logger.error(f"记录故障事件失败: {e}")
            
    def monitor_cluster_status(self):
        """监控集群状态"""
        logger.info("开始监控集群状态...")
        
        last_primary = None
        
        while self.running:
            try:
                current_primary = self.get_current_primary()
                
                if current_primary != last_primary:
                    if last_primary:
                        self.log_failure_event(
                            'failover', 
                            current_primary,
                            f"主节点从 {last_primary} 切换到 {current_primary}",
                            {'old_primary': last_primary, 'new_primary': current_primary}
                        )
                        logger.info(f"🔄 主节点切换: {last_primary} -> {current_primary}")
                    else:
                        logger.info(f"📍 当前主节点: {current_primary}")
                        
                    last_primary = current_primary
                    
                time.sleep(10)
                
            except Exception as e:
                logger.error(f"监控集群状态失败: {e}")
                time.sleep(5)
                
    def run_continuous_writes(self):
        """持续写入数据"""
        logger.info("开始持续写入数据...")
        
        while self.running:
            try:
                success = self.write_transaction()
                
                if success:
                    time.sleep(random.uniform(0.1, 1.0))  # 随机间隔
                else:
                    time.sleep(2.0)  # 错误后等待longer
                    
                # 每1000笔事务验证一次数据一致性
                if self.write_count % 1000 == 0 and self.write_count > 0:
                    self.verify_data_consistency()
                    
            except KeyboardInterrupt:
                logger.info("收到中断信号，正在停止...")
                self.running = False
                break
            except Exception as e:
                logger.error(f"写入循环异常: {e}")
                time.sleep(5)
                
    def signal_handler(self, signum, frame):
        """信号处理器"""
        logger.info(f"收到信号 {signum}，正在停止...")
        self.running = False
        
    def print_statistics(self):
        """打印统计信息"""
        while self.running:
            time.sleep(30)
            
            duration = datetime.now() - self.start_time
            rate = self.write_count / max(duration.total_seconds(), 1)
            
            logger.info(f"📊 统计信息:")
            logger.info(f"   运行时间: {duration}")
            logger.info(f"   写入事务: {self.write_count}")
            logger.info(f"   错误次数: {self.error_count}")
            logger.info(f"   写入速率: {rate:.2f} 事务/秒")
            logger.info(f"   成功率: {((self.write_count/(self.write_count+self.error_count))*100 if (self.write_count+self.error_count) > 0 else 0):.2f}%")
            
    def run(self):
        """主运行方法"""
        # 注册信号处理器
        signal.signal(signal.SIGINT, self.signal_handler)
        signal.signal(signal.SIGTERM, self.signal_handler)
        
        logger.info("🚀 启动PostgreSQL数据写入器...")
        
        # 初始化表
        if not self.init_tables():
            logger.error("初始化失败，退出")
            return 1
            
        # 启动监控线程
        monitor_thread = threading.Thread(target=self.monitor_cluster_status)
        monitor_thread.daemon = True
        monitor_thread.start()
        
        # 启动统计线程
        stats_thread = threading.Thread(target=self.print_statistics)
        stats_thread.daemon = True
        stats_thread.start()
        
        # 运行主写入循环
        try:
            self.run_continuous_writes()
        except Exception as e:
            logger.error(f"主循环异常: {e}")
            return 1
        finally:
            logger.info("🏁 数据写入器已停止")
            # 最终数据一致性检查
            self.verify_data_consistency()
            
        return 0

if __name__ == "__main__":
    writer = DataWriter()
    exit_code = writer.run()
    sys.exit(exit_code)
