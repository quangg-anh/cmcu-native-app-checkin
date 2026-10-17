import 'dart:async';
import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;

import 'portal_api.dart';

/// Chỉ gửi các API app đang dùng, không biến WebView thành HTTP proxy tùy ý.
const _allowedPaths = <String>[
  '/sinhvienapi/api/SV_ThongTin_MH/DSA4BRINKCIpAiAPKSAv',
  '/sinhvienapi/api/SV_ThongTin_MH/DSA4FSkuLyYVKC8CKTQuLyYVMygvKQkuIgPP',
  '/sinhvienapi/api/SV_ThongTin_MH/CiQ1EDQgCS4iFSAxAiAPKSAv',
  '/sinhvienapi/api/SV_ThongTin_MH/DSA4BRIFKCQsFSkgLykRKSAvFSkkLhUKCREP',
  '/chuyencanapi/api/CC_ThongTin/Them_QLSV_NguoiHoc_TuGhiNhan',
];

const _postInPortal = r'''
if (location.origin !== origin) return {expired: true};
var target = new URL(url);
if (target.origin !== origin || allowedPaths.indexOf(target.pathname) < 0 ||
    target.search || target.hash || target.username || target.password) {
  return {failed: true};
}
var system = (typeof edu !== 'undefined' && edu) ? edu.system : null;
if (!system || String(system.userId || '') !== userId) {
  return {expired: true};
}
// Dùng token hiện tại do portal cấp, không phát lại token native đã lưu.
var token = typeof system.tokenJWT === 'string' ? system.tokenJWT : '';
return await new Promise(function (resolve) {
  var xhr = new XMLHttpRequest();
  xhr.open('POST', url, true);
  xhr.withCredentials = true;
  xhr.timeout = 30000;
  xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded; charset=UTF-8');
  xhr.setRequestHeader('Accept', 'application/json, text/javascript, */*; q=0.01');
  xhr.setRequestHeader('X-Requested-With', 'XMLHttpRequest');
  if (token) xhr.setRequestHeader('Authorization', 'Bearer ' + token);
  // Cookie (kể cả HttpOnly), User-Agent, Origin và Referer do WebView quản lý.
  xhr.onload = function () {
    var finalUrl = new URL(xhr.responseURL || url);
    if (finalUrl.origin !== origin ||
        /^\/congthongtin\/login\.aspx\/?$/i.test(finalUrl.pathname)) {
      resolve({expired: true});
      return;
    }
    resolve({status: xhr.status, body: xhr.responseText});
  };
  xhr.onerror = xhr.ontimeout = xhr.onabort = function () {
    resolve({failed: true});
  };
  xhr.send(body);
});
''';

/// Giữ request trong đúng WebView đã đăng nhập. Không sao chép cookie sang Dart,
/// không mở callback JavaScript nhận token, không tự retry POST (nhất là điểm danh).
class PortalWebClient extends http.BaseClient {
  PortalWebClient({required InAppWebViewController web, required String userId})
    : _web = web,
      _userId = userId;

  final InAppWebViewController _web;
  final String _userId;
  final _closedSignal = Completer<void>();
  bool _closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) throw http.ClientException('Portal WebView closed');
    final url = request.url;
    if (request.method != 'POST' ||
        url.origin != portalOrigin ||
        url.userInfo.isNotEmpty ||
        url.hasQuery ||
        url.hasFragment ||
        !_allowedPaths.contains(url.path)) {
      throw http.ClientException('Unsupported portal request');
    }
    final body = utf8.decode(await request.finalize().toBytes());
    final result = await Future.any([
      _send(url, body),
      _closedSignal.future.then<http.StreamedResponse>(
        (_) => throw http.ClientException('Portal WebView closed'),
      ),
    ]);
    if (_closed) throw http.ClientException('Portal WebView closed');
    return result;
  }

  Future<http.StreamedResponse> _send(Uri url, String body) async {
    try {
      final page = await _web.getUrl();
      if (_closed) throw http.ClientException('Portal WebView closed');
      if (page == null || Uri.parse(page.toString()).origin != portalOrigin) {
        throw SessionExpiredException();
      }
      final result = await _web
          .callAsyncJavaScript(
            functionBody: _postInPortal,
            arguments: {
              'origin': portalOrigin,
              'allowedPaths': _allowedPaths,
              'url': url.toString(),
              'body': body,
              'userId': _userId,
            },
          )
          .timeout(const Duration(seconds: 35));
      if (_closed) throw http.ClientException('Portal WebView closed');
      final value = result?.value;
      if (result?.error != null || value is! Map) {
        throw http.ClientException('Portal WebView request failed');
      }
      if (value['expired'] == true) throw SessionExpiredException();
      final status = value['status'];
      final responseBody = value['body'];
      if (value['failed'] == true ||
          status is! int ||
          status < 100 ||
          status > 599 ||
          responseBody is! String) {
        throw http.ClientException('Portal WebView request failed');
      }
      return http.StreamedResponse(
        Stream.value(utf8.encode(responseBody)),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    } on SessionExpiredException {
      rethrow;
    } on http.ClientException {
      rethrow;
    } catch (_) {
      // Không đưa lỗi JavaScript/response chứa dữ liệu phiên vào log/UI.
      throw http.ClientException('Portal WebView request failed');
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _closedSignal.complete();
    // AuthGate bỏ WebView khi reset/đăng xuất; XHR cũng có timeout riêng.
  }
}
