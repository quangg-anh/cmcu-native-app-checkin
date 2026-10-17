import 'dart:convert';

import 'package:cmc_checkin/core/portal_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'academic_fixture.dart';

void main() {
  test(
    'Schedule request uses captured UA, API-path cookies and portal AJAX headers',
    () async {
      Uri? cookieUrl;
      final api = PortalApi(
        session: testSession,
        userAgent: 'synthetic WebView user agent',
        cookieHeader: (url) async {
          cookieUrl = url;
          return 'portal_session=synthetic-cookie';
        },
        client: MockClient((request) async {
          expect(cookieUrl, request.url);
          expect(
            request.headers['Authorization'],
            'Bearer ${testSession.token}',
          );
          expect(request.headers['Cookie'], 'portal_session=synthetic-cookie');
          expect(request.headers['User-Agent'], 'synthetic WebView user agent');
          expect(request.headers['Origin'], portalOrigin);
          expect(
            request.headers['Referer'],
            '$portalOrigin/congthongtin/Index.aspx',
          );
          expect(request.headers['X-Requested-With'], 'XMLHttpRequest');
          return http.Response(jsonEncode({'Success': true, 'Data': []}), 200);
        }),
      );
      addTearDown(api.close);
      expect(
        await api.weekSchedule(DateTime(2026, 10, 12), DateTime(2026, 10, 18)),
        isEmpty,
      );
    },
  );

  test(
    'Browser-managed requests never export cookie or attach saved Bearer',
    () async {
      final lines = <String>[];
      final api = PortalApi(
        session: testSession,
        userAgent: 'synthetic WebView user agent',
        browserManagedSession: true,
        cookieHeader: (_) async => fail('Must not export cookie'),
        diagnosticLog: lines.add,
        client: MockClient((request) async {
          for (final name in [
            'Authorization',
            'Cookie',
            'User-Agent',
            'Origin',
            'Referer',
          ]) {
            expect(request.headers, isNot(contains(name)));
          }
          return http.Response('', 401);
        }),
      );
      addTearDown(api.close);
      await expectLater(
        api.weekSchedule(DateTime(2026, 10, 12), DateTime(2026, 10, 18)),
        throwsA(isA<SessionExpiredException>()),
      );
      expect(lines.single, contains('transport=webview'));
      expect(lines.single, contains('cookiePresent=browser_managed'));
      expect(lines.single, isNot(contains(testSession.token)));
    },
  );

  for (final cookie in [null, 'portal_session=secret-test-cookie']) {
    test(
      'HTTP 401 is not retried; diagnostics redact credentials (cookie=${cookie != null})',
      () async {
        final lines = <String>[];
        var requests = 0;
        final api = PortalApi(
          session: testSession,
          userAgent: 'secret-test-user-agent',
          cookieHeader: (_) async => cookie,
          diagnosticLog: lines.add,
          client: MockClient((_) async {
            requests++;
            return http.Response('secret-test-response', 401);
          }),
        );
        addTearDown(api.close);
        await expectLater(
          api.weekSchedule(DateTime(2026, 10, 12), DateTime(2026, 10, 18)),
          throwsA(isA<SessionExpiredException>()),
        );
        expect(requests, 1);
        final output = lines.join('\n');
        expect(output, contains('http_401 api=SV_ThongTin_MH'));
        expect(output, contains('cookiePresent=${cookie != null}'));
        expect(output, contains('userAgentPresent=true'));
        expect(output, contains('refererPresent=true'));
        for (final secret in [
          testSession.token,
          testSession.userId,
          'secret-test-cookie',
          'secret-test-user-agent',
          'secret-test-response',
          'tokenTail',
        ]) {
          expect(output, isNot(contains(secret)));
        }
      },
    );
  }
}
