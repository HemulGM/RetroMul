unit PS2.HostTempo;

interface

type
  // Time expansion on the presentation side only. At normal speed the
  // caller submits the original stereo PCM without buffering or filtering.
  TPS2HostTempo = class
  private
    const
      Hop = 576;
      Tail = 192;
      Reach = 144;
      One = 65536;
  private
    FWork, FNative: array[0..7] of Integer;
    FCount, FNext, FRatio, FGood: Integer;
    FPosition: Int64;
    FInput: TArray<SmallInt>;
    FUsed: Integer;
    FOverlap: array[0..2 * Tail - 1] of SmallInt;
    FActive, FStarted: Boolean;
    FTarget, FPeak, FPeakHold: Integer;
    function Match(Centre: Integer): Integer;
    procedure Append(const Samples: array of SmallInt);
  public
    property TargetFrames: Integer read FTarget;
    property Stretching: Boolean read FActive;
    procedure Clear;
    function Expand(
      const Samples: array of SmallInt;
      WorkFrames, QueueFrames: Integer;
      out Output: TArray<SmallInt>
    ): Boolean;
  end;

const
  TimelyRefill = True;

implementation

uses
  System.Math,
  System.SysUtils;

procedure TPS2HostTempo.Clear;
begin
  FCount := 0;
  FNext := 0;
  FGood := 0;
  FActive := False;
  FStarted := False;
  FUsed := 0;
  FPosition := 0;
  FRatio := One;
  FTarget := 6144;
  FPeak := 0;
  FPeakHold := 0;
end;

procedure TPS2HostTempo.Append(const Samples: array of SmallInt);
begin
  var Needed := FUsed + Length(Samples) div 2;
  if 2 * Needed > Length(FInput) then
    SetLength(FInput, 2 * Needed + 4096);
  Move(Samples[0], FInput[2 * FUsed], Length(Samples) * 2);
  FUsed := Needed;
end;

function TPS2HostTempo.Match(Centre: Integer): Integer;
  function Distance(Start: Integer): Int64;
  begin
    Result := 0;
    for var I := 0 to Tail div 3 - 1 do
      for var Ch := 0 to 1 do
        Inc(Result, Abs(Integer(FOverlap[6 * I + Ch]) - Integer(FInput[2 * Start + 6 * I + Ch])));
  end;
begin
  Result := Centre;
  var Best := Distance(Centre);
  var Lo := Max(0, Centre - Reach);
  var Hi := Min(FUsed - Hop - Tail, Centre + Reach);
  var At := Lo;
  while At <= Hi do
  begin
    var Score := Distance(At);
    if Score < Best then
    begin
      Best := Score;
      Result := At;
    end;
    Inc(At, 4);
  end;
  Lo := Max(Lo, Result - 3);
  Hi := Min(Hi, Result + 3);
  for At := Lo to Hi do
  begin
    var Score := Distance(At);
    if Score < Best then
    begin
      Best := Score;
      Result := At;
    end;
  end;
end;

function TPS2HostTempo.Expand(
  const Samples: array of SmallInt;
  WorkFrames, QueueFrames: Integer;
  out Output: TArray<SmallInt>
): Boolean;
begin
  Output := nil;
  Result := False;
  var N := Length(Samples) div 2;
  if (N = 0) or Odd(Length(Samples)) or (N > 32768) then
    Exit;
  // Use a multi-field interval: some games do the work of two fields in one.
  FWork[FNext] := EnsureRange(WorkFrames, 0, 24 * N);
  if FCount >= 5 then
  begin
    if WorkFrames >= FPeak then
    begin
      FPeak := WorkFrames;
      FPeakHold := 48000 * 5;
    end
    else if FPeakHold > 0 then
      Dec(FPeakHold, N)
    else
      FPeak := Max(WorkFrames, FPeak - FPeak div 96);
  end;
  FNative[FNext] := N;
  FNext := (FNext + 1) and 7;
  FCount := Min(FCount + 1, 8);
  var W := 0;
  var S := 0;
  for var I := 0 to FCount - 1 do
  begin
    Inc(W, FWork[I]);
    Inc(S, FNative[I]);
  end;
  var Ratio := Integer(Int64(W) * One div S);
  if not FActive then
  begin
    if (FCount < 6) or (Ratio < One + One div 10) or (QueueFrames >= 4608) then
      Exit;
    FActive := True;
    FRatio := Ratio;
  end;
  if Ratio < One + One div 32 then
    Inc(FGood)
  else
    FGood := 0;
  FTarget := EnsureRange((5 * FPeak) div 2 + 2048, 8192, 20480);
  if QueueFrames >= 0 then
  begin
    // The request is made *after* this field's work. Leave a cushion for
    // the next heavy field without feeding launcher/limiter sleeps back.
    var Expected := QueueFrames + W div FCount;
    var Gap := FTarget - 1024 - Expected;
    Inc(Ratio, Integer(EnsureRange(Int64(Gap) * One div (4 * N), -Int64(One), Int64(One))));
  end;
  Ratio := EnsureRange(Ratio, One, 6 * One);
  FRatio := (FRatio * 3 + Ratio) div 4;
  // After a stall only submitted PCM will reach the device before the next
  // field. Recover with the existing bounded stereo stretch for this hop.
  if TimelyRefill and (QueueFrames >= 0) and (QueueFrames < 6144) and (WorkFrames >= 6 * N) and (FGood = 0) then
    FRatio := Max(FRatio, Min(6 * One, Int64(FTarget - QueueFrames) * One div N));
  Append(Samples);
  Result := True;
  var LengthOut := 0;
  if FGood >= 16 then
  begin
    // Join the last overlap to the remaining source at unity, then hand
    // the next unmodified sample straight to playback.
    var At := Min(Integer(FPosition div One), FUsed - 1);
    if FStarted and (FUsed >= Hop + Tail) then
      At := Match(Min(At, FUsed - Hop - Tail));
    SetLength(Output, 2 * (FUsed - At));
    Move(FInput[2 * At], Output[0], Length(Output) * 2);
    if FStarted then
      for var I := 0 to Min(Tail, FUsed - At) - 1 do
        for var Ch := 0 to 1 do
          Output[2 * I + Ch] := (Integer(FOverlap[2 * I + Ch]) * (Tail - I) + Integer(Output[2 * I + Ch]) * I) div Tail;
    Clear;
    Exit;
  end;
  while FPosition div One + Hop + Tail <= FUsed do
  begin
    var At := Integer(FPosition div One);
    if FStarted then
      At := Match(At);
    if LengthOut + 2 * Hop > Length(Output) then
      SetLength(Output, Max(LengthOut + 2 * Hop, Length(Output) * 2));
    Move(FInput[2 * At], Output[LengthOut], Hop * 4);
    if FStarted then
      for var I := 0 to Tail - 1 do
        for var Ch := 0 to 1 do
          Output[LengthOut + 2 * I + Ch] :=
            (Integer(FOverlap[2 * I + Ch]) * (Tail - I) + Integer(FInput[2 * (At + I) + Ch]) * I) div Tail;
    Move(FInput[2 * (At + Hop)], FOverlap[0], Tail * 4);
    FStarted := True;
    Inc(LengthOut, 2 * Hop);
    Inc(FPosition, Int64(Hop) * One * One div FRatio);
  end;
  SetLength(Output, LengthOut);
  var Drop := Min(FUsed, Max(0, Integer(FPosition div One) - Reach));
  if Drop > 0 then
  begin
    Dec(FUsed, Drop);
    if FUsed <> 0 then
      Move(FInput[2 * Drop], FInput[0], 4 * FUsed);
    Dec(FPosition, Int64(Drop) * One);
  end;
end;

end.
