import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/models.dart';
import 'core/app_preferences.dart';
import 'core/app_brand.dart';
import 'core/portal_api.dart';
import 'core/session_store.dart';
import 'core/session_recovery.dart';
import 'core/web_session.dart';
import 'core/widget_bridge.dart';
import 'features/login/login_screen.dart';
import 'features/schedule/schedule_controller.dart';
import 'features/schedule/schedule_screen.dart';
import 'theme/app_theme.dart';

class CmcCheckinApp extends StatelessWidget {
  const CmcCheckinApp({
    super.key,
    this.initialSession,
    required this.preferences,
  });
  final Session? initialSession;
  final AppPreferences preferences;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: preferences,
      builder: (context, _) => MaterialApp(
        title: AppBrand.name,
        debugShowCheckedModeBanner: false,
        locale: const Locale('vi'),
        supportedLocales: const [Locale('vi')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: preferences.themeMode,
        themeAnimationDuration: preferences.reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 240),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations:
                preferences.reduceMotion ||
                MediaQuery.disableAnimationsOf(context),
          ),
          child: child!,
        ),
        home: AuthGate(
          initialSession: initialSession,
          preferences: preferences,
        ),
      ),
    );
  }
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key, this.initialSession, required this.preferences});
  final Session? initialSession;
  final AppPreferences preferences;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  Session? _session;
  ScheduleController? _controller;
  bool _restoreSession = false;
  bool _resettingSession = false;
  bool _checkInRequested = false;
  int _loginGeneration = 0;
  final _recovery = SessionRecovery();
  StreamSubscription<Uri>? _links;

  @override
  void initState() {
    super.initState();
    // Session đã lưu chỉ là gợi ý mở Index.aspx. Phải lấy lại ngữ cảnh portal
    // và xác minh API trong WebView trước khi hiển thị dữ liệu tài khoản.
    _restoreSession = widget.initialSession != null;
    _listenDeepLinks();
  }

  @override
  void dispose() {
    _links?.cancel();
    _controller?.api.close();
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _listenDeepLinks() async {
    final links = AppLinks();
    final initial = await links.getInitialLink();
    if (!mounted) return;
    if (initial != null) _handle(initial);
    _links = links.uriLinkStream.listen(_handle);
  }

  void _handle(Uri uri) {
    if (!mounted) return;
    if (uri.scheme == 'cmccheckin' && uri.host == 'checkin') {
      setState(() => _checkInRequested = true);
    }
  }

  Future<void> _onSignedIn(
    int generation,
    Session session,
    PortalApi api,
    DateTime week,
    List<ScheduleEntry> entries,
  ) async {
    if (!mounted ||
        _resettingSession ||
        generation != _loginGeneration ||
        !_recovery.acceptToken(session.token)) {
      api.close();
      return;
    }
    await SessionStore.save(session);
    if (!mounted || _resettingSession || generation != _loginGeneration) {
      api.close();
      return;
    }
    final controller = ScheduleController(
      api: api,
      fallbackIp: session.portalIp,
      initialWeekStart: week,
      initialEntries: entries,
      onCurrentWeekLoaded: (week, entries) {
        _recovery.confirmAuthenticated();
        _publishWeek(week, entries);
      },
    );
    final old = _controller;
    FocusManager.instance.primaryFocus?.unfocus();
    _recovery.confirmAuthenticated();
    setState(() {
      _session = session;
      _controller = controller;
    });
    old?.dispose();
    old?.api.close();
    // Không để lỗi widget phụ làm mất phiên đã được API xác minh.
    unawaited(_publishWeek(week, entries));
  }

  Future<void> _publishWeek(DateTime week, List<ScheduleEntry> entries) async {
    try {
      await WidgetBridge.publish(
        signedIn: true,
        weekStart: week,
        entries: entries,
      );
    } catch (_) {
      debugPrint('[widget] publish_failed');
    }
  }

  Future<void> _onSessionExpired([Session? candidate]) async {
    final session = candidate ?? _session;
    if (session == null || _resettingSession) return;
    await _resetSession(() => _recovery.expire(session));
  }

  Future<void> _onSignOut() => _resetSession(_recovery.retry);

  Future<void> _resetSession(Future<void> Function() reset) async {
    if (_resettingSession || !mounted) return;
    final old = _controller;
    setState(() {
      _resettingSession = true;
      _loginGeneration++;
      _session = null;
      _controller = null;
      _restoreSession = false;
      _checkInRequested = false;
    });
    // Chặn kết quả request đang chạy trước khi dọn session/cookie.
    old?.dispose();
    old?.api.close();
    try {
      // Chờ WebView cũ bị hủy trong frame kế tiếp trước khi xóa cookie/storage;
      // trang còn sống có thể ghi lại dữ liệu phiên trong lúc đang dọn.
      await WidgetsBinding.instance.endOfFrame;
      await reset();
    } finally {
      if (mounted) setState(() => _resettingSession = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final generation = _loginGeneration;
    final signedIn = _session != null && controller != null;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Giữ nguyên phần tử WebView sau khi đăng nhập; Offstage chỉ ẩn UI,
        // không hủy phiên/cookie hay chuyển request sang HTTP client khác.
        Offstage(
          offstage: signedIn,
          child: TickerMode(
            enabled: !signedIn,
            child: ExcludeFocus(
              excluding: signedIn,
              child: LoginScreen(
                key: ValueKey(generation),
                restoreSession: _restoreSession,
                onSignedIn: (session, api, week, entries) =>
                    _onSignedIn(generation, session, api, week, entries),
                onSessionExpired: (session) async {
                  if (generation == _loginGeneration) {
                    await _onSessionExpired(session);
                  }
                },
                onUserAgentCaptured: WebSession.rememberUserAgent,
                acceptToken: _recovery.acceptToken,
                resetting: _resettingSession,
                blocked: _recovery.blocked,
                sessionNotice: _recovery.notice,
                onRetrySession: _onSignOut,
              ),
            ),
          ),
        ),
        if (signedIn)
          ScheduleScreen(
            key: ValueKey(generation),
            controller: controller,
            preferences: widget.preferences,
            checkInRequested: _checkInRequested,
            onCheckInRequestHandled: () =>
                setState(() => _checkInRequested = false),
            onSignOut: _onSignOut,
            onSessionExpired: _onSessionExpired,
          ),
      ],
    );
  }
}
