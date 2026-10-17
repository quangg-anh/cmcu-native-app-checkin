import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/models.dart';
import '../../theme/campus_brand.dart';
import '../../core/portal_api.dart';
import '../../core/portal_web_client.dart';

const _loginUrl = '$portalOrigin/congthongtin/login.aspx';
const _probeInterval = Duration(milliseconds: 700);
const _menuWaitProbes = 15;

const _probeJs = r'''
(function () {
  try {
    if (location.origin !== 'https://iu.cmcu.edu.vn') return null;
    var s = (typeof edu !== 'undefined' && edu) ? edu.system : null;
    if (!s || !s.userId) return null;
    var list = s.dtChucNang || [], match = null, grades = null;
    for (var i = 0; i < list.length; i++) {
      var file = String(list[i].DUONGDANFILE || '').toLowerCase();
      var name = String(list[i].TENCHUCNANG || '').toLowerCase();
      if (file.indexOf('lichgiang') >= 0 || file.indexOf('lichhoc') >= 0 || name.indexOf('lịch cá nhân') >= 0) match = list[i].ID;
      if (file.indexOf('diemhoc') >= 0 || name.indexOf('điểm học') >= 0 || name.indexOf('kết quả học tập') >= 0) grades = list[i].ID;
    }
    return JSON.stringify({
      token: typeof s.tokenJWT === 'string' ? s.tokenJWT : '',
      userId: String(s.userId), clientIP: s.clientIP || '',
      chucNangId: match == null ? null : String(match),
      gradesChucNangId: grades == null ? '' : String(grades),
      currentChucNangId: s.strChucNang_Id || '', menuLoaded: list.length > 0,
      userAgent: navigator.userAgent || ''
    });
  } catch (e) { return null; }
})();
''';

class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
    required this.onSignedIn,
    this.onSessionExpired,
    this.onUserAgentCaptured,
    this.restoreSession = false,
    this.acceptToken,
    this.resetting = false,
    this.blocked = false,
    this.sessionNotice,
    this.onRetrySession,
  });
  final Future<void> Function(
    Session session,
    PortalApi api,
    DateTime weekStart,
    List<ScheduleEntry> entries,
  )
  onSignedIn;
  final Future<void> Function(Session session)? onSessionExpired;
  final Future<void> Function(String userAgent)? onUserAgentCaptured;
  final bool Function(String token)? acceptToken;
  final bool restoreSession;
  final bool resetting;
  final bool blocked;
  final String? sessionNotice;
  final VoidCallback? onRetrySession;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  InAppWebViewController? _web;
  // Package tạo platform view ngay trong constructor. Cache cả widget để
  // setState/progress/Offstage không thay controller hoặc làm mất phiên gốc.
  late final InAppWebView _loginWebView = _createWebView();
  double _progress = 0;
  bool _canGoBack = false;
  Timer? _timer;
  bool _done = false;
  bool _probing = false;
  bool _menuError = false;
  bool _tokenRejected = false;
  bool _validating = false;
  String? _validationError;
  PortalApi? _candidateApi;
  int _probesWithToken = 0;

  @override
  void initState() {
    super.initState();
    // Package có thể log URL OAuth và kết quả JavaScript chứa dữ liệu cá nhân
    // ở debug mode. Chỉ dùng diagnostics đã lược bỏ dữ liệu của app.
    PlatformInAppWebViewController.debugLoggingSettings.enabled = false;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _candidateApi?.close();
    super.dispose();
  }

  void _startProbe() {
    _timer?.cancel();
    if (widget.resetting || widget.blocked || _tokenRejected) return;
    _timer = Timer.periodic(_probeInterval, (_) => _probe());
  }

  void _retry() {
    setState(() {
      _menuError = false;
      _validationError = null;
      _probesWithToken = 0;
    });
    _startProbe();
    _web?.reload();
  }

  Future<void> _probe() async {
    final web = _web;
    if (_done ||
        _probing ||
        web == null ||
        !mounted ||
        widget.resetting ||
        widget.blocked ||
        _tokenRejected)
      return;
    _probing = true;
    try {
      final uri = await web.getUrl();
      if (!mounted || widget.resetting || widget.blocked) return;
      if (uri == null || Uri.parse(uri.toString()).origin != portalOrigin)
        return;
      final raw = await web.evaluateJavascript(source: _probeJs);
      if (raw is! String ||
          _done ||
          !mounted ||
          widget.resetting ||
          widget.blocked)
        return;
      final obj = jsonDecode(raw) as Map<String, dynamic>;
      final token = obj['token'] as String? ?? '';
      final userId = obj['userId'] as String?;
      if (userId == null || userId.isEmpty) return;
      final chucNangId = obj['chucNangId'] as String?;
      final menuLoaded = obj['menuLoaded'] == true;
      final gradesId = obj['gradesChucNangId'] as String? ?? '';
      final scheduleId =
          chucNangId ?? (obj['currentChucNangId'] as String? ?? '');
      final menuReady = menuLoaded && chucNangId != null;
      final timedOut = _probesWithToken >= _menuWaitProbes;
      if (menuReady || (timedOut && scheduleId.isNotEmpty)) {
        if (widget.acceptToken?.call(token) == false) {
          _timer?.cancel();
          setState(() => _tokenRejected = true);
          return;
        }
        final userAgent = obj['userAgent'] as String? ?? '';
        await widget.onUserAgentCaptured?.call(userAgent);
        if (!mounted || widget.resetting || widget.blocked) return;
        final session = Session(
          token: token,
          userId: userId,
          chucNangId: scheduleId,
          portalIp: obj['clientIP'] as String? ?? '',
          // Tài khoản không có mục Điểm học vẫn dùng được lịch; tab Kết quả
          // tự báo lỗi khi `gradesChucNangId` rỗng.
          gradesChucNangId: gradesId,
        );
        await _validate(session, userAgent, web);
      } else if (timedOut) {
        _timer?.cancel();
        setState(() => _menuError = true);
      } else {
        _probesWithToken++;
      }
    } catch (_) {
      // Trang đang chuyển hướng / chưa có `edu` → thử lại ở nhịp sau.
    } finally {
      _probing = false;
    }
  }

  Future<void> _validate(
    Session session,
    String userAgent,
    InAppWebViewController web,
  ) async {
    _timer?.cancel();
    setState(() {
      _validating = true;
      _validationError = null;
    });
    final api = PortalApi(
      session: session,
      userAgent: userAgent,
      // WebView tự quản lý cookie HttpOnly/path/SameSite, không xuất cookie.
      cookieHeader: (_) async => null,
      client: PortalWebClient(web: web, userId: session.userId),
      browserManagedSession: true,
      diagnosticLog: debugPrint,
    );
    _candidateApi = api;
    try {
      final week = startOfWeek(DateTime.now());
      final entries = await api.weekSchedule(
        week,
        week.add(const Duration(days: 6)),
      );
      if (!mounted || widget.resetting || widget.blocked) return;
      // Chỉ API hợp lệ mới được lưu session/chuyển màn hình. Cùng WebView và
      // cùng client tiếp tục phục vụ lịch, điểm, điểm danh sau khi đăng nhập.
      await widget.onSignedIn(session, api, week, entries);
      _candidateApi = null; // Quyền đóng client chuyển cho AuthGate.
      _done = true;
    } on SessionExpiredException {
      if (!mounted || widget.resetting || widget.blocked) return;
      if (widget.onSessionExpired != null) {
        await widget.onSessionExpired!(session);
      } else {
        setState(() => _tokenRejected = true);
      }
    } on PortalException catch (error) {
      if (mounted) setState(() => _validationError = error.message);
    } catch (_) {
      if (mounted) {
        setState(() {
          _validationError =
              'Không thể xác minh phiên đăng nhập. Vui lòng thử lại.';
        });
      }
    } finally {
      if (identical(_candidateApi, api)) {
        api.close();
        _candidateApi = null;
      }
      if (mounted) setState(() => _validating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _done || !_canGoBack,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_done && _canGoBack) _web?.goBack();
      },
      child: Scaffold(
        appBar: AppBar(
          toolbarHeight: 24 + MediaQuery.textScalerOf(context).scale(44),
          title: const CampusWordmark(subtitle: 'Đăng nhập tài khoản trường'),
          bottom: _progress < 1
              ? PreferredSize(
                  preferredSize: const Size.fromHeight(3),
                  child: LinearProgressIndicator(
                    value: _progress,
                    minHeight: 3,
                  ),
                )
              : null,
        ),
        body: widget.resetting
            ? const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('Đang xóa dữ liệu phiên đăng nhập cũ…'),
                  ],
                ),
              )
            : widget.blocked || _tokenRejected
            ? _sessionBlocked(context)
            : Stack(
                children: [
                  _loginWebView,
                  if (widget.sessionNotice != null)
                    Align(
                      alignment: Alignment.topCenter,
                      child: Material(
                        color: Theme.of(context).colorScheme.secondaryContainer,
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(widget.sessionNotice!),
                        ),
                      ),
                    ),
                  if (_menuError || _validationError != null)
                    _errorBanner(context),
                  if (_validating)
                    Positioned.fill(
                      child: ColoredBox(
                        color: Theme.of(context).colorScheme.surface,
                        child: const Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              CircularProgressIndicator(),
                              SizedBox(height: 16),
                              Text('Đang xác minh phiên và tải lịch học…'),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
      ),
    );
  }

  InAppWebView _createWebView() => InAppWebView(
    initialUrlRequest: URLRequest(
      url: WebUri(
        widget.restoreSession
            ? '$portalOrigin/congthongtin/Index.aspx'
            : _loginUrl,
      ),
    ),
    initialSettings: InAppWebViewSettings(
      javaScriptEnabled: true,
      domStorageEnabled: true,
      thirdPartyCookiesEnabled: true,
      javaScriptCanOpenWindowsAutomatically: true,
      supportMultipleWindows: false,
      allowsBackForwardNavigationGestures: true,
      useShouldOverrideUrlLoading: true,
    ),
    onWebViewCreated: (c) {
      _web = c;
      _startProbe();
    },
    onProgressChanged: (_, p) {
      if (mounted) setState(() => _progress = p / 100);
    },
    onUpdateVisitedHistory: (c, _, __) async {
      final can = await c.canGoBack();
      if (mounted && can != _canGoBack) setState(() => _canGoBack = can);
    },
    shouldOverrideUrlLoading: (c, action) async {
      final uri = action.request.url;
      final scheme = uri?.scheme.toLowerCase();
      if (uri == null ||
          const {'http', 'https', 'about', 'data', 'blob'}.contains(scheme)) {
        return NavigationActionPolicy.ALLOW;
      }
      try {
        await launchUrl(
          Uri.parse(uri.toString()),
          mode: LaunchMode.externalApplication,
        );
      } catch (_) {}
      return NavigationActionPolicy.CANCEL;
    },
  );

  Widget _sessionBlocked(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.lock_reset_rounded,
                size: 48,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(
                'Không thể khôi phục phiên đăng nhập',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              Text(
                _tokenRejected
                    ? 'Cổng sinh viên trả lại phiên cũ đã bị từ chối. '
                          'Đã dừng tự đăng nhập để tránh lặp.'
                    : widget.sessionNotice ?? 'Vui lòng đăng nhập lại.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: widget.onRetrySession,
                icon: const Icon(Icons.login_rounded),
                label: const Text('Đăng nhập lại'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _errorBanner(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Material(
          color: s.errorContainer,
          borderRadius: BorderRadius.circular(20),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 10, 14),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _validationError ??
                        'Không đọc được mục “Lịch cá nhân” của tài khoản này. '
                            'Kiểm tra lại quyền truy cập rồi thử lại.',
                    style: TextStyle(color: s.onErrorContainer),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(onPressed: _retry, child: const Text('Thử lại')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
