# YEET LogicMod 建築打包待辦

正式產品規格與 Workshop 邊界以 `../../Workshop/YEET/PACKAGE-CONTRACT.json` 為準：玩家訂閱的是一個獨立的 YEET MOD，進入遊戲後建造自己的 YEET 終端，面對終端按原生 F 開啟商隊面板。F8 只保留在開發除錯設定。建築事件接線以 `INTERACTION-CONTRACT.json` 為準：`UPalInteractiveObjectBoxComponent.OnInteractBegin` → `BP_YEETTerminal.YEET_RequestRouteMenu` → `terminal_interact`；玩家執行期不依賴自訂原生 C++ 類別。

Gemini 與本地研究共同採用 Hybrid 邊界：Blueprint/Pak 只承擔終端、碰撞、原生互動與 UMG 版面；UE4SS Lua 承擔路線狀態、設定與安全降級。Phase 1 的介面契約見 `ROUTE-UI-CONTRACT.json`。

`LogicModBuild` 已能以 UE 5.1 產生並烹飪 `ModActor` 與
`WBP_YEETRouteMenu`，輸出為 `dist/YEET.pak`。目前 pak 已包含自有商隊 UI，
但正式 `BP_YEETTerminal` 仍需取得 Pal 建築父類別後才能取代工作台原型。

目前另有一條較快的資料驗證路徑：`../../PalSchema/mods/YEETTerminal` 先把
`YEET_Terminal` 指向原版 WorkBench Blueprint。它只驗證新建築資料列能否被
PalSchema 載入與出現在建造選單；工作台外觀／行為是刻意的 placeholder，不能
視為正式 YEET 終端，也不會取代後續 `BP_YEETTerminal` 的 Blueprint/Pak。

PMK 階段需要：

1. 建立 `Mods/YEET` 資料夾與 `Actor` parent 的 `ModActor`。
2. 建立 `Buildings/BP_YEETTerminal`，先把既有小型儲物箱或告示牌 mesh 做成可替換 placeholder。
3. 將建築資料／配方接到建造選單，預設解鎖，配方採 `BUILD-CONTRACT.json`。
4. 建立 `PrimaryAssetLabel`，Chunk ID 使用非 0 且與其他 MOD 不衝突。
5. 打包後把同名 `YEET.pak` 放到 `Pal/Content/Paks/LogicMods/`；檢查 `ModActor` 路徑與檔名同名。

在完成以上步驟之前，不要把 `BUILD-CONTRACT.json` 當成遊戲內已可建造的證明。

## 三波驗收

1. **Phase 1 UI 雛形**：先以無音效 WBP 驗證開關、輸入焦點與路線狀態呼叫；不打包自訂 Wwise SoundBank。
2. **Phase 2 終端建造**：完成 `YEET_Terminal` 資料列、placeholder mesh、原生互動元件與 Host 建造驗收。
3. **Phase 3 持久化／多人**：再驗證終端唯一識別、Host authority、Dedicated Server 無 UI 降級與存讀。

任何 `DT_BuildObjectData` 欄位、互動事件名稱、終端 GUID 取得方式，都必須先完成 runtime 探索；契約中的 `EXPLORE-*` 項目不是已證實 API。

## 抵達時的基地激活（硬性需求）

商隊抵達目的地後，不能只記錄 `arrived` 或播放飛行動畫。正式行為必須在
Host／單人權威端解析目的地的 `UPalBaseCampModel`，走可證實的原生等價喚醒
流程，讓基地的 worker director／基地狀態恢復運作。禁止把玩家瞬移進基地、
偽造玩家進入事件，或直接改寫 `PlayerUIdsExistsInsideInServer` 當作捷徑。

目前 PMK headers 只證實 `UPalBaseCampManager::GetInRangedBaseCamp`、
`UPalBaseCampModel::IsAvailable` 與玩家專用 `UPalInsideBaseCampCheckComponent`
等觀測邊界，尚未證實可安全呼叫的 server activation API；因此
`arrival_activation` 維持未驗證狀態，直到 runtime 探索取得實際入口。

`BP_YEETTerminal.YEET_RequestRouteMenu` 是 Blueprint 互動橋：終端的 Pal 互動元件事件圖呼叫自有事件，再由 UE4SS 精確類別 Hook 開啟 WBP。舊的 `AYEETTerminal` 僅是廢棄研究 scaffold，不得成為 Workshop 執行期依賴，也不得把 Wwise 當成所有 Lua／LogicMod 工作的全域阻塞。
