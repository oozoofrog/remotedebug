#!/usr/bin/env bash
# README.md, README.ko.md와 docs/*.md가 저장소와 맞는지 검사한다. 어긋난 곳마다 '실패:' 한 줄을 출력하고 종료 코드 1로 끝난다.
#
# 검사: (a) 문서의 경로가 있는가. 코드 조각과 모든 코드 블록(json 제외, 들여쓴 블록 포함)에서
#           scripts/ docs/ Packages/ Apps/ core/ Config/ .agent-loop/ 아래 경로, 루트 파일 이름(project.yml 등),
#           `--spec` 인자, `<이름>.xcodeproj`(project.yml의 name과 비교)를 본다
#       (b) 문서에 적은 스크립트가 실행 가능하고 문법이 맞는가
#       (c) 대상·스킴·패키지·모듈·번들 ID 이름이 project.yml, project-*.yml, Packages/*/Package.swift에 있는가.
#           번들 ID와 `-scheme` 인자는 긴 코드 조각과 코드 블록 안에서도 찾는다
#       (d) device-test.md의 U 항목이 tunnel.md의 실기기 항목과 번호·문장까지 같은가(빠진 것, 남는 것, 중복)
#       (e) README가 docs/의 파일을 모두 링크하는가, 문서의 상대 링크와 `#` 제목 앵커가 살아 있는가
#       (f) scripts/check_quotes.py, scripts/check_protocol_examples.py가 있고 통과하는가
#       (g) 금지 표현(경고만)
#       (h) docs/setup.md의 웹 페이지 절과 device-test.md의 D14에 적은 화면 문구(**…**, "…")가 페이지·Mac 앱 소스에 있는가
#       (i) device-test.md의 D 항목이 모두 실행 순서 표에 있는가
#
# check_quotes.py는 Apple 원문을 내려받는다. 받지 못하면(종료 코드 2) 경고로 남기고 실패로 치지 않는다.
# RD_QUOTES_CACHE_DIR를 주면 그 폴더의 원문 사본을 쓴다.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
USAGE='사용: scripts/check-docs.sh [--help]   (RD_QUOTES_CACHE_DIR=<폴더>를 주면 Apple 원문 사본으로 인용을 검사한다)'

case "${1:-}" in
  -h|--help) echo "$USAGE"; exit 0 ;;
  "") ;;
  *) echo "$USAGE" >&2; exit 2 ;;
esac

command -v python3 >/dev/null 2>&1 || { echo "실패: python3가 없다"; exit 1; }

RD_USAGE="$USAGE" python3 -I - "$ROOT" <<'PY'
import collections
import glob
import os
import re
import subprocess
import sys

root = sys.argv[1]
os.chdir(root)
usage = os.environ["RD_USAGE"]

failures = []
warnings = []


def one_line_error(kind, error, _trace):
    # 예상하지 못한 오류도 traceback 대신 한 줄로 알리고 종료 코드 1로 끝낸다.
    print(f"실패: 검사 중 오류: {kind.__name__}: {error}")


sys.excepthook = one_line_error


def fail(message):
    failures.append(message)


def finish():
    for warning in warnings:
        print(f"경고: {warning}")
    for failure in dict.fromkeys(failures):
        print(f"실패: {failure}")
    sys.exit(1 if failures else 0)


def read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


REQUIRED = ["README.md", "README.ko.md", "project.yml", "docs/setup.md", "docs/device-test.md", "docs/device-test-results.md",
            "docs/protocol.md", "docs/protocol-addenda.md", "docs/tunnel.md", "docs/architecture.md",
            "docs/appstore-review.md"]
text = {}
for path in sorted(set(REQUIRED + glob.glob("docs/*.md")), key=lambda p: (p != "README.md", p)):
    try:
        text[path] = read(path)
    except FileNotFoundError:
        fail(f"{path}: 파일이 없다")
    except (OSError, UnicodeDecodeError) as error:
        fail(f"{path}: 읽지 못했다: {error.__class__.__name__}")
if failures:
    finish()
project_text = text.pop("project.yml")

PREFIXES = ("scripts/", "docs/", "Packages/", "Apps/", "core/", "Config/", ".agent-loop/")
# 사용자나 스크립트가 만드는 파일이라 없어도 되는 경로.
GENERATED = {"Config/Signing.local.xcconfig", "Packages/RDCore/RDCore.xcframework"}

FENCE = re.compile(r"^[ \t]*```([\w+-]*)[^\n]*\n(.*?)^[ \t]*```[ \t]*$", re.M | re.S)
SHELL_PATH = re.compile(r"(?:^|[\s\"'=(])((?:scripts|docs|Packages|Apps|core|Config|\.agent-loop)/[\w./*+-]+)", re.M)
ROOT_FILE = re.compile(r"(?:^|[\s\"'=(])(\.?[\w-]+(?:\.[\w-]+)*\.(?:yml|yaml|xcconfig|xcodeproj))(?=$|[\s\"')])", re.M)
BUNDLE_ID = re.compile(r"\bcom\.oozoofrog\.app\.[A-Za-z0-9.-]+")
SCHEME = re.compile(r"-scheme[=\s]+[\"']?([\w-]+)")
NOT_SCANNED = ("json", "hujson")


def split_doc(body):
    """(코드 블록을 뺀 글, 검사할 코드 블록 목록)."""
    blocks = [m.group(2) for m in FENCE.finditer(body) if m.group(1).lower() not in NOT_SCANNED]
    return FENCE.sub("", body), blocks


def clean_path(token):
    token = token.split()[0] if token.split() else ""
    token = re.sub(r":\d+(-\d+)?$", "", token)
    return token.rstrip(".,;:)")


def line_of(body, needle):
    index = body.find(needle)
    return body.count("\n", 0, index) + 1 if index >= 0 else 0


def line_of_scheme(body, scheme):
    """`-scheme <이름>` 인자가 있는 줄. 이름만 처음 나온 곳이 아니라 틀린 인자의 줄을 알린다."""
    match = re.search(r"-scheme[=\s]+[\"']?" + re.escape(scheme) + r"(?![\w-])", body)
    return body.count("\n", 0, match.start()) + 1 if match else line_of(body, scheme)


# 이름 목록: project.yml, project-*.yml, Packages/*/Package.swift.
specs = {"project.yml": project_text}
for spec in sorted(glob.glob("Apps/*/project-*.yml")):
    specs[spec] = read(spec)
project_name = (re.search(r"^name:\s*(\S+)\s*$", project_text, re.M) or [None, ""])[1]
targets, schemes, packages, bundle_ids = set(), set(), set(), set()
for spec, body in specs.items():
    section = None
    for raw in body.splitlines():
        top = re.match(r"^([A-Za-z]+):\s*$", raw)
        if top:
            section = top.group(1)
            continue
        if re.match(r"^\S", raw):
            section = None
            continue
        key = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", raw)
        if key and section == "targets":
            targets.add(key.group(1))
        elif key and section == "schemes":
            schemes.add(key.group(1))
        elif key and section == "packages":
            packages.add(key.group(1))
    bundle_ids.update(m.rstrip(".") for m in BUNDLE_ID.findall(body))
modules = set()
for manifest in glob.glob("Packages/*/Package.swift") + glob.glob("Package.swift"):
    modules.update(re.findall(r'\bname:\s*"([^"]+)"', read(manifest)))
known_names = targets | schemes | packages | modules
MODULE_SPAN = re.compile(r"(?:MacHost|PhoneClient|RD|RemoteDebug)[A-Z][A-Za-z0-9]*")
BARE_NAME = re.compile(r"(?<![/\w.])RemoteDebug[A-Z][A-Za-z0-9]*")

documented_scripts = set()

for path, body in text.items():
    prose, blocks = split_doc(body)
    spans = re.findall(r"`([^`\n]+)`", prose)
    here = os.path.dirname(path)

    # (a) 경로
    tokens = [clean_path(span) for span in spans if span.startswith(PREFIXES)]
    for block in spans + blocks:
        tokens += [clean_path(m.group(1)) for m in SHELL_PATH.finditer(block)]
    documented_scripts.update(re.findall(r"\bscripts/[\w.-]+\.(?:sh|py)\b", body))
    for token in sorted(set(tokens)):
        if not token.startswith(PREFIXES):
            continue
        if any(ch in token for ch in "<>{}$…"):
            continue
        if token.endswith("..."):
            continue
        if token.rstrip("/") in GENERATED:
            continue
        if "*" in token:
            if not glob.glob(token):
                fail(f"{path}:{line_of(body, token)}: 일치하는 경로가 없다: {token}")
        elif not os.path.lexists(token.rstrip("/")):
            fail(f"{path}:{line_of(body, token)}: 경로가 없다: {token}")

    # (a) 루트 파일 이름, --spec 인자, <이름>.xcodeproj
    names = set()
    for chunk in spans + blocks:
        names.update(m.group(1) for m in ROOT_FILE.finditer(chunk))
        names.update(clean_path(m) for m in re.findall(r"--spec[=\s]+[\"']?(\S+?)[\"']?(?=\s|$)", chunk))
    for name in sorted(names):
        if "/" in name and name.startswith(PREFIXES):
            continue  # 위에서 검사했다
        if name.endswith(".xcodeproj"):
            if name[: -len(".xcodeproj")] != project_name:
                fail(f"{path}:{line_of(body, name)}: project.yml의 name({project_name})과 다른 프로젝트: {name}")
        elif any(ch in name for ch in "<>{}$…*"):
            continue
        elif name.rstrip("/") in GENERATED:
            continue
        elif not (os.path.lexists(name) or os.path.lexists(os.path.join(here, name))):
            fail(f"{path}:{line_of(body, name)}: 파일이 없다: {name}")

    # (c) 대상·스킴·패키지·모듈·번들 ID
    for span in spans:
        if MODULE_SPAN.fullmatch(span) and span not in known_names:
            fail(f"{path}:{line_of(body, span)}: project 파일과 Package.swift에 없는 이름: {span}")
    for name in sorted(set(BARE_NAME.findall(prose)) - known_names):
        fail(f"{path}:{line_of(body, name)}: project 파일과 Package.swift에 없는 이름: {name}")
    for chunk in spans + blocks:
        for bundle in BUNDLE_ID.findall(chunk):
            bundle = bundle.rstrip(".-")
            if bundle not in bundle_ids:
                fail(f"{path}:{line_of(body, bundle)}: project 파일에 없는 번들 ID: {bundle}")
        for scheme in SCHEME.findall(chunk):
            if scheme not in schemes:
                fail(f"{path}:{line_of_scheme(body, scheme)}: project 파일에 없는 스킴: {scheme}")

# (b) 문서에 적은 스크립트
for script in sorted(documented_scripts):
    if not os.path.exists(script):
        fail(f"{script}: 문서에 적었지만 파일이 없다")
        continue
    if not os.access(script, os.X_OK):
        fail(f"{script}: 실행 권한이 없다")
    if script.endswith(".sh"):
        result = subprocess.run(["bash", "-n", script], capture_output=True, text=True)
        if result.returncode != 0:
            fail(f"{script}: bash -n 실패: {(result.stderr.strip().splitlines() or ['원인 없음'])[0]}")
    else:
        try:
            # py_compile과 같은 문법 검사다. __pycache__를 만들지 않으려고 compile을 직접 부른다.
            compile(read(script), script, "exec")
        except SyntaxError as error:
            fail(f"{script}: 문법 오류: {error}")
        except (OSError, UnicodeDecodeError) as error:
            fail(f"{script}: 읽지 못했다: {error.__class__.__name__}")

# (d) tunnel.md의 실기기 항목과 device-test.md
tunnel_section = re.search(r"^## 실기기에서만 확인할 것\n(.*?)(?=^## )", text["docs/tunnel.md"], re.M | re.S)
if not tunnel_section:
    fail("docs/tunnel.md: '실기기에서만 확인할 것' 절을 찾지 못했다")
else:
    expected = dict(re.findall(r"^(\d+)\. (.+)$", tunnel_section.group(1), re.M))
    device = text["docs/device-test.md"]
    headings = re.findall(r"^### U(\d+)\. ", device, re.M)
    # 절마다 인용을 모은다. U 절은 `### U<n>. ` 제목에서 다음 `#`~`###` 제목 앞까지다.
    section_quotes, outside, current = {}, [], None
    for lineno, raw in enumerate(device.split("\n"), 1):
        heading = re.match(r"^### U(\d+)\. ", raw)
        if heading:
            current = heading.group(1)
            section_quotes.setdefault(current, [])
            continue
        if re.match(r"^#{1,3} ", raw):
            current = None
            continue
        quote = re.match(r"^> (\d+)\. (.+)$", raw)
        if quote:
            if current is None:
                outside.append((lineno, quote.group(1)))
            else:
                section_quotes[current].append((quote.group(1), quote.group(2), lineno))
    if not expected:
        fail("docs/tunnel.md: 실기기 항목을 읽지 못했다")
    for number, count in collections.Counter(headings).items():
        if count > 1:
            fail(f"docs/device-test.md: U{number} 제목이 {count}번 있다")
        if number not in expected:
            fail(f"docs/device-test.md:{line_of(device, f'### U{number}. ')}: tunnel.md에 없는 U{number} 제목")
    for lineno, number in outside:
        fail(f"docs/device-test.md:{lineno}: U 항목 절 밖의 인용: {number}")
    for number, sentence in expected.items():
        if number not in headings:
            fail(f"docs/device-test.md: U{number} 제목이 없다")
            continue
        quotes = section_quotes.get(number, [])
        if len(quotes) != 1:
            fail(f"docs/device-test.md:{line_of(device, f'### U{number}. ')}: U{number} 절에 tunnel.md 인용이 {len(quotes)}개 있다(1개여야 한다)")
            continue
        quoted_number, quoted_sentence, lineno = quotes[0]
        if quoted_number != number:
            fail(f"docs/device-test.md:{lineno}: U{number} 절에 항목 {quoted_number}의 인용이 있다")
        elif quoted_sentence != sentence:
            fail(f"docs/device-test.md:{lineno}: U{number}의 문장이 tunnel.md와 다르다")


# (e) README 링크, 상대 링크, 제목 앵커
def slugs(body):
    """GitHub 방식의 제목 앵커 목록."""
    prose, _ = split_doc(body)
    seen = collections.Counter()
    found = set()
    for heading in re.findall(r"^#{1,6}[ \t]+(.+?)[ \t]*#*[ \t]*$", prose, re.M):
        slug = re.sub(r"[^\w\- ]", "", heading.replace("`", "").strip().lower()).replace(" ", "-")
        found.add(slug if seen[slug] == 0 else f"{slug}-{seen[slug]}")
        seen[slug] += 1
    return found


LINK = re.compile(r"\]\(\s*<?([^)\s>]*)>?(?:\s+\"[^\"]*\")?\s*\)")
readme = text["README.md"]
readme_prose, _ = split_doc(readme)
readme_links = {os.path.normpath(link.split("#")[0]) for link in LINK.findall(readme_prose) if link.split("#")[0]}
for path in sorted(p for p in glob.glob("docs/**", recursive=True) if os.path.isfile(p)):
    if os.path.basename(path) == ".DS_Store":
        continue
    if path not in readme_links:
        fail(f"README.md: {path}로 가는 링크가 없다")
for path, body in text.items():
    prose, _ = split_doc(body)
    for link in LINK.findall(prose):
        if not link or re.match(r"[a-z][a-z0-9+.-]*:", link):
            continue
        target, _, anchor = link.partition("#")
        resolved = os.path.normpath(os.path.join(os.path.dirname(path), target)) if target else path
        if not os.path.exists(resolved):
            fail(f"{path}:{line_of(body, link)}: 끊어진 링크: {link}")
            continue
        if anchor and resolved.endswith(".md"):
            try:
                target_body = text.get(resolved) or read(resolved)
            except (OSError, UnicodeDecodeError):
                fail(f"{path}:{line_of(body, link)}: 링크 대상을 읽지 못했다: {link}")
                continue
            if anchor.lower() not in slugs(target_body):
                fail(f"{path}:{line_of(body, link)}: {resolved}에 없는 제목 앵커: #{anchor}")
if usage not in readme:
    fail("README.md: scripts/check-docs.sh 사용 줄이 --help 출력과 다르다")

# (f) 기존 검사
helpers_ok = True
for helper in ("scripts/check_protocol_examples.py", "scripts/check_quotes.py"):
    if not os.path.isfile(helper) or not os.access(helper, os.R_OK):
        fail(f"{helper}: 파일이 없거나 읽을 수 없다")
        helpers_ok = False

if helpers_ok:
    protocol = subprocess.run(
        [sys.executable, "-I", "scripts/check_protocol_examples.py", "docs/protocol.md"],
        capture_output=True, text=True)
    if protocol.returncode != 0:
        output = [l.strip() for l in (protocol.stdout + protocol.stderr).splitlines() if l.strip()]
        lines = [l.lstrip("- ").strip() for l in output if l.startswith("- ")]
        for line in lines or output[-1:] or ["종료 코드 %d" % protocol.returncode]:
            fail(f"check_protocol_examples.py: {line}")

    quote_args = [sys.executable, "-I", "scripts/check_quotes.py", "docs/appstore-review.md"]
    cache_dir = os.environ.get("RD_QUOTES_CACHE_DIR", "")
    if cache_dir:
        quote_args += ["--cache-dir", cache_dir]
    try:
        quotes = subprocess.run(quote_args, capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired:
        warnings.append("check_quotes.py: 120초 안에 Apple 원문을 받지 못해 인용을 검사하지 못했다")
    else:
        if quotes.returncode == 2:
            reason = (quotes.stdout + quotes.stderr).strip().splitlines()
            warnings.append("check_quotes.py: Apple 원문을 받지 못해 인용을 검사하지 못했다: " + (reason[-1] if reason else "원인 없음"))
        elif quotes.returncode != 0:
            lines = [l.strip(" -") for l in quotes.stdout.splitlines() if l.startswith(" - ")]
            for line in lines or ["종료 코드 %d" % quotes.returncode]:
                fail(f"check_quotes.py: {line}")

# (h) 설치 웹 페이지 절차의 화면 문구. 굵은 글씨(**…**)와 큰따옴표("…") 문구가 페이지·Mac 앱 소스에 글자 그대로 있는가.
#     `<`가 든 문구(자리표시)와 코드 조각은 보지 않는다.
UI_SOURCES = sorted(glob.glob("core/internal/host/web/*") + glob.glob("Packages/MacHost/Sources/MacHostUI/*.swift")
                    + glob.glob("Packages/MacHost/Sources/MacHostKit/*.swift"))
ui_text = "".join(read(f) for f in UI_SOURCES if os.path.isfile(f))
if not ui_text:
    fail("화면 문구 검사: core/internal/host/web, Packages/MacHost/Sources를 읽지 못했다")
UI_SECTIONS = [("docs/setup.md", r"^## iPhone에서 앱 없이 설치\(웹 페이지\)\n.*?(?=^## |\Z)"),
               ("docs/device-test.md", r"^### D14\. .*?(?=^##+ |\Z)")]
for path, pattern in UI_SECTIONS:
    body = text[path]
    found = re.search(pattern, body, re.M | re.S)
    if not found:
        fail(f"{path}: 설치 웹 페이지 절을 찾지 못했다")
        continue
    prose, _ = split_doc(found.group(0))
    prose = re.sub(r"`[^`\n]+`", "", prose)
    for phrase in sorted(set(re.findall(r"\*\*([^*\n]+)\*\*", prose) + re.findall(r'"([^"\n]+)"', prose))):
        if "<" not in phrase and ui_text and phrase not in ui_text:
            fail(f"{path}:{line_of(body, phrase)}: 페이지·Mac 앱 소스에 없는 화면 문구: {phrase}")

# (i) device-test.md의 D 항목이 모두 실행 순서 표에 있는가.
device = text["docs/device-test.md"]
order = re.search(r"^## 실행 순서\n(.*?)(?=^## )", device, re.M | re.S)
if not order:
    fail("docs/device-test.md: '실행 순서' 절을 찾지 못했다")
else:
    ordered = set(re.findall(r"\bD\d+\b", order.group(1)))
    for item in re.findall(r"^### (D\d+)\. ", device, re.M):
        if item not in ordered:
            fail(f"docs/device-test.md:{line_of(device, f'### {item}. ')}: 실행 순서 표에 없는 항목: {item}")

# (g) 금지 표현. 경고만 한다.
FORBIDDEN = ["Claude", "ChatGPT", "GPT-", "AI가", "AI로", "인공지능", "에이전트가 작성", "자동 생성된 문서",
             "혁신", "강력한", "완벽", "손쉽", "놀라운", "최고의", "매끄러운", "차세대"]
for path in ["README.md", "README.ko.md", "docs/setup.md", "docs/device-test.md", "docs/device-test-results.md"]:
    for number, line in enumerate(text.get(path, "").splitlines(), 1):
        for phrase in FORBIDDEN:
            if phrase in line:
                warnings.append(f"{path}:{number}: 금지 표현: {phrase}")

if failures:
    finish()
for warning in warnings:
    print(f"경고: {warning}")
print(f"통과: 문서 {len(text)}개, 경고 {len(warnings)}개")
PY
