import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { resolve, extname } from 'node:path';
const root=resolve('dist');
createServer(async (req,res) => {
  try {
    const path=resolve(root,'.'+decodeURIComponent(new URL(req.url,'http://localhost').pathname === '/' ? '/index.html' : new URL(req.url,'http://localhost').pathname));
    if (!path.startsWith(root+'/')) throw new Error('invalid path');
    const data=await readFile(path); res.setHeader('Content-Type',({'.html':'text/html','.js':'text/javascript','.css':'text/css','.woff2':'font/woff2','.woff':'font/woff','.ttf':'font/ttf'})[extname(path)] || 'application/octet-stream');res.end(data);
  } catch {res.writeHead(404);res.end('Not found');}
}).listen(8766,'127.0.0.1');
