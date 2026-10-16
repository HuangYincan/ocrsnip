from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import threading
import uuid

root = Path(__file__).resolve().parents[1]
app, updates, probe_binary = map(Path, sys.argv[1:])

class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass

with tempfile.TemporaryDirectory(prefix='update-probe-', dir=root / '.build') as temporary:
    work = Path(temporary)
    fixture = work / 'UpdateProbe.app'
    shutil.copytree(app, fixture, symlinks=True)
    info_path = fixture / 'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    build = int(info['CFBundleVersion'])
    info.update(CFBundleIdentifier='com.acc.ocrsnip.probe.' + uuid.uuid4().hex,
                CFBundleExecutable='UpdateProbe', SUEnableAutomaticChecks=False,
                NSAppTransportSecurity={'NSAllowsArbitraryLoads': True})
    executable = fixture / 'Contents/MacOS/UpdateProbe'
    shutil.copy2(probe_binary, executable)
    served = work / 'feed'
    served.mkdir()
    signed_feed = (updates / 'appcast.xml').read_bytes()
    (served / 'appcast.xml').write_bytes(signed_feed)
    # Alter the signed XML document (comments outside it need not be signed).
    # The version and download URL remain valid, so rejection must be authentication.
    tampered_feed = signed_feed.replace(b'<channel>', b'<channel>\n<description>unsigned alteration</description>', 1)
    assert tampered_feed != signed_feed
    (served / 'tampered.xml').write_bytes(tampered_feed)
    server = ThreadingHTTPServer(('127.0.0.1', 0), partial(QuietHandler, directory=str(served)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}/'
    try:
        for installed, feed, expected in [
            (build - 1, 'appcast.xml', 'update'),
            (build, 'appcast.xml', 'current'),
            (build + 1, 'appcast.xml', 'current'),
            (build - 1, 'tampered.xml', 'rejected'),
            (build - 1, 'missing.xml', 'rejected'),
        ]:
            info['CFBundleVersion'] = str(installed)
            info_path.write_bytes(plistlib.dumps(info))
            subprocess.run(['codesign', '--force', '--sign', '-', str(fixture)], check=True, capture_output=True)
            subprocess.run([str(executable), base + feed, expected, str(build)], check=True, timeout=30)
    finally:
        server.shutdown()
        server.server_close()

    # Independently check the shipped public key against a damaged download.
    archive = updates / ('ocrsnip-' + info['CFBundleShortVersionString'] + '.zip')
    tampered = work / 'tampered.zip'
    shutil.copyfile(archive, tampered)
    with tampered.open('ab') as stream:
        stream.write(b'unsigned alteration')
    result = subprocess.run(['swift', '-module-cache-path', str(root / '.build/module-cache'),
        str(root / 'scripts/verify-update.swift'), str(app), str(updates / 'appcast.xml'), str(tampered)],
        capture_output=True, text=True)
    assert result.returncode == 1, 'Damaged update must fail signature verification'
    assert 'signature does not match' in result.stderr, result.stderr
    print('PASS: damaged archive rejected')
