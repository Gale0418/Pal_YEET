# YEET Caravan Core

這是我們自己寫的 UE4SS Lua 核心（0.5.0-alpha），不是把別人的遠征 MOD 當成成品。

目前已經具備：

- 路線狀態機：scheduled → traveling → arrival_pending_activation → arrived，可循環往返。
- 低頻 `LoopAsync` 倒數，不使用每幀輪詢。
- 路線安全限制（預設最多 32 條、可設定上限 128、ETA 1～86400 秒、欄位長度限制）。
- `YEETCaravanCore.routes.json` 儲存（遊戲不支援檔案寫入時自動退回記憶體狀態）。
- 玩家準星射線觀測（development_mode 的 F12），只讀取面前物件 class/full name。
- 自有 cooked UMG 商隊面板：development_mode 的 F8 開啟／關閉，Esc 關閉；資產找不到時 fail closed。
- 終端互動橋接候選：`BP_YEETTerminal_C:YEET_RequestRouteMenu` 僅接受完整類別名完全相等的物件；核心啟動只做唯讀能力 probe，不猜 UE4SS callback signature。
- 開發按鍵（僅 `development_mode=true`）：F9 狀態、F10 設定／觀測診斷、F11 simulation route、F12 focus inspect。
- `Scripts/config.lua` 啟動時讀取本地設定（啟用、tick 間隔、路線上限、模擬 ETA、觀測距離、抵達激活門檻）；缺檔或值越界會回退安全預設值。

抵達 ETA 到期後，路線會停在 `arrival_pending_activation`；只有 Host／單人權威端
的基地激活橋呼叫 `YEET.CaravanCore.ConfirmArrivalActivation(routeId, baseCampId)`
才會進入 `arrived`。這避免把動畫或本地旗標冒充成基地已喚醒。

這一版已打包自有 `ModActor` 與 `WBP_YEETRouteMenu`，仍不會自動改物品欄或搬動 Pal。

`inventory_adapter.lua` 是唯一的原生物品搬運邊界，`inventory_runtime.lua` 則是
唯一接觸 Palworld UObject 的 runtime bridge。核心啟動時建立的 runtime 沒有有效
container，因此預設 `ready=false`（fail-closed）。外部 game-thread staging hook
必須明確呼叫下列只讀整合 API：

- `YEET.CaravanCore.InjectInventoryRuntime(runtime)`：注入 bridge；不會 probe 或搬運。
- `YEET.CaravanCore.RegisterContainer(reference)`／`CaptureActor(reference)`：註冊目前
  有效的 container／actor，拒絕 GUID 猜測與全域掃描。
- `YEET.CaravanCore.ProbeInventoryRuntime()`：逐項驗證 discovery、snapshot、authority、
  native exact-slot move 與 out-param 形式；probe 不會呼叫 `request_move`。
- `YEET.CaravanCore.GetInventoryRuntimeStatus()`：每次即時讀取 adapter 狀態，不使用
  靜態 `InventoryAdapterReady` 快照。

只有完整 probe 後，上層明確呼叫 `SubmitInventoryMove` 才可能送出搬運；未通過 probe
時不會寫入 `ItemSlotArray`／`StackCount`，也不會呼叫原生搬運。`SimulationOnly` 在
inventory、Pal reservation、arrival activation 三橋未全 ready 時維持 `true`。

`pal_reservation_runtime.lua` 現在已由 core 載入，但預設沒有任何 UObject callback，
因此仍是 fail-closed。Host／外部 game-thread bridge 必須明確呼叫下列 API；載入、注入、
註冊與 probe 都不會自動改遊戲狀態：

- `YEET.CaravanCore.InjectPalReservationRuntime(runtime)`：注入 callback bridge，清除舊的
  readiness 與 GUID 註冊，不會自動 probe。
- `YEET.CaravanCore.RegisterPal({ pal_guid = "..." })`：只解析指定 GUID 的 live Pal，拒絕
  GUID 猜測、全域掃描與未驗證物件。
- `YEET.CaravanCore.ProbePalReservationRuntime()`：執行完整 capability／Host authority
  probe；未通過前 `ReservePal`／`ReleasePal` 一律拒絕。
- `YEET.CaravanCore.ReservePal`、`ReleasePal`、`ReconcilePalReservations`：只有 caller
  明確呼叫時才進入 runtime；native reserve/release callback 是唯一允許的原生 mutation
  邊界，而 reconcile 永遠只清理本地 ledger。
- `YEET.CaravanCore.PalReservationStatus()`：每次即時查詢 runtime status，不提供靜態 ready
  快照；短名 `Inject`／`Probe`／`Reserve`／`Release`／`Reconcile`／`Status` 亦可供 bridge 使用。

即使外部 runtime 回報完整 probe，產品公開的 `SimulationOnly` 仍固定為 `true`；必須等
inventory、Pal reservation、arrival activation 三橋都完成實機驗證後，才由後續受審核變更解除。

舊版 `SetInventoryAdapterRuntime`、`ProbeInventoryAdapter`、
`GetInventoryAdapterStatus` 仍保留相容別名；提交資料只能是已驗證的純 Lua
exact-slot 描述。F8-F12 全部只在 `development_mode=true` 時註冊；正式產品不提供
 這些診斷／測試熱鍵，development mode 的 F10 才可執行明確只讀 inventory probe。
正式 `BP_YEETTerminal` 尚未取代 PalSchema 的工作台原型；只有取得 Pal 建築父類別並完成互動驗證後才會切換。

`terminal_interaction_bridge.lua` 是原生 F 互動的 fail-closed 邊界。由 Host／staging
bridge 明確注入 `class_path`、`function_path`、事件 context 的
`resolve_terminal`、可解除的 `register_hook`／`unregister_hook`，並以
`signature_verified=true` 表示已完成同版本唯讀探針後，才可
呼叫 `InstallTerminalInteractionHook`。核心公開 `ProbeTerminalInteractionBridge` 與
`TerminalInteractionBridgeStatus`；probe 不註冊 hook、不呼叫 `ProcessEvent`、不載入
遠征 WBP，也不會改變 `SimulationOnly=true`。未注入或未驗證時，安裝一律拒絕。

`config.lua` 是目前不依賴第三方 UI 的設定垂直切片；之後若安裝相容的 Mod Options 框架，會把同一組欄位映射到遊戲選單，核心仍保留這份本地回退設定。

啟動遊戲後可用 `tools/verify-yeet-runtime.ps1` 檢查最新 `0.5.0-alpha` ready marker 與 Lua 錯誤；它不會觸碰遊戲狀態。
