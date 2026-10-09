unit A2600.AudioMachine;

interface

uses
  System.SysUtils, C64.CPU, A2600.Sound.TIA;

type
  TAtari2600Audio = class
  private
    FCPU: TCPU6510;
    FTIA: TTIASound;
    FROM: TBytes;
    FRAM: array[0..127] of Byte;
    FBank, FCycles, FStall, FTimer, FInterval, FTimerPhase: Integer;
    FTimerExpired: Boolean;
    FDebt, FClock: Double;
    function Read(Address: Word): Byte;
    procedure Write(Address: Word; Value: Byte);
    procedure Step;
  public
    constructor Create(const ROM: TBytes; PAL: Boolean = True);
    destructor Destroy; override;
    procedure Reset;
    procedure Sample(out Left, Right: SmallInt);
  end;

implementation

constructor TAtari2600Audio.Create(const ROM: TBytes; PAL: Boolean);
begin
  inherited Create;
  if (Length(ROM) <> 2048) and (Length(ROM) <> 4096) and (Length(ROM) <> 8192) and (Length(ROM) <> 16384) then
    raise EArgumentException.Create('A26 supports 2K/4K/F8/F6 cartridges');

  FROM := Copy(ROM);
  FClock := 1193191.666666667;
  if PAL then
    FClock := 1182298.0;
  FTIA := TTIASound.Create(FClock);
  FCPU := TCPU6510.Create;
  FCPU.Connect(Read, Write);
  Reset;
end;

destructor TAtari2600Audio.Destroy;
begin
  FCPU.Free;
  FTIA.Free;
  inherited;
end;

procedure TAtari2600Audio.Reset;
begin
  FillChar(FRAM, SizeOf(FRAM), 0);
  FBank := Length(FROM) div 4096 - 1;
  if FBank < 0 then
    FBank := 0;
  FCycles := 0;
  FStall := 0;
  FTimer := 0;
  FInterval := 1;
  FTimerPhase := 0;
  FTimerExpired := False;
  FDebt := 0;
  FTIA.Reset;
  FCPU.Reset;
end;

function TAtari2600Audio.Read(Address: Word): Byte;
begin
  var A := Integer(Address) and $1FFF;
  if A and $1000 <> 0 then
  begin
    if (Length(FROM) = 8192) and (A >= $1FF8) and (A <= $1FF9) then
      FBank := A - $1FF8;
    if (Length(FROM) = 16384) and (A >= $1FF6) and (A <= $1FF9) then
      FBank := A - $1FF6;
    if Length(FROM) = 2048 then
      Exit(FROM[A and $7FF]);

    Exit(FROM[FBank * 4096 + (A and $FFF)]);
  end;
  if A and $80 = 0 then
    Exit(0);

  if A and $200 = 0 then
    Exit(FRAM[A and $7F]);

  case A and $1F of
    4:
      Result := FTimer;
    5:
      begin
        Result := Ord(FTimerExpired) * $80;
        FTimerExpired := False;
      end;
  else
    Result := $FF;
  end;
end;

procedure TAtari2600Audio.Write(Address: Word; Value: Byte);
begin
  var A := Integer(Address) and $1FFF;
  if A and $1000 <> 0 then
  begin
    Read(Address);
    Exit;
  end;

  if A and $80 = 0 then
  begin
    A := A and $3F;
    if A = 2 then
      FStall := 76 - FCycles;
    if (A >= $15) and (A <= $1A) then
      FTIA.WriteRegister(A, Value);
  end
  else if A and $200 = 0 then
    FRAM[A and $7F] := Value
  else if A and $14 = $14 then
  begin
    case A and 3 of
      0:
        FInterval := 1;
      1:
        FInterval := 8;
      2:
        FInterval := 64;
      3:
        FInterval := 1024;
    end;
    FTimer := Value;
    FTimerPhase := 0;
    FTimerExpired := False;
  end;
end;

procedure TAtari2600Audio.Step;
begin
  if FStall > 0 then
    Dec(FStall)
  else
    FCPU.Clock;
  if FCPU.Jammed then
    raise EArgumentException.Create('Atari cartridge CPU stopped');

  Inc(FCycles);
  if FCycles = 76 then
    FCycles := 0;
  Inc(FTimerPhase);
  if FTimerPhase >= FInterval then
  begin
    FTimerPhase := 0;
    if FTimer = 0 then
    begin
      FTimer := 255;
      FInterval := 1;
      FTimerExpired := True;
    end
    else
      Dec(FTimer);
  end;
end;

procedure TAtari2600Audio.Sample(out Left, Right: SmallInt);
begin
  FDebt := FDebt + FClock / 44100;
  while FDebt >= 1 do
  begin
    FDebt := FDebt - 1;
    Step;
  end;
  FTIA.Sample(Left, Right);
end;

end.

