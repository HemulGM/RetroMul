unit MSX.VDP;

interface

uses
  System.SysUtils, System.Classes, System.UITypes, System.Math, Core.Snapshots,
  SG1000.VDP, MSX.Machine;

type
  TMSXSpriteFetch = packed record
    Index, Y, X, Code, Attr, Left, Right: Byte;
  end;

  TMSXStatusTransition = packed record
    Clock: Int64;
    Before: array[0..1] of Byte;
  end;

  TMSXVideoRead = packed record
    RAS, CAS, Due: Int64;
    Address: Integer;
    Index: Word;
    Kind, Flags: Byte;
  end;

  TMSXLineTiming = packed record
    Start, Serial: Int64;
    Clocks: Word;
    Adjust: Byte;
  end;

  TMSXVideoAccessTrace = procedure(RAS, CAS, Data: Int64; Address, Kind, Index: Integer; Value: Byte);

  TMSXCPUAccessTrace = procedure(Time: Int64; Dummy, Write: Boolean; Address: Integer; Value: Byte);

  TMSXCommandAccessTrace = procedure(RAS, Data: Int64; Write, Enabled: Boolean; Address: Integer; Value: Byte);
  // Keep physical VRAM banks stable across mode switches. G6/G7 interleave
  // logical CPU, display and command addresses across the two 64 KiB banks.

  TMSXVDP = class(TSGVDP)
  private
    FModel: TMSXModel;
    FChip: TMSXVDPChip;
    FDefaultPAL: Boolean;
    FStatusReadUntil: Int64;
    FStatusSetClock: array[0..2] of Int64;
    FHorizontalSetClock: Int64;
    FStatusHistory: array[0..3] of TMSXStatusTransition;
    FStatusHistoryHead: Integer;
    FMSX1PAL: Boolean;
    FVideo: array[0..$1FFFF] of Byte;
    FR: array[0..63] of Byte;
    FS: array[0..9] of Byte;
    FPalette: array[0..15] of Word;
    FOutput: TArray<TAlphaColor>;
    FScanline: array[0..511] of TAlphaColor;
    FBlinkOn: Boolean;
    FBlinkFrames: Integer;
    FPointer: Integer;
    FBuffer, FFirstControl, FFirstPalette: Byte;
    FPending, FPalettePending: Boolean;
    FCommand, FCX, FCY, FSX, FSY, FDX, FDY, FNX, FNY, FTX, FTY: Integer;
    FHorizontalCycles, FLineError, FCommandPhase: Integer;
    FVideoClock, FCommandDue: Int64;
    FCommandDataDue, FCommandRAS, FCommandSerial, FCommandBusSerial: Int64;
    FCommandBusAddress, FCommandBusMode: Integer;
    FCommandBusKind, FCommandBusValue, FCommandBusShift, FCommandBusMask: Byte;
    FCommandBusR44, FCommandBusR45, FCommandBusR46: Byte;
    FCommandBusEnabled, FCommandCommitting: Boolean;
    FCommandTrace: TMSXCommandAccessTrace;
    FTransferPending, FCachedDestination: Boolean;
    FTransferValue, FSourceByte, FDestByte: Byte;
    FDestAddress: Integer;
    FBeamLine, FRasterX: Integer;
    FLineAdjust, FPreviousLineAdjust: Byte;
    FLineStartClock: Int64;
    FLineClocks: Integer;
    FLineTiming: array[0..7] of TMSXLineTiming;
    FLineTimingHead, FLineTimingCount: Integer;
    FCommandRequestTime: Int64;
    FCommandWork: Integer;
    FClocked, FCPUWrite, FCPUPending: Boolean;
    FCPUWaitLatch: Boolean;
    FCPUPhase, FCPUValue: Byte;
    FCPUAddress: Integer;
    FCPUAccessWrite: Boolean;
    FCPUAccessStart: Int64;
    FCPUAccessEnabled: Boolean;
    FCPUNextSlot, FCPUNextReady, FCPUGranted, FCPUDummy: Int64;
    FCPUNextWrite, FCPUGrantedLate: Boolean;
    FCPUNextValue: Byte;
    FVRAMTrace: TMSXCPUAccessTrace;
    FCPUDue, FNextFetch, FNextSpritePixel, FNextSpriteStatus, FCPUReady, FCommandReady: Int64;
    FSpriteStatusValue, FSpriteCounter: Byte;
    FFetchMode: Integer;
    FVideoReads: array[0..1] of TMSXVideoRead;
    FNextVideoData: Int64;
    FVideoTrace: TMSXVideoAccessTrace;
    FFetchEvents: array[0..1367] of Integer;
    FNames, FPatterns, FColors: array[0..79] of Byte;
    FDisplayKeys: array[0..1023] of Integer;
    FDisplayBytes: array[0..1023] of Byte;
    FBitmapBytes: array[0..263] of Byte;
    FSpriteCurrent, FSpriteNext: array[0..7] of TMSXSpriteFetch;
    FSpriteCount, FNextSpriteCount: Integer;
    FSpriteOverflow, FNextSpriteOverflow: Byte;
    FSpriteStop: Boolean;
    FSpriteCollision: array[0..7] of Cardinal;
    FSpriteCollisionDirty: Boolean;
    procedure QueueCPU(Write: Boolean; Value: Byte = 0);
    procedure CPUAccess;
    function CPUTimingKind(Time: Int64): Integer;
    function ConfiguredLineClocks: Integer;
    function ShortRAMTick(Tick, Kind: Integer): Integer;
    function SpriteReadPhase(Operation, Phase: Integer): Integer;
    procedure LocateLine(Time: Int64; out Base, Serial: Int64; out Clocks: Integer; out Adjust: Byte);
    function LineBaseAt(Time: Int64): Int64;
    function LineTickAt(Time: Int64): Integer;
    function LineClocksAt(Time: Int64): Integer;
    function LineSerialAt(Time: Int64): Int64;
    procedure LatchLineTiming;
    function VideoLineAt(Time: Int64): Integer;
    function RAMWindowEnd(Time: Int64): Integer;
    function RAMPostShift(Time: Int64): Integer;
    function RAMAdjustAt(Time: Int64): Integer;
    function CPUMemoryDistance(A, B: Int64): Int64;
    function CPULateSlot(Time: Int64): Boolean;
    function CPUTightSlot(Time: Int64): Boolean;
    procedure RescheduleCPU;
    function VideoByte(Address: Integer): Byte;
    function DisplayByte(Address: Integer): Byte;
    procedure BuildFetchEvents;
    procedure ScheduleFetch;
    procedure FetchAccess;
    procedure BeginVideoAccess(Kind, Index: Integer);
    procedure CompleteVideoAccess;
    procedure EvaluateSprite(Index, SY: Integer; M2: Boolean);
    procedure FetchCharacter(Cell, Stage: Integer);
    procedure FetchSprite(Entry, Field: Integer);
    procedure ScanSprite(Index: Integer);
    procedure SetSpriteStatus(Value: Byte);
    procedure SetHorizontalStatus(Value: Byte);
    procedure RecordStatusChange;
    function SampleStatus(Index: Integer; Time: Int64): Byte;
    function RaiseStatus(Flag: Byte): Boolean;
    function Status0: Byte;
    function TMSAddress(Address: Integer): Integer;
    function IsTI: Boolean;
    function IsToshiba: Boolean;
    procedure ScheduleSpritePixel;
    procedure SpritePixel;
    procedure BuildSpriteCollision;
    procedure ModeChanged(Previous: Integer);
    function TimedBitmapPixel(X: Integer): TAlphaColor;
    function DecodeYJK(Value, C0, C1, C2, C3: Byte): TAlphaColor;
    function HorizontalAdjust: Integer;
    function VerticalAdjust: Integer;
    procedure FlushRaster;
    procedure DrawRaster(Y, First, Last: Integer; SpriteStatus: Boolean);
    procedure ComposeLine(Y, First, Last: Integer; SpriteStatus: Boolean);
    function Mode: Integer;
    function DotWidth: Integer;
    function DisplayDotWidth: Integer;
    function BitsPerPixel: Integer;
    function VideoAddress(X, Y: Integer): Integer;
    function PhysicalAddress(Address: Integer): Integer;
    function Dot(X, Y: Integer): Byte;
    procedure PutDot(X, Y: Integer; Value, Logic: Byte);
    function CommandDot(X, Y: Integer): Byte;
    procedure CommandPutDot(X, Y: Integer; Value: Byte);
    procedure SetCommandY(Index, Value: Integer);
    function DirectColor(Value: Byte): TAlphaColor;
    function YJKColor(Address: Integer): TAlphaColor;
    function DisplayPixels: TArray<TAlphaColor>;
    function PaletteColor(Index: Integer): TAlphaColor;
    function SpriteColor(Index, Half: Integer): TAlphaColor;
    function PatternPixel(X, Y, DisplayMode: Integer): TAlphaColor;
    function BitmapPixel(X, Y, Page: Integer): TAlphaColor;
    procedure IncrementAddress;
    procedure SetRegister(Index, Value: Byte);
    procedure StartCommand(Value: Byte);
    procedure CommandUnit(Value: Byte = 0);
    procedure NextCommand;
    function NextAccessSlot(AfterTicks: Integer): Int64;
    function CommandReadyAt(Time: Int64; Delay: Integer; AfterAccess: Boolean = True): Int64;
    function CommandExtra(Time: Int64; AfterAccess: Boolean): Integer;
    function MemoryReadyAt(Time: Int64; Work: Integer): Int64;
    function FindCommandSlot(Time: Int64; Work: Integer; NotBefore: Int64 = -1): Int64;
    procedure RescheduleCommand;
    procedure ScheduleCommand(AfterTicks: Integer; AfterAccess: Boolean = True);
    procedure ScheduleCommandFrom(Time: Int64; AfterTicks: Integer; AfterAccess: Boolean = True);
    procedure CommandAccess;
    procedure CommandData;
    procedure CompleteCommandData;
    function CommandReadPixel: Byte;
    function CommandMode: Integer;
    function CommandVideoAddress(X, Y: Integer): Integer;
    function CommandWidth: Integer;
    function CommandPixelBits: Integer;
    function CommandArgument(Index: Integer): Byte;
    class function MergePixelByte(Previous, Value, Logic: Byte; Shift, BPP: Integer; out Data: Byte): Boolean; static;
    procedure RenderSprites(Y: Integer; Mode2: Boolean; UpdateStatus: Boolean);
  protected
    function Color(Index: Integer): TAlphaColor; override;
  public
    constructor Create(Model: TMSXModel; PAL: Boolean = False; Clocked: Boolean = False);
    procedure Reset; override;
    procedure ConfigureChip(Chip: TMSXVDPChip);
    function SpriteRow(Y, RawY, Index: Integer): Integer;
    function ReadData: Byte; override;
    function ReadStatus: Byte; override;
    function ReadStatusCPU: Byte;
    function VRAMAccessSlot(Time: Int64; AfterTicks: Integer): Int64;
    function CommandAccessSlot(Time: Int64; Delay: Integer): Int64;
    function CommandStepDelay(Command, Phase: Integer; NewLine: Boolean): Integer;
    function CommandStartDelay(Command: Integer): Integer;
    function CommandStartSlot(Time: Int64; Command: Integer): Int64;
    function VRAMDataDelay(Time: Int64): Integer;
    function CPUAccessSlot(Request: Int64; IncludeTight: Boolean = False; NotBefore: Int64 = -1): Int64;
    function CPURequestAllowed(Request: Int64): Boolean;
    function CPUWaitAsserted: Boolean;
    procedure WriteData(Value: Byte); override;
    procedure WriteControl(Value: Byte); override;
    procedure WritePalette(Value: Byte);
    procedure WriteIndirect(Value: Byte);
    function Interrupt: Boolean; override;
    procedure RenderLine(Y: Integer); override;
    procedure VBlank; override;
    procedure EndLine(Line, TotalLines: Integer); override;
    procedure Advance(Cycles: Integer);
    procedure AdvanceMasterClocks(Clocks: Int64);
    function ScreenHeight: Integer; override;
    function ScreenWidth: Integer;
    function TotalLines: Integer;
    function Interlaced: Boolean;
    function OutputHeight: Integer;
    procedure SerializeState(State: TStateArchive); override;
    property Output: TArray<TAlphaColor> read DisplayPixels;
    property MasterClock: Int64 read FVideoClock;
    property ScanlineClocks: Integer read FLineClocks;
    property ScanlineStart: Int64 read FLineStartClock;
    property Chip: TMSXVDPChip read FChip;
    property OnCPUAccessTrace: TMSXCPUAccessTrace read FVRAMTrace write FVRAMTrace;
    property OnVideoAccessTrace: TMSXVideoAccessTrace read FVideoTrace write FVideoTrace;
    property OnCommandAccessTrace: TMSXCommandAccessTrace read FCommandTrace write FCommandTrace;
  end;

implementation

uses
  MSX.VDP.Timing, MSX.VDP.AdjustTiming, MSX.VDP.SpriteTiming,
  MSX.VDP.ShortTiming;

{$REGION 'Scanline timing'}
// A line has its own clock origin. S1/S0 must not rephase the accumulated
// master clock or the CPU's half-T remainder when a 1365-clock line ends.
function TMSXVDP.ConfiguredLineClocks: Integer;
begin
  Result := 1368;
  if (FModel <> MSX1) and (FR[9] and $30 <> 0) then
    Result := 1365;
end;

procedure TMSXVDP.LocateLine(Time: Int64; out Base, Serial: Int64; out Clocks: Integer; out Adjust: Byte);

  function FloorDivide(A: Int64; B: Integer): Int64;
  begin
    Result := A div B;
    if (A < 0) and (A mod B <> 0) then
      Dec(Result);
  end;

begin
  var L := FLineTiming[FLineTimingHead];
  if Time >= L.Start + L.Clocks then
  begin
    Base := L.Start + L.Clocks;
    Clocks := ConfiguredLineClocks;
    var N := (Time - Base) div Clocks;
    Inc(Base, N * Clocks);
    Serial := L.Serial + 1 + N;
    Adjust := (FR[18] and 15) or ((FR[25] and 8) shl 1);
    Exit;
  end;
  for var I := 0 to FLineTimingCount - 1 do
  begin
    L := FLineTiming[(FLineTimingHead - I + Length(FLineTiming)) mod Length(FLineTiming)];
    if (Time >= L.Start) or (I = FLineTimingCount - 1) then
    begin
      var N := FloorDivide(Time - L.Start, L.Clocks);
      Base := L.Start + N * L.Clocks;
      Clocks := L.Clocks;
      Serial := L.Serial + N;
      Adjust := L.Adjust;
      Exit;
    end;
  end;
  raise EInvalidOpException.Create('VDP line history is empty');
end;

function TMSXVDP.LineBaseAt(Time: Int64): Int64;
begin
  var Serial: Int64;
  var Clocks: Integer;
  var Adjust: Byte;
  LocateLine(Time, Result, Serial, Clocks, Adjust);
end;

function TMSXVDP.LineTickAt(Time: Int64): Integer;
begin
  Result := Integer(Time - LineBaseAt(Time));
end;

function TMSXVDP.LineClocksAt(Time: Int64): Integer;
begin
  var Base, Serial: Int64;
  var Adjust: Byte;
  LocateLine(Time, Base, Serial, Result, Adjust);
end;

function TMSXVDP.LineSerialAt(Time: Int64): Int64;
begin
  var Base: Int64;
  var Clocks: Integer;
  var Adjust: Byte;
  LocateLine(Time, Base, Result, Clocks, Adjust);
end;

procedure TMSXVDP.LatchLineTiming;
begin
  var Base, Serial: Int64;
  var Clocks: Integer;
  var Adjust: Byte;
  LocateLine(FVideoClock, Base, Serial, Clocks, Adjust);
  if Base <> FLineStartClock then
  begin
    FLineTimingHead := (FLineTimingHead + 1) mod Length(FLineTiming);
    FLineTimingCount := Min(FLineTimingCount + 1, Length(FLineTiming));
  end;
  FLineStartClock := Base;
  FLineClocks := ConfiguredLineClocks;
  var P: ^TMSXLineTiming;
  P := @FLineTiming[FLineTimingHead];
  P.Start := Base;
  P.Serial := Serial;
  P.Clocks := FLineClocks;
  P.Adjust := (FR[18] and 15) or ((FR[25] and 8) shl 1);
end;

// Measured S1/S0 tail changes at R18=0. Combined R18/S-bit captures are
// unavailable; other adjust values share these gates pending calibration.
function TMSXVDP.ShortRAMTick(Tick, Kind: Integer): Integer;
begin
  Result := Tick;
  case Kind of
    0:
      begin
        if Tick >= 1334 then
          Dec(Result);
        if Tick >= 1344 then
          Dec(Result, 2);
      end;
    1:
      begin
        if Tick >= 1332 then
          Dec(Result);
        if Tick >= 1342 then
          Dec(Result, 2);
      end;
    2:
      begin
        if Tick >= 1330 then
          Dec(Result);
        if Tick >= 1337 then
          Dec(Result);
        if Tick >= 1348 then
          Dec(Result);
      end;
    3:
      begin
        if Tick >= 1334 then
          Dec(Result);
        if Tick >= 1341 then
          Dec(Result);
        if Tick >= 1352 then
          Dec(Result);
      end;
    4:
      begin
        if Tick >= 1336 then
          Dec(Result);
        if Tick >= 1346 then
          Dec(Result, 2);
      end;
  end;
end;

function TMSXVDP.SpriteReadPhase(Operation, Phase: Integer): Integer;
begin
  var T := MSXSpriteReadR18[FLineAdjust and 15, Operation];
  if FLineClocks = 1365 then
  begin
    if FLineAdjust and 15 = 0 then
      T := MSXSpriteReadShort[Operation]
    else
    begin
      T.RAS := ShortRAMTick(T.RAS, 2);
      T.CAS := ShortRAMTick(T.CAS, 2);
      T.Data := ShortRAMTick(T.Data, 2);
    end;
  end;
  case Phase of
    0:
      Result := T.RAS;
    1:
      Result := T.CAS;
  else
    Result := T.Data;
  end;
end;
{$ENDREGION}

{$REGION 'Command timing'}
// Command delay counters run in the memory sequencer's clock. R18 can
// move RAS slots; the apparent global 2026 slot shift was RAS/CAS numbering.
// Primary captures: m9710797/vdp-timing-measurements, part2.

function TMSXVDP.CommandStepDelay(Command, Phase: Integer; NewLine: Boolean): Integer;
begin
  Result := 88;
  if Phase <> 0 then
    Result := 24;
  case Command of
    7:
      if Phase <> 0 then
        Result := 24
      else
      begin
        Result := 84;
        if NewLine then
          Inc(Result, 36);
      end;
    8:
      if Phase <> 0 then
        Result := 24
      else
      begin
        Result := 72;
        if NewLine then
          Inc(Result, 58);
      end;
    9:
      case Phase of
        1:
          Result := 32;
        2:
          Result := 24;
      else
        begin
          Result := 60;
          if NewLine then
            Inc(Result, 68);
        end;
      end;
    $C:
      begin
        Result := 46;
        if NewLine then
          Inc(Result, 58);
      end;
    $D:
      if Phase <> 0 then
        Result := 24
      else
      begin
        Result := 60;
        if NewLine then
          Inc(Result, 68);
      end;
    $E:
      if Phase <> 0 then
        Result := 24
      else
      begin
        Result := 36;
        if NewLine then
          Inc(Result, 68);
      end;
  end;
end;

function TMSXVDP.CommandStartDelay(Command: Integer): Integer;
const
  Delay: array[4..15] of Byte = (45, 70, 70, 94, 70, 46, 58, 70, 94, 82, 82, 94);
begin
  // /CSW-to-first-request delays measured in the h/i captures. MD.Z80 calls
  // the port at I/O completion: do not add openMSX's 18-clock T2-to-/CSW term.
  Result := 0;
  if Command in [4..15] then
    Result := Delay[Command];
end;

function TMSXVDP.CommandExtra(Time: Int64; AfterAccess: Boolean): Integer;
begin
  Result := 0;
  if (FModel = MSX1) or (Mode < 12) then
    Exit;
  case CPUTimingKind(Time) of
    1:
      if AfterAccess and CPUTightSlot(Time) then
        Result := 1;
    2:
      Result := 1; // captures allow +1 or +2; +1 is the retained fit
  end;
end;

function TMSXVDP.MemoryReadyAt(Time: Int64; Work: Integer): Int64;

  procedure Pad(At, Count: Integer; Base: Int64);
  begin
    var Edge := Base + At;
    if (Time < Edge) and (Edge <= Result) then
      Inc(Result, Count);
  end;

begin
  Result := Time + Work;
  if (FModel = MSX1) or (Mode < 12) then
    Exit;
  var Base := LineBaseAt(Time);
  while Base <= Result do
  begin
    var Kind := CPUTimingKind(Base);
    if Kind in [0..2] then
    begin
      for var K := 0 to 2 do
      begin
        var P := MSXRAMPadR18[K, RAMAdjustAt(Base)];
        if LineClocksAt(Base) = 1365 then
        begin
          P.Count := 1;
          P.Amount[0] := 1;
          case K of
            0:
              P.Tick[0] := 1333;
            1:
              P.Tick[0] := 1331;
            2:
              P.Tick[0] := 1329;
          end;
        end;
        for var I := 0 to P.Count - 1 do
        begin
          var At := Integer(P.Tick[I]);
          if K = 2 then
            Inc(At, RAMPostShift(Base + At));
          if CPUTimingKind(Base + At) = K then
            Pad(At, P.Amount[I], Base);
        end;
      end;
    end;
    Inc(Base, LineClocksAt(Base));
  end;
end;

function TMSXVDP.CommandReadyAt(Time: Int64; Delay: Integer; AfterAccess: Boolean): Int64;
begin
  Result := MemoryReadyAt(Time, Delay + CommandExtra(Time, AfterAccess));
end;

function TMSXVDP.FindCommandSlot(Time: Int64; Work: Integer; NotBefore: Int64): Int64;
begin
  Result := VRAMAccessSlot(Max(Time + Work, NotBefore), 0);
  if (FModel = MSX1) or (Mode < 12) then
    Exit;
 // A lower-bound deadline can sit just before a stretched cycle completes.
 // Test the memory distance to the actual candidate RAS as well; otherwise
 // a request one clock too early incorrectly receives that same slot.
  while CPUMemoryDistance(Time, Result) < Work do
    Result := VRAMAccessSlot(Result, 1);
end;

procedure TMSXVDP.RescheduleCommand;
begin
  if FCommandDue = High(Int64) then
    Exit;
  FCommandReady := MemoryReadyAt(FCommandRequestTime, FCommandWork);
  FCommandDue := FindCommandSlot(FCommandRequestTime, FCommandWork, Max(FVideoClock + 1, FCommandReady));
end;

function TMSXVDP.CommandAccessSlot(Time: Int64; Delay: Integer): Int64;
begin
  Result := FindCommandSlot(Time, Delay + CommandExtra(Time, True));
end;

function TMSXVDP.CommandStartSlot(Time: Int64; Command: Integer): Int64;
begin
  Result := FindCommandSlot(Time, CommandStartDelay(Command) + CommandExtra(Time, False));
end;
{$ENDREGION}

{$REGION 'CPU arbitration'}
// Native CPU request arbitration. Measurements distinguish RAM slots from
// the single request register, and ordinary slots from the late grant phase.

function TMSXVDP.CPUTimingKind(Time: Int64): Integer;
begin
  if Mode in [1, 9] then
    Exit(4);
  if Mode < 12 then
    Exit(3);
  if not FClocked then
  begin
    if (FR[1] and $40 = 0) or (FS[2] and $40 <> 0) then
      Exit(0);
    if FR[8] and 2 <> 0 then
      Exit(1);
    Exit(2);
  end;
  if FR[1] and $40 = 0 then
    Exit(0);
  var Line := VideoLineAt(Time);
  var Tick := LineTickAt(Time);
  if FR[8] and 2 <> 0 then
  begin
    if Line < ScreenHeight then
      Exit(1);
    Exit(0);
  end;
  // The left sprite fetches belong to the previous display-fetch region.
  if Line = TotalLines - 1 then
  begin
    if Tick < 162 then
      Exit(1);
    Exit(2);
  end;
  if Line = ScreenHeight then
  begin
    if Tick < 162 then
      Exit(2);
    Exit(0);
  end;
  if Line < ScreenHeight then
    Exit(2);
  Result := 0;
end;

function TMSXVDP.VideoLineAt(Time: Int64): Integer;
begin
  Result := (FBeamLine + Integer(LineSerialAt(Time) - FLineTiming[FLineTimingHead].Serial) + VerticalAdjust + TotalLines) mod TotalLines;
end;

function TMSXVDP.RAMWindowEnd(Time: Int64): Integer;
begin
  Result := LineClocksAt(Time);
  if FClocked and (FR[1] and $40 <> 0) and (FR[8] and 2 = 0) and (LineTickAt(Time) < 162) then
  begin
    var Line := VideoLineAt(Time);
    if (Line = TotalLines - 1) or (Line = ScreenHeight) then
      Result := 162;
  end;
end;

function TMSXVDP.RAMPostShift(Time: Int64): Integer;
begin
  Result := 0;
  if FClocked and (FR[1] and $40 <> 0) and (FR[8] and 2 = 0) and
    (LineTickAt(Time) < 162) and (VideoLineAt(Time) = ScreenHeight) then
    Result := 2;
end;

function TMSXVDP.RAMAdjustAt(Time: Int64): Integer;
begin
  Result := FR[18] and 15;
  if not FClocked then
    Exit;
  var Base, Serial: Int64;
  var Clocks: Integer;
  var Adjust: Byte;
  LocateLine(Time, Base, Serial, Clocks, Adjust);
  Result := Adjust and 15;
end;

function TMSXVDP.CPUMemoryDistance(A, B: Int64): Int64;

  procedure Pad(At, Count: Integer; Base: Int64);
  begin
    if (A < Base + At) and (Base + At <= B) then
      Dec(Result, Count);
  end;

begin
  if A > B then
    Exit(-CPUMemoryDistance(B, A));
  Result := B - A;
  var Base := LineBaseAt(A);
  while Base <= B do
  begin
    var Kind := CPUTimingKind(Base);
    if Kind in [0..2] then
    begin
      for var K := 0 to 2 do
      begin
        var P := MSXRAMPadR18[K, RAMAdjustAt(Base)];
        if LineClocksAt(Base) = 1365 then
        begin
          P.Count := 1;
          P.Amount[0] := 1;
          case K of
            0:
              P.Tick[0] := 1333;
            1:
              P.Tick[0] := 1331;
            2:
              P.Tick[0] := 1329;
          end;
        end;
        for var I := 0 to P.Count - 1 do
        begin
          var At := Integer(P.Tick[I]);
          if K = 2 then
            Inc(At, RAMPostShift(Base + At));
          if CPUTimingKind(Base + At) = K then
            Pad(At, P.Amount[I], Base);
        end;
      end;
    end
    // Only three character-mode clocks have been located; R18 variants
    // of the character/text sequencer remain unmeasured.
    else if Kind = 3 then
    begin
      if LineClocksAt(Base) = 1365 then
        Pad(1333, 1, Base)
      else
      begin
        Pad(1341, 2, Base);
        Pad(1352, 1, Base);
      end;
    end
    else if Kind = 4 then
    begin
      if LineClocksAt(Base) = 1365 then
        Pad(1335, 1, Base)
      else
      begin
        Pad(1336, 2, Base);
        Pad(1346, 2, Base);
      end;
    end;
    Inc(Base, LineClocksAt(Base));
  end;
end;

function TMSXVDP.CPULateSlot(Time: Int64): Boolean;
begin
  var Tick := LineTickAt(Time);
  case CPUTimingKind(Time) of
    2:
      Result := (Tick <> 162) and (Tick <> 170);
    3:
      Result := (Tick <> 166) and (Tick <> 174);
  else
    Result := False;
  end;
end;

function TMSXVDP.CPUTightSlot(Time: Int64): Boolean;
begin
  Result := False;
  if CPUTimingKind(Time) <> 1 then
    Exit;
  var Tick := LineTickAt(Time);
  for var I := 1 to High(MSXSlotsNoSprites) do
    if (MSXSlotsNoSprites[I] = Tick) and (MSXSlotsNoSprites[I - 1] + 6 = Tick) then
      Exit(True);
end;

function TMSXVDP.CPUAccessSlot(Request: Int64; IncludeTight: Boolean; NotBefore: Int64): Int64;
begin
  Result := VRAMAccessSlot(Max(Request + 16, NotBefore), 0);
  while True do
  begin
    var Lead := 16;
    if CPULateSlot(Result) then
      Inc(Lead, 2);
    if (IncludeTight or not CPUTightSlot(Result)) and (CPUMemoryDistance(Request, Result) >= Lead) then
      Exit;
    Result := VRAMAccessSlot(Result, 1);
  end;
end;

function TMSXVDP.CPURequestAllowed(Request: Int64): Boolean;
begin
  if FCPUGranted < 0 then
    Exit(True);
  if Request >= FCPUGranted + 5 then
    Exit(True);
  if Request < FCPUGranted - 5 then
    Exit(False);
  var Threshold := 1;
  if FCPUGrantedLate then
    Threshold := -1;
  Result := CPUMemoryDistance(FCPUGranted, Request) >= Threshold;
end;

procedure TMSXVDP.RescheduleCPU;

  procedure ScheduleDummy(Ready, Slot, Minimum: Int64);
  begin
    var Dummy := CPUAccessSlot(Ready, True, Minimum);
    if (Dummy <> Slot) and (Dummy - Ready >= 18) and (Dummy - Ready < 22) then
      FCPUDummy := Min(FCPUDummy, Dummy);
  end;

begin
  if FModel = MSX1 then
  begin
    if FCPUPending and (FCPUPhase = 0) then
      FCPUDue := NextAccessSlot(Max(1, Integer(FCPUReady - FVideoClock)));
    Exit;
  end;
  if FCPUPending and (FCPUPhase = 0) then
    FCPUDue := CPUAccessSlot(FCPUReady, False, FVideoClock + 1);
  var NextMinimum := FVideoClock + 1;
  if FCPUNextSlot <> High(Int64) then
  begin
    var FirstRAS := FCPUDue;
    if FCPUPhase <> 0 then
      FirstRAS := FCPUAccessStart;
    NextMinimum := Max(NextMinimum, FirstRAS + 8);
    FCPUNextSlot := CPUAccessSlot(FCPUNextReady, False, NextMinimum);
  end;
  if FCPUPending then
  begin
    if FCPUNextSlot <> High(Int64) then
    begin
      FCPUGranted := FCPUNextSlot;
      FCPUGrantedLate := CPULateSlot(FCPUGranted);
    end
    else if FCPUPhase = 0 then
    begin
      FCPUGranted := FCPUDue;
      FCPUGrantedLate := CPULateSlot(FCPUGranted);
    end;
  end;
  FCPUDummy := High(Int64);
  if FCPUPending and (FCPUPhase = 0) then
    ScheduleDummy(FCPUReady, FCPUDue, FVideoClock + 1);
  if FCPUNextSlot <> High(Int64) then
    ScheduleDummy(FCPUNextReady, FCPUNextSlot, NextMinimum);
end;
{$ENDREGION}

{$REGION 'Command bus'}
// A RAM slot begins at /RAS; single-byte data is available at /CAS release.
// Integer functional phases follow the measured V9938 bus (ordinary +3,
// the two stretched-cycle slots +4). They are not analogue propagation times.

function TMSXVDP.VRAMDataDelay(Time: Int64): Integer;
begin
  Result := 3;
  if LineClocksAt(Time) = 1365 then
    Exit;
  var Tick := LineTickAt(Time);
  var Kind := CPUTimingKind(Time);
  if not (Kind in [0, 1]) then
    Exit;
  var Adjust := RAMAdjustAt(Time);
  if (Tick = MSXLateDataR18[Kind, Adjust, 0]) or (Tick = MSXLateDataR18[Kind, Adjust, 1]) then
    Result := 4;
end;

class function TMSXVDP.MergePixelByte(Previous, Value, Logic: Byte; Shift, BPP: Integer; out Data: Byte): Boolean;
begin
  Result := False;
  Data := Previous;
  var Mask := (1 shl BPP) - 1;
  Value := Value and Mask;
  if (Logic and 8 <> 0) and (Value = 0) then
    Exit;
  var Old := (Previous shr Shift) and Mask;
  case Logic and 7 of
    0:
      ;
    1:
      Value := Value and Old;
    2:
      Value := Value or Old;
    3:
      Value := Value xor Old;
    4:
      Value := Value xor Mask;
  else
    Exit;
  end;
  Data := (Previous and ($FF xor (Mask shl Shift))) or (Integer(Value) shl Shift);
  Result := True;
end;

function TMSXVDP.CommandMode: Integer;
begin
  Result := Mode;
 // V9958 technical data book 5.1.3: CMD expands non-bitmap commands
 // using G7 x/y coordinates and pixel organization, independently of scanout.
  if (Result < 12) and (FChip = VDPV9958) and (FR[25] and $40 <> 0) then
    Result := 28;
end;

function TMSXVDP.CommandPixelBits: Integer;
begin
  var M := CommandMode;
  if FCommandCommitting then
    M := FCommandBusMode;
  Result := 4;
  if M = 16 then
    Result := 2;
  if M = 28 then
    Result := 8;
end;

function TMSXVDP.CommandWidth: Integer;
begin
  var M := CommandMode;
  if FCommandCommitting then
    M := FCommandBusMode;
  Result := 256;
  if M in [16, 20] then
    Result := 512;
end;

function TMSXVDP.CommandVideoAddress(X, Y: Integer): Integer;
begin
  var M := CommandMode;
  var Width := CommandWidth;
  var BPP := CommandPixelBits;
  Result := ((Y and 1023) * (Width * BPP div 8) + (X and (Width - 1)) * BPP div 8) and $1FFFF;
  if M in [20, 28] then
    Result := (Result shr 1) or ((Result and 1) shl 16);
end;

function TMSXVDP.CommandArgument(Index: Integer): Byte;
begin
  Result := FR[Index];
  if not FCommandCommitting then
    Exit;
  case Index of
    44:
      Result := FCommandBusR44;
    45:
      Result := FCommandBusR45;
    46:
      Result := FCommandBusR46;
  end;
end;

function TMSXVDP.CommandReadPixel: Byte;
begin
  if not FCommandBusEnabled then
    Exit($FF);
  Result := (FCommandBusValue shr FCommandBusShift) and FCommandBusMask;
end;

procedure TMSXVDP.ScheduleCommandFrom(Time: Int64; AfterTicks: Integer; AfterAccess: Boolean);
begin
  FCommandRequestTime := Time;
  FCommandWork := AfterTicks + CommandExtra(Time, AfterAccess);
  FCommandReady := CommandReadyAt(Time, AfterTicks, AfterAccess);
  FCommandDue := FindCommandSlot(Time, FCommandWork, FCommandReady);
end;

procedure TMSXVDP.CommandAccess;
begin
  FCommandDue := High(Int64);
  if (FCommand in [$B, $F]) and not FTransferPending then
  begin
    FS[2] := FS[2] or $80;
    Exit;
  end;
  FCommandRAS := FVideoClock;
  FCommandBusSerial := FCommandSerial;
  FCommandBusMode := CommandMode;
  FCommandBusR44 := FR[44];
  FCommandBusR45 := FR[45];
  FCommandBusR46 := FR[46];
  FCommandBusKind := 4;
  FCommandBusEnabled := False;
  FCommandBusValue := 0;
  FCommandBusAddress := 0;
  var X := FDX + FCX * FTX;
  var Y := FDY + FCY * FTY;
  if (FCommand = 7) and (FR[45] and 1 <> 0) then
  begin
    X := FDX + FCY * FTX;
    Y := FDY + FCX * FTY;
  end;
  var BPP := CommandPixelBits;
  FCommandBusMask := (1 shl BPP) - 1;
  FCommandBusShift := 0;
  if (FCommand in [4, 6, $A]) or ((FCommand = 9) and (FCommandPhase = 0)) then
  begin
    var SX := FSX + FCX * FTX;
    var SY := FSY + FCY * FTY;
    FCommandBusKind := 0;
    FCommandBusAddress := CommandVideoAddress(SX, SY);
    FCommandBusShift := (8 div BPP - 1 - (SX and (8 div BPP - 1))) * BPP;
    FCommandBusEnabled := FR[45] and $10 = 0;
  end
  else if (FCommand in [$D, $E]) and (FCommandPhase = 0) then
  begin
    var SX := FSX + FCX * FTX;
    if FCommand = $E then
      SX := X;
    FCommandBusKind := 1;
    FCommandBusAddress := CommandVideoAddress(SX, FSY + FCY * FTY);
    FCommandBusEnabled := FR[45] and $10 = 0;
    if FCommand = $E then
      FCommandBusEnabled := FR[45] and $20 = 0;
  end
  else if ((FCommand in [5, 7, 8, $B]) and (FCommandPhase = 0)) or ((FCommand = 9) and (FCommandPhase = 1)) then
  begin
    FCommandBusKind := 2;
    FCommandBusAddress := CommandVideoAddress(X, Y);
    FCommandBusEnabled := FR[45] and $20 = 0;
  end
  else if FCommand in [5, 7, 8, 9, $B, $C, $D, $E, $F] then
  begin
    FCommandBusKind := 3;
    FCommandBusAddress := CommandVideoAddress(X, Y);
    FCommandBusEnabled := FR[45] and $20 = 0;
    var Value := FR[44];
    if FCommand in [9, $D, $E] then
      Value := FSourceByte;
    if FCommand in [$B, $F] then
      Value := FTransferValue;
    if FCommand < $C then
    begin
      var Previous := FVideo[FCommandBusAddress];
      if FCachedDestination and (FDestAddress = FCommandBusAddress) then
        Previous := FDestByte;
      FCommandBusShift := (8 div BPP - 1 - (X and (8 div BPP - 1))) * BPP;
      var Enabled := MergePixelByte(Previous, Value, FR[46], FCommandBusShift, BPP, FCommandBusValue);
      FCommandBusEnabled := FCommandBusEnabled and Enabled;
    end
    else
      FCommandBusValue := Value;
  end;
  FCommandDataDue := FVideoClock + VRAMDataDelay(FVideoClock);
end;

procedure TMSXVDP.CommandData;
begin
  FCommandDataDue := High(Int64);
  if FCommandBusKind < 3 then
    if FCommandBusEnabled then
      FCommandBusValue := FVideo[FCommandBusAddress]
    else
      FCommandBusValue := $FF;
  if (FCommandBusKind = 3) and FCommandBusEnabled then
  begin
    FlushRaster;
    FVideo[FCommandBusAddress] := FCommandBusValue;
    if FCommandBusAddress < $4000 then
      FVRAM[FCommandBusAddress] := FCommandBusValue;
  end;
 // A newer R46 may abort the command, but an issued RAM transaction retains
 // its pins. Do not let the old result advance the newly started command.
  if FCommandBusSerial = FCommandSerial then
  begin
    FCommandCommitting := True;
    try
      CompleteCommandData;
    finally
      FCommandCommitting := False;
    end;
  end;
  if Assigned(FCommandTrace) then
    FCommandTrace(FCommandRAS, FVideoClock, FCommandBusKind = 3,
      FCommandBusEnabled, FCommandBusAddress, FCommandBusValue);
end;

procedure TMSXVDP.CompleteCommandData;
begin
  if FCommand = $A then
  begin
    FS[7] := CommandReadPixel;
    FR[44] := FS[7];
    FS[2] := FS[2] or $80;
    FCommandDue := High(Int64);
    Exit;
  end;
  if (FCommand in [$B, $F]) and not FTransferPending then
  begin
    FS[2] := FS[2] or $80;
    FCommandDue := High(Int64);
    Exit;
  end;
  // Logical writes read the packed destination byte before their write slot.
  // Copies have a separate source read, preserving CPU/VDP interleaving.
  if (FCommand in [9, $D, $E]) and (FCommandPhase = 0) then
  begin
    if FCommand = 9 then
      FSourceByte := CommandReadPixel
    else
      FSourceByte := FCommandBusValue;
    FCommandPhase := 1;
    ScheduleCommandFrom(FCommandRAS, CommandStepDelay(FCommand, 1, False));
    Exit;
  end;
  if ((FCommand in [5, 7, 8, $B]) and (FCommandPhase = 0)) or
    ((FCommand = 9) and (FCommandPhase = 1)) then
  begin
    FDestAddress := FCommandBusAddress;
    FDestByte := FCommandBusValue;
    FCachedDestination := True;
    Inc(FCommandPhase);
    ScheduleCommandFrom(FCommandRAS, CommandStepDelay(FCommand, FCommandPhase, False));
    Exit;
  end;
  var PreviousCommand := FCommand;
  var PreviousY := FCY;
  CommandUnit(FTransferValue);
  FCommandPhase := 0;
  FCachedDestination := False;
  if PreviousCommand in [$B, $F] then
  begin
    FTransferPending := False;
    FS[2] := FS[2] or $80;
    FCommandDue := High(Int64);
    Exit;
  end;
  if FCommand = 0 then
  begin
    FCommandDue := High(Int64);
    Exit;
  end;
  ScheduleCommandFrom(FCommandRAS, CommandStepDelay(FCommand, 0, FCY <> PreviousY));
end;
{$ENDREGION}

{$REGION 'Silicon profiles and status'}

function TMSXVDP.IsTI: Boolean;
begin
  Result := FChip in [VDPTMS9918A, VDPTMS9929A, VDPTMS9118, VDPTMS9129];
end;

function TMSXVDP.IsToshiba: Boolean;
begin
  Result := FChip in [VDPT7937A, VDPT6950];
end;

procedure TMSXVDP.ConfigureChip(Chip: TMSXVDPChip);
begin
  if Chip = VDPAuto then
    case FModel of
      MSX1:
        if FDefaultPAL then
          Chip := VDPTMS9929A
        else
          Chip := VDPTMS9918A;
      MSX2:
        Chip := VDPV9938C;
      MSX2Plus:
        Chip := VDPV9958;
    end;
  if Chip = FChip then
    Exit;
  if (FVideoClock <> 0) or FCPUPending or (FCommand <> 0) then
    raise EInvalidOpException.Create('Changing the MSX VDP revision requires reopening the machine');
  if ((FModel = MSX1) and not (Chip in [VDPTMS9918A..VDPT6950])) or
    ((FModel = MSX2) and not (Chip in [VDPV9938A..VDPV9958])) or
    ((FModel = MSX2Plus) and (Chip <> VDPV9958)) then
    raise EArgumentException.Create('VDP revision does not match the MSX generation');
  FChip := Chip;
  if FChip <> VDPV9958 then
  begin
    FR[25] := 0;
    FR[26] := 0;
    FR[27] := 0;
  end;
  // The BIOS generation and the fitted VDP are independent on upgraded MSX2.
  // Identity is fixed by the silicon before power-on bus activity.
  FS[1] := FS[1] and $C1;
  if FChip = VDPV9958 then
    FS[1] := FS[1] or 4;
  for var I := 0 to High(FStatusHistory) do
    FStatusHistory[I].Before[1] := (FStatusHistory[I].Before[1] and $C1) or (FS[1] and $3E);
  if FModel = MSX1 then
    FMSX1PAL := Chip in [VDPTMS9929A, VDPTMS9129, VDPT6950];
end;

function TMSXVDP.TMSAddress(Address: Integer): Integer;
begin
  Result := Address and $3FFF;
  // TI99xx connected to 16K DRAM while the 4K address multiplexer is selected.
  // Keep physical RAM stable. TI91xx removed this multiplexer; Toshiba differs.
  if FClocked and (FChip in [VDPTMS9918A, VDPTMS9929A]) and (FR[1] and $80 = 0) then
    Result := (Result and $203F) or ((Result shl 1) and $1F80) or ((Result shr 6) and $40);
end;

function TMSXVDP.SpriteRow(Y, RawY, Index: Integer): Integer;
begin
  var Line := (Y + Integer(FR[23]) - 1) and 255;
  Result := (Line - RawY) and 255;
  if not IsTI or (Index < 8) or (FR[0] and 2 = 0) or (FR[4] and 3 = 3) then
    Exit;
  // Empirical TI NMOS address-mux outcomes, measured exhaustively by hap.
  // https://github.com/openMSX/openMSX/issues/593#issuecomment-242970572
  var Alternate := Result;
  if Line >= 192 then
  begin
    var Bits := ((not Integer(FR[4])) and 3) shl 6;
    var Mask := 255;
    if (FR[3] and $40 = 0) and (Bits and $80 <> 0) then
    begin
      Mask := 127;
      Bits := Bits and 127;
    end;
    Result := ((Line and Mask) - (RawY or Bits)) and 255;
    Alternate := Result;
  end
  else if (Line >= 128) and (FR[4] and 2 = 0) then
  begin
    Result := (Line - (RawY xor $80)) and 255;
    Alternate := (Line - ((RawY xor $80) or ((Integer(FR[3]) shl 1) and $80))) and 255;
  end
  else if (Line >= 64) and (Line < 128) and (FR[4] and 1 = 0) then
  begin
    Result := ((Line and 63) - RawY) and 255;
    Alternate := (Line - (RawY or (((not Integer(FR[3])) shl 1) and $40))) and 255;
  end;
  var Size := 8;
  if FR[1] and 2 <> 0 then
    Size := 16;
  if FR[1] and 1 <> 0 then
    Size := Size * 2;
  if Result >= Size then
    Result := Alternate;
end;

function TMSXVDP.RaiseStatus(Flag: Byte): Boolean;
begin
  Result := False;
  if FClocked and (Flag = $80) and (FVideoClock <= FStatusReadUntil) then
    Exit;
  var Index := 0;
  if Flag = $20 then
    Index := 1
  else if Flag = $40 then
    Index := 2;
  if FS[0] and Flag = 0 then
    FStatusSetClock[Index] := FVideoClock;
  SetSpriteStatus(FS[0] or Flag);
  Result := True;
end;

function TMSXVDP.Status0: Byte;
begin
  Result := FS[0];
  // Clear dominates a simultaneous C/5S set. Existing latched flags survive
  // sampling, then acknowledge normally. Do not introduce random misses.
  if (FStatusSetClock[1] = FVideoClock) then
    Result := Result and $DF;
  if (FStatusSetClock[2] = FVideoClock) then
    Result := (Result and $A0) or FSpriteCounter;
  if IsTI then
  begin
    // Measured NMOS recovery: a read in the three VDP clocks preceding F can
    // suppress that frame's flag/IRQ. The last clock can return F while still
    // suppressing the IRQ. One TI VDP clock is four master clocks.
    var Line := (FBeamLine + VerticalAdjust + TotalLines) mod TotalLines;
    var Lines := (ScreenHeight - Line + TotalLines) mod TotalLines;
    var Delta := Int64(Lines) * 1368 - (FVideoClock mod 1368);
    if Delta <= 0 then
      Inc(Delta, Int64(TotalLines) * 1368);
    if Delta < 4 then
      Result := Result or $80;
    FStatusReadUntil := FVideoClock + 12;
  end
  else
    FStatusReadUntil := FVideoClock;
  SetSpriteStatus(FSpriteCounter);
  ScheduleSpritePixel;
end;

procedure TMSXVDP.RecordStatusChange;
begin
  if not FClocked then
    Exit;
  // Several events can change both registers at one master tick. Keep the
  // value before the first change, not a partly updated intermediate value.
  if FStatusHistory[FStatusHistoryHead].Clock = FVideoClock then
    Exit;
  FStatusHistoryHead := (FStatusHistoryHead + 1) and 3;
  FStatusHistory[FStatusHistoryHead].Clock := FVideoClock;
  FStatusHistory[FStatusHistoryHead].Before[0] := FS[0];
  FStatusHistory[FStatusHistoryHead].Before[1] := FS[1];
end;

procedure TMSXVDP.SetHorizontalStatus(Value: Byte);
begin
  if Value <> FS[1] then
    RecordStatusChange;
  FS[1] := Value;
end;

function TMSXVDP.SampleStatus(Index: Integer; Time: Int64): Byte;
begin
  Result := FS[Index];
  for var I := 0 to High(FStatusHistory) do
  begin
    var P := (FStatusHistoryHead - I + Length(FStatusHistory)) and 3;
    if FStatusHistory[P].Clock <= Time then
      Break;
    Result := FStatusHistory[P].Before[Index];
  end;
end;

function TMSXVDP.CPUWaitAsserted: Boolean;
begin
  // Yamaha V9958 section 5.1.2. Decap investigation: the busy latch masks
  // both CSR/CSW internally, even when the board leaves pin 26 disconnected.
  // https://www.msx.org/forum/msx-talk/general-discussion/v9958-decapped?page=2
  // Incomplete register/palette and R44 transfers do not SET this latch;
  // they are still masked if a previous direct VRAM operation has set it.
  Result := FClocked and (FChip = VDPV9958) and (FR[25] and 4 <> 0) and FCPUWaitLatch;
end;

function TMSXVDP.ReadStatusCPU: Byte;
begin
  if CPUWaitAsserted then
    Exit($FF);
  if not FClocked then
    Exit(ReadStatus);
  var Index := 0;
  if FModel <> MSX1 then
    Index := FR[15] and 15;
  if Index > 1 then
    Exit(ReadStatus);
  // MD.Z80 calls the port after the entire four-T-state I/O cycle. The
  // falling T3 data sample precedes that callback by half a T (3 master
  // ticks). Acknowledge at the callback, but return the sampled byte.
  // This bounded digital aperture follows the observed read/clear ordering:
  // https://github.com/openMSX/openMSX/issues/792#issuecomment-752130878
  // The exact chip/board propagation inside it is not a calibrated delay.
  Result := SampleStatus(Index, FVideoClock - 3);
  ReadStatus;
end;
{$ENDREGION}

{$REGION 'Video prefetch'}
// Fetch positions are VDP master clocks. See the measured V9938 bus diagrams
// in MSX.VDP.Timing; character name/pattern/colour reads stay separate.

function TMSXVDP.VideoByte(Address: Integer): Byte;
begin
  if FModel = MSX1 then
    Result := FVRAM[TMSAddress(Address)]
  else
    Result := FVideo[Address and $1FFFF];
end;

function TMSXVDP.DisplayByte(Address: Integer): Byte;
begin
  Address := Address and $1FFFF;
  if not FClocked then
    Exit(VideoByte(Address));
  var H := ((Address shl 1) or (Address shr 16)) and 1023;
  if FDisplayKeys[H] = Address then
    Result := FDisplayBytes[H]
  else
    Result := 0;
end;

procedure TMSXVDP.BuildFetchEvents;

  procedure Event(Tick, Kind, Data: Integer);
  begin
    if Mode in [12, 16, 20, 28] then
    begin
      var Bus := CPUTimingKind(FLineStartClock + Tick);
      if ((Kind = 1) and not (Bus in [1, 2])) or ((Kind in [5, 6]) and (Bus <> 2)) then
        Exit;
    end;
    FFetchEvents[Tick] := (Kind shl 12) or Data;
  end;

begin
  FillChar(FFetchEvents, SizeOf(FFetchEvents), 0);
  FFetchMode := Mode;
  if Mode in [12, 16, 20, 28] then
  begin
    var Bytes := 4;
    var Step := 4;
    if Mode in [20, 28] then
    begin
      Bytes := 8;
      Step := 2;
    end;
    for var Block := -1 to 31 do
      for var B := 0 to Bytes - 1 do
        Event(227 + Block * 32 + B * Step, 1, (Block + 1) * 8 + B);
  end
  else if Mode in [1, 9] then
  begin
    if FModel = MSX1 then
      for var C := 0 to 39 do
      begin
        Event(236 + C * 24, 2, C);
        Event(252 + C * 24, 3, C);
      end
    else
      for var G := 0 to 19 do
      begin
        var N := 4;
        if Mode = 1 then
          N := 2;
        for var B := 0 to N - 1 do
        begin
          Event(246 + G * 48 + B * 4, 2, G * N + B);
          Event(270 + G * 48 + B * 6, 3, G * N + B);
        end;
        if (Mode = 9) and (G and 1 = 0) then
          Event(264 + G * 48, 4, G * 4);
      end;
  end
  else
  begin
    for var C := 0 to 31 do
    begin
      var Start := 214;
      if FModel = MSX1 then
        Start := 212;
      Event(Start + C * 32, 2, C);
      if FModel = MSX1 then
      begin
        Event(236 + C * 32, 3, C);
        Event(228 + C * 32, 4, C);
      end
      else
      begin
        Event(Start + 18 + C * 32, 3, C);
        Event(Start + 24 + C * 32, 4, C);
      end;
    end;
    if FChip = VDPV9958 then
    begin
      Event(182, 2, 79);
      Event(200, 3, 79);
      Event(206, 4, 79);
    end;
  end;
  if Mode in [1, 9] then
    Exit;
  var SM2 := Mode in [8, 12, 16, 20, 28];
  var Bitmap := Mode in [12, 16, 20, 28];
  if FModel = MSX1 then
  begin
    for var I := 0 to 7 do
      Event(148 + I * 8, 5, I);
    for var I := 8 to 31 do
      Event(252 + (I - 8) * 32, 5, I);
    for var I := 0 to 1 do
      for var F := 0 to 5 do
        Event(1252 + I * 48 + F * 8, 6, I * 8 + F);
    Event(1348, 6, 16);
    Event(1356, 6, 17);
    for var F := 2 to 5 do
      Event(36 + (F - 2) * 8, 6, 16 + F);
    for var F := 0 to 5 do
      Event(68 + F * 8, 6, 24 + F);
    Exit;
  end;
  for var I := 0 to 31 do
    if Mode >= 12 then
      Event(183 + I * 32, 5, I)
    else
      Event(226 + I * 32, 5, I);
  if Bitmap then
  begin
    Event(1207, 5, 32); // physical postamble read, ignored by sprite selection
    for var I := 0 to 47 do
    begin
      var Tick := SpriteReadPhase(I, 1);
      Event(Tick + RAMPostShift(FLineStartClock + Tick), 6, (I div 12) * 16 + MSXSpriteByteField[I mod 12]);
    end;
    for var I := 0 to 3 do
    begin
      var Tick := 1237 + I * 8;
      if CPUTimingKind(FLineStartClock + Tick) = 0 then
        Event(Tick, 7, 8 + I);
    end;
    for var I := 0 to 2 do
    begin
      var Tick := 1243 + I * 8;
      if CPUTimingKind(FLineStartClock + Tick) = 1 then
        Event(Tick, 7, I);
    end;
  end
  else if SM2 then
    for var G := 0 to 3 do
    begin
      var T: Integer;
      case G of
        0:
          T := 1238;
        1:
          T := 1302;
        2:
          T := 2;
      else
        T := 66;
      end;
      Event(T, 6, G * 16);
      Event(T + 4, 6, G * 16 + 1);
      Event(T + 8, 6, G * 16 + 2);
      Event(T + 13, 6, G * 16 + 8);
      Event(T + 17, 6, G * 16 + 9);
      Event(T + 21, 6, G * 16 + 10);
      var P := T + 32;
      if G = 1 then
        Inc(P, 4);
      Event(P, 6, G * 16 + 4);
      Event(P + 4, 6, G * 16 + 5);
      Event(P + 10, 6, G * 16 + 3);
      Event(P + 16, 6, G * 16 + 12);
      Event(P + 20, 6, G * 16 + 13);
      Event(P + 26, 6, G * 16 + 11);
    end
  else
    for var I := 0 to 3 do
    begin
      var T: Integer;
      case I of
        0:
          T := 1242;
        1:
          T := 1306;
        2:
          T := 6;
      else
        T := 70;
      end;
      for var B := 0 to 3 do
        Event(T + B * 4, 6, I * 8 + B);
      var P := T + 32;
      if I = 1 then
        Inc(P, 4);
      Event(P, 6, I * 8 + 4);
      Event(P + 4, 6, I * 8 + 5);
    end;
end;

procedure TMSXVDP.ScheduleFetch;
begin
  FNextFetch := High(Int64);
  if not FClocked then
    Exit;
  var Base := LineBaseAt(FVideoClock);
  for var T := LineTickAt(FVideoClock) + 1 to LineClocksAt(FVideoClock) - 1 do
    if FFetchEvents[T] <> 0 then
    begin
      FNextFetch := Base + T;
      Exit;
    end;
  for var T := 0 to LineClocksAt(Base + LineClocksAt(FVideoClock)) - 1 do
    if FFetchEvents[T] <> 0 then
    begin
      FNextFetch := Base + LineClocksAt(FVideoClock) + T;
      Exit;
    end;
end;

procedure TMSXVDP.FetchCharacter(Cell, Stage: Integer);
begin
  var Y := (FBeamLine + VerticalAdjust + Integer(FR[23])) and 255;
  var Text := Mode in [1, 9];
  var Cols := 32;
  if Mode = 1 then
    Cols := 40
  else if Mode = 9 then
    Cols := 80;
  var SX := Cell;
  if not Text and (Cell = 79) then
    SX := -1;
  if not Text and (FChip = VDPV9958) then
    SX := (SX + Integer(FR[26] and $3F)) and 63;
  var NB := Integer(FR[2] and $7F) shl 10;
  if Mode = 9 then
    NB := NB and $1F000;
  if not Text and (FChip = VDPV9958) and (FR[25] and 1 <> 0) then
  begin
    var Enable := NB and $8000;
    NB := NB and $17FFF;
    if SX and 32 <> 0 then
      NB := NB or Enable;
  end;
  if not Text then
    SX := SX and 31;
  var CI := Y div 8 * Cols + SX;
  if Stage = 0 then
  begin
    FNames[Cell] := VideoByte(NB + CI);
    Exit;
  end;
  var Code := Integer(FNames[Cell]);
  var PB := Integer(FR[4] and $3F) shl 11;
  var CB := (Integer(FR[10] and 7) shl 14) or (Integer(FR[3]) shl 6);
  var Offset := ((Y and $C0) shl 5) or (Code shl 3) or (Y and 7);
  if Stage = 1 then
    case Mode of
      2:
        begin
          FPatterns[Cell] := $F0;
          FColors[Cell] := VideoByte(PB + Code * 8 + ((Y div 4) and 7));
        end;
      4, 8:
        begin
          var Mask := ((Integer(FR[4]) and 3) shl 11) or $7FF;
          if IsToshiba then
            Mask := $1FFF;
          FPatterns[Cell] := VideoByte(((Integer(FR[4]) and $3C) shl 11) or (Offset and Mask));
        end;
    else
      FPatterns[Cell] := VideoByte(PB + Code * 8 + (Y and 7));
    end
  else
    case Mode of
      0:
        FColors[Cell] := VideoByte(CB + Code div 8);
      4, 8:
        begin
          var Mask := ((Integer(FR[3]) and $7F) shl 6) or $3F;
          if IsToshiba then
            Mask := $1FFF;
          FColors[Cell] := VideoByte((CB and $1E000) or (Offset and Mask));
        end;
      9:
        begin
          CB := (Integer(FR[10] and 7) shl 14) or (Integer(FR[3] and $F8) shl 6);
          var Value := VideoByte(CB + CI div 8);
          for var N := 0 to 7 do
            if Cell + N < 80 then
              FColors[Cell + N] := Ord(Value and ($80 shr N) <> 0);
        end;
    end;
end;

procedure TMSXVDP.ScanSprite(Index: Integer);
begin
  var M2 := Mode in [8, 12, 16, 20, 28];
  var SAT := ((Integer(FR[11] and 3) shl 15) or (Integer(FR[5]) shl 7));
  if M2 then
    SAT := SAT and $1FE00
  else
    SAT := SAT and $1FF80;
  EvaluateSprite(Index, VideoByte(PhysicalAddress(SAT + Index * 4)), M2);
end;

procedure TMSXVDP.EvaluateSprite(Index, SY: Integer; M2: Boolean);
begin
  if FSpriteStop then
    Exit;
  var Y := (FBeamLine + 1 + VerticalAdjust + TotalLines) mod TotalLines;
  if Y >= ScreenHeight then
    Exit;
  var Limit := 4;
  if M2 then
    Limit := 8;
  // Yamaha reports 31 in the absence of overflow. TI exposes the scan
  // counter; its first eight Y reads are in a separate short scan phase.
  if FModel = MSX1 then
  begin
    FSpriteCounter := Index;
    if FChip = VDPTMS9918A then
      FSpriteCounter := Min(Index, 8);
    if FS[0] and $40 = 0 then
      SetSpriteStatus((FS[0] and $E0) or FSpriteCounter);
  end;
  if (M2 and (SY = 216)) or (not M2 and (SY = 208)) then
  begin
    FSpriteStop := True;
    Exit;
  end;
  var Size := 8;
  if FR[1] and 2 <> 0 then
    Size := 16;
  if FR[1] and 1 <> 0 then
    Size := Size * 2;
  if SpriteRow(Y, SY, Index) >= Size then
    Exit;
  if FNextSpriteCount >= Limit then
  begin
    if FNextSpriteOverflow = $FF then
    begin
      FNextSpriteOverflow := Index;
      FSpriteStatusValue := Index;
      // Physical TMS9918 tests (hap, 2007): overflow becomes visible at the
      // end of evaluation, independently of which sprite exceeded the limit.
      var EndTick := 1180;
      if Mode < 12 then
        EndTick := 1224;
      if FModel = MSX1 then
        EndTick := 996;
      FNextSpriteStatus := LineBaseAt(FVideoClock) + EndTick;
    end;
    Exit;
  end;
  FSpriteNext[FNextSpriteCount].Index := Index;
  Inc(FNextSpriteCount);
end;

procedure TMSXVDP.FetchSprite(Entry, Field: Integer);
begin
  var S: ^TMSXSpriteFetch;
  var Y := FBeamLine + VerticalAdjust;
  if LineTickAt(FVideoClock) >= 1200 then
  begin
    if Entry >= FNextSpriteCount then
      Exit;
    S := @FSpriteNext[Entry];
    Inc(Y);
  end
  else
  begin
    if Entry >= FSpriteCount then
      Exit;
    S := @FSpriteCurrent[Entry];
    FSpriteCollisionDirty := True;
    ScheduleSpritePixel;
  end;
  Y := (Y + TotalLines) mod TotalLines;
  var M2 := Mode in [8, 12, 16, 20, 28];
  var SAT := (Integer(FR[11] and 3) shl 15) or (Integer(FR[5]) shl 7);
  if M2 then
    SAT := SAT and $1FE00
  else
    SAT := SAT and $1FF80;
  if Field < 3 then
  begin
    var V := VideoByte(PhysicalAddress(SAT + Integer(S.Index) * 4 + Field));
    case Field of
      0:
        S.Y := V;
      1:
        S.X := V;
      2:
        S.Code := V;
    end;
    Exit;
  end;
  var Row := SpriteRow(Y, S.Y, S.Index);
  if FR[1] and 1 <> 0 then
    Row := Row div 2;
  if Field = 3 then
    if M2 then
      S.Attr := VideoByte(PhysicalAddress((SAT and $1FC00) + Integer(S.Index) * 16 + (Row and 15)))
    else
      S.Attr := VideoByte(PhysicalAddress(SAT + Integer(S.Index) * 4 + 3)) and $8F
  else
  begin
    var Code := Integer(S.Code);
    if FR[1] and 2 <> 0 then
      Code := Code and $FC;
    var A := (Integer(FR[6] and $3F) shl 11) + Code * 8 + (Row and 15) + (Field - 4) * 16;
    var V := VideoByte(PhysicalAddress(A));
    if Field = 4 then
      S.Left := V
    else
      S.Right := V;
  end;
end;

procedure TMSXVDP.FetchAccess;
begin
  var E := FFetchEvents[LineTickAt(FVideoClock)];
  var K := E shr 12;
  var N := E and $FFF;
  if Mode in [12, 16, 20, 28] then
  begin
    BeginVideoAccess(K, N);
    Exit;
  end;
  if K = 5 then
  begin
    if (FR[1] and $40 <> 0) and ((FModel = MSX1) or (FR[8] and 2 = 0)) then
      ScanSprite(N);
    Exit;
  end;
  if K = 6 then
  begin
    if (FR[1] and $40 <> 0) and ((FModel = MSX1) or (FR[8] and 2 = 0)) then
      FetchSprite(N div 8, N and 7);
    Exit;
  end;
  var Y := FBeamLine + VerticalAdjust;
  if (Y < 0) or (Y >= ScreenHeight) then
    Exit;
  if (FR[1] and $40 = 0) and (Mode >= 12) then
    Exit;
  if K <> 1 then
  begin
    FetchCharacter(N, K - 2);
    Exit;
  end;
  // Fetch a physical byte once. Palette lookup happens later, at the pixel DAC.
  var LineBytes := DotWidth * BitsPerPixel div 8;
  var Bytes := 4;
  if Mode in [20, 28] then
    Bytes := 8;
  var Column := (N div 8 - 1) * Bytes + (N and 7);
  if (Column < 0) and ((FChip <> VDPV9958) or ((FR[26] = 0) and (FR[27] = 0))) then
    Exit;
  var Page := (Integer(FR[2]) and $60) shl 10;
  if Mode in [20, 28] then
    Page := (Integer(FR[2]) and $20) shl 11;
  if FBlinkOn or ((FR[9] and 4 <> 0) and (FS[2] and 2 = 0)) then
    Page := Page and ($1FFFF xor (LineBytes * 256));
  if FChip = VDPV9958 then
  begin
    Inc(Column, Integer(FR[26] and $3F) * 8 * LineBytes div 256);
    if FR[25] and 1 <> 0 then
    begin
      var Enable := Page and (LineBytes * 256);
      Page := Page and ($1FFFF xor (LineBytes * 256));
      if Column and LineBytes <> 0 then
        Page := Page or Enable;
    end;
  end;
  var A := PhysicalAddress(Page + ((Y + Integer(FR[23])) and 255) * LineBytes + (Column and (LineBytes - 1)));
  var H := ((A shl 1) or (A shr 16)) and 1023;
  FDisplayKeys[H] := A;
  FDisplayBytes[H] := VideoByte(A);
  FBitmapBytes[N] := FDisplayBytes[H];
end;
{$ENDREGION}

{$REGION 'Video bus'}
// Bitmap/sprite bytes are addressed at CAS assertion and enter their latches
// at CAS release. RAS origins identify shared bursts in the host-only trace.
// Row/column-mixing on a register edge inside a burst remains uncalibrated.

procedure TMSXVDP.BeginVideoAccess(Kind, Index: Integer);
begin
  var Y := VideoLineAt(FVideoClock);
  var Bus := CPUTimingKind(FVideoClock);
  if ((Kind = 1) and not (Bus in [1, 2])) or ((Kind in [5, 6]) and (Bus <> 2)) then
    Exit;
  var Q: TMSXVideoRead;
  FillChar(Q, SizeOf(Q), 0);
  Q.Kind := Kind;
  Q.Index := Index;
  var Base := LineBaseAt(FVideoClock);
  Q.CAS := FVideoClock;
  Q.Due := Q.CAS + 2;
  case Kind of
    1:
      begin
        var LineBytes := DotWidth * BitsPerPixel div 8;
        var Bytes := 4;
        if Mode in [20, 28] then
          Bytes := 8;
        var Block := Index div 8 - 1;
        var Column := Block * Bytes + (Index and 7);
        Q.RAS := Base + 226 + Block * 32;
        if (Y >= ScreenHeight) or ((Column < 0) and ((FChip <> VDPV9958) or ((FR[26] = 0) and (FR[27] = 0)))) then
        begin
          Q.Address := $1FFFF;
          Q.Flags := 2;
        end
        else
        begin
          var Page := (Integer(FR[2]) and $60) shl 10;
          if Mode in [20, 28] then
            Page := (Integer(FR[2]) and $20) shl 11;
          if FBlinkOn or ((FR[9] and 4 <> 0) and (FS[2] and 2 = 0)) then
            Page := Page and ($1FFFF xor (LineBytes * 256));
          if FChip = VDPV9958 then
          begin
            Inc(Column, Integer(FR[26] and $3F) * 8 * LineBytes div 256);
            if FR[25] and 1 <> 0 then
            begin
              var Enable := Page and (LineBytes * 256);
              Page := Page and ($1FFFF xor (LineBytes * 256));
              if Column and LineBytes <> 0 then
                Page := Page or Enable;
            end;
          end;
          Q.Address := PhysicalAddress(Page + ((Y + Integer(FR[23])) and 255) * LineBytes + (Column and (LineBytes - 1)));
        end;
      end;
    5:
      begin
        Q.RAS := Q.CAS - 1;
        if (Index = 32) or ((Y + 1) mod TotalLines >= ScreenHeight) then
        begin
          Q.Address := $1FFFF;
          Q.Flags := 2;
        end
        else
        begin
          var SAT := ((Integer(FR[11] and 3) shl 15) or (Integer(FR[5]) shl 7)) and $1FE00;
          Q.Address := PhysicalAddress(SAT + Index * 4);
        end;
      end;
    6:
      begin
        var Operation := (Index div 16) * 12 + MSXSpriteReadOperation[Index and 15];
        var RAS := SpriteReadPhase(Operation, 0);
        var Data := SpriteReadPhase(Operation, 2);
        var Shift := RAMPostShift(FVideoClock);
        Q.RAS := Base + RAS + Shift;
        Q.Due := Base + Data + Shift;
        var Entry := Index div 8;
        var Field := Index and 7;
        var S: ^TMSXSpriteFetch;
        if LineTickAt(FVideoClock) >= 1200 then
        begin
          Q.Flags := 1;
          S := @FSpriteNext[Entry];
          Inc(Y);
          if Entry >= FNextSpriteCount then
            S.Index := 0;
        end
        else
        begin
          S := @FSpriteCurrent[Entry];
          if Entry >= FSpriteCount then
            S.Index := 0;
        end;
        if (Y + TotalLines) mod TotalLines >= ScreenHeight then
        begin
          Q.Flags := Q.Flags or 2;
          Q.Address := $1FFFF;
    // The second attribute burst of the final display line uses the held
    // bitmap-row counter; all its data remains ignored by sprite selection.
          if (Q.Flags and 1 <> 0) and (Entry = 1) and (Field < 3) then
            Q.Address := PhysicalAddress((((Y - 1 + Integer(FR[23])) and 255) * (DotWidth * BitsPerPixel div 8)) + Field);
        end
        else
        begin
          var SAT := ((Integer(FR[11] and 3) shl 15) or (Integer(FR[5]) shl 7)) and $1FE00;
          if Field < 3 then
            Q.Address := PhysicalAddress(SAT + Integer(S.Index) * 4 + Field)
          else
          begin
            var Row := SpriteRow((Y + TotalLines) mod TotalLines, S.Y, S.Index);
            if FR[1] and 1 <> 0 then
              Row := Row div 2;
            if Field = 3 then
              Q.Address := PhysicalAddress((SAT and $1FC00) + Integer(S.Index) * 16 + (Row and 15))
            else
            begin
              var Code := Integer(S.Code);
              if FR[1] and 2 <> 0 then
                Code := Code and $FC;
              Q.Address := PhysicalAddress((Integer(FR[6] and $3F) shl 11) + Code * 8 + (Row and 15) + (Field - 4) * 16);
            end;
          end;
        end;
      end;
    7:
      begin
        Q.RAS := Q.CAS - 1;
        Q.Flags := 2;
        Q.Address := $1FFFF;
        if Index in [1, 2] then
          Q.Address := PhysicalAddress((((Y + Integer(FR[23])) and 255) * (DotWidth * BitsPerPixel div 8)) + (Index - 1) * 2);
      end;
  else
    Exit;
  end;
  for var I := 0 to High(FVideoReads) do
    if FVideoReads[I].Due = High(Int64) then
    begin
      FVideoReads[I] := Q;
      FNextVideoData := Min(FNextVideoData, Q.Due);
      Exit;
    end;
  raise EInvalidOpException.Create('MSX video-read pipeline exceeds two banks');
end;

procedure TMSXVDP.CompleteVideoAccess;
begin
  for var I := 0 to High(FVideoReads) do
    if FVideoReads[I].Due = FVideoClock then
    begin
      var Q := FVideoReads[I];
      FVideoReads[I].Due := High(Int64);
      var Value := VideoByte(Q.Address);
      if Assigned(FVideoTrace) then
        FVideoTrace(Q.RAS, Q.CAS, FVideoClock, Q.Address, Q.Kind, Q.Index, Value);
      if Q.Flags and 2 <> 0 then
        Continue;
      case Q.Kind of
        1:
          begin
            var H := ((Q.Address shl 1) or (Q.Address shr 16)) and 1023;
            FDisplayKeys[H] := Q.Address;
            FDisplayBytes[H] := Value;
            FBitmapBytes[Q.Index] := Value;
          end;
        5:
          EvaluateSprite(Q.Index, Value, True);
        6:
          begin
            var S: ^TMSXSpriteFetch;
            if Q.Flags and 1 <> 0 then
              S := @FSpriteNext[Q.Index div 8]
            else
              S := @FSpriteCurrent[Q.Index div 8];
            case Q.Index and 7 of
              0:
                S.Y := Value;
              1:
                S.X := Value;
              2:
                S.Code := Value;
              3:
                S.Attr := Value;
              4:
                S.Left := Value;
              5:
                S.Right := Value;
            end;
            if Q.Flags and 1 = 0 then
            begin
              FSpriteCollisionDirty := True;
              ScheduleSpritePixel;
            end;
          end;
      end;
    end;
  FNextVideoData := Min(FVideoReads[0].Due, FVideoReads[1].Due);
end;
{$ENDREGION}

{$REGION 'Sprite evaluation and pixels'}
// Status changes belong to the video clock, independently of host rendering.

procedure TMSXVDP.SetSpriteStatus(Value: Byte);
begin
  if Value <> FS[0] then
    RecordStatusChange;
  FS[0] := Value;
  if FModel = MSX1 then
  begin
    FStatus := Value;
    FSpriteIndex := Value and $1F;
  end;
end;

procedure TMSXVDP.ScheduleSpritePixel;
begin
  FNextSpritePixel := High(Int64);
  if not FClocked or (FS[0] and $20 <> 0) or (FSpriteCount < 2) or
    (FR[1] and $40 = 0) or (Mode in [1, 9]) or
    ((FModel <> MSX1) and (FR[8] and 2 <> 0)) then
    Exit;
  var Y := FBeamLine + VerticalAdjust;
  if (Y < 0) or (Y >= ScreenHeight) then
    Exit;
  var Start := 258 - HorizontalAdjust * 4;
  var Dot := LineTickAt(FVideoClock);
  var X := 0;
  if Dot >= Start then
    X := (Dot - Start) div 4 + 1;
  if X >= 256 then
    Exit;
  // Wait until the display starts before combining the border fetch latches.
  if FSpriteCollisionDirty and (Dot < Start) then
  begin
    FNextSpritePixel := LineBaseAt(FVideoClock) + Start;
    Exit;
  end;
  if FSpriteCollisionDirty then
    BuildSpriteCollision;
  while X < 256 do
  begin
    if FSpriteCollision[X shr 5] and (Cardinal(1) shl (X and 31)) <> 0 then
    begin
      FNextSpritePixel := LineBaseAt(FVideoClock) + Start + X * 4;
      Exit;
    end;
    Inc(X);
  end;
end;

procedure TMSXVDP.BuildSpriteCollision;
var
  Seen: array[0..7] of Cardinal;
begin
  FillChar(Seen, SizeOf(Seen), 0);
  FillChar(FSpriteCollision, SizeOf(FSpriteCollision), 0);
  FSpriteCollisionDirty := False;
  var M2 := Mode in [8, 12, 16, 20, 28];
  var Limit := 4;
  if M2 then
    Limit := 8;
  var Size := 8;
  if FR[1] and 2 <> 0 then
    Size := 16;
  var Zoom := 1;
  if FR[1] and 1 <> 0 then
    Zoom := 2;
  for var I := 0 to Min(Limit, FSpriteCount) - 1 do
  begin
    var S := FSpriteCurrent[I];
    var Attr := S.Attr;
    if M2 and (Attr and $60 <> 0) then
      Continue;
    // TI's coincidence detector includes colour zero; Yamaha gates it by TP.
    if (FModel <> MSX1) and (Attr and 15 = 0) and (FR[8] and $20 = 0) then
      Continue;
    var SX := Integer(S.X);
    if Attr and $80 <> 0 then
      Dec(SX, 32);
    for var PX := 0 to Size - 1 do
    begin
      var Pattern := S.Left;
      if PX >= 8 then
        Pattern := S.Right;
      if Pattern and ($80 shr (PX and 7)) = 0 then
        Continue;
      for var Z := 0 to Zoom - 1 do
      begin
        var X := SX + PX * Zoom + Z;
        if (X < 0) or (X > 255) then
          Continue;
        var Bit := Cardinal(1) shl (X and 31);
        var WordIndex := X shr 5;
        FSpriteCollision[WordIndex] := FSpriteCollision[WordIndex] or (Seen[WordIndex] and Bit);
        Seen[WordIndex] := Seen[WordIndex] or Bit;
      end;
    end;
  end;
end;

procedure TMSXVDP.SpritePixel;
begin
  if FSpriteCollisionDirty then
    BuildSpriteCollision;
  var X := (LineTickAt(FVideoClock) - 258 + HorizontalAdjust * 4) div 4;
  if (X < 0) or (X > 255) or (FSpriteCollision[X shr 5] and (Cardinal(1) shl (X and 31)) = 0) then
    Exit;
  if not RaiseStatus($20) then
    Exit;
  if (FModel <> MSX1) and (FR[8] and $C0 = 0) then
  begin
    var Y := FBeamLine + VerticalAdjust + 8;
    FS[3] := (X + 12) and 255;
    FS[4] := $FE or ((X + 12) shr 8);
    FS[5] := Y and 255;
    FS[6] := $FC or ((Y shr 8) and 1) or (FS[2] and 2);
  end;
end;

procedure TMSXVDP.ModeChanged(Previous: Integer);
begin
  // Completed fetches remain in their latches. Only future bus windows and
  // fetches change; an in-flight CPU RAM cycle keeps its granted transaction.
  BuildFetchEvents;
  ScheduleFetch;
  RescheduleCPU;
  RescheduleCommand;
end;

function TMSXVDP.DecodeYJK(Value, C0, C1, C2, C3: Byte): TAlphaColor;
begin
  if (FR[25] and $10 <> 0) and (Value and 8 <> 0) then
    Exit(PaletteColor(Value shr 4));
  var J := Integer(C2 and 7) or (Integer(C3 and 7) shl 3);
  var K := Integer(C0 and 7) or (Integer(C1 and 7) shl 3);
  if J >= 32 then
    Dec(J, 64);
  if K >= 32 then
    Dec(K, 64);
  var Y := Integer(Value shr 3);
  var R := EnsureRange(Y + J, 0, 31);
  var G := EnsureRange(Y + K, 0, 31);
  var B := EnsureRange((5 * Y - 2 * J - K) div 4, 0, 31);
  // Integer replication, matching the existing V9958 conversion path.
  Result := $FF000000 or (Cardinal((R shl 3) or (R shr 2)) shl 16) or
    (Cardinal((G shl 3) or (G shr 2)) shl 8) or Cardinal((B shl 3) or (B shr 2));
end;

function TMSXVDP.TimedBitmapPixel(X: Integer): TAlphaColor;
begin
  var Width := DisplayDotWidth;
  var BlockWidth := Width div 32;
  var SX := X + BlockWidth;
  if FChip = VDPV9958 then
    Dec(SX, Integer(FR[27] and 7) * (Width div 256));
  var Bytes := 4;
  if Mode in [20, 28] then
    Bytes := 8;
  var Index := SX div BlockWidth * 8 + (SX mod BlockWidth) * Bytes div BlockWidth;
  if (Index < 0) or (Index > High(FBitmapBytes)) then
    Exit(PaletteColor(FR[7] and 15));
  var Value := FBitmapBytes[Index];
  if (FChip = VDPV9958) and (Mode in [20, 28]) and (FR[25] and 8 <> 0) then
  begin
    var A := Index and (not 3);
    Exit(DecodeYJK(Value, FBitmapBytes[A], FBitmapBytes[A + 1], FBitmapBytes[A + 2], FBitmapBytes[A + 3]));
  end;
  var BPP := BitsPerPixel;
  Value := (Value shr ((8 div BPP - 1 - (SX and (8 div BPP - 1))) * BPP)) and ((1 shl BPP) - 1);
  if Mode = 28 then
    Exit(DirectColor(Value));
  if (Mode = 16) and (Value = 0) and (FR[8] and $20 = 0) then
    Exit(PaletteColor((FR[7] shr ((1 - (X and 1)) * 2)) and 3));
  Result := Color(Value);
end;
{$ENDREGION}

function RGB3(Value: Cardinal): Cardinal; inline;
begin
  Result := (Value shl 5) or (Value shl 2) or (Value shr 1);
end;

function RGB5(Value: Cardinal): Cardinal; inline;
begin
  Result := (Value shl 3) or (Value shr 2);
end;

constructor TMSXVDP.Create(Model: TMSXModel; PAL, Clocked: Boolean);
begin
  inherited Create;
  FModel := Model;
  FDefaultPAL := PAL;
  ConfigureChip(VDPAuto);
  FClocked := Clocked;
  FMSX1PAL := PAL;
  SetLength(FOutput, 512 * 424);
  Reset;
end;

procedure TMSXVDP.Reset;
const
  InitialPalette: array[0..15] of Word = ($000, $000, $611, $733,
    $117, $327, $151, $627, $171, $373, $661, $664, $411, $265, $555, $777);
begin
  inherited;
  FillChar(FVideo, SizeOf(FVideo), 0);
  FillChar(FR, SizeOf(FR), 0);
  FillChar(FS, SizeOf(FS), 0);
  Move(InitialPalette, FPalette, SizeOf(FPalette));
  FS[0] := $1F;
  FS[2] := $0C;
  FS[4] := $FE;
  FS[6] := $FC;
  FS[9] := $FE;
  if FChip = VDPV9958 then
    FS[1] := 4;
  FStatusHistoryHead := 0;
  for var I := 0 to High(FStatusHistory) do
  begin
    FStatusHistory[I].Clock := -1;
    FStatusHistory[I].Before[0] := FS[0];
    FStatusHistory[I].Before[1] := FS[1];
  end;
  FPointer := 0;
  FBuffer := 0;
  FFirstControl := 0;
  FFirstPalette := 0;
  FPending := False;
  FPalettePending := False;
  FCommand := 0;
  FVideoClock := 0;
  FCommandDue := High(Int64);
  FCommandPhase := 0;
  FCommandDataDue := High(Int64);
  FCommandRAS := 0;
  FCommandSerial := 0;
  FCommandBusSerial := 0;
  FCommandBusAddress := 0;
  FCommandBusMode := 0;
  FCommandBusKind := 0;
  FCommandBusValue := 0;
  FCommandBusShift := 0;
  FCommandBusMask := 0;
  FCommandBusR44 := 0;
  FCommandBusR45 := 0;
  FCommandBusR46 := 0;
  FCommandBusEnabled := False;
  FCommandCommitting := False;
  FStatusReadUntil := -1;
  FHorizontalSetClock := -1;
  for var I := 0 to 2 do
    FStatusSetClock[I] := -1;
  FTransferPending := False;
  FCachedDestination := False;
  FTransferValue := 0;
  FSourceByte := 0;
  FDestByte := 0;
  FDestAddress := 0;
  FHorizontalCycles := 0;
  // RenderLine can also be used without a scan clock by diagnostic callers.
  // EndLine connects it to the timed beam, used by the running console.
  FBeamLine := -1;
  FRasterX := 0;
  FLineAdjust := 0;
  FPreviousLineAdjust := 0;
  FLineStartClock := 0;
  FLineClocks := 1368;
  FillChar(FLineTiming, SizeOf(FLineTiming), 0);
  FLineTimingHead := 0;
  FLineTimingCount := 1;
  FLineTiming[0].Clocks := 1368;
  FCommandRequestTime := 0;
  FCommandWork := 0;
  FillChar(FVideoReads, SizeOf(FVideoReads), 0);
  FNextVideoData := High(Int64);
  for var I := 0 to High(FVideoReads) do
    FVideoReads[I].Due := High(Int64);
  if FClocked then
    FBeamLine := 0;
  FCPUPending := False;
  FCPUWrite := False;
  FCPUDue := High(Int64);
  FNextFetch := High(Int64);
  FFetchMode := -1;
  FNextSpritePixel := High(Int64);
  FCPUReady := 0;
  FCommandReady := 0;
  FCPUWaitLatch := False;
  FNextSpriteStatus := High(Int64);
  FSpriteStatusValue := 0;
  FSpriteCounter := 31;
  FillChar(FSpriteCollision, SizeOf(FSpriteCollision), 0);
  FSpriteCollisionDirty := True;
  FillChar(FBitmapBytes, SizeOf(FBitmapBytes), 0);
  FCPUPhase := 0;
  FCPUValue := 0;
  FCPUAddress := 0;
  FCPUAccessWrite := False;
  FCPUAccessStart := 0;
  FCPUAccessEnabled := True;
  FCPUNextSlot := High(Int64);
  FCPUNextReady := 0;
  FCPUGranted := -1;
  FCPUDummy := High(Int64);
  FCPUNextWrite := False;
  FCPUGrantedLate := False;
  FCPUNextValue := 0;
  FillChar(FNames, SizeOf(FNames), 0);
  FillChar(FPatterns, SizeOf(FPatterns), 0);
  FillChar(FColors, SizeOf(FColors), 0);
  FillChar(FDisplayKeys, SizeOf(FDisplayKeys), $FF);
  FillChar(FDisplayBytes, SizeOf(FDisplayBytes), 0);
  FillChar(FSpriteCurrent, SizeOf(FSpriteCurrent), 0);
  FillChar(FSpriteNext, SizeOf(FSpriteNext), 0);
  FSpriteCount := 0;
  FNextSpriteCount := 0;
  FSpriteOverflow := $FF;
  FNextSpriteOverflow := $FF;
  FSpriteStop := False;
  if FClocked then
  begin
    BuildFetchEvents;
    ScheduleFetch;
  end;
  FLineError := 0;
  FBlinkOn := False;
  FBlinkFrames := 0;
  FCX := 0;
  FCY := 0;
  FSX := 0;
  FSY := 0;
  FDX := 0;
  FDY := 0;
  FNX := 0;
  FNY := 0;
  FTX := 1;
  FTY := 1;
  for var i := 0 to High(FOutput) do
    FOutput[i] := $FF000000;
end;

function TMSXVDP.Mode: Integer;
begin
  Result := ((FR[1] shr 4) and 1) or ((FR[1] shr 2) and 2) or
    ((FR[0] and $0E) shl 1);
end;

function TMSXVDP.ScreenWidth: Integer;
begin
  Result := 256;
  if FModel <> MSX1 then
    Result := 512;
end;

function TMSXVDP.ScreenHeight: Integer;
begin
  Result := 192;
  if (FModel <> MSX1) and (FR[9] and $80 <> 0) then
    Result := 212;
end;

function TMSXVDP.TotalLines: Integer;
begin
  Result := 262;
  if (FModel = MSX1) and FMSX1PAL then
    Exit(313);
  if (FModel <> MSX1) and (FR[9] and 2 <> 0) then
    Result := 313;
end;

function TMSXVDP.DisplayPixels: TArray<TAlphaColor>;
begin
  if FModel = MSX1 then
    Result := FPixels
  else
    Result := FOutput;
end;

function TMSXVDP.Interlaced: Boolean;
begin
  Result := (FModel <> MSX1) and (FR[9] and 8 <> 0);
end;

function TMSXVDP.OutputHeight: Integer;
begin
  Result := ScreenHeight;
  if Interlaced then
    Result := Result * 2;
end;

function TMSXVDP.PaletteColor(Index: Integer): TAlphaColor;
begin
  if FModel = MSX1 then
    Exit(inherited Color(Index));
  var P := FPalette[Index and 15];
  Result := $FF000000 or (RGB3((P shr 4) and 7) shl 16) or
    (RGB3((P shr 8) and 7) shl 8) or RGB3(P and 7);
end;

function TMSXVDP.Color(Index: Integer): TAlphaColor;
begin
  if FModel = MSX1 then
    Exit(inherited Color(Index));
  Index := Index and 15;
  if (Index = 0) and (FR[8] and $20 = 0) then
    Index := FR[7] and 15;
  Result := PaletteColor(Index);
end;

function TMSXVDP.SpriteColor(Index, Half: Integer): TAlphaColor;
const
  // Fixed G7 sprite DAC levels from Yamaha's sprite colour table (GRB333).
  G7: array[0..15] of Word = ($000, $002, $030, $032, $300, $302, $330, $332,
    $472, $007, $070, $077, $700, $707, $770, $777);
begin
  if FModel = MSX1 then
    Exit(inherited Color(Index));
  if Mode = 16 then
    Exit(PaletteColor((Index shr ((1 - Half) * 2)) and 3));
  if Mode = 28 then
  begin
    var P := G7[Index and 15];
    Exit($FF000000 or (RGB3((P shr 4) and 7) shl 16) or
      (RGB3((P shr 8) and 7) shl 8) or RGB3(P and 7));
  end;
  Result := PaletteColor(Index);
end;

function TMSXVDP.DirectColor(Value: Byte): TAlphaColor;
const
  Blue: array[0..3] of Cardinal = (0, 2, 4, 7);
begin
  Result := $FF000000 or (RGB3((Value shr 2) and 7) shl 16) or
    (RGB3(Value shr 5) shl 8) or RGB3(Blue[Value and 3]);
end;

procedure TMSXVDP.IncrementAddress;
begin
  FPointer := (FPointer + 1) and $1FFFF;
  // Only the TMS-compatible modes wrap at 16 KiB. G3 (SCREEN 4) and
  // TEXT2 carry A13 into R14 just like the bitmap modes (Yamaha, p.16).
  if FPointer and $3FFF = 0 then
    if Mode < 8 then
      FPointer := (FPointer - $4000) and $1FFFF
    else
      FR[14] := (FPointer shr 14) and 7;
end;

function TMSXVDP.ReadData: Byte;
begin
  if CPUWaitAsserted then
    Exit($FF);
  if FClocked then
  begin
    FPending := False;
    FControlPending := False;
    Result := FBuffer;
    QueueCPU(False);
    Exit;
  end;
  if FModel = MSX1 then
    Exit(inherited ReadData);
  FPending := False;
  Result := FBuffer;
  if FR[45] and $40 <> 0 then
    FBuffer := $FF
  else
    FBuffer := FVideo[PhysicalAddress(FPointer)];
  IncrementAddress;
end;

procedure TMSXVDP.WriteData(Value: Byte);
begin
  if CPUWaitAsserted then
    Exit;
  if FClocked then
  begin
    FPending := False;
    FControlPending := False;
    QueueCPU(True, Value);
    Exit;
  end;
  if FModel = MSX1 then
  begin
    inherited;
    Exit;
  end;
  FPending := False;
  var A := PhysicalAddress(FPointer);
  if FR[45] and $40 = 0 then
  begin
    FlushRaster;
    FVideo[A] := Value;
    if A < $4000 then
      FVRAM[A] := Value;
  end;
  FBuffer := Value;
  IncrementAddress;
end;

procedure TMSXVDP.SetRegister(Index, Value: Byte);
begin
  if Index > 46 then
    if (FChip <> VDPV9958) or not (Index in [25, 26, 27]) then
      Exit;
  if (Index in [25, 26, 27]) and (FChip <> VDPV9958) then
    Exit;
  var Previous := Mode;
  var OldAdjust := FR[18] and 15;
  var OldValue := FR[Index];
  if (Index in [0..13, 18, 23, 25, 26, 27]) and (FR[Index] <> Value) then
    FlushRaster;
  FR[Index] := Value;
  if Index < 8 then
    FRegisters[Index] := Value;
  case Index of
    13:
      begin
        FBlinkOn := Value and $F0 <> 0;
        FBlinkFrames := 0;
        if (Value and $F0 <> 0) and (Value and 15 <> 0) then
          FBlinkFrames := (Value shr 4) * 10;
      end;
    14:
      begin
        FR[14] := Value and 7;
        FPointer := (FPointer and $3FFF) or (Integer(FR[14]) shl 14);
      end;
    15:
      FR[15] := Value and 15;
    16:
      begin
        FR[16] := Value and 15;
        FPalettePending := False;
      end;
    17:
      FR[17] := Value and $BF;
    44:
      begin
        FTransferPending := True;
        FTransferValue := Value;
        FS[2] := FS[2] and $7F;
        if (FCommand in [$B, $F]) and (FCommandDue = High(Int64)) and
          (FCommandDataDue = High(Int64)) then
          ScheduleCommand(24);
      end;
    46:
      StartCommand(Value);
  end;
  if (Index = 18) and (OldAdjust <> (FR[18] and 15)) then
  begin
    if FClocked then
      RescheduleCPU;
    RescheduleCommand;
  end;
  if FClocked then
  begin
    if Mode <> Previous then
      ModeChanged(Previous)
    else if ((Index = 1) and ((OldValue xor Value) and $40 <> 0)) or
      ((Index = 8) and ((OldValue xor Value) and 2 <> 0)) or
      ((Index = 9) and ((OldValue xor Value) and $B2 <> 0)) or
      ((Index = 18) and ((OldValue xor Value) and $F0 <> 0)) then
    begin
      BuildFetchEvents;
      ScheduleFetch;
      RescheduleCPU;
      RescheduleCommand;
    end;
    if Index in [0, 1, 8, 18, 23, 25] then
    begin
      FSpriteCollisionDirty := True;
      ScheduleSpritePixel;
    end;
  end;
end;

procedure TMSXVDP.WriteControl(Value: Byte);
const
  Masks: array[0..7] of Byte = ($03, $FB, $0F, $FF, $07, $7F, $07, $FF);
begin
  if CPUWaitAsserted then
    Exit;
  if (FModel = MSX1) and FClocked then
  begin
    if not FControlPending then
    begin
      FAddress := (FAddress and $3F00) or Value;
      FControlPending := True;
      Exit;
    end;
    FAddress := ((Integer(Value) shl 8) or (FAddress and $FF)) and $3FFF;
    FControlPending := False;
    if Value and $80 <> 0 then
      SetRegister(Value and 7, (FAddress and $FF) and Masks[Value and 7])
    else if Value and $40 = 0 then
      QueueCPU(False);
    Exit;
  end;
  if FModel = MSX1 then
  begin
    inherited;
    Exit;
  end;
  if not FPending then
  begin
    FFirstControl := Value;
    FPending := True;
    Exit;
  end;
  FPending := False;
  if Value and $80 <> 0 then
  begin
    if Value and $40 = 0 then
      SetRegister(Value and $3F, FFirstControl);
  end
  else
  begin
    FPointer := (Integer(FR[14] and 7) shl 14) or (Integer(Value and $3F) shl 8) or FFirstControl;
    if Value and $40 = 0 then
    begin
      if FClocked then
      begin
        QueueCPU(False);
        Exit;
      end;
      if FR[45] and $40 <> 0 then
        FBuffer := $FF
      else
        FBuffer := FVideo[PhysicalAddress(FPointer)];
      IncrementAddress;
    end;
  end;
end;

procedure TMSXVDP.WritePalette(Value: Byte);
begin
  if CPUWaitAsserted then
    Exit;
  if FModel = MSX1 then
    Exit;
  if not FPalettePending then
  begin
    FFirstPalette := Value and $77;
    FPalettePending := True;
    Exit;
  end;
  FlushRaster;
  FPalettePending := False;
  FPalette[FR[16] and 15] := (Integer(Value and 7) shl 8) or FFirstPalette;
  FR[16] := (FR[16] + 1) and 15;
end;

procedure TMSXVDP.WriteIndirect(Value: Byte);
begin
  if CPUWaitAsserted then
    Exit;
  if FModel = MSX1 then
    Exit;
  var Index := FR[17] and $3F;
  if Index <> 17 then
    SetRegister(Index, Value);
  if FR[17] and $80 = 0 then
    FR[17] := (Index + 1) and $3F;
end;

function TMSXVDP.ReadStatus: Byte;
begin
  if CPUWaitAsserted then
    Exit($FF);
  if FClocked and ((FModel = MSX1) or (FR[15] and 15 = 0)) then
  begin
    FPending := False;
    FControlPending := False;
    Result := Status0;
    Exit;
  end;
  if FModel = MSX1 then
  begin
    Result := inherited ReadStatus;
    FS[0] := FStatus;
    if FClocked then
    begin
      SetSpriteStatus(FSpriteCounter);
      ScheduleSpritePixel;
    end;
    Exit;
  end;
  FPending := False;
  var Index := FR[15] and 15;
  Result := $FF;
  if Index > 9 then
    Exit;
  Result := FS[Index];
  case Index of
    0:
      begin
        FS[0] := FS[0] and $1F;
        if FClocked then
        begin
          SetSpriteStatus(FSpriteCounter);
          ScheduleSpritePixel;
        end;
      end;
    1:
      begin
        if FClocked and (FHorizontalSetClock = FVideoClock) then
          Result := Result and $FE;
        SetHorizontalStatus(FS[1] and $FE);
      end;
    5:
      begin
        FS[3] := 0;
        FS[4] := $FE;
        FS[5] := 0;
        FS[6] := $FC;
      end;
    7:
      if (FCommand = $A) and (FS[2] and $80 <> 0) then
      begin
        FS[2] := FS[2] and $7F;
        NextCommand;
        if FCommand <> 0 then
          ScheduleCommand(88);
      end;
  end;
end;

function TMSXVDP.CommandDot(X, Y: Integer): Byte;
begin
  if FCommandCommitting then
    Exit(CommandReadPixel);
  if FR[45] and $10 <> 0 then
    Exit($FF);
  var BPP := CommandPixelBits;
  var Shift := (8 div BPP - 1 - (X and (8 div BPP - 1))) * BPP;
  Result := (FVideo[CommandVideoAddress(X, Y)] shr Shift) and ((1 shl BPP) - 1);
end;

procedure TMSXVDP.CommandPutDot(X, Y: Integer; Value: Byte);
begin
  if FCommandCommitting then
    Exit; // the latched RAM write has already committed
  if FR[45] and $20 <> 0 then
    Exit;
  var Address := CommandVideoAddress(X, Y);
  var BPP := CommandPixelBits;
  var Shift := (8 div BPP - 1 - (X and (8 div BPP - 1))) * BPP;
  var Data: Byte;
  if MergePixelByte(FVideo[Address], Value, FR[46], Shift, BPP, Data) then
  begin
    FlushRaster;
    FVideo[Address] := Data;
    if Address < $4000 then
      FVRAM[Address] := Data;
  end;
end;

procedure TMSXVDP.SetCommandY(Index, Value: Integer);
begin
  FR[Index] := Value and $FF;
  FR[Index + 1] := (Value shr 8) and 3;
end;

function TMSXVDP.Interrupt: Boolean;
begin
  if FModel = MSX1 then
    Exit(inherited Interrupt);
  Result := ((FS[0] and $80 <> 0) and (FR[1] and $20 <> 0)) or
    ((FS[1] and 1 <> 0) and (FR[0] and $10 <> 0));
end;

procedure TMSXVDP.VBlank;
begin
  if FClocked then
  begin
    RaiseStatus($80);
    Exit;
  end;
  if FModel = MSX1 then
  begin
    inherited;
    FS[0] := FStatus;
    Exit;
  end;
  FS[0] := FS[0] or $80;
end;

procedure TMSXVDP.EndLine(Line, TotalLines: Integer);
begin
  LatchLineTiming;
  if FClocked then
  begin
    FSpriteCurrent := FSpriteNext;
    FSpriteCount := FNextSpriteCount;
    FSpriteOverflow := FNextSpriteOverflow;
    for var I := 0 to High(FVideoReads) do
      if FVideoReads[I].Due <> High(Int64) then
        if FVideoReads[I].Flags and 1 <> 0 then
          FVideoReads[I].Flags := FVideoReads[I].Flags and $FE;
    FNextSpriteCount := 0;
    FNextSpriteOverflow := $FF;
    FSpriteStop := False;
    FillChar(FSpriteNext, SizeOf(FSpriteNext), 0);
    FillChar(FDisplayKeys, SizeOf(FDisplayKeys), $FF);
    FillChar(FBitmapBytes, SizeOf(FBitmapBytes), 0);
    FSpriteCollisionDirty := True;
  end;
  if (FModel = MSX1) and FClocked then
  begin
    if Line = ScreenHeight - 1 then
      VBlank;
    FBeamLine := (Line + 1) mod TotalLines;
    FRasterX := 0;
    ScheduleSpritePixel;
    Exit;
  end;
  if FModel = MSX1 then
    Exit;
  FBeamLine := (Line + 1) mod TotalLines;
  FRasterX := 0;
  FPreviousLineAdjust := FLineAdjust;
  FLineAdjust := (FR[18] and 15) or ((FR[25] and 8) shl 1);
  if (FLineAdjust and 15) <> (FPreviousLineAdjust and 15) then
  begin
    RescheduleCPU;
    RescheduleCommand;
    if FClocked then
    begin
      BuildFetchEvents;
      ScheduleFetch;
    end;
  end;
  var DisplayLine := (Line + VerticalAdjust + TotalLines) mod TotalLines;
  var Boundary := DisplayLine;
  if FClocked then
    Boundary := (DisplayLine + 1) mod TotalLines;
  if Boundary = 0 then
    FS[2] := FS[2] and $BF;
  if Line = TotalLines - 1 then
  begin
    FS[2] := FS[2] xor 2;
    if FBlinkFrames > 0 then
    begin
      Dec(FBlinkFrames);
      if FBlinkFrames = 0 then
      begin
        FBlinkOn := not FBlinkOn;
        if FBlinkOn then
          FBlinkFrames := (FR[13] shr 4) * 10
        else
          FBlinkFrames := (FR[13] and 15) * 10;
      end;
    end;
  end;
  if Boundary = ScreenHeight then
  begin
    FS[2] := FS[2] or $40;
    VBlank;
  end;
  // With IE1 disabled FH is a line-comparison pulse, not a permanent latch.
  // Keeping an old match misidentifies a later vertical IRQ as a line IRQ.
  if FR[0] and $10 = 0 then
    SetHorizontalStatus(FS[1] and $FE);
  if (DisplayLine < 256) and (((DisplayLine + Integer(FR[23])) and 255) = FR[19]) then
  begin
    if FS[1] and 1 = 0 then
      FHorizontalSetClock := FVideoClock;
    SetHorizontalStatus(FS[1] or 1);
  end;
  if FClocked then
  begin
    if Mode in [12, 16, 20, 28] then
    begin
      BuildFetchEvents;
      ScheduleFetch;
    end;
    ScheduleSpritePixel;
  end;
end;

function TMSXVDP.DotWidth: Integer;
begin
  Result := 256;
  if Mode in [16, 20] then
    Result := 512;
end;

function TMSXVDP.DisplayDotWidth: Integer;
begin
  Result := DotWidth;
  if (FChip = VDPV9958) and (Mode in [20, 28]) and (FR[25] and 8 <> 0) then
    Result := 256;
end;

function TMSXVDP.BitsPerPixel: Integer;
begin
  Result := 4;
  if Mode = 16 then
    Result := 2;
  if Mode = 28 then
    Result := 8;
end;

function TMSXVDP.VideoAddress(X, Y: Integer): Integer;
begin
  Result := ((Y and 1023) * (DotWidth * BitsPerPixel div 8) +
    (X and (DotWidth - 1)) * BitsPerPixel div 8) and $1FFFF;
  Result := PhysicalAddress(Result);
end;

function TMSXVDP.PhysicalAddress(Address: Integer): Integer;
begin
  Result := Address and $1FFFF;
  if Mode in [20, 28] then
    Result := (Result shr 1) or ((Result and 1) shl 16);
end;

function TMSXVDP.Dot(X, Y: Integer): Byte;
begin
  var BPP := BitsPerPixel;
  Result := (FVideo[VideoAddress(X, Y)] shr ((8 div BPP - 1 - (X and (8 div BPP - 1))) * BPP)) and ((1 shl BPP) - 1);
end;

procedure TMSXVDP.PutDot(X, Y: Integer; Value, Logic: Byte);
begin
  var BPP := BitsPerPixel;
  var A := VideoAddress(X, Y);
  var Shift := (8 div BPP - 1 - (X and (8 div BPP - 1))) * BPP;
  var Previous := FVideo[A];
  if FCachedDestination and (A = FDestAddress) then
    Previous := FDestByte;
  var Data: Byte;
  if not MergePixelByte(Previous, Value, Logic, Shift, BPP, Data) then
    Exit;
  FlushRaster;
  FVideo[A] := Data;
  if A < $4000 then
    FVRAM[A] := FVideo[A];
end;

function TMSXVDP.YJKColor(Address: Integer): TAlphaColor;
begin
  var X := Address and 255;
  var Y := Address shr 8;
  var Base := X and $FC;
  var A := (Y * 256 + Base) and $1FFFF;
  var C0 := DisplayByte(PhysicalAddress(A));
  var C1 := DisplayByte(PhysicalAddress(A + 1));
  var C2 := DisplayByte(PhysicalAddress(A + 2));
  var C3 := DisplayByte(PhysicalAddress(A + 3));
  var J := Integer(C2 and 7) or (Integer(C3 and 7) shl 3);
  var K := Integer(C0 and 7) or (Integer(C1 and 7) shl 3);
  if J >= 32 then
    Dec(J, 64);
  if K >= 32 then
    Dec(K, 64);
  var V := DisplayByte(PhysicalAddress(Y * 256 + X));
  if (FR[25] and $10 <> 0) and (V and 8 <> 0) then
    Exit(PaletteColor(V shr 4));
  var L := Integer(V shr 3);
  var R := EnsureRange(L + J, 0, 31);
  var G := EnsureRange(L + K, 0, 31);
  var B := EnsureRange((5 * L - 2 * J - K) div 4, 0, 31);
  Result := $FF000000 or (RGB5(R) shl 16) or (RGB5(G) shl 8) or RGB5(B);
end;

function TMSXVDP.PatternPixel(X, Y, DisplayMode: Integer): TAlphaColor;
begin
  var TextMode := DisplayMode in [1, 9];
  var SX := X div 2;
  var Cols := 32;
  var Cell := 8;
  if TextMode then
  begin
    // V99x8 text starts nine low-resolution dots after the graphics origin.
    var Left := 18;
    if FModel = MSX1 then
      Left := 16;
    if DisplayMode = 1 then
    begin
      Cols := 40;
      SX := (X - Left) div 2;
    end
    else
    begin
      Cols := 80;
      SX := X - Left;
    end;
    Cell := 6;
    if (X < Left) or (SX >= Cols * Cell) then
      Exit(PaletteColor(FR[7] and 15));
  end;
  var NameBase := Integer(FR[2] and $7F) shl 10;
  if DisplayMode = 9 then
    NameBase := NameBase and $1F000;
  if not TextMode and (FChip = VDPV9958) then
  begin
    var Scroll := (Integer(FR[26] and $3F) * 8 - Integer(FR[27] and 7));
    SX := (SX + Scroll) and 511;
    if (FR[25] and 1 <> 0) then
    begin
      var Enable := NameBase and $8000;
      NameBase := NameBase and $17FFF;
      if SX and 256 <> 0 then
        NameBase := NameBase or Enable;
    end;
    SX := SX and 255;
  end;
  var CellIndex := (Y div 8) * Cols + SX div Cell;
  var Code := Integer(VideoByte(NameBase + CellIndex));
  var PatternBase := Integer(FR[4] and $3F) shl 11;
  var Colors := FR[7];
  var Pattern: Byte;
  case DisplayMode of
    0:
      begin
        Pattern := FVideo[(PatternBase + Code * 8 + (Y and 7)) and $1FFFF];
        var ColorBase := (Integer(FR[10] and 7) shl 14) or (Integer(FR[3]) shl 6);
        Colors := FVideo[(ColorBase + Code div 8) and $1FFFF];
      end;
    1, 9:
      begin
        Pattern := FVideo[(PatternBase + Code * 8 + (Y and 7)) and $1FFFF];
        if (DisplayMode = 9) and FBlinkOn then
        begin
          var ColorBase := (Integer(FR[10] and 7) shl 14) or (Integer(FR[3] and $F8) shl 6);
          if FVideo[(ColorBase + CellIndex div 8) and $1FFFF] and ($80 shr (CellIndex and 7)) <> 0 then
            Colors := FR[12];
        end;
      end;
    2:
      begin
        Colors := FVideo[(PatternBase + Code * 8 + ((Y div 4) and 7)) and $1FFFF];
        Pattern := $F0;
      end;
    4, 8:
      begin
        var Offset := ((Y and $C0) shl 5) or (Code shl 3) or (Y and 7);
        var PatternMask := ((Integer(FR[4]) and 3) shl 11) or $7FF;
        PatternBase := (Integer(FR[4]) and $3C) shl 11;
        Pattern := FVideo[(PatternBase or (Offset and PatternMask)) and $1FFFF];
        var ColorMask := ((Integer(FR[3]) and $7F) shl 6) or $3F;
        var ColorBase := (Integer(FR[10] and 7) shl 14) or (Integer(FR[3] and $80) shl 6);
        Colors := FVideo[(ColorBase or (Offset and ColorMask)) and $1FFFF];
      end;
  else
    Exit(Color(0));
  end;
  if FClocked then
  begin
    var CacheCell := X div 16;
    if not TextMode and (FChip = VDPV9958) then
    begin
      var Pixel := X div 2 - Integer(FR[27] and 7);
      if Pixel < 0 then
        CacheCell := 79
      else
        CacheCell := Pixel div 8;
    end;
    if TextMode then
      if DisplayMode = 1 then
        CacheCell := (X - 18) div 12
      else
        CacheCell := (X - 18) div 6;
    if (FModel = MSX1) and TextMode then
      CacheCell := (X - 16) div 12;
    CacheCell := EnsureRange(CacheCell, 0, 79);
    Pattern := FPatterns[CacheCell];
    if TextMode then
    begin
      Colors := FR[7];
      if (DisplayMode = 9) and FBlinkOn and (FColors[CacheCell] <> 0) then
        Colors := FR[12];
    end
    else
      Colors := FColors[CacheCell];
  end;
  var Index := Integer(Colors and 15);
  if Pattern and ($80 shr (SX mod Cell)) <> 0 then
    Index := Colors shr 4;
  // Text colour zero resolves to the text background, not the global border.
  if TextMode and (Index = 0) then
    Index := Colors and 15;
  Result := Color(Index);
end;

function TMSXVDP.BitmapPixel(X, Y, Page: Integer): TAlphaColor;
begin
  if FClocked then
    Exit(TimedBitmapPixel(X));
  var Width := DisplayDotWidth;
  var LineBytes := DotWidth * BitsPerPixel div 8;
  var SX := X;
  if FChip = VDPV9958 then
  begin
    SX := X + (Integer(FR[26] and $3F) * 8 - Integer(FR[27] and 7)) * (Width div 256);
    if FR[25] and 1 <> 0 then
    begin
      // R2 A15 enables the second horizontally adjacent page. H08 selects it.
      var PageBit := LineBytes * 256;
      var Enable := Page and PageBit;
      Page := Page and ($1FFFF xor PageBit);
      if (SX and Width <> 0) then
        Page := Page or Enable;
    end;
    SX := SX and (Width - 1);
  end;
  var PageY := Page div LineBytes;
  var BPP := BitsPerPixel;
  var Value := (DisplayByte(VideoAddress(SX, Y + PageY)) shr ((8 div BPP - 1 - (SX and (8 div BPP - 1))) * BPP)) and ((1 shl BPP) - 1);
  if (Mode in [20, 28]) and (FChip = VDPV9958) and (FR[25] and 8 <> 0) then
  begin
    // YJK display is 256 dots even when the command engine selects G6.
    // YJKColor uses logical byte addresses and its own 256-dot interpretation.
    Result := YJKColor(((Y + PageY) shl 8) or SX);
  end
  else if Mode = 28 then
    Result := DirectColor(Value)
  else if (Mode = 16) and (Value = 0) and (FR[8] and $20 = 0) then
    Result := PaletteColor((FR[7] shr ((1 - (X and 1)) * 2)) and 3)
  else
    Result := Color(Value);
end;

function TMSXVDP.HorizontalAdjust: Integer;
begin
  Result := FR[18] and 15;
  // The horizontal counter reloads on the next line, unlike palette writes.
  if FBeamLine >= 0 then
    Result := FLineAdjust and 15;
  if Result >= 8 then
    Dec(Result, 16);
  // YJK's conversion pipeline shifts both planes four low-resolution dots.
  var YJK := FR[25] and 8 <> 0;
  if FBeamLine >= 0 then
    YJK := FLineAdjust and $10 <> 0;
  if YJK then
    Dec(Result, 4);
end;

function TMSXVDP.VerticalAdjust: Integer;
begin
  Result := FR[18] shr 4;
  if Result >= 8 then
    Dec(Result, 16);
end;

procedure TMSXVDP.FlushRaster;
begin
  if ((FModel = MSX1) and not FClocked) or (FBeamLine < 0) or (FBeamLine >= ScreenHeight) then
    Exit;
  // One high-resolution output dot is two VDP clocks. Preserve pixels that
  // the beam has passed before changing a display register or palette entry.
  var X := EnsureRange((LineTickAt(FVideoClock) - 258) div 2, 0, 512);
  if X <= FRasterX then
    Exit;
  DrawRaster(FBeamLine, FRasterX, X, False);
  FRasterX := X;
end;

procedure TMSXVDP.DrawRaster(Y, First, Last: Integer; SpriteStatus: Boolean);
begin
  ComposeLine(Y, EnsureRange(First + HorizontalAdjust * 2, 0, 512),
    EnsureRange(Last + HorizontalAdjust * 2, 0, 512), SpriteStatus);
  var Row := Y;
  if Interlaced then
    Row := Y * 2 + Ord(FS[2] and 2 <> 0);
  var M := Mode;
  var Back := PaletteColor(FR[7] and 15);
  if M = 28 then
    Back := DirectColor(FR[7]);
  for var X := First to Last - 1 do
  begin
    var SX := X + HorizontalAdjust * 2;
    var C := Back;
    if M = 16 then
      C := PaletteColor((FR[7] shr ((1 - (X and 1)) * 2)) and 3);
    if (SX >= 0) and (SX < 512) then
      C := FScanline[SX];
    FOutput[Row * 512 + X] := C;
    if (FModel = MSX1) and (X and 1 = 0) then
      FPixels[Y * 256 + X div 2] := C;
  end;
end;

procedure TMSXVDP.RenderLine(Y: Integer);
begin
  if (FModel = MSX1) and not FClocked then
  begin
    inherited;
    Exit;
  end;
  if (Y < 0) or (Y >= ScreenHeight) then
    Exit;
  var First := 0;
  if Y = FBeamLine then
    First := FRasterX;
  DrawRaster(Y, First, 512, not FClocked);
  if FModel = MSX1 then
  begin
    FStatus := FS[0];
    FSpriteIndex := FS[0] and $1F;
  end;
end;

procedure TMSXVDP.ComposeLine(Y, First, Last: Integer; SpriteStatus: Boolean);
begin
  Inc(Y, VerticalAdjust);
  var M := Mode;
  var Back := PaletteColor(FR[7] and 15);
  if M = 28 then
    Back := DirectColor(FR[7]);
  for var X := 0 to 511 do
    if M = 16 then
      FScanline[X] := PaletteColor((FR[7] shr ((1 - (X and 1)) * 2)) and 3)
    else
      FScanline[X] := Back;
  if (FR[1] and $40 <> 0) and (Y >= 0) and (Y < ScreenHeight) then
  begin
    var SY := (Y + Integer(FR[23])) and 255;
    if FShowBackground then
    begin
      if M in [12, 16, 20, 28] then
      begin
        var Page := (Integer(FR[2]) and $60) shl 10;
        if M in [20, 28] then
          Page := (Integer(FR[2]) and $20) shl 11;
        if FBlinkOn or ((FR[9] and 4 <> 0) and (FS[2] and 2 = 0)) then
          Page := Page and ($1FFFF xor (DotWidth * BitsPerPixel div 8 * 256));
        var Scale := 512 div DisplayDotWidth;
        for var X := First div Scale to (Last + Scale - 1) div Scale - 1 do
        begin
          var C := BitmapPixel(X, SY, Page);
          if DisplayDotWidth = 256 then
          begin
            FScanline[X * 2] := C;
            FScanline[X * 2 + 1] := C;
          end
          else
            FScanline[X] := C;
        end;
      end
      else
        for var X := First to Last - 1 do
          FScanline[X] := PatternPixel(X, SY, M);
    end;
    if not (M in [1, 9]) and (FR[8] and 2 = 0) then
      RenderSprites(Y, M in [8, 12, 16, 20, 28], SpriteStatus);
    if (FChip = VDPV9958) and (FR[25] and 2 <> 0) then
      for var X := 0 to 15 do
        if M = 16 then
          FScanline[X] := PaletteColor((FR[7] shr ((1 - (X and 1)) * 2)) and 3)
        else
          FScanline[X] := Back;
  end;
end;

procedure TMSXVDP.RenderSprites(Y: Integer; Mode2: Boolean; UpdateStatus: Boolean);
begin
  var Occupied, Drawn: array[0..255] of Boolean;
  var Owners, Indices: array[0..255] of Integer;
  FillChar(Occupied, SizeOf(Occupied), 0);
  FillChar(Drawn, SizeOf(Drawn), 0);
  FillChar(Owners, SizeOf(Owners), $FF);
  FillChar(Indices, SizeOf(Indices), 0);
  var Group := -1;
  var SAT := ((Integer(FR[11] and 3) shl 15) or (Integer(FR[5]) shl 7)) and $1FE00;
  if not Mode2 then
    SAT := ((Integer(FR[11] and 3) shl 15) or (Integer(FR[5]) shl 7)) and $1FF80;
  var CT := SAT and $1FC00;
  var PG := Integer(FR[6] and $3F) shl 11;
  var Size := 8;
  if FR[1] and 2 <> 0 then
    Size := 16;
  var Zoom := 1;
  if FR[1] and 1 <> 0 then
    Zoom := 2;
  var Count := 0;
  var CollisionX := 256;
  for var SlotIndex := 0 to 31 do
  begin
    if FClocked and (SlotIndex >= FSpriteCount) then
      Break;
    var I := SlotIndex;
    if FClocked then
      I := FSpriteCurrent[SlotIndex].Index;
    var SY := Integer(VideoByte(PhysicalAddress(SAT + I * 4)));
    if FClocked then
      SY := FSpriteCurrent[SlotIndex].Y;
    if (Mode2 and (SY = 216)) or (not Mode2 and (SY = 208)) then
      Break;
    var SpriteOffset := SpriteRow(Y, SY, I);
    if not FClocked and (SpriteOffset >= Size * Zoom) then
      Continue;
    Inc(Count);
    var Limit := 4;
    if Mode2 then
      Limit := 8;
    if Count = Limit + 1 then
    begin
      if UpdateStatus and (FS[0] and $40 = 0) then
        FS[0] := (FS[0] and $A0) or $40 or I;
      if not FRemoveSpriteLimit then
        Break;
    end;
    var Row := SpriteOffset div Zoom;
    var Attr := FVideo[PhysicalAddress(CT + I * 16 + Row)];
    if not Mode2 then
      Attr := FVideo[PhysicalAddress(SAT + I * 4 + 3)] and $8F;
    if FClocked then
      Attr := FSpriteCurrent[SlotIndex].Attr;
    if Attr and $40 = 0 then
      Group := I;
    var SX := Integer(FVideo[PhysicalAddress(SAT + I * 4 + 1)]);
    if FClocked then
      SX := FSpriteCurrent[SlotIndex].X;
    if Attr and $80 <> 0 then
      Dec(SX, 32);
    var Code := Integer(FVideo[PhysicalAddress(SAT + I * 4 + 2)]);
    if Size = 16 then
      Code := Code and $FC;
    for var PX := 0 to Size - 1 do
    begin
      var Pattern := FVideo[PhysicalAddress(PG + Code * 8 + Row + (PX div 8) * 16)];
      if FClocked then
        if PX < 8 then
          Pattern := FSpriteCurrent[SlotIndex].Left
        else
          Pattern := FSpriteCurrent[SlotIndex].Right;
      if Pattern and ($80 shr (PX and 7)) = 0 then
        Continue;
      for var Z := 0 to Zoom - 1 do
      begin
        var X := SX + PX * Zoom + Z;
        if (X < 0) or (X > 255) then
          Continue;
        if (Attr and 15 = 0) and (FR[8] and $20 = 0) then
          Continue;
        if Occupied[X] and (Attr and $60 = 0) and (Count <= Limit) then
          CollisionX := Min(CollisionX, X);
        if Attr and $60 = 0 then
          Occupied[X] := True;
        var Visible := not Drawn[X];
        var Index := Integer(Attr and 15);
        if Attr and $40 <> 0 then
        begin
          Visible := Drawn[X] and (Owners[X] = Group) and (Group >= 0);
          Index := Index or Indices[X];
        end;
        if FShowSprites and Visible then
        begin
          FScanline[X * 2] := SpriteColor(Index, 0);
          FScanline[X * 2 + 1] := SpriteColor(Index, 1);
          Drawn[X] := True;
          Owners[X] := Group;
          Indices[X] := Index;
        end;
      end;
    end;
  end;
  // The beam encounters the leftmost coincidence first. Coordinates stay
  // latched with C until status 0 is acknowledged, including subsequent lines.
  if UpdateStatus and (CollisionX < 256) and (FS[0] and $20 = 0) then
  begin
    FS[0] := FS[0] or $20;
    if FR[8] and $C0 = 0 then
    begin
      FS[3] := (CollisionX + 12) and $FF;
      FS[4] := $FE or ((CollisionX + 12) shr 8);
      FS[5] := (Y + 8) and $FF;
      FS[6] := $FC or ((Y + 8) shr 8) or (FS[2] and 2);
    end;
  end;
end;

procedure TMSXVDP.StartCommand(Value: Byte);
begin
  Inc(FCommandSerial);
  FCommand := Value shr 4;
  FS[2] := FS[2] and $7E;
  FCommandDue := High(Int64);
  FCommandPhase := 0;
  FCachedDestination := False;
  if FCommand = 0 then
    Exit;
  if (Mode < 12) and not ((FChip = VDPV9958) and (FR[25] and $40 <> 0)) then
  begin
    FCommand := 0;
    Exit;
  end;
  FSX := Integer(FR[32]) or ((Integer(FR[33]) and 1) shl 8);
  FSY := Integer(FR[34]) or ((Integer(FR[35]) and 3) shl 8);
  FDX := Integer(FR[36]) or ((Integer(FR[37]) and 1) shl 8);
  FDY := Integer(FR[38]) or ((Integer(FR[39]) and 3) shl 8);
  FNX := Integer(FR[40]) or ((Integer(FR[41]) and 1) shl 8);
  FNY := Integer(FR[42]) or ((Integer(FR[43]) and 3) shl 8);
  if FCommand >= 8 then
  begin
    if FNX = 0 then
      FNX := 512;
    if FNY = 0 then
      FNY := 1024;
  end;
  FLineError := Max(0, (FNX - 1) div 2);
  FTX := 1;
  FTY := 1;
  if FR[45] and 4 <> 0 then
    FTX := -1;
  if FR[45] and 8 <> 0 then
    FTY := -1;
  FCX := 0;
  FCY := 0;
  if (FCommand >= 8) and (FTY < 0) then
  begin
    if FCommand <> $A then
      FNY := Min(FNY, FDY + 1);
    if FCommand in [9, $A, $D, $E] then
      FNY := Min(FNY, FSY + 1);
  end;
  if FCommand >= $C then
  begin
    var Pixels := 8 div CommandPixelBits;
    FSX := FSX and not (Pixels - 1);
    FDX := FDX and not (Pixels - 1);
    FNX := FNX and not (Pixels - 1);
    if FNX = 0 then
      FNX := CommandWidth;
  end;
  FS[2] := FS[2] or 1;
  if (FCommand in [$B, $F]) and not FTransferPending then
    FS[2] := FS[2] or $80
  else
    ScheduleCommand(CommandStartDelay(FCommand), False);
end;

procedure TMSXVDP.NextCommand;
begin
  var UnitWidth := 1;
  if FCommand >= $C then
    UnitWidth := 8 div CommandPixelBits;
  Inc(FCX, UnitWidth);
  var Width := FNX;
  if FCommand = $E then
    if FTX < 0 then
      Width := FDX + UnitWidth
    else
      Width := CommandWidth - FDX;
  var SourceEdge := (FCommand in [9, $A, $D]) and
    ((FSX + FCX * FTX < 0) or (FSX + FCX * FTX >= CommandWidth));
  var DestEdge := (FCommand <> $A) and
    ((FDX + FCX * FTX < 0) or (FDX + FCX * FTX >= CommandWidth));
  if (FCX >= Width) or SourceEdge or DestEdge then
  begin
    FCX := 0;
    Inc(FCY);
    if FCommand in [9, $A, $D, $E] then
      SetCommandY(34, FSY + FCY * FTY);
    if FCommand <> $A then
      SetCommandY(38, FDY + FCY * FTY);
    var Remaining := (Integer(FR[42]) or (Integer(FR[43] and 3) shl 8)) - 1;
    SetCommandY(42, Remaining);
  end;
  if FCY >= FNY then
  begin
    FCommand := 0;
    FS[2] := FS[2] and $7E;
  end;
end;

procedure TMSXVDP.CommandUnit(Value: Byte);
begin
  var X := FDX + FCX * FTX;
  var Y := FDY + FCY * FTY;
  var SX := FSX + FCX * FTX;
  case FCommand of
    4:
      begin
        FS[7] := CommandDot(FSX, FSY);
        FR[44] := FS[7];
        FCommand := 0;
      end;
    5:
      begin
        CommandPutDot(FDX, FDY, CommandArgument(44));
        FCommand := 0;
      end;
    6:
      begin
        var Found := CommandDot(SX, FSY) = (CommandArgument(44) and ((1 shl CommandPixelBits) - 1));
        if CommandArgument(45) and 2 <> 0 then
          Found := not Found;
        if Found then
        begin
          FS[2] := FS[2] or $10;
          FCommand := 0;
        end
        else
        begin
          Inc(FCX);
          SX := FSX + FCX * FTX;
          if (SX and CommandWidth) <> 0 then
            FCommand := 0;
        end;
        FS[8] := SX and $FF;
        FS[9] := $FE or ((SX shr 8) and 1);
      end;
    7:
      begin
        if CommandArgument(45) and 1 = 0 then
        begin
          CommandPutDot(X, Y, CommandArgument(44));
          Inc(FCX);
          // X-major LINE stops before advancing Y after its last dot.
          if (FCX > FNX) or ((FDX + FCX * FTX) and CommandWidth <> 0) then
            FCommand := 0
          else
          begin
            if FLineError < FNY then
            begin
              Inc(FLineError, FNX);
              Inc(FCY);
            end;
            FLineError := (FLineError - FNY) and 1023;
            SetCommandY(38, FDY + FCY * FTY);
            if (FTY < 0) and (FDY - FCY < 0) then
              FCommand := 0;
          end;
        end
        else
        begin
          CommandPutDot(FDX + FCY * FTX, FDY + FCX * FTY, CommandArgument(44));
          Inc(FCX);
          SetCommandY(38, FDY + FCX * FTY);
          if FLineError < FNY then
          begin
            Inc(FLineError, FNX);
            Inc(FCY);
          end;
          FLineError := (FLineError - FNY) and 1023;
          if (FCX > FNX) or ((FDX + FCY * FTX) and CommandWidth <> 0) or
            ((FTY < 0) and (FDY - FCX < 0)) then
            FCommand := 0;
        end;
      end;
    8:
      begin
        CommandPutDot(X, Y, CommandArgument(44));
        NextCommand;
      end;
    9:
      begin
        CommandPutDot(X, Y, FSourceByte);
        NextCommand;
      end;
    $A:
      NextCommand;
    $B:
      begin
        CommandPutDot(X, Y, Value);
        NextCommand;
      end;
    $C, $D, $E, $F:
      begin
        if not FCommandCommitting and (CommandArgument(45) and $20 = 0) then
        begin
          FlushRaster;
          var A := CommandVideoAddress(X, Y);
          if FCommand = $C then
            FVideo[A] := CommandArgument(44)
          else if FCommand = $F then
            FVideo[A] := Value
          else
            FVideo[A] := FSourceByte;
          if A < $4000 then
            FVRAM[A] := FVideo[A];
        end;
        NextCommand;
      end;
  else
    FCommand := 0;
  end;
  if FCommand = 0 then
    FS[2] := FS[2] and $7E;
end;

function TMSXVDP.NextAccessSlot(AfterTicks: Integer): Int64;
begin
  Result := VRAMAccessSlot(FVideoClock, AfterTicks);
end;

function TMSXVDP.VRAMAccessSlot(Time: Int64; AfterTicks: Integer): Int64;

  function Slot(const Slots: array of Word; Base: Int64; Dot: Integer; UntilDot: Integer; Shift: Integer = 0; Kind: Integer = -1): Int64;
  begin
    for var S in Slots do
    begin
      var At := Integer(S);
      if LineClocksAt(Base) = 1365 then
        At := ShortRAMTick(At, Kind);
      Inc(At, Shift);
      if (At >= Dot) and (At < UntilDot) then
        Exit(Base + At);
    end;
    Result := High(Int64);
  end;

begin
  var Earliest := Time + AfterTicks;
  var LineBase := LineBaseAt(Earliest);
  var Dot := Integer(Earliest - LineBase);
  repeat
    var Line := FBeamLine + Integer(LineSerialAt(LineBase) - FLineTiming[FLineTimingHead].Serial);
    Line := (Line + VerticalAdjust + TotalLines) mod TotalLines;
    var Enabled := (FR[1] and $40 <> 0) and (Line < ScreenHeight);
    if not FClocked then
      Enabled := (FR[1] and $40 <> 0) and (FS[2] and $40 = 0);
    if FModel = MSX1 then
    begin
      if not Enabled then
        Result := Slot(MSXSlotsTMSBlank, LineBase, Dot, LineClocksAt(LineBase))
      else if Mode = 1 then
        Result := Slot(MSXSlotsTMSText, LineBase, Dot, LineClocksAt(LineBase))
      // VATT's measurements on real MSX1s contradict the inferred extra
      // Multicolor slots in the old hand-drawn diagram: MC needs 27 T too.
      else
        Result := Slot(MSXSlotsTMSPattern, LineBase, Dot, LineClocksAt(LineBase));
    end
    // VATT measurements: BL/SD do not free the character/text access slots.
    else if Mode in [1, 9] then
      Result := Slot(MSXSlotsText, LineBase, Dot, LineClocksAt(LineBase), 0, 4)
    else if Mode < 12 then
      Result := Slot(MSXSlotsCharacter, LineBase, Dot, LineClocksAt(LineBase), 0, 3)
    else
    begin
      var UntilDot := RAMWindowEnd(LineBase + Dot);
      var Adjust := RAMAdjustAt(LineBase);
      case CPUTimingKind(LineBase + Dot) of
        0:
          Result := Slot(MSXSlotsBlankR18[Adjust], LineBase, Dot, UntilDot, 0, 0);
        1:
          Result := Slot(MSXSlotsNoSpritesR18[Adjust], LineBase, Dot, UntilDot, 0, 1);
      else
        Result := Slot(MSXSlotsSpritesR18[Adjust], LineBase, Dot, UntilDot, RAMPostShift(LineBase + Dot), 2);
      end;
      if (Result = High(Int64)) and (UntilDot < LineClocksAt(LineBase)) then
      begin
        Dot := UntilDot;
        Continue;
      end;
    end;
    if Result <> High(Int64) then
      Exit;
    Inc(LineBase, LineClocksAt(LineBase));
    Dot := 0;
  until False;
end;

procedure TMSXVDP.QueueCPU(Write: Boolean; Value: Byte);
begin
  if Write then
    FBuffer := Value;
  if FModel = MSX1 then
  begin
    FCPUWrite := Write;
    if not FCPUPending then
    begin
      FCPUPending := True;
      FCPUReady := FVideoClock + 28;
      FCPUDue := NextAccessSlot(28);
    end;
    Exit;
  end;
  // Measured pin-to-request delay: 10.9 +/- 0.2 master clocks. MD.Z80's
  // callback is at the end of the I/O cycle, rather than openMSX's T2 anchor.
  var Request := FVideoClock + 11;
  if not CPURequestAllowed(Request) then
    Exit; // old request owns its data/type
  var Slot := CPUAccessSlot(Request);
  var Dummy := CPUAccessSlot(Request, True);
  if (Dummy <> Slot) and (Dummy - Request >= 18) and (Dummy - Request < 22) then
    FCPUDummy := Dummy;
  FCPUGranted := Slot;
  FCPUGrantedLate := CPULateSlot(Slot);
  if FChip = VDPV9958 then
    FCPUWaitLatch := True;
  if not FCPUPending then
  begin
    FCPUPending := True;
    FCPUPhase := 0;
    FCPUReady := Request;
    FCPUDue := Slot;
    FCPUWrite := Write;
    FCPUValue := Value;
  end
  else
  begin
    if FCPUNextSlot <> High(Int64) then
      raise EInvalidOpException.Create('MSX CPU request queue exceeds physical I/O pace');
    FCPUNextSlot := Slot;
    FCPUNextReady := Request;
    FCPUNextWrite := Write;
    FCPUNextValue := Value;
  end;
end;

procedure TMSXVDP.CPUAccess;
begin
  if FCPUPhase = 0 then
  begin
    FCPUAccessStart := FVideoClock;
    FCPUAccessEnabled := (FModel = MSX1) or (FR[45] and $40 = 0);
    FCPUAddress := PhysicalAddress(FPointer);
    if FModel = MSX1 then
      FCPUAddress := TMSAddress(FAddress);
    if FModel = MSX1 then
      FCPUValue := FBuffer;
    FCPUAccessWrite := FCPUWrite;
    FCPUPhase := 1;
    if FModel = MSX1 then
      Inc(FCPUDue, 4)
    else
      Inc(FCPUDue, VRAMDataDelay(FVideoClock));
    Exit;
  end;
  if FCPUPhase = 1 then
  begin
    var A := FCPUAddress;
    if Assigned(FVRAMTrace) then
    begin
      var TraceValue := FCPUValue;
      if not FCPUAccessWrite then
        if FModel = MSX1 then
          TraceValue := FVRAM[A]
        else if not FCPUAccessEnabled then
          TraceValue := $FF
        else
          TraceValue := VideoByte(A);
      FVRAMTrace(FCPUAccessStart, False, FCPUAccessWrite, A, TraceValue);
    end;
  // The internal VRAM data-sample strobe also clears the WAIT latch.
  // This uses our existing functional data phase, not a measured pin delay.
    FCPUWaitLatch := False;
    if FCPUAccessWrite then
    begin
      if FCPUAccessEnabled then
      begin
        FlushRaster;
        FVideo[A] := FCPUValue;
        if A < $4000 then
          FVRAM[A] := FCPUValue;
      end;
    end;
    if not FCPUAccessWrite then
      if FModel = MSX1 then
        FBuffer := FVRAM[A]
      else if not FCPUAccessEnabled then
        FBuffer := $FF
      else
        FBuffer := VideoByte(A);
    FCPUPhase := 2;
    if FModel = MSX1 then
      Inc(FCPUDue, 4)
    else
      Inc(FCPUDue, 3);
    Exit;
  end;
  if FModel = MSX1 then
  begin
    FAddress := (FAddress + 1) and $3FFF;
    FReadBuffer := FBuffer;
  end
  else
    IncrementAddress;
  FCPUPhase := 0;
  if FCPUNextSlot <> High(Int64) then
  begin
    FCPUDue := FCPUNextSlot;
    FCPUReady := FCPUNextReady;
    FCPUWrite := FCPUNextWrite;
    FCPUValue := FCPUNextValue;
    FCPUNextSlot := High(Int64);
  end
  else
  begin
    FCPUPending := False;
    FCPUDue := High(Int64);
  end;
end;

procedure TMSXVDP.ScheduleCommand(AfterTicks: Integer; AfterAccess: Boolean);
begin
  ScheduleCommandFrom(FVideoClock, AfterTicks, AfterAccess);
end;

procedure TMSXVDP.Advance(Cycles: Integer);
begin
  AdvanceMasterClocks(Int64(Cycles) * 6);
end;

procedure TMSXVDP.AdvanceMasterClocks(Clocks: Int64);
begin
  if Clocks < 0 then
    raise EArgumentOutOfRangeException.Create('Negative VDP clock advance');
  var Target := FVideoClock + Clocks;
  if FClocked and (FFetchMode <> Mode) then
  begin
    BuildFetchEvents;
    ScheduleFetch;
  end;
  while True do
  begin
    var Due := Min(FNextVideoData, Min(FCommandDataDue, Min(FCPUDummy, Min(FNextSpriteStatus, Min(FNextSpritePixel, Min(FCommandDue, Min(FCPUDue, FNextFetch)))))));
    if Due > Target then
      Break;
    FVideoClock := Due;
    if FCPUDummy = Due then
    begin
      if FCommandDue = Due then
        FCommandDue := NextAccessSlot(1);
      if Assigned(FVRAMTrace) then
        FVRAMTrace(Due, True, False, $1FFFF, VideoByte($1FFFF));
      FCPUDummy := High(Int64);
    end;
    if FCPUDue = Due then
    begin
      if (FCPUPhase = 0) and (FCommandDue = Due) then
        FCommandDue := NextAccessSlot(1);
      CPUAccess;
    end
    else if FCommandDue = Due then
      CommandAccess;
    if FCommandDataDue = Due then
      CommandData;
    if FNextVideoData = Due then
      CompleteVideoAccess;
    if FNextFetch = Due then
    begin
      FetchAccess;
      ScheduleFetch;
    end;
    if FNextSpriteStatus = Due then
    begin
      if FS[0] and $C0 = 0 then
        if RaiseStatus($40) then
          SetSpriteStatus((FS[0] and $E0) or FSpriteStatusValue);
      FNextSpriteStatus := High(Int64);
    end;
    if FNextSpritePixel = Due then
    begin
      SpritePixel;
      ScheduleSpritePixel;
    end;
  end;
  FVideoClock := Target;
  FHorizontalCycles := LineTickAt(Target) div 6;
  FS[2] := FS[2] and $DF;
  var Right := 1282 - HorizontalAdjust * 4;
  var Blank := 312;
  if Mode in [1, 9] then
  begin
    Dec(Right, 28);
    Blank := 404;
  end;
  // Shortening consumes trailing blank clocks; the left counter phase stays fixed.
  Dec(Blank, 1368 - LineClocksAt(Target));
  // HR has its own counter phase; it does not equal the visible RGB interval.
  if (LineTickAt(Target) + LineClocksAt(Target) - Right) mod LineClocksAt(Target) < Blank then
    FS[2] := FS[2] or $20;
end;

procedure TMSXVDP.SerializeState(State: TStateArchive);
begin
  var Model := FModel;
  State.Field(Model, SizeOf(Model));
  if State.Loading and (Model <> FModel) then
    raise EReadError.Create('MSX VDP model differs');
  var SavedChip := FChip;
  var SavedPAL := FMSX1PAL;
  State.Field(SavedChip, SizeOf(SavedChip));
  State.Field(SavedPAL, SizeOf(SavedPAL));
  if (SavedChip <> FChip) or (SavedPAL <> FMSX1PAL) then
    raise EReadError.Create('MSX VDP revision differs');
  State.Field(FStatusReadUntil, SizeOf(FStatusReadUntil));
  State.Field(FStatusSetClock, SizeOf(FStatusSetClock));
  State.Field(FHorizontalSetClock, SizeOf(FHorizontalSetClock));
  if FModel = MSX1 then
  begin
    inherited;
    State.Field(FVideoClock, SizeOf(FVideoClock));
    State.Field(FBeamLine, SizeOf(FBeamLine));
    State.Field(FRasterX, SizeOf(FRasterX));
    State.Field(FBuffer, 1);
    if State.Loading then
    begin
      Move(FRegisters, FR, 8);
      FS[0] := FStatus;
    end;
  end
  else
  begin
    State.Field(FStatus, SizeOf(FStatus));
    State.Field(FSpriteIndex, SizeOf(FSpriteIndex));
    State.Field(FPixels[0], 256 * 192 * SizeOf(TAlphaColor));
    State.Field(FVideo, SizeOf(FVideo));
    State.Field(FR, SizeOf(FR));
    State.Field(FS, SizeOf(FS));
    State.Field(FPalette, SizeOf(FPalette));
    State.Field(FPointer, SizeOf(FPointer));
    State.Field(FBuffer, SizeOf(FBuffer));
    State.Field(FFirstControl, SizeOf(FFirstControl));
    State.Field(FFirstPalette, SizeOf(FFirstPalette));
    State.Field(FPending, SizeOf(FPending));
    State.Field(FPalettePending, SizeOf(FPalettePending));
    State.Field(FCommand, SizeOf(FCommand));
    State.Field(FVideoClock, SizeOf(FVideoClock));
    State.Field(FCommandDue, SizeOf(FCommandDue));
    State.Field(FCommandPhase, SizeOf(FCommandPhase));
    State.Field(FTransferPending, SizeOf(FTransferPending));
    State.Field(FTransferValue, SizeOf(FTransferValue));
    State.Field(FSourceByte, SizeOf(FSourceByte));
    State.Field(FDestByte, SizeOf(FDestByte));
    State.Field(FDestAddress, SizeOf(FDestAddress));
    State.Field(FCachedDestination, SizeOf(FCachedDestination));
    State.Field(FHorizontalCycles, SizeOf(FHorizontalCycles));
    State.Field(FBeamLine, SizeOf(FBeamLine));
    State.Field(FRasterX, SizeOf(FRasterX));
    State.Field(FLineAdjust, SizeOf(FLineAdjust));
    State.Field(FCX, SizeOf(FCX));
    State.Field(FCY, SizeOf(FCY));
    State.Field(FSX, SizeOf(FSX));
    State.Field(FSY, SizeOf(FSY));
    State.Field(FDX, SizeOf(FDX));
    State.Field(FDY, SizeOf(FDY));
    State.Field(FNX, SizeOf(FNX));
    State.Field(FNY, SizeOf(FNY));
    State.Field(FTX, SizeOf(FTX));
    State.Field(FTY, SizeOf(FTY));
    State.Field(FOutput[0], Length(FOutput) * SizeOf(TAlphaColor));
    State.Field(FLineError, SizeOf(FLineError));
    State.Field(FBlinkOn, SizeOf(FBlinkOn));
    State.Field(FBlinkFrames, SizeOf(FBlinkFrames));
    if State.Loading then
    begin
      Move(FVideo, FVRAM, SizeOf(FVRAM));
      Move(FR, FRegisters, SizeOf(FRegisters));
    end;
    if State.Loading and ((FPointer < 0) or (FPointer > $1FFFF) or
      (FBlinkFrames < 0) or (FBlinkFrames > 150) or
      (FLineAdjust and $E0 <> 0) or (FBeamLine < -1) or (FBeamLine >= 313) or (FRasterX < 0) or (FRasterX > 512) or
      (FHorizontalCycles < 0) or (FHorizontalCycles >= 228) or
      (FVideoClock < 0) or (FCommandDue < FVideoClock) or
      (FCommandPhase < 0) or (FCommandPhase > 2) or (FDestAddress < 0) or (FDestAddress > $1FFFF) or
      (FCommand < 0) or (FCommand > 15) or (FNX < 0) or (FNX > 512) or
      (FNY < 0) or (FNY > 1024) or (FCX < 0) or (FCX > 1024) or
      (FCY < 0) or (FCY > 1024) or (Abs(FTX) <> 1) or (Abs(FTY) <> 1)) then
      raise EReadError.Create('Invalid MSX VDP state');
  end;
  var Clocked := FClocked;
  State.Field(Clocked, SizeOf(Clocked));
  if Clocked <> FClocked then
    raise EReadError.Create('VDP clock connection differs');
  State.Field(FCPUWrite, SizeOf(FCPUWrite));
  State.Field(FCPUPending, SizeOf(FCPUPending));
  State.Field(FCPUDue, SizeOf(FCPUDue));
  State.Field(FCPUPhase, 1);
  State.Field(FCPUValue, 1);
  State.Field(FCPUAddress, SizeOf(FCPUAddress));
  State.Field(FCPUAccessWrite, SizeOf(FCPUAccessWrite));
  State.Field(FNextFetch, SizeOf(FNextFetch));
  State.Field(FFetchMode, SizeOf(FFetchMode));
  State.Field(FCPUWaitLatch, SizeOf(FCPUWaitLatch));
  State.Field(FNextSpritePixel, SizeOf(FNextSpritePixel));
  State.Field(FCPUReady, SizeOf(FCPUReady));
  State.Field(FCommandReady, SizeOf(FCommandReady));
  State.Field(FNextSpriteStatus, SizeOf(FNextSpriteStatus));
  State.Field(FSpriteStatusValue, 1);
  State.Field(FSpriteCounter, 1);
  State.Field(FSpriteCollision, SizeOf(FSpriteCollision));
  State.Field(FSpriteCollisionDirty, SizeOf(FSpriteCollisionDirty));
  State.Field(FBitmapBytes, SizeOf(FBitmapBytes));
  State.Field(FNames, SizeOf(FNames));
  State.Field(FPatterns, SizeOf(FPatterns));
  State.Field(FColors, SizeOf(FColors));
  State.Field(FDisplayKeys, SizeOf(FDisplayKeys));
  State.Field(FDisplayBytes, SizeOf(FDisplayBytes));
  State.Field(FSpriteCurrent, SizeOf(FSpriteCurrent));
  State.Field(FSpriteNext, SizeOf(FSpriteNext));
  State.Field(FSpriteCount, SizeOf(FSpriteCount));
  State.Field(FNextSpriteCount, SizeOf(FNextSpriteCount));
  State.Field(FSpriteOverflow, 1);
  State.Field(FNextSpriteOverflow, 1);
  State.Field(FSpriteStop, SizeOf(FSpriteStop));
  State.Field(FStatusHistory, SizeOf(FStatusHistory));
  State.Field(FStatusHistoryHead, SizeOf(FStatusHistoryHead));
  State.Field(FCPUNextSlot, SizeOf(FCPUNextSlot));
  State.Field(FCPUNextReady, SizeOf(FCPUNextReady));
  State.Field(FCPUGranted, SizeOf(FCPUGranted));
  State.Field(FCPUDummy, SizeOf(FCPUDummy));
  State.Field(FCPUNextWrite, SizeOf(FCPUNextWrite));
  State.Field(FCPUGrantedLate, SizeOf(FCPUGrantedLate));
  State.Field(FCPUNextValue, 1);
  State.Field(FCPUAccessStart, SizeOf(FCPUAccessStart));
  State.Field(FCPUAccessEnabled, SizeOf(FCPUAccessEnabled));
  State.Field(FCommandDataDue, SizeOf(FCommandDataDue));
  State.Field(FCommandRAS, SizeOf(FCommandRAS));
  State.Field(FCommandSerial, SizeOf(FCommandSerial));
  State.Field(FCommandBusSerial, SizeOf(FCommandBusSerial));
  State.Field(FCommandBusAddress, SizeOf(FCommandBusAddress));
  State.Field(FCommandBusMode, SizeOf(FCommandBusMode));
  State.Field(FCommandBusKind, 1);
  State.Field(FCommandBusValue, 1);
  State.Field(FCommandBusShift, 1);
  State.Field(FCommandBusMask, 1);
  State.Field(FCommandBusR44, 1);
  State.Field(FCommandBusR45, 1);
  State.Field(FCommandBusR46, 1);
  State.Field(FCommandBusEnabled, SizeOf(FCommandBusEnabled));
  State.Field(FPreviousLineAdjust, 1);
  State.Field(FCommandRequestTime, SizeOf(FCommandRequestTime));
  State.Field(FCommandWork, SizeOf(FCommandWork));
  State.Field(FLineStartClock, SizeOf(FLineStartClock));
  State.Field(FLineClocks, SizeOf(FLineClocks));
  State.Field(FLineTiming, SizeOf(FLineTiming));
  State.Field(FLineTimingHead, SizeOf(FLineTimingHead));
  State.Field(FLineTimingCount, SizeOf(FLineTimingCount));
  State.Field(FVideoReads, SizeOf(FVideoReads));
  State.Field(FNextVideoData, SizeOf(FNextVideoData));
  if State.Loading then
  begin
    var NextVideo := High(Int64);
    for var Q in FVideoReads do
      if Q.Due <> High(Int64) then
      begin
        if (Q.RAS < 0) or (Q.RAS > Q.CAS) or (Q.CAS > FVideoClock) or
          (Q.Due < FVideoClock) or (Q.Due - Q.CAS < 1) or (Q.Due - Q.CAS > 4) or
          (Q.Address < 0) or (Q.Address > $1FFFF) or not (Q.Kind in [1, 5, 6, 7]) or
          ((Q.Kind = 1) and ((Q.Index > 263) or not (Q.Flags in [0, 2]))) or
          ((Q.Kind = 5) and ((Q.Index > 32) or ((Q.Index = 32) and (Q.Flags <> 2)) or not (Q.Flags in [0, 2]))) or
          ((Q.Kind = 6) and ((Q.Index > 63) or (Q.Index and 7 > 5) or (Q.Flags > 3))) or
          ((Q.Kind = 7) and ((Q.Index > 11) or (Q.Flags <> 2))) then
          raise EReadError.Create('Invalid VDP video-read latch');
        NextVideo := Min(NextVideo, Q.Due);
      end;
    if NextVideo <> FNextVideoData then
      raise EReadError.Create('Invalid VDP video data deadline');
    if (FPreviousLineAdjust and $E0 <> 0) or (FCommandRequestTime < 0) or
      (FCommandRequestTime > FVideoClock) or (FCommandWork < 0) or (FCommandWork > 512) then
      raise EReadError.Create('Invalid VDP memory-clock request');
    if ((FLineClocks <> 1365) and (FLineClocks <> 1368)) or
      (FLineTimingHead < 0) or (FLineTimingHead > High(FLineTiming)) or
      (FLineTimingCount < 1) or (FLineTimingCount > Length(FLineTiming)) then
      raise EReadError.Create('Invalid VDP line timing history');
    for var I := 0 to FLineTimingCount - 1 do
    begin
      var P := (FLineTimingHead - I + Length(FLineTiming)) mod Length(FLineTiming);
      var L := FLineTiming[P];
      if (L.Start < 0) or (L.Start > FLineStartClock) or ((L.Clocks <> 1365) and (L.Clocks <> 1368)) or
        (L.Adjust and $E0 <> 0) or (L.Serial < 0) then
        raise EReadError.Create('Invalid VDP historical line');
      if I > 0 then
      begin
        var N := FLineTiming[(P + 1) mod Length(FLineTiming)];
        if (L.Start >= N.Start) or (L.Serial >= N.Serial) then
          raise EReadError.Create('Unordered VDP line history');
      end;
    end;
    if (FLineTiming[FLineTimingHead].Start <> FLineStartClock) or
      (FLineTiming[FLineTimingHead].Clocks <> FLineClocks) or
      (FLineTiming[FLineTimingHead].Adjust <> FLineAdjust) then
      raise EReadError.Create('VDP current line timing differs');
    if (FLineStartClock < 0) or (FLineStartClock > FVideoClock) then
      raise EReadError.Create('Invalid VDP scanline clock origin');
    FCommandCommitting := False;
    if (FCPUAccessStart < 0) or (FCPUAccessStart > FVideoClock) or (FCommandDataDue < FVideoClock) or
      (FCommandRAS < 0) or (FCommandRAS > FVideoClock) or (FCommandSerial < 0) or
      (FCommandBusSerial < 0) or (FCommandBusSerial > FCommandSerial) or
      (FCommandBusAddress < 0) or (FCommandBusAddress > $1FFFF) or (FCommandBusMode < 0) or (FCommandBusMode > 31) or
      (FCommandBusKind > 4) or (FCommandBusShift > 6) or not (FCommandBusMask in [0, 3, 15, 255]) then
      raise EReadError.Create('Invalid VDP RAM data phase');
    if (FCommandDataDue <> High(Int64)) and not (FCommandDataDue - FCommandRAS in [3, 4]) then
      raise EReadError.Create('Invalid VDP RAM data deadline');
    if (FCPUNextSlot < FVideoClock) or (FCPUDummy < FVideoClock) or (FCPUGranted < -1) or (FCPUNextReady < 0) or
      ((FCPUNextSlot <> High(Int64)) and not FCPUPending) then
      raise EReadError.Create('Invalid MSX CPU request queue');
    if (FStatusHistoryHead < 0) or (FStatusHistoryHead > High(FStatusHistory)) then
      raise EReadError.Create('Invalid MSX VDP status history index');
    for var I := 0 to High(FStatusHistory) do
      if (FStatusHistory[I].Clock < -1) or (FStatusHistory[I].Clock > FVideoClock) then
        raise EReadError.Create('Invalid MSX VDP status history time');
    if (FStatusReadUntil < -1) or (FStatusReadUntil > FVideoClock + 12) or (FHorizontalSetClock > FVideoClock) then
      raise EReadError.Create('Invalid MSX VDP status-read phase');
    for var I := 0 to 2 do
      if (FStatusSetClock[I] < -1) or (FStatusSetClock[I] > FVideoClock) then
        raise EReadError.Create('Invalid MSX VDP status latch time');
    var SavedMode := FFetchMode;
    BuildFetchEvents;
    FFetchMode := SavedMode;
    if FCPUWaitLatch and ((FChip <> VDPV9958) or not FCPUPending) then
      raise EReadError.Create('Invalid MSX VDP WAIT latch');
    if (FNextSpritePixel < FVideoClock) or (FNextSpriteStatus < FVideoClock) or (FSpriteStatusValue > 31) or (FSpriteCounter > 31) or (FCPUReady < 0) or (FCommandReady < 0) or
      (FCPUPhase > 2) or (FCPUAddress < 0) or (FCPUAddress > $1FFFF) or (FCPUDue < FVideoClock) or (FNextFetch < FVideoClock) or (FSpriteCount < 0) or (FSpriteCount > 8) or
      (FNextSpriteCount < 0) or (FNextSpriteCount > 8) then
      raise EReadError.Create('Invalid VDP pipeline state');
  end;
end;

end.

