# 色票預約所

Windows PowerShell 5.1 以上版本即可執行，不需安裝套件。

## 啟動

在此資料夾開啟 PowerShell，執行：

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
.\server.ps1
```

開啟 `http://localhost:8765`。第一次啟動時，管理密碼會顯示在 PowerShell 視窗中：複製該密碼，到 `http://localhost:8765/admin` 登入，再於頁面下方的「修改管理密碼」設定新密碼。新密碼至少 12 個字元，儲存後重啟伺服器仍會保留。預約資料儲存在 `data/reservations.json`，密碼雜湊儲存在 `data/admin-credentials.json`。

## 多人使用

所有訪客必須連到同一個已啟動的伺服器網址，預約才會共用。部署到可供訪客連線的 Windows 主機時，以系統管理員身分為所需的網路網址設定 Windows HTTP URL reservation，再使用 `-ListenAddress 'http://+'` 監聽網路連線。請搭配 HTTPS 反向代理公開網站；不要將 `data` 資料夾公開。

後台提供預約資料檢視與 CSV 匯出。色票一經登記即不可再次預約；刪除資料檔中的該筆紀錄後，該色票才會重新開放。