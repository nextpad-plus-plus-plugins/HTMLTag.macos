// HTMLTag — macOS port
// Original Windows plugin: "HTML Tag" by Martijn Coppoolse (vor0nwe), maintained
// by Robert Di Pardo. Licensed under the Mozilla Public License v2.0.
// Upstream: https://github.com/rdipardo/nppHTMLTag  (v1.5.6)
//
// Provides HTML/XML tag matching & selection, HTML-entity and Unicode-escape
// encode/decode, GitHub-emoji shortcode decoding, plus optional "live" decoding
// and entity/emoji auto-completion as you type.
//
// Porting approach
// ----------------
// The Windows plugin operates on the Scintilla buffer through a small object
// layer (SciActiveDocument / SciTextRange / SciSelection, from its bundled
// "LibNppPlugin").  That layer talks to Scintilla ONLY via SendMessage, so the
// tag/entity/Unicode logic is platform-independent once SendMessage is routed
// through NppData._sendMessage.  This file re-implements that object layer and
// ports the four logic modules (TagFinder, Entities, Unicode, the live-decode
// dispatcher) as faithfully as possible.
//
// Critical detail — wide strings: the original keeps document text in
// std::wstring and does surrogate-pair arithmetic assuming wchar_t is 16-bit
// (true on Windows).  On macOS wchar_t is 32-bit, so this port uses
// std::u16string (UTF-16 code units) everywhere the original used wstring, and
// converts UTF-8 <-> UTF-16 at the Scintilla boundary (the macOS document code
// page is always UTF-8 / 65001).  All Scintilla positions are byte offsets, as
// on Windows, so the position arithmetic is unchanged.
//
// Simplifications vs. Windows (documented, not host limitations):
//   * Menu titles are the English defaults; the .ini-based UI localization and
//     the runtime menu-relabel-on-language-change are not ported.
//   * The About box is a native AppKit panel (the Win32 dialog template, dark-
//     mode subclassing and per-locale layout don't apply on macOS).
//   * The "configure Unicode prefix" mini-dialog is not exposed; the default
//     prefix "\u" is used (the options file is still honored if present).

#include "NppPluginInterfaceMac.h"
#include "Scintilla.h"
#import <Cocoa/Cocoa.h>

#include <dlfcn.h>
#include <cstdint>
#include <cstring>
#include <cctype>
#include <string>
#include <vector>
#include <map>
#include <list>
#include <memory>
#include <sstream>
#include <iomanip>
#include <algorithm>
#include <regex>
#include <fstream>

// ════════════════════════════════════════════════════════════════════════════
//  Windows LangType enum values (NPPM_GETCURRENTLANGTYPE returns these)
// ════════════════════════════════════════════════════════════════════════════
enum LangType {
    L_TEXT = 0, L_PHP, L_C, L_CPP, L_CS, L_OBJC, L_JAVA, L_RC,
    L_HTML, L_XML, L_MAKEFILE, L_PASCAL, L_BATCH, L_INI, L_NFO, L_USER,
    L_ASP, L_SQL, L_VB, L_JS_legacy, L_CSS, L_PERL, L_PYTHON, L_LUA,
    L_TEX, L_FORTRAN, L_BASH, L_FLASH, L_NSIS, L_TCL, L_LISP, L_SCHEME,
    L_ASM, L_DIFF, L_PROPS, L_PS, L_RUBY, L_SMALLTALK, L_VHDL, L_KIX,
    L_AU3, L_CAML, L_ADA, L_VERILOG, L_MATLAB, L_HASKELL, L_INNO, L_SEARCHRESULT,
    L_CMAKE, L_YAML, L_COBOL, L_GUI4CLI, L_D, L_POWERSHELL, L_R, L_JSP,
    L_COFFEESCRIPT, L_JSON, L_JAVASCRIPT, L_FORTRAN_77, L_BAANC, L_SREC, L_IHEX, L_TEHEX,
    L_SWIFT, L_ASN1, L_AVS, L_BLITZBASIC, L_PUREBASIC, L_FREEBASIC, L_CSOUND, L_ERLANG,
    L_ESCRIPT, L_FORTH, L_LATEX, L_MMIXAL, L_NIM, L_NNCRONTAB, L_OSCRIPT, L_REBOL,
    L_REGISTRY, L_RUST, L_SPICE, L_TXT2TAGS, L_VISUALPROLOG, L_TYPESCRIPT, L_GDSCRIPT, L_HOLLYWOOD,
    L_GOLANG, L_RAKU, L_TOML, L_SAS, L_ERR, L_EXTERNAL
};

// ════════════════════════════════════════════════════════════════════════════
//  Globals & platform plumbing
// ════════════════════════════════════════════════════════════════════════════
static const char *PLUGIN_NAME = "HTML Tag";

namespace {

NppData nppData;

// ── UTF-8 <-> UTF-16 (replaces TextConv::bytesToText / textToBytes) ──────────
std::u16string utf8to16(const char *src, size_t len) {
    std::u16string out;
    if (!src) return out;
    out.reserve(len);
    size_t i = 0;
    while (i < len) {
        unsigned char c = (unsigned char)src[i];
        uint32_t cp; size_t n;
        if (c < 0x80)      { cp = c;            n = 1; }
        else if ((c >> 5) == 0x6)  { cp = c & 0x1F; n = 2; }
        else if ((c >> 4) == 0xE)  { cp = c & 0x0F; n = 3; }
        else if ((c >> 3) == 0x1E) { cp = c & 0x07; n = 4; }
        else { ++i; out.push_back(0xFFFD); continue; }   // invalid lead
        if (i + n > len) { out.push_back(0xFFFD); break; }
        bool ok = true;
        for (size_t k = 1; k < n; ++k) {
            unsigned char cc = (unsigned char)src[i + k];
            if ((cc & 0xC0) != 0x80) { ok = false; break; }
            cp = (cp << 6) | (cc & 0x3F);
        }
        if (!ok) { ++i; out.push_back(0xFFFD); continue; }
        i += n;
        if (cp <= 0xFFFF) {
            out.push_back((char16_t)cp);
        } else {
            cp -= 0x10000;
            out.push_back((char16_t)(0xD800 + (cp >> 10)));
            out.push_back((char16_t)(0xDC00 + (cp & 0x3FF)));
        }
    }
    return out;
}
std::u16string utf8to16(const std::string &s) { return utf8to16(s.data(), s.size()); }

std::string utf16to8(const char16_t *src, size_t len) {
    std::string out;
    if (!src) return out;
    out.reserve(len);
    for (size_t i = 0; i < len; ++i) {
        uint32_t cp = src[i];
        if (cp >= 0xD800 && cp <= 0xDBFF && i + 1 < len) {
            uint32_t lo = src[i + 1];
            if (lo >= 0xDC00 && lo <= 0xDFFF) {
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                ++i;
            }
        }
        if (cp < 0x80) {
            out.push_back((char)cp);
        } else if (cp < 0x800) {
            out.push_back((char)(0xC0 | (cp >> 6)));
            out.push_back((char)(0x80 | (cp & 0x3F)));
        } else if (cp < 0x10000) {
            out.push_back((char)(0xE0 | (cp >> 12)));
            out.push_back((char)(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back((char)(0x80 | (cp & 0x3F)));
        } else {
            out.push_back((char)(0xF0 | (cp >> 18)));
            out.push_back((char)(0x80 | ((cp >> 12) & 0x3F)));
            out.push_back((char)(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back((char)(0x80 | (cp & 0x3F)));
        }
    }
    return out;
}
std::string utf16to8(const std::u16string &s) { return utf16to8(s.data(), s.size()); }

// Format an unsigned value as a u16 string. base 10 or 16; minWidth zero-pads;
// uppercase hex.  (libc++ has no numpunct<char16_t>, so char16_t streams fail.)
std::u16string u16FromUInt(uint32_t v, int base = 10, int minWidth = 0) {
    static const char *digs = "0123456789ABCDEF";
    std::u16string s;
    if (v == 0) s = u"0";
    while (v) { s.insert(s.begin(), (char16_t)digs[v % base]); v /= base; }
    while ((int)s.size() < minWidth) s.insert(s.begin(), u'0');
    return s;
}

// Pascal-style 1-based find (TextConv::pos)
size_t posU16(const char16_t *sub, const std::u16string &str, size_t off = 0) {
    size_t r = str.find(sub, off);
    return (r == std::u16string::npos) ? 0 : r + 1;
}
bool sameTextU8(std::string a, std::string b) {
    auto lc = [](unsigned char c){ return (char)std::tolower(c); };
    std::transform(a.begin(), a.end(), a.begin(), lc);
    std::transform(b.begin(), b.end(), b.begin(), lc);
    return a == b;
}

std::string resourceDir() {
    Dl_info info;
    if (dladdr((const void *)&resourceDir, &info) && info.dli_fname) {
        std::string p(info.dli_fname);
        size_t s = p.find_last_of('/');
        return (s == std::string::npos ? std::string(".") : p.substr(0, s)) + "/resources";
    }
    return "resources";
}

} // namespace

// ════════════════════════════════════════════════════════════════════════════
//  Scintilla object layer (port of LibNppPlugin/SciTextObjects)
// ════════════════════════════════════════════════════════════════════════════
namespace SciTextObjects {

enum SelectionMode : unsigned {
    smStreamSingle = SC_SEL_STREAM, smColumn, smLines, smThin, smStreamMulti
};
constexpr unsigned multiselectionMask = 0x4;

class SciTextRange;
class SciSelection;

// ── current Scintilla handle ─────────────────────────────────────────────────
static NppHandle currentSci() {
    int which = -1;
    nppData._sendMessage(nppData._nppHandle, NPPM_GETCURRENTSCINTILLA, 0, (intptr_t)&which);
    return (which == 1) ? nppData._scintillaSecondHandle : nppData._scintillaMainHandle;
}

// --------------------------------------------------------------------------------------
// SciActiveDocument
// --------------------------------------------------------------------------------------
class SciActiveDocument {
public:
    explicit SciActiveDocument(NppHandle h) : _sci(h) {}

    intptr_t sendMessage(uint32_t msg, uintptr_t w = 0, intptr_t l = 0) const {
        return nppData._sendMessage(_sci, msg, w, l);
    }
    NppHandle handle() const { return _sci; }

    SelectionMode getSelectionMode() const {
        intptr_t mode = sendMessage(SCI_GETSELECTIONMODE);
        if (mode == SC_SEL_STREAM && sendMessage(SCI_GETSELECTIONS) > 1)
            mode |= multiselectionMask;
        return static_cast<SelectionMode>(mode);
    }
    void select(Sci_Position start = 0, Sci_Position length = INVALID_POSITION) const {
        const SelectionMode mode = static_cast<SelectionMode>(getSelectionMode() & ~multiselectionMask);
        if (mode != smStreamSingle) sendMessage(SCI_SETSELECTIONMODE, SC_SEL_STREAM);
        sendMessage(SCI_SETSEL, (uintptr_t)start, (intptr_t)(start + length));
        if (mode != smStreamSingle) sendMessage(SCI_SETSELECTIONMODE, (uintptr_t)mode);
    }
    void find(const std::u16string &text, SciTextRange &target, int options = 0,
              Sci_Position startPos = INVALID_POSITION, Sci_Position endPos = INVALID_POSITION) const;

    SciSelection &currentSelection() const { return *_selection; }
    Sci_Position currentPosition() const { return (Sci_Position)sendMessage(SCI_GETCURRENTPOS); }
    Sci_Position currentPosition(Sci_Position value) const {
        sendMessage(SCI_SETANCHOR, (uintptr_t)value);
        return (sendMessage(SCI_SETCURRENTPOS, (uintptr_t)value) == 0) ? value : INVALID_POSITION;
    }
    Sci_Position nextLineStartPosition() const {
        Sci_Position lineEnd = (Sci_Position)sendMessage(SCI_GETLINEENDPOSITION,
                                  (uintptr_t)sendMessage(SCI_LINEFROMPOSITION, (uintptr_t)currentPosition()));
        return (Sci_Position)sendMessage(SCI_POSITIONAFTER, (uintptr_t)lineEnd);
    }
    Sci_Position length() const { return (Sci_Position)sendMessage(SCI_GETLENGTH); }

    // Selection object is created lazily after construction (needs *this).
    void attachSelection();

private:
    NppHandle _sci;
    std::shared_ptr<SciSelection> _selection;
};

// --------------------------------------------------------------------------------------
// SciTextRange
// --------------------------------------------------------------------------------------
class SciTextRange {
public:
    explicit SciTextRange(const SciActiveDocument &ed, Sci_Position s = 0, Sci_Position e = 0)
        : _editor(ed), _startPos(s), _endPos(e) {}
    virtual ~SciTextRange() = default;

    virtual Sci_Position startPos(Sci_Position v) { setStart(v); return _startPos; }
    virtual Sci_Position startPos() const { return getStart(); }
    virtual Sci_Position endPos(Sci_Position v) { setEnd(v); return _endPos; }
    virtual Sci_Position endPos() const { return getEnd(); }
    virtual Sci_Position length() const { return getLength(); }
    virtual std::u16string text();

    SciTextRange &operator=(const SciTextRange &o) {
        setStart(o.getStart()); setEnd(o.getEnd()); return *this;
    }
    virtual SciTextRange &operator=(const std::u16string &v) { setText(v); return *this; }
    virtual explicit operator bool() const { return getLength() > 0; }

    void select();
    void clearRange();
    void clearSelection();
    void mark(int style, unsigned timeoutMSecs = 0);
    const SciActiveDocument &editor() const { return _editor; }

protected:
    SciActiveDocument _editor;
    std::u16string _text;
    Sci_Position _startPos = 0;
    Sci_Position _endPos = 0;

    Sci_Position getAnchor() const { return (Sci_Position)_editor.sendMessage(SCI_GETANCHOR); }
    void setAnchor(Sci_Position v) { _editor.sendMessage(SCI_SETANCHOR, (uintptr_t)v); }
    virtual Sci_Position getStart() const { return _startPos; }
    virtual void setStart(Sci_Position v) { _startPos = (v <= INVALID_POSITION) ? 0 : v; }
    virtual Sci_Position getEnd() const { return (_endPos <= INVALID_POSITION) ? getLength() : _endPos; }
    virtual void setEnd(Sci_Position v) {
        _endPos = (v <= INVALID_POSITION) ? (Sci_Position)_editor.sendMessage(SCI_GETLENGTH) : v;
    }
    virtual Sci_Position getLength() const { return std::abs(_endPos - _startPos); }
    virtual void setText(const std::u16string &v);
};

// --------------------------------------------------------------------------------------
// SciSelection
// --------------------------------------------------------------------------------------
class SciSelection final : public SciTextRange {
public:
    explicit SciSelection(const SciActiveDocument &ed) : SciTextRange(ed) {}

    Sci_Position startPos(Sci_Position v) override { setStart(v); return getStart(); }
    Sci_Position startPos() const override { return getStart(); }
    Sci_Position endPos() const override { return getEnd(); }
    Sci_Position length() const override { return getLength(); }
    std::u16string text() override;

    SciSelection &operator=(const std::u16string &v) override { setText(v); return *this; }
    explicit operator bool() const override { return getLength() > 0; }

private:
    Sci_Position getCurrentPos() const { return (Sci_Position)_editor.sendMessage(SCI_GETCURRENTPOS); }
    Sci_Position getStart() const override { return (Sci_Position)_editor.sendMessage(SCI_GETSELECTIONSTART); }
    Sci_Position getEnd() const override { return (Sci_Position)_editor.sendMessage(SCI_GETSELECTIONEND); }
    Sci_Position getLength() const override { return std::abs(getEnd() - getStart()); }
    void setStart(Sci_Position v) override { _editor.sendMessage(SCI_SETSELECTIONSTART, (uintptr_t)v); }
    void setEnd(Sci_Position v) override { _editor.sendMessage(SCI_SETSELECTIONEND, (uintptr_t)v); }
    void setText(const std::u16string &v) override;
};

// --------------------------------------------------------------------------------------
// SciTextRangeMark — timed style highlight (port w/ NSTimer instead of Win32 SetTimer)
// --------------------------------------------------------------------------------------
class SciTextRangeMark {
public:
    SciTextRangeMark(SciTextRange &range, unsigned timeoutMSecs);
private:
    SciActiveDocument _editor;
    Sci_Position _startPos, _endPos;
};
static std::vector<std::shared_ptr<SciTextRangeMark>> g_textRangeMarks;

// ── SciActiveDocument out-of-line ────────────────────────────────────────────
void SciActiveDocument::attachSelection() {
    _selection = std::make_shared<SciSelection>(*this);
}

void SciActiveDocument::find(const std::u16string &text, SciTextRange &target, int options,
                             Sci_Position startPos, Sci_Position endPos) const {
    Sci_TextToFindFull ttf = Sci_TextToFindFull{};
    ttf.chrg.cpMin = (startPos < 0) ? 0 : startPos;
    ttf.chrg.cpMax = (endPos < 0) ? INTPTR_MAX : endPos;
    std::string needle = utf16to8(text);
    ttf.lpstrText = needle.c_str();
    ttf.chrgText = ttf.chrg;
    intptr_t r = sendMessage(SCI_FINDTEXTFULL, (uintptr_t)options, (intptr_t)&ttf);
    if (r == INVALID_POSITION) { target.startPos(0); target.endPos(0); }
    else { target.startPos(ttf.chrgText.cpMin); target.endPos(ttf.chrgText.cpMax); }
}

// ── SciTextRange out-of-line ─────────────────────────────────────────────────
std::u16string SciTextRange::text() {
    if (getLength() <= 0) return _text;
    Sci_TextRangeFull tr = Sci_TextRangeFull{};
    std::string buf(getLength() + 1, '\0');
    tr.chrg.cpMin = _startPos;
    tr.chrg.cpMax = _endPos;
    tr.lpstrText = &buf[0];
    _editor.sendMessage(SCI_GETTEXTRANGEFULL, 0, (intptr_t)&tr);
    _text = utf8to16(tr.lpstrText, std::strlen(tr.lpstrText));
    return _text;
}

void SciTextRange::setText(const std::u16string &value) {
    std::string chars = utf16to8(value);
    Sci_Position txtRng = (Sci_Position)chars.size();
    _editor.sendMessage(SCI_SETTARGETSTART, (uintptr_t)_startPos);
    _editor.sendMessage(SCI_SETTARGETEND, (uintptr_t)_endPos);
    Sci_Position nReplaced = (Sci_Position)_editor.sendMessage(SCI_REPLACETARGETMINIMAL,
                                                               (uintptr_t)txtRng, (intptr_t)chars.c_str());
    _startPos += nReplaced;
}

void SciTextRange::select() {
    _editor.sendMessage(SCI_SETSELECTION, (uintptr_t)_endPos, (intptr_t)_startPos);
    _editor.sendMessage(SCI_SCROLLCARET);
}
void SciTextRange::clearRange() { _startPos = 0; _endPos = 0; _text.clear(); }
void SciTextRange::clearSelection() { setAnchor(_editor.currentPosition()); _text.clear(); }

void SciTextRange::mark(int style, unsigned durationInMs) {
    Sci_Position currentStyleEnd = (Sci_Position)_editor.sendMessage(SCI_GETENDSTYLED);
    _editor.sendMessage(SCI_STARTSTYLING, (uintptr_t)_startPos);
    _editor.sendMessage(SCI_SETSTYLING, (uintptr_t)getLength(), (intptr_t)style);
    _editor.sendMessage(SCI_STARTSTYLING, (uintptr_t)currentStyleEnd);
    if (durationInMs > 0)
        g_textRangeMarks.push_back(std::make_shared<SciTextRangeMark>(*this, durationInMs));
}

// ── SciSelection out-of-line ─────────────────────────────────────────────────
std::u16string SciSelection::text() {
    intptr_t lenSel = _editor.sendMessage(SCI_GETSELTEXT, 0, 0);
    lenSel++;  // modern API: returns length excluding NUL
    if (lenSel <= 0) { _text.clear(); return _text; }
    std::string buf(lenSel, '\0');
    _editor.sendMessage(SCI_GETSELTEXT, 0, (intptr_t)&buf[0]);
    _text = utf8to16(buf.data(), std::strlen(buf.data()));
    return _text;
}

void SciSelection::setText(const std::u16string &value) {
    std::string chars = utf16to8(value);
    Sci_Position lenNew = (Sci_Position)chars.size();
    bool reversed = (getAnchor() > getCurrentPos());
    _editor.sendMessage(SCI_REPLACESEL, 0, (intptr_t)chars.c_str());
    Sci_Position endPos = getCurrentPos();
    if (reversed) _editor.sendMessage(SCI_SETSEL, (uintptr_t)endPos, (intptr_t)(endPos - lenNew));
    else _editor.sendMessage(SCI_SETSEL, (uintptr_t)(endPos - lenNew), (intptr_t)endPos);
}

// ── SciTextRangeMark — clear styling after a delay ───────────────────────────
SciTextRangeMark::SciTextRangeMark(SciTextRange &range, unsigned durationInMS)
    : _editor(range.editor()), _startPos(range.startPos()), _endPos(range.endPos()) {
    SciActiveDocument ed = _editor;
    Sci_Position startPos = _startPos;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)durationInMS * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        Sci_Position currentStyleEnd = (Sci_Position)ed.sendMessage(SCI_GETENDSTYLED);
        if (startPos < currentStyleEnd) currentStyleEnd = startPos;
        ed.sendMessage(SCI_STARTSTYLING, (uintptr_t)currentStyleEnd);
        if (!g_textRangeMarks.empty()) g_textRangeMarks.erase(g_textRangeMarks.begin());
    });
}

} // namespace SciTextObjects

using namespace SciTextObjects;

// ════════════════════════════════════════════════════════════════════════════
//  Plugin state (entities, options, the "active document" accessor)
// ════════════════════════════════════════════════════════════════════════════
namespace HtmlTag {

constexpr unsigned soNone = 0x1, soTags = 0x2, soContents = 0x4;

constexpr char amp = '&', semi = ';', colon = ':';
constexpr const char16_t scDigits[] = u"0123456789";
constexpr const char16_t scHexLetters[] = u"ABCDEFabcdef";
constexpr const char16_t scLetters[] = u"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

constexpr const char *defaultUnicodePrefix = "\\u";

struct PluginOptions {
    bool liveEntityDecoding = false;
    bool liveUnicodeDecoding = false;
    bool entityAutoCompletion = true;
    std::string unicodePrefix;
    std::string unicodeRE;
};

// entity name -> codePoint string (and, for non-emoji, codePoint -> name)
typedef std::map<std::string, std::string> EntityList;

struct State {
    PluginOptions options;
    std::map<std::string, EntityList> entityMap;   // "HTML 5" / "XML" / "Emoji"
    std::string optionsConfigPath;
    std::string entitiesPath;
} g;

SciActiveDocument activeDocument() {
    SciActiveDocument doc(currentSci());
    doc.attachSelection();
    return doc;
}

LangType documentLangType() {
    int t = 0;
    nppData._sendMessage(nppData._nppHandle, NPPM_GETCURRENTLANGTYPE, 0, (intptr_t)&t);
    return static_cast<LangType>(t);
}

bool isDarkModeEnabled() {
    return nppData._sendMessage(nppData._nppHandle, NPPM_ISDARKMODEENABLED, 0, 0) == 1;
}

// ── load entities INI (HTML 5 / XML / Emoji) on demand ──────────────────────
void loadEntities(EntityList &list, bool preferEmoji) {
    const char *listName = (documentLangType() == L_XML) ? "XML" : (preferEmoji ? "Emoji" : "HTML 5");
    auto it = g.entityMap.find(listName);
    if (it != g.entityMap.end() && !it->second.empty()) { list = it->second; return; }

    std::ifstream ifs(g.entitiesPath, std::ios::in | std::ios::binary);
    if (!ifs) return;

    EntityList &dst = g.entityMap[listName];
    std::string line, section;
    while (std::getline(ifs, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        size_t b = line.find_first_not_of(" \t");
        if (b == std::string::npos) continue;
        if (line[b] == ';') continue;                         // comment
        if (line[b] == '[') {                                  // section header
            size_t e = line.find(']', b);
            section = (e != std::string::npos) ? line.substr(b + 1, e - b - 1) : "";
            continue;
        }
        if (section != listName) continue;
        size_t eq = line.find('=');
        if (eq == std::string::npos) continue;
        std::string key = line.substr(0, eq);
        // trim trailing ws / inline comment from value
        std::string val = line.substr(eq + 1);
        size_t vc = val.find_first_of(";");
        if (vc != std::string::npos) val = val.substr(0, vc);
        size_t ve = val.find_last_not_of(" \t");
        if (ve == std::string::npos) continue;
        val = val.substr(0, ve + 1);
        // trim key
        size_t ke = key.find_last_not_of(" \t");
        if (ke == std::string::npos) continue;
        key = key.substr(0, ke + 1);
        int codePoint = 0;
        try { codePoint = std::stoi(val); } catch (...) { continue; }
        if (codePoint <= 0) continue;
        dst[key] = std::to_string(codePoint);
        if (!preferEmoji)
            dst.emplace(std::to_string(codePoint), key);  // reverse map (first wins)
    }
    list = dst;
}

// ── options load/save ────────────────────────────────────────────────────────
void setUnicodeFormatOption(const std::string &userPrefix) {
    if (!userPrefix.empty()) {
        std::string reStr = std::regex_replace(userPrefix, std::regex(R"([\.*+?^${}()[\]|])"), R"(\$&)");
        reStr = std::regex_replace(reStr, std::regex(R"(\\[[:alpha:]])"), R"(\\$&)");
        reStr += R"(((00[7-9A-F][0-9A-F])|[0-9A-F]{6}|[1-9A-F]?[0-9A-F]{4}))";
        g.options.unicodePrefix = userPrefix;
        g.options.unicodeRE = reStr;
    } else if (g.options.unicodePrefix.empty()) {
        setUnicodeFormatOption(defaultUnicodePrefix);
    }
}

void loadOptions() {
    std::ifstream ifs(g.optionsConfigPath, std::ios::in | std::ios::binary);
    std::string userPrefix = defaultUnicodePrefix;
    if (ifs) {
        std::string line, section;
        auto boolVal = [](std::string v){
            size_t a = v.find_first_not_of(" \t"); if (a==std::string::npos) return false;
            size_t b = v.find_last_not_of(" \t"); v = v.substr(a, b-a+1);
            return v=="1"||sameTextU8(v,"true")||sameTextU8(v,"yes");
        };
        while (std::getline(ifs, line)) {
            if (!line.empty() && line.back()=='\r') line.pop_back();
            size_t b = line.find_first_not_of(" \t");
            if (b==std::string::npos || line[b]==';') continue;
            if (line[b]=='[') { size_t e=line.find(']',b); section=(e!=std::string::npos)?line.substr(b+1,e-b-1):""; continue; }
            size_t eq=line.find('='); if (eq==std::string::npos) continue;
            std::string key=line.substr(0,eq), val=line.substr(eq+1);
            size_t ke=key.find_last_not_of(" \t"); if(ke!=std::string::npos) key=key.substr(0,ke+1);
            if (section=="AUTO_DECODE" && key=="ENTITIES") g.options.liveEntityDecoding=boolVal(val);
            else if (section=="AUTO_DECODE" && key=="UNICODE_ESCAPE_CHARS") g.options.liveUnicodeDecoding=boolVal(val);
            else if (section=="AUTO_COMPLETE" && key=="ENTITIES") g.options.entityAutoCompletion=boolVal(val);
            else if (section=="FORMAT" && key=="UNICODE_ESCAPE_PREFIX") {
                size_t a=val.find_first_not_of(" \t"); size_t z=val.find_last_not_of(" \t");
                if (a!=std::string::npos) userPrefix=val.substr(a,z-a+1);
            }
        }
    }
    setUnicodeFormatOption(userPrefix);
}

void saveOptions() {
    std::ofstream ofs(g.optionsConfigPath, std::ios::out | std::ios::binary);
    if (!ofs) return;
    ofs << "[AUTO_DECODE]\n";
    ofs << "ENTITIES=" << (g.options.liveEntityDecoding ? 1 : 0) << "\n";
    ofs << "UNICODE_ESCAPE_CHARS=" << (g.options.liveUnicodeDecoding ? 1 : 0) << "\n";
    ofs << "[AUTO_COMPLETE]\n";
    ofs << "ENTITIES=" << (g.options.entityAutoCompletion ? 1 : 0) << "\n";
    ofs << "[FORMAT]\n";
    ofs << "UNICODE_ESCAPE_PREFIX=" << g.options.unicodePrefix << "\n";
}

// ════════════════════════════════════════════════════════════════════════════
//  Entities encode/decode  (port of Entities.cpp)
// ════════════════════════════════════════════════════════════════════════════
namespace Entities {

int doEncode(std::u16string &text, const EntityList &entities, bool includeLineBreaks) {
    int result = 0;
    SciActiveDocument doc = activeDocument();
    if (entities.empty() || doc.getSelectionMode() != smStreamSingle) return result;

    std::u16string encodedEntity;
    bool didReplace = false;
    try {
        for (std::ptrdiff_t chIndex = (std::ptrdiff_t)text.size() - 1; chIndex >= 0; chIndex--) {
            size_t startPos = chIndex, endPos = chIndex + 1;
            uint32_t charCode = text[chIndex];
            auto eit = entities.find(std::to_string(charCode));
            if (eit != entities.end() && !eit->second.empty()) {
                didReplace = true;
                encodedEntity = utf8to16(eit->second);
            } else if (charCode > 127 || (includeLineBreaks && (charCode == u'\n' || charCode == u'\r'))) {
                const size_t chPrevIndex = (size_t)std::max((std::ptrdiff_t)0, chIndex - 1);
                const uint32_t chPrevCode = text[chPrevIndex];
                if (chPrevCode >= 0xD800 && chPrevCode <= 0xDBFF) {
                    charCode = ((chPrevCode & 0x03FFU) << 10) | (charCode & 0x03FFU) | 0x10000U;
                    encodedEntity = u"#x" + u16FromUInt(charCode, 16, 6);
                    startPos = chPrevIndex;
                    chIndex--;
                } else {
                    encodedEntity = u"#" + u16FromUInt(charCode, 10, 0);
                }
                didReplace = true;
            } else {
                didReplace = false;
            }

            if (didReplace) {
                text.replace(startPos, endPos - startPos, u"&" + encodedEntity + u";");
                ++result;
            }
            if (chIndex >= (std::ptrdiff_t)text.size()) break;
        }
    } catch (...) {}
    return result;
}

void encode(bool includeLineBreaks = false) {
    EntityList entities;
    loadEntities(entities, false);
    SciActiveDocument doc = activeDocument();
    std::u16string text = doc.currentSelection().text();
    if (doEncode(text, entities, includeLineBreaks) > 0) {
        doc.currentSelection() = text;
        doc.currentSelection().clearSelection();
    }
}

int decode() {
    int result = 0;
    SciActiveDocument doc = activeDocument();
    if (doc.getSelectionMode() != smStreamSingle) return result;

    char16_t chStart = amp, chEnd = semi, chInvalid = colon;
    std::u16string target = doc.currentSelection().text();
    size_t charIndex = target.find(chStart);
    if (charIndex == std::u16string::npos) {
        chStart = colon;
        charIndex = target.find(chStart);
        if (charIndex != std::u16string::npos) { chInvalid = semi; chEnd = chStart; }
        else return result;
    }

    size_t endPos = target.find(chEnd, charIndex);
    if ((endPos == std::u16string::npos) || (target.find(chInvalid, charIndex) < endPos))
        return result;

    EntityList entities;
    bool preferEmoji = (chStart == (char16_t)colon);
    loadEntities(entities, preferEmoji);

    try {
        while (charIndex != std::u16string::npos) {
            size_t firstPos = charIndex + 1;
            size_t lastPos = firstPos;
            size_t nextIndex = target.length() + 1;
            bool isNumeric = false, isHex = false;
            std::u16string allowedChars;

            for (size_t i = 1; i < target.length() - firstPos; i++) {
                if (i == 1) {
                    if (!preferEmoji && target[firstPos] == u'#') {
                        isNumeric = true;
                        allowedChars += u"x"; allowedChars += scDigits;
                    } else {
                        allowedChars += scLetters; allowedChars += scDigits;
                        if (preferEmoji) allowedChars += u"+_-";
                    }
                } else if (i == 2) {
                    if (isNumeric && target[firstPos + 1] == u'x') { isHex = true; allowedChars += scHexLetters; }
                    allowedChars += chEnd;
                }
                if (allowedChars.find(target[firstPos + i]) == std::u16string::npos) {
                    lastPos = firstPos + i - 1; nextIndex = firstPos + i; break;
                } else if (target[firstPos + i] == chEnd) {
                    lastPos = firstPos + i - 1; nextIndex = firstPos + i + 1; break;
                }
            }

            int codePoint = 0;
            bool isValid = false;
            if (isNumeric) {
                if (isHex) {
                    std::u16string hexStr = target.substr(firstPos + 2, lastPos - firstPos - 1);
                    codePoint = std::stoi(utf16to8(hexStr), nullptr, 16); isValid = (codePoint != 0);
                } else {
                    std::u16string numStr = target.substr(firstPos + 1, lastPos - firstPos);
                    codePoint = std::stoi(utf16to8(numStr)); isValid = (codePoint != 0);
                }
            } else {
                std::u16string entityCode = target.substr(firstPos, lastPos - firstPos + 1);
                std::string entityCodeStr = utf16to8(entityCode);
                auto eit = entities.find(entityCodeStr);
                if (eit != entities.end() && !eit->second.empty()) {
                    codePoint = std::stoi(eit->second); isValid = (codePoint != 0);
                }
            }

            if (isValid) {
                std::u16string decoded(2, u'\0');
                if (codePoint >= 0x010000 && codePoint <= 0x10FFFF) {
                    decoded[0] = (char16_t)(((codePoint - 0x10000) >> 10) + 0xD800);
                    decoded[1] = (char16_t)(((codePoint - 0x10000) & 0x03FF) + 0xDC00);
                } else {
                    decoded.resize(1);
                    decoded[0] = (char16_t)codePoint;
                }
                target.replace(firstPos - 1, std::u16string::npos, decoded + target.substr(nextIndex));
                ++result;
            }
            charIndex = target.find(chStart, firstPos);
        }
    } catch (...) {}

    if (result > 0) {
        doc.currentSelection() = target;
        doc.currentSelection().clearSelection();
    }
    return result;
}

} // namespace Entities

// ════════════════════════════════════════════════════════════════════════════
//  Unicode escape encode/decode  (port of Unicode.cpp)
// ════════════════════════════════════════════════════════════════════════════
namespace Unicode {

int doEncode(std::u16string &text, bool multiSel) {
    int result = 0;
    if (multiSel) return result;
    std::u16string prefix = utf8to16(g.options.unicodePrefix);

    for (std::ptrdiff_t chIndex = (std::ptrdiff_t)text.size() - 1; chIndex >= 0; chIndex--) {
        uint32_t charCode = text[chIndex];
        if (charCode > 127) {
            int nDigits = 4;
            size_t startPos = chIndex, endPos = chIndex + 1;
            const size_t chPrevIndex = (size_t)std::max((std::ptrdiff_t)0, chIndex - 1);
            const uint32_t chPrevCode = text[chPrevIndex];
            if (chPrevCode >= 0xD800 && chPrevCode <= 0xDBFF) {
                charCode = ((chPrevCode & 0x03FFU) << 10) | (charCode & 0x03FFU) | 0x10000U;
                startPos = chPrevIndex; nDigits = 6; chIndex--;
            }
            text = text.substr(0, startPos) + prefix + u16FromUInt(charCode, 16, nDigits) + text.substr(endPos);
            ++result;
            if (chIndex >= (std::ptrdiff_t)text.size()) break;
        }
    }
    return result;
}

void encode() {
    SciActiveDocument doc = activeDocument();
    std::u16string targetText = doc.currentSelection().text();
    bool multiSel = (doc.getSelectionMode() != smStreamSingle);
    if (doEncode(targetText, multiSel) > 0) {
        doc.currentSelection() = targetText;
        doc.currentSelection().clearSelection();
    }
}

int decode() {
    int result = 0;
    SciActiveDocument doc = activeDocument();
    if (doc.getSelectionMode() != smStreamSingle) return result;

    Sci_Position lenPrefix = (Sci_Position)g.options.unicodePrefix.size();
    std::u16string pattern = utf8to16(g.options.unicodeRE);
    SciTextRange target(doc, doc.currentSelection().startPos(), doc.currentSelection().endPos());
    SciTextRange match(doc);
    std::u16string mbCharBuf(3, u'\0');

    doc.sendMessage(SCI_BEGINUNDOACTION);
    try {
        do {
            doc.find(pattern, match, SCFIND_REGEXP, target.startPos(), target.endPos());
            if (match.length() != 0) {
                target.startPos(match.startPos() + 1);
                int head = 0, tail = 0;
                head = std::stoi(utf16to8(match.text().substr(lenPrefix, 6)), nullptr, 16);
                if (head >= 0x010000 && head <= 0x10FFFF) {
                    tail = ((head - 0x10000) & 0x03FF) + 0xDC00;
                    head = ((head - 0x10000) >> 10) + 0xD800;
                    mbCharBuf[0] = (char16_t)head; mbCharBuf[1] = (char16_t)tail;
                    mbCharBuf.resize(2);
                    match = mbCharBuf;
                    mbCharBuf.resize(3, u'\0');
                } else if (head >= 0xD800 && head <= 0xDBFF) {
                    SciTextRange matchNext(doc);
                    doc.find(pattern, matchNext, SCFIND_REGEXP, match.endPos() - lenPrefix, target.endPos());
                    if (matchNext.length() != 0) {
                        tail = std::stoi(utf16to8(matchNext.text().substr(lenPrefix, 4)), nullptr, 16);
                        if (tail > 0 && tail < UINT16_MAX) {
                            mbCharBuf[0] = (char16_t)head; mbCharBuf[1] = (char16_t)tail;
                            matchNext = std::u16string();
                            mbCharBuf.resize(2);
                            match = mbCharBuf;
                            mbCharBuf.resize(3, u'\0');
                            if (result < 1) doc.currentSelection().startPos(match.startPos());
                        }
                    }
                } else {
                    mbCharBuf[0] = (char16_t)head; mbCharBuf[1] = 0;
                    mbCharBuf.resize(1);
                    match = mbCharBuf;
                    mbCharBuf.resize(3, u'\0');
                }
                if (result < 1) doc.currentSelection().startPos(match.startPos());
                ++result;
            }
        } while (match.length() != 0);
    } catch (...) {}
    doc.sendMessage(SCI_ENDUNDOACTION);

    if (result > 0) doc.currentSelection().clearSelection();
    return result;
}

} // namespace Unicode

// ════════════════════════════════════════════════════════════════════════════
//  TagFinder  (port of TagFinder.cpp)
// ════════════════════════════════════════════════════════════════════════════
namespace TagFinder {

enum SearchDirection { dirBackward = -1, dirNone, dirForward, dirUnknown };

struct TagPair {
    std::string name;
    std::shared_ptr<SciTextRange> tag;
};

constexpr const char *voidElements[] = {
    "AREA","BASE","BASEFONT","BR","COL","EMBED","FRAME","HR","IMG","INPUT",
    "ISINDEX","LINK","META","PARAM","SOURCE","TRACK","WBR",
};
constexpr int ncHighlightTimeout = 1000;

std::shared_ptr<SciTextRange> extractTagName(std::string &tagName, bool &isOpenTag, bool &isEndTag,
                                             Sci_Position tagPos = -1) {
    SciActiveDocument doc = activeDocument();
    bool closureFound = false;
    isOpenTag = true; isEndTag = false; tagName.clear();

    if (tagPos < 0) {
        const Sci_Position caret = doc.currentPosition();
        tagPos = (caret <= (Sci_Position)doc.sendMessage(SCI_GETANCHOR)) ? caret + 1 : caret;
    }

    auto result = std::make_shared<SciTextRange>(doc);
    doc.find(u"<", *result, 0, tagPos, 0);            // search backward
    if (result->length() == 0) {
        doc.find(u"<", *result, 0, tagPos);          // search forward
        if (result->length() == 0) return result;
    }

    SciTextRange tagEnd(doc);
    doc.find(u">", tagEnd, 0, result->endPos() + 1);
    if (tagEnd.length() == 0) return result;
    else result->endPos(tagEnd.endPos());

    std::string digits = utf16to8(scDigits), letters = utf16to8(scLetters), attrchars = "-_.:";
    tagName = utf16to8(result->text());

    size_t startIndex = 0, endIndex = 0;
    for (size_t i = 1; i < tagName.length(); i++) {
        if (tagName.substr(i) == "/>") {
            isOpenTag = true; isEndTag = true; endIndex = i - 1; break;
        } else if (startIndex == 0) {
            if (tagName[i] == '/') { isOpenTag = false; isEndTag = true; }
            else if (digits.find(tagName[i]) != std::string::npos ||
                     letters.find(tagName[i]) != std::string::npos ||
                     attrchars.find(tagName[i]) != std::string::npos) {
                startIndex = i;
            }
        } else if (endIndex == 0) {
            if (tagName[i] && digits.find(tagName[i]) == std::string::npos &&
                letters.find(tagName[i]) == std::string::npos &&
                attrchars.find(tagName[i]) == std::string::npos) {
                endIndex = i - 1;
                if (isEndTag) break;
            }
        } else {
            if (tagName[i] == '/') closureFound = true;
            else if (closureFound && !std::isspace((unsigned char)tagName[i])) closureFound = false;
        }
    }

    isEndTag = (isEndTag || closureFound);
    if (endIndex == 0) tagName = tagName.substr(startIndex);
    else tagName = tagName.substr(startIndex, endIndex - startIndex + 1);
    return result;
}

void selectTags(SciTextRange *startTag, SciTextRange *endTag = nullptr) {
    SciActiveDocument doc = activeDocument();
    const std::u16string startTagName = startTag->text();
    std::u16string tagNameBuf;
    size_t tagAttrPos = posU16(u" ", startTagName);

    if (tagAttrPos > posU16(u"<", startTagName))
        startTag->endPos(startTag->startPos() + tagAttrPos);

    if (endTag == nullptr) {
        startTag->startPos(startTag->startPos() + posU16(u"<", startTagName));
        if (startTag->text().find(u"/>") != std::u16string::npos)
            startTag->endPos(startTag->endPos() - 1);
    } else {
        tagNameBuf = startTagName.substr(0, startTag->length());
        startTag->startPos(startTag->startPos() + (posU16(u"/", tagNameBuf) >> 1) + 1);
    }

    doc.sendMessage(SCI_SETSELECTION, (uintptr_t)startTag->startPos(), (intptr_t)(startTag->endPos() - 1));

    if (endTag) {
        const std::u16string endTagName = endTag->text();
        tagAttrPos = posU16(u" ", endTagName);
        if (tagAttrPos > posU16(u"<", endTagName))
            endTag->endPos(endTag->startPos() + tagAttrPos);
        tagNameBuf = endTagName.substr(0, endTag->length());
        doc.sendMessage(SCI_ADDSELECTION,
                        (uintptr_t)(endTag->startPos() + (posU16(u"/", tagNameBuf) >> 1) + 1),
                        (intptr_t)(endTag->endPos() - 1));
    }
}

void findMatchingTag(unsigned options = soNone) {
    std::string tagName;
    bool dispose = false;
    SearchDirection searchDirection = dirUnknown;
    SciActiveDocument doc = activeDocument();
    SciTextRange match(doc);
    std::shared_ptr<SciTextRange> currentTag = nullptr;
    std::vector<TagPair> matchingTags;

    auto classifyTag = [&](SearchDirection processDirection, char prefix) {
        tagName = prefix + tagName;
        if (matchingTags.empty()) {
            matchingTags.push_back(TagPair{ tagName, currentTag });
            dispose = false; searchDirection = processDirection;
        } else if (sameTextU8(tagName.substr(1), matchingTags.front().name.substr(1))) {
            if (searchDirection == processDirection) {
                matchingTags.push_back(TagPair{ tagName, currentTag }); dispose = false;
            } else {
                if (matchingTags.size() > 1) {
                    matchingTags.pop_back();
                } else {
                    match = *currentTag;
                    matchingTags.push_back(TagPair{ tagName, currentTag }); dispose = false;
                }
            }
        }
    };

    SciTextRange nextTag(doc);
    bool isStartTag = false, isEndTag = false;
    bool isXML = (documentLangType() == L_XML);
    bool wantSelection = !(options & soNone);
    bool contentsOnly = wantSelection && !(options & soTags);
    bool tagsOnly = wantSelection && !(options & soContents);

    try {
        do {
            dispose = true;
            if (!nextTag) {
                currentTag = extractTagName(tagName, isStartTag, isEndTag);
            } else {
                currentTag = extractTagName(tagName, isStartTag, isEndTag, nextTag.startPos() + 1);
                nextTag.clearRange();
            }

            if (currentTag && !tagName.empty()) {
                if (!isXML && isStartTag && !isEndTag) {
                    for (size_t i = 0; i < sizeof(voidElements)/sizeof(voidElements[0]); i++) {
                        if (sameTextU8(tagName, voidElements[i])) { isEndTag = true; break; }
                    }
                }
                if (isStartTag && isEndTag) {
                    tagName = '*' + tagName;
                    if (matchingTags.empty()) {
                        match = *currentTag;
                        matchingTags.push_back(TagPair{ tagName, currentTag });
                        dispose = false; searchDirection = dirNone;
                    }
                } else if (isStartTag) {
                    classifyTag(dirForward, '+');
                } else if (isEndTag) {
                    classifyTag(dirBackward, '-');
                } else {
                    NSBeep();
                }
            }

            switch (searchDirection) {
                case dirForward: {
                    nextTag.clearRange();
                    doc.find(u"<[^%\\?\\r\\n\\t 0-9]", nextTag, SCFIND_REGEXP | SCFIND_POSIX,
                             currentTag->endPos());
                    if (nextTag.length() != 0) nextTag.endPos(nextTag.endPos() - 1);
                    else nextTag.clearRange();
                    break;
                }
                case dirBackward: {
                    Sci_Position initPos = currentTag->startPos();
                    do {
                        nextTag.clearRange();
                        doc.find(u">", nextTag, 0, initPos, 0);
                        if (nextTag.length() != 0) {
                            if (nextTag.startPos() == 0) { nextTag.clearRange(); break; }
                            nextTag.startPos(nextTag.startPos() - 1);
                            if (nextTag.text()[0] == u'%' || nextTag.text()[0] == u'?') {
                                initPos = nextTag.startPos(); continue;
                            } else {
                                nextTag.startPos(nextTag.startPos() + 1); break;
                            }
                        } else nextTag.clearRange();
                    } while ((bool)nextTag);
                    break;
                }
                default:
                    nextTag.clearRange();
                    break;
            }

            if (dispose) currentTag = nullptr;
        } while ((bool)nextTag && !(bool)match);

        if ((bool)match) {
            if (matchingTags.size() == 2) {
                currentTag = matchingTags.front().tag;
                doc.sendMessage(SCI_FOLDLINE,
                                (uintptr_t)doc.sendMessage(SCI_LINEFROMPOSITION, (uintptr_t)match.startPos()),
                                SC_FOLDACTION_EXPAND);
                if (wantSelection && !tagsOnly) {
                    SciTextRange selRange(doc), selRangeNoSpaces(doc);
                    if (currentTag->startPos() < match.startPos()) {
                        if (contentsOnly) { selRange.startPos(currentTag->endPos()); selRange.endPos(match.startPos()); }
                        else { selRange.startPos(currentTag->startPos()); selRange.endPos(match.endPos()); }
                    } else {
                        if (contentsOnly) { selRange.startPos(match.endPos()); selRange.endPos(currentTag->startPos()); }
                        else { selRange.startPos(match.startPos()); selRange.endPos(currentTag->endPos()); }
                    }
                    if (contentsOnly) {
                        doc.find(u"[^ \\r\\n\\t]", selRangeNoSpaces, SCFIND_REGEXP | SCFIND_POSIX,
                                 selRange.startPos(), selRange.endPos());
                        if (selRangeNoSpaces.length() != 0) selRange.startPos(selRangeNoSpaces.startPos());
                        doc.find(u"[^ \\r\\n\\t]", selRangeNoSpaces, SCFIND_REGEXP | SCFIND_POSIX,
                                 selRange.endPos(), selRange.startPos());
                        if (selRangeNoSpaces.length() != 0) selRange.endPos(selRangeNoSpaces.endPos());
                    }
                    selRange.select();
                } else if (wantSelection) {
                    selectTags(currentTag.get(), &match);
                } else {
                    match.select();
                }
            } else {
                if (tagsOnly) selectTags(&match);
                else match.select();
            }
        } else if (!matchingTags.empty()) {
            currentTag = matchingTags.front().tag;
            if (wantSelection) currentTag->select();
            currentTag->mark(STYLE_BRACEBAD, ncHighlightTimeout);
            NSBeep();
        }

        matchingTags.clear();
    } catch (...) {}
}

} // namespace TagFinder

// ════════════════════════════════════════════════════════════════════════════
//  Live decode dispatcher  (port of findAndDecode in HtmlTag.cpp)
// ════════════════════════════════════════════════════════════════════════════
enum DecodeCmd { dcAuto = -1, dcEntity, dcUnicode };

constexpr bool isStartOfEntity(int ch) { return ch == amp || ch == colon; }
constexpr bool isEndOfEntity(int ch)   { return ch == semi || ch == colon; }

void findAndDecode(int keyCode, DecodeCmd cmd = dcAuto) {
    using Decoder = int (*)();
    SciActiveDocument doc = activeDocument();
    int ch = keyCode & 0xff;

    if ((cmd == dcAuto) && ((ch == 0x0D && doc.sendMessage(SCI_GETEOLMODE) == SC_EOL_CRLF) ||
                            !(g.options.liveEntityDecoding || g.options.liveUnicodeDecoding) ||
                            !((ch >= 0x09 && ch <= 0x0D) || ch == 0x20))) {
        return;
    }

    Sci_Position caret = doc.currentPosition(), charOffset = -1, anchor = 0, selStart = 0, nextCaretPos = 0;
    bool didReplace = false;
    bool skipEntities = false;

    auto replace = [&doc](Decoder decoder, Sci_Position start, Sci_Position end) {
        doc.select(start, end - start);
        int nDecoded = decoder();
        return (nDecoded > 0);
    };

    if (cmd == dcAuto)
        caret = (Sci_Position)doc.sendMessage(SCI_POSITIONBEFORE, (uintptr_t)doc.currentPosition());

    Sci_Position startPos = caret - 1;
    for (anchor = startPos; anchor >= 0; anchor--) {
        int chCurrent = (int)doc.sendMessage(SCI_GETCHARAT, (uintptr_t)anchor);
        if (chCurrent >= 0 && chCurrent <= 0x20) break;
        if (g.options.liveEntityDecoding || cmd == dcEntity) {
            if (anchor == startPos)
                skipEntities = !isEndOfEntity(chCurrent) ||
                               isEndOfEntity((int)doc.sendMessage(SCI_GETCHARAT, (uintptr_t)(anchor - 1)));
            else if (anchor < startPos && !skipEntities && isStartOfEntity(chCurrent)) {
                didReplace = replace(Entities::decode, anchor, caret);
                if (!(ch == 0x0A || ch == 0x0D)) ++charOffset;
                break;
            }
        }
        if (chCurrent == (int)(unsigned char)g.options.unicodePrefix[0] &&
            (g.options.liveUnicodeDecoding || cmd == dcUnicode)) {
            Sci_Position lenPrefix = (Sci_Position)g.options.unicodePrefix.size();
            Sci_Position lenCodePt = 4 + lenPrefix;
            selStart = anchor;
            chCurrent = (int)doc.sendMessage(SCI_GETCHARAT, (uintptr_t)(anchor - lenCodePt));
            if (chCurrent == (int)(unsigned char)g.options.unicodePrefix[0]) {
                doc.select(anchor - lenCodePt, lenCodePt);
                const std::u16string str = doc.currentSelection().text().substr(lenPrefix, 4);
                if (std::all_of(str.begin(), str.end(), [](char16_t c){ return std::isxdigit((int)c); })) {
                    int chValue = std::stoi(utf16to8(str), nullptr, 16);
                    if (chValue >= 0xD800 && chValue <= 0xDBFF) selStart -= lenCodePt;
                }
            }
            didReplace = replace(Unicode::decode, selStart, caret);
            for (Sci_Position i = 1; i < lenPrefix; ++i) ++charOffset;
            break;
        }
    }

    if (didReplace) {
        if (ch == 0x0A || ch == 0x0D) {
            doc.currentPosition(doc.nextLineStartPosition());
        } else {
            nextCaretPos = (Sci_Position)doc.sendMessage(SCI_POSITIONAFTER, (uintptr_t)doc.currentPosition());
            if (nextCaretPos >= doc.nextLineStartPosition()) {
                if (cmd == dcAuto) doc.currentPosition(caret);
                return;
            }
            if (cmd > dcAuto) charOffset = -1;
            doc.currentPosition(nextCaretPos + charOffset);
        }
    } else {
        if (cmd == dcAuto) {
            ++caret;
            if (ch == 0x0A && doc.sendMessage(SCI_GETEOLMODE) == SC_EOL_CRLF) ++caret;
        }
        doc.currentSelection().clearSelection();
        doc.currentPosition(caret);
    }
}

// ── isWebDocument (subset: lang + a few markup extensions) ───────────────────
bool isWebDocument() {
    switch (documentLangType()) {
        case L_HTML: case L_XML: case L_PHP: case L_ASP: case L_JSP: return true;
        default: break;
    }
    char extBuf[512] = {0};
    if (!nppData._sendMessage(nppData._nppHandle, NPPM_GETEXTPART, sizeof(extBuf) - 1, (intptr_t)extBuf))
        return false;
    static const char *exts[] = {
        ".adoc",".asciidoc",".creole",".markdown",".md",".mdoc",".mdown",".mdtext",
        ".mdtxt",".mdwn",".mediawiki",".mkd",".mkdn",".org",".pod",".rdoc",".rst",
        ".textile",".wiki",
    };
    for (auto e : exts) if (sameTextU8(extBuf, e)) return true;
    return false;
}

} // namespace HtmlTag

using namespace HtmlTag;

// ════════════════════════════════════════════════════════════════════════════
//  Menu commands
// ════════════════════════════════════════════════════════════════════════════
namespace {

const int nbFunc = 16;
FuncItem funcItem[nbFunc];

// indexes of the three checkable toggle items (so beNotified can set checkmarks)
int idxLiveEntity = -1, idxLiveUnicode = -1, idxAutoComplete = -1;

void cmdFindMatchingTag()           { TagFinder::findMatchingTag(); }
void cmdSelectMatchingTags()        { TagFinder::findMatchingTag(soTags); }
void cmdSelectTagContents()         { TagFinder::findMatchingTag(soTags | soContents); }
void cmdSelectTagContentsOnly()     { TagFinder::findMatchingTag(soContents); }
void cmdEncodeEntities()            { Entities::encode(); }
void cmdEncodeEntitiesInclBreaks()  { Entities::encode(true); }
void cmdDecodeEntities() {
    if (!(bool)activeDocument().currentSelection()) findAndDecode(0, dcEntity);
    else Entities::decode();
}
void cmdEncodeJS()                  { Unicode::encode(); }
void cmdDecodeJS() {
    if (!(bool)activeDocument().currentSelection()) findAndDecode(0, dcUnicode);
    else Unicode::decode();
}

void setMenuChecks() {
    if (idxLiveEntity >= 0)
        nppData._sendMessage(nppData._nppHandle, NPPM_SETMENUITEMCHECK,
                             (uintptr_t)funcItem[idxLiveEntity]._cmdID, g.options.liveEntityDecoding);
    if (idxLiveUnicode >= 0)
        nppData._sendMessage(nppData._nppHandle, NPPM_SETMENUITEMCHECK,
                             (uintptr_t)funcItem[idxLiveUnicode]._cmdID, g.options.liveUnicodeDecoding);
    if (idxAutoComplete >= 0)
        nppData._sendMessage(nppData._nppHandle, NPPM_SETMENUITEMCHECK,
                             (uintptr_t)funcItem[idxAutoComplete]._cmdID, g.options.entityAutoCompletion);
}

void toggleLiveEntityDecoding() {
    g.options.liveEntityDecoding = !g.options.liveEntityDecoding; saveOptions(); setMenuChecks();
}
void toggleLiveUnicodeDecoding() {
    g.options.liveUnicodeDecoding = !g.options.liveUnicodeDecoding; saveOptions(); setMenuChecks();
}
void toggleEntityAutoCompletion() {
    g.options.entityAutoCompletion = !g.options.entityAutoCompletion; saveOptions(); setMenuChecks();
}

// ── About (native NSAlert, macOS style) ──────────────────────────────────────
void cmdAbout() {
    @autoreleasepool {
        NSAlert *a = [[NSAlert alloc] init];
        a.alertStyle = NSAlertStyleInformational;
        a.messageText = @"HTML Tag";
        a.informativeText =
            @"HTML Tag for Notepad++ (macOS port)\n"
            @"Version 1.0.0\n\n"
            @"HTML and XML tag matching, selection, and entity encoding.\n\n"
            @"Features:\n"
            @"- Jump to the matching open/close tag\n"
            @"- Select tag contents or the whole tag\n"
            @"- Encode and decode HTML entities and Unicode escapes\n"
            @"- Live entity decode and entity-name autocompletion\n"
            @"- Toolbar button\n\n"
            @"Original Windows plugin by Martijn Coppoolse (vor0nwe) and Robert Di Pardo (MPL 2.0)\n"
            @"macOS port by Andrey Letov\n"
            @"Project home: https://github.com/nextpad-plus-plus-plugins/HTMLTag.macos";
        [a addButtonWithTitle:@"OK"];
        [a runModal];
    }
}

} // namespace

// ════════════════════════════════════════════════════════════════════════════
//  beNotified — live decode + auto-complete handlers
// ════════════════════════════════════════════════════════════════════════════
namespace {

bool g_isWebDoc = false;
bool g_isAutoCompletionCandidate = false;
intptr_t g_acInsertMode = SC_MULTIAUTOC_ONCE;

// Auto-complete an HTML entity / emoji shortcode list at the caret.
void autoCompleteEntity(bool preferEmoji) {
    EntityList entities;
    loadEntities(entities, preferEmoji);
    if (entities.empty()) return;
    SciActiveDocument doc = activeDocument();

    // Build a space-separated list of candidate names (sorted, deduped).
    std::vector<std::string> names;
    names.reserve(entities.size());
    for (auto &kv : entities) {
        // Skip the reverse (numeric-key) entries for the HTML list.
        if (!kv.first.empty() && (std::isdigit((unsigned char)kv.first[0]))) continue;
        names.push_back(kv.first);
    }
    std::sort(names.begin(), names.end());
    std::string acList;
    for (auto &n : names) { if (!acList.empty()) acList += ' '; acList += n; }
    if (acList.empty()) return;
    doc.sendMessage(SCI_AUTOCSHOW, 0, (intptr_t)acList.c_str());
}

// When an entity/emoji name is chosen from the list, append the closing char.
bool autoCompleteMatchingTag(Sci_Position startPos, const char *tagName) {
    constexpr size_t maxTagLength = 72;
    SciActiveDocument doc = activeDocument();
    if (doc.getSelectionMode() != smStreamMulti || std::strlen(tagName) > maxTagLength) return false;
    SciTextRange tagEnd(doc);
    doc.find(u"[/>\\s]", tagEnd, SCFIND_REGEXP, startPos, startPos + (Sci_Position)maxTagLength + 1);
    return (tagEnd.length() != 0);
}

} // namespace

// ════════════════════════════════════════════════════════════════════════════
//  Plugin exports
// ════════════════════════════════════════════════════════════════════════════
extern "C" NPP_EXPORT void setInfo(NppData data) {
    nppData = data;

    // config dir → entities.ini + options.ini
    char cfg[1024] = {0};
    nppData._sendMessage(nppData._nppHandle, NPPM_GETPLUGINSCONFIGDIR, sizeof(cfg) - 1, (intptr_t)cfg);
    std::string cfgDir = (cfg[0] ? std::string(cfg) : std::string("."));
    std::string htmlTagCfg = cfgDir + "/HTMLTag";
    @autoreleasepool {
        [[NSFileManager defaultManager] createDirectoryAtPath:[NSString stringWithUTF8String:htmlTagCfg.c_str()]
                                   withIntermediateDirectories:YES attributes:nil error:nil];
    }
    g.optionsConfigPath = htmlTagCfg + "/options.ini";

    // entities.ini: prefer a user copy in the config dir, else the bundled resource.
    std::string userEntities = htmlTagCfg + "/entities.ini";
    std::string bundledEntities = resourceDir() + "/HTMLTag-entities.ini";
    @autoreleasepool {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *userP = [NSString stringWithUTF8String:userEntities.c_str()];
        NSString *bundP = [NSString stringWithUTF8String:bundledEntities.c_str()];
        if (![fm fileExistsAtPath:userP] && [fm fileExistsAtPath:bundP])
            [fm copyItemAtPath:bundP toPath:userP error:nil];
    }
    {
        std::ifstream test(userEntities, std::ios::binary);
        g.entitiesPath = test ? userEntities : bundledEntities;
    }

    loadOptions();

    // ── build menu ──
    memset(funcItem, 0, sizeof(funcItem));
    int i = 0;
    auto add = [&](const char *name, PFUNCPLUGINCMD fn) {
        strncpy(funcItem[i]._itemName, name, NPP_MENU_ITEM_SIZE - 1);
        funcItem[i]._pFunc = fn;
        funcItem[i]._pShKey = nullptr;
        return i++;
    };
    add("Find matching tag", cmdFindMatchingTag);
    add("Select matching tags", cmdSelectMatchingTags);
    add("Select tag and contents", cmdSelectTagContents);
    add("Select tag contents only", cmdSelectTagContentsOnly);
    add("---", nullptr);                                   // separator (empty name)
    add("Encode entities", cmdEncodeEntities);
    add("Encode entities (incl. line breaks)", cmdEncodeEntitiesInclBreaks);
    add("Decode entities", cmdDecodeEntities);
    add("---", nullptr);
    add("Encode Unicode characters", cmdEncodeJS);
    add("Decode Unicode characters", cmdDecodeJS);
    add("---", nullptr);
    idxLiveEntity   = add("Automatically decode entities", toggleLiveEntityDecoding);
    idxLiveUnicode  = add("Automatically decode Unicode characters", toggleLiveUnicodeDecoding);
    idxAutoComplete = add("Auto-complete HTML entities", toggleEntityAutoCompletion);
    add("About...", cmdAbout);
    // (i == nbFunc)

    // separators: the host treats an item with empty _itemName as a divider.
    for (int k = 0; k < nbFunc; ++k)
        if (std::strcmp(funcItem[k]._itemName, "---") == 0) funcItem[k]._itemName[0] = '\0';

    // initial checkmarks
    funcItem[idxLiveEntity]._init2Check   = g.options.liveEntityDecoding;
    funcItem[idxLiveUnicode]._init2Check  = g.options.liveUnicodeDecoding;
    funcItem[idxAutoComplete]._init2Check = g.options.entityAutoCompletion;
}

extern "C" NPP_EXPORT const char *getName() { return PLUGIN_NAME; }

extern "C" NPP_EXPORT FuncItem *getFuncsArray(int *nbF) { *nbF = nbFunc; return funcItem; }

extern "C" NPP_EXPORT void beNotified(SCNotification *scn) {
    if (!scn) return;
    NppHandle from = (NppHandle)scn->nmhdr.hwndFrom;
    unsigned code = scn->nmhdr.code;

    if (from == nppData._nppHandle) {
        switch (code) {
            case NPPN_READY:
                g_isWebDoc = isWebDocument();
                setMenuChecks();
                break;
            case NPPN_TBMODIFICATION:
                // lParam 0 → host loads toolbar.png / toolbar_dark.png from the plugin dir.
                nppData._sendMessage(nppData._nppHandle, NPPM_ADDTOOLBARICON_FORDARKMODE,
                                     (uintptr_t)funcItem[0]._cmdID, 0);
                break;
            case NPPN_BUFFERACTIVATED:
                g_isWebDoc = isWebDocument();
                break;
            case NPPN_SHUTDOWN:
                saveOptions();
                break;
            default: break;
        }
        return;
    }

    // Scintilla notifications (from an editor view)
    switch (code) {
        case SCN_AUTOCSELECTION:
            g_acInsertMode = activeDocument().sendMessage(SCI_AUTOCGETMULTI);
            if (g_isWebDoc && g_isAutoCompletionCandidate &&
                autoCompleteMatchingTag(scn->position, scn->text)) {
                nppData._sendMessage(nppData._scintillaMainHandle, SCI_AUTOCSETMULTI, SC_MULTIAUTOC_EACH, 0);
                nppData._sendMessage(nppData._scintillaSecondHandle, SCI_AUTOCSETMULTI, SC_MULTIAUTOC_EACH, 0);
            }
            break;
        case SCN_AUTOCCOMPLETED:
            nppData._sendMessage(nppData._scintillaMainHandle, SCI_AUTOCSETMULTI, (uintptr_t)g_acInsertMode, 0);
            nppData._sendMessage(nppData._scintillaSecondHandle, SCI_AUTOCSETMULTI, (uintptr_t)g_acInsertMode, 0);
            break;
        case SCN_AUTOCSELECTIONCHANGE:
            g_isAutoCompletionCandidate = (scn->listType == 0);
            break;
        case SCN_USERLISTSELECTION:
            g_isAutoCompletionCandidate = false;
            break;
        case SCN_CHARADDED:
            if ((scn->characterSource == SC_CHARACTERSOURCE_DIRECT_INPUT) &&
                !(bool)activeDocument().currentSelection()) {
                findAndDecode(scn->ch);
            }
            if (g.options.entityAutoCompletion && isStartOfEntity(scn->ch) && g_isWebDoc) {
                autoCompleteEntity(scn->ch == (int)colon);
            }
            break;
        default: break;
    }
}

extern "C" NPP_EXPORT intptr_t messageProc(uint32_t m, uintptr_t w, intptr_t l) {
    (void)m; (void)w; (void)l; return 1;
}
