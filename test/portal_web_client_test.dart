import 'dart:async';
import 'dart:convert';

import 'package:cmc_checkin/core/models.dart';
import 'package:cmc_checkin/core/portal_api.dart';
import 'package:cmc_checkin/core/portal_crypto.dart';
import 'package:cmc_checkin/core/portal_web_client.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'academic_fixture.dart';

class _WebController extends PlatformInAppWebViewController {
  _WebController()
    : super.implementation(
        const PlatformInAppWebViewControllerCreationParams(
          id: 'transport-test',
        ),
      );

  String page = '$portalOrigin/congthongtin/Index.aspx';
  int requests = 0;
  Map<String, dynamic> arguments = {};
  String source = '';
  CallAsyncJavaScriptResult? result = CallAsyncJavaScriptResult(
    value: {
      'status': 200,
      'body': jsonEncode({'Success': true, 'Data': []}),
    },
  );
  Completer<CallAsyncJavaScriptResult?>? pending;
  bool fail = false;

  @override
  Future<WebUri?> getUrl() async => WebUri(page);

  @override
  Future<CallAsyncJavaScriptResult?> callAsyncJavaScript({
    required String functionBody,
    Map<String, dynamic> arguments = const {},
    ContentWorld? contentWorld,
  }) async {
    requests++;
    this.arguments = arguments;
    source = functionBody;
    if (fail) throw StateError('sensitive synthetic exception');
    return pending != null ? pending!.future : result;
  }
}

void main() {
  late _WebController web;
  late PortalWebClient client;
  late PortalApi api;

  setUp(() {
    web = _WebController();
    client = PortalWebClient(
      web: InAppWebViewController.fromPlatform(platform: web),
      userId: testSession.userId,
    );
    api = PortalApi(
      session: testSession,
      userAgent: 'synthetic-agent',
      cookieHeader: (_) async => throw StateError('Must not export cookie'),
      client: client,
      browserManagedSession: true,
    );
  });

  tearDown(() => api.close());

  Future<List<Object>> schedule() async =>
      api.weekSchedule(DateTime(2026, 10, 12), DateTime(2026, 10, 18));

  test(
    'Encrypted form reaches WebView unchanged, no saved token passed to JS',
    () async {
      expect(await schedule(), isEmpty);
      expect(web.requests, 1);
      expect(
        web.arguments['url'],
        apiUri('SV_ThongTin_MH/DSA4BRINKCIpAiAPKSAv').toString(),
      );
      expect(web.arguments['userId'], testSession.userId);
      expect(web.arguments, isNot(contains('token')));
      final form = Uri.splitQueryString(web.arguments['body'] as String);
      final payload =
          jsonDecode(PortalCrypto.decrypt(form['A']!, 'DSA4BRINKCIpAiAPKSAv'))
              as Map;
      expect(payload['strQLSV_NguoiHoc_Id'], testSession.userId);
      expect(payload['strChucNang_Id'], testSession.chucNangId);
      expect(payload['strNgayBatDau'], '12/10/2026');
      expect(web.source, contains('location.origin !== origin'));
      expect(web.source, contains("String(system.userId || '') !== userId"));
      expect(web.source, contains("typeof system.tokenJWT === 'string'"));
      expect(web.source, contains('xhr.withCredentials = true'));
      expect(web.source, contains('xhr.timeout = 30000'));
      expect(web.source, isNot(contains('document.cookie')));
      expect(web.source, isNot(contains("setRequestHeader('User-Agent'")));
      expect(web.source, isNot(contains("setRequestHeader('Origin'")));
      expect(web.source, isNot(contains("setRequestHeader('Referer'")));
    },
  );

  test(
    'Schedule, grades and check-in all use same WebView transport',
    () async {
      await schedule();
      await api.studyPrograms();
      web.result = CallAsyncJavaScriptResult(
        value: {
          'status': 200,
          'body': jsonEncode({'Success': true, 'Data': academicFixture()}),
        },
      );
      await api.academicRecord('synthetic-program');
      web.result = CallAsyncJavaScriptResult(
        value: {
          'status': 200,
          'body': jsonEncode({'Success': true, 'Data': []}),
        },
      );
      await api.gradeComponents('synthetic-result');
      final entry = parseSchedule([
        {'ID': 'synthetic-class', 'NGAYHOC': '12/10/2026'},
      ]).single;
      await api.checkIn(entry, 'Từ khóa & + =', '192.0.2.1');
      expect(web.requests, 5);
      expect(web.arguments['url'], contains('/chuyencanapi/api/CC_ThongTin/'));
      final form = Uri.splitQueryString(web.arguments['body'] as String);
      expect(
        form,
        PortalApi.checkInFields(
          testSession,
          entry,
          'Từ khóa & + =',
          '192.0.2.1',
        ),
      );
    },
  );

  for (final uri in [
    'https://example.test/sinhvienapi/api/SV_ThongTin_MH/DSA4BRINKCIpAiAPKSAv',
    'http://iu.cmcu.edu.vn/sinhvienapi/api/SV_ThongTin_MH/DSA4BRINKCIpAiAPKSAv',
    '$portalOrigin/congthongtin/login.aspx',
    '$portalOrigin/sinhvienapi/api/SV_ThongTin_MH/unknown',
    '$portalOrigin/sinhvienapi/api/SV_ThongTin_MH/DSA4BRINKCIpAiAPKSAv?leak=true',
    '$portalOrigin/sinhvienapi/api/SV_ThongTin_MH/DSA4BRINKCIpAiAPKSAv#fragment',
    'https://user:password@iu.cmcu.edu.vn/sinhvienapi/api/SV_ThongTin_MH/DSA4BRINKCIpAiAPKSAv',
  ]) {
    test('Rejects unsupported URL before JS: $uri', () async {
      await expectLater(
        client.post(Uri.parse(uri), body: 'A=synthetic'),
        throwsA(isA<http.ClientException>()),
      );
      expect(web.requests, 0);
    });
  }

  test('Rejects unsupported method before JS', () async {
    await expectLater(
      client.get(apiUri('SV_ThongTin_MH/DSA4BRINKCIpAiAPKSAv')),
      throwsA(isA<http.ClientException>()),
    );
    expect(web.requests, 0);
  });

  test('Never evaluates request on Microsoft or another origin', () async {
    web.page = 'https://login.microsoftonline.com/synthetic';
    await expectLater(schedule(), throwsA(isA<SessionExpiredException>()));
    expect(web.requests, 0);
  });

  test(
    'Navigation or account change reported by JS invalidates session',
    () async {
      web.result = CallAsyncJavaScriptResult(value: {'expired': true});
      await expectLater(schedule(), throwsA(isA<SessionExpiredException>()));
      expect(web.requests, 1);
    },
  );

  test('HTTP 401 propagates once, no retry/fallback without Bearer', () async {
    web.result = CallAsyncJavaScriptResult(
      value: {'status': 401, 'body': 'synthetic secret'},
    );
    await expectLater(schedule(), throwsA(isA<SessionExpiredException>()));
    expect(web.requests, 1);
  });

  for (final value in [
    null,
    {'failed': true},
    {'status': 0, 'body': ''},
    {'status': 200, 'body': null},
    {'status': '200', 'body': '{}'},
  ]) {
    test('Invalid JS response becomes safe connection error: $value', () async {
      web.result = CallAsyncJavaScriptResult(value: value);
      await expectLater(
        schedule(),
        throwsA(
          isA<PortalException>().having(
            (e) => e.message,
            'message',
            offlineMessage,
          ),
        ),
      );
      expect(web.requests, 1);
    });
  }

  test('JS/platform error is redacted', () async {
    web.fail = true;
    await expectLater(
      schedule(),
      throwsA(
        isA<PortalException>().having(
          (e) => e.message,
          'message',
          offlineMessage,
        ),
      ),
    );
  });

  test('Closing transport rejects new and in-flight requests', () async {
    web.pending = Completer<CallAsyncJavaScriptResult?>();
    final pending = schedule();
    final rejected = expectLater(pending, throwsA(isA<PortalException>()));
    await Future<void>.delayed(Duration.zero);
    expect(web.requests, 1);
    api.close();
    await rejected;
    web.pending!.complete(web.result);
    await expectLater(schedule(), throwsA(isA<PortalException>()));
    expect(web.requests, 1);
  });
}
