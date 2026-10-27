unit PS1.Bus;

interface

uses
  System.SysUtils, Core.Snapshots, PS1.Types;

const
  // Access costs in CPU cycles on top of the issuing instruction (hardware
  // load timings: RAM about 5, internal I/O 3, scratchpad 1 cycle in total).
  // Device regions use the Memory Control delay registers instead.
  PS1RAMReadStall = 4;
  PS1RAMFetchStall = 4;
  PS1ICacheFillFirst = 4;
  PS1ICacheFillNext = 1;
  PS1IOStall = 2;
  PS1CacheControlStall = 1;
  // A RAM store occupies the bus this long once it leaves the write queue
  // (fitted to ps1-tests dma/chain-looping's store/load loop).
  PS1RAMWriteCycles = 8;
  PS1IOWriteCycles = 2;
  PS1WriteQueueDepth = 4;

  // Physical regions.
  PS1PhysDEV0 = $1F000000;
  PS1PhysScratchpad = $1F800000;
  PS1PhysIO = $1F801000;
  PS1PhysDEV8 = $1F802000;
  PS1PhysDEV1 = $1FA00000;
  PS1PhysBIOS = $1FC00000;
  PS1CacheControlAddress = $FFFE0130;

  // Cache control (BCC) bits.
  PS1BCCTag = $00000004;
  PS1BCCScratchpad = $00000008;
  PS1BCCDataCache = $00000080;
  PS1BCCBlock4 = $00000100;
  PS1BCCICache = $00000800;

type
  TPS1PageKind = (Slow, RAM, BIOS);

  TPS1MemControl = array[0..8] of Cardinal;

  // Devices between 1F801000h and 1F802FFFh. Addresses are physical; values
  // are right-aligned for 8/16-bit accesses, and a store passes the whole
  // register (narrow stores drive all 32 data lines). False is a bus error.
  TPS1IOHandler = class abstract
  public
    function ReadIO(Address: Cardinal; Size: Integer; out Value: Cardinal): Boolean; virtual; abstract;
    function WriteIO(Address, Value: Cardinal; Size: Integer): Boolean; virtual; abstract;
  end;

  TPS1TTYOutput = procedure(Value: Byte) of object;

  TPS1Bus = class
  private
    FRAMWindow: Cardinal;
    FRAS0Size: Cardinal;
    FIsolated: Boolean;
    FBIOSRead: array[1..4] of Integer;
    function DeviceWindow(Index: Integer): Cardinal;
    function ReadMemControl(Address: Cardinal): Cardinal;
    procedure WriteMemControl(Address, Value: Cardinal);
    function RAMOffset(Physical: Cardinal): Cardinal; inline;
  public
    RAM: array[0..PS1RAMSize - 1] of Byte;
    BIOS: array[0..PS1BIOSSize - 1] of Byte;
    Scratchpad: array[0..PS1ScratchpadSize - 1] of Byte;
    // Host pointer to each 64 KiB virtual page, or nil for the slow path.
    // Writes are mapped for RAM only; BIOS writes are ignored by the slow path.
    ReadMap, WriteMap: array[0..$FFFF] of PByte;
    PageKind: array[0..$FFFF] of TPS1PageKind;
    // 1F801000h..1F801020h: DEV0/DEV8 base, DEV0/1/2/4/5/8 delay/size, COM_DELAY.
    MemControl: TPS1MemControl;
    RAMControl: Cardinal;
    CacheControl: Cardinal;
    POST: Byte;
    IO: TPS1IOHandler;
    OnTTY: TPS1TTYOutput;
    constructor Create;
    procedure Reset;
    procedure LoadBIOS(const Data: TBytes);
    procedure RebuildMaps;
    procedure SetIsolated(Value: Boolean);
    // Cycles for an access through a Memory Control device window.
    function DeviceCycles(Index, Size: Integer; Writing: Boolean): Integer;
    function BIOSReadCycles(Size: Integer): Integer; inline;
    // Any virtual address and size 1/2/4 (aligned). Isolated-cache accesses
    // are handled by the CPU before these are called. Cycles is the stall.
    function ReadSlow(Address: Cardinal; Size: Integer; out Value: Cardinal; out Cycles: Integer): Boolean;
    function WriteSlow(Address, Value: Cardinal; Size: Integer; out Cycles: Integer): Boolean;
    function FetchAllowed(Address: Cardinal): Boolean;
    procedure SerializeState(State: TStateArchive);
    property Isolated: Boolean read FIsolated;
    property RAMWindow: Cardinal read FRAMWindow;
  end;

implementation

const
  MemControlReset: TPS1MemControl = ($1F000000, $1F802000, $0013243F, $00003022,
    $001324FF, $200931E1, $00020843, $00070777, $00031125);
  MemControlWritable: TPS1MemControl = ($00FFFFFF, $00FFFFFF, $FFFFFFFF, $FFFFFFFF,
    $FFFFFFFF, $FFFFFFFF, $FFFFFFFF, $FFFFFFFF, $0000FFFF);

  // Delay register index for each device window.
  DelayDEV0 = 2;
  DelayDEV1 = 3;
  DelayDEV2 = 4;
  DelayDEV4 = 5;
  DelayDEV5 = 6;
  DelayDEV8 = 7;

constructor TPS1Bus.Create;
begin
  inherited Create;
  Reset;
end;

procedure TPS1Bus.Reset;
begin
  FillChar(RAM, SizeOf(RAM), 0);
  FillChar(Scratchpad, SizeOf(Scratchpad), 0);
  MemControl := MemControlReset;
  RAMControl := $00000B88;
  CacheControl := 0;
  POST := 0;
  FIsolated := False;
  RebuildMaps;
end;

procedure TPS1Bus.LoadBIOS(const Data: TBytes);
begin
  if Length(Data) <> PS1BIOSSize then
    raise EPS1Error.Create('PS1 BIOS must contain exactly 512 KiB');

  Move(Data[0], BIOS[0], PS1BIOSSize);
end;

function TPS1Bus.DeviceWindow(Index: Integer): Cardinal;
begin
  var Bits := (MemControl[Index] shr 16) and $1F;
  if Bits > 23 then
    Bits := 23;
  Result := Cardinal(1) shl Bits;
end;

// Stall of one access through a Memory Control window. The structure follows
// psx-spx's COM_DELAY notes; the exact terms are fitted to the access times
// measured on hardware (ps1-tests cpu/access-time) for BIOS, DEV0, DEV1,
// DEV8 and CD-ROM: recovery separates sequential transfers only, and the
// first transfer takes at least six cycles.
function TPS1Bus.DeviceCycles(Index, Size: Integer; Writing: Boolean): Integer;
begin
  var Delay := MemControl[Index];
  var Common := MemControl[8];
  var Access := Integer((Delay shr 4) and $F);
  if Writing then
    Access := Integer(Delay and $F);
  var First := Access + 2;
  var Sequential := Access + 2;
  if (Delay and $100) <> 0 then
    Inc(Sequential, Integer(Common and $F));
  if Writing and ((Delay and $200) <> 0) then
  begin
    Inc(First, Integer((Common shr 4) and $F));
    Inc(Sequential, Integer((Common shr 4) and $F));
  end;
  if (Delay and $400) <> 0 then
  begin
    Inc(First, Integer((Common shr 8) and $F));
    Inc(Sequential, Integer((Common shr 8) and $F));
  end;
  if First < 6 then
    Inc(First);
  if (Delay and $800) <> 0 then
  begin
    var Minimum := Integer((Common shr 12) and $F);
    if First < Minimum + 6 then
      First := Minimum + 6;
    if Sequential < Minimum + 2 then
      Sequential := Minimum + 2;
  end;
  var Transfers := Size;
  if (Delay and $1000) <> 0 then
    Transfers := (Size + 1) div 2;
  Result := First + (Transfers - 1) * Sequential;
end;

function TPS1Bus.BIOSReadCycles(Size: Integer): Integer;
begin
  Result := FBIOSRead[Size];
end;

function TPS1Bus.RAMOffset(Physical: Cardinal): Cardinal;
begin
  if Physical < FRAS0Size then
    Result := Physical and PS1RAMMask
  else
    Result := (Physical - FRAS0Size) and PS1RAMMask;
end;

procedure TPS1Bus.RebuildMaps;
begin
  // DRAM_CTRL: /RAS0 and /RAS1 bank sizes; the 2 MiB of RAM repeat in each bank.
  var Bit0 := (RAMControl shr 11) and 1;
  FRAS0Size := Cardinal($100000) shl ((((RAMControl shr 9) and 1) shl 1) or Bit0);
  FRAMWindow := FRAS0Size;
  if (RAMControl and $400) <> 0 then
    Inc(FRAMWindow, Cardinal($100000) shl ((((RAMControl shr 8) and 1) shl 1) or Bit0));
  for var Size := 1 to 4 do
    FBIOSRead[Size] := DeviceCycles(DelayDEV2, Size, False);

  // Only the RAM banks (at most 16 MiB: physical pages 0..FFh) and the BIOS
  // window (pages 1FC0h..1FFFh) are ever mapped; every other page keeps the
  // nil/Slow entry it got when the object was created.
  var BIOSWindow := DeviceWindow(DelayDEV2);
  for var Segment := 0 to 2 do
  begin
    var Base: Cardinal := 0;
    case Segment of
      1:
        Base := $8000;
      2:
        Base := $A000;
    end;
    var Cached := Segment < 2;
    for var Index := 0 to $13F do
    begin
      var Physical := Index;
      if Index > $FF then
        Physical := Integer(PS1PhysBIOS shr 16) + Index - $100;
      var Address := Cardinal(Physical) shl 16;
      var Page := Base + Cardinal(Physical);
      ReadMap[Page] := nil;
      WriteMap[Page] := nil;
      PageKind[Page] := TPS1PageKind.Slow;
      if Address < FRAMWindow then
      begin
        var Memory := @RAM[RAMOffset(Address)];
        PageKind[Page] := TPS1PageKind.RAM;
        if not (Cached and FIsolated) then
        begin
          ReadMap[Page] := Memory;
          WriteMap[Page] := Memory;
        end;
      end
      else if (Address >= PS1PhysBIOS) and (Address - PS1PhysBIOS < BIOSWindow) and
        (BIOSWindow >= $10000) then
      begin
        PageKind[Page] := TPS1PageKind.BIOS;
        if not (Cached and FIsolated) then
          ReadMap[Page] := @BIOS[(Address - PS1PhysBIOS) and PS1BIOSMask];
      end;
    end;
  end;
end;

procedure TPS1Bus.SetIsolated(Value: Boolean);
begin
  if FIsolated = Value then
    Exit;

  FIsolated := Value;
  RebuildMaps;
end;

function TPS1Bus.ReadMemControl(Address: Cardinal): Cardinal;
begin
  Result := MemControl[(Address - PS1PhysIO) shr 2];
end;

procedure TPS1Bus.WriteMemControl(Address, Value: Cardinal);
begin
  var Index := (Address - PS1PhysIO) shr 2;
  MemControl[Index] := (MemControl[Index] and not MemControlWritable[Index]) or
    (Value and MemControlWritable[Index]);
  // Address error flag (bit 28) is cleared by writing 1.
  if (Index >= 2) and (Index <= 7) then
    MemControl[Index] := MemControl[Index] and not $10000000;
  RebuildMaps;
end;

function TPS1Bus.FetchAllowed(Address: Cardinal): Boolean;
begin
  var Physical := Address and $1FFFFFFF;
  Result := not ((Physical >= PS1PhysScratchpad) and (Physical < PS1PhysIO));
end;

function ReadBytes(Source: PByte; Size: Integer): Cardinal; inline;
begin
  case Size of
    1:
      Result := Source^;
    2:
      Result := PWord(Source)^;
  else
    Result := PCardinal(Source)^;
  end;
end;

procedure WriteBytes(Target: PByte; Value: Cardinal; Size: Integer); inline;
begin
  case Size of
    1:
      Target^ := Byte(Value);
    2:
      PWord(Target)^ := Word(Value);
  else
    PCardinal(Target)^ := Value;
  end;
end;

function TPS1Bus.ReadSlow(Address: Cardinal; Size: Integer; out Value: Cardinal; out Cycles: Integer): Boolean;
begin
  Value := 0;
  Cycles := PS1IOStall;
  Result := False;
  var Segment := Address shr 29;
  if Segment >= 6 then
  begin
    if Address = PS1CacheControlAddress then
    begin
      Value := CacheControl shr ((Address and 3) * 8);
      if Size < 4 then
        Value := Value and ($FFFFFFFF shr ((4 - Size) * 8));
      Cycles := 0;
      if Size > 1 then
        Cycles := PS1CacheControlStall;
      Exit(True);
    end;
    if (Address and $FFFFFE00) = $FFFE0000 then
      Exit(True);
    Exit;
  end;
  if Segment in [1, 2, 3] then
    Exit;

  var Physical := Address and $1FFFFFFF;
  if Physical < FRAMWindow then
  begin
    Value := ReadBytes(@RAM[RAMOffset(Physical)], Size);
    Cycles := PS1RAMReadStall;
    Exit(True);
  end;
  if Physical < PS1PhysDEV0 then
    Exit;

  if Physical < PS1PhysScratchpad then
  begin
    if Physical - PS1PhysDEV0 >= DeviceWindow(DelayDEV0) then
      Exit;
    Cycles := DeviceCycles(DelayDEV0, Size, False);
    Value := $FFFFFFFF shr ((4 - Size) * 8);
    Exit(True);
  end;

  if Physical < PS1PhysIO then
  begin
    if (Segment = 5) or (Physical >= PS1PhysScratchpad + PS1ScratchpadSize) then
      Exit;
    Value := ReadBytes(@Scratchpad[Physical - PS1PhysScratchpad], Size);
    Cycles := 0;
    Exit(True);
  end;

  if Physical < PS1PhysIO + $24 then
  begin
    Value := ReadMemControl(Physical and not 3) shr ((Physical and 3) * 8);
    if Size < 4 then
      Value := Value and ($FFFFFFFF shr ((4 - Size) * 8));
    Exit(True);
  end;
  if (Physical >= $1F801060) and (Physical < $1F801064) then
  begin
    Value := RAMControl shr ((Physical and 3) * 8);
    if Size < 4 then
      Value := Value and ($FFFFFFFF shr ((4 - Size) * 8));
    Exit(True);
  end;

  if Physical < PS1PhysDEV8 then
  begin
    if (Physical >= $1F801800) and (Physical < $1F801810) then
      Cycles := DeviceCycles(DelayDEV5, Size, False)
    else if Physical >= $1F801C00 then
      Cycles := DeviceCycles(DelayDEV4, Size, False);
    Result := (IO <> nil) and IO.ReadIO(Physical, Size, Value);
    Exit;
  end;

  if Physical < PS1PhysDEV8 + $2000 then
  begin
    if Physical - PS1PhysDEV8 >= DeviceWindow(DelayDEV8) then
      Exit;
    Cycles := DeviceCycles(DelayDEV8, Size, False);
    Value := $FFFFFFFF shr ((4 - Size) * 8);
    Exit(True);
  end;

  if (Physical >= PS1PhysDEV1) and (Physical < PS1PhysBIOS) then
  begin
    if Physical - PS1PhysDEV1 >= DeviceWindow(DelayDEV1) then
      Exit;
    Cycles := DeviceCycles(DelayDEV1, Size, False);
    Value := $FFFFFFFF shr ((4 - Size) * 8);
    Exit(True);
  end;

  if Physical >= PS1PhysBIOS then
  begin
    if Physical - PS1PhysBIOS >= DeviceWindow(DelayDEV2) then
      Exit;
    Value := ReadBytes(@BIOS[(Physical - PS1PhysBIOS) and PS1BIOSMask], Size);
    Cycles := FBIOSRead[Size];
    Exit(True);
  end;
end;

function TPS1Bus.WriteSlow(Address, Value: Cardinal; Size: Integer; out Cycles: Integer): Boolean;
begin
  Cycles := 0;
  Result := False;
  var Segment := Address shr 29;
  if Segment >= 6 then
  begin
    if Address = PS1CacheControlAddress then
    begin
      // Bits 6 and 10 read as zero.
      CacheControl := Value and not Cardinal($440);
      Exit(True);
    end;
    if (Address and $FFFFFE00) = $FFFE0000 then
      Exit(True);
    Exit;
  end;
  if Segment in [1, 2, 3] then
    Exit;

  var Physical := Address and $1FFFFFFF;
  if Physical < FRAMWindow then
  begin
    WriteBytes(@RAM[RAMOffset(Physical)], Value, Size);
    Exit(True);
  end;
  if Physical < PS1PhysDEV0 then
    Exit;

  if Physical < PS1PhysScratchpad then
  begin
    if Physical - PS1PhysDEV0 >= DeviceWindow(DelayDEV0) then
      Exit;
    Cycles := DeviceCycles(DelayDEV0, Size, True);
    Exit(True);
  end;

  if Physical < PS1PhysIO then
  begin
    if (Segment = 5) or (Physical >= PS1PhysScratchpad + PS1ScratchpadSize) then
      Exit;
    WriteBytes(@Scratchpad[Physical - PS1PhysScratchpad], Value, Size);
    Exit(True);
  end;

  if Physical < PS1PhysIO + $24 then
  begin
    // Narrow stores still drive the whole register, shifted to the offset.
    WriteMemControl(Physical and not 3, Value shl ((Physical and 3) * 8));
    Exit(True);
  end;
  if (Physical >= $1F801060) and (Physical < $1F801064) then
  begin
    RAMControl := Value;
    RebuildMaps;
    Exit(True);
  end;

  if Physical < PS1PhysDEV8 then
  begin
    if (Physical >= $1F801800) and (Physical < $1F801810) then
      Cycles := DeviceCycles(DelayDEV5, Size, True)
    else if Physical >= $1F801C00 then
      Cycles := DeviceCycles(DelayDEV4, Size, True);
    Result := (IO <> nil) and IO.WriteIO(Physical, Value, Size);
    Exit;
  end;

  if Physical < PS1PhysDEV8 + $2000 then
  begin
    if Physical - PS1PhysDEV8 >= DeviceWindow(DelayDEV8) then
      Exit;
    Cycles := DeviceCycles(DelayDEV8, Size, True);
    if Physical = $1F802041 then
      POST := Byte(Value)
    else if (Physical = $1F802023) and Assigned(OnTTY) then
      OnTTY(Byte(Value));
    Exit(True);
  end;

  if (Physical >= PS1PhysDEV1) and (Physical < PS1PhysBIOS) then
  begin
    if Physical - PS1PhysDEV1 >= DeviceWindow(DelayDEV1) then
      Exit;
    Cycles := DeviceCycles(DelayDEV1, Size, True);
    Exit(True);
  end;

  if Physical >= PS1PhysBIOS then
  begin
    if Physical - PS1PhysBIOS >= DeviceWindow(DelayDEV2) then
      Exit;
    Cycles := DeviceCycles(DelayDEV2, Size, True);
    Exit(True);
  end;
end;

procedure TPS1Bus.SerializeState(State: TStateArchive);
begin
  State.Field(RAM, SizeOf(RAM));
  State.Field(Scratchpad, SizeOf(Scratchpad));
  State.Field(MemControl, SizeOf(MemControl));
  State.Field(RAMControl, SizeOf(RAMControl));
  State.Field(CacheControl, SizeOf(CacheControl));
  State.Field(POST, SizeOf(POST));
  State.Field(FIsolated, SizeOf(FIsolated));
  if State.Loading then
    RebuildMaps;
end;

end.

