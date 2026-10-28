unit GBA.Cartridge;

interface

uses
  System.SysUtils, System.Classes, System.Math, Core.Snapshots, GBA.Peripherals;

const
  ROM_CORE_ID_GBA = 'GBA';

const
  GBA_ROM_MAX_SIZE = 32 * 1024 * 1024;
  GBA_LOGO_PREFIX: array[0..15] of Byte = ($24, $FF, $AE, $51, $69, $9A, $A2, $21, $3D, $84, $82, $0A, $84, $E4, $09, $AD);

type
  TGBASaveKind = (None, SRAM, Flash64, Flash128, EEPROM);

  TGBACartridge = class
  private
    FData, FSave: TBytes;
    FKind: TGBASaveKind;
    FFixedEEPROMBits: Integer;
    FDirty, FFlashID, FFlashErase, FFlashProgram, FFlashBankSelect: Boolean;
    FFlashState, FFlashBank, FEEPROMBits, FEEPROMCount, FEEPROMRead, FEEPROMAddress: Integer;
    FHardware: TGBAHardware;
    FFlashBusy, FEEPROMBusy: Integer;
    FEEPROMCommand: array[0..81] of Byte;
    function ReadROMBusSlow(Address: Cardinal; Size: Integer): Cardinal; inline;
  public
    constructor Create(const Data: TBytes);
    destructor Destroy; override;
    procedure Tick(Cycles: Integer); //inline;
    procedure OverrideSaveKind(Kind: TGBASaveKind);
    procedure WriteROM(Address: Cardinal; Value: Byte);
    function ReadROM(Address: Cardinal): Byte;
    function ReadROMBus(Address: Cardinal; Size: Integer): Cardinal; inline;
    function ReadSave(Address: Cardinal): Byte;
    procedure WriteSave(Address: Cardinal; Value: Byte);
    procedure BeginEEPROM(Count: Integer);
    procedure WriteEEPROM(Value: Byte);
    function ReadEEPROM: Byte;
    procedure LoadBattery(const Data: TBytes);
    function BatteryData: TBytes;
    procedure MarkBatteryDirty;
    procedure Reset;
    procedure SerializeState(State: TStateArchive);
    property Hardware: TGBAHardware read FHardware;
    property Data: TBytes read FData;
    property SaveKind: TGBASaveKind read FKind;
    property BatteryDirty: Boolean read FDirty;
  end;

function IsGBAROM(const Data: TBytes): Boolean;

implementation

function IsGBAROM(const Data: TBytes): Boolean;
begin
  Result := (Length(Data) >= $C0) and (Data[$B2] = $96) and
    CompareMem(@Data[4], @GBA_LOGO_PREFIX[0], SizeOf(GBA_LOGO_PREFIX));
end;

constructor TGBACartridge.Create(const Data: TBytes);

  function Has(const Signature: AnsiString): Boolean;
  begin
    Result := False;
    for var i := 0 to Length(Data) - Length(Signature) do
      if (Data[i] = Ord(Signature[1])) and CompareMem(@Data[i], PAnsiChar(Signature), Length(Signature)) then
        Exit(True);
  end;

begin
  inherited Create;
  if (Length(Data) < $C0) or (Length(Data) > GBA_ROM_MAX_SIZE) then
    raise EReadError.Create('Invalid GBA cartridge (header or size)');

  FData := Copy(Data);
  var Code := AnsiString('    ');
  Move(Data[$AC], Code[1], 4);
  FHardware := TGBAHardware.Create(Code, Has('SIIRTC_V'));

  // Classic NES/Famicom mini cartridges decode mirrors up to 4 MiB.
  if (Code[1] = 'F') and (Length(FData) = $100000) then
  begin
    SetLength(FData, $400000);
    for var i := 1 to 3 do
      Move(FData[0], FData[i * $100000], $100000);
  end;

  // Game-code exceptions override misleading or absent SDK save markers.
  if (Code = 'A2YE') or (Code = 'AI2E') then
    FKind := TGBASaveKind.None
  else if Code = 'BR4J' then
    FKind := TGBASaveKind.Flash64
  else if (Code = 'AYGE') or (Code = 'ALUE') or (Code = 'ALUP') then
  begin
    FKind := TGBASaveKind.EEPROM;
    FFixedEEPROMBits := 6;
  end
  else if Has('SRAM_V') or Has('SRAM_F_V') then
    FKind := TGBASaveKind.SRAM
  else if Has('EEPROM_V') then
    FKind := TGBASaveKind.EEPROM
  else if Has('FLASH1M_V') then
    FKind := TGBASaveKind.Flash128
  else if Has('FLASH512_V') or Has('FLASH_V') then
    FKind := TGBASaveKind.Flash64
  else
    FKind := TGBASaveKind.SRAM; // Untagged cartridges may still use SRAM.
  case FKind of
    TGBASaveKind.SRAM:
      SetLength(FSave, $8000);
    TGBASaveKind.Flash64:
      SetLength(FSave, $10000);
    TGBASaveKind.Flash128:
      SetLength(FSave, $20000);
    TGBASaveKind.EEPROM:
      SetLength(FSave, $2000);
  end;
  if Length(FSave) > 0 then
    FillChar(FSave[0], Length(FSave), $FF);
  Reset;
end;

destructor TGBACartridge.Destroy;
begin
  FHardware.Free;
  inherited;
end;

procedure TGBACartridge.Tick(Cycles: Integer);
begin
  FHardware.Tick(Cycles);
  if FFlashBusy > 0 then
    FFlashBusy := Max(0, FFlashBusy - Cycles);
  if FEEPROMBusy > 0 then
    FEEPROMBusy := Max(0, FEEPROMBusy - Cycles);
end;

procedure TGBACartridge.OverrideSaveKind(Kind: TGBASaveKind);
begin
  if FKind = Kind then
    Exit;

  FKind := Kind;
  FFixedEEPROMBits := 0;
  FEEPROMBits := 6;
  var Size := 0;
  case Kind of
    TGBASaveKind.SRAM:
      Size := $8000;
    TGBASaveKind.Flash64:
      Size := $10000;
    TGBASaveKind.Flash128:
      Size := $20000;
    TGBASaveKind.EEPROM:
      Size := $2000;
  end;
  SetLength(FSave, Size);
  if Size > 0 then
    FillChar(FSave[0], Size, $FF);
  Reset;
end;

procedure TGBACartridge.WriteROM(Address: Cardinal; Value: Byte);
begin
  FHardware.WriteGPIO(Address, Value);
end;

procedure TGBACartridge.Reset;
begin
  FHardware.Reset;
  FFlashBusy := 0;
  FEEPROMBusy := 0;
  FFlashState := 0;
  FFlashBank := 0;
  FFlashID := False;
  FFlashErase := False;
  FFlashProgram := False;
  FFlashBankSelect := False;
  if FFixedEEPROMBits <> 0 then
    FEEPROMBits := FFixedEEPROMBits
  else if FEEPROMBits = 0 then
    FEEPROMBits := 6;
  FEEPROMCount := 0;
  FEEPROMRead := 68;
  FEEPROMAddress := 0;
end;

function TGBACartridge.ReadROMBus(Address: Cardinal; Size: Integer): Cardinal;
begin
  // Console supplies an aligned 8/16/32-bit Game Pak transaction.
  var Offset := Address and $1FFFFFF;
  if (Offset + Cardinal(Size) <= Cardinal(Length(FData))) and ((Address < $080000C4) or (Address > $080000C9)) then
    case Size of
      1:
        Result := FData[Offset];
      2:
        Result := PWord(@FData[Offset])^;
      4:
        Result := PCardinal(@FData[Offset])^;
    else
      Result := ReadROMBusSlow(Address, Size);
    end
  else
    Result := ReadROMBusSlow(Address, Size);
end;

function TGBACartridge.ReadROMBusSlow(Address: Cardinal; Size: Integer): Cardinal;
begin
  // GPIO bytes and unmapped ROM keep their individual device/open-bus reads.
  Result := 0;
  for var i := 0 to Size - 1 do
    Result := Result or (Cardinal(ReadROM(Address + Cardinal(i))) shl (i * 8));
end;

function TGBACartridge.ReadROM(Address: Cardinal): Byte;
begin
  if FHardware.ReadGPIO(Address, Result) then
    Exit;

  Address := Address and $1FFFFFF;
  if Address < Cardinal(Length(FData)) then
    Result := FData[Address]
  else if Address and 1 = 0 then
    Result := Byte((Address shr 1) and 255)
  else
    Result := Byte((Address shr 9) and 255);
end;

function TGBACartridge.ReadSave(Address: Cardinal): Byte;
begin
  Result := $FF;
  if FHardware.ReadTilt(Address, Result) then
    Exit;

  Address := Address and $FFFF;
  if FKind = TGBASaveKind.SRAM then
    Exit(FSave[Address and $7FFF]);

  if not (FKind in [TGBASaveKind.Flash64, TGBASaveKind.Flash128]) then
    Exit;

  if FFlashID then
  begin
    if Address and 3 = 0 then
      Exit($C2);

    if Address and 3 = 1 then
      if FKind = TGBASaveKind.Flash128 then
        Exit($09)
      else
        Exit($1C);
  end;
  Result := FSave[Address + Cardinal(FFlashBank * $10000)];
  if FFlashBusy > 0 then
    Result := (Result xor $80) and $80;
end;

procedure TGBACartridge.WriteSave(Address: Cardinal; Value: Byte);
begin
  if FHardware.WriteTilt(Address, Value) then
    Exit;

  if FFlashBusy > 0 then
    Exit;

  Address := Address and $FFFF;
  if FKind = TGBASaveKind.SRAM then
  begin
    FSave[Address and $7FFF] := Value;
    FDirty := True;
    Exit;
  end;

  if not (FKind in [TGBASaveKind.Flash64, TGBASaveKind.Flash128]) then
    Exit;

  if FFlashProgram then
  begin
    FSave[Address + Cardinal(FFlashBank * $10000)] := FSave[Address + Cardinal(FFlashBank * $10000)] and Value;
    FFlashProgram := False;
    FDirty := True;
    FFlashBusy := 85;
    if Value = $FF then
      FFlashBusy := 17;
    Exit;
  end;

  if FFlashBankSelect then
  begin
    if (Address = 0) and (FKind = TGBASaveKind.Flash128) then
      FFlashBank := Value and 1;
    FFlashBankSelect := False;
    Exit;
  end;

  if Value = $F0 then
  begin
    FFlashID := False;
    FFlashState := 0;
    FFlashErase := False;
    Exit;
  end;

  case FFlashState of
    0:
      if (Address = $5555) and (Value = $AA) then
        FFlashState := 1;
    1:
      begin
        if (Address = $2AAA) and (Value = $55) then
          FFlashState := 2
        else
          FFlashState := 0;
      end;
    2:
      begin
        FFlashState := 0;
        if FFlashErase then
        begin
          if (Address = $5555) and (Value = $10) then
          begin
            FillChar(FSave[0], Length(FSave), $FF);
            FDirty := True;
            FFlashBusy := 2000000 * (Length(FSave) div $1000);
          end
          else if Value = $30 then
          begin
            FillChar(FSave[(Address and $F000) + Cardinal(FFlashBank * $10000)], $1000, $FF);
            FDirty := True;
            FFlashBusy := 2000000;
          end;
          FFlashErase := False;
        end
        else if Address = $5555 then
          case Value of
            $90:
              FFlashID := True;
            $80:
              FFlashErase := True;
            $A0:
              FFlashProgram := True;
            $B0:
              FFlashBankSelect := True;
          end;
      end;
  end;
end;

procedure TGBACartridge.BeginEEPROM(Count: Integer);
begin
  if FFixedEEPROMBits <> 0 then
    FEEPROMBits := FFixedEEPROMBits
  else
  begin
    if Count in [9, 73] then
      FEEPROMBits := 6;
    if Count in [17, 81] then
      FEEPROMBits := 14;
  end;
  if Count <> 68 then
    FEEPROMCount := 0;
end;

procedure TGBACartridge.WriteEEPROM(Value: Byte);
begin
  if (FKind <> TGBASaveKind.EEPROM) or (FEEPROMBusy > 0) then
    Exit;

  if FEEPROMCount >= Length(FEEPROMCommand) then
    FEEPROMCount := 0;
  if (FEEPROMCount = 0) and (Value and 1 = 0) then
    Exit;

  FEEPROMCommand[FEEPROMCount] := Value and 1;
  Inc(FEEPROMCount);
  if FEEPROMCount < 2 then
    Exit;

  var ReadCommand := FEEPROMCommand[1] <> 0;
  var Needed := 2 + FEEPROMBits + 1;
  if not ReadCommand then
    Inc(Needed, 64);
  if FEEPROMCount <> Needed then
    Exit;

  FEEPROMAddress := 0;
  for var i := 2 to 1 + FEEPROMBits do
    FEEPROMAddress := (FEEPROMAddress shl 1) or FEEPROMCommand[i];
  FEEPROMAddress := (FEEPROMAddress and $3FF) * 8;
  if ReadCommand then
    FEEPROMRead := 0
  else
  begin
    for var i := 0 to 7 do
    begin
      var B := 0;
      for var Bit := 0 to 7 do
        B := (B shl 1) or FEEPROMCommand[2 + FEEPROMBits + i * 8 + Bit];
      FSave[FEEPROMAddress + i] := Byte(B);
    end;
    FDirty := True;
    FEEPROMBusy := 108368;
  end;
  FEEPROMCount := 0;
end;

function TGBACartridge.ReadEEPROM: Byte;
begin
  Result := 1;
  if FEEPROMBusy > 0 then
    Exit(0);

  if FEEPROMRead >= 68 then
    Exit;

  if FEEPROMRead < 4 then
    Result := 0
  else
    Result := (FSave[FEEPROMAddress + (FEEPROMRead - 4) div 8] shr (7 - (FEEPROMRead - 4) mod 8)) and 1;
  Inc(FEEPROMRead);
end;

procedure TGBACartridge.LoadBattery(const Data: TBytes);
begin
  if (FKind = TGBASaveKind.EEPROM) and ((Length(Data) = 512) or (Length(Data) = 8192)) then
  begin
    Move(Data[0], FSave[0], Length(Data));
    if FFixedEEPROMBits <> 0 then
      FEEPROMBits := FFixedEEPROMBits
    else if Length(Data) = 8192 then
      FEEPROMBits := 14
    else
      FEEPROMBits := 6;
  end
  else if Length(Data) = Length(FSave) then
  begin
    if Length(Data) > 0 then
      Move(Data[0], FSave[0], Length(Data));
  end
  else
    raise EReadError.Create('Invalid GBA battery save size');

  FDirty := False;
end;

function TGBACartridge.BatteryData: TBytes;
begin
  if (FKind = TGBASaveKind.EEPROM) and (FEEPROMBits = 6) then
    Result := Copy(FSave, 0, 512)
  else
    Result := Copy(FSave);
end;

procedure TGBACartridge.MarkBatteryDirty;
begin
  FDirty := Length(FSave) > 0;
end;

procedure TGBACartridge.SerializeState(State: TStateArchive);
begin
  State.Field(FFlashBusy, SizeOf(FFlashBusy));
  State.Field(FEEPROMBusy, SizeOf(FEEPROMBusy));
  FHardware.SerializeState(State);
  if Length(FSave) > 0 then
    State.Field(FSave[0], Length(FSave));
  State.Field(FFlashState, SizeOf(FFlashState));
  State.Field(FFlashBank, SizeOf(FFlashBank));
  State.Field(FFlashID, SizeOf(FFlashID));
  State.Field(FFlashErase, SizeOf(FFlashErase));
  State.Field(FFlashProgram, SizeOf(FFlashProgram));
  State.Field(FFlashBankSelect, SizeOf(FFlashBankSelect));
  State.Field(FEEPROMBits, SizeOf(FEEPROMBits));
  State.Field(FEEPROMCount, SizeOf(FEEPROMCount));
  State.Field(FEEPROMRead, SizeOf(FEEPROMRead));
  State.Field(FEEPROMAddress, SizeOf(FEEPROMAddress));
  State.Field(FEEPROMCommand, SizeOf(FEEPROMCommand));

  if State.Loading then
  begin
    if (FFlashState < 0) or
      (FFlashState > 2) or
      (FFlashBank < 0) or
      (FFlashBank > Ord(FKind = TGBASaveKind.Flash128)) or
      not (FEEPROMBits in [6, 14]) or
      (FEEPROMCount < 0) or
      (FEEPROMCount > 81) or
      (FEEPROMRead < 0) or
      (FEEPROMRead > 68) or
      (FEEPROMAddress < 0) or
      (FEEPROMAddress > $1FF8) then
      raise EReadError.Create('Invalid GBA cartridge state');

    MarkBatteryDirty;
  end;
end;

end.

