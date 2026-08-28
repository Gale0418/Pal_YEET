"""Run checked-in Lua specs through Lupa when a standalone Lua is unavailable."""

from pathlib import Path

try:
    from lupa import LuaRuntime
except ImportError:
    print("LUA SPECS: FAIL (Lupa is not installed)")
    raise SystemExit(1)


ROOT = Path(__file__).resolve().parents[1]
for path in sorted((ROOT / "tests").glob("*_spec.lua")):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(path.read_text(encoding="utf-8"))
    print(f"{path.name}: PASS (Lupa runner)")

print("LUA SPECS: PASS")
