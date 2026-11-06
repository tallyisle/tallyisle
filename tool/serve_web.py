#!/usr/bin/env python3
"""Local-only static server with the isolation headers required by SQLite OPFS."""
import http.server,sys,os
if len(sys.argv)>2: os.chdir(sys.argv[2])
class Handler(http.server.SimpleHTTPRequestHandler):
 def end_headers(self):
  self.send_header('Cross-Origin-Opener-Policy','same-origin')
  self.send_header('Cross-Origin-Embedder-Policy','require-corp')
  self.send_header('Cache-Control','no-store')
  super().end_headers()
Handler.extensions_map['.wasm']='application/wasm'
http.server.ThreadingHTTPServer(('127.0.0.1',int(sys.argv[1]) if len(sys.argv)>1 else 8765),Handler).serve_forever()
