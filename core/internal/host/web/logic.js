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

  // MARK: 언어

  // 페이지가 보여 줄 수 있는 한국어 원문마다 en·ja·zh-Hans·zh-Hant 번역 칸이 있다. 아래 표는 그대로 JSON이다
  // (scripts/check_strings.py가 읽는다). ""은 아직 번역하지 않은 것이고, 그 글자는 영어, 그다음 한국어 원문으로 보인다.
  // {name} 꼴의 자리표시는 번역에서도 같은 것을 써야 한다.
  // RD-STRINGS-BEGIN
  var STRINGS = {
    "en": {
      "RemoteDebug 빌드 설치": "Install RemoteDebug Build",
      "빌드 목록을 받는 중": "Downloading build list",
      "Mac에 연결하는 중": "Connecting to Mac",
      "빌드 목록을 받지 못했습니다": "Couldn't download the build list",
      "다시 시도": "Try Again",
      "Mac 페어링": "Mac Pairing",
      "Mac 앱의 페어링 화면에 표시된 코드를 입력하세요. Mac에서 승인하면 빌드 목록이 열립니다.": "Enter the code shown on the Mac app's Pairing screen. Once you approve it on the Mac, the build list opens.",
      "페어링 코드": "Pairing code",
      "기기 이름": "Device Name",
      "Mac의 승인 화면에 이 이름이 표시됩니다.": "This name is shown on the Mac's approval screen.",
      "페어링 요청": "Pairing request",
      "Mac의 승인을 기다리는 중": "Waiting for approval on the Mac",
      "남은 시간": "Time Remaining",
      "페어링 취소": "Cancel Pairing",
      "빌드": "Builds",
      "새로고침": "Refresh",
      "공유 중인 빌드가 없습니다": "No builds are being shared",
      "Mac 앱에서 빌드를 공유한 뒤 새로고침하세요.": "Share builds in the Mac app, then reload.",
      "이 페이지와 설치는 iPhone의 Tailscale VPN이 켜져 있어야 동작합니다.": "This page and installation work only while Tailscale VPN is on on the iPhone.",
      "이 iPhone은 Mac에서 승인되지 않았습니다. 다시 페어링하세요.": "This iPhone hasn't been approved on the Mac. Pair again.",
      "페어링 코드가 맞지 않거나 만료되었습니다. Mac에 표시된 코드를 확인하고 다시 입력하세요.": "The pairing code is incorrect or expired. Check the code shown on the Mac and enter it again.",
      "코드를 너무 많이 틀렸습니다. Mac에서 새 페어링 코드를 연 뒤 다시 시도하세요.": "Too many wrong codes. Open a new pairing code on the Mac and try again.",
      "설치 세션을 확인할 수 없습니다. 다시 설치하세요.": "Couldn't verify the install session. Install again.",
      "설치 세션이 만료되었습니다. 다시 설치하세요.": "The install session expired. Install again.",
      "Mac에 이 빌드가 없습니다. 목록을 새로고침하세요.": "This build isn't on the Mac. Refresh the list.",
      "Mac에서 빌드가 바뀌었습니다. 목록을 새로고침하세요.": "The build changed on the Mac. Refresh the list.",
      "디버그 빌드가 아니라서 설치할 수 없습니다. Mac에서 Debug 빌드를 게시하세요.": "This isn't a Debug build, so it can't be installed. Publish a Debug build from the Mac.",
      "Mac 앱이 이 요청을 처리하지 못했습니다. Mac 앱을 최신 버전으로 업데이트한 뒤 이 페이지를 새로고침하세요.": "The Mac app couldn't handle this request. Update the Mac app to the latest version, then reload this page.",
      "Mac 앱에서 오류가 났습니다. 잠시 뒤 다시 시도하세요.": "An error occurred in the Mac app. Try again in a moment.",
      "Mac에 연결할 수 없습니다. iPhone의 VPN이 켜져 있는지, Mac 앱이 공유 중인지 확인하세요.": "Can't connect to the Mac. Check that VPN is on in iPhone and that the Mac app is sharing.",
      "Mac 앱과 통신 규약 버전이 다릅니다. Mac 앱을 최신 버전으로 업데이트한 뒤 이 페이지를 새로고침하세요.": "The protocol version differs from the Mac app. Update the Mac app to the latest version, then reload this page.",
      "Mac에서 알 수 없는 응답을 받았습니다. 잠시 뒤 다시 시도하세요.": "Received an unknown response from the Mac. Try again in a moment.",
      "페어링 코드는 8자입니다. Mac에 표시된 코드를 다시 확인하세요.": "The pairing code is 8 characters. Check the code shown on the Mac again.",
      "페어링 코드에 쓰지 않는 글자가 들어 있습니다. Mac에 표시된 코드를 다시 확인하세요.": "The pairing code contains characters that aren't used. Check the code shown on the Mac again.",
      "Mac에서 페어링을 거절했습니다. 다시 하려면 Mac에서 새 코드를 여세요.": "The Mac declined pairing. To try again, open a new code on the Mac.",
      "페어링 요청이 만료되었습니다. Mac에서 새 코드를 열고 다시 시도하세요.": "The pairing request expired. Open a new code on the Mac and try again.",
      "설치 주소가 이 페이지를 연 주소와 달라 열지 않았습니다. Mac 앱 네트워크 화면의 ‘설치 페이지’ 주소로 이 페이지를 다시 연 뒤 설치하세요. 그래도 같으면 Mac 앱을 최신 버전으로 업데이트하세요.": "The install URL differs from the address that opened this page, so it wasn't opened. Reopen this page using the ‘Install Page’ address on the Mac app's Network screen, then install. If it's still the same, update the Mac app to the latest version.",
      "Mac에서 설치를 중단했습니다. Mac에서 빌드를 내렸거나 이 기기의 페어링이 해제되었을 수 있습니다. 빌드 목록을 새로고침하세요.": "The Mac stopped the installation. The build may have been taken down on the Mac, or this device may have been unpaired. Refresh the build list.",
      "제한 시간 안에 전송이 끝났는지 확인하지 못했습니다. 홈 화면에서 앱이 설치되었는지 확인하고, 없으면 다시 설치하세요.": "Couldn't confirm that the transfer finished in time. Check on the Home Screen whether the app was installed, and install again if not.",
      "Mac이 빌드를 확인하는 동안 응답 시간이 지났습니다. 잠시 뒤 다시 설치하세요.": "The response timed out while the Mac was checking the build. Install again in a moment.",
      "앱이 실행되지 않으면 설정 > 개인정보 보호 및 보안 > 개발자 모드가 켜져 있는지 확인하세요.": "If the app doesn't launch, check that Settings > Privacy & Security > Developer Mode is on.",
      "Mac이 빌드를 모두 보냈습니다. 설치 진행은 홈 화면의 앱 아이콘에서 확인하세요.": "The Mac has sent the whole build. Check installation progress on the app icon on the Home Screen.",
      "Mac이 빌드를 확인하는 중": "The Mac is checking the build",
      "설치 창에서 ‘설치’를 누르세요": "Tap ‘Install’ in the install window",
      "전송 완료": "Transfer complete",
      "남은 시간 {minutes}분 {seconds}초": "{minutes}m {seconds}s remaining",
      "{count}바이트": "{count} bytes",
      "버전 {version} ({build}) · {size}": "Version {version} ({build}) · {size}",
      "{year}. {month}. {day}.": "{month}/{day}/{year}",
      "프로비저닝 프로파일이 {date}에 만료되었습니다. 설치해도 실행되지 않을 수 있습니다.": "The provisioning profile expired on {date}. It might not run if installed.",
      "전송 중 {sent} / {total}": "Sending {sent} / {total}",
      "전송 중 {sent}": "Sending {sent}",
      "설치": "Install",
      "{name} 설치": "Install {name}",
      "다시 열기": "Reopen",
      "설치 창 열기": "Open Install Window",
      "{name} 다시 열기": "Reopen {name}",
      "{name} 설치 창 열기": "Open {name} Install Window",
      "취소": "Cancel",
      "{name} 설치 취소": "Cancel {name} Install",
      "전송": "Send",
      "확인": "OK",
      "다시 설치": "Install Again",
      "{name} 다시 설치": "Reinstall {name}",
      "닫기": "Close",
      "받는 중": "Downloading",
      "목록을 새로 받지 못했습니다. 아래는 이전 목록입니다. {message}": "Couldn't refresh the list. The previous list is shown below. {message}",
      "{time}에 받은 목록": "List downloaded at {time}",
      "페어링 요청을 보내는 중": "Sending pairing request",
      "Mac 앱에서 ‘{name}’의 페어링 요청을 승인하세요.": "Approve the pairing request from ‘{name}’ in the Mac app."
    },
    "ja": {
      "RemoteDebug 빌드 설치": "RemoteDebugビルドをインストール",
      "빌드 목록을 받는 중": "ビルドリストを取得中",
      "Mac에 연결하는 중": "Macに接続中",
      "빌드 목록을 받지 못했습니다": "ビルドリストを取得できませんでした",
      "다시 시도": "やり直す",
      "Mac 페어링": "Macのペアリング",
      "Mac 앱의 페어링 화면에 표시된 코드를 입력하세요. Mac에서 승인하면 빌드 목록이 열립니다.": "Macアプリのペアリング画面に表示されているコードを入力してください。Macで承認すると、ビルド一覧が開きます。",
      "페어링 코드": "ペアリングコード",
      "기기 이름": "デバイス名",
      "Mac의 승인 화면에 이 이름이 표시됩니다.": "Macの承認画面にこの名前が表示されます。",
      "페어링 요청": "ペアリングリクエスト",
      "Mac의 승인을 기다리는 중": "Macの承認を待っています",
      "남은 시간": "残り時間",
      "페어링 취소": "ペアリングをキャンセル",
      "빌드": "ビルド",
      "새로고침": "更新",
      "공유 중인 빌드가 없습니다": "共有中のビルドはありません",
      "Mac 앱에서 빌드를 공유한 뒤 새로고침하세요.": "Macアプリでビルドを共有してから、再読み込みしてください。",
      "이 페이지와 설치는 iPhone의 Tailscale VPN이 켜져 있어야 동작합니다.": "このページとインストールは、iPhone の Tailscale VPN がオンの場合のみ動作します。",
      "이 iPhone은 Mac에서 승인되지 않았습니다. 다시 페어링하세요.": "この iPhone は Mac で承認されていません。もう一度ペアリングしてください。",
      "페어링 코드가 맞지 않거나 만료되었습니다. Mac에 표시된 코드를 확인하고 다시 입력하세요.": "ペアリングコードが正しくないか、有効期限が切れています。Mac に表示されているコードを確認して、もう一度入力してください。",
      "코드를 너무 많이 틀렸습니다. Mac에서 새 페어링 코드를 연 뒤 다시 시도하세요.": "コードを何度も間違えました。Mac で新しいペアリングコードを開いてから、やり直してください。",
      "설치 세션을 확인할 수 없습니다. 다시 설치하세요.": "インストールセッションを確認できません。もう一度インストールしてください。",
      "설치 세션이 만료되었습니다. 다시 설치하세요.": "インストールセッションの有効期限が切れました。もう一度インストールしてください。",
      "Mac에 이 빌드가 없습니다. 목록을 새로고침하세요.": "Macにこのビルドがありません。一覧を再読み込みしてください。",
      "Mac에서 빌드가 바뀌었습니다. 목록을 새로고침하세요.": "Mac上でビルドが変更されました。一覧を再読み込みしてください。",
      "디버그 빌드가 아니라서 설치할 수 없습니다. Mac에서 Debug 빌드를 게시하세요.": "Debugビルドではないため、インストールできません。MacでDebugビルドを公開してください。",
      "Mac 앱이 이 요청을 처리하지 못했습니다. Mac 앱을 최신 버전으로 업데이트한 뒤 이 페이지를 새로고침하세요.": "Macアプリがこのリクエストを処理できませんでした。Macアプリを最新バージョンにアップデートしてから、このページを再読み込みしてください。",
      "Mac 앱에서 오류가 났습니다. 잠시 뒤 다시 시도하세요.": "Macアプリでエラーが発生しました。しばらくしてからやり直してください。",
      "Mac에 연결할 수 없습니다. iPhone의 VPN이 켜져 있는지, Mac 앱이 공유 중인지 확인하세요.": "Macに接続できません。iPhoneのVPNがオンになっているか、Macアプリが共有中かを確認してください。",
      "Mac 앱과 통신 규약 버전이 다릅니다. Mac 앱을 최신 버전으로 업데이트한 뒤 이 페이지를 새로고침하세요.": "Macアプリと通信プロトコルのバージョンが異なります。Macアプリを最新バージョンにアップデートしてから、このページを再読み込みしてください。",
      "Mac에서 알 수 없는 응답을 받았습니다. 잠시 뒤 다시 시도하세요.": "Macから不明な応答を受け取りました。しばらくしてからやり直してください。",
      "페어링 코드는 8자입니다. Mac에 표시된 코드를 다시 확인하세요.": "ペアリングコードは 8 文字です。Mac に表示されているコードをもう一度確認してください。",
      "페어링 코드에 쓰지 않는 글자가 들어 있습니다. Mac에 표시된 코드를 다시 확인하세요.": "ペアリングコードに使用できない文字が含まれています。Mac に表示されているコードをもう一度確認してください。",
      "Mac에서 페어링을 거절했습니다. 다시 하려면 Mac에서 새 코드를 여세요.": "Macでペアリングが拒否されました。やり直すには、Macで新しいコードを開いてください。",
      "페어링 요청이 만료되었습니다. Mac에서 새 코드를 열고 다시 시도하세요.": "ペアリングリクエストの有効期限が切れました。Mac で新しいコードを開いて、やり直してください。",
      "설치 주소가 이 페이지를 연 주소와 달라 열지 않았습니다. Mac 앱 네트워크 화면의 ‘설치 페이지’ 주소로 이 페이지를 다시 연 뒤 설치하세요. 그래도 같으면 Mac 앱을 최신 버전으로 업데이트하세요.": "インストール用アドレスがこのページを開いたアドレスと異なるため、開きませんでした。Mac App のネットワーク画面にある「インストールページ」のアドレスでこのページを開き直してから、インストールしてください。それでも同じ場合は、Mac App を最新バージョンにアップデートしてください。",
      "Mac에서 설치를 중단했습니다. Mac에서 빌드를 내렸거나 이 기기의 페어링이 해제되었을 수 있습니다. 빌드 목록을 새로고침하세요.": "Macでインストールが中断されました。Macでビルドが取り下げられたか、このデバイスのペアリングが解除された可能性があります。ビルド一覧を再読み込みしてください。",
      "제한 시간 안에 전송이 끝났는지 확인하지 못했습니다. 홈 화면에서 앱이 설치되었는지 확인하고, 없으면 다시 설치하세요.": "制限時間内に送信が完了したか確認できませんでした。ホーム画面で App がインストールされているか確認し、ない場合はもう一度インストールしてください。",
      "Mac이 빌드를 확인하는 동안 응답 시간이 지났습니다. 잠시 뒤 다시 설치하세요.": "Macがビルドを確認している間に応答時間が過ぎました。しばらくしてからもう一度インストールしてください。",
      "앱이 실행되지 않으면 설정 > 개인정보 보호 및 보안 > 개발자 모드가 켜져 있는지 확인하세요.": "App が起動しない場合は、「設定」>「プライバシーとセキュリティ」で「デベロッパモード」がオンになっているか確認してください。",
      "Mac이 빌드를 모두 보냈습니다. 설치 진행은 홈 화면의 앱 아이콘에서 확인하세요.": "Macがビルドをすべて送信しました。インストールの進行状況は、ホーム画面のアプリアイコンで確認してください。",
      "Mac이 빌드를 확인하는 중": "Macがビルドを確認中",
      "설치 창에서 ‘설치’를 누르세요": "インストールウインドウで「インストール」をタップしてください",
      "전송 완료": "送信完了",
      "남은 시간 {minutes}분 {seconds}초": "残り時間 {minutes}分{seconds}秒",
      "{count}바이트": "{count}バイト",
      "버전 {version} ({build}) · {size}": "バージョン {version} ({build}) · {size}",
      "{year}. {month}. {day}.": "{year}年{month}月{day}日",
      "프로비저닝 프로파일이 {date}에 만료되었습니다. 설치해도 실행되지 않을 수 있습니다.": "プロビジョニングプロファイルの有効期限が {date} に切れました。インストールしても起動しない場合があります。",
      "전송 중 {sent} / {total}": "送信中 {sent} / {total}",
      "전송 중 {sent}": "送信中 {sent}",
      "설치": "インストール",
      "{name} 설치": "{name}をインストール",
      "다시 열기": "もう一度開く",
      "설치 창 열기": "インストールウインドウを開く",
      "{name} 다시 열기": "{name}をもう一度開く",
      "{name} 설치 창 열기": "{name}のインストールウインドウを開く",
      "취소": "キャンセル",
      "{name} 설치 취소": "{name}のインストールをキャンセル",
      "전송": "送信",
      "확인": "OK",
      "다시 설치": "再インストール",
      "{name} 다시 설치": "{name}を再インストール",
      "닫기": "閉じる",
      "받는 중": "ダウンロード中",
      "목록을 새로 받지 못했습니다. 아래는 이전 목록입니다. {message}": "リストを更新できませんでした。以前のリストを表示しています。{message}",
      "{time}에 받은 목록": "{time}に受信した一覧",
      "페어링 요청을 보내는 중": "ペアリングリクエストを送信中",
      "Mac 앱에서 ‘{name}’의 페어링 요청을 승인하세요.": "Macアプリで「{name}」のペアリングリクエストを承認してください。"
    },
    "zh-Hans": {
      "RemoteDebug 빌드 설치": "安装 RemoteDebug 构建",
      "빌드 목록을 받는 중": "正在下载构建列表",
      "Mac에 연결하는 중": "正在连接 Mac",
      "빌드 목록을 받지 못했습니다": "无法下载构建列表",
      "다시 시도": "重试",
      "Mac 페어링": "Mac 配对",
      "Mac 앱의 페어링 화면에 표시된 코드를 입력하세요. Mac에서 승인하면 빌드 목록이 열립니다.": "输入 Mac App 配对界面中显示的代码。在 Mac 上批准后，将打开构建列表。",
      "페어링 코드": "配对代码",
      "기기 이름": "设备名称",
      "Mac의 승인 화면에 이 이름이 표시됩니다.": "此名称会显示在 Mac 的批准界面中。",
      "페어링 요청": "配对请求",
      "Mac의 승인을 기다리는 중": "正在等待 Mac 批准",
      "남은 시간": "剩余时间",
      "페어링 취소": "取消配对",
      "빌드": "构建",
      "새로고침": "刷新",
      "공유 중인 빌드가 없습니다": "没有正在共享的构建",
      "Mac 앱에서 빌드를 공유한 뒤 새로고침하세요.": "请在 Mac App 中共享构建后刷新。",
      "이 페이지와 설치는 iPhone의 Tailscale VPN이 켜져 있어야 동작합니다.": "此页面和安装需要 iPhone 上的 Tailscale VPN 处于打开状态才能运行。",
      "이 iPhone은 Mac에서 승인되지 않았습니다. 다시 페어링하세요.": "这台 iPhone 尚未获得 Mac 的批准。请重新配对。",
      "페어링 코드가 맞지 않거나 만료되었습니다. Mac에 표시된 코드를 확인하고 다시 입력하세요.": "配对代码不正确或已过期。请核对 Mac 上显示的代码后重新输入。",
      "코드를 너무 많이 틀렸습니다. Mac에서 새 페어링 코드를 연 뒤 다시 시도하세요.": "代码输入错误次数过多。请在 Mac 上打开新的配对代码后重试。",
      "설치 세션을 확인할 수 없습니다. 다시 설치하세요.": "无法确认安装会话。请重新安装。",
      "설치 세션이 만료되었습니다. 다시 설치하세요.": "安装会话已过期。请重新安装。",
      "Mac에 이 빌드가 없습니다. 목록을 새로고침하세요.": "Mac 上没有此构建。请刷新列表。",
      "Mac에서 빌드가 바뀌었습니다. 목록을 새로고침하세요.": "Mac 上的构建已变化。请刷新列表。",
      "디버그 빌드가 아니라서 설치할 수 없습니다. Mac에서 Debug 빌드를 게시하세요.": "不是 Debug 构建，无法安装。请在 Mac 上发布 Debug 构建。",
      "Mac 앱이 이 요청을 처리하지 못했습니다. Mac 앱을 최신 버전으로 업데이트한 뒤 이 페이지를 새로고침하세요.": "Mac App 无法处理此请求。请将 Mac App 更新到最新版本，然后刷新此页面。",
      "Mac 앱에서 오류가 났습니다. 잠시 뒤 다시 시도하세요.": "Mac App 出错。请稍后重试。",
      "Mac에 연결할 수 없습니다. iPhone의 VPN이 켜져 있는지, Mac 앱이 공유 중인지 확인하세요.": "无法连接 Mac。请确认 iPhone 的 VPN 已打开，且 Mac App 正在共享。",
      "Mac 앱과 통신 규약 버전이 다릅니다. Mac 앱을 최신 버전으로 업데이트한 뒤 이 페이지를 새로고침하세요.": "与 Mac App 的通信协议版本不同。请将 Mac App 更新到最新版本，然后刷新此页面。",
      "Mac에서 알 수 없는 응답을 받았습니다. 잠시 뒤 다시 시도하세요.": "从 Mac 收到未知响应。请稍后重试。",
      "페어링 코드는 8자입니다. Mac에 표시된 코드를 다시 확인하세요.": "配对代码为 8 位。请再次核对 Mac 上显示的代码。",
      "페어링 코드에 쓰지 않는 글자가 들어 있습니다. Mac에 표시된 코드를 다시 확인하세요.": "配对代码中含有不使用的字符。请再次核对 Mac 上显示的代码。",
      "Mac에서 페어링을 거절했습니다. 다시 하려면 Mac에서 새 코드를 여세요.": "Mac 拒绝了配对。要重试，请在 Mac 上打开新代码。",
      "페어링 요청이 만료되었습니다. Mac에서 새 코드를 열고 다시 시도하세요.": "配对请求已过期。请在 Mac 上打开新代码后重试。",
      "설치 주소가 이 페이지를 연 주소와 달라 열지 않았습니다. Mac 앱 네트워크 화면의 ‘설치 페이지’ 주소로 이 페이지를 다시 연 뒤 설치하세요. 그래도 같으면 Mac 앱을 최신 버전으로 업데이트하세요.": "安装地址与打开此页面的地址不一致，因此未打开。请通过 Mac App 网络屏幕中的“安装页面”地址重新打开此页面，然后再安装。若仍不一致，请将 Mac App 更新到最新版本。",
      "Mac에서 설치를 중단했습니다. Mac에서 빌드를 내렸거나 이 기기의 페어링이 해제되었을 수 있습니다. 빌드 목록을 새로고침하세요.": "Mac 中止了安装。可能是 Mac 已撤下该构建，或此设备的配对已解除。请刷新构建列表。",
      "제한 시간 안에 전송이 끝났는지 확인하지 못했습니다. 홈 화면에서 앱이 설치되었는지 확인하고, 없으면 다시 설치하세요.": "无法确认传输是否在限定时间内完成。请在主屏幕上确认 App 是否已安装，如果没有，请重新安装。",
      "Mac이 빌드를 확인하는 동안 응답 시간이 지났습니다. 잠시 뒤 다시 설치하세요.": "Mac 确认构建时响应超时。请稍后重新安装。",
      "앱이 실행되지 않으면 설정 > 개인정보 보호 및 보안 > 개발자 모드가 켜져 있는지 확인하세요.": "如果 App 无法运行，请确认已打开“设置”>“隐私与安全性”>“开发者模式”。",
      "Mac이 빌드를 모두 보냈습니다. 설치 진행은 홈 화면의 앱 아이콘에서 확인하세요.": "Mac 已发送全部构建。请在主屏幕的 App 图标上查看安装进度。",
      "Mac이 빌드를 확인하는 중": "Mac 正在确认构建",
      "설치 창에서 ‘설치’를 누르세요": "请在安装窗口中点按“安装”",
      "전송 완료": "发送完成",
      "남은 시간 {minutes}분 {seconds}초": "剩余时间 {minutes} 分 {seconds} 秒",
      "{count}바이트": "{count} 字节",
      "버전 {version} ({build}) · {size}": "版本 {version}（{build}）· {size}",
      "{year}. {month}. {day}.": "{year}年{month}月{day}日",
      "프로비저닝 프로파일이 {date}에 만료되었습니다. 설치해도 실행되지 않을 수 있습니다.": "描述文件已于 {date} 到期。安装后可能无法运行。",
      "전송 중 {sent} / {total}": "正在发送 {sent} / {total}",
      "전송 중 {sent}": "正在发送 {sent}",
      "설치": "安装",
      "{name} 설치": "安装 {name}",
      "다시 열기": "重新打开",
      "설치 창 열기": "打开安装窗口",
      "{name} 다시 열기": "重新打开 {name}",
      "{name} 설치 창 열기": "打开 {name} 的安装窗口",
      "취소": "取消",
      "{name} 설치 취소": "取消安装 {name}",
      "전송": "发送",
      "확인": "好",
      "다시 설치": "重新安装",
      "{name} 다시 설치": "重新安装 {name}",
      "닫기": "关闭",
      "받는 중": "正在下载",
      "목록을 새로 받지 못했습니다. 아래는 이전 목록입니다. {message}": "未能重新下载列表。以下为之前的列表。{message}",
      "{time}에 받은 목록": "{time} 收到的列表",
      "페어링 요청을 보내는 중": "正在发送配对请求",
      "Mac 앱에서 ‘{name}’의 페어링 요청을 승인하세요.": "请在 Mac App 上批准“{name}”的配对请求。"
    },
    "zh-Hant": {
      "RemoteDebug 빌드 설치": "安裝 RemoteDebug 建置",
      "빌드 목록을 받는 중": "正在下載建置列表",
      "Mac에 연결하는 중": "正在連線到 Mac",
      "빌드 목록을 받지 못했습니다": "無法下載建置列表",
      "다시 시도": "重試",
      "Mac 페어링": "Mac 配對",
      "Mac 앱의 페어링 화면에 표시된 코드를 입력하세요. Mac에서 승인하면 빌드 목록이 열립니다.": "請輸入 Mac App 配對畫面中顯示的代碼。在 Mac 上核准後，就會開啟建置列表。",
      "페어링 코드": "配對代碼",
      "기기 이름": "裝置名稱",
      "Mac의 승인 화면에 이 이름이 표시됩니다.": "這個名稱會顯示在 Mac 的核准畫面上。",
      "페어링 요청": "配對請求",
      "Mac의 승인을 기다리는 중": "正在等待 Mac 核准",
      "남은 시간": "剩餘時間",
      "페어링 취소": "取消配對",
      "빌드": "建置",
      "새로고침": "重新整理",
      "공유 중인 빌드가 없습니다": "沒有共享中的建置",
      "Mac 앱에서 빌드를 공유한 뒤 새로고침하세요.": "請在 Mac App 中共享建置後重新整理。",
      "이 페이지와 설치는 iPhone의 Tailscale VPN이 켜져 있어야 동작합니다.": "必須開啟 iPhone 的 Tailscale VPN,此頁面與安裝才能運作。",
      "이 iPhone은 Mac에서 승인되지 않았습니다. 다시 페어링하세요.": "此 iPhone 尚未獲得 Mac 核准。請重新配對。",
      "페어링 코드가 맞지 않거나 만료되었습니다. Mac에 표시된 코드를 확인하고 다시 입력하세요.": "配對代碼不正確或已過期。請確認 Mac 上顯示的代碼後重新輸入。",
      "코드를 너무 많이 틀렸습니다. Mac에서 새 페어링 코드를 연 뒤 다시 시도하세요.": "輸入錯誤的代碼次數過多。請在 Mac 上開啟新的配對代碼後再試一次。",
      "설치 세션을 확인할 수 없습니다. 다시 설치하세요.": "無法確認安裝工作階段。請重新安裝。",
      "설치 세션이 만료되었습니다. 다시 설치하세요.": "安裝工作階段已過期。請重新安裝。",
      "Mac에 이 빌드가 없습니다. 목록을 새로고침하세요.": "Mac 上沒有這個建置。請重新整理列表。",
      "Mac에서 빌드가 바뀌었습니다. 목록을 새로고침하세요.": "Mac 上的建置已變更。請重新整理列表。",
      "디버그 빌드가 아니라서 설치할 수 없습니다. Mac에서 Debug 빌드를 게시하세요.": "不是 Debug 建置，無法安裝。請在 Mac 上發布 Debug 建置。",
      "Mac 앱이 이 요청을 처리하지 못했습니다. Mac 앱을 최신 버전으로 업데이트한 뒤 이 페이지를 새로고침하세요.": "Mac App 無法處理這項要求。請將 Mac App 更新至最新版本後，重新整理此頁面。",
      "Mac 앱에서 오류가 났습니다. 잠시 뒤 다시 시도하세요.": "Mac App 發生錯誤。請稍後再試一次。",
      "Mac에 연결할 수 없습니다. iPhone의 VPN이 켜져 있는지, Mac 앱이 공유 중인지 확인하세요.": "無法連線到 Mac。請確認 iPhone 的 VPN 已開啟，且 Mac App 正在共享。",
      "Mac 앱과 통신 규약 버전이 다릅니다. Mac 앱을 최신 버전으로 업데이트한 뒤 이 페이지를 새로고침하세요.": "與 Mac App 的通訊協定版本不同。請將 Mac App 更新至最新版本後，重新整理此頁面。",
      "Mac에서 알 수 없는 응답을 받았습니다. 잠시 뒤 다시 시도하세요.": "收到 Mac 傳來的未知回應。請稍後再試一次。",
      "페어링 코드는 8자입니다. Mac에 표시된 코드를 다시 확인하세요.": "配對代碼為 8 個字元。請再次確認 Mac 上顯示的代碼。",
      "페어링 코드에 쓰지 않는 글자가 들어 있습니다. Mac에 표시된 코드를 다시 확인하세요.": "配對代碼包含不使用的字元。請再次確認 Mac 上顯示的代碼。",
      "Mac에서 페어링을 거절했습니다. 다시 하려면 Mac에서 새 코드를 여세요.": "Mac 已拒絕配對。若要重試，請在 Mac 上開啟新的代碼。",
      "페어링 요청이 만료되었습니다. Mac에서 새 코드를 열고 다시 시도하세요.": "配對請求已過期。請在 Mac 上開啟新代碼後再試一次。",
      "설치 주소가 이 페이지를 연 주소와 달라 열지 않았습니다. Mac 앱 네트워크 화면의 ‘설치 페이지’ 주소로 이 페이지를 다시 연 뒤 설치하세요. 그래도 같으면 Mac 앱을 최신 버전으로 업데이트하세요.": "安裝位址與開啟此頁面的位址不同，因此未開啟。請使用 Mac App 網路畫面中的「安裝頁面」位址重新開啟此頁面，再進行安裝。若仍相同，請將 Mac App 更新至最新版本。",
      "Mac에서 설치를 중단했습니다. Mac에서 빌드를 내렸거나 이 기기의 페어링이 해제되었을 수 있습니다. 빌드 목록을 새로고침하세요.": "Mac 已中止安裝。可能是 Mac 上已移除建置，或這部裝置的配對已解除。請重新整理建置列表。",
      "제한 시간 안에 전송이 끝났는지 확인하지 못했습니다. 홈 화면에서 앱이 설치되었는지 확인하고, 없으면 다시 설치하세요.": "無法確認是否已在時限內完成傳送。請在主畫面確認 App 是否已安裝，若沒有請重新安裝。",
      "Mac이 빌드를 확인하는 동안 응답 시간이 지났습니다. 잠시 뒤 다시 설치하세요.": "Mac 確認建置時已逾時。請稍後再安裝一次。",
      "앱이 실행되지 않으면 설정 > 개인정보 보호 및 보안 > 개발자 모드가 켜져 있는지 확인하세요.": "若 App 無法執行，請確認「設定」>「隱私權與安全性」>「開發者模式」是否已開啟。",
      "Mac이 빌드를 모두 보냈습니다. 설치 진행은 홈 화면의 앱 아이콘에서 확인하세요.": "Mac 已傳送所有建置。請在主畫面的 App 圖示查看安裝進度。",
      "Mac이 빌드를 확인하는 중": "Mac 正在確認建置",
      "설치 창에서 ‘설치’를 누르세요": "請在安裝視窗中點一下「安裝」",
      "전송 완료": "傳送完成",
      "남은 시간 {minutes}분 {seconds}초": "剩餘時間 {minutes} 分 {seconds} 秒",
      "{count}바이트": "{count} 位元組",
      "버전 {version} ({build}) · {size}": "版本 {version} ({build}) · {size}",
      "{year}. {month}. {day}.": "{year}/{month}/{day}",
      "프로비저닝 프로파일이 {date}에 만료되었습니다. 설치해도 실행되지 않을 수 있습니다.": "佈建描述檔已於 {date} 過期。即使安裝也可能無法執行。",
      "전송 중 {sent} / {total}": "傳送中 {sent} / {total}",
      "전송 중 {sent}": "傳送中 {sent}",
      "설치": "安裝",
      "{name} 설치": "安裝 {name}",
      "다시 열기": "重新開啟",
      "설치 창 열기": "打開安裝視窗",
      "{name} 다시 열기": "重新開啟 {name}",
      "{name} 설치 창 열기": "開啟 {name} 安裝視窗",
      "취소": "取消",
      "{name} 설치 취소": "取消安裝 {name}",
      "전송": "傳送",
      "확인": "好",
      "다시 설치": "重新安裝",
      "{name} 다시 설치": "重新安裝 {name}",
      "닫기": "關閉",
      "받는 중": "下載中",
      "목록을 새로 받지 못했습니다. 아래는 이전 목록입니다. {message}": "無法重新下載列表。以下為先前的列表。{message}",
      "{time}에 받은 목록": "{time} 接收的列表",
      "페어링 요청을 보내는 중": "正在傳送配對請求",
      "Mac 앱에서 ‘{name}’의 페어링 요청을 승인하세요.": "請在 Mac App 中核准「{name}」的配對要求。"
    }
  };
  // RD-STRINGS-END

  var LANGUAGES = ["ko", "en", "ja", "zh-Hans", "zh-Hant"];
  var language = "ko";

  // 브라우저의 선호 언어 목록에서 앞쪽부터 처음으로 맞는 언어를 고른다. 맞는 것이 없으면 영어,
  // 목록이 없거나 비었으면(navigator가 없는 환경) 한국어.
  function pickLanguage(list) {
    if (list == null || typeof list.length !== "number" || list.length === 0) return "ko";
    for (var i = 0; i < list.length; i++) {
      var parts = String(list[i] == null ? "" : list[i]).trim().toLowerCase().split(/[-_]/);
      switch (parts[0]) {
        case "ko": return "ko";
        case "en": return "en";
        case "ja": return "ja";
        case "zh":
          var rest = parts.slice(1);
          if (rest.indexOf("hant") >= 0) return "zh-Hant";
          if (rest.indexOf("hans") >= 0) return "zh-Hans";
          if (rest.indexOf("tw") >= 0 || rest.indexOf("hk") >= 0 || rest.indexOf("mo") >= 0) return "zh-Hant";
          return "zh-Hans";
      }
    }
    return "en";
  }

  // 화면 글자의 언어를 바꾼다. 모르는 값이면 그대로 둔다. 지금 언어를 돌려준다.
  function setLanguage(code) {
    if (LANGUAGES.indexOf(code) >= 0) language = code;
    return language;
  }

  function getLanguage() {
    return language;
  }

  function lookup(lang, key) {
    var table = STRINGS[lang];
    if (!table || !Object.prototype.hasOwnProperty.call(table, key)) return "";
    var v = table[key];
    return typeof v === "string" ? v : "";
  }

  // 표에 있는 원문인지.
  function hasText(key) {
    return Object.prototype.hasOwnProperty.call(STRINGS.en, key);
  }

  // 원문(한국어)을 지금 언어로 바꾸고 {name} 자리에 params 값을 넣는다. 번역이 없으면 영어, 그다음 원문.
  function t(key, params) {
    var text = String(key);
    if (language !== "ko") text = lookup(language, text) || lookup("en", text) || text;
    if (!params) return text;
    return text.replace(/\{([A-Za-z0-9_]+)\}/g, function (whole, name) {
      return Object.prototype.hasOwnProperty.call(params, name) ? String(params[name]) : whole;
    });
  }

  // MARK: 안내 문구

  // 키별 한국어 원문. RDLogic.messages는 읽을 때마다 지금 언어로 바꿔 준다.
  var messageText = Object.freeze({
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

  var messages = (function () {
    var out = {};
    Object.keys(messageText).forEach(function (k) {
      Object.defineProperty(out, k, { enumerable: true, get: function () { return t(messageText[k]); } });
    });
    return Object.freeze(out);
  })();

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
    return { text: m + ":" + (r < 10 ? "0" : "") + r, label: t("남은 시간 {minutes}분 {seconds}초", { minutes: m, seconds: r }), low: s <= 30 };
  }

  // MARK: 표시

  // ByteCountFormatter(.file)처럼 1000 단위로 적는다.
  function formatSize(bytes) {
    var b = typeof bytes === "number" && isFinite(bytes) && bytes > 0 ? bytes : 0;
    if (b < 1000) return t("{count}바이트", { count: b });
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
      detail: t("버전 {version} ({build}) · {size}", { version: String(b.version || ""), build: String(b.buildNumber || ""), size: formatSize(ipa.size) }),
      bundleId: String(b.bundleId || ""),
      warning: null
    };
    var expires = typeof signing.profileExpires === "string" ? Date.parse(signing.profileExpires) : NaN;
    if (!isNaN(expires) && expires < nowMs) {
      var d = new Date(expires);
      var day = t("{year}. {month}. {day}.", { year: d.getUTCFullYear(), month: d.getUTCMonth() + 1, day: d.getUTCDate() });
      summary.warning = t("프로비저닝 프로파일이 {date}에 만료되었습니다. 설치해도 실행되지 않을 수 있습니다.", { date: day });
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
          return t("전송 중 {sent} / {total}", { sent: formatSize(s.bytesServed), total: formatSize(s.size) });
        }
        return t("전송 중 {sent}", { sent: formatSize(s.bytesServed) });
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
    LANGUAGES: Object.freeze(LANGUAGES.slice()),
    messages: messages,
    pickLanguage: pickLanguage,
    setLanguage: setLanguage,
    getLanguage: getLanguage,
    hasText: hasText,
    t: t,
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
