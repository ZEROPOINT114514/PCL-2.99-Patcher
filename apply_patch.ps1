# apply_patch.ps1
# ---------------------------------------------------------------------------
# Single-point IL patch for PCL (Plain Craft Launcher 2) 2.99.0.0 (build 413).
#
# Purpose: restore the official "download vanilla Minecraft" feature that the
#          vendor disabled at compile time via
#          `Public Const RestrictMcDownload As Boolean = True`
#          (Modules/ModSecret.vb). Because it is a Const, the compiler folded
#          every `If RestrictMcDownload` and deleted the real code paths.
#          The download engine itself is intact: PCL.ModDownload still owns the
#          static field DlClientListLoader, initialised by PCL.ModDownload::.cctor.
#
# Scope:   Only PCL.PageDownloadInstall::LoaderInit() is touched.
#          The 13 instructions that build a *dummy* LoaderTask (its onFinish
#          shows the "download disabled" message) are replaced by a single
#          `ldsfld PCL.ModDownload::DlClientListLoader`. The real onFinish
#          callback (_Lambda$__R3-4), the `ldnull`, `ldc.i4.1` flag and the
#          PageLoaderInit call are left untouched.
#
# Stack safety:
#          The removed range (ldstr .. newobj LoaderTask::.ctor) has a net
#          stack effect of +1: it pushes exactly one LoaderTask reference and
#          leaves all previously pushed arguments balanced, because the 4-arg
#          ctor pops the ldstr/Action/ldnull/ldc.i4.2 it was handed.
#          `ldsfld` also has a net effect of +1, so the stack is exactly
#          balanced at the join point of the following instruction.
#
# Assembly resolution:
#          The vendor's exe references assemblies that are not shipped next to
#          it (PCLCS, MeloongCore, ...). Cecil still has to *resolve* some of
#          those types while rebuilding the Constant metadata table
#          (MetadataBuilder.GetConstantType -> TypeReference.CheckedResolve),
#          so a plain Cecil rewrite fails with "Failed to resolve assembly".
#          A stub resolver therefore synthesises a placeholder assembly that
#          mirrors the type names referenced from the patched module. Placeholder
#          types are plain classes (never enums), which reproduces the original
#          ELEMENT_TYPE_CLASS encoding Cecil wrote for those constants.
#          The result of this rewrite is validated by a full semantic diff
#          against a control round-trip (see verify_models.ps1), so any
#          placeholder-induced metadata drift would be caught.
#
# Idempotent: re-running on an already patched assembly is a no-op.
#
# This file intentionally contains NO non-ASCII string literals. The expected
# ldstr payload is compared via code points so the script behaves identically
# whether PowerShell parses it as ANSI/GBK or UTF-8.
# ---------------------------------------------------------------------------

[CmdletBinding()]
param(
    [string]$InPath  = (Join-Path $PSScriptRoot 'PCL-2.99.0-orig.exe'),
    [string]$OutPath = (Join-Path $PSScriptRoot 'PCL-2.99.0-unlocked.exe'),
    [string]$CecilPath = (Join-Path $PSScriptRoot 'Mono.Cecil.dll'),
    # Writes a control round-trip (read + rewrite, NO IL change). Used by the
    # differential verification: control-vs-patched must differ only in
    # LoaderInit, and original-vs-control must be semantically identical.
    [switch]$NoPatch
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---- Expected ldstr payload: U+5173 U+95ED U+4E0B U+8F7D -------------------
$expectedName = -join @([char]0x5173, [char]0x95ED, [char]0x4E0B, [char]0x8F7D)
$expectedCodepoints = '5173 95ED 4E0B 8F7D'

# Generic arity marker '`' (U+0060 / char 0x60). NEVER write it inside a -like
# pattern: PowerShell's WildcardPattern treats the backtick as its escape
# character, so a literal '`2' in a pattern will not match '`2' in the subject.
# All signature matching below uses .Contains() / .StartsWith() with these
# pre-built literals instead.
$tick = [string][char]0x60
$loaderTaskArity = 'LoaderTask' + $tick + '2'
$actionArity = 'Action' + $tick + '1'
$loaderTaskCtorPrefix = 'System.Void PCL.ModLoader/' + $loaderTaskArity
$dummyClosureField = '_Closure$__::$IR3-3'
$dummyClosureMethod = '_Lambda$__R3-3'
$realOnFinishMethod = '_Lambda$__R3-4'

$fieldName = 'DlClientListLoader'
$expectedFieldType = 'PCL.ModLoader/' + $loaderTaskArity + '<System.String,PCL.ModDownload/DlClientListResult>'

function Get-Codepoints {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '<empty>' }
    return (($Text.ToCharArray() | ForEach-Object { '{0:X4}' -f [int]$_ }) -join ' ')
}

function Format-Instruction {
    param($Instruction)
    $operand = ''
    if ($null -ne $Instruction.Operand) {
        if ($Instruction.Operand -is [Mono.Cecil.Cil.Instruction]) {
            $operand = ('IL_{0:X4}' -f $Instruction.Operand.Offset)
        }
        else {
            $operand = $Instruction.Operand.ToString()
        }
    }
    $operand = ($operand -replace '\s+', ' ')
    return ('IL_{0:X4}: {1,-12} {2}' -f $Instruction.Offset, $Instruction.OpCode.Name, $operand)
}

function Test-LoaderTaskCtorText {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    return ($Text.StartsWith($loaderTaskCtorPrefix) -and $Text.Contains('::.ctor('))
}

function Dump-Method {
    param($Method, [string]$Title)
    Write-Output ''
    Write-Output ('--- ' + $Title + ' ---')
    Write-Output ('  Signature : ' + $Method.FullName)
    Write-Output ('  CodeSize  : ' + $Method.Body.CodeSize + '  MaxStack=' + $Method.Body.MaxStackSize + '  EH=' + $Method.Body.ExceptionHandlers.Count)
    foreach ($i in $Method.Body.Instructions) {
        Write-Output ('    ' + (Format-Instruction $i))
    }
}

if (-not (Test-Path -LiteralPath $InPath)) { throw ('Input assembly not found: ' + $InPath) }
if (-not (Test-Path -LiteralPath $CecilPath)) { throw ('Mono.Cecil.dll not found: ' + $CecilPath) }
if ([System.IO.Path]::GetFullPath($InPath) -eq [System.IO.Path]::GetFullPath($OutPath)) {
    throw 'InPath and OutPath must differ; refusing to overwrite the source assembly.'
}

if (-not ('Mono.Cecil.AssemblyDefinition' -as [type])) {
    Add-Type -Path $CecilPath
}

# ===========================================================================
# 0. Stub assembly resolver
#    Cecil must resolve types from assemblies that are merged into the exe but
#    not present as files on disk (PCLCS, MeloongCore, ...). During the metadata
#    rebuild it asks whether such a type is an enum
#    (MetadataBuilder.GetConstantType -> TypeReference.CheckedResolve), so the
#    placeholder types are recreated as enums whenever the source module used
#    one of them for a default value. That keeps the emitted Constant rows
#    byte-faithful; every other placeholder stays a plain class.
# ===========================================================================
$resolverSource = @'
using System;
using System.Collections.Generic;
using System.IO;
using Mono.Cecil;

public class PclStubResolver : IAssemblyResolver
{
    public readonly List<string> Log = new List<string>();
    public readonly List<string> Stubbed = new List<string>();
    public readonly List<string> FromDisk = new List<string>();

    private readonly DefaultAssemblyResolver inner = new DefaultAssemblyResolver();
    private readonly Dictionary<string, AssemblyDefinition> stubs = new Dictionary<string, AssemblyDefinition>();

    // Type full name -> runtime CLR type of the default value that the source
    // module supplies for a parameter/field of that type. Lets a placeholder be
    // recreated as an enum with the original underlying type.
    private readonly Dictionary<string, Type> constantHints = new Dictionary<string, Type>();

    private ModuleDefinition source;

    public PclStubResolver()
    {
    }

    // Set after the target assembly has been read. Assigning it analyses the
    // default values of the module, which the placeholder factory needs.
    public ModuleDefinition Source
    {
        get { return source; }
        set
        {
            source = value;
            BuildConstantHints();
        }
    }

    public void AddSearchDirectory(string directory)
    {
        if (String.IsNullOrEmpty(directory)) return;
        if (!Directory.Exists(directory)) return;
        inner.AddSearchDirectory(directory);
    }

    public AssemblyDefinition Resolve(AssemblyNameReference name)
    {
        return Resolve(name, new ReaderParameters());
    }

    public AssemblyDefinition Resolve(AssemblyNameReference name, ReaderParameters parameters)
    {
        Log.Add(name.FullName);

        try
        {
            AssemblyDefinition found = inner.Resolve(name, parameters);
            FromDisk.Add(name.Name);
            return found;
        }
        catch (AssemblyResolutionException)
        {
            // fall through to the stub
        }

        Stubbed.Add(name.FullName);
        AssemblyDefinition cached;
        if (stubs.TryGetValue(name.Name, out cached)) return cached;

        AssemblyDefinition stub = AssemblyDefinition.CreateAssembly(
            new AssemblyNameDefinition(name.Name, name.Version),
            name.Name,
            ModuleKind.Dll);

        PopulateStub(stub, name.Name);
        stubs[name.Name] = stub;
        return stub;
    }

    private void PopulateStub(AssemblyDefinition stub, string scopeName)
    {
        if (source == null) return;

        foreach (TypeReference tr in source.GetTypeReferences())
        {
            if (tr.Scope == null) continue;
            if (tr.Scope.Name != scopeName) continue;
            EnsureType(stub.MainModule, tr.FullName);
        }
    }

    // For every default value in the source module, remember the runtime CLR
    // type of that constant. Cecil consults the resolver to learn whether such
    // a type is an enum while it rebuilds the Constant table, so a placeholder
    // recreated as a plain class would silently turn e.g. "Level = 1" into
    // "Level = null" for enum-typed optional parameters.
    private void BuildConstantHints()
    {
        constantHints.Clear();
        if (source == null) return;

        foreach (TypeDefinition type in source.GetTypes())
        {
            foreach (FieldDefinition field in type.Fields)
            {
                if (!field.HasConstant) continue;
                if (field.Constant == null) continue;
                RegisterConstantHint(field.FieldType, field.Constant);
            }

            foreach (MethodDefinition method in type.Methods)
            {
                if (!method.HasParameters) continue;
                foreach (ParameterDefinition parameter in method.Parameters)
                {
                    if (!parameter.HasConstant) continue;
                    if (parameter.Constant == null) continue;
                    RegisterConstantHint(parameter.ParameterType, parameter.Constant);
                }
            }
        }
    }

    private void RegisterConstantHint(TypeReference declaredType, object constant)
    {
        if (declaredType == null) return;
        string name = declaredType.FullName;
        if (String.IsNullOrEmpty(name)) return;
        if (constantHints.ContainsKey(name)) return;
        constantHints[name] = constant.GetType();
    }

    private static TypeReference MapSystemType(TypeSystem types, Type clrType)
    {
        if (clrType == typeof(bool)) return types.Boolean;
        if (clrType == typeof(char)) return types.Char;
        if (clrType == typeof(sbyte)) return types.SByte;
        if (clrType == typeof(byte)) return types.Byte;
        if (clrType == typeof(short)) return types.Int16;
        if (clrType == typeof(ushort)) return types.UInt16;
        if (clrType == typeof(int)) return types.Int32;
        if (clrType == typeof(uint)) return types.UInt32;
        if (clrType == typeof(long)) return types.Int64;
        if (clrType == typeof(ulong)) return types.UInt64;
        if (clrType == typeof(float)) return types.Single;
        if (clrType == typeof(double)) return types.Double;
        if (clrType == typeof(string)) return types.String;
        return null;
    }

    private TypeDefinition EnsureType(ModuleDefinition module, string fullName)
    {
        // Nested types are separated by '/' in Cecil's FullName.
        string[] parts = fullName.Split('/');
        TypeDefinition parent = null;

        for (int i = 0; i < parts.Length; i++)
        {
            string part = parts[i];
            int lt = part.IndexOf('<');
            if (lt > 0) part = part.Substring(0, lt);
            if (part.Length == 0) continue;

            string ns = String.Empty;
            string simple = part;
            int dot = part.LastIndexOf('.');
            if (dot > 0)
            {
                ns = part.Substring(0, dot);
                simple = part.Substring(dot + 1);
            }

            TypeDefinition existing = FindType(module, parent, ns, simple);
            if (existing != null)
            {
                parent = existing;
                continue;
            }

            string partialName = (parent == null) ? part : (parent.FullName + "/" + simple);

            Type clrConstantType;
            TypeReference underlying = null;
            if (constantHints.TryGetValue(partialName, out clrConstantType))
            {
                underlying = MapSystemType(module.TypeSystem, clrConstantType);
            }

            TypeDefinition created;
            if (underlying != null)
            {
                // Recreate as an enum so Cecil recomputes the very same
                // ELEMENT_TYPE the original compiler emitted for this default.
                // Cecil's TypeSystem exposes no Enum reference, so import it.
                TypeReference enumBase = module.ImportReference(typeof(System.Enum));
                created = new TypeDefinition(
                    ns,
                    simple,
                    TypeAttributes.Public | TypeAttributes.Sealed | TypeAttributes.AnsiClass,
                    enumBase);
                created.Fields.Add(new FieldDefinition(
                    "value__",
                    FieldAttributes.Public | FieldAttributes.SpecialName | FieldAttributes.RTSpecialName,
                    underlying));
            }
            else
            {
                created = new TypeDefinition(
                    ns,
                    simple,
                    TypeAttributes.Public | TypeAttributes.Class | TypeAttributes.AnsiClass | TypeAttributes.BeforeFieldInit,
                    module.TypeSystem.Object);
            }

            if (parent == null)
            {
                module.Types.Add(created);
            }
            else
            {
                created.Attributes = (created.Attributes & ~TypeAttributes.VisibilityMask) | TypeAttributes.NestedPublic;
                parent.NestedTypes.Add(created);
            }

            parent = created;
        }

        return parent;
    }

    private static TypeDefinition FindType(ModuleDefinition module, TypeDefinition parent, string ns, string simple)
    {
        if (parent == null)
        {
            foreach (TypeDefinition t in module.Types)
                if (t.Name == simple && t.Namespace == ns) return t;
        }
        else
        {
            foreach (TypeDefinition t in parent.NestedTypes)
                if (t.Name == simple) return t;
        }
        return null;
    }

    public void Dispose()
    {
        inner.Dispose();
        foreach (AssemblyDefinition stub in stubs.Values)
        {
            try { stub.Dispose(); } catch { }
        }
        stubs.Clear();
        constantHints.Clear();
    }
}
'@

if (-not ('PclStubResolver' -as [type])) {
    Add-Type -TypeDefinition $resolverSource -ReferencedAssemblies $CecilPath -Language CSharp
}

# ===========================================================================
# 1. Read the source assembly
# ===========================================================================
$resolver = New-Object PclStubResolver
$resolver.AddSearchDirectory($PSScriptRoot)
$resolver.AddSearchDirectory((Split-Path -Parent ([System.IO.Path]::GetFullPath($InPath))))
$resolver.AddSearchDirectory((Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'))
$resolver.AddSearchDirectory((Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\WPF'))
$resolver.AddSearchDirectory((Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319'))
$resolver.AddSearchDirectory((Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\WPF'))

$readerParams = New-Object Mono.Cecil.ReaderParameters
$readerParams.ReadWrite = $false
$readerParams.AssemblyResolver = $resolver

$asm = [Mono.Cecil.AssemblyDefinition]::ReadAssembly($InPath, $readerParams)
$resolver.Source = $asm.MainModule

$srcInfo = Get-Item -LiteralPath $InPath
$srcHash = (Get-FileHash -LiteralPath $InPath -Algorithm SHA256).Hash
Write-Output '================ INPUT ================'
Write-Output ('Path        : ' + $srcInfo.FullName)
Write-Output ('Length      : ' + $srcInfo.Length)
Write-Output ('SHA256      : ' + $srcHash)
Write-Output ('Assembly    : ' + $asm.Name.FullName)
Write-Output ('HasPubKey   : ' + $asm.Name.HasPublicKey)
Write-Output ('Runtime     : ' + $asm.MainModule.Runtime)

# ===========================================================================
# 2. Locate PCL.ModDownload::DlClientListLoader (the real download engine loader)
# ===========================================================================
$modDownload = $null
foreach ($t in $asm.MainModule.GetTypes()) {
    if ($t.FullName -eq 'PCL.ModDownload') { $modDownload = $t; break }
}
if ($null -eq $modDownload) { throw 'Type PCL.ModDownload not found in the assembly.' }

$loaderField = $null
foreach ($f in $modDownload.Fields) {
    if ($f.Name -eq $fieldName) { $loaderField = $f; break }
}
if ($null -eq $loaderField) { throw ('Field PCL.ModDownload::' + $fieldName + ' not found.') }
if (-not $loaderField.IsStatic) { throw ('PCL.ModDownload::' + $fieldName + ' is not static.') }
$actualFieldType = $loaderField.FieldType.FullName
if ($actualFieldType -ne $expectedFieldType) {
    throw ('PCL.ModDownload::' + $fieldName + ' has unexpected type: ' + $actualFieldType)
}
Write-Output ''
Write-Output '================ LOADER FIELD ================'
Write-Output ('Field       : PCL.ModDownload::' + $loaderField.Name)
Write-Output ('Type        : ' + $actualFieldType)
Write-Output ('IsStatic    : ' + $loaderField.IsStatic + '   IsPublic=' + $loaderField.IsPublic)

# The field must be assigned in .cctor, otherwise ldsfld would yield null and
# PageLoaderInit would fail at runtime with a NullReferenceException.
$cctor = $null
foreach ($m in $modDownload.Methods) {
    if ($m.Name -eq '.cctor') { $cctor = $m; break }
}
if ($null -eq $cctor -or -not $cctor.HasBody) {
    throw 'PCL.ModDownload::.cctor not found; cannot confirm DlClientListLoader initialisation.'
}
$cctorInitCount = 0
foreach ($i in $cctor.Body.Instructions) {
    if ($i.OpCode.Name -in @('stsfld', 'stfld') -and $null -ne $i.Operand) {
        if ($i.Operand.ToString().Contains('PCL.ModDownload::' + $fieldName)) { $cctorInitCount++ }
    }
}
Write-Output ('cctor init  : ' + $cctorInitCount + ' assignment(s) of ' + $fieldName + ' in PCL.ModDownload::.cctor')
if ($cctorInitCount -lt 1) {
    throw ('PCL.ModDownload::.cctor never assigns ' + $fieldName + '; the patched page would receive a null loader.')
}

# ===========================================================================
# 3. Locate PCL.PageDownloadInstall::LoaderInit
# ===========================================================================
$pageDownloadInstall = $null
foreach ($t in $asm.MainModule.GetTypes()) {
    if ($t.FullName -eq 'PCL.PageDownloadInstall') { $pageDownloadInstall = $t; break }
}
if ($null -eq $pageDownloadInstall) { throw 'Type PCL.PageDownloadInstall not found in the assembly.' }

$loaderInit = $null
foreach ($m in $pageDownloadInstall.Methods) {
    if ($m.Name -eq 'LoaderInit' -and $m.Parameters.Count -eq 0) { $loaderInit = $m; break }
}
if ($null -eq $loaderInit) { throw 'Method PCL.PageDownloadInstall::LoaderInit() not found.' }
if (-not $loaderInit.HasBody) { throw 'PCL.PageDownloadInstall::LoaderInit() has no body.' }

Dump-Method -Method $loaderInit -Title 'BEFORE: PCL.PageDownloadInstall::LoaderInit'

$instructions = @($loaderInit.Body.Instructions)

# ===========================================================================
# 4. Idempotency check: already patched <=> the instruction right after the
#    `ldnull` that follows `callvirt ... get_PanAllBack` is
#    `ldsfld PCL.ModDownload::DlClientListLoader`.
# ===========================================================================
$alreadyPatched = $false
for ($k = 1; $k -lt $instructions.Count; $k++) {
    $prev = $instructions[$k - 1]
    if ($prev.OpCode.Name -ne 'ldnull') { continue }
    if ($null -eq $prev.Previous) { continue }
    if ($prev.Previous.OpCode.Name -notin @('call', 'callvirt')) { continue }
    if ($null -eq $prev.Previous.Operand) { continue }
    if (-not $prev.Previous.Operand.ToString().Contains('::get_PanAllBack()')) { continue }

    $cur = $instructions[$k]
    if ($cur.OpCode.Name -eq 'ldsfld' -and $null -ne $cur.Operand -and
        $cur.Operand.ToString().Contains('PCL.ModDownload::' + $fieldName)) {
        $alreadyPatched = $true
    }
    break
}

# ===========================================================================
# 5. Structural location of the dummy-LoaderTask range [start .. end]
#    start : the ldstr instruction naming the dummy task; it must directly
#            follow a `ldnull` (the Func(Of TIn) ctor argument).
#    end   : the first `newobj LoaderTask`2::.ctor` at/after start.
# ===========================================================================
$startIndex = -1
$endIndex = -1

if (-not $alreadyPatched -and -not $NoPatch) {
    for ($k = 1; $k -lt $instructions.Count; $k++) {
        $cur = $instructions[$k]
        if ($cur.OpCode.Name -ne 'ldstr') { continue }

        $prev = $instructions[$k - 1]
        if ($prev.OpCode.Name -ne 'ldnull') { continue }

        # Located by code point, so the match does not depend on the encoding
        # PowerShell used to parse this script file.
        if ((Get-Codepoints ([string]$cur.Operand)) -ne $expectedCodepoints) { continue }

        $ctorIdx = -1
        $limit = [Math]::Min($k + 12, $instructions.Count - 1)
        for ($j = $k + 1; $j -le $limit; $j++) {
            $cand = $instructions[$j]
            if ($cand.OpCode.Name -eq 'newobj' -and $null -ne $cand.Operand -and
                (Test-LoaderTaskCtorText $cand.Operand.ToString())) {
                $ctorIdx = $j
                break
            }
        }
        if ($ctorIdx -lt 0) { continue }

        $startIndex = $k
        $endIndex = $ctorIdx
        break
    }

    if ($startIndex -lt 0) {
        throw 'Could not locate the dummy LoaderTask construction range in LoaderInit().'
    }
}

# ===========================================================================
# 6. Pre-flight assertions on the located range
# ===========================================================================
if (-not $alreadyPatched -and -not $NoPatch) {
    $startInstr = $instructions[$startIndex]
    $endInstr = $instructions[$endIndex]
    $rangeCount = $endIndex - $startIndex + 1

    $rangeSet = New-Object System.Collections.ArrayList
    for ($k = $startIndex; $k -le $endIndex; $k++) { [void]$rangeSet.Add($instructions[$k]) }

    Write-Output ''
    Write-Output '================ PATCH TARGET ================'
    Write-Output ('start       : index ' + $startIndex + '  ' + (Format-Instruction $startInstr))
    Write-Output ('end         : index ' + $endIndex + '  ' + (Format-Instruction $endInstr))
    Write-Output ('range size  : ' + $rangeCount + ' instructions (expected 13)')
    Write-Output ('ldstr cps   : ' + (Get-Codepoints ([string]$startInstr.Operand)))
    Write-Output ''
    Write-Output '  instructions to be removed/replaced:'
    for ($k = $startIndex; $k -le $endIndex; $k++) {
        Write-Output ('    ' + (Format-Instruction $instructions[$k]))
    }

    if ($rangeCount -ne 13) {
        throw ('Expected exactly 13 instructions in the patch range, found ' + $rangeCount + '. Aborting.')
    }
    if ($startInstr.OpCode.Name -ne 'ldstr') { throw 'Patch range must start with ldstr.' }
    if ($endInstr.OpCode.Name -ne 'newobj') { throw 'Patch range must end with newobj.' }
    if ($startInstr.Previous.OpCode.Name -ne 'ldnull') {
        throw 'Instructions preceding the patch range must end with ldnull (Func(Of TIn) argument).'
    }

    # No instruction outside the range may branch into it: deleting the range
    # must not leave any dangling branch target behind.
    $externalBranches = New-Object System.Collections.ArrayList
    foreach ($i in $instructions) {
        if ($rangeSet.Contains($i)) { continue }
        if ($null -ne $i.Operand -and $i.Operand -is [Mono.Cecil.Cil.Instruction]) {
            if ($rangeSet.Contains($i.Operand)) { [void]$externalBranches.Add((Format-Instruction $i)) }
        }
        if ($i.OpCode.Name -eq 'switch' -and $null -ne $i.Operand) {
            foreach ($t in $i.Operand) {
                if ($rangeSet.Contains($t)) { [void]$externalBranches.Add((Format-Instruction $i)) }
            }
        }
    }
    if ($externalBranches.Count -gt 0) {
        Write-Output ''
        Write-Output 'EXTERNAL BRANCHES INTO PATCH RANGE:'
        $externalBranches | ForEach-Object { Write-Output ('    ' + $_) }
        throw 'Aborting: instructions outside the patch range target instructions inside it.'
    }
    Write-Output ''
    Write-Output 'ASSERT OK: no instruction outside the range targets anything inside it.'

    # No exception handler may cover the range.
    foreach ($eh in $loaderInit.Body.ExceptionHandlers) {
        for ($k = $startIndex; $k -le $endIndex; $k++) {
            $ins = $instructions[$k]
            if ($eh.TryStart -eq $ins -or $eh.TryEnd -eq $ins -or
                $eh.HandlerStart -eq $ins -or $eh.HandlerEnd -eq $ins -or
                $eh.FilterStart -eq $ins) {
                throw ('Aborting: an exception handler covers the patch range at ' + (Format-Instruction $ins) + '.')
            }
        }
    }
    Write-Output 'ASSERT OK: no exception handler covers the patch range.'

    # =======================================================================
    # 7. Apply the patch: delete (start, end], replace start with ldsfld
    # =======================================================================
    $processor = $loaderInit.Body.GetILProcessor()

    $doomed = New-Object System.Collections.ArrayList
    for ($k = $startIndex + 1; $k -le $endIndex; $k++) { [void]$doomed.Add($instructions[$k]) }

    foreach ($ins in $doomed) { $processor.Remove($ins) }

    $ldsfldInstruction = [Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $loaderField)
    $processor.Replace($startInstr, $ldsfldInstruction)

    Write-Output ''
    Write-Output ('PATCHED: removed ' + $doomed.Count + ' instruction(s), replaced 1 with ldsfld ' + $fieldName + '.')
}
else {
    Write-Output ''
    Write-Output 'ALREADY PATCHED: LoaderInit() already loads PCL.ModDownload::DlClientListLoader; no IL change applied.'
}

# ===========================================================================
# 8. Write the patched assembly to a NEW file (never overwrite the source)
# ===========================================================================
$writerParams = New-Object Mono.Cecil.WriterParameters
$writerParams.WriteSymbols = $false
$asm.Write($OutPath, $writerParams)
$asm.Dispose()

$outInfo = Get-Item -LiteralPath $OutPath
$outHash = (Get-FileHash -LiteralPath $OutPath -Algorithm SHA256).Hash

Write-Output ''
Write-Output '================ OUTPUT ================'
Write-Output ('Path        : ' + $outInfo.FullName)
Write-Output ('Length      : ' + $outInfo.Length + '  (delta ' + ($outInfo.Length - $srcInfo.Length) + ' bytes)')
Write-Output ('SHA256      : ' + $outHash)
Write-Output ('resolved from disk: ' + $(if ($resolver.FromDisk.Count -eq 0) { '<none>' } else { ($resolver.FromDisk | Select-Object -Unique) -join ' | ' }))
Write-Output ('stubbed (missing): ' + $(if ($resolver.Stubbed.Count -eq 0) { '<none>' } else { ($resolver.Stubbed | Select-Object -Unique) -join ' | ' }))
$resolver.Dispose()

if ($NoPatch) {
    Write-Output ''
    Write-Output 'CONTROL MODE (-NoPatch): assembly rewritten without any IL change.'
    Write-Output ('RESULT: CONTROL WRITTEN -> ' + $outInfo.FullName)
    exit 0
}

# ===========================================================================
# 9. Re-read the product and validate
# ===========================================================================
$verifyResolver = New-Object PclStubResolver
$verifyResolver.AddSearchDirectory($PSScriptRoot)
$verifyResolver.AddSearchDirectory((Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'))
$verifyResolver.AddSearchDirectory((Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\WPF'))

$verifyParams = New-Object Mono.Cecil.ReaderParameters
$verifyParams.ReadWrite = $false
$verifyParams.AssemblyResolver = $verifyResolver
$verifyAsm = [Mono.Cecil.AssemblyDefinition]::ReadAssembly($OutPath, $verifyParams)
$verifyResolver.Source = $verifyAsm.MainModule

$vPageType = $null
foreach ($t in $verifyAsm.MainModule.GetTypes()) {
    if ($t.FullName -eq 'PCL.PageDownloadInstall') { $vPageType = $t; break }
}
if ($null -eq $vPageType) { throw 'VERIFY FAILED: PCL.PageDownloadInstall missing from the output assembly.' }

$vMethod = $null
foreach ($m in $vPageType.Methods) {
    if ($m.Name -eq 'LoaderInit' -and $m.Parameters.Count -eq 0) { $vMethod = $m; break }
}
if ($null -eq $vMethod) { throw 'VERIFY FAILED: LoaderInit() missing from the output assembly.' }

Dump-Method -Method $vMethod -Title 'AFTER: PCL.PageDownloadInstall::LoaderInit (re-read from product)'

$vInstr = @($vMethod.Body.Instructions)
$failures = New-Object System.Collections.ArrayList

# 9.1 exactly one ret, as the last instruction
$retIndexes = New-Object System.Collections.ArrayList
for ($k = 0; $k -lt $vInstr.Count; $k++) { if ($vInstr[$k].OpCode.Name -eq 'ret') { [void]$retIndexes.Add($k) } }
if ($retIndexes.Count -ne 1) {
    [void]$failures.Add('Expected exactly 1 ret, found ' + $retIndexes.Count)
}
elseif ($retIndexes[0] -ne ($vInstr.Count - 1)) {
    [void]$failures.Add('The single ret is not the last instruction.')
}

# 9.2 no leftover ldstr carrying the dummy loader name
foreach ($i in $vInstr) {
    if ($i.OpCode.Name -eq 'ldstr' -and (Get-Codepoints ([string]$i.Operand)) -eq $expectedCodepoints) {
        [void]$failures.Add('Leftover ldstr with the dummy loader name at IL_' + ('{0:X4}' -f $i.Offset))
    }
}

# 9.3 no leftover LoaderTask ctor invocation
foreach ($i in $vInstr) {
    if ($i.OpCode.Name -eq 'newobj' -and $null -ne $i.Operand -and
        (Test-LoaderTaskCtorText $i.Operand.ToString())) {
        [void]$failures.Add('Leftover LoaderTask ctor at IL_' + ('{0:X4}' -f $i.Offset))
    }
}

# 9.4 exact expected tail sequence
$expectedTail = @(
    @{ Op = 'ldarg.0'; Contains = @() },
    @{ Op = 'callvirt'; Contains = @('::get_PanAllBack()') },
    @{ Op = 'ldnull'; Contains = @() },
    @{ Op = 'ldsfld'; Contains = @('PCL.ModDownload::' + $fieldName) },
    @{ Op = 'ldarg.0'; Contains = @() },
    @{ Op = 'ldftn'; Contains = @($realOnFinishMethod) },
    @{ Op = 'newobj'; Contains = @(('System.Void System.' + $actionArity), '::.ctor(') },
    @{ Op = 'ldnull'; Contains = @() },
    @{ Op = 'ldc.i4.1'; Contains = @() },
    @{ Op = 'call'; Contains = @('::PageLoaderInit') },
    @{ Op = 'ret'; Contains = @() }
)

$tailStart = $vInstr.Count - $expectedTail.Count
if ($tailStart -lt 0) {
    [void]$failures.Add('Patched method is shorter than the expected tail sequence.')
}
else {
    for ($k = 0; $k -lt $expectedTail.Count; $k++) {
        $actual = $vInstr[$tailStart + $k]
        $want = $expectedTail[$k]
        if ($actual.OpCode.Name -ne $want.Op) {
            [void]$failures.Add(('Tail mismatch at position {0}: expected opcode {1}, found {2} ({3})' -f $k, $want.Op, $actual.OpCode.Name, (Format-Instruction $actual)))
            continue
        }
        if ($want.Contains.Count -gt 0) {
            $operandText = ''
            if ($null -ne $actual.Operand) { $operandText = $actual.Operand.ToString() }
            foreach ($needle in @($want.Contains)) {
                if (-not $operandText.Contains([string]$needle)) {
                    [void]$failures.Add(('Tail mismatch at position {0}: operand "{1}" does not contain "{2}"' -f $k, $operandText, $needle))
                }
            }
        }
    }
}

# 9.5 no leftover reference to the dummy closure
foreach ($i in $vInstr) {
    if ($null -ne $i.Operand -and $i.Operand -isnot [Mono.Cecil.Cil.Instruction]) {
        $text = $i.Operand.ToString()
        if ($text.Contains($dummyClosureField) -or $text.Contains($dummyClosureMethod)) {
            [void]$failures.Add('Leftover reference to the dummy closure at IL_' + ('{0:X4}' -f $i.Offset) + ': ' + $text)
        }
    }
}

# 9.6 the referenced field must still exist, be static and correctly typed
$vModDownload = $null
foreach ($t in $verifyAsm.MainModule.GetTypes()) {
    if ($t.FullName -eq 'PCL.ModDownload') { $vModDownload = $t; break }
}
$vField = $null
if ($null -ne $vModDownload) {
    foreach ($f in $vModDownload.Fields) { if ($f.Name -eq $fieldName) { $vField = $f; break } }
}
if ($null -eq $vField) { [void]$failures.Add('Product is missing PCL.ModDownload::' + $fieldName) }
elseif (-not $vField.IsStatic) { [void]$failures.Add('Product field PCL.ModDownload::' + $fieldName + ' is not static.') }
elseif ($vField.FieldType.FullName -ne $expectedFieldType) { [void]$failures.Add('Product field type changed: ' + $vField.FieldType.FullName) }

# 9.7 all branch targets resolve to an instruction of this body
$bodySet = New-Object System.Collections.ArrayList
foreach ($i in $vInstr) { [void]$bodySet.Add($i) }
foreach ($i in $vInstr) {
    if ($null -ne $i.Operand -and $i.Operand -is [Mono.Cecil.Cil.Instruction]) {
        if (-not $bodySet.Contains($i.Operand)) {
            [void]$failures.Add('Dangling branch target from IL_' + ('{0:X4}' -f $i.Offset))
        }
    }
    if ($i.OpCode.Name -eq 'switch' -and $null -ne $i.Operand) {
        foreach ($t in $i.Operand) {
            if (-not $bodySet.Contains($t)) {
                [void]$failures.Add('Dangling switch target from IL_' + ('{0:X4}' -f $i.Offset))
            }
        }
    }
}

$verifyAsm.Dispose()
$verifyResolver.Dispose()

# 9.8 file-size sanity (a Cecil PE rewrite shifts a few hundred bytes)
$sizeDelta = [Math]::Abs($outInfo.Length - $srcInfo.Length)
if ($sizeDelta -gt 4096) {
    Write-Output ('NOTE: output size differs from the source by ' + $sizeDelta + ' bytes.')
}

Write-Output ''
Write-Output '================ VERIFICATION ================'
if ($failures.Count -eq 0) {
    Write-Output '[1] exactly one ret, as the last instruction              OK'
    Write-Output '[2] no leftover ldstr with the dummy loader name          OK'
    Write-Output '[3] no leftover LoaderTask ctor invocation                OK'
    Write-Output '[4] exact expected tail sequence (ldsfld ... PageLoaderInit) OK'
    Write-Output '[5] no leftover references to the dummy closure           OK'
    Write-Output '[6] PCL.ModDownload::DlClientListLoader static & typed    OK'
    Write-Output '[7] no dangling branch targets                            OK'
    Write-Output 'ALL CHECKS PASSED'
    Write-Output ''
    Write-Output ('RESULT: SUCCESS -> ' + $outInfo.FullName)
    Write-Output ('SHA256: ' + $outHash)
    exit 0
}
else {
    Write-Output 'VERIFICATION FAILED:'
    foreach ($f in $failures) { Write-Output ('  - ' + $f) }
    Write-Output ''
    Write-Output ('RESULT: FAILED -> ' + $outInfo.FullName)
    exit 1
}
