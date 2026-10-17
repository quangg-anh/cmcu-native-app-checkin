import 'dart:async';

import 'package:cmc_checkin/core/models.dart';
import 'package:cmc_checkin/core/session_recovery.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'academic_fixture.dart';

const _freshSession = Session(
  token: 'new-test-token',
  userId: 'student-synthetic',
  chucNangId: 'schedule-menu',
  portalIp: '',
);

void main() {
  late List<String> calls;
  late SessionRecovery recovery;
  setUp(() {
    calls = [];
    recovery = SessionRecovery(
      clearSession: () async => calls.add('session'),
      clearWebSession: () async => calls.add('web'),
      clearWidget: () async => calls.add('widget'),
    );
  });

  test(
    'Clears saved session, WebView and widget before accepting a new token',
    () async {
      final pending = recovery.expire(testSession);
      expect(recovery.resetting, isTrue);
      expect(recovery.acceptToken(_freshSession.token), isFalse);
      await pending;
      expect(calls, ['session', 'web', 'widget']);
      expect(recovery.resetting, isFalse);
      expect(recovery.blocked, isFalse);
      expect(recovery.acceptToken(_freshSession.token), isTrue);
      expect(recovery.notice, contains('hết hạn'));
    },
  );

  test('Rejects stale token instead of calling the API in a loop', () async {
    await recovery.expire(testSession);
    expect(recovery.acceptToken(testSession.token), isFalse);
    expect(recovery.blocked, isTrue);
    expect(recovery.acceptToken(_freshSession.token), isFalse);
    expect(recovery.notice, contains('phiên đăng nhập cũ'));
  });

  test('Stops after two consecutive 401s even with different tokens', () async {
    await recovery.expire(testSession);
    expect(recovery.acceptToken(_freshSession.token), isTrue);
    // Probe thành công không được reset bộ đếm trước khi API chấp nhận phiên.
    await recovery.expire(_freshSession);
    expect(recovery.blocked, isTrue);
    expect(recovery.acceptToken('third-test-token'), isFalse);
    expect(recovery.notice, contains('HTTP 401'));
    expect(calls, ['session', 'web', 'widget', 'session', 'web', 'widget']);
  });

  test(
    'Cookie-only sessions do not share empty-token identity; still stop after two 401s',
    () async {
      const cookieSession = Session(
        token: '',
        userId: 'synthetic-cookie-user',
        chucNangId: 'schedule-menu',
        portalIp: '',
      );
      await recovery.expire(cookieSession);
      expect(recovery.acceptToken(''), isTrue);
      expect(recovery.blocked, isFalse);
      await recovery.expire(cookieSession);
      expect(recovery.blocked, isTrue);
      expect(recovery.acceptToken(''), isFalse);
      expect(recovery.notice, contains('HTTP 401'));
    },
  );

  test('Only accepted API response resets consecutive failures', () async {
    await recovery.expire(testSession);
    recovery.confirmAuthenticated();
    await recovery.expire(_freshSession);
    expect(recovery.blocked, isFalse);
    expect(recovery.acceptToken('third-test-token'), isTrue);
  });

  test(
    'Explicit retry clears all stores and starts a new recovery cycle',
    () async {
      await recovery.expire(testSession);
      await recovery.expire(_freshSession);
      expect(recovery.blocked, isTrue);
      await recovery.retry();
      expect(recovery.blocked, isFalse);
      expect(recovery.notice, isNull);
      expect(recovery.acceptToken(testSession.token), isTrue);
      expect(calls, hasLength(9));
    },
  );

  test(
    'Coalesces concurrent expiry callbacks and waits for WebView cleanup',
    () async {
      final webCleared = Completer<void>();
      recovery = SessionRecovery(
        clearSession: () async => calls.add('session'),
        clearWebSession: () => webCleared.future,
        clearWidget: () async => calls.add('widget'),
      );
      final first = recovery.expire(testSession);
      final second = recovery.expire(testSession);
      expect(identical(first, second), isTrue);
      expect(recovery.resetting, isTrue);
      expect(calls, ['session', 'widget']);
      webCleared.complete();
      await Future.wait([first, second]);
      expect(recovery.blocked, isFalse);
    },
  );

  test(
    'Cleanup failure blocks login but still clears other stores; retry recovers',
    () async {
      var fail = true;
      recovery = SessionRecovery(
        clearSession: () async => calls.add('session'),
        clearWebSession: () {
          if (fail) throw StateError('synthetic WebView failure');
          return Future.value();
        },
        clearWidget: () async => calls.add('widget'),
      );
      await recovery.expire(testSession);
      expect(calls, ['session', 'widget']);
      expect(recovery.resetting, isFalse);
      expect(recovery.blocked, isTrue);
      expect(recovery.notice, contains('Không xóa được'));
      expect(recovery.acceptToken(_freshSession.token), isFalse);
      fail = false;
      await recovery.retry();
      expect(recovery.blocked, isFalse);
    },
  );

  test('Recovery diagnostics contain no token, user ID or IP', () async {
    final lines = <String>[];
    final previous = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) =>
        lines.add(message ?? '');
    addTearDown(() => debugPrint = previous);
    await recovery.expire(testSession);
    recovery.acceptToken(testSession.token);
    final output = lines.join('\n');
    expect(output, contains('tokenRepeated=false'));
    expect(output, contains('reason=rejected_token'));
    expect(output, isNot(contains(testSession.token)));
    expect(output, isNot(contains(testSession.userId)));
    expect(output, isNot(contains('tokenTail')));
  });
}
