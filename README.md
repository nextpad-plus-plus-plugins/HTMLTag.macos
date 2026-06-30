# HTML Tag — macOS port

macOS port of the **HTML Tag** plugin for Notepad++ (here: Nextpad++), originally
written by Martijn Coppoolse (vor0nwe) and maintained by Robert Di Pardo.

Upstream (Windows): <https://github.com/rdipardo/nppHTMLTag> (v1.5.6)

## Features

All commands appear under **Plugins ▸ HTML Tag**:

* **Find matching tag** — jump to the tag that pairs with the one at the caret.
* **Select matching tags** — select both the opening and closing tag (a multi-
  selection; edits/autocompletions stay in sync while it's active).
* **Select tag and contents** — select both tags plus everything between them.
* **Select tag contents only** — select just the content between the tags
  (whitespace at the ends trimmed).
* **Encode entities** / **Encode entities (incl. line breaks)** — convert the
  selected non-ASCII characters to HTML entities (`é` → `&eacute;`).
* **Decode entities** — convert HTML entities or GitHub emoji shortcodes back to
  characters. With nothing selected, place the caret just after the target text.
* **Encode / Decode Unicode characters** — `é` ⇆ `é` escape sequences.
* **Automatically decode entities / Unicode** (toggles) — decode as you type.
* **Auto-complete HTML entities** (toggle) — pop up an entity/emoji list after
  `&` or `:` in markup documents.

The entity tables (HTML 5, XML, Emoji) ship in `resources/HTMLTag-entities.ini`;
on first run a user-editable copy is placed in the plugin's config directory.

## Build

```sh
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
```

Produces a universal (`arm64;x86_64`) `HTMLTag.dylib`. `cmake --install build`
copies the dylib, the toolbar PNGs and the entities INI into the Nextpad++
plugins directory.

## Notes on the port

The tag-matching, entity and Unicode logic is ported faithfully from the Windows
source, which operates on the Scintilla buffer through a small object layer
(`SciActiveDocument` / `SciTextRange` / `SciSelection`).  That layer is
re-implemented here on top of `NppData._sendMessage`.  Document text is handled
as UTF-16 (`std::u16string`) internally — matching the original's surrogate-pair
arithmetic — and converted to/from the editor's UTF-8 buffer at the boundary.

Differences from the Windows build (cosmetic, not functional gaps):

* Menu titles are the English defaults; the `.ini`-based UI localization is not
  ported.
* The About box is a native AppKit panel.
* The "configure Unicode prefix" mini-dialog is not exposed; the default `\u`
  prefix is used (a `UNICODE_ESCAPE_PREFIX` in `options.ini` is still honored).

## License

Mozilla Public License v2.0 — see [`LICENSE`](LICENSE).
