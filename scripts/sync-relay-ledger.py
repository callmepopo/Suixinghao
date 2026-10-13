#!/usr/bin/env python3
"""Merge a PRIVATE relay-export JSON into an existing local testing Markdown.
No network, email, plaintext key export, automatic recipient matching or uploads.
"""
import argparse
import html
import json
import os
import re
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--ledger', type=Path, required=True)
parser.add_argument('--material', type=Path, required=True)
args = parser.parse_args()
ledger = json.loads(args.ledger.read_text())
if ledger.get('schema_version') != 1:
    raise SystemExit('Unsupported ledger schema')
rows = ledger.get('grants', [])
if len(rows) > 1000 or len({r['id'] for r in rows}) != len(rows):
    raise SystemExit('Invalid grant records')
if re.search(r'sxr_[0-9a-fA-F]{64}', args.ledger.read_text()):
    raise SystemExit('Refusing plaintext credential export')
material = args.material.read_text()
if args.material.stat().st_mode & 0o077:
    raise SystemExit('Material must already be private (0600)')
def cell(value):
    return html.escape(str(value or '待登记'), quote=False).replace('|', '／').replace('\n', ' ').replace('\r', ' ').replace('`', '').replace('[', r'\[').replace(']', r'\]')
def date(value):
    return '历史时间未留存' if not value or value.startswith('0001-') else value
start = '<!-- relay-ledger:start -->'
end = '<!-- relay-ledger:end -->'
lines = [start, '## 中继签发台账（管理导出）', '',
         f"更新时间：{cell(ledger.get('generated_at'))}。昵称为登记标识，不等于已验证真实身份；未自动关联 TestFlight 邮箱。", '',
         '| 授权 ID | 登记接收人 | NAS 实例 | 环境 | 签发时间 | 方式 | 当前状态 | 到期／撤销 | 生命周期 |',
         '| --- | --- | --- | --- | --- | --- | --- | --- | --- |']
for r in rows:
    if not re.fullmatch(r'[0-9a-f]{16}', r['id']):
        raise SystemExit('Invalid authorization ID')
    history = '；'.join(f"{date(x.get('at'))} {cell(x.get('action'))}" for x in (r.get('history') or []))
    values = [r['id'], r.get('name'), r.get('instance_id'), r.get('environment'), date(r.get('created_at')),
              r.get('method'), r.get('status'), date(r.get('revoked_at') if r.get('status') == 'revoked' else r.get('expires_at')), history or '历史事件未留存']
    lines.append('| ' + ' | '.join(cell(x) for x in values) + ' |')
lines += ['', '汇总：' + '；'.join(f'{cell(k)}={int(v)}' for k,v in ledger.get('counts', {}).items()), '',
          '手工接收人及备注保留在原分发表；本导出中的预备名称不能推定为实际接收人。有效授权不代表真机推送验收。', end]
block = '\n'.join(lines)
if start in material:
    if material.count(start) != 1 or material.count(end) != 1:
        raise SystemExit('Ambiguous generated section')
    a = material.index(start); b = material.index(end, a) + len(end)
    material = material[:a] + block + material[b:]
else:
    material = material.rstrip() + '\n\n' + block + '\n'
# Keep manually maintained sections and existing secret table untouched.
tmp = args.material.with_suffix(args.material.suffix + '.sync-tmp')
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
try:
    with os.fdopen(fd, 'w') as f:
        f.write(material); f.flush(); os.fsync(f.fileno())
    os.replace(tmp, args.material)
finally:
    if tmp.exists(): tmp.unlink()
print(f'Private ledger synchronized: {len(rows)} records; manual sections preserved.')
