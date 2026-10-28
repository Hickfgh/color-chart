# XAMPP 部署方式

這個版本保留現有 PowerShell 後端，XAMPP 的 Apache 只負責接收網域流量並轉送到 `server.ps1`。不要只把 `index.html` 放到 XAMPP 後就關閉 PowerShell，否則登入、預約和後台 API 會離線。

## 本機測試

1. 安裝並啟動 XAMPP 的 Apache。
2. 在專案資料夾啟動後端：

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
.\server.ps1
```

3. 先確認 `http://localhost:8765/` 可以開啟。
4. 在 XAMPP Apache 設定反向代理，再從網域開啟網站。

## Apache 設定

1. 開啟 `C:\xampp\apache\conf\httpd.conf`。
2. 確認以下三行沒有被 `#` 註解：

```apache
LoadModule proxy_module modules/mod_proxy.so
LoadModule proxy_http_module modules/mod_proxy_http.so
Include conf/extra/httpd-vhosts.conf
```

3. 將 `color-chart-vhost.conf` 的內容加到 `C:\xampp\apache\conf\extra\httpd-vhosts.conf`。
4. 把 `color.example.com` 換成你的實際網域。
5. 確認 DNS 的 A record 指向這台電腦的公開 IP。
6. 在 XAMPP Control Panel 重新啟動 Apache。

設定後，Apache 會把以下網址轉到 PowerShell 後端：

```text
https://你的網域/api/status
https://你的網域/account
https://你的網域/admin
```

## HTTPS 與安全性

正式公開時必須使用 HTTPS。可以用 Cloudflare Proxy、Let's Encrypt 或主機商的 SSL 憑證。不要直接把 Windows 的 `8765` port 公開到網際網路；只讓 Apache 對外提供 80/443，PowerShell 保持監聽 `localhost`。

若 XAMPP 和 PowerShell 不在同一台電腦，這個設定不能使用 `127.0.0.1`，必須把 ProxyPass 改成後端主機的內網 IP，並限制防火牆只允許 Apache 主機連線。

## 資料與密碼

預約、管理者帳號、員工帳號、客戶帳號和 Gmail 設定仍保存在專案的 `data` 資料夾。請備份這個資料夾，但不要讓 Apache 直接公開它。Gmail 應用程式密碼使用 Windows DPAPI 加密，因此 PowerShell 後端重啟時必須使用同一個 Windows 使用者。

## 常見問題

- 首頁顯示「離線」：確認 PowerShell 後端仍在執行，並從伺服器本機測試 `http://localhost:8765/api/status`。
- 網域 502/503：確認 Apache proxy modules 已啟用，且 PowerShell 正在監聽 8765。
- Gmail 驗證信失敗：先在管理後台按「儲存並寄送測試信」，再查看執行 `server.ps1` 的 PowerShell 視窗錯誤。