import unreal

ASSET_PATH = "/Game/Mods/YEET/UI"
ASSET_NAME = "WBP_YEETRouteMenu"

unreal.EditorAssetLibrary.make_directory(ASSET_PATH)
existing = unreal.EditorAssetLibrary.load_asset(ASSET_PATH + "/" + ASSET_NAME)
if existing:
    asset = existing
else:
    factory = unreal.WidgetBlueprintFactory()
    factory.set_editor_property("parent_class", unreal.UserWidget)
    asset = unreal.AssetToolsHelpers.get_asset_tools().create_asset(
        ASSET_NAME, ASSET_PATH, unreal.WidgetBlueprint, factory
    )

unreal.log("YEETPY:ASSET={}".format(asset))
unreal.log("YEETPY:DIR={}".format([x for x in dir(asset) if "widget" in x.lower() or "tree" in x.lower()]))
for prop in ("widget_tree", "generated_class", "parent_class", "skeleton_generated_class"):
    try:
        unreal.log("YEETPY:PROP {}={}".format(prop, asset.get_editor_property(prop)))
    except Exception as exc:
        unreal.log_warning("YEETPY:PROPFAIL {}={}".format(prop, exc))

unreal.KismetEditorUtilities.compile_blueprint(asset)
unreal.EditorAssetLibrary.save_loaded_asset(asset, only_if_is_dirty=False)
unreal.log("YEETPY:DONE")
