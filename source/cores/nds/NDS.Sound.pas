unit NDS.Sound;

interface

uses
  System.SysUtils, System.Classes, System.Math, HW.ARM, Core.Snapshots;

const
  NDS_SAMPLE_RATE = 44100;
  NDS_BUS_CLOCK = 33513982;

type
  TNDSSoundChannel = record
    Control, Source, Length: Cardinal;
    Timer, Loop: Word;
    Position, Phase, Sample, Predictor, Index, LoopPredictor, LoopIndex: Integer;
    Noise: Word;
    Clock: Int64;
    Started, HighNibble: Boolean;
  end;

  PNDSSoundChannel = ^TNDSSoundChannel;

  TNDSSound = class
  private
    FRead: TARMRead;
    FSampleClock: Int64;
    FPendingCycles: Integer;
    FDeferredCycles, FClockDeadline: Integer;
    procedure ScheduleClock;
    procedure ClockBoundary;
    procedure Clock(Cycles: Integer);
    procedure Start(Index: Integer);
    procedure Advance(Index: Integer);
    procedure MixSample;
  public
    Channels: array[0..15] of TNDSSoundChannel;
    Control, Bias: Word;
    Samples: TArray<SmallInt>;
    SampleFrames: Integer;
    constructor Create(Read: TARMRead);
    procedure Reset;
    procedure SerializeState(State: TStateArchive);
    procedure Tick(Cycles: Integer); inline;
    procedure Flush;
    function ReadRegister(Offset: Integer): Byte;
    procedure WriteRegister(Offset: Integer; Value: Byte);
    procedure BeginFrame;
    property PendingCycles: Integer read FPendingCycles;
  end;

implementation

const
  ADPCMStep: array[0..88] of Integer = (7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31,
    34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253,
    279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411,
    1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894,
    6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350,
    22385, 24623, 27086, 29794, 32767);
  ADPCMIndex: array[0..7] of Integer = (-1, -1, -1, -1, 2, 4, 6, 8);
  Divisors: array[0..3] of Integer = (1, 2, 4, 16);

constructor TNDSSound.Create(Read: TARMRead);
begin
  inherited Create;
  FRead := Read;
  SetLength(Samples, 4096);
  Reset;
end;

procedure TNDSSound.Reset;
begin
  FillChar(Channels, SizeOf(Channels), 0);
  Control := 0;
  Bias := $200;
  FSampleClock := 0;
  FPendingCycles := 0;
  FDeferredCycles := 0;
  ScheduleClock;
  SampleFrames := 0;
end;

procedure TNDSSound.BeginFrame;
begin
  SampleFrames := 0;
end;

procedure TNDSSound.Start(Index: Integer);
begin
  var C: PNDSSoundChannel := @Channels[Index];
  C.Position := 0;
  C.Phase := 0;
  C.Clock := 0;
  C.Sample := 0;
  C.Noise := $7FFF;
  C.HighNibble := False;
  C.Started := True;
  if C.Control shr 29 and 3 = 2 then
  begin
    var Header := FRead(C.Source, 4);
    C.Predictor := SmallInt(Header and $FFFF);
    C.Index := Min(88, Integer((Header shr 16) and $7F));
    C.LoopPredictor := C.Predictor;
    C.LoopIndex := C.Index;
    C.Position := 4;
    C.Sample := C.Predictor;
  end;
end;

procedure TNDSSound.Advance(Index: Integer);
begin
  var C: PNDSSoundChannel := @Channels[Index];
  var Format := (C.Control shr 29) and 3;
  if Format = 3 then
  begin
    if Index in [8..13] then
    begin
      C.Sample := -32767;
      if C.Phase <= Integer((C.Control shr 24) and 7) then
        C.Sample := 32767;
      if (C.Control shr 24) and 7 = 7 then
        C.Sample := -32767;
      C.Phase := (C.Phase + 1) and 7;
    end
    else if Index >= 14 then
    begin
      var Bit := C.Noise and 1;
      C.Noise := C.Noise shr 1;
      if Bit <> 0 then
        C.Noise := C.Noise xor $6000;
      C.Sample := 32767;
      if Bit <> 0 then
        C.Sample := -32767;
    end;
    Exit;
  end;
  if C.Position >= Integer((Cardinal(C.Loop) + C.Length) * 4) then
  begin
    if (C.Control shr 27) and 3 = 1 then
    begin
      C.Position := C.Loop * 4;
      if Format = 2 then
      begin
        C.Position := Max(4, C.Position);
        C.Predictor := C.LoopPredictor;
        C.Index := C.LoopIndex;
        C.HighNibble := False;
      end;
    end
    else
    begin
      C.Control := C.Control and $7FFFFFFF;
      C.Started := False;
      if C.Control and $8000 = 0 then
        C.Sample := 0;
      Exit;
    end;
  end;
  case Format of
    0:
      begin
        C.Sample := ShortInt(FRead(C.Source + Cardinal(C.Position), 1)) * 256;
        Inc(C.Position);
      end;
    1:
      begin
        C.Sample := SmallInt(FRead(C.Source + Cardinal(C.Position), 2));
        Inc(C.Position, 2);
      end;
    2:
      begin
        if (C.Position = C.Loop * 4) and not C.HighNibble then
        begin
          C.LoopPredictor := C.Predictor;
          C.LoopIndex := C.Index;
        end;
        var N := Integer(FRead(C.Source + Cardinal(C.Position), 1));
        if C.HighNibble then
        begin
          N := N shr 4;
          Inc(C.Position);
        end
        else
          N := N and 15;
        C.HighNibble := not C.HighNibble;
        var Step := ADPCMStep[C.Index];
        var Delta := Step div 8;
        if N and 1 <> 0 then
          Inc(Delta, Step div 4);
        if N and 2 <> 0 then
          Inc(Delta, Step div 2);
        if N and 4 <> 0 then
          Inc(Delta, Step);
        if N and 8 <> 0 then
          Dec(C.Predictor, Delta)
        else
          Inc(C.Predictor, Delta);
        C.Predictor := EnsureRange(C.Predictor, -32767, 32767);
        C.Index := EnsureRange(C.Index + ADPCMIndex[N and 7], 0, 88);
        C.Sample := C.Predictor;
      end;
  end;
end;

procedure TNDSSound.MixSample;
begin
  var L: Int64 := 0;
  var R: Int64 := 0;
  if Control and $8000 <> 0 then
  begin
    for var i := 0 to 15 do
    begin
      var C: PNDSSoundChannel := @Channels[i];
      if not C.Started and (C.Control and $8000 = 0) then
        Continue;
      var Volume := Integer(C.Control and 127);
      if Volume = 127 then
        Volume := 128;
      var Pan := Integer((C.Control shr 16) and 127);
      if Pan = 127 then
        Pan := 128;
      var Sample := Int64(C.Sample) * Volume div (128 * Divisors[(C.Control shr 8) and 3]);
      Inc(L, Sample * (128 - Pan) div 128);
      Inc(R, Sample * Pan div 128);
    end;
    var Master := Control and 127;
    if Master = 127 then
      Master := 128;
    L := L * Master div 128;
    R := R * Master div 128;
  end;
  if SampleFrames * 2 + 2 > Length(Samples) then
    SetLength(Samples, Length(Samples) + 4096);
  Samples[SampleFrames * 2] := EnsureRange(L, -32768, 32767);
  Samples[SampleFrames * 2 + 1] := EnsureRange(R, -32768, 32767);
  Inc(SampleFrames);
end;

procedure TNDSSound.Tick(Cycles: Integer);
begin
  Inc(FPendingCycles, Cycles);
  if FPendingCycles >= 32 then
    ClockBoundary;
end;

procedure TNDSSound.ScheduleClock;
begin
  FClockDeadline := (NDS_BUS_CLOCK - Integer(FSampleClock) + NDS_SAMPLE_RATE - 1) div NDS_SAMPLE_RATE;
  for var i := 0 to 15 do
    if Channels[i].Started then
      FClockDeadline := Min(FClockDeadline, 2 * (65536 - Integer(Channels[i].Timer)) - Integer(Channels[i].Clock));
  FClockDeadline := Max(1, FClockDeadline);
end;

procedure TNDSSound.ClockBoundary;
begin
  // Keep the original 32-cycle flush boundaries: advancing on an earlier
  // sample/channel deadline could read PCM/ADPCM RAM before the same CPU write.
  Inc(FDeferredCycles, FPendingCycles);
  FPendingCycles := 0;
  if FDeferredCycles < FClockDeadline then
    Exit;

  var Cycles := FDeferredCycles;
  FDeferredCycles := 0;
  Clock(Cycles);
  ScheduleClock;
end;

procedure TNDSSound.Flush;
begin
  var Cycles := FPendingCycles + FDeferredCycles;
  FPendingCycles := 0;
  FDeferredCycles := 0;
  if Cycles <> 0 then
  begin
    Clock(Cycles);
    ScheduleClock;
  end;
end;

procedure TNDSSound.Clock(Cycles: Integer);
begin
  while Cycles > 0 do
  begin
    // These are bounded phases, not absolute timestamps: sample phase is
    // below NDS_BUS_CLOCK and channel phase never exceeds $20000.
    var Delta := Min(Cycles, (NDS_BUS_CLOCK - Integer(FSampleClock) + NDS_SAMPLE_RATE - 1) div NDS_SAMPLE_RATE);
    for var i := 0 to 15 do
      if Channels[i].Started then
        Delta := Min(Delta, 2 * (65536 - Integer(Channels[i].Timer)) - Integer(Channels[i].Clock));
    Delta := Max(1, Delta);
    Dec(Cycles, Delta);
    for var i := 0 to 15 do
      if Channels[i].Started then
      begin
        Inc(Channels[i].Clock, Delta);
        var Period := 2 * (65536 - Integer(Channels[i].Timer));
        if Channels[i].Clock >= Period then
        begin
          Dec(Channels[i].Clock, Period);
          Advance(i);
        end;
      end;
    Inc(FSampleClock, Delta * NDS_SAMPLE_RATE);
    if FSampleClock >= NDS_BUS_CLOCK then
    begin
      Dec(FSampleClock, NDS_BUS_CLOCK);
      MixSample;
    end;
  end;
end;

function TNDSSound.ReadRegister(Offset: Integer): Byte;
begin
  Flush;
  Result := 0;
  if Offset < $500 then
  begin
    var C: PNDSSoundChannel := @Channels[(Offset - $400) div 16];
    case Offset and 15 of
      0..3:
        Result := Byte(C.Control shr ((Offset and 3) * 8));
      4..7:
        Result := Byte(C.Source shr ((Offset and 3) * 8));
      8, 9:
        Result := Byte(C.Timer shr ((Offset and 1) * 8));
      10, 11:
        Result := Byte(C.Loop shr ((Offset and 1) * 8));
      12..15:
        Result := Byte(C.Length shr ((Offset and 3) * 8));
    end;
  end
  else
    case Offset of
      $500, $501:
        Result := Byte(Control shr ((Offset and 1) * 8));
      $504, $505:
        Result := Byte(Bias shr ((Offset and 1) * 8));
    end;
end;

procedure TNDSSound.WriteRegister(Offset: Integer; Value: Byte);
begin
  Flush;
  if Offset < $500 then
  begin
    var i := (Offset - $400) div 16;
    var C: PNDSSoundChannel := @Channels[i];
    var S := (Offset and 3) * 8;
    case Offset and 15 of
      0..3:
        begin
          var Old := C.Control;
          C.Control := (C.Control and not (Cardinal($FF) shl S)) or (Cardinal(Value) shl S);
          if (Old and $80000000 = 0) and (C.Control and $80000000 <> 0) then
            Start(i);
          if C.Control and $80000000 = 0 then
            C.Started := False;
        end;
      4..7:
        C.Source := ((C.Source and not (Cardinal($FF) shl S)) or (Cardinal(Value) shl S)) and $07FFFFFC;
      8, 9:
        C.Timer := (C.Timer and not (Word($FF) shl ((Offset and 1) * 8))) or (Word(Value) shl ((Offset and 1) * 8));
      10, 11:
        C.Loop := (C.Loop and not (Word($FF) shl ((Offset and 1) * 8))) or (Word(Value) shl ((Offset and 1) * 8));
      12..15:
        C.Length := ((C.Length and not (Cardinal($FF) shl S)) or (Cardinal(Value) shl S)) and $003FFFFF;
    end;
  end
  else
    case Offset of
      $500, $501:
        Control := (Control and not (Word($FF) shl ((Offset and 1) * 8))) or (Word(Value) shl ((Offset and 1) * 8));
      $504, $505:
        Bias := ((Bias and not (Word($FF) shl ((Offset and 1) * 8))) or (Word(Value) shl ((Offset and 1) * 8))) and $3FF;
    end;
  ScheduleClock;
end;

procedure TNDSSound.SerializeState(State: TStateArchive);
begin
  if State.Loading then
    FDeferredCycles := 0
  else if FDeferredCycles <> 0 then
  begin
    // Materialize only completed old flush boundaries. The pending fraction
    // remains serialized exactly as before, including mid-frame snapshots.
    var Cycles := FDeferredCycles;
    FDeferredCycles := 0;
    Clock(Cycles);
    ScheduleClock;
  end;
  State.Field(FSampleClock, SizeOf(FSampleClock));
  State.Field(FPendingCycles, SizeOf(FPendingCycles));
  State.Field(Control, SizeOf(Control));
  State.Field(Bias, SizeOf(Bias));
  State.Field(SampleFrames, SizeOf(SampleFrames));
  if (SampleFrames < 0) or (SampleFrames > 262144) then
    raise EReadError.Create('Invalid NDS snapshot sample count');

  var Count := SampleFrames * 2;
  if State.Loading then
    SetLength(Samples, Max(4096, Count));
  if Count <> 0 then
    State.Field(Samples[0], Count * SizeOf(SmallInt));
  for var i := 0 to 15 do
  begin
    State.Field(Channels[i].Control, SizeOf(Channels[i].Control));
    State.Field(Channels[i].Source, SizeOf(Channels[i].Source));
    State.Field(Channels[i].Length, SizeOf(Channels[i].Length));
    State.Field(Channels[i].Timer, SizeOf(Channels[i].Timer));
    State.Field(Channels[i].Loop, SizeOf(Channels[i].Loop));
    State.Field(Channels[i].Position, SizeOf(Channels[i].Position));
    State.Field(Channels[i].Phase, SizeOf(Channels[i].Phase));
    State.Field(Channels[i].Sample, SizeOf(Channels[i].Sample));
    State.Field(Channels[i].Predictor, SizeOf(Channels[i].Predictor));
    State.Field(Channels[i].Index, SizeOf(Channels[i].Index));
    State.Field(Channels[i].LoopPredictor, SizeOf(Channels[i].LoopPredictor));
    State.Field(Channels[i].LoopIndex, SizeOf(Channels[i].LoopIndex));
    State.Field(Channels[i].Noise, SizeOf(Channels[i].Noise));
    State.Field(Channels[i].Clock, SizeOf(Channels[i].Clock));
    State.Field(Channels[i].Started, SizeOf(Channels[i].Started));
    State.Field(Channels[i].HighNibble, SizeOf(Channels[i].HighNibble));
    if State.Loading then
    begin
      var C: PNDSSoundChannel := @Channels[i];
      if (C.Index < 0) or (C.Index > 88) or (C.LoopIndex < 0) or (C.LoopIndex > 88) or
        (C.Position < 0) or (C.Position > $1100000) or (C.Phase < 0) or (C.Phase > 7) or
        (C.Clock < 0) or (C.Clock > $20000) then
        raise EReadError.Create('Invalid NDS snapshot sound channel');
    end;
  end;

  if State.Loading and ((FSampleClock < 0) or (FSampleClock >= NDS_BUS_CLOCK) or
    (FPendingCycles < 0) or (FPendingCycles >= 32)) then
    raise EReadError.Create('Invalid NDS snapshot audio clock');

  if State.Loading then
    ScheduleClock;
end;

end.

