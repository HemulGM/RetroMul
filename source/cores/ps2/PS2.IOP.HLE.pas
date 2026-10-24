unit PS2.IOP.HLE;

// High-level IOP services reached over SIF RPC: the IOP heap (SID
// 80000003h: allocate, free, load a file into IOP memory), LOADFILE (SID
// 80000006h: load modules and EE ELF images) and the IOP memory allocator
// they share with the IOP kernel (sysmem). Modules known to the high-level
// IOP register their servers through OnModule; others are reported.
// References: ps2sdk iopheap/loadfile structures (AFL 2.0, interfaces only),
// Play! Iop_Loadcore/Iop_SifMan (BSD-2).
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, Core.Snapshots, PS2.Types, PS2.SIF, PS2.ELF,
  PS2.IOP.FileIO;

type
  TPS2IOPBlock = record
    Address, Size: Cardinal;
  end;

  // First-fit allocator over IOP RAM (256-byte granularity).
  TPS2IOPAllocator = class
  private
    FBlocks: TList<TPS2IOPBlock>;
    FBase, FLimit: Cardinal;
  public
    constructor Create(Base, Limit: Cardinal);
    destructor Destroy; override;
    procedure Reset;
    function Allocate(Size: Cardinal; Fixed: Cardinal = 0): Cardinal;
    function Release(Address: Cardinal): Boolean;
    // The size of the block at Address (0 when none starts there).
    function BlockSize(Address: Cardinal): Cardinal;
    function FreeTotal: Cardinal;
    function LargestFree: Cardinal;
    procedure SerializeState(State: TStateArchive);
  end;

  TPS2LoadFileServer = class;

  // A module to load: Path (or '' for an image in IOP memory), its image
  // (nil: read by path) and arguments. Returns the module id, or an error;
  // a module started as IOP code answers later (Server.DeferCall, then
  // Server.FinishModule).
  TPS2ModuleLoad = function(Server: TPS2LoadFileServer; const Path: string; const Image, Args: TBytes): Integer of object;

  TPS2IOPHeapServer = class(TPS2RPCServer)
  private
    FAllocator: TPS2IOPAllocator;
    FIOMan: TPS2IOMan;
  public
    constructor Create(Allocator: TPS2IOPAllocator; IOMan: TPS2IOMan);
    function Call(Fn: Cardinal; Args: PByte; Size: Integer; ReplySize: Integer): TBytes; override;
  end;

  TPS2LoadFileServer = class(TPS2RPCServer)
  private
    FIOMan: TPS2IOMan;
    FOnModule: TPS2ModuleLoad;
    FImageReader: TFunc<Cardinal, TBytes>;
    FLog: TStrings;
    function LoadELF(const Path: string; out Entry, GP: Cardinal): Boolean;
  public
    constructor Create(IOMan: TPS2IOMan);
    function Call(Fn: Cardinal; Args: PByte; Size: Integer; ReplySize: Integer): TBytes; override;
    function DeferCall: TBytes;
    procedure FinishModule(const Token: TBytes; ModuleId, ModuleResult: Integer);
    property OnModule: TPS2ModuleLoad read FOnModule write FOnModule;
    property Log: TStrings read FLog write FLog;
    // Reads a module image from IOP memory (buffer loads).
    property ImageReader: TFunc<Cardinal, TBytes> read FImageReader write FImageReader;
  end;

function CString(P: PByte; Max: Integer): string;

implementation

function CString(P: PByte; Max: Integer): string;
begin
  var B: TBytes;
  for var K := 0 to Max - 1 do
  begin
    if P[K] = 0 then
      Break;
    B := B + [P[K]];
  end;
  Result := TEncoding.ANSI.GetString(B);
end;

{ TPS2IOPAllocator }

constructor TPS2IOPAllocator.Create(Base, Limit: Cardinal);
begin
  inherited Create;
  FBlocks := TList<TPS2IOPBlock>.Create;
  FBase := Base;
  FLimit := Limit;
end;

destructor TPS2IOPAllocator.Destroy;
begin
  FBlocks.Free;
  inherited;
end;

procedure TPS2IOPAllocator.Reset;
begin
  FBlocks.Clear;
end;

function TPS2IOPAllocator.Allocate(Size: Cardinal; Fixed: Cardinal): Cardinal;
begin
  Size := (Size + 255) and not Cardinal(255);
  if Size = 0 then
    Size := 256;
  // Blocks are kept sorted by address.
  var Candidate := FBase;
  if Fixed <> 0 then
    Candidate := Fixed and not Cardinal(255);
  var Index := 0;
  while Index < FBlocks.Count do
  begin
    var B := FBlocks[Index];
    if Candidate + Size <= B.Address then
      Break;
    if B.Address + B.Size > Candidate then
    begin
      if Fixed <> 0 then
        Exit(0);
      Candidate := B.Address + B.Size;
    end;
    Inc(Index);
  end;
  if Candidate + Size > FLimit then
    Exit(0);
  var N: TPS2IOPBlock;
  N.Address := Candidate;
  N.Size := Size;
  // Insert sorted.
  Index := 0;
  while (Index < FBlocks.Count) and (FBlocks[Index].Address < Candidate) do
    Inc(Index);
  FBlocks.Insert(Index, N);
  Result := Candidate;
end;

function TPS2IOPAllocator.Release(Address: Cardinal): Boolean;
begin
  for var K := 0 to FBlocks.Count - 1 do
    if FBlocks[K].Address = Address then
    begin
      FBlocks.Delete(K);
      Exit(True);
    end;
  Result := False;
end;

function TPS2IOPAllocator.BlockSize(Address: Cardinal): Cardinal;
begin
  for var B in FBlocks do
    if B.Address = Address then
      Exit(B.Size);
  Result := 0;
end;

function TPS2IOPAllocator.FreeTotal: Cardinal;
begin
  Result := FLimit - FBase;
  for var B in FBlocks do
    Dec(Result, B.Size);
end;

function TPS2IOPAllocator.LargestFree: Cardinal;
begin
  Result := 0;
  var Prev := FBase;
  for var B in FBlocks do
  begin
    if B.Address > Prev then
      if B.Address - Prev > Result then
        Result := B.Address - Prev;
    Prev := B.Address + B.Size;
  end;
  if FLimit > Prev then
    if FLimit - Prev > Result then
      Result := FLimit - Prev;
end;

procedure TPS2IOPAllocator.SerializeState(State: TStateArchive);
begin
  var N := FBlocks.Count;
  State.Field(N, SizeOf(N));
  if State.Loading then
  begin
    if (N < 0) or (N > 100000) then
      raise EReadError.Create('PS2 snapshot IOP heap');
    FBlocks.Clear;
    for var K := 0 to N - 1 do
    begin
      var B: TPS2IOPBlock;
      State.Field(B, SizeOf(B));
      FBlocks.Add(B);
    end;
  end
  else
    for var K := 0 to N - 1 do
    begin
      var B := FBlocks[K];
      State.Field(B, SizeOf(B));
    end;
end;

{ TPS2IOPHeapServer }

constructor TPS2IOPHeapServer.Create(Allocator: TPS2IOPAllocator; IOMan: TPS2IOMan);
begin
  inherited Create($80000003);
  FAllocator := Allocator;
  FIOMan := IOMan;
end;

function TPS2IOPHeapServer.Call(Fn: Cardinal; Args: PByte; Size: Integer; ReplySize: Integer): TBytes;
begin
  case Fn of
    1: Result := IntBytes(Integer(FAllocator.Allocate(PCardinal(Args)^)));
    2:
      if FAllocator.Release(PCardinal(Args)^) then
        Result := IntBytes(0)
      else
        Result := IntBytes(-1);
    3:
      begin
        var Address := PCardinal(Args)^;
        var Path := CString(Args + 4, 252);
        var Fd := FIOMan.Open(Path, 1);
        if Fd < 0 then
          Exit(IntBytes(Fd));
        var Data: TBytes;
        var N := FIOMan.Read(Fd, $200000, Data);
        FIOMan.Close(Fd);
        if N > 0 then
        begin
          var A := Address and PS2IOPRAMMask;
          if A + Cardinal(N) > PS2IOPRAMSize then
            N := Integer(PS2IOPRAMSize - A);
          Move(Data[0], (FSIF.IOPRAM + A)^, N);
        end;
        Result := IntBytes(0);
      end;
  else
    Result := IntBytes(-1);
  end;
end;

{ TPS2LoadFileServer }

constructor TPS2LoadFileServer.Create(IOMan: TPS2IOMan);
begin
  inherited Create($80000006);
  FIOMan := IOMan;
end;

function TPS2LoadFileServer.LoadELF(const Path: string; out Entry, GP: Cardinal): Boolean;
begin
  Entry := 0;
  GP := 0;
  var Device, P: string;
  TPS2IOMan.SplitPath(Path, Device, P);
  var Data := FIOMan.FileSystem.ReadFile(Device, P);
  if (Data = nil) or not TPS2ELF.IsELF(Data) then
    Exit(False);
  var ELF := TPS2ELF.Create(Data);
  try
    for var S in ELF.Segments do
    begin
      if S.Flags <> 1 then
        Continue;
      var Phys := S.VirtualAddress and PS2RAMMask;
      if Int64(Phys) + S.MemorySize > PS2RAMSize then
        Continue;
      FillChar((FSIF.EERAM + Phys)^, S.MemorySize, 0);
      if S.FileSize > 0 then
        Move(Data[S.Offset], (FSIF.EERAM + Phys)^, S.FileSize);
    end;
    Entry := ELF.Entry;
  finally
    ELF.Free;
  end;
  Result := True;
end;

function TPS2LoadFileServer.DeferCall: TBytes;
begin
  Result := Defer;
end;

procedure TPS2LoadFileServer.FinishModule(const Token: TBytes; ModuleId, ModuleResult: Integer);
begin
  var R: TBytes;
  SetLength(R, 8);
  PInteger(@R[0])^ := ModuleId;
  PInteger(@R[4])^ := ModuleResult;
  if FLog <> nil then
    FLog.Add(Format('module %d started: %d', [ModuleId, ModuleResult]));
  Complete(Token, R);
end;

function TPS2LoadFileServer.Call(Fn: Cardinal; Args: PByte; Size: Integer; ReplySize: Integer): TBytes;
begin
  SetLength(Result, 8);
  case Fn of
    0, 4, 6:
      begin
        // _lf_module_load_arg: arg_len 0, modres 4, path 8, args 260;
        // buffer loads: IOP address 0, arg_len 4, args 260.
        var ArgLen := Integer(PCardinal(Args)^);
        var Path := CString(Args + 8, 252);
        var Image: TBytes := nil;
        if Fn = 6 then
        begin
          ArgLen := Integer(PCardinal(Args + 4)^);
          Path := '';
          if Assigned(FImageReader) then
            Image := FImageReader(PCardinal(Args)^);
        end;
        var ModArgs: TBytes;
        if (ArgLen > 0) and (ArgLen <= 252) then
        begin
          SetLength(ModArgs, ArgLen);
          Move((Args + 260)^, ModArgs[0], ArgLen);
        end;
        var Id := -200;
        if Assigned(FOnModule) then
          Id := FOnModule(Self, Path, Image, ModArgs);
        if FLog <> nil then
          FLog.Add(Format('load module %s: %d', [Path, Id]));
        PInteger(@Result[0])^ := Id;
        PInteger(@Result[4])^ := 0;
      end;
    1, 5:
      begin
        // _lf_elf_load_arg: epc 0, gp 4, path 8, secname 260.
        var Path := CString(Args + 8, 252);
        var Entry, GP: Cardinal;
        if LoadELF(Path, Entry, GP) then
        begin
          PCardinal(@Result[0])^ := Entry;
          PCardinal(@Result[4])^ := GP;
        end
        else
          PInteger(@Result[0])^ := -1;
        SetLength(Result, 8);
      end;
    7, 8:
      PInteger(@Result[0])^ := 0;
    9:
      PInteger(@Result[0])^ := -200;
    $FF:
      // Version query: '....' (2020/2000 for those module versions).
      Result := TEncoding.ANSI.GetBytes('....');
  else
    PInteger(@Result[0])^ := -1;
  end;
end;

end.
