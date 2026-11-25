"""Rename Wine's loader in its embedded Info.plist, keeping the section size. usage: brand-loader.py <loader> <name>"""
import re, sys
path, name = sys.argv[1:]
data = open(path, 'rb').read()
m = re.search(rb'<\?xml.*?</plist>\s*', data, re.S)
old = m.group(0)
new = re.sub(rb'>\s+<', b'><', old)
new, n = re.subn(rb'(<key>CFBundleName</key><string>)[^<]*', rb'\g<1>' + name.encode(), new)
assert n == 1 and len(new) <= len(old)
new = new.rstrip() + b'\n' * (len(old) - len(new.rstrip()))
open(path, 'wb').write(data[:m.start()] + new + data[m.end():])
