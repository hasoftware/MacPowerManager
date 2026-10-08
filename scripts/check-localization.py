#!/usr/bin/env python3
"""Kiểm tra bản dịch tiếng Anh (best-effort, không cần Xcode).

Khóa (key) dịch chính là câu tiếng Việt trong mã nguồn. Script quét Sources/**/*.swift, lấy các chuỗi được
SwiftUI/Foundation tra bản dịch:
  - Text("…"), Label("…", …), Button("…"), Toggle("…"), Section("…"), LabeledContent("…"), Link("…"),
    Picker("…"), Stepper("…"), ContentUnavailableView("…"), Window("…"), .navigationTitle("…"), .help("…"),
    .alert("…"), .confirmationDialog("…"), .accessibilityLabel("…"), nhãn biểu đồ .value("…", …),
    String(localized: "…"), các view riêng nhận LocalizedStringKey (Footnote, InfoRow, `title:`, `text:`);
  - mọi chuỗi trong thân thuộc tính/hàm có kiểu LocalizedStringKey (ví dụ `var title: LocalizedStringKey`
    với `case .x: "…"`);
  - trong Sources/MacPowerManager: mọi chuỗi có chữ tiếng Việt có dấu.
Bỏ qua dòng có `l10n-ignore`, Text(verbatim:) và print(…).

Phần nội suy \\(…) được coi là ký tự đại diện, khớp với %lld / %@ / %lf… trong khóa. Như SwiftUI, chuỗi có nội
suy thì dấu % trong chữ thành %% trong khóa; chuỗi không có nội suy thì giữ nguyên %.

Báo cáo: khóa trong mã chưa có trong en.lproj (lỗi), khóa trong en.lproj không còn dùng (cảnh báo; lỗi khi có
--strict), định dạng của bản dịch không khớp với khóa (lỗi). Mã thoát 1 khi có lỗi.

    python3 scripts/check-localization.py [--strict] [--list]
"""

import argparse
import plistlib
import re
import sys
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"
# Chỉ app có bản dịch. Helper (root) và smc-probe không có .lproj nên luôn là tiếng Việt.
APP_SOURCES = SOURCES / "MacPowerManager"
EXCLUDED = [SOURCES / "PowerHelper", SOURCES / "SMCProbe"]
EN_DIR = ROOT / "Resources" / "Localization" / "en.lproj"

WILD = "\x00"  # một tham số nội suy

# Lời gọi nhận LocalizedStringKey / LocalizationValue ở đối số đầu tiên.
CALL_CONTEXT = re.compile(
    r"(?:"
    r"\b(?:Text|Label|Button|Toggle|Section|LabeledContent|Link|Picker|Stepper|Menu|ContentUnavailableView"
    r"|GroupBox|DisclosureGroup|NavigationLink|TextField|SecureField|Window|WindowGroup|Footnote|InfoRow"
    r"|LocalizedStringKey|LocalizedStringResource|NSLocalizedString)"
    r"|\.(?:navigationTitle|navigationSubtitle|help|alert|confirmationDialog|accessibilityLabel"
    r"|accessibilityHint|accessibilityValue|value)"
    r")\(\s*\Z"
)
LOCALIZED_CONTEXT = re.compile(r"\bString\(\s*localized:\s*\Z")
NAMED_CONTEXT = re.compile(r"\b(?:title|text|titleKey):\s*\Z")
# Thân của thuộc tính/hàm trả về LocalizedStringKey: mọi chuỗi trong đó là khóa (ví dụ `case .x: "…"`).
LOCALIZED_BODY = re.compile(
    r"\b(?:var|func)\s+\w+[^{}=]*?(?::|->)\s*(?:SwiftUI\.)?"
    r"(?:LocalizedStringKey|LocalizedStringResource|String\.LocalizationValue)\s*\{"
)
NON_LOCALIZED_CONTEXT = re.compile(r"(?:\bprint|\blog|\bverbatim:|\bLogger\.\w+)\(?\s*\Z")

# Định dạng SwiftUI/Foundation sinh ra trong khóa: Int → %lld, String → %@, Double → %lf…
KEY_SPEC = re.compile(r"%%|%(?:lld|llu|ld|lu|lf|hhd|hhu|hd|hu|d|u|f|@|c|s)")
# Định dạng đầy đủ trong bản dịch (cho phép vị trí %1$@, cờ, độ rộng).
VALUE_SPEC = re.compile(
    r"%%|%(?:(\d+)\$)?[-+ #0']*(?:\d+|\*)?(?:\.(?:\d+|\*))?(hh|h|ll|l|q|L|z|t|j)?([@dDiuUxXoOfFeEgGaAcCsSp])"
)
PLURAL_VAR = re.compile(r"%(?:(\d+)\$)?#@(\w+)@")


def spec_kind(conversion):
    if conversion in "dDiuUxXoOc":
        return "int"
    if conversion in "fFeEgGaA":
        return "double"
    if conversion == "@":
        return "object"
    return conversion


# MARK: Đọc mã Swift


class Literal:
    def __init__(self, path, line, text, interpolations, start):
        self.path = path
        self.line = line
        self.text = text  # WILD thay cho mỗi \(…)
        self.interpolations = interpolations
        self.start = start

    @property
    def has_interpolation(self):
        return bool(self.interpolations)

    @property
    def key(self):
        # SwiftUI và String.LocalizationValue thoát % thành %% khi chuỗi có nội suy.
        return self.text.replace("%", "%%") if self.has_interpolation else self.text


ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", '"': '"', "'": "'", "\\": "\\"}


def skip_code(src, i, closer):
    """Bỏ qua mã Swift (trong nội suy) tới dấu `closer` cân bằng. Trả về vị trí ngay sau nó."""
    depth = 0
    n = len(src)
    while i < n:
        c = src[i]
        if src.startswith("//", i):
            i = src.find("\n", i)
            i = n if i < 0 else i
            continue
        if src.startswith("/*", i):
            i = skip_block_comment(src, i)
            continue
        if c == '"':
            _, _, i = read_string(src, i)
            continue
        if c in "([{":
            depth += 1
        elif c in ")]}":
            if depth == 0 and c == closer:
                return i + 1
            depth -= 1
        i += 1
    return n


def skip_block_comment(src, i):
    depth = 0
    n = len(src)
    while i < n:
        if src.startswith("/*", i):
            depth += 1
            i += 2
        elif src.startswith("*/", i):
            depth -= 1
            i += 2
            if depth == 0:
                return i
        else:
            i += 1
    return n


def read_string(src, i):
    """Đọc chuỗi bắt đầu ở src[i] == '"'. Trả về (chữ với WILD, [mã nội suy], vị trí sau chuỗi)."""
    multiline = src.startswith('"""', i)
    i += 3 if multiline else 1
    out, interps = [], []
    n = len(src)
    while i < n:
        c = src[i]
        if multiline and src.startswith('"""', i):
            i += 3
            break
        if not multiline and c == '"':
            i += 1
            break
        if not multiline and c == "\n":  # chuỗi lỗi, dừng để không nuốt cả file
            break
        if c == "\\":
            nxt = src[i + 1] if i + 1 < n else ""
            if nxt == "(":
                end = skip_code(src, i + 2, ")")
                interps.append(src[i + 2:end - 1].strip())
                out.append(WILD)
                i = end
                continue
            if nxt == "u" and src.startswith("{", i + 2):
                close = src.find("}", i + 3)
                out.append(chr(int(src[i + 3:close], 16)))
                i = close + 1
                continue
            if multiline and nxt == "\n":  # nối dòng
                i += 2
                continue
            out.append(ESCAPES.get(nxt, nxt))
            i += 2
            continue
        out.append(c)
        i += 1
    text = "".join(out)
    if multiline:
        text = dedent_multiline(text)
    return text, interps, i


def dedent_multiline(text):
    lines = text.split("\n")
    if len(lines) < 2:
        return text
    indent = lines[-1] if not lines[-1].strip() else ""
    body = lines[1:-1] if indent or not lines[-1].strip() else lines[1:]
    return "\n".join(line[len(indent):] if line.startswith(indent) else line for line in body)


def literals(path):
    src = path.read_text(encoding="utf-8")
    i, n = 0, len(src)
    while i < n:
        if src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
        elif src.startswith("/*", i):
            i = skip_block_comment(src, i)
        elif src[i] == "#" and re.match(r'#+"', src[i:]):
            # Chuỗi thô #"…"#: app không dùng để hiển thị, chỉ bỏ qua.
            hashes = re.match(r"#+", src[i:]).group(0)
            end = src.find('"' + hashes, i + len(hashes) + 1)
            i = n if end < 0 else end + 1 + len(hashes)
        elif src[i] == '"':
            start = i
            text, interps, i = read_string(src, i)
            yield Literal(path, src.count("\n", 0, start) + 1, text, interps, start), src
        else:
            i += 1


def has_letters(text):
    return any(unicodedata.category(c).startswith("L") for c in text.replace(WILD, ""))


def has_vietnamese(text):
    return any(ord(c) > 127 and unicodedata.category(c).startswith("L") for c in text)


def localized_bodies(src):
    """Các khoảng [đầu, cuối) là thân của thuộc tính/hàm có kiểu LocalizedStringKey."""
    return [(m.end(), skip_code(src, m.end(), "}")) for m in LOCALIZED_BODY.finditer(src)]


def source_keys():
    """{khóa chuẩn hóa: [Literal]} của mọi chuỗi cần dịch."""
    found = {}
    for path in sorted(SOURCES.rglob("*.swift")):
        if any(path.is_relative_to(d) for d in EXCLUDED):
            continue
        in_app = path.is_relative_to(APP_SOURCES)
        bodies = localized_bodies(path.read_text(encoding="utf-8"))
        for lit, src in literals(path):
            line_start = src.rfind("\n", 0, lit.start) + 1
            line_end = src.find("\n", lit.start)
            if "l10n-ignore" in src[line_start:line_end if line_end >= 0 else None]:
                continue
            before = src[max(0, lit.start - 240):lit.start]
            if NON_LOCALIZED_CONTEXT.search(before):
                continue
            localizable = (CALL_CONTEXT.search(before) or LOCALIZED_CONTEXT.search(before)
                           or NAMED_CONTEXT.search(before) or (in_app and has_vietnamese(lit.text))
                           or any(start <= lit.start < end for start, end in bodies))
            if not localizable or not has_letters(lit.text):
                continue
            # normalize_key: khóa viết sẵn định dạng, ví dụ String(localized: "%lld giờ (ngắn)", defaultValue: …).
            found.setdefault(normalize_key(lit.key), []).append(lit)
    return found


# MARK: Đọc bản dịch


def parse_strings(path):
    """Đọc file .strings (cú pháp "khóa" = "giá trị";). Trả về [(khóa, giá trị, dòng)]."""
    raw = path.read_bytes()
    if raw.startswith(b"\xff\xfe") or raw.startswith(b"\xfe\xff"):
        src = raw.decode("utf-16")
    else:
        src = raw.decode("utf-8-sig")
    entries, i, n = [], 0, len(src)

    def skip_trivia(i):
        while i < n:
            if src[i].isspace():
                i += 1
            elif src.startswith("//", i):
                j = src.find("\n", i)
                i = n if j < 0 else j
            elif src.startswith("/*", i):
                j = src.find("*/", i + 2)
                i = n if j < 0 else j + 2
            else:
                break
        return i

    def read_quoted(i):
        assert src[i] == '"', f"{path}:{src.count(chr(10), 0, i) + 1}: cần dấu \""
        i += 1
        out = []
        while i < n and src[i] != '"':
            if src[i] == "\\":
                nxt = src[i + 1]
                if nxt == "U":
                    out.append(chr(int(src[i + 2:i + 6], 16)))
                    i += 6
                    continue
                out.append({"n": "\n", "t": "\t", "r": "\r"}.get(nxt, nxt))
                i += 2
                continue
            out.append(src[i])
            i += 1
        return "".join(out), i + 1

    while True:
        i = skip_trivia(i)
        if i >= n:
            break
        line = src.count("\n", 0, i) + 1
        key, i = read_quoted(i)
        i = skip_trivia(i)
        if i < n and src[i] == "=":
            i = skip_trivia(i + 1)
            value, i = read_quoted(i)
            i = skip_trivia(i)
        else:
            value = key
        if i < n and src[i] == ";":
            i += 1
        else:
            raise SystemExit(f"{path}:{line}: thiếu dấu ; sau khóa {key!r}")
        entries.append((key, value, line))
    return entries


def key_specs(key):
    """Kiểu tham số theo thứ tự trong khóa, hoặc None nếu khóa không có định dạng."""
    if not KEY_SPEC.search(key):
        return None
    return [spec_kind(m.group(0)[-1]) for m in KEY_SPEC.finditer(key) if m.group(0) != "%%"]


def value_specs(value, plural_types=None):
    """[(vị trí, kiểu)] trong bản dịch; `plural_types` cho biến %#@x@ của .stringsdict."""
    specs, next_pos = [], 1
    tokens = []
    for m in PLURAL_VAR.finditer(value):
        tokens.append((m.start(), m.group(1), (plural_types or {}).get(m.group(2), "?")))
    # Che các biến %#@x@ để VALUE_SPEC không đọc nhầm "%#@" thành %@.
    masked = PLURAL_VAR.sub(lambda m: " " * len(m.group(0)), value)
    for m in VALUE_SPEC.finditer(masked):
        if m.group(0) != "%%":
            tokens.append((m.start(), m.group(1), spec_kind(m.group(3))))
    for _, pos, kind in sorted(tokens):
        if pos:
            specs.append((int(pos), kind))
        else:
            specs.append((next_pos, kind))
            next_pos += 1
    return specs


def check_format(key, value, where, plural_types=None):
    expected = key_specs(key)
    if expected is None:
        # Khóa không có tham số thì SwiftUI không định dạng bản dịch: %@, %lld… sẽ hiện nguyên văn.
        if re.search(r"%(?:\d+\$)?(?:#@\w+@|(?:hh|h|ll|l)?[diuf@])", value):
            return [f"{where}: khóa không có tham số nhưng bản dịch có định dạng: {value!r}"]
        return []
    got = value_specs(value, plural_types)
    by_pos = {}
    for pos, kind in got:
        if by_pos.get(pos, kind) != kind:
            return [f"{where}: tham số {pos} có hai kiểu khác nhau trong {value!r}"]
        by_pos[pos] = kind
    wanted = {i + 1: kind for i, kind in enumerate(expected)}
    if by_pos != wanted:
        show = lambda d: ", ".join(f"{p}:{k}" for p, k in sorted(d.items())) or "không có"
        return [f"{where}: tham số không khớp khóa {key!r}: khóa [{show(wanted)}], bản dịch [{show(by_pos)}]"]
    return []


def load_translations():
    """{khóa chuẩn hóa: (khóa gốc, nguồn)} và danh sách lỗi định dạng."""
    translations, problems, warnings = {}, [], []
    strings = EN_DIR / "Localizable.strings"
    for key, value, line in parse_strings(strings):
        where = f"{strings.relative_to(ROOT)}:{line}"
        norm = normalize_key(key)
        if norm in translations:
            warnings.append(f"{where}: khóa trùng {key!r}")
        translations[norm] = (key, where)
        problems += check_format(key, value, where)
    stringsdict = EN_DIR / "Localizable.stringsdict"
    if stringsdict.exists():
        with stringsdict.open("rb") as f:
            plurals = plistlib.load(f)
        for key, entry in plurals.items():
            where = f"{stringsdict.relative_to(ROOT)}: {key!r}"
            norm = normalize_key(key)
            if norm in translations:
                warnings.append(f"{where}: cũng có trong {translations[norm][1]} (.stringsdict được ưu tiên)")
            translations[norm] = (key, where)
            fmt = entry.get("NSStringLocalizedFormatKey")
            if not isinstance(fmt, str):
                problems.append(f"{where}: thiếu NSStringLocalizedFormatKey")
                continue
            types = {}
            for name, rule in entry.items():
                if name == "NSStringLocalizedFormatKey":
                    continue
                if rule.get("NSStringFormatSpecTypeKey") != "NSStringPluralRuleType" or "other" not in rule:
                    problems.append(f"{where}: biến {name!r} cần NSStringPluralRuleType và dạng 'other'")
                    continue
                types[name] = spec_kind(rule.get("NSStringFormatValueTypeKey", "@")[-1])
            problems += check_format(key, fmt, where, types)
    return translations, problems, warnings


def normalize_key(key):
    return KEY_SPEC.sub(lambda m: m.group(0) if m.group(0) == "%%" else WILD, key)


def show(key):
    return key.replace(WILD, "%?")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--strict", action="store_true", help="khóa không còn dùng cũng là lỗi")
    parser.add_argument("--list", action="store_true", help="in mọi khóa tìm thấy trong mã nguồn")
    args = parser.parse_args()

    sources = source_keys()
    translations, problems, warnings = load_translations()

    if args.list:
        for key, sites in sorted(sources.items()):
            site = sites[0]
            print(f"{site.path.relative_to(ROOT)}:{site.line}: {show(key)!r}")

    missing = {k: v for k, v in sources.items() if k not in translations}
    unused = {k: v for k, v in translations.items() if k not in sources}

    for message in warnings:
        print(f"cảnh báo: {message}")
    if missing:
        print(f"\nThiếu {len(missing)} khóa trong {EN_DIR.relative_to(ROOT)} "
              "(%? = tham số: Int → %lld, String → %@, Double → %lf):")
        for key, sites in sorted(missing.items(), key=lambda kv: (str(kv[1][0].path), kv[1][0].line)):
            site = sites[0]
            hint = f"   ← \\({'), \\('.join(site.interpolations)})" if site.interpolations else ""
            print(f"  {site.path.relative_to(ROOT)}:{site.line}: {show(key)!r}{hint}")
    if unused:
        label = "Lỗi" if args.strict else "Cảnh báo"
        print(f"\n{label}: {len(unused)} khóa trong bản dịch không còn dùng trong mã nguồn:")
        for key, (original, where) in sorted(unused.items(), key=lambda kv: kv[1][1]):
            print(f"  {where}: {original!r}")
    if problems:
        print(f"\n{len(problems)} lỗi định dạng:")
        for message in problems:
            print(f"  {message}")

    print(f"\n{len(sources)} khóa trong mã nguồn, {len(translations)} khóa trong en.lproj, "
          f"thiếu {len(missing)}, không dùng {len(unused)}, lỗi định dạng {len(problems)}.")
    failed = missing or problems or (args.strict and unused)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
