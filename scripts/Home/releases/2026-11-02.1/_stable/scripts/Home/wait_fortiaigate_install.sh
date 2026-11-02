#!/usr/bin/env bash
# Generated approved GitHub launcher. Edit the maintained release builder.
set -euo pipefail
umask 077
command -v python3 >/dev/null || { printf 'Python 3 is required.\n' >&2; exit 1; }
forti_work=$(mktemp -d "${TMPDIR:-/tmp}/fortiaigate-release.XXXXXXXX")
trap 'rm -rf -- "$forti_work"' EXIT
forti_manifest=https://raw.githubusercontent.com/WEEMR/FortiAIGate/approved/scripts/Home/current.json
forti_base=https://raw.githubusercontent.com/WEEMR/FortiAIGate/shared-__VERSION__/scripts/Home/releases/__VERSION__
forti_filename=wait_fortiaigate_install.sh
forti_edition=home
forti_fetch() {
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --retry 3 --connect-timeout 15 --max-time 120 --max-filesize 1048576 "$1" --output "$2"
}
forti_fetch "$forti_manifest" "$forti_work/manifest.json"
python3 - "$forti_work/manifest.json" "$forti_filename" "$forti_edition" > "$forti_work/selection" <<'VERIFY_MANIFEST'
import json,re,sys
def unique(pairs):
    result={}
    for key,value in pairs:
        if key in result: raise ValueError('Duplicate manifest key')
        result[key]=value
    return result
raw=open(sys.argv[1],'rb').read()
if len(raw)>65536: raise SystemExit('Manifest is too large')
m=json.loads(raw,object_pairs_hook=unique)
if (set(m)!={'schema_version','edition','version','files'} or type(m['schema_version']) is not int
        or m['schema_version']!=1 or m['edition']!=sys.argv[3]
        or not isinstance(m['version'],str) or not re.fullmatch(r'20\d{2}-\d{2}-\d{2}\.\d{1,4}',m['version'])
        or not isinstance(m['files'],dict)):
    raise SystemExit('Invalid approved script manifest')
for name,e in m['files'].items():
    if (not re.fullmatch(r'[A-Za-z0-9_./-]+',name) or any(p in ('','.','..') for p in name.split('/'))
            or set(e)!={'sha256','size'} or not re.fullmatch(r'[0-9a-f]{64}',e['sha256'])
            or type(e['size']) is not int or not 0<e['size']<=67108864):
        raise SystemExit('Invalid script digest or path')
e=m['files'][sys.argv[2]]
if e['size']>1048576: raise SystemExit('Script exceeds 1 MiB')
print(m['version'],e['sha256'],e['size'])
VERIFY_MANIFEST
read -r forti_version forti_digest forti_size < "$forti_work/selection"
forti_base=${forti_base//__VERSION__/$forti_version}
forti_fetch "$forti_base/$forti_filename" "$forti_work/payload.sh"
python3 - "$forti_work/payload.sh" "$forti_digest" "$forti_size" <<'VERIFY_BYTES'
import hashlib,sys
data=open(sys.argv[1],'rb').read()
if len(data)!=int(sys.argv[3]) or hashlib.sha256(data).hexdigest()!=sys.argv[2]:
    raise SystemExit('Script checksum/size verification failed; nothing was executed')
VERIFY_BYTES
/bin/bash -n "$forti_work/payload.sh"
/bin/bash "$forti_work/payload.sh" "$@"
