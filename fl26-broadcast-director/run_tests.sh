#!/bin/sh
# Runs the test suite under LuaJIT (sider's runtime), falling back to lua5.1.
cd "$(dirname "$0")"
LUA=$(command -v luajit || command -v lua5.1 || command -v lua)
[ -z "$LUA" ] && { echo "LuaJIT or Lua 5.1 required"; exit 1; }
exec "$LUA" tests/test_director.lua . "${TMPDIR:-/tmp}"
