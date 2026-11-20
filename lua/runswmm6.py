#!/usr/bin/env python3
"""runswmm6.py - the Lua port's launcher: starts a Lua 5.4 state (lupa's LuaRuntime, with Python's builtins and eval
kept out of it) and calls runswmm6.lua with this folder, the working directory (the engine's full paths need it, and
Lua has no getcwd) and the command line, as bytes; the engine, its runtime and its math are all Lua. The process ends
with the code runswmm6.lua returns (134 for an exception that escaped the engine), without running Python's exit
handlers.
    lua/runswmm6 model.inp report.rpt [output.out]
Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see AI-USE.md and README.md."""
import os, sys
from lupa import lua54

here = os.path.dirname(os.path.abspath(__file__))
L = lua54.LuaRuntime(register_eval=False, register_builtins=False, encoding=None)
L.execute('os.setlocale("C")')
main = L.execute('return dofile(...)', os.fsencode(os.path.join(here, 'runswmm6.lua')))
rc = main(os.fsencode(here), os.fsencode(os.getcwd()), *[os.fsencode(a) for a in sys.argv[1:]])
sys.stdout.flush()
sys.stderr.flush()
os._exit(int(rc or 0) & 0xFF)
