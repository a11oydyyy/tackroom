#!/bin/zsh
# Lists text shown in the app that has no 简体中文 or English translation yet.
# Traditional Chinese is the source: the text itself is the key.
set -e
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
touch Sources/TackroomKit/*.swift Sources/TackroomApp/*.swift
swift build --product TackroomApp -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$OUT" >/dev/null 2>&1
python3 -I - "$OUT" <<'PY'
import glob, json, plistlib, re, sys
keys = {}
for f in glob.glob(sys.argv[1] + '/*.stringsdata'):
    j = json.load(open(f))
    for k in j['tables'].get('Localizable', []):
        if re.search(r'[　-鿿＀-￯]', k['key']):
            keys.setdefault(k['key'], f"{j['source'].split('/')[-1]}:{k['location']['startingLine']}")
def table(lang):
    found = set(re.findall(r'^"((?:[^"\\]|\\.)*)" = ', open(f'Localization/{lang}.lproj/Localizable.strings').read(), re.M))
    found = {s.replace('\\"', '"').replace('\\\\', '\\') for s in found}
    try: found |= set(plistlib.load(open(f'Localization/{lang}.lproj/Localizable.stringsdict', 'rb')))
    except FileNotFoundError: pass
    return found
missing = 0
for lang in ['zh-Hans', 'en']:
    have = table(lang)
    for k, where in sorted(keys.items()):
        if k not in have:
            missing += 1
            print(f'{lang}\t{where}\t{k}')
print(f'{len(keys)} texts, {missing} missing translations')
PY
