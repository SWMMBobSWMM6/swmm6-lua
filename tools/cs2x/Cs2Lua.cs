// Cs2Lua - translate the generated C# SWMM6 engine (cs/gen and cs/runtime/Hand_*.cs) into one Lua 5.4 file
// (lua/gen/engine.lua), using Roslyn's semantic model, the way Cs2Pl writes the Perl engine. The design is recorded
// in LUA.md; the runtime contract the file relies on is the Python, Ruby and Perl ports' (the same runtime names),
// with the Lua spellings LUA.md lists.
//
//   dotnet bin/cs2lua.dll CS_DIR LUA_GEN_DIR
//
// writes LUA_GEN_DIR/engine.lua, LUA_GEN_DIR/literals.txt (every double literal and its bits),
// LUA_GEN_DIR/../cs2lua_runtime.txt (every runtime name the file uses, with the C# member it stands for),
// LUA_GEN_DIR/../cs2lua_todo.txt (untranslated constructs; the goal is none) and LUA_GEN_DIR/../cs2lua_stats.txt.
//
// Begun from tools/cs2x/Cs2Pl.cs (the analysis and the names are the Perl, Ruby and Python back ends'; the printing
// is Lua's). Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see AI-USE.md and lua/README.md.
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;
using Microsoft.CodeAnalysis.Operations;

public sealed class Todo : Exception { public Todo(string m) : base(m) { } }

public static partial class Cs2Lua
{
    static CSharpCompilation comp = null!;
    static readonly Dictionary<SyntaxTree, SemanticModel> models = new();
    static SemanticModel M(SyntaxNode n) => models[n.SyntaxTree];
    static readonly SortedDictionary<string, int> todos = new();
    static readonly SortedDictionary<string, SortedSet<string>> manifest = new(StringComparer.Ordinal);
    static readonly SortedDictionary<string, int> stats = new();

    public static int Main(string[] args)
    {
        var cs = args[0];
        var outDir = args[1];
        var files = Directory.GetFiles(Path.Combine(cs, "gen"), "*.cs").Concat(Directory.GetFiles(Path.Combine(cs, "runtime"), "*.cs"))
            .Where(f => !f.EndsWith("Program.cs")).OrderBy(f => f, StringComparer.Ordinal).ToArray();
        var opts = new CSharpParseOptions(LanguageVersion.Latest);
        var trees = files.Select(f => CSharpSyntaxTree.ParseText(File.ReadAllText(f), opts, f)).ToList();
        var fw = Path.GetDirectoryName(typeof(object).Assembly.Location)!;
        var refs = new List<MetadataReference>();
        foreach (var f in Directory.GetFiles(fw, "*.dll"))
        {
            var b = Path.GetFileName(f);
            if (b.StartsWith("Microsoft.VisualBasic") || b == "mscorlib.dll") continue;
            try { refs.Add(MetadataReference.CreateFromFile(f)); } catch { }
        }
        comp = CSharpCompilation.Create("engine", trees, refs, new CSharpCompilationOptions(OutputKind.DynamicallyLinkedLibrary, allowUnsafe: true));
        var errs = comp.GetDiagnostics().Where(d => d.Severity == DiagnosticSeverity.Error).ToList();
        if (errs.Count > 0) { foreach (var e in errs.Take(10)) Console.Error.WriteLine(e); return 1; }
        foreach (var t in trees) models[t] = comp.GetSemanticModel(t);
        var gen = trees.Where(t => t.FilePath.Contains("/gen/") || Path.GetFileName(t.FilePath).StartsWith("Hand_")).ToList();

        Directory.CreateDirectory(outDir);
        CollectTypes(gen);
        Analyze(gen);
        var text = Module(gen);
        CheckNameClashes();
        File.WriteAllText(Path.Combine(outDir, "engine.lua"), text);
        // every double literal the engine file holds, with the IEEE bits C# gives it: lua/test checks Lua reads each
        File.WriteAllText(Path.Combine(outDir, "literals.txt"), string.Concat(doubleLits.Select(kv => kv.Key + " " + kv.Value + "\n")));
        using (var w = new StreamWriter(Path.Combine(outDir, "..", "cs2lua_todo.txt")))
            foreach (var kv in todos.OrderByDescending(kv => kv.Value).ThenBy(kv => kv.Key, StringComparer.Ordinal)) w.WriteLine("{0,6}  {1}", kv.Value, kv.Key);
        using (var w = new StreamWriter(Path.Combine(outDir, "..", "cs2lua_runtime.txt")))
        {
            w.WriteLine("# The runtime names lua/gen/engine.lua uses: Lua name, tab, the C# member(s) it stands for (a .name is a method or field of runtime objects; the rest are globals of the runtime's environment). See tools/cs2x/LUA.md.");
            w.WriteLine("# Written by tools/cs2x/Cs2Lua.cs. Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see AI-USE.md.");
            foreach (var kv in manifest) w.WriteLine(kv.Key + "\t" + string.Join(" | ", kv.Value));
        }
        using (var w = new StreamWriter(Path.Combine(outDir, "..", "cs2lua_stats.txt")))
            foreach (var kv in stats.OrderByDescending(kv => kv.Value).ThenBy(kv => kv.Key, StringComparer.Ordinal)) w.WriteLine("{0,7}  {1}", kv.Value, kv.Key);
        Console.WriteLine("wrote engine.lua (" + text.Count(c => c == '\n') + " lines), " + manifest.Count + " runtime names, " + todos.Count + " TODO kinds, " + todos.Values.Sum() + " TODO sites");
        return 0;
    }

    static void Note(string what) { todos[what] = todos.TryGetValue(what, out var c) ? c + 1 : 1; }
    static void Stat(string what) { stats[what] = stats.TryGetValue(what, out var c) ? c + 1 : 1; }

    static string Todo(string what)
    {
        todos[what] = todos.TryGetValue(what, out var c) ? c + 1 : 1;
        throw new Todo(what);
    }

    /// <summary>Record that the engine uses runtime global lua (a field of the shared environment) for C# member cs.</summary>
    static string Use(string lua, string cs)
    {
        if (!manifest.TryGetValue(lua, out var set)) manifest[lua] = set = new SortedSet<string>(StringComparer.Ordinal);
        set.Add(cs);
        return lua;
    }

    /// <summary>Record that the engine uses method or field lua of runtime objects for the C# member cs.</summary>
    static string UseM(string lua, string cs)
    {
        lua = AttrIdent(lua);
        var k = "." + lua;
        if (!manifest.TryGetValue(k, out var set)) manifest[k] = set = new SortedSet<string>(StringComparer.Ordinal);
        set.Add(cs);
        return lua;
    }

    /// <summary>A runtime class table (Cpp_Name).</summary>
    static string UseC(string n, string cs) => Use("Cpp_" + n, cs);

    // ------------------------------------------------------------------------------------------------ names
    static readonly HashSet<string> LuaKeywords = new()
    {
        "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in", "local", "nil", "not",
        "or", "repeat", "return", "then", "true", "until", "while"
    };

    /// <summary>Local names the translator gives a meaning of its own (the receiver, the environment) or that would
    /// shadow a chunk-level alias of the engine file (those all start with L_).</summary>
    static readonly HashSet<string> LuaReservedLocals = new() { "self", "_ENV", "_G", "o_", "arg" };

    static string LuaIdentBase(string n)
    {
        n = n.TrimStart('@');
        var sb = new StringBuilder();
        foreach (var ch in n) sb.Append(ch < 128 && (char.IsLetterOrDigit(ch) || ch == '_') ? ch : '_');
        n = sb.ToString();
        if (n.Length == 0 || char.IsDigit(n[0])) n = "_" + n;
        return n;
    }

    /// <summary>A local variable or parameter. Every engine local starts with a lower-case letter or is given the prefix
    /// v_, so it can never shadow a global the function uses (globals are O_*, F_*, Type_* and the runtime's names,
    /// which start with an upper-case letter or are listed in GlobalLowerNames).</summary>
    static string LocalIdent(string n)
    {
        n = LuaIdentBase(n);
        if (LuaKeywords.Contains(n) || LuaReservedLocals.Contains(n)) n += "_";
        if (n.Length > 0 && (char.IsUpper(n[0]) || n[0] == '_')) n = "v_" + n;
        if (GlobalLowerNames.Contains(n)) n = "v_" + n;
        return n;
    }

    /// <summary>Lower-case global names the runtime defines and the engine file calls (they must not be shadowed).</summary>
    static readonly HashSet<string> GlobalLowerNames = new()
    {
        "isa_", "req", "cell", "exc_of", "f32", "i2d", "u2d", "udiv64", "umod64", "ult", "is_nan", "is_inf", "is_finite",
        "cs_tostring", "cs_tostring_d", "cs_chr", "cs_equals", "seq", "fdiv0", "newA", "newAD", "newAI", "newAZ", "aLen",
        "deref2", "idiv", "imod", "sar", "f2i32", "f2u32", "f2i64", "f2u64", "f2i16", "f2u16", "f2i8", "f2u8", "signbit",
        "f64_from_bits", "f64_to_bits_signed", "exc_message", "elems", "cmp_lt", "bAnd", "bOr", "bXor", "lua_class",
        "inherit_all", "set_strict", "declare_global", "unpack", "math", "string", "table", "type", "pairs", "next",
        "select", "error", "pcall", "tostring", "tonumber", "setmetatable", "getmetatable", "rawget", "rawset", "rawequal",
        "print", "assert", "load", "require", "io", "os", "utf8", "coroutine", "debug", "ipairs", "collectgarbage"
    };

    /// <summary>A field or method name: Lua keywords get a _ suffix (obj.end_, obj:end_()).</summary>
    public static string AttrIdent(string n)
    {
        n = LuaIdentBase(n);
        if (LuaKeywords.Contains(n)) n += "_";
        if (n.StartsWith("__")) n = "u" + n;              // never a metamethod name (__index, __eq, ...)
        return n;
    }

    static string PyIdent(string n)
    {
        n = n.TrimStart('@');
        var sb = new StringBuilder();
        foreach (var ch in n) sb.Append(char.IsLetterOrDigit(ch) || ch == '_' ? ch : '_');
        n = sb.ToString();
        if (n.Length == 0 || char.IsDigit(n[0])) n = "_" + n;
        return n;
    }

    static bool IsRuntime(ISymbol s)
    {
        var ns = s is INamespaceSymbol nss ? nss : s.ContainingNamespace;
        while (ns != null && !ns.IsGlobalNamespace)
        {
            if (ns.Name == "Cpp" && ns.ContainingNamespace.IsGlobalNamespace) return true;
            ns = ns.ContainingNamespace;
        }
        return false;
    }

    static bool IsSystem(ISymbol s)
    {
        var ns = s.ContainingNamespace;
        while (ns != null && !ns.IsGlobalNamespace) { if (ns.Name == "System" && ns.ContainingNamespace.IsGlobalNamespace) return true; ns = ns.ContainingNamespace; }
        return false;
    }

    static readonly HashSet<string> engineFunctions = new();
    static readonly HashSet<string> engineGlobals = new(StringComparer.Ordinal);
    static readonly Dictionary<ISymbol, string> typeNames = new(SymbolEqualityComparer.Default);

    /// <summary>The Python back end's name of an engine type: the prefix of its functions and globals.</summary>
    static string TypeIdent(INamedTypeSymbol t)
    {
        t = t.OriginalDefinition;
        if (typeNames.TryGetValue(t, out var n)) return n;
        var parts = new List<string>();
        for (var c = t; c != null; c = c.ContainingType) parts.Insert(0, c.Name);
        var ns = new List<string>();
        for (var x = t.ContainingNamespace; x != null && !x.IsGlobalNamespace; x = x.ContainingNamespace) ns.Insert(0, x.Name);
        if (ns.Count > 0 && (ns[0] == "openswmm" || ns[0] == "_global" || ns[0] == "Gen")) ns.RemoveAt(0);
        var s = PyIdent(string.Join("_", ns.Concat(parts)));
        if (t.Name == "_F" && t.ContainingType == null)
        {
            var full = new List<string>();
            for (var x = t.ContainingNamespace; x != null && !x.IsGlobalNamespace; x = x.ContainingNamespace) full.Insert(0, x.Name);
            s = full.Count == 1 && full[0] == "openswmm" ? "F" : full.Count > 0 && full[0] == "openswmm" ? "F_" + string.Join("_", full.Skip(1)) : "F_" + string.Join("_", full);
        }
        while (s.StartsWith("__")) s += "_";
        if (s.Length > 0 && !char.IsUpper(s[0])) s = "T" + s;      // globals start with an upper-case letter (LocalIdent)
        typeNames[t] = s;
        return s;
    }

    /// <summary>The Lua class table of an engine class: O_ and its type name.</summary>
    static string ClassConst(INamedTypeSymbol t) => "O_" + TypeIdent(t.OriginalDefinition);

    static string StaticFuncName(IMethodSymbol m) => TypeIdent(m.ContainingType) + "_" + MethodIdent(m);

    /// <summary>A static field: a global of the engine's environment.</summary>
    static string StaticFieldName(IFieldSymbol f) => "S_" + TypeIdent(f.ContainingType) + "_" + PyIdent(f.Name);

    static readonly Dictionary<IMethodSymbol, string> methodNames = new(SymbolEqualityComparer.Default);

    /// <summary>An engine method's Lua name (the Ruby and Perl back ends' rule: overloads and hiding methods get a suffix
    /// of their parameter types, an override keeps its base's name, a method implementing a runtime interface member
    /// keeps that member's name).</summary>
    static string MethodIdent(IMethodSymbol m)
    {
        m = m.OriginalDefinition;
        if (m.OverriddenMethod != null) return MethodIdent(m.OverriddenMethod);
        if (methodNames.TryGetValue(m, out var n)) return n;
        var t = m.ContainingType;
        var nm = AttrIdent(m.Name);
        var impl = !m.IsStatic ? RuntimeInterfaceMember(m) : null;
        if (impl != null) { methodNames[m] = AttrIdent(impl); return methodNames[m]; }
        var same = t.GetMembers(m.Name).OfType<IMethodSymbol>().Where(x => x.MethodKind == MethodKind.Ordinary).ToList();
        bool overloaded = same.Count > 1;
        bool hidesSame = false;
        if (!m.IsStatic)
        {
            for (var b = t.BaseType; b != null && !IsSystem(b) && !IsRuntime(b); b = b.BaseType)
                foreach (var x in b.GetMembers(m.Name).OfType<IMethodSymbol>())
                    if (x.MethodKind == MethodKind.Ordinary && !x.IsStatic && !IsOverrideOf(m, x))
                    { overloaded = true; if (SameParams(x, m)) hidesSame = true; }
        }
        if (overloaded)
            nm += "__" + string.Join("_", m.Parameters.Select(p => ShortType(p.Type) + (p.RefKind != RefKind.None ? "r" : "")));
        if (hidesSame) nm += "__" + TypeIdent(t);
        methodNames[m] = nm;
        return nm;
    }

    static ulong Fnv(string s)
    {
        ulong h = 14695981039346656037UL;
        foreach (var ch in s) { h ^= ch; h *= 1099511628211UL; }
        return h;
    }

    static bool SameParams(IMethodSymbol a, IMethodSymbol b) =>
        a.Parameters.Length == b.Parameters.Length && a.Parameters.Zip(b.Parameters).All(p => SymbolEqualityComparer.Default.Equals(p.First.Type, p.Second.Type) && p.First.RefKind == p.Second.RefKind);

    static string? RuntimeInterfaceMember(IMethodSymbol m)
    {
        foreach (var i in m.ContainingType.AllInterfaces)
        {
            if (!IsRuntime(i) && !IsSystem(i)) continue;
            foreach (var im in i.GetMembers().OfType<IMethodSymbol>())
            {
                var impl = m.ContainingType.FindImplementationForInterfaceMember(im);
                if (SymbolEqualityComparer.Default.Equals(impl?.OriginalDefinition, m)) return im.Name;
            }
        }
        return null;
    }

    static bool IsOverrideOf(IMethodSymbol m, IMethodSymbol b)
    {
        for (var o = m.OverriddenMethod; o != null; o = o.OverriddenMethod) if (SymbolEqualityComparer.Default.Equals(o.OriginalDefinition, b.OriginalDefinition)) return true;
        return false;
    }

    static bool Derives(INamedTypeSymbol d, INamedTypeSymbol b)
    {
        for (var x = d.BaseType; x != null; x = x.BaseType) if (SymbolEqualityComparer.Default.Equals(x.OriginalDefinition, b.OriginalDefinition)) return true;
        return false;
    }

    /// <summary>Whether a call of m must go through Lua's method lookup (obj:m()): a virtual, abstract or override
    /// method, or one implementing a runtime interface member (the runtime calls those by name). Every other instance
    /// method is called as the function of the class that declares it (O_T.m(obj, ...)), which is what C# does for a
    /// non-virtual method.</summary>
    static bool IsDispatched(IMethodSymbol m)
    {
        m = m.OriginalDefinition;
        if (m.IsVirtual || m.IsAbstract || m.IsOverride) return true;
        if (RuntimeInterfaceMember(m) != null) return true;
        foreach (var i in m.ContainingType.AllInterfaces)
            foreach (var im in i.GetMembers().OfType<IMethodSymbol>())
                if (SymbolEqualityComparer.Default.Equals(m.ContainingType.FindImplementationForInterfaceMember(im)?.OriginalDefinition, m)) return true;
        return false;
    }

    static string ShortType(ITypeSymbol t)
    {
        switch (t.SpecialType)
        {
            case SpecialType.System_Int32: return "i";
            case SpecialType.System_Int64: return "l";
            case SpecialType.System_UInt64: return "ul";
            case SpecialType.System_UInt32: return "u";
            case SpecialType.System_Double: return "d";
            case SpecialType.System_Single: return "f";
            case SpecialType.System_Boolean: return "b";
            case SpecialType.System_SByte: return "c";
            case SpecialType.System_Byte: return "uc";
            case SpecialType.System_Int16: return "s";
            case SpecialType.System_UInt16: return "us";
            case SpecialType.System_Char: return "ch";
            case SpecialType.System_Object: return "o";
            case SpecialType.System_String: return "str";
        }
        if (t is IArrayTypeSymbol at) return ShortType(at.ElementType) + "A";
        if (t is ITypeParameterSymbol tp) return tp.Name;
        if (t is INamedTypeSymbol nt)
        {
            var s = nt.Name;
            if (nt.TypeArguments.Length > 0) s += string.Join("", nt.TypeArguments.Select(ShortType));
            return s;
        }
        return "x";
    }

    static readonly Dictionary<IFieldSymbol, string> fieldNames = new(SymbolEqualityComparer.Default);

    /// <summary>Every name a method of an engine object can have (engine methods, the runtime's interface methods and
    /// the methods of the runtime classes engine classes derive from): a field with one of these names would hide the
    /// method in Lua, where an object's fields and its class's methods share one namespace, so such a field is renamed.</summary>
    static HashSet<string>? methodNameSet;

    static readonly string[] RuntimeObjectMethods =
    {
        "Clone", "Assign", "MoveFrom", "Equals", "GetHashCode", "CompareTo", "Dispose", "DestroyElems", "HashOf", "Call2",
        "ToString", "what", "Message", "op_Call", "write", "flush", "close", "Raw", "Pad", "kind", "elems", "Items", "_ctor_Str",
        "_alloc", "_new", "Set", "Get", "Bool", "open", "is_open", "good", "fail_", "bad", "eof", "clear", "str_", "size",
        "empty", "begin", "end_"
    };

    static HashSet<string> MethodNameSet()
    {
        if (methodNameSet != null) return methodNameSet;
        var s = new HashSet<string>(RuntimeObjectMethods);
        foreach (var t in engineTypes)
            foreach (var m in t.GetMembers().OfType<IMethodSymbol>())
                if (m.MethodKind == MethodKind.Ordinary && !m.IsStatic) s.Add(MethodIdent(m));
        foreach (var t in engineTypes)
            for (var b = t.BaseType; b != null; b = b.BaseType)
                if (IsRuntime(b))
                    foreach (var m in b.GetMembers().OfType<IMethodSymbol>()) if (m.MethodKind == MethodKind.Ordinary) s.Add(AttrIdent(m.Name));
        methodNameSet = s;
        return s;
    }

    /// <summary>An instance field's key. A field hiding a base class's field gets its class's name; a field that shares
    /// a name with any method gets the suffix _f.</summary>
    static string FieldIdent(IFieldSymbol f)
    {
        f = f.OriginalDefinition;
        if (fieldNames.TryGetValue(f, out var n)) return n;
        n = AttrIdent(f.Name);
        if (!f.IsStatic && IsEngine(f.ContainingType))
        {
            for (var b = f.ContainingType.BaseType; b != null && b.SpecialType != SpecialType.System_Object && !IsSystem(b); b = b.BaseType)
                if (b.GetMembers(f.Name).OfType<IFieldSymbol>().Any(x => !x.IsStatic)) { n += "_" + TypeIdent(f.ContainingType); Stat("hidden field (renamed) " + f.Name); break; }
            if (MethodNameSet().Contains(n)) { n += "_f"; Stat("field named like a method (renamed)"); }
        }
        fieldNames[f] = n;
        return n;
    }

    static string StripArity(string s) { var i = s.IndexOf('`'); return i < 0 ? s : s.Substring(0, i); }

    /// <summary>Two engine globals with one name, or an engine global with a runtime global's name, would replace
    /// each other silently in the shared environment: each is a TODO.</summary>
    static void CheckNameClashes()
    {
        foreach (var g in engineGlobals)
            if (manifest.ContainsKey(g)) Note("engine global " + g + " has a runtime name");
    }

    static void DefineGlobal(string name)
    {
        if (!engineGlobals.Add(name)) Note("engine global defined twice: " + name);
    }
}
