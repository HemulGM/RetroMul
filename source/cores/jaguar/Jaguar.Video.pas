unit Jaguar.Video;

interface

uses
  System.SysUtils, Jaguar.RISC, Core.Emulation.Types, Core.Snapshots;

type
  TJaguarIRQ = procedure(Line: Integer) of object;

  TJaguarVideo = class
  private
    FRead: TJaguarRead;
    FWrite: TJaguarWrite;
    FGPUInterrupt, FCPUInterrupt: TJaguarIRQ;
    FMemory: array[0..$1FFF] of Byte;
    FFrame: TEmulatorFrame;
    FCursor: Cardinal;
    FVC, FEnable, FPending: Word;
    FObjects, FTimer, FHC, FBasePixelWidth: Integer;
    FStopped, FPAL: Boolean;
    function GetWord(Offset: Integer): Word;
    procedure PutWord(Offset: Integer; Value: Word);
    function Phrase(Address: Cardinal): UInt64;
    procedure WritePhrase(Address: Cardinal; Value: UInt64);
    procedure Bitmap(Address: Cardinal; Header: UInt64; Scaled: Boolean);
    function Color(Value: Word): Cardinal;
  public
    constructor Create(Reader: TJaguarRead; Writer: TJaguarWrite; GPUIRQ, CPUIRQ: TJaguarIRQ; PAL: Boolean);
    procedure Reset;
    function Read(Offset: Cardinal; Size: Integer): Cardinal;
    procedure Write(Offset, Value: Cardinal; Size: Integer);
    procedure BeginFrame;
    procedure BeginLine(VC: Integer);
    procedure ProcessObjects;
    procedure DisplayLine;
    procedure EndFrame;
    procedure Clock(Cycles: Integer);
    procedure RaiseIRQ(Line: Integer);
    procedure SetJerryIRQ(Active: Boolean);
    procedure SerializeState(State: TStateArchive);
    property Frame: TEmulatorFrame read FFrame;
    property VC: Word read FVC;
  end;

implementation

uses
  System.Math, System.Classes;

{$Q-}{$R-}

constructor TJaguarVideo.Create(Reader: TJaguarRead; Writer: TJaguarWrite; GPUIRQ, CPUIRQ: TJaguarIRQ; PAL: Boolean);
begin
  inherited Create;
  FRead := Reader;
  FWrite := Writer;
  FGPUInterrupt := GPUIRQ;
  FCPUInterrupt := CPUIRQ;
  FPAL := PAL;
  Reset;
end;

function TJaguarVideo.GetWord(Offset: Integer): Word;
begin
  Result := (Word(FMemory[Offset and $1FFF]) shl 8) or FMemory[(Offset + 1) and $1FFF];
end;

procedure TJaguarVideo.PutWord(Offset: Integer; Value: Word);
begin
  FMemory[Offset and $1FFF] := Value shr 8;
  FMemory[(Offset + 1) and $1FFF] := Value and 255;
end;

procedure TJaguarVideo.Reset;
begin
  FillChar(FMemory, SizeOf(FMemory), 0);
  FVC := 0;
  FEnable := 0;
  FPending := 0;
  FCursor := 0;
  FStopped := True;
  FObjects := 0;
  FTimer := 0;
  FHC := 0;
  FBasePixelWidth := 4;
  PutWord($28, $6C1);
  PutWord($2E, 844);
  PutWord($3E, 523);
  PutWord($46, 38);
  PutWord($48, 518);
  PutWord($4E, $FFFF);
  if FPAL then
  begin
    PutWord($3E, 623);
    PutWord($46, 78);
    PutWord($48, 558);
  end;
  FFrame := Default(TEmulatorFrame);
  FFrame.Width := 320;
  FFrame.Height := 240;
  FFrame.FramesPerSecond := 26590906.0 / (845 * 2 * 262);
  if FPAL then
    FFrame.FramesPerSecond := 26593900.0 / (851 * 2 * 312);
  SetLength(FFrame.Pixels, 320 * 240);
end;

procedure TJaguarVideo.RaiseIRQ(Line: Integer);
begin
  FPending := FPending or (1 shl Line);
  if FPending and FEnable <> 0 then
    FCPUInterrupt(2);
end;

procedure TJaguarVideo.SetJerryIRQ(Active: Boolean);
begin
  // Jerry supplies a level to TOM, not another independently sticky latch.
  // Acknowledging J_INT must remove it from INT1's readback too.
  FPending := FPending and not Word($10);
  if Active then
    FPending := FPending or $10;
  if FPending and FEnable <> 0 then
    FCPUInterrupt(2)
  else
    FCPUInterrupt(0);
end;

function TJaguarVideo.Read(Offset: Cardinal; Size: Integer): Cardinal;
begin
  Result := 0;
  for var i := 0 to Size - 1 do
  begin
    var Address := (Offset + Cardinal(i)) and $1FFF;
    var Value := FMemory[Address];
    case Address of
      4:
        Value := (FHC shr 8) or ((FVC and 1) shl 2);
      5:
        Value := FHC and 255;
      6:
        Value := FVC shr 8;
      7:
        Value := FVC and 255;
      $E0:
        Value := 0;
      $E1:
        Value := FPending;
    end;
    Result := (Result shl 8) or Value;
  end;
end;

procedure TJaguarVideo.Write(Offset, Value: Cardinal; Size: Integer);
begin
  for var i := 0 to Size - 1 do
  begin
    var Address := (Offset + Cardinal(i)) and $1FFF;
    var V := Byte(Value shr ((Size - 1 - i) * 8));
    FMemory[Address] := V;
    if (Address >= $400) and (Address < $800) then
    begin
      FMemory[Address xor $200] := V;
    end;
  end;
  if (Offset <= $E1) and (Offset + Cardinal(Size) > $E0) then
  begin
    var V := GetWord($E0);
    FEnable := V and 31;
    FPending := FPending and not (V shr 8);
    if FPending and FEnable <> 0 then
      FCPUInterrupt(2)
    else
      FCPUInterrupt(0);
  end;
  if (Offset <= $27) and (Offset + Cardinal(Size) > $26) then
  begin
    FStopped := False;
    ProcessObjects;
  end;
end;

function TJaguarVideo.Phrase(Address: Cardinal): UInt64;
begin
  Result := (UInt64(FRead(Address, 4)) shl 32) or FRead(Address + 4, 4);
end;

procedure TJaguarVideo.WritePhrase(Address: Cardinal; Value: UInt64);
begin
  FWrite(Address, Cardinal(Value shr 32), 4);
  FWrite(Address + 4, Cardinal(Value), 4);
end;

procedure TJaguarVideo.Bitmap(Address: Cardinal; Header: UInt64; Scaled: Boolean);
begin
  var Height := Integer((Header shr 14) and $3FF);
  var Y := Integer((Header shr 3) and $7FF);
  if (Integer(FVC) < Y) or (Height = 0) then
    Exit;
  var P2 := Phrase(Address + 8);
  var X := Integer(P2 and $FFF);
  if X and $800 <> 0 then
    Dec(X, $1000);
  var Depth := Integer((P2 shr 12) and 7);
  if Depth > 5 then
    Exit;
  var Bits := 1 shl Depth;
  var Pitch := Integer((P2 shr 15) and 7) * 8;
  var Width := Integer((P2 shr 28) and $3FF);
  var DataWidth := Integer((P2 shr 18) and $3FF) * 8;
  var Palette := Integer((P2 shr 37) and $FE);
  var Reflected := P2 and (UInt64(1) shl 45) <> 0;
  var Transparent := P2 and (UInt64(1) shl 47) <> 0;
  var RMW := P2 and (UInt64(1) shl 46) <> 0;
  var First := Integer((P2 shr 49) and 63);
  var Data := Cardinal((Header shr 43) shl 3);
  var HScale := 32;
  var VScale := 32;
  var Remainder := 32;
  var P3: UInt64 := 0;
  if Scaled then
  begin
    P3 := Phrase(Address + 16);
    HScale := P3 and 255;
    VScale := (P3 shr 8) and 255;
    Remainder := (P3 shr 16) and 255;
  end;
  var Output := 0;
  var LastPixel := -1;
  var Count := Min(Width * (64 div Bits), 32768);
  for var Pixel := First div Bits to Count - 1 do
  begin
    if HScale = 0 then
      Break;
    var BitIndex := Pixel * Bits;
    var Source := Phrase(Data + Cardinal((BitIndex div 64) * Pitch));
    var V := Cardinal(Source shr (64 - Bits - (BitIndex and 63)));
    if Bits < 32 then
      V := V and ((Cardinal(1) shl Bits) - 1);
    var Physical := V;
    if Bits < 16 then
    begin
      var Index := (Palette and not ((1 shl Bits) - 1)) or Integer(V);
      Physical := GetWord($400 + (Index and 255) * 2);
    end;
    var EndPixel := ((Pixel - First div Bits + 1) * HScale) div 32;
    while Output < EndPixel do
    begin
      var Destination := X + Output;
      if Reflected then
        Destination := X - Output;
      if (Destination >= 0) and (Destination < 720) and (not Transparent or (V <> 0)) then
      begin
        var ByteOffset := $1800 + Destination * 2;
        if Bits = 32 then
          ByteOffset := $1800 + Destination * 4;
        if (ByteOffset >= $1800) and (ByteOffset + (Bits div 8) < $1DA0) then
        begin
          if Bits = 32 then
          begin
            PutWord(ByteOffset, Physical shr 16);
            PutWord(ByteOffset + 2, Physical and $FFFF);
          end
          else
          begin
            if RMW then
            begin
              var Old := GetWord(ByteOffset);
              var Intensity := EnsureRange(Integer(Old and 255) + Integer(ShortInt(Physical and 255)), 0, 255);
              var Cyan := EnsureRange(Integer((Old shr 12) and 15) + ((Integer((Physical shr 12) and 15) xor 8) - 8), 0, 15);
              var Red := EnsureRange(Integer((Old shr 8) and 15) + ((Integer((Physical shr 8) and 15) xor 8) - 8), 0, 15);
              Physical := (Cyan shl 12) or (Red shl 8) or Intensity;
            end;
            PutWord(ByteOffset, Physical);
          end;
        end;
      end;
      Inc(Output);
      LastPixel := Destination;
    end;
    if (LastPixel > 720) and not Reflected then
      Break;
    if (LastPixel < -1) and Reflected then
      Break;
  end;
  var Advance := 1;
  if Scaled then
  begin
    Advance := 0;
    Dec(Remainder, 32);
    if VScale = 0 then
      VScale := 32;
    while (Remainder < 0) and (Advance < Height) do
    begin
      Inc(Remainder, VScale);
      Inc(Advance);
    end;
    P3 := (P3 and not (UInt64($FF) shl 16)) or (UInt64(Remainder and 255) shl 16);
    WritePhrase(Address + 16, P3);
  end;
  Height := Max(0, Height - Advance);
  Data := Data + Cardinal(DataWidth * Advance);
  Header := (Header and ((UInt64(1) shl 43) - 1)) or (UInt64(Data shr 3) shl 43);
  Header := (Header and not (UInt64($3FF) shl 14)) or (UInt64(Height) shl 14);
  WritePhrase(Address, Header);
end;

procedure TJaguarVideo.BeginFrame;
begin
  var PixelWidth := ((GetWord($28) shr 9) and 7) + 1;
  FBasePixelWidth := PixelWidth;
  var Start := Integer(GetWord($38) and $3FF);
  var Finish := Integer(GetWord($3C) and $3FF);
  if GetWord($3C) and $400 <> 0 then
    Inc(Finish, Integer(GetWord($2E)) + 1);
  var Width := (Finish - Start) div PixelWidth;
  var Height := (Min(Integer(GetWord($48)), Integer(GetWord($3E)) + 1) - Integer(GetWord($46))) div 2;
  var Limit := 720;
  if GetWord($28) and 6 = 2 then
    Limit := 360;
  if (Width < 64) or (Width > Limit) then
    Width := 320;
  if (Height < 32) or (Height > 512) then
    Height := 240;
  if (Width <> FFrame.Width) or (Height <> FFrame.Height) then
  begin
    FFrame.Width := Width;
    FFrame.Height := Height;
    SetLength(FFrame.Pixels, Width * Height);
  end;
end;

procedure TJaguarVideo.BeginLine(VC: Integer);
begin
  FVC := VC;
  FHC := 0;
  if FVC = GetWord($4E) then
  begin
    RaiseIRQ(0);
    FGPUInterrupt(2);
  end;
  if GetWord($28) and $80 <> 0 then
    for var X := 0 to 719 do
      PutWord($1800 + X * 2, GetWord($58));
  FObjects := 0;
  FCursor := (Cardinal(GetWord($22)) shl 16) or GetWord($20);
  FStopped := False;
  if (VC < GetWord($46)) or (VC >= GetWord($48)) then
    FStopped := True;
  ProcessObjects;
end;

procedure TJaguarVideo.ProcessObjects;
begin
  while not FStopped and (FObjects < 2048) do
  begin
    Inc(FObjects);
    var Address := FCursor and $FFFFF8;
    var Header := Phrase(Address);
    var Link := Cardinal((Header shr 24) and $7FFFF) shl 3;
    FCursor := Address + 8;
    case Header and 7 of
      0, 1:
        begin
          Bitmap(Address, Header, Header and 7 = 1);
          FCursor := Link;
        end;
      2:
        begin
          for var i := 0 to 3 do
            PutWord($10 + i * 2, Header shr (48 - i * 16));
          FStopped := True;
          FGPUInterrupt(3);
        end;
      3:
        begin
          var Y := Integer((Header shr 3) and $7FF);
          var Take := False;
          case (Header shr 14) and 7 of
            0:
              Take := (Y = FVC) or (Y = $7FF);
            1:
              Take := Y > FVC;
            2:
              Take := Y < FVC;
            3:
              Take := GetWord($26) and 1 <> 0;
            4:
              Take := False;
          end;
          if Take then
            FCursor := Link;
        end;
      4:
        begin
          FStopped := True;
          if Header and 8 <> 0 then
            RaiseIRQ(2);
        end;
    else
      FStopped := True;
    end;
  end;
end;

function TJaguarVideo.Color(Value: Word): Cardinal;
begin
  var Mode := (GetWord($28) shr 1) and 3;
  if (Mode = 3) or ((GetWord($28) and $100 <> 0) and (Value and 1 <> 0)) then
  begin
    var R := (Value shr 11) and 31;
    var B := (Value shr 6) and 31;
    var G := Value and 63;
    Exit($FF000000 or (Cardinal((R * 255) div 31) shl 16) or
      (Cardinal((G * 255) div 63) shl 8) or Cardinal((B * 255) div 31));
  end;
  // CRY is a chroma square: C runs from blue to red, R from saturated
  // color to white. Intensity multiplies each 8-bit DAC channel.
  var C := Integer(Value shr 12);
  var Chroma := Integer((Value shr 8) and 15);
  var Y := Integer(Value and 255);
  var Distance := Min(C, 15 - C);
  var Slope := 17.0 + Distance * 16.0 / 7.0;
  if Distance <> 0 then
    Slope := Slope * 255.0 / 256.0;
  var RedBase := Round(C * 237.0 / 7.0);
  var BlueBase := Round((15 - C) * 237.0 / 7.0);
  var Red := Min(RedBase, Trunc((15 - Chroma) * Slope));
  var Blue := Min(BlueBase, Trunc((15 - Chroma) * Slope));
  if C >= 8 then
    Red := Min(255, 17 + (C - 8) * 34 + Trunc((15 - Chroma) * Slope));
  if C <= 7 then
    Blue := Min(255, 17 + (7 - C) * 34 + Trunc((15 - Chroma) * Slope));
  var Green := Min(255, Trunc(Chroma * Slope));
  Result := $FF000000 or (Cardinal((Red * Y) shr 8) shl 16) or
    (Cardinal((Green * Y) shr 8) shl 8) or Cardinal((Blue * Y) shr 8);
end;

procedure TJaguarVideo.DisplayLine;
begin
  var Y := (Integer(FVC) - Integer(GetWord($46))) div 2;
  if (Integer(FVC) < GetWord($46)) or (Y >= FFrame.Height) then
    Exit;
  var RGB24 := GetWord($28) and 6 = 2;
  for var X := 0 to FFrame.Width - 1 do
  begin
    var CurrentPixelWidth := ((GetWord($28) shr 9) and 7) + 1;
    var SourceX := Min(719, X * FBasePixelWidth div CurrentPixelWidth);
    var Pixel := Color(GetWord($1800 + SourceX * 2));
    if RGB24 then
    begin
      var High := GetWord($1800 + Min(SourceX, 359) * 4);
      var Low := GetWord($1802 + Min(SourceX, 359) * 4);
      Pixel := $FF000000 or (Cardinal(Low and 255) shl 16) or (Cardinal(Low shr 8) shl 8) or (High and 255);
    end;
    FFrame.Pixels[Y * FFrame.Width + X] := Pixel;
  end;
end;

procedure TJaguarVideo.Clock(Cycles: Integer);
begin
  Inc(FHC, Cycles);
  var HalfPeriod := Integer(GetWord($2E)) + 1;
  if FHC >= HalfPeriod then
  begin
    Dec(FHC, HalfPeriod);
    Inc(FVC);
    if FVC = GetWord($4E) then
    begin
      RaiseIRQ(0);
      FGPUInterrupt(2);
    end;
  end;
  var Period := (Integer(GetWord($50)) + 1) * (Integer(GetWord($52)) + 1);
  if (GetWord($50) <> 0) and (GetWord($52) <> 0) then
  begin
    Inc(FTimer, Cycles);
    if FTimer >= Period then
    begin
      Dec(FTimer, Period);
      RaiseIRQ(3);
      FGPUInterrupt(2);
    end;
  end;
end;

procedure TJaguarVideo.EndFrame;
begin
  Inc(FFrame.FrameNumber);
end;

procedure TJaguarVideo.SerializeState(State: TStateArchive);
begin
  State.Field(FMemory, SizeOf(FMemory));
  State.Field(FCursor, SizeOf(FCursor));
  State.Field(FVC, SizeOf(FVC));
  State.Field(FEnable, SizeOf(FEnable));
  State.Field(FPending, SizeOf(FPending));
  State.Field(FObjects, SizeOf(FObjects));
  State.Field(FTimer, SizeOf(FTimer));
  State.Field(FHC, SizeOf(FHC));
  State.Field(FBasePixelWidth, SizeOf(FBasePixelWidth));
  State.Field(FStopped, SizeOf(FStopped));
  State.Field(FFrame.FrameNumber, SizeOf(FFrame.FrameNumber));
  State.Field(FFrame.Width, SizeOf(FFrame.Width));
  State.Field(FFrame.Height, SizeOf(FFrame.Height));
  if State.Loading then
  begin
    if (FFrame.Width < 1) or (FFrame.Width > 720) or (FFrame.Height < 1) or (FFrame.Height > 512) then
      raise EReadError.Create('Invalid Jaguar snapshot video dimensions');
    SetLength(FFrame.Pixels, FFrame.Width * FFrame.Height);
  end;
  State.Field(FFrame.Pixels[0], Length(FFrame.Pixels) * SizeOf(Cardinal));
end;

end.

