# changelog

all notable changes to slyph, newest first.<br>
v0.x is early: the version numbers are build phases, not stability promises.

## v0.1.3
+ **table layout** - `display:table/row/cell`, colspan + rowspan, automatic column
  widths from min/max content measurement. hn, forums and wikipedia comparison
  tables render as real tables instead of one flat text run
+ block-level content inside an inline wrapper is promoted instead of swallowed
+ text is painted in reading order, so side-by-side cells come out aligned
+ implied end tags for `<td>`/`<th>`/`<tr>`/`<li>`/`<dt>`/`<dd>`/`<option>` and `<p>`
+ `<img>` renders: alt text as content, or width-based spacers (restores hn comment indent)
+ document structure: nested list indentation, `<ol>` numbering (with `start`),
  indented `<blockquote>`/`<dd>`, `<hr>` drawn as a rule
+ loading indicator - per-stage progress on the status line while a page loads
+ 4- and 8-digit hex colors (`#rgba`, `#rrggbbaa`); alpha is dropped, not blended
+ fixed a parser hang: a stray `}` in any css could spin the browser forever
+ cascade is indexed by selector key instead of matching every rule against every
  node - a page with 1.1 mb of css went from 3.5s to 0.37s, byte-identical output
+ prebuilt binaries for linux (x86, x86_64, arm64, riscv64), macos and freebsd

## v0.1.2
+ external `<link rel=stylesheet>` now fetched + cascaded (was inline `<style>` only)
+ css custom properties + `var(--x, fallback)`, `:root` selector
+ user-owned css deny policy (`~/.slyph/css.policy`), same engine as cookies
+ truecolor when the terminal supports it, else graceful xterm-256 fallback
+ no flicker between page loads; live terminal resize

## v0.1.1
+ reload + back/forward history, with an in-app error page when a fetch fails
+ full keyboard scroll: arrows, page up/down, home/end
+ status bar shows the current url + scroll position

## v0.1
+ pure-zig text browser end to end, zero C
+ html5 tokenizer + tree builder → dom
+ css parser + cascade + computed style (specificity, inherit)
+ block/inline layout → box tree (margins, wrap, lists, pre)
+ text-mode ansi renderer + scrolling tui
+ forms (text/pw/checkbox/radio/submit), GET + POST
+ cookie jar (Set-Cookie capture/replay/persist), redirects per-hop
+ user-owned cookie deny policy
+ in-app url bar + configurable banner start page
