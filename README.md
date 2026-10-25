# 色票預約所

Windows PowerShell 5.1 以上版本即可執行，不需安裝套件。

## 啟動

在此資料夾開啟 PowerShell，執行：

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
.\server.ps1
```

開啟 `http://localhost:8765/admin`，第一次使用時直接建立管理帳號和密碼。帳號只能註冊一次；新密碼至少 12 個字元。之後從同一頁登入，登入後可在頁面下方修改密碼。管理帳密以雜湊保存於 `data/admin-credentials.json`，預約資料保存於 `data/reservations.json`；重啟伺服器後兩者都會保留。

## Gmail 通知

登入後台，在「Gmail 預約通知」輸入寄件 Gmail、通知收件地址及 Google 應用程式密碼，勾選啟用後按「儲存並寄送測試信」。應用程式密碼需先開啟 Google 兩步驟驗證，再至 [Google 應用程式密碼](https://myaccount.google.com/apppasswords)建立；不可使用 Gmail 一般登入密碼。應用程式密碼以 Windows DPAPI 加密保存，伺服器必須以同一個 Windows 使用者執行。所有透過此網站預約 API 成功登記的色票都會寄通知；若寄信失敗，預約仍會保存。

## 多人使用

所有訪客必須連到同一個已啟動的伺服器網址，預約才會共用。部署到可供訪客連線的 Windows 主機時，以系統管理員身分為所需的網路網址設定 Windows HTTP URL reservation，再使用 `-ListenAddress 'http://+'` 監聽網路連線。請搭配 HTTPS 反向代理公開網站；不要將 `data` 資料夾公開。

後台提供預約資料檢視與 CSV 匯出。色票一經登記即不可再次預約；刪除資料檔中的該筆紀錄後，該色票才會重新開放。