// LuaTypes.cs - C# types to Lua, the capture and written-field analysis, and the declarations of the Lua engine file.
// Begun from PlTypes.cs: the analysis is the Perl (and Ruby, Python) back end's; the declarations are printed as Lua.
// Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see AI-USE.md and lua/README.md.
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;
using Microsoft.CodeAnalysis.Operations;

public static partial class Cs2Lua
{
    static readonly List<INamedTypeSymbol> engineTypes = new();

    static bool IsEngine(ITypeSymbol t) => t is INamedTypeSymbol n && !IsRuntime(n) && !IsSystem(n) && n.Locations.Any(l => l.IsInSource);

    static void CollectTypes(List<SyntaxTree> gen)
    {
        var seen = new HashSet<INamedTypeSymbol>(SymbolEqualityComparer.Default);
        foreach (var t in gen)
        {
            foreach (var td in t.GetRoot().DescendantNodes().OfType<BaseTypeDeclarationSyntax>())
            {
                var s = (INamedTypeSymbol)M(td).GetDeclaredSymbol(td)!;
                if (seen.Add(s)) engineTypes.Add(s);
            }
            foreach (var dd in t.GetRoot().DescendantNodes().OfType<DelegateDeclarationSyntax>())
            {
                var s = (INamedTypeSymbol)M(dd).GetDeclaredSymbol(dd)!;
                if (seen.Add(s)) engineTypes.Add(s);
            }
        }
        foreach (var s in engineTypes)
        {
            if (s.TypeKind is TypeKind.Enum or TypeKind.Delegate) continue;
            foreach (var m in s.GetMembers())
                if (m is IMethodSymbol ms && ms.IsStatic && ms.MethodKind == MethodKind.Ordinary) engineFunctions.Add(StaticFuncName(ms));
        }
        foreach (var g in engineTypes.Where(IsClassEmitted).GroupBy(TypeIdent).Where(g => g.Count() > 1)) Note("two types named " + g.Key);
    }

    static bool IsClassEmitted(INamedTypeSymbol s) => s.TypeKind == TypeKind.Class && !s.IsStatic;

    // ------------------------------------------------------------------------------------------------ capture analysis
    // Lua's local in a loop body is a fresh variable each iteration when a closure captures it, as C#'s is, so a
    // lambda captures as C# does without help. A local or parameter whose address is taken (passed as ref or out,
    // bound to a ref local) lives in a one-element table, a cell, for its whole life (addrTaken).
    static readonly HashSet<ISymbol> captured = new(SymbolEqualityComparer.Default);
    static readonly HashSet<ISymbol> addrTaken = new(SymbolEqualityComparer.Default);

    static void Analyze(List<SyntaxTree> gen)
    {
        foreach (var t in gen)
        {
            var m = models[t];
            foreach (var node in t.GetRoot().DescendantNodes().Where(n => n is BaseMethodDeclarationSyntax || n is VariableDeclaratorSyntax && n.Parent?.Parent is FieldDeclarationSyntax))
            {
                IOperation? root = node switch
                {
                    BaseMethodDeclarationSyntax bm => bm.Body != null ? m.GetOperation(bm.Body) : bm.ExpressionBody != null ? m.GetOperation(bm.ExpressionBody) : null,
                    VariableDeclaratorSyntax vd => vd.Initializer != null ? m.GetOperation(vd.Initializer) : null,
                    _ => null
                };
                if (root == null) continue;
                foreach (var op in root.DescendantsAndSelf())
                {
                    if (op is IAnonymousFunctionOperation af)
                        foreach (var r in af.Body.Descendants())
                        {
                            ISymbol? s = r is ILocalReferenceOperation lr ? lr.Local : r is IParameterReferenceOperation pr ? pr.Parameter : null;
                            if (s == null) continue;
                            if (!SymbolEqualityComparer.Default.Equals(s.ContainingSymbol, af.Symbol) && !IsInside(s.ContainingSymbol, af.Symbol)) captured.Add(s);
                        }
                    if (IsAddrUse(op))
                    {
                        var x = op;
                        while (x is IConversionOperation cv && cv.Conversion.IsIdentity) x = cv.Operand;
                        if (x is ILocalReferenceOperation l && l.Local.RefKind == RefKind.None) addrTaken.Add(l.Local);
                        else if (x is IParameterReferenceOperation p && p.Parameter.RefKind == RefKind.None) addrTaken.Add(p.Parameter);
                    }
                }
            }
        }
    }

    /// <summary>Whether op is used as a location (its address taken): a ref/out/in argument, the initializer of a ref
    /// local, a ref return, the value of a ref assignment or an arm of a ref conditional.</summary>
    static bool IsAddrUse(IOperation op)
    {
        var p = op.Parent;
        while (p is IConversionOperation cv && cv.Conversion.IsIdentity) { op = p; p = p.Parent; }
        if (p is IParenthesizedOperation) { op = p; p = p.Parent; }
        return p is IArgumentOperation a && a.Parameter != null && a.Parameter.RefKind is RefKind.Ref or RefKind.Out or RefKind.In
            || p is IVariableInitializerOperation vi && vi.Parent is IVariableDeclaratorOperation vd && vd.Symbol.RefKind != RefKind.None
            || p is IReturnOperation r && IsRefReturn(r)
            || p is ISimpleAssignmentOperation sa && sa.IsRef && sa.Value == op
            || p is IConditionalOperation c && c.IsRef && c.Condition != op;
    }

    // ------------------------------------------------------------------------------------------------ written fields
    static Dictionary<IMethodSymbol, int>? methodIndex;
    static List<System.Collections.BitArray>? transWrites;
    static readonly Dictionary<IFieldSymbol, int> fieldIndex = new(SymbolEqualityComparer.Default);
    static System.Collections.BitArray? escapingWrites;

    static int FieldNo(IFieldSymbol f)
    {
        f = f.OriginalDefinition;
        if (!fieldIndex.TryGetValue(f, out var k)) { k = fieldIndex.Count; fieldIndex[f] = k; }
        return k;
    }

    static IEnumerable<IOperation> BodiesOf(IMethodSymbol m)
    {
        foreach (var sr in m.OriginalDefinition.DeclaringSyntaxReferences)
        {
            var syn = sr.GetSyntax();
            if (syn is BaseMethodDeclarationSyntax bm)
            {
                if (bm.Body != null && M(bm).GetOperation(bm.Body) is IOperation b) yield return b;
                else if (bm.ExpressionBody != null && M(bm).GetOperation(bm.ExpressionBody) is IOperation e) yield return e;
                if (bm is ConstructorDeclarationSyntax cd && cd.Initializer != null && M(cd).GetOperation(cd.Initializer) is IOperation ci) yield return ci;
            }
        }
    }

    static (List<int> writes, List<IMethodSymbol> calls, bool dlg) Effects(IOperation root)
    {
        var w = new List<int>(); var c = new List<IMethodSymbol>(); bool dlg = false;
        foreach (var d in root.DescendantsAndSelf())
        {
            switch (d)
            {
                case IAssignmentOperation a when StripConvS(a.Target) is IFieldReferenceOperation f: w.Add(FieldNo(f.Field)); break;
                case IIncrementOrDecrementOperation i when StripConvS(i.Target) is IFieldReferenceOperation f2: w.Add(FieldNo(f2.Field)); break;
                case IArgumentOperation arg when arg.Parameter != null && arg.Parameter.RefKind != RefKind.None && StripConvS(arg.Value) is IFieldReferenceOperation f3: w.Add(FieldNo(f3.Field)); break;
                case IInvocationOperation inv:
                    if (inv.TargetMethod.MethodKind == MethodKind.DelegateInvoke) dlg = true;
                    else if (IsEngine(inv.TargetMethod.ContainingType)) c.Add(inv.TargetMethod.OriginalDefinition);
                    else if (inv.Arguments.Any(x => x.Value.Type?.TypeKind == TypeKind.Delegate)) dlg = true;
                    break;
                case IObjectCreationOperation oc when oc.Constructor != null:
                    if (IsEngine(oc.Constructor.ContainingType)) c.Add(oc.Constructor.OriginalDefinition);
                    else if (oc.Arguments.Any(x => x.Value.Type?.TypeKind == TypeKind.Delegate)) dlg = true;
                    break;
            }
        }
        return (w, c, dlg);
    }

    static IOperation StripConvS(IOperation op) { while (op is IConversionOperation cv && cv.Conversion.IsIdentity) op = cv.Operand; return op; }

    static void ComputeWrites()
    {
        var methods = new List<IMethodSymbol>();
        methodIndex = new(SymbolEqualityComparer.Default);
        foreach (var t in engineTypes)
            foreach (var m in t.GetMembers().OfType<IMethodSymbol>())
                if (m.DeclaringSyntaxReferences.Length > 0 && !methodIndex.ContainsKey(m.OriginalDefinition)) { methodIndex[m.OriginalDefinition] = methods.Count; methods.Add(m.OriginalDefinition); }
        var overrides = new Dictionary<IMethodSymbol, List<IMethodSymbol>>(SymbolEqualityComparer.Default);
        foreach (var m in methods)
            for (var o = m.OverriddenMethod; o != null; o = o.OverriddenMethod)
            {
                var od = o.OriginalDefinition;
                if (!overrides.TryGetValue(od, out var l)) overrides[od] = l = new List<IMethodSymbol>();
                l.Add(m);
            }
        var eff = new List<(List<int> writes, List<int> calls, bool dlg)>();
        var escW = new List<int>(); var escC = new List<int>(); bool escD = false;
        void AddCalls(List<IMethodSymbol> c, List<int> into)
        {
            foreach (var cm in c)
            {
                if (methodIndex!.TryGetValue(cm, out var k)) into.Add(k);
                if (overrides.TryGetValue(cm, out var ol)) foreach (var x in ol) if (methodIndex.TryGetValue(x, out var k2)) into.Add(k2);
            }
        }
        foreach (var m in methods)
        {
            var ws = new List<int>(); var cs = new List<int>(); bool dlg = false;
            foreach (var body in BodiesOf(m))
            {
                var (w, c, d) = Effects(body);
                ws.AddRange(w); dlg |= d;
                AddCalls(c, cs);
                foreach (var d2 in body.Descendants())
                {
                    if (d2 is IMethodReferenceOperation mr && methodIndex.TryGetValue(mr.Method.OriginalDefinition, out var k3)) escC.Add(k3);
                    if (d2 is IAnonymousFunctionOperation af)
                    {
                        var (lw, lc, ld) = Effects(af.Body);
                        escW.AddRange(lw); escD |= ld; AddCalls(lc, escC);
                    }
                }
            }
            eff.Add((ws, cs, dlg));
        }
        foreach (var t in engineTypes)
            foreach (var f in t.GetMembers().OfType<IFieldSymbol>())
                foreach (var sr in f.DeclaringSyntaxReferences)
                    if (sr.GetSyntax() is VariableDeclaratorSyntax vd && vd.Initializer != null && M(vd).GetOperation(vd.Initializer) is IOperation fo)
                        foreach (var af in fo.Descendants().OfType<IAnonymousFunctionOperation>())
                        {
                            var (lw, lc, ld) = Effects(af.Body);
                            escW.AddRange(lw); escD |= ld; AddCalls(lc, escC);
                        }
        int ESC = methods.Count;
        eff.Add((escW, escC, escD));
        int nf() => fieldIndex.Count + 1;
        var sets = new List<System.Collections.BitArray>();
        for (int i = 0; i < eff.Count; i++) { var b = new System.Collections.BitArray(nf()); foreach (var w in eff[i].writes) b[w] = true; sets.Add(b); }
        bool changed = true;
        int rounds = 0;
        while (changed && rounds++ < 500)
        {
            changed = false;
            for (int i = 0; i < eff.Count; i++)
            {
                var b = (System.Collections.BitArray)sets[i].Clone();
                foreach (var c in eff[i].calls) b.Or(sets[c]);
                if (eff[i].dlg) b.Or(sets[ESC]);
                if (!SameBits(b, sets[i])) { sets[i] = b; changed = true; }
            }
        }
        if (changed) Note("written-field analysis did not converge");
        transWrites = sets;
        escapingWrites = sets[ESC];
    }

    static bool SameBits(System.Collections.BitArray a, System.Collections.BitArray b)
    {
        if (a.Length != b.Length) return false;
        for (int i = 0; i < a.Length; i++) if (a[i] != b[i]) return false;
        return true;
    }

    /// <summary>Whether op may write field f: directly, through a ref argument, or in any method it can reach (the
    /// written-field analysis). A field whose address is taken anywhere (a ref argument) may change through any call.</summary>
    static bool MayWrite(IOperation op, IFieldSymbol f)
    {
        f = f.OriginalDefinition;
        if (methodIndex == null) ComputeWrites();
        if (!fieldIndex.TryGetValue(f, out var fk)) return false;
        var (w, c, d) = Effects(op);
        if (w.Contains(fk)) return true;
        if (d && fk < escapingWrites!.Length && escapingWrites[fk]) return true;
        foreach (var cm in c)
        {
            if (!methodIndex!.TryGetValue(cm, out var k)) return true;
            if (fk < transWrites![k].Length && transWrites[k][fk]) return true;
            foreach (var t in engineTypes)
                foreach (var m in t.GetMembers(cm.Name).OfType<IMethodSymbol>())
                    if (IsOverrideOf(m, cm) && methodIndex.TryGetValue(m.OriginalDefinition, out var k2) && fk < transWrites[k2].Length && transWrites[k2][fk]) return true;
        }
        return false;
    }

    static bool IsRefSym(ISymbol s) => s is ILocalSymbol l && l.RefKind != RefKind.None || s is IParameterSymbol p && p.RefKind != RefKind.None;

    static bool IsInside(ISymbol? s, ISymbol lambda)
    {
        for (var x = s; x != null; x = x.ContainingSymbol) if (SymbolEqualityComparer.Default.Equals(x, lambda)) return true;
        return false;
    }

    static bool IsRefReturn(IReturnOperation r)
    {
        for (var p = r.Parent; p != null; p = p.Parent)
        {
            if (p is IAnonymousFunctionOperation af) return af.Symbol.RefKind != RefKind.None;
            if (p is IMethodBodyOperation || p is IBlockOperation && p.Parent == null) break;
        }
        var sm = r.SemanticModel;
        var md = r.Syntax.Ancestors().OfType<MethodDeclarationSyntax>().FirstOrDefault();
        return md != null && sm != null && sm.GetDeclaredSymbol(md) is IMethodSymbol ms && ms.RefKind != RefKind.None;
    }

    // ------------------------------------------------------------------------------------------------ types
    static readonly HashSet<string> Specializable = new() { "Vec", "Ptr", "Iter", "RevIter", "CSpan", "Opt", "Atomic", "RefAt", "RefGet" };

    static string? PrimCode(ITypeSymbol t)
    {
        if (t.TypeKind == TypeKind.Enum && t is INamedTypeSymbol en) return PrimCode(en.EnumUnderlyingType!);
        return t.SpecialType switch
        {
            SpecialType.System_Double => "D", SpecialType.System_Single => "F",
            SpecialType.System_Int32 or SpecialType.System_UInt32 => "I",
            SpecialType.System_Int64 or SpecialType.System_UInt64 => "L",
            SpecialType.System_Byte or SpecialType.System_SByte => "B",
            SpecialType.System_Boolean => "Z",
            SpecialType.System_Int16 => "S",
            SpecialType.System_UInt16 or SpecialType.System_Char => "C",
            _ => null
        };
    }

    static string RuntimeTypeName(INamedTypeSymbol n)
    {
        var parts = new List<string>();
        for (var c = n; c != null; c = c.ContainingType) parts.Insert(0, StripArity(c.Name));
        var s = string.Join("_", parts);
        if (n.TypeArguments.Length == 1 && Specializable.Contains(StripArity(n.Name)) && PrimCode(n.TypeArguments[0]) is string code) s += code;
        return s;
    }

    static bool SpecializedClass(INamedTypeSymbol t) => t.IsGenericType && t.TypeArguments.Length == 1 && Specializable.Contains(StripArity(t.Name)) && PrimCode(t.TypeArguments[0]) != null;

    static bool IsStructType(ITypeSymbol t) => t.TypeKind == TypeKind.Struct && t.SpecialType == SpecialType.None && !(t is INamedTypeSymbol n && n.OriginalDefinition.SpecialType == SpecialType.System_Nullable_T);

    static bool IsIntegral(ITypeSymbol? t) => t != null && (t.SpecialType is SpecialType.System_Int32 or SpecialType.System_Int64 or SpecialType.System_UInt32 or SpecialType.System_UInt64 or SpecialType.System_Int16 or SpecialType.System_UInt16 or SpecialType.System_SByte or SpecialType.System_Byte or SpecialType.System_Char
        || t.TypeKind == TypeKind.Enum);
    static bool IsUnsigned(ITypeSymbol? t) => t != null && (t.SpecialType is SpecialType.System_UInt32 or SpecialType.System_UInt64 or SpecialType.System_Byte or SpecialType.System_UInt16 or SpecialType.System_Char
        || t.TypeKind == TypeKind.Enum && t is INamedTypeSymbol e && IsUnsigned(e.EnumUnderlyingType));
    static bool IsDouble(ITypeSymbol? t) => t != null && t.SpecialType == SpecialType.System_Double;
    static bool IsSingle(ITypeSymbol? t) => t != null && t.SpecialType == SpecialType.System_Single;
    static bool IsFloat(ITypeSymbol? t) => IsDouble(t) || IsSingle(t);
    static bool IsNumeric(ITypeSymbol? t) => IsFloat(t) || IsIntegral(t);
    static ITypeSymbol Under(ITypeSymbol t) => t.TypeKind == TypeKind.Enum && t is INamedTypeSymbol e ? e.EnumUnderlyingType! : t;
    static bool IsULong(ITypeSymbol? t) => t != null && Under(t).SpecialType == SpecialType.System_UInt64;

    static int Width(ITypeSymbol? t)
    {
        if (t == null) return 0;
        t = Under(t);
        return t.SpecialType switch
        {
            SpecialType.System_Byte or SpecialType.System_SByte => 8, SpecialType.System_Int16 or SpecialType.System_UInt16 or SpecialType.System_Char => 16,
            SpecialType.System_Int32 or SpecialType.System_UInt32 => 32, SpecialType.System_Int64 or SpecialType.System_UInt64 => 64, _ => 0
        };
    }

    /// <summary>The Lua expression that reduces integer x to the value range of type t (C#'s unchecked wrap-around).
    /// A Lua integer is 64 bits wide and its + - * and &lt;&lt; wrap modulo 2^64, as a C# long's do, so a 64-bit value needs
    /// no reduction (a ulong is held as the long with the same bits); a narrower one keeps its low bits, and a signed
    /// one is then moved down by the sign bit: ((x + half) &amp; mask) - half.</summary>
    static string WrapInt(string x, ITypeSymbol t)
    {
        int w = Width(t);
        bool u = IsUnsigned(t);
        if (w == 0 || w == 64) return x;
        var mask = w == 32 ? "0xFFFFFFFF" : w == 16 ? "0xFFFF" : "0xFF";
        if (u) return "(" + x + " & " + mask + ")";
        var half = w == 32 ? "0x80000000" : w == 16 ? "0x8000" : "0x80";
        return "(((" + x + " + " + half + ") & " + mask + ") - " + half + ")";
    }

    static string MaskOf(ITypeSymbol t)
    {
        int w = Width(t);
        return w == 64 ? "-1" : w == 32 ? "0xFFFFFFFF" : w == 16 ? "0xFFFF" : "0xFF";
    }

    /// <summary>The value a field, array element or local of type t starts with (C#'s default).</summary>
    static string DefaultOf(ITypeSymbol t)
    {
        if (t.SpecialType == SpecialType.System_Boolean) return "false";
        if (IsFloat(t)) return "0.0";
        if (IsIntegral(t)) return "0";
        if (IsStructType(t) && t is INamedTypeSymbol n)
        {
            if (IsRuntime(n)) return Use(RuntimeTypeName(n) + "_ZERO", "default(" + n.OriginalDefinition.ToDisplayString() + ")" + (SpecializedClass(n) ? " (" + n.TypeArguments[0].ToDisplayString() + ")" : "") + " (a constant)");
            if (IsSystem(n) && n.Name == "ValueTuple") return "nil";
            return Todo("engine struct " + n.Name);
        }
        return "nil";
    }

    static readonly SortedDictionary<string, string> makerConsts = new(StringComparer.Ordinal);

    static string MakerConst(string body)
    {
        foreach (var kv in makerConsts) if (kv.Value == body) return kv.Key;
        var n = "K_MK" + makerConsts.Count;
        makerConsts[n] = body;
        DefineGlobal(n);
        return n;
    }

    /// <summary>An element maker: a function that makes a default T (C#'s Elem&lt;T&gt;.Make).</summary>
    static string Maker(ITypeSymbol t)
    {
        if (t.SpecialType == SpecialType.System_Boolean) return Use("MK_Z", "maker: false");
        if (IsFloat(t)) return Use("MK_D", "maker: 0.0");
        if (IsIntegral(t)) return Use("MK_I", "maker: 0");
        if (IsStructType(t) && t is INamedTypeSymbol sn && IsRuntime(sn)) return Use("MK_" + RuntimeTypeName(sn), "maker: default(" + sn.OriginalDefinition.ToDisplayString() + ")");
        if (t is INamedTypeSymbol n && IsEngine(n) && n.TypeKind == TypeKind.Class && !n.IsAbstract && !n.IsStatic)
        {
            var c = n.InstanceConstructors.FirstOrDefault(k => k.Parameters.Length == 0 && k.DeclaredAccessibility == Accessibility.Public);
            if (c == null) return Use("MK_N", "maker: null");
            return MakerConst("function() return " + CtorCall(c, "") + " end");
        }
        if (t is INamedTypeSymbol r && IsRuntime(r) && r.TypeKind == TypeKind.Class && !r.IsAbstract)
        {
            var ctor = r.InstanceConstructors.FirstOrDefault(k => k.Parameters.Length == 0 && k.DeclaredAccessibility == Accessibility.Public)
                ?? r.InstanceConstructors.FirstOrDefault(k => k.Parameters.Length > 0 && k.Parameters.All(p => p.IsOptional) && k.DeclaredAccessibility == Accessibility.Public);
            if (ctor == null) return Use("MK_N", "maker: null");
            var nm = StripArity(r.Name);
            var fname = RuntimeCtorName(ctor, r);
            var extra = new List<string>();
            if (!SpecializedClass(r) && r.IsGenericType)
            {
                if (ctor.Parameters.Length > 0)
                    foreach (var p in ctor.Parameters)
                        extra.Add(p.Type is INamedTypeSymbol ft && IsSystem(ft) && ft.Name == "Func" && ft.TypeArguments.Length == 1 ? Maker(((INamedTypeSymbol)p.Type).TypeArguments[0]) : "nil");
                else if (makerSlots.TryGetValue(nm, out var slots)) foreach (var k in slots) extra.Add(Maker(r.TypeArguments[k]));
                else if (nm is "Pair" or "Tup") foreach (var ta in r.TypeArguments) extra.Add(Maker(ta));
            }
            Use(fname, "new " + ctor.OriginalDefinition.ToDisplayString() + (SpecializedClass(r) ? " (" + r.TypeArguments[0].ToDisplayString() + ")" : "") + (extra.Count > 0 ? " + makers" : ""));
            if (extra.Count == 0) return fname;
            return MakerConst("function() return " + fname + "(" + string.Join(", ", extra) + ") end");
        }
        return Use("MK_N", "maker: null");
    }

    static readonly Dictionary<string, int[]> makerSlots = new() { ["Vec"] = new[] { 0 }, ["Map"] = new[] { 1 }, ["UMap"] = new[] { 1 }, ["UMapC"] = new[] { 1 } };

    static string RuntimeCtorName(IMethodSymbol c, INamedTypeSymbol t)
    {
        var ctors = t.OriginalDefinition.InstanceConstructors.Where(k => k.DeclaredAccessibility != Accessibility.Private).ToList();
        var sfx = ctors.Count > 1 && c.Parameters.Length > 0 ? "_" + string.Join("_", c.OriginalDefinition.Parameters.Select(p => ShortType(p.Type) + (p.RefKind != RefKind.None ? "r" : ""))) : "";
        return "New" + RuntimeTypeName(t) + sfx;
    }

    // ------------------------------------------------------------------------------------------------ engine constructors
    // An engine object is made in two steps: O_T._new allocates it (a table with every field of its hierarchy at its
    // C# default, whose metatable is the class table: what the protected Raw constructor does), and a constructor with
    // a body is the function O_T.ctor_<Type><sfx> run on it by the factory <Type>__new<sfx>.
    static bool IsRawCtor(IMethodSymbol c) => c.Parameters.Length == 1 && c.Parameters[0].Type.Name == "Raw" && IsRuntime(c.Parameters[0].Type);

    static readonly Dictionary<IMethodSymbol, bool> trivialCtor = new(SymbolEqualityComparer.Default);

    static bool IsTrivialCtor(IMethodSymbol c)
    {
        c = c.OriginalDefinition;
        if (trivialCtor.TryGetValue(c, out var v)) return v;
        trivialCtor[c] = false;
        bool r;
        var decl = c.DeclaringSyntaxReferences.Select(x => x.GetSyntax()).OfType<ConstructorDeclarationSyntax>().FirstOrDefault();
        if (decl == null)
        {
            var b = c.ContainingType.BaseType;
            r = b == null || !IsEngine(b) || b.InstanceConstructors.Where(k => k.Parameters.Length == 0).All(IsTrivialCtor);
            if (HasInstanceFieldInits(c.ContainingType)) r = false;
        }
        else
        {
            bool emptyBody = decl.Body == null ? decl.ExpressionBody == null : decl.Body.Statements.Count == 0;
            r = emptyBody && !HasInstanceFieldInits(c.ContainingType);
            if (r && decl.Initializer != null)
            {
                var init = M(decl).GetOperation(decl.Initializer);
                var inv = init is IExpressionStatementOperation es ? es.Operation : init;
                if (inv is IInvocationOperation ci)
                {
                    var target = ci.TargetMethod;
                    if (IsEngine(target.ContainingType)) r = IsTrivialCtor(target);
                    else r = IsRawCtor(target) || target.Parameters.Length == 0;
                }
                else r = false;
            }
            else if (r && c.ContainingType.BaseType is INamedTypeSymbol bt && IsEngine(bt))
                r = bt.InstanceConstructors.Where(k => k.Parameters.Length == 0).All(IsTrivialCtor);
        }
        trivialCtor[c] = r;
        return r;
    }

    static bool HasInstanceFieldInits(INamedTypeSymbol t) =>
        t.GetMembers().OfType<IFieldSymbol>().Any(f => !f.IsStatic && !f.IsConst && f.DeclaringSyntaxReferences.Select(r => r.GetSyntax()).OfType<VariableDeclaratorSyntax>().Any(v => v.Initializer != null));

    static string CtorSuffix(IMethodSymbol c)
    {
        if (c.Parameters.Length == 0) return "";
        return "_" + string.Join("_", c.Parameters.Select(p => ShortType(p.Type) + (p.RefKind != RefKind.None ? "r" : "")));
    }

    static string CtorMethod(IMethodSymbol c) => ClassConst(c.ContainingType) + ".ctor_" + TypeIdent(c.ContainingType) + CtorSuffix(c);

    /// <summary>C#'s new T(args) for engine constructor c, with the argument text.</summary>
    static string CtorCall(IMethodSymbol c, string args)
    {
        var t = c.ContainingType;
        if (IsTrivialCtor(c)) { var ia = InlineAlloc(t, 12); return ia ?? ClassConst(t) + "._new()"; }
        return TypeIdent(t) + "__new" + CtorSuffix(c) + "(" + args + ")";
    }

    static List<IFieldSymbol> AllFields(INamedTypeSymbol s)
    {
        var all = new List<IFieldSymbol>();
        for (var c = s; c != null && IsEngine(c); c = c.BaseType) all.InsertRange(0, c.GetMembers().OfType<IFieldSymbol>().Where(f => !f.IsImplicitlyDeclared && !f.IsStatic && !f.IsConst));
        return all;
    }

    /// <summary>The allocation O_T._new does, as an expression (a table of the field defaults with the class as its
    /// metatable), for a type with no runtime base class and at most maxFields fields; else null.</summary>
    static string? InlineAlloc(INamedTypeSymbol s, int maxFields)
    {
        for (var c = s.BaseType; c != null; c = c.BaseType)
        {
            if (c.SpecialType == SpecialType.System_Object) break;
            if (IsRuntime(c) || IsSystem(c) && c.Name == "Exception") return null;
        }
        var all = AllFields(s);
        if (all.Count > maxFields) return null;
        var inits = all.Select(f => (FieldIdent(f), DefaultOf(f.Type))).Where(x => x.Item2 != "nil").Select(x => x.Item1 + " = " + x.Item2);
        return "L_setmetatable({" + string.Join(", ", inits) + "}, " + ClassConst(s) + ")";
    }

    // ------------------------------------------------------------------------------------------------ the file
    static readonly StringBuilder classText = new();
    static readonly StringBuilder funcText = new();
    static readonly List<(INamedTypeSymbol owner, string text, int order)> staticInits = new();
    static readonly List<string> staticDefaults = new();
    static readonly SortedDictionary<string, string> moduleConsts = new(StringComparer.Ordinal);

    /// <summary>The standard library functions the engine file uses, captured as chunk locals (L_name) before the
    /// chunk's _ENV becomes the runtime's environment.</summary>
    static readonly string[] StdAliases =
    {
        "setmetatable", "getmetatable", "error", "pcall", "type", "rawget", "rawequal", "select", "tostring"
    };

    /// <summary>Runtime globals the engine file calls often enough to be worth a chunk local (an upvalue read instead
    /// of a lookup in the environment): name in the file, runtime global.</summary>
    static readonly (string local, string global)[] HotAliases =
    {
        ("L_idiv", "idiv"), ("L_imod", "imod"), ("L_fmod", "L_math_fmod"), ("L_sqrt", "L_math_sqrt"), ("L_abs", "L_math_abs"),
        ("L_exp", "L_math_exp"), ("L_log", "Math_Log_d"), ("L_pow", "Math_Pow_d"), ("L_floor", "Math_Floor_d"),
        ("L_ceil", "Math_Ceiling_d"), ("L_f32", "f32"), ("L_isa", "isa_"), ("L_i2d", "i2d"), ("L_sar", "sar"),
        ("L_ult", "ult"), ("L_deref2", "deref2"), ("L_newA", "newA"), ("L_cell", "cell"), ("L_bAnd", "bAnd"),
        ("L_bOr", "bOr"), ("L_bXor", "bXor"), ("L_excof", "exc_of"), ("L_tostr_d", "cs_tostring_d"), ("L_tostr", "cs_tostring"),
        ("L_chr", "cs_chr"), ("L_elems", "elems"), ("L_f2i32", "f2i32"), ("L_f2i64", "f2i64"),
        ("L_udiv", "udiv64"), ("L_umod", "umod64"), ("L_u2d", "u2d"), ("L_sin", "L_math_sin"), ("L_cos", "L_math_cos")
    };

    static string Module(List<SyntaxTree> gen)
    {
        var classes = engineTypes.Where(IsClassEmitted).ToList();
        var order = new List<INamedTypeSymbol>();
        var done = new HashSet<INamedTypeSymbol>(SymbolEqualityComparer.Default);
        void Visit(INamedTypeSymbol c)
        {
            if (done.Contains(c)) return;
            done.Add(c);
            if (c.BaseType is INamedTypeSymbol b && IsEngine(b) && IsClassEmitted(b.OriginalDefinition)) Visit(b.OriginalDefinition);
            order.Add(c);
        }
        foreach (var c in classes) Visit(c);
        foreach (var s in order)
        {
            try { ClassDecl(s); }
            catch (Todo e) { classText.Append("-- TODO class ").Append(ClassConst(s)).Append(": ").Append(e.Message).Append('\n'); }
        }
        foreach (var s in engineTypes.Where(t => t.TypeKind == TypeKind.Class && t.IsStatic))
        {
            try { StaticMembers(s); }
            catch (Todo e) { funcText.Append("-- TODO static class ").Append(TypeIdent(s)).Append(": ").Append(e.Message).Append('\n'); }
        }
        foreach (var s in engineTypes.Where(t => t.TypeKind != TypeKind.Class && t.TypeKind != TypeKind.Enum && t.TypeKind != TypeKind.Delegate))
            Note("type kind " + s.TypeKind + " " + s.Name);

        var sb = new StringBuilder();
        sb.Append("-- Code generated by tools/cs2x/Cs2Lua.cs from cs/gen and cs/runtime/Hand_*.cs. DO NOT EDIT.\n");
        sb.Append("-- The OpenSWMM 6 engine (C++, Caleb Buahin and the OpenSWMM contributors; Apache-2.0, HydroCouple Developers)\n");
        sb.Append("-- translated mechanically C++ -> C# -> Lua 5.4. It runs on the runtime in lua/rt, whose environment (every\n");
        sb.Append("-- runtime global) is this chunk's _ENV; the engine's classes, functions and static fields become globals of it.\n");
        sb.Append("-- Written by Claude (Anthropic) for Robert Dickinson; see AI-USE.md.\n");
        sb.Append("local ").Append(string.Join(", ", StdAliases.Select(a => "L_" + a))).Append(" = ").Append(string.Join(", ", StdAliases)).Append('\n');
        sb.Append("local _ENV = ...\n");
        sb.Append("local ").Append(string.Join(", ", HotAliases.Select(a => a.local))).Append(" = ").Append(string.Join(", ", HotAliases.Select(a => a.global))).Append('\n');
        foreach (var a in HotAliases) Use(a.global, "chunk alias " + a.local);
        foreach (var kv in moduleConsts) sb.Append(kv.Key).Append(" = ").Append(kv.Value).Append('\n');
        sb.Append("\n-- ---------------------------------------------------------------- classes\n\n");
        sb.Append(classText);
        sb.Append("\n-- ---------------------------------------------------------------- functions\n\n");
        sb.Append(funcText);
        sb.Append("\n-- ---------------------------------------------------------------- methods inherited (copied down), element makers\n\n");
        sb.Append(Use("inherit_all", "copy each class's inherited methods into its table (base classes first)")).Append("()\n");
        foreach (var kv in makerConsts) sb.Append(kv.Key).Append(" = ").Append(kv.Value).Append('\n');
        sb.Append("\n-- ---------------------------------------------------------------- static fields\n\n");
        foreach (var d in staticDefaults) sb.Append(d).Append('\n');
        sb.Append("\n\n-- ---------------------------------------------------------------- static initialisation\n\n");
        foreach (var (owner, text, _) in OrderStaticInits()) sb.Append(text).Append('\n');
        return sb.ToString();
    }

    static readonly List<string> classOrder = new();

    static void ClassDecl(INamedTypeSymbol s)
    {
        var nm = ClassConst(s);
        DefineGlobal(nm);
        string baseText = "nil";
        string? runtimeBase = null;
        var ifaces = new List<string>();
        var b = s.BaseType;
        if (b != null && b.SpecialType != SpecialType.System_Object)
        {
            if (IsEngine(b)) baseText = ClassConst(b);
            else if (IsRuntime(b)) { runtimeBase = UseC(RuntimeTypeName(b), "type " + b.OriginalDefinition.ToDisplayString() + " (an engine base class: _alloc(class) makes its object)"); baseText = runtimeBase; }
            else if (IsSystem(b) && b.Name == "Exception") { runtimeBase = UseC("CppException", "type Cpp.CppException"); baseText = runtimeBase; }
            else Note("base type " + b.ToDisplayString());
        }
        for (var c = b; c != null && runtimeBase == null; c = c.BaseType)
        {
            if (c.SpecialType == SpecialType.System_Object) break;
            if (IsRuntime(c)) runtimeBase = "Cpp_" + RuntimeTypeName(c);
            else if (IsSystem(c) && c.Name == "Exception") runtimeBase = "Cpp_CppException";
        }
        foreach (var i in s.Interfaces)
        {
            if (b != null && b.AllInterfaces.Contains(i)) continue;
            if (IsRuntime(i)) ifaces.Add(UseC(StripArity(i.Name), "interface " + i.OriginalDefinition.ToDisplayString() + " (a marker in the class's __isa)"));
            else if (IsSystem(i) && i.Name == "IDisposable") ifaces.Add(UseC("IDisposable", "interface System.IDisposable (a marker in the class's __isa)"));
            else if (IsSystem(i)) { }
            else Note("interface " + i.ToDisplayString());
        }
        var sb = classText;
        sb.Append("-- ---- ").Append(nm).Append('\n');
        sb.Append(nm).Append(" = ").Append(Use("lua_class", "make a class table (__index, __name, __isa, __base)")).Append("(\"").Append(TypeIdent(s)).Append("\", ").Append(baseText)
            .Append(ifaces.Count > 0 ? ", {" + string.Join(", ", ifaces.Distinct()) + "}" : "").Append(")\n");
        var all = AllFields(s);
        if (runtimeBase != null)
        {
            sb.Append("function ").Append(nm).Append("._new() local o = ").Append(runtimeBase).Append("._alloc(").Append(nm).Append(")");
            foreach (var f in all) { var d = DefaultOf(f.Type); if (d != "nil") sb.Append("; o.").Append(FieldIdent(f)).Append(" = ").Append(d); }
            sb.Append("; return o end\n");
        }
        else
        {
            var inits = all.Select(f => (FieldIdent(f), DefaultOf(f.Type))).Where(x => x.Item2 != "nil").Select(x => x.Item1 + " = " + x.Item2);
            sb.Append("function ").Append(nm).Append("._new() return L_setmetatable({").Append(string.Join(", ", inits)).Append("}, ").Append(nm).Append(") end\n");
        }
        foreach (var f in s.GetMembers().OfType<IFieldSymbol>().Where(f => !f.IsImplicitlyDeclared && (f.IsStatic || f.IsConst)))
        {
            try { StaticField(f); }
            catch (Todo e) { staticDefaults.Add("-- TODO field " + f.Name + ": " + e.Message); }
        }
        var decls = s.DeclaringSyntaxReferences.Select(r => r.GetSyntax()).OfType<ClassDeclarationSyntax>().ToList();
        foreach (var cd in decls)
            foreach (var m in cd.Members)
            {
                try
                {
                    switch (m)
                    {
                        case MethodDeclarationSyntax md: MethodDecl(md, s); break;
                        case ConstructorDeclarationSyntax ctor: CtorDecl(ctor, s); break;
                        case FieldDeclarationSyntax: break;
                        case BaseTypeDeclarationSyntax: break;
                        case DelegateDeclarationSyntax: break;
                        default: sb.Append("-- TODO member ").Append(m.Kind()).Append('\n'); Note("member " + m.Kind()); break;
                    }
                }
                catch (Todo e) { sb.Append("-- TODO ").Append(e.Message).Append('\n'); }
                catch (Exception e) when (e is not global::Todo) { sb.Append("-- TODO translator error: ").Append(e.GetType().Name).Append(' ').Append(e.Message.Replace("\n", " ")).Append('\n'); Note("translator error " + e.GetType().Name + ": " + e.Message.Split('\n')[0]); }
            }
        if (!decls.SelectMany(d => d.Members).OfType<ConstructorDeclarationSyntax>().Any(c => !c.Modifiers.Any(SyntaxKind.StaticKeyword)))
            foreach (var c in s.InstanceConstructors.Where(c => c.IsImplicitlyDeclared && !IsTrivialCtor(c)))
                Note("implicit constructor with work " + s.Name);
        sb.Append('\n');
    }

    static void StaticMembers(INamedTypeSymbol s)
    {
        foreach (var f in s.GetMembers().OfType<IFieldSymbol>().Where(f => !f.IsImplicitlyDeclared))
        {
            try { StaticField(f); }
            catch (Todo e) { staticDefaults.Add("-- TODO field " + f.Name + ": " + e.Message); }
        }
        var decls = s.DeclaringSyntaxReferences.Select(r => r.GetSyntax()).OfType<ClassDeclarationSyntax>().ToList();
        foreach (var cd in decls)
            foreach (var m in cd.Members)
            {
                try
                {
                    switch (m)
                    {
                        case MethodDeclarationSyntax md: MethodDecl(md, s); break;
                        case ConstructorDeclarationSyntax ctor: CtorDecl(ctor, s); break;
                        case FieldDeclarationSyntax: break;
                        case BaseTypeDeclarationSyntax: break;
                        case DelegateDeclarationSyntax: break;
                        default: funcText.Append("-- TODO member ").Append(m.Kind()).Append('\n'); Note("member " + m.Kind()); break;
                    }
                }
                catch (Todo e) { funcText.Append("-- TODO ").Append(e.Message).Append('\n'); }
                catch (Exception e) when (e is not global::Todo) { funcText.Append("-- TODO translator error: ").Append(e.GetType().Name).Append(' ').Append(e.Message.Replace("\n", " ")).Append('\n'); Note("translator error " + e.GetType().Name + ": " + e.Message.Split('\n')[0]); }
            }
    }

    static int staticOrder;

    static void StaticField(IFieldSymbol f)
    {
        var name = StaticFieldName(f);
        DefineGlobal(name);
        if (f.IsConst)
        {
            staticDefaults.Add(name + " = " + LuaFn.Const(f.ConstantValue, f.Type));
            return;
        }
        var d0 = DefaultOf(f.Type);
        staticDefaults.Add(d0 == "nil" ? Use("declare_global", "declare a global whose value starts as nil (the strict guard lets it be read)") + "(\"" + name + "\")" : name + " = " + d0);
        var syn = f.DeclaringSyntaxReferences.Select(r => r.GetSyntax()).OfType<VariableDeclaratorSyntax>().FirstOrDefault();
        if (syn?.Initializer == null) return;
        var op = M(syn).GetOperation(syn.Initializer) is IFieldInitializerOperation fi ? fi.Value : M(syn).GetOperation(syn.Initializer.Value);
        if (op == null) { Todo("field initializer"); return; }
        var fn = new LuaFn(null, f.ContainingType, 1);
        var lines = new List<string>();
        try
        {
            var val = fn.ValueOf(op, f.Type);
            if (fn.Pre.Count == 0 && LuaFn.IsLiteral(val) && d0 != "nil")
            {
                staticDefaults[^1] = name + " = " + LuaFn.StripPub(val);
                return;
            }
            fn.FlushTo(lines, 1);
            lines.Add("  " + name + " = " + LuaFn.StripPub(val));
        }
        catch (Todo e) { lines.Add("  " + LuaFn.TodoThrow(e.Message)); }
        var text = "do -- " + name + "\n" + fn.FuncPrologue(1) + string.Concat(lines.Select(l => l + "\n")) + "end\n";
        staticInits.Add((f.ContainingType, text, staticOrder++));
        fn.CollectDeps(op, f.ContainingType);
        initDeps[(f.ContainingType, staticOrder - 1)] = fn.Deps;
    }

    static readonly Dictionary<(INamedTypeSymbol, int), HashSet<INamedTypeSymbol>> initDeps = new();

    static List<(INamedTypeSymbol owner, string text, int order)> OrderStaticInits()
    {
        var byClass = staticInits.GroupBy(x => x.owner, SymbolEqualityComparer.Default).Select(g => (owner: (INamedTypeSymbol)g.Key!, items: g.OrderBy(x => x.order).ToList())).ToList();
        var first = byClass.ToDictionary(x => x.owner, x => x.items[0].order, SymbolEqualityComparer.Default);
        var deps = new Dictionary<INamedTypeSymbol, HashSet<INamedTypeSymbol>>(SymbolEqualityComparer.Default);
        foreach (var (owner, items) in byClass)
        {
            var d = new HashSet<INamedTypeSymbol>(SymbolEqualityComparer.Default);
            foreach (var it in items)
                if (initDeps.TryGetValue((owner, it.order), out var ds)) foreach (var x in ds) if (!SymbolEqualityComparer.Default.Equals(x, owner) && first.ContainsKey(x)) d.Add(x);
            deps[owner] = d;
        }
        var outv = new List<(INamedTypeSymbol, string, int)>();
        var state = new Dictionary<INamedTypeSymbol, int>(SymbolEqualityComparer.Default);
        void Visit(INamedTypeSymbol c)
        {
            if (state.TryGetValue(c, out var st)) { if (st == 1) Note("static initialisation cycle (declaration order kept) " + c.Name); return; }
            state[c] = 1;
            foreach (var d in deps[c].OrderBy(x => first[x])) Visit(d);
            state[c] = 2;
            outv.AddRange(byClass.First(x => SymbolEqualityComparer.Default.Equals(x.owner, c)).items);
        }
        foreach (var (owner, _) in byClass.OrderBy(x => x.items[0].order)) Visit(owner);
        return outv;
    }

    static void MethodDecl(MethodDeclarationSyntax md, INamedTypeSymbol s)
    {
        var m = (IMethodSymbol)M(md).GetDeclaredSymbol(md)!;
        var inClass = !m.IsStatic && IsClassEmitted(s);
        var fn = new LuaFn(m, s, 1);
        var ps = new List<string>();
        if (!m.IsStatic) ps.Add("self");
        foreach (var p in m.Parameters) ps.AddRange(fn.DeclareParam(p));
        string name;
        if (m.IsStatic) { name = StaticFuncName(m); DefineGlobal(name); }
        else name = ClassConst(s) + "." + MethodIdent(m);
        var head = "function " + name + "(" + string.Join(", ", ps) + ")\n";
        string body;
        if (m.IsAbstract) body = "  " + LuaFn.TodoThrow("abstract method " + m.Name) + "\n";
        else
        {
            IOperation? op = md.Body != null ? M(md).GetOperation(md.Body) : md.ExpressionBody != null ? M(md).GetOperation(md.ExpressionBody) : null;
            try { body = op == null ? "" : fn.Body(op, m); }
            catch (Todo e) { body = "  " + LuaFn.TodoThrow(e.Message) + "\n"; }
            body = fn.FuncPrologue(1) + body;
        }
        var text = head + body + "end\n";
        if (inClass) classText.Append(text);
        else funcText.Append(text);
    }

    static void CtorDecl(ConstructorDeclarationSyntax cd, INamedTypeSymbol s)
    {
        var c = (IMethodSymbol)M(cd).GetDeclaredSymbol(cd)!;
        if (c.IsStatic)
        {
            var fn0 = new LuaFn(c, s, 1);
            var body0 = cd.Body != null ? fn0.Body(M(cd).GetOperation(cd.Body)!, c) : "";
            var text0 = "do -- static constructor of " + TypeIdent(s) + "\n" + fn0.FuncPrologue(1) + body0 + "end\n";
            staticInits.Add((s, text0, staticOrder++));
            fn0.CollectDeps(M(cd).GetOperation(cd.Body!)!, s);
            initDeps[(s, staticOrder - 1)] = fn0.Deps;
            return;
        }
        if (IsTrivialCtor(c)) return;
        if (IsRawCtor(c)) { Note("raw constructor with a body " + s.Name); return; }
        var fn = new LuaFn(c, s, 1);
        var ps = new List<string> { "self" };
        foreach (var p in c.Parameters) ps.AddRange(fn.DeclareParam(p));
        var lines = new List<string>();
        if (cd.Initializer != null && M(cd).GetOperation(cd.Initializer) is IOperation init)
        {
            var inv = init is IExpressionStatementOperation es ? es.Operation : init;
            if (inv is IInvocationOperation ci)
            {
                var target = ci.TargetMethod;
                if (IsEngine(target.ContainingType))
                {
                    if (!IsTrivialCtor(target))
                    {
                        var args = fn.ArgList(target, ci.Arguments);
                        fn.FlushTo(lines, 1);
                        lines.Add("  " + CtorMethod(target) + "(self" + (args.Length > 0 ? ", " + args : "") + ")");
                    }
                }
                else if (IsRuntime(target.ContainingType) && !IsRawCtor(target) && target.Parameters.Length > 0)
                {
                    var args = fn.ArgList(target, ci.Arguments);
                    fn.FlushTo(lines, 1);
                    var mn = UseM("_ctor" + CtorSuffix(target), "constructor " + target.ToDisplayString() + " run on an allocated object of an engine class derived from " + RuntimeTypeName(target.ContainingType));
                    lines.Add("  self:" + mn + "(" + args + ")");
                }
            }
            else Todo("constructor initializer " + inv.Kind);
        }
        var body = cd.Body != null ? fn.Body(M(cd).GetOperation(cd.Body)!, c) : "";
        var cm = CtorMethod(c);
        classText.Append("function ").Append(cm).Append("(").Append(string.Join(", ", ps)).Append(")\n").Append(fn.FuncPrologue(1));
        foreach (var l in lines) classText.Append(l).Append('\n');
        classText.Append(body);
        classText.Append("end\n");
        if (HasInstanceFieldInits(s)) Note("instance field initializer (not translated) in " + s.Name);
        var tn = TypeIdent(s);
        var fname = tn + "__new" + CtorSuffix(c);
        engineFunctions.Add(fname);
        DefineGlobal(fname);
        funcText.Append("function ").Append(fname).Append("(...) local o = ").Append(InlineAlloc(s, 1000) ?? ClassConst(s) + "._new()").Append("; ").Append(cm).Append("(o, ...); return o end\n");
    }
}
