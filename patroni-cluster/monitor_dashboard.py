#!/usr/bin/env python3
"""
Patroni集群实时监控仪表板
显示集群状态、数据写入统计、故障事件等
"""

import os
import sys
import time
import json
import curses
import psycopg2
import requests
import threading
from datetime import datetime, timedelta
from psycopg2.extras import RealDictCursor

class PatroniMonitor:
    def __init__(self):
        self.connections = {
            'primary': {
                'host': 'localhost',
                'port': 15000,
                'database': 'postgres',
                'user': 'postgres',
                'password': 'postgres123'
            },
            'direct1': {
                'host': 'localhost',
                'port': 15432,
                'database': 'postgres',
                'user': 'postgres',
                'password': 'postgres123'
            },
            'direct2': {
                'host': 'localhost',
                'port': 15433,
                'database': 'postgres',
                'user': 'postgres',
                'password': 'postgres123'
            },
            'direct3': {
                'host': 'localhost',
                'port': 15434,
                'database': 'postgres',
                'user': 'postgres',
                'password': 'postgres123'
            }
        }
        
        self.patroni_apis = [
            ('postgres1', 'http://localhost:8008'),
            ('postgres2', 'http://localhost:8009'),
            ('postgres3', 'http://localhost:8010')
        ]
        
        self.cluster_status = {}
        self.data_stats = {}
        self.failure_events = []
        self.running = True
        
    def get_connection(self, conn_name):
        """获取数据库连接"""
        try:
            conn = psycopg2.connect(**self.connections[conn_name])
            conn.autocommit = True
            return conn
        except Exception:
            return None
            
    def get_cluster_status(self):
        """获取集群状态"""
        status = {}
        
        for node_name, api_url in self.patroni_apis:
            try:
                # 获取节点状态
                response = requests.get(f"{api_url}/patroni", timeout=2)
                if response.status_code == 200:
                    node_info = response.json()
                    status[node_name] = {
                        'role': node_info.get('role', 'unknown'),
                        'state': node_info.get('state', 'unknown'),
                        'timeline': node_info.get('timeline', 'unknown'),
                        'lag': node_info.get('xlog', {}).get('received_location', 'unknown'),
                        'api_accessible': True,
                        'last_update': datetime.now()
                    }
                else:
                    status[node_name] = {
                        'role': 'unknown',
                        'state': 'unreachable',
                        'api_accessible': False,
                        'last_update': datetime.now()
                    }
                    
            except Exception as e:
                status[node_name] = {
                    'role': 'unknown',
                    'state': 'error',
                    'api_accessible': False,
                    'error': str(e),
                    'last_update': datetime.now()
                }
                
        return status
        
    def get_data_statistics(self):
        """获取数据统计"""
        stats = {}
        
        # 尝试从主库获取统计信息
        conn = self.get_connection('primary')
        if conn:
            try:
                with conn.cursor(cursor_factory=RealDictCursor) as cur:
                    # 检查表是否存在
                    cur.execute("""
                        SELECT EXISTS (
                            SELECT FROM information_schema.tables 
                            WHERE table_name = 'test_transactions'
                        )
                    """)
                    
                    if cur.fetchone()[0]:
                        # 总体统计
                        cur.execute("""
                            SELECT 
                                COUNT(*) as total_records,
                                MAX(sequence_num) as max_sequence,
                                MIN(sequence_num) as min_sequence,
                                COUNT(DISTINCT node_name) as node_count,
                                MAX(timestamp) as last_transaction_time
                            FROM test_transactions
                        """)
                        
                        total_stats = cur.fetchone()
                        
                        # 最近1分钟的统计
                        cur.execute("""
                            SELECT COUNT(*) as recent_count
                            FROM test_transactions 
                            WHERE timestamp > NOW() - INTERVAL '1 minute'
                        """)
                        
                        recent_stats = cur.fetchone()
                        
                        # 按节点统计
                        cur.execute("""
                            SELECT 
                                node_name,
                                COUNT(*) as count,
                                MAX(sequence_num) as max_seq,
                                MAX(timestamp) as last_write
                            FROM test_transactions 
                            GROUP BY node_name
                            ORDER BY node_name
                        """)
                        
                        node_stats = cur.fetchall()
                        
                        # 最近的故障事件
                        cur.execute("""
                            SELECT 
                                timestamp,
                                event_type,
                                node_name,
                                description
                            FROM failure_log 
                            ORDER BY timestamp DESC 
                            LIMIT 10
                        """)
                        
                        failure_events = cur.fetchall()
                        
                        stats = {
                            'total_records': total_stats['total_records'],
                            'max_sequence': total_stats['max_sequence'],
                            'min_sequence': total_stats['min_sequence'],
                            'node_count': total_stats['node_count'],
                            'last_transaction_time': total_stats['last_transaction_time'],
                            'recent_count': recent_stats['recent_count'],
                            'node_stats': [dict(row) for row in node_stats],
                            'failure_events': [dict(row) for row in failure_events],
                            'accessible': True
                        }
                        
                conn.close()
                
            except Exception as e:
                stats = {'accessible': False, 'error': str(e)}
                if conn:
                    conn.close()
        else:
            stats = {'accessible': False, 'error': 'Cannot connect to primary'}
            
        return stats
        
    def check_node_connectivity(self):
        """检查节点连接性"""
        connectivity = {}
        
        for node_name, conn_info in [
            ('postgres1', self.connections['direct1']),
            ('postgres2', self.connections['direct2']),
            ('postgres3', self.connections['direct3'])
        ]:
            try:
                conn = psycopg2.connect(**conn_info)
                conn.close()
                connectivity[node_name] = True
            except Exception:
                connectivity[node_name] = False
                
        return connectivity
        
    def update_data(self):
        """更新监控数据"""
        while self.running:
            try:
                self.cluster_status = self.get_cluster_status()
                self.data_stats = self.get_data_statistics()
                time.sleep(2)  # 每2秒更新一次
            except Exception as e:
                pass  # 忽略更新错误，继续运行
                
    def draw_header(self, stdscr, y_pos):
        """绘制标题"""
        title = "🔍 Patroni 集群实时监控仪表板"
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        
        stdscr.addstr(y_pos, 0, title, curses.A_BOLD | curses.color_pair(1))
        stdscr.addstr(y_pos, len(title) + 5, f"更新时间: {timestamp}")
        
        return y_pos + 2
        
    def draw_cluster_status(self, stdscr, y_pos):
        """绘制集群状态"""
        stdscr.addstr(y_pos, 0, "📊 集群状态", curses.A_BOLD | curses.color_pair(2))
        y_pos += 1
        
        if not self.cluster_status:
            stdscr.addstr(y_pos, 2, "正在获取集群状态...")
            return y_pos + 2
            
        # 绘制表头
        header = f"{'节点':^12} {'角色':^10} {'状态':^12} {'时间线':^8} {'API':^8}"
        stdscr.addstr(y_pos, 2, header, curses.A_UNDERLINE)
        y_pos += 1
        
        for node_name, status in self.cluster_status.items():
            role = status.get('role', 'unknown')
            state = status.get('state', 'unknown')
            timeline = str(status.get('timeline', 'N/A'))
            api_status = "✅" if status.get('api_accessible', False) else "❌"
            
            # 根据角色设置颜色
            if role == 'leader':
                color = curses.color_pair(3)  # 绿色
            elif role == 'replica':
                color = curses.color_pair(4)  # 蓝色
            else:
                color = curses.color_pair(5)  # 红色
                
            line = f"{node_name:^12} {role:^10} {state:^12} {timeline:^8} {api_status:^8}"
            stdscr.addstr(y_pos, 2, line, color)
            y_pos += 1
            
        return y_pos + 1
        
    def draw_data_statistics(self, stdscr, y_pos):
        """绘制数据统计"""
        stdscr.addstr(y_pos, 0, "📈 数据统计", curses.A_BOLD | curses.color_pair(2))
        y_pos += 1
        
        if not self.data_stats.get('accessible', False):
            error_msg = self.data_stats.get('error', '数据不可访问')
            stdscr.addstr(y_pos, 2, f"❌ {error_msg}", curses.color_pair(5))
            return y_pos + 2
            
        # 总体统计
        total_records = self.data_stats.get('total_records', 0)
        max_sequence = self.data_stats.get('max_sequence', 0)
        recent_count = self.data_stats.get('recent_count', 0)
        last_transaction = self.data_stats.get('last_transaction_time')
        
        stdscr.addstr(y_pos, 2, f"总记录数: {total_records:,}")
        stdscr.addstr(y_pos, 25, f"最大序列号: {max_sequence:,}")
        y_pos += 1
        
        stdscr.addstr(y_pos, 2, f"最近1分钟: {recent_count} 条")
        
        if last_transaction:
            time_diff = datetime.now() - last_transaction.replace(tzinfo=None)
            stdscr.addstr(y_pos, 25, f"最后写入: {time_diff.total_seconds():.0f}秒前")
        y_pos += 1
        
        # 计算写入速率
        if recent_count > 0:
            rate = recent_count / 60.0  # 每秒事务数
            stdscr.addstr(y_pos, 2, f"写入速率: {rate:.2f} TPS", curses.color_pair(3))
        else:
            stdscr.addstr(y_pos, 2, "写入速率: 0.00 TPS", curses.color_pair(5))
        y_pos += 1
        
        # 按节点统计
        node_stats = self.data_stats.get('node_stats', [])
        if node_stats:
            y_pos += 1
            stdscr.addstr(y_pos, 2, "按节点统计:", curses.A_UNDERLINE)
            y_pos += 1
            
            for node_stat in node_stats:
                node_name = node_stat['node_name']
                count = node_stat['count']
                max_seq = node_stat['max_seq']
                last_write = node_stat['last_write']
                
                if last_write:
                    time_diff = datetime.now() - last_write.replace(tzinfo=None)
                    time_str = f"{time_diff.total_seconds():.0f}s前"
                else:
                    time_str = "未知"
                    
                line = f"  {node_name}: {count:,} 条 (序列: {max_seq}, 最后: {time_str})"
                stdscr.addstr(y_pos, 2, line)
                y_pos += 1
                
        return y_pos + 1
        
    def draw_failure_events(self, stdscr, y_pos, max_lines=8):
        """绘制故障事件"""
        stdscr.addstr(y_pos, 0, "⚠️ 最近故障事件", curses.A_BOLD | curses.color_pair(2))
        y_pos += 1
        
        failure_events = self.data_stats.get('failure_events', [])
        
        if not failure_events:
            stdscr.addstr(y_pos, 2, "暂无故障事件")
            return y_pos + 2
            
        # 绘制表头
        header = f"{'时间':^20} {'类型':^12} {'节点':^12} {'描述'}"
        stdscr.addstr(y_pos, 2, header, curses.A_UNDERLINE)
        y_pos += 1
        
        for i, event in enumerate(failure_events[:max_lines]):
            timestamp = event['timestamp'].strftime("%m-%d %H:%M:%S")
            event_type = event['event_type']
            node_name = event['node_name'] or 'N/A'
            description = event['description'][:40] + "..." if len(event['description']) > 40 else event['description']
            
            line = f"{timestamp:^20} {event_type:^12} {node_name:^12} {description}"
            
            # 根据事件类型设置颜色
            if event_type == 'failover':
                color = curses.color_pair(6)  # 黄色
            else:
                color = curses.color_pair(5)  # 红色
                
            stdscr.addstr(y_pos, 2, line, color)
            y_pos += 1
            
        return y_pos + 1
        
    def draw_help(self, stdscr, y_pos):
        """绘制帮助信息"""
        help_text = [
            "快捷键:",
            "  q - 退出",
            "  r - 刷新",
            "  c - 清屏",
            "",
            "颜色说明:",
            "  绿色 - 主节点/正常",
            "  蓝色 - 副本节点",
            "  红色 - 错误/不可访问",
            "  黄色 - 故障转移事件"
        ]
        
        for i, line in enumerate(help_text):
            if i == 0:
                stdscr.addstr(y_pos + i, 0, line, curses.A_BOLD | curses.color_pair(2))
            else:
                stdscr.addstr(y_pos + i, 0, line)
                
        return y_pos + len(help_text) + 1
        
    def run_dashboard(self, stdscr):
        """运行仪表板"""
        # 初始化颜色
        curses.start_color()
        curses.init_pair(1, curses.COLOR_WHITE, curses.COLOR_BLUE)   # 标题
        curses.init_pair(2, curses.COLOR_CYAN, curses.COLOR_BLACK)   # 章节标题
        curses.init_pair(3, curses.COLOR_GREEN, curses.COLOR_BLACK)  # 正常/主节点
        curses.init_pair(4, curses.COLOR_BLUE, curses.COLOR_BLACK)   # 副本节点
        curses.init_pair(5, curses.COLOR_RED, curses.COLOR_BLACK)    # 错误
        curses.init_pair(6, curses.COLOR_YELLOW, curses.COLOR_BLACK) # 警告
        
        # 设置curses
        curses.curs_set(0)  # 隐藏光标
        stdscr.nodelay(1)   # 非阻塞输入
        stdscr.timeout(100) # 100ms超时
        
        # 启动数据更新线程
        update_thread = threading.Thread(target=self.update_data)
        update_thread.daemon = True
        update_thread.start()
        
        while self.running:
            try:
                # 清屏
                stdscr.clear()
                
                # 获取屏幕尺寸
                height, width = stdscr.getmaxyx()
                
                y_pos = 0
                
                # 绘制各个部分
                y_pos = self.draw_header(stdscr, y_pos)
                y_pos = self.draw_cluster_status(stdscr, y_pos)
                y_pos = self.draw_data_statistics(stdscr, y_pos)
                y_pos = self.draw_failure_events(stdscr, y_pos)
                
                # 如果屏幕足够大，显示帮助信息
                if height - y_pos > 12:
                    self.draw_help(stdscr, y_pos)
                
                # 刷新屏幕
                stdscr.refresh()
                
                # 处理用户输入
                key = stdscr.getch()
                if key == ord('q') or key == ord('Q'):
                    self.running = False
                    break
                elif key == ord('r') or key == ord('R'):
                    # 强制刷新数据
                    self.cluster_status = self.get_cluster_status()
                    self.data_stats = self.get_data_statistics()
                elif key == ord('c') or key == ord('C'):
                    stdscr.clear()
                    
                time.sleep(0.1)
                
            except KeyboardInterrupt:
                self.running = False
                break
            except Exception as e:
                # 在出错时显示错误信息
                stdscr.addstr(0, 0, f"错误: {str(e)}", curses.color_pair(5))
                stdscr.refresh()
                time.sleep(1)
                
    def run(self):
        """运行监控器"""
        try:
            curses.wrapper(self.run_dashboard)
        except Exception as e:
            print(f"监控器启动失败: {e}")
            return 1
        return 0

if __name__ == "__main__":
    print("启动Patroni集群监控仪表板...")
    print("按 'q' 退出, 'r' 刷新, 'c' 清屏")
    print()
    
    monitor = PatroniMonitor()
    exit_code = monitor.run()
    sys.exit(exit_code)
