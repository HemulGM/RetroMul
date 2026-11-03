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
    function PlayerBits(X: Integer; Missile: Boolean): Byte;
    function BaseColor(Pixel: Byte; out Playfield: Byte): Byte;
  public
    constructor Create;
    procedure Reset;
    function Read(Index: Byte; Controller: TA5200Controller): Byte;
    procedure Write(Index, Value: Byte);
    procedure LoadPlayer(Index: Integer; Value: Byte; Line: Integer);
    function Pixel(X: Integer; Playfield: Byte): TAlphaColor;
    function Priority: Byte;
    function ConsoleControl: Byte;
    procedure SerializeState(State: TStateArchive);
  end;

implementation

uses
  System.Math;

constructor TA5200GTIA.Create;
begin
  inherited;
  for var i := 0 to 255 do
  begin
    var H := i shr 4;
    var L := (i and 15) / 16;
    var A := (H - 1) * Pi / 7 - 0.8;
    var C := 0.23;
    if H = 0 then
      C := 0;
    var U := Cos(A) * C;
    var V := Sin(A) * C;
    FPalette[i] := $FF000000 or (Cardinal(EnsureRange(Round((L + 0.956 * U + 0.621 * V) * 255), 0, 255)) shl 16)
      or (Cardinal(EnsureRange(Round((L - 0.272 * U - 0.647 * V) * 255), 0, 255)) shl 8)
      or Cardinal(EnsureRange(Round((L - 1.106 * U + 1.703 * V) * 255), 0, 255));
  end;
  Reset;
end;

procedure TA5200GTIA.Reset;
begin
  FillChar(FRegs, SizeOf(FRegs), 0);
  FillChar(FHits, SizeOf(FHits), 0);
  FillChar(FTriggers, SizeOf(FTriggers), 1);
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
    var i := Index - 16;
    if FRegs[$1D] and 4 = 0 then
      FTriggers[i] := Controller.Trigger(i)
    else
      FTriggers[i] := FTriggers[i] and Controller.Trigger(i);
    Exit(FTriggers[i]);
  end;
  if Index = 20 then
    Exit(15);
  if Index = 31 then
    Exit((not FRegs[31]) and 7);
  Result := $0F;
end;

procedure TA5200GTIA.Write(Index, Value: Byte);
begin
  Index := Index and 31;
  if Index = $1E then
    FillChar(FHits, SizeOf(FHits), 0)
  else
    FRegs[Index] := Value;
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

function TA5200GTIA.PlayerBits(X: Integer; Missile: Boolean): Byte;
const
  Widths: array[0..3] of Integer = (1, 2, 1, 4);
begin
  Result := 0;
  for var i := 0 to 3 do
  begin
    var Position := FRegs[i] * 2;
    var Size := Widths[FRegs[8 + i] and 3] * 2;
    var Data := FRegs[$0D + i];
    var Bits := 8;
    if Missile then
    begin
      Position := FRegs[4 + i] * 2;
      Size := Widths[(FRegs[$0C] shr (i * 2)) and 3] * 2;
      Data := (FRegs[$11] shr (i * 2)) and 3;
      Bits := 2;
    end;
    var Offset := X - Position;
    if (Offset >= 0) and (Offset < Bits * Size) then
      if Data and (1 shl (Bits - 1 - Offset div Size)) <> 0 then
        Result := Result or (1 shl i);
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

function TA5200GTIA.Pixel(X: Integer; Playfield: Byte): TAlphaColor;
begin
  var PF: Byte;
  var Color := BaseColor(Playfield, PF);
  var P := PlayerBits(X, False);
  var M := PlayerBits(X, True);
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
  if (M <> 0) and (FRegs[$1B] and 16 <> 0) then
  begin
    PF := PF or 8;
    Color := FRegs[$19];
    M := 0;
  end;
  var Sprites := P or M;
  for var i := 3 downto 0 do
    if Sprites and (1 shl i) <> 0 then
    begin
      var Front := PF = 0;
      case FRegs[$1B] and 15 of
        0, 1:
          Front := True;
        2:
          Front := (PF = 0) or (i < 2);
        4:
          Front := PF = 0;
        8:
          Front := (PF and 3 = 0);
      end;
      if Front then
      begin
        Color := FRegs[$12 + i];
        if (FRegs[$1B] and 32 <> 0) and (i and 1 = 0) and (Sprites and (2 shl i) <> 0) then
          Color := Color or FRegs[$13 + i];
      end;
    end;
  Result := FPalette[Color];
end;

procedure TA5200GTIA.SerializeState(State: TStateArchive);
begin
  State.Field(FRegs, SizeOf(FRegs));
  State.Field(FHits, SizeOf(FHits));
  State.Field(FTriggers, SizeOf(FTriggers));
end;

end.

