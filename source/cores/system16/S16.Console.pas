unit S16.Console;

interface

uses
  SegaArcade.Console, SegaArcade.Video, S16.Sound, Core.Snapshots;

type
  TS16Console = class(TSegaArcadeConsole)
  private
    FMultiply: array[0..1] of Word;
    FCompare: array[0..1, 0..15] of Word;
    FHistory: array[0..1] of Integer;
    function ReadMath(UnitIndex: Integer; Offset: Cardinal): Word;
    procedure WriteMath(UnitIndex: Integer; Offset: Cardinal; Value: Word; HighByte, LowByte: Boolean);
    function MCUAddress(Address: Word; out Physical: Cardinal): Boolean;
    procedure SimulateMCU;
  protected
    function CreateVideo: TSegaArcadeVideo; override;
    procedure CreateAudio; override;
    procedure ResetAudio; override;
    procedure CommandAudio(Value: Byte); override;
    function ReplyAudio: Byte; override;
    procedure BeginAudioFrame; override;
    procedure EndAudioFrame; override;
    procedure RunAudio; override;
    procedure SerializeAudio(State: TStateArchive); override;
    function HasNVRAM: Boolean; override;
    function LineDeadline(Line: Integer): Int64; override;
    function MCURead(Address: Word): Byte; override;
    procedure MCUWrite(Address: Word; Value: Byte); override;
    function MCUPortRead(Port: Byte): Byte; override;
    procedure MCUPortWrite(Port, Value: Byte); override;
    function DecodeAddress(Address: Cardinal; out Offset: Cardinal): Integer; override;
    function ReadIO(Offset: Cardinal): Word; override;
    procedure WriteIO(Offset: Cardinal; Value: Byte); override;
    function UsesMapper: Boolean; override;
    function HasMCU: Boolean; override;
    procedure VerticalBlank; override;
    procedure SerializeBoardState(State: TStateArchive); override;
    function ExtraRead(Region: Integer; Offset: Cardinal): Word; override;
    procedure ExtraWrite(Region: Integer; Offset: Cardinal; Value: Word; HighByte, LowByte: Boolean); override;
  public
    Sound: TS16Sound;
    destructor Destroy; override;
    procedure Reset; override;
    function AudioSamples: TArray<SmallInt>; override;
    function FrameRate: Double; override;
  end;

  TS16ConsoleClass = class of TS16Console;

implementation

uses
  System.Math, Core.Emulation.Types, HW.M68k, SegaArcade.RomSets, S16.Video;

destructor TS16Console.Destroy;
begin
  Sound.Free;
  inherited;
end;

procedure TS16Console.Reset;
begin
  FillChar(FMultiply, SizeOf(FMultiply), 0);
  FillChar(FCompare, SizeOf(FCompare), 0);
  FillChar(FHistory, SizeOf(FHistory), 0);
  inherited;
end;

function TS16Console.UsesMapper: Boolean;
begin
  Result := FCart.RomSet.Board <> 0;
end;

function TS16Console.HasMCU: Boolean;
begin
  Result := inherited HasMCU and (FCart.RomSet.MCUSimulation = smNone);
end;

procedure TS16Console.VerticalBlank;
begin
  if FCart.RomSet.MCUSimulation = smNone then
    inherited
  else
    SimulateMCU;
end;

procedure TS16Console.SerializeBoardState(State: TStateArchive);
begin
  State.Field(FMultiply, SizeOf(FMultiply));
  State.Field(FCompare, SizeOf(FCompare));
  State.Field(FHistory, SizeOf(FHistory));
end;

function TS16Console.ExtraRead(Region: Integer; Offset: Cardinal): Word;
begin
  case Region of
    9:
      Exit($FFFF);
    10:
      Exit(ReadMath(0, Offset));
    11:
      Exit(ReadMath(1, (Offset and $1F) or $1000));
  end;
  Result := inherited ExtraRead(Region, Offset);
end;

procedure TS16Console.ExtraWrite(Region: Integer; Offset: Cardinal; Value: Word; HighByte, LowByte: Boolean);
begin
  case Region of
    10:
      begin
        WriteMath(0, Offset, Value, HighByte, LowByte);
        Exit;
      end;
    11:
      begin
        WriteMath(1, (Offset and $1F) or $1000, Value, HighByte, LowByte);
        Exit;
      end;
    9:
      begin
        if LowByte and (Offset < 4) then
          Video.TileBank[Offset shr 1] := Byte(Value and 7);
        Exit;
      end;
  end;
end;

function TS16Console.CreateVideo: TSegaArcadeVideo;
begin
  Result := TS16Video.Create(FCart['tiles'], FCart['sprites'], FCart.RomSet.Board = 0, FCart.RomSet.Board);
end;

procedure TS16Console.CreateAudio;
begin
  Sound := TS16Sound.Create(FCart['soundcpu'], FCart.RomSet.Board,
    FCart['soundcpu:key'], FCart['upd7751'], FCart['upd7751data'], FCart.RomSet.Crypto);
end;

procedure TS16Console.ResetAudio;
begin
  Sound.Reset;
end;

procedure TS16Console.CommandAudio(Value: Byte);
begin
  Sound.Command(Value);
end;

function TS16Console.ReplyAudio: Byte;
begin
  Result := Sound.Reply;
end;

procedure TS16Console.BeginAudioFrame;
begin
  Sound.BeginFrame;
end;

procedure TS16Console.EndAudioFrame;
begin
  Sound.EndFrame;
end;

procedure TS16Console.RunAudio;
begin
  Sound.RunUntil(FTime * Sound.Clock div 10000000);
end;

procedure TS16Console.SerializeAudio(State: TStateArchive);
begin
  Sound.SerializeState(State);
end;

function TS16Console.AudioSamples: TArray<SmallInt>;
begin
  Result := Sound.Samples;
end;

function TS16Console.FrameRate: Double;
begin
  Result := S16_FPS;
end;

function TS16Console.LineDeadline(Line: Integer): Int64;
begin
  Result := ((FFrameNumber * 262 + Line + 1) * Int64(10000000) * 1600) div 25174800;
end;

function TS16Console.HasNVRAM: Boolean;
begin
  Result := FCart.RomSet.Board = 0;
end;

function TS16Console.DecodeAddress(Address: Cardinal; out Offset: Cardinal): Integer;
const
  Sizes: array[0..3] of Cardinal = ($FFFF, $1FFFF, $7FFFF, $1FFFFF);
  Mirrors: array[3..7] of Cardinal = ($FFC000, $FFF800, $FE0000, $FFF000, $FFC000);
begin
  if FCart.RomSet.Board = 0 then
  begin
    Offset := Address and $3FFFF;
    if Address and $C40000 = 0 then
      Exit(0);
    Offset := Address and $7FFF;
    if Address and $470000 = $400000 then
      Exit(5);
    Offset := Address and $FFF;
    if Address and $470000 = $410000 then
      Exit(8);
    Offset := Address and $7FF;
    if Address and $C40000 = $440000 then
      Exit(4);
    Offset := Address and $FFF;
    if Address and $C40000 = $840000 then
      Exit(6);
    Offset := Address and $3FFF;
    if Address and $C60000 = $C40000 then
      Exit(7);
    if Address and $C70000 = $C70000 then
      Exit(3);
    Exit(-1);
  end;
  // Lowest region index wins if regions overlap, including reset aliases.
  for var I := 0 to 7 do
  begin
    var Mask := Sizes[FMapper[$10 + I * 2] and 3];
    var Base := (Cardinal(FMapper[$11 + I * 2]) shl 16) and not Mask;
    if (Address and not Mask) <> Base then
      Continue;
    var local := Address and Mask;
    if I >= 3 then
    begin
      var Mirror := Mirrors[I] and Mask;
      Offset := local and not Mirror;
      if I = 5 then
      begin
        // Text RAM overrides the tile RAM mapping at +$10000.
        var TextOffset := local and not ($FEF000 and Mask);
        if (TextOffset >= ($10000 and Mask)) and
          (TextOffset <= ($10000 and Mask) + Min($FFF, Mask)) then
        begin
          Offset := TextOffset - ($10000 and Mask);
          Exit(8);
        end;
        if Offset < $10000 then
          Exit(5);
      end
      else
      begin
        case I of
          3:
            if Offset < $4000 then
              Exit(3);
          4:
            if Offset < $800 then
              Exit(4);
          6:
            if Offset < $1000 then
              Exit(6);
          7:
            if Offset < $4000 then
              Exit(7);
        end;
      end;
    end
    else
    begin
      if (FCart.RomSet.Board = 5) and (I in [1, 2]) then
      begin
        Offset := local and $3FFF;
        if I = 2 then
          Offset := local and $FFFF;
        Exit(9 + I);
      end;
      var ROMSize := $20000;
      if FCart.RomSet.Board >= 3 then
        ROMSize := $40000;
      if FCart.RomSet.Board = 5 then
        ROMSize := $80000;
      if (I = 2) and (FCart.RomSet.Board >= 3) then
      begin
        Offset := local and $FFFF;
        Exit(9); // Tile bank latches, 5521/5704.
      end;
      Offset := local and (ROMSize - 1);
      var ROMBase := I * ROMSize;
      if FCart.RomSet.Board = 1 then
        ROMBase := I * $10000;
      Inc(Offset, ROMBase);
      if Offset < Cardinal(Length(FProgram)) then
        Exit(0);
    end;
  end;
  Offset := 0;
  Result := -1;
end;

function Signed16(Value: Word): Integer; inline;
begin
  Result := Integer(Value and $7FFF) - Integer(Value and $8000);
end;

function TS16Console.ReadMath(UnitIndex: Integer; Offset: Cardinal): Word;
begin
  var Index := Integer((Offset shr 1) and $F);
  if Offset and $3000 = 0 then
  begin
    Index := Index and 3;
    if Index < 2 then
      Exit(FMultiply[Index]);
    var Product := Int64(Signed16(FMultiply[0])) * Signed16(FMultiply[1]);
    if Index = 2 then
      Exit(Word((Product shr 16) and $FFFF));
    Exit(Word(Product and $FFFF));
  end;
  if Offset and $3000 = $1000 then
  begin
    case Index of
      0..4, 7:
        Exit(FCompare[UnitIndex, Index]);
      5:
        Exit(FCompare[UnitIndex, 1]);
      6:
        Exit(FCompare[UnitIndex, 2]);
    end;
  end;
  Result := $FFFF;
end;

procedure TS16Console.WriteMath(UnitIndex: Integer; Offset: Cardinal; Value: Word; HighByte, LowByte: Boolean);

  procedure Merge(var Dest: Word);
  begin
    if HighByte then
      Dest := (Dest and $FF) or (Value and $FF00);
    if LowByte then
      Dest := (Dest and $FF00) or (Value and $FF);
  end;

begin
  var Index := Integer((Offset shr 1) and $F);
  case Offset and $3000 of
    $0000:
      Merge(FMultiply[Index and 1]);
    $1000:
      begin
        case Index of
          0..2:
            Merge(FCompare[UnitIndex, Index]);
          4:
            begin
              FCompare[UnitIndex, 4] := 0;
              FHistory[UnitIndex] := 0;
            end;
          6:
            Merge(FCompare[UnitIndex, 2]);
          8, 12:
            Merge(FCompare[UnitIndex, 8]);
          10, 14:
            Merge(FCompare[UnitIndex, 10]);
          11, 15:
            if LowByte then
              FCompare[UnitIndex, 11] := Value and $FF;
        end;
        if Index in [0, 1, 2, 6] then
        begin
          var Lower := Min(Signed16(FCompare[UnitIndex, 0]), Signed16(FCompare[UnitIndex, 1]));
          var Upper := Max(Signed16(FCompare[UnitIndex, 0]), Signed16(FCompare[UnitIndex, 1]));
          var Operand := Signed16(FCompare[UnitIndex, 2]);
          FCompare[UnitIndex, 3] := 0;
          if Operand < Lower then
            FCompare[UnitIndex, 3] := $8000;
          if Operand > Upper then
            FCompare[UnitIndex, 3] := $4000;
          FCompare[UnitIndex, 7] := Word(EnsureRange(Operand, Lower, Upper) and $FFFF);
          if Index = 2 then
          begin
            if (FCompare[UnitIndex, 3] = 0) and (FHistory[UnitIndex] < 16) then
              FCompare[UnitIndex, 4] := FCompare[UnitIndex, 4] or Word(1 shl FHistory[UnitIndex]);
            if FHistory[UnitIndex] < 32 then
              Inc(FHistory[UnitIndex]);
          end;
        end;
      end;
    $2000:
      if LowByte then
        Video.TileBank[(Offset shr 1) and 1] := Byte(Value and 7);
  end;
end;

function TS16Console.ReadIO(Offset: Cardinal): Word;

  function QuartetPad(const Buttons: TEmulatorButtons; Coin: Boolean): Byte;
  const
    Order: array[0..5] of TEmulatorButton = (TEmulatorButton.Down,
      TEmulatorButton.Up, TEmulatorButton.Right, TEmulatorButton.Left,
      TEmulatorButton.B, TEmulatorButton.A);
  begin
    Result := $FF;
    for var I := 0 to 5 do
      if Order[I] in Buttons then
        Result := Result and Byte($FF xor (1 shl I));
    if Coin or (TEmulatorButton.Select in Buttons) then
      Result := Result and $BF;
    if TEmulatorButton.Mode in Buttons then
      Result := Result and $7F;
  end;

begin
  if (FCart.RomSet.Inputs = 'quartet') and (Offset and $3000 = $1000) then
    case (Offset shr 1) and 3 of
      0:
        Exit(QuartetPad(FInput.Buttons, FCoins[0] > 0));
      1:
        Exit(QuartetPad(FInput.Buttons2, FCoins[1] > 0));
      2:
        Exit(QuartetPad(FInput.Buttons3, False));
      3:
        Exit(QuartetPad(FInput.Buttons4, False));
    end;
  case Offset and $3000 of
    $0000:
      if FCart.RomSet.Board = 0 then
        Exit(FPPI[(Offset shr 1) and 3]);
    $1000:
      case (Offset shr 1) and 3 of
        0:
          begin
            Result := $FF;
            if (FCoins[0] > 0) or (TEmulatorButton.Select in FInput.Buttons) then
              Result := Result and $FE;
            if (FCoins[1] > 0) or (TEmulatorButton.Select in FInput.Buttons2) then
              Result := Result and $FD;
            if TEmulatorButton.Mode in FInput.Buttons then
              Result := Result and $FB;
            if TEmulatorButton.Start in FInput.Buttons then
              Result := Result and $EF;
            if TEmulatorButton.Start in FInput.Buttons2 then
              Result := Result and $DF;
            Exit;
          end;
        1:
          Exit(Pad(FInput.Buttons));
        2:
          Exit($FF);
        3:
          Exit(Pad(FInput.Buttons2));
      end;
    $2000:
      begin
        var Index := Integer((Offset shr 1) and 1);
        if FCart.RomSet.Board <> 0 then
          Index := Index xor 1;
        Exit(DIP[Index]);
      end;
  end;
  Result := $FFFF;
end;

procedure TS16Console.WriteIO(Offset: Cardinal; Value: Byte);
begin
  if Offset and $3000 <> 0 then
    Exit;
  if FCart.RomSet.Board = 0 then
  begin
    var Port := (Offset shr 1) and 3;
    FPPI[Port] := Value;
    case Port of
      0:
        CommandAudio(Value);
      1:
        begin
          Video.DisplayEnabled := Value and $10 <> 0;
          Video.Flip := Value and $80 <> 0;
          if FMCU <> nil then
            FMCU.SetIRQ(1, Value and $40 = 0);
        end;
      2:
        begin
          Video.RowScroll := Value and 2 = 0;
          Video.ColumnScroll := Value and 4 = 0;
        end;
    end;
  end
  else
  begin
    Video.DisplayEnabled := Value and $20 <> 0;
    Video.Flip := Value and $40 <> 0;
  end;
end;

function TS16Console.MCUPortRead(Port: Byte): Byte;
begin
  Result := $FF;
  if (FCart.RomSet.Board <> 0) and (Port = 1) then
    Result := Byte(ReadIO($1000) and $FF);
end;

procedure TS16Console.MCUPortWrite(Port, Value: Byte);
begin
  if Port <> 1 then
    Exit;
  if FCart.RomSet.Board <> 0 then
  begin
    // Compatibility scheduling window used by MAME's 16B driver as well.
    // The precise P1 bus arbitration circuit is not documented.
    FMainPauseUntil := FTime + 20000;
    Exit;
  end;
  FMCUControl := Value;
  SetMainReset(Value and $40 <> 0);
  Clown68000Interrupt(FCPU, (not Value) and 7);
  if FMainReset then
    Video.DisplayEnabled := True;
end;

function TS16Console.MCUAddress(Address: Word; out Physical: Cardinal): Boolean;
begin
  Result := True;
  case (FMCUControl shr 3) and 7 of
    0:
      if (Address >= $4000) and (Address < $8000) then
        Physical := $C70001 xor (Address and $3FFF)
      else if (Address >= $8000) and (Address < $C000) then
        Physical := $C40001 xor (Address and $3FFF)
      else
        Exit(False);
    1:
      if Address < $8000 then
        Physical := $400001 xor (Address and $7FFF)
      else if Address < $9000 then
        Physical := $410001 xor (Address and $FFF)
      else
        Exit(False);
    3:
      Physical := $840001 xor Address;
  else
    Result := False;
  end;
end;

function TS16Console.MCURead(Address: Word): Byte;
var
  Physical: Cardinal;
begin
  if UsesMapper then
    Exit(inherited MCURead(Address));
  if (FMCUControl shr 3) and 7 in [5, 6, 7] then
    Exit(FProgram[(((FMCUControl shr 3) and 7) - 5) * $10000 + (Address xor 1)]);
  if not MCUAddress(Address, Physical) then
    Exit($FF);
  var Data := ReadWord(Physical);
  if Physical and 1 = 0 then
    Result := Byte(Data shr 8)
  else
    Result := Byte(Data and $FF);
end;

procedure TS16Console.MCUWrite(Address: Word; Value: Byte);
var
  Physical: Cardinal;
begin
  if UsesMapper then
  begin
    inherited;
    Exit;
  end;
  if not MCUAddress(Address, Physical) then
    Exit;
  if Physical and 1 = 0 then
    WriteWord(Physical, Word(Value) shl 8, True, False)
  else
    WriteWord(Physical, Value, False, True);
end;

// Native Pascal adaptation of MAME's tturf_i8751_sim / wb3_i8751_sim.
// Copyright Aaron Giles, BSD-3-Clause; see REFERENCE-LICENSE.txt.
// These two MCU ROMs are undumped. The VBLANK mailbox protocol has no
// private state: all pending requests and acknowledgements live in work RAM.
procedure TS16Console.SimulateMCU;
begin
  Clown68000Interrupt(FCPU, 4);
  case FCart.RomSet.MCUSimulation of
    smToughTurf:
      begin
        var Request := FRAM[$1D0 div 2];
        if Request and $FF00 <> 0 then
        begin
          WriteMapper(3, Byte(Request and $FF));
          FRAM[$1D0 div 2] := Request and $FF;
        end;
        FRAM[$1E6 div 2] := (ReadIO($1000) and $FF) shl 8;
        FRAM[$1E8 div 2] := (ReadIO($1002) and $FF) shl 8;
        FRAM[$1EA div 2] := (ReadIO($1006) and $FF) shl 8;
      end;
    smWonderBoy3:
      begin
        var Request := FRAM[$8 div 2];
        if Request and $FF <> 0 then
        begin
          WriteMapper(3, Byte(Request shr 8));
          FRAM[$8 div 2] := Request and $FF00;
        end;
      end;
  end;
end;

end.
