#!/usr/bin/env python3
"""docs/protocol.md 검사: JSON 예제 파싱, 필수 엔드포인트·오류 코드·C API 이름 존재, 예제 키 일치.

사용: python3 -I scripts/check_protocol_examples.py docs/protocol.md
종료 코드 0이면 통과, 1이면 실패 사유를 출력한다.
"""
import json
import re
import sys

ENDPOINTS = [
    "/v1/info", "/v1/builds", "/v1/pair/request", "/v1/pair/request/{requestId}",
    "/v1/builds/{id}/sessions", "/v1/sessions/{sessionId}",
    "/i/{token}/manifest.plist", "/i/{token}/app.ipa",
]
ERROR_CODES = [
    "bad_request", "not_paired", "pair_code_invalid", "token_invalid", "build_not_found",
    "build_changed", "session_expired", "not_debug_build", "too_many_attempts", "internal",
    "invalid_config", "not_running", "unknown_handle", "path_outside_publish_dir", "hash_mismatch",
]
C_API = [
    "rd_start", "rd_status", "rd_stop", "rd_host_publish", "rd_host_unpublish", "rd_host_set_devices",
    "rd_host_pairing_open", "rd_host_pairing_decide", "rd_proxy_start", "rd_next_event", "rd_free",
]
EVENT_TYPES = ["state", "pair-request", "pair-decided", "device-added", "denied", "session", "log"]
DESCRIPTOR_KEYS = {"id", "bundleId", "displayName", "version", "buildNumber", "minOS", "debug",
                   "configuration", "configurationEvidence", "signing", "ipa", "publishedAt"}
SIGNING_KEYS = {"teamId", "profileName", "profileExpires", "provisionedDeviceCount", "getTaskAllow"}
STATUS_KEYS = {"backendState", "authURL", "hostname", "fqdn", "tailscaleIPs", "certDomains",
               "tlsReady", "listening", "publishedBuilds", "pairedDevices", "rssMiB"}
CONFIG_KEYS = {"mode", "stateDir", "hostname", "authKey", "controlURL", "ephemeral", "listenTLS",
               "port", "publishDir", "allowedTargets", "goMemLimitMiB", "logPath"}


def main(path):
    text = open(path, encoding="utf-8").read()
    problems = []

    blocks = re.findall(r"```json\n(.*?)```", text, flags=re.S)
    parsed = []
    for index, block in enumerate(blocks, 1):
        try:
            parsed.append(json.loads(block))
        except json.JSONDecodeError as error:
            problems.append(f"JSON 예제 {index} 파싱 실패: {error}")
    if len(blocks) < 10:
        problems.append(f"JSON 예제가 너무 적다: {len(blocks)}")

    for name, items in (("엔드포인트", ENDPOINTS), ("C API", C_API)):
        for item in items:
            if item not in text:
                problems.append(f"{name} 누락: {item}")
    for code in ERROR_CODES:
        if f"`{code}`" not in text:
            problems.append(f"오류 코드 표기 누락: {code}")
    for event in EVENT_TYPES:
        if f"`{event}`" not in text:
            problems.append(f"이벤트 타입 누락: {event}")

    def find(keys):
        return next((d for d in parsed if isinstance(d, dict) and keys <= set(d)), None)

    descriptor = find(DESCRIPTOR_KEYS)
    if descriptor is None:
        problems.append("BuildDescriptor 예제의 키가 계약과 다르다")
    elif not SIGNING_KEYS <= set(descriptor["signing"]) or set(descriptor["ipa"]) != {"size", "sha256"}:
        problems.append("BuildDescriptor.signing/ipa 키가 계약과 다르다")
    elif descriptor["debug"] is not True or descriptor["signing"]["getTaskAllow"] is not True:
        problems.append("BuildDescriptor 예제는 debug=true, getTaskAllow=true 여야 한다")
    elif len(descriptor["ipa"]["sha256"]) != 64:
        problems.append("ipa.sha256 예제는 64자리여야 한다")

    if find(STATUS_KEYS) is None:
        problems.append("상태 JSON 예제의 키가 계약과 다르다")
    config = find({"mode", "stateDir"})
    if config is None or set(config) != CONFIG_KEYS:
        problems.append("rd_start 설정 예제의 키가 계약과 다르다")

    session = find({"sessionId", "manifestUrl", "installUrl", "expiresAt"})
    if session is None:
        problems.append("설치 세션 예제 누락")
    elif not session["manifestUrl"].startswith("https://") or not session["installUrl"].startswith("itms-services://"):
        problems.append("설치 세션 예제의 URL 형식이 잘못됨")

    if "<key>software-package</key>" in text or "software-package" not in text:
        problems.append("OTA 매니페스트 예제에 software-package 자산이 있어야 한다")

    if problems:
        print("실패:")
        for problem in problems:
            print(" -", problem)
        return 1
    print(f"통과: JSON 예제 {len(blocks)}개, 엔드포인트 {len(ENDPOINTS)}개, 오류 코드 {len(ERROR_CODES)}개, "
          f"C API {len(C_API)}개, 이벤트 {len(EVENT_TYPES)}개")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
