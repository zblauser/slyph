# changelog

all notable changes to slyph, newest first.<br>

## v0.1.4
+ **fetch deny policy** (`~/.slyph/fetch.policy`) - a denied sub-resource is never
  requested. matches host, path, kind or `third-party`. seeded with tracker hosts
+ **security** - page text can no longer emit terminal escapes. a page could retitle
  the terminal, forge ui with cursor moves, or overwrite the clipboard via OSC 52
+ **security** - dom depth is capped at parse time; ~60k nested elements used to segfault
+ **security** - releases build with runtime safety checks on (`ReleaseSafe`)
+ **security** - response bodies are capped at 32 mb, so a never-ending or
  decompression-bomb response cannot exhaust memory
+ **security** - a redirected sub-resource is re-checked against `fetch.policy`, so a
  denied host cannot be reached by bouncing through an allowed one
+ **themes** - colors resolve through roles (`text`, `background`, `link`, `heading`,
  `marker`, `rule`), set in `~/.slyph/theme`. `roles-only` overrides site colors.
  no theme file means no change
+ **background-color** - drawn only when it is a dark tint, or when a theme declares a
  `background` and the color contrasts with it. sites assume a white canvas, so painting
  them literally turned text into highlighter bars
+ **table borders** - box rules for tables that ask, via the `border` attribute or css
  (css wins). layout-only tables stay rule-free
+ **`<pre>` keeps inline markup** - code blocks flattened to one unstyled run before,
  which dropped every link inside them. links now get their `[n]` and syntax colors hold
+ **windows builds** - console backend behind a platform interface. all nine targets build
+ `?` opens a key reference, rendered through the engine so it scrolls and `H` backs
+ `q` asks before quitting; `Q` quits at once
+ start page lists bookmarks in a table with hosts and a count of standing deny rules
+ list markers take a `marker` role, colorable apart from item text
+ cookie writes are atomic, so a crash mid-save cannot truncate `cookies.txt`
+ `LINES` / `COLUMNS` override the detected terminal size, clamped, shrink-only on a tty
+ `border`, `border-style`, `border-width` parsed; `none` / `0` distinct from undeclared
+ `zig build clean` removes `zig-out` and the local cache

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
