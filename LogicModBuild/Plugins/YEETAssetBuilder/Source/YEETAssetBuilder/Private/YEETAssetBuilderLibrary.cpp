#include "YEETAssetBuilderLibrary.h"

#include "Blueprint/UserWidget.h"
#include "Blueprint/WidgetTree.h"
#include "Components/Border.h"
#include "Components/Button.h"
#include "Components/CanvasPanel.h"
#include "Components/CanvasPanelSlot.h"
#include "Components/ComboBoxString.h"
#include "Components/CheckBox.h"
#include "Components/EditableTextBox.h"
#include "Components/HorizontalBox.h"
#include "Components/HorizontalBoxSlot.h"
#include "Components/ProgressBar.h"
#include "Components/ScrollBox.h"
#include "Components/SizeBox.h"
#include "Components/TextBlock.h"
#include "Components/VerticalBox.h"
#include "Components/VerticalBoxSlot.h"
#include "Engine/Blueprint.h"
#include "Engine/World.h"
#include "Kismet2/KismetEditorUtilities.h"
#include "UObject/Package.h"
#include "WidgetBlueprint.h"
#include "Blueprint/WidgetBlueprintGeneratedClass.h"

namespace
{
    constexpr const TCHAR* TerminalBlueprintAssetPath = TEXT("/Game/Mods/YEET/Buildings/BP_YEETTerminal.BP_YEETTerminal");

    const FLinearColor TextPrimary(0.90f, 0.95f, 1.00f, 1.00f);
    const FLinearColor TextMuted(0.55f, 0.66f, 0.72f, 1.00f);
    const FLinearColor Accent(0.25f, 0.75f, 0.95f, 1.00f);

    UTextBlock* MakeText(UWidgetTree* Tree, const TCHAR* Name, const TCHAR* Value, int32 Size = 18, FLinearColor Color = TextPrimary)
    {
        UTextBlock* Text = Tree->ConstructWidget<UTextBlock>(UTextBlock::StaticClass(), FName(Name));
        Text->SetText(FText::FromString(Value));
        Text->SetColorAndOpacity(FSlateColor(Color));
        FSlateFontInfo Font = Text->GetFont();
        Font.Size = Size;
        Text->SetFont(Font);
        return Text;
    }

    void AddVertical(UVerticalBox* Parent, UWidget* Child, const FMargin& Padding = FMargin(0.0f, 4.0f), float Fill = 0.0f)
    {
        UVerticalBoxSlot* Slot = Parent->AddChildToVerticalBox(Child);
        Slot->SetPadding(Padding);
        Slot->SetHorizontalAlignment(HAlign_Fill);
        if (Fill > 0.0f)
        {
            Slot->SetSize(FSlateChildSize(ESlateSizeRule::Fill));
        }
    }

    UBorder* MakePanel(UWidgetTree* Tree, const TCHAR* Name, const FLinearColor& Color, const FMargin& Padding)
    {
        UBorder* Panel = Tree->ConstructWidget<UBorder>(UBorder::StaticClass(), FName(Name));
        Panel->SetBrushColor(Color);
        Panel->SetPadding(Padding);
        return Panel;
    }

    UButton* MakeButton(UWidgetTree* Tree, const TCHAR* Name, const TCHAR* Label)
    {
        UButton* Button = Tree->ConstructWidget<UButton>(UButton::StaticClass(), FName(Name));
        Button->AddChild(MakeText(Tree, *FString::Printf(TEXT("Text_%s"), Name), Label, 18));
        return Button;
    }

    UWidgetBlueprint* LoadOrCreateWidgetBlueprint()
    {
        const FString PackageName(TEXT("/Game/Mods/YEET/UI/WBP_YEETRouteMenu"));
        UPackage* Package = LoadPackage(nullptr, *PackageName, LOAD_None);
        if (!Package)
        {
            Package = CreatePackage(*PackageName);
        }
        if (UWidgetBlueprint* Existing = FindObject<UWidgetBlueprint>(Package, TEXT("WBP_YEETRouteMenu")))
        {
            return Existing;
        }

        return Cast<UWidgetBlueprint>(FKismetEditorUtilities::CreateBlueprint(
            UUserWidget::StaticClass(),
            Package,
            FName(TEXT("WBP_YEETRouteMenu")),
            BPTYPE_Normal,
            UWidgetBlueprint::StaticClass(),
            UWidgetBlueprintGeneratedClass::StaticClass(),
            FName(TEXT("YEETAssetBuilder"))));
    }

    bool VerifyTerminalBlueprint()
    {
        UBlueprint* TerminalBlueprint = LoadObject<UBlueprint>(nullptr, TerminalBlueprintAssetPath);
        if (!TerminalBlueprint)
        {
            UE_LOG(LogTemp, Error, TEXT("YEETBUILD: blocked status=terminal_blueprint_missing asset=%s"), TerminalBlueprintAssetPath);
            return false;
        }
        if (!TerminalBlueprint->GeneratedClass
            || !TerminalBlueprint->GeneratedClass->IsChildOf(AActor::StaticClass()))
        {
            UE_LOG(LogTemp, Error, TEXT("YEETBUILD: blocked status=terminal_blueprint_uncompiled_or_invalid asset=%s"), TerminalBlueprintAssetPath);
            return false;
        }

        UE_LOG(LogTemp, Display, TEXT("YEETBUILD: terminal blueprint verified asset=%s"), TerminalBlueprintAssetPath);
        return true;
    }

    bool BuildRouteWidget()
    {
        UWidgetBlueprint* WidgetBP = LoadOrCreateWidgetBlueprint();
        if (!WidgetBP || !WidgetBP->WidgetTree)
        {
            UE_LOG(LogTemp, Error, TEXT("YEETBUILD: Widget blueprint creation failed"));
            return false;
        }

        // Operate layout: route navigation, editable cargo rules, and live operations are kept distinct.
        const FLinearColor Background(0.063f, 0.094f, 0.126f, 1.0f);
        const FLinearColor Surface(0.094f, 0.149f, 0.188f, 1.0f);
        const FLinearColor SurfaceRaised(0.129f, 0.200f, 0.239f, 1.0f);
        const FLinearColor TextSecondary(0.72f, 0.81f, 0.84f, 1.0f);
        const FLinearColor Amber(0.95f, 0.68f, 0.28f, 1.0f);

        UWidgetTree* Tree = WidgetBP->WidgetTree;
        UCanvasPanel* Root = Tree->ConstructWidget<UCanvasPanel>(UCanvasPanel::StaticClass(), TEXT("RootOverlay"));
        Tree->RootWidget = Root;

        UBorder* Dimmer = MakePanel(Tree, TEXT("Dimmer"), FLinearColor(0.01f, 0.02f, 0.03f, 0.82f), FMargin(0.0f));
        UCanvasPanelSlot* DimmerSlot = Root->AddChildToCanvas(Dimmer);
        DimmerSlot->SetAnchors(FAnchors(0.0f, 0.0f, 1.0f, 1.0f));
        DimmerSlot->SetOffsets(FMargin(0.0f));

        UBorder* Frame = MakePanel(Tree, TEXT("MainFrame"), Background, FMargin(24.0f));
        UCanvasPanelSlot* FrameSlot = Root->AddChildToCanvas(Frame);
        FrameSlot->SetAnchors(FAnchors(0.5f, 0.5f));
        FrameSlot->SetAlignment(FVector2D(0.5f, 0.5f));
        FrameSlot->SetSize(FVector2D(1240.0f, 760.0f));

        UVerticalBox* Main = Tree->ConstructWidget<UVerticalBox>(UVerticalBox::StaticClass(), TEXT("VB_MainLayout"));
        Frame->AddChild(Main);

        UHorizontalBox* Header = Tree->ConstructWidget<UHorizontalBox>(UHorizontalBox::StaticClass(), TEXT("Header"));
        UTextBlock* Title = MakeText(Tree, TEXT("Text_Title"), TEXT("YEET 航空物流控制台"), 30, TextPrimary);
        UHorizontalBoxSlot* TitleSlot = Header->AddChildToHorizontalBox(Title);
        TitleSlot->SetSize(FSlateChildSize(ESlateSizeRule::Fill));
        TitleSlot->SetVerticalAlignment(VAlign_Center);
        UTextBlock* Network = MakeText(Tree, TEXT("NetworkSummary"), TEXT("2 基地 · 3 航線 · 5 商隊運行中"), 16, TextSecondary);
        UHorizontalBoxSlot* NetworkSlot = Header->AddChildToHorizontalBox(Network);
        NetworkSlot->SetVerticalAlignment(VAlign_Center);
        NetworkSlot->SetPadding(FMargin(0.0f, 0.0f, 24.0f, 0.0f));
        UButton* Close = MakeButton(Tree, TEXT("Btn_Close"), TEXT("關閉 ×"));
        UHorizontalBoxSlot* CloseSlot = Header->AddChildToHorizontalBox(Close);
        CloseSlot->SetPadding(FMargin(12.0f, 0.0f));
        AddVertical(Main, Header, FMargin(0.0f, 0.0f, 0.0f, 12.0f));

        UHorizontalBox* Body = Tree->ConstructWidget<UHorizontalBox>(UHorizontalBox::StaticClass(), TEXT("Body"));
        UVerticalBoxSlot* BodySlot = Main->AddChildToVerticalBox(Body);
        BodySlot->SetSize(FSlateChildSize(ESlateSizeRule::Fill));
        BodySlot->SetPadding(FMargin(0.0f, 0.0f, 0.0f, 12.0f));

        // RouteRail: stable navigation and the empty-state recovery path.
        UBorder* RouteRail = MakePanel(Tree, TEXT("RouteRail"), Surface, FMargin(16.0f));
        USizeBox* RouteRailSize = Tree->ConstructWidget<USizeBox>(USizeBox::StaticClass(), TEXT("RouteRailSize"));
        RouteRailSize->SetWidthOverride(280.0f);
        RouteRailSize->AddChild(RouteRail);
        UHorizontalBoxSlot* RailSlot = Body->AddChildToHorizontalBox(RouteRailSize);
        RailSlot->SetPadding(FMargin(0.0f, 0.0f, 12.0f, 0.0f));
        UVerticalBox* RailContent = Tree->ConstructWidget<UVerticalBox>(UVerticalBox::StaticClass(), TEXT("VB_RouteRail"));
        RouteRail->AddChild(RailContent);
        AddVertical(RailContent, MakeText(Tree, TEXT("Text_RouteRailTitle"), TEXT("航線導覽"), 20, TextPrimary), FMargin(0.0f, 0.0f, 0.0f, 12.0f));
        AddVertical(RailContent, MakeButton(Tree, TEXT("Btn_NewRoute"), TEXT("建立航線 +")), FMargin(0.0f, 0.0f, 0.0f, 12.0f));
        UEditableTextBox* Search = Tree->ConstructWidget<UEditableTextBox>(UEditableTextBox::StaticClass(), TEXT("Search_Routes"));
        Search->SetHintText(FText::FromString(TEXT("搜尋航線")));
        AddVertical(RailContent, Search, FMargin(0.0f, 0.0f, 0.0f, 12.0f));
        UScrollBox* RouteList = Tree->ConstructWidget<UScrollBox>(UScrollBox::StaticClass(), TEXT("List_Routes"));
        RouteList->AddChild(MakeText(Tree, TEXT("Text_EmptyRoutes"), TEXT("尚未建立航線。先在兩座基地各建造一座 YEET 終端。"), 15, TextSecondary));
        AddVertical(RailContent, RouteList, FMargin(0.0f), 1.0f);

        // RouteWorkspace: the only region that edits a route or its demand rules.
        UBorder* RouteWorkspace = MakePanel(Tree, TEXT("RouteWorkspace"), Surface, FMargin(20.0f));
        UHorizontalBoxSlot* WorkspaceSlot = Body->AddChildToHorizontalBox(RouteWorkspace);
        WorkspaceSlot->SetSize(FSlateChildSize(ESlateSizeRule::Fill));
        WorkspaceSlot->SetPadding(FMargin(0.0f, 0.0f, 12.0f, 0.0f));
        UVerticalBox* Workspace = Tree->ConstructWidget<UVerticalBox>(UVerticalBox::StaticClass(), TEXT("VB_RouteWorkspace"));
        RouteWorkspace->AddChild(Workspace);

        UHorizontalBox* RouteHeader = Tree->ConstructWidget<UHorizontalBox>(UHorizontalBox::StaticClass(), TEXT("RouteHeader"));
        UTextBlock* RouteName = MakeText(Tree, TEXT("Text_RouteEndpoints"), TEXT("BaseCamp_Alpha  ⇄  BaseCamp_Beta"), 22, TextPrimary);
        UHorizontalBoxSlot* RouteNameSlot = RouteHeader->AddChildToHorizontalBox(RouteName);
        RouteNameSlot->SetSize(FSlateChildSize(ESlateSizeRule::Fill));
        UCheckBox* Enabled = Tree->ConstructWidget<UCheckBox>(UCheckBox::StaticClass(), TEXT("Toggle_RouteEnabled"));
        Enabled->SetIsChecked(true);
        Enabled->AddChild(MakeText(Tree, TEXT("Text_RouteEnabled"), TEXT("已啟用"), 15, Accent));
        RouteHeader->AddChildToHorizontalBox(Enabled);
        AddVertical(Workspace, RouteHeader, FMargin(0.0f, 0.0f, 0.0f, 12.0f));

        UBorder* EndpointBinding = MakePanel(Tree, TEXT("EndpointBinding"), SurfaceRaised, FMargin(12.0f));
        UHorizontalBox* Endpoints = Tree->ConstructWidget<UHorizontalBox>(UHorizontalBox::StaticClass(), TEXT("HB_EndpointBinding"));
        EndpointBinding->AddChild(Endpoints);
        UVerticalBox* SourceEndpoint = Tree->ConstructWidget<UVerticalBox>(UVerticalBox::StaticClass(), TEXT("Endpoint_Source"));
        AddVertical(SourceEndpoint, MakeText(Tree, TEXT("Text_SourceEndpoint"), TEXT("來源端 · BaseCamp_Alpha"), 16, TextPrimary), FMargin(0.0f));
        AddVertical(SourceEndpoint, MakeText(Tree, TEXT("Text_SourceTradeBox"), TEXT("商隊箱：已連線 · 可互動商隊箱"), 14, TextSecondary), FMargin(0.0f, 6.0f));
        AddVertical(SourceEndpoint, MakeText(Tree, TEXT("Text_SourceEscrow"), TEXT("安全貨艙：已連線"), 14, Accent), FMargin(0.0f));
        UHorizontalBoxSlot* SourceEndpointSlot = Endpoints->AddChildToHorizontalBox(SourceEndpoint);
        SourceEndpointSlot->SetSize(FSlateChildSize(ESlateSizeRule::Fill));
        SourceEndpointSlot->SetPadding(FMargin(0.0f, 0.0f, 16.0f, 0.0f));
        UVerticalBox* DestinationEndpoint = Tree->ConstructWidget<UVerticalBox>(UVerticalBox::StaticClass(), TEXT("Endpoint_Destination"));
        AddVertical(DestinationEndpoint, MakeText(Tree, TEXT("Text_DestinationEndpoint"), TEXT("目的端 · BaseCamp_Beta"), 16, TextPrimary), FMargin(0.0f));
        AddVertical(DestinationEndpoint, MakeText(Tree, TEXT("Text_DestinationTradeBox"), TEXT("商隊箱：尚未指定"), 14, TextSecondary), FMargin(0.0f, 6.0f));
        AddVertical(DestinationEndpoint, MakeText(Tree, TEXT("Text_DestinationEscrow"), TEXT("尚未綁定商隊箱；YEET 不會開始補貨"), 14, Amber), FMargin(0.0f));
        UHorizontalBoxSlot* DestinationEndpointSlot = Endpoints->AddChildToHorizontalBox(DestinationEndpoint);
        DestinationEndpointSlot->SetSize(FSlateChildSize(ESlateSizeRule::Fill));
        AddVertical(Workspace, EndpointBinding, FMargin(0.0f, 0.0f, 0.0f, 12.0f));

        UHorizontalBox* DirectionTabs = Tree->ConstructWidget<UHorizontalBox>(UHorizontalBox::StaticClass(), TEXT("DirectionTabs"));
        DirectionTabs->AddChildToHorizontalBox(MakeButton(Tree, TEXT("Btn_Direction_Outbound"), TEXT("去程 A→B")))->SetPadding(FMargin(0.0f, 0.0f, 8.0f, 0.0f));
        DirectionTabs->AddChildToHorizontalBox(MakeButton(Tree, TEXT("Btn_Direction_Return"), TEXT("回程 B→A")))->SetPadding(FMargin(0.0f));
        AddVertical(Workspace, DirectionTabs, FMargin(0.0f, 0.0f, 0.0f, 12.0f));

        UBorder* DemandRulesTable = MakePanel(Tree, TEXT("DemandRulesTable"), SurfaceRaised, FMargin(12.0f));
        UVerticalBox* DemandRules = Tree->ConstructWidget<UVerticalBox>(UVerticalBox::StaticClass(), TEXT("VB_DemandRulesTable"));
        DemandRulesTable->AddChild(DemandRules);
        AddVertical(DemandRules, MakeText(Tree, TEXT("Text_DemandRulesTitle"), TEXT("需求規則"), 18, TextPrimary), FMargin(0.0f, 0.0f, 0.0f, 8.0f));
        UHorizontalBox* RuleHeader = Tree->ConstructWidget<UHorizontalBox>(UHorizontalBox::StaticClass(), TEXT("DemandRuleHeader"));
        const TCHAR* RuleHeaders[] = { TEXT("Item"), TEXT("來源基地保留"), TEXT("卸貨端點"), TEXT("目的目標"), TEXT("單趟上限"), TEXT("目前缺口") };
        for (int32 Index = 0; Index < UE_ARRAY_COUNT(RuleHeaders); ++Index)
        {
            UTextBlock* HeaderText = MakeText(Tree, *FString::Printf(TEXT("DemandHeader_%d"), Index), RuleHeaders[Index], 13, TextSecondary);
            UHorizontalBoxSlot* HeaderSlot = RuleHeader->AddChildToHorizontalBox(HeaderText);
            HeaderSlot->SetSize(FSlateChildSize(ESlateSizeRule::Fill));
            HeaderSlot->SetPadding(FMargin(0.0f, 0.0f, 8.0f, 0.0f));
        }
        AddVertical(DemandRules, RuleHeader, FMargin(0.0f, 0.0f, 0.0f, 6.0f));
        UHorizontalBox* RuleRow = Tree->ConstructWidget<UHorizontalBox>(UHorizontalBox::StaticClass(), TEXT("DemandRuleRow_0"));
        const TCHAR* RuleValues[] = { TEXT("木材"), TEXT("20"), TEXT("trade_box"), TEXT("100"), TEXT("40"), TEXT("12") };
        for (int32 Index = 0; Index < UE_ARRAY_COUNT(RuleValues); ++Index)
        {
            UTextBlock* ValueText = MakeText(Tree, *FString::Printf(TEXT("DemandValue_%d"), Index), RuleValues[Index], 14, TextPrimary);
            UHorizontalBoxSlot* ValueSlot = RuleRow->AddChildToHorizontalBox(ValueText);
            ValueSlot->SetSize(FSlateChildSize(ESlateSizeRule::Fill));
            ValueSlot->SetPadding(FMargin(0.0f, 0.0f, 8.0f, 0.0f));
        }
        AddVertical(DemandRules, RuleRow, FMargin(0.0f, 0.0f, 0.0f, 8.0f));
        UHorizontalBox* RuleOptions = Tree->ConstructWidget<UHorizontalBox>(UHorizontalBox::StaticClass(), TEXT("DemandRuleOptions"));
        RuleOptions->AddChildToHorizontalBox(MakeText(Tree, TEXT("Text_FeedBoxOption"), TEXT("Feed Box 選項"), 14, TextSecondary));
        UComboBoxString* DestinationKind = Tree->ConstructWidget<UComboBoxString>(UComboBoxString::StaticClass(), TEXT("Combo_DestinationKind"));
        DestinationKind->AddOption(TEXT("trade_box"));
        DestinationKind->AddOption(TEXT("feed_box"));
        UHorizontalBoxSlot* DestinationKindSlot = RuleOptions->AddChildToHorizontalBox(DestinationKind);
        DestinationKindSlot->SetPadding(FMargin(12.0f, 0.0f, 12.0f, 0.0f));
        RuleOptions->AddChildToHorizontalBox(MakeText(Tree, TEXT("Text_FeedBoxHint"), TEXT("Food／Ingredients 過濾、現有堆疊與容量沿用原版規則"), 13, TextSecondary));
        AddVertical(DemandRules, RuleOptions, FMargin(0.0f));
        AddVertical(Workspace, DemandRulesTable, FMargin(0.0f, 0.0f, 0.0f, 12.0f));

        UBorder* CaravanRoster = MakePanel(Tree, TEXT("CaravanRoster"), SurfaceRaised, FMargin(12.0f));
        UVerticalBox* Roster = Tree->ConstructWidget<UVerticalBox>(UVerticalBox::StaticClass(), TEXT("VB_CaravanRoster"));
        CaravanRoster->AddChild(Roster);
        AddVertical(Roster, MakeText(Tree, TEXT("Text_CaravanRosterTitle"), TEXT("商隊編制與運行狀態"), 18, TextPrimary), FMargin(0.0f, 0.0f, 0.0f, 8.0f));
        AddVertical(Roster, MakeText(Tree, TEXT("Text_CaravanRosterValues"), TEXT("Pal 編制  2 / 2    正式占用  2    容量  480 kg    速度  1.0×    ETA  08:42    運送中"), 14, TextSecondary), FMargin(0.0f));
        AddVertical(Workspace, CaravanRoster, FMargin(0.0f, 0.0f, 0.0f, 12.0f));

        UBorder* AdapterNotice = MakePanel(Tree, TEXT("AdapterSafetyNotice"), FLinearColor(0.16f, 0.12f, 0.07f, 1.0f), FMargin(10.0f));
        AdapterNotice->AddChild(MakeText(Tree, TEXT("Text_AdapterSafetyNotice"), TEXT("安全 adapter：此功能仍在安全驗證中，未修改任何物品／Pal／基地狀態。"), 13, Amber));
        AddVertical(Workspace, AdapterNotice, FMargin(0.0f, 0.0f, 0.0f, 12.0f));

        UHorizontalBox* ActionBar = Tree->ConstructWidget<UHorizontalBox>(UHorizontalBox::StaticClass(), TEXT("ActionBar"));
        ActionBar->AddChildToHorizontalBox(MakeButton(Tree, TEXT("Btn_DeleteRoute"), TEXT("刪除航線")))->SetPadding(FMargin(0.0f, 0.0f, 8.0f, 0.0f));
        ActionBar->AddChildToHorizontalBox(MakeButton(Tree, TEXT("Btn_PauseRoute"), TEXT("暫停")))->SetPadding(FMargin(0.0f, 0.0f, 8.0f, 0.0f));
        ActionBar->AddChildToHorizontalBox(MakeButton(Tree, TEXT("Btn_SaveRoute"), TEXT("儲存變更")));
        AddVertical(Workspace, ActionBar, FMargin(0.0f));

        // OperationsRail: status is deliberately separate from editing controls.
        UBorder* OperationsRail = MakePanel(Tree, TEXT("OperationsRail"), Surface, FMargin(16.0f));
        USizeBox* OperationsRailSize = Tree->ConstructWidget<USizeBox>(USizeBox::StaticClass(), TEXT("OperationsRailSize"));
        OperationsRailSize->SetWidthOverride(300.0f);
        OperationsRailSize->AddChild(OperationsRail);
        Body->AddChildToHorizontalBox(OperationsRailSize);
        UVerticalBox* Operations = Tree->ConstructWidget<UVerticalBox>(UVerticalBox::StaticClass(), TEXT("VB_OperationsRail"));
        OperationsRail->AddChild(Operations);
        AddVertical(Operations, MakeText(Tree, TEXT("Text_NextArrivalTitle"), TEXT("下一抵達"), 17, TextSecondary), FMargin(0.0f));
        AddVertical(Operations, MakeText(Tree, TEXT("NextArrival"), TEXT("08:42"), 32, Accent), FMargin(0.0f, 2.0f, 0.0f, 24.0f));
        AddVertical(Operations, MakeText(Tree, TEXT("Text_ActiveCaravansTitle"), TEXT("運行中商隊"), 16, TextSecondary), FMargin(0.0f));
        AddVertical(Operations, MakeText(Tree, TEXT("ActiveCaravans"), TEXT("5 條 · 1 條運送中 · 2 條準備出發"), 14, TextPrimary), FMargin(0.0f, 4.0f, 0.0f, 20.0f));
        AddVertical(Operations, MakeText(Tree, TEXT("Text_CargoEscrowTitle"), TEXT("在途貨物／安全貨艙"), 16, TextSecondary), FMargin(0.0f));
        AddVertical(Operations, MakeText(Tree, TEXT("CargoEscrow"), TEXT("安全貨艙：已快照確認 · 320 kg · 2 箱"), 14, Accent), FMargin(0.0f, 4.0f, 0.0f, 20.0f));
        AddVertical(Operations, MakeText(Tree, TEXT("Text_BlockingIssuesTitle"), TEXT("阻塞問題"), 16, TextSecondary), FMargin(0.0f));
        AddVertical(Operations, MakeText(Tree, TEXT("BlockingIssues"), TEXT("目的箱已滿，貨物仍在商隊\n清出綁定商隊箱／Feed Box 後重試"), 14, Amber), FMargin(0.0f, 4.0f, 0.0f, 0.0f));

        UHorizontalBox* Footer = Tree->ConstructWidget<UHorizontalBox>(UHorizontalBox::StaticClass(), TEXT("Footer"));
        UTextBlock* Version = MakeText(Tree, TEXT("Text_Version"), TEXT("YEET Protocol v0.5.0 · Host Authority: Lua"), 13, TextSecondary);
        UHorizontalBoxSlot* VersionSlot = Footer->AddChildToHorizontalBox(Version);
        VersionSlot->SetSize(FSlateChildSize(ESlateSizeRule::Fill));
        Footer->AddChildToHorizontalBox(MakeText(Tree, TEXT("Text_SaveState"), TEXT("儲存狀態：未修改"), 13, TextSecondary));
        AddVertical(Main, Footer, FMargin(0.0f));

        FKismetEditorUtilities::CompileBlueprint(WidgetBP);
        WidgetBP->MarkPackageDirty();
        const bool bSaved = UPackage::SavePackage(
            WidgetBP->GetOutermost(), WidgetBP, RF_Public | RF_Standalone,
            *FPackageName::LongPackageNameToFilename(WidgetBP->GetOutermost()->GetName(), FPackageName::GetAssetPackageExtension()));
        UE_LOG(LogTemp, Display, TEXT("YEETBUILD: WBP_YEETRouteMenu saved=%s"), bSaved ? TEXT("true") : TEXT("false"));
        return bSaved;
    }

    bool BuildModActor()
    {
        const FString PackageName(TEXT("/Game/Mods/YEET/ModActor"));
        UPackage* Package = LoadPackage(nullptr, *PackageName, LOAD_None);
        if (!Package)
        {
            Package = CreatePackage(*PackageName);
        }
        UBlueprint* Blueprint = FindObject<UBlueprint>(Package, TEXT("ModActor"));
        if (!Blueprint)
        {
            Blueprint = FKismetEditorUtilities::CreateBlueprint(
                AActor::StaticClass(), Package, TEXT("ModActor"), BPTYPE_Normal,
                UBlueprint::StaticClass(), UBlueprintGeneratedClass::StaticClass(), TEXT("YEETAssetBuilder"));
        }
        if (!Blueprint)
        {
            UE_LOG(LogTemp, Error, TEXT("YEETBUILD: ModActor creation failed"));
            return false;
        }
        FKismetEditorUtilities::CompileBlueprint(Blueprint);
        Blueprint->MarkPackageDirty();
        const bool bSaved = UPackage::SavePackage(
            Blueprint->GetOutermost(), Blueprint, RF_Public | RF_Standalone,
            *FPackageName::LongPackageNameToFilename(Blueprint->GetOutermost()->GetName(), FPackageName::GetAssetPackageExtension()));
        UE_LOG(LogTemp, Display, TEXT("YEETBUILD: ModActor saved=%s"), bSaved ? TEXT("true") : TEXT("false"));
        return bSaved;
    }
}

bool UYEETAssetBuilderLibrary::BuildYEETAssets()
{
    if (!VerifyTerminalBlueprint())
    {
        UE_LOG(LogTemp, Error, TEXT("YEETBUILD: incomplete status=terminal_required_before_widget_or_actor_build"));
        return false;
    }

    const bool bWidget = BuildRouteWidget();
    const bool bActor = BuildModActor();
    UE_LOG(LogTemp, Display, TEXT("YEETBUILD: complete widget=%s actor=%s"), bWidget ? TEXT("true") : TEXT("false"), bActor ? TEXT("true") : TEXT("false"));
    return bWidget && bActor;
}
