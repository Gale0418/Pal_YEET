using UnrealBuildTool;

public class YEETAssetBuilder : ModuleRules
{
    public YEETAssetBuilder(ReadOnlyTargetRules Target) : base(Target)
    {
        PCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;
        PrivateDependencyModuleNames.AddRange(new string[]
        {
            "Core",
            "CoreUObject",
            "Engine",
            "Slate",
            "SlateCore",
            "UMG",
            "UMGEditor",
            "UnrealEd",
            "Kismet",
            "AssetTools"
        });
    }
}
