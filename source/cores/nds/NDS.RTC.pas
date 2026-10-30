unit NDS.RTC;

interface

uses
  System.SysUtils, System.Classes, System.DateUtils, System.Math, Core.Snapshots;

type
  TNDSRTC = class
  private
    FPort, FCommand, FInput, FOutput: Byte;
    FBits, FPosition: Integer;
    FReceivingCommand, FRead: Boolean;
    FRegisters: array[0..7, 0..6] of Byte;
    FBuffer: array[0..6] of Byte;
    FNow: TDateTime;
    FClock: Int64;
    procedure DecodeCommand;
    procedure Store(Value: Byte);
  public
    constructor Create;
    procedure Reset;
    procedure SerializeState(State: TStateArchive);
    procedure Write(Value: Byte);
    function Read: Byte;
    function Tick(Cycles: Integer): Boolean;
    function CyclesUntilTick: Integer;
    procedure SetDateTime(Value: TDateTime);
  end;

implementation

const
  BusClock = 33513982;

function BCD(Value: Integer): Byte;
begin
  Result := (Value div 10) * 16 + Value mod 10;
end;

function FromBCD(Value: Byte): Integer;
begin
  Result := (Value shr 4) * 10 + (Value and 15);
end;

constructor TNDSRTC.Create;
begin
  inherited;
  FNow := Now;
  Reset;
end;

procedure TNDSRTC.Reset;
begin
  FillChar(FRegisters, SizeOf(FRegisters), 0);
  FRegisters[0, 0] := 2;
  FPort := 0;
  FCommand := 0;
  FInput := 0;
  FOutput := 0;
  FBits := 0;
  FPosition := 0;
  FReceivingCommand := True;
  FRead := False;
  FClock := 0;
end;

procedure TNDSRTC.SetDateTime(Value: TDateTime);
begin
  FNow := Value;
  FClock := 0;
end;

procedure TNDSRTC.DecodeCommand;
begin
  if FCommand and 15 <> 6 then
  begin
    var Reverse: Byte := 0;
    for var I := 0 to 7 do
      Reverse := Reverse or (((FCommand shr I) and 1) shl (7 - I));
    FCommand := Reverse;
  end;
  FRead := FCommand and $80 <> 0;
  FPosition := 0;
  FBits := 0;
  FInput := 0;
  FReceivingCommand := False;
  var RegisterIndex := (FCommand shr 4) and 7;
  Move(FRegisters[RegisterIndex], FBuffer, SizeOf(FBuffer));
  if RegisterIndex in [2, 6] then
  begin
    var Y, M, D, H, N, S, MS: Word;
    DecodeDate(FNow, Y, M, D);
    DecodeTime(FNow, H, N, S, MS);
    var Hour := Integer(H);
    if FRegisters[0, 0] and 2 = 0 then
      Hour := Hour mod 12;
    if RegisterIndex = 2 then
    begin
      FBuffer[0] := BCD(Y mod 100);
      FBuffer[1] := BCD(M);
      FBuffer[2] := BCD(D);
      FBuffer[3] := (DayOfTheWeek(FNow) - 1) mod 7;
    end;
    var P := 0;
    if RegisterIndex = 2 then
      P := 4;
    FBuffer[P] := BCD(Hour);
    if H >= 12 then
      FBuffer[P] := FBuffer[P] or $40;
    FBuffer[P + 1] := BCD(N);
    FBuffer[P + 2] := BCD(S);
  end;
  if RegisterIndex = 0 then
    FRegisters[0, 0] := FRegisters[0, 0] and $0F;
end;

procedure TNDSRTC.Store(Value: Byte);
begin
  var RegisterIndex := (FCommand shr 4) and 7;
  if FPosition > 6 then
    Exit;

  FRegisters[RegisterIndex, FPosition] := Value;
  if RegisterIndex = 0 then
  begin
    if Value and 1 <> 0 then
    begin
      FillChar(FRegisters, SizeOf(FRegisters), 0);
      FRegisters[0, 0] := 2;
    end;
    FRegisters[0, 0] := Value and $0E;
  end;
  if ((RegisterIndex = 2) and (FPosition = 6)) or ((RegisterIndex = 6) and (FPosition = 2)) then
  begin
    var Y, M, D: Word;
    DecodeDate(FNow, Y, M, D);
    if RegisterIndex = 2 then
    begin
      Y := 2000 + FromBCD(FRegisters[2, 0]);
      M := FromBCD(FRegisters[2, 1]);
      D := FromBCD(FRegisters[2, 2]);
    end;
    var P := 0;
    if RegisterIndex = 2 then
      P := 4;
    var H := FromBCD(FRegisters[RegisterIndex, P] and $3F);
    if FRegisters[0, 0] and 2 = 0 then
      if FRegisters[RegisterIndex, P] and $40 <> 0 then
        Inc(H, 12);
    var Stamp: TDateTime;
    if TryEncodeDateTime(Y, M, D, H, FromBCD(FRegisters[RegisterIndex, P + 1]), FromBCD(FRegisters[RegisterIndex, P + 2]), 0, Stamp) then
      FNow := Stamp;
  end;
  Inc(FPosition);
end;

procedure TNDSRTC.Write(Value: Byte);
begin
  var Old := FPort;
  FPort := Value;
  if Value and 4 = 0 then
    Exit;
  if Old and 4 = 0 then
  begin
    FReceivingCommand := True;
    FCommand := 0;
    FBits := 0;
    FPosition := 0;
    FInput := 0;
    FOutput := 0;
    Exit;
  end;

  if (Old and 2 = 0) and (Value and 2 <> 0) and (Value and $10 <> 0) then
  begin
    if FReceivingCommand then
    begin
      FCommand := FCommand or ((Value and 1) shl FBits);
      Inc(FBits);
      if FBits = 8 then
        DecodeCommand;
    end
    else if not FRead then
    begin
      FInput := FInput or ((Value and 1) shl FBits);
      Inc(FBits);
      if FBits = 8 then
      begin
        Store(FInput);
        FInput := 0;
        FBits := 0;
      end;
    end;
  end;
  if (Old and 2 <> 0) and (Value and 2 = 0) and not FReceivingCommand and FRead then
  begin
    if FPosition < 7 then
      FOutput := (FBuffer[FPosition] shr FBits) and 1
    else
      FOutput := 0;
    Inc(FBits);
    if FBits = 8 then
    begin
      FBits := 0;
      Inc(FPosition);
    end;
  end;
end;

function TNDSRTC.Read: Byte;
begin
  Result := FPort;
  if FPort and $10 = 0 then
    Result := (Result and $FE) or FOutput;
end;

function TNDSRTC.CyclesUntilTick: Integer;
begin
  Result := BusClock - FClock;
end;

function TNDSRTC.Tick(Cycles: Integer): Boolean;
begin
  Result := False;
  Inc(FClock, Cycles);
  if FClock >= BusClock then
  begin
    Dec(FClock, BusClock);
    FNow := IncSecond(FNow, 1);
    if ((FRegisters[4, 0] and 15) = 1) and (FRegisters[1, 0] and 1 <> 0) then
    begin
      FRegisters[0, 0] := FRegisters[0, 0] or $10;
      Result := True;
    end;
  end;
end;

procedure TNDSRTC.SerializeState(State: TStateArchive);
begin
  State.Field(FPort, SizeOf(FPort));
  State.Field(FCommand, SizeOf(FCommand));
  State.Field(FInput, SizeOf(FInput));
  State.Field(FOutput, SizeOf(FOutput));
  State.Field(FBits, SizeOf(FBits));
  State.Field(FPosition, SizeOf(FPosition));
  State.Field(FReceivingCommand, SizeOf(FReceivingCommand));
  State.Field(FRead, SizeOf(FRead));
  State.Field(FRegisters, SizeOf(FRegisters));
  State.Field(FBuffer, SizeOf(FBuffer));
  State.Field(FNow, SizeOf(FNow));
  State.Field(FClock, SizeOf(FClock));
  if State.Loading and ((FBits < 0) or (FBits > 7) or (FPosition < 0) or (FPosition > $1000000) or
    (FClock < 0) or (FClock >= BusClock) or IsNan(FNow) or IsInfinite(FNow) or
    (FNow < 0) or (FNow > 2958465)) then
    raise EReadError.Create('Invalid NDS snapshot RTC state');
end;

end.

