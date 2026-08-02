# slyph
a terminal web browser with its own engine, in pure zig<br>
no chromium, no webkit, no servo.

<p align="center">
  <img src="assets/slyph.gif" alt="slyph browsing from the terminal" width="82%"/>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-v0.1.3-000?style=flat-square&labelColor=500" alt="version"/>
  <img src="https://img.shields.io/badge/license-GPL--3.0-000?style=flat-square&labelColor=500" alt="GPL-3.0"/>
  <img src="https://img.shields.io/badge/zig-0.16-000?style=flat-square&labelColor=500" alt="zig 0.16"/>
</p>

zig 0.16, single binary
- fetches raw bytes and runs the whole pipeline itself:<br>
`fetch > html parse > dom > css cascade > layout > render > terminal cells`
- networking via zig std (`std.http.Client` + `std.crypto.tls`)
- runs no javascript at all: nothing on a page executes (see [planned](#planned))

## why
browsers obey the server: the site says which cookies are "required," ships whatever js it likes, the browser complies.<br>
slyph inverts that. it parses and runs everything itself, **every stage is a point where _you_, not the site, decide what's necessary.** running zero js is the most radical "deemed unnecessary." the cookie and css deny policies are the first concrete slices: one deny-rule surface, consulted per pipeline stage.

> **[ ! ]** v0.1 is early. a working pure-zig text browser end to end:
> - fetch + cookies, html5 parse, css cascade, block/inline + table layout, ansi render,
> - scroll, links, forms, login. no javascript yet. expect rough edges.

## version
<b>v0.1.3 (latest)</b>
+ **table layout** - `display:table/row/cell`, colspan + rowspan, automatic column
  widths from min/max content measurement. hn, forums and wikipedia comparison
  tables render as real tables instead of one flat text run
+ `<img>` renders: alt text as content, or width-based spacers (restores hn comment indent)
+ document structure: nested list indentation, `<ol>` numbering (with `start`),
  indented `<blockquote>`/`<dd>`, `<hr>` drawn as a rule
+ loading indicator - per-stage progress on the status line while a page loads
+ indexed cascade - a page with 1.1 mb of css went from 3.5s to 0.37s
+ fixed a parser hang: a stray `}` in any css could spin the browser forever
+ prebuilt binaries for linux, macos and freebsd

earlier versions: [CHANGELOG.md](CHANGELOG.md)

## install
prebuilt binaries are on the [releases](https://github.com/zblauser/slyph/releases) page:
linux (x86, x86_64, arm64, riscv64), macos (intel, apple silicon), freebsd.

```sh
tar xzf slyph-*.tar.gz && chmod +x slyph && ./slyph
```

the linux builds are static musl - no libc to install, nothing to link. the 32-bit
x86 build is small enough to run under [ish](https://ish.app) on ios.

## build
```sh
zig build                              # → zig-out/bin/slyph
zig build install --prefix ~/.local    # → ~/.local/bin/slyph
zig build test                         # unit tests
```

## run
```sh
slyph                 # start page (your bookmarks)
slyph example.com     # load a url (bare host → https)
slyph https://lobste.rs
slyph example.com | less   # piped → plain-text dump
```

## commands
<details>
<summary>view</summary><br>

| key            | action                        |
| -------------- | ----------------------------- |
| `j` / `k` / arrows | scroll line down / up     |
| `d` / `u`      | half-page down / up           |
| `space` / `b`  | half-page down / up           |
| `PgUp` / `PgDn`| page up / down                |
| `g` / `G` / `Home` / `End` | top / bottom      |
| `f`            | follow a `[n]` link           |
| `i`            | edit / activate a `{n}` field |
| `r`            | reload                        |
| `Ctrl+L` / `:` | open the url bar              |
| `H` / `L`      | back / forward                |
| `q`            | quit                          |
</details>

## storage/config
all user state lives under `~/.slyph/`, seeded on first run so every default is
visible and editable:
- `~/.slyph/start` - start-page links, `name<TAB>url`, one per line.
- `~/.slyph/cookies.txt` - persisted (non-session) cookies.
- `~/.slyph/cookies.policy` - deny rules `deny <domain-glob> <name-glob>`.
- `~/.slyph/css.policy` - deny rules `deny <domain-glob> <property-glob>`.

cookies.policy ships seeded with common tracker rules; anything not denied is
accepted as usual. css.policy ships opt-in (examples commented) so styling is
unchanged until you add a rule - e.g. `deny * color` to ignore author text colors.

> **[ ! ]** session cookies stay in memory only; just `cat`/edit the files.

## known limitations
- no javascript yet - js-heavy app sites (gmail, telegram, discord) render mostly empty. static / server-rendered sites work now.
- `std.crypto.tls` (zig 0.16) handshakes fail on some ecdsa-cert hosts. most sites work; bounded upstream gap.
- no flexbox/grid or video yet. images are not drawn - you get the alt text.
- tables have no borders; columns are space-separated. a cell spanning rows is placed on its own row, not stretched down.
- pages that link a lot of css are slow: sub-resources are fetched one at a time, and the cascade matches every rule against every node.

## planned
- a js engine + core dom bindings > light-js sites, with per-origin run/skip policy
- flexbox / grid + more dom/cssom > modern layouts
- pixel mode (sixel / kitty + ansi-block fallback) > images
- heavy js apps, eventually media

## contribution
free + open source, GPL-3.0. issues and PRs welcome; no guarantee of merge.

> **[ ! ]** thank you for your attention

