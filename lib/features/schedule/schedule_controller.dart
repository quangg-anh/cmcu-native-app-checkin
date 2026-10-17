import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/models.dart';
import '../../core/portal_api.dart';
import '../../core/public_ip.dart';
import '../../core/display_text.dart';

enum ScheduleFilter { all, classes, exams }

class CheckInState {
  const CheckInState({
    required this.entry,
    this.focusKeyword = false,
    this.ip,
    this.sending = false,
    this.result,
    this.succeeded = false,
  });

  final ScheduleEntry entry;
  final bool focusKeyword;
  final String? ip;
  final bool sending;
  final String? result;
  final bool succeeded;

  CheckInState copyWith({
    String? ip,
    bool? sending,
    String? result,
    bool clearResult = false,
    bool? succeeded,
  }) => CheckInState(
    entry: entry,
    focusKeyword: focusKeyword,
    ip: ip ?? this.ip,
    sending: sending ?? this.sending,
    result: clearResult ? null : (result ?? this.result),
    succeeded: succeeded ?? this.succeeded,
  );
}

class ScheduleController extends ChangeNotifier {
  ScheduleController({
    required this.api,
    required this.fallbackIp,
    this.onCurrentWeekLoaded,
    DateTime? initialWeekStart,
    List<ScheduleEntry>? initialEntries,
    DateTime Function()? clock,
    Future<String?> Function()? ipLookup,
  }) : _clock = clock ?? DateTime.now,
       _lookupIp = ipLookup ?? PublicIp.lookup {
    final today = dateOnly(now);
    _selectedDay = today;
    _weekStart = startOfWeek(today);
    if (initialWeekStart != null && initialEntries != null) {
      _weeks[startOfWeek(initialWeekStart)] = initialEntries;
      _updatedAt[startOfWeek(initialWeekStart)] = now;
    }
    _load(force: false);
  }

  final PortalApi api;
  final String fallbackIp;
  final DateTime Function() _clock;
  final Future<String?> Function() _lookupIp;
  DateTime get now => _clock();
  String query = '';
  ScheduleFilter filter = ScheduleFilter.all;
  bool weekOverview = false;
  final Map<DateTime, DateTime> _updatedAt = {};
  DateTime? get updatedAt => _updatedAt[_weekStart];
  final void Function(DateTime weekStart, List<ScheduleEntry> entries)?
  onCurrentWeekLoaded;

  late DateTime _weekStart;
  late DateTime _selectedDay;
  List<ScheduleEntry> _entries = const [];
  bool _loading = false;
  String? _error;
  bool _sessionExpired = false;
  String? _notice;
  CheckInState? _checkIn;
  final Map<DateTime, List<ScheduleEntry>> _weeks = {};
  int _loadToken = 0;
  Future<void>? _loadFuture;
  bool _disposed = false;
  bool _checkInNowPending = false;

  DateTime get weekStart => _weekStart;
  DateTime get selectedDay => _selectedDay;
  List<ScheduleEntry> get entries => _entries;
  bool get loading => _loading;
  String? get error => _error;
  bool get sessionExpired => _sessionExpired;
  String? get notice => _notice;
  CheckInState? get checkIn => _checkIn;

  List<DateTime> get weekDays =>
      List.generate(7, (i) => _weekStart.add(Duration(days: i)));
  List<ScheduleEntry> get dayEntries =>
      _entries.where((e) => sameDay(e.date, _selectedDay)).toList();
  List<ScheduleEntry> get visibleEntries {
    final search = searchKey(query);
    return (weekOverview ? entries : dayEntries)
        .where(
          (entry) =>
              (filter == ScheduleFilter.all ||
                  (filter == ScheduleFilter.exams
                      ? entry.isExam
                      : !entry.isExam)) &&
              (search.isEmpty ||
                  searchKey(
                    '${entry.subjectLabel} ${entry.roomLabel} ${entry.lecturerLabel} ${entry.classSectionLabel}',
                  ).contains(search)),
        )
        .toList();
  }

  void search(String value) {
    query = value;
    _emit();
  }

  void selectFilter(ScheduleFilter value) {
    filter = value;
    _emit();
  }

  void showWeek(bool value) {
    weekOverview = value;
    _emit();
  }

  void resetFilters() {
    query = '';
    filter = ScheduleFilter.all;
    _emit();
  }

  void refreshTime() => _emit();
  void goToDate(DateTime date) {
    weekOverview = false;
    _moveTo(date);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  void previousWeek() =>
      _moveTo(_selectedDay.subtract(const Duration(days: 7)));
  void nextWeek() => _moveTo(_selectedDay.add(const Duration(days: 7)));
  void goToToday() {
    weekOverview = false;
    _moveTo(now);
  }

  void selectDay(DateTime d) {
    weekOverview = false;
    _selectedDay = dateOnly(d);
    _emit();
  }

  Future<void> refresh() {
    _load(force: true);
    return _loadFuture ?? Future.value();
  }

  void noticeShown() => _notice = null;

  void _moveTo(DateTime date) {
    final day = dateOnly(date);
    final week = startOfWeek(day);
    final changed = week != _weekStart;
    _selectedDay = day;
    _weekStart = week;
    if (changed) {
      _load(force: false);
    } else {
      _emit();
    }
  }

  void checkInNow() {
    final now = this.now;
    final thisWeek = startOfWeek(now);
    final weekEntries = _weeks[thisWeek];
    if (weekEntries == null) {
      _checkInNowPending = true;
      if (_weekStart != thisWeek) {
        _moveTo(now);
      } else if (!_loading) {
        _load(force: false);
      }
      return;
    }
    _checkInNowPending = false;
    _moveTo(now);
    final entry = currentClass(weekEntries, now);
    if (entry == null) {
      final next = nextClass(weekEntries, now);
      _notice = next != null
          ? 'Chưa có lớp đang học. Tiếp theo: ${next.subjectLabel} lúc ${next.startTime}.'
          : 'Hiện không có lớp đang học.';
      _emit();
      return;
    }
    if (_checkIn?.entry.id != entry.id) _showCheckIn(entry, focusKeyword: true);
  }

  void openCheckIn(ScheduleEntry entry) =>
      _showCheckIn(entry, focusKeyword: false);

  void dismissCheckIn() {
    if (_checkIn == null) return;
    _checkIn = null;
    _emit();
  }

  void _showCheckIn(ScheduleEntry entry, {required bool focusKeyword}) {
    _checkIn = CheckInState(entry: entry, focusKeyword: focusKeyword);
    _emit();
    if (entry.isExam || entry.isPresent) return;
    () async {
      final ip = await _lookupIp() ?? fallbackIp;
      final cur = _checkIn;
      if (!_disposed &&
          cur != null &&
          cur.entry.id == entry.id &&
          cur.ip == null) {
        _checkIn = cur.copyWith(ip: ip);
        _emit();
      }
    }();
  }

  Future<void> submitCheckIn(String keyword) async {
    final current = _checkIn;
    if (_disposed ||
        current == null ||
        current.sending ||
        current.succeeded ||
        current.entry.isExam ||
        current.entry.isPresent)
      return;
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) return;
    _checkIn = current.copyWith(sending: true, clearResult: true);
    _emit();
    final ip = current.ip ?? await _lookupIp() ?? fallbackIp;
    if (_disposed) return;
    CheckInState? outcome;
    try {
      final message = await api.checkIn(current.entry, trimmed, ip);
      outcome = current.copyWith(
        ip: ip,
        sending: false,
        result: message,
        succeeded: true,
      );
    } on SessionExpiredException {
      _sessionExpired = true;
    } on PortalException catch (e) {
      outcome = current.copyWith(
        ip: ip,
        sending: false,
        result: e.message,
        succeeded: false,
      );
    } catch (_) {
      outcome = current.copyWith(
        ip: ip,
        sending: false,
        result: offlineMessage,
        succeeded: false,
      );
    }
    if (_disposed) return;
    if (_checkIn?.entry.id == current.entry.id) _checkIn = outcome;
    _emit();
    if (outcome?.succeeded == true) _load(force: true);
  }

  void _load({required bool force}) {
    final start = _weekStart;
    final cached = _weeks[start];
    final token = ++_loadToken;
    if (cached != null && !force) {
      _entries = cached;
      _loading = false;
      _error = null;
      _loadFuture = null;
      _emit();
      return;
    }
    _entries = cached ?? const [];
    _loading = true;
    _error = null;
    // Có dữ liệu cũ thì vẽ ngay, không dựng spinner (tránh nhấp nháy
    // spinner → bảng khi dữ liệu về trong cùng khung hình).
    if (cached == null) _emit();
    _loadFuture = _fetch(start, token);
  }

  Future<void> _fetch(DateTime start, int token) async {
    try {
      final result = await api.weekSchedule(
        start,
        start.add(const Duration(days: 6)),
      );
      if (token != _loadToken || _disposed) return;
      _weeks[start] = result;
      _updatedAt[start] = now;
      if (_weekStart == start) {
        _entries = result;
        _loading = false;
      }
      _emit();
      if (start == startOfWeek(now)) {
        onCurrentWeekLoaded?.call(start, result);
        if (_checkInNowPending) {
          checkInNow();
        }
      }
    } on SessionExpiredException {
      if (token != _loadToken || _disposed) return;
      _loading = false;
      _sessionExpired = true;
      _emit();
    } on PortalException catch (e) {
      if (token != _loadToken || _disposed) return;
      if (_weekStart == start) {
        _loading = false;
        _error = e.message;
      }
      _emit();
    } catch (_) {
      if (token != _loadToken || _disposed) return;
      if (_weekStart == start) {
        _loading = false;
        _error = offlineMessage;
      }
      _emit();
    }
  }
}
