# YEETRuntimeProbe

這是 development-only、一次性、Host 單機 staging probe；不屬於
`YEETCaravanCore` 正式 payload，也不應加入 Workshop 封裝。它只觀察玩家正常
操作，從 getter、hook argument 與 out-param 的形狀建立有上限的 JSONL log。

## 觀測範圍

- Feed Box：觀察 concrete-model/container 的讀取邊界；只有能辨識 `FeedBox`
  或 `FoodBox` class 的事件才入樣本，並記錄 class、公開 getter availability、
  container/base 相關回傳形狀與 Host authority。
- Pal assign/unassign：觀察 `RequestFixedAssign` 與 `RequestUnassign` 的玩家
  UI 呼叫前後；不替玩家呼叫、不改參數、不把 UI 路徑當成 reservation API。
- 基地進出：沿用 `OnEnterBaseCamp` 與 `OnExitBaseCamp` 的可解除 hook，保存
  getter snapshot 前後差異。

每筆輸出都是一行 `YEETRuntimeProbe ... JSONL {"schema":"yeet-runtime-probe/v1",...}`，
包含 `before`、`after`、`class`、`function_availability`、`authority`、
`out_param_shapes` 與 `argument_shapes`。整個 session 最多 24 筆、最長 30 秒；
達 cap、watchdog 到期、失去 Host authority 或 disarm 後會自動 unregister。
F5 只負責 arm 一次，載入時永遠 disarmed。F5 與 `YEETAnatomyProbe` 共用按鍵，兩者不可同時啟用；一次只部署一個 probe。

## 安全邊界

Probe 不主動送出物品交易、assign/unassign、reservation 或任何 reflected
mutation；不使用全域 UObject enumeration、每幀輪詢、ProcessEvent、傳送或
建立/摧毀 UObject。它不載入 `inventory_runtime.lua` 或
`pal_reservation_runtime.lua`，因此不會改變產品邏輯路徑。

## 一次性實機步驟

1. 備份單人存檔，使用可丟棄的單機世界；先完全關閉 Palworld。
2. 執行 repository 根目錄的 `tools\deploy-yeet-runtime-probe.ps1`。腳本會
   檢查遊戲程序已關閉、備份 `mods.txt`、只複製本 probe，並輸出可重算的
   payload SHA-256；它不會停用正式或既有 Mod。
3. 啟動 Palworld 進入單人 Host，確認 log 顯示 `ready ... disarmed`，按一次
   F5，確認 `armed one-shot host session=` 與操作提示。
4. 依提示只做一輪：面對並互動 Feed Box；用正常 UI assign 再 unassign 同一隻
   Pal；走進基地、停留數秒、再走出基地。不要傳送、不要重複按 F5、不要同時
   啟用其他探針。
5. 保存所有 `YEETRuntimeProbe` JSONL 行，確認 30 秒內出現
   `released=... remaining=0 reason=watchdog timeout`（若 cap 先到則是
   `event cap reached`），之後沒有新的 probe callback。
6. 若有 crash、Lua traceback、authority 不明或資料互相矛盾，立即關閉遊戲，
   執行同一部署腳本的 `-Restore` 還原 `mods.txt`，不要宣稱 runtime 證據成立。

## 靜態驗證與還原

在 repository 根目錄執行：

```powershell
pwsh -NoLogo -NoProfile -File .\UE4SS\Mods\YEETRuntimeProbe\Scripts\smoke-static.ps1
pwsh -NoLogo -NoProfile -File .\tools\deploy-yeet-runtime-probe.ps1 -WhatIf
```

`-Restore` 只在 Palworld 關閉時以最後一次 backup 還原原始 `mods.txt`；不會
碰正式 `YEETCaravanCore` 原始碼、`main.lua`、`domain.lua`、MissionCenter
或 package。
