unit PS2.VU.DiamondPlan;

interface

const
  DiamondPairLimit = 48;

type
  TDiamondPath = record
    Count: Integer;
    PairIndex: array[0..DiamondPairLimit - 1] of Integer;
  end;
  TDiamondPlan = record
    SelectorVI, LoadPair, SignBranch, NonzeroBranch, JoinPair: Integer;
    Path: array[-1..1] of TDiamondPath;
  end;

function TryPlanDiamond(const Words: array of Cardinal; out Plan: TDiamondPlan): Boolean;

implementation

// Return the VI written by a supported lower operation, including implicit
// address updates. Unknown operations end the shape, even for a dead result.
function PlainWrite(Lo, Hi: Cardinal; out Reg: Integer): Boolean;
begin
  Result := False;
  Reg := 0;
  if (Hi and $78000000) <> 0 then
    Exit;
  if (Hi and $80000000) <> 0 then
    Exit(True);
  var Ft := Integer((Lo shr 16) and 15);
  var Fs := Integer((Lo shr 11) and 15);
  case Lo shr 25 of
    $00, $01, $05: Exit(True);
    $04, $08, $09: Reg := Ft;
    $40:
      case Lo and $3F of
        $30, $31, $34, $35: Reg := Integer((Lo shr 6) and 15);
        $32: Reg := Ft;
        $3C..$3F:
          case ((Lo shr 4) and $7C) or (Lo and 3) of
            $30, $31, $38..$3B, $3D, $3F, $64: Exit(True);
            $34, $36: Reg := Fs;
            $35, $37, $3C, $3E: Reg := Ft;
          else
            Exit;
          end;
      else
        Exit;
      end;
  else
    Exit;
  end;
  Result := True;
end;

function TryPlanDiamond(const Words: array of Cardinal; out Plan: TDiamondPlan): Boolean;
var
  LastLoad: array[0..15] of Integer;
begin
  Result := False;
  Plan := Default(TDiamondPlan);
  Plan.SignBranch := -1;
  Plan.NonzeroBranch := -1;
  if Odd(Length(Words)) then
    Exit;
  for var R := 0 to 15 do
    LastLoad[R] := -1;
  for var I := 0 to Length(Words) div 2 - 1 do
  begin
    if I >= DiamondPairLimit then
      Exit;
    var Lo := Words[I * 2];
    var Hi := Words[I * 2 + 1];
    var G := Lo shr 25;
    var R := Integer((Lo shr 11) and 15);
    if ((Hi and $F8000000) = 0) and (G in [$2D, $29]) then
    begin
      if (R = 0) or ((Lo and $7FF) <> 2) then
        Exit;
      if Plan.SignBranch < 0 then
      begin
        if (G <> $2D) or (LastLoad[R] < 0) or (I - LastLoad[R] < 3) then
          Exit;
        Plan.SelectorVI := R;
        Plan.LoadPair := LastLoad[R];
        Plan.SignBranch := I;
      end
      else
      begin
        if (Plan.NonzeroBranch >= 0)
          or (G <> $29)
          or (R <> Plan.SelectorVI)
          or (((Lo shr 16) and 15) <> 0)
          or (I < Plan.SignBranch + 3) then
          Exit;
        Plan.NonzeroBranch := I;
        Plan.JoinPair := I + 3;
      end;
    end
    else
    begin
      var W: Integer;
      if not PlainWrite(Lo, Hi, W) then
        Exit;
      if (W <> 0) and (Plan.SignBranch < 0) then
      begin
        if (G = $04) and ((Lo and $01E00000) <> 0) then
          LastLoad[W] := I
        else
          LastLoad[W] := -1;
      end
      else if (Plan.SignBranch >= 0) and (W = Plan.SelectorVI) then
        Exit;
    end;
    if (Plan.NonzeroBranch >= 0) and (I = Plan.JoinPair) then
    begin
      for var Sign := -1 to 1 do
        for var K := 0 to I do
          if not (((Sign > 0) and (K = Plan.SignBranch + 2)) or ((Sign <> 0) and (K = Plan.NonzeroBranch + 2))) then
          begin
            var N := Plan.Path[Sign].Count;
            Plan.Path[Sign].PairIndex[N] := K;
            Inc(Plan.Path[Sign].Count);
          end;
      Exit(True);
    end;
  end;
end;

end.
