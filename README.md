# IU CheckIn

IU CheckIn là ứng dụng Flutter xem lịch học, nhập từ khóa điểm danh và xem kết quả học tập từ cổng sinh viên CMC.

## Chức năng

- **Lịch học:** chuyển tuần/ngày, chọn ngày nhanh, tìm không dấu theo môn/phòng/giảng viên, lọc lịch học/lịch thi trong dữ liệu đã tải, xem cả tuần theo ngày, kéo để tải lại.
- **Điểm danh:** nhãn “Có mặt” riêng, loại bỏ HTML như `<br>` khỏi nhãn hiển thị; thông tin lớp dài nằm trong chi tiết, có nút sao chép. Người dùng chủ động mở ô nhập từ khóa; không tự bật sheet khi tải lịch. Chặn gửi lặp khi đang xử lý, đã thành công hoặc portal báo có mặt.
- **Kết quả:** chọn chương trình học, lọc học kỳ, tìm tên/mã môn không dấu, sắp xếp học kỳ/tên/điểm, lọc môn đã có điểm; xem điểm hệ 10/hệ 4/điểm chữ, đánh giá, lần học/lần thi và điểm thành phần.
- **Tổng quan:** GPA tích lũy, trung bình học kỳ, tín chỉ tích lũy và tiến độ chương trình từ số liệu portal. Không tự tính lại GPA bằng cách lấy trung bình các điểm đang lọc.
- **Giao diện:** nhận diện IU CheckIn với xanh navy–cyan, monogram IU, họa tiết khiên/check, thanh điều hướng nổi, thẻ lịch có màu phân biệt lớp; tổng quan lịch trong ngày và vòng tiến độ tín chỉ theo số liệu portal. Có sáng/tối, chuyển tab mượt, giữ vị trí cuộn/từ khóa và hiệu ứng thẻ/chọn ngày.
- **Tùy chỉnh:** sáng/tối/hệ thống, lịch gọn và giảm chuyển động, được lưu trên máy. Tôn trọng cài đặt giảm chuyển động của hệ điều hành; thao tác đăng xuất nằm trong cài đặt và có bước xác nhận.
- **Trạng thái:** đang tải, rỗng, lỗi, thử lại, thời điểm cập nhật; giữ dữ liệu đã tải trong RAM khi làm mới thất bại và báo rõ dữ liệu cũ.

## Chạy và kiểm tra

Cần Flutter >= 3.44 / Dart >= 3.12 theo bộ dependency trong `pubspec.lock`. Lượt triển khai này được kiểm tra bằng Flutter 3.47.7 / Dart 3.13.5 trên Windows.

```sh
flutter pub get
flutter analyze
flutter test
```

Kết quả: `flutter analyze` không có vấn đề và 31 unit/widget test chạy thành công. Kiểm thử bao gồm HTML/HTML đã escape, văn bản tiếng Việt không dấu, request không bị sửa bởi bước làm sạch nhãn, chặn gửi điểm danh lặp, sắp xếp điểm/null, lưu cài đặt, giữ state giữa tab, sao chép thông tin, chọn ngày/lọc lịch và giao diện sáng/tối 320px với text scale 150%–200%. Kiểm tra offline HAR đọc được 1 chương trình, 16 học phần và 3 học kỳ; xác nhận bộ chọn GPA toàn khóa/học kỳ. Đây chưa phải kiểm thử trực tiếp tài khoản hoặc thiết bị.

Checkout hiện chỉ chứa mã Dart và một phần cấu hình iOS; chưa có đầy đủ project Android/iOS để chạy trực tiếp. Khi chuẩn bị platform, lưu lại cấu hình `ios/Runner/Info.plist`, widget và signing rồi tạo project theo tài liệu kỹ thuật. Chưa xác nhận build IPA/APK hoặc chạy SSO trên thiết bị thật trong lượt này.

Tên hiển thị iOS và widget là **IU CheckIn**. Biểu trưng được cung cấp nằm tại `assets/brand/campus-emblem.png`; icon iOS đủ kích thước nằm trong `ios/Runner/Assets.xcassets/AppIcon.appiconset`. Cấu hình Codemagic áp dụng lại tên/icon sau khi tạo platform và xuất `IU-CheckIn-unsigned.ipa`. Khi đã có project Xcode đầy đủ, cập nhật icon bằng `dart run flutter_launcher_icons`. Với catalog đã có trong checkout này, kiểm tra manifest và kích thước PNG bằng `dart run tool/complete_ios_icon_catalog.dart`.

Nếu đang dùng phiên đăng nhập cũ, **đăng xuất rồi đăng nhập lại** để thu nhận thêm quyền menu “Điểm học”. App lấy riêng ID menu lịch và điểm từ phiên portal; phiên cũ thiếu quyền xem điểm sẽ hiện hướng dẫn đăng nhập lại.

### Phục hồi phiên khi API trả HTTP 401 (#4)

- App dừng request cũ, xóa session đã lưu, cache widget, cookie/cache/storage của WebView trước khi mở trang đăng nhập mới. iOS/macOS dùng `WKWebsiteDataStore` qua `removeDataModifiedSince`; Android dùng `deleteAllData`. Nếu dọn dữ liệu thất bại, app dừng và hiện nút **Đăng nhập lại**, không tiếp tục bằng cookie cũ.
- Token đã bị API từ chối không được nhận lại từ `Index.aspx`. Nếu hai phiên liên tiếp cùng bị 401, kể cả hai token khác nhau, app dừng tự đăng nhập. Chỉ API lịch thành công hoặc người dùng chủ động bấm **Đăng nhập lại** mới bắt đầu chu kỳ phục hồi mới; probe đọc được token không reset bộ đếm.
- Request dùng `navigator.userAgent` thu được từ trang đăng nhập (fallback UA mặc định khi khôi phục phiên đã lưu), cookie đúng URL API, `Origin`, `Referer` và `X-Requested-With: XMLHttpRequest`.
- Log `[auth] http_401` chỉ báo nhóm API và sự hiện diện của Bearer/cookie/UA/header; `tokenRepeated` và `reason=rejected_token` phân biệt phiên cũ bị dùng lại. Không ghi token/tokenTail, cookie, ID, IP, request body hoặc response body. Token mới vẫn bị 401 chưa chứng minh nguyên nhân cụ thể; cần xác minh request trong phiên hợp lệ trên thiết bị.

Kiểm thử hồi quy nằm trong `test/session_recovery_test.dart`, `test/login_session_test.dart`, `test/portal_session_test.dart` và `test/web_session_test.dart`. Với bản sửa #4: Flutter 3.47.7 / Dart 3.13.5, `flutter analyze --no-pub` không có vấn đề; `flutter test --no-pub --timeout 45s` đạt **54 test** (31 test cũ + 23 test mới). CLI `tool/verify_har.dart` cũng chạy được bằng Dart thuần với HAR giả lập (1 chương trình, 3 học phần, 3 học kỳ). Không gọi portal thật, không dùng tài khoản hoặc dữ liệu sinh viên thật. Chưa xác minh SSO trên thiết bị thật hoặc build APK/IPA.

### Giữ request trong phiên portal đã đăng nhập

Bản tiếp theo xử lý chỗ chuyển từ WebView sang HTTP client native, thay vì chỉ dừng vòng lặp:

- `PortalWebClient` gửi POST bằng `XMLHttpRequest` **ngay trong WebView đã đăng nhập**. WebView tự quản lý cookie HttpOnly/path/SameSite, UA, Origin, Referer; Bearer lấy từ `edu.system.tokenJWT` hiện tại nếu portal cấp. Không xuất cookie sang Dart, không dùng token Microsoft thay token portal, không thử bỏ Bearer sau 401.
- WebView được giữ sống và ẩn bằng `Offstage` sau đăng nhập. Lịch, điểm và điểm danh dùng cùng client; cập nhật giao diện không tạo lại WebView/controller.
- Chỉ lưu session và mở lịch sau khi API lịch trả HTTP 2xx, `Success == true`, giải mã được và `Data` là danh sách. Dữ liệu tuần xác minh được chuyển vào controller, tránh gọi lịch hai lần. Danh sách rỗng hợp lệ vẫn được chấp nhận; HTML đăng nhập, JSON sai cấu trúc hoặc `Success == false` không được coi là thành công.
- Session lưu trên máy chỉ gợi ý mở lại `Index.aspx`. Mỗi lần mở app vẫn cần khôi phục ngữ cảnh portal và xác minh API trong WebView; không phát lại JWT cũ bằng HTTP client riêng. Phiên portal có user/menu nhưng không có JWT cũng phải vượt qua bước xác minh này.
- Bridge chỉ cho phép 5 endpoint đang dùng, đúng HTTPS origin, POST, không query/fragment/userinfo; kiểm tra lại origin và user ID trong JavaScript trước khi gửi. Chuyển về trang login hoặc đổi tài khoản làm phiên hết hiệu lực. Không tự gửi lại POST điểm danh khi mạng lỗi/timeout.
- HTTP 401 thật vẫn dùng `SessionRecovery`: hủy client/WebView cũ trước khi xóa cookie/storage, giới hạn phục hồi tự động, không bỏ xác thực. Lỗi mạng/5xx/sai phản hồi ở bước xác minh giữ màn đăng nhập và chờ người dùng bấm **Thử lại**. Tắt log sự kiện của plugin WebView cả ở debug để tránh lộ URL OAuth hoặc dữ liệu trả về qua JavaScript.

Vẫn dùng Microsoft SSO do portal cung cấp trong WebView. Chưa chuyển sang Custom Tabs/ASWebAuthenticationSession vì redirect hiện tại trả về website trường; cần callback và cơ chế cấp phiên portal được backend hỗ trợ trước khi chuyển sang tab ngoài.

Kiểm tra bổ sung:

```sh
flutter analyze --no-pub
flutter test --no-pub --timeout 45s
node --test tool/verify_portal_bridge.cjs
```

Kết quả bản mới: **85 test Flutter + 17 test JavaScript đạt**, `flutter analyze --no-pub` và `dart analyze` không có vấn đề (Flutter 3.47.7 / Dart 3.13.5, Node.js 22.23.2). `tool/verify_portal_bridge.cjs` chạy trực tiếp đoạn JavaScript trong `PortalWebClient` bằng XHR giả lập, không gọi mạng. Các test Flutter/JavaScript xác minh mã và luồng giả lập, **không chứng minh portal thực tế đã hết 401**. Chưa có tài khoản/thiết bị để kiểm tra Microsoft SSO, cookie native WebView, tải lịch/điểm hoặc build APK/IPA. Xem checklist trong `docs/AUTH_TESTING.md` trước khi phát hành.

HAR cục bộ có thể kiểm tra offline:

```sh
dart run tool/verify_har.dart
# Hoặc dart run tool/verify_har.dart /duong/dan/ban-ghi.har
```

Công cụ chỉ in số chương trình/học phần/học kỳ và kết quả kiểm tra, không gọi mạng hoặc xuất điểm/định danh. HAR được bỏ qua trong Git. Các fixture kiểm thử đều là dữ liệu giả lập.

## Hợp đồng xem điểm

Nguồn: `diemhoc.js` và request/response lưu trong HAR ngày 15/10/2026, kết hợp tài liệu `README_CMC_Checkin_ChiTiet_HAR.md`.

| Chức năng | Action dưới `/sinhvienapi/api/` | Bằng chứng |
|---|---|---|
| Chương trình học | `SV_ThongTin_MH/DSA4FSkuLyYVKC8CKTQuLyYVMygvKQkuIgPP` | Request + response HAR, JS |
| Bảng điểm | `SV_ThongTin_MH/CiQ1EDQgCS4iFSAxAiAPKSAv` | Request + response HAR, JS |
| Điểm thành phần theo mã tổng kết | `SV_ThongTin_MH/DSA4BRIFKCQsFSkgLykRKSAvFSkkLhUKCREP` | Mã JS trong HAR; chưa có request thực tế tới endpoint này trong capture |

Cả ba dùng POST form `A = AE(JSON, action suffix)`; giải mã `Data.B` bằng `AzzSystem` và kiểm tra `Success == true`. Bảng điểm dùng quyền menu điểm, ID người học từ session và ID chương trình do portal trả về. Điểm thành phần dùng `strDiem_NguoiHoc_TongKet_Id` để tách từng kết quả/lần thi.

Response bảng điểm có `rsDiemKetThucHocPhan`, `rsDiemTrungBinhChung` cùng các nhóm dữ liệu khác. Điều kiện chọn trung bình giữ theo JavaScript portal: `THUOCTINHLANTINH == 0`; toàn khóa có `DAOTAO_THOIGIANDAOTAO_ID == null`; học kỳ khớp năm/kỳ, `DOTHOC == null` và phạm vi `HOCKY`. Số `2.0` của học kỳ được chuẩn hóa thành `2`; điểm 0 được giữ nguyên, thiếu điểm hiển thị `—`. Schema không hợp lệ gây lỗi hiển thị, không biến thành bảng điểm rỗng.

Chi tiết kiến trúc lịch/điểm danh nằm trong `README_CMC_Checkin_ChiTiet_HAR.md`. Lộ trình nâng cấp tiếp theo nằm trong [docs/UPGRADES.md](docs/UPGRADES.md).
