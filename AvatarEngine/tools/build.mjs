import { build } from 'esbuild';
const common = { entryPoints: ['src/index.ts'], bundle: true, sourcemap: true, target: 'es2020', logLevel: 'info' };
await build({ ...common, format: 'esm', outfile: 'dist/mewpon.esm.js' });
await build({ ...common, format: 'iife', globalName: 'Mewpon', outfile: 'dist/mewpon.iife.js', footer: { js: 'window.MewponLib = Mewpon; window.Mewpon = Mewpon.Mewpon;' }, minify: true });

// Keep the native application resource in sync with this vendored source.
const { copyFile, readFile, writeFile } = await import("node:fs/promises");
await copyFile("dist/mewpon.iife.js", "../Sources/MewponDesktop/Resources/ExistingMewponAvatar/mewpon.iife.js");
// file:// images taint Canvas in WKWebView. Package the exact original PNG
// bytes as local data resources, allowing coverage cleanup without relaxing
// WebKit security or changing any source artwork.
const root='../Sources/MewponDesktop/Resources/ExistingMewponAvatar/';
const manifest=JSON.parse(await readFile(root+'spritesheets/manifest.json','utf8'));
const files=new Set();
function visit(value){if(!value||typeof value!=='object')return;if(typeof value.file==='string')files.add(value.file);for(const child of Object.values(value))visit(child);}
visit(manifest);
const textures={};
for(const file of files)textures[file]='data:image/png;base64,'+(await readFile(root+'spritesheets/'+file)).toString('base64');
await writeFile(root+'textures.js','window.MEWPON_TEXTURES='+JSON.stringify(textures)+';\n');
