unit PSP.Loader;

// Module loader and ModuleMgrForUser. Fixed ELFs load at their addresses,
// PRX modules are relocated into the user partition. Imports become HLE
// syscall stubs, or jumps into another guest module that exports the library.
// Sony's firmware libraries a game ships on the disc are not loaded: their
// libraries are served by HLE.
// Relocation and address arithmetic wraps by design.
{$IFDEF PSP_CHECKED}{$Q-}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

{$RTTI EXPLICIT FIELDS([vcPrivate, vcProtected, vcPublic, vcPublished]) METHODS([vcPrivate, vcProtected, vcPublic,
  vcPublished]) PROPERTIES([vcPublic, vcPublished])}

uses
  System.SysUtils, System.Generics.Collections, PSP.Types, PSP.Memory, PSP.CPU,
  PSP.HLE, PSP.Kernel, PSP.IO, PSP.SysMem, PSP.State.Action;

const
  NID_MODULE_START = $D632ACDB;
  NID_MODULE_STOP = $CEE8593C;
  NID_MODULE_INFO = $F01D73A7;
  NID_MODULE_START_THREAD_PARAMETER = $0F7C276C;
  NID_MODULE_STOP_THREAD_PARAMETER = $CF0CC697;
  NID_MODULE_SDK_VERSION = $11B97506;

type
  TPSPImportStub = record
    Address: Cardinal;
    Lib: string;
    NID: Cardinal;
    Module: Cardinal;
  end;

  TPSPModule = class(TPSPKernelObject)
  public
    Path: string;
    Attr: Word;
    Version: array[0..1] of Byte;
    GP, Entry, StopEntry: Cardinal;
    Base, Size: Cardinal;
    TextAddr, TextSize, DataSize, BssSize: Cardinal;
    Segments: TArray<TPair<Cardinal, Cardinal>>;
    Exported: TDictionary<string, TDictionary<Cardinal, Cardinal>>;
    StartPriority, StartStack, StartAttr: Cardinal;
    StopPriority, StopStack, StopAttr: Cardinal;
    SdkVersion: Cardinal;
    Started, Stopped: Boolean;
    Fake: Boolean;
    Block: Cardinal;
    constructor Create;
    destructor Destroy; override;
    function ExportAddress(const Lib: string; NID: Cardinal): Cardinal;
  end;

  TPSPLoadExecEvent = function(const Path: string; ArgSize, ArgPtr: Cardinal): Cardinal of object;

  TPSPLoader = class
  private
    FKernel: TPSPKernel;
    FHLE: TPSPHLE;
    FMemory: TPSPMemory;
    FIO: TPSPIO;
    FModules: TList<TPSPModule>;
    FStubs: TList<TPSPImportStub>;
    FOnLoadExec: TPSPLoadExecEvent;
    FMainModule: TPSPModule;
    function Unwrap(const Data: TBytes; out Elf: TBytes; out Name: string): Cardinal;
    function IsFirmwareName(const Name: string): Boolean;
    function LoadElf(const Elf: TBytes; const Path: string; out M: TPSPModule): Cardinal;
    procedure Relocate(const Elf: TBytes; M: TPSPModule; const SegVaddr: TArray<Cardinal>);
    procedure RelocateTypeB(const Elf: TBytes; Offset, Size: Cardinal; M: TPSPModule; const SegVaddr: TArray<Cardinal>);
    procedure ReadModuleInfo(M: TPSPModule; InfoAddr: Cardinal);
    procedure SectionSizes(const Elf: TBytes; M: TPSPModule; Base: Cardinal);
    procedure LinkStub(const S: TPSPImportStub);
    procedure RelinkLibrary(const Lib: string);
    function FindExport(const Lib: string; NID: Cardinal): Cardinal;
    function ModuleOfAddress(Address: Cardinal): TPSPModule;
    procedure StartModuleThread(M: TPSPModule; ArgSize, ArgPtr, StatusPtr, OptPtr: Cardinal; const ArgData: TBytes; Wait: Boolean);
    procedure WaitForModuleThread(T: TPSPThread; Id, StatusPtr: Cardinal; Linger: Int64);
    function ThreadOptions(OptPtr: Cardinal; var Prio: Integer; var Stack, Attr: Cardinal): Cardinal;
    function NoRetry(T: TPSPThread): Boolean;
    procedure ScheduleThreadDelete(Id: Cardinal);
    procedure StateThreadDelete(Action: TPSPStateAction; Value: Cardinal);
    procedure StateThreadExited(Action: TPSPStateAction; Value: Cardinal);
    procedure StateLoadWait(Action: TPSPStateAction; Value: Cardinal);
    procedure StateLoad(Action: TPSPStateAction; Value: Cardinal);
    procedure LoadForCaller(const Data: TBytes; const Path: string);
    procedure hKprintf;
    procedure hIcacheClearAll;
    procedure hLoadModule;
    procedure hLoadModuleByID;
    procedure hLoadModuleBufferUsbWlan;
    procedure hStartModule;
    procedure hStopModule;
    procedure hUnloadModule;
    procedure hStopUnloadSelfModule;
    procedure hSelfStopUnloadModule;
    procedure hGetModuleIdByAddress;
    procedure hGetModuleId;
    procedure hGetModuleIdList;
    procedure hQueryModuleInfo;
    procedure hGetModuleGPByAddress;
    procedure hLoadExec;
    function StartRetry(T: TPSPThread): Boolean;
  public
    constructor Create(Kernel: TPSPKernel; IO: TPSPIO);
    destructor Destroy; override;
    procedure Reset;
    procedure Register;
    // Loads a module image (ELF, PRX, ~PSP, ~SCE). Returns 0 or a kernel error.
    function Load(const Data: TBytes; const Path: string; out M: TPSPModule): Cardinal;
    // Starts the main module: creates and starts its thread with the path as argument.
    procedure StartMain(M: TPSPModule; const Path: string; const Arguments: TBytes = nil; UseArguments: Boolean = False);
    function Validate(const Data: TBytes; const Path: string; ArgumentSize: Cardinal = 0): Cardinal;
    function Describe: string;
    property Modules: TList<TPSPModule> read FModules;
    property MainModule: TPSPModule read FMainModule;
    property OnLoadExec: TPSPLoadExecEvent read FOnLoadExec write FOnLoadExec;
  end;

implementation

uses
  System.Classes, System.ZLib, System.Math, PSP.PRX, PSP.Scheduler;

const
  SHT_PSPREL = $700000A0;
  PT_PSPREL1 = $700000A0;
  PT_PSPREL2 = $700000A1;

function LE16(const D: TBytes; O: Cardinal): Cardinal; inline;
begin
  Result := D[O] or (Cardinal(D[O + 1]) shl 8);
end;

function LE32(const D: TBytes; O: Cardinal): Cardinal; inline;
begin
  Result := PCardinal(@D[O])^;
end;

{ TPSPModule }

constructor TPSPModule.Create;
begin
  inherited Create;
  Exported := TObjectDictionary<string, TDictionary<Cardinal, Cardinal>>.Create([doOwnsValues]);
end;

destructor TPSPModule.Destroy;
begin
  Exported.Free;
  inherited;
end;

function TPSPModule.ExportAddress(const Lib: string; NID: Cardinal): Cardinal;
begin
  var D: TDictionary<Cardinal, Cardinal>;
  if Exported.TryGetValue(Lib, D) and D.TryGetValue(NID, Result) then
    Exit;
  Result := 0;
end;

{ TPSPLoader }

constructor TPSPLoader.Create(Kernel: TPSPKernel; IO: TPSPIO);
begin
  inherited Create;
  FKernel := Kernel;
  FHLE := Kernel.HLE;
  FMemory := Kernel.Memory;
  FIO := IO;
  FModules := TList<TPSPModule>.Create;
  FStubs := TList<TPSPImportStub>.Create;
end;

destructor TPSPLoader.Destroy;
begin
  FStubs.Free;
  FModules.Free;
  inherited;
end;

procedure TPSPLoader.Reset;
begin
  // Module objects belong to the kernel's object table.
  FModules.Clear;
  FStubs.Clear;
  FMainModule := nil;
end;

function TPSPLoader.IsFirmwareName(const Name: string): Boolean;
begin
  Result := Name.StartsWith('sce', True) or Name.StartsWith('Sce', False);
end;

function TPSPLoader.Unwrap(const Data: TBytes; out Elf: TBytes; out Name: string): Cardinal;
begin
  Name := '';
  Elf := Data;
  if (Length(Data) >= $160) and (Data[0] = Ord('~')) and (Data[1] = Ord('S')) and (Data[2] = Ord('C')) and
    (Data[3] = Ord('E')) then
  begin
    var Skip := LE32(Data, 4);
    if (Skip = 0) or (Skip >= Cardinal(Length(Data))) then
      Skip := $40;
    Elf := Copy(Data, Skip, Length(Data) - Integer(Skip));
  end;
  if (Length(Elf) >= $150) and (Elf[0] = Ord('~')) and (Elf[1] = Ord('P')) and (Elf[2] = Ord('S')) and
    (Elf[3] = Ord('P')) then
  begin
    var Raw: TBytes;
    SetLength(Raw, 28);
    Move(Elf[$0A], Raw[0], 28);
    var N := 0;
    while (N < 28) and (Raw[N] <> 0) do
      Inc(N);
    Name := TEncoding.ANSI.GetString(Raw, 0, N);
    try
      Elf := DecryptPSPPRX(Elf);
    except
      on E: Exception do
      begin
        FHLE.Log('loader: %s cannot be decrypted (%s)', [Name, E.Message]);
        Exit(SCE_KERNEL_ERROR_UNSUPPORTED_PRX_TYPE);
      end;
    end;
  end;
  if (Length(Elf) >= 2) and (Elf[0] = $1F) and (Elf[1] = $8B) then
  begin
    var Input := TBytesStream.Create(Elf);
    var Output := TBytesStream.Create;
    try
      var Z := TZDecompressionStream.Create(Input, 31);
      try
        Output.CopyFrom(Z, 0);
      finally
        Z.Free;
      end;
      Elf := Copy(Output.Bytes, 0, Output.Size);
    finally
      Input.Free;
      Output.Free;
    end;
  end;
  if (Length(Elf) < 52) or (Elf[0] <> $7F) or (Elf[1] <> Ord('E')) or (Elf[2] <> Ord('L')) or (Elf[3] <> Ord('F')) then
    Exit(SCE_KERNEL_ERROR_ILLEGAL_OBJECT);
  Result := 0;
end;

function TPSPLoader.Load(const Data: TBytes; const Path: string; out M: TPSPModule): Cardinal;
begin
  M := nil;
  var Elf: TBytes;
  var Name: string;
  Result := Unwrap(Data, Elf, Name);
  if (Result <> 0) or ((Name <> '') and IsFirmwareName(Name)) then
  begin
    if (Name = '') or not IsFirmwareName(Name) then
      Exit;
    // A firmware library: served by HLE.
    M := TPSPModule.Create;
    M.Name := Name;
    M.Path := Path;
    M.Fake := True;
    FKernel.AddObject(M);
    FModules.Add(M);
    FHLE.Log('loader: %s (%s) is provided by HLE', [Name, Path]);
    Exit(0);
  end;
  Result := LoadElf(Elf, Path, M);
end;

function TPSPLoader.LoadElf(const Elf: TBytes; const Path: string; out M: TPSPModule): Cardinal;
begin
  M := nil;
  var EType := LE16(Elf, 16);
  var Entry := LE32(Elf, 24);
  var PhOff := LE32(Elf, 28);
  var ShOff := LE32(Elf, 32);
  var PhNum := LE16(Elf, 44);
  var ShNum := LE16(Elf, 48);
  var ShStrNdx := LE16(Elf, 50);
  if (PhNum = 0) or (PhOff + PhNum * 32 > Cardinal(Length(Elf))) then
    Exit(SCE_KERNEL_ERROR_ILLEGAL_OBJECT);
  var Relocatable := EType = $FFA0;
  var Low: Cardinal := $FFFFFFFF;
  var High: Cardinal := 0;
  for var I := 0 to PhNum - 1 do
  begin
    var P := PhOff + Cardinal(I) * 32;
    if LE32(Elf, P) <> 1 then
      Continue;
    var VA := LE32(Elf, P + 8);
    var MemSz := LE32(Elf, P + 20);
    if VA < Low then
      Low := VA;
    if VA + MemSz > High then
      High := VA + MemSz;
  end;
  if High <= Low then
    Exit(SCE_KERNEL_ERROR_ILLEGAL_OBJECT);
  M := TPSPModule.Create;
  M.Path := Path;
  var Base: Cardinal;
  if Relocatable then
  begin
    var Block := FKernel.UserPartition.Alloc(High - Low, akLow, 0, 256, 'module');
    if Block = 0 then
    begin
      M.Free;
      M := nil;
      Exit(SCE_KERNEL_ERROR_NO_MEMORY);
    end;
    M.Block := Block;
    Base := Block - Low;
  end
  else
  begin
    var Start := Low and not Cardinal(255);
    var Block := FKernel.UserPartition.Alloc(High - Start, akAddress, Start, 256, 'module');
    if Block = 0 then
      FHLE.Log('loader: %s overlaps allocated memory at %.8x', [Path, Low]);
    M.Block := Block;
    Base := 0;
  end;
  M.Base := Base + Low;
  M.Size := High - Low;
  var SegVaddr: TArray<Cardinal>;
  SetLength(SegVaddr, PhNum);
  for var I := 0 to PhNum - 1 do
  begin
    var P := PhOff + Cardinal(I) * 32;
    var PType := LE32(Elf, P);
    var Off := LE32(Elf, P + 4);
    var VA := LE32(Elf, P + 8);
    var FileSz := LE32(Elf, P + 16);
    var MemSz := LE32(Elf, P + 20);
    SegVaddr[I] := VA;
    if PType <> 1 then
      Continue;
    var Dest := Base + VA;
    FMemory.Fill(Dest, 0, MemSz);
    if FileSz > 0 then
    begin
      if Off + FileSz > Cardinal(Length(Elf)) then
        FileSz := Cardinal(Length(Elf)) - Off;
      FMemory.WriteBytes(Dest, Elf[Off], FileSz);
    end;
    M.Segments := M.Segments + [TPair<Cardinal, Cardinal>.Create(Dest, MemSz)];
    if I = 0 then
    begin
      M.TextAddr := Dest;
      M.TextSize := FileSz;
    end
    else
      Inc(M.DataSize, FileSz);
    if MemSz > FileSz then
      Inc(M.BssSize, MemSz - FileSz);
  end;
  if Relocatable then
    Relocate(Elf, M, SegVaddr);
  // Module info: PRX keeps its file offset in the first segment's paddr.
  var InfoAddr: Cardinal := 0;
  var P0 := PhOff;
  var PAddr := LE32(Elf, P0 + 12);
  if Relocatable then
    InfoAddr := Base + SegVaddr[0] + (PAddr and $7FFFFFFF) - LE32(Elf, P0 + 4)
  else
  begin
    if (ShOff <> 0) and (ShNum > 0) and (ShStrNdx < ShNum) and (ShOff + ShNum * 40 <= Cardinal(Length(Elf))) then
    begin
      var StrOff := LE32(Elf, ShOff + ShStrNdx * 40 + 16);
      for var I := 0 to ShNum - 1 do
      begin
        var S := ShOff + Cardinal(I) * 40;
        var NameOff := StrOff + LE32(Elf, S);
        var NameStr := '';
        while (NameOff < Cardinal(Length(Elf))) and (Elf[NameOff] <> 0) do
        begin
          NameStr := NameStr + Char(Elf[NameOff]);
          Inc(NameOff);
        end;
        if NameStr = '.rodata.sceModuleInfo' then
          InfoAddr := LE32(Elf, S + 12);
      end;
    end;
    // Otherwise the first segment's paddr is the module info's file offset
    // (old SDKs put its address there instead).
    if InfoAddr = 0 then
      if PAddr >= SegVaddr[0] then
        InfoAddr := PAddr
      else
        InfoAddr := SegVaddr[0] + PAddr - LE32(Elf, P0 + 4);
  end;
  if (InfoAddr = 0) or not FMemory.Valid(InfoAddr, 52) then
  begin
    FKernel.UserPartition.FreeBlock(M.Block);
    M.Free;
    M := nil;
    Exit(SCE_KERNEL_ERROR_ILLEGAL_OBJECT);
  end;
  M.Entry := Base + Entry;
  if Entry = $FFFFFFFF then
    M.Entry := 0;
  FKernel.AddObject(M);
  FModules.Add(M);
  // Some games ship libfont as a plain ELF rather than a ~PSP module. It is
  // the same firmware service: do not replace sceLibFont's HLE stubs with code
  // that needs the firmware's private registry and font files in flash0.
  M.Name := FMemory.ReadString(InfoAddr + 4, 28);
  if M.Name = 'sceFont_Library' then
  begin
    M.Fake := True;
    FKernel.UserPartition.FreeBlock(M.Block);
    M.Block := 0;
    M.Base := 0;
    M.Size := 0;
    M.Entry := 0;
    FHLE.Log('loader: %s (%s) is provided by HLE', [M.Name, Path]);
  end
  else
  begin
    SectionSizes(Elf, M, Base);
    ReadModuleInfo(M, InfoAddr);
  end;
  FKernel.CPU.FlushDecoded;
  Result := 0;
end;

// Text (code and read-only data), data and bss sizes as the module manager
// reports them: from the allocated sections when the file has them.
procedure TPSPLoader.SectionSizes(const Elf: TBytes; M: TPSPModule; Base: Cardinal);
begin
  var ShOff := LE32(Elf, 32);
  var ShNum := LE16(Elf, 48);
  if (ShOff = 0) or (ShNum = 0) or (ShOff + ShNum * 40 > Cardinal(Length(Elf))) then
    Exit;
  var TextEnd: Cardinal := 0;
  var DataEnd: Cardinal := 0;
  var BssEnd: Cardinal := 0;
  var Found := False;
  for var I := 0 to ShNum - 1 do
  begin
    var S := ShOff + Cardinal(I) * 40;
    var Kind := LE32(Elf, S + 4);
    var Flags := LE32(Elf, S + 8);
    var Addr := Base + LE32(Elf, S + 12);
    var Size := LE32(Elf, S + 20);
    if ((Flags and 2) = 0) or (Size = 0) or (Addr < M.TextAddr) then
      Continue;
    if Kind >= $70000000 then
      Continue;
    Found := True;
    var Stop := Addr + Size - M.TextAddr;
    if Kind = 8 then
      Inc(BssEnd, Size)
    else if (Flags and 1) <> 0 then
      Inc(DataEnd, Size)
    else if Stop > TextEnd then
      TextEnd := Stop;
  end;
  if not Found then
    Exit;
  M.TextSize := TextEnd;
  M.DataSize := DataEnd;
  M.BssSize := BssEnd;
end;

procedure TPSPLoader.Relocate(const Elf: TBytes; M: TPSPModule; const SegVaddr: TArray<Cardinal>);
begin
  var Base := M.Base - SegVaddr[0];
  var PhOff := LE32(Elf, 28);
  var ShOff := LE32(Elf, 32);
  var PhNum := LE16(Elf, 44);
  var ShNum := LE16(Elf, 48);
  var Ranges: TArray<TPair<Cardinal, Cardinal>>;
  // Section relocations first; program header ones are the same data.
  if (ShOff <> 0) and (ShOff + ShNum * 40 <= Cardinal(Length(Elf))) then
    for var I := 0 to ShNum - 1 do
    begin
      var S := ShOff + Cardinal(I) * 40;
      if LE32(Elf, S + 4) = SHT_PSPREL then
        Ranges := Ranges + [TPair<Cardinal, Cardinal>.Create(LE32(Elf, S + 16), LE32(Elf, S + 20))];
    end;
  if Length(Ranges) = 0 then
    for var I := 0 to PhNum - 1 do
    begin
      var P := PhOff + Cardinal(I) * 32;
      var T := LE32(Elf, P);
      if T = PT_PSPREL1 then
        Ranges := Ranges + [TPair<Cardinal, Cardinal>.Create(LE32(Elf, P + 4), LE32(Elf, P + 16))]
      else if T = PT_PSPREL2 then
        RelocateTypeB(Elf, LE32(Elf, P + 4), LE32(Elf, P + 16), M, SegVaddr);
    end;
  for var R in Ranges do
  begin
    var Count := R.Value div 8;
    var HiList := TList<Cardinal>.Create;
    try
      for var K := 0 to Integer(Count) - 1 do
      begin
        var E := R.Key + Cardinal(K) * 8;
        if E + 8 > Cardinal(Length(Elf)) then
          Break;
        var Offset := LE32(Elf, E);
        var Info := LE32(Elf, E + 4);
        var Kind := Info and $FF;
        var OfsBase := (Info shr 8) and $FF;
        var AddrBase := (Info shr 16) and $FF;
        if (OfsBase >= Cardinal(Length(SegVaddr))) or (AddrBase >= Cardinal(Length(SegVaddr))) then
          Continue;
        var A := Base + SegVaddr[OfsBase] + Offset;
        var Delta := Base + SegVaddr[AddrBase];
        var W := FMemory.Read32(A);
        case Kind of
          0:
            ;
          1:
            FMemory.Write32(A, (W and $FFFF0000) or ((W + Delta) and $FFFF));
          2:
            FMemory.Write32(A, W + Delta);
          4:
            FMemory.Write32(A, (W and $FC000000) or ((((W and $03FFFFFF) shl 2) + Delta) shr 2 and $03FFFFFF));
          5:
            HiList.Add(A or 0);
          6:
            begin
              var Lo := Cardinal(Integer(SmallInt(Word(W))));
              for var H in HiList do
              begin
                var HW := FMemory.Read32(H);
                var Full := (HW shl 16) + Lo + Delta;
                FMemory.Write32(H, (HW and $FFFF0000) or (((Full + $8000) shr 16) and $FFFF));
              end;
              HiList.Clear;
              FMemory.Write32(A, (W and $FFFF0000) or ((Lo + Delta) and $FFFF));
            end;
          7:
            ;
        else
          FHLE.Log('loader: relocation type %d at %.8x', [Kind, A]);
        end;
      end;
    finally
      HiList.Free;
    end;
  end;
end;

procedure TPSPLoader.RelocateTypeB(const Elf: TBytes; Offset, Size: Cardinal; M: TPSPModule; const SegVaddr: TArray<Cardinal>);
begin
  // Compressed relocation stream of newer SDKs.
  var Base := M.Base - SegVaddr[0];
  var P := Offset;
  var Stop := Offset + Size;
  if (Stop > Cardinal(Length(Elf))) or (Size < 8) then
    Exit;
  if (Elf[P] <> 0) or (Elf[P + 1] <> 0) then
  begin
    FHLE.Log('loader: unknown type B relocation header in %s', [M.Path]);
    Exit;
  end;
  var Part1s := Elf[P + 2];
  var Part2s := Elf[P + 3];
  var Block1s := Elf[P + 4];
  var Block1 := P + 4;
  P := P + 4 + Block1s;
  var Block2s := Elf[P];
  var Block2 := P;
  P := P + Block2s;
  var OfsBase: Cardinal := 0;
  var AddrSeg: Cardinal := 0;
  var Offs: Cardinal := 0;
  var LastPart2 := Block2s;
  var LastHI: Cardinal := 0;
  var HaveHI := False;
  while P + 2 <= Stop do
  begin
    var Cmd := LE16(Elf, P);
    Inc(P, 2);
    var T1 := (Cmd shl (16 - Part1s)) and $FFFF;
    T1 := (T1 shr (16 - Part1s)) and $FFFF;
    if T1 >= Block1s then
    begin
      FHLE.Log('loader: bad type B relocation in %s', [M.Path]);
      Exit;
    end;
    var Part1 := Elf[Block1 + T1];
    if (Part1 and 1) = 0 then
    begin
      // Selects the segment the following offsets are in.
      OfsBase := Part1 shr 1;
      if (Part1 and 6) = 0 then
      begin
        Offs := Cmd shr (Part1s + Part2s);
        if (Part1 and 8) <> 0 then
        begin
          Offs := Offs or (Cardinal(LE16(Elf, P)) shl (16 - Part1s - Part2s));
          Inc(P, 2);
        end;
      end
      else
        Offs := 0;
      AddrSeg := (Part1 shr 1) and 3;
      Continue;
    end;
    var T2 := (Cmd shl (16 - (Part1s + Part2s))) and $FFFF;
    T2 := (T2 shr (16 - Part2s)) and $FFFF;
    if T2 >= Block2s then
    begin
      FHLE.Log('loader: bad type B relocation type in %s', [M.Path]);
      Exit;
    end;
    var AddrBase := (Part1 shr 1) and 3;
    var Kind := Elf[Block2 + T2];
    case Part1 and 6 of
      0:
        begin
          var D := Cmd;
          if (D and $8000) <> 0 then
            D := D or $FFFF0000;
          D := Cardinal(Integer(D) shr (Part1s + Part2s)) shl 2;
          Offs := Offs + D;
        end;
      2:
        begin
          var D := Cmd;
          if (D and $8000) <> 0 then
            D := D or $FFFF0000;
          D := (Cardinal(Integer(D) shr (Part1s + Part2s)) shl 16) or LE16(Elf, P);
          Inc(P, 2);
          Offs := Offs + D;
        end;
      4:
        begin
          Offs := (Cardinal(LE16(Elf, P + 2)) shl 16) or LE16(Elf, P);
          Inc(P, 4);
        end;
    else
      FHLE.Log('loader: bad type B relocation mode in %s', [M.Path]);
      Exit;
    end;
    if (OfsBase >= Cardinal(Length(SegVaddr))) or (AddrBase >= Cardinal(Length(SegVaddr))) then
      Continue;
    var A := Base + SegVaddr[OfsBase] + Offs;
    var Delta := Base + SegVaddr[AddrBase];
    var W := FMemory.Read32(A);
    case Kind of
      2:
        FMemory.Write32(A, W + Delta);
      0, 1:
        ;
      4, 7:
        FMemory.Write32(A, (W and $FC000000) or ((((W and $03FFFFFF) shl 2) + Delta) shr 2 and $03FFFFFF));
      6:
        begin
          // LO16
          var Lo := Cardinal(Integer(SmallInt(Word(W))));
          if HaveHI then
          begin
            var HW := FMemory.Read32(LastHI);
            var Full := (HW shl 16) + Lo + Delta;
            FMemory.Write32(LastHI, (HW and $FFFF0000) or (((Full + $8000) shr 16) and $FFFF));
            HaveHI := False;
          end;
          FMemory.Write32(A, (W and $FFFF0000) or ((Lo + Delta) and $FFFF));
        end;
      5:
        begin
          LastHI := A;
          HaveHI := True;
        end;
    else
      FHLE.Log('loader: type B relocation %d at %.8x', [Kind, A]);
    end;
    LastPart2 := T2;
  end;
  if LastPart2 = 0 then
    ;
  if AddrSeg = 0 then
    ;
end;

procedure TPSPLoader.ReadModuleInfo(M: TPSPModule; InfoAddr: Cardinal);
begin
  M.Attr := FMemory.Read16(InfoAddr);
  M.Version[0] := FMemory.Read8(InfoAddr + 2);
  M.Version[1] := FMemory.Read8(InfoAddr + 3);
  M.Name := FMemory.ReadString(InfoAddr + 4, 27);
  M.GP := FMemory.Read32(InfoAddr + 32);
  var EntTop := FMemory.Read32(InfoAddr + 36);
  var EntEnd := FMemory.Read32(InfoAddr + 40);
  var StubTop := FMemory.Read32(InfoAddr + 44);
  var StubEnd := FMemory.Read32(InfoAddr + 48);
  var Delta := M.Base - (M.Base - (M.Block and 0));
  if Delta = 0 then
    ;
  // For relocated modules the pointers were relocated with the module.
  // Exported
  var P := EntTop;
  var NewLibs: TArray<string>;
  while (P < EntEnd) and FMemory.Valid(P, 16) do
  begin
    var LibNamePtr := FMemory.Read32(P);
    var Len := FMemory.Read8(P + 8);
    var VarCount := FMemory.Read8(P + 9);
    var FuncCount := FMemory.Read16(P + 10);
    var Table := FMemory.Read32(P + 12);
    var Lib := '';
    if LibNamePtr <> 0 then
      Lib := FMemory.ReadString(LibNamePtr, 64);
    var D := TDictionary<Cardinal, Cardinal>.Create;
    var Total := Integer(FuncCount) + Integer(VarCount);
    for var I := 0 to Total - 1 do
    begin
      var NID := FMemory.Read32(Table + Cardinal(I) * 4);
      var Addr := FMemory.Read32(Table + Cardinal(Total + I) * 4);
      D.AddOrSetValue(NID, Addr);
    end;
    if Lib = '' then
    begin
      var V: Cardinal;
      if D.TryGetValue(NID_MODULE_START, V) then
        M.Entry := V;
      if D.TryGetValue(NID_MODULE_STOP, V) then
        M.StopEntry := V;
      if D.TryGetValue(NID_MODULE_START_THREAD_PARAMETER, V) and FMemory.Valid(V, 16) then
      begin
        M.StartPriority := FMemory.Read32(V + 4);
        M.StartStack := FMemory.Read32(V + 8);
        M.StartAttr := FMemory.Read32(V + 12);
      end;
      if D.TryGetValue(NID_MODULE_STOP_THREAD_PARAMETER, V) and FMemory.Valid(V, 16) then
      begin
        M.StopPriority := FMemory.Read32(V + 4);
        M.StopStack := FMemory.Read32(V + 8);
        M.StopAttr := FMemory.Read32(V + 12);
      end;
      if D.TryGetValue(NID_MODULE_SDK_VERSION, V) and FMemory.Valid(V, 4) then
        M.SdkVersion := FMemory.Read32(V);
      D.Free;
    end
    else
    begin
      if M.Exported.ContainsKey(Lib) then
        M.Exported[Lib] := D
      else
        M.Exported.Add(Lib, D);
      NewLibs := NewLibs + [Lib];
    end;
    if Len < 4 then
      Len := 4;
    Inc(P, Cardinal(Len) * 4);
  end;
  // Imports
  P := StubTop;
  while (P < StubEnd) and FMemory.Valid(P, 20) do
  begin
    var LibNamePtr := FMemory.Read32(P);
    var Len := FMemory.Read8(P + 8);
    var VarCount := FMemory.Read8(P + 9);
    var FuncCount := FMemory.Read16(P + 10);
    var NidTable := FMemory.Read32(P + 12);
    var StubTable := FMemory.Read32(P + 16);
    var Lib := FMemory.ReadString(LibNamePtr, 64);
    for var I := 0 to Integer(FuncCount) - 1 do
    begin
      var S := Default(TPSPImportStub);
      S.Address := StubTable + Cardinal(I) * 8;
      S.Lib := Lib;
      S.NID := FMemory.Read32(NidTable + Cardinal(I) * 4);
      S.Module := M.UID;
      FStubs.Add(S);
      LinkStub(S);
    end;
    if (VarCount > 0) and (Len >= 6) then
      FHLE.Log('loader: %s imports %d variables of %s', [M.Name, VarCount, Lib]);
    if Len < 5 then
      Len := 5;
    Inc(P, Cardinal(Len) * 4);
  end;
  for var Lib in NewLibs do
    RelinkLibrary(Lib);
end;

function TPSPLoader.FindExport(const Lib: string; NID: Cardinal): Cardinal;
begin
  for var M in FModules do
    if not M.Fake then
    begin
      Result := M.ExportAddress(Lib, NID);
      if Result <> 0 then
        Exit;
    end;
  Result := 0;
end;

procedure TPSPLoader.LinkStub(const S: TPSPImportStub);
begin
  var Target := FindExport(S.Lib, S.NID);
  if Target <> 0 then
  begin
    FMemory.Write32(S.Address, $08000000 or ((Target shr 2) and $03FFFFFF));
    FMemory.Write32(S.Address + 4, 0);
  end
  else
    FHLE.WriteStub(S.Address, FHLE.Resolve(S.Lib, S.NID));
end;

procedure TPSPLoader.RelinkLibrary(const Lib: string);
begin
  for var S in FStubs do
    if S.Lib = Lib then
      LinkStub(S);
end;

function TPSPLoader.ModuleOfAddress(Address: Cardinal): TPSPModule;
begin
  for var M in FModules do
    if not M.Fake and (Address >= M.Base) and (Address < M.Base + M.Size) then
      Exit(M);
  Result := nil;
end;

procedure TPSPLoader.StartMain(M: TPSPModule; const Path: string; const Arguments: TBytes; UseArguments: Boolean);
begin
  FMainModule := M;
  var Prio: Integer := $20;
  var Stack: Cardinal := $40000;
  var Attr: Cardinal := $80004000;
  // A kernel module starts in a kernel thread.
  var KernelMode := (M.Attr and $1000) <> 0;
  if KernelMode then
    Attr := 0;
  if (M.StartPriority >= 8) and (M.StartPriority <= 119) then
    Prio := M.StartPriority;
  if M.StartStack >= $200 then
    Stack := M.StartStack;
  if M.StartAttr <> 0 then
    if KernelMode then
      Attr := M.StartAttr
    else
      Attr := M.StartAttr or $80000000;
  var T := FKernel.CreateThread('user_main', M.Entry, Prio, Stack, Attr, M.GP, M.UID);
  if T = nil then
    raise EPSPError.Create('PSP: no memory for the main thread');
  // The module manager deletes the start thread once module_start returns.
  T.DeleteOnExit := True;
  var Arg := Arguments;
  if not UseArguments then
  begin
    Arg := TEncoding.ANSI.GetBytes(Path);
    SetLength(Arg, Length(Arg) + 1);
    Arg[High(Arg)] := 0;
  end;
  FKernel.StartThread(T, 0, 0, Arg);
  M.Started := True;
  FKernel.Reschedule;
end;

function TPSPLoader.StartRetry(T: TPSPThread): Boolean;
begin
  var Starter := TPSPThread(FKernel.GetObject(T.Wait.Id, TPSPThread));
  Result := (Starter = nil) or ((Starter.Status and PSPThreadDormant) <> 0);
  if Result then
  begin
    if (Starter <> nil) and (T.Wait.Data[0] <> 0) then
      FMemory.Write32(T.Wait.Data[0], Starter.ExitStatus);
    T.SetResult(T.Wait.Data[1]);
  end;
end;

// The module manager deletes its start and stop threads once they end.
procedure TPSPLoader.ScheduleThreadDelete(Id: Cardinal);
begin
  FKernel.AddStateTimer(FKernel.Scheduler.Now, nil, TPSPStateAction.Create(StateThreadDelete, [], [Id]));
end;

procedure TPSPLoader.StateThreadDelete(Action: TPSPStateAction; Value: Cardinal);
begin
  var X := FKernel.ThreadById(Cardinal(Action.Arg(0)));
  if (X <> nil) and ((X.Status and PSPThreadDormant) <> 0) then
    FKernel.DeleteThread(X);
end;

// A SceKernelSMOption's stack size, priority and attributes for a module's
// start or stop thread. Returns 0 or the error the module manager gives.
function TPSPLoader.ThreadOptions(OptPtr: Cardinal; var Prio: Integer; var Stack, Attr: Cardinal): Cardinal;
begin
  Result := 0;
  if OptPtr = 0 then
    Exit;
  // Programs built for the 6.xx SDK must give the option's size; older ones
  // have it ignored.
  var Size := FMemory.Read32(OptPtr);
  if (FKernel.CompiledSdkVersion >= $06000000) and (Size <> $14) then
    Exit(SCE_KERNEL_ERROR_ILLEGAL_SIZE);
  var Part := Integer(FMemory.Read32(OptPtr + 4));
  var OS := FMemory.Read32(OptPtr + 8);
  var OP := Integer(FMemory.Read32(OptPtr + 12));
  var OA := FMemory.Read32(OptPtr + 16);
  if not (Part in [0, 2, 6]) then
    Exit(SCE_KERNEL_ERROR_PARTITION_MISMATCH);
  if OS <> 0 then
  begin
    if OS < $200 then
      Exit(SCE_KERNEL_ERROR_ILLEGAL_STACK_SIZE);
    Stack := OS;
  end;
  if OP <> 0 then
  begin
    if (OP < 1) or (OP > 126) then
      Exit(SCE_KERNEL_ERROR_ILLEGAL_PRIORITY);
    Prio := OP;
  end;
  if (OA and not Cardinal($00F06000)) <> 0 then
    Exit(SCE_KERNEL_ERROR_ERROR);
  Attr := Attr or OA;
end;

procedure TPSPLoader.StartModuleThread(M: TPSPModule; ArgSize, ArgPtr, StatusPtr, OptPtr: Cardinal; const ArgData: TBytes; Wait: Boolean);
begin
  var Prio: Integer := $20;
  var Stack: Cardinal := $40000;
  var Attr: Cardinal := $800000FF;
  if (M.StartPriority >= 1) and (M.StartPriority <= 126) then
    Prio := M.StartPriority;
  if M.StartStack >= $200 then
    Stack := M.StartStack;
  if M.StartAttr <> 0 then
    Attr := Attr or (M.StartAttr and $00F06000);
  var Err := ThreadOptions(OptPtr, Prio, Stack, Attr);
  if Err <> 0 then
  begin
    FHLE.Result(Err);
    Exit;
  end;
  var T := FKernel.CreateThread('SceModmgrStart', M.Entry, Prio, Stack, $80000000, M.GP, M.UID);
  if T = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_NO_MEMORY);
    Exit;
  end;
  T.Attr := Attr;
  M.Started := True;
  FHLE.Result(M.UID);
  FKernel.StartThread(T, ArgSize, ArgPtr, ArgData);
  if Wait and FKernel.CanWait then
    WaitForModuleThread(T, M.UID, StatusPtr, 0)
  else
  begin
    T.ExitState := TPSPStateAction.Create(StateThreadExited, [], [T.UID, 0, 0, 0, 0]);
  end;
end;

procedure TPSPLoader.WaitForModuleThread(T: TPSPThread; Id, StatusPtr: Cardinal; Linger: Int64);
begin
  var Caller := FKernel.Current;
  T.ExitState := TPSPStateAction.Create(StateThreadExited, [], [T.UID, Caller.UID, Id, StatusPtr, Linger]);
  FKernel.BeginWait(PSPWaitThreadEnd, nil, T.UID, 0, False, StartRetry, nil, 'module');
  if Caller.Wait.HLETag = 'module' then
  begin
    Caller.Wait.Data[0] := StatusPtr;
    Caller.Wait.Data[1] := Id;
  end;
end;

procedure TPSPLoader.StateThreadExited(Action: TPSPStateAction; Value: Cardinal);
begin
  var StatusPtr := Cardinal(Action.Arg(3));
  if StatusPtr <> 0 then
    FMemory.Write32(StatusPtr, Value);
  var ThreadID := Cardinal(Action.Arg(0));
  ScheduleThreadDelete(ThreadID);
  var Caller := FKernel.ThreadById(Cardinal(Action.Arg(1)));
  if (Caller <> nil) and Caller.IsWaiting and (Caller.Wait.HLETag = 'module') and (Caller.Wait.Id = ThreadID) then
  begin
    if Action.Arg(4) > 0 then
      FKernel.AddWakeTimer(FKernel.Scheduler.Now + Action.Arg(4), Caller, 'module', Cardinal(Action.Arg(2)))
    else
      FKernel.EndWait(Caller, Cardinal(Action.Arg(2)));
  end;
end;

procedure TPSPLoader.LoadForCaller(const Data: TBytes; const Path: string);
begin
  if not FKernel.CanWait then
  begin
    var M: TPSPModule;
    var Err := Load(Data, Path, M);
    if Err <> 0 then
      FHLE.Result(Err)
    else
      FHLE.Result(M.UID);
    Exit;
  end;
  // The file is read while the caller waits; the module reaches memory at the end.
  var Caller := FKernel.Current;
  var Host: Boolean;
  if FIO.CostedDevice(Path, Host) then
  begin
    // The driver's open, read and close, then relocating and linking on the
    // caller's time (probe io_cost; threads/scheduling/callcosts).
    var Busy: Int64 := 1860000 + Int64(Length(Data)) * 264 div 10;
    var Wait: Int64 := 0;
    for var C in [icOpen, icRead, icClose] do
    begin
      var B, W: Int64;
      TPSPIO.DeviceCost(Host, C, Length(Data), 0, B, W);
      Inc(Busy, B);
      Inc(Wait, W);
    end;
    FHLE.Result(0);
    var Next := TPSPStateAction.Create(StateLoadWait, [], [Caller.UID, Wait]);
    Next.Data := Data;
    Next.Text := Path;
    FKernel.SpendThen(Busy, Next);
    Exit;
  end;
  var Latency := Int64(2000000) + Int64(Length(Data)) * 1000000000 div (8 * 1024 * 1024);
  FHLE.Result(0);
  FKernel.BeginWait(PSPWaitEventFlag, nil, 0, 0, False, NoRetry, nil, 'loadmodule');
  var A := TPSPStateAction.Create(StateLoad, [], [Caller.UID]);
  A.Data := Data;
  A.Text := Path;
  FKernel.AddStateTimer(FKernel.Scheduler.Now + Latency, Caller, A);
end;

procedure TPSPLoader.StateLoadWait(Action: TPSPStateAction; Value: Cardinal);
begin
  var Caller := FKernel.Current;
  if (Caller = nil) or (Caller.UID <> Cardinal(Action.Arg(0))) then
    Exit;
  FKernel.BeginWait(PSPWaitEventFlag, nil, 0, 0, False, NoRetry, nil, 'loadmodule');
  var A := TPSPStateAction.Create(StateLoad, [], [Caller.UID]);
  A.Data := Action.Data;
  A.Text := Action.Text;
  FKernel.AddStateTimer(FKernel.Scheduler.Now + Action.Arg(1), Caller, A);
end;

procedure TPSPLoader.StateLoad(Action: TPSPStateAction; Value: Cardinal);
begin
  var Caller := FKernel.ThreadById(Cardinal(Action.Arg(0)));
  if (Caller = nil) or not Caller.IsWaiting or (Caller.Wait.HLETag <> 'loadmodule') then
    Exit;
  var M: TPSPModule;
  var E := Load(Action.Data, Action.Text, M);
  if E <> 0 then
  begin
    FHLE.Log('sceKernelLoadModule %s failed %.8x', [Action.Text, E]);
    FKernel.EndWait(Caller, E);
  end
  else
  begin
    FHLE.Log('sceKernelLoadModule %s -> %s %x', [Action.Text, M.Name, M.UID]);
    FKernel.EndWait(Caller, M.UID);
  end;
end;

procedure TPSPLoader.hLoadModule;
begin
  var Path := FMemory.ReadString(FHLE.Arg(0), 1024);
  var Data: TBytes;
  var Err := FIO.ReadAll(Path, Data);
  if Err <> 0 then
  begin
    FHLE.Log('sceKernelLoadModule %s -> %.8x', [Path, Err]);
    FHLE.Result(Err);
    Exit;
  end;
  LoadForCaller(Data, Path);
end;

procedure TPSPLoader.hLoadModuleByID;
begin
  var Data: TBytes;
  var Path: string;
  var Err := FIO.ReadOpen(FHLE.Arg(0), Data, Path);
  if Err <> 0 then
  begin
    FHLE.Result(Err);
    Exit;
  end;
  LoadForCaller(Data, Path);
end;

function TPSPLoader.NoRetry(T: TPSPThread): Boolean;
begin
  Result := False;
end;

procedure TPSPLoader.hLoadModuleBufferUsbWlan;
begin
  FHLE.Unimplemented('usb/wlan module buffer');
  FHLE.Result(SCE_KERNEL_ERROR_ERROR);
end;

procedure TPSPLoader.hStartModule;
begin
  if FKernel.RefuseWait then
    Exit;
  var M := TPSPModule(FKernel.GetObject(FHLE.Arg(0), TPSPModule));
  if M = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_MODULE);
    Exit;
  end;
  if M.Started then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ALREADY_STARTED);
    Exit;
  end;
  var StatusPtr := FHLE.Arg(3);
  if M.Fake or (M.Entry = 0) then
  begin
    M.Started := True;
    if StatusPtr <> 0 then
      FMemory.Write32(StatusPtr, 0);
    FHLE.Result(M.UID);
    Exit;
  end;
  StartModuleThread(M, FHLE.Arg(1), FHLE.Arg(2), StatusPtr, FHLE.Arg(4), nil, True);
end;

procedure TPSPLoader.hStopModule;
begin
  if FKernel.RefuseWait then
    Exit;
  var M := TPSPModule(FKernel.GetObject(FHLE.Arg(0), TPSPModule));
  if M = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_MODULE);
    Exit;
  end;
  if not M.Started then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_NOT_STARTED);
    Exit;
  end;
  if M.Stopped then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ALREADY_STOPPED);
    Exit;
  end;
  var StatusPtr := FHLE.Arg(3);
  var Prio: Integer := $20;
  var Stack: Cardinal := $40000;
  var Attr: Cardinal := $800000FF;
  if (M.StopPriority >= 1) and (M.StopPriority <= 126) then
    Prio := M.StopPriority;
  if M.StopStack >= $200 then
    Stack := M.StopStack;
  if M.StopAttr <> 0 then
    Attr := Attr or (M.StopAttr and $00F06000);
  var Err := ThreadOptions(FHLE.Arg(4), Prio, Stack, Attr);
  if Err <> 0 then
  begin
    FHLE.Result(Err);
    Exit;
  end;
  M.Stopped := True;
  if M.Fake or (M.StopEntry = 0) then
  begin
    if StatusPtr <> 0 then
      FMemory.Write32(StatusPtr, 0);
    FHLE.Result(0);
    Exit;
  end;
  var T := FKernel.CreateThread('SceModmgrStop', M.StopEntry, Prio, Stack, $80000000, M.GP, M.UID);
  if T = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_NO_MEMORY);
    Exit;
  end;
  T.Attr := Attr;
  FHLE.Result(0);
  FKernel.StartThread(T, FHLE.Arg(1), FHLE.Arg(2));
  if FKernel.CanWait then
    WaitForModuleThread(T, 0, StatusPtr, 1500000);
end;

procedure TPSPLoader.hUnloadModule;
begin
  var M := TPSPModule(FKernel.GetObject(FHLE.Arg(0), TPSPModule));
  if M = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_MODULE);
    Exit;
  end;
  if M.Started and not M.Stopped and not M.Fake then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_NOT_STOPPED);
    Exit;
  end;
  var Id := M.UID;
  var FillTime := TPSPKernel.MemoryFillTime(M.Size);
  if not M.Fake then
  begin
    // What is left behind: text as break 1, data and bss as $FFFFFFFF.
    var A := M.TextAddr;
    while A < M.TextAddr + M.TextSize do
    begin
      FMemory.Write32(A, $0000004D);
      Inc(A, 4);
    end;
    if M.Size > M.TextSize then
      FMemory.Fill(M.TextAddr + M.TextSize, $FF, M.Size - M.TextSize);
  end;
  if M.Block <> 0 then
    FKernel.UserPartition.FreeBlock(M.Block);
  FModules.Remove(M);
  for var I := FStubs.Count - 1 downto 0 do
    if FStubs[I].Module = Id then
      FStubs.Delete(I);
  FKernel.DeleteObject(M);
  FHLE.Result(Id);
  // Clearing module memory and bookkeeping are CPU work, not a drive wait.
  // Higher-priority threads can preempt it. The manager's completion handoff
  // lets an equal-priority ready thread run, without donating CPU time to a
  // lower-priority spinner while the manager works.
  FKernel.SpendPreemptible(245000 + FillTime, True);
end;

procedure TPSPLoader.hStopUnloadSelfModule;
begin
  var T := FKernel.Current;
  var M: TPSPModule := nil;
  if T <> nil then
    M := TPSPModule(FKernel.GetObject(T.ModuleId, TPSPModule));
  if M <> nil then
    M.Stopped := True;
  FHLE.Result(0);
  FKernel.ExitCurrent(0);
end;

procedure TPSPLoader.hSelfStopUnloadModule;
begin
  hStopUnloadSelfModule;
end;

procedure TPSPLoader.hGetModuleIdByAddress;
begin
  var M := ModuleOfAddress(FHLE.Arg(0));
  if M = nil then
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_MODULE)
  else
    FHLE.Result(M.UID);
end;

procedure TPSPLoader.hGetModuleId;
begin
  var M := ModuleOfAddress(FKernel.CPU.Ctx.GPR[31]);
  if (M = nil) and (FKernel.Current <> nil) then
    M := TPSPModule(FKernel.GetObject(FKernel.Current.ModuleId, TPSPModule));
  if M = nil then
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_MODULE)
  else
    FHLE.Result(M.UID);
end;

procedure TPSPLoader.hGetModuleIdList;
begin
  var Buf := FHLE.Arg(0);
  var Size := FHLE.ArgInt(1);
  var CountPtr := FHLE.Arg(2);
  if (Buf = 0) or (Size < 0) or ((Buf and $80000000) <> 0) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ADDR);
    Exit;
  end;
  // Whole entries, and the first bytes of a partial one.
  var N := 0;
  for var M in FModules do
  begin
    var Off := N * 4;
    if Off < Size then
    begin
      var Id := M.UID;
      var Bytes := Size - Off;
      if Bytes > 4 then
        Bytes := 4;
      FMemory.WriteBytes(Buf + Cardinal(Off), Id, Bytes);
    end;
    Inc(N);
  end;
  if CountPtr <> 0 then
    FMemory.Write32(CountPtr, Cardinal(N));
  FHLE.Result(0);
end;

procedure TPSPLoader.hQueryModuleInfo;
begin
  var M := TPSPModule(FKernel.GetObject(FHLE.Arg(0), TPSPModule));
  if M = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_MODULE);
    Exit;
  end;
  var P := FHLE.Arg(1);
  var Size := FMemory.Read32(P);
  if Size > $60 then
    Size := $60;
  var Buf: array[0..$5F] of Byte;
  FillChar(Buf, SizeOf(Buf), 0);
  PCardinal(@Buf[0])^ := FMemory.Read32(P);
  Buf[4] := Length(M.Segments);
  for var I := 0 to Min(3, High(M.Segments)) do
  begin
    PCardinal(@Buf[8 + I * 4])^ := M.Segments[I].Key;
    PCardinal(@Buf[24 + I * 4])^ := M.Segments[I].Value;
  end;
  PCardinal(@Buf[40])^ := M.Entry;
  PCardinal(@Buf[44])^ := M.GP;
  PCardinal(@Buf[48])^ := M.TextAddr;
  PCardinal(@Buf[52])^ := M.TextSize;
  PCardinal(@Buf[56])^ := M.DataSize;
  PCardinal(@Buf[60])^ := M.BssSize;
  PWord(@Buf[64])^ := M.Attr;
  Buf[66] := M.Version[0];
  Buf[67] := M.Version[1];
  var N := RawByteString(M.Name);
  if N <> '' then
    Move(N[1], Buf[68], System.Math.Min(27, Length(N)));
  FMemory.WriteBytes(P, Buf, Size);
  FHLE.Result(0);
end;

procedure TPSPLoader.hGetModuleGPByAddress;
begin
  var M := ModuleOfAddress(FHLE.Arg(0));
  if M = nil then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_UNKNOWN_MODULE);
    Exit;
  end;
  if FHLE.Arg(1) <> 0 then
    FMemory.Write32(FHLE.Arg(1), M.GP);
  FHLE.Result(0);
end;

function TPSPLoader.Validate(const Data: TBytes; const Path: string; ArgumentSize: Cardinal): Cardinal;
begin
  // Parse, relocate and link against an isolated machine before loadexec can
  // discard the running program. This follows the real loader's checks.
  var Memory := TPSPMemory.Create;
  var CPU := TPSPCPU.Create(Memory);
  var Scheduler := TPSPScheduler.Create;
  var HLE := TPSPHLE.Create(CPU, Memory);
  var Kernel := TPSPKernel.Create(CPU, Memory, HLE, Scheduler);
  var Loader := TPSPLoader.Create(Kernel, nil);
  try
    var Module: TPSPModule;
    Result := Loader.Load(Data, Path, Module);
    if (Result = 0) and Module.Fake then
      Result := SCE_KERNEL_ERROR_UNSUPPORTED_PRX_TYPE;
    if Result = 0 then
    begin
      var Stack: Cardinal := $40000;
      if Module.StartStack >= $200 then
        Stack := Module.StartStack;
      if ArgumentSize > Stack - $140 then
        Result := SCE_KERNEL_ERROR_ILLEGAL_SIZE;
      if Result = 0 then
        try
          // Also reserve the main stack: malformed thread parameters or an
          // image leaving no room for it must fail before the live reset.
          Loader.StartMain(Module, Path, nil, True);
        except
          on EPSPError do
            Result := SCE_KERNEL_ERROR_NO_MEMORY;
        end;
    end;
  finally
    Loader.Free;
    Kernel.Free;
    HLE.Free;
    Scheduler.Free;
    CPU.Free;
    Memory.Free;
  end;
end;

procedure TPSPLoader.hLoadExec;
begin
  var Path := FMemory.ReadString(FHLE.Arg(0), 1024);
  var Param := FHLE.Arg(1);
  var ArgSize: Cardinal := 0;
  var ArgPtr: Cardinal := 0;
  if Param <> 0 then
  begin
    if not FMemory.Valid(Param, 12) then
    begin
      FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ADDR);
      Exit;
    end;
    ArgSize := FMemory.Read32(Param + 4);
    ArgPtr := FMemory.Read32(Param + 8);
  end;
  if (ArgSize > 0) and ((ArgPtr = 0) or not FMemory.Valid(ArgPtr, ArgSize)) then
  begin
    FHLE.Result(SCE_KERNEL_ERROR_ILLEGAL_ADDR);
    Exit;
  end;
  if Assigned(FOnLoadExec) then
    FHLE.Result(FOnLoadExec(Path, ArgSize, ArgPtr))
  else
    FHLE.Result(SCE_KERNEL_ERROR_NOTIMP);
end;

procedure TPSPLoader.hKprintf;
begin
  // The format is printed as is: the kernel's own printf is not emulated.
  FKernel.DebugWrite(FMemory.ReadAnsi(FHLE.Arg(0), 4096));
  FHLE.Result(0);
end;

procedure TPSPLoader.hIcacheClearAll;
begin
  FHLE.CPU.FlushDecoded;
  FHLE.Result(0);
end;

procedure TPSPLoader.Register;
const
  L = 'ModuleMgrForUser';
begin
  var H := FHLE;
  H.Register('KDebugForKernel', $84F370BC, 'Kprintf', hKprintf);
  H.Register('LoadCoreForKernel', $D8779AC6, 'sceKernelIcacheClearAll', hIcacheClearAll);
  H.Register(L, $977DE386, 'sceKernelLoadModule', hLoadModule);
  H.Register(L, $B7F46618, 'sceKernelLoadModuleByID', hLoadModuleByID);
  H.Register(L, $710F61B5, 'sceKernelLoadModuleMs', hLoadModule);
  H.Register(L, $F9275D98, 'sceKernelLoadModuleBufferUsbWlan', hLoadModuleBufferUsbWlan);
  H.Register(L, $50F0C1EC, 'sceKernelStartModule', hStartModule);
  H.Register(L, $D1FF982A, 'sceKernelStopModule', hStopModule);
  H.Register(L, $2E0911AA, 'sceKernelUnloadModule', hUnloadModule);
  H.Register(L, $CC1D3699, 'sceKernelStopUnloadSelfModule', hStopUnloadSelfModule);
  H.Register(L, $D675EBB8, 'sceKernelSelfStopUnloadModule', hSelfStopUnloadModule);
  H.Register(L, $D8B73127, 'sceKernelGetModuleIdByAddress', hGetModuleIdByAddress);
  H.Register(L, $F0A26395, 'sceKernelGetModuleId', hGetModuleId);
  H.Register(L, $644395E2, 'sceKernelGetModuleIdList', hGetModuleIdList);
  H.Register(L, $748CBED9, 'sceKernelQueryModuleInfo', hQueryModuleInfo);
  H.Register(L, $D2FBC957, 'sceKernelGetModuleGPByAddress', hGetModuleGPByAddress);
  H.Register('LoadExecForUser', $BD2F1094, 'sceKernelLoadExec', hLoadExec);
end;

function TPSPLoader.Describe: string;
begin
  Result := '';
  for var M in FModules do
    Result := Result + Format('%x %s base=%.8x size=%x entry=%.8x gp=%.8x fake=%s'#10,
      [M.UID, M.Name, M.Base, M.Size, M.Entry, M.GP, BoolToStr(M.Fake, True)]);
end;

end.

