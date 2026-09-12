// Local test server. Binds only to loopback and serves files below web/.
const { createServer } = require('node:http');
const { readFile } = require('node:fs/promises');
const { resolve, extname, sep } = require('node:path');
const root = resolve(__dirname, '../web');
const types = {
  '.html': 'text/html',
  '.css': 'text/css',
  '.js': 'text/javascript',
  '.svg': 'image/svg+xml',
  '.woff2': 'font/woff2',
};
createServer(async (request, response) => {
  try {
    const pathname = decodeURIComponent(new URL(request.url, 'http://localhost').pathname);
    const file = resolve(root, '.' + (pathname === '/' ? '/index.html' : pathname));
    if (!file.startsWith(root + sep)) {
      response.writeHead(403).end();
      return;
    }
    const body = await readFile(file);
    response
      .writeHead(200, { 'Content-Type': types[extname(file)] || 'application/octet-stream' })
      .end(body);
  } catch {
    response.writeHead(404).end();
  }
}).listen(4175, '127.0.0.1');
