unit ZX.PIT8253;

interface

uses
  Core.Snapshots;

type
  TZX8253Counter = record
    Reload, Count: Integer;
    Mode, Access, Low: Byte;
    WriteHigh, ReadHigh, Pending, Enabled, Output, BCD, First: Boolean;
    Latched, LatchHigh: Boolean;
    Latch: Word;
  end;

  PZX8253Counter = ^TZX8253Counter;

  // The DMA USC ties all GATE pins high. Based on RetroMul's native Byte VI53
  // counter, extended with readable counters and independent count latches.
  TZX8253 = class
  private
    FCounters: array[0..2] of TZX8253Counter;
    function CounterWord(Index: Integer): Word;
  public
    constructor Create;
    procedure Reset;
    procedure Write(Index: Integer; Value: Byte);
    function Read(Index: Integer): Byte;
    procedure Tick(Index: Integer);
    function Output(Index: Integer): Boolean;
    procedure SerializeState(State: TStateArchive);
  end;

implementation

uses
  System.SysUtils, System.Classes, System.Math;

constructor TZX8253.Create;
begin
  inherited;
  Reset;
end;

procedure TZX8253.Reset;
begin
  FillChar(FCounters, SizeOf(FCounters), 0);
  for var I := 0 to 2 do
    FCounters[I].Output := True;
end;

function TZX8253.CounterWord(Index: Integer): Word;
begin
  var P := FCounters[Index];
  var N := P.Count;
  if P.BCD then
  begin
    N := N mod 10000;
    Result := (N mod 10) or ((N div 10 mod 10) shl 4) or
      ((N div 100 mod 10) shl 8) or ((N div 1000) shl 12);
  end
  else
    Result := N and $FFFF;
end;

procedure TZX8253.Write(Index: Integer; Value: Byte);
begin
  if Index = 3 then
  begin
    Index := Value shr 6;
    if Index = 3 then
      Exit; // 8253 has no 8254 read-back command.
    var P: PZX8253Counter := @FCounters[Index];
    if (Value and $30) = 0 then
    begin
      if not P.Latched then
      begin
        P.Latch := CounterWord(Index);
        P.Latched := True;
        P.LatchHigh := False;
      end;
      Exit;
    end;
    P.Access := (Value shr 4) and 3;
    P.Mode := (Value shr 1) and 7;
    if P.Mode > 5 then
      Dec(P.Mode, 4);
    P.BCD := (Value and 1) <> 0;
    P.WriteHigh := False;
    P.ReadHigh := False;
    P.Latched := False;
    P.Pending := False;
    P.Enabled := False;
    P.Output := P.Mode <> 0;
    Exit;
  end;
  if not (Index in [0..2]) then
    Exit;
  var P: PZX8253Counter := @FCounters[Index];
  var N: Integer;
  case P.Access of
    1:
      N := Value;
    2:
      N := Integer(Value) shl 8;
    3:
      begin
        if not P.WriteHigh then
        begin
          P.Low := Value;
          P.WriteHigh := True;
          if P.Mode = 0 then
          begin
            P.Enabled := False;
            P.Output := False;
          end;
          Exit;
        end;
        N := (Integer(Value) shl 8) or P.Low;
        P.WriteHigh := False;
      end;
  else
    Exit;
  end;
  if P.BCD then
  begin
    N := ((N shr 12) and 15) * 1000 + ((N shr 8) and 15) * 100 + ((N shr 4) and 15) * 10 + (N and 15);
    N := N mod 10000;
    if N = 0 then
      N := 10000;
  end
  else if N = 0 then
    N := 65536;
  P.Reload := N;
  P.Pending := True;
end;

function TZX8253.Read(Index: Integer): Byte;
begin
  Result := $FF;
  if not (Index in [0..2]) then
    Exit;
  var P: PZX8253Counter := @FCounters[Index];
  if P.Access = 0 then
    Exit;
  var N := CounterWord(Index);
  var HighByte := P.ReadHigh;
  if P.Latched then
  begin
    N := P.Latch;
    HighByte := P.LatchHigh;
  end;
  if (P.Access = 2) or ((P.Access = 3) and HighByte) then
    Result := N shr 8
  else
    Result := N and 255;
  if P.Latched then
  begin
    if (P.Access <> 3) or HighByte then
      P.Latched := False
    else
      P.LatchHigh := True;
  end
  else if P.Access = 3 then
    P.ReadHigh := not P.ReadHigh;
end;

procedure TZX8253.Tick(Index: Integer);
begin
  var P: PZX8253Counter := @FCounters[Index];
  if P.Pending and not (P.Enabled and (P.Mode in [2, 3])) then
  begin
    P.Pending := False;
    P.Count := P.Reload;
    P.First := True;
    P.Enabled := not (P.Mode in [1, 5]);
    P.Output := P.Mode <> 0;
    Exit;
  end;
  if not P.Enabled then
    Exit;
  case P.Mode of
    0:
      begin
        if P.Count > 0 then
          Dec(P.Count);
        if P.Count = 0 then
        begin
          P.Output := True;
          P.Enabled := False;
        end;
      end;
    2:
      begin
        if P.Count <= 1 then
        begin
          P.Count := P.Reload;
          P.Output := True;
          P.Pending := False;
        end
        else
        begin
          Dec(P.Count);
          P.Output := P.Count <> 1;
        end;
      end;
    3:
      begin
        var Step := 2;
        if P.First and Odd(P.Count) then
        begin
          if P.Output then
            Step := 1
          else
            Step := 3;
        end;
        P.First := False;
        P.Count := Max(0, P.Count - Step);
        if P.Count = 0 then
        begin
          P.Output := not P.Output;
          P.Pending := False;
          P.Count := P.Reload;
          P.First := True;
        end;
      end;
    4:
      begin
        if P.Count > 0 then
        begin
          Dec(P.Count);
          P.Output := P.Count <> 0;
        end
        else
        begin
          P.Output := True;
          P.Enabled := False;
        end;
      end;
    // Modes 1/5 await a rising GATE edge; the board hard-wires GATE high.
  end;
end;

function TZX8253.Output(Index: Integer): Boolean;
begin
  Result := FCounters[Index].Output;
end;

procedure TZX8253.SerializeState(State: TStateArchive);
begin
  State.Field(FCounters, SizeOf(FCounters));
  for var P in FCounters do
    if (P.Mode > 5) or (P.Access > 3) or (P.Reload < 0) or (P.Reload > 65536) or
      (P.Count < 0) or (P.Count > 65536) then
      raise EReadError.Create('Invalid DMA USC timer state');
end;

end.
