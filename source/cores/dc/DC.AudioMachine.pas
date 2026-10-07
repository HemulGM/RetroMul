unit DC.AudioMachine;

interface

uses
  System.SysUtils, DC.CPU.ARM7, DC.Sound.AICA;

type
  TDSFAudio = class
  private
    FImage, FRAM: TBytes;
    FCPU: TARM7;
    FAICA: TAICA;
    FDebt: Integer;
    function Read(Address: Cardinal; Size: Integer): Cardinal;
    procedure Write(Address, Value: Cardinal; Size: Integer);
    procedure SoundWrite(Address: Cardinal; Value: Byte);
    function SoundRead(Address: Cardinal): Byte;
  public
    constructor Create(const Image: TBytes);
    destructor Destroy; override;
    procedure Reset;
    procedure Sample(out Left, Right: SmallInt);
  end;

implementation

constructor TDSFAudio.Create(const Image: TBytes);
begin
  inherited Create;
  if Length(Image) > $800000 then
    raise EArgumentException.Create('DSF image exceeds 8 MiB');
  FImage := Copy(Image);
  SetLength(FRAM, $800000);
  FAICA := TAICA.Create(SoundRead, SoundWrite);
  FCPU := TARM7.Create(Read, Write);
  Reset;
end;

destructor TDSFAudio.Destroy;
begin
  FCPU.Free;
  FAICA.Free;
  inherited;
end;

procedure TDSFAudio.Reset;
begin
  for var I := 0 to High(FRAM) do
    FRAM[I] := 0;
  for var I := 0 to High(FImage) do
    FRAM[I] := FImage[I];
  FCPU.Reset;
  FAICA.Reset;
  FDebt := 0;
end;

procedure TDSFAudio.SoundWrite(Address: Cardinal; Value: Byte);
begin
  FRAM[Address and $7FFFFF] := Value;
end;

function TDSFAudio.SoundRead(Address: Cardinal): Byte;
begin
  Result := FRAM[Address and $7FFFFF];
end;

function TDSFAudio.Read(Address: Cardinal; Size: Integer): Cardinal;
begin
  var Rotate: Integer := 0;
  if Size = 4 then
  begin
    Rotate := Integer(Address and 3) * 8;
    Address := Address and $FFFFFFFC;
  end;
  Result := 0;
  for var I := 0 to Size - 1 do
  begin
    var A := ARMAdd(Address, I) and $FFFFFF;
    var V: Byte;
    if A < $800000 then
      V := FRAM[A]
    else if A < $808000 then
      V := FAICA.ReadRegister(A - $800000)
    else
      V := $FF;
    Result := Result or (Cardinal(V) shl (I * 8));
  end;
  if Rotate <> 0 then
    Result := (Result shr Rotate) or (Result shl (32 - Rotate));
end;

procedure TDSFAudio.Write(Address, Value: Cardinal; Size: Integer);
begin
  if Size = 4 then
    Address := Address and $FFFFFFFC;
  for var I := 0 to Size - 1 do
  begin
    var A := ARMAdd(Address, I) and $FFFFFF;
    var V: Byte := (Value shr (I * 8)) and 255;
    if A < $800000 then
      FRAM[A] := V
    else if A < $808000 then
      FAICA.WriteRegister(A - $800000, V);
  end;
end;

procedure TDSFAudio.Sample(out Left, Right: SmallInt);
begin
  Inc(FDebt, 128);
  while FDebt > 0 do
  begin
    try
      Dec(FDebt, FCPU.Step(FAICA.FIQ));
    except
      on E: EArgumentException do
        raise EArgumentException.CreateFmt('DSF ARM at %.8x: %s', [FCPU.R[15], E.Message]);
    end;
  end;
  FAICA.Sample(Left, Right);
end;

end.

