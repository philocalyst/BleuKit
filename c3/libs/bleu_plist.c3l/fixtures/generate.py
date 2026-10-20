#!/usr/bin/env python3
r"""Generate the golden fixtures for bleu_plist.

Every fixture is written by Python's `plistlib` (the reference implementation
that ships with CPython), and every `.canon` file is the canonical text of what
`plistlib.load` decodes from that fixture. The C3 tests parse each fixture with
bleu::plist and compare their canonical text with the `.canon` file, so the
expected values come from an implementation independent of this library.

Canonical text (one line, no spaces):
  dict     {"key":value,...}      in file order
  array    [value,...]
  string   s"..."                 \\ and \" escaped; other code points as \u{hex}
  integer  i<decimal>
  real     r<16 hex digits>       IEEE-754 double bits, big-endian
  true     true / false
  date     d<16 hex digits>       CFAbsoluteTime double bits (seconds since 2001-01-01Z)
  data     x<hex>
  uid      u<decimal>

Run from this directory:  python3 generate.py
"""
import datetime
import io
import os
import plistlib
import struct

HERE = os.path.dirname(os.path.abspath(__file__))
CF_EPOCH = datetime.datetime(2001, 1, 1)


def canon_string(text):
    out = ['"']
    for ch in text:
        cp = ord(ch)
        if ch == '\\':
            out.append('\\\\')
        elif ch == '"':
            out.append('\\"')
        elif 32 <= cp <= 126:
            out.append(ch)
        else:
            out.append('\\u{%x}' % cp)
    out.append('"')
    return ''.join(out)


def canon(value):
    if isinstance(value, dict):
        return '{' + ','.join(canon_string(k) + ':' + canon(v) for k, v in value.items()) + '}'
    if isinstance(value, list):
        return '[' + ','.join(canon(v) for v in value) + ']'
    if isinstance(value, bool):
        return 'true' if value else 'false'
    if isinstance(value, int):
        return 'i%d' % value
    if isinstance(value, float):
        return 'r' + struct.pack('>d', value).hex()
    if isinstance(value, str):
        return 's' + canon_string(value)
    if isinstance(value, bytes):
        return 'x' + value.hex()
    if isinstance(value, datetime.datetime):
        seconds = (value - CF_EPOCH).total_seconds()
        return 'd' + struct.pack('>d', seconds).hex()
    if isinstance(value, plistlib.UID):
        return 'u%d' % value.data
    raise TypeError(type(value))


def write(name, data, canonical_of=None):
    path = os.path.join(HERE, name)
    with open(path, 'wb') as handle:
        handle.write(data)
    decoded = plistlib.loads(data)
    with open(path + '.canon', 'w', encoding='ascii') as handle:
        handle.write(canon(decoded) + '\n')
    print('wrote', name, len(data), 'bytes')


SAMPLE = {
    'Name': 'Sample & <Test> "quoted" \\ back',
    'Count': 42,
    'Negative': -7,
    'Big': 2 ** 40,
    'NegBig': -(2 ** 40),
    'Max64': 2 ** 63 - 1,
    'Min64': -(2 ** 63),
    'Zero': 0,
    'Pi': 3.141592653589793,
    'Half': 0.5,
    'Tiny': -1e-300,
    'Yes': True,
    'No': False,
    'When': datetime.datetime(2013, 6, 22, 10, 18, 0),
    'Epoch': datetime.datetime(2001, 1, 1, 0, 0, 0),
    'Blob': b'\x00\x01\x02\xffbinary',
    'List': [1, 'two', 3.0, [], {}],
    'Unicode': 'héllo — 世界 \U0001F600',
    'Empty': '',
    'Long': 'x' * 40,
    'Shared': 'same',
    'Nested': {'Deep': {'Deeper': [{'Deepest': 'bottom'}]}},
}

HANDWRITTEN = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- A comment before the root element -->
<plist version="1.0">
<dict>
	<key>Escapes</key>
	<string>A &amp; B &lt;tag&gt; &quot;q&quot; &apos;a&apos; &#x41;&#66; &#x1F600;</string>
	<key>Cdata</key>
	<string>before <![CDATA[<raw> & text]]> after</string>
	<!-- a comment between members -->
	<key>Spaced</key>
	<string>
		padded value
	</string>
	<key>Nums</key>
	<array>
		<integer>-12</integer>
		<real>-0.25</real>
		<real>1e3</real>
	</array>
	<key>Empty element</key>
	<dict/>
	<key>Dates</key>
	<date>2024-02-29T23:59:59Z</date>
	<key>Data</key>
	<data>
	AAEC/w==
	</data>
</dict>
</plist>
"""

# An app bundle's Info.plist, as Xcode writes it.
INFO_PLIST = {
    'CFBundleDevelopmentRegion': 'en',
    'CFBundleExecutable': 'Example',
    'CFBundleIconFile': 'Example.icns',
    'CFBundleIdentifier': 'com.example.Example',
    'CFBundleName': 'Example',
    'CFBundleDisplayName': 'Example App',
    'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': '2.3',
    'CFBundleVersion': '2300',
    'LSApplicationCategoryType': 'public.app-category.developer-tools',
    'LSMinimumSystemVersion': '11.0',
    'LSUIElement': False,
    'LSBackgroundOnly': True,
    'CFBundleURLTypes': [
        {'CFBundleURLName': 'Example URL', 'CFBundleURLSchemes': ['example', 'exm']},
    ],
}

STRINGS_DE = {'CFBundleDisplayName': 'Beispiel-App', 'CFBundleName': 'Beispiel'}
STRINGS_EN = {'CFBundleDisplayName': 'Example for English'}


def shared_big():
    items = ['item %03d' % i for i in range(300)]
    body = {'items': items, 'again': items[:20], 'self_refs': [items[7], items[7], items[299]]}
    return body


def main():
    write('sample.plist', plistlib.dumps(SAMPLE, fmt=plistlib.FMT_XML, sort_keys=False))
    write('sample.bplist', plistlib.dumps(SAMPLE, fmt=plistlib.FMT_BINARY, sort_keys=False))
    write('uid.bplist', plistlib.dumps({'a': plistlib.UID(7), 'b': [plistlib.UID(300), plistlib.UID(70000)]},
                                       fmt=plistlib.FMT_BINARY, sort_keys=False))
    write('shared.bplist', plistlib.dumps(shared_big(), fmt=plistlib.FMT_BINARY, sort_keys=False))
    write('handwritten.plist', HANDWRITTEN.encode('utf-8'))
    write('info.plist', plistlib.dumps(INFO_PLIST, fmt=plistlib.FMT_XML))
    write('InfoPlist-de.strings', plistlib.dumps(STRINGS_DE, fmt=plistlib.FMT_BINARY))
    # UTF-16 with a byte-order mark, the encoding Xcode uses for InfoPlist.strings.
    xml_text = plistlib.dumps(STRINGS_EN, fmt=plistlib.FMT_XML).decode('utf-8')
    write('InfoPlist-en.strings', xml_text.replace('encoding="UTF-8"', 'encoding="UTF-16"').encode('utf-16'))


if __name__ == '__main__':
    main()
