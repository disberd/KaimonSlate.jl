// The live deck lifts the heading a slide starts with into its own `.slide-title` element, outside the
// scaled body, and puts it back when the slide is torn down. The real `_titleOf`, `_hoistTitle` and
// `_restoreTitle` are extracted from slides.js and run on minidom.
//
//   node test/js/slide_title.mjs      # exit 0 = pass, 1 = mismatch, 2 = extraction failure
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { El } from './minidom.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(here, '..', '..', 'src', 'assets', 'js', 'slides.js'), 'utf8');

let bad = 0;
const ok = (cond, m) => { if (!cond) { console.error('slide_title: ' + m); bad++; } };

const grab = re => { const m = src.match(re); if (!m) { console.error('slide_title: ' + re + ' is gone from slides.js'); process.exit(2); } return m[0]; };
const fn = n => grab(new RegExp('\\n  function ' + n + '\\([\\s\\S]*?\\n  \\}'));
const code = [fn('_titleOf'), grab(/\n  const _isHeading[^\n]*/), fn('_hoistTitle'), fn('_restoreTitle')].join('\n');
const doc = { createElement: t => new El(t) };
const { _titleOf, _hoistTitle, _restoreTitle } =
  (0, eval)('(function (document) {' + code + '\nreturn { _titleOf, _hoistTitle, _restoreTitle }; })')(doc);

// ── the title rule: the first block, when it is a heading of any depth ──
ok(_titleOf('# Intro') === 'Intro', 'h1');
ok(_titleOf('###### Deep\n\ntext') === 'Deep', 'h6 followed by text');
ok(_titleOf('\n\n## Padded ##\nbody') === 'Padded', 'leading blank lines, closing hashes');
ok(_titleOf('text first\n## Later') === null, 'a heading after prose is not the title');
ok(_titleOf('```\n# not a heading\n```') === null, 'a fenced line is not a heading');
ok(_titleOf('#hashtag') === null, 'no space after the hashes');
ok(_titleOf(null) === null && _titleOf('') === null, 'no source, no title');
ok(_titleOf('   ## Indented') === 'Indented', 'up to three leading spaces');
ok(_titleOf('    ## Code') === null, 'four spaces make a code block');
ok(_titleOf('# Title##') === 'Title##', 'a closing run needs a space before it');
ok(_titleOf('# Title ##') === 'Title', 'a spaced closing run is dropped');

// ── hoist and restore ──
const el = (tag, cls, kids = []) => { const e = new El(tag); if (cls) e.className = cls; kids.forEach(k => e.appendChild(k)); return e; };
const redraw = (md, ...kids) => { [...md.children].forEach(c => c.remove()); kids.forEach(k => md.appendChild(k)); };
const setup = () => {
  const h = el('h2'), p = el('p');
  const md = el('div', 'md', [h, p]);
  const cell = el('div', 'cell md', [md]);
  const body = el('div', 'slide-body', [cell]);
  const slide = el('div', 'deck-slide', [el('div', 'slide-bg'), body]);
  return { h, p, md, cell, body, slide };
};

{
  const { h, p, md, body, slide, cell } = setup();
  _hoistTitle(slide, cell, '## Heading\n\ntext');
  const titles = slide.querySelectorAll('.slide-title');
  ok(titles.length === 1, 'one .slide-title');
  ok(titles[0].dataset.deckRegion === 'title', '.slide-title is the title region');
  ok(titles[0].parentElement === slide && !body.contains(titles[0]), '.slide-title sits outside the body');
  ok(slide.children.indexOf(titles[0]) < slide.children.indexOf(body), '.slide-title comes before the body');
  ok(titles[0].children[0] === h, 'the heading moved, not cloned');
  ok(md.children.length === 1 && md.children[0] === p, 'the heading is gone from the body');

  _hoistTitle(slide, cell, '## Heading\n\ntext');
  ok(slide.querySelectorAll('.slide-title').length === 1 && titles[0].children[0] === h, 'a second pass changes nothing');

  _restoreTitle(slide);
  ok(md.children[0] === h && md.children[1] === p, 'restore puts the heading back at the top of its block');
  ok(titles[0].children.length === 0, 'restore empties the title');
}

{ // the cell re-rendered while on the slide: the new heading takes the title, the old one is dropped
  const { h, md, slide, cell } = setup();
  _hoistTitle(slide, cell, '## Heading');
  const h2 = el('h2'), p2 = el('p');
  redraw(md, h2, p2);
  _hoistTitle(slide, cell, '## Heading');
  ok(slide.querySelector('.slide-title').children[0] === h2 && md.children.length === 1, 're-render: the new heading is the title');
  _restoreTitle(slide);
  ok(md.children[0] === h2 && md.children.indexOf(h) < 0, 'restore after a re-render leaves the new heading in place');
}

{ // the cell re-rendered and restore ran before the next sync: no duplicate
  const { h, md, slide, cell } = setup();
  _hoistTitle(slide, cell, '## Heading');
  redraw(md, el('h2'), el('p'));
  const first = md.children[0];
  _restoreTitle(slide);
  ok(md.children[0] === first && md.children.length === 2, 'a stale heading is not put back next to a new one');
}

{ // the source lost its heading: the title goes
  const { slide, cell } = setup();
  _hoistTitle(slide, cell, '## Heading');
  _hoistTitle(slide, cell, 'plain text');
  ok(slide.querySelectorAll('.slide-title').length === 0, 'no heading, no .slide-title');
}

{ // a slide whose first block is not a heading has no title
  const { md, slide, cell } = setup();
  _hoistTitle(slide, cell, 'text\n\n## Later');
  ok(slide.querySelectorAll('.slide-title').length === 0 && md.children.length === 2, 'a non-heading start leaves the body alone');
}

process.exit(bad ? 1 : 0);
