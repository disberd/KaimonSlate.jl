// Asserts the `ctx` that a component's `exportFigure` gets for a PDF export: the keys it always had
// (`params`, `kind`, `theme`, `vars`, `dark`) and the size fields of the figure from the hub (`width`,
// `max_height`, `scale`).
//
//   node test/js/component_fig_ctx.mjs      # exit 0 = pass, 1 = mismatch
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(here, '..', '..', 'src', 'assets', 'js', 'inspect.js'), 'utf8');

let got = null, posted = null;
const el = { dataset: { component: 'demo' }, querySelectorAll: () => [] };
const host = {
  querySelector: (s) => s === '.slatecomponent' ? el : { textContent: '{"props": {"n": 3}}' },
};
const cell = { querySelectorAll: () => [host] };
const window = {
  __SLATE_APP__: { on: true },                        // no idle warm-up of the capture library
  slateWidgets: { demo: { exportFigure: async (_el, ctx) => { got = ctx; return { svg: '<svg/>' }; } } },
};
const document = { getElementById: (id) => id === 'cell-c1' ? cell : null };
const api = async (_method, _path, body) => { posted = body; };
new Function('window', 'document', 'api', src)(window, document, api);

let bad = 0;
const eq = (a, b, what) => {
  if (JSON.stringify(a) !== JSON.stringify(b)) { console.error(`component ctx: ${what}\n  got:  ${JSON.stringify(a)}\n  want: ${JSON.stringify(b)}`); bad++; }
};

await window._slateComponentFig('r1', 'c1', 0, 'midnight', { width: 816, max_height: 756, scale: 2 });
eq(Object.keys(got).sort(), ['dark', 'kind', 'max_height', 'params', 'scale', 'theme', 'vars', 'width'], 'the keys');
eq([got.params, got.kind, got.theme], [{ n: 3 }, 'demo', 'midnight'], 'the old keys keep their values');
eq([got.width, got.max_height, got.scale], [816, 756, 2], 'the size of the figure');
eq([posted.ok, posted.svg], [true, '<svg/>'], 'the picture goes back to the hub');

// A document has no figure cap: `max_height` is null.
await window._slateComponentFig('r2', 'c1', 0, 'daylight', { width: 627, max_height: null, scale: 2 });
eq([got.width, got.max_height], [627, null], 'a document');

process.exit(bad ? 1 : 0);
