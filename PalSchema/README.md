# YEET PalSchema 原型

這個資料夾是可提交的 PalSchema source，不是已部署的遊戲檔案。

`mods/YEETTerminal/buildings/yeet_terminal.jsonc` 先把新資料列指向原版
`BP_BuildObject_WorkBench`，目的只有驗證「新建築資料列 → 建造選單 → 存檔」
這條最短路徑。它會暫時顯示工作台外觀與原生工作台行為，不能冒充正式的
YEET 終端，也不會自動開啟路線 UI。

正式版的切換順序：

1. 在 UE 5.1 PMK 建立 `BP_YEETTerminal`，加入原生建築碰撞與互動元件。
2. 將 `BlueprintClassSoft` 改成 `/Game/Mods/YEET/Buildings/BP_YEETTerminal...`。
3. 把 Blueprint、UMG 與 `ModActor` cook 成同名 `YEET.pak`，再做遊戲內建造與 F 鍵互動驗收。

依賴：PalSchema 與 Palworld 專用 UE4SS。未安裝 PalSchema 前，這裡的 JSONC
只作為 source；不會被遊戲讀取。
