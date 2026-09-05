# 員工預休月曆

適合小團隊使用的繁體中文預休登記站台。

## 功能

- 月曆只顯示所有員工的姓名與預休日期
- 員工登入一次後，系統自動帶出姓名到月曆
- 在月曆選擇 1～7 天後直接點日期，立即新增並存檔
- 再點一次自己的預休日期，即可立即取消
- 每月 1～15 日可修改所有未來月份；16 日起全部鎖定，次月 1 日重開
- 管理頁可新增員工、登入帳密及指定顏色
- 員工密碼與管理密碼只保存雜湊值
- 手機與電腦皆可使用

## GitHub Pages 設定

1. 將整個資料夾上傳到 GitHub repository。
2. 保留 `config.js`，不要把它刪除；裡面只有可公開的 Supabase Publishable Key。
3. 在 repository 的 **Settings → Pages**，選擇 **Deploy from a branch**。
4. Branch 選 `main`，資料夾選 `/ (root)`，按下 Save。

## 第一次使用

1. 開啟網站的「員工管理」。
2. 使用交付時提供的初始管理密碼。
3. 依序新增員工，為每人設定姓名、登入帳號、初始密碼及顏色。
4. 建議立刻到「更改管理密碼」換成只有主管知道的新密碼。

登入帳號不會顯示在公開月曆。請為每位員工設定不同且不容易猜到的密碼，也不要把帳密放在 GitHub。

> Supabase Publishable Key 可以放在前端；資料權限由資料庫函式、RLS 與最小授權控制。不可把 Secret Key 或 service_role key 放進 GitHub。

## 資料庫

資料庫結構位於 `supabase/schema.sql`。底層資料表位在未公開的 `private` schema，瀏覽器只能執行指定函式。

目前 `config.js` 已連接本系統專用的 Supabase 專案。Publishable Key 本來就會隨公開網頁下載；真正的寫入權限由資料庫端驗證，而不是把 Secret Key 放在網頁中。
