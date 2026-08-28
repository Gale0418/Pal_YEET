import unreal

unreal.log("YEETPY:START")
for name in (
    "WidgetBlueprintFactory",
    "WidgetBlueprint",
    "WidgetTree",
    "CanvasPanel",
    "Border",
    "VerticalBox",
    "TextBlock",
    "Button",
):
    cls = getattr(unreal, name, None)
    unreal.log("YEETPY:CLASS {}={}".format(name, cls))

factory = unreal.WidgetBlueprintFactory()
unreal.log("YEETPY:FACTORY={}".format(factory))
unreal.log("YEETPY:FACTORY_PROPS={}".format(factory.get_editor_property("parent_class")))
unreal.log("YEETPY:DONE")
