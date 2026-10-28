unit PS2.GS.RaceCheck;

// Diagnostics (with GS_RACECHECK defined): GS memory words that two band
// threads touch in commands no barrier orders. TPS2GSMemory reports each
// access, TPS2GSRaster the barriers (and a description of each command), the
// band threads which band and command is running. Reports reads after another
// band's unordered write (RAW), writes after its write (WAW) or read (WAR).
{$IFDEF PS2_CHECKED}{$Q+}{$R+}{$ELSE}{$O+}{$Q-}{$R-}{$ENDIF}

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs;

threadvar
  RaceBandPlus1: Integer;
  RaceCmd: Int64;

procedure RaceBarrier(Position: Int64);
procedure RaceDescribe(Position: Int64; const Text: string);
procedure RaceAccess(WordIndex: Cardinal; Write: Boolean);
procedure RaceMainWrite(WordIndex: Cardinal);
function RaceReport: TArray<string>;

implementation

var
  WriterCmd: array of Int64;
  WriterBand: array of ShortInt;
  ReaderCmd: array of Int64;
  ReaderBand: array of ShortInt;
  Barriers: array of Int64;
  BarrierCount: Integer;
  Desc: array of string;
  Lock: TCriticalSection;
  Reports: TStringList;

procedure RaceBarrier(Position: Int64);
begin
  Lock.Enter;
  try
    if (BarrierCount = 0) or (Barriers[BarrierCount - 1] < Position) then
    begin
      if BarrierCount >= Length(Barriers) then
        SetLength(Barriers, Length(Barriers) * 2 + 1024);
      Barriers[BarrierCount] := Position;
      Inc(BarrierCount);
    end;
  finally
    Lock.Leave;
  end;
end;

procedure RaceDescribe(Position: Int64; const Text: string);
begin
  Desc[Position and $FFFFF] := Text;
end;

// The latest barrier at or before Position.
function LatestBarrier(Position: Int64): Int64;
begin
  Result := -1;
  var Lo := 0;
  var Hi := BarrierCount - 1;
  while Lo <= Hi do
  begin
    var M := (Lo + Hi) div 2;
    if Barriers[M] <= Position then
    begin
      Result := Barriers[M];
      Lo := M + 1;
    end
    else
      Hi := M - 1;
  end;
end;

procedure Report(const Kind: string; W: Cardinal; C: Int64; B: Integer; OC: Int64; OB: Integer);
begin
  Lock.Enter;
  try
    if Reports.Count < 60 then
      Reports.Add(Format('%s word %.6x: cmd %d band %d [%s] vs cmd %d band %d [%s]', [Kind, W, C, B,
        Desc[C and $FFFFF], OC, OB, Desc[OC and $FFFFF]]));
  finally
    Lock.Leave;
  end;
end;

procedure RaceAccess(WordIndex: Cardinal; Write: Boolean);
begin
  var B := RaceBandPlus1 - 1;
  if B < 0 then
    Exit;
  var C := RaceCmd;
  var W := WordIndex and $FFFFF;
  var OB := WriterBand[W];
  var OC := WriterCmd[W];
  if (OB >= 0) and (OB <> B) then
    if (OC > C) or (LatestBarrier(C) <= OC) then
      if Write then
        Report('WAW', W, C, B, OC, OB)
      else
        Report('RAW', W, C, B, OC, OB);
  if Write then
  begin
    var RB := ReaderBand[W];
    var RC := ReaderCmd[W];
    if (RB >= 0) and (RB <> B) and ((RC > C) or (LatestBarrier(C) <= RC)) then
      Report('WAR', W, C, B, RC, RB);
    WriterBand[W] := B;
    WriterCmd[W] := C;
  end
  else
  begin
    ReaderBand[W] := B;
    ReaderCmd[W] := C;
  end;
end;

procedure RaceMainWrite(WordIndex: Cardinal);
begin
  var W := WordIndex and $FFFFF;
  WriterBand[W] := -1;
  ReaderBand[W] := -1;
end;

function RaceReport: TArray<string>;
begin
  Result := Reports.ToStringArray;
end;

initialization
  SetLength(WriterCmd, 1 shl 20);
  SetLength(WriterBand, 1 shl 20);
  SetLength(ReaderCmd, 1 shl 20);
  SetLength(ReaderBand, 1 shl 20);
  FillChar(WriterBand[0], Length(WriterBand), $FF);
  FillChar(ReaderBand[0], Length(ReaderBand), $FF);
  SetLength(Desc, 1 shl 20);
  Lock := TCriticalSection.Create;
  Reports := TStringList.Create;
end.
