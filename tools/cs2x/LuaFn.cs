// LuaFn.cs - method bodies: C# statements and expressions (Roslyn IOperation trees) to Lua 5.4.
// Begun from PlFn.cs (the Perl back end's walk of the same trees); what changed for Lua is listed in LUA.md.
// Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see AI-USE.md and lua/README.md.
//
// Numbers: a C# integer is a Lua integer (64-bit, wrapping as a C# long does; a ulong is the long with its bits) in its
// type's value range ("clean"); an expression whose value may lie outside it ("raw") is reduced only where it is
// stored or used by an operation whose result depends on the width. A double is a Lua float, always: an int converted
// to double ("xint") stays a Lua integer only while Lua's mixed arithmetic converts it exactly (one float operand),
// and is made a float (x + 0.0) wherever it is stored, passed, returned or meets another xint.
// References: a C# ref is a pair of values, a table and a key (t, k), passed as two arguments; *r is t[k]. A local
// whose address is taken lives in a one-element table (a cell, x[1]).
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;
using Microsoft.CodeAnalysis.Operations;

public static partial class Cs2Lua
{
    /// <summary>A translated expression: its text (atomic or parenthesised), whether an integer value may lie outside
    /// its type's range, and whether it is a Lua integer standing for a C# double.</summary>
    public readonly struct Ex
    {
        public readonly string S;
        public readonly bool Raw;
        public readonly bool XInt;
        public Ex(string s, bool raw = false, bool xint = false) { S = s; Raw = raw; XInt = xint; }
        public static implicit operator Ex(string s) => new Ex(s);
        public static implicit operator string(Ex e) => e.S;
        public override string ToString() => S;
    }

    /// <summary>A reference: the table and the key (Lua texts).</summary>
    public readonly struct RefX
    {
        public readonly string T, K;
        public RefX(string t, string k) { T = t; K = k; }
        public string Deref => (LuaFn.IsPrefix(T) ? T : "(" + T + ")") + "[" + K + "]";
        public string Pair => T + ", " + K;
    }

    static HashSet<INamedTypeSymbol> StaticDeps(IOperation root)
    {
        var res = new HashSet<INamedTypeSymbol>(SymbolEqualityComparer.Default);
        var seen = new HashSet<IMethodSymbol>(SymbolEqualityComparer.Default);
        var work = new Stack<IOperation>();
        work.Push(root);
        while (work.Count > 0)
        {
            var op = work.Pop();
            foreach (var d in op.DescendantsAndSelf())
            {
                IMethodSymbol? callee = null;
                switch (d)
                {
                    case IFieldReferenceOperation fr when fr.Field.IsStatic && !fr.Field.IsConst && IsEngine(fr.Field.ContainingType):
                        res.Add(fr.Field.ContainingType.OriginalDefinition); break;
                    case IInvocationOperation inv: callee = inv.TargetMethod; break;
                    case IObjectCreationOperation oc: callee = oc.Constructor; break;
                    case IMethodReferenceOperation mr: callee = mr.Method; break;
                }
                if (callee == null || !IsEngine(callee.ContainingType)) continue;
                callee = callee.OriginalDefinition;
                if (!seen.Add(callee)) continue;
                foreach (var sr in callee.DeclaringSyntaxReferences)
                {
                    var syn = sr.GetSyntax();
                    IOperation? body = syn switch
                    {
                        BaseMethodDeclarationSyntax bm => bm.Body != null ? M(bm).GetOperation(bm.Body) : bm.ExpressionBody != null ? M(bm).GetOperation(bm.ExpressionBody) : null,
                        _ => null
                    };
                    if (body != null) work.Push(body);
                }
            }
        }
        return res;
    }

    static readonly SortedDictionary<string, string> doubleLits = new(StringComparer.Ordinal);

public sealed class LuaFn
{
    readonly IMethodSymbol? method;
    readonly INamedTypeSymbol cls;
    public List<string> Pre = new();
    readonly Dictionary<ISymbol, string> names;
    readonly HashSet<string> used;
    readonly int[] tmp;
    readonly List<string> temps = new();
    readonly LuaFn? parent;
    ITypeSymbol? retType;
    bool retRef;
    readonly int baseInd;
    public HashSet<INamedTypeSymbol> Deps = new(SymbolEqualityComparer.Default);
    readonly HashSet<ISymbol> refByValue;
    readonly HashSet<ISymbol> nonNeg;
    readonly HashSet<ISymbol> predeclared;
    readonly List<string> paramCells = new();
    int evalDepth;                      // try bodies (Lua functions run by pcall) of this function around the current statement
    readonly Stack<string> catchVars = new();
    readonly int[] labelNo;
    readonly List<TryCtx> tries = new();

    public LuaFn(IMethodSymbol? m, INamedTypeSymbol c, int ind)
    {
        method = m; cls = c; baseInd = ind;
        names = new(SymbolEqualityComparer.Default); used = new(); tmp = new int[1]; labelNo = new int[1];
        retType = m?.ReturnType; retRef = m != null && m.RefKind != RefKind.None;
        refByValue = new(SymbolEqualityComparer.Default);
        nonNeg = new(SymbolEqualityComparer.Default);
        predeclared = new(SymbolEqualityComparer.Default);
    }

    LuaFn(LuaFn par, IMethodSymbol lambda, int ind)
    {
        parent = par;
        method = lambda; cls = par.cls; baseInd = ind;
        names = par.names; used = par.used; tmp = par.tmp; labelNo = par.labelNo;
        retType = lambda.ReturnType; retRef = lambda.RefKind != RefKind.None;
        refByValue = par.refByValue; nonNeg = par.nonNeg; predeclared = par.predeclared;
        selfText = par.selfText;
    }

    public void CollectDeps(IOperation op, INamedTypeSymbol owner) { Deps = StaticDeps(op); }

    public static string TodoExc(string what) => Use("NewSysException", "a .NET exception object (kind, message)") + "(\"NotImplementedException\", " + LuaStr("TODO " + what) + ")";
    public static string TodoThrow(string what) => "L_error(" + TodoExc(what) + ", 0)";

    /// <summary>A temporary: one of the function's pool, which a statement takes from and gives back when it ends
    /// (a temporary lives no longer than the statement that made it), so a function declares only as many as its
    /// deepest statement needs (Lua allows a function 200 locals).</summary>
    string Fresh(string b)
    {
        if (inUse < temps.Count) return temps[inUse++];
        string n;
        do { tmp[0]++; n = "t_" + tmp[0]; } while (used.Contains(n));
        used.Add(n);
        temps.Add(n);
        inUse++;
        return n;
    }

    int inUse;

    string NewLabel(string b) { labelNo[0]++; return b + labelNo[0]; }

    string Declare(ISymbol s, string name)
    {
        var n = LocalIdent(name);
        var b = n; int k = 2;
        while (used.Contains(n) || used.Contains(n + "_k")) n = b + "_" + k++;
        used.Add(n); used.Add(n + "_k");
        names[s] = n;
        return n;
    }

    static bool IsCell(ISymbol s) => addrTaken.Contains(s);

    /// <summary>The Lua parameter names of a C# parameter: a ref, out or in parameter is two (the table and the key);
    /// a parameter whose address is taken arrives as a value and is put in a cell by the prologue.</summary>
    public List<string> DeclareParam(IParameterSymbol p)
    {
        var n = Declare(p, p.Name);
        if (p.RefKind != RefKind.None) return new List<string> { n, n + "_k" };
        if (IsCell(p))
        {
            var pin = n + "_in";
            used.Add(pin);
            paramCells.Add("local " + n + " = {" + pin + "}");
            return new List<string> { pin };
        }
        return new List<string> { n };
    }

    /// <summary>The cells of parameters whose address is taken, and the temporaries, declared first in the function.</summary>
    public string FuncPrologue(int ind)
    {
        var sb = new StringBuilder();
        foreach (var c in paramCells) sb.Append(Ind(ind)).Append(c).Append('\n');
        for (int i = 0; i < temps.Count; i += 40)
            sb.Append(Ind(ind)).Append("local ").Append(string.Join(", ", temps.Skip(i).Take(40))).Append('\n');
        return sb.ToString();
    }

    static string Ind(int n) => new string(' ', 2 * n);

    public void FlushTo(List<string> lines, int ind)
    {
        foreach (var p in Pre) foreach (var l in SafeStmt(p).Split('\n')) lines.Add(Ind(ind) + l);
        Pre.Clear();
    }

    /// <summary>A statement line: one that starts with ( is preceded by ; so Lua cannot read it as a call of the
    /// line before.</summary>
    static string SafeStmt(string s) => s.StartsWith("(") ? ";" + s : s;

    // -------------------------------------------------------------------------------------------- statements
    readonly List<Ctx> ctx = new();

    sealed class Ctx
    {
        public bool IsLoop;
        public ILabelSymbol? Exit, Cont;
        public string ContLabel = "";
        public bool ContUsed;
        public string ExitLabel = "";       // a switch's end label (a break that is not the last statement of its case)
        public bool ExitUsed;
        public bool IsSwitch;
        public int EvalDepth;
    }

    sealed class TryCtx
    {
        public int Depth;
        public readonly List<(int id, IBranchOperation br)> Escapes = new();
    }

    public string Body(IOperation op, IMethodSymbol m)
    {
        var lines = new List<string>();
        var ops = op is IBlockOperation b ? b.Operations.ToList() : op is IMethodBodyOperation mb && mb.BlockBody != null ? mb.BlockBody.Operations.ToList() : new List<IOperation> { op };
        if (ops.Count == 1 && !(ops[0] is IBlockOperation) && op is not IBlockOperation && op is not IMethodBodyOperation && m.ReturnsVoid == false && ops[0] is not IReturnOperation)
        {
            // an expression body
            if (retRef)
            {
                var r = RefOf(ops[0]);
                FlushTo(lines, baseInd);
                lines.Add(Ind(baseInd) + "do return " + r.Pair + " end");
            }
            else
            {
                var v = ValueOf(ops[0], retType);
                FlushTo(lines, baseInd);
                lines.Add(Ind(baseInd) + "do return " + Strip(v) + " end");
            }
        }
        else Block(ops, lines, baseInd);
        return string.Concat(lines.Select(l => l + "\n"));
    }

    void Block(IEnumerable<IOperation> ops, List<string> lines, int ind)
    {
        var list = ops.ToList();
        PredeclareForLabels(list, lines, ind);
        for (int i = 0; i < list.Count; i++)
        {
            if (list[i] is IUsingDeclarationOperation ud) { UsingRest(ud, list.Skip(i + 1).ToList(), lines, ind); return; }
            Stmt(list[i], lines, ind);
        }
    }

    /// <summary>A block with a label in it: a Lua goto may not jump into the scope of a local, and C# lets a goto pass
    /// the declarations of locals the code after the label does not read first, so every local the block declares
    /// itself is declared at its start (each declaration below becomes an assignment).</summary>
    void PredeclareForLabels(List<IOperation> list, List<string> lines, int ind)
    {
        if (!list.Any(o => o is ILabeledOperation)) return;
        var locs = new List<ILocalSymbol>();
        foreach (var o in list)
            if (o is IVariableDeclarationGroupOperation g)
                foreach (var d in g.Declarations) foreach (var v in d.Declarators) if (!predeclared.Contains(v.Symbol)) locs.Add(v.Symbol);
        if (locs.Count == 0) return;
        var plain = new List<string>();
        foreach (var l in locs)
        {
            var n = names.TryGetValue(l, out var e) ? e : Declare(l, l.Name);
            predeclared.Add(l);
            if (l.RefKind != RefKind.None) { plain.Add(n); plain.Add(n + "_k"); }
            else if (IsCell(l)) lines.Add(Ind(ind) + "local " + n + " = {" + DefaultOf(l.Type) + "}");
            else plain.Add(n);
        }
        for (int i = 0; i < plain.Count; i += 40) lines.Add(Ind(ind) + "local " + string.Join(", ", plain.Skip(i).Take(40)));
        Stat("locals predeclared for a label");
    }

    void Sub(IOperation op, List<string> lines, int ind)
    {
        if (op is IBlockOperation b) Block(b.Operations, lines, ind);
        else Stmt(op, lines, ind);
    }

    void Stmt(IOperation op, List<string> lines, int ind)
    {
        int n0 = lines.Count;
        int mark = inUse;
        try { StmtInner(op, lines, ind); }
        catch (global::Todo e)
        {
            Pre.Clear();
            if (lines.Count > n0) lines.RemoveRange(n0, lines.Count - n0);
            lines.Add(Ind(ind) + TodoThrow(e.Message));
        }
        finally { inUse = mark; }
    }

    void StmtInner(IOperation op, List<string> lines, int ind)
    {
        var p = Ind(ind);
        switch (op)
        {
            case IBlockOperation b:
                // a nested block is a Lua do ... end block: its locals end with it, as C#'s do
                if (b.Locals.IsEmpty) { Block(b.Operations, lines, ind); return; }
                lines.Add(p + "do");
                Block(b.Operations, lines, ind + 1);
                lines.Add(p + "end");
                return;
            case IVariableDeclarationGroupOperation g:
                foreach (var d in g.Declarations)
                    foreach (var v in d.Declarators) LocalDecl(v, d.Initializer, lines, ind);
                return;
            case IExpressionStatementOperation es:
                {
                    var s = StmtExpr(es.Operation);
                    FlushTo(lines, ind);
                    if (s.Length > 0) foreach (var l in SafeStmt(s).Split('\n')) lines.Add(p + l);
                    return;
                }
            case IReturnOperation r: Return(r, lines, ind); return;
            case IConditionalOperation c: If(c, lines, ind); return;
            case IWhileLoopOperation w: While(w, lines, ind); return;
            case IForLoopOperation f: For(f, lines, ind); return;
            case IForEachLoopOperation fe: ForEach(fe, lines, ind); return;
            case IBranchOperation br: Branch(br, lines, ind); return;
            case ILabeledOperation l:
                lines.Add(p + "::GT_" + LuaIdentBase(l.Label.Name) + "::");
                if (l.Operation != null) Stmt(l.Operation, lines, ind);
                return;
            case ISwitchOperation sw: Switch(sw, lines, ind); return;
            case ITryOperation t: Try(t, lines, ind); return;
            case IUsingOperation: Todo("using"); return;
            case IThrowOperation th:
                {
                    if (th.Exception == null)
                    {
                        if (catchVars.Count == 0) Todo("rethrow outside a catch");
                        lines.Add(p + "L_error(" + catchVars.Peek() + ", 0)");
                        return;
                    }
                    var v = V(th.Exception);
                    FlushTo(lines, ind);
                    lines.Add(p + "L_error(" + Strip(v) + ", 0)");
                    return;
                }
            case IEmptyOperation: return;
            case ILocalFunctionOperation: Todo("local function"); return;
            case ILockOperation lk:
                {
                    var o = V(lk.LockedValue);
                    FlushTo(lines, ind);
                    Sub(lk.Body, lines, ind);
                    return;
                }
        }
        Todo("statement " + op.Kind);
    }

    void LocalDecl(IVariableDeclaratorOperation v, IVariableInitializerOperation? outerInit, List<string> lines, int ind)
    {
        var p = Ind(ind);
        var loc = v.Symbol;
        var init = v.Initializer ?? outerInit;
        bool pre = predeclared.Contains(loc);
        string lc = pre ? "" : "local ";
        if (loc.RefKind != RefKind.None)
        {
            if (init != null && RefLocalByValue(loc, init.Value))
            {
                var val = V(init.Value);
                FlushTo(lines, ind);
                var n0 = names.TryGetValue(loc, out var e0) ? e0 : Declare(loc, loc.Name);
                refByValue.Add(loc);
                lines.Add(p + lc + n0 + " = " + Strip(val));
                return;
            }
            var n = names.TryGetValue(loc, out var e1) ? e1 : Declare(loc, loc.Name);
            if (init == null) { lines.Add(p + lc + n + ", " + n + "_k = nil, nil"); return; }
            var a = RefOf(init.Value);
            FlushTo(lines, ind);
            lines.Add(p + lc + n + ", " + n + "_k = " + a.Pair);
            return;
        }
        string value = init == null ? DefaultOf(loc.Type) : ValueOf(init.Value, loc.Type);
        FlushTo(lines, ind);
        var name = names.TryGetValue(loc, out var existing) ? existing : Declare(loc, loc.Name);
        if (IsCell(loc)) lines.Add(p + (pre ? name + "[1] = " + Strip(value) : "local " + name + " = {" + Strip(value) + "}"));
        else if (init == null && !pre && value == "nil") lines.Add(p + "local " + name);
        else lines.Add(p + lc + name + " = " + Strip(value));
    }

    static bool RefLocalByValue(ILocalSymbol loc, IOperation init)
    {
        if (loc.Type.IsValueType || loc.Type is ITypeParameterSymbol) return false;
        if (!(init is IArrayElementReferenceOperation || init is IPropertyReferenceOperation pr && pr.Property.IsIndexer)) return false;
        var scope = loc.DeclaringSyntaxReferences.FirstOrDefault()?.GetSyntax().Ancestors().OfType<BlockSyntax>().FirstOrDefault();
        if (scope == null) return false;
        var model = M(scope);
        foreach (var id in scope.DescendantNodes().OfType<IdentifierNameSyntax>())
        {
            if (id.Identifier.Text != loc.Name) continue;
            if (!SymbolEqualityComparer.Default.Equals(model.GetSymbolInfo(id).Symbol, loc)) continue;
            var parent = id.Parent;
            if (parent is AssignmentExpressionSyntax asg && asg.Left == id) return false;
            if (parent is PrefixUnaryExpressionSyntax || parent is PostfixUnaryExpressionSyntax) return false;
            if (parent is ArgumentSyntax arg && !arg.RefKindKeyword.IsKind(SyntaxKind.None)) return false;
            if (parent is RefExpressionSyntax) return false;
        }
        return true;
    }

    /// <summary>return v: inside a try body (a function pcall runs) the body returns 1, v to the code after the pcall.</summary>
    void Return(IReturnOperation r, List<string> lines, int ind)
    {
        string? v = null;
        if (r.ReturnedValue != null)
        {
            if (retRef) { var rr = RefOf(r.ReturnedValue); v = rr.Pair; if (evalDepth > 0) Todo("ref return inside a try"); }
            else v = Strip(ValueOf(r.ReturnedValue, retType));
        }
        FlushTo(lines, ind);
        if (evalDepth > 0) lines.Add(Ind(ind) + "do return 1" + (v != null ? ", " + v : "") + " end");
        else lines.Add(Ind(ind) + "do return" + (v != null ? " " + v : "") + " end");
    }

    void If(IConditionalOperation c, List<string> lines, int ind)
    {
        var cond = Cond(c.Condition);
        FlushTo(lines, ind);
        IfRest(c, cond, lines, ind, false);
        lines.Add(Ind(ind) + "end");
    }

    void IfRest(IConditionalOperation c, string cond, List<string> lines, int ind, bool elif)
    {
        var p = Ind(ind);
        lines.Add(p + (elif ? "elseif " : "if ") + Strip(cond) + " then");
        Sub(c.WhenTrue, lines, ind + 1);
        if (c.WhenFalse == null) return;
        var wf = c.WhenFalse;
        while (wf is IBlockOperation bb && bb.Operations.Length == 1 && bb.Locals.IsEmpty && bb.Operations[0] is IConditionalOperation) wf = bb.Operations[0];
        if (wf is IConditionalOperation ec && !ec.IsRef && ec.Type == null)
        {
            var saved = Pre; Pre = new List<string>();
            var c2 = Cond(ec.Condition);
            var pre2 = Pre; Pre = saved;
            if (pre2.Count == 0) { IfRest(ec, c2, lines, ind, true); return; }
            lines.Add(p + "else");
            foreach (var l in pre2) foreach (var l2 in l.Split('\n')) lines.Add(Ind(ind + 1) + l2);
            IfRest(ec, c2, lines, ind + 1, false);
            lines.Add(Ind(ind + 1) + "end");
            return;
        }
        lines.Add(p + "else");
        Sub(c.WhenFalse, lines, ind + 1);
    }

    string Cond(IOperation c) => V(c);

    /// <summary>s without its outer parentheses, where any expression may stand.</summary>
    public static string Strip(string s) => s.Length > 1 && s[0] == '(' && s[^1] == ')' && Balanced(s.Substring(1, s.Length - 2)) && !TopLevelSeq(s.Substring(1, s.Length - 2)) ? s.Substring(1, s.Length - 2) : s;

    /// <summary>Whether s has, outside brackets and strings, a comma.</summary>
    static bool TopLevelSeq(string s)
    {
        int d = 0;
        for (int i = 0; i < s.Length; i++)
        {
            var ch = s[i];
            if (ch == '"' || ch == '\'') { i = SkipStr(s, i); continue; }
            if (ch == '(' || ch == '[' || ch == '{') d++; else if (ch == ')' || ch == ']' || ch == '}') d--;
            else if (d == 0 && ch == ',') return true;
        }
        return false;
    }

    static int SkipStr(string s, int i)
    {
        var q = s[i];
        for (int j = i + 1; j < s.Length; j++) { if (s[j] == '\\') { j++; continue; } if (s[j] == q) return j; }
        return s.Length;
    }

    static bool Balanced(string s)
    {
        int d = 0;
        for (int i = 0; i < s.Length; i++)
        {
            var ch = s[i];
            if (ch == '"' || ch == '\'') { i = SkipStr(s, i); continue; }
            if (ch == '(' || ch == '[' || ch == '{') d++; else if (ch == ')' || ch == ']' || ch == '}') { d--; if (d < 0) return false; }
        }
        return d == 0;
    }

    Ctx PushLoop(ILabelSymbol? exit, ILabelSymbol? cont)
    {
        var c = new Ctx { IsLoop = true, Exit = exit, Cont = cont, ContLabel = NewLabel("cont"), EvalDepth = evalDepth };
        ctx.Add(c);
        return c;
    }

    void PopLoop(Ctx c) => ctx.Remove(c);

    /// <summary>A loop body: a do ... end block, then the continue label when a continue used it (a goto may not jump
    /// into the scope of a local, and the body's locals end with its block).</summary>
    void LoopBody(Ctx lc, IOperation body, List<string> lines, int ind)
    {
        var sub = new List<string>();
        Sub(body, sub, ind + 1);
        if (lc.ContUsed)
        {
            lines.Add(Ind(ind) + "do");
            lines.AddRange(sub);
            lines.Add(Ind(ind) + "end");
            lines.Add(Ind(ind) + "::" + lc.ContLabel + "::");
        }
        else foreach (var l in sub) lines.Add(l.Length >= 2 ? l.Substring(2) : l);
    }

    void While(IWhileLoopOperation w, List<string> lines, int ind)
    {
        var p = Ind(ind);
        if (w.ConditionIsTop)
        {
            var cond = w.Condition == null ? "true" : Cond(w.Condition);
            var lc = PushLoop(w.ExitLabel, w.ContinueLabel);
            if (Pre.Count > 0)
            {
                var pre = new List<string>(Pre); Pre.Clear();
                lines.Add(p + "while true do");
                foreach (var s in pre) foreach (var s2 in s.Split('\n')) lines.Add(Ind(ind + 1) + s2);
                lines.Add(Ind(ind + 1) + "if not " + Paren(cond) + " then break end");
            }
            else lines.Add(p + "while " + Strip(cond) + " do");
            LoopBody(lc, w.Body, lines, ind + 1);
            PopLoop(lc);
            lines.Add(p + "end");
            return;
        }
        // do { body } while (cond): repeat ... until not cond, the condition after the continue label
        var lc2 = PushLoop(w.ExitLabel, w.ContinueLabel);
        lines.Add(p + "repeat");
        var sub = new List<string>();
        Sub(w.Body, sub, ind + 2);
        PopLoop(lc2);
        lines.Add(Ind(ind + 1) + "do");
        lines.AddRange(sub);
        lines.Add(Ind(ind + 1) + "end");
        if (lc2.ContUsed) lines.Add(Ind(ind + 1) + "::" + lc2.ContLabel + "::");
        var c = Cond(w.Condition!);
        FlushTo(lines, ind + 1);
        lines.Add(p + "until not " + Paren(c));
    }

    void For(IForLoopOperation f, List<string> lines, int ind)
    {
        var p = Ind(ind);
        if (RangeFor(f, lines, ind)) return;
        bool block = f.Locals.Length > 0;
        int ib = ind;
        if (block) { lines.Add(p + "do"); ib = ind + 1; }
        var pb = Ind(ib);
        foreach (var b in f.Before) Stmt(b, lines, ib);
        var cond = f.Condition == null ? "true" : Cond(f.Condition);
        var condPre = new List<string>(Pre); Pre.Clear();
        var step = new List<string>();
        foreach (var a in f.AtLoopBottom)
        {
            var s = a is IExpressionStatementOperation es ? (es.Operation is IIncrementOrDecrementOperation sinc ? IncDec(sinc, true, true).S : StmtExpr(es.Operation)) : Todo("for-loop step " + a.Kind);
            foreach (var x in Pre) foreach (var x2 in SafeStmt(x).Split('\n')) step.Add(x2);
            Pre.Clear();
            if (s.Length > 0) foreach (var l in SafeStmt(s).Split('\n')) step.Add(l);
        }
        var lc = PushLoop(f.ExitLabel, f.ContinueLabel);
        if (condPre.Count > 0)
        {
            lines.Add(pb + "while true do");
            foreach (var s in condPre) foreach (var s2 in s.Split('\n')) lines.Add(Ind(ib + 1) + s2);
            lines.Add(Ind(ib + 1) + "if not " + Paren(cond) + " then break end");
        }
        else lines.Add(pb + "while " + Strip(cond) + " do");
        if (step.Count > 0)
        {
            var sub = new List<string>();
            Sub(f.Body, sub, ib + 2);
            lines.Add(Ind(ib + 1) + "do");
            lines.AddRange(sub);
            lines.Add(Ind(ib + 1) + "end");
            if (lc.ContUsed) lines.Add(Ind(ib + 1) + "::" + lc.ContLabel + "::");
            foreach (var s in step) lines.Add(Ind(ib + 1) + s);
        }
        else LoopBody(lc, f.Body, lines, ib + 1);
        PopLoop(lc);
        lines.Add(pb + "end");
        if (block) lines.Add(p + "end");
    }

    /// <summary>for (i = a; i &lt; n; i++) with an invariant bound and a counter only the step changes: Lua's numeric
    /// for, for i = a, n - 1 do, which evaluates n once (the Ruby and Perl back ends' conditions). The counter is a
    /// fresh local each iteration in Lua, so a loop whose counter a lambda captures is not one of these.</summary>
    bool RangeFor(IForLoopOperation f, List<string> lines, int ind)
    {
        if (f.Condition is not IBinaryOperation cmp) return false;
        if (cmp.OperatorMethod != null) return false;
        var k = cmp.OperatorKind;
        if (k is not (BinaryOperatorKind.LessThan or BinaryOperatorKind.LessThanOrEqual or BinaryOperatorKind.GreaterThan or BinaryOperatorKind.GreaterThanOrEqual)) return false;
        var lhs = StripConv(cmp.LeftOperand);
        if (lhs is not ILocalReferenceOperation lr) return false;
        var iv = lr.Local;
        if (!IsIntegral(iv.Type) || iv.RefKind != RefKind.None || refByValue.Contains(iv) || IsCell(iv)) return false;
        if (Width(iv.Type) == 64 && IsUnsigned(iv.Type)) return false;
        if (!SymbolEqualityComparer.Default.Equals(Under(cmp.LeftOperand.Type!), Under(iv.Type)) && !(cmp.LeftOperand is IConversionOperation)) return false;
        var ct = Under(cmp.LeftOperand.Type!);
        if (IsUnsigned(ct) != IsUnsigned(iv.Type) || Width(ct) < Width(iv.Type)) return false;
        if (IsULong(cmp.RightOperand.Type)) return false;
        bool up = k is BinaryOperatorKind.LessThan or BinaryOperatorKind.LessThanOrEqual;
        if (!up && IsUnsigned(iv.Type)) return false;
        if (f.AtLoopBottom.Length != 1 || f.AtLoopBottom[0] is not IExpressionStatementOperation stepSt) return false;
        var step = stepSt.Operation;
        bool stepOk = step switch
        {
            IIncrementOrDecrementOperation inc => StripConv(inc.Target) is ILocalReferenceOperation t1 && SymbolEqualityComparer.Default.Equals(t1.Local, iv) && (inc.Kind == OperationKind.Increment) == up && inc.OperatorMethod == null,
            ICompoundAssignmentOperation ca => StripConv(ca.Target) is ILocalReferenceOperation t2 && SymbolEqualityComparer.Default.Equals(t2.Local, iv) && ca.OperatorMethod == null &&
                (ca.OperatorKind == (up ? BinaryOperatorKind.Add : BinaryOperatorKind.Subtract)) && ca.Value.ConstantValue.HasValue && Convert.ToInt64(ca.Value.ConstantValue.Value) == 1,
            _ => false
        };
        if (!stepOk) return false;
        bool ownVar = f.Locals.Contains(iv);
        IVariableDeclaratorOperation? ownDecl = null;
        if (ownVar)
        {
            foreach (var b in f.Before)
                if (b is IVariableDeclarationGroupOperation g)
                    foreach (var d in g.Declarations) foreach (var v in d.Declarators) if (SymbolEqualityComparer.Default.Equals(v.Symbol, iv)) ownDecl = v;
            if (ownDecl == null) return false;
        }
        else return false;      // a counter declared before the loop keeps its last value after it in C#; Lua's for counter does not
        foreach (var d in f.Body.DescendantsAndSelf().Concat(cmp.RightOperand.DescendantsAndSelf()))
        {
            if (d is IAssignmentOperation a && StripConv(a.Target) is ILocalReferenceOperation al && SymbolEqualityComparer.Default.Equals(al.Local, iv)) return false;
            if (d is IIncrementOrDecrementOperation ii && StripConv(ii.Target) is ILocalReferenceOperation il && SymbolEqualityComparer.Default.Equals(il.Local, iv)) return false;
            if (d is IAnonymousFunctionOperation af && af.Body.Descendants().Any(x => x is ILocalReferenceOperation xl && SymbolEqualityComparer.Default.Equals(xl.Local, iv))) return false;
            if (d is IArgumentOperation arg && arg.Parameter != null && arg.Parameter.RefKind != RefKind.None && StripConv(arg.Value) is ILocalReferenceOperation rl && SymbolEqualityComparer.Default.Equals(rl.Local, iv)) return false;
        }
        var bound = cmp.RightOperand;
        if (!Invariant(bound, f)) return false;
        bool block = f.Before.Any(b => !(b is IVariableDeclarationGroupOperation g && g.Declarations.All(d => d.Declarators.All(v => SymbolEqualityComparer.Default.Equals(v.Symbol, iv)))));
        int ib = ind;
        if (block) { lines.Add(Ind(ind) + "do"); ib = ind + 1; }
        foreach (var b in f.Before)
        {
            if (b is IVariableDeclarationGroupOperation g)
            {
                foreach (var d in g.Declarations)
                    foreach (var v in d.Declarators)
                        if (!SymbolEqualityComparer.Default.Equals(v.Symbol, iv)) LocalDecl(v, d.Initializer, lines, ib);
            }
            else Stmt(b, lines, ib);
        }
        var init = ownDecl!.Initializer ?? (ownDecl.Parent as IVariableDeclarationOperation)?.Initializer;
        string start = init == null ? "0" : ValueOf(init.Value, iv.Type);
        var bnd = ValueOf(bound, cmp.RightOperand.Type);
        FlushTo(lines, ib);
        Declare(iv, iv.Name);
        var iname = names[iv];
        string range = k switch
        {
            BinaryOperatorKind.LessThan => Strip(start) + ", " + Paren(bnd) + " - 1",
            BinaryOperatorKind.LessThanOrEqual => Strip(start) + ", " + Strip(bnd),
            BinaryOperatorKind.GreaterThan => Strip(start) + ", " + Paren(bnd) + " + 1, -1",
            _ => Strip(start) + ", " + Strip(bnd) + ", -1"
        };
        bool nn = up && (start == "0" || long.TryParse(start, out var sv) && sv >= 0 || IsUnsigned(iv.Type));
        if (nn) nonNeg.Add(iv);
        var lc = PushLoop(f.ExitLabel, f.ContinueLabel);
        lines.Add(Ind(ib) + "for " + iname + " = " + range + " do");
        LoopBody(lc, f.Body, lines, ib + 1);
        PopLoop(lc);
        if (nn) nonNeg.Remove(iv);
        lines.Add(Ind(ib) + "end");
        if (block) lines.Add(Ind(ind) + "end");
        Stat("range for");
        return true;
    }

    static IOperation StripConv(IOperation op)
    {
        while (op is IConversionOperation cv && cv.OperatorMethod == null && (cv.Conversion.IsIdentity || cv.Conversion.IsNumeric && cv.Conversion.IsImplicit)) op = cv.Operand;
        return op;
    }

    bool Invariant(IOperation b, IForLoopOperation f)
    {
        b = StripConv(b);
        if (b.ConstantValue.HasValue) return true;
        ISymbol? s = b switch { ILocalReferenceOperation l => l.Local, IParameterReferenceOperation p => p.Parameter, _ => null };
        if (s == null)
        {
            if (b is IPropertyReferenceOperation pr && IsSystem(pr.Property) && pr.Property.Name == "Length" && pr.Instance != null && Invariant(pr.Instance, f)) return true;
            if (b is IConversionOperation cv && cv.OperatorMethod == null && IsIntegral(cv.Type) && IsIntegral(cv.Operand.Type)) return Invariant(cv.Operand, f);
            if (b is IFieldReferenceOperation fr && IsEngine(fr.Field.ContainingType) && !fr.Field.IsConst)
            {
                if (!fr.Field.IsStatic && !(fr.Instance is IInstanceReferenceOperation) && !Invariant(fr.Instance!, f)) return false;
                if (MayWrite(f.Body, fr.Field) || f.AtLoopBottom.Any(x => MayWrite(x, fr.Field)) || MayWrite(f.Condition!, fr.Field)) return false;
                Stat("range for with a field bound");
                return true;
            }
            if (b is IInstanceReferenceOperation) return true;
            return false;
        }
        if (IsRefSym(s) || s is ILocalSymbol ls && refByValue.Contains(ls) || IsCell(s)) return false;
        foreach (var d in f.Body.DescendantsAndSelf().Concat(f.AtLoopBottom.SelectMany(x => x.DescendantsAndSelf())).Concat(f.Condition!.DescendantsAndSelf()))
        {
            if (d is IAssignmentOperation a && Sym(StripConv(a.Target)) is ISymbol t && SymbolEqualityComparer.Default.Equals(t, s)) return false;
            if (d is IIncrementOrDecrementOperation ii && Sym(StripConv(ii.Target)) is ISymbol t2 && SymbolEqualityComparer.Default.Equals(t2, s)) return false;
            if (d is IArgumentOperation arg && arg.Parameter != null && arg.Parameter.RefKind != RefKind.None && Sym(StripConv(arg.Value)) is ISymbol t4 && SymbolEqualityComparer.Default.Equals(t4, s)) return false;
            if (d is IAnonymousFunctionOperation af && af.Body.Descendants().Any(x => (x is IAssignmentOperation xa && Sym(StripConv(xa.Target)) is ISymbol t3 && SymbolEqualityComparer.Default.Equals(t3, s)))) return false;
        }
        return true;
    }

    static ISymbol? Sym(IOperation op) => op switch { ILocalReferenceOperation l => l.Local, IParameterReferenceOperation p => p.Parameter, _ => null };

    /// <summary>foreach: a numeric for over an array's elements (0 .. n - 1), or over the elements a runtime collection's
    /// elems() returns (a Lua sequence 1 .. n, and its n). The loop variable is a local of the loop body: a fresh one
    /// each iteration, as C#'s.</summary>
    void ForEach(IForEachLoopOperation fe, List<string> lines, int ind)
    {
        var p = Ind(ind);
        var coll = fe.Collection is IConversionOperation cv && cv.IsImplicit ? cv.Operand : fe.Collection;
        var ct = coll.Type!;
        var src = V(coll);
        FlushTo(lines, ind);
        if (fe.LoopControlVariable is not IVariableDeclaratorOperation vd) { Todo("foreach variable"); return; }
        var loc = vd.Symbol;
        var arr = Fresh("fa");
        var cnt = Fresh("fn");
        var idx = FreshLocal("fi");
        lines.Add(p + "do");
        string first, last, elem;
        if (ct is IArrayTypeSymbol || ct is INamedTypeSymbol ie && IsSystem(ie) && ie.Name == "IEnumerable")
        {
            lines.Add(Ind(ind + 1) + arr + " = " + Strip(src));
            first = "0"; last = arr + ".n - 1";
        }
        else if (ct is INamedTypeSymbol nt && IsRuntime(nt))
        {
            lines.Add(Ind(ind + 1) + arr + ", " + cnt + " = " + Use("elems", "foreach over a runtime collection: its elements as a Lua sequence and their count") + "(" + Strip(src) + ")");
            first = "1"; last = cnt;
        }
        else { Todo("foreach over " + ct.ToDisplayString()); return; }
        var lc = PushLoop(fe.ExitLabel, fe.ContinueLabel);
        lines.Add(Ind(ind + 1) + "for " + idx + " = " + first + ", " + last + " do");
        var name = Declare(loc, loc.Name);
        elem = arr + "[" + idx + "]";
        var body = new List<string>();
        body.Add(Ind(ind + 2) + (IsCell(loc) ? "local " + name + " = {" + elem + "}" : "local " + name + " = " + elem));
        var sub = new List<string>();
        Sub(fe.Body, sub, ind + 3);
        if (lc.ContUsed)
        {
            body.Add(Ind(ind + 2) + "do");
            body.AddRange(sub);
            body.Add(Ind(ind + 2) + "end");
            body.Add(Ind(ind + 2) + "::" + lc.ContLabel + "::");
        }
        else foreach (var l in sub) body.Add(l.Length >= 2 ? l.Substring(2) : l);
        PopLoop(lc);
        lines.AddRange(body);
        lines.Add(Ind(ind + 1) + "end");
        lines.Add(p + "end");
    }

    /// <summary>A name for a local the translator declares itself (a loop counter), unique in the function.</summary>
    string FreshLocal(string b)
    {
        string n;
        do { tmp[0]++; n = b + "_" + tmp[0]; } while (used.Contains(n));
        used.Add(n);
        return n;
    }

    void Branch(IBranchOperation br, List<string> lines, int ind)
    {
        var p = Ind(ind);
        switch (br.BranchKind)
        {
            case BranchKind.Break:
            case BranchKind.Continue:
                {
                    bool isBreak = br.BranchKind == BranchKind.Break;
                    for (int i = ctx.Count - 1; i >= 0; i--)
                    {
                        var c = ctx[i];
                        bool hit = isBreak ? SymbolEqualityComparer.Default.Equals(c.Exit, br.Target) : c.IsLoop && SymbolEqualityComparer.Default.Equals(c.Cont, br.Target);
                        if (!hit) continue;
                        if (c.EvalDepth < evalDepth) { Escape(br, lines, ind); return; }
                        if (isBreak)
                        {
                            if (c.IsSwitch) { c.ExitUsed = true; lines.Add(p + "goto " + c.ExitLabel); }
                            else
                            {
                                // a Lua break leaves the innermost loop; a switch inside the loop is no loop in Lua
                                lines.Add(p + "break");
                            }
                        }
                        else { c.ContUsed = true; lines.Add(p + "goto " + c.ContLabel); }
                        return;
                    }
                    Todo("branch target not found");
                    return;
                }
            case BranchKind.GoTo:
                if (evalDepth > 0) Todo("goto inside a try");
                lines.Add(p + "goto GT_" + LuaIdentBase(br.Target.Name));
                Stat("goto");
                return;
        }
        Todo("branch " + br.BranchKind);
    }

    /// <summary>A break or continue that leaves a try body: the body function returns 2 and the branch's number, and
    /// the code after the pcall takes the branch (Escapes of the innermost try).</summary>
    void Escape(IBranchOperation br, List<string> lines, int ind)
    {
        var t = tries[^1];
        labelNo[0]++;
        int id = labelNo[0];
        t.Escapes.Add((id, br));
        lines.Add(Ind(ind) + "do return 2, " + id + " end");
        Stat("branch out of a try body");
    }

    // ---- switch: an if/elseif chain; a break that is not the last statement of its case is a goto to the end label
    void Switch(ISwitchOperation sw, List<string> lines, int ind)
    {
        var p = Ind(ind);
        var vt = sw.Value.Type!;
        var v = V(sw.Value);
        string t = v;
        if (!SimpleName(v) && !IsConstText(v)) { t = Fresh("sw"); FlushTo(lines, ind); lines.Add(p + t + " = " + Strip(v)); }
        else FlushTo(lines, ind);
        var locals = sw.Cases.SelectMany(c => c.Locals).Concat(sw.Locals).Distinct<ILocalSymbol>(SymbolEqualityComparer.Default).ToList();
        bool block = locals.Count > 0;
        int bi = ind;
        if (block)
        {
            lines.Add(p + "do");
            bi = ind + 1;
            var ns = locals.Select(l => names.TryGetValue(l, out var e) ? e : Declare(l, l.Name)).ToList();
            foreach (var l in locals) predeclared.Add(l);
            var decl = new List<string>();
            for (int i = 0; i < locals.Count; i++)
                decl.Add(IsCell(locals[i]) ? "local " + ns[i] + " = {" + DefaultOf(locals[i].Type) + "}" : "local " + ns[i]);
            foreach (var d in decl) lines.Add(Ind(bi) + d);
        }
        var sc = new Ctx { Exit = sw.ExitLabel, IsSwitch = true, ExitLabel = NewLabel("sw"), EvalDepth = evalDepth };
        ctx.Add(sc);
        bool first = true;
        IOperation[]? defBody = null;
        foreach (var c in sw.Cases)
        {
            var conds = new List<string>();
            foreach (var cl in c.Clauses)
            {
                if (cl is IDefaultCaseClauseOperation) continue;
                if (cl is ISingleValueCaseClauseOperation sv)
                {
                    var cv = ValueOf(sv.Value, vt);
                    conds.Add(t + " == " + cv);
                }
                else Todo("case clause " + cl.CaseKind);
            }
            if (c.Clauses.Any(cl => cl is IDefaultCaseClauseOperation)) { defBody = c.Body.ToArray(); if (conds.Count == 0) continue; }
            lines.Add(Ind(bi) + (first ? "if " : "elseif ") + string.Join(" or ", conds) + " then");
            first = false;
            CaseBody(c.Body, sw.ExitLabel, lines, bi + 1);
        }
        if (defBody != null)
        {
            if (first) { lines.Add(Ind(bi) + "do"); CaseBody(defBody, sw.ExitLabel, lines, bi + 1); lines.Add(Ind(bi) + "end"); }
            else { lines.Add(Ind(bi) + "else"); CaseBody(defBody, sw.ExitLabel, lines, bi + 1); lines.Add(Ind(bi) + "end"); }
        }
        else if (!first) lines.Add(Ind(bi) + "end");
        ctx.Remove(sc);
        if (sc.ExitUsed) { lines.Add(Ind(bi) + "::" + sc.ExitLabel + "::"); Stat("switch with a goto to its end"); }
        if (block) lines.Add(p + "end");
    }

    /// <summary>A case body without its last statement when that is the break that ends the case.</summary>
    void CaseBody(IEnumerable<IOperation> body, ILabelSymbol exit, List<string> lines, int ind)
    {
        var list = body.ToList();
        if (list.Count > 0 && list[^1] is IBranchOperation b && b.BranchKind == BranchKind.Break && SymbolEqualityComparer.Default.Equals(b.Target, exit))
            list.RemoveAt(list.Count - 1);
        Block(list, lines, ind);
    }

    // ---- try: the body in a function run by pcall, which returns nothing when it ends, 1 and the value for a return,
    // 2 and a number for a break or continue that leaves it; the code after the pcall runs the matching catch, then the
    // finally, then rethrows, returns or branches.
    void Try(ITryOperation t, List<string> lines, int ind)
    {
        var p = Ind(ind);
        if (t.Finally != null && t.Catches.Length > 0)
        {
            // try { try {body} catch {...} } finally {...}
            TryFinally(t, (ls, i) => TryCatch(t.Body, t.Catches, ls, i), lines, ind);
            return;
        }
        if (t.Finally != null) { TryFinally(t, (ls, i) => Sub(t.Body, ls, i), lines, ind); return; }
        TryCatch(t.Body, t.Catches, lines, ind);
    }

    void TryFinally(ITryOperation t, Action<List<string>, int> body, List<string> lines, int ind)
    {
        var p = Ind(ind);
        var ok = Fresh("ok"); var tr = Fresh("tr"); var tv = Fresh("tv");
        var tc = new TryCtx { Depth = evalDepth + 1 };
        tries.Add(tc);
        lines.Add(p + ok + ", " + tr + ", " + tv + " = L_pcall(function()");
        evalDepth++;
        body(lines, ind + 1);
        evalDepth--;
        tries.RemoveAt(tries.Count - 1);
        lines.Add(p + "end)");
        Sub(t.Finally!, lines, ind);
        lines.Add(p + "if not " + ok + " then L_error(" + tr + ", 0) end");
        Propagate(ok, tr, tv, tc, lines, ind);
    }

    void TryCatch(IOperation body, System.Collections.Immutable.ImmutableArray<ICatchClauseOperation> catches, List<string> lines, int ind)
    {
        var p = Ind(ind);
        var ok = Fresh("ok"); var tr = Fresh("tr"); var tv = Fresh("tv");
        var tc = new TryCtx { Depth = evalDepth + 1 };
        tries.Add(tc);
        lines.Add(p + ok + ", " + tr + ", " + tv + " = L_pcall(function()");
        evalDepth++;
        Sub(body, lines, ind + 1);
        evalDepth--;
        tries.RemoveAt(tries.Count - 1);
        lines.Add(p + "end)");
        CatchPart(ok, tr, catches, lines, ind);
        Propagate(ok, tr, tv, tc, lines, ind);
    }

    /// <summary>After a pcall that ended normally: a return or a branch the body made, taken here.</summary>
    void Propagate(string ok, string tr, string tv, TryCtx tc, List<string> lines, int ind)
    {
        var p = Ind(ind);
        bool returns = true;
        if (returns)
        {
            if (evalDepth > 0) lines.Add(p + "if " + ok + " and " + tr + " == 1 then do return 1, " + tv + " end end");
            else if (method != null && method.ReturnsVoid || method == null) lines.Add(p + "if " + ok + " and " + tr + " == 1 then do return end end");
            else lines.Add(p + "if " + ok + " and " + tr + " == 1 then do return " + tv + " end end");
        }
        foreach (var (id, br) in tc.Escapes)
        {
            lines.Add(p + "if " + ok + " and " + tr + " == 2 and " + tv + " == " + id + " then");
            Branch(br, lines, ind + 1);
            lines.Add(p + "end");
        }
    }

    void CatchPart(string ok, string tr, System.Collections.Immutable.ImmutableArray<ICatchClauseOperation> catches, List<string> lines, int ind)
    {
        var p = Ind(ind);
        lines.Add(p + "if not " + ok + " then");
        var ex = Fresh("ex");
        lines.Add(Ind(ind + 1) + ex + " = L_excof(" + tr + ")");
        bool first = true;
        bool catchAll = false;
        foreach (var cc in catches)
        {
            var et = cc.ExceptionType;
            string test;
            if (et.SpecialType == SpecialType.System_Object || et is INamedTypeSymbol en && IsSystem(en) && en.Name == "Exception") test = "true";
            else if (et is INamedTypeSymbol en2 && IsSystem(en2)) test = "L_isa(" + ex + ", " + UseC("SysException", "a .NET exception (NewSysException(kind, message)); a catch of " + en2.Name) + ")";
            else if (et is INamedTypeSymbol rt && IsRuntime(rt)) test = "L_isa(" + ex + ", " + UseC(RuntimeTypeName(rt), "type " + rt.OriginalDefinition.ToDisplayString() + " (an exception class)") + ")";
            else test = "L_isa(" + ex + ", " + ClassConst((INamedTypeSymbol)et) + ")";
            if (cc.Filter != null) Todo("exception filter");
            if (test == "true") lines.Add(Ind(ind + 1) + (first ? "do" : "else"));
            else lines.Add(Ind(ind + 1) + (first ? "if " : "elseif ") + test + " then");
            first = false;
            if (cc.ExceptionDeclarationOrExpression is IVariableDeclaratorOperation vd)
            {
                var ev = Declare(vd.Symbol, vd.Symbol.Name);
                lines.Add(Ind(ind + 2) + "local " + ev + " = " + ex);
            }
            catchVars.Push(ex);
            Sub(cc.Handler, lines, ind + 2);
            catchVars.Pop();
            if (test == "true") { catchAll = true; break; }
        }
        if (!catchAll)
        {
            if (first) lines.Add(Ind(ind + 1) + "L_error(" + ex + ", 0)");
            else { lines.Add(Ind(ind + 1) + "else"); lines.Add(Ind(ind + 2) + "L_error(" + ex + ", 0)"); lines.Add(Ind(ind + 1) + "end"); }
        }
        else lines.Add(Ind(ind + 1) + "end");
        lines.Add(p + "end");
    }

    /// <summary>using var x = ...; and the rest of the block: the rest in a pcall'd function, then x.Dispose(), as a finally.</summary>
    void UsingRest(IUsingDeclarationOperation ud, List<IOperation> rest, List<string> lines, int ind)
    {
        var p = Ind(ind);
        var decls = ud.DeclarationGroup.Declarations.SelectMany(d => d.Declarators).ToList();
        foreach (var d in ud.DeclarationGroup.Declarations)
            foreach (var v in d.Declarators) LocalDecl(v, d.Initializer, lines, ind);
        var ok = Fresh("ok"); var tr = Fresh("tr"); var tv = Fresh("tv");
        var tc = new TryCtx { Depth = evalDepth + 1 };
        tries.Add(tc);
        lines.Add(p + ok + ", " + tr + ", " + tv + " = L_pcall(function()");
        evalDepth++;
        Block(rest, lines, ind + 1);
        evalDepth--;
        tries.RemoveAt(tries.Count - 1);
        lines.Add(p + "end)");
        foreach (var v in decls.AsEnumerable().Reverse())
        {
            var n = Read(v.Symbol).S;
            lines.Add(p + "if " + n + " ~= nil then " + n + ":Dispose() end");
        }
        lines.Add(p + "if not " + ok + " then L_error(" + tr + ", 0) end");
        Propagate(ok, tr, tv, tc, lines, ind);
        UseC("IDisposable", "interface System.IDisposable (Dispose())");
        Stat("using declaration");
    }

    static bool InLambda(IOperation d, IOperation outer)
    {
        for (var x = d.Parent; x != null && x != outer; x = x.Parent) if (x is IAnonymousFunctionOperation) return true;
        return false;
    }

    // -------------------------------------------------------------------------------------------- expression statements
    string StmtExpr(IOperation op)
    {
        switch (op)
        {
            case ISimpleAssignmentOperation a:
                {
                    if (a.IsRef) return RefRebind(a.Target, RefOf(a.Value));
                    var v = ValueOf(a.Value, a.Target.Type);
                    return Assign(a.Target, v);
                }
            case ICompoundAssignmentOperation ca: return Compound(ca, true).S;
            case IIncrementOrDecrementOperation inc: return IncDec(inc, true).S;
            case IDiscardOperation: return "";
            case IConditionalAccessOperation ca:
                {
                    var recv = V(ca.Operation);
                    string r = recv;
                    if (!Simple(recv)) { r = Fresh("ca"); Pre.Add(r + " = " + Strip(recv)); }
                    condAccess.Push(r);
                    var saved = Pre; Pre = new List<string>();
                    var inner = StmtExpr(ca.WhenNotNull);
                    var ip = Pre; Pre = saved;
                    condAccess.Pop();
                    var sb = new StringBuilder("if " + r + " ~= nil then");
                    foreach (var l in ip) foreach (var l2 in l.Split('\n')) sb.Append("\n  ").Append(l2);
                    foreach (var l in SafeStmt(inner).Split('\n')) if (l.Length > 0) sb.Append("\n  ").Append(l);
                    sb.Append("\nend");
                    return sb.ToString();
                }
            case ILiteralOperation:
                return "";
            default:
                {
                    var s = X(op).S;
                    if (IsCallText(s)) return Strip(s);
                    if (op is IInvocationOperation iv0 && IsEngine(iv0.TargetMethod.ContainingType) && iv0.TargetMethod.MethodKind != MethodKind.DelegateInvoke) { Stat("inlined call as a statement (dropped: pure)"); return ""; }
                    if (Simple(s) || IsConstText(s) || IsPureOp(op)) return "";
                    // an expression with no call at its top (an inlined call, a conversion of a call): evaluate it
                    var t = Fresh("discard");
                    Stat("expression statement assigned to a temporary");
                    return t + " = " + Strip(s);
                }
        }
    }

    /// <summary>Whether s is a call (a prefix expression that ends with an argument list), which Lua takes as a statement.</summary>
    static bool IsCallText(string s)
    {
        s = Strip(s);
        if (s.Length == 0 || s[^1] != ')' || !IsPrefix(s)) return false;
        if (s[0] == '(' && Balanced(s.Substring(1, s.Length - 2)) && FullyParenthesized(s)) return false;
        return true;
    }

    static bool FullyParenthesized(string s)
    {
        if (s.Length < 2 || s[0] != '(' || s[^1] != ')') return false;
        int d = 0;
        for (int i = 0; i < s.Length; i++)
        {
            var ch = s[i];
            if (ch == '"' || ch == '\'') { i = SkipStr(s, i); continue; }
            if (ch == '(' || ch == '[' || ch == '{') d++;
            else if (ch == ')' || ch == ']' || ch == '}') { d--; if (d == 0 && i < s.Length - 1) return false; }
        }
        return true;
    }

    string RefRebind(IOperation target, RefX r)
    {
        if (target is ILocalReferenceOperation l && l.Local.RefKind != RefKind.None && !refByValue.Contains(l.Local)) return Name(l.Local) + ", " + Name(l.Local) + "_k = " + r.Pair;
        return Todo("ref reassignment of " + target.Kind);
    }

    readonly Stack<string> condAccess = new();
    readonly Stack<string> implicitRecv = new();

    // -------------------------------------------------------------------------------------------- places
    static bool IsThis(IOperation? inst)
    {
        while (inst is IConversionOperation cv && cv.Conversion.IsIdentity) inst = cv.Operand;
        return inst is IInstanceReferenceOperation ir && ir.ReferenceKind == InstanceReferenceKind.ContainingTypeInstance;
    }

    string EngineField(IOperation inst, IFieldSymbol fs) => (IsThis(inst) ? selfText : Recv(inst)) + "." + FieldIdent(fs);

    /// <summary>What this stands for: self, or the receiver of a method being inlined.</summary>
    string selfText = "self";

    /// <summary>A Lua assignable place for op, if it has one (a name, a field, an element).</summary>
    string? Direct(IOperation op, bool forWrite)
    {
        switch (op)
        {
            case ILocalReferenceOperation l:
                if (l.Local.RefKind != RefKind.None) return refByValue.Contains(l.Local) ? (forWrite ? null : Name(l.Local)) : Name(l.Local) + "[" + Name(l.Local) + "_k]";
                if (IsCell(l.Local)) return Name(l.Local) + "[1]";
                return Name(l.Local);
            case IParameterReferenceOperation pr:
                if (pr.Parameter.RefKind is RefKind.Ref or RefKind.Out or RefKind.In) return Name(pr.Parameter) + "[" + Name(pr.Parameter) + "_k]";
                if (IsCell(pr.Parameter)) return Name(pr.Parameter) + "[1]";
                return Name(pr.Parameter);
            case IFieldReferenceOperation f:
                {
                    var fs = f.Field;
                    if (IsRuntime(fs)) return fs.IsStatic ? (forWrite ? null : StaticRuntimeField(fs)) : Recv(f.Instance!) + "." + RuntimeField(fs);
                    if (fs.IsStatic) return StaticFieldName(fs);
                    return EngineField(f.Instance!, fs);
                }
            case IArrayElementReferenceOperation ae:
                return Recv(ae.ArrayReference) + "[" + Index(ae.Indices[0]) + "]";
            case IPropertyReferenceOperation p when VecElem(p, out var vs, out var vi):
                return vs + "[" + vi + "]";
            case IPropertyReferenceOperation p2 when PtrOverArray(p2, out var arr, out var ix):
                return arr + "[" + ix + "]";
            case IPropertyReferenceOperation p3 when DerefElem(p3, out var arr3, out var ix3):
                return arr3 + "[" + ix3 + "]";
            case IConversionOperation cv when cv.Conversion.IsIdentity: return Direct(cv.Operand, forWrite);
        }
        return null;
    }

    string Name(ISymbol s) => names.TryGetValue(s, out var n) ? n : Todo("unknown symbol " + s.Name);

    string Assign(IOperation target, string v)
    {
        var d = Direct(target, true);
        if (d != null) return d + " = " + Strip(v);
        if (target is IPropertyReferenceOperation cp && IsCPtrIndexer(cp)) return Recv(cp.Instance!) + ":" + UseM("set", "method CPtr.this[int] set (set(i, v))") + "(" + Index(cp.Arguments[0].Value) + ", " + Strip(v) + ")";
        if (target is IPropertyReferenceOperation sp && !sp.Property.IsIndexer && sp.Property.SetMethod != null && sp.Property.RefKind == RefKind.None)
            return PropSet(sp, v);
        if (target is IPropertyReferenceOperation rp && rp.Property.RefKind != RefKind.None && IsRuntime(rp.Property))
            return PropRefSet(rp, v);
        var r = SpillRef(RefOf(target));
        return r.Deref + " = " + Strip(v);
    }

    /// <summary>A reference whose table is not a plain name is put in temporaries first (it is read and written).</summary>
    RefX SpillRef(RefX r)
    {
        if (SimpleName(r.T) && (SimpleName(r.K) || IsConstText(r.K))) return r;
        var tt = Fresh("rt"); var tk = Fresh("rk");
        Pre.Add(tt + ", " + tk + " = " + r.Pair);
        return new RefX(tt, tk);
    }

    bool StableTarget(IOperation target)
    {
        switch (target)
        {
            case ILocalReferenceOperation: case IParameterReferenceOperation: return true;
            case IFieldReferenceOperation f: return f.Field.IsStatic || f.Instance == null || StableRecv(f.Instance);
            case IArrayElementReferenceOperation ae: return StableRecv(ae.ArrayReference) && StableIndex(ae.Indices[0]);
            case IPropertyReferenceOperation p when (IsVecIndexer(p) || IsCPtrIndexer(p) || IsPtrIndexer(p)) && p.Arguments.Length == 1: return StableRecv(p.Instance!) && StableIndex(p.Arguments[0].Value);
            case IPropertyReferenceOperation pd when pd.Property.Name == "Deref" && IsRuntime(pd.Property) && pd.Instance != null && StripArity(pd.Property.ContainingType.Name) is "Ptr" or "Iter": return StableRecv(pd.Instance);
            case IConversionOperation cv when cv.Conversion.IsIdentity: return StableTarget(cv.Operand);
        }
        return false;
    }

    static bool StableRecv(IOperation r)
    {
        r = StripConv(r);
        return r switch
        {
            IInstanceReferenceOperation => true,
            ILocalReferenceOperation => true,
            IParameterReferenceOperation => true,
            IFieldReferenceOperation f => f.Field.IsStatic || f.Instance == null || StableRecv(f.Instance),
            _ => false
        };
    }

    static bool StableIndex(IOperation i)
    {
        i = StripConv(i);
        if (i.ConstantValue.HasValue) return true;
        if (i is IConversionOperation cv && cv.OperatorMethod == null && IsIntegral(cv.Type)) return StableIndex(cv.Operand);
        return i is ILocalReferenceOperation || i is IParameterReferenceOperation || i is IFieldReferenceOperation f && (f.Field.IsStatic || StableRecv(f.Instance!));
    }

    Ex Compound(ICompoundAssignmentOperation ca, bool stmt)
    {
        var tt = ca.Target.Type!;
        if (ca.OperatorMethod != null && !IsSystem(ca.OperatorMethod))
            return AssignWith(ca.Target, stmt, cur => UserBinary(ca.OperatorMethod, cur, ValueOf(ca.Value, ca.OperatorMethod.Parameters[1].Type)), tt);
        if (tt.SpecialType == SpecialType.System_String)
            return AssignWith(ca.Target, stmt, cur => "(" + cur + " .. " + StrPart(ca.Value) + ")", tt);
        var opT = ca.InConversion.Exists && !ca.InConversion.IsIdentity && ca.InConversion.IsNumeric ? ca.Value.Type! : tt;
        if (ca.OperatorMethod != null && ca.OperatorMethod.ContainingType.SpecialType == SpecialType.System_String) opT = tt;
        return AssignWith(ca.Target, stmt, cur =>
        {
            var l = Conv(new Ex(cur), tt, opT);
            var r = X(ca.Value);
            var res = BinOp(ca.OperatorKind, opT, l, r, ca.Value.Type, ca.Target, ca.Value);
            return Clean(Conv(res, opT, tt), tt);
        }, tt);
    }

    /// <summary>target = f(target) as a statement, or as a value (the assignment is hoisted, the value is the place or a
    /// temporary holding it).</summary>
    Ex AssignWith(IOperation target, bool stmt, Func<string, string> f, ITypeSymbol tt)
    {
        var d = Direct(target, false);
        if (d != null && StableTarget(target))
        {
            var dw = Direct(target, true)!;
            var nv = f(d);
            if (stmt) return dw + " = " + Strip(nv);
            Pre.Add(dw + " = " + Strip(nv));
            return ValueAfter(dw, tt);
        }
        if (d != null)
        {
            var spilled = Spill(target);
            if (spilled != null)
            {
                var nv = f(spilled);
                if (stmt) return spilled + " = " + Strip(nv);
                Pre.Add(spilled + " = " + Strip(nv));
                return ValueAfter(spilled, tt);
            }
        }
        if (target is IPropertyReferenceOperation cp && IsCPtrIndexer(cp))
        {
            var pr = Recv(cp.Instance!); var ix = Index(cp.Arguments[0].Value);
            if (!SimpleName(pr)) { var t0 = Fresh("p"); Pre.Add(t0 + " = " + Strip(pr)); pr = t0; }
            if (!SimpleName(ix) && !IsConstText(ix)) { var t1 = Fresh("i"); Pre.Add(t1 + " = " + Strip(ix)); ix = t1; }
            UseM("get", "method CPtr.this[int] get (get(i))");
            var nv = f(pr + ":get(" + ix + ")");
            UseM("set", "method CPtr.this[int] set (set(i, v))");
            if (stmt) return pr + ":set(" + ix + ", " + Strip(nv) + ")";
            var t = Fresh("v");
            Pre.Add(t + " = " + Strip(nv));
            Pre.Add(pr + ":set(" + ix + ", " + t + ")");
            return t;
        }
        var r0 = SpillRef(RefOf(target));
        var val = f(r0.Deref);
        if (stmt) return r0.Deref + " = " + Strip(val);
        Pre.Add(r0.Deref + " = " + Strip(val));
        return ValueAfter(r0.Deref, tt);
    }

    /// <summary>The value of a place just assigned in Pre, read back (a temporary when a later statement could change it).</summary>
    Ex ValueAfter(string place, ITypeSymbol tt)
    {
        if (SimpleName(place)) return place;
        var t = Fresh("v");
        Pre.Add(t + " = " + place);
        return t;
    }

    string? Spill(IOperation target)
    {
        switch (target)
        {
            case IFieldReferenceOperation f when !f.Field.IsStatic && f.Instance != null && !IsRuntime(f.Field):
                {
                    var r = V(f.Instance);
                    var t = Fresh("o"); Pre.Add(t + " = " + Strip(r));
                    return t + "." + FieldIdent(f.Field);
                }
            case IFieldReferenceOperation f2 when !f2.Field.IsStatic && f2.Instance != null && IsRuntime(f2.Field):
                {
                    var r = V(f2.Instance);
                    var t = Fresh("o"); Pre.Add(t + " = " + Strip(r));
                    return t + "." + RuntimeField(f2.Field);
                }
            case IArrayElementReferenceOperation ae:
                {
                    var a = V(ae.ArrayReference); var i = Index(ae.Indices[0]);
                    var ta = Fresh("a"); Pre.Add(ta + " = " + Strip(a));
                    var ti = Fresh("i"); Pre.Add(ti + " = " + Strip(i));
                    return ta + "[" + ti + "]";
                }
            case IPropertyReferenceOperation p when VecElem(p, out var vs, out var vi):
                {
                    var ta = Fresh("a"); Pre.Add(ta + " = " + Strip(vs));
                    var ti = Fresh("i"); Pre.Add(ti + " = " + Strip(vi));
                    return ta + "[" + ti + "]";
                }
            case IPropertyReferenceOperation p2 when PtrOverArray(p2, out var arr, out var ix):
                {
                    var ta = Fresh("a"); Pre.Add(ta + " = " + Strip(arr));
                    var ti = Fresh("i"); Pre.Add(ti + " = " + Strip(ix));
                    return ta + "[" + ti + "]";
                }
            case IPropertyReferenceOperation p3 when DerefElem(p3, out var arr3, out var ix3):
                {
                    var ta = Fresh("a"); Pre.Add(ta + " = " + Strip(arr3));
                    var ti = Fresh("i"); Pre.Add(ti + " = " + Strip(ix3));
                    return ta + "[" + ti + "]";
                }
        }
        return null;
    }

    Ex IncDec(IIncrementOrDecrementOperation inc, bool stmt, bool loopStep = false)
    {
        var up = inc.Kind == OperationKind.Increment;
        var post = inc.IsPostfix;
        var tt = inc.Target.Type!;
        if (inc.OperatorMethod != null)
        {
            var m = up ? "op_Increment" : "op_Decrement";
            var cn = RuntimeTypeName((INamedTypeSymbol)tt);
            var fnm = Use(cn + "_" + m, "operator " + inc.OperatorMethod.ToDisplayString());
            var d0 = Direct(inc.Target, false);
            if (d0 != null && StableTarget(inc.Target))
            {
                var dw = Direct(inc.Target, true)!;
                if (stmt) return dw + " = " + fnm + "(" + d0 + ")";
                if (!post) { Pre.Add(dw + " = " + fnm + "(" + d0 + ")"); return ValueAfter(dw, tt); }
                var t0 = Fresh("old");
                Pre.Add(t0 + " = " + d0);
                Pre.Add(dw + " = " + fnm + "(" + t0 + ")");
                return t0;
            }
            var r1 = SpillRef(RefOf(inc.Target));
            if (stmt) return r1.Deref + " = " + fnm + "(" + r1.Deref + ")";
            var t1 = Fresh("old");
            Pre.Add(t1 + " = " + r1.Deref);
            Pre.Add(r1.Deref + " = " + fnm + "(" + t1 + ")");
            return post ? t1 : ValueAfter(r1.Deref, tt);
        }
        string Next(string cur)
        {
            if (IsDouble(tt)) return "(" + cur + (up ? " + 1.0)" : " - 1.0)");
            if (IsSingle(tt)) return "L_f32(" + cur + (up ? " + 1.0)" : " - 1.0)");
            var e = "(" + cur + (up ? " + 1)" : " - 1)");
            if (Width(tt) == 64) return e;
            if (Width(tt) >= 32 && !IsUnsigned(tt) && loopStep && up) return e;
            return WrapInt(e, tt);
        }
        if (inc.Target is IPropertyReferenceOperation cp && IsCPtrIndexer(cp))
        {
            var pr = Recv(cp.Instance!); var ix = Index(cp.Arguments[0].Value);
            var mn = (post ? "post" : "pre") + (up ? "Inc" : "Dec");
            UseM(mn, "method CPtr element " + (post ? "post" : "pre") + (up ? "increment" : "decrement") + " (" + mn + "(i), returns the old/new sbyte value)");
            return pr + ":" + mn + "(" + ix + ")";
        }
        var d = Direct(inc.Target, false);
        if (d != null && StableTarget(inc.Target))
        {
            var dw = Direct(inc.Target, true)!;
            if (stmt) return dw + " = " + Strip(Next(d));
            if (!post) { Pre.Add(dw + " = " + Strip(Next(d))); return ValueAfter(dw, tt); }
            var t0 = Fresh("old");
            Pre.Add(t0 + " = " + d);
            Pre.Add(dw + " = " + Strip(Next(t0)));
            return new Ex(t0);
        }
        if (d != null)
        {
            var sp = Spill(inc.Target);
            if (sp != null)
            {
                if (stmt) return sp + " = " + Strip(Next(sp));
                if (!post) { Pre.Add(sp + " = " + Strip(Next(sp))); return ValueAfter(sp, tt); }
                var t0 = Fresh("old");
                Pre.Add(t0 + " = " + sp);
                Pre.Add(sp + " = " + Strip(Next(t0)));
                return new Ex(t0);
            }
        }
        var r = SpillRef(RefOf(inc.Target));
        if (stmt) return r.Deref + " = " + Strip(Next(r.Deref));
        if (!post) { Pre.Add(r.Deref + " = " + Strip(Next(r.Deref))); return ValueAfter(r.Deref, tt); }
        var t2 = Fresh("old");
        Pre.Add(t2 + " = " + r.Deref);
        Pre.Add(r.Deref + " = " + Strip(Next(t2)));
        return new Ex(t2);
    }

    // -------------------------------------------------------------------------------------------- references
    /// <summary>The table and key of the location op names (a ref argument, a ref local, a ref return).</summary>
    public RefX RefOf(IOperation op)
    {
        switch (op)
        {
            case ILocalReferenceOperation l:
                if (l.Local.RefKind != RefKind.None && !refByValue.Contains(l.Local)) return new RefX(Name(l.Local), Name(l.Local) + "_k");
                if (l.Local.RefKind != RefKind.None) return TodoR("reference through a value-bound ref local");
                if (IsCell(l.Local)) return new RefX(Name(l.Local), "1");
                return TodoR("reference to a local not in a cell: " + l.Local.Name);
            case IParameterReferenceOperation p:
                if (p.Parameter.RefKind is RefKind.Ref or RefKind.Out or RefKind.In) return new RefX(Name(p.Parameter), Name(p.Parameter) + "_k");
                if (IsCell(p.Parameter)) return new RefX(Name(p.Parameter), "1");
                return TodoR("reference to a parameter not in a cell: " + p.Parameter.Name);
            case IFieldReferenceOperation f:
                {
                    var fs = f.Field;
                    if (IsRuntime(fs))
                    {
                        if (fs.IsStatic) return TodoR("reference to a runtime static field");
                        return new RefX(Recv(f.Instance!), "\"" + RuntimeField(fs) + "\"");
                    }
                    if (fs.IsStatic) return new RefX("_ENV", "\"" + StaticFieldName(fs) + "\"");
                    return new RefX(IsThis(f.Instance) ? selfText : Recv(f.Instance!), "\"" + FieldIdent(fs) + "\"");
                }
            case IArrayElementReferenceOperation ae:
                return new RefX(Recv(ae.ArrayReference), Index(ae.Indices[0]));
            case IPropertyReferenceOperation pr:
                {
                    if (VecElem(pr, out var vs, out var vi)) return new RefX(vs, vi);
                    if (PtrOverArray(pr, out var arr, out var ix)) return new RefX(arr, ix);
                    if (DerefElem(pr, out var arr6, out var ix6)) return new RefX(arr6, ix6);
                    if (IsCPtrIndexer(pr)) return SpillCall(Recv(pr.Instance!) + ":" + UseM("ref", "method CPtr element reference (ref(i): a table and key that read and write the sbyte at i)") + "(" + Index(pr.Arguments[0].Value) + ")");
                    if (pr.Property.RefKind != RefKind.None) return SpillCall(Prop(pr, true));
                    return TodoR("reference to a property that returns no reference: " + pr.Property.Name);
                }
            case IInvocationOperation inv when inv.TargetMethod.RefKind != RefKind.None:
                return SpillCall(Invoke(inv, true).S);
            case IConditionalOperation c when c.IsRef:
                {
                    var cond = Cond(c.Condition);
                    var tt = Fresh("rt"); var tk = Fresh("rk");
                    var saved = Pre; Pre = new List<string>();
                    var a = RefOf(c.WhenTrue); var pa = Pre; Pre = new List<string>();
                    var b = RefOf(c.WhenFalse!); var pb = Pre; Pre = saved;
                    Pre.Add("if " + Strip(cond) + " then");
                    foreach (var s in pa) Pre.Add("  " + s);
                    Pre.Add("  " + tt + ", " + tk + " = " + a.Pair);
                    Pre.Add("else");
                    foreach (var s in pb) Pre.Add("  " + s);
                    Pre.Add("  " + tt + ", " + tk + " = " + b.Pair);
                    Pre.Add("end");
                    return new RefX(tt, tk);
                }
            case IDiscardOperation d:
                return new RefX("{" + DefaultOf(d.Type!) + "}", "1");
            case IConversionOperation cv when cv.Conversion.IsIdentity:
                return RefOf(cv.Operand);
            case IParenthesizedOperation pp: return RefOf(pp.Operand);
        }
        return TodoR("reference to " + op.Kind);
    }

    static RefX TodoR(string what) { Todo(what); return default; }

    /// <summary>A call that returns a reference (two values): its results in two temporaries.</summary>
    RefX SpillCall(string call)
    {
        var tt = Fresh("rt"); var tk = Fresh("rk");
        Pre.Add(tt + ", " + tk + " = " + Strip(call));
        return new RefX(tt, tk);
    }

    // -------------------------------------------------------------------------------------------- expressions
    public string ValueOf(IOperation op, ITypeSymbol? target)
    {
        var e = X(op);
        if (target != null && op.Type != null && !SymbolEqualityComparer.Default.Equals(op.Type, target))
        {
            e = Conv(e, op.Type, target);
            return Fin(e, target);
        }
        return Fin(e, target ?? op.Type);
    }

    /// <summary>The value made clean for its type, and a float if it is a double held as a Lua integer.</summary>
    static string Fin(Ex e, ITypeSymbol? t)
    {
        if (t != null && IsFloat(t) && e.XInt) return Flt(e.S);
        return Clean(e, t);
    }

    /// <summary>An integer standing for a double made a Lua float: + 0.0 converts it exactly (it is an int's value).</summary>
    static string Flt(string s) => IsConstText(s) && long.TryParse(Strip(s).Replace("(", "").Replace(")", ""), out var v) ? DoubleLit(v) : "(" + Paren(s) + " + 0.0)";

    string V(IOperation op) => Fin(X(op), op.Type);

    static string Clean(Ex e, ITypeSymbol? t)
    {
        if (t == null) return e.S;
        if (e.Raw && IsIntegral(t)) return WrapInt(e.S, t);
        return e.S;
    }

    public Ex X(IOperation op)
    {
        if (op.ConstantValue.HasValue) return Const(op.ConstantValue.Value, op.Type);
        switch (op)
        {
            case IConversionOperation c: return Conversion(c);
            case ILocalReferenceOperation l: return Read(l.Local);
            case IParameterReferenceOperation pr:
                {
                    var n = Name(pr.Parameter);
                    if (pr.Parameter.RefKind is RefKind.Ref or RefKind.Out or RefKind.In) return n + "[" + n + "_k]";
                    if (IsCell(pr.Parameter)) return n + "[1]";
                    return n;
                }
            case IInstanceReferenceOperation ir:
                if (ir.ReferenceKind == InstanceReferenceKind.ImplicitReceiver) return implicitRecv.Count > 0 ? implicitRecv.Peek() : Todo("implicit receiver");
                return selfText;
            case IFieldReferenceOperation f: return Field(f);
            case IPropertyReferenceOperation p: return Prop(p, false);
            case IArrayElementReferenceOperation ae: return Recv(ae.ArrayReference) + "[" + Index(ae.Indices[0]) + "]";
            case IInvocationOperation inv: return Invoke(inv, false);
            case IObjectCreationOperation oc: return New(oc);
            case IArrayCreationOperation ac: return NewArray(ac);
            case IBinaryOperation b: return Binary(b);
            case IUnaryOperation u: return Unary(u);
            case IConditionalOperation c: return Ternary(c);
            case ISimpleAssignmentOperation a:
                {
                    if (a.IsRef) return Todo("ref assignment as a value");
                    var v = ValueOf(a.Value, a.Target.Type);
                    var d = Direct(a.Target, true);
                    if (d != null && StableTarget(a.Target))
                    {
                        if (SimpleName(d)) { Pre.Add(d + " = " + Strip(v)); return d; }
                        var t0 = IsConstText(v) ? v : Fresh("v");
                        if (t0 != v) Pre.Add(t0 + " = " + Strip(v));
                        Pre.Add(d + " = " + t0);
                        return t0;
                    }
                    var t = IsConstText(v) ? v : Fresh("v");
                    if (t != v) Pre.Add(t + " = " + Strip(v));
                    Pre.Add(Assign(a.Target, t));
                    Stat("assignment as a value (hoisted)");
                    return t;
                }
            case ICompoundAssignmentOperation ca: return Compound(ca, false);
            case IIncrementOrDecrementOperation inc: return IncDec(inc, false);
            case IConditionalAccessOperation ca: return CondAccess(ca);
            case IConditionalAccessInstanceOperation: return condAccess.Count > 0 ? condAccess.Peek() : Todo("conditional access instance");
            case IAnonymousFunctionOperation af: return Lambda(af, null);
            case IDelegateCreationOperation dc: return DelegateCreation(dc);
            case IDefaultValueOperation dv: return DefaultOf(dv.Type!);
            case ILiteralOperation lit: return Const(lit.ConstantValue.Value, lit.Type);
            case IIsTypeOperation it: return "L_isa(" + Strip(V(it.ValueOperand)) + ", " + LuaTypeRef(it.TypeOperand) + ")";
            case IIsPatternOperation ip when ip.Pattern is IConstantPatternOperation cpat && cpat.Value.ConstantValue is { HasValue: true, Value: null }:
                return "(" + Paren(V(ip.Value)) + " == nil)";
            case IThrowOperation th:
                return Use("throw_", "throw as an expression: raises its argument") + "(" + Strip(V(th.Exception!)) + ")";
            case ICoalesceOperation co:
                {
                    var a = V(co.Value);
                    var saved = Pre; Pre = new List<string>();
                    var b = ValueOf(co.WhenNull, co.Type);
                    var pb = Pre; Pre = saved;
                    bool truthy = co.Value.Type != null && !co.Value.Type.IsValueType && co.Value.Type.SpecialType != SpecialType.System_Boolean;
                    if (pb.Count == 0 && truthy) return "(" + Paren(a) + " or " + Paren(b) + ")";
                    var t = Fresh("co");
                    Pre.Add(t + " = " + Strip(a));
                    Pre.Add("if " + t + " == nil then");
                    foreach (var l in pb) Pre.Add("  " + l);
                    Pre.Add("  " + t + " = " + Strip(b));
                    Pre.Add("end");
                    return t;
                }
            case IParenthesizedOperation pp: return X(pp.Operand);
            case IDiscardOperation: return Todo("discard as a value");
            case ISizeOfOperation: return Todo("sizeof");
            case ITypeOfOperation: return Todo("typeof");
            case IDeclarationExpressionOperation: return Todo("declaration expression");
        }
        return Todo("expression " + op.Kind);
    }

    Ex Read(ILocalSymbol l)
    {
        if (refByValue.Contains(l)) return Name(l);
        if (l.RefKind != RefKind.None) return Name(l) + "[" + Name(l) + "_k]";
        if (IsCell(l)) return Name(l) + "[1]";
        return Name(l);
    }

    static string LuaTypeRef(ITypeSymbol t)
    {
        if (t is INamedTypeSymbol n && IsEngine(n)) return ClassConst(n);
        if (t is INamedTypeSymbol r && IsRuntime(r)) return UseC(RuntimeTypeName(r), "type " + r.OriginalDefinition.ToDisplayString() + " (isa_)");
        if (t is INamedTypeSymbol sx && IsSystem(sx) && sx.Name == "Exception") return UseC("Exception", "System.Exception (the root of every exception class)");
        return Todo("type test against " + t.ToDisplayString());
    }

    /// <summary>An array index. A signed integer converted to ulong (C#'s vector index) is used as it is: the two
    /// differ only for a negative value, which is out of range either way (C++ would read outside the vector).</summary>
    string Index(IOperation i)
    {
        if (i is IConversionOperation cv && cv.OperatorMethod == null && cv.Type?.SpecialType == SpecialType.System_UInt64 && cv.Operand.Type != null
            && IsIntegral(cv.Operand.Type) && !IsUnsigned(cv.Operand.Type) && Width(cv.Operand.Type) <= 64)
        {
            Stat("signed index used as it is");
            return Strip(V(cv.Operand));
        }
        return Strip(V(i));
    }

    public static string Paren(string s) => Atomic(s) ? s : "(" + s + ")";

    /// <summary>A name, a chain of fields, indexes and calls of one, a number or string literal, or a fully parenthesised
    /// expression: safe as an operand of any operator.</summary>
    static bool Atomic(string s)
    {
        if (s.Length == 0) return false;
        if (FullyParenthesized(s)) return true;
        if (s[0] == '-' || s.StartsWith("not ") || s[0] == '~' || s[0] == '#') return false;
        if (s.StartsWith("function")) return false;
        int depth = 0;
        for (int i = 0; i < s.Length; i++)
        {
            var ch = s[i];
            if (ch == '"' || ch == '\'') { i = SkipStr(s, i); continue; }
            if (ch == '(' || ch == '[' || ch == '{') depth++;
            else if (ch == ')' || ch == ']' || ch == '}') depth--;
            else if (depth == 0)
            {
                if (!(char.IsLetterOrDigit(ch) || ch == '_' || ch == ':' || ch == '.' && !(i + 1 < s.Length && s[i + 1] == '.'))) return false;
                if (ch == '.' && i > 0 && char.IsDigit(s[i - 1]) && i + 1 < s.Length && s[i + 1] == '.') return false;
            }
        }
        if (depth != 0) return false;
        return true;
    }

    /// <summary>A Lua prefix expression (one that can be indexed, called or given a method call): a name, a chain of
    /// fields, indexes and calls of one, or a parenthesised expression.</summary>
    public static bool IsPrefix(string s)
    {
        if (s.Length == 0) return false;
        if (!(char.IsLetter(s[0]) || s[0] == '_' || s[0] == '(')) return false;
        if (s.StartsWith("function") && (s.Length == 8 || !char.IsLetterOrDigit(s[8]) && s[8] != '_')) return false;
        if (s.StartsWith("not ") || s == "nil" || s == "true" || s == "false") return false;
        if (s.StartsWith("nil") && s.Length > 3 && !char.IsLetterOrDigit(s[3]) && s[3] != '_') return false;
        if (s[0] == '(' && !FullyParenthesized(s))
        {
            // (x).f or (x)(y): a parenthesised head followed by suffixes
            int d = 0, i = 0;
            for (; i < s.Length; i++)
            {
                var ch = s[i];
                if (ch == '"' || ch == '\'') { i = SkipStr(s, i); continue; }
                if (ch == '(' || ch == '[' || ch == '{') d++;
                else if (ch == ')' || ch == ']' || ch == '}') { d--; if (d == 0) break; }
            }
            if (i + 1 >= s.Length || !(s[i + 1] == '.' || s[i + 1] == '[' || s[i + 1] == ':' || s[i + 1] == '(')) return false;
        }
        return Atomic(s) && !char.IsDigit(s[0]);
    }

    // ---- constants
    public static Ex Const(object? v, ITypeSymbol? t)
    {
        if (v == null) return t != null && t.IsValueType && !(t is INamedTypeSymbol nn && nn.OriginalDefinition.SpecialType == SpecialType.System_Nullable_T) ? DefaultOf(t) : "nil";
        if (t != null && t.TypeKind == TypeKind.Enum) t = Under(t);
        switch (v)
        {
            case bool b: return b ? "true" : "false";
            case string s: return LuaStr(s);
            case char ch:
                if (t != null && IsFloat(t)) return DoubleLit(ch);
                return ((int)ch).ToString(CultureInfo.InvariantCulture);
            case double d: return t != null && t.SpecialType == SpecialType.System_Single ? DoubleLit((float)d) : DoubleLit(d);
            case float f: return DoubleLit(f);
        }
        var st = t?.SpecialType ?? SpecialType.System_Int32;
        if (st == SpecialType.System_Double || st == SpecialType.System_Single)
        {
            double dv = v switch { int i => i, long l => l, uint u => u, ulong ul => ul, short sh => sh, ushort us => us, byte by => by, sbyte sb => sb, _ => 0 };
            return DoubleLit(st == SpecialType.System_Single ? (float)dv : dv);
        }
        System.Numerics.BigInteger val = v switch { int i => i, long l => l, uint u => u, ulong ul => ul, short sh => sh, ushort us => us, byte by => by, sbyte sb => sb, _ => 0 };
        if (val > long.MaxValue) return "0x" + ((ulong)val).ToString("X16");            // a ulong at or above 2^63: Lua's hex literal wraps to its bits
        if (val == long.MinValue) return "(-9223372036854775807 - 1)";
        var s0 = val.ToString(CultureInfo.InvariantCulture);
        return val < 0 ? "(" + s0 + ")" : s0;
    }

    static string DoubleLit(double d)
    {
        if (double.IsNaN(d))
        {
            var bits = (ulong)BitConverter.DoubleToInt64Bits(d);
            var n = "K_NAN_" + bits.ToString("X16");
            moduleConsts[n] = Use("f64_from_bits", "the double with the given IEEE bits (a NaN constant keeps its sign and payload)") + "(0x" + bits.ToString("X16") + ")";
            DefineGlobalOnce(n);
            return n;
        }
        if (double.IsPositiveInfinity(d)) return Use("K_INF", "+infinity (a constant)");
        if (double.IsNegativeInfinity(d)) return "(-" + Use("K_INF", "+infinity (a constant)") + ")";
        if (d == 0 && double.IsNegative(d)) return Use("K_NZERO", "-0.0 (a constant)");
        var s = d.ToString("R", CultureInfo.InvariantCulture);
        if (!s.Contains('.') && !s.Contains('E')) s += ".0";
        doubleLits[s] = ((ulong)BitConverter.DoubleToInt64Bits(d)).ToString("x16");
        return d < 0 ? "(" + s + ")" : s;
    }

    static readonly HashSet<string> onceGlobals = new();
    static void DefineGlobalOnce(string n) { if (onceGlobals.Add(n)) DefineGlobal(n); }

    /// <summary>A Lua string literal (each C# char below 256 is one byte).</summary>
    public static string LuaStr(string s)
    {
        var sb = new StringBuilder("\"");
        for (int i = 0; i < s.Length; i++)
        {
            int c = s[i];
            if (c == '"') sb.Append("\\\"");
            else if (c == '\\') sb.Append("\\\\");
            else if (c >= 32 && c < 127) sb.Append(s[i]);
            else if (c == '\n') sb.Append("\\n");
            else if (c == '\t') sb.Append("\\t");
            else if (c == '\r') sb.Append("\\r");
            else if (c < 256) sb.Append("\\").Append(c.ToString("D3", CultureInfo.InvariantCulture));
            else { Note("string literal with a char above U+00FF"); sb.Append("?"); }
        }
        return sb.Append('"').ToString();
    }

    // ---- conversions
    Ex Conversion(IConversionOperation c)
    {
        var from = c.Operand.Type;
        var to = c.Type!;
        if (c.OperatorMethod != null)
        {
            if (IsSystem(c.OperatorMethod)) return Todo("system conversion operator " + c.OperatorMethod.ToDisplayString());
            return RuntimeConvOp(c.OperatorMethod, c.Operand);
        }
        if (c.Operand is IAnonymousFunctionOperation af) return Lambda(af, to);
        if (c.Operand is IDelegateCreationOperation dc0 && to.TypeKind == TypeKind.Delegate) return DelegateCreation(dc0);
        if (from == null)
        {
            if (c.Operand is ILiteralOperation || c.Operand is IDefaultValueOperation) return DefaultOf(to);
            return X(c.Operand);
        }
        if (c.IsTryCast)
        {
            var v = V(c.Operand);
            var t = Fresh("as");
            Pre.Add(t + " = " + Strip(v));
            Pre.Add("if not L_isa(" + t + ", " + LuaTypeRef(to) + ") then " + t + " = nil end");
            return t;
        }
        return Conv(X(c.Operand), from, to);
    }

    public Ex Conv(Ex e, ITypeSymbol from, ITypeSymbol to)
    {
        if (SymbolEqualityComparer.Default.Equals(from, to)) return e;
        var f = Under(from); var t = Under(to);
        if (SymbolEqualityComparer.Default.Equals(f, t)) return e;
        if (IsNumeric(t) && IsNumeric(f))
        {
            if (IsFloat(f) && IsIntegral(t))
            {
                var k = t.SpecialType switch
                {
                    SpecialType.System_Int32 => "i32", SpecialType.System_UInt32 => "u32", SpecialType.System_Int64 => "i64", SpecialType.System_UInt64 => "u64",
                    SpecialType.System_Int16 => "i16", SpecialType.System_UInt16 => "u16", SpecialType.System_SByte => "i8", SpecialType.System_Byte => "u8", SpecialType.System_Char => "u16",
                    _ => "x"
                };
                var fe = e.XInt ? Flt(e.S) : e.S;
                if (k == "i32") return "L_f2i32(" + Strip(fe) + ")";
                if (k == "i64") return "L_f2i64(" + Strip(fe) + ")";
                Use("f2" + k, "C# (" + t.ToDisplayString() + ") of a double or float, unchecked, on x86-64");
                return "f2" + k + "(" + Strip(fe) + ")";
            }
            if (IsDouble(t))
            {
                if (IsSingle(f)) return e.XInt ? Flt(e.S) : e;
                var ce = Clean(e, f);
                if (Width(f) <= 32) return new Ex(ce, xint: true);
                if (IsUnsigned(f)) return "L_u2d(" + Strip(ce) + ")";
                return "(" + Paren(ce) + " + 0.0)";           // (double)long: Lua's int-to-float conversion rounds to nearest, as cvtsi2sd does
            }
            if (IsSingle(t))
            {
                if (IsDouble(f)) return "L_f32(" + Strip(e.XInt ? Flt(e.S) : e.S) + ")";
                var ce = Clean(e, f);
                if (IsULong(f)) return Use("f32_u64", "C# (float) of a ulong: rounded once from its exact value") + "(" + Strip(ce) + ")";
                return "L_f32(" + Strip(ce) + ")";
            }
            int wf = Width(f), wt = Width(t);
            bool uf = IsUnsigned(f), ut = IsUnsigned(t);
            if (wt > wf)
            {
                var ce = Clean(e, f);
                if (!uf && ut)
                {
                    if (e.S.Length > 0 && IsNonNeg(e)) return ce;
                    if (wt == 64) return ce;                 // a ulong is held as the long with the same bits
                    return WrapInt(Paren(ce), t);
                }
                return ce;
            }
            if (wt == wf && uf == ut) return e;
            if (wt == 64 && wf == 64) return e;              // long <-> ulong: the same bits
            if (!e.Raw && wt == wf && !uf && ut && IsNonNeg(e)) return e;
            if (!e.Raw && wt == wf && uf && !ut && e.S.Length > 0 && char.IsDigit(e.S[0]) && System.Numerics.BigInteger.TryParse(e.S, out var cvv) && cvv < System.Numerics.BigInteger.Pow(2, wt - 1)) return e;
            return new Ex(WrapInt(Paren(e.S), t));
        }
        if (t.SpecialType == SpecialType.System_Boolean && f.SpecialType == SpecialType.System_Boolean) return e;
        if (to.SpecialType == SpecialType.System_Object || to.TypeKind == TypeKind.Interface) return new Ex(Fin(e, from));
        if (from.SpecialType == SpecialType.System_Object || from.TypeKind == TypeKind.Interface || from is ITypeParameterSymbol) return e;
        if (to is INamedTypeSymbol tex && IsSystem(tex) && tex.Name == "Exception") return e;
        if (from is INamedTypeSymbol fn && to is INamedTypeSymbol tn && (IsEngine(fn) || IsRuntime(fn)) && (IsEngine(tn) || IsRuntime(tn)))
        {
            if (Derives(fn, tn) || tn.TypeKind == TypeKind.Interface || Derives(tn, fn)) return e;
        }
        if (from.TypeKind == TypeKind.Delegate && to.TypeKind == TypeKind.Delegate) return e;
        if (to is INamedTypeSymbol nl && nl.OriginalDefinition.SpecialType == SpecialType.System_Nullable_T) return new Ex(Fin(e, from));
        if (from is INamedTypeSymbol nf && nf.OriginalDefinition.SpecialType == SpecialType.System_Nullable_T) return e;
        if (SymbolEqualityComparer.Default.Equals(from.OriginalDefinition, to.OriginalDefinition)) return e;
        if (from.TypeKind == TypeKind.Array && to.TypeKind == TypeKind.Array) return e;
        if (from.TypeKind == TypeKind.Array && to is INamedTypeSymbol sa && IsSystem(sa)) return e;
        if (from is INamedTypeSymbol fs && IsSystem(fs) && fs.Name == "Exception") return e;
        return Todo("conversion " + from.ToDisplayString() + " -> " + to.ToDisplayString());
    }

    bool IsNonNeg(Ex e)
    {
        if (e.Raw) return false;
        var s = e.S;
        if (s.Length > 0 && char.IsDigit(s[0]) && s.All(char.IsLetterOrDigit) && !s.StartsWith("0x")) return true;
        foreach (var sym in nonNeg) if (names.TryGetValue(sym, out var n) && n == s) return true;
        return false;
    }

    Ex RuntimeConvOp(IMethodSymbol op, IOperation operand)
    {
        var t = op.ContainingType;
        var p0 = op.OriginalDefinition.Parameters[0].Type;
        var nm = RuntimeTypeName(t) + "_from_" + ShortType(p0);
        Use(nm, "conversion " + op.ToDisplayString());
        return nm + "(" + Strip(ValueOf(operand, op.Parameters[0].Type)) + ")";
    }

    static string Spec(INamedTypeSymbol? t, IMethodSymbol? m)
    {
        var args = new List<ITypeSymbol>();
        if (t != null && t.IsGenericType && !SpecializedClass(t)) args.AddRange(t.TypeArguments);
        if (m != null && m.IsGenericMethod) args.AddRange(m.TypeArguments);
        if (args.Count == 0 || args.All(a => PrimCode(a) == null)) return "";
        if (m != null && m.Name == "Back" && m.ContainingType?.Name == "Mv" && m.TypeArguments.Length == 2)
            return "__" + (PrimCode(m.TypeArguments[0]) ?? "O") + m.TypeArguments[1].SpecialType switch
            {
                SpecialType.System_UInt32 => "U", SpecialType.System_UInt64 => "Q", _ => PrimCode(m.TypeArguments[1]) ?? "O"
            };
        return "__" + string.Concat(args.Select(a => PrimCode(a) ?? "O"));
    }

    // ---- fields and properties
    Ex Field(IFieldReferenceOperation f)
    {
        var fs = f.Field;
        if (fs.ContainingType.TypeKind == TypeKind.Enum) return Const(fs.ConstantValue, fs.Type);
        if (IsRuntime(fs))
        {
            if (fs.IsStatic || fs.IsConst) return StaticRuntimeField(fs);
            return Recv(f.Instance!) + "." + RuntimeField(fs);
        }
        if (fs.IsStatic || fs.IsConst) return StaticFieldName(fs);
        return EngineField(f.Instance!, fs);
    }

    static string StaticRuntimeField(IFieldSymbol fs)
    {
        var n = RuntimeTypeName(fs.ContainingType) + "_" + fs.Name;
        return Use(n, "static field " + fs.OriginalDefinition.ToDisplayString() + " (a global value)");
    }

    static string RuntimeField(IFieldSymbol fs) => UseM(fs.Name, "field " + fs.OriginalDefinition.ToDisplayString());

    /// <summary>The receiver of a field access or method call: a prefix expression.</summary>
    string Recv(IOperation inst) { var v = V(inst); return IsPrefix(v) ? v : "(" + Strip(v) + ")"; }

    /// <summary>A name or a chain of fields of one: safe to evaluate twice.</summary>
    static bool Simple(string s) => System.Text.RegularExpressions.Regex.IsMatch(s, @"^[A-Za-z_]\w*(\.\w+)*$");
    public static bool SimpleName(string s) => System.Text.RegularExpressions.Regex.IsMatch(s, @"^[A-Za-z_]\w*$") && !LuaKeywords.Contains(s);

    static bool IsPtrIndexer(IPropertyReferenceOperation p) => p.Property.IsIndexer && IsRuntime(p.Property) && StripArity(p.Property.ContainingType.Name) is "Ptr" or "CSpan";
    static bool IsCPtrIndexer(IPropertyReferenceOperation p) => p.Property.IsIndexer && p.Property.ContainingType.Name == "CPtr" && IsRuntime(p.Property);
    static bool IsVecIndexer(IPropertyReferenceOperation p) => p.Property.IsIndexer && IsRuntime(p.Property) && StripArity(p.Property.ContainingType.Name) is "Vec" or "Str" && p.Property.RefKind != RefKind.None;

    /// <summary>A vector or string element: the backing array (text ending in .a or .b) and the index.</summary>
    bool VecElem(IPropertyReferenceOperation p, out string arr, out string idx)
    {
        arr = idx = "";
        var tn = StripArity(p.Property.ContainingType.Name);
        if (!p.Property.IsIndexer || !IsRuntime(p.Property) || p.Property.RefKind == RefKind.None) return false;
        if (tn == "Vec") { arr = Recv(p.Instance!) + "." + UseM("a", "field Cpp.Vec<T>.a (the backing array; elements 0..n-1)"); idx = Index(p.Arguments[0].Value); return true; }
        if (tn == "Str") { arr = Recv(p.Instance!) + "." + UseM("b", "field Cpp.Str.b (the backing byte array; bytes 0..n-1)"); idx = Index(p.Arguments[0].Value); return true; }
        return false;
    }

    bool PtrOverArray(IPropertyReferenceOperation p, out string arr, out string idx)
    {
        arr = idx = "";
        if (!p.Property.IsIndexer || !IsRuntime(p.Property) || StripArity(p.Property.ContainingType.Name) is not ("Ptr" or "CSpan")) return false;
        var inst = p.Instance;
        while (inst is IConversionOperation cv && cv.Conversion.IsIdentity) inst = cv.Operand;
        if (inst is IObjectCreationOperation oc && oc.Constructor!.Parameters.Length == 2 && oc.Constructor.Parameters[0].Type is IArrayTypeSymbol)
        {
            var a = Recv(oc.Arguments.First(x => x.Parameter!.Ordinal == 0).Value);
            var off = oc.Arguments.First(x => x.Parameter!.Ordinal == 1).Value;
            var i = Index(p.Arguments[0].Value);
            arr = a;
            if (off.ConstantValue.HasValue && Convert.ToInt64(off.ConstantValue.Value) == 0) idx = i;
            else idx = Paren(V(off)) + " + " + Paren(i);
            Stat("ptr over array element");
            return true;
        }
        if (inst is IInvocationOperation inv && inv.TargetMethod.Name == "data" && IsRuntime(inv.TargetMethod) && StripArity(inv.TargetMethod.ContainingType.Name) == "Vec" && inv.Arguments.Length == 0)
        {
            arr = Recv(inv.Instance!) + "." + UseM("a", "field Cpp.Vec<T>.a (the backing array; elements 0..n-1)");
            idx = Index(p.Arguments[0].Value);
            Stat("vec data element");
            return true;
        }
        // any other pointer: its array and offset (a pointer to one field has a proxy array, FieldPtr)
        var r = Recv(inst!);
        if (!Simple(r)) { var t = Fresh("p"); Pre.Add(t + " = " + Strip(r)); r = t; }
        arr = r + "." + UseM("a", "field Cpp.Ptr<T>.a (the array; a FieldPtr's is a proxy table)");
        var ix0 = Index(p.Arguments[0].Value);
        idx = r + "." + UseM("o", "field Cpp.Ptr<T>.o (the offset)") + " + " + Paren(ix0);
        Stat("ptr element");
        return true;
    }

    /// <summary>*p of a pointer or a vector iterator: the element (array and index texts).</summary>
    bool DerefElem(IPropertyReferenceOperation p, out string arr, out string idx)
    {
        arr = idx = "";
        if (p.Property.Name != "Deref" || !IsRuntime(p.Property) || p.Instance == null) return false;
        var tn = StripArity(p.Property.ContainingType.Name);
        if (tn != "Ptr" && tn != "Iter") return false;
        var r = Recv(p.Instance);
        if (!Simple(r)) { var t = Fresh("p"); Pre.Add(t + " = " + Strip(r)); r = t; }
        arr = r + ".a";
        idx = r + "." + (tn == "Ptr" ? "o" : "i");
        UseM("a", "field a of Ptr and Iter (the array)"); UseM(tn == "Ptr" ? "o" : "i", "field of Ptr (o) and Iter (i): the position");
        Stat("deref element");
        return true;
    }

    Ex Prop(IPropertyReferenceOperation p, bool asRef)
    {
        var ps = p.Property;
        if (IsSystem(ps) && ps.Name == "Length") return Recv(p.Instance!) + ".n";
        if (IsSystem(ps) && ps.Name == "HasValue" && ps.ContainingType.OriginalDefinition.SpecialType == SpecialType.System_Nullable_T) return "(" + Paren(V(p.Instance!)) + " ~= nil)";
        if (IsSystem(ps) && ps.Name == "Value" && ps.ContainingType.OriginalDefinition.SpecialType == SpecialType.System_Nullable_T) return V(p.Instance!);
        if (IsSystem(ps) && ps.Name == "Message" && ps.ContainingType.Name == "Exception") return Use("exc_message", "System.Exception.Message of a caught exception (a Lua string)") + "(" + Strip(V(p.Instance!)) + ")";
        if (!IsRuntime(ps)) return Todo((IsSystem(ps) ? "system" : "engine") + " property " + ps.ContainingType.Name + "." + ps.Name);
        if (!asRef && VecElem(p, out var arr, out var idx)) return arr + "[" + idx + "]";
        if (!asRef && PtrOverArray(p, out var arr2, out var idx2)) return arr2 + "[" + idx2 + "]";
        if (!asRef && DerefElem(p, out var arr4, out var idx4)) return arr4 + "[" + idx4 + "]";
        if (IsCPtrIndexer(p) && !asRef) return Recv(p.Instance!) + ":" + UseM("get", "method CPtr.this[int] get (get(i))") + "(" + Index(p.Arguments[0].Value) + ")";
        var cn = RuntimeTypeName(ps.ContainingType);
        var nm = ps.IsIndexer ? "Item" : ps.Name;
        var sfx = ps.IsIndexer && ps.ContainingType.GetMembers().OfType<IPropertySymbol>().Count(x => x.IsIndexer) > 1 ? "_" + ShortType(ps.OriginalDefinition.Parameters[0].Type) : "";
        var args = string.Join(", ", p.Arguments.OrderBy(a => a.Parameter!.Ordinal).Select(a => Strip(ValueOf(a.Value, a.Parameter!.Type))));
        var key = "property " + ps.ContainingType.OriginalDefinition.ToDisplayString() + "." + ps.Name + (ps.IsIndexer ? "[" + string.Join(",", ps.Parameters.Select(x => x.Type.ToDisplayString())) + "]" : "");
        var recv = ps.IsStatic ? null : Recv(p.Instance!);
        if (asRef)
        {
            var rn = "ref_" + nm + sfx;
            if (ps.IsStatic) return Use(cn + "_" + rn, key + " (static, a reference: table and key)") + "(" + args + ")";
            return recv + ":" + UseM(rn, key + " (a reference: table and key)") + "(" + args + ")";
        }
        var gn = "get_" + nm + sfx;
        if (ps.IsStatic) return Use(cn + "_" + gn, key + " (static)") + "(" + args + ")";
        return recv + ":" + UseM(gn, key) + "(" + args + ")";
    }

    string PropSet(IPropertyReferenceOperation p, string v)
    {
        var ps = p.Property;
        if (!IsRuntime(ps)) return Todo("set engine property " + ps.Name);
        var sn = "set_" + ps.Name;
        if (ps.IsStatic) return Use(RuntimeTypeName(ps.ContainingType) + "_" + sn, "property set " + ps.ContainingType.OriginalDefinition.ToDisplayString() + "." + ps.Name + " (static)") + "(" + Strip(v) + ")";
        return Recv(p.Instance!) + ":" + UseM(sn, "property set " + ps.ContainingType.OriginalDefinition.ToDisplayString() + "." + ps.Name) + "(" + Strip(v) + ")";
    }

    string PropRefSet(IPropertyReferenceOperation p, string v)
    {
        var ps = p.Property;
        var nm = ps.IsIndexer ? "Item" : ps.Name;
        var sfx = ps.IsIndexer && ps.ContainingType.GetMembers().OfType<IPropertySymbol>().Count(x => x.IsIndexer) > 1 ? "_" + ShortType(ps.OriginalDefinition.Parameters[0].Type) : "";
        var args = p.Arguments.OrderBy(a => a.Parameter!.Ordinal).Select(a => Strip(ValueOf(a.Value, a.Parameter!.Type))).ToList();
        args.Add(Strip(v));
        var key = "property " + ps.ContainingType.OriginalDefinition.ToDisplayString() + "." + ps.Name + (ps.IsIndexer ? "[" + string.Join(",", ps.Parameters.Select(x => x.Type.ToDisplayString())) + "]" : "") + " (assignment through the reference: set_" + nm + sfx + "(args..., v))";
        if (ps.IsStatic) return Use(RuntimeTypeName(ps.ContainingType) + "_set_" + nm + sfx, key) + "(" + string.Join(", ", args) + ")";
        return Recv(p.Instance!) + ":" + UseM("set_" + nm + sfx, key) + "(" + string.Join(", ", args) + ")";
    }

    // ---- calls
    public string ArgList(IMethodSymbol m, IEnumerable<IArgumentOperation> args) => Args(m, args);

    string Args(IMethodSymbol m, IEnumerable<IArgumentOperation> args, bool runtime = false)
    {
        var list = args.OrderBy(a => a.Parameter?.Ordinal ?? 0).ToList();
        var texts = new List<string>();
        foreach (var a in list)
        {
            var prm = a.Parameter!;
            int pre0 = Pre.Count;
            string text;
            if (a.ArgumentKind == ArgumentKind.ParamArray)
            {
                if (a.Value is IArrayCreationOperation ac && ac.Initializer != null)
                {
                    var et = ((IArrayTypeSymbol)prm.Type).ElementType;
                    var parts = ac.Initializer.ElementValues.Select(e => runtime ? VarArg(e, et) : Strip(ValueOf(e, et))).ToList();
                    text = runtime ? string.Join(", ", parts) : ArrayLit(parts);
                    if (parts.Count == 0 && runtime) text = "";
                }
                else text = runtime ? Use("L_unpackA", "the elements of an array (table.unpack of 0 .. n - 1)") + "(" + Strip(V(a.Value)) + ")" : Strip(V(a.Value));
            }
            else if (prm.RefKind is RefKind.Ref or RefKind.Out or RefKind.In) text = RefOf(a.Value).Pair;
            else text = Strip(ValueOf(a.Value, prm.Type));
            if (Pre.Count > pre0 && texts.Count > 0) SpillEarlier(texts, pre0);
            texts.Add(text);
        }
        return string.Join(", ", texts.Where(t => t.Length > 0));
    }

    void SpillEarlier(List<string> texts, int pre0)
    {
        var ins = new List<string>();
        for (int i = 0; i < texts.Count; i++)
        {
            var t = texts[i];
            if (t.Length == 0 || IsConstText(t)) continue;
            if (TopLevelSeq(t))
            {
                // a reference (two values): each part in its own temporary
                var parts = SplitTop(t);
                var outp = new List<string>();
                foreach (var part in parts)
                {
                    if (IsConstText(part.Trim()) || part.Trim().StartsWith("\"")) { outp.Add(part.Trim()); continue; }
                    var tv0 = Fresh("arg");
                    ins.Add(tv0 + " = " + part.Trim());
                    outp.Add(tv0);
                }
                texts[i] = string.Join(", ", outp);
                continue;
            }
            var tv = Fresh("arg");
            ins.Add(tv + " = " + t);
            texts[i] = tv;
        }
        Pre.InsertRange(pre0, ins);
        Stat("arguments spilled for order");
    }

    static List<string> SplitTop(string s)
    {
        var res = new List<string>();
        int d = 0, st = 0;
        for (int i = 0; i < s.Length; i++)
        {
            var ch = s[i];
            if (ch == '"' || ch == '\'') { i = SkipStr(s, i); continue; }
            if (ch == '(' || ch == '[' || ch == '{') d++; else if (ch == ')' || ch == ']' || ch == '}') d--;
            else if (d == 0 && ch == ',') { res.Add(s.Substring(st, i - st)); st = i + 1; }
        }
        res.Add(s.Substring(st));
        return res;
    }

    static readonly System.Text.RegularExpressions.Regex ConstRx = new(@"^(\(-)?[0-9][0-9A-Fa-fx_.+\-]*\)?$|^""([^""\\]|\\.)*""$|^nil$|^true$|^false$|^K_INF$|^\(-K_INF\)$|^K_NZERO$|^K_NAN_[0-9A-F]+$|^\(-9223372036854775807 - 1\)$");

    public static bool IsLiteral(string t) => IsConstText(t) || IsConstText(Strip(t));
    public static string StripPub(string t) => Strip(t);

    static bool IsConstText(string t) => ConstRx.IsMatch(t) && !(t.Contains('(') && !t.StartsWith("(-"));

    /// <summary>A params object[] element whose C# type the runtime's printf must know is wrapped in a typed box.</summary>
    string VarArg(IOperation e, ITypeSymbol et)
    {
        var src = e is IConversionOperation cv && cv.IsImplicit && et.SpecialType == SpecialType.System_Object ? cv.Operand : e;
        if (et.SpecialType == SpecialType.System_Object && src.Type != null)
        {
            var st = Under(src.Type);
            var v = Strip(V(src));
            string? box = st.SpecialType switch
            {
                SpecialType.System_UInt32 => "U32", SpecialType.System_UInt64 => "U64", SpecialType.System_Int64 => "I64",
                SpecialType.System_Byte => "U8", SpecialType.System_SByte => "I8", SpecialType.System_Int16 => "I16", SpecialType.System_UInt16 => "U16",
                SpecialType.System_Char => "Ch", SpecialType.System_Single => "F32", _ => null
            };
            if (box != null) return Use(box, "a typed box for a params object[] argument of C# type " + st.ToDisplayString() + " (.v holds the value)") + "(" + v + ")";
            if (st.SpecialType == SpecialType.System_Boolean) return Use("Bool", "a typed box for a params object[] argument of C# type bool") + "(" + v + ")";
            return v;
        }
        return Strip(ValueOf(e, et));
    }

    Ex Invoke(IInvocationOperation inv, bool asRef)
    {
        var m = inv.TargetMethod;
        string call;
        if (!asRef && TryInline(inv, out var inl)) return inl;
        if (m.MethodKind == MethodKind.DelegateInvoke)
        {
            call = Recv(inv.Instance!) + "(" + Args(m, inv.Arguments) + ")";
            if (m.RefKind != RefKind.None) return asRef ? call : "L_deref2(" + call + ")";
            return call;
        }
        if (IsRuntime(m) && m.ContainingType.Name == "Conv" && m.Name == "D2I" && m.Parameters.Length == 1)
        {
            var a = Strip(ValueOf(inv.Arguments[0].Value, m.Parameters[0].Type));
            Stat("Conv.D2I");
            return "L_f2i32(" + a + ")";
        }
        if (IsRuntime(m) || IsSystem(m)) return RuntimeCall(m, inv.Instance, inv.Arguments, asRef);
        if (m.IsStatic) call = StaticFuncName(m) + "(" + Args(m, inv.Arguments) + ")";
        else
        {
            var mn = MethodIdent(m);
            bool baseCall = inv.Instance is IInstanceReferenceOperation ir && ir.ReferenceKind == InstanceReferenceKind.ContainingTypeInstance && !SymbolEqualityComparer.Default.Equals(m.ContainingType.OriginalDefinition, cls.OriginalDefinition)
                && ((!inv.IsVirtual && (m.IsVirtual || m.IsOverride || m.IsAbstract)) || ir.Syntax is BaseExpressionSyntax);
            if (baseCall || !IsDispatched(m))
            {
                // the function of the declaring class: C#'s call of a non-virtual method, and of base.M()
                var r = IsThis(inv.Instance) ? selfText : Strip(V(inv.Instance!));
                int pre0 = Pre.Count;
                var a = Args(m, inv.Arguments);
                if (Pre.Count > pre0 && !Simple(r) && !IsConstText(r)) { var l2 = new List<string> { r }; SpillEarlier(l2, pre0); r = l2[0]; }
                call = ClassConst(m.ContainingType) + "." + mn + "(" + r + (a.Length > 0 ? ", " + a : "") + ")";
                if (baseCall) Stat("base method called directly");
                else Stat("non-virtual method called as a function");
            }
            else
            {
                var r = IsThis(inv.Instance) ? selfText : Recv(inv.Instance!);
                int pre0 = Pre.Count;
                var a = Args(m, inv.Arguments);
                if (Pre.Count > pre0 && !Simple(r)) { var tr = Fresh("recv"); Pre.Insert(pre0, tr + " = " + Strip(r)); r = tr; }
                call = r + ":" + mn + "(" + a + ")";
            }
        }
        if (m.RefKind != RefKind.None) return asRef ? call : "L_deref2(" + call + ")";
        return call;
    }

    // ---- inlining: a non-virtual engine method whose body is one return of an expression with no side effect of its
    // own, called with arguments (and receiver) that have none either, is written in place of the call: the argument
    // texts stand for the parameters, the receiver's for this. A call costs Lua more than a few table reads.
    static readonly Dictionary<IMethodSymbol, IOperation?> inlineBodies = new(SymbolEqualityComparer.Default);
    int inlineDepth;

    static IOperation? InlineBody(IMethodSymbol m)
    {
        m = m.OriginalDefinition;
        if (inlineBodies.TryGetValue(m, out var b)) return b;
        inlineBodies[m] = null;
        IOperation? res = null;
        if (m.MethodKind == MethodKind.Ordinary && !m.IsAbstract && !m.IsVirtual && !m.IsOverride && m.RefKind == RefKind.None && !m.ReturnsVoid && !m.IsGenericMethod
            && m.Parameters.All(p => p.RefKind == RefKind.None && !addrTaken.Contains(p)) && (m.IsStatic || !IsDispatched(m)) && IsEngine(m.ContainingType))
        {
            var md = m.DeclaringSyntaxReferences.Select(r => r.GetSyntax()).OfType<MethodDeclarationSyntax>().FirstOrDefault();
            IOperation? body = md == null ? null : md.Body != null ? M(md).GetOperation(md.Body) : md.ExpressionBody != null ? M(md).GetOperation(md.ExpressionBody) : null;
            var blk = body as IBlockOperation;
            var ops = blk?.Operations.ToList();
            if (blk != null && ops != null && ops.Count == 1 && ops[0] is IReturnOperation ret && ret.ReturnedValue != null && blk.Locals.IsEmpty)
            {
                var e = ret.ReturnedValue;
                int n = e.DescendantsAndSelf().Count();
                bool ok = n <= 40 && e.DescendantsAndSelf().All(d => d is not (IAnonymousFunctionOperation or IAssignmentOperation or IIncrementOrDecrementOperation or IThrowOperation or IConditionalAccessOperation or IObjectCreationOperation or IArrayCreationOperation or IDelegateCreationOperation or ICoalesceOperation or IConditionalOperation));
                ok &= !e.DescendantsAndSelf().Any(d => d is IInvocationOperation iv && SymbolEqualityComparer.Default.Equals(iv.TargetMethod.OriginalDefinition, m));
                if (ok) res = e;
            }
        }
        inlineBodies[m] = res;
        return res;
    }

    bool TryInline(IInvocationOperation inv, out Ex result)
    {
        result = "";
        var m = inv.TargetMethod;
        if (m.MethodKind == MethodKind.DelegateInvoke || IsRuntime(m) || IsSystem(m) || inlineDepth > 4) return false;
        var e = InlineBody(m);
        if (e == null) return false;
        if (!m.IsStatic && (inv.Instance == null || !(IsThis(inv.Instance) || IsPureOp(inv.Instance)))) return false;
        foreach (var a in inv.Arguments)
            if (a.ArgumentKind != ArgumentKind.Explicit && a.ArgumentKind != ArgumentKind.DefaultValue || !IsPureOp(a.Value)) return false;
        // the uses of each parameter in the body; a parameter used more than once needs a cheap argument
        var uses = new Dictionary<IParameterSymbol, int>(SymbolEqualityComparer.Default);
        foreach (var d in e.DescendantsAndSelf()) if (d is IParameterReferenceOperation pr) uses[pr.Parameter] = uses.TryGetValue(pr.Parameter, out var c) ? c + 1 : 1;
        int pre0 = Pre.Count;
        var saved = new Dictionary<ISymbol, string?>(SymbolEqualityComparer.Default);
        string selfSaved = selfText;
        var newSelf = selfText;
        if (!m.IsStatic && !IsThis(inv.Instance)) newSelf = Recv(inv.Instance!);
        var argTexts = new Dictionary<IParameterSymbol, string>(SymbolEqualityComparer.Default);
        foreach (var a in inv.Arguments)
        {
            var t = Strip(ValueOf(a.Value, a.Parameter!.Type));
            int u = uses.TryGetValue(a.Parameter.OriginalDefinition, out var uu) ? uu : uses.TryGetValue(a.Parameter, out var uu2) ? uu2 : 0;
            if (u > 1 && !SimpleName(t) && !IsConstText(t) && !(Cheap(t) && u <= 3)) { Pre.RemoveRange(pre0, Pre.Count - pre0); return false; }
            if (!IsPrefix(t) && !IsConstText(t)) t = "(" + t + ")";
            argTexts[a.Parameter.OriginalDefinition] = t;
        }
        if (Pre.Count > pre0) { Pre.RemoveRange(pre0, Pre.Count - pre0); return false; }
        foreach (var kv in argTexts)
        {
            saved[kv.Key] = names.TryGetValue(kv.Key, out var old) ? old : null;
            names[kv.Key] = kv.Value;
        }
        selfText = newSelf;
        inlineDepth++;
        try
        {
            var v = X(e);
            var conv = ValueOf2(v, e.Type, m.ReturnType);
            result = new Ex(Paren(conv.S), conv.Raw, conv.XInt);
            Stat("inlined call");
            return true;
        }
        catch (global::Todo) { Pre.RemoveRange(pre0, Pre.Count - pre0); return false; }
        finally
        {
            inlineDepth--;
            selfText = selfSaved;
            foreach (var kv in saved) { if (kv.Value == null) names.Remove(kv.Key); else names[kv.Key] = kv.Value; }
        }
    }

    /// <summary>A value converted to the return type of an inlined method, as a return would (made clean, a float).</summary>
    Ex ValueOf2(Ex v, ITypeSymbol? from, ITypeSymbol to)
    {
        if (from != null && !SymbolEqualityComparer.Default.Equals(from, to)) v = Conv(v, from, to);
        return new Ex(Fin(v, to));
    }

    Ex RuntimeCall(IMethodSymbol m, IOperation? inst, System.Collections.Immutable.ImmutableArray<IArgumentOperation> argOps, bool asRef)
    {
        var t = m.ContainingType;
        if (IsSystem(m)) return SystemCall(m, inst, argOps);
        if (t.Name == "M" && m.IsStatic && !m.IsGenericMethod && m.Parameters.All(p => IsNumeric(p.Type)) && m.Name is "min" or "max" or "clamp")
            return InlineMinMax(m, argOps);
        if (!m.IsStatic && inst != null && m.Parameters.Length == 0 && StripArity(t.Name) is "Vec" or "Str" && m.Name is "size" or "empty" or "length")
        {
            var r = Recv(inst);
            UseM("n", "field " + (StripArity(t.Name) == "Vec" ? "Cpp.Vec<T>.n" : "Cpp.Str.n") + " (the element count; size(), length(), empty() read it)");
            return m.Name == "empty" ? "(" + r + ".n == 0)" : r + ".n";
        }
        var args = Args(m, argOps, true);
        if (m.Name == "ToString" && !m.IsStatic) return Recv(inst!) + ":" + UseM("ToString", "method ToString() of a runtime value (a Lua string)") + "()";
        var overloads = t.GetMembers(m.Name).OfType<IMethodSymbol>().Count();
        var sfx = overloads > 1 ? "_" + string.Join("_", m.OriginalDefinition.Parameters.Select(p => ShortType(p.Type) + (p.RefKind != RefKind.None ? "r" : ""))) : "";
        var spec = Spec(m.IsStatic ? t : null, m);
        var nm = m.Name + sfx + spec;
        var refm = m.RefKind != RefKind.None;
        if (refm && asRef) nm = "ref_" + nm;
        string call;
        bool maker = false;
        if (m.IsStatic && m.IsGenericMethod && spec.Length == 0 && (t.Name == "Mv" && m.Name == "Take" || t.Name == "Arr" && (m.Name == "Make" && m.Parameters.Length == 1 || m.Name == "Make2")))
        {
            args = (args.Length > 0 ? args + ", " : "") + Maker(m.TypeArguments[0]);
            maker = true;
        }
        if (m.IsStatic)
        {
            var cn = RuntimeTypeName(t);
            var full = cn + "_" + nm;
            Use(full, "static " + m.OriginalDefinition.ToDisplayString() + (spec.Length > 0 ? " " + spec : "") + (refm && asRef ? " (a reference: table and key)" : "") + (maker ? " + maker" : ""));
            call = full + "(" + args + ")";
        }
        else
        {
            var r = Recv(inst!);
            nm = UseM(nm, "method " + m.OriginalDefinition.ToDisplayString() + (spec.Length > 0 ? " " + spec : "") + (refm && asRef ? " (a reference: table and key)" : ""));
            call = r + ":" + nm + "(" + args + ")";
        }
        return call;     // a runtime member that returns a reference: its plain name returns the value, ref_<name> the reference
    }

    Ex InlineMinMax(IMethodSymbol m, System.Collections.Immutable.ImmutableArray<IArgumentOperation> argOps)
    {
        var vals = argOps.OrderBy(a => a.Parameter!.Ordinal).Select(a => Strip(ValueOf(a.Value, a.Parameter!.Type))).ToList();
        var use = new string[vals.Count];
        int pre0 = Pre.Count;
        for (int i = 0; i < vals.Count; i++)
        {
            if (Simple(vals[i]) || IsConstText(vals[i])) { use[i] = Paren(vals[i]); continue; }
            var t = Fresh("m");
            Pre.Add(t + " = " + vals[i]);
            use[i] = t;
        }
        Stat("inline " + m.Name);
        bool unsigned64 = m.Parameters.Any(p => IsULong(p.Type));
        string Lt(string a, string b) => unsigned64 ? "L_ult(" + a + ", " + b + ")" : a + " < " + b;
        string e;
        if (m.Name == "min") e = "(" + Lt(use[1], use[0]) + ") and " + use[1] + " or " + use[0];
        else if (m.Name == "max") e = "(" + Lt(use[0], use[1]) + ") and " + use[1] + " or " + use[0];
        else e = "(" + Lt(use[0], use[1]) + ") and " + use[1] + " or ((" + Lt(use[2], use[0]) + ") and " + use[2] + " or " + use[0] + ")";
        return "(" + e + ")";
    }

    Ex SystemCall(IMethodSymbol m, IOperation? inst, System.Collections.Immutable.ImmutableArray<IArgumentOperation> argOps)
    {
        var t = m.ContainingType.Name;
        string args() => Args(m, argOps);
        if (t == "Math" || t == "MathF")
        {
            var n = "Math_" + m.Name + (m.Parameters.Length > 0 ? "_" + ShortType(m.Parameters[0].Type) : "");
            if (m.Parameters.Length == 1 && IsDouble(m.Parameters[0].Type))
            {
                switch (m.Name)
                {
                    case "Sqrt": return "L_sqrt(" + args() + ")";          // math.sqrt: the C library's sqrt, which IEEE fixes
                    case "Abs": return "L_abs(" + args() + ")";            // math.abs of a float: fabs
                    case "Exp": return "L_exp(" + args() + ")";
                    case "Log": return "L_log(" + args() + ")";
                    case "Floor": return "L_floor(" + args() + ")";
                    case "Ceiling": return "L_ceil(" + args() + ")";
                    case "Sin": return "L_sin(" + args() + ")";
                    case "Cos": return "L_cos(" + args() + ")";
                }
            }
            if (m.Parameters.Length == 2 && IsDouble(m.Parameters[0].Type) && m.Name == "Pow") return "L_pow(" + args() + ")";
            if (m.Name == "Abs" && m.Parameters.Length == 1 && IsIntegral(m.Parameters[0].Type))
            {
                Use("Math_Abs_i", "System.Math.Abs of an integer");
                return "Math_Abs_i(" + args() + ")";
            }
            Use(n, "System.Math." + m.Name + "(" + string.Join(",", m.Parameters.Select(p => p.Type.Name)) + "): glibc's result");
            return n + "(" + args() + ")";
        }
        if (t == "Object" && m.Name == "ReferenceEquals") { var a = argOps.OrderBy(x => x.Parameter!.Ordinal).Select(x => V(x.Value)).ToList(); return "L_rawequal(" + Strip(a[0]) + ", " + Strip(a[1]) + ")"; }
        if (t == "Double" && m.Name == "IsFinite") return Use("is_finite", "Double.IsFinite") + "(" + args() + ")";
        if (t == "Double" && m.Name == "IsNaN") { var a = Strip(args()); if (SimpleName(a)) return "(" + a + " ~= " + a + ")"; return Use("is_nan", "Double.IsNaN") + "(" + a + ")"; }
        if (t == "Double" && m.Name == "IsInfinity") return Use("is_inf", "Double.IsInfinity") + "(" + args() + ")";
        if (t == "Double" && m.Name == "IsPositiveInfinity") return "(" + Paren(args()) + " == " + Use("K_INF", "+infinity (a constant)") + ")";
        if (t == "Double" && m.Name == "IsNegativeInfinity") return "(" + Paren(args()) + " == -" + Use("K_INF", "+infinity (a constant)") + ")";
        if (t == "Double" && m.Name == "IsNegative") return Use("signbit", "Double.IsNegative: the sign bit of a double") + "(" + args() + ")";
        if (t == "BitConverter" && m.Name == "DoubleToInt64Bits") return Use("f64_to_bits_signed", "BitConverter.DoubleToInt64Bits: the IEEE bits of a double as a signed 64-bit int") + "(" + args() + ")";
        if (t == "BitConverter" && m.Name == "Int64BitsToDouble") return Use("f64_from_bits", "the double with the given IEEE bits (a NaN constant keeps its sign and payload)") + "(" + args() + ")";
        if (t == "Array" && m.Name == "Fill") return Use("Array_Fill", "System.Array.Fill(T[], T): every element the same value") + "(" + args() + ")";
        if (t == "File" && m.Name == "Exists") return Use("File_Exists", "System.IO.File.Exists(string)") + "(" + args() + ")";
        if (m.Name == "Dispose" && inst != null) return Recv(inst) + ":Dispose()";
        if (m.Name == "GetHashCode" && inst != null) return Recv(inst) + ":" + UseM("GetHashCode", "method GetHashCode() of a runtime value") + "()";
        if (m.Name == "Equals" && inst != null) return Use("cs_equals", "object.Equals(a, b) as C# would call it") + "(" + Strip(V(inst)) + ", " + args() + ")";
        if (m.Name == "ToString" && inst != null)
        {
            var it = inst.Type!;
            if (IsIntegral(it))
            {
                if (IsULong(it)) return Use("cs_tostring_u64", "C#'s ToString() of a ulong") + "(" + Strip(V(inst)) + ")";
                return "L_tostring(" + Strip(V(inst)) + ")";
            }
            if (IsDouble(it)) return "L_tostr_d(" + Strip(V(inst)) + ")";
            return "L_tostr(" + Strip(V(inst)) + ")";
        }
        return Todo("system call " + m.ContainingType.ToDisplayString() + "." + m.Name);
    }

    Ex New(IObjectCreationOperation oc)
    {
        var t = (INamedTypeSymbol)oc.Type!;
        var c = oc.Constructor!;
        string e;
        if (t.TypeKind == TypeKind.Delegate) return Todo("delegate construction");
        if (IsEngine(t))
        {
            if (IsRawCtor(c) || IsTrivialCtor(c)) e = ClassConst(t) + "._new()";
            else e = CtorCall(c, Args(c, oc.Arguments));
        }
        else if (IsRuntime(t))
        {
            var fname = RuntimeCtorName(c, t);
            var args = MakerArgs(c, oc.Arguments, t);
            Use(fname, "new " + c.OriginalDefinition.ToDisplayString() + (SpecializedClass(t) ? " (" + t.TypeArguments[0].ToDisplayString() + ")" : "") + (args.appended ? " + makers" : ""));
            e = fname + "(" + args.text + ")";
        }
        else if (IsSystem(t))
        {
            if (t.Name.EndsWith("Exception"))
            {
                var se = Use("NewSysException", "a .NET exception object (kind, message)");
                var a0 = oc.Arguments.Length > 0 ? oc.Arguments[0].Value : null;
                var msg = a0 == null ? "\"\"" : a0.Type?.SpecialType == SpecialType.System_String && a0.ConstantValue.HasValue ? V(a0)
                    : "L_tostr(" + Strip(V(a0)) + ")";
                e = se + "(" + LuaStr(t.Name) + ", " + Strip(msg) + ")";
            }
            else return Todo("new " + t.ToDisplayString());
        }
        else return Todo("new " + t.ToDisplayString());
        if (oc.Initializer == null || oc.Initializer.Initializers.Length == 0) return e;
        var o = Fresh("o");
        Pre.Add(o + " = " + e);
        implicitRecv.Push(o);
        foreach (var init in oc.Initializer.Initializers)
        {
            var st = StmtExpr(init);
            if (st.Length > 0) foreach (var l in st.Split('\n')) Pre.Add(SafeStmt(l));
        }
        implicitRecv.Pop();
        Stat("object initializer");
        return o;
    }

    (string text, bool appended) MakerArgs(IMethodSymbol c, System.Collections.Immutable.ImmutableArray<IArgumentOperation> argOps, INamedTypeSymbol t)
    {
        var name = StripArity(t.Name);
        var specialized = SpecializedClass(t);
        var outv = new List<string>();
        bool hasFunc = false;
        int pre0 = Pre.Count;
        foreach (var a in argOps.OrderBy(a => a.Parameter?.Ordinal ?? 0))
        {
            var prm = a.Parameter!;
            int p1 = Pre.Count;
            if (prm.Type is INamedTypeSymbol ft && IsSystem(ft) && ft.Name == "Func" && ft.TypeArguments.Length == 1 && !specialized)
            {
                hasFunc = true;
                if (a.Value.ConstantValue is { HasValue: true, Value: null } || a.Value is IDefaultValueOperation || a.ArgumentKind == ArgumentKind.DefaultValue && a.Value.ConstantValue.HasValue)
                { outv.Add(Maker(ft.TypeArguments[0])); continue; }
            }
            string text;
            if (a.ArgumentKind == ArgumentKind.ParamArray)
            {
                if (a.Value is IArrayCreationOperation ac && ac.Initializer != null)
                {
                    var et = ((IArrayTypeSymbol)prm.Type).ElementType;
                    text = string.Join(", ", ac.Initializer.ElementValues.Select(e => VarArg(e, et)));
                }
                else text = Use("L_unpackA", "the elements of an array (table.unpack of 0 .. n - 1)") + "(" + Strip(V(a.Value)) + ")";
            }
            else text = prm.RefKind is RefKind.Ref or RefKind.Out ? RefOf(a.Value).Pair : Strip(ValueOf(a.Value, prm.Type));
            if (Pre.Count > p1 && outv.Count > 0) SpillEarlier(outv, p1);
            if (text.Length > 0) outv.Add(text);
        }
        bool appended = false;
        if (!specialized && !hasFunc)
        {
            if (makerSlots.TryGetValue(name, out var slots))
                foreach (var k in slots) { outv.Add(Maker(t.TypeArguments[k])); appended = true; }
            else if ((name == "Pair" || name == "Tup") && c.Parameters.Length == 0)
                foreach (var ta in t.TypeArguments) { outv.Add(Maker(ta)); appended = true; }
        }
        return (string.Join(", ", outv), appended);
    }

    /// <summary>A C# array literal: a table with the elements at 0 .. n - 1 and the length in n.</summary>
    static string ArrayLit(List<string> elems)
    {
        if (elems.Count == 0) return "{n = 0}";
        return "{[0] = " + elems[0] + (elems.Count > 1 ? ", " + string.Join(", ", elems.Skip(1)) : "") + ", n = " + elems.Count + "}";
    }

    Ex NewArray(IArrayCreationOperation ac)
    {
        var at = (IArrayTypeSymbol)ac.Type!;
        var et = at.ElementType;
        if (ac.Initializer != null)
        {
            var vals = ac.Initializer.ElementValues;
            if (vals.Any(v => v.DescendantsAndSelf().Any(d => d is IObjectCreationOperation oc0 && oc0.Initializer != null || d is IAssignmentOperation || d is IIncrementOrDecrementOperation || d is IConditionalOperation || d is ICoalesceOperation || d is IConditionalAccessOperation)))
            {
                // elements that need statements: the table first, then each element in turn, whose temporaries the
                // next one may use again (an initializer of hundreds of objects would need hundreds of locals)
                var arr = Fresh("arr");
                Pre.Add(arr + " = {n = " + vals.Length + "}");
                for (int i = 0; i < vals.Length; i++)
                {
                    int mark = inUse;
                    var x = Strip(ValueOf(vals[i], et));
                    Pre.Add(arr + "[" + i + "] = " + x);
                    inUse = mark;
                }
                Stat("array initializer element by element");
                return arr;
            }
            var elems = new List<string>();
            foreach (var v in vals)
            {
                int p1 = Pre.Count;
                var x = Strip(ValueOf(v, et));
                if (Pre.Count > p1 && elems.Count > 0) SpillEarlier(elems, p1);
                elems.Add(x);
            }
            return ArrayLit(elems);
        }
        var n = Index(ac.DimensionSizes[0]);
        var d = DefaultOf(et);
        if (d == "nil") return "{n = " + Strip(n) + "}";
        return "L_newA(" + Strip(n) + ", " + d + ")";
    }

    // ---- operators
    static string LuaOp(BinaryOperatorKind k) => k switch
    {
        BinaryOperatorKind.Add => "+", BinaryOperatorKind.Subtract => "-", BinaryOperatorKind.Multiply => "*",
        BinaryOperatorKind.Divide => "/", BinaryOperatorKind.Remainder => "%", BinaryOperatorKind.LeftShift => "<<",
        BinaryOperatorKind.RightShift => ">>", BinaryOperatorKind.And => "&", BinaryOperatorKind.Or => "|",
        BinaryOperatorKind.ExclusiveOr => "~", BinaryOperatorKind.ConditionalAnd => "and", BinaryOperatorKind.ConditionalOr => "or",
        BinaryOperatorKind.Equals => "==", BinaryOperatorKind.NotEquals => "~=", BinaryOperatorKind.LessThan => "<",
        BinaryOperatorKind.LessThanOrEqual => "<=", BinaryOperatorKind.GreaterThan => ">", BinaryOperatorKind.GreaterThanOrEqual => ">=",
        BinaryOperatorKind.UnsignedRightShift => ">>",
        _ => Todo("operator " + k)
    };

    static bool IsCompare(BinaryOperatorKind k) => k is BinaryOperatorKind.Equals or BinaryOperatorKind.NotEquals or BinaryOperatorKind.LessThan or BinaryOperatorKind.LessThanOrEqual or BinaryOperatorKind.GreaterThan or BinaryOperatorKind.GreaterThanOrEqual;

    /// <summary>l op r for operands of C# type t (after C#'s promotions); lop and rop are the operand trees when known.</summary>
    Ex BinOp(BinaryOperatorKind k, ITypeSymbol t, Ex l, Ex r, ITypeSymbol? rt, IOperation? lop, IOperation? rop)
    {
        var u = Under(t);
        if (IsIntegral(u))
        {
            int w = Width(u);
            bool us = IsUnsigned(u);
            if (w == 64)
            {
                var a = Paren(Clean(l, u)); var b = Paren(Clean(r, u));
                switch (k)
                {
                    case BinaryOperatorKind.Add: case BinaryOperatorKind.Subtract: case BinaryOperatorKind.Multiply:
                    case BinaryOperatorKind.And: case BinaryOperatorKind.Or: case BinaryOperatorKind.ExclusiveOr:
                        return "(" + a + " " + LuaOp(k) + " " + b + ")";
                    case BinaryOperatorKind.LeftShift:
                        return "(" + a + " << " + ShiftCount(r, rt, u) + ")";
                    case BinaryOperatorKind.RightShift:
                        if (us) return "(" + a + " >> " + ShiftCount(r, rt, u) + ")";
                        return "L_sar(" + Strip(a) + ", " + ShiftCount(r, rt, u) + ")";
                    case BinaryOperatorKind.UnsignedRightShift:
                        return "(" + a + " >> " + ShiftCount(r, rt, u) + ")";
                    case BinaryOperatorKind.Divide:
                        return us ? "L_udiv(" + Strip(a) + ", " + Strip(b) + ")" : "L_idiv(" + Strip(a) + ", " + Strip(b) + ")";
                    case BinaryOperatorKind.Remainder:
                        return us ? "L_umod(" + Strip(a) + ", " + Strip(b) + ")" : "L_imod(" + Strip(a) + ", " + Strip(b) + ")";
                }
                if (IsCompare(k))
                {
                    if (!us || k is BinaryOperatorKind.Equals or BinaryOperatorKind.NotEquals) return "(" + a + " " + LuaOp(k) + " " + b + ")";
                    return k switch
                    {
                        BinaryOperatorKind.LessThan => "L_ult(" + Strip(a) + ", " + Strip(b) + ")",
                        BinaryOperatorKind.GreaterThan => "L_ult(" + Strip(b) + ", " + Strip(a) + ")",
                        BinaryOperatorKind.LessThanOrEqual => "(not L_ult(" + Strip(b) + ", " + Strip(a) + "))",
                        _ => "(not L_ult(" + Strip(a) + ", " + Strip(b) + "))"
                    };
                }
                return Todo("integer operator " + k);
            }
            switch (k)
            {
                case BinaryOperatorKind.Add: case BinaryOperatorKind.Subtract:
                    return new Ex("(" + Paren(l.S) + " " + LuaOp(k) + " " + Paren(r.S) + ")", raw: true);
                case BinaryOperatorKind.Multiply:
                    return new Ex("(" + Paren(Clean(l, u)) + " * " + Paren(Clean(r, u)) + ")", raw: true);
                case BinaryOperatorKind.And:
                    {
                        bool clean = us && (!l.Raw || !r.Raw) || IsNonNegConst(l) || IsNonNegConst(r);
                        return new Ex("(" + Paren(l.S) + " & " + Paren(r.S) + ")", raw: !clean);
                    }
                case BinaryOperatorKind.Or: case BinaryOperatorKind.ExclusiveOr:
                    return new Ex("(" + Paren(l.S) + " " + LuaOp(k) + " " + Paren(r.S) + ")", raw: !us || l.Raw || r.Raw);
                case BinaryOperatorKind.LeftShift:
                    return new Ex("(" + Paren(l.S) + " << " + ShiftCount(r, rt, u) + ")", raw: true);
                case BinaryOperatorKind.RightShift:
                    {
                        var cnt = ShiftCount(r, rt, u);
                        if (us || IsNonNegConst(l)) return "(" + Paren(Clean(l, u)) + " >> " + cnt + ")";
                        // an arithmetic shift of a value in a 32-bit range: floor division by 2^n
                        if (int.TryParse(cnt, out var cn)) return "(" + Paren(Clean(l, u)) + " // " + (1L << cn).ToString(CultureInfo.InvariantCulture) + ")";
                        return "(" + Paren(Clean(l, u)) + " // (1 << " + cnt + "))";
                    }
                case BinaryOperatorKind.UnsignedRightShift:
                    {
                        var cnt = ShiftCount(r, rt, u);
                        var lv = us ? Paren(Clean(l, u)) : "(" + Paren(l.S) + " & " + MaskOf(u) + ")";
                        bool cleanRes = us || cnt.Length > 0 && char.IsDigit(cnt[0]) && cnt != "0";
                        return new Ex("(" + lv + " >> " + cnt + ")", raw: !cleanRes);
                    }
                case BinaryOperatorKind.Divide:
                    {
                        var a = Clean(l, u); var b = Clean(r, u);
                        if (us || IsNonNeg(new Ex(a)) && IsNonNegConst(new Ex(b))) return "(" + Paren(a) + " // " + Paren(b) + ")";
                        return "L_idiv(" + Strip(a) + ", " + Strip(b) + ")";
                    }
                case BinaryOperatorKind.Remainder:
                    {
                        var a = Clean(l, u); var b = Clean(r, u);
                        if (us || IsNonNeg(new Ex(a)) && IsNonNegConst(new Ex(b))) return "(" + Paren(a) + " % " + Paren(b) + ")";
                        return "L_imod(" + Strip(a) + ", " + Strip(b) + ")";
                    }
            }
            if (IsCompare(k)) return "(" + Paren(Clean(l, u)) + " " + LuaOp(k) + " " + Paren(Clean(r, u)) + ")";
            return Todo("integer operator " + k);
        }
        if (IsDouble(u))
        {
            var a = l.S; var b = r.S;
            switch (k)
            {
                case BinaryOperatorKind.Add: case BinaryOperatorKind.Subtract: case BinaryOperatorKind.Multiply:
                    if (l.XInt && r.XInt) a = Flt(a);
                    return "(" + Paren(a) + " " + LuaOp(k) + " " + Paren(b) + ")";
                case BinaryOperatorKind.Divide:
                    return "(" + Paren(a) + " / " + Paren(b) + ")";      // Lua's / of numbers is always a float division
                case BinaryOperatorKind.Remainder:
                    return "L_fmod(" + Strip(l.XInt ? Flt(a) : a) + ", " + Strip(r.XInt ? Flt(b) : b) + ")";
            }
            if (IsCompare(k))
            {
                // Lua compares an integer with a float by their exact values; an xint here is an int's value, which
                // its conversion to double keeps, so the comparison is C#'s
                return "(" + Paren(a) + " " + LuaOp(k) + " " + Paren(b) + ")";
            }
            return Todo("double operator " + k);
        }
        if (IsSingle(u))
        {
            var a = l.XInt ? Flt(l.S) : l.S; var b = r.XInt ? Flt(r.S) : r.S;
            switch (k)
            {
                case BinaryOperatorKind.Add: case BinaryOperatorKind.Subtract: case BinaryOperatorKind.Multiply:
                    return "L_f32(" + Paren(a) + " " + LuaOp(k) + " " + Paren(b) + ")";
                case BinaryOperatorKind.Divide: return "L_f32(" + Paren(a) + " / " + Paren(b) + ")";
                case BinaryOperatorKind.Remainder:
                    return "L_f32(L_fmod(" + Strip(a) + ", " + Strip(b) + "))";
            }
            if (IsCompare(k)) return "(" + Paren(a) + " " + LuaOp(k) + " " + Paren(b) + ")";
            return Todo("float operator " + k);
        }
        if (u.SpecialType == SpecialType.System_Boolean)
        {
            switch (k)
            {
                case BinaryOperatorKind.And: return "L_bAnd(" + Strip(l.S) + ", " + Strip(r.S) + ")";
                case BinaryOperatorKind.Or: return "L_bOr(" + Strip(l.S) + ", " + Strip(r.S) + ")";
                case BinaryOperatorKind.ExclusiveOr: return "L_bXor(" + Strip(l.S) + ", " + Strip(r.S) + ")";
                case BinaryOperatorKind.Equals: return "(" + Paren(l.S) + " == " + Paren(r.S) + ")";
                case BinaryOperatorKind.NotEquals: return "(" + Paren(l.S) + " ~= " + Paren(r.S) + ")";
            }
        }
        if (k is BinaryOperatorKind.Equals or BinaryOperatorKind.NotEquals)
        {
            var eq = k == BinaryOperatorKind.Equals;
            return "(" + Paren(l.S) + (eq ? " == " : " ~= ") + Paren(r.S) + ")";
        }
        return Todo("operator " + k + " on " + t.ToDisplayString());
    }

    static bool IsNonNegConst(Ex e) => !e.Raw && e.S.Length > 0 && char.IsDigit(e.S[0]) && e.S.All(char.IsLetterOrDigit) && !e.S.StartsWith("0x");

    static string ShiftCount(Ex r, ITypeSymbol? rt, ITypeSymbol lt)
    {
        int mask = Width(lt) == 64 ? 63 : 31;
        if (long.TryParse(r.S, out var c)) return (c & mask).ToString(CultureInfo.InvariantCulture);
        var cr = rt != null ? Clean(r, rt) : r.S;
        return "(" + Paren(cr) + " & " + mask + ")";
    }

    static bool ConstIs(IOperation? op, Func<double, bool> pred)
    {
        if (op == null || !op.ConstantValue.HasValue) return false;
        var v = op.ConstantValue.Value;
        double d = v switch { double x => x, float f => f, int i => i, long l => l, uint u => u, ulong ul => ul, short s => s, ushort us => us, byte b => b, sbyte sb => sb, _ => double.NaN };
        return pred(d);
    }

    /// <summary>An operand with no side effect (read twice, it gives the same value): a variable, a field, an element,
    /// a constant, and arithmetic or conversions of those.</summary>
    static bool IsPureOp(IOperation op)
    {
        switch (op)
        {
            case ILiteralOperation: return true;
            case ILocalReferenceOperation: case IParameterReferenceOperation: case IInstanceReferenceOperation: return true;
            case IFieldReferenceOperation f: return f.Instance == null || IsPureOp(f.Instance);
            case IArrayElementReferenceOperation ae: return IsPureOp(ae.ArrayReference) && ae.Indices.All(IsPureOp);
            case IPropertyReferenceOperation p when (IsVecIndexer(p) || IsPtrIndexer(p)) && p.Arguments.Length == 1: return IsPureOp(p.Instance!) && IsPureOp(p.Arguments[0].Value);
            case IConversionOperation cv when cv.OperatorMethod == null: return IsPureOp(cv.Operand);
            case IParenthesizedOperation pp: return IsPureOp(pp.Operand);
        }
        return op.ConstantValue.HasValue;
    }

    /// <summary>Text that is cheap to evaluate twice: no call, no function, not long.</summary>
    static bool Cheap(string s) => s.Length < 120 && !s.Contains("function") && !System.Text.RegularExpressions.Regex.IsMatch(s, @"[A-Za-z_]\w*\(") && !s.Contains(":");

    Ex Binary(IBinaryOperation b)
    {
        if (b.OperatorMethod != null)
        {
            if (IsSystem(b.OperatorMethod) && b.OperatorMethod.ContainingType.SpecialType == SpecialType.System_String)
            {
                if (b.OperatorKind == BinaryOperatorKind.Add) return StrConcat(b.LeftOperand, b.RightOperand);
                var a0 = V(b.LeftOperand); var b0 = V(b.RightOperand);
                if (b.OperatorKind == BinaryOperatorKind.Equals) return "(" + Paren(a0) + " == " + Paren(b0) + ")";
                if (b.OperatorKind == BinaryOperatorKind.NotEquals) return "(" + Paren(a0) + " ~= " + Paren(b0) + ")";
            }
            if (IsSystem(b.OperatorMethod) && b.OperatorMethod.ContainingType.TypeKind == TypeKind.Delegate)
            {
                var a0 = V(b.LeftOperand); var b0 = V(b.RightOperand);
                if (b.OperatorKind == BinaryOperatorKind.Equals) return "L_rawequal(" + Strip(a0) + ", " + Strip(b0) + ")";
                if (b.OperatorKind == BinaryOperatorKind.NotEquals) return "(not L_rawequal(" + Strip(a0) + ", " + Strip(b0) + "))";
            }
            var lv = ValueOf(b.LeftOperand, b.OperatorMethod.Parameters[0].Type);
            int pre0 = Pre.Count;
            var rv = ValueOf(b.RightOperand, b.OperatorMethod.Parameters[1].Type);
            if (Pre.Count > pre0 && !Simple(lv) && !IsConstText(lv)) { var l2 = new List<string> { lv }; SpillEarlier(l2, pre0); lv = l2[0]; }
            return UserBinary(b.OperatorMethod, lv, rv);
        }
        var k = b.OperatorKind;
        if (k is BinaryOperatorKind.ConditionalAnd or BinaryOperatorKind.ConditionalOr) return Logical(b);
        var lt = b.LeftOperand.Type;
        var l = X(b.LeftOperand);
        int p0 = Pre.Count;
        var r = X(b.RightOperand);
        if (Pre.Count > p0 && !Simple(l.S) && !IsConstText(l.S))
        {
            var tv = Fresh("l");
            Pre.Insert(p0, tv + " = " + Strip(l.XInt ? l.S : Clean(l, lt)));
            l = new Ex(tv, false, l.XInt);
            Stat("binary operand spilled for order");
        }
        if ((lt != null && lt.SpecialType == SpecialType.System_String || b.Type?.SpecialType == SpecialType.System_String) && k == BinaryOperatorKind.Add) return StrConcat(b.LeftOperand, b.RightOperand);
        if (k is BinaryOperatorKind.Equals or BinaryOperatorKind.NotEquals && (IsNullConst(b.LeftOperand) || IsNullConst(b.RightOperand)))
        {
            var other = IsNullConst(b.RightOperand) ? l.S : r.S;
            return "(" + Paren(other) + (k == BinaryOperatorKind.Equals ? " == nil)" : " ~= nil)");
        }
        var opT = lt ?? b.Type!;
        return BinOp(k, opT, l, r, b.RightOperand.Type, b.LeftOperand, b.RightOperand);
    }

    static bool IsNullConst(IOperation op)
    {
        while (op is IConversionOperation cv && cv.OperatorMethod == null) op = cv.Operand;
        return op.ConstantValue is { HasValue: true, Value: null } || op is IDefaultValueOperation dv && dv.Type != null && !dv.Type.IsValueType;
    }

    Ex Logical(IBinaryOperation b)
    {
        bool and = b.OperatorKind == BinaryOperatorKind.ConditionalAnd;
        var l = V(b.LeftOperand);
        var saved = Pre; Pre = new List<string>();
        var r = V(b.RightOperand);
        var pr = Pre; Pre = saved;
        if (pr.Count == 0) return "(" + Paren(l) + (and ? " and " : " or ") + Paren(r) + ")";
        var t = Fresh("c");
        Pre.Add(t + " = " + Strip(l));
        Pre.Add((and ? "if " : "if not ") + t + " then");
        foreach (var s in pr) foreach (var s2 in s.Split('\n')) Pre.Add("  " + s2);
        Pre.Add("  " + t + " = " + Strip(r));
        Pre.Add("end");
        Stat("logical with statements");
        return t;
    }

    Ex StrConcat(IOperation a, IOperation b) => "(" + StrPart(a) + " .. " + StrPart(b) + ")";

    string StrPart(IOperation o)
    {
        while (o is IConversionOperation cv && cv.OperatorMethod == null && cv.Type?.SpecialType == SpecialType.System_Object) o = cv.Operand;
        var t = o.Type;
        var v = V(o);
        if (t == null) return "\"\"";
        if (t.SpecialType == SpecialType.System_String) return IsNullConst(o) ? "\"\"" : o is ILiteralOperation || o.ConstantValue.HasValue || o is IBinaryOperation ? Paren(v) : "(" + Paren(v) + " or \"\")";
        if (t.SpecialType == SpecialType.System_Char) return "L_chr(" + Strip(v) + ")";
        if (IsIntegral(t)) return IsULong(t) ? Use("cs_tostring_u64", "C#'s ToString() of a ulong") + "(" + Strip(v) + ")" : Paren(v);
        if (t.SpecialType == SpecialType.System_Boolean) return "(" + Paren(v) + " and \"True\" or \"False\")";
        if (IsDouble(t)) return "L_tostr_d(" + Strip(v) + ")";
        return "L_tostr(" + Strip(v) + ")";
    }

    Ex UserBinary(IMethodSymbol op, string l, string r)
    {
        var t = op.ContainingType;
        var opn = op.Name switch
        {
            "op_Equality" => "op_Eq", "op_Inequality" => "op_Ne", "op_Addition" => "op_Add", "op_Subtraction" => "op_Sub",
            "op_LessThan" => "op_Lt", "op_GreaterThan" => "op_Gt", "op_LessThanOrEqual" => "op_Le", "op_GreaterThanOrEqual" => "op_Ge",
            "op_Multiply" => "op_Mul", "op_Division" => "op_Div",
            _ => Todo("user operator " + op.Name)
        };
        if (!IsRuntime(op)) return Todo("engine operator");
        var overloads = t.GetMembers(op.Name).OfType<IMethodSymbol>().Count();
        var sfx = overloads > 1 ? "_" + string.Join("_", op.OriginalDefinition.Parameters.Select(p => ShortType(p.Type))) : "";
        var spec = Spec(t, null);
        var n = RuntimeTypeName(t) + "_" + opn + sfx + spec;
        Use(n, "operator " + op.ToDisplayString());
        return n + "(" + Strip(l) + ", " + Strip(r) + ")";
    }

    Ex Unary(IUnaryOperation u)
    {
        if (u.OperatorMethod != null) return Todo("user unary operator");
        var o = X(u.Operand);
        var t = u.Operand.Type!;
        switch (u.OperatorKind)
        {
            case UnaryOperatorKind.Minus:
                if (IsIntegral(t))
                {
                    if (Width(t) == 64) return new Ex("(-" + Paren(Clean(o, t)) + ")");
                    return new Ex("(-" + Paren(o.S) + ")", raw: true);
                }
                // IEEE negation (flips the sign of a zero and of a NaN): an int's value is made a float first
                if (o.XInt) return "(-" + Flt(o.S) + ")";
                return "(-" + Paren(o.S) + ")";
            case UnaryOperatorKind.Plus: return o;
            case UnaryOperatorKind.BitwiseNegation:
                if (Width(t) == 64) return "(~" + Paren(Clean(o, t)) + ")";
                if (IsUnsigned(t)) return new Ex("(" + Paren(o.S) + " ~ " + MaskOf(t) + ")", raw: o.Raw);
                return new Ex("(~" + Paren(o.S) + ")", raw: true);
            case UnaryOperatorKind.Not: return "(not " + Paren(o.S) + ")";
        }
        return Todo("unary " + u.OperatorKind);
    }

    /// <summary>Whether a value of type t is never false or nil in Lua, so (c and a or b) chooses a.</summary>
    static bool Truthy(ITypeSymbol? t, string text)
    {
        if (t == null) return false;
        if (IsNumeric(t)) return true;
        if (IsStructType(t)) return true;
        if (t.SpecialType == SpecialType.System_String && text.StartsWith("\"")) return true;
        return false;
    }

    Ex Ternary(IConditionalOperation c)
    {
        var cond = Cond(c.Condition);
        var t = c.Type!;
        if (c.IsRef) return RefOf(c).Deref;
        var saved = Pre; Pre = new List<string>();
        var ae = X(c.WhenTrue);
        var a = Conv(ae, c.WhenTrue.Type ?? t, t); var pa = Pre; Pre = new List<string>();
        var be = X(c.WhenFalse!);
        var bb = Conv(be, c.WhenFalse!.Type ?? t, t); var pb = Pre; Pre = saved;
        bool xint = a.XInt && bb.XInt;
        string sa = xint ? Clean(a, t) : Fin(a, t), sb = xint ? Clean(bb, t) : Fin(bb, t);
        if (pa.Count > 0 || pb.Count > 0 || !Truthy(t, sa))
        {
            var tv = Fresh("t");
            Pre.Add("if " + Strip(cond) + " then");
            foreach (var s in pa) foreach (var s2 in s.Split('\n')) Pre.Add("  " + s2);
            Pre.Add("  " + tv + " = " + Strip(sa));
            Pre.Add("else");
            foreach (var s in pb) foreach (var s2 in s.Split('\n')) Pre.Add("  " + s2);
            Pre.Add("  " + tv + " = " + Strip(sb));
            Pre.Add("end");
            Stat(pa.Count > 0 || pb.Count > 0 ? "conditional with statements" : "conditional that may be false or nil (hoisted)");
            return new Ex(tv, xint: xint);
        }
        return new Ex("(" + Paren(cond) + " and " + Paren(sa) + " or " + Paren(sb) + ")", xint: xint);
    }

    Ex CondAccess(IConditionalAccessOperation ca)
    {
        var recv = V(ca.Operation);
        var r = recv;
        if (!Simple(recv)) { r = Fresh("ca"); Pre.Add(r + " = " + Strip(recv)); }
        condAccess.Push(r);
        var saved = Pre; Pre = new List<string>();
        var inner = V(ca.WhenNotNull);
        var ip = Pre; Pre = saved;
        condAccess.Pop();
        var t = ca.Type!;
        var none = IsStructType(t) || IsNumeric(t) || t.SpecialType == SpecialType.System_Boolean ? DefaultOf(t) : "nil";
        if (t is INamedTypeSymbol nt && nt.OriginalDefinition.SpecialType == SpecialType.System_Nullable_T) none = "nil";
        if (ip.Count > 0 || none != "nil")
        {
            var tv = Fresh("t");
            Pre.Add(tv + " = " + none);
            Pre.Add("if " + r + " ~= nil then");
            foreach (var s in ip) foreach (var s2 in s.Split('\n')) Pre.Add("  " + s2);
            Pre.Add("  " + tv + " = " + Strip(inner));
            Pre.Add("end");
            return tv;
        }
        // (r and x): nil when r is nil, else x (whatever x is, false and nil included)
        return "(" + r + " and " + Paren(inner) + ")";
    }

    // ---- lambdas: function (params) ... end, written in place. Lua's closures capture variables, as C#'s do, and a
    // local in a loop body is a fresh variable each iteration, so no binding is needed.
    Ex Lambda(IAnonymousFunctionOperation af, ITypeSymbol? target)
    {
        var m = af.Symbol;
        var sub = new LuaFn(this, m, baseInd + 1);
        var ps = new List<string>();
        foreach (var p in m.Parameters) ps.AddRange(sub.DeclareParam(p));
        var ops = af.Body.Operations;
        var body = new List<string>();
        if (ops.Length >= 1 && ops[0] is IReturnOperation ret && ret.ReturnedValue != null)
        {
            string e;
            if (sub.retRef) e = sub.RefOf(ret.ReturnedValue).Pair;
            else e = Strip(sub.ValueOf(ret.ReturnedValue, sub.retType));
            if (sub.Pre.Count == 0 && sub.temps.Count == 0 && sub.paramCells.Count == 0)
            {
                Stat("expression lambda");
                return "function(" + string.Join(", ", ps) + ") return " + e + " end";
            }
            sub.FlushTo(body, 1);
            body.Add(Ind(1) + "do return " + e + " end");
        }
        else sub.Block(ops, body, 1);
        var pro = sub.FuncPrologue(1);
        var sb = new StringBuilder();
        sb.Append("function(").Append(string.Join(", ", ps)).Append(")\n");
        foreach (var l in pro.Split('\n')) if (l.Length > 0) sb.Append(l).Append('\n');
        foreach (var l in body) sb.Append(l).Append('\n');
        sb.Append("end");
        Stat("lambda with statements");
        return sb.ToString();
    }

    Ex DelegateCreation(IDelegateCreationOperation dc)
    {
        var t = dc.Type!;
        if (dc.Target is IAnonymousFunctionOperation af) return Lambda(af, t);
        if (dc.Target is IMethodReferenceOperation mr)
        {
            var m = mr.Method;
            if (IsRuntime(m))
            {
                if (m.IsStatic)
                {
                    var overloads = m.ContainingType.GetMembers(m.Name).OfType<IMethodSymbol>().Count();
                    var sfx = overloads > 1 ? "_" + string.Join("_", m.OriginalDefinition.Parameters.Select(p => ShortType(p.Type) + (p.RefKind != RefKind.None ? "r" : ""))) : "";
                    var n = RuntimeTypeName(m.ContainingType) + "_" + m.Name + sfx + Spec(m.ContainingType, m);
                    return Use(n, "static " + m.OriginalDefinition.ToDisplayString() + " (as a function value)");
                }
                return Use("bind_method", "a method of a runtime object as a function value (the object bound)") + "(" + Strip(V(mr.Instance!)) + ", \"" + UseM(m.Name, "method " + m.OriginalDefinition.ToDisplayString() + " (as a bound method)") + "\")";
            }
            if (m.IsStatic) return StaticFuncName(m);
            var recv = IsThis(mr.Instance) ? selfText : Strip(V(mr.Instance!));
            if (IsDispatched(m)) return "(function(o_) return function(...) return o_:" + MethodIdent(m) + "(...) end end)(" + recv + ")";
            return "(function(o_) return function(...) return " + ClassConst(m.ContainingType) + "." + MethodIdent(m) + "(o_, ...) end end)(" + recv + ")";
        }
        return Todo("delegate creation " + dc.Target.Kind);
    }
}
}
