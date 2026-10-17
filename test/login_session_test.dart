import 'dart:async';
import 'dart:convert';

import 'package:cmc_checkin/app.dart';
import 'package:cmc_checkin/core/app_preferences.dart';
import 'package:cmc_checkin/core/models.dart';
import 'package:cmc_checkin/core/portal_api.dart';
import 'package:cmc_checkin/features/login/login_screen.dart';
import 'package:cmc_checkin/features/schedule/schedule_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'academic_fixture.dart';

// CookieManager/WebStorageManager là singleton của package. Giữ fake chung
// giữa test để singleton vẫn trỏ vào cùng owner, rồi reset trạng thái mỗi test.
final _platform = _LoginPlatform();

class _LoginPlatform extends InAppWebViewPlatform {
  int webViews = 0;
  int requests = 0;
  int writes = 0;
  String token = 'synthetic-login-token';
  int status = 200;
  String responseBody = jsonEncode({'Success': true, 'Data': []});
  final cleared = <String>[];
  final requestedUrls = <String>[];
  Completer<void>? cleanup;
  Completer<CallAsyncJavaScriptResult?>? response;
  final initialUrls = <String>[];

  @override
  PlatformCookieManager createPlatformCookieManager(
    PlatformCookieManagerCreationParams params,
  ) => _LoginCookies(params, this);

  @override
  PlatformWebStorageManager createPlatformWebStorageManager(
    PlatformWebStorageManagerCreationParams params,
  ) => _LoginStorage(params, this);

  @override
  PlatformInAppWebViewController createPlatformInAppWebViewControllerStatic() =>
      _LoginController(this);

  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) {
    webViews++;
    initialUrls.add(params.initialUrlRequest!.url.toString());
    return _LoginWebView(params, this);
  }
}

class _LoginCookies extends PlatformCookieManager {
  _LoginCookies(super.params, this.owner) : super.implementation();
  final _LoginPlatform owner;

  @override
  Future<List<Cookie>> getCookies({
    required WebUri url,
    PlatformInAppWebViewController? iosBelow11WebViewController,
    PlatformInAppWebViewController? webViewController,
  }) async => throw StateError('App must not export browser cookies');

  @override
  Future<bool> deleteAllCookies() async {
    owner.cleared.add('cookies');
    await owner.cleanup?.future;
    return true;
  }
}

class _LoginStorage extends PlatformWebStorageManager {
  _LoginStorage(super.params, this.owner) : super.implementation();
  final _LoginPlatform owner;

  @override
  Future<void> deleteAllData() async => owner.cleared.add('storage');
}

class _LoginWebView extends PlatformInAppWebViewWidget {
  _LoginWebView(super.params, this.owner) : super.implementation();
  final _LoginPlatform owner;
  bool _created = false;

  @override
  Widget build(BuildContext context) {
    if (!_created) {
      _created = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        params.onWebViewCreated?.call(
          controllerFromPlatform<InAppWebViewController>(
            _LoginController(owner),
          ),
        );
      });
    }
    return const SizedBox.expand();
  }

  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      InAppWebViewController.fromPlatform(platform: controller) as T;

  @override
  void dispose() {}
}

class _LoginController extends PlatformInAppWebViewController {
  _LoginController(this.owner)
    : super.implementation(
        const PlatformInAppWebViewControllerCreationParams(id: 'login-test'),
      );
  final _LoginPlatform owner;

  @override
  Future<String> getDefaultUserAgent() async => 'synthetic-default-agent';

  @override
  Future<void> clearAllCache({bool includeDiskFiles = true}) async =>
      owner.cleared.add('cache');

  @override
  Future<void> reload() async {}

  @override
  Future<WebUri?> getUrl() async =>
      WebUri('https://iu.cmcu.edu.vn/congthongtin/Index.aspx');

  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async {
    expect(source, contains('navigator.userAgent'));
    expect(
      PlatformInAppWebViewController.debugLoggingSettings.enabled,
      isFalse,
    );
    return jsonEncode({
      'token': owner.token,
      'userId': 'synthetic-student',
      'chucNangId': 'schedule-menu',
      'gradesChucNangId': 'grades-menu',
      'menuLoaded': true,
      'userAgent': 'synthetic-login-user-agent',
    });
  }

  @override
  Future<CallAsyncJavaScriptResult?> callAsyncJavaScript({
    required String functionBody,
    Map<String, dynamic> arguments = const {},
    ContentWorld? contentWorld,
  }) async {
    owner.requests++;
    owner.requestedUrls.add(arguments['url'] as String);
    expect(functionBody, contains('xhr.withCredentials = true'));
    expect(arguments['userId'], 'synthetic-student');
    expect(arguments, isNot(contains('token')));
    if (owner.response != null) return owner.response!.future;
    return CallAsyncJavaScriptResult(
      value: {'status': owner.status, 'body': owner.responseBody},
    );
  }
}

void main() {
  late _LoginPlatform platform;
  setUp(() {
    platform = _platform
      ..webViews = 0
      ..requests = 0
      ..writes = 0
      ..token = 'synthetic-login-token'
      ..status = 200
      ..responseBody = jsonEncode({'Success': true, 'Data': []})
      ..cleanup = null
      ..response = null;
    platform.cleared.clear();
    platform.requestedUrls.clear();
    platform.initialUrls.clear();
    InAppWebViewPlatform.instance = platform;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.llfbandit.app_links/messages'),
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.llfbandit.app_links/events'),
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        if (call.method == 'write') platform.writes++;
        return null;
      },
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('home_widget'),
      (_) async => true,
    );
  });

  Future<void> flush(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump();
    }
  }

  Future<void> probe(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 700));
    await flush(tester);
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await flush(tester);
  }

  testWidgets(
    'AuthGate validates restored session in WebView, cleans up, stops after two 401s',
    (tester) async {
      final preferences = AppPreferences();
      addTearDown(preferences.dispose);
      platform.status = 401;
      platform.cleanup = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(
          home: AuthGate(initialSession: testSession, preferences: preferences),
        ),
      );
      expect(platform.initialUrls.single, endsWith('/Index.aspx'));
      await probe(tester);
      expect(platform.requests, 1);
      expect(platform.writes, 0);
      expect(find.byType(ScheduleScreen), findsNothing);
      expect(find.text('Đang xóa dữ liệu phiên đăng nhập cũ…'), findsOneWidget);
      expect(platform.cleared, containsAll(['cookies', 'cache', 'storage']));
      expect(platform.webViews, 1); // Chưa tạo WebView mới khi đang dọn phiên.
      platform.token = 'different-synthetic-token';
      platform.cleanup!.complete();
      await flush(tester);
      expect(platform.webViews, 2);
      expect(platform.initialUrls.last, endsWith('/login.aspx'));
      await probe(tester);
      expect(platform.requests, 2);
      expect(find.text('Không thể khôi phục phiên đăng nhập'), findsOneWidget);
      expect(find.byType(InAppWebView), findsNothing);
      await tester.pump(const Duration(seconds: 5));
      expect(platform.requests, 2);
      await tester.tap(find.text('Đăng nhập lại'));
      await flush(tester);
      expect(platform.webViews, 3);
      expect(find.byType(InAppWebView), findsOneWidget);
      expect(platform.requests, 2); // Thử lại mở login, không tự gửi request.
      await unmount(tester);
    },
  );

  testWidgets(
    'AuthGate keeps same WebView/client for refresh; no native request even if native returns 401',
    (tester) async {
      final preferences = AppPreferences();
      addTearDown(preferences.dispose);
      var nativeRequests = 0;
      final native = MockClient((_) async {
        nativeRequests++;
        return http.Response('', 401);
      });
      addTearDown(native.close);
      await http.runWithClient(() async {
        await tester.pumpWidget(
          MaterialApp(home: AuthGate(preferences: preferences)),
        );
        await probe(tester);
        expect(find.byType(ScheduleScreen), findsOneWidget);
        expect(platform.writes, 1);
        expect(
          platform.requests,
          1,
        ); // Lịch xác minh được dùng lại, không gọi đôi.
        expect(platform.webViews, 1);
        final login = find.byType(InAppWebView, skipOffstage: false);
        expect(login, findsOneWidget);
        expect(find.byType(InAppWebView), findsNothing);
        final controller = tester
            .widget<ScheduleScreen>(find.byType(ScheduleScreen))
            .controller;
        await controller.refresh();
        await tester.pump();
        expect(platform.requests, 2);
        expect(platform.webViews, 1);
        expect(nativeRequests, 0);
        await unmount(tester);
      }, () => native);
    },
  );

  testWidgets(
    'API 401 after successful login closes old transport and resets',
    (tester) async {
      final preferences = AppPreferences();
      addTearDown(preferences.dispose);
      await tester.pumpWidget(
        MaterialApp(home: AuthGate(preferences: preferences)),
      );
      await probe(tester);
      final api = tester
          .widget<ScheduleScreen>(find.byType(ScheduleScreen))
          .controller
          .api;
      platform.status = 401;
      await tester
          .widget<ScheduleScreen>(find.byType(ScheduleScreen))
          .controller
          .refresh();
      await flush(tester);
      expect(find.byType(ScheduleScreen), findsNothing);
      expect(platform.webViews, 2);
      expect(platform.cleared, containsAll(['cookies', 'cache', 'storage']));
      await expectLater(
        api.weekSchedule(DateTime(2026, 10, 12), DateTime(2026, 10, 18)),
        throwsA(isA<PortalException>()),
      );
      await unmount(tester);
    },
  );

  testWidgets('Does not save session or show schedule before API confirms', (
    tester,
  ) async {
    final preferences = AppPreferences();
    addTearDown(preferences.dispose);
    platform.response = Completer<CallAsyncJavaScriptResult?>();
    await tester.pumpWidget(
      MaterialApp(home: AuthGate(preferences: preferences)),
    );
    await probe(tester);
    expect(platform.requests, 1);
    expect(platform.writes, 0);
    expect(find.byType(ScheduleScreen), findsNothing);
    expect(find.text('Đang xác minh phiên và tải lịch học…'), findsOneWidget);
    platform.response!.complete(
      CallAsyncJavaScriptResult(
        value: {'status': 200, 'body': platform.responseBody},
      ),
    );
    await flush(tester);
    expect(platform.writes, 1);
    expect(find.byType(ScheduleScreen), findsOneWidget);
    await unmount(tester);
  });

  testWidgets(
    'Network failure stays on login and retries only on user action',
    (tester) async {
      var signedIn = 0;
      platform.responseBody = 'synthetic server error';
      platform.status = 503;
      await tester.pumpWidget(
        MaterialApp(
          home: LoginScreen(
            onSignedIn: (_, api, _, _) async {
              signedIn++;
              api.close();
            },
          ),
        ),
      );
      await probe(tester);
      expect(signedIn, 0);
      expect(find.textContaining('HTTP 503'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      expect(platform.requests, 1);
      platform.status = 200;
      platform.responseBody = jsonEncode({'Success': true, 'Data': []});
      await tester.tap(find.text('Thử lại'));
      await probe(tester);
      expect(signedIn, 1);
      expect(platform.requests, 2);
      await unmount(tester);
    },
  );

  for (final response in [
    jsonEncode({'Success': false, 'Message': 'Phiên không được chấp nhận'}),
    jsonEncode({'Success': true, 'Data': {}}),
    '<html>Login required</html>',
  ]) {
    testWidgets('Invalid API result cannot save login: $response', (
      tester,
    ) async {
      final preferences = AppPreferences();
      addTearDown(preferences.dispose);
      platform.responseBody = response;
      await tester.pumpWidget(
        MaterialApp(home: AuthGate(preferences: preferences)),
      );
      await probe(tester);
      expect(platform.requests, 1);
      expect(platform.writes, 0);
      expect(find.byType(ScheduleScreen), findsNothing);
      expect(find.text('Thử lại'), findsOneWidget);
      await unmount(tester);
    });
  }

  testWidgets(
    'Unmount during verification cannot publish or save late session',
    (tester) async {
      final preferences = AppPreferences();
      addTearDown(preferences.dispose);
      platform.response = Completer<CallAsyncJavaScriptResult?>();
      await tester.pumpWidget(
        MaterialApp(home: AuthGate(preferences: preferences)),
      );
      await probe(tester);
      await unmount(tester);
      platform.response!.complete(
        CallAsyncJavaScriptResult(
          value: {'status': 200, 'body': platform.responseBody},
        ),
      );
      await flush(tester);
      expect(platform.writes, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Does not create WebView while old session data is being cleared',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: LoginScreen(
            resetting: true,
            onSignedIn: (_, _, _, _) async =>
                fail('Must not sign in during cleanup'),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 3));
      expect(platform.webViews, 0);
      expect(find.text('Đang xóa dữ liệu phiên đăng nhập cũ…'), findsOneWidget);
      await unmount(tester);
    },
  );

  testWidgets('Blocked recovery does not create WebView or auto retry', (
    tester,
  ) async {
    var retries = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: LoginScreen(
          blocked: true,
          sessionNotice: 'HTTP 401: synthetic test error',
          onRetrySession: () => retries++,
          onSignedIn: (_, _, _, _) async =>
              fail('Must not sign in after repeated 401'),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 3));
    expect(platform.webViews, 0);
    expect(retries, 0);
    expect(find.text('HTTP 401: synthetic test error'), findsOneWidget);
    await tester.tap(find.text('Đăng nhập lại'));
    expect(retries, 1);
    await unmount(tester);
  });

  testWidgets('Rejected token stops probing and never reaches API', (
    tester,
  ) async {
    var accepted = 0;
    var retries = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: LoginScreen(
          onSignedIn: (_, _, _, _) async =>
              fail('Rejected token must not reach API'),
          acceptToken: (_) {
            accepted++;
            return false;
          },
          onRetrySession: () => retries++,
        ),
      ),
    );
    await probe(tester);
    expect(accepted, 1);
    expect(platform.requests, 0);
    expect(find.byType(InAppWebView), findsNothing);
    expect(find.textContaining('phiên cũ đã bị từ chối'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(accepted, 1);
    await tester.tap(find.text('Đăng nhập lại'));
    expect(retries, 1);
    await unmount(tester);
  });

  for (final token in ['synthetic-login-token', '']) {
    testWidgets(
      'Captures UA and validates session once (JWT=${token.isNotEmpty})',
      (tester) async {
        platform.token = token;
        final events = <String>[];
        Session? session;
        await tester.pumpWidget(
          MaterialApp(
            home: LoginScreen(
              acceptToken: (_) => true,
              onUserAgentCaptured: (ua) async => events.add(ua),
              onSignedIn: (value, api, week, entries) async {
                expect(platform.requests, 1);
                expect(entries, isEmpty);
                expect(week, startOfWeek(DateTime.now()));
                session = value;
                events.add('signed-in');
                api.close();
              },
            ),
          ),
        );
        await probe(tester);
        expect(events, ['synthetic-login-user-agent', 'signed-in']);
        expect(session!.token, token);
        expect(session!.chucNangId, 'schedule-menu');
        await tester.pump(const Duration(seconds: 3));
        expect(events, hasLength(2));
        expect(platform.requests, 1);
        await unmount(tester);
      },
    );
  }

  testWidgets('Blocked screen remains usable at 320px with 200% text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: LoginScreen(
          blocked: true,
          sessionNotice:
              'Cổng sinh viên vẫn trả HTTP 401 sau khi đăng nhập lại. '
              'Đã dừng tự đăng nhập. Vui lòng thử lại sau.',
          onSignedIn: (_, _, _, _) async {},
          onRetrySession: () {},
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Đăng nhập lại'));
    await tester.tap(find.text('Đăng nhập lại'));
    await unmount(tester);
  });
}
