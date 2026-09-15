#!/usr/bin/env python3
"""Install a tiny interactive site without needing Flutter to run the demo."""
import io
import pathlib
import sys
import tarfile

root = pathlib.Path(sys.argv[1]) / 'club_gallery_demo' / 'demo'
root.mkdir(parents=True, exist_ok=True)
archive = root / 'site.tar.gz'
if not archive.exists():
    content = b'''<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Club demo</title><style>body{margin:0;background:#fff8f4;color:#27221f;font:18px system-ui;display:grid;place-items:center;min-height:100vh}main{padding:32px;text-align:center}h1{font-size:48px;letter-spacing:-2px}button{background:#ff4f18;color:white;border:0;padding:14px 24px;border-radius:8px;font:inherit;cursor:pointer}</style>
<main><p>YOUR PACKAGE, ALIVE</p><h1>Hello from Club.</h1><p>This site is running in your browser.</p><button id="counter">Clicked 0 times</button></main>
<script>let count=0;document.querySelector('#counter').onclick=e=>e.target.textContent='Clicked '+(++count)+' times';</script>'''
    with tarfile.open(archive, 'w:gz', format=tarfile.USTAR_FORMAT) as tar:
        entry = tarfile.TarInfo('index.html')
        entry.size = len(content)
        entry.mode = 0o644
        tar.addfile(entry, io.BytesIO(content))
