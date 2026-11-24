unit PS2.AudioWait;

interface

function TakeSplice(
  const PCM: array of SmallInt;
  N: Integer;
  out Prefix: Integer;
  out Cycle: TArray<SmallInt>
): Boolean;
function StretchReserve(const Input: array of SmallInt; Frames, Extra: Integer): TArray<SmallInt>;

implementation

uses
  System.SysUtils,
  System.Math;

function TakeSplice(
  const PCM: array of SmallInt;
  N: Integer;
  out Prefix: Integer;
  out Cycle: TArray<SmallInt>
): Boolean;
const
  Overlap = 64;
begin
  Result := False;
  Prefix := 0;
  Cycle := nil;
  if (N < 256) or (N > 4096) or (Length(PCM) < 2 * N) then
    Exit;
  var Best: Int64 := High(Int64);
  var Tail := 0;
  var LengthBest := 0;
  // Both ends follow the original time trajectory. Repeating a complete
  // matched grain can stop at any boundary without dropping its source tail.
  var B := N - Overlap - 32;
  while B >= Max(128, N div 2) do
  begin
    for var L := 80 to Min(B, 768) do
    begin
      var E: Int64 := 0;
      for var I := 0 to Overlap div 2 - 1 do
        for var Ch := 0 to 1 do
        begin
          var J := 2 * (B + 2 * I) + Ch;
          var K := J - 2 * L;
          var Diff := Integer(PCM[J]) - PCM[K];
          var Slope := (Integer(PCM[J + 2]) - PCM[J]) - (Integer(PCM[K + 2]) - PCM[K]);
          Inc(E, Int64(Diff) * Diff + Int64(Slope) * Slope);
        end;
      if (E < Best) or ((E = Best) and (L > LengthBest)) then
      begin
        Best := E;
        Tail := B;
        LengthBest := L;
      end;
    end;
    Dec(B, 64);
  end;
  if LengthBest = 0 then
    Exit;
  Prefix := Tail;
  SetLength(Cycle, 2 * LengthBest);
  for var I := 0 to LengthBest - 1 do
    for var Ch := 0 to 1 do
      if I < Overlap then
        Cycle[I * 2 + Ch] :=
          (Integer(PCM[(Tail + I) * 2 + Ch]) * (Overlap - I) + Integer(PCM[(Tail - LengthBest + I) * 2 + Ch]) * I)
            div Overlap
      else
        Cycle[I * 2 + Ch] := PCM[(Tail - LengthBest + I) * 2 + Ch];
  Result := True;
end;

function StretchReserve(const Input: array of SmallInt; Frames, Extra: Integer): TArray<SmallInt>;
const
  Hop = 256;
  Overlap = 128;
var
  Previous: Integer;

  function Distance(Start: Integer): Integer;
  begin
    Result := 0;
    for var I := 0 to Overlap div 2 - 1 do
      for var Ch := 0 to 1 do
        Inc(Result, Abs(Integer(Input[(Previous + Hop + 2 * I) * 2 + Ch]) - Integer(Input[(Start + 2 * I) * 2 + Ch])));
  end;

begin
  if (Frames < 1024) or (Frames > 8192) or (Extra < 0) or (Extra > 2 * Frames) or (Length(Input) < 2 * Frames) then
    raise EArgumentOutOfRangeException.Create('Invalid queued PCM segment');
  SetLength(Result, 2 * (Frames + Extra));
  if Extra = 0 then
  begin
    Move(Input[0], Result[0], Frames * 4);
    Exit;
  end;
  var Total := Frames + Extra;
  var Last := (Total - Hop - Overlap) div Hop * Hop;
  var EndStart := Frames - (Total - Last);
  Move(Input[0], Result[0], Hop * 4);
  Previous := 0;
  var At := Hop;
  while At <= Last do
  begin
    var Count := Hop;
    var Start := EndStart;
    if At = Last then
      Count := Total - At
    else
    begin
      var Centre := Integer(Int64(At) * EndStart div Last);
      var L := Max(Previous, Centre - 112);
      var R := Min(EndStart, Centre + 112);
      Start := EnsureRange(Centre, L, R);
      var Best := Distance(Start);
      var Candidate := L;
      while Candidate <= R do
      begin
        var Score := Distance(Candidate);
        if Score < Best then
        begin
          Best := Score;
          Start := Candidate;
        end;
        Inc(Candidate, 4);
      end;
      var Coarse := Start;
      for Candidate := Max(L, Coarse - 3) to Min(R, Coarse + 3) do
      begin
        var Score := Distance(Candidate);
        if Score < Best then
        begin
          Best := Score;
          Start := Candidate;
        end;
      end;
    end;
    for var I := 0 to Overlap - 1 do
      for var Ch := 0 to 1 do
        Result[(At + I) * 2 + Ch] :=
          (Integer(Input[(Previous + Hop + I) * 2 + Ch]) * (Overlap - I) + Integer(Input[(Start + I) * 2 + Ch]) * I)
            div Overlap;
    Move(Input[(Start + Overlap) * 2], Result[(At + Overlap) * 2], (Count - Overlap) * 4);
    Previous := Start;
    Inc(At, Count);
  end;
end;

end.
