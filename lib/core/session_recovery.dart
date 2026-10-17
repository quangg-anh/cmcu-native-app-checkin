import 'package:flutter/foundation.dart';

import 'models.dart';
import 'session_store.dart';
import 'web_session.dart';
import 'widget_bridge.dart';

/// Giới hạn phục hồi tự động; chỉ API thành công hoặc thao tác thử lại mới
/// bắt đầu chu kỳ mới. Đọc được token trong WebView chưa chứng minh phiên hợp lệ.
class SessionRecovery {
  SessionRecovery({
    Future<void> Function()? clearSession,
    Future<void> Function()? clearWebSession,
    Future<void> Function()? clearWidget,
  }) : _clearSession = clearSession ?? SessionStore.clear,
       _clearWebSession = clearWebSession ?? WebSession.clearAll,
       _clearWidget = clearWidget ?? WidgetBridge.clear;

  static const maxFailures = 2;
  final Future<void> Function() _clearSession;
  final Future<void> Function() _clearWebSession;
  final Future<void> Function() _clearWidget;
  final Set<String> _rejectedTokens = {};
  int _failures = 0;
  bool _repeatedToken = false;
  bool _cleanupFailed = false;
  Future<void>? _resetFuture;
  String? _notice;

  bool get resetting => _resetFuture != null;
  bool get blocked =>
      _cleanupFailed || _repeatedToken || _failures >= maxFailures;
  String? get notice => _notice;

  /// Không gửi lại token đã bị API từ chối, kể cả portal tự vào Index.aspx.
  bool acceptToken(String token) {
    if (resetting || blocked) return false;
    if (token.isEmpty || !_rejectedTokens.contains(token)) return true;
    _repeatedToken = true;
    _notice =
        'Cổng sinh viên trả lại phiên đăng nhập cũ đã bị từ chối. '
        'Đã dừng tự đăng nhập để tránh lặp. Vui lòng đăng nhập lại.';
    debugPrint('[auth] login_blocked reason=rejected_token');
    return false;
  }

  Future<void> expire(Session session) {
    final pending = _resetFuture;
    if (pending != null) return pending;
    // Phiên cookie có thể không có JWT. Chuỗi rỗng không định danh phiên;
    // vẫn giới hạn số lần thất bại, không coi mọi phiên cookie là cùng token.
    final repeated =
        session.token.isNotEmpty && !_rejectedTokens.add(session.token);
    _failures++;
    _repeatedToken = repeated;
    _notice = blocked
        ? 'Cổng sinh viên vẫn trả HTTP 401 sau khi đăng nhập lại. '
              'Đã dừng tự đăng nhập. Vui lòng thử lại sau; '
              'nếu lỗi tiếp diễn, cần kiểm tra cookie, User-Agent và header của request.'
        : 'Phiên đăng nhập đã hết hạn. Đã xóa dữ liệu phiên cũ. '
              'Vui lòng đăng nhập lại.';
    debugPrint(
      '[auth] session_rejected attempt=$_failures '
      'tokenRepeated=$repeated blocked=$blocked',
    );
    return _resetFuture = _clear(resetFailures: false);
  }

  /// Người dùng chủ động thử lại/đăng xuất: vẫn phải xóa dữ liệu web trước.
  Future<void> retry() {
    final pending = _resetFuture;
    if (pending != null) return pending;
    return _resetFuture = _clear(resetFailures: true);
  }

  Future<void> _clear({required bool resetFailures}) async {
    try {
      // Mỗi bước đều được chạy, kể cả khi bước khác lỗi. Không dựng WebView mới
      // cho tới khi cả ba hoàn tất; lỗi dọn phiên phải chặn tự đăng nhập.
      await Future.wait([
        Future<void>.sync(_clearSession),
        Future<void>.sync(_clearWebSession),
        Future<void>.sync(_clearWidget),
      ]);
      _cleanupFailed = false;
      if (resetFailures) confirmAuthenticated();
    } catch (_) {
      _cleanupFailed = true;
      _notice =
          'Không xóa được dữ liệu phiên đăng nhập cũ. '
          'Vui lòng thử lại trước khi đăng nhập.';
      debugPrint('[auth] login_blocked reason=session_cleanup_failed');
    } finally {
      _resetFuture = null;
    }
  }

  /// Chỉ gọi khi API lịch chấp nhận phiên, không gọi ngay sau probe đăng nhập.
  void confirmAuthenticated() {
    _failures = 0;
    _repeatedToken = false;
    _rejectedTokens.clear();
    _notice = null;
  }
}
