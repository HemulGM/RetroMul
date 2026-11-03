unit CV.SSTFlash;

interface

uses
  System.SysUtils, Core.Snapshots;

type
  // SST39SF010A/020A/040: 4 KiB sectors, A14..A0 unlock command addresses.
  // Microchip DS20005022: byte program, ID, sector/chip erase, DQ6/DQ7 polling.
  TCVSSTFlash = class
  private
    FData: TBytes;
    FCommand, FOperation, FRemaining, FAddress: Integer;
    FProgramData: Byte;
    FID, FToggle: Boolean;
    procedure Complete;
  public
    constructor Create(const Data: TBytes);
    procedure Reset;
    procedure Advance(Clocks: Integer);
    function Read(Address: Integer): Byte;
    procedure Write(Address: Integer; Value: Byte);
    function Image: TBytes;
    procedure LoadImage(const Data: TBytes);
    procedure SerializeState(State: TStateArchive);
  end;

implementation

uses
  System.Classes;

constructor TCVSSTFlash.Create(const Data: TBytes);
begin
  inherited Create;
  if (Length(Data) <> $20000) and (Length(Data) <> $40000) and (Length(Data) <> $80000) then
    raise EReadError.Create('SST cartridge requires a 128, 256 or 512 KiB image');
  FData := Copy(Data);
  Reset;
end;

procedure TCVSSTFlash.Reset;
begin
  FCommand := 0;
  FOperation := 0;
  FRemaining := 0;
  FAddress := 0;
  FProgramData := $FF;
  FID := False;
  FToggle := False;
end;

procedure TCVSSTFlash.Complete;
begin
  case FOperation of
    1:
      FData[FAddress] := FData[FAddress] and FProgramData;
    2:
      FillChar(FData[FAddress and not $FFF], $1000, $FF);
    3:
      FillChar(FData[0], Length(FData), $FF);
  end;
  FOperation := 0;
  FRemaining := 0;
end;

procedure TCVSSTFlash.Advance(Clocks: Integer);
begin
  if FRemaining = 0 then
    Exit;
  Dec(FRemaining, Clocks);
  if FRemaining <= 0 then
    Complete;
end;

function TCVSSTFlash.Read(Address: Integer): Byte;
begin
  Address := Address and (Length(FData) - 1);
  Result := FData[Address];
  if FRemaining > 0 then
  begin
    FToggle := not FToggle;
    Result := (Result and $3F) or (Ord(FToggle) shl 6);
    if FOperation = 1 then
      Result := Result or ((not FProgramData) and $80);
    Exit;
  end;
  if FID then
    case Address and $FFFF of
      0:
        Result := $BF;
      1:
        case Length(FData) of
          $20000:
            Result := $B5;
          $40000:
            Result := $B6;
          $80000:
            Result := $B7;
        end;
    else
      Result := $FF;
    end;
end;

procedure TCVSSTFlash.Write(Address: Integer; Value: Byte);
begin
  Address := Address and (Length(FData) - 1);
  if FRemaining > 0 then
    Exit;
  // Data after A0 is a byte, even when it equals an unlock/reset command.
  if FCommand = 3 then
  begin
    FCommand := 0;
    FID := False;
    FOperation := 1;
    FAddress := Address;
    FProgramData := Value;
    FRemaining := 72;
    FToggle := False; // 20 us at 3.579545 MHz
    Exit;
  end;
  if Value = $F0 then
  begin
    FID := False;
    FCommand := 0;
    Exit;
  end;
  var A := Address and $7FFF;
  case FCommand of
    0:
      if (A = $5555) and (Value = $AA) then
        FCommand := 1;
    1:
      if (A = $2AAA) and (Value = $55) then
        FCommand := 2
      else
        FCommand := 0;
    2:
      begin
        FCommand := 0;
        if A = $5555 then
          case Value of
            $90:
              FID := True;
            $A0:
              FCommand := 3;
            $80:
              FCommand := 4;
          end;
      end;
    4:
      if (A = $5555) and (Value = $AA) then
        FCommand := 5
      else
        FCommand := 0;
    5:
      if (A = $2AAA) and (Value = $55) then
        FCommand := 6
      else
        FCommand := 0;
    6:
      begin
        FCommand := 0;
        FID := False;
        FToggle := False;
        FAddress := Address;
        if Value = $30 then
        begin
          FOperation := 2;
          FRemaining := 89489;
        end
        else if (A = $5555) and (Value = $10) then
        begin
          FOperation := 3;
          FRemaining := 357955;
        end;
      end;
  end;
end;

function TCVSSTFlash.Image: TBytes;
begin
  Result := Copy(FData);
end;

procedure TCVSSTFlash.LoadImage(const Data: TBytes);
begin
  if Length(Data) <> Length(FData) then
    raise EReadError.Create('SST flash save has an invalid size');
  FData := Copy(Data);
  Reset;
end;

procedure TCVSSTFlash.SerializeState(State: TStateArchive);
begin
  State.Field(FData[0], Length(FData));
  State.Field(FCommand, SizeOf(FCommand));
  State.Field(FOperation, SizeOf(FOperation));
  State.Field(FRemaining, SizeOf(FRemaining));
  State.Field(FAddress, SizeOf(FAddress));
  State.Field(FProgramData, SizeOf(FProgramData));
  State.Field(FID, SizeOf(FID));
  State.Field(FToggle, SizeOf(FToggle));
  if State.Loading and ((FCommand < 0) or (FCommand > 6) or
    (FOperation < 0) or (FOperation > 3) or
    (FRemaining < 0) or (FRemaining > 357955) or
    ((FOperation = 0) <> (FRemaining = 0)) or
    (FAddress < 0) or (FAddress >= Length(FData))) then
    raise EReadError.Create('Invalid SST flash operation');
end;

end.

