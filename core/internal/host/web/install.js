// RemoteDebug 설치 페이지의 화면과 요청. 규칙과 문구는 logic.js(RDLogic)에 있다.
// 글자는 언제나 textContent로 넣는다(빌드 이름 등이 마크업으로 해석되지 않게).
(function (root) {
  "use strict";
  var L = root.RDLogic;

  // MARK: 요소 만들기

  // props: text, className, attrs(setAttribute로 넣을 값), type, disabled, hidden.
  function el(doc, tag, props, children) {
    var n = doc.createElement(tag);
    var p = props || {};
    if (p.className) n.className = p.className;
    if (p.type) n.type = p.type;
    if (p.disabled) n.disabled = true;
    if (p.hidden) n.hidden = true;
    if (p.attrs) {
      for (var k in p.attrs) {
        if (Object.prototype.hasOwnProperty.call(p.attrs, k)) n.setAttribute(k, String(p.attrs[k]));
      }
    }
    if (p.text != null) n.textContent = String(p.text);
    if (children) {
      for (var i = 0; i < children.length; i++) {
        if (children[i]) n.appendChild(children[i]);
      }
    }
    return n;
  }

  function button(doc, text, className, label, onClick) {
    var b = el(doc, "button", { type: "button", className: className, text: text, attrs: label ? { "aria-label": label } : null });
    if (onClick) b.addEventListener("click", onClick);
    return b;
  }

  function spinnerLine(doc, text) {
    return el(doc, "p", { className: "progress-line" }, [
      el(doc, "span", { className: "spinner", attrs: { "aria-hidden": "true" } }),
      el(doc, "span", { text: text })
    ]);
  }

  // 빌드 하나의 설치 영역. handlers: install, open, cancel, clear.
  function installArea(doc, build, st, handlers) {
    var name = L.buildSummary(build, 0).name;
    var nodes = [];
    if (!st) {
      nodes.push(button(doc, "설치", "primary", name + " 설치", function () { handlers.install(build); }));
    } else if (st.kind === "preparing") {
      nodes.push(spinnerLine(doc, L.messages.preparing));
    } else if (st.kind === "waiting") {
      var label = st.opened ? "다시 열기" : "설치 창 열기";
      var a = el(doc, "a", { className: "button primary", text: label, attrs: { href: st.href, "aria-label": name + " " + label, "data-primary": "1" } });
      a.addEventListener("click", function () { handlers.open(build, a); });
      nodes.push(a);
      nodes.push(el(doc, "p", { className: "hint", text: L.messages.waitingForInstaller }));
      nodes.push(button(doc, "취소", "secondary", name + " 설치 취소", function () { handlers.cancel(build); }));
    } else if (st.kind === "transferring") {
      var bar = el(doc, "progress", { attrs: { "aria-label": "전송" } });
      if (st.size > 0) {
        bar.max = st.size;
        bar.value = Math.min(st.bytesServed, st.size);
      }
      nodes.push(bar);
      nodes.push(el(doc, "p", { className: "hint", text: L.progressText({ state: "downloading", bytesServed: st.bytesServed, size: st.size }), attrs: { "aria-live": "off" } }));
    } else if (st.kind === "completed") {
      nodes.push(el(doc, "p", { className: "ok", text: "✓ " + L.messages.completedTitle }));
      nodes.push(el(doc, "p", { text: L.messages.completedSent }));
      nodes.push(el(doc, "p", { className: "hint", text: L.messages.developerModeHint }));
      nodes.push(button(doc, "확인", "secondary", null, function () { handlers.clear(build); }));
    } else {
      nodes.push(el(doc, "p", { className: st.kind === "expired" ? "warn" : "error", text: st.message }));
      nodes.push(el(doc, "div", { className: "actions" }, [
        button(doc, "다시 설치", "primary", name + " 다시 설치", function () { handlers.install(build); }),
        button(doc, "닫기", "secondary", null, function () { handlers.clear(build); })
      ]));
    }
    return nodes;
  }

  // 빌드 목록의 한 항목.
  function buildItem(doc, build, st, nowMs, handlers) {
    var s = L.buildSummary(build, nowMs);
    var area = el(doc, "div", { className: "install", attrs: { "aria-live": "polite" } }, installArea(doc, build, st, handlers));
    return el(doc, "li", { className: "build" }, [
      el(doc, "h3", { text: s.name }),
      el(doc, "p", { className: "detail", text: s.detail }),
      el(doc, "p", { className: "bundle", text: s.bundleId }),
      s.warning ? el(doc, "p", { className: "warn", text: s.warning }) : null,
      area
    ]);
  }

  root.RDPage = Object.freeze({ el: el, installArea: installArea, buildItem: buildItem });

  if (root.RD_NO_AUTOSTART || typeof root.document === "undefined" || typeof root.fetch !== "function") return;

  // MARK: 앱

  var doc = root.document;
  var $ = function (id) { return doc.getElementById(id); };
  var STORE_KEY = "rd.pairing";

  var app = {
    builds: [],
    loadedAt: null,
    installs: {},
    pollers: {},
    keys: {},
    pairing: null,
    pairTimer: null,
    countdownTimer: null,
    refreshing: false,
    settled: false
  };

  // MARK: 저장소 (없어도 동작한다)

  function storeLoad() {
    try {
      var t = root.sessionStorage.getItem(STORE_KEY);
      return t ? L.parseStoredPairing(t) : null;
    } catch (e) {
      return null;
    }
  }

  function storeSave(p) {
    try { root.sessionStorage.setItem(STORE_KEY, L.serializePairing(p)); } catch (e) { /* 저장소 없이 계속한다 */ }
  }

  function storeClear() {
    try { root.sessionStorage.removeItem(STORE_KEY); } catch (e) { /* 저장소 없이 계속한다 */ }
  }

  // MARK: 요청

  function api(method, path, body, timeoutMs) {
    var ctrl = typeof AbortController === "function" ? new AbortController() : null;
    var timedOut = false;
    var timer = setTimeout(function () {
      timedOut = true;
      if (ctrl) ctrl.abort();
    }, timeoutMs || L.REQUEST_TIMEOUT_MS);
    var init = {
      method: method,
      headers: { "Accept": "application/json", "X-RD-Client": "Web/1" },
      cache: "no-store",
      credentials: "omit",
      redirect: "error"
    };
    if (ctrl) init.signal = ctrl.signal;
    if (body) {
      init.headers["Content-Type"] = "application/json";
      init.body = JSON.stringify(body);
    }
    return root.fetch(path, init).then(function (res) {
      return res.text().then(function (text) {
        clearTimeout(timer);
        return L.classifyResponse(res.status, res.headers.get("X-RD-Protocol"), text);
      });
    }).catch(function () {
      clearTimeout(timer);
      return { ok: false, status: 0, code: timedOut ? "timed_out" : "connection_failed" };
    });
  }

  // MARK: 화면 전환

  var views = ["loading", "error", "pair", "waiting", "builds"];

  function show(view, focus) {
    for (var i = 0; i < views.length; i++) $("view-" + views[i]).hidden = views[i] !== view;
    // 처음 그린 화면은 초점을 옮기지 않고, 그 뒤 바뀐 화면은 초점을 옮긴다. 알림이 떠 있으면 알림으로 보내
    // 이유를 먼저 읽게 하고, 없으면 새 화면의 제목으로 보낸다. 알림은 aria-live 없이 초점으로만 알린다:
    // 보이게 하는 순간 쓴 live region은 읽히지 않고, 초점 이동과 겹치면 한쪽이 잘리거나 두 번 읽힌다.
    if (focus && app.settled) {
      var target = $("notice").hidden ? $("view-" + view).querySelector("h2") : $("notice");
      if (target) target.focus();
    }
    if (view !== "loading") app.settled = true;
  }

  function notice(text, isError) {
    var n = $("notice");
    n.textContent = text || "";
    n.className = "notice" + (isError ? " error" : "");
    n.hidden = !text;
  }

  // MARK: 빌드 목록

  function loadBuilds(initial) {
    if (app.refreshing) return;
    app.refreshing = true;
    var btn = $("refresh");
    btn.disabled = true;
    btn.textContent = "받는 중";
    if (initial) show("loading", false);
    api("GET", "/v1/builds").then(function (r) {
      app.refreshing = false;
      btn.disabled = false;
      btn.textContent = "새로고침";
      if (r.ok && Array.isArray(r.data.builds)) {
        app.builds = r.data.builds.filter(function (b) { return b && L.isSafeID(b.id); });
        app.loadedAt = new Date();
        $("refresh-error").hidden = true;
        renderBuilds();
        var wasHidden = $("view-builds").hidden;
        show("builds", wasHidden);
        loadInfo();
        return;
      }
      var code = r.ok ? "invalid_response" : r.code;
      if (code === "not_paired") {
        clearBuilds();
        showPairForm(initial ? null : L.messageForError(r.status, code));
        return;
      }
      var msg = L.messageForError(r.status, code);
      if (app.loadedAt) {
        var re = $("refresh-error");
        re.textContent = "목록을 새로 받지 못했습니다. 아래는 이전 목록입니다. " + msg;
        re.hidden = false;
        re.focus();
      } else {
        $("error-text").textContent = msg;
        show("error", true);
      }
    });
  }

  function loadInfo() {
    api("GET", "/v1/info").then(function (r) {
      if (!r.ok) return;
      var name = typeof r.data.hostName === "string" ? r.data.hostName : "";
      var fqdn = typeof r.data.fqdn === "string" ? r.data.fqdn.replace(/\.$/, "") : "";
      var line = [name, fqdn].filter(function (s) { return s; }).join(" · ");
      if (line) $("host-line").textContent = line;
    });
  }

  function renderBuilds() {
    var list = $("build-list");
    var focusedId = activeBuildId();
    while (list.firstChild) list.removeChild(list.firstChild);
    var now = Date.now();
    for (var i = 0; i < app.builds.length; i++) {
      var b = app.builds[i];
      var item = buildItem(doc, b, app.installs[b.id] || null, now, handlers);
      item.setAttribute("data-build", b.id);
      list.appendChild(item);
      app.keys[b.id] = renderKey(app.installs[b.id]);
    }
    $("empty").hidden = app.builds.length !== 0;
    $("loaded-at").textContent = app.loadedAt ? L.clockText(app.loadedAt) + "에 받은 목록" : "";
    if (focusedId) focusInstall(focusedId);
  }

  function activeBuildId() {
    var a = doc.activeElement;
    while (a && a !== doc.body) {
      if (a.getAttribute && a.getAttribute("data-build")) return a.getAttribute("data-build");
      a = a.parentNode;
    }
    return null;
  }

  function findItem(id) {
    var items = $("build-list").children;
    for (var i = 0; i < items.length; i++) {
      if (items[i].getAttribute("data-build") === id) return items[i];
    }
    return null;
  }

  function findBuild(id) {
    for (var i = 0; i < app.builds.length; i++) if (app.builds[i].id === id) return app.builds[i];
    return null;
  }

  function focusInstall(id) {
    var item = findItem(id);
    if (!item) return;
    var target = item.querySelector(".install [data-primary]") || item.querySelector(".install button");
    if (target) target.focus();
  }

  function renderKey(st) {
    if (!st) return "none";
    if (st.kind === "transferring") return "transferring";
    return st.kind + (st.opened ? ":opened" : "");
  }

  // 설치 상태를 바꾸고 그 빌드의 설치 영역만 다시 그린다.
  function setInstall(id, st) {
    if (st) app.installs[id] = st; else delete app.installs[id];
    var item = findItem(id);
    var build = findBuild(id);
    if (!item || !build) return;
    var area = item.querySelector(".install");
    var key = renderKey(st);
    if (app.keys[id] === key && st && st.kind === "transferring") {
      var bar = area.querySelector("progress");
      if (bar && st.size > 0) {
        bar.max = st.size;
        bar.value = Math.min(st.bytesServed, st.size);
      }
      var p = area.querySelector("p");
      if (p) p.textContent = L.progressText({ state: "downloading", bytesServed: st.bytesServed, size: st.size });
      return;
    }
    if (app.keys[id] === key) return;
    var hadFocus = activeBuildId() === id;
    while (area.firstChild) area.removeChild(area.firstChild);
    var nodes = installArea(doc, build, st || null, handlers);
    for (var i = 0; i < nodes.length; i++) area.appendChild(nodes[i]);
    app.keys[id] = key;
    if (hadFocus) focusInstall(id);
  }

  // MARK: 설치

  var handlers = {
    install: startInstall,
    open: function (build, anchor) {
      // 링크의 기본 동작(설치 창 열기)을 막지 않도록 요소를 바꾸지 않고 글자만 고친다.
      var st = L.installReducer(app.installs[build.id] || null, { type: "opened" });
      app.installs[build.id] = st;
      app.keys[build.id] = renderKey(st);
      anchor.textContent = "다시 열기";
      anchor.setAttribute("aria-label", L.buildSummary(build, 0).name + " 다시 열기");
    },
    cancel: function (build) {
      clearTimeout(app.pollers[build.id]);
      setInstall(build.id, L.installReducer(app.installs[build.id] || null, { type: "cancel" }));
      focusInstall(build.id);
    },
    clear: function (build) {
      setInstall(build.id, L.installReducer(app.installs[build.id] || null, { type: "clear" }));
      focusInstall(build.id);
    }
  };

  function startInstall(build) {
    var id = build.id;
    var cur = app.installs[id] || null;
    if (!L.canStartInstall(cur) || !L.isSafeID(id)) return;
    setInstall(id, L.installReducer(cur, { type: "start" }));
    api("POST", "/v1/builds/" + id + "/sessions", null, L.CREATE_SESSION_TIMEOUT_MS).then(function (r) {
      var st = app.installs[id] || null;
      if (!st || st.kind !== "preparing") return;
      if (!r.ok) {
        setInstall(id, L.installReducer(st, { type: "error", code: r.code, creating: true }));
        if (r.code === "not_paired") loadBuilds(false);
        return;
      }
      var d = r.data;
      setInstall(id, L.installReducer(st, {
        type: "created", sessionId: d.sessionId, installUrl: d.installUrl, manifestUrl: d.manifestUrl,
        origin: root.location.origin, now: Date.now()
      }));
      focusInstall(id);
      schedulePoll(id);
    });
  }

  function schedulePoll(id) {
    clearTimeout(app.pollers[id]);
    var st = app.installs[id];
    if (!L.needsSessionPoll(st)) return;
    var delay = L.nextPollDelay(Date.now(), st.deadline);
    if (delay === null) {
      pollSession(id, true);
      return;
    }
    app.pollers[id] = setTimeout(function () { pollSession(id, false); }, delay);
  }

  function pollSession(id, final) {
    var st = app.installs[id];
    if (!L.needsSessionPoll(st)) return;
    var sid = st.sessionId;
    api("GET", "/v1/sessions/" + sid).then(function (r) {
      var cur = app.installs[id];
      if (!L.needsSessionPoll(cur) || cur.sessionId !== sid) return;
      if (!r.ok && r.code === "not_paired") {
        // 설치 중에 Mac에서 이 기기가 허용 목록에서 빠졌다. 설치 시작과 같이 목록을 다시 받아 페어링 화면으로 보낸다.
        setInstall(id, L.installReducer(cur, { type: "error", code: r.code }));
        loadBuilds(false);
        return;
      }
      var terminal = r.ok && (r.data.state === "completed" || r.data.state === "expired" || r.data.state === "failed");
      if (final) {
        setInstall(id, terminal ? L.installReducer(cur, statusEvent(r.data)) : L.installReducer(cur, { type: "deadline" }));
        return;
      }
      setInstall(id, r.ok ? L.installReducer(cur, statusEvent(r.data)) : L.installReducer(cur, { type: "error", code: r.code }));
      schedulePoll(id);
    });
  }

  function statusEvent(d) {
    return { type: "status", state: d.state, bytesServed: d.bytesServed, size: d.size };
  }

  function stopAllInstalls() {
    for (var id in app.pollers) {
      if (Object.prototype.hasOwnProperty.call(app.pollers, id)) clearTimeout(app.pollers[id]);
    }
    app.pollers = {};
    app.installs = {};
    app.keys = {};
  }

  // 접근을 잃었거나 새 코드를 받았을 때: 진행 중인 설치와 이전 목록을 화면과 DOM에서 모두 치운다.
  function clearBuilds() {
    stopAllInstalls();
    app.builds = [];
    app.loadedAt = null;
    var list = $("build-list");
    while (list.firstChild) list.removeChild(list.firstChild);
    $("loaded-at").textContent = "";
    $("refresh-error").hidden = true;
  }

  // MARK: 페어링

  function showPairForm(message) {
    stopPairing();
    if (message) {
      notice(message, true);
    }
    show("pair", true);
  }

  function setCodeError(text) {
    var e = $("code-error");
    var input = $("code");
    e.textContent = text || "";
    e.hidden = !text;
    if (text) input.setAttribute("aria-invalid", "true"); else input.removeAttribute("aria-invalid");
  }

  function submitPairing(ev) {
    ev.preventDefault();
    notice("");
    var nameInput = $("device-name");
    var req = L.pairRequestBody($("code").value, nameInput.value);
    if (req.error) {
      setCodeError(L.messages[req.error]);
      $("code").focus();
      return;
    }
    setCodeError("");
    var submit = $("pair-submit");
    submit.disabled = true;
    submit.textContent = "페어링 요청을 보내는 중";
    api("POST", "/v1/pair/request", req.body).then(function (r) {
      submit.disabled = false;
      submit.textContent = "페어링 요청";
      if (!r.ok || !L.isSafeID(r.data.requestId)) {
        var code = r.ok ? "invalid_response" : r.code;
        var msg = L.messageForError(r.status, code);
        if (code === "pair_code_invalid" || code === "too_many_attempts") {
          setCodeError(msg);
          $("code").focus();
        } else {
          notice(msg, true);
          $("notice").focus();
        }
        return;
      }
      $("code").value = "";
      var p = { requestId: r.data.requestId, deadline: L.pairingDeadline(Date.now(), r.data.expiresAt), deviceName: req.body.deviceName };
      startWaiting(p, r.data.state);
    });
  }

  function startWaiting(p, firstState) {
    app.pairing = p;
    storeSave(p);
    $("waiting-text").textContent = "Mac 앱에서 ‘" + p.deviceName + "’의 페어링 요청을 승인하세요.";
    updateCountdown();
    clearInterval(app.countdownTimer);
    app.countdownTimer = setInterval(updateCountdown, 1000);
    show("waiting", true);
    if (firstState && firstState !== "pending") {
      applyPairing(firstState);
      return;
    }
    schedulePairPoll();
  }

  function updateCountdown() {
    if (!app.pairing) return;
    var r = L.remainingText(app.pairing.deadline - Date.now());
    var c = $("countdown");
    c.textContent = r.text;
    c.setAttribute("aria-label", r.label);
    c.className = r.low ? "low" : "";
  }

  function schedulePairPoll() {
    clearTimeout(app.pairTimer);
    var p = app.pairing;
    if (!p) return;
    var delay = L.nextPollDelay(Date.now(), p.deadline);
    if (delay === null) {
      pollPairing(true);
      return;
    }
    app.pairTimer = setTimeout(function () { pollPairing(false); }, delay);
  }

  function pollPairing(final) {
    var p = app.pairing;
    if (!p) return;
    api("GET", "/v1/pair/request/" + p.requestId).then(function (r) {
      if (app.pairing !== p) return;
      if (final) {
        if (r.ok && r.data.state !== "pending") applyPairing(r.data.state);
        else failPairing(L.messages.pairingExpired);
        return;
      }
      if (!r.ok) {
        if (L.isConnectionFailure(r.code)) {
          schedulePairPoll();
          return;
        }
        failPairing(L.messageForError(r.status, r.code));
        return;
      }
      if (r.data.state === "pending") {
        schedulePairPoll();
        return;
      }
      applyPairing(r.data.state);
    });
  }

  function applyPairing(state) {
    var out = L.pairingOutcome(state);
    if (out === "wait") {
      schedulePairPoll();
      return;
    }
    if (out === "approved") {
      stopPairing();
      notice("");
      loadBuilds(true);
      return;
    }
    failPairing(out.message);
  }

  function failPairing(message) {
    showPairForm(message);
  }

  function stopPairing() {
    clearTimeout(app.pairTimer);
    clearInterval(app.countdownTimer);
    app.pairing = null;
    storeClear();
  }

  // MARK: 시작

  // 주소의 #code= 조각에서 코드를 읽고 곧바로 주소에서 지운다(코드가 주소창·방문 기록에 남지 않게). 코드는 보내지 않는다.
  function takeFragmentCode() {
    var hash = root.location.hash;
    if (!hash) return null;
    var frag = L.parseFragment(hash);
    try {
      root.history.replaceState(null, "", root.location.pathname + root.location.search);
    } catch (e) { /* 조각을 지우지 못해도 계속한다 */ }
    return frag.code ? frag.code.toUpperCase() : null;
  }

  // 이미 열려 있는 탭의 주소창에 새 링크가 들어온 경우(주소의 조각만 바뀌면 페이지를 다시 읽지 않는다).
  // 낡은 목록·요청을 접고, 새 코드가 채워진 입력 화면으로 간다.
  function onHashChange() {
    var code = takeFragmentCode();
    if (!code) return;
    clearBuilds();
    notice("");
    setCodeError("");
    $("code").value = code;
    showPairForm(null);
  }

  function start() {
    var hostLine = $("host-line");
    hostLine.textContent = root.location.hostname;

    $("pair-form").addEventListener("submit", submitPairing);
    $("code").addEventListener("input", function () {
      var input = $("code");
      var pos = input.selectionStart;
      var upper = input.value.toUpperCase();
      if (upper !== input.value && upper.length === input.value.length) {
        input.value = upper;
        try { input.setSelectionRange(pos, pos); } catch (e) { /* 선택 범위를 지원하지 않는 입력 */ }
      }
      setCodeError("");
    });
    $("device-name").value = L.DEFAULT_DEVICE_NAME;
    $("pair-cancel").addEventListener("click", function () {
      stopPairing();
      notice("");
      show("pair", true);
    });
    $("refresh").addEventListener("click", function () { loadBuilds(false); });
    $("retry").addEventListener("click", function () { notice(""); loadBuilds(true); });

    var linked = takeFragmentCode();
    if (linked) $("code").value = linked;
    root.addEventListener("hashchange", onHashChange);

    var saved = storeLoad();
    if (saved) {
      startWaiting(saved, null);
    } else {
      loadBuilds(true);
    }
  }

  if (doc.readyState === "loading") doc.addEventListener("DOMContentLoaded", start);
  else start();
})(typeof globalThis !== "undefined" ? globalThis : this);
