// Renders Graphviz dot to SVG with the WebAssembly build of Graphviz (@viz-js/viz, MIT; toolchain.versions pins it).
// Reads a JSON array of dot texts on stdin and prints a JSON array of SVG texts (null for a text Graphviz refused, with its message in "errors").
// Where the module is: $JG_VIZ_DIR (a folder with node_modules/@viz-js/viz), else the global npm root.
const { execFileSync } = require('node:child_process');
const paths = [process.env.JG_VIZ_DIR, (() => { try { return execFileSync('npm', ['root', '-g'], { encoding: 'utf8' }).trim(); } catch (e) { return null; } })()].filter(Boolean);
let mod;
try { mod = require(require.resolve('@viz-js/viz', { paths })); } catch (e) { console.error('no @viz-js/viz in ' + (paths.join(' or ') || 'any folder')); process.exit(3); }
let input = '';
process.stdin.on('data', d => { input += d; }).on('end', async () => {
  const viz = await mod.instance();
  const out = { version: viz.graphvizVersion, svg: [], errors: [] };
  for (const dot of JSON.parse(input)) {
    try { out.svg.push(viz.renderString(dot, { format: 'svg', engine: 'dot' })); out.errors.push(null); } catch (e) { out.svg.push(null); out.errors.push(String(e.message || e)); }
  }
  process.stdout.write(JSON.stringify(out));
});
