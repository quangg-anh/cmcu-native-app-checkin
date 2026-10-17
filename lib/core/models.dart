import 'dart:convert';
import 'display_text.dart';

/// Những gì app giữ lại từ `edu.system` sau khi đăng nhập.
class Session {
  const Session({
    required this.token,
    required this.userId,
    required this.chucNangId,
    required this.portalIp,
    this.gradesChucNangId = '',
  });

  /// JWT portal nếu có; phiên cookie được xác minh trong WebView có thể rỗng.
  final String token;
  final String userId;

  /// `strChucNang_Id` của mục menu "Lịch cá nhân".
  final String chucNangId;

  /// IP portal ghi lúc đăng nhập — chỉ dùng khi tra IP mới thất bại.
  final String portalIp;

  /// Quyền của menu Điểm học, độc lập với quyền xem lịch.
  final String gradesChucNangId;

  Map<String, dynamic> toJson() => {
    'token': token,
    'userId': userId,
    'chucNangId': chucNangId,
    'portalIp': portalIp,
    'gradesChucNangId': gradesChucNangId,
  };

  factory Session.fromJson(Map<String, dynamic> j) => Session(
    token: j['token'] as String,
    userId: j['userId'] as String,
    chucNangId: (j['chucNangId'] as String?) ?? '',
    portalIp: (j['portalIp'] as String?) ?? '',
    gradesChucNangId: (j['gradesChucNangId'] as String?) ?? '',
  );

  String encode() => jsonEncode(toJson());
  static Session? decode(String? s) {
    if (s == null) return null;
    try {
      return Session.fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }
}

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
bool sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// Thứ Hai của tuần chứa [d].
DateTime startOfWeek(DateTime d) =>
    dateOnly(d).subtract(Duration(days: d.weekday - DateTime.monday));

/// Một dòng của `LayDSLichCaNhan`. Giữ chuỗi gốc ở những trường check-in gửi lại.
class ScheduleEntry {
  const ScheduleEntry({
    required this.id,
    required this.classSectionId,
    required this.subject,
    required this.date,
    required this.dateText,
    required this.startHour,
    required this.startMinute,
    required this.endHour,
    required this.endMinute,
    required this.isExam,
    this.classSection,
    this.room,
    this.lecturer,
    this.firstPeriod,
    this.lastPeriod,
    this.examShift,
    this.attendance,
  });

  final String id;

  /// `IDLOPHOCPHAN` → `strDiem_DanhSach_Id` khi check-in.
  final String classSectionId;
  final String subject;
  final String? classSection;
  final String? room;
  final String? lecturer;
  final DateTime date; // đầu ngày, giờ địa phương
  /// `NGAYHOC` nguyên văn.
  final String dateText;
  final String startHour;
  final String startMinute;
  final String endHour;
  final String endMinute;
  final String? firstPeriod;
  final String? lastPeriod;
  final bool isExam;
  final String? examShift;

  /// `THONGTINCHUYENCAN` — ghi chú điểm danh portal hiển thị cạnh buổi học.
  final String? attendance;

  String get subjectLabel => portalPlainText(subject);
  String get roomLabel {
    final value = portalPlainText(room);
    return value.isEmpty
        ? 'Chưa có phòng'
        : (RegExp(r'^phòng\b', caseSensitive: false).hasMatch(value)
              ? value
              : 'Phòng $value');
  }

  String get lecturerLabel => portalPlainText(lecturer);
  String get attendanceLabel => portalPlainText(
    attendance,
  ).replaceFirst(RegExp(r'\s*\(\d+\)\s*$'), '').trim();
  bool get isPresent => searchKey(attendanceLabel) == 'co mat';
  bool get isAbsent =>
      RegExp(r'^vang(\b| )').hasMatch(searchKey(attendanceLabel));
  String get classSectionLabel => portalPlainText(classSection)
      .split('\n')
      .where(
        (line) =>
            searchKey(line) != searchKey(attendanceLabel) ||
            attendanceLabel.isEmpty,
      )
      .join('\n');
  int get periodCount => firstPeriod == null || lastPeriod == null
      ? 0
      : ((int.tryParse(lastPeriod!) ?? 0) -
                (int.tryParse(firstPeriod!) ?? 0) +
                1)
            .clamp(0, 30);

  int get startMinutes =>
      (int.tryParse(startHour) ?? 0) * 60 + (int.tryParse(startMinute) ?? 0);
  int get endMinutes =>
      (int.tryParse(endHour) ?? 0) * 60 + (int.tryParse(endMinute) ?? 0);
  String get startTime => _clock(startHour, startMinute);
  String get timeRange => '$startTime – ${_clock(endHour, endMinute)}';
}

String _clock(String h, String m) =>
    '${h.padLeft(2, '0')}:${m.padLeft(2, '0')}';

// ---------------------------------------------------------------- chọn lớp

/// Bao nhiêu phút trước giờ bắt đầu thì lớp đã được tính là "lớp hiện tại".
const int earlyCheckInMinutes = 15;

int minuteOfDay(DateTime t) => t.hour * 60 + t.minute;

/// Lớp cần check-in lúc [now]: buổi học (không phải thi) hôm nay đang diễn ra
/// hoặc bắt đầu trong vòng [earlyCheckInMinutes]. Trùng giờ → lớp bắt đầu muộn nhất.
ScheduleEntry? currentClass(List<ScheduleEntry> entries, DateTime now) {
  final minute = minuteOfDay(now);
  ScheduleEntry? best;
  for (final e in entries) {
    if (e.isExam || !sameDay(e.date, now)) continue;
    if (!(e.startMinutes - earlyCheckInMinutes <= minute &&
        minute < e.endMinutes)) {
      continue;
    }
    if (best == null || e.startMinutes > best.startMinutes) best = e;
  }
  return best;
}

/// Lớp kế tiếp hôm nay mà cửa sổ check-in chưa mở.
ScheduleEntry? nextClass(List<ScheduleEntry> entries, DateTime now) {
  final minute = minuteOfDay(now);
  ScheduleEntry? best;
  for (final e in entries) {
    if (e.isExam || !sameDay(e.date, now)) continue;
    if (!(e.startMinutes - earlyCheckInMinutes > minute)) continue;
    if (best == null || e.startMinutes < best.startMinutes) best = e;
  }
  return best;
}

// ----------------------------------------------------------------- parse lịch

List<ScheduleEntry> parseSchedule(Object? data) {
  if (data is! List) return const [];
  final list = <ScheduleEntry>[];
  for (final row in data) {
    if (row is Map) {
      final e = _toEntry(row.cast<String, dynamic>());
      if (e != null) list.add(e);
    }
  }
  list.sort((a, b) {
    final c = a.date.compareTo(b.date);
    return c != 0 ? c : a.startMinutes.compareTo(b.startMinutes);
  });
  return list;
}

ScheduleEntry? _toEntry(Map<String, dynamic> r) {
  final id = _text(r, 'ID');
  final dateText = _text(r, 'NGAYHOC');
  if (id == null || dateText == null) return null;
  final date = _parseDate(dateText);
  if (date == null) return null;
  return ScheduleEntry(
    id: id,
    classSectionId: _text(r, 'IDLOPHOCPHAN') ?? '',
    subject: _text(r, 'TENHOCPHAN') ?? _text(r, 'DANGKY_LOPHOCPHAN_TEN') ?? '—',
    classSection: _text(r, 'TENLOPHOCPHAN'),
    room: _text(r, 'TENPHONGHOC') ?? _text(r, 'PHONGHOC_TEN'),
    lecturer: _text(r, 'GIANGVIEN'),
    date: date,
    dateText: dateText,
    startHour: _text(r, 'GIOBATDAU') ?? '0',
    startMinute: _text(r, 'PHUTBATDAU') ?? '0',
    endHour: _text(r, 'GIOKETTHUC') ?? '0',
    endMinute: _text(r, 'PHUTKETTHUC') ?? '0',
    firstPeriod: _text(r, 'TIETBATDAU'),
    lastPeriod: _text(r, 'TIETKETTHUC'),
    isExam: _text(r, 'PHANLOAI') == 'LICHTHI',
    examShift: _text(r, 'CATHI'),
    attendance: _text(r, 'THONGTINCHUYENCAN'),
  );
}

/// `d/M/yyyy` (chấp nhận cả `03/10/2026`).
DateTime? _parseDate(String s) {
  final p = s.split('/');
  if (p.length != 3) return null;
  final d = int.tryParse(p[0]), m = int.tryParse(p[1]), y = int.tryParse(p[2]);
  if (d == null || m == null || y == null) return null;
  final date = DateTime(y, m, d);
  return (date.year == y && date.month == m && date.day == d) ? date : null;
}

/// Giá trị trường như JavaScript của portal sẽ stringify (số mất đuôi ".0"), đã trim; rỗng → null.
String? _text(Map<String, dynamic> row, String key) {
  final v = row[key];
  if (v == null) return null;
  String raw;
  if (v is String) {
    raw = v;
  } else if (v is num) {
    raw = (v % 1 == 0) ? v.toInt().toString() : v.toString();
  } else {
    raw = v.toString();
  }
  raw = raw.trim();
  return raw.isEmpty ? null : raw;
}
