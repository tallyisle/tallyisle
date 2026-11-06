#!/usr/bin/env python3
"""SQLite online backup for development diagnostics; not .penny or app restore."""
import sys,sqlite3,pathlib,hashlib,json,contextlib
source=pathlib.Path(sys.argv[1]).resolve();target=pathlib.Path(sys.argv[2]).resolve()
if not source.is_file() or target.exists() or target == source:
 raise SystemExit('Source must exist; destination must be a new file.')
target.parent.mkdir(parents=True,exist_ok=True)
temporary=target.with_name(target.name+'.pending')
if temporary.exists(): raise SystemExit('Pending destination already exists; inspect it first.')
with contextlib.closing(sqlite3.connect(source.as_uri()+'?mode=ro',uri=True)) as src,contextlib.closing(sqlite3.connect(temporary)) as dst:
 src.backup(dst)
 assert dst.execute('PRAGMA integrity_check').fetchone()==('ok',)
 assert not dst.execute('PRAGMA foreign_key_check').fetchall()
digest=hashlib.sha256(temporary.read_bytes()).hexdigest()
temporary.rename(target)
print(json.dumps({'type':'native SQLite development backup, not original-format export','file':str(target),'sha256':digest}))
