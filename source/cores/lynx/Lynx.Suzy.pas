unit Lynx.Suzy;

interface

uses
  System.SysUtils, Lynx.Types, Lynx.Cartridge, Core.Snapshots;

type
  TLynxSuzy = class
  private
    FRAM: PLynxRAM;
    FCartridge: TLynxCartridge;
    FRegs: array[0..255] of Byte;
    FPalette: array[0..15] of Byte;
    FMathTicks, FSpriteTicks: Integer;
    FMathStatus: Byte;
    FSignAB, FSignCD: Boolean;
    FJoystick, FSwitches: Byte;
    function GetWord(Index: Integer): Integer;
    procedure SetWord(Index, Value: Integer);
    function GetLong(Index: Integer): Cardinal;
    procedure SetLong(Index: Integer; Value: Cardinal);
    procedure Multiply;
    procedure Divide;
    function PaintSprites: Integer;
    procedure PaintPixel(X, Y, Pen, Kind, Collision: Integer; var Highest: Integer; var EverOn: Boolean);
  public
    constructor Create(RAM: PLynxRAM; Cartridge: TLynxCartridge);
    procedure Reset;
    function Read(Address: Byte): Byte;
    procedure Write(Address, Value: Byte);
    procedure Advance(Ticks: Integer);
    function BeginSprites: Integer;
    procedure SetInput(Joystick, Switches: Byte);
    procedure SerializeState(State: TStateArchive);
    property SpriteTicks: Integer read FSpriteTicks;
  end;

implementation

uses
  System.Math;

constructor TLynxSuzy.Create(RAM: PLynxRAM; Cartridge: TLynxCartridge);
begin
  inherited Create;
  FRAM := RAM;
  FCartridge := Cartridge;
  Reset;
end;

procedure TLynxSuzy.Reset;
begin
  FillChar(FRegs, SizeOf(FRegs), 0);
  FillChar(FPalette, SizeOf(FPalette), 0);
  FMathTicks := 0;
  FSpriteTicks := 0;
  FMathStatus := 0;
  FSignAB := False;
  FSignCD := False;
  FJoystick := 0;
  FSwitches := 0;
end;

function TLynxSuzy.GetWord(Index: Integer): Integer;
begin
  Result := Integer(FRegs[Index]) or (Integer(FRegs[Index + 1]) shl 8);
end;

procedure TLynxSuzy.SetWord(Index, Value: Integer);
begin
  FRegs[Index] := Value and 255;
  FRegs[Index + 1] := (Value shr 8) and 255;
end;

function TLynxSuzy.GetLong(Index: Integer): Cardinal;
begin
  Result := Cardinal(GetWord(Index)) or (Cardinal(GetWord(Index + 2)) shl 16);
end;

procedure TLynxSuzy.SetLong(Index: Integer; Value: Cardinal);
begin
  SetWord(Index, Value and $FFFF);
  SetWord(Index + 2, Value shr 16);
end;

procedure TLynxSuzy.Multiply;
begin
  var Product := UInt64(GetWord($54)) * UInt64(GetWord($52));
  if (FRegs[$92] and $80 <> 0) and (FSignAB xor FSignCD) then
    Product := (UInt64($100000000) - Product) and $FFFFFFFF;
  SetLong($60, Cardinal(Product));
  if FRegs[$92] and $40 <> 0 then
  begin
    var Sum := UInt64(GetLong($6C)) + Product;
    FMathStatus := Ord(Sum > $FFFFFFFF) * $40;
    SetLong($6C, Cardinal(Sum and $FFFFFFFF));
  end;
  FMathTicks := 54;
  if FRegs[$92] and $C0 <> 0 then
    FMathTicks := 54 + 16;
end;

procedure TLynxSuzy.Divide;
begin
  var Dividend := GetLong($60);
  var Divisor := GetWord($56);
  FMathStatus := 0;
  if Divisor = 0 then
  begin
    SetLong($52, $FFFFFFFF);
    SetLong($6C, 0);
    FMathStatus := $60;
  end
  else
  begin
    SetLong($52, Dividend div Cardinal(Divisor));
    SetLong($6C, Dividend mod Cardinal(Divisor));
  end;
  var Leading := 0;
  for var Bit := 15 downto 0 do
    if Divisor and (1 shl Bit) = 0 then
      Inc(Leading)
    else
      Break;
  FMathTicks := 176 + 14 * Leading;
end;

function TLynxSuzy.Read(Address: Byte): Byte;
begin
  case Address of
    $88:
      Exit(1);
    $92:
      Exit((FRegs[$92] and $1A) or FMathStatus or Ord(FMathTicks > 0) * $80 or Ord(FSpriteTicks > 0));
    $B0:
      begin
        Result := FJoystick;
        // Physical pad inputs are Up=$40/Down=$80/Left=$10/Right=$20.
        // SPRSYS.Lefthand=0 reverses these pairs when JOYSTICK is read.
        if FRegs[$92] and 8 = 0 then
          Result := (Result and 15) or ((Result and $A0) shr 1) or ((Result and $50) shl 1);
        Exit;
      end;
    $B1:
      Exit(FSwitches);
    $B2, $B3:
      Exit(FCartridge.Read(Address and 1));
  end;
  Result := FRegs[Address];
end;

procedure TLynxSuzy.Write(Address, Value: Byte);
begin
  if Address in [$B2, $B3] then
  begin
    FCartridge.Write(Address and 1, Value);
    Exit;
  end;
  FRegs[Address] := Value;
  if (Address < $80) and not Odd(Address) then
    FRegs[Address + 1] := 0;
  if (Address = $53) or (Address = $55) then
  begin
    var Negative := False;
    var WordValue := GetWord(Address - 1);
    if FRegs[$92] and $80 <> 0 then
    begin
      Negative := WordValue and $8000 <> 0;
      if Negative then
        SetWord(Address - 1, (-WordValue) and $FFFF);
    end;
    if Address = $53 then
      FSignCD := Negative
    else
      FSignAB := Negative;
  end;
  case Address of
    $55:
      Multiply;
    $63:
      Divide;
    $6C:
      FMathStatus := 0;
    $91:
      FRegs[$92] := FRegs[$92] and $FD;
  end;
end;

procedure TLynxSuzy.SetInput(Joystick, Switches: Byte);
begin
  FJoystick := Joystick;
  FSwitches := Switches;
end;

procedure TLynxSuzy.Advance(Ticks: Integer);
begin
  FMathTicks := Max(0, FMathTicks - Ticks);
  if FSpriteTicks > 0 then
  begin
    FSpriteTicks := Max(0, FSpriteTicks - Ticks);
    if FSpriteTicks = 0 then
      FRegs[$91] := FRegs[$91] and $FE;
  end;
end;

procedure TLynxSuzy.PaintPixel(X, Y, Pen, Kind, Collision: Integer; var Highest: Integer; var EverOn: Boolean);
begin
  if (X < 0) or (X >= 160) or (Y < 0) or (Y >= 102) then
    Exit;
  EverOn := True;
  var Opaque := (Pen <> 0) or (Kind in [0, 1]);
  if (Pen = 15) and (Kind in [2, 3]) then
    Opaque := False;
  if Opaque then
  begin
    var Address := (GetWord(8) + Y * 80 + X div 2) and $FFFF;
    var Shift := (1 - (X and 1)) * 4;
    var Value := Integer(FRAM^[Address]);
    var NewPen := Pen;
    if Kind = 6 then
      NewPen := ((Value shr Shift) and 15) xor Pen;
    FRAM^[Address] := (Value and not (15 shl Shift)) or (NewPen shl Shift);
  end;
  var Collidable := (Kind <> 1) and (Kind <> 5) and (Collision and $20 = 0) and (FRegs[$92] and $20 = 0);
  if Pen = 0 then
    Collidable := Collidable and (Kind = 0);
  if Pen = 14 then
    Collidable := Collidable and (Kind in [3, 4]);
  if Collidable then
  begin
    var Address := (GetWord($0A) + Y * 80 + X div 2) and $FFFF;
    var Shift := (1 - (X and 1)) * 4;
    var Value := Integer(FRAM^[Address]);
    if Kind <> 0 then
      Highest := Max(Highest, (Value shr Shift) and 15);
    FRAM^[Address] := (Value and not (15 shl Shift)) or ((Collision and 15) shl Shift);
  end;
end;

function TLynxSuzy.PaintSprites: Integer;
var
  DataAddress, BitPosition, BitsLeft: Integer;

  function RAMWord(Address: Integer): Integer;
  begin
    Result := Integer(FRAM^[Address and $FFFF]) or (Integer(FRAM^[(Address + 1) and $FFFF]) shl 8);
  end;

  function ReadBits(Count: Integer): Integer;
  begin
    Result := 0;
    for var I := 1 to Count do
    begin
      Result := (Result shl 1) or ((FRAM^[(DataAddress + BitPosition div 8) and $FFFF] shr (7 - (BitPosition and 7))) and 1);
      Inc(BitPosition);
    end;
    Dec(BitsLeft, Count);
  end;

begin
  Result := 0;
  var SCB := GetWord($10);
  var SpriteCount := 0;
  while SCB and $FF00 <> 0 do
  begin
    Inc(SpriteCount);
    if SpriteCount > 4096 then
      Break;
    SetWord($2C, SCB);
    var Ctl0 := FRAM^[SCB];
    var Ctl1 := FRAM^[(SCB + 1) and $FFFF];
    var Collision := FRAM^[(SCB + 2) and $FFFF];
    FRegs[$80] := Ctl0;
    FRegs[$81] := Ctl1;
    FRegs[$82] := Collision;
    var Next := RAMWord(SCB + 3);
    SetWord($10, Next);
    Inc(Result, 5 * 5);
    if Ctl1 and 4 = 0 then
    begin
      var Ptr := SCB + 5;
      for var Reg := 0 to 2 do
      begin
        SetWord($12 + Reg * 2, RAMWord(Ptr));
        Inc(Ptr, 2);
      end;
      var Reload := (Ctl1 shr 4) and 3;
      if Reload > 0 then
      begin
        SetWord($18, RAMWord(Ptr));
        Inc(Ptr, 2);
        SetWord($1A, RAMWord(Ptr));
        Inc(Ptr, 2);
      end;
      if Reload > 1 then
      begin
        SetWord($1C, RAMWord(Ptr));
        Inc(Ptr, 2);
      end;
      if Reload > 2 then
      begin
        SetWord($1E, RAMWord(Ptr));
        Inc(Ptr, 2);
      end;
      if Ctl1 and 8 = 0 then
        for var I := 0 to 7 do
        begin
          var Value := FRAM^[(Ptr + I) and $FFFF];
          FPalette[I * 2] := Value shr 4;
          FPalette[I * 2 + 1] := Value and 15;
        end;
      var StartX := (GetWord($14) - GetWord(4)) and $FFFF;
      if StartX >= $8000 then
        Dec(StartX, $10000);
      var StartY := (GetWord($16) - GetWord(6)) and $FFFF;
      if StartY >= $8000 then
        Dec(StartY, $10000);
      var HSize := GetWord($18);
      var VSize := GetWord($1A);
      var Stretch := 0;
      var Tilt := 0;
      if Reload > 1 then
        Stretch := GetWord($1C);
      if Reload > 2 then
        Tilt := GetWord($1E);
      if Stretch >= $8000 then
        Dec(Stretch, $10000);
      if Tilt >= $8000 then
        Dec(Tilt, $10000);
      var BPP := 1 + (Ctl0 shr 6);
      var Highest := 0;
      var EverOn := False;
      var InitialQuadrant := (Ctl1 shr 1) and 1;
      if Ctl1 and 1 <> 0 then
        InitialQuadrant := 3 - InitialQuadrant;
      // Quadrants rotate clockwise: down-right, up-right, up-left, down-left.
      var Quadrant := InitialQuadrant;
      var DirectionX := 1;
      var DirectionY := 1;
      if Quadrant >= 2 then
        DirectionX := -1;
      if Quadrant in [1, 2] then
        DirectionY := -1;
      if Ctl0 and $20 <> 0 then
        DirectionX := -DirectionX;
      if Ctl0 and $10 <> 0 then
        DirectionY := -DirectionY;
      var Y := StartY;
      var VAccum := 0;
      if DirectionY > 0 then
        VAccum := GetWord($2A);
      var TiltAccum := 0;
      var Line := GetWord($12);
      var SourceLines := 0;
      repeat
        Inc(SourceLines);
        if SourceLines > 4096 then
          Break;
        var Offset := Integer(FRAM^[Line]);
        if Offset = 0 then
          Break;
        if Offset = 1 then
        begin
          Quadrant := (Quadrant + 1) and 3;
          if Quadrant = InitialQuadrant then
            Break;
          DirectionX := 1;
          DirectionY := 1;
          if Quadrant >= 2 then
            DirectionX := -1;
          if Quadrant in [1, 2] then
            DirectionY := -1;
          if Ctl0 and $20 <> 0 then
            DirectionX := -DirectionX;
          if Ctl0 and $10 <> 0 then
            DirectionY := -DirectionY;
          Y := StartY;
          // Do not paint the pivot row/column twice across quadrant boundaries.
          if ((Quadrant xor InitialQuadrant) and 1) <> 0 then
            Inc(Y, DirectionY);
          VAccum := 0;
          if DirectionY > 0 then
            VAccum := GetWord($2A);
          TiltAccum := 0;
          Line := (Line + 1) and $FFFF;
          Continue;
        end;
        VAccum := VAccum + VSize;
        var Repeats := VAccum shr 8;
        VAccum := VAccum and 255;
        for var Row := 1 to Repeats do
        begin
          var SignedTilt := TiltAccum;
          if SignedTilt and $8000 <> 0 then
            Dec(SignedTilt, $10000);
          var X := StartX + ((SignedTilt + $8000) div 256 - $80);
          if ((Quadrant >= 2) <> (InitialQuadrant >= 2)) then
            Inc(X, DirectionX);
          var HAccum := 0;
          if DirectionX > 0 then
            HAccum := GetWord($28);
          DataAddress := (Line + 1) and $FFFF;
          BitPosition := 0;
          BitsLeft := (Offset - 1) * 8;
          while BitsLeft >= BPP do
          begin
            var Count := 1;
            var Literal := True;
            if Ctl1 and $80 = 0 then
            begin
              if BitsLeft < 5 then
                Break;
              Literal := ReadBits(1) <> 0;
              Count := ReadBits(4);
              if not Literal and (Count = 0) then
                Break;
              Inc(Count);
            end;
            var Pen := 0;
            for var Pixel := 1 to Count do
            begin
              if Literal or (Pixel = 1) then
              begin
                if BitsLeft < BPP then
                  Break;
                Pen := FPalette[ReadBits(BPP)];
              end;
              Inc(HAccum, HSize);
              var Width := HAccum shr 8;
              HAccum := HAccum and 255;
              for var Col := 1 to Width do
              begin
                PaintPixel(X, Y, Pen, Ctl0 and 7, Collision, Highest, EverOn);
                Inc(X, DirectionX);
                Inc(Result, 5);
              end;
            end;
          end;
          Inc(Y, DirectionY);
          HSize := (HSize + Stretch) and $FFFF;
          if FRegs[$92] and $10 <> 0 then
            VSize := (VSize + Stretch) and $FFFF;
          TiltAccum := (TiltAccum + Tilt) and $FFFF;
        end;
        Inc(Result, Offset * 5);
        Line := (Line + Offset) and $FFFF;
      until False;
      var Depository := (SCB + GetWord($24)) and $FFFF;
      if (Ctl0 and 7 in [2, 3, 4, 6, 7]) and (Collision and $20 = 0) and (FRegs[$92] and $20 = 0) then
        FRAM^[Depository] := Highest;
      if FRegs[$91] and 4 <> 0 then
        FRAM^[Depository] := (FRAM^[Depository] and $7F) or (Ord(not EverOn) shl 7);
      SetWord($18, HSize);
      SetWord($1A, VSize);
      SetWord($12, Line);
    end;
    SCB := Next;
    if FRegs[$92] and 2 <> 0 then
      Break;
  end;
end;

function TLynxSuzy.BeginSprites: Integer;
begin
  Result := 0;
  if (FRegs[$90] and 1 = 0) or (FRegs[$91] and 1 = 0) or (FSpriteTicks <> 0) then
    Exit;
  Result := Max(1, PaintSprites);
  FSpriteTicks := Result;
end;

procedure TLynxSuzy.SerializeState(State: TStateArchive);
begin
  State.Field(FRegs, SizeOf(FRegs));
  State.Field(FPalette, SizeOf(FPalette));
  State.Field(FMathTicks, SizeOf(FMathTicks));
  State.Field(FSpriteTicks, SizeOf(FSpriteTicks));
  State.Field(FMathStatus, SizeOf(FMathStatus));
  State.Field(FSignAB, SizeOf(FSignAB));
  State.Field(FSignCD, SizeOf(FSignCD));
end;

end.

