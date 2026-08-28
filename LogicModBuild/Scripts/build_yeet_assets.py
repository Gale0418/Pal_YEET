import unreal

unreal.log("YEETPY:BUILD_START")
ok = unreal.YEETAssetBuilderLibrary.build_yeet_assets()
if not ok:
    raise RuntimeError("YEET asset builder returned false")
unreal.log("YEETPY:BUILD_COMPLETE")
