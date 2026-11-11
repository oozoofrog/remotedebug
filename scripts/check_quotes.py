#!/usr/bin/env python3
"""판정서의 인용문이 Apple 공식 원문에 그대로 있는지 검사한다.

문서의 인용은 한 줄짜리 블록 인용이며 형식은 `> [<출처> <선택 라벨>] <원문>`이다.
출처: guidelines, TN3120, TestFlight, Devices, AccountOverview. `…` 또는 `[...]`로 생략을 표시하면
각 조각이 원문에 순서대로 있어야 한다. 공백·따옴표·대시·구두점 앞 공백은 정규화해서 비교한다.

사용: python3 -I scripts/check_quotes.py docs/appstore-review.md [--cache-dir DIR]
  --cache-dir: 출처별 원문을 DIR/<출처>.txt 로 저장·재사용한다(오프라인 재검사용).
종료 코드: 0 통과, 1 인용 불일치 또는 판 날짜 불일치, 2 원문을 가져오지 못함.
"""
import hashlib
import html
import json
import os
import re
import sys
import urllib.request

SOURCES = {
    "guidelines": ("https://developer.apple.com/app-store/review/guidelines/", "html"),
    "TN3120": ("https://developer.apple.com/tutorials/data/documentation/technotes/"
               "tn3120-expected-use-cases-for-network-extension-packet-tunnel-providers.json", "docjson"),
    "TestFlight": ("https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/", "html"),
    "Devices": ("https://developer.apple.com/help/account/devices/devices-overview/", "html"),
    "AccountOverview": ("https://developer.apple.com/support/compare-memberships/", "html"),
}
MONTHS = {m: i for i, m in enumerate(
    ["January", "February", "March", "April", "May", "June", "July", "August",
     "September", "October", "November", "December"], 1)}


def normalize(text):
    text = text.replace(" ", " ")
    for a, b in (("’", "'"), ("‘", "'"), ("“", '"'), ("”", '"'),
                 ("–", "-"), ("—", "-")):
        text = text.replace(a, b)
    text = re.sub(r"\s+", " ", text).strip()
    return re.sub(r"\s+([.,;:])", r"\1", text)


def html_to_text(raw):
    raw = re.sub(r"<script.*?</script>|<style.*?</style>", " ", raw, flags=re.S)
    return html.unescape(re.sub(r"<[^>]+>", " ", raw))


def docjson_to_text(raw):
    parts = []

    def walk(node):
        if isinstance(node, dict):
            if node.get("type") == "text" and "text" in node:
                parts.append(node["text"])
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)

    walk(json.loads(raw))
    return " ".join(parts)


def load_source(name, cache_dir):
    url, kind = SOURCES[name]
    cache = os.path.join(cache_dir, name + ".txt") if cache_dir else None
    if cache and os.path.exists(cache):
        return open(cache, encoding="utf-8").read()
    request = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(request, timeout=60) as response:
        raw = response.read().decode("utf-8", errors="replace")
    text = normalize(docjson_to_text(raw) if kind == "docjson" else html_to_text(raw))
    if cache:
        os.makedirs(cache_dir, exist_ok=True)
        open(cache, "w", encoding="utf-8").write(text)
    return text


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    doc_path = argv[1]
    cache_dir = argv[argv.index("--cache-dir") + 1] if "--cache-dir" in argv else None
    doc = open(doc_path, encoding="utf-8").read()
    quotes = re.findall(r"^> \[(\w+)(?: ([^\]]*))?\] (.+)$", doc, flags=re.M)
    if not quotes:
        print("실패: 인용문이 하나도 없다")
        return 1

    texts, failures = {}, []
    for source in sorted({q[0] for q in quotes}):
        if source not in SOURCES:
            failures.append(f"알 수 없는 출처: {source}")
            continue
        try:
            texts[source] = load_source(source, cache_dir)
        except Exception as error:  # 네트워크·파싱 실패는 코드 2로 구분한다
            print(f"원문을 가져오지 못함: {source}: {error}")
            return 2
        digest = hashlib.sha256(texts[source].encode("utf-8")).hexdigest()[:16]
        print(f"원문 {source}: {len(texts[source])}자, sha256[:16]={digest}")

    for source, label, quote in quotes:
        if source not in texts:
            continue
        haystack, position, ok = texts[source], 0, True
        for segment in re.split(r"\s*(?:…|\[\.\.\.\])\s*", normalize(quote)):
            if not segment:
                continue
            found = haystack.find(segment, position)
            if found < 0:
                ok = False
                failures.append(f"원문에 없음 [{source} {label or ''}]: {segment[:90]}")
                break
            position = found + len(segment)
        print(("일치 " if ok else "불일치 ") + f"[{source} {label or ''}] {normalize(quote)[:70]}")

    if "guidelines" in texts:
        match = re.search(r"Last Updated:?\s*([A-Za-z]+) (\d{1,2}), (\d{4})", texts["guidelines"])
        if not match:
            failures.append("지침 페이지에서 갱신 날짜를 찾지 못함")
        else:
            iso = f"{int(match.group(3)):04d}-{MONTHS[match.group(1)]:02d}-{int(match.group(2)):02d}"
            print(f"지침 페이지 갱신 날짜: {iso}")
            if iso not in doc:
                failures.append(f"문서 기준 날짜가 지침 페이지 판({iso})과 다르다")

    if failures:
        print("실패:")
        for failure in failures:
            print(" -", failure)
        return 1
    print(f"통과: 인용 {len(quotes)}개가 원문과 일치")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
