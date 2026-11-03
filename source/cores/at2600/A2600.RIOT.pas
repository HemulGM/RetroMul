unit A2600.RIOT;

interface

type
  TA2600RIOTState = record
    RAM: array[0..127] of Byte;
    TimerDivider, TimerPhase: Integer;
    Timer, TimerFlag, PortA, DDRA, PortB, DDRB: Byte;
    TimerRunning, TimerUnderflow, TimerWrapped: Boolean;
  end;

  TA2600RIOT = class
  private
    FState: TA2600RIOTState;
  public
    constructor Create;
    procedure Reset;
    procedure Clock;
    function Read(Address: Word; PortAInput, PortBInput: Byte): Byte;
    procedure Write(Address: Word; Value: Byte);
    property SnapshotState: TA2600RIOTState read FState write FState;
  end;

implementation

constructor TA2600RIOT.Create;
begin
  inherited;
  Reset;
end;

procedure TA2600RIOT.Reset;
begin
  FillChar(FState, SizeOf(FState), 0);
  // The divider runs after power-on, before software programs TIMxT.
  FState.Timer := $FF;
  FState.TimerDivider := 1024;
  FState.TimerPhase := 1;
  FState.TimerRunning := True;
end;

procedure TA2600RIOT.Clock;
begin
  FState.TimerWrapped := False;
  if FState.TimerRunning then
  begin
    Dec(FState.TimerPhase);
    if FState.TimerPhase <= 0 then
    begin
      if FState.Timer = 0 then
      begin
        FState.Timer := $FF;
        FState.TimerFlag := $80;
        FState.TimerUnderflow := True;
        FState.TimerWrapped := True;
      end
      else
        Dec(FState.Timer);
      if FState.TimerUnderflow then
        FState.TimerPhase := 1
      else
        FState.TimerPhase := FState.TimerDivider;
    end;
  end;
end;

function TA2600RIOT.Read(Address: Word; PortAInput, PortBInput: Byte): Byte;
begin
  if Address and $200 = 0 then
    Exit(FState.RAM[Address and 127]);
  Result := 0;
  case Address and 7 of
    0:
      Result := (PortAInput and not FState.DDRA) or (FState.PortA and FState.DDRA);
    1:
      Result := FState.DDRA;
    2:
      Result := (PortBInput and not FState.DDRB) or (FState.PortB and FState.DDRB);
    3:
      Result := FState.DDRB;
    4, 6:
      begin
        Result := FState.Timer;
        if not FState.TimerWrapped then
        begin
          FState.TimerFlag := FState.TimerFlag and $7F;
          FState.TimerUnderflow := False;
        end;
      end;
    5, 7:
      Result := FState.TimerFlag;
  end;
end;

procedure TA2600RIOT.Write(Address: Word; Value: Byte);
const
  Dividers: array[0..3] of Integer = (1, 8, 64, 1024);
begin
  if Address and $200 = 0 then
    FState.RAM[Address and 127] := Value
  else if Address and $14 = $14 then
  begin
    FState.Timer := Value;
    FState.TimerFlag := 0;
    FState.TimerUnderflow := False;
    FState.TimerDivider := Dividers[Address and 3];
    FState.TimerPhase := 1;
    FState.TimerRunning := True;
  end
  else
    case Address and 7 of
      0:
        FState.PortA := Value;
      1:
        FState.DDRA := Value;
      2:
        FState.PortB := Value;
      3:
        FState.DDRB := Value;
    end;
end;

end.

