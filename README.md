# slyph
a terminal web browser with its own engine, in pure zig<br>
*no chromium, no webkit, no servo*

<p align="center">
  <img src="assets/slyph.gif" alt="slyph browsing from the terminal" width="82%"/>
</p>

<p align="center">
  <img src="https://img.shields.io/github/v/tag/zblauser/slyph?sort=semver&style=flat-square&labelColor=500&color=000&label=version" alt="version"/>
  <img src="https://img.shields.io/badge/license-GPL--3.0-000?style=flat-square&labelColor=500" alt="GPL-3.0"/>
  <img src="https://img.shields.io/badge/zig-0.16-000?style=flat-square&labelColor=500" alt="zig 0.16"/>
</p>

zig 0.16, single binary
- fetches raw bytes and runs the pipeline itself:<br>
`fetch > html parse > dom > css > layout > render > terminal cells`
- networking via zig std (`std.http.Client` + `std.crypto.tls`)
- runs 0 javascript if desired, though a user controlled js implementation is in development (see [planned](#planned))

## why
browsers are built to obey the server; the site says (at their discretion) which cookies are "required," ships whatever js it likes, and your browser just complies with it for the most part<br>

slyph attempts to invert that. it parses and runs everything itself, **every stage is a point where _you the user_, not the host, decides what is actually necessary.** the cookie and css deny policies are the first concrete slices; one deny rule, consulted per pipeline stage. plus, running a TUI browser is just plain fun.

> **[ ! ]** the current version is early, expect rough edges. that being said, it's a working, pure zig, text browser end to end

## version
<b>v0.1.4 (latest)</b>
- **fetch deny policy** - a denied sub resource is never requested (matches host, path, kind or `third-party`, seeded with tracker hosts)
- **security** - page text can not emit terminal escapes (clipboard, title, cursor), deeply nested markup no longer crashes
- **themes** - for now it is manual, and colors are set in `~/.slyph/theme`
- **background color** - generally drawn only where it reads well in a terminal
- **`<pre>` keeps inline markup** - links in code blocks are followable
- **windows builds** - console backends, need more work
- `?` opens help; `q` asks before quitting

earlier versions: [CHANGELOG.md](CHANGELOG.md)

## install
prebuilt binaries are on the [releases](https://github.com/zblauser/slyph/releases) page:
linux (x86, x86_64, arm64, riscv64), macos (intel, apple silicon), freebsd, windows

```sh
tar xzf slyph-*.tar.gz && chmod +x slyph && ./slyph
```

the linux builds are static musl

## build
```sh
zig build                              # -> zig-out/bin/slyph
zig build install --prefix ~/.local    # -> ~/.local/bin/slyph
zig build test                         # unit tests
zig build clean                        # removes zig-out + local cache
```

## run
```sh
slyph                 # start page (your bookmarks)
slyph example.com     # load a url (bare host -> https)
slyph https://ziggit.dev
slyph example.com | less   # piped -> plain-text dump
```

## commands
<details>
<summary>view</summary><br>

| key            | action                        |
| -------------- | ----------------------------- |
| `j` / `k` / `arrows` | scroll line down / up     |
| `d` / `u`      | half page down / up           |
| `space` / `b`  | half page down / up           |
| `PgUp` / `PgDn`| page up / down                |
| `g` / `G` / `Home` / `End` | top / bottom      |
| `f`            | follow `[n]` link           |
| `i`            | edit / activate `{n}` fields |
| `r`            | reload                        |
| `Ctrl+L` / `:` | open the url bar              |
| `H` / `L`      | back / forward                |
| `?`            | key reference                 |
| `q` / `Q`      | quit (asks) / quit now  |
</details>

## storage/config
user state spawns/lives under `~/.slyph/` on first run, so all defaults are visible/editable:
- `~/.slyph/start` - start page links, `name<TAB>url`, one per line
- `~/.slyph/cookies.txt` - persisted (non-session) cookies
- `~/.slyph/cookies.policy` - deny rules `deny <domain-glob> <name-glob>`
- `~/.slyph/css.policy` - deny rules `deny <domain-glob> <property-glob>`
- `~/.slyph/fetch.policy` - deny rules `deny <domain-glob> <what-glob>`
    - where `what-glob` matches the sub resource host (path, kind, or `third-party`)
- `~/.slyph/theme` - `<role> #rrggbb` per line (roles: `text`, `background`,
  `link`, `heading`, `marker`, `rule`)
    - add `roles-only` to ignore the site colors
    - no file = terminal defaults.

> **[ ! ]** cookies.policy/fetch.policy ship seeded with "common" tracker rules; anything not denied is accepted as usual (definitely susceptible to change). css.policy ships opt in so styling is unchanged until you add a rule (e.g. `deny * color`) to ignore author text colors. session cookies stay in memory only; just `cat`/edit the files.

## known limitations
- no javascript yet - js-heavy sites (google results in the current year, discourse forums, etc.) render mostly empty, though static/server rendered sites work now
- for search, a no js engine like lite.duckduckgo.com works today
- `std.crypto.tls` (zig 0.16) handshakes fail on some ecdsa cert hosts, most sites work
- no flexbox/grid or video, images are not drawn, you get the alt text
- table borders are drawn only when the markup asks for them
- backgrounds paint behind text cells, not across a whole box
- tabs in `<pre>` render as one space each; control bytes stripped from page text
- pages that link a lot of css are slow-ish, sub resources fetched one at a time, denyable in fetch.policy

## planned (as i get time)
- a js engine + core dom bindings > light-js sites, with per-origin run/skip policy
- flexbox / grid + more dom/cssom > modern layouts
- pixel mode (sixel / kitty + ansi-block fallback) > images
- heavy js apps, eventually media

## contribution
free + open source, GPL-3.0. issues and PRs welcome; no guarantee of merge.

> **[ ! ]** thank you for your attention

