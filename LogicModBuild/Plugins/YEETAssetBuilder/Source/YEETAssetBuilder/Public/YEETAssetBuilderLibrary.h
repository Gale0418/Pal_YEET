#pragma once

#include "CoreMinimal.h"
#include "Kismet/BlueprintFunctionLibrary.h"
#include "YEETAssetBuilderLibrary.generated.h"

UCLASS()
class YEETASSETBUILDER_API UYEETAssetBuilderLibrary : public UBlueprintFunctionLibrary
{
    GENERATED_BODY()

public:
    UFUNCTION(BlueprintCallable, Category="YEET|Editor")
    static bool BuildYEETAssets();
};
