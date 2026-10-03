import http from 'http';
import path from 'path';
import fs from 'fs';
import url from 'url';

const BASE_DIR = process.env.BASE_DIR || process.env.HOME || '/config';
const PORT = parseInt(process.env.PORT || 9998);
const HOSTNAME = process.env.HOSTNAME || '0.0.0.0';
const PREFIX = '/files';

console.log('Starting file-manager server...');
console.log('BASE_DIR:', BASE_DIR);
console.log('PORT:', PORT);
console.log('HOSTNAME:', HOSTNAME);
console.log('PREFIX:', PREFIX);

const server = http.createServer(async (req, res) => {
  const parsedUrl = url.parse(req.url, true);
  let pathname = decodeURIComponent(parsedUrl.pathname);

  if (pathname.startsWith(PREFIX + '/')) {
    pathname = pathname.slice(PREFIX.length);
  } else if (pathname === PREFIX) {
    pathname = '/';
  }

  pathname = pathname.replace(/\/+/g, '/').replace(/^\/+/, '').replace(/\/+$/, '');

  const fullPath = path.join(BASE_DIR, pathname);

  const normalizedBase = path.normalize(BASE_DIR) + path.sep;
  if (!path.normalize(fullPath).startsWith(normalizedBase) && path.normalize(fullPath) !== path.normalize(BASE_DIR)) {
    res.writeHead(403, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Access denied' }));
    return;
  }

  try {
    const stats = fs.statSync(fullPath);
    if (stats.isDirectory()) {
      const files = fs.readdirSync(fullPath);
      const items = files.map(file => {
        const itemPath = path.join(fullPath, file);
        const itemStats = fs.statSync(itemPath);
        const itemRelativePath = pathname ? path.join(pathname, file).replace(/\\/g, '/') : file;
        const linkPath = `${PREFIX}/${itemRelativePath}`;
        return {
          name: file,
          type: itemStats.isDirectory() ? 'directory' : 'file',
          size: itemStats.size,
          modified: itemStats.mtime.toISOString(),
          path: linkPath
        };
      });

      if (req.headers.accept && req.headers.accept.includes('application/json')) {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ path: `${PREFIX}/${pathname || ''}`.replace(/\/+/g, '/'), items }));
      } else {
        const currentPath = pathname ? `${PREFIX}/${pathname}`.replace(/\/+/g, '/') : PREFIX;
        const html = `<!DOCTYPE html><html><head><title>File Manager</title><style>body{margin:0;padding:20px;font-family:sans-serif;background:#f5f5f5}.container{max-width:1000px;margin:0 auto;background:white;padding:20px;border-radius:8px}h1{margin-top:0}.breadcrumb{margin-bottom:20px;padding:10px;background:#f9f9f9;border-radius:4px}.breadcrumb a{color:#0066cc;text-decoration:none;margin:0 5px}.file{padding:10px;border-bottom:1px solid #eee}.file a{color:#0066cc;text-decoration:none}</style></head><body><div class="container"><h1>File Manager</h1><div class="breadcrumb">📍 ${currentPath}</div>` + items.map(i => `<div class="file"><a href="${i.path}">${i.type === 'directory' ? '📁' : '📄'} ${i.name}</a></div>`).join('') + `</div></body></html>`;
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
        res.end(html);
      }
    } else {
      const ext = path.extname(fullPath).toLowerCase();
      const mimeTypes = { '.html': 'text/html', '.css': 'text/css', '.js': 'application/javascript', '.json': 'application/json', '.txt': 'text/plain' };
      const contentType = mimeTypes[ext] || 'application/octet-stream';
      res.writeHead(200, { 'Content-Type': contentType, 'Content-Length': stats.size });
      fs.createReadStream(fullPath).pipe(res);
    }
  } catch (err) {
    if (err.code === 'ENOENT') {
      res.writeHead(404, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Not found' }));
    } else {
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: err.message }));
    }
  }
});

server.listen(PORT, '::', () => {
  console.log(`Server listening on all interfaces :${PORT}`);
  console.log(`Serving files from: ${BASE_DIR}`);
});

process.on('SIGTERM', () => {
  console.log('SIGTERM - closing');
  server.close(() => process.exit(0));
});
