unit MD.MegaCD;

interface

uses
  System.SysUtils, System.Classes, Core.CD.Disc, Core.Snapshots, MD.M68k;

type
  TMDMegaCD = class
  private
    type
      TPCMChannel = record
        Envelope, Pan, Start: Byte;
        Step, Loop: Word;
        Address: Cardinal;
      end;

      TCDState = record
        CPU: TM68kState;
        PRG: array[0..$7FFFF] of Byte;
        RAM: array[0..$3FFFF] of Byte;
        Wave: array[0..$FFFF] of Byte;
        PCM: array[0..7] of TPCMChannel;
        Gate: array[0..255] of Word;
        Decoder: array[0..15] of Byte;
        Buffer: array[0..$3FFF] of Byte;
        Head: array[0..3] of Byte;
        Status: array[0..3] of Byte;
        CDDA: array[0..2351] of Byte;
        CPUTime, Time, NextSector, SectorNumber, NextPCM, NextAudio, TimerDue: Int64;
        TimerReload, GraphicsDue, DMADue: Int64;
        GraphicsRegisters: array[0..7] of Word;
        GraphicsRow, GraphicsPriority: Integer;
        StopwatchOffset: Int64;
        CDPosition, SeekPosition, SeekTicks, DriveStatus, ReportType: Integer;
        DMAAddress, DecodeAddress, WriteAddress, TransferAddress: Cardinal;
        TransferLeft, CDDAIndex, PCMChannel, PCMBank, PCMDisabled, PCMControl: Integer;
        PCMSample: array[0..1] of Integer;
        Fader, FaderTarget: Integer;
        IRQPending, LED: Byte;
        NeedReset, SeekPlay, TransferActive, TransferDone, DecodePending: Boolean;
      end;
  private
    FState: TCDState;
    FCallbacks: TM68kReadWriteCallbacks;
    FDisc: TCDDisc;
    FBoot: TBytes;
    FClock: Integer;
    FBase: Int64;
    FBackup: array[0..8191] of Byte;
    FDirty: Boolean;
    procedure FormatBackup;
    function GateByte(Address: Integer): Byte;
    procedure SetGateByte(Address: Integer; Value: Byte);
    function GateRead(Index: Integer; SubCPU: Boolean): Word;
    procedure GateWrite(Index: Integer; Value, Mask: Word; SubCPU: Boolean);
    function WordAddress(Address: Cardinal; SubCPU: Boolean; out Index: Cardinal): Boolean;
    procedure UpdateIRQ;
    procedure Events(Target: Int64);
    procedure DriveTick;
    procedure DriveCommand;
    procedure DriveReport;
    procedure ReadSector;
    function DecoderRead: Byte;
    procedure DecoderWrite(Value: Byte);
    function HostRead: Word;
    procedure DMA;
    procedure PCMWrite(RegisterIndex: Integer; Value: Byte);
    function PCMRead(RegisterIndex: Integer): Byte;
    procedure PCMTick;
    function StampPixel(X, Y: Integer): Byte;
    procedure DrawStamps;
    procedure GraphicsStep;
  public
    // The board owns Disc, including all its track streams.
    class function Requires32X(Disc: TCDDisc): Boolean; static;
    constructor Create(const BIOS: TBytes; Disc: TCDDisc; MasterClock: Integer);
    destructor Destroy; override;
    procedure Reset;
    procedure Advance(Target: Int64);
    function MainRead(Address: Cardinal; out Value: Word): Boolean;
    function ReadVDPDMA(Address: Cardinal; out Value: Word): Boolean;
    function MainWrite(Address: Cardinal; Value: Word; HighByte, LowByte: Boolean): Boolean;
    function SubRead(Address: Cardinal): Word;
    procedure SubWrite(Address: Cardinal; Value: Word; HighByte, LowByte: Boolean);
    procedure Sample(out Left, Right: Integer);
    function BatteryData: TBytes;
    procedure LoadBattery(const Data: TBytes);
    procedure SerializeState(Archive: TStateArchive);
    property Dirty: Boolean read FDirty write FDirty;
    function CPUState: TM68kState;
    function BoardTime: Int64;
  end;

implementation

uses
  System.Math;

function SubReadCallback(User: Pointer; Address: Cardinal; Hi, Lo: Byte; Cycle: Cardinal; var Early: Byte): Cardinal;
begin
  var Board := TMDMegaCD(User);
  Board.Events(Board.FBase + Cycle);
  Result := Board.SubRead((Address * 2) and $FFFFFF);
end;

procedure SubWriteCallback(User: Pointer; Address: Cardinal; Hi, Lo: Byte; Cycle: Cardinal; var Early: Byte; Value: Cardinal);
begin
  var Board := TMDMegaCD(User);
  Board.Events(Board.FBase + Cycle);
  Board.SubWrite((Address * 2) and $FFFFFF, Value and $FFFF, Hi <> 0, Lo <> 0);
end;

procedure SubAck(User: Pointer);
begin
  var Board := TMDMegaCD(User);

  Board.FState.IRQPending := Board.FState.IRQPending and not (1 shl Board.FState.CPU.PendingInterrupt);
  Board.UpdateIRQ;
end;

function BCD(Value: Integer): Byte;
begin
  Result := ((Value div 10) shl 4) or (Value mod 10);
end;

class function TMDMegaCD.Requires32X(Disc: TCDDisc): Boolean;
begin
  Result := False;
  if Disc = nil then
    Exit;
  var Header: TBytes;
  Disc.ReadData(Disc.Track(1).StartLBA, Header);
  if Length(Header) >= $110 then
    Result := TEncoding.ASCII.GetString(Header, $100, 16).StartsWith('SEGA 32X');
end;

constructor TMDMegaCD.Create(const BIOS: TBytes; Disc: TCDDisc; MasterClock: Integer);
begin
  inherited Create;
  FDisc := Disc;
  if (Length(BIOS) <> $20000) or (Disc = nil) or (MasterClock <= 0) then
    raise EArgumentException.Create('Mega CD requires a 128-KiB BIOS and a disc');
  FBoot := Copy(BIOS);
  FClock := MasterClock;
  FormatBackup;
  FCallbacks.UserData := Self;
  FCallbacks.ReadCallback := SubReadCallback;
  FCallbacks.WriteCallback := SubWriteCallback;
  FCallbacks.InterruptAcknowledgeCallback := SubAck;
  Reset;
end;

destructor TMDMegaCD.Destroy;
begin
  FDisc.Free;
  inherited;
end;

procedure TMDMegaCD.FormatBackup;
const
  // BIOS BRMFORMAT: directory terminator, duplicated free-block count,
  // then the volume identifier in the final 64 bytes of the 8-KiB RAM.
  DirectoryEnd: array[0..15] of Byte = (
    $5F, $5F, $5F, $5F, $5F, $5F, $5F, $5F, $5F, $5F, $5F, 0, 0, 0, 0, $40);
  VolumeID: AnsiString = 'SEGA_CD_ROM'#0#1#0#0#0'RAM_CARTRIDGE___';
begin
  FillChar(FBackup, SizeOf(FBackup), 0);
  Move(DirectoryEnd, FBackup[$1FC0], SizeOf(DirectoryEnd));
  for var I := 0 to 3 do
    FBackup[$1FD1 + I * 2] := $7D;
  Move(VolumeID[1], FBackup[$1FE0], Length(VolumeID));
  FDirty := True;
end;

procedure TMDMegaCD.Reset;
begin
  FState := Default(TCDState);
  FState.Gate[1] := 1; // Word RAM returned to MAIN, 2M mode.
  FState.Gate[$36 div 2] := $0100;
  FState.Gate[3] := $FFFF;
  FState.NeedReset := True;
  FState.DriveStatus := 9;
  FState.ReportType := 15;
  FState.CDPosition := 0;
  FState.NextSector := 12500000 div 75;
  FState.SectorNumber := 1;
  FState.NextPCM := 384;
  FState.NextAudio := 12500000 div 44100;
  FState.PCMDisabled := $FF;
  FState.Status[3] := $80;
  FState.Decoder[1] := 0; // IFCTRL is separate from the active-low IFSTAT.
  FState.Fader := 1024;
  FState.FaderTarget := 1024;
  FState.Gate[$34 div 2] := $4000;
  // The power-on reply acknowledges STOP before the TOC becomes available.
  SetGateByte($41, 15);
end;

function TMDMegaCD.GateByte(Address: Integer): Byte;
begin
  if Odd(Address) then
    Result := FState.Gate[(Address and $1FE) div 2] and $FF
  else
    Result := FState.Gate[(Address and $1FE) div 2] shr 8;
end;

procedure TMDMegaCD.SetGateByte(Address: Integer; Value: Byte);
begin
  var I := (Address and $1FE) div 2;
  if Odd(Address) then
    FState.Gate[I] := (FState.Gate[I] and $FF00) or Value
  else
    FState.Gate[I] := (FState.Gate[I] and $FF) or (Word(Value) shl 8);
end;

procedure TMDMegaCD.UpdateIRQ;
begin
  FState.CPU.PendingInterrupt := 0;
  for var Level := 6 downto 1 do
    if FState.IRQPending and FState.Gate[$32 div 2] and (1 shl Level) <> 0 then
    begin
      FState.CPU.PendingInterrupt := Level;
      Break;
    end;
end;

function TMDMegaCD.WordAddress(Address: Cardinal; SubCPU: Boolean; out Index: Cardinal): Boolean;
begin
  var Mode := FState.Gate[1] and 4 <> 0;
  var Bank := FState.Gate[1] and 1;
  if not Mode then
  begin
    Result := SubCPU = (FState.Gate[1] and 2 <> 0);
    Index := Address and $3FFFF;
    if SubCPU and (Address >= $C0000) then
      Result := False;
  end
  else
  begin
    if SubCPU then
      Bank := Bank xor 1
    else if Address and $20000 <> 0 then
    begin
      // Cell-arranged window: 64 columns, with 32/16/8/4 rows per region.
      var A := Address and $1FFFF;
      var Base: Cardinal := 0;
      var Rows := 32;
      if A >= $1E000 then
      begin
        Base := $1E000;
        Rows := 4;
      end
      else if A >= $1C000 then
      begin
        Base := $1C000;
        Rows := 4;
      end
      else if A >= $18000 then
      begin
        Base := $18000;
        Rows := 8;
      end
      else if A >= $10000 then
      begin
        Base := $10000;
        Rows := 16;
      end;
      Dec(A, Base);
      var Cell := A div 32;
      Address := Base + (Cell mod Cardinal(Rows)) * 2048 + ((A div 4) and 7) * 256 +
        (Cell div Cardinal(Rows)) * 4 + (A and 3);
    end;
    Index := ((Address and $1FFFE) shl 1) or (Bank shl 1) or (Address and 1);
    Result := True;
  end;
end;

function TMDMegaCD.GateRead(Index: Integer; SubCPU: Boolean): Word;
begin
  Result := FState.Gate[Index];
  case Index of
    0:
      if SubCPU then
        Result := (Word(FState.LED) shl 8) or 1
      else
        Result := Result or ((FState.Gate[$32 div 2] and 4) shl 13);
    1:
      if SubCPU then
        Result := Result and $FF1F;
    2:
      begin
        Result := Result and $07FF;
        if FState.TransferActive then
          Result := Result or $4000
        else if FState.TransferDone then
          Result := Result or $8000;
      end;
    3:
      if SubCPU then
        Result := DecoderRead;
    4:
      Result := HostRead;
    6:
      Result := ((FState.Time div 384) + FState.StopwatchOffset) and $FFF;
    $30 div 2:
      Result := 0;
    $50 div 2..$56 div 2:
      begin
        Result := 0;
        var Bits := FState.Gate[$4E div 2];
        var Colours := FState.Gate[$4C div 2] and $FF;
        for var I := 0 to 3 do
        begin
          var Bit := 15 - ((Index - $50 div 2) * 4 + I);
          var Colour := Colours and 15;
          if Bits and (1 shl Bit) <> 0 then
            Colour := Colours shr 4;
          Result := (Result shl 4) or Colour;
        end;
      end;
  end;
end;

procedure TMDMegaCD.GateWrite(Index: Integer; Value, Mask: Word; SubCPU: Boolean);
begin
  var Old := FState.Gate[Index];
  var V: Word := (Old and not Mask) or (Value and Mask);

  case Index of
    0:
      if SubCPU then
      begin
        if Mask and $FF00 <> 0 then
          FState.LED := (V shr 8) and 3;
      end
      else
      begin
        if Mask and $FF00 <> 0 then
          if V and $100 <> 0 then
          begin
            FState.IRQPending := FState.IRQPending or 4;
            UpdateIRQ;
          end;
        if Mask and $FF <> 0 then
        begin
          if (Old and 1 = 0) and (V and 1 <> 0) then
            FState.NeedReset := True;
          FState.Gate[0] := V and 3;
        end;
      end;
    1:
      begin
        if Mask and $FF00 <> 0 then
          FState.Gate[1] := (FState.Gate[1] and $FF) or (V and $FF00);
        if Mask and $FF <> 0 then
          if SubCPU then
          begin
            FState.Gate[1] := (FState.Gate[1] and $FFC3) or (V and $1C);
            if (V and 1 <> 0) or (V and 4 <> 0) then
              FState.Gate[1] := (FState.Gate[1] and $FFFC) or (V and 1);
          end
          else
          begin
            FState.Gate[1] := (FState.Gate[1] and $FF3F) or (V and $C0);
            if V and 2 <> 0 then
              FState.Gate[1] := (FState.Gate[1] and $FFFE) or 2;
          end;
      end;
    2:
      begin
        if Mask and $FF00 <> 0 then
          FState.Gate[2] := (FState.Gate[2] and $FF) or (V and $700);
        if Mask and $FF <> 0 then
          FState.Gate[2] := (FState.Gate[2] and $FF00) or (V and 15);
      end;
    3:
      if SubCPU and (Mask and $FF <> 0) then
        DecoderWrite(V and $FF)
      else if not SubCPU then
        FState.Gate[3] := V;
    5:
      if SubCPU then
        FState.DMAAddress := Cardinal(V) shl 3;
    6:
      FState.StopwatchOffset := Int64(V and $FFF) - FState.Time div 384;
    7:
      if SubCPU then
        FState.Gate[7] := (Old and $FF00) or (V and $FF)
      else
        FState.Gate[7] := (Old and $FF) or (V and $FF00);
    8..15:
      if not SubCPU then
        FState.Gate[Index] := V;
    16..23:
      if SubCPU then
        FState.Gate[Index] := V;
    $30 div 2:
      if SubCPU then
      begin
        FState.TimerReload := Int64(V and $FF) * 384;
        FState.TimerDue := 0;
        if FState.TimerReload > 0 then
          FState.TimerDue := FState.Time + FState.TimerReload;
      end;
    $32 div 2:
      if SubCPU then
      begin
        FState.Gate[Index] := V and $7E;
        UpdateIRQ;
      end;
    $34 div 2:
      if SubCPU then
      begin
        FState.FaderTarget := Min(1024, V shr 4);
        FState.Gate[Index] := V;
      end;
    $36 div 2:
      if SubCPU then
        FState.Gate[Index] := (Old and $FF00) or (V and 4);
    $42 div 2..$48 div 2:
      if SubCPU then
        FState.Gate[Index] := V and $0F0F;
    $4A div 2:
      if SubCPU then
      begin
        FState.Gate[Index] := 0;
        DriveCommand;
      end;
    $4C div 2:
      if SubCPU then
        FState.Gate[Index] := V and $FF;
    $4E div 2:
      if SubCPU then
        FState.Gate[Index] := V;
    $58 div 2..$66 div 2:
      if SubCPU then
      begin
        FState.Gate[Index] := V;
        if Index = $66 div 2 then
          DrawStamps;
      end;
  end;
end;

function TMDMegaCD.ReadVDPDMA(Address: Cardinal; out Value: Word): Boolean;
begin
  Result := (Address >= $200000) and (Address < $240000);
  if not Result then
    Exit;
  // Sega Mega-CD Hardware Manual, supplement p.61: Word RAM data arrives
  // one VDP read late. Software advances SAR by a word and repairs the first
  // two destination words using the CPU. The initial DMA word is undefined;
  // use the preceding word, preserving the VDP's 128-KiB source wrap.
  Address := (Address and $FE0000) or ((Address + $1FFFE) and $1FFFE);
  MainRead(Address, Value);
end;

function TMDMegaCD.MainRead(Address: Cardinal; out Value: Word): Boolean;
begin
  Result := True;
  Value := $FFFF;
  if Address < $200000 then
  begin
    if Address and $20000 = 0 then
    begin
      var A := Address and $1FFFE;
      if A = $70 then
        Value := $FFFF
      else if A = $72 then
        Value := FState.Gate[3]
      else
        Value := (Word(FBoot[A]) shl 8) or FBoot[A + 1];
    end
    else
    begin
      var A := ((Cardinal(FState.Gate[1] shr 6) and 3) shl 17) or (Address and $1FFFE);
      Value := (Word(FState.PRG[A]) shl 8) or FState.PRG[A + 1];
    end;
  end
  else if (Address >= $200000) and (Address < $240000) then
  begin
    var A: Cardinal;
    if WordAddress(Address, False, A) then
      Value := (Word(FState.RAM[A]) shl 8) or FState.RAM[A + 1];
  end
  else if (Address >= $A12000) and (Address < $A12200) then
    Value := GateRead((Address and $1FE) div 2, False)
  else
    Result := False;
end;

function TMDMegaCD.MainWrite(Address: Cardinal; Value: Word; HighByte, LowByte: Boolean): Boolean;
begin
  var Mask: Word := 0;
  if HighByte then
    Mask := $FF00;
  if LowByte then
    Mask := Mask or $FF;
  Result := True;
  if (Address < $200000) and (Address and $20000 <> 0) then
  begin
    if FState.Gate[0] and 3 <> 1 then
    begin
      var A := ((Cardinal(FState.Gate[1] shr 6) and 3) shl 17) or (Address and $1FFFE);

      if HighByte then
        FState.PRG[A] := Value shr 8;
      if LowByte then
        FState.PRG[A + 1] := Value and $FF;
    end;
  end
  else if (Address >= $200000) and (Address < $240000) then
  begin
    var A: Cardinal;
    if WordAddress(Address, False, A) then
    begin
      if HighByte then
        FState.RAM[A] := Value shr 8;
      if LowByte then
        FState.RAM[A + 1] := Value and $FF;
    end;
  end
  else if (Address >= $A12000) and (Address < $A12200) then
    GateWrite((Address and $1FE) div 2, Value, Mask, False)
  else if Address < $200000 then // BIOS and its mirrors are read-only.

  else
    Result := False;
end;

function TMDMegaCD.SubRead(Address: Cardinal): Word;
begin
  Address := Address and $FFFFFE;
  Result := $FFFF;
  if Address < $80000 then
    Result := (Word(FState.PRG[Address]) shl 8) or FState.PRG[Address + 1]
  else if (Address >= $80000) and (Address < $C0000) and (FState.Gate[1] and 4 <> 0) then
  begin
    var A: Cardinal;
    var Logical := (Address and $3FFFF) div 2;
    WordAddress($C0000 + (Logical and $1FFFE), True, A);
    var Data := FState.RAM[A + (Logical and 1)];
    Result := ((Word(Data) and $F0) shl 4) or (Data and 15);
  end
  else if (Address >= $80000) and (Address < $E0000) then
  begin
    var A: Cardinal;
    if WordAddress(Address, True, A) then
      Result := (Word(FState.RAM[A]) shl 8) or FState.RAM[A + 1];
  end
  else if (Address >= $FE0000) and (Address < $FF0000) then
    Result := $FF00 or FBackup[(Address div 2) and $1FFF]
  else if (Address >= $FF0000) and (Address < $FF8000) then
  begin
    var R := Integer((Address and $1FFF) div 2);
    if Address and $2000 <> 0 then
      Result := FState.Wave[FState.PCMBank * 4096 + R]
    else
      Result := PCMRead(R);
  end
  else if Address >= $FF8000 then
    Result := GateRead((Address and $1FE) div 2, True);
end;

procedure TMDMegaCD.SubWrite(Address: Cardinal; Value: Word; HighByte, LowByte: Boolean);
begin
  Address := Address and $FFFFFE;
  if Address < $80000 then
  begin

    if Address < Cardinal(FState.Gate[1] shr 8) * 512 then
    begin

      Exit;
    end;
    if HighByte then
      FState.PRG[Address] := Value shr 8;
    if LowByte then
      FState.PRG[Address + 1] := Value and $FF;
  end
  else if (Address >= $80000) and (Address < $C0000) and (FState.Gate[1] and 4 <> 0) then
  begin
    var A: Cardinal;
    var Logical := (Address and $3FFFF) div 2;
    WordAddress($C0000 + (Logical and $1FFFE), True, A);
    Inc(A, Logical and 1);
    var Old := FState.RAM[A];
    var Mode := (FState.Gate[1] shr 3) and 3;
    for var N := 0 to 1 do
      if ((N = 0) and HighByte) or ((N = 1) and LowByte) then
      begin
        var V := (Value shr ((1 - N) * 8)) and 15;
        var Shift := (1 - N) * 4;
        var Previous := (Old shr Shift) and 15;
        if (Mode = 0) or ((Mode = 1) and (Previous = 0)) or ((Mode = 2) and (V <> 0)) then
          Old := (Old and not (15 shl Shift)) or (V shl Shift);
      end;
    FState.RAM[A] := Old;
  end
  else if (Address >= $80000) and (Address < $E0000) then
  begin
    var A: Cardinal;
    if WordAddress(Address, True, A) then
    begin
      if HighByte then
        FState.RAM[A] := Value shr 8;
      if LowByte then
        FState.RAM[A + 1] := Value and $FF;
    end;
  end
  else if (Address >= $FE0000) and (Address < $FF0000) then
  begin
    if LowByte and (FBackup[(Address div 2) and $1FFF] <> Value and $FF) then
    begin
      FBackup[(Address div 2) and $1FFF] := Value and $FF;
      FDirty := True;
    end;
  end
  else if (Address >= $FF0000) and (Address < $FF8000) then
  begin
    if LowByte then
    begin
      var R := Integer((Address and $1FFF) div 2);
      if Address and $2000 <> 0 then
        FState.Wave[FState.PCMBank * 4096 + R] := Value and $FF
      else
        PCMWrite(R, Value and $FF);
    end;
  end
  else if Address >= $FF8000 then
  begin
    var Mask: Word := 0;
    if HighByte then
      Mask := $FF00;
    if LowByte then
      Mask := Mask or $FF;
    var I := (Address and $1FE) div 2;
    if HighByte and not LowByte and (I in [1, 7, $30 div 2, $4C div 2]) then
    begin
      Mask := $FF;
      Value := Value shr 8;
    end;
    GateWrite(I, Value, Mask, True);
  end;
end;

procedure TMDMegaCD.DriveReport;

  procedure Digits(Offset, Value: Integer);
  begin
    SetGateByte(Offset, (Value div 10) mod 10);
    SetGateByte(Offset + 1, Value mod 10);
  end;

  procedure Time(Frames: Integer);
  begin
    Frames := Max(0, Frames);
    Digits($3A, Frames div 4500);
    Digits($3C, (Frames div 75) mod 60);
    Digits($3E, Frames mod 75);
  end;

begin
  for var A := $38 to $41 do
    SetGateByte(A, 0);
  var ReportStatus := FState.DriveStatus;
  // Status commands acknowledge PLAY during the final seek settling period,
  // giving the host time to enable decoding before the first block arrives.
  if (FState.SeekTicks > 0) and (FState.SeekTicks <= 3) and FState.SeekPlay and
    (GateByte($42) and 15 = 0) then
    ReportStatus := 1;
  SetGateByte($38, ReportStatus and 15);
  SetGateByte($39, FState.ReportType and 15);
  var Track := FDisc.TrackAt(FState.CDPosition) + 1;
  case FState.ReportType of
    0:
      Time(FState.CDPosition + 150);
    1:
      if Track >= 1 then
        Time(FState.CDPosition - FDisc.Track(Track).StartLBA);
    2:
      Digits($3A, Max(1, Track));
    3:
      Time(FDisc.LeadOut + 150);
    4:
      begin
        Digits($3A, 1);
        Digits($3C, FDisc.TrackCount);
      end;
    5:
      begin
        var Requested := GateByte($46) * 10 + GateByte($47);
        if (Requested >= 1) and (Requested <= FDisc.TrackCount) then
        begin
          var T := FDisc.Track(Requested);
          Time(T.StartLBA + 150);
          if not T.Audio then
            SetGateByte($3E, GateByte($3E) or 8);
          SetGateByte($40, Requested mod 10);
        end;
      end;
  end;
  if (FState.ReportType <= 1) and (Track >= 1) and not FDisc.Track(Track).Audio then
    SetGateByte($40, 4);
  var Sum := 0;
  for var A := $38 to $40 do
    Inc(Sum, GateByte(A));
  SetGateByte($41, (not Sum) and 15);
end;

procedure TMDMegaCD.DriveCommand;
begin
  var Command := GateByte($42) and 15;

  case Command of
    0:
      if (FState.SeekTicks > 0) and (FState.SeekTicks <= 3) and FState.SeekPlay then
        FState.ReportType := 0;
    1, 12:
      begin
        FState.DriveStatus := 9;
        FState.ReportType := 15;
        FState.CDPosition := 0;
        FState.CDDAIndex := 588;
        DriveReport;
        // STOP is acknowledged for one command before reporting the TOC state.
        SetGateByte($38, 0);
        SetGateByte($41, 0);
        Exit;
      end;
    2:
      FState.ReportType := GateByte($45) and 15;
    3, 4:
      begin
        var M := GateByte($44) * 10 + GateByte($45);
        var S := GateByte($46) * 10 + GateByte($47);
        var F := GateByte($48) * 10 + GateByte($49);
        FState.SeekPosition := EnsureRange((M * 60 + S) * 75 + F - 150, -150, FDisc.LeadOut);
        FState.SeekTicks := 12 + Abs(FState.SeekPosition - FState.CDPosition) div 7500;
        FState.SeekPlay := Command = 3;
        FState.DriveStatus := 2;
        FState.ReportType := 15;
      end;
    6:
      FState.DriveStatus := 4;
    7:
      FState.DriveStatus := 1;
    8, 9:
      begin
        FState.DriveStatus := 3;
        FState.SeekPlay := Command = 8;
      end;
    10:
      FState.DriveStatus := 4;
    13:
      FState.DriveStatus := 5;
  end;
  DriveReport;
end;

procedure TMDMegaCD.DriveTick;
begin
  var Decoded := False;
  if FState.SeekTicks > 0 then
  begin
    Dec(FState.SeekTicks);
    if FState.SeekTicks = 0 then
    begin
      FState.CDPosition := FState.SeekPosition;
      FState.DriveStatus := 4 - 3 * Ord(FState.SeekPlay);
      if FState.ReportType = 15 then
        FState.ReportType := 0;
    end;
  end
  else if FState.DriveStatus = 1 then
  begin
    if FState.CDPosition >= FDisc.LeadOut then
      FState.DriveStatus := 4
    else
    begin
      ReadSector;
      Decoded := (FState.CDPosition < 0) or FDisc.IsData(FState.CDPosition);
      Inc(FState.CDPosition);
    end;
  end
  else if FState.DriveStatus = 3 then
    FState.CDPosition := EnsureRange(FState.CDPosition + 10 * (2 * Ord(FState.SeekPlay) - 1), 0, FDisc.LeadOut);
  // The decoder continues receiving blocks during pause/seek, without a valid
  // data header. Its interrupt clock is independent of the drive mechanism.
  if not Decoded and (FState.Decoder[10] and $80 <> 0) then
  begin
    FillChar(FState.Head, SizeOf(FState.Head), 0);
    FState.Status[0] := $80;
    FState.Status[1] := 0;
    FState.Status[2] := FState.Decoder[11] and $0C;
    FState.Status[3] := 0;
    FState.DecodePending := True;
    if FState.Decoder[1] and $20 <> 0 then
      FState.IRQPending := FState.IRQPending or $20;
  end;
  if FState.Fader < FState.FaderTarget then
    Inc(FState.Fader)
  else if FState.Fader > FState.FaderTarget then
    Dec(FState.Fader);
  if FState.Gate[$36 div 2] and 4 <> 0 then
    FState.IRQPending := FState.IRQPending or $10;
  UpdateIRQ;
end;

procedure TMDMegaCD.ReadSector;
begin
  if (FState.CDPosition >= 0) and not FDisc.IsData(FState.CDPosition) then
  begin
    var Data: TBytes;
    FDisc.ReadAudio(FState.CDPosition, Data);
    if Length(Data) = 2352 then
      Move(Data[0], FState.CDDA, 2352);
    FState.CDDAIndex := 0;
    Exit;
  end;
  var LBA := FState.CDPosition + 150;
  FState.Head[0] := BCD(LBA div 4500);
  FState.Head[1] := BCD((LBA div 75) mod 60);
  FState.Head[2] := BCD(LBA mod 75);
  FState.Head[3] := 1;

  if FState.Decoder[10] and $80 = 0 then
    Exit;
  FState.Status[0] := $80;
  FState.Status[1] := 0;
  FState.Status[2] := FState.Decoder[11] and 8;
  FState.Status[3] := 0;
  FState.DecodePending := True;
  if FState.Decoder[10] and 4 <> 0 then
  begin
    var Data: TBytes;
    if FState.CDPosition < 0 then
      SetLength(Data, 2048)
    else
      FDisc.ReadData(FState.CDPosition, Data);
    FState.DecodeAddress := (FState.DecodeAddress + 2352) and $FFFF;
    FState.WriteAddress := (FState.WriteAddress + 2352) and $FFFF;
    for var I := 0 to 3 do
      FState.Buffer[(FState.DecodeAddress + Cardinal(I)) and $3FFF] := FState.Head[I];
    for var I := 0 to 2047 do
      FState.Buffer[(FState.DecodeAddress + Cardinal(I + 4)) and $3FFF] := Data[I];
  end;
  if FState.Decoder[1] and $20 <> 0 then
    FState.IRQPending := FState.IRQPending or $20;
end;

function TMDMegaCD.DecoderRead: Byte;
begin
  var R := FState.Gate[2] and 15;
  case R of
    1:
      begin
        Result := $FF;
        if FState.DecodePending then
          Result := Result and $DF;
        if FState.TransferActive then
          Result := Result and $F5;
        if FState.TransferDone then
          Result := Result and $BF;
      end;
    2:
      Result := (FState.TransferLeft - 1) and $FF;
    3:
      Result := ((FState.TransferLeft - 1) shr 8) and $FF;
    4..7:
      Result := FState.Head[R - 4];
    8:
      Result := FState.DecodeAddress and $FF;
    9:
      Result := (FState.DecodeAddress shr 8) and $FF;
    10:
      Result := FState.WriteAddress and $FF;
    11:
      Result := (FState.WriteAddress shr 8) and $FF;
    12..15:
      begin
        Result := FState.Status[R - 12];
        if R = 15 then
        begin
          FState.DecodePending := False;
          FState.Status[3] := $80;
          FState.IRQPending := FState.IRQPending and $DF;
          UpdateIRQ;
        end;
      end;
  else
    Result := $FF;
  end;

  if R <> 0 then
    FState.Gate[2] := (FState.Gate[2] and $FF00) or ((R + 1) and 15);
end;

procedure TMDMegaCD.DecoderWrite(Value: Byte);
begin
  var R := FState.Gate[2] and 15;

  FState.Decoder[R] := Value;
  case R of
    4:
      FState.TransferAddress := (FState.TransferAddress and $FF00) or Value;
    5:
      FState.TransferAddress := (FState.TransferAddress and $FF) or (Cardinal(Value) shl 8);
    6:
      if FState.Decoder[1] and 2 <> 0 then
      begin
        FState.TransferLeft := ((FState.Decoder[3] and 15) shl 8) or FState.Decoder[2];
        Inc(FState.TransferLeft);
        FState.TransferActive := True;
        FState.TransferDone := False;
        FState.DMADue := FState.Time + 8;
      end;
    7:
      begin
        FState.TransferDone := False;
        FState.IRQPending := FState.IRQPending and $DF;
        UpdateIRQ;
      end;
    8:
      FState.WriteAddress := (FState.WriteAddress and $FF00) or Value;
    9:
      FState.WriteAddress := ((FState.WriteAddress and $FF) or (Cardinal(Value) shl 8)) and $FFFF;
    12:
      FState.DecodeAddress := (FState.DecodeAddress and $FF00) or Value;
    13:
      FState.DecodeAddress := ((FState.DecodeAddress and $FF) or (Cardinal(Value) shl 8)) and $FFFF;
    15:
      begin
        FillChar(FState.Decoder, SizeOf(FState.Decoder), 0);
        FState.TransferActive := False;
        FState.TransferDone := False;
        FState.TransferLeft := 0;
        FState.DecodePending := False;
        FState.DecodeAddress := 0;
        FState.WriteAddress := 0;
        FState.TransferAddress := 0;
        FillChar(FState.Head, SizeOf(FState.Head), 0);
        FillChar(FState.Status, SizeOf(FState.Status), 0);
        FState.IRQPending := FState.IRQPending and $DF;
        UpdateIRQ;
        FState.Status[3] := $80;
      end;
  end;
  if R <> 0 then
    FState.Gate[2] := (FState.Gate[2] and $FF00) or ((R + 1) and 15);
end;

function TMDMegaCD.HostRead: Word;
begin
  Result := $FFFF;
  if not FState.TransferActive then
    Exit;
  Result := (Word(FState.Buffer[FState.TransferAddress and $3FFF]) shl 8) or
    FState.Buffer[(FState.TransferAddress + 1) and $3FFF];
  FState.TransferAddress := (FState.TransferAddress + 2) and $FFFF;
  FState.TransferLeft := Max(0, FState.TransferLeft - 2);
  if FState.TransferLeft = 0 then
  begin
    FState.TransferActive := False;
    FState.TransferDone := True;
    if FState.Decoder[1] and $40 <> 0 then
      FState.IRQPending := FState.IRQPending or $20;
    UpdateIRQ;
  end;
end;

procedure TMDMegaCD.DMA;
begin
  var Destination := (FState.Gate[2] shr 8) and 7;
  if not (Destination in [4, 5, 7]) then
    Exit;
  if Destination = 7 then
  begin
    var A: Cardinal;
    if not WordAddress(FState.DMAAddress, True, A) then
      Exit;
  end;
  if FState.TransferActive then
  begin
    var Data := HostRead;
    case Destination of
      4:
        begin
          FState.Wave[(FState.DMAAddress shr 1) and $FFFF] := Data shr 8;
          FState.Wave[((FState.DMAAddress shr 1) + 1) and $FFFF] := Data and $FF;
          Inc(FState.DMAAddress, 4);
        end;
      5:
        begin
          FState.PRG[FState.DMAAddress and $7FFFF] := Data shr 8;
          FState.PRG[(FState.DMAAddress + 1) and $7FFFF] := Data and $FF;
          Inc(FState.DMAAddress, 2);
        end;
      7:
        begin
          var A: Cardinal;
          if WordAddress(FState.DMAAddress, True, A) then
          begin
            FState.RAM[A] := Data shr 8;
            FState.RAM[A + 1] := Data and $FF;
          end;
          Inc(FState.DMAAddress, 2);
        end;
    end;
  end;
  FState.Gate[5] := (FState.DMAAddress shr 3) and $FFFF;
end;

procedure TMDMegaCD.PCMWrite(RegisterIndex: Integer; Value: Byte);
begin
  case RegisterIndex of
    0:
      FState.PCM[FState.PCMChannel].Envelope := Value;
    1:
      FState.PCM[FState.PCMChannel].Pan := Value;
    2:
      FState.PCM[FState.PCMChannel].Step := (FState.PCM[FState.PCMChannel].Step and $FF00) or Value;
    3:
      FState.PCM[FState.PCMChannel].Step := (FState.PCM[FState.PCMChannel].Step and $FF) or (Word(Value) shl 8);
    4:
      FState.PCM[FState.PCMChannel].Loop := (FState.PCM[FState.PCMChannel].Loop and $FF00) or Value;
    5:
      FState.PCM[FState.PCMChannel].Loop := (FState.PCM[FState.PCMChannel].Loop and $FF) or (Word(Value) shl 8);
    6:
      FState.PCM[FState.PCMChannel].Start := Value;
    7:
      begin
        FState.PCMControl := Value;
        if Value and $40 <> 0 then
          FState.PCMChannel := Value and 7
        else
          FState.PCMBank := Value and 15;
      end;
    8:
      FState.PCMDisabled := Value;
  end;
  for var I := 0 to 7 do
    if (FState.PCMDisabled and (1 shl I) <> 0) or (FState.PCMControl and $80 = 0) then
      FState.PCM[I].Address := Cardinal(FState.PCM[I].Start) shl 19;
end;

function TMDMegaCD.PCMRead(RegisterIndex: Integer): Byte;
begin
  Result := $FF;
  if (RegisterIndex >= $10) and (RegisterIndex < $20) then
    Result := (FState.PCM[(RegisterIndex - $10) div 2].Address shr (11 + 8 * (RegisterIndex and 1))) and $FF;
end;

procedure TMDMegaCD.PCMTick;
begin
  FState.PCMSample[0] := 0;
  FState.PCMSample[1] := 0;
  if FState.PCMControl and $80 = 0 then
    Exit;
  for var I := 0 to 7 do
    if FState.PCMDisabled and (1 shl I) = 0 then
    begin
      var C := FState.PCM[I];
      var Value := FState.Wave[(C.Address shr 11) and $FFFF];
      if Value = $FF then
      begin
        C.Address := Cardinal(C.Loop) shl 11;
        Value := FState.Wave[C.Loop];
      end;
      if Value <> $FF then
      begin
        var S := Integer(Value and $7F);
        if Value and $80 = 0 then
          S := -S;
        Inc(FState.PCMSample[0], S * C.Envelope * (C.Pan and 15) div 32);
        Inc(FState.PCMSample[1], S * C.Envelope * (C.Pan shr 4) div 32);
        C.Address := (C.Address + C.Step) and $7FFFFFF;
      end;
      FState.PCM[I] := C;
    end;
end;

procedure TMDMegaCD.Events(Target: Int64);
begin
  if Target < FState.Time then
    Exit;
  while FState.NextSector <= Target do
  begin
    DriveTick;
    Inc(FState.SectorNumber);
    FState.NextSector := FState.SectorNumber * 12500000 div 75;
  end;
  while FState.NextPCM <= Target do
  begin
    PCMTick;
    Inc(FState.NextPCM, 384);
  end;
  if (FState.TimerDue > 0) and (FState.TimerDue <= Target) then
  begin
    FState.IRQPending := FState.IRQPending or 8;
    FState.TimerDue := FState.TimerDue + ((Target - FState.TimerDue) div FState.TimerReload + 1) * FState.TimerReload;
    UpdateIRQ;
  end;
  // CD-DA advances at 44100 Hz even when the frontend mutes sound.
  while FState.NextAudio <= Target do
  begin
    if FState.CDDAIndex < 588 then
      Inc(FState.CDDAIndex);
    FState.NextAudio := (FState.NextAudio * 44100 div 12500000 + 2) * 12500000 div 44100;
  end;
  while FState.TransferActive and (FState.DMADue > 0) and (FState.DMADue <= Target) do
  begin
    DMA;
    Inc(FState.DMADue, 8);
    // Host-read transfers consume data only when their port is read.
    if not ((FState.Gate[2] shr 8) and 7 in [4, 5, 7]) then
    begin
      FState.DMADue := 0;
      Break;
    end;
  end;
  while (FState.GraphicsDue > 0) and (FState.GraphicsDue <= Target) do
    GraphicsStep;
  FState.Time := Target;
end;

procedure TMDMegaCD.Advance(Target: Int64);
begin
  var EndCycle := (Target div FClock) * 12500000 + (Target mod FClock) * 12500000 div FClock;
  if FState.Gate[0] and 3 = 1 then
  begin
    if FState.NeedReset then
    begin
      FState.NeedReset := False;
      Clown68000Reset(FState.CPU, FCallbacks);
    end;
    while FState.CPUTime < EndCycle do
    begin
      Events(FState.CPUTime);
      FBase := FState.CPUTime;

      Inc(FState.CPUTime, Clown68000DoCycles(FState.CPU, FCallbacks, 1));
    end;
  end
  else
    FState.CPUTime := EndCycle;
  Events(EndCycle);
end;

function TMDMegaCD.StampPixel(X, Y: Integer): Byte;
begin
  Result := 0;
  var Control := FState.GraphicsRegisters[0];
  var Size := 16 shl Ord(Control and 2 <> 0);
  var MapSize := 256 shl (4 * Ord(Control and 4 <> 0));
  if (Control and 1 = 0) and ((X < 0) or (Y < 0) or (X >= MapSize) or (Y >= MapSize)) then
    Exit;
  X := X and (MapSize - 1);
  Y := Y and (MapSize - 1);
  var TableBytes := Cardinal(Sqr(MapSize div Size) * 2);
  var MapAddress := ((Cardinal(FState.GraphicsRegisters[1]) * 4) and not (TableBytes - 1)) + Cardinal(((Y div Size) * (MapSize div Size) + X div Size) * 2);
  var Entry := (Word(FState.RAM[MapAddress and $3FFFF]) shl 8) or FState.RAM[(MapAddress + 1) and $3FFFF];
  var Stamp := Entry and $7FF;
  if Size = 32 then
    Stamp := Stamp and $7FC;
  if Stamp = 0 then
    Exit;
  X := X and (Size - 1);
  Y := Y and (Size - 1);
  if Entry and $8000 <> 0 then
    X := Size - 1 - X;
  var T := X;
  case (Entry shr 13) and 3 of
    1:
      begin
        X := Y;
        Y := Size - 1 - T;
      end;
    2:
      begin
        X := Size - 1 - X;
        Y := Size - 1 - Y;
      end;
    3:
      begin
        X := Size - 1 - Y;
        Y := T;
      end;
  end;
  var Pixel := ((X div 8) * Size + Y) * 8 + X mod 8;
  var Address := (Stamp * 128 + Pixel div 2) and $3FFFF;
  Result := (FState.RAM[Address] shr (4 * (1 - (Pixel and 1)))) and 15;
end;

procedure TMDMegaCD.DrawStamps;
begin
  if FState.Gate[1] and 4 <> 0 then
    Exit;
  for var I := 0 to 7 do
    FState.GraphicsRegisters[I] := FState.Gate[$58 div 2 + I];
  FState.GraphicsRow := 0;
  FState.GraphicsPriority := (FState.Gate[1] shr 3) and 3;
  FState.Gate[$58 div 2] := FState.Gate[$58 div 2] or $8000;
  var Width := FState.GraphicsRegisters[5] and $1FF;
  var Offset := FState.GraphicsRegisters[4] and 7;
  FState.GraphicsDue := FState.Time + 3 * (4 + Width * 2 + (Width + Offset + 3) div 4);
end;

procedure TMDMegaCD.GraphicsStep;

  function W(Address: Cardinal): Word;
  begin
    Result := (Word(FState.RAM[Address and $3FFFF]) shl 8) or FState.RAM[(Address + 1) and $3FFFF];
  end;

begin
  var Y := FState.GraphicsRow;
  var Trace := ((Cardinal(FState.GraphicsRegisters[7]) * 4) and $3FFF8) + Cardinal(Y * 8);
  var Base := (Cardinal(FState.GraphicsRegisters[3]) * 4) and $3FFE0;
  var Width := FState.GraphicsRegisters[5] and $1FF;
  var Height := FState.GraphicsRegisters[6] and $FF;
  var CellHeight := ((FState.GraphicsRegisters[2] and 31) + 1) * 8;
  var OffsetX := FState.GraphicsRegisters[4] and 7;
  var OffsetY := (FState.GraphicsRegisters[4] shr 3) and 7;
  if Y < Height then
  begin
    // Read each trace and the stamp map when its row reaches the engine.
    var XFixed: Int64 := Integer(SmallInt(W(Trace))) * 256;
    var YFixed: Int64 := Integer(SmallInt(W(Trace + 2))) * 256;
    var DX := SmallInt(W(Trace + 4));
    var DY := SmallInt(W(Trace + 6));
    for var X := 0 to Width - 1 do
    begin
      var SourceX := XFixed div 2048;
      var SourceY := YFixed div 2048;
      if (XFixed < 0) and (XFixed mod 2048 <> 0) then
        Dec(SourceX);
      if (YFixed < 0) and (YFixed mod 2048 <> 0) then
        Dec(SourceY);
      var Value := StampPixel(SourceX, SourceY);
      var DestX := X + OffsetX;
      var DestY := Y + OffsetY;
      var Pixel := ((DestX div 8) * CellHeight + DestY) * 8 + DestX mod 8;
      var Address := (Base + Cardinal(Pixel div 2)) and $3FFFF;
      var Shift := 4 * (1 - (Pixel and 1));
      var Previous := (FState.RAM[Address] shr Shift) and 15;
      var Priority := FState.GraphicsPriority;
      if (Priority = 0) or ((Priority = 1) and (Previous = 0)) or ((Priority = 2) and (Value <> 0)) then
        FState.RAM[Address] := (FState.RAM[Address] and not (15 shl Shift)) or (Value shl Shift);
      Inc(XFixed, DX);
      Inc(YFixed, DY);
    end;
  end;
  Inc(FState.GraphicsRow);
  FState.Gate[$64 div 2] := Max(0, Height - FState.GraphicsRow);
  if FState.GraphicsRow >= Height then
  begin
    FState.GraphicsDue := 0;
    FState.Gate[$58 div 2] := FState.Gate[$58 div 2] and $FF;
    FState.IRQPending := FState.IRQPending or 2;
    UpdateIRQ;
  end
  else
    Inc(FState.GraphicsDue, 3 * (4 + Width * 2 + (Width + OffsetX + 3) div 4));
end;

procedure TMDMegaCD.Sample(out Left, Right: Integer);
begin
  Left := FState.PCMSample[0] div 4;
  Right := FState.PCMSample[1] div 4;
  if (FState.DriveStatus = 1) and (FState.CDDAIndex < 588) then
  begin
    var A := FState.CDDAIndex * 4;
    Inc(Left, Integer(SmallInt(Word(FState.CDDA[A]) or (Word(FState.CDDA[A + 1]) shl 8))) * FState.Fader div 1024);
    Inc(Right, Integer(SmallInt(Word(FState.CDDA[A + 2]) or (Word(FState.CDDA[A + 3]) shl 8))) * FState.Fader div 1024);
  end;
end;

function TMDMegaCD.BatteryData: TBytes;
begin
  SetLength(Result, SizeOf(FBackup));
  Move(FBackup, Result[0], Length(Result));
end;

procedure TMDMegaCD.LoadBattery(const Data: TBytes);
begin
  if Length(Data) <> SizeOf(FBackup) then
    raise EReadError.Create('Invalid Mega CD backup RAM size');
  // Older versions could persist untouched, unformatted RAM. Repair only
  // uniformly erased images; never infer that a nonempty save is disposable.
  var Empty := (Data[0] = 0) or (Data[0] = $FF);
  if Empty then
    for var I := 1 to High(Data) do
      if Data[I] <> Data[0] then
      begin
        Empty := False;
        Break;
      end;
  if Empty then
    FormatBackup
  else
  begin
    Move(Data[0], FBackup, SizeOf(FBackup));
    FDirty := False;
  end;
end;

procedure TMDMegaCD.SerializeState(Archive: TStateArchive);
begin
  Archive.Field(FState, SizeOf(FState));
  Archive.Field(FBackup, SizeOf(FBackup));
  if (FState.GraphicsRow < 0) or (FState.GraphicsRow > 256) or (FState.GraphicsPriority < 0) or (FState.GraphicsPriority > 3) or (FState.PCMChannel < 0) or (FState.PCMChannel > 7) or (FState.PCMBank < 0) or
    (FState.PCMBank > 15) or (FState.TransferLeft < 0) or (FState.TransferLeft > 4096) or
    (FState.CDDAIndex < 0) or (FState.CDDAIndex > 588) or (FState.CDPosition < -150) or
    (FState.CDPosition > FDisc.LeadOut) or (FState.CPUTime < 0) or (FState.Time < 0) then
    raise EReadError.Create('Invalid Mega CD snapshot');
end;

function TMDMegaCD.BoardTime: Int64;
begin
  Result := FState.Time;
end;

function TMDMegaCD.CPUState: TM68kState;
begin
  Result := FState.CPU;
end;

end.

