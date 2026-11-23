unit A5200.GTIA;

interface

uses
  System.SysUtils, System.UITypes, A5200.Types, A5200.Controller, Core.Snapshots;

type
  TA5200GTIA = class
  private
    FRegs: array[0..31] of Byte;
    FHits: array[0..15] of Byte;
    FTriggers: array[0..3] of Byte;
    FPalette: TA5200Palette;
    FHiresEnable: Boolean;
    FShift, FPhase: array[0..7] of Byte;
    FPlayers, FMissiles: Byte;
    FClock: Integer;
    FPending: array[0..7] of record
      Mask: Cardinal;
      Values: array[0..$1B] of Byte;
    end;
    function ClockSprite(Clock, Position, Size: Integer; Latch: Byte; Index: Integer): Boolean;
    function BaseColor(Pixel: Byte; out Playfield: Byte): Byte;
    function CompositeColor(Pixel, Playfield, Players, Missiles, Background: Byte): Byte;
  public
    constructor Create(PAL: Boolean = False);
    procedure Reset;
    procedure ClockObjects(X: Integer);
    function Read(Index: Byte; Controller: TA5200Controller): Byte;
    function ReadTrigger(Port: Integer; Level: Byte): Byte;
    procedure Write(Index, Value: Byte);
    procedure LoadPlayer(Index: Integer; Value: Byte; Line: Integer);
    function Pixel(X: Integer; Playfield: Byte): TAlphaColor;
    function Priority: Byte;
    function ConsoleControl: Byte;
    procedure SerializeState(State: TStateArchive; LegacyTiming: Boolean = False);
  end;

implementation

uses
  System.Math;

constructor TA5200GTIA.Create(PAL: Boolean);
const
  PALHue: array[0..15] of Single = (0, 135, 112.5, 90, 67.5, 45, 22.5, 337.5,
    315, 292.5, 270, 225, 202.5, 180, 157.5, 135);
begin
  inherited Create;
  for var i := 0 to 255 do
  begin
    var H := i shr 4;
    var L := (i and 15) / 16;
    var A := (H - 1) * Pi / 7 - 0.8;
    var C := 0.23;
    if PAL then
    begin
      // PAL has unequal hue intervals. Decode its ideal, line-averaged chroma.
      A := DegToRad(PALHue[H]);
      C := 0.18;
    end;
    if H = 0 then
      C := 0;
    var U := Cos(A) * C;
    var V := Sin(A) * C;
    var Red := L + 0.956 * U + 0.621 * V;
    var Green := L - 0.272 * U - 0.647 * V;
    var Blue := L - 1.106 * U + 1.703 * V;
    if PAL then
    begin
      Red := L + 1.140 * V;
      Green := L - 0.395 * U - 0.581 * V;
      Blue := L + 2.032 * U;
    end;
    FPalette[i] := $FF000000 or (Cardinal(EnsureRange(Round(Red * 255), 0, 255)) shl 16)
      or (Cardinal(EnsureRange(Round(Green * 255), 0, 255)) shl 8)
      or Cardinal(EnsureRange(Round(Blue * 255), 0, 255));
  end;
  Reset;
end;

procedure TA5200GTIA.Reset;
begin
  FillChar(FRegs, SizeOf(FRegs), 0);
  FillChar(FHits, SizeOf(FHits), 0);
  FillChar(FTriggers, SizeOf(FTriggers), 1);
  FillChar(FShift, SizeOf(FShift), 0);
  FillChar(FPhase, SizeOf(FPhase), 0);
  FillChar(FPending, SizeOf(FPending), 0);
  FClock := 0;
  FHiresEnable := False;
  FPlayers := 0;
  FMissiles := 0;
end;

function TA5200GTIA.Priority: Byte;
begin
  Result := FRegs[$1B];
end;

function TA5200GTIA.ConsoleControl: Byte;
begin
  Result := FRegs[$1F];
end;

function TA5200GTIA.Read(Index: Byte; Controller: TA5200Controller): Byte;
begin
  Index := Index and 31;
  if Index < 16 then
    Exit(FHits[Index]);
  if Index < 20 then
  begin
    Exit(ReadTrigger(Index - 16, Controller.Trigger(Index - 16)));
  end;
  if Index = 20 then
    Exit(15);
  if Index = 31 then
    Exit((not FRegs[31]) and 7);
  Result := $0F;
end;

function TA5200GTIA.ReadTrigger(Port: Integer; Level: Byte): Byte;
begin
  if FRegs[$1D] and 4 = 0 then
    FTriggers[Port] := Level
  else
    FTriggers[Port] := FTriggers[Port] and Level;
  Result := FTriggers[Port];
end;

procedure TA5200GTIA.Write(Index, Value: Byte);
begin
  Index := Index and 31;
  if Index = $1E then
    FillChar(FHits, SizeOf(FHits), 0)
  else
  begin
    case Index of
      $12..$1A:
        Value := Value and $FE;
      $1D:
        if Value and 4 = 0 then
          FillChar(FTriggers, SizeOf(FTriggers), 1);
    end;
    if (Index <= $11) or (Index = $1B) then
    begin
      var Delay := 4;
      case Index of
        0..7:
          Delay := 6;
        $1B:
          Delay := 2;
      end;
      var Slot := (FClock + Delay) and High(FPending);
      FPending[Slot].Mask := FPending[Slot].Mask or (Cardinal(1) shl Index);
      FPending[Slot].Values[Index] := Value;
    end
    else
      FRegs[Index] := Value;
  end;
end;

procedure TA5200GTIA.LoadPlayer(Index: Integer; Value: Byte; Line: Integer);
begin
  if Index < 4 then
  begin
    if (FRegs[$1D] and 2 <> 0) and ((Line and 1 <> 0) or (FRegs[$1C] and (16 shl Index) = 0)) then
      FRegs[$0D + Index] := Value;
  end
  else if FRegs[$1D] and 1 <> 0 then
    for var i := 0 to 3 do
      if (Line and 1 <> 0) or (FRegs[$1C] and (1 shl i) = 0) then
        FRegs[$11] := (FRegs[$11] and not (3 shl (i * 2))) or (Value and (3 shl (i * 2)));
end;

function TA5200GTIA.ClockSprite(Clock, Position, Size: Integer; Latch: Byte; Index: Integer): Boolean;
begin
  FPhase[Index] := (FPhase[Index] + 1) and Size;
  if Clock = Position then
    FPhase[Index] := 0;
  if FPhase[Index] = 0 then
    FShift[Index] := (FShift[Index] shl 1) and $FF;
  if Clock = Position then
    FShift[Index] := FShift[Index] or Latch;
  Result := FShift[Index] and $80 <> 0;
end;

procedure TA5200GTIA.ClockObjects(X: Integer);
begin
  var Slot := FClock and High(FPending);
  var PositionIndex := -1;
  var OldPosition := -1;
  if FPending[Slot].Mask <> 0 then
  begin
    for var Index := 0 to High(FPending[Slot].Values) do
      if FPending[Slot].Mask and (Cardinal(1) shl Index) <> 0 then
      begin
        if Index <= 7 then
        begin
          PositionIndex := Index;
          OldPosition := FRegs[Index];
        end;
        FRegs[Index] := FPending[Slot].Values[Index];
      end;
    FPending[Slot].Mask := 0;
  end;
  if X = 32 then
    FHiresEnable := FRegs[$1B] shr 6 = 0;
  if FRegs[$1B] shr 6 <> 0 then
    FHiresEnable := False;
  FClock := (FClock + 1) and High(FPending);
  FPlayers := 0;
  FMissiles := 0;
  for var I := 0 to 3 do
  begin
    var Position := Integer(FRegs[I]);
    if (PositionIndex = I) and (X = OldPosition) then
      Position := OldPosition;
    if ClockSprite(X, Position, FRegs[8 + I] and 3, FRegs[$0D + I], I) then
      FPlayers := FPlayers or (1 shl I);
    var Shift := 2 * I;
    Position := FRegs[4 + I];
    if (PositionIndex = I + 4) and (X = OldPosition) then
      Position := OldPosition;
    if ClockSprite(X, Position, (FRegs[$0C] shr Shift) and 3,
      ((FRegs[$11] shr Shift) and 3) shl 6, I + 4) then
      FMissiles := FMissiles or (1 shl I);
  end;
end;

function TA5200GTIA.BaseColor(Pixel: Byte; out Playfield: Byte): Byte;
begin
  Playfield := 0;
  Result := FRegs[$1A];
  if Pixel and $80 <> 0 then
  begin
    var V := Pixel and 15;
    case FRegs[$1B] shr 6 of
      1:
        Result := FRegs[$1A] or V;
      2:
        if V < 4 then
          Result := FRegs[$12 + V]
        else if V and 7 >= 4 then
        begin
          Playfield := 1 shl (V and 3);
          Result := FRegs[$16 + (V and 3)];
        end;
      3:
        begin
          Result := FRegs[$1A] or (V shl 4);
          if V = 0 then
            Result := Result and $F0;
        end;
    end;
  end
  else if Pixel = 5 then
  begin
    Playfield := 4;
    Result := (FRegs[$18] and $F0) or (FRegs[$17] and 15);
  end
  else if Pixel = 6 then
    Result := FRegs[$18]
  else if (Pixel >= 1) and (Pixel <= 4) then
  begin
    Playfield := 1 shl (Pixel - 1);
    Result := FRegs[$15 + Pixel];
  end;
end;

function TA5200GTIA.CompositeColor(Pixel, Playfield, Players, Missiles, Background: Byte): Byte;
begin
  var Prior := FRegs[$1B];
  var SpecialMode := Prior shr 6;
  if (Players = 0) and (Missiles = 0) then
    Exit(Background);

  var FifthPlayer := (Prior and $10 <> 0) and (Missiles <> 0);
  if not FifthPlayer then
    Players := Players or Missiles;
  if (SpecialMode = 2) and (Pixel and $FC = $80) then
    Players := Players or (1 shl (Pixel and 3));
  if Pixel = 6 then
    Playfield := 4;
  if FifthPlayer then
    Playfield := Playfield or 8;

  // Gate the two player groups and the two playfield groups independently.
  // Conflicting priority bits can suppress all layers, yielding black.
  var P01 := Players and 3 <> 0;
  var P23 := Players and 12 <> 0;
  var PF01 := Playfield and 3 <> 0;
  var PF23 := Playfield and 12 <> 0;
  var LowerPlayfield := PF23 and not (P23 and (Prior and 9 <> 0)) and
    not (P01 and (Prior and 4 = 0));
  Result := 0;
  if LowerPlayfield and (Playfield and 8 <> 0) then
  begin
    Result := FRegs[$19];
    if FifthPlayer and (Pixel and $80 <> 0) then
      case SpecialMode of
        1:
          Result := Result or (Pixel and 15);
        3:
          if Pixel and 15 = 0 then
            Result := Result and $F0
          else
            Result := Result or ((Pixel and 15) shl 4);
      end;
  end
  else
  begin
    if PF01 and not (P23 and (Prior and 1 <> 0)) and not (P01 and (Prior and 3 <> 0)) then
      Result := FRegs[$16 + Ord(Playfield and 2 <> 0)];
    if LowerPlayfield then
      Result := Result or FRegs[$18];
  end;
  if P01 and not (PF01 and (Prior and 12 <> 0)) and not (PF23 and (Prior and 4 <> 0)) then
  begin
    if Players and 1 <> 0 then
      Result := Result or FRegs[$12];
    if (Players and 2 <> 0) and ((Players and 1 = 0) or (Prior and $20 <> 0)) then
      Result := Result or FRegs[$13];
  end
  else if not P01 and P23 and not (PF23 and (Prior and 6 <> 0)) and not (PF01 and (Prior and 1 = 0)) then
  begin
    if Players and 4 <> 0 then
      Result := Result or FRegs[$14];
    if (Players and 8 <> 0) and ((Players and 4 = 0) or (Prior and $20 <> 0)) then
      Result := Result or FRegs[$15];
  end;
  if Pixel = 5 then
    Result := (Result and $F0) or (FRegs[$17] and 15);
end;

function TA5200GTIA.Pixel(X: Integer; Playfield: Byte): TAlphaColor;
begin
  var Mode := FRegs[$1B] shr 6;
  if (Playfield = 0) and (Mode = 2) then
    Playfield := $80
  else if Playfield and $80 <> 0 then
    if Mode <> 0 then
      Playfield := Playfield and $8F
    else
    begin
      var Pair := (Playfield shr 4) and 3;
      if FHiresEnable then
        Playfield := 6 - ((Pair shr (1 - (X and 1))) and 1)
      else
        Playfield := Pair + 1;
    end;
  var PF: Byte;
  var Color := BaseColor(Playfield, PF);
  var P := FPlayers;
  var M := FMissiles;
  for var i := 0 to 3 do
  begin
    if M and (1 shl i) <> 0 then
    begin
      FHits[i] := FHits[i] or PF;
      FHits[8 + i] := FHits[8 + i] or P;
    end;
    if P and (1 shl i) <> 0 then
    begin
      FHits[4 + i] := FHits[4 + i] or PF;
      FHits[12 + i] := FHits[12 + i] or (P and not (1 shl i));
    end;
  end;
  Result := FPalette[CompositeColor(Playfield, PF, P, M, Color)];
end;

procedure TA5200GTIA.SerializeState(State: TStateArchive; LegacyTiming: Boolean);
begin
  State.Field(FRegs, SizeOf(FRegs));
  State.Field(FHits, SizeOf(FHits));
  State.Field(FTriggers, SizeOf(FTriggers));
  if not LegacyTiming and (State.Version <> 1) then
  begin
    State.Field(FShift, SizeOf(FShift));
    State.Field(FPhase, SizeOf(FPhase));
    State.Field(FPending, SizeOf(FPending));
    State.Field(FClock, SizeOf(FClock));
  end
  else if State.Loading then
  begin
    FillChar(FShift, SizeOf(FShift), 0);
    FillChar(FPhase, SizeOf(FPhase), 0);
    FillChar(FPending, SizeOf(FPending), 0);
    FClock := 0;
  end;
end;

end.

