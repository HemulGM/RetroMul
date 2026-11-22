unit NES.Mapper.BlazePro;

interface

uses
  NES.Mapper, NES.Mapper.Banked, NES.Mapper.Mmc3, NES.State, NES.Types;

type
  TBlazeProMode = (bmMmc3, bmMmc1, bmSurom, bmMmc2, bmMmc4, bmUxrom, bmIf12,
    bmAxrom, bmCnrom, bmGxrom, bmNanjing, bmSmb2j, bmVrc24, bmVrc6, bmVrc1,
    bmVrc7, bmVrc3, bmFme7);

  TMapperBlazePro = class(TMapperBanked)
  private
    FRegs: array[0..7] of Word;
    FScratch: array[0..15] of Byte;
    FWidePrg: array[0..2] of Byte;
    FExtra, FLatch, FMmc3Mirror, FMicrowire: Byte;
    FScratchCommand, FScratchBit: Byte;
    FScratchClock, FScratchOut, FChrHalf, FNametableHigh, FGxromSplit: Boolean;
    FSubmapper, FFuse, FLowPrgOffset: Integer;
    FMode: TBlazeProMode;
    FNameBanks: array[0..7] of Integer;
    FActive: TMapper;
    FMmc3: TMapperMmc3;
    FRegion: TNesRegion;
    procedure SelectMode(ResetChip: Boolean);
    procedure SyncBanks;
    procedure WriteSupervisor(Address: Word; Value: Byte);
    procedure ClockScratch(SelectHigh, Clock, Data: Boolean);
    function Fme7WorkBank: Byte;
    procedure ReleaseActive;
  protected
    function ShareProgramRom: Boolean; override;
  public
    constructor Create(const Prg, Chr: TByteArray; MirrorMode: TMirrorMode; Submapper: Integer);
    destructor Destroy; override;
    procedure ConfigureMemory(PrgRamSize, ChrRamSize: UInt64);
    procedure PowerOn; override;
    procedure Reset; override;
    function CpuRead(Address: Word; out Value: Byte): Boolean; override;
    function CpuWrite(Address: Word; Value: Byte): Boolean; override;
    function CpuWriteTimed(Address: Word; Value: Byte; CpuCycle: UInt64): Boolean; override;
    function PpuRead(Address: Word; out Value: Byte): Boolean; override;
    function PpuPeek(Address: Word; Rendering: Boolean; out Value: Byte; Sprite: Boolean): Boolean; override;
    function PpuWrite(Address: Word; Value: Byte): Boolean; override;
    function NameTableOffset(Address: Word): Word; override;
    procedure SetRegion(Region: TNesRegion); override;
    procedure ClockCpu; override;
    procedure ClockPpuAddress(Address: Word; PpuCycle: UInt64); override;
    function IrqPending: Boolean; override;
    function ExpansionAudio: Double; override;
    procedure SerializeState(State: TNesStateArchive); override;
  end;

implementation

uses
  System.SysUtils, NES.Mapper.Mmc1, NES.Mapper.MmcLatch, NES.Mapper.Vrc,
  NES.Mapper.VrcAudio, NES.Mapper.Discrete, NES.Mapper.Sunsoft, HW.Sound.YM2149;

type
  TBankedView = class(TMapperBanked);

  TMmc1View = class(TMapperMmc1);

  TMmc3View = class(TMapperMmc3);

  TVrcView = class(TMapperVrc);

  TVrcAudioView = class(TMapperVrcAudio);

  TBlazeProFme7 = class(TMapperSunsoft)
  private
    FPsg: TYM2149F;
    FDivider: Byte;
    FOutput: Double;
  public
    constructor Create(const Prg: NES.Types.TByteArray);
    destructor Destroy; override;
    function CpuWrite(Address: Word; Value: Byte): Boolean; override;
    function WorkBank: Byte;
    procedure ClockCpu; override;
    function ExpansionAudio: Double; override;
    procedure SerializeState(State: TNesStateArchive); override;
  end;

constructor TBlazeProFme7.Create(const Prg: NES.Types.TByteArray);
begin
  inherited Create(MAPPER_FME7, Prg, nil, False, TMirrorMode.Vertical);
  // The CPLD powers the 5B-compatible PSG at half the CPU clock.
  FPsg := TYM2149F.Create;
  Prg8(2, $FE);
end;

destructor TBlazeProFme7.Destroy;
begin
  FPsg.Free;
  inherited;
end;

function TBlazeProFme7.CpuWrite(Address: Word; Value: Byte): Boolean;
begin
  case Address and $E000 of
    $C000:
      FPsg.WriteAddress(Value and $0F);
    $E000:
      FPsg.WriteData(Value);
  else
    Exit(inherited CpuWrite(Address, Value));
  end;
  Result := True;
end;

function TBlazeProFme7.WorkBank: Byte;
begin
  Result := FWorkBank;
end;

procedure TBlazeProFme7.ClockCpu;
begin
  inherited;
  FDivider := (FDivider + 1) and 15;
  if FDivider = 0 then
  begin
    var Left, Right: Double;
    FPsg.GenerateNative(Left, Right);
    FOutput := 0.35 * (Left + Right);
  end;
end;

function TBlazeProFme7.ExpansionAudio: Double;
begin
  Result := FOutput;
end;

procedure TBlazeProFme7.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FDivider, SizeOf(FDivider));
  State.Field(FOutput, SizeOf(FOutput));
  FPsg.SerializeState(State.Field);
end;

// The 509-in-1 menu indexes an ascending game-number table with these
// seven inserted entries and six unused game numbers.
function MenuGameNumber(Index: Integer): Integer;
begin
  case Index of
    66:
      Exit(0);
    67:
      Exit(1);
    86:
      Exit(4);
    126:
      Exit(2);
    127:
      Exit(3);
    138:
      Exit(5);
    254:
      Exit(6);
  end;
  Result := Index + 7 - Ord(Index > 66) - Ord(Index > 67) - Ord(Index > 86) -
    Ord(Index > 126) - Ord(Index > 127) - Ord(Index > 138) - Ord(Index > 254);
  if Result >= 237 then
    Inc(Result);
  if Result >= 255 then
    Inc(Result);
  if Result >= 348 then
    Inc(Result);
  if Result >= 509 then
    Inc(Result, 3);
end;

constructor TMapperBlazePro.Create(const Prg, Chr: NES.Types.TByteArray; MirrorMode: TMirrorMode; Submapper: Integer);
begin
  inherited Create(Prg, Chr, Length(Chr) = 0, MirrorMode);
  if (Submapper < 0) or (Submapper > 5) or not FHasChrRam then
    raise ENesException.Create('Unsupported BlazePro CPLD cartridge layout');
  FSubmapper := Submapper;
  SetLength(FChrMemory, $40000);
  var ControllerPrg: NES.Types.TByteArray;
  SetLength(ControllerPrg, $4000);
  FMmc3 := TMapperMmc3.Create(ControllerPrg, nil, False, TMirrorMode.Vertical);
  TMmc3View(FMmc3).FIrqRequiresCounterTransition := True;
  Reset;
end;

destructor TMapperBlazePro.Destroy;
begin
  ReleaseActive;
  FMmc3.Free;
  inherited;
end;

function TMapperBlazePro.ShareProgramRom: Boolean;
begin
  Result := True;
end;

procedure TMapperBlazePro.ConfigureMemory(PrgRamSize, ChrRamSize: UInt64);
begin
  if (PrgRamSize > $2000) or (ChrRamSize > $40000) then
    raise ENesException.Create('Unsupported BlazePro CPLD RAM layout');
  FRamEnabled := PrgRamSize <> 0;
  if ChrRamSize <> 0 then
    SetLength(FChrMemory, Integer(ChrRamSize));
end;

procedure TMapperBlazePro.PowerOn;
begin
  FillChar(FRegs, SizeOf(FRegs), 0);
  FillChar(FScratch, SizeOf(FScratch), 0);
  FScratchCommand := 0;
  FScratchOut := False;
  FMmc3Mirror := 0;
  FMmc3.Reset;
  Reset;
end;

procedure TMapperBlazePro.Reset;
begin
  FRegs[6] := 0;
  FRegs[7] := $FF0F;
  FExtra := $10;
  FScratchClock := False;
  FScratchBit := 0;
  FChrHalf := False;
  FNametableHigh := False;
  FMicrowire := 0;
  SelectMode(True);
  SyncBanks;
end;

procedure TMapperBlazePro.ReleaseActive;
begin
  if FActive <> FMmc3 then
    FActive.Free;
  FActive := nil;
end;

procedure TMapperBlazePro.SelectMode(ResetChip: Boolean);
begin
  ReleaseActive;
  FFuse := (FSubmapper shl 4) or ((FRegs[7] shr 4) and $0F);
  var Flags := FRegs[7] and $0F;
  case FFuse of
    $00, $32:
      FMode := bmMmc1;
    $01:
      FMode := bmSurom;
    $0A:
      FMode := bmMmc2;
    $08:
      FMode := bmMmc4;
    $04, $06, $14, $16:
      FMode := bmAxrom;
    $05, $15:
      FMode := bmCnrom;
    $0C, $0D, $1C, $1D:
      FMode := bmGxrom;
    $0E, $1E:
      FMode := bmNanjing;
    $07:
      FMode := bmSmb2j;
    $20..$23:
      FMode := bmVrc24;
    $30, $31:
      FMode := bmVrc6;
    $40:
      FMode := bmVrc1;
    $41:
      FMode := bmVrc7;
    $44:
      FMode := bmVrc3;
    $50:
      FMode := bmFme7;
    $09, $0B, $17, $37:
      if (Flags and 8) <> 0 then
        FMode := bmUxrom
      else
        FMode := bmIf12;
  else
    // The menu and unassigned selections use the TxROM decoder.
    FMode := bmMmc3;
  end;

  if ResetChip then
  begin
    FLatch := 0;
    if FMode in [bmCnrom, bmNanjing, bmSmb2j] then
      FillChar(FRegs[0], (3 + Ord(FMode = bmNanjing)) * SizeOf(Word), 0);
    if FMode = bmGxrom then
      FGxromSplit := (FRegs[6] and $1000) <> 0;
    FillChar(FWidePrg, SizeOf(FWidePrg), 0);
    if FMode = bmVrc7 then
    begin
      FWidePrg[1] := 1;
      FWidePrg[2] := $FE;
    end;
  end;

  if FMode = bmMmc3 then
  begin
    FActive := FMmc3;
    if ResetChip then
      FMmc3.CpuWrite($E000, 0);
    Exit;
  end;
  if FMode in [bmUxrom, bmIf12, bmAxrom, bmCnrom, bmGxrom, bmNanjing, bmSmb2j] then
    Exit;

  // A 256-bank virtual PRG window keeps fixed bank numbers $FD–$FF
  // available to the CPLD without copying the physical flash into the cores.
  var ControllerPrg: NES.Types.TByteArray;
  SetLength(ControllerPrg, $200000);
  case FMode of
    bmMmc1, bmSurom:
      FActive := TMapperMmc1.Create(ControllerPrg, nil, False, TMirrorMode.Vertical);
    bmMmc2, bmMmc4:
      FActive := TMapperMmcLatch.Create(FMode = bmMmc4, ControllerPrg, nil, False, TMirrorMode.Vertical);
    bmVrc24:
      begin
        FActive := TMapperVrc.Create(MAPPER_VRC2_VRC4_27, ControllerPrg, nil, False, TMirrorMode.Vertical);
        for var Slot := 0 to 7 do
          TVrcView(FActive).FChrRegisters[Slot] := Slot;
      end;
    bmVrc6:
      FActive := TMapperVrcAudio.Create(MAPPER_VRC6A, ControllerPrg, nil, False, TMirrorMode.Vertical);
    bmVrc1:
      FActive := TMapperDiscrete.Create(MAPPER_VRC1, ControllerPrg, nil, False, FInitialMirror);
    bmVrc7:
      begin
        FActive := TMapperVrcAudio.Create(MAPPER_VRC7, ControllerPrg, nil, False, TMirrorMode.Vertical, 2);
        for var Slot := 0 to 7 do
          TBankedView(FActive).FChrBanks[Slot] := Slot;
      end;
    bmVrc3:
      FActive := TMapperDiscrete.Create(MAPPER_VRC3, ControllerPrg, nil, False, TMirrorMode.Vertical);
    bmFme7:
      FActive := TBlazeProFme7.Create(ControllerPrg);
  end;
  FActive.SetRegion(FRegion);
end;

procedure TMapperBlazePro.SyncBanks;
var
  Outer, Mask, Flags, Bank, ChrMask: Integer;
begin
  Flags := FRegs[7] and $0F;
  Outer := ((FRegs[7] shr 3) and $1FE0) or ((FRegs[7] shl 4) and $10);
  if FSubmapper = 1 then
    Outer := Outer or ((Integer(FExtra) shl 9) and $2000)
  else
    Outer := Outer or ((FRegs[6] shl 1) and $2000);

  Mirror(Ord((Flags and 4) <> 0));
  case FMode of
    bmMmc3:
      begin
        Mask := $7F;
        if (Flags and 8) <> 0 then
          if (Flags and 4) = 0 then
            Mask := $3F
          else if (Flags and 2) = 0 then
            Mask := $1F
          else if (FExtra and 2) = 0 then
            Mask := $0F
          else
            Mask := $07;
        if FFuse <> $12 then
          Outer := Outer or (12 * (FExtra and 1));
        Outer := Outer and not Mask;
        for var Slot := 0 to 3 do
          Prg8(Slot, Outer or (TMmc3View(FMmc3).PrgRegisterBank(Slot) and Mask));
        ChrMask := $7F;
        if (FFuse <> $12) and ((FRegs[7] and $10) <> 0) then
          ChrMask := $FF;
        for var Slot := 0 to 7 do
        begin
          Bank := TMmc3View(FMmc3).ChrRegisterBank(Slot xor ((TMmc3View(FMmc3).FBankSelect shr 5) and 4));
          Chr1(Slot, Bank and ChrMask);
          FNameBanks[Slot] := Bank shr 7;
        end;
        Mirror(FMmc3Mirror and 1);
        if (FFuse = $12) and (FMmc3Mirror = 3) then
          Mirror(3);
      end;
    bmMmc1, bmSurom:
      begin
        var Chip := TMmc1View(FActive);
        FMirror := Chip.GetMirrorMode;
        Outer := Outer shr 1;
        Mask := $0F;
        ChrMask := $1F;
        if FMode = bmSurom then
        begin
          Outer := (Outer and not $1F) or (Chip.FChrBank0 and $10);
          ChrMask := 1;
        end
        else
        begin
          Outer := Outer or (Flags and 6);
          if (Flags and 2) <> 0 then
            Mask := $07 - 4 * Ord((Flags and 8) <> 0);
        end;
        Outer := Outer and not Mask;
        var Selected := Chip.FPrgBank and $0F;
        for var Slot := 0 to 1 do
        begin
          case (Chip.FControl shr 2) and 3 of
            0, 1:
              Bank := (Selected and $0E) + Slot;
            2:
              Bank := Selected * Slot;
          else
            if Slot = 0 then
              Bank := Selected
            else
              Bank := $0F;
          end;
          Prg16(Slot, Outer or (Bank and Mask));
          if (Chip.FControl and $10) = 0 then
            Bank := (Chip.FChrBank0 and $1E) + Slot
          else if Slot = 0 then
            Bank := Chip.FChrBank0
          else
            Bank := Chip.FChrBank1;
          Chr4(Slot, Bank and ChrMask);
        end;
      end;
    bmUxrom, bmIf12, bmVrc3:
      begin
        if (FFuse = $0B) or ((FFuse = $17) and ((Flags and 2) = 0)) then
          Mask := $1F
        else
          Mask := $0F - 8 * Ord((Flags and 2) <> 0);
        Bank := FLatch;
        Chr8(0);
        case FMode of
          bmIf12:
            begin
              Bank := FRegs[2];
              Chr8((FRegs[0] shr 1) and 15);
              Mirror(FRegs[0] and 1);
            end;
          bmVrc3:
            begin
              Mask := 7;
              Bank := TBankedView(FActive).FPrgBanks[0] shr 1;
            end;
        end;
        Outer := (Outer shr 1) and not Mask;
        Prg16(0, Outer or (Bank and Mask));
        Prg16(1, Outer or Mask);
      end;
    bmAxrom:
      begin
        Mask := $07 - 4 * Ord((Flags and 2) <> 0);
        if (FFuse and $0F) = 6 then
          Mask := $0F;
        Prg32(((Outer shr 2) and not Mask) or (FLatch and Mask));
        Chr8(0);
        if (Flags and 8) = 0 then
          Mirror(2 + (FLatch shr 4 and 1));
      end;
    bmCnrom:
      begin
        if (Flags and 2) <> 0 then
        begin
          Bank := ((Outer shr 1) and not $0F) or ((FRegs[2] shl 1) and $0E) or (Flags and 1);
          Prg16(0, Bank);
          Prg16(1, Bank);
          Chr8(FRegs[0] and 3);
        end
        else
        begin
          Prg32((Outer shr 2) or (FRegs[2] and 7));
          Chr8(FRegs[0] and 15);
        end;
        if (Flags and 8) = 0 then
          Mirror(2 + ((FRegs[1] shr 4) and 1));
      end;
    bmGxrom:
      begin
        Mask := 3 - 2 * Ord((Flags and 8) <> 0);
        Outer := ((Outer shr 2) or (2 * Ord((Flags and 4) <> 0))) and not Mask;
        if FGxromSplit then
        begin
          Prg32(Outer or ((FLatch shr 4) and Mask));
          Chr8(FLatch and 15);
        end
        else
        begin
          Prg32(Outer or (FLatch and Mask));
          Chr8(FLatch shr 4);
        end;
        Mirror((FRegs[7] shr 4) and 1);
      end;
    bmNanjing:
      begin
        Prg32((Outer shr 2) or ((FRegs[2] shl 4) and $30) or (FRegs[0] and $0F) or
          (3 * Ord((FRegs[3] and 4) = 0)));
        Chr8(0);
      end;
    bmSmb2j:
      begin
        Outer := Outer or (Flags and 8);
        Prg8(0, Outer or 4);
        Prg8(1, Outer or 5);
        Prg8(2, Outer or (FRegs[2] and 7));
        Prg8(3, Outer or 7);
        Chr8(0);
      end;
  else
    begin
      var Chip := TBankedView(FActive);
      ChrMask := $FF;
      FMirror := Chip.GetMirrorMode;
      case FMode of
        bmMmc2:
          Mask := $0F;
        bmMmc4:
          Mask := (($0F - 8 * Ord((Flags and 2) <> 0)) shl 1) or 1;
        bmVrc24, bmVrc6:
          begin
            Mask := $1F - 16 * Ord((Flags and 2) <> 0);
            if FFuse = $31 then
              ChrMask := $7F;
          end;
        bmVrc1, bmVrc7:
          begin
            Mask := $7F;
            if (Flags and 8) <> 0 then
              if (Flags and 4) = 0 then
                Mask := $3F
              else if (Flags and 2) = 0 then
                Mask := $1F
              else
                Mask := $0F;
          end;
      else
        Mask := $1F;
        if (Flags and 2) <> 0 then
          Mask := $0F - 8 * Ord((FExtra and 2) <> 0);
        if (Flags and 8) = 0 then
          ChrMask := $7F;
      end;
      Outer := Outer and not Mask;
      for var Slot := 0 to 3 do
      begin
        Bank := Chip.FPrgBanks[Slot];
        if (FMode in [bmVrc1, bmVrc7]) and (Slot < 3) then
          Bank := FWidePrg[Slot];
        Prg8(Slot, Outer or (Bank and Mask));
      end;
      for var Slot := 0 to 7 do
        Chr1(Slot, Chip.FChrBanks[Slot] and ChrMask);
      if FMode = bmVrc6 then
        for var Slot := 0 to 3 do
          FNameBanks[Slot] := TVrcAudioView(FActive).FNameBanks[Slot];
      if FMode = bmFme7 then
      begin
        Bank := Outer or (Fme7WorkBank and $3F and Mask);
        FLowPrgOffset := (Bank mod (Length(FPrgRom) div $2000)) * $2000;
      end;
    end;
  end;
end;

procedure TMapperBlazePro.ClockScratch(SelectHigh, Clock, Data: Boolean);
begin
  if SelectHigh then
    FScratchBit := 0
  else if Clock and not FScratchClock then
  begin
    if FScratchBit < 8 then
    begin
      FScratchCommand := ((Integer(FScratchCommand) shl 1) and $FF) or Ord(Data);
      Inc(FScratchBit);
      if (FScratchBit = 8) and not ((FScratchCommand and $F0) in [$50, $A0]) then
        FScratchBit := 0;
    end
    else
    begin
      var Index := FScratchCommand and 15;
      var Mask := 1 shl (15 - FScratchBit);
      if (FScratchCommand and $F0) = $A0 then
      begin
        var Lookup := MenuGameNumber((FScratch[0] or FScratch[1] or (Integer(FScratch[2]) shl 8)) and $1FF);
        FScratch[Index] := (FScratch[Index] and not Mask) or (Ord(Data) * Mask);
        FScratchOut := ((Lookup shr (8 * Ord((Index and 1) = 0))) and Mask) <> 0;
      end
      else
        FScratchOut := (FScratch[Index] and Mask) <> 0;
      FScratchBit := (FScratchBit + 1) and 15;
    end;
  end;
  FScratchClock := Clock;
end;

procedure TMapperBlazePro.WriteSupervisor(Address: Word; Value: Byte);
begin
  if (Address >= $5600) and ((FRegs[6] and $8000) <> 0) then
    Exit;

  if (Address >= $5700) and ((Address and 2) <> 0) then
  begin
    FExtra := Value;
    SelectMode(True);
  end
  else
  begin
    var Index := (Address shr 8) and 7;
    if (Address and 1) = 0 then
      FRegs[Index] := (FRegs[Index] and $FF00) or Value
    else
      FRegs[Index] := (FRegs[Index] and $00FF) or (Word(Value) shl 8);
    if (Index = 7) and ((Address and 1) = 0) then
      SelectMode(True);
    if (Index = 3) and (FSubmapper = 0) then
      ClockScratch((FRegs[3] and $400) <> 0, (FRegs[3] and $200) <> 0, (FRegs[3] and $100) <> 0)
    else if (Index = 6) and (FSubmapper = 1) then
      ClockScratch((FRegs[6] and $1000) <> 0, (FRegs[6] and $200) <> 0, (FRegs[6] and $100) <> 0);
  end;
  SyncBanks;
end;

function TMapperBlazePro.Fme7WorkBank: Byte;
begin
  Result := TBlazeProFme7(FActive).WorkBank;
end;

function TMapperBlazePro.CpuRead(Address: Word; out Value: Byte): Boolean;
begin
  case Address of
    $5030:
      begin
        Value := 2;
        Exit(True);
      end;
    $5301, $5601:
      begin
        Value := (FCpuOpenBus and $7F) or (Ord(FScratchOut) shl 7);
        Exit(True);
      end;
  end;
  if (Address >= $6000) and (Address < $8000) then
  begin
    if FMode = bmFme7 then
      case Fme7WorkBank and $C0 of
        0, $80:
          begin
            Value := FPrgRom[FLowPrgOffset + (Address and $1FFF)];
            Exit(True);
          end;
        $40:
          Exit(False);
      end;
    if (FMode in [bmMmc1, bmSurom]) and ((TMmc1View(FActive).FPrgBank and $10) <> 0) then
      Exit(False);
    if (FMode = bmVrc24) and not FRamEnabled and ((FFuse and 1) = 0) and (Address < $7000) then
    begin
      Value := FMicrowire;
      Exit(True);
    end;
  end;
  Result := inherited CpuRead(Address, Value);
end;

function TMapperBlazePro.CpuWrite(Address: Word; Value: Byte): Boolean;
begin
  Result := CpuWriteTimed(Address, Value, High(UInt64));
end;

function TMapperBlazePro.CpuWriteTimed(Address: Word; Value: Byte; CpuCycle: UInt64): Boolean;
begin
  if Address < $5000 then
    Exit(False);
  if Address < $6000 then
  begin
    WriteSupervisor(Address, Value);
    Exit(True);
  end;
  if Address < $8000 then
  begin
    if (FMode = bmFme7) and ((Fme7WorkBank and $C0) <> $C0) then
      Exit(True);
    if (FMode in [bmMmc1, bmSurom]) and ((TMmc1View(FActive).FPrgBank and $10) <> 0) then
      Exit(True);
    if (FMode = bmVrc24) and not FRamEnabled and ((FFuse and 1) = 0) and (Address < $7000) then
    begin
      FMicrowire := Value;
      Exit(True);
    end;
    Exit(inherited CpuWrite(Address, Value));
  end;

  case FMode of
    bmUxrom, bmAxrom, bmGxrom:
      FLatch := Value;
    bmCnrom:
      if (Address shr 12 = 9) and ((FRegs[7] and $0F) = 0) then
        FRegs[1] := Value
      else if Address < $C000 then
        FRegs[0] := Value
      else if Address >= $E000 then
        FRegs[2] := Value;
    bmIf12:
      if Address < $C000 then
        FRegs[0] := Value
      else
        FRegs[2] := Value;
    bmSmb2j:
      if Address < $C000 then
        FRegs[0] := Ord((Address and $2000) <> 0)
      else if Address >= $E000 then
        FRegs[2] := Value;
    bmNanjing:
      Exit(True);
    bmVrc24:
      begin
        var Pins := Address and 3;
        if (FFuse and 2) <> 0 then
          Pins := (Pins shr 1) or ((Pins and 1) shl 1);
        var Page := Address and $F000;
        if (FFuse and 1) = 0 then
        begin
          if Page = $F000 then
            Exit(True);
          if Page = $9000 then
          begin
            Pins := 0;
            Value := Value and 1;
          end
          else if (Page >= $B000) and ((Pins and 1) <> 0) then
            Value := Value and $0F;
        end;
        FActive.CpuWrite(Page or Pins, Value);
      end;
  else
    begin
      if FMode = bmMmc3 then
      begin
        if (Address and $E001) = $A000 then
          FMmc3Mirror := Value and 3;
      end
      else if FMode = bmVrc1 then
        case Address shr 12 of
          8:
            FWidePrg[0] := Value;
          10, 11:
            FWidePrg[1] := Value;
          12, 13:
            FWidePrg[2] := Value;
        end
      else if FMode = bmVrc7 then
        case Address and $F010 of
          $8000:
            FWidePrg[0] := Value;
          $8010:
            FWidePrg[1] := Value;
          $9000:
            FWidePrg[2] := Value;
        end;
      if (FMode = bmVrc1) and ((Address shr 12) in [11, 13]) then
        Address := Address and not $1000;
      if CpuCycle = High(UInt64) then
        FActive.CpuWrite(Address, Value)
      else
        FActive.CpuWriteTimed(Address, Value, CpuCycle);
    end;
  end;
  if (FMode = bmUxrom) and (Address = $A000) and (Value = 0) and ((FRegs[7] and $FF) = $9E) then
    FLatch := 6; // Portopia in Forever Duo.
  SyncBanks;
  Result := True;
end;

function TMapperBlazePro.PpuPeek(Address: Word; Rendering: Boolean; out Value: Byte; Sprite: Boolean): Boolean;
begin
  if (FMode = bmVrc6) and (Address >= $2000) and (Address < $3F00) and
    ((TVrcAudioView(FActive).FMode and $10) <> 0) then
  begin
    var Bank := FNameBanks[(Address shr 10) and 3];
    Value := FChrMemory[(Bank * $400 + (Address and $3FF)) mod Length(FChrMemory)];
    Exit(True);
  end;
  Result := inherited PpuRead(Address, Value);
end;

function TMapperBlazePro.PpuRead(Address: Word; out Value: Byte): Boolean;
begin
  if (FMode = bmNanjing) and (Address < $2000) and ((FRegs[0] and $80) <> 0) then
    Address := (Address and $0FFF) or ($1000 * Ord(FChrHalf));
  Result := PpuPeek(Address, FPpuRenderingRead, Value, FPpuSpriteFetch);
  if Result and (Address < $2000) and (FMode in [bmMmc2, bmMmc4]) then
  begin
    var LatchAddress := Address;
    if (FMode = bmMmc4) or (Address >= $1000) then
      LatchAddress := LatchAddress and $FFF8;
    case LatchAddress of
      $0FD8, $0FE8, $1FD8, $1FE8:
        begin
          var Ignored: Byte;
          FActive.PpuRead(Address, Ignored);
          SyncBanks;
        end;
    end;
  end;
end;

function TMapperBlazePro.PpuWrite(Address: Word; Value: Byte): Boolean;
begin
  if (FMode = bmVrc6) and (Address >= $2000) and (Address < $3F00) and
    ((TVrcAudioView(FActive).FMode and $10) <> 0) then
  begin
    var Bank := FNameBanks[(Address shr 10) and 3];
    FChrMemory[(Bank * $400 + (Address and $3FF)) mod Length(FChrMemory)] := Value;
    Exit(True);
  end;
  Result := inherited;
end;

function TMapperBlazePro.NameTableOffset(Address: Word): Word;
begin
  if (FMode = bmMmc3) and (FFuse = $12) and (FMmc3Mirror = 2) then
    Exit(((FNameBanks[(Address shr 10) and 7] and 1) shl 10) or (Address and $3FF));
  if FMode = bmVrc6 then
    Exit(((FNameBanks[(Address shr 10) and 3] and 1) shl 10) or (Address and $3FF));
  Result := inherited;
end;

procedure TMapperBlazePro.SetRegion(Region: TNesRegion);
begin
  FRegion := Region;
  if FActive <> nil then
    FActive.SetRegion(Region);
end;

procedure TMapperBlazePro.ClockCpu;
begin
  if FMode = bmSmb2j then
  begin
    if FRegs[0] = 0 then
      FRegs[1] := 0
    else
      FRegs[1] := (Integer(FRegs[1]) + 1) and $FFFF;
  end
  else if FActive <> nil then
    FActive.ClockCpu;
end;

procedure TMapperBlazePro.ClockPpuAddress(Address: Word; PpuCycle: UInt64);
begin
  if FMode = bmMmc3 then
    FMmc3.ClockPpuAddress(Address, PpuCycle)
  else if FMode = bmNanjing then
  begin
    var HighAddress := (Address and $2000) <> 0;
    if HighAddress and not FNametableHigh then
      FChrHalf := (Address and $200) <> 0;
    FNametableHigh := HighAddress;
  end;
end;

function TMapperBlazePro.IrqPending: Boolean;
begin
  if FMode = bmSmb2j then
    Result := (FRegs[1] and $1000) <> 0
  else
    Result := (FActive <> nil) and FActive.IrqPending;
end;

function TMapperBlazePro.ExpansionAudio: Double;
begin
  if FMode in [bmVrc6, bmVrc7, bmFme7] then
    Result := FActive.ExpansionAudio
  else
    Result := 0;
end;

procedure TMapperBlazePro.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FRegs, SizeOf(FRegs));
  State.Field(FScratch, SizeOf(FScratch));
  State.Field(FWidePrg, SizeOf(FWidePrg));
  State.Field(FExtra, SizeOf(FExtra));
  State.Field(FLatch, SizeOf(FLatch));
  State.Field(FMmc3Mirror, SizeOf(FMmc3Mirror));
  State.Field(FMicrowire, SizeOf(FMicrowire));
  State.Field(FScratchCommand, SizeOf(FScratchCommand));
  State.Field(FScratchBit, SizeOf(FScratchBit));
  State.Field(FScratchClock, SizeOf(FScratchClock));
  State.Field(FScratchOut, SizeOf(FScratchOut));
  State.Field(FChrHalf, SizeOf(FChrHalf));
  State.Field(FNametableHigh, SizeOf(FNametableHigh));
  State.Field(FGxromSplit, SizeOf(FGxromSplit));
  FMmc3.SerializeState(State);
  if State.Loading then
    SelectMode(False);
  if (FActive <> nil) and (FActive <> FMmc3) then
    FActive.SerializeState(State);
  if State.Loading then
    SyncBanks;
end;

end.

