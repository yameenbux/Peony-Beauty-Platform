import http.server, os, sys, functools
ROOT = '/home/user/test/dist'
class H(http.server.SimpleHTTPRequestHandler):
    def translate_path(self, path):
        p = path.split('?',1)[0].split('#',1)[0]
        full = os.path.join(ROOT, p.lstrip('/'))
        # Render serves a real file in preference to any rule
        if os.path.isfile(full): return full
        if os.path.isdir(full) and os.path.isfile(os.path.join(full,'index.html')):
            return os.path.join(full,'index.html')
        if p == '/': return os.path.join(ROOT,'index.html')
        # the catch-all rewrite
        return os.path.join(ROOT,'book','index.html')
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', 8099), H).serve_forever()
