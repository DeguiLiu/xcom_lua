# lua51-libs — Lua 5.1 library bundle from Lua for Windows

Curated subset of pure-Lua libraries bundled with **Lua for Windows 5.1.5**
(installed at `D:\develop\Lua\5.1`). All files here are LuaJIT 2.1 compatible
(Lua 5.1 syntax + the LuaJIT-implemented extensions).

The subset was filtered for xcom_lua (`LuaJIT + ImGui` over a Windows COM port
tool), so the focus is on string / table / config / test / OOP / serialization
helpers, NOT on C modules, networking, GUI, or DB drivers.

## Source

- Origin: `D:\develop\Lua\5.1\lua\`
- Vendor: Lua for Windows 5.1.5 (`Lua.org, PUC-Rio` runtime; `LfW` packaging).
- Snapshot date: 2026-09-05.
- No version pinning — these are whatever the LfW installer dropped in
  2018-01-30 (file dates). Penlight carries no explicit version number in
  these files; treat it as **Penlight 1.x**. `luaunit` is v2.0, `moses` is
  v1.4.0, `LuaLogging` is v1.2.0, `30log` is v1.0.0.

## License

See the header comment of each individual `.lua` file. Summary:

| Library / file               | License              |
|------------------------------|----------------------|
| `*.lua` in `lua/pl/`         | MIT (Penlight, David Manura / Steve Donovan / others) |
| `luaunit.lua`                | X11 (`LICENSE.txt` upstream) |
| `logging.lua` + `logging/*.lua` | MIT (LuaLogging, Kepler Project) |
| `moses.lua`                  | MIT (Roland Yonaba) |
| `30log.lua`                  | MIT (Roland Yonaba) |
| `binary_heap.lua`            | MIT (Roland Yonaba) |
| `serialize.lua`              | MIT |
| `base.lua`, `list.lua`, `std.lua`, `set.lua`, `lcs.lua`, `getopt.lua`, `parser.lua`, `object.lua`, `classlib.lua`, `strict.lua`, `strictness.lua` | various permissive (MIT / BSD-equivalent); see headers |
| `stdlib-ext/*.lua`           | same as `base.lua` family; **see warning below** |

Nothing here is GPL/AGPL/LGPL. MIT and X11 are both compatible with the
project's overall license posture.

## Layout

```
third_party/lua51-libs/
├── README.md                  (this file)
├── 30log.lua                  (A) 30-line OOP class system
├── base.lua                   (A) base "globals + op table" helpers
├── binary_heap.lua            (A) binary heap data structure
├── classlib.lua               (A) class library (alternative)
├── getopt.lua                 (A) command-line getopt-style parser
├── lcs.lua                    (A) longest common subsequence
├── list.lua                   (A) linked-list helpers
├── logging.lua                (A) LuaLogging core API
├── logging/
│   ├── console.lua            (A) console appender
│   ├── file.lua               (A) file appender
│   ├── rolling_file.lua       (A) rolling-file appender
│   ├── email.lua              (B) SMTP appender — needs luasocket C lib
│   ├── socket.lua             (B) socket appender — needs luasocket C lib
│   └── sql.lua                (B) SQL appender — needs luasql C lib
├── luaunit.lua                (A) unit testing framework
├── moses.lua                  (A) functional programming utility belt
├── object.lua                 (A) prototype-based OOP
├── parser.lua                 (A) parser-combinator generator
├── penlight/pl/               (A) Penlight library (39 modules)
├── serialize.lua              (A) Lua-table serializer
├── set.lua                    (A) Set datatype
├── std.lua                    (A) "standard" misc helpers
├── stdlib-ext/                (B) WARNING — mutates LuaJIT builtins
│   ├── string_ext.lua             extends built-in `string`
│   ├── table_ext.lua              extends built-in `table`
│   ├── math_ext.lua               extends built-in `math`
│   ├── io_ext.lua                 extends built-in `io`
│   └── package_ext.lua            extends built-in `package`
└── strict.lua                 (A) strict-mode for globals
└── strictness.lua             (A) Yonaba's stricter variant
```

Total: **67 .lua files** copied verbatim from `D:\develop\Lua\5.1\lua\`.

## A / B / C classification

### A — Pure Lua, LuaJIT 2.1 compatible, project-applicable (搬)

These work out of the box on the xcom_lua runtime (`xcom_lua/runtime/luajit.exe`):

- `30log.lua` — Compact OOP class system (`Class("Foo"):extends("Bar")`); a
  lighter alternative to `pl.class`.
- `base.lua` — Globals + functional operator table (`op.add`, `op.eq`, ...).
- `binary_heap.lua` — Binary min/max-heap.
- `classlib.lua` — Yet another class library (richer features than 30log).
- `getopt.lua` — Svenne Panne-style command-line option parser.
- `lcs.lua` — Longest Common Subsequence algorithm (useful for diffs).
- `list.lua` — Singly/doubly linked list helpers.
- `logging.lua` + `logging/console.lua` + `logging/file.lua` +
  `logging/rolling_file.lua` — Full logging API with console/file/rolling
  appenders. `require "logging"` registers the API; the appenders activate
  them by name. Useful for the diagnostic log (`xcom_lua/runtime/xcom_diag.log`).
- `luaunit.lua` — xUnit-style test framework (`TestRunner`, `TestCase`).
- `moses.lua` — Functional programming utility belt (map/filter/reduce,
  curry, composition, set ops, ...). Big file but all pure Lua.
- `object.lua` — Prototype-based objects (no class needed).
- `parser.lua` — Parser-combinator generator (PEG-style).
- `penlight/pl/**` — **Penlight**, 39 modules. Useful ones:
  - `pl.utils` — `split`, `assert_string`, `printf`, `merge`, ...
  - `pl.stringx` — Python-style string ops (`split`, `startswith`, `endswith`,
    `strip`, `ljust`, `partition`, ...). The DLP encryption requirement makes
    this the most direct answer to the project's "no general UTF-8 utils yet"
    gap (still pure Lua; does NOT add UTF-8 awareness, but adds the missing
    pure-Lua string ergonomics).
  - `pl.tablex` — `deepcopy`, `merge`, `map`, `filter`, `reduce`, `sortv`,
    `compare`, `index_by`, `range`, ...
  - `pl.class` — OOP with `class()` and `:extends()`.
  - `pl.Map`, `pl.Set`, `pl.List`, `pl.MultiMap`, `pl.OrderedMap` —
  container classes.
  - `pl.Date` — Date/time class (5.1 / LuaJIT safe).
  - `pl.config` — INI / classic Unix config file parser.
  - `pl.comprehension` — List comprehensions.
  - `pl.pretty` — Pretty-printing of tables + sandboxed table reader.
  - `pl.lexer` — Lexical scanner (used by `pretty` and `template`).
  - `pl.test` — Test assertion helpers.
  - `pl.app`, `pl.dir`, `pl.file`, `pl.path` — File system helpers
    (`pl.path` and `pl.dir` soft-depend on `lfs`; they degrade gracefully
    if `require 'lfs'` fails because LfW ships lfs but the xcom_lua runtime
    doesn't. → B for these three.)
  - `pl.lapp` — Human-readable command-line parser.
  - `pl.data`, `pl.seq`, `pl.permute`, `pl.comprehension`, `pl.array2d` —
  functional / array helpers.
  - `pl.text`, `pl.template` — Templating.
  - `pl.url` — URL quoting.
  - `pl.func` — Function composition / placeholders.
  - `pl.operator` — Operators as functions.
  - `pl.sip`, `pl.luabalanced` — Input parsing helpers.
  - `pl.types` — Type predicates (`is_callable`, `is_string`, ...).
  - `pl.compat` — 5.1/5.2 compatibility shim (gives `table.pack`,
    `package.searchpath`, etc.).
  - `pl.stringio` — String-as-file object.
  - `pl.init` — top-level entry; `require "pl"` injects everything into the
    global namespace (use with care; prefer `local utils = require "pl.utils"`).
  - `pl.import_into` — Helper for the injection above.
- `serialize.lua` — Lua-table → loadable source string serializer.
- `set.lua` — Set datatype (basic, no class).
- `std.lua` — Misc standard helpers.
- `strict.lua` — Warns on read of undeclared globals.
- `strictness.lua` — Stricter global checker.

### B — Moved but with caveats (搬但标注)

These either **mutate LuaJIT built-in tables** (`stdlib-ext/`) or
**depend on C modules not shipped with xcom_lua runtime**.

#### B1: `stdlib-ext/*.lua` — *MUTATES LuaJIT built-ins*

| File                  | After `require`, this affects...                       |
|-----------------------|--------------------------------------------------------|
| `string_ext.lua`      | adds methods/fields to `string` global (e.g. `string.split`, `string.print`) |
| `table_ext.lua`       | adds methods to `table` global (e.g. `table.deepcopy`, `table.compare`) |
| `math_ext.lua`        | patches `math.floor` to accept decimal places          |
| `io_ext.lua`          | adds helpers to `io` global                            |
| `package_ext.lua`     | adds named constants to `package` global               |

**Warning**: LuaJIT 2.1 already ships its own `string`, `table`, `math`,
`io`, `package` modules (in compiled bytecode). Requiring these `*_ext.lua`
files will *shadow / mutate the LuaJIT built-ins for the rest of the
process lifetime*. This is **incompatible with xcom_lua's draw hot path**
if the patches accidentally hit a name the existing code uses.

**Recommendation**: do **NOT** `require` these unless you have a very
specific need AND you have audited the patch surface. The xcom_lua codebase
already covers what most of these provide (`core/charset.lua`, the receive
ring buffer, etc.).

#### B2: `logging/email.lua`, `logging/socket.lua`, `logging/sql.lua`

Require LuaSocket / LuaSQL C libraries. Neither is in `xcom_lua/runtime/`.
**Will fail at `require "socket.smtp"` etc.**

#### B3: `penlight/pl/path.lua`, `penlight/pl/dir.lua`

Soft-depend on `lfs` (LuaFileSystem). LfW ships `lfs.dll`, but the
xcom_lua runtime at `xcom_lua/runtime/` does NOT include it. `pl.path` /
`pl.dir` will load (the `require 'lfs'` is wrapped in `pcall`); the
features that need lfs (`path.dir`, `path.mkdir`, ...) will raise at call
time. Read-only operations like `path.splitext`, `path.extension`,
`utils.isfile` (via `lfs.attributes`) degrade.

#### B4: `penlight/pl/dir.lua` copy/move on Windows

Uses `alien` or `ffi` for `CopyFile`/`MoveFile`. Neither is in the xcom_lua
runtime; copy/move will fall back to a temp-file shell hack.

### C — Not moved (不搬)

- C source / `.dll` / `.exe` / `.lib` files anywhere under `D:\develop\Lua\5.1`
  (Lua interpreter, LfW installers, all C module DLLs). These are out of scope.
- `lua/re.lua` (Roberto's LPEG regex wrapper) — needs `lpeg.dll`, not shipped.
- `lua/rex.lua` — needs `rex_pcre.dll`, not shipped.
- `lua/json/` (Thomas Harning's lpeg JSON) + `lua/json.lua` — needs `lpeg.dll`.
  The xcom_lua project already has its own minimal JSON encoder/decoder
  needs satisfied by LuaJIT's `string.format`/manual build; if more is
  wanted, porting `lua-cjson` (binary) or using `dkjson` (pure Lua) is the
  right next step, not LfW's lpeg JSON.
- `lua/md5.lua` — needs `md5.core` C module.
- `lua/LuaXml.lua`, `lua/xml.lua`, `lua/lxp/` — needs `LuaXML_lib.dll` /
  `lxp.dll` (expat).
- `lua/mime.lua`, `lua/ltn12.lua`, `lua/socket.lua`, `lua/socket/` — needs
  luasocket C library.
- `lua/copas.lua` — coroutine dispatcher over luasocket.
- `lua/lanes.lua` — needs `lua51-lanes.dll`.
- `lua/alien.lua` — needs `alien.core` C library.
- `lua/oil.lua`, `lua/oil/` — CORBA / RPC over alien.
- `lua/metalua/` — Metalua compiler (mix of `.lua`, `.mlua`, `.luac`,
  includes precompiled bytecode; not a runtime lib).
- `lua/metalua.luac` — precompiled metalua.
- `lua/luarocks/` — LuaRocks the package manager (heavy, requires luarocks
  bootstrap path). Out of scope.
- `lua/luadoc/` — LuaDoc doc generator. Heavy and tangential.
- `lua/loop/` — Loop UI component framework (Windows GUI). Not applicable.
- `lua/markdown.lua` — large but pure Lua; not high-value for a serial tool.
- `lua/delaunay.lua` — computational geometry; no project relevance.
- `lua/tar.lua` — tar archive reader; tangential.
- `lua/tree.lua` — tree helpers (depends on `list.lua`); not relevant.
- `lua/mbox.lua` — Unix mailbox parser; not relevant.
- `lua/fstable.lua` — depends on `io_ext` and `table_ext` plus rings C
  (`remotedostring`). Half C, half Lua; not usable.
- `lua/precompiler.lua`, `lua/preloader.lua`, `lua/ilua.lua`,
  `lua/idl2lua.lua`, `lua/CLRForm.lua`, `lua/CLRPackage.lua` — Windows COM /
  CLR / IDL tooling. Project does not need.
- `lua/debug_ext.lua` — patches built-in `debug`; combined with other
  `*_ext` warnings (B1), skip.
- `lua/posix_ext.lua` — requires `luaposix` C lib.
- `lua/unclasslib.lua` — duplicates `classlib.lua` semantics; redundant.
- `lua/bin.lua`, `lua/modules.lua` — tiny one-off glue.
- `lua/id2lua.lua` (no IDL parser) — idl2lua lives in luacom-style toolchains.

## Usage from xcom_lua

Add the `third_party/lua51-libs` tree to `package.path` so the standard
`require "penlight.pl.utils"` / `require "logging"` / `require "luaunit"`
names work without restructuring. Two patterns:

### Option 1 — flat path (LuaJIT default `?` resolution)

```lua
-- xcom_lua/main.lua (top)
package.path = table.concat({
    "third_party/lua51-libs/?.lua",
    "third_party/lua51-libs/?/init.lua",
    "third_party/lua51-libs/penlight/?.lua",
    "third_party/lua51-libs/penlight/?/init.lua",
    package.path,
}, ";")

-- then anywhere:
local utils     = require "pl.utils"            -- Penlight
local stringx   = require "pl.stringx"          -- Python-style strings
local tablex    = require "pl.tablex"           -- deep copy, merge, map, ...
local Config    = require "pl.config"           -- INI reader
local pretty    = require "pl.pretty"           -- pretty print
local logger    = require "logging"             -- LuaLogging
local LuaUnit   = require "luaunit"             -- test framework
local moses     = require "moses"                -- functional belt
```

Note that `pl.config` lives at `pl/config.lua`, but `require "pl.config"` will
fail unless `third_party/lua51-libs/penlight/?.lua` is on `package.path`
(Penlight expects to live under a `pl/` directory). The setup above handles
that.

### Option 2 — explicit sub-paths

If you prefer not to muck with `package.path`, address each subtree
explicitly:

```lua
local utils = require "penlight.pl.utils"
local logger = require "logging"
local LuaUnit = require "luaunit"
```

`logging/` does NOT have an `init.lua`, so `require "logging"` resolves to
`logging.lua` directly when `?/init.lua` is on the path.

### Do NOT require `stdlib-ext/*.lua` in xcom_lua

See warning B1. Don't.

## Update workflow

To re-sync from upstream:

```bash
# From repo root D:\workspace\SSCOM_lua
SRC="D:/develop/Lua/5.1/lua"
DST="D:/workspace/SSCOM_lua/third_party/lua51-libs"

# Penlight (39 modules, full dir)
cp -r "$SRC/pl/." "$DST/penlight/pl/"

# Logging (top + subdir)
cp "$SRC/logging.lua"            "$DST/logging.lua"
cp "$SRC/logging/console.lua"    "$DST/logging/console.lua"
cp "$SRC/logging/file.lua"       "$DST/logging/file.lua"
cp "$SRC/logging/rolling_file.lua" "$DST/logging/rolling_file.lua"
# Skip email/socket/sql unless luasocket/luasql become available
cp "$SRC/logging/email.lua"      "$DST/logging/email.lua"  # B
cp "$SRC/logging/socket.lua"     "$DST/logging/socket.lua" # B
cp "$SRC/logging/sql.lua"        "$DST/logging/sql.lua"    # B

# A-tier top-level files (16)
for f in 30log.lua base.lua binary_heap.lua classlib.lua getopt.lua \
         lcs.lua list.lua luaunit.lua moses.lua object.lua parser.lua \
         serialize.lua set.lua std.lua strict.lua strictness.lua; do
    cp "$SRC/$f" "$DST/$f"
done

# stdlib-ext B-tier (mutates built-ins)
for f in string_ext.lua table_ext.lua math_ext.lua io_ext.lua package_ext.lua; do
    cp "$SRC/$f" "$DST/stdlib-ext/$f"
done
```

Then re-run the smoke test (`xcom_lua/tests/test_lua51-libs.lua`) and confirm
`0 failed`. If the snapshot upstream added a new module, add it to this
README's A/B/C list manually.