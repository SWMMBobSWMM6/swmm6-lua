#!/usr/bin/env python3
"""runlua.py SCRIPT.lua ARGS... - run one of the Lua port's test scripts in a Lua 5.4 state set up as lua/runswmm6.py
sets up the engine's (lupa's LuaRuntime without Python's builtins, the C locale). The script returns a function; it is
called with the lua/ folder and the arguments, as bytes, and its result is the exit code.
Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see ../README.md."""
import os, sys
from lupa import lua54

lua_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
L = lua54.LuaRuntime(register_eval=False, register_builtins=False, encoding=None)
L.execute('os.setlocale("C")')
main = L.execute('return dofile(...)', os.fsencode(os.path.abspath(sys.argv[1])))
rc = main(os.fsencode(lua_dir), *[os.fsencode(a) for a in sys.argv[2:]])
sys.stdout.flush()
os._exit(int(rc or 0) & 0xFF)
