# YEETArrivalActivationProbe

這是 development-only、一次性、唯讀的基地抵達等價流程探針。它不屬於 YEET 產品 payload，也不應加入正式 `mods.txt`／Workshop 封裝。

## 目前找到的候選邊界

本機 `PalworldModdingKit` header 明確存在：

- `UPalBaseCampManager::GetInRangedBaseCamp`、`TryGetModel`、`GetBaseCampIds`：可查詢基地模型，但本身不是喚醒操作。
- `UPalBaseCampModel::IsAvailable`、`GetState`、`GetWorkCollection`、`GetRange`、`GetId`、`GetGroupIdBelongTo`：可作為前後快照的唯讀狀態。
- `UPalInsideBaseCampCheckComponent::OnEnterBaseCampDelegate`／`OnLeaveBaseCampDelegate` 與 `IsInsideBaseCamp`：證明玩家側有基地範圍語意，但未證明可把非玩家事件送進去。
- `UPalBuilderComponent::OnEnterBaseCamp(UPalBaseCampModel*)`／`OnExitBaseCamp(UPalBaseCampModel*)`：本探針唯一掛載的候選函式。
- `APalPlayerCharacter::OnEnterBaseCamp_StartBaseCampCombat`：名稱指向玩家進入後的戰鬥副作用，不能當作一般基地工作喚醒入口。
- `UPalBaseCampWorkerDirector::OnUpdateOwnerBaseCampStatus_ServerInternal`：伺服器側狀態通知候選，但未證實其觸發條件或能否安全由外部呼叫。

本地 header／source、既有六輪 Anatomy probe 結果與目前 UE4SS log 都沒有證實任何可直接呼叫的基地喚醒函式。探針刻意不包含未驗證的 tick／玩家進入替身 API，也不修改玩家清單、位置、基地模型或工作模組。

開源 prior art `Sarfflow/palworld-integrated-storage` 使用 `/Script/Pal.PalBuilderComponent:OnEnterBaseCamp` 與 `OnExitBaseCamp`，採事件驅動、不在每幀路徑做全域列舉；這只證明 hook 邊界在某版本／某 C++ runtime 可用，不等於本機 Palworld 版本已驗證，也不等於已找到 Host server wake bridge。

## 安全與生命週期

- 預設 disarmed；只有按 F5 才嘗試 arm，而且一次遊戲程序只接受一個 session。
- arm 前必須同時看到 `AuthorityGameMode`、local `PlayerController` 與 `PlayerController:HasAuthority()==true`；否則 fail-closed。
- 僅註冊 `OnEnterBaseCamp` 與 `OnExitBaseCamp` 的可解除 hook；pre/post 都只讀取 `UPalBaseCampModel` getter。
- 每次 session 最多 12 筆 `ARRIVALPROBE:` JSON；30 秒 watchdog 到期或 cap 到達後自動 unregister。
- 不使用每幀 tick、`FindAllOf`、`ProcessEvent`、建構／摧毀 UObject、傳送、改 transform、修改玩家／基地狀態或改 tick policy。
- `base_before`／`base_after` 只代表事件前後可讀快照；即使看到 state／availability 改變，也不能直接宣稱「基地已喚醒」，必須與工作進度、工作 tick／停止行為及離開後回復做關聯。

## 最小實機採樣步驟

1. 備份單人存檔；關閉 Palworld。將本資料夾手動複製到 `Palworld\Mods\NativeMods\UE4SS\Mods\YEETArrivalActivationProbe`，暫時在 `mods.txt` 加入 `YEETArrivalActivationProbe : 1`。
2. 啟動遊戲進入單人世界；確認 log 只有 `ready; development-only, disarmed`，沒有 hook 或狀態寫入。
3. 先在基地外按一次 F5，預期 `fail-closed`（沒有 Host authority 的場景不可採樣）。重新啟動後在單人 Host 再按一次 F5，預期 `armed one-shot host session=`。
4. 只做一次「玩家走進基地 → 等待 5 秒 → 玩家走出基地」，不要開 UI、不要傳送、不要同時啟用其他探針。保存兩類 `ARRIVALPROBE:` 記錄及其順序。
5. 確認 30 秒內看到 `released=2 remaining=0`，離開後不再有 probe callback／timer 記錄；若遊戲有任何 native crash、Lua traceback 或 authority 不明，立即停用探針，不進行下一輪。
6. 只有在上述 baseline 成功後，才規劃第二輪「商隊視覺抵達但不注入玩家事件」的觀察對照。探針本身沒有商隊注入入口，不能用它偽造抵達。

## 解析結果

每筆 log 的 `ARRIVALPROBE:` 後方是 JSON，包含 `session_id`、`sequence`、`kind`、`hook`、`authority`、builder class/path，以及基地的 `id`、`name`、`state`、`available`、`range`、`group_id`、`work_collection` 前後快照。getter 失敗會輸出 `null`，不猜值。

實機成功條件不是「hook 有命中」，而是能在 Host 上重複觀察：同一目的基地的 enter 後工作恢復、exit 後不永久保持額外 tick，且沒有玩家偽造或非冪等副作用。達成前，`ArrivalActivationAdapterReady` 必須維持 false。
