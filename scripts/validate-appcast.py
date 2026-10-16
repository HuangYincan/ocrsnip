"""Fail a release if its feed does not describe the exact shipped bundle/archive."""
import base64
from pathlib import Path
import plistlib
import sys
import xml.etree.ElementTree as ET

app, feed, archive = map(Path, sys.argv[1:])
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
sparkle = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
items = ET.parse(feed).findall('./channel/item')
matching = [item for item in items if item.findtext(sparkle + 'version') == info['CFBundleVersion']]
assert len(matching) == 1, 'Missing or duplicate current version in appcast'
item = matching[0]
assert item.findtext(sparkle + 'shortVersionString') == info['CFBundleShortVersionString']
assert item.findtext(sparkle + 'minimumSystemVersion') == info['LSMinimumSystemVersion']
enclosure = item.find('enclosure')
assert enclosure is not None, 'Missing update download'
expected = ('https://github.com/HuangYincan/ocrsnip/releases/download/v'
            + info['CFBundleShortVersionString'] + '/' + archive.name)
assert enclosure.get('url') == expected, 'Archive URL does not match release'
assert int(enclosure.get('length', '0')) == archive.stat().st_size, 'Archive length mismatch'
assert len(base64.b64decode(enclosure.get(sparkle + 'edSignature', ''), validate=True)) == 64
assert len(base64.b64decode(info['SUPublicEDKey'], validate=True)) == 32
print('PASS: appcast version, platform, archive URL, size and signature metadata')
