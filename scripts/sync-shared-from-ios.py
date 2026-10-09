#!/usr/bin/env python3
"""Synchronize reviewed common Apple files from a local iOS checkout."""
import argparse, hashlib, json
from pathlib import Path
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source',type=Path,required=True)
parser.add_argument('--check',action='store_true')
args=parser.parse_args()
root=Path(__file__).resolve().parents[1]
manifest=root/'Shared/upstream.json'
data=json.loads(manifest.read_text())
planned=[]
for item in data['files']:
    origin=(args.source/item['source']).resolve()
    target=(root/item['destination']).resolve()
    if not origin.is_relative_to(args.source.resolve()) or not target.is_relative_to(root/'Shared'):
        raise SystemExit('Invalid source or destination path')
    if not origin.is_file() or not target.is_file() or origin.is_symlink() or target.is_symlink():
        raise SystemExit('Missing or unsafe shared file: '+item['destination'])
    old=target.read_bytes(); new=origin.read_bytes()
    if old!=new:
        if hashlib.sha256(old).hexdigest()!=item['sha256']:
            raise SystemExit('Preserve local changes and merge manually: '+item['destination'])
        planned.append((item,target,new))
if args.check:
    if planned:
        print('Shared files differ: '+', '.join(item['destination'] for item,_,_ in planned))
        raise SystemExit(1)
    print('Shared Apple source matches the iOS checkout')
else:
    for item,target,new in planned:
        target.write_bytes(new)
        item['sha256']=hashlib.sha256(new).hexdigest()
    manifest.write_text(json.dumps(data,indent=2)+'\n')
    print('Updated shared files: '+str(len(planned)))
