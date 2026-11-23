unit PSP.HLE;

// HLE function registry. Every (library, NID) the core implements is one entry;
// its index is the syscall code written into an import stub (`jr ra; syscall N`).
// Handlers read arguments from a0..a3, t0..t3 and return in v0 (v1 for the
// high word of 64-bit results). Unknown NIDs get an entry of their own so the
// log names them; they return 0 unless strict mode is on.
{$IFDEF PSP_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Generics.Collections, PSP.Types, PSP.Memory, PSP.CPU;

const
  // Syscall codes below this are reserved for kernel traps (returns from guest calls).
  PSPTrapCount = 16;
  PSPTrapReturn = 1;
  PSPTrapThreadExit = 2;
  PSPTrapIdle = 3;

type
  TPSPHLEHandler = procedure of object;

  TPSPHLEFunction = record
    Library_: string;
    NID: Cardinal;
    Name: string;
    Handler: TPSPHLEHandler;
    Calls: Int64;
    Known: Boolean;
  end;

  PPSPHLEFunction = ^TPSPHLEFunction;

  TPSPLogEvent = procedure(const Text: string) of object;

  TPSPHLE = class
  private
    FFunctions: TList<TPSPHLEFunction>;
    FIndex: TDictionary<string, Integer>;
    FLibraries: TDictionary<string, Boolean>;
    FCPU: TPSPCPU;
    FMemory: TPSPMemory;
    FCurrent: Integer;
    FStrict: Boolean;
    FOnLog: TPSPLogEvent;
    FUnknownLogged: TDictionary<Integer, Boolean>;
    FCycleCost: Integer;
    class function Key(const Lib: string; NID: Cardinal): string; static; inline;
    function GetCount: Integer;
    procedure Clobber;
  public
    TraceCalls: Boolean;
    NoClobber: Boolean;
    constructor Create(CPU: TPSPCPU; Memory: TPSPMemory);
    destructor Destroy; override;
    procedure Clear;
    procedure Register(const Lib: string; NID: Cardinal; const Name: string; Handler: TPSPHLEHandler);
    // Libraries whose every import is resolved by HLE (no guest module needed).
    procedure DeclareLibrary(const Lib: string);
    function HasLibrary(const Lib: string): Boolean;
    function Find(const Lib: string; NID: Cardinal): Integer;
    // Index to put into a stub: a known entry, or a new unknown one.
    function Resolve(const Lib: string; NID: Cardinal): Integer;
    function Call(Index: Integer): Boolean;
    function FunctionInfo(Index: Integer): PPSPHLEFunction;
    function CurrentName: string;
    procedure Log(const Text: string); overload;
    procedure Log(const Fmt: string; const Args: array of const); overload;
    procedure Unimplemented(const What: string);
    function Arg(Index: Integer): Cardinal; inline;
    function ArgInt(Index: Integer): Integer; inline;
    function Arg64(Index: Integer): UInt64;
    function ArgFloat(Index: Integer): Single;
    procedure Result(Value: Cardinal); inline;
    procedure Result64(Value: UInt64); inline;
    procedure ResultFloat(Value: Single);
    procedure WriteStub(Address: Cardinal; Index: Integer);
    property strict: Boolean read FStrict write FStrict;
    property OnLog: TPSPLogEvent read FOnLog write FOnLog;
    property CPU: TPSPCPU read FCPU;
    property Memory: TPSPMemory read FMemory;
    property Count: Integer read GetCount;
    property CycleCost: Integer read FCycleCost write FCycleCost;
  end;

  EPSPUnimplemented = class(EPSPError);

implementation

constructor TPSPHLE.Create(CPU: TPSPCPU; Memory: TPSPMemory);
begin
  inherited Create;
  FCPU := CPU;
  FMemory := Memory;
  FFunctions := TList<TPSPHLEFunction>.Create;
  FIndex := TDictionary<string, Integer>.Create;
  FLibraries := TDictionary<string, Boolean>.Create;
  FUnknownLogged := TDictionary<Integer, Boolean>.Create;
  FCycleCost := 300;
  Clear;
end;

destructor TPSPHLE.Destroy;
begin
  FUnknownLogged.Free;
  FLibraries.Free;
  FIndex.Free;
  FFunctions.Free;
  inherited;
end;

procedure TPSPHLE.Clear;
begin
  FFunctions.Clear;
  FIndex.Clear;
  FLibraries.Clear;
  FUnknownLogged.Clear;
  var Empty := Default(TPSPHLEFunction);
  for var I := 0 to PSPTrapCount - 1 do
    FFunctions.Add(Empty);
end;

class function TPSPHLE.Key(const Lib: string; NID: Cardinal): string;
begin
  Result := Lib + ':' + IntToHex(NID, 8);
end;

function TPSPHLE.GetCount: Integer;
begin
  Result := FFunctions.Count;
end;

procedure TPSPHLE.Register(const Lib: string; NID: Cardinal; const Name: string; Handler: TPSPHLEHandler);
begin
  var F := Default(TPSPHLEFunction);
  F.Library_ := Lib;
  F.NID := NID;
  F.Name := Name;
  F.Handler := Handler;
  F.Known := True;
  var K := Key(Lib, NID);
  var Existing: Integer;
  if FIndex.TryGetValue(K, Existing) then
    FFunctions[Existing] := F
  else
  begin
    FIndex.Add(K, FFunctions.Count);
    FFunctions.Add(F);
  end;
  FLibraries.AddOrSetValue(Lib, True);
end;

procedure TPSPHLE.DeclareLibrary(const Lib: string);
begin
  FLibraries.AddOrSetValue(Lib, True);
end;

function TPSPHLE.HasLibrary(const Lib: string): Boolean;
begin
  Result := FLibraries.ContainsKey(Lib);
end;

function TPSPHLE.Find(const Lib: string; NID: Cardinal): Integer;
begin
  if not FIndex.TryGetValue(Key(Lib, NID), Result) then
    Result := -1;
end;

// Kernel-mode and driver libraries share most NIDs with their user ones.
function UserLibrary(const Lib: string): string;
const
  Pairs: array[0..20, 0..1] of string = (
    ('ThreadManForKernel', 'ThreadManForUser'), ('SysMemForKernel', 'SysMemUserForUser'),
    ('UtilsForKernel', 'UtilsForUser'), ('IoFileMgrForKernel', 'IoFileMgrForUser'),
    ('LoadExecForKernel', 'LoadExecForUser'), ('ModuleMgrForKernel', 'ModuleMgrForUser'),
    ('InterruptManagerForKernel', 'InterruptManager'), ('StdioForKernel', 'StdioForUser'),
    ('sceDisplay_driver', 'sceDisplay'), ('sceCtrl_driver', 'sceCtrl'), ('sceAudio_driver', 'sceAudio'),
    ('sceGe_driver', 'sceGe_user'), ('scePower_driver', 'scePower'), ('sceRtc_driver', 'sceRtc'),
    ('sceReg_driver', 'sceReg'), ('sceUmd', 'sceUmdUser'), ('sceHprm_driver', 'sceHprm'),
    ('sceImpose_driver', 'sceImpose'), ('sceMpegbase_driver', 'sceMpegbase'),
    ('sceAudioRouting_driver', 'sceAudioRouting'), ('sceSuspendForKernel', 'sceSuspendForUser'));
begin
  for var I := 0 to High(Pairs) do
    if Pairs[I, 0] = Lib then
      Exit(Pairs[I, 1]);
  Result := '';
end;

function TPSPHLE.Resolve(const Lib: string; NID: Cardinal): Integer;
begin
  Result := Find(Lib, NID);
  if Result >= 0 then
    Exit;
  // Firmware 6.6x kernel entry names for the same module-manager operations.
  // Resolve to the existing entry, retaining syscall indices of older images.
  if Lib = 'ModuleMgrForKernel' then
  begin
    case NID of
      $939E4270:
        Result := Find('ModuleMgrForUser', $977DE386);
      $387E3CA9:
        Result := Find('ModuleMgrForUser', $2E0911AA);
    end;
    if Result >= 0 then
      Exit;
  end;
  var Alias := UserLibrary(Lib);
  if Alias <> '' then
  begin
    Result := Find(Alias, NID);
    if Result >= 0 then
      Exit;
  end;
  var F := Default(TPSPHLEFunction);
  F.Library_ := Lib;
  F.NID := NID;
  F.Name := Format('%s_%.8X', [Lib, NID]);
  F.Known := False;
  Result := FFunctions.Count;
  FIndex.Add(Key(Lib, NID), Result);
  FFunctions.Add(F);
end;

function TPSPHLE.FunctionInfo(Index: Integer): PPSPHLEFunction;
begin
  if (Index < 0) or (Index >= FFunctions.Count) then
    Exit(nil);
  Result := @FFunctions.List[Index];
end;

function TPSPHLE.CurrentName: string;
begin
  if (FCurrent >= PSPTrapCount) and (FCurrent < FFunctions.Count) then
    Result := FFunctions.List[FCurrent].Name
  else
    Result := '';
end;

function TPSPHLE.Call(Index: Integer): Boolean;
begin
  if (Index < PSPTrapCount) or (Index >= FFunctions.Count) then
    Exit(False);
  var F: PPSPHLEFunction := @FFunctions.List[Index];
  Inc(F.Calls);
  FCurrent := Index;
  FCPU.AddCycles(FCycleCost);
  if TraceCalls then
    Log('call %s(%x, %x, %x, %x) ra=%.8x',
      [F.Name, FCPU.Ctx.GPR[4], FCPU.Ctx.GPR[5], FCPU.Ctx.GPR[6], FCPU.Ctx.GPR[7], FCPU.Ctx.GPR[31]]);
  var ReturnPC := FCPU.Ctx.PC;
  if Assigned(F.Handler) then
  begin
    F.Handler();
  end
  else
  begin
    if not FUnknownLogged.ContainsKey(Index) then
    begin
      FUnknownLogged.Add(Index, True);
      Log('unimplemented %s (a0=%.8x a1=%.8x a2=%.8x ra=%.8x)',
        [F.Name, FCPU.Ctx.GPR[4], FCPU.Ctx.GPR[5], FCPU.Ctx.GPR[6], FCPU.Ctx.GPR[31]]);
    end;
    if FStrict then
      raise EPSPUnimplemented.CreateFmt('PSP: unimplemented %s', [F.Name]);
    if F.Known then
      FCPU.Ctx.GPR[2] := 0
    else
      FCPU.Ctx.GPR[2] := SCE_KERNEL_ERROR_LIBRARY_NOT_YET_LINKED;
  end;
  if (FCPU.Ctx.PC = ReturnPC) and not NoClobber then
    Clobber;
  Result := True;
end;

procedure TPSPHLE.Clobber;
begin
  PSPClobberCallerSaved(FCPU.Ctx);
end;

procedure TPSPHLE.Log(const Text: string);
begin
  if Assigned(FOnLog) then
    FOnLog(Text);
end;

procedure TPSPHLE.Log(const Fmt: string; const Args: array of const);
begin
  if Assigned(FOnLog) then
    FOnLog(Format(Fmt, Args));
end;

procedure TPSPHLE.Unimplemented(const What: string);
begin
  var K := FCurrent;
  if not FUnknownLogged.ContainsKey(-K - 1) then
  begin
    FUnknownLogged.Add(-K - 1, True);
    Log('%s: %s not implemented', [CurrentName, What]);
  end;
  if FStrict then
    raise EPSPUnimplemented.CreateFmt('PSP: %s: %s', [CurrentName, What]);
end;

function TPSPHLE.Arg(Index: Integer): Cardinal;
begin
  Result := FCPU.Ctx.GPR[4 + Index];
end;

function TPSPHLE.ArgInt(Index: Integer): Integer;
begin
  Result := Integer(FCPU.Ctx.GPR[4 + Index]);
end;

function TPSPHLE.Arg64(Index: Integer): UInt64;
begin
  // 64-bit arguments occupy an even/odd register pair, low word first.
  Result := UInt64(FCPU.Ctx.GPR[4 + Index]) or (UInt64(FCPU.Ctx.GPR[5 + Index]) shl 32);
end;

function TPSPHLE.ArgFloat(Index: Integer): Single;
begin
  Result := PSingle(@FCPU.Ctx.FPR[12 + Index])^;
end;

procedure TPSPHLE.Result(Value: Cardinal);
begin
  FCPU.Ctx.GPR[2] := Value;
end;

procedure TPSPHLE.Result64(Value: UInt64);
begin
  FCPU.Ctx.GPR[2] := Cardinal(Value);
  FCPU.Ctx.GPR[3] := Cardinal(Value shr 32);
end;

procedure TPSPHLE.ResultFloat(Value: Single);
begin
  PSingle(@FCPU.Ctx.FPR[0])^ := Value;
end;

procedure TPSPHLE.WriteStub(Address: Cardinal; Index: Integer);
begin
  FMemory.Write32(Address, $03E00008);
  FMemory.Write32(Address + 4, (Cardinal(Index) shl 6) or $0C);
end;

end.

