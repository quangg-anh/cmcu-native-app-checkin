import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'display_text.dart';
import 'academic_models.dart';
import 'portal_crypto.dart';

const String portalOrigin = 'https://iu.cmcu.edu.vn';

/// Phần Config.js `Init_API()` mà app dùng: tiền tố action (trước dấu `_` đầu tiên) → base path.
const Map<String, String> _apiBases = {
  'SV': '/sinhvienapi/api',
  'CC': '/chuyencanapi/api',
};

class SessionExpiredException implements Exception {
  @override
  String toString() => 'Session expired';
}

class PortalException implements Exception {
  PortalException(this.message);
  final String message;
  @override
  String toString() => message;
}

const String offlineMessage =
    'Không thể kết nối cổng sinh viên. Kiểm tra mạng và thử lại.';

Uri apiUri(String action) {
  final i = action.indexOf('_');
  final prefix = i < 0 ? action : action.substring(0, i);
  final base = _apiBases[prefix];
  if (base == null) throw ArgumentError('No API base configured for $action');
  return Uri.parse('$portalOrigin$base/$action');
}

class PortalResponse {
  PortalResponse(this.data, this.message);
  final Object? data;
  final String? message;
}

/// `{Success, Message, Data}` — `Data` có thể là `{B: <ciphertext>}`.
PortalResponse parseResponse(String body) {
  final Object? root;
  try {
    root = jsonDecode(body);
  } on FormatException {
    throw PortalException('Phản hồi từ cổng sinh viên không hợp lệ.');
  }
  if (root is! Map)
    throw PortalException('Phản hồi từ cổng sinh viên không hợp lệ.');
  final rawMsg = root['Message'];
  final cleaned = rawMsg is String ? portalPlainText(rawMsg) : '';
  final message = cleaned.isNotEmpty ? cleaned : null;
  if (root['Success'] != true) {
    throw PortalException(message ?? 'Cổng sinh viên từ chối yêu cầu.');
  }
  Object? data = root['Data'];
  if (data is Map && data['B'] is String) {
    try {
      data = jsonDecode(
        PortalCrypto.decrypt(data['B'] as String, PortalCrypto.im),
      );
    } on FormatException {
      throw PortalException('Không đọc được dữ liệu từ cổng sinh viên.');
    }
  }
  return PortalResponse(data, message);
}

/// Đóng gói form giống `edu.system.makeRequest` (systemroot.js).
/// App dùng PortalWebClient để request chạy trong phiên trình duyệt đã đăng nhập;
/// HTTP client trực tiếp chỉ dành cho kiểm thử/công cụ với phiên được hỗ trợ.
class PortalApi {
  PortalApi({
    required this.session,
    required this.userAgent,
    required this.cookieHeader,
    http.Client? client,
    this.browserManagedSession = false,
    void Function(String message)? diagnosticLog,
  }) : _client = client ?? http.Client(),
       _diagnosticLog = diagnosticLog ?? _logDiagnostic;

  final Session session;
  final String userAgent;
  final Future<String?> Function(Uri url) cookieHeader;
  final http.Client _client;
  final bool browserManagedSession;
  final void Function(String message) _diagnosticLog;

  static void _logDiagnostic(String message) =>
      developer.log(message, name: 'auth');

  Future<List<ScheduleEntry>> weekSchedule(DateTime from, DateTime to) async {
    const action = 'SV_ThongTin_MH/DSA4BRINKCIpAiAPKSAv';
    // Dart Map giữ thứ tự chèn → JSON đúng thứ tự khóa như bản Kotlin.
    final payload = jsonEncode(<String, String>{
      'action': action,
      'func': 'pkg_congthongtin_hssv_thongtin.LayDSLichCaNhan',
      'iM': PortalCrypto.im,
      'strQLSV_NguoiHoc_Id': session.userId,
      'strNgayBatDau': _portalDate(from),
      'strNgayKetThuc': _portalDate(to),
      'strChucNang_Id': session.chucNangId,
      'strNguoiThucHien_Id': session.userId,
    });
    final key = action.substring(action.indexOf('/') + 1);
    final body = await _post(action, {'A': PortalCrypto.encrypt(payload, key)});
    final data = parseResponse(body).data;
    if (data is! List) {
      throw PortalException('Không đọc được lịch học từ cổng sinh viên.');
    }
    return parseSchedule(data);
  }

  Future<Object?> _academicRequest(
    String action,
    Map<String, String> fields,
  ) async {
    if (session.gradesChucNangId.isEmpty) {
      throw PortalException(
        'Cần đăng nhập lại để cập nhật quyền xem điểm học.',
      );
    }
    final payload = jsonEncode(<String, String>{'action': action, ...fields});
    final body = await _post(action, {
      'A': PortalCrypto.encrypt(payload, action.split('/').last),
    });
    return parseResponse(body).data;
  }

  Future<List<StudyProgram>> studyPrograms() async {
    final data = await _academicRequest(
      'SV_ThongTin_MH/DSA4FSkuLyYVKC8CKTQuLyYVMygvKQkuIgPP',
      {
        'func': 'pkg_congthongtin_hssv_thongtin.LayThongTinChuongTrinhHoc',
        'iM': PortalCrypto.im,
        'strChucNang_Id': session.gradesChucNangId,
        'strQLSV_NguoiHoc_Id': session.userId,
        'strNguoiThucHien_Id': session.userId,
      },
    );
    try {
      return StudyProgram.parse(data);
    } on FormatException {
      throw PortalException('Không đọc được danh sách chương trình học.');
    }
  }

  Future<AcademicRecord> academicRecord(String programId) async {
    final data =
        await _academicRequest('SV_ThongTin_MH/CiQ1EDQgCS4iFSAxAiAPKSAv', {
          'func': 'pkg_congthongtin_hssv_thongtin.KetQuaHocTapCaNhan',
          'iM': PortalCrypto.im,
          'strChucNang_Id': session.gradesChucNangId,
          'strQLSV_NguoiHoc_Id': session.userId,
          'strDaoTao_ChuongTrinh_Id': programId,
          'strNguoiThucHien_Id': session.userId,
        });
    try {
      return AcademicRecord.parse(data);
    } on FormatException {
      throw PortalException(
        'Cấu trúc bảng điểm đã thay đổi. Vui lòng thử lại sau.',
      );
    }
  }

  /// Endpoint có trong diemhoc.js; lấy theo ID tổng kết để không trộn các lần thi.
  Future<List<GradeComponent>> gradeComponents(String resultId) async {
    final data = await _academicRequest(
      'SV_ThongTin_MH/DSA4BRIFKCQsFSkgLykRKSAvFSkkLhUKCREP',
      {
        'func': 'pkg_congthongtin_hssv_thongtin.LayDSDiemThanhPhanTheoTKHP',
        'iM': PortalCrypto.im,
        'strDiem_NguoiHoc_TongKet_Id': resultId,
      },
    );
    try {
      return portalRows(data).map(GradeComponent.new).toList();
    } on FormatException {
      throw PortalException('Không đọc được điểm thành phần.');
    }
  }

  /// Gửi từ khóa điểm danh với cùng các field, cùng thứ tự như `save_TuGhiNhan`
  /// (lichgiang.js). Request này không có `iM` nên **không mã hóa**. Trả `Message` của portal.
  Future<String> checkIn(ScheduleEntry entry, String keyword, String ip) async {
    const action = 'CC_ThongTin/Them_QLSV_NguoiHoc_TuGhiNhan';
    final body = await _post(
      action,
      checkInFields(session, entry, keyword, ip),
    );
    return parseResponse(body).message ?? 'Điểm danh thành công.';
  }

  static Map<String, String> checkInFields(
    Session s,
    ScheduleEntry e,
    String keyword,
    String ip,
  ) => <String, String>{
    'action': 'CC_ThongTin/Them_QLSV_NguoiHoc_TuGhiNhan',
    'type': 'POST',
    'strChucNang_Id': s.chucNangId,
    'strDaoTao_LopQuanLy_Id': '',
    'strDiem_DanhSach_Id': e.classSectionId,
    'strNgayGhiNhan': e.dateText,
    'strGio': e.startHour,
    'strPhut': e.startMinute,
    'strGiay': '0',
    'strIp': ip,
    'strNoiDungTuGhiNhan': keyword,
    'strNguoiThucHien_Id': s.userId,
    'strQLSV_NguoiHoc_Id': s.userId,
    'strDaoTao_ChuongTrinh_Id': '',
    'strQLSV_TrangThaiNguoiHoc_Id': '',
  };

  Future<String> _post(String action, Map<String, String> fields) async {
    final url = apiUri(action);
    final headers = <String, String>{
      'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
      'Accept': 'application/json, text/javascript, */*; q=0.01',
      if (!browserManagedSession && session.token.isNotEmpty)
        'Authorization': 'Bearer ${session.token}',
      if (!browserManagedSession) ...{
        'User-Agent': userAgent,
        'Origin': portalOrigin,
        'Referer': '$portalOrigin/congthongtin/Index.aspx',
      },
      'X-Requested-With': 'XMLHttpRequest',
    };
    final cookie = browserManagedSession ? null : await cookieHeader(url);
    if (cookie != null && cookie.isNotEmpty) headers['Cookie'] = cookie;
    final http.Response res;
    try {
      // `body: Map` → http tự mã hóa form (UTF-8, khoảng trắng → '+').
      res = await _client
          .post(url, headers: headers, body: fields, encoding: utf8)
          .timeout(const Duration(seconds: 30));
    } on SocketException {
      throw PortalException(offlineMessage);
    } on TimeoutException {
      throw PortalException(offlineMessage);
    } on http.ClientException {
      throw PortalException(offlineMessage);
    }
    if (res.statusCode == 401) {
      // Chỉ ghi loại request và cờ hiện diện, không tokenTail/cookie/ID/body.
      _diagnosticLog(
        '[auth] http_401 api=${action.split('/').first} '
        'transport=${browserManagedSession ? 'webview' : 'native'} '
        'bearerPresent=${browserManagedSession ? 'browser_managed' : session.token.isNotEmpty} '
        'cookiePresent=${browserManagedSession ? 'browser_managed' : cookie != null && cookie.isNotEmpty} '
        'userAgentPresent=${browserManagedSession ? 'browser_managed' : userAgent.isNotEmpty} '
        'refererPresent=${browserManagedSession ? 'browser_managed' : headers.containsKey('Referer')} '
        'ajaxHeaderPresent=${headers.containsKey('X-Requested-With')}',
      );
      throw SessionExpiredException();
    }
    if (res.statusCode < 200 || res.statusCode > 299) {
      throw PortalException(
        'Cổng sinh viên trả về lỗi HTTP ${res.statusCode}.',
      );
    }
    return utf8.decode(res.bodyBytes);
  }

  void close() => _client.close();
}

String _portalDate(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
