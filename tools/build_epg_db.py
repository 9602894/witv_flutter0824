import json
import sqlite3
import os
import sys

def build(input_json: str, output_db: str):
    # 删除旧文件
    if os.path.exists(output_db):
        os.remove(output_db)
    
    conn = sqlite3.connect(output_db)
    c = conn.cursor()
    
    # 映射表：COLLATE NOCASE 解决大小写匹配问题
    c.execute('''
        CREATE TABLE epg_mappings (
            name TEXT PRIMARY KEY COLLATE NOCASE,
            epgid TEXT NOT NULL
        )
    ''')
    c.execute('CREATE INDEX idx_mappings_epgid ON epg_mappings(epgid)')
    
    # 节目表（空表占位，Flutter 运行时写入）
    c.execute('''
        CREATE TABLE epg_programs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            channel_name TEXT NOT NULL,
            title TEXT NOT NULL,
            start_time INTEGER NOT NULL,
            end_time INTEGER NOT NULL,
            desc TEXT,
            date TEXT NOT NULL
        )
    ''')
    c.execute('CREATE INDEX idx_programs_channel_time ON epg_programs(channel_name, start_time, end_time)')
    c.execute('CREATE INDEX idx_programs_date ON epg_programs(date)')
    
    # 图标表
    c.execute('''
        CREATE TABLE epg_icons (
            channel_name TEXT PRIMARY KEY,
            icon_url TEXT NOT NULL
        )
    ''')
    
    # 元数据表
    c.execute('''
        CREATE TABLE epg_meta (
            key TEXT PRIMARY KEY,
            value TEXT
        )
    ''')
    
    # 解析 JSON
    with open(input_json, 'r', encoding='utf-8') as f:
        data = json.load(f)
    
    mappings = []
    for item in data.get('epgs', []):
        epgid = item.get('epgid', '').strip()
        names = item.get('name', '')
        if not epgid or not names:
            continue
        for name in names.split(','):
            name = name.strip()
            if name:
                mappings.append((name, epgid))
    
    c.executemany('INSERT OR IGNORE INTO epg_mappings (name, epgid) VALUES (?, ?)', mappings)
    conn.commit()
    conn.close()
    print(f'✅ 预构建完成: {output_db}')
    print(f'   映射条目: {len(mappings)}')

if __name__ == '__main__':
    if len(sys.argv) < 3:
        print('用法: python build_epg_db.py <input.json> <output.db>')
        sys.exit(1)
    build(sys.argv[1], sys.argv[2])
