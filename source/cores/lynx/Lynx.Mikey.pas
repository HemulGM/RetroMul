unit Lynx.Mikey;

interface

uses
  System.SysUtils, System.UITypes, Core.Snapshots, Lynx.Types;

type
  TLynxMikey = class
  private
    FRAM: PLynxRAM;
    FRegs: array[0..255] of Byte;
    FPhase: array[0..11] of Integer;
    FDone: array[0..11] of Boolean;
    FIRQ: Byte;
    FDisplayAddress, FSerialBits: Integer;
    FSerialRX: Boolean;
    FSamplePhase: Int64;
    FFrames: UInt64;
    FPixels: TArray<TAlphaColor>;
    FSamples: TArray<SmallInt>;
    FSampleFrames: Integer;
    FFilterL, FFilterR: Double;
    function TimerBase(Index: Integer): Integer;
    procedure TickTimer(Index, Depth: Integer);
    procedure ClockAudio(Channel: Integer);
    procedure DisplayLine;
    procedure UpdateSerialIRQ;
    procedure Sample;
  public
    constructor Create(RAM: PLynxRAM);
    procedure Reset;
    function Read(Address: Byte): Byte;
    procedure Write(Address, Value: Byte);
    procedure Advance(Ticks: Integer);
    procedure BeginAudioFrame;
    function FramesPerSecond: Double;
    procedure SerializeState(State: TStateArchive);
    property IRQ: Byte read FIRQ;
    property FrameNumber: UInt64 read FFrames;
    property Pixels: TArray<TAlphaColor> read FPixels;
    property Samples: TArray<SmallInt> read FSamples;
    property SampleFrames: Integer read FSampleFrames;
  end;

implementation

uses
  System.Math;

constructor TLynxMikey.Create(RAM: PLynxRAM);
begin
  inherited Create;
  FRAM := RAM;
  SetLength(FPixels, LynxWidth * LynxHeight);
  SetLength(FSamples, 4096);
  Reset;
end;

procedure TLynxMikey.Reset;
begin
  FillChar(FRegs, SizeOf(FRegs), 0);
  FillChar(FPhase, SizeOf(FPhase), 0);
  FillChar(FDone, SizeOf(FDone), 0);
  FIRQ := 0;
  FFrames := 0;
  FSamplePhase := 0;
  FSampleFrames := 0;
  FDisplayAddress := 0;
  FSerialBits := 0;
  FSerialRX := False;
  FFilterL := 0;
  FFilterR := 0;
  FRegs[$87] := 2;
  for var I := 0 to High(FPixels) do
    FPixels[I] := $FF000000;
end;

function TLynxMikey.TimerBase(Index: Integer): Integer;
begin
  if Index < 8 then
    Result := Index * 4
  else
    Result := $24 + (Index - 8) * 8;
end;

procedure TLynxMikey.UpdateSerialIRQ;
begin
  if ((FRegs[$8C] and $80 <> 0) and (FSerialBits = 0)) or
    ((FRegs[$8C] and $40 <> 0) and FSerialRX) then
    FIRQ := FIRQ or $10;
end;

function TLynxMikey.Read(Address: Byte): Byte;
begin
  case Address of
    $80, $81:
      Exit(FIRQ);
    $88:
      Exit(1);
    $8B:
      Exit((FRegs[$8B] and FRegs[$8A]) or ($15 and not FRegs[$8A]));
    $8C:
      Exit(Ord(FSerialBits = 0) * $A0 or Ord(FSerialRX) * $40);
    $8D:
      begin
        Result := FRegs[$8D];
        FSerialRX := False;
        Exit;
      end;
  end;
  Result := FRegs[Address];
end;

procedure TLynxMikey.Write(Address, Value: Byte);
begin
  case Address of
    $80:
      begin
        FIRQ := FIRQ and not Value;
        UpdateSerialIRQ;
        Exit;
      end;
    $81:
      begin
        FIRQ := FIRQ or Value;
        Exit;
      end;
    $8D:
      begin
        FSerialBits := 11;
        FSerialRX := False;
      end;
  end;
  FRegs[Address] := Value;
  if Address < $40 then
  begin
    var Index: Integer;
    if Address < $20 then
      Index := Address div 4
    else
      Index := 8 + (Address - $20) div 8;
    var Base := TimerBase(Index);
    if Address = Base + 1 then
    begin
      if Value and $40 <> 0 then
      begin
        FDone[Index] := False;
        FRegs[Base + 3] := FRegs[Base + 3] and $F7;
      end;
      FRegs[Address] := Value and $BF;
      FPhase[Index] := 0;
    end;
    if Address = Base + 3 then
      FDone[Index] := Value and 8 <> 0;
  end;
  if Address = $8C then
    UpdateSerialIRQ;
end;

procedure TLynxMikey.ClockAudio(Channel: Integer);
begin
  var Base := $20 + Channel * 8;
  var Shift := Integer(FRegs[Base + 3]) or ((Integer(FRegs[Base + 7]) and $F0) shl 4);
  var Feedback := Integer(FRegs[Base + 1]);
  var Taps := (Feedback and $3F) or ((Feedback and $C0) shl 4) or ((Integer(FRegs[Base + 5]) and $80));
  var Bits := Shift and Taps;
  var Parity := 1;
  while Bits <> 0 do
  begin
    Parity := Parity xor (Bits and 1);
    Bits := Bits shr 1;
  end;
  Shift := ((Shift shl 1) or Parity) and $FFF;
  FRegs[Base + 3] := Shift and 255;
  FRegs[Base + 7] := (FRegs[Base + 7] and 15) or ((Shift shr 4) and $F0);
  var Volume := Integer(FRegs[Base]);
  if Volume >= 128 then
    Dec(Volume, 256);
  if Parity = 0 then
    Volume := -Volume;
  var Output := Volume;
  if FRegs[Base + 5] and $20 <> 0 then
  begin
    Output := Integer(FRegs[Base + 2]);
    if Output >= 128 then
      Dec(Output, 256);
    Output := EnsureRange(Output + Volume, -128, 127);
  end;
  FRegs[Base + 2] := Output and 255;
end;

procedure TLynxMikey.DisplayLine;
var
  Row, X, Value, Pen, Red, Green, Blue: Integer;
  Flipped: Boolean;
begin
  Row := 101 - Integer(FRegs[$0A]);
  if FRegs[$0A] = 102 then
    FDisplayAddress := (Integer(FRegs[$94]) or (Integer(FRegs[$95]) shl 8)) and $FFFC;
  if (Row < 0) or (Row >= LynxHeight) then
    Exit;
  if FRegs[$92] and 1 = 0 then
    Exit;
  Flipped := FRegs[$92] and 2 <> 0;
  for X := 0 to 159 do
  begin
    Value := FRAM^[(FDisplayAddress + X div 2) and $FFFF];
    if Flipped then
      Value := FRAM^[(FDisplayAddress - X div 2) and $FFFF];
    if Odd(X) xor Flipped then
      Pen := Value and 15
    else
      Pen := Value shr 4;
    Green := (Integer(FRegs[$A0 + Pen]) and 15) * 17;
    Red := (Integer(FRegs[$B0 + Pen]) and 15) * 17;
    Blue := (Integer(FRegs[$B0 + Pen]) shr 4) * 17;
    FPixels[Row * 160 + X] := $FF000000 or Cardinal(Red shl 16) or Cardinal(Green shl 8) or Cardinal(Blue);
  end;
  if Flipped then
    FDisplayAddress := (FDisplayAddress - 80) and $FFFF
  else
    FDisplayAddress := (FDisplayAddress + 80) and $FFFF;
end;

procedure TLynxMikey.TickTimer(Index, Depth: Integer);
const
  Linked: array[0..11] of Integer = (2, 3, 4, 5, -1, 7, -1, 8, 9, 10, 11, 1);
begin
  if Depth > 12 then
    Exit;
  var Base := TimerBase(Index);
  if (FRegs[Base + 1] and 8 = 0) or (FDone[Index] and (FRegs[Base + 1] and $10 = 0)) then
    Exit;
  FRegs[Base + 3] := (FRegs[Base + 3] and $FC) or 2;
  if FRegs[Base + 2] <> 0 then
    Dec(FRegs[Base + 2])
  else
  begin
    FRegs[Base + 3] := FRegs[Base + 3] or 1;
    FDone[Index] := True;
    FRegs[Base + 3] := FRegs[Base + 3] or 8;
    if FRegs[Base + 1] and $10 <> 0 then
      FRegs[Base + 2] := FRegs[Base]
    else
    begin
      FRegs[Base + 2] := 255;
      FDone[Index] := True;
      FRegs[Base + 3] := FRegs[Base + 3] or 8;
    end;
    if Index < 8 then
    begin
      if (Index <> 4) and (FRegs[Base + 1] and $80 <> 0) then
        FIRQ := FIRQ or (1 shl Index);
      case Index of
        0:
          DisplayLine;
        2:
          Inc(FFrames);
        4:
          begin
            if FSerialBits > 0 then
            begin
              Dec(FSerialBits);
              if FSerialBits = 0 then
                FSerialRX := True;
            end;
            UpdateSerialIRQ;
          end;
      end;
    end
    else
      ClockAudio(Index - 8);
    var Next := Linked[Index];
    if (Next >= 0) and (FRegs[TimerBase(Next) + 1] and 7 = 7) then
      TickTimer(Next, Depth + 1);
  end;
end;

procedure TLynxMikey.Sample;
begin
  var L := 0;
  var R := 0;
  for var Channel := 0 to 3 do
  begin
    var Output := Integer(FRegs[$22 + Channel * 8]);
    if Output >= 128 then
      Dec(Output, 256);
    var LeftGain := 15;
    var RightGain := 15;
    if FRegs[$44] and (1 shl (Channel + 4)) <> 0 then
      LeftGain := FRegs[$40 + Channel] shr 4;
    if FRegs[$44] and (1 shl Channel) <> 0 then
      RightGain := FRegs[$40 + Channel] and 15;
    if FRegs[$50] and (1 shl (Channel + 4)) = 0 then
      Inc(L, Output * LeftGain * 4);
    if FRegs[$50] and (1 shl Channel) = 0 then
      Inc(R, Output * RightGain * 4);
  end;
  // Original analog output has a single-pole low-pass filter near 4.5 kHz.
  FFilterL := FFilterL + 0.473 * (L - FFilterL);
  FFilterR := FFilterR + 0.473 * (R - FFilterR);
  if FSampleFrames * 2 + 2 > Length(FSamples) then
    SetLength(FSamples, Length(FSamples) + 4096);
  FSamples[FSampleFrames * 2] := EnsureRange(Round(FFilterL), -32768, 32767);
  FSamples[FSampleFrames * 2 + 1] := EnsureRange(Round(FFilterR), -32768, 32767);
  Inc(FSampleFrames);
end;

procedure TLynxMikey.Advance(Ticks: Integer);
begin
  for var Index := 0 to 11 do
  begin
    var Base := TimerBase(Index);
    var Control := FRegs[Base + 1];
    if (Control and 8 = 0) or (FDone[Index] and (Control and $10 = 0)) or (Control and 7 = 7) then
      Continue;
    var Period := 16 shl (Control and 7);
    Inc(FPhase[Index], Ticks);
    while FPhase[Index] >= Period do
    begin
      Dec(FPhase[Index], Period);
      TickTimer(Index, 0);
    end;
  end;
  Inc(FSamplePhase, Int64(Ticks) * LynxSampleRate);
  while FSamplePhase >= LynxMasterClock do
  begin
    Dec(FSamplePhase, LynxMasterClock);
    Sample;
  end;
end;

procedure TLynxMikey.BeginAudioFrame;
begin
  FSampleFrames := 0;
end;

function TLynxMikey.FramesPerSecond: Double;
begin
  var Period := (Integer(FRegs[0]) + 1) * (16 shl (FRegs[1] and 7)) * (Integer(FRegs[8]) + 1);
  if (FRegs[1] and 8 = 0) or (FRegs[9] and 15 <> 15) or (Period = 0) then
    Exit(60);
  Result := LynxMasterClock / Period;
end;

procedure TLynxMikey.SerializeState(State: TStateArchive);
begin
  State.Field(FRegs, SizeOf(FRegs));
  State.Field(FPhase, SizeOf(FPhase));
  State.Field(FDone, SizeOf(FDone));
  State.Field(FIRQ, SizeOf(FIRQ));
  State.Field(FDisplayAddress, SizeOf(FDisplayAddress));
  State.Field(FSerialBits, SizeOf(FSerialBits));
  State.Field(FSerialRX, SizeOf(FSerialRX));
  State.Field(FSamplePhase, SizeOf(FSamplePhase));
  State.Field(FFrames, SizeOf(FFrames));
  State.Field(FFilterL, SizeOf(FFilterL));
  State.Field(FFilterR, SizeOf(FFilterR));
  State.Field(FPixels[0], Length(FPixels) * SizeOf(TAlphaColor));
  if State.Loading then
    BeginAudioFrame;
end;

end.

