# 色票預約所

Windows PowerShell 5.1 以上版本即可執行，不需安裝套件。

## 啟動

在此資料夾開啟 PowerShell，執行：

```powershell
.
\server.ps1
```

開啟 `http://localhost:8765`。第一次啟動時，管理密碼會顯示在 PowerShell 視窗中；前往 `http://localhost:8765/admin` 登入。預約資料會儲存在 `data/reservations.json`。

指定固定的管理密碼：

```powershell
$env:COLOR_CHART_ADMIN_PASSWORD = '請換成自己的密碼'
.\server.ps1
```

## 多人使用

所有訪客必須連到同一個已啟動的伺服器網址，預約才會共用。部署到可供訪客連線的 Windows 主機時，可設定 `COLOR_CHART_ADMIN_PASSWORD`，並以系統管理員身分為所需的網路網址設定 Windows HTTP URL reservation，再使用 `-ListenAddress 'http://+'` 監聽網路連線。請搭配 HTTPS 反向代理公開網站；不要將管理密碼或 `data/reservations.json` 公開。

後台提供預約資料檢視與 CSV 匯出。色票一經登記即不可再次預約；刪除資料檔中的該筆紀錄後，該色票才會重新開放。