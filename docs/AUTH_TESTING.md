# Kiểm tra phiên portal trên thiết bị

## Phạm vi bản sửa

App giữ WebView Microsoft/portal sống và gửi API trong chính WebView đó. Không có callback OAuth native mới, không sửa backend trường, không bảo đảm mọi HTTP 401 biến mất: tài khoản bị khóa, quyền bị thu hồi hoặc phiên thực sự hết hạn vẫn phải được portal từ chối.

Kiểm thử offline dùng fixture/fake, không đăng nhập tài khoản thật và không gửi điểm danh thật. Checkout chưa có đầy đủ project Android/iOS; cần project nền tảng/signing hợp lệ trước khi chạy checklist dưới đây.

## Kiểm tra offline

```sh
flutter analyze --no-pub
flutter test --no-pub --timeout 45s
node --test tool/verify_portal_bridge.cjs
```

- Flutter: bridge/allowlist, mã hóa form, lịch/điểm/điểm danh dùng cùng client, không xuất cookie, xác minh trước khi lưu session, giữ WebView sau đăng nhập, hết phiên và lỗi mạng/sai schema.
- Node.js >= 18: thực thi chính JavaScript nằm trong `PortalWebClient` với XHR giả lập; kiểm tra token portal hiện tại, cookie do trình duyệt quản lý, origin/account, login redirect, timeout và không retry POST.

## Checklist thiết bị thật

Thực hiện trên Android và iOS bằng tài khoản được chủ tài khoản cho phép. Không gửi mật khẩu, mã MFA, token, cookie hoặc HAR chưa che dữ liệu vào issue/PR.

1. **Đăng nhập mới**
   - Đăng xuất trong app để xóa phiên cũ; mở lại màn login.
   - Đăng nhập Microsoft qua nút do website trường cung cấp, hoàn thành MFA nếu có.
   - Sau khi quay về portal, app hiện “Đang xác minh phiên và tải lịch học…”.
   - Chỉ mở lịch khi API tuần được chấp nhận; tuần không có lớp được phép hiển thị rỗng.
   - Xác nhận lịch thuộc đúng tài khoản, so với portal trong cùng khoảng ngày.
2. **Giữ phiên và dữ liệu**
   - Chuyển tuần, kéo làm mới, mở tab Kết quả, chọn chương trình và xem điểm thành phần.
   - Đưa app xuống nền rồi mở lại; tắt/mở app khi cookie còn hạn.
   - Lịch/điểm vẫn tải; không nhấp nháy qua màn lịch rồi quay về login vì JWT native cũ.
   - Cấu hình app/text scale không làm WebView đăng nhập lại.
3. **Mạng lỗi**
   - Ngắt mạng sau khi đăng nhập; làm mới không xóa dữ liệu đã tải chỉ vì lỗi mạng.
   - Ngắt mạng khi app đang xác minh login; không lưu phiên mới/mở lịch thành công giả. Khôi phục mạng rồi bấm “Thử lại”.
4. **Hết phiên và đổi tài khoản**
   - Dùng phiên được kiểm soát đã hết hạn hoặc thu hồi qua công cụ chính thức của trường; không sửa token để giả mạo phiên.
   - HTTP 401 hoặc chuyển về login phải xóa session/widget/cookie/storage rồi mở login mới.
   - Token cũ bị từ chối không được gọi API lặp; hai phiên liên tiếp bị 401 phải dừng và hiện “Đăng nhập lại”.
   - Đăng xuất tài khoản A, đăng nhập B; không được hiện lịch/điểm cũ của A. Bridge phải từ chối request nếu `edu.system.userId` đổi khỏi phiên app.
5. **Điểm danh (chỉ trong buổi học hợp lệ)**
   - Chỉ thử khi được phép, có lớp đang học và có từ khóa do giảng viên cung cấp.
   - Gửi một lần; không tự gửi lại sau timeout/401. Nếu kết quả chưa rõ, kiểm tra trạng thái trên portal trước khi bấm gửi lại.
   - Không dùng kiểm thử tự động để tạo bản ghi điểm danh thật.

## Thông tin báo lỗi an toàn

Ghi OS/phiên bản app, bước tái hiện, lịch có tải được trên website trường hay không, nhóm endpoint và HTTP status. Dòng `[auth] http_401` của luồng mới phải có `transport=webview`; `browser_managed` nghĩa là app không xuất cookie/header ra để kiểm tra, không khẳng định chúng có mặt.

Không đính kèm response body chứa điểm/lịch cá nhân, token/tokenTail, cookie, user ID, IP, URL OAuth đầy đủ hoặc console log của portal. Nếu cần network trace, chỉ thu trong môi trường được phép, che dữ liệu trước khi chia sẻ và tránh commit HAR.

## Khi vẫn còn 401

Nếu cả WebView bridge và website trường cùng bị từ chối, cần trường kiểm tra phiên/quyền. Nếu website tải được nhưng bridge vẫn lỗi, cần so sánh request trong **cùng phiên được phép**: endpoint, form, menu ID và cách `edu.system.makeRequest` hiện tại đặt header. Không thử token Microsoft làm token portal, không bỏ Bearer để dò đường vượt xác thực, không sửa app báo thành công khi API từ chối.

Đăng nhập qua tab hệ thống cần Microsoft Entra redirect URI và cơ chế backend đổi kết quả OAuth thành phiên portal/callback về app. Chỉ mở URL ngoài không chuyển được cookie HttpOnly hoặc phiên trình duyệt vào app.
