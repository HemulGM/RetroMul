unit NES.Mapper.Cony;

interface

uses
  NES.State, NES.Types, NES.Mapper, NES.Mapper.Banked;

type
  TMapperCony = class(TMapperBanked)
  private
    FRegisters: array[0..10] of Byte;
    FExpansion: array[0..3] of Byte;
    FMode, FBank: Byte;
    FCounter: Integer;
    FEnabled, FPending, FTwoK, FOneK: Boolean;
    procedure UpdateBanks;
  public
    procedure SerializeState(State: TNesStateArchive); override;
    constructor Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
    procedure Reset; override;
    procedure ClockCpu; override;
    function IrqPending: Boolean; override;
    function CpuRead(Address: UInt16; out Value: UInt8): Boolean; override;
    function CpuWrite(Address: UInt16; Value: UInt8): Boolean; override;
  end;

implementation

procedure TMapperCony.SerializeState(State: TNesStateArchive);
begin
  inherited;
  State.Field(FRegisters, SizeOf(FRegisters));
  State.Field(FExpansion, SizeOf(FExpansion));
  State.Field(FMode, SizeOf(FMode));
  State.Field(FBank, SizeOf(FBank));
  State.Field(FCounter, SizeOf(FCounter));
  State.Field(FEnabled, SizeOf(FEnabled));
  State.Field(FPending, SizeOf(FPending));
  State.Field(FTwoK, SizeOf(FTwoK));
  State.Field(FOneK, SizeOf(FOneK));
end;

constructor TMapperCony.Create(const Prg, Chr: TByteArray; HasChrRam: Boolean; MirrorMode: TMirrorMode);
begin
  inherited;
  Reset;
end;

procedure TMapperCony.Reset;
begin
  inherited;
  FillChar(FRegisters, SizeOf(FRegisters), 0);
  FillChar(FExpansion, SizeOf(FExpansion), 0);
  FMode := 0;
  FBank := 0;
  FCounter := 0;
  FEnabled := False;
  FPending := False;
  FTwoK := False;
  FOneK := False;
  UpdateBanks;
end;

procedure TMapperCony.UpdateBanks;
begin
  Mirror(FMode and 3);
  if FTwoK and not FOneK then
  begin
    Chr2(0, FRegisters[0]);
    Chr2(1, FRegisters[1]);
    Chr2(2, FRegisters[6]);
    Chr2(3, FRegisters[7]);
  end
  else
    for var i := 0 to 7 do
      Chr1(i, FRegisters[i] or ((FBank and $30) shl 4));
  if (FMode and $40) <> 0 then
  begin
    Prg16(0, FBank and $3F);
    Prg16(1, (FBank and $30) or $0F);
  end
  else
  begin
    for var i := 0 to 2 do
      Prg8(i, FRegisters[8 + i]);
    Prg8(3, -1);
  end;
end;

function TMapperCony.CpuRead(Address: UInt16; out Value: UInt8): Boolean;
begin
  if Address = $5000 then
  begin
    Value := 0;
    Exit(True);
  end;
  if (Address >= $5100) and (Address <= $5103) then
  begin
    Value := FExpansion[Address and 3];
    Exit(True);
  end;
  Result := inherited CpuRead(Address, Value);
end;

function TMapperCony.CpuWrite(Address: UInt16; Value: UInt8): Boolean;
begin
  if (Address >= $5100) and (Address <= $5103) then
  begin
    FExpansion[Address and 3] := Value;
    Exit(True);
  end;
  if Address < $8000 then
    Exit(inherited CpuWrite(Address, Value));
  Result := True;
  if (Address >= $8300) and (Address <= $8302) then
  begin
    FMode := FMode and $BF;
    FRegisters[8 + Address - $8300] := Value;
  end
  else if (Address >= $8310) and (Address <= $8317) then
  begin
    FRegisters[Address - $8310] := Value;
    if (Address >= $8312) and (Address <= $8315) then
      FOneK := True;
  end
  else
    case Address of
      $8000:
        begin
          FTwoK := True;
          FBank := Value;
          FMode := FMode or $40;
        end;
      $B000, $B0FF, $B1FF:
        begin
          FBank := Value;
          FMode := FMode or $40;
        end;
      $8100:
        FMode := Value or (FMode and $40);
      $8200:
        begin
          FCounter := (FCounter and $FF00) or Value;
          FPending := False;
        end;
      $8201:
        begin
          FCounter := (FCounter and $FF) or (Integer(Value) shl 8);
          FEnabled := (FMode and $80) <> 0;
        end;
    end;
  UpdateBanks;
end;

procedure TMapperCony.ClockCpu;
begin
  if FEnabled then
  begin
    FCounter := (FCounter - 1) and $FFFF;
    if FCounter = 0 then
    begin
      FPending := True;
      FEnabled := False;
      FCounter := $FFFF;
    end;
  end;
end;

function TMapperCony.IrqPending: Boolean;
begin
  Result := FPending;
end;

end.

