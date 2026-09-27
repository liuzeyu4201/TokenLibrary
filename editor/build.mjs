import { build } from 'esbuild';
import { mkdirSync, copyFileSync, readFileSync, writeFileSync, cpSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
const root=dirname(fileURLToPath(import.meta.url)), dist=join(root,'dist');
rmSync(dist,{recursive:true,force:true}); mkdirSync(dist,{recursive:true});
await build({entryPoints:[join(root,'src/editor.js')], bundle:true, outfile:join(dist,'editor.js'), format:'iife', target:['safari17','chrome120'], minify:true, legalComments:'linked', loader:{'.woff':'file','.woff2':'file','.ttf':'file'}, assetNames:'fonts/[name]-[hash]'});
copyFileSync(join(root,'index.html'),join(dist,'index.html'));
const lock=readFileSync(join(root,'package-lock.json'),'utf8');
writeFileSync(join(dist,'build.json'),JSON.stringify({lockSHA256:createHash('sha256').update(lock).digest('hex')},null,2));
const licenses=[];
for (const [path, pkg] of Object.entries(JSON.parse(lock).packages)) {
  if (!path || pkg.dev) continue;
  licenses.push(`${path.replace('node_modules/','')} ${pkg.version} — ${pkg.license || 'see package license'}`);
  for (const name of ['LICENSE','LICENSE.md','LICENSE.txt','license','LICENSE-MIT']) {
    try { licenses.push(readFileSync(join(root,path,name),'utf8')); break; } catch {}
  }
}
writeFileSync(join(dist,'THIRD-PARTY-LICENSES.txt'),licenses.join('\n\n'));
// Xcode consumes this exact folder, avoiding a stale independently copied editor.
const packaged=join(root,'../clients/editor');
rmSync(packaged,{recursive:true,force:true}); cpSync(dist,packaged,{recursive:true});
console.log('Offline editor built and copied to clients/editor.');
