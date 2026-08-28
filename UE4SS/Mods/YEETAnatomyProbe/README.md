# YEETAnatomyProbe — M0 Expedition Anatomy Probe (v3)

最小、純觀測的 Palworld UE4SS Lua staging mod。預設停用；按 **F5** 才會 arm，再按一次會解除本次可解除 hook。本 M0 同一個短 session 會並行觀測 Actor construction、可解除的 BeginPlay 入口（若 runtime 可用）與 Destroyed；所有事件仍需通過精確名稱過濾。

> F5 與 `YEETRuntimeProbe` 共用按鍵，兩者不可同時啟用；一次只部署一個 probe。

## 安裝（人工操作，不會由本 staging 自動修改遊戲）

1. 先在 Palworld 的「選項 → Mod 管理」確認 **UE4SS Experimental (Palworld)** 已啟用；目前本機尚未部署它。
2. 將 `YEETAnatomyProbe` 資料夾複製到 `Palworld\Mods\NativeMods\UE4SS\Mods\YEETAnatomyProbe`。
3. 在 `Palworld\Mods\NativeMods\UE4SS\Mods\mods.txt` 加入 `YEETAnatomyProbe : 1`；或在同層 `mods.json` 加入等價 enabled 項目，格式依現有檔案為準。
4. 啟動遊戲後查看 UE4SS log：應有 `ready; press F5...`。按 F5 開始或停止本次 session。

本工作區沒有修改任何遊戲安裝、UE4SS 設定或 Workshop 檔案。

## M0 行為、範圍與限制

- 使用本機 Workshop 範例已看見的 `RegisterKeyBind`、`RegisterHook`、`UnregisterHook`；所有非必要 runtime API 都以 `pcall` 防護。
- F5 arm 時只註冊一次 `/Script/Engine.Actor` construction observer。它只讀 class/path，callback 在未武裝時回傳 `true` 自動解除；若在下一次 construction 前重新 arm，會沿用待釋放的 observer，不會重複註冊。
- BeginPlay 優先嘗試 generic `RegisterHook("/Script/Engine.Actor:BeginPlay", ...)`。若回傳數字 pre/post id，會納入 `UnregisterHook` 清單，F5 disarm 可解除；若路徑或 API 不可用，才以 `pcall` 嘗試 `RegisterBeginPlayPostHook` fallback。
- `RegisterBeginPlayPostHook` 沒有已證實的解除 API，因此 fallback 最多註冊一次，之後僅由 `state.armed` guard 控制；disarm 後 callback 仍存在但 inert，README 明示此殘留，且不會因重複 arm 再註冊。
- generic Actor observer 有 construction callback 成本，僅適合短時間手動武裝視窗：執行遠征實驗時才按 F5，完成後立刻再按 F5 disarm。
- 同時保留 `/Script/Engine.Actor:Destroyed` 作為事件驅動、可解除的消失事件；v3 僅記錄 class 或 path 命中 `ObjectPool`、`Expedition`、`CharacterTeamMission`、`BuildObject`、`Dispatch`、`MissionStation`、`ExpeditionStation`、`PalExpedition`，或較精確的 `BP_Pal_`、`PalCharacter`、`PalAI`、`PalActor`、`/Pal/Character/` 候選。刻意排除泛用 `Spawner`（第五輪已證明會被地圖串流噪音淹沒），也不匹配 `/Game/Pal/` namespace，避免把所有道具當成 Pal。
- 記錄最多 256 筆；同一非遠征 class 每個 session 最多保留 8 筆。到 cap 時 `armed` 會設為 false；下一個 Actor construction callback 以 `true` 自動解除 construction observer。可立刻按 F5 解除 Destroyed 與 generic BeginPlay hook；fallback 只會保持 inert。
- 每筆事件訊息含固定標記 `M0JSON:`，其後 payload 是 JSON object；UE4SS 與 MOD 自身仍可能在整行前方加入時間、等級或 `[YEETAnatomyProbe]` prefix。機器解析時應擷取 `M0JSON:` 之後的內容。
- JSON payload 欄位為 `session_id`、`sequence`、`utc`、`relative_ms`、`event_kind`、`class`、`path`、`function`、`transform`、`owner`、`instigator`、`confidence`。
- `transform`、`owner`、`instigator` 在此 M0 一律為 `null`：此 probe 沒有可靠、已驗證且不擴大觀測範圍的來源，絕不虛構。
- `relative_ms` 來自 Lua `os.clock()`；它是可得的 session 相對時間，不保證為 wall-clock elapsed time。`utc` 用 `os.date("!")`，若執行環境不支援則屬未驗證 runtime 風險。
- 事件詞 taxonomy 保留 `Spawn`、`Pool`、`Dispose`、`Destroy`、`MoveTo`、`Goal`、`BeginPlay`；未證實 Palworld 對應 UFunction path 前，不猜測其他 gameplay hook。

## 安全護欄

不寫任何 UObject、不呼叫 gameplay 函式、不 spawn/destroy、不改 transform、不使用 `ExecuteInGameThread`，也不做全域或每幀列舉。它僅讀取 hook context 的有效性、完整名稱與 class 名稱並寫入 UE4SS log。

## 人工測試（同一次短 session）

1. 進入可讓目標 actor 生成、BeginPlay 與消失的情境，確認初始只有 ready log，尚無 event log。
2. 按 F5，確認 `armed session=`；在短視窗內產生或銷毀名稱符合目標詞的 actor。
3. 確認 JSON 的 `event_kind` 可為 `Spawn`、`BeginPlay` 或 `Destroy`：前者對應 `NotifyOnNewObject:/Script/Engine.Actor`，BeginPlay 對應 `/Script/Engine.Actor:BeginPlay` 或 `RegisterBeginPlayPostHook`，Destroy 對應 `/Script/Engine.Actor:Destroyed`；沒有命中目標詞的 actor 不應輸出。
4. 遠征實驗完成立刻再按 F5，確認 hook unregister request 沒有 Lua error；generic BeginPlay 與 Destroyed 應停止，construction observer 會在下一次 construction 自動解除。若使用 fallback，應看見它 remains registered but inert 的 disarm 訊息。
5. 在 construction observer 自動解除前立即再按 F5，應沿用同一個 observer 開始新 session，不得出現重複 observer；BeginPlay fallback 也不得重複註冊。
6. 若 generic BeginPlay 與 fallback 都不可用，應有 optional/unavailable log，但 construction 或 Destroyed 任一可用仍可運作；若三者都不可用，probe 保持 disarmed，遊戲仍可正常啟動。

## 可重複靜態檢查

在 workspace 根目錄執行：

```powershell
pwsh -NoLogo -NoProfile -File .\UE4SS\Mods\YEETAnatomyProbe\scripts\smoke-static.ps1
```

此檢查是關鍵字／結構護欄，不是 Lua AST、UE4SS 載入或 Palworld runtime 驗證。
