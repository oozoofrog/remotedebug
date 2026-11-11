// RemoteDebug 설치 페이지의 순수 로직. DOM·네트워크·저장소에 접근하지 않는다.
// 모든 함수는 전역 RDLogic 하나에 담긴다. Packages/WebPage 테스트가 JavaScriptCore에서 이 파일을 불러 검사한다.
// 문구와 규칙은 iPhone 앱(Packages/PhoneClient)과 같다.
(function (root) {
  "use strict";

  // MARK: 시간·제한 (ClientModel.Timing, HostAPI.Timeouts, protocol §4.3·§4.4)

  var POLL_INTERVAL_MS = 1000;
  var PAIRING_TIMEOUT_MS = 120 * 1000;
  var SESSION_TIMEOUT_MS = 600 * 1000;
  var REQUEST_TIMEOUT_MS = 10 * 1000;
  var CREATE_SESSION_TIMEOUT_MS = 60 * 1000;
  var MAX_DEVICE_NAME_BYTES = 200;
  var MAX_PLATFORM_BYTES = 200;
  var MAX_CLIENT_VERSION_BYTES = 100;
  var DEFAULT_DEVICE_NAME = "iPhone(Safari)";
  var PLATFORM = "Web";
  var CLIENT_VERSION = "web-1";
  var TOKEN_LENGTH = 43;

  // MARK: 안내 문구

  var messages = Object.freeze({
    // HostAPIError.userMessage
    not_paired: "이 iPhone은 Mac에서 승인되지 않았습니다. 다시 페어링하세요.",
    pair_code_invalid: "페어링 코드가 맞지 않거나 만료되었습니다. Mac에 표시된 코드를 확인하고 다시 입력하세요.",
    too_many_attempts: "코드를 너무 많이 틀렸습니다. Mac에서 새 페어링 코드를 연 뒤 다시 시도하세요.",
    token_invalid: "설치 세션을 확인할 수 없습니다. 다시 설치하세요.",
    session_expired: "설치 세션이 만료되었습니다. 다시 설치하세요.",
    build_not_found: "Mac에 이 빌드가 없습니다. 목록을 새로고침하세요.",
    build_changed: "Mac에서 빌드가 바뀌었습니다. 목록을 새로고침하세요.",
    not_debug_build: "디버그 빌드가 아니라서 설치할 수 없습니다. Mac에서 Debug 빌드를 게시하세요.",
    // 앱은 "iPhone 앱과 Mac 앱을 최신 버전으로 맞추세요"라고 쓴다. 이 페이지는 Mac 앱이 직접 내주므로 Mac 앱만 말한다.
    unsupported: "Mac 앱이 이 요청을 처리하지 못했습니다. Mac 앱을 최신 버전으로 업데이트한 뒤 이 페이지를 새로고침하세요.",
    internal: "Mac 앱에서 오류가 났습니다. 잠시 뒤 다시 시도하세요.",
    connection_failed: "Mac에 연결할 수 없습니다. iPhone의 VPN이 켜져 있는지, Mac 앱이 공유 중인지 확인하세요.",
    protocol_mismatch: "Mac 앱과 통신 규약 버전이 다릅니다. Mac 앱을 최신 버전으로 업데이트한 뒤 이 페이지를 새로고침하세요.",
    unknown: "Mac에서 알 수 없는 응답을 받았습니다. 잠시 뒤 다시 시도하세요.",
    // PairingLinkError.userMessage
    invalidCodeLength: "페어링 코드는 8자입니다. Mac에 표시된 코드를 다시 확인하세요.",
    invalidCodeCharacters: "페어링 코드에 쓰지 않는 글자가 들어 있습니다. Mac에 표시된 코드를 다시 확인하세요.",
    // ClientModel
    pairingDenied: "Mac에서 페어링을 거절했습니다. 다시 하려면 Mac에서 새 코드를 여세요.",
    pairingExpired: "페어링 요청이 만료되었습니다. Mac에서 새 코드를 열고 다시 시도하세요.",
    // 이 페이지를 Mac의 설치 페이지 주소가 아닌 다른 주소로 열면 설치 주소의 출처가 달라 여기로 온다.
    untrustedInstallURL: "설치 주소가 이 페이지를 연 주소와 달라 열지 않았습니다. Mac 앱 네트워크 화면의 ‘설치 페이지’ 주소로 이 페이지를 다시 연 뒤 설치하세요. 그래도 같으면 Mac 앱을 최신 버전으로 업데이트하세요.",
    sessionFailed: "Mac에서 설치를 중단했습니다. Mac에서 빌드를 내렸거나 이 기기의 페어링이 해제되었을 수 있습니다. 빌드 목록을 새로고침하세요.",
    installTimeout: "제한 시간 안에 전송이 끝났는지 확인하지 못했습니다. 홈 화면에서 앱이 설치되었는지 확인하고, 없으면 다시 설치하세요.",
    createSessionTimeout: "Mac이 빌드를 확인하는 동안 응답 시간이 지났습니다. 잠시 뒤 다시 설치하세요.",
    // InstallState
    developerModeHint: "앱이 실행되지 않으면 설정 > 개인정보 보호 및 보안 > 개발자 모드가 켜져 있는지 확인하세요.",
    completedSent: "Mac이 빌드를 모두 보냈습니다. 설치 진행은 홈 화면의 앱 아이콘에서 확인하세요.",
    expired: "설치 세션이 만료되었습니다. 다시 설치하세요.",
    // 화면 상태
    preparing: "Mac이 빌드를 확인하는 중",
    waitingForInstaller: "설치 창에서 ‘설치’를 누르세요",
    completedTitle: "전송 완료"
  });

  // MARK: 페어링 코드 (PairingCode.parse)

  // Crockford base32 8자. 하이픈·공백·탭을 무시하고 대소문자를 가리지 않는다. O→0, I/L→1.
  // U와 영문·숫자가 아닌 글자는 거부한다.
  // 결과: { code: "K7M29QXD" } 또는 { error: "invalidCodeCharacters" | "invalidCodeLength" }.
  function normalizeCode(text) {
    var out = "";
    var bad = false;
    var upper = String(text == null ? "" : text).toUpperCase();
    for (var ch of upper) {
      if (ch === "-" || ch === " " || ch === "\t") continue;
      if (ch === "O") out += "0";
      else if (ch === "I" || ch === "L") out += "1";
      else if (ch === "U") bad = true;
      else if (/^[A-Z0-9]$/.test(ch)) out += ch;
      else bad = true;
    }
    if (bad) return { error: "invalidCodeCharacters" };
    if (out.length !== 8) return { error: "invalidCodeLength" };
    return { code: out };
  }

  function isValidCode(text) {
    return typeof normalizeCode(text).code === "string";
  }

  // 화면 표시용 K7M2-9QXD. 올바른 코드가 아니면 "".
  function displayCode(text) {
    var r = normalizeCode(text);
    return r.code ? r.code.slice(0, 4) + "-" + r.code.slice(4) : "";
  }

  // MARK: URL 조각

  // "#code=K7M2-9QXD" 꼴의 조각에서 코드를 읽는다. 없거나 두 번 이상 있거나 잘못 인코딩됐으면 code는 null.
  function parseFragment(hash) {
    var text = String(hash == null ? "" : hash);
    if (text.charAt(0) === "#") text = text.slice(1);
    var found = [];
    if (text !== "") {
      var parts = text.split("&");
      for (var i = 0; i < parts.length; i++) {
        var eq = parts[i].indexOf("=");
        if (eq < 0) continue;
        if (parts[i].slice(0, eq) !== "code") continue;
        var value;
        try {
          value = decodeURIComponent(parts[i].slice(eq + 1));
        } catch (e) {
          return { code: null };
        }
        found.push(value);
      }
    }
    if (found.length !== 1) return { code: null };
    var code = found[0].trim();
    if (code === "" || code.length > 32) return { code: null };
    return { code: code };
  }

  // MARK: 설치 주소 (ClientModel.isTrustedInstallURL)

  function isToken(text) {
    return text.length === TOKEN_LENGTH && /^[A-Za-z0-9_-]+$/.test(text);
  }

  // origin은 location.origin(Mac의 MagicDNS 이름을 쓴 https 출처)이다.
  // 설치 주소는 itms-services://?action=download-manifest&url=<매니페스트> 꼴이어야 한다:
  // authority·경로·조각이 없고, 쿼리는 action과 url 하나씩뿐이며, 매니페스트는 정확히
  // <origin>/i/<43자 base64url 토큰>/manifest.plist이고 같은 응답의 manifestUrl과 같다.
  function trustedInstallURL(installUrl, manifestUrl, origin) {
    if (typeof installUrl !== "string" || typeof manifestUrl !== "string" || typeof origin !== "string") return false;
    if (!/^(https|http):\/\/[a-z0-9.-]+(:[0-9]{1,5})?$/.test(origin)) return false;
    if (!/^[\x21-\x7e]+$/.test(installUrl)) return false;
    var prefix = "itms-services://?";
    if (installUrl.slice(0, prefix.length) !== prefix) return false;
    var query = installUrl.slice(prefix.length);
    if (query.indexOf("#") >= 0) return false;
    var items = query.split("&");
    if (items.length !== 2) return false;
    var action = null, url = null, actions = 0, urls = 0;
    for (var i = 0; i < items.length; i++) {
      var eq = items[i].indexOf("=");
      if (eq < 0) return false;
      var name, value;
      try {
        name = decodeURIComponent(items[i].slice(0, eq));
        value = decodeURIComponent(items[i].slice(eq + 1));
      } catch (e) {
        return false;
      }
      if (name === "action") { actions++; action = value; }
      else if (name === "url") { urls++; url = value; }
      else return false;
    }
    if (actions !== 1 || urls !== 1 || action !== "download-manifest") return false;
    var base = origin + "/i/";
    var suffix = "/manifest.plist";
    if (url.slice(0, base.length) !== base) return false;
    if (url.length <= base.length + suffix.length || url.slice(url.length - suffix.length) !== suffix) return false;
    if (!isToken(url.slice(base.length, url.length - suffix.length))) return false;
    return url === manifestUrl;
  }

  // MARK: 응답 해석 (HostAPI.call)

  // 결과: { ok: true, status, data } 또는 { ok: false, status, code }.
  // X-RD-Protocol이 없으면 중간에서 끊긴 응답(4xx·5xx는 연결 실패, 그 밖은 규약 불일치)이다.
  function classifyResponse(status, protocolHeader, bodyText) {
    if (protocolHeader == null) {
      return { ok: false, status: status, code: status >= 400 ? "connection_failed" : "protocol_mismatch" };
    }
    if (String(protocolHeader).trim() !== "1") return { ok: false, status: status, code: "protocol_mismatch" };
    var body = null;
    try {
      body = JSON.parse(bodyText);
    } catch (e) {
      body = null;
    }
    if (status < 200 || status > 299) {
      if (body && body.error && typeof body.error.code === "string") {
        return { ok: false, status: status, code: body.error.code };
      }
      return { ok: false, status: status, code: "invalid_response" };
    }
    if (body === null || typeof body !== "object") return { ok: false, status: status, code: "invalid_response" };
    return { ok: true, status: status, data: body };
  }

  // HostAPIError.userMessage와 같은 안내.
  function messageForError(status, code) {
    switch (code) {
      case "not_paired":
      case "pair_code_invalid":
      case "too_many_attempts":
      case "token_invalid":
      case "session_expired":
      case "build_not_found":
      case "build_changed":
      case "not_debug_build":
      case "internal":
      case "connection_failed":
      case "protocol_mismatch":
        return messages[code];
      case "timed_out":
        return messages.connection_failed;
      case "not_found":
      case "method_not_allowed":
      case "bad_request":
        return messages.unsupported;
      default:
        return messages.unknown;
    }
  }

  function isConnectionFailure(code) {
    return code === "connection_failed" || code === "timed_out";
  }

  // MARK: 페어링 요청

  // 앞뒤 공백을 지우고 UTF-8 maxBytes 안에 들어가게 글자 경계에서 자른다(HostAPI.truncated).
  function truncateUTF8(text, maxBytes) {
    var trimmed = String(text == null ? "" : text).trim();
    var pieces;
    if (typeof Intl !== "undefined" && typeof Intl.Segmenter === "function") {
      pieces = [];
      var it = new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(trimmed);
      for (var seg of it) pieces.push(seg.segment);
    } else {
      pieces = Array.from(trimmed);
    }
    var out = "";
    var used = 0;
    for (var i = 0; i < pieces.length; i++) {
      var n = utf8Length(pieces[i]);
      if (used + n > maxBytes) break;
      out += pieces[i];
      used += n;
    }
    return out.trim();
  }

  function utf8Length(s) {
    var n = 0;
    for (var ch of s) {
      var c = ch.codePointAt(0);
      n += c < 0x80 ? 1 : c < 0x800 ? 2 : c < 0x10000 ? 3 : 4;
    }
    return n;
  }

  // POST /v1/pair/request 본문. 코드가 올바르지 않으면 { error }.
  function pairRequestBody(codeText, deviceName) {
    var parsed = normalizeCode(codeText);
    if (!parsed.code) return { error: parsed.error };
    var name = truncateUTF8(deviceName, MAX_DEVICE_NAME_BYTES);
    if (name === "") name = DEFAULT_DEVICE_NAME;
    return {
      body: {
        code: parsed.code,
        deviceName: name,
        platform: truncateUTF8(PLATFORM, MAX_PLATFORM_BYTES),
        clientVersion: truncateUTF8(CLIENT_VERSION, MAX_CLIENT_VERSION_BYTES)
      }
    };
  }

  // 경로에 넣는 식별자는 [A-Za-z0-9_-] 1~128자만 받는다(HostAPI.checkedID).
  function isSafeID(id) {
    return typeof id === "string" && id.length >= 1 && id.length <= 128 && /^[A-Za-z0-9_-]+$/.test(id);
  }

  // 승인 대기 마감: 지금부터 120초와 호스트 expiresAt 중 이른 쪽(ClientModel.runPairing).
  function pairingDeadline(nowMs, expiresAt) {
    var deadline = nowMs + PAIRING_TIMEOUT_MS;
    var t = typeof expiresAt === "string" ? Date.parse(expiresAt) : NaN;
    if (!isNaN(t) && t > nowMs && t < deadline) deadline = t;
    return deadline;
  }

  // 페어링 상태 응답의 결과: "wait" | "approved" | { message }.
  function pairingOutcome(state) {
    switch (state) {
      case "pending": return "wait";
      case "approved": return "approved";
      case "denied": return { message: messages.pairingDenied };
      case "expired": return { message: messages.pairingExpired };
      default: return { message: messages.unknown };
    }
  }

  // sessionStorage에 둔 승인 대기 기록을 읽는다. 형식이 틀리면 null.
  function parseStoredPairing(text) {
    var v;
    try {
      v = JSON.parse(text);
    } catch (e) {
      return null;
    }
    if (!v || typeof v !== "object") return null;
    if (!isSafeID(v.requestId)) return null;
    if (typeof v.deadline !== "number" || !isFinite(v.deadline)) return null;
    var name = typeof v.deviceName === "string" ? truncateUTF8(v.deviceName, MAX_DEVICE_NAME_BYTES) : "";
    return { requestId: v.requestId, deadline: v.deadline, deviceName: name || DEFAULT_DEVICE_NAME };
  }

  function serializePairing(p) {
    return JSON.stringify({ requestId: p.requestId, deadline: p.deadline, deviceName: p.deviceName });
  }

  // MARK: 폴링

  // 다음 확인까지 기다릴 시간(ms). 마감이 지났으면 null(마지막으로 한 번 확인하고 끝낸다).
  // 앱과 같이 1초 간격이고, 연결 실패도 같은 간격으로 마감까지 다시 시도한다. 마감을 넘겨 기다리지 않는다.
  function nextPollDelay(nowMs, deadlineMs) {
    if (!(nowMs < deadlineMs)) return null;
    return Math.min(POLL_INTERVAL_MS, deadlineMs - nowMs);
  }

  // 남은 시간 "m:ss"와 읽기용 문구.
  function remainingText(ms) {
    var s = Math.max(0, Math.ceil(ms / 1000));
    var m = Math.floor(s / 60);
    var r = s % 60;
    return { text: m + ":" + (r < 10 ? "0" : "") + r, label: "남은 시간 " + m + "분 " + r + "초", low: s <= 30 };
  }

  // MARK: 표시

  // ByteCountFormatter(.file)처럼 1000 단위로 적는다.
  function formatSize(bytes) {
    var b = typeof bytes === "number" && isFinite(bytes) && bytes > 0 ? bytes : 0;
    if (b < 1000) return b + "바이트";
    if (b < 1000 * 1000) return Math.round(b / 1000) + " KB";
    if (b < 1000 * 1000 * 1000) return (b / 1e6).toFixed(1) + " MB";
    return (b / 1e9).toFixed(2) + " GB";
  }

  function pad2(n) {
    return (n < 10 ? "0" : "") + n;
  }

  // 마지막 새로고침 시각(현지 시각 HH:MM).
  function clockText(date) {
    return pad2(date.getHours()) + ":" + pad2(date.getMinutes());
  }

  // 빌드 한 줄에 보여 줄 값(BuildRow).
  function buildSummary(build, nowMs) {
    var b = build || {};
    var signing = b.signing || {};
    var ipa = b.ipa || {};
    var name = String(b.displayName || b.bundleId || "");
    var summary = {
      name: name,
      detail: "버전 " + String(b.version || "") + " (" + String(b.buildNumber || "") + ") · " + formatSize(ipa.size),
      bundleId: String(b.bundleId || ""),
      warning: null
    };
    var expires = typeof signing.profileExpires === "string" ? Date.parse(signing.profileExpires) : NaN;
    if (!isNaN(expires) && expires < nowMs) {
      var d = new Date(expires);
      var day = d.getUTCFullYear() + ". " + (d.getUTCMonth() + 1) + ". " + d.getUTCDate() + ".";
      summary.warning = "프로비저닝 프로파일이 " + day + "에 만료되었습니다. 설치해도 실행되지 않을 수 있습니다.";
    }
    return summary;
  }

  // 세션 상태를 화면 문구로 바꾼다.
  function progressText(session) {
    var s = session || {};
    switch (s.state) {
      case "created":
      case "manifest_served":
        return messages.waitingForInstaller;
      case "downloading":
        if (typeof s.size === "number" && s.size > 0) {
          return "전송 중 " + formatSize(s.bytesServed) + " / " + formatSize(s.size);
        }
        return "전송 중 " + formatSize(s.bytesServed);
      case "completed":
        return messages.completedSent + " " + messages.developerModeHint;
      case "expired":
        return messages.expired;
      case "failed":
        return messages.sessionFailed;
      default:
        return messages.unknown;
    }
  }

  // MARK: 설치 상태 (InstallState)

  // 상태 kind: "preparing" | "waiting" | "transferring" | "completed" | "expired" | "failed".
  // null은 설치 기록이 없는 것이다.
  function isInProgress(st) {
    return !!st && (st.kind === "preparing" || st.kind === "waiting" || st.kind === "transferring");
  }

  // 같은 빌드의 설치가 진행 중이면 새 세션을 만들지 않는다.
  function canStartInstall(st) {
    return !isInProgress(st);
  }

  function sessionStateToInstall(prev, status) {
    switch (status.state) {
      case "created":
      case "manifest_served":
        return { kind: "waiting", sessionId: prev.sessionId, href: prev.href, opened: prev.opened || status.state === "manifest_served", deadline: prev.deadline };
      case "downloading":
        return { kind: "transferring", sessionId: prev.sessionId, href: prev.href, deadline: prev.deadline, bytesServed: Number(status.bytesServed) || 0, size: Number(status.size) || 0 };
      case "completed":
        return { kind: "completed", message: messages.completedSent };
      case "expired":
        return { kind: "expired", message: messages.expired };
      case "failed":
        return { kind: "failed", message: messages.sessionFailed };
      default:
        return prev;
    }
  }

  function installErrorState(code, creating) {
    if (code === "session_expired") return { kind: "expired", message: messages.expired };
    if (creating && code === "timed_out") return { kind: "failed", message: messages.createSessionTimeout };
    return { kind: "failed", message: messageForError(0, code) };
  }

  // 설치 상태 전이. 이벤트:
  //   {type:"start"}                                   → preparing (진행 중이면 그대로)
  //   {type:"created", sessionId, installUrl, manifestUrl, origin, now}
  //                                                     → waiting 또는 주소가 믿을 수 없으면 failed
  //   {type:"opened"}                                  → waiting.opened = true
  //   {type:"status", state, bytesServed, size}        → waiting / transferring / 끝난 상태
  //   {type:"error", code, creating}                   → expired / failed (연결 실패는 진행 중이면 무시)
  //   {type:"deadline"}                                → 시간 초과(failed)
  //   {type:"cancel"}                                  → 설치 창을 기다릴 때만 null
  //   {type:"clear"}                                   → 끝난 상태만 null
  function installReducer(st, ev) {
    switch (ev.type) {
      case "start":
        return canStartInstall(st) ? { kind: "preparing" } : st;
      case "created":
        if (!st || st.kind !== "preparing") return st;
        if (!isSafeID(ev.sessionId) || !trustedInstallURL(ev.installUrl, ev.manifestUrl, ev.origin)) {
          return { kind: "failed", message: messages.untrustedInstallURL };
        }
        return { kind: "waiting", sessionId: ev.sessionId, href: ev.installUrl, opened: false, deadline: ev.now + SESSION_TIMEOUT_MS };
      case "opened":
        if (!st || st.kind !== "waiting") return st;
        return { kind: "waiting", sessionId: st.sessionId, href: st.href, opened: true, deadline: st.deadline };
      case "status":
        if (!st || (st.kind !== "waiting" && st.kind !== "transferring")) return st;
        return sessionStateToInstall(st, ev);
      case "error":
        if (!isInProgress(st)) return st;
        if (isConnectionFailure(ev.code) && !ev.creating) return st;
        return installErrorState(ev.code, !!ev.creating);
      case "deadline":
        if (!st || (st.kind !== "waiting" && st.kind !== "transferring")) return st;
        return { kind: "failed", message: messages.installTimeout };
      case "cancel":
        return st && st.kind === "waiting" ? null : st;
      case "clear":
        return isInProgress(st) ? st : null;
      default:
        return st;
    }
  }

  // 진행 확인이 필요한 상태인지(세션이 있고 끝나지 않음).
  function needsSessionPoll(st) {
    return !!st && (st.kind === "waiting" || st.kind === "transferring");
  }

  root.RDLogic = Object.freeze({
    POLL_INTERVAL_MS: POLL_INTERVAL_MS,
    PAIRING_TIMEOUT_MS: PAIRING_TIMEOUT_MS,
    SESSION_TIMEOUT_MS: SESSION_TIMEOUT_MS,
    REQUEST_TIMEOUT_MS: REQUEST_TIMEOUT_MS,
    CREATE_SESSION_TIMEOUT_MS: CREATE_SESSION_TIMEOUT_MS,
    MAX_DEVICE_NAME_BYTES: MAX_DEVICE_NAME_BYTES,
    DEFAULT_DEVICE_NAME: DEFAULT_DEVICE_NAME,
    messages: messages,
    normalizeCode: normalizeCode,
    isValidCode: isValidCode,
    displayCode: displayCode,
    parseFragment: parseFragment,
    trustedInstallURL: trustedInstallURL,
    classifyResponse: classifyResponse,
    messageForError: messageForError,
    isConnectionFailure: isConnectionFailure,
    truncateUTF8: truncateUTF8,
    pairRequestBody: pairRequestBody,
    isSafeID: isSafeID,
    pairingDeadline: pairingDeadline,
    pairingOutcome: pairingOutcome,
    parseStoredPairing: parseStoredPairing,
    serializePairing: serializePairing,
    nextPollDelay: nextPollDelay,
    remainingText: remainingText,
    formatSize: formatSize,
    clockText: clockText,
    buildSummary: buildSummary,
    progressText: progressText,
    isInProgress: isInProgress,
    canStartInstall: canStartInstall,
    installReducer: installReducer,
    needsSessionPoll: needsSessionPoll
  });
})(typeof globalThis !== "undefined" ? globalThis : this);
