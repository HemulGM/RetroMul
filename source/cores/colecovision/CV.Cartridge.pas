unit CV.Cartridge;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots, MD.EEPROM, CV.SSTFlash;

type
  // Ordinals are persisted in settings: append new boards.
  TCVMapper = (Standard, MegaCart, Activision, Activision24C02, Activision24C256,
    Activision24C08, SRAM2K, OpcodeOCM, OpcodeSGC);

  TCVCartridge = class
  private
    FData, FSaveData: TBytes;
    FMapper: TCVMapper;
    FBank, FBankCount: Integer;
    FOCMBanks: array[0..3] of Byte;
    FOCMCommand, FOCMState: Byte;
    FOCMReadClocks: Integer;
    FEEPROM: TMDEEPROM;
    FFlash: TCVSSTFlash;
    FFlashA16: Byte;
    FEEPROMPins: Byte;
    FCRC: Cardinal;
    FNeedsF18A, FNeedsLegacyRAM: Boolean;
    function ROM(Offset: Integer): Byte;
    procedure WriteOCM(Address: Word; Value: Byte);
  public
    constructor Create(const Data: TBytes; MapperHint: Integer = -1);
    destructor Destroy; override;
    procedure Reset;
    procedure AdvanceClocks(Cycles: Integer);
    function Read(Address: Word): Byte;
    procedure Write(Address: Word; Value: Byte);
    procedure SerializeState(State: TStateArchive);
    procedure LoadRAM(const Data: TBytes);
    function SaveRAM: TBytes;
    property Mapper: TCVMapper read FMapper;
    property CRC: Cardinal read FCRC;
    property NeedsF18A: Boolean read FNeedsF18A;
    property NeedsLegacyRAM: Boolean read FNeedsLegacyRAM;
    class function HasHeader(const Data: TBytes; Offset: Integer = 0): Boolean; static;
    class function DetectMapper(const Data: TBytes): TCVMapper; static;
  end;

implementation

uses
  System.Math, SG1000.Cartridge;

const
  OCMReadWindowClocks = 228 * 262 * 3;
  OCMNormal = 0;
  OCMInit = 1;
  OCMStatus = 2;
  OCMWriteByte = 3;

class function TCVCartridge.HasHeader(const Data: TBytes; Offset: Integer): Boolean;
begin
  Result := (Offset >= 0) and (Offset + 2 <= Length(Data)) and
    (((Data[Offset] = $AA) and (Data[Offset + 1] = $55)) or
    ((Data[Offset] = $55) and (Data[Offset + 1] = $AA)));
end;

class function TCVCartridge.DetectMapper(const Data: TBytes): TCVMapper;
begin
  // Board identities independently listed by ColecoDS / Gearcoleco.
  case SGCRC32(Data) of
    $FEE15196, $1053F610:
      Exit(TCVMapper.SRAM2K);
    $DDDD1396, $9F74B0E9:
      Exit(TCVMapper.Activision24C02);
    $62DACF07:
      Exit(TCVMapper.Activision24C256);
    // Physical SST-based SGC boards, verified in MAME coleco_homebrew.xml.
      $30D337E4, $EFE6A1A5:
      Exit(TCVMapper.OpcodeSGC);
    $E4676D56, $76004C98, $C4EA9601, $6C8113C1, $2426C300, $80586CC5, $BDAE4248, $DE785EE3, $6831AD48, $CF803DDC:
      Exit(TCVMapper.OpcodeOCM);
  end;
  Result := TCVMapper.Standard;
  if Length(Data) > $8000 then
  begin
    Result := TCVMapper.MegaCart;
    if HasHeader(Data) and not HasHeader(Data, Length(Data) - $4000) then
      Result := TCVMapper.Activision;
  end;
end;

constructor TCVCartridge.Create(const Data: TBytes; MapperHint: Integer);
begin
  inherited Create;
  if (Length(Data) < 2) or (Length(Data) > $200000) then
    raise EReadError.Create('ColecoVision cartridge must contain 2 bytes to 2 MiB');
  FData := Copy(Data);
  FCRC := SGCRC32(Data);
  FMapper := DetectMapper(Data);
  if MapperHint >= 0 then
  begin
    if MapperHint > Ord(High(TCVMapper)) then
      raise EReadError.Create('Unknown ColecoVision cartridge mapper');
    FMapper := TCVMapper(MapperHint);
  end;
  case FCRC of
    $E4676D56, $76004C98, $6C8113C1, $80586CC5, $BDAE4248, $91326103, $3E4F3045, $D0F37969, $B90C2062, $B5BE3448, $FD298C7E, $AD7BB5B0, $6411055C, $1AA1E72A:
      FNeedsF18A := True;
  end;
  // Older expanded-memory demos predate SGM port-controlled RAM.
  // Identified from the user's collection and checked by RAM-access probes.
  case FCRC of
    $B42F4E5B, $4280E9F1, $54F7F145, $D849705B, $529FBBAF, $B1215C7A:
      FNeedsLegacyRAM := True; // GamePack Demo 2 clears over 1 KiB above $6800.
  end;
  FBankCount := (Length(FData) + $3FFF) div $4000;
  case FMapper of
    TCVMapper.Standard, TCVMapper.SRAM2K:
      if Length(Data) > $8000 then
        raise EReadError.Create('Standard ColecoVision cartridge exceeds 32 KiB');
    TCVMapper.MegaCart:
      if (Length(Data) < $10000) or (Length(Data) > $100000) or
        (Length(Data) and (Length(Data) - 1) <> 0) then
        raise EReadError.Create('MegaCart requires a power-of-two size from 64 KiB to 1 MiB');
    TCVMapper.OpcodeOCM, TCVMapper.OpcodeSGC:
      begin
        if Length(Data) mod $2000 <> 0 then
          raise EReadError.Create('OCM cartridge must contain complete 8 KiB banks');
        FBankCount := Length(Data) div $2000;
        if FMapper = TCVMapper.OpcodeOCM then
        begin
          SetLength(FSaveData, $400);
          FillChar(FSaveData[0], Length(FSaveData), $FF);
        end
        else
          FFlash := TCVSSTFlash.Create(Data);
      end;
  else
    if (Length(Data) < $8000) or (Length(Data) mod $4000 <> 0) then
      raise EReadError.Create('Activision cartridge needs complete 16 KiB banks');
  end;
  if FMapper = TCVMapper.SRAM2K then
    SetLength(FSaveData, $800);
  if FMapper in [TCVMapper.Activision24C02, TCVMapper.Activision24C256,
      TCVMapper.Activision24C08] then
  begin
    var Config := Default(TMDEEPROMConfig);
    Config.Mode := TMDEEPROMMode.Address8;
    Config.Size := 256;
    Config.PageSize := 8;
    if FMapper = TCVMapper.Activision24C08 then
    begin
      Config.Size := 1024;
      Config.PageSize := 16;
    end;
    if FMapper = TCVMapper.Activision24C256 then
    begin
      Config.Mode := TMDEEPROMMode.Address16;
      Config.Size := 32768;
      Config.PageSize := 64;
    end;
    Config.PageAlignment := Config.PageSize;
    Config.SDAInAddress := 1;
    Config.SDAOutAddress := 1;
    Config.SCLAddress := 1;
    Config.SDAInMask := 1;
    Config.SDAOutMask := 1;
    Config.SCLMask := 2;
    FEEPROM := TMDEEPROM.Create(Config);
  end;
  Reset;
end;

destructor TCVCartridge.Destroy;
begin
  FFlash.Free;
  FEEPROM.Free;
  inherited;
end;

procedure TCVCartridge.Reset;
begin
  FBank := 0;
  FEEPROMPins := 3;
  FOCMCommand := 0;
  FOCMState := OCMNormal;
  FOCMReadClocks := 0;
  for var I := 0 to 3 do
    FOCMBanks[I] := (3 - I) mod Max(1, FBankCount);
  FFlashA16 := 0;
  if FFlash <> nil then
  begin
    FillChar(FOCMBanks, SizeOf(FOCMBanks), 0);
    FFlash.Reset;
  end;
  if FEEPROM <> nil then
    FEEPROM.Reset;
  // Battery memory survives reset.
end;

procedure TCVCartridge.AdvanceClocks(Cycles: Integer);
begin
  FOCMReadClocks := Max(0, FOCMReadClocks - Cycles);
  if FFlash <> nil then
    FFlash.Advance(Cycles);
end;

function TCVCartridge.ROM(Offset: Integer): Byte;
begin
  Result := $FF;
  if (Offset >= 0) and (Offset < Length(FData)) then
    Result := FData[Offset];
end;

function TCVCartridge.Read(Address: Word): Byte;
begin
  Result := $FF;
  if Address < $8000 then
    Exit;
  var Offset := Integer(Address) - $8000;
  case FMapper of
    TCVMapper.OpcodeSGC:
      Exit(FFlash.Read(Integer(FOCMBanks[(Address shr 13) and 3]) * $2000 + (Address and $1FFF)));
    TCVMapper.SRAM2K:
      if Address >= $E000 then
        Exit(FSaveData[Address and $7FF]);
    TCVMapper.MegaCart:
      begin
        if Address >= $FFC0 then
          FBank := Address and (FBankCount - 1);
        if Address < $C000 then
          Offset := (FBankCount - 1) * $4000 + (Address and $3FFF)
        else
          Offset := FBank * $4000 + (Address and $3FFF);
      end;
    TCVMapper.Activision, TCVMapper.Activision24C02, TCVMapper.Activision24C256, TCVMapper.Activision24C08:
      begin
        if (Address = $FF80) and (FEEPROM <> nil) then
          Exit(FEEPROM.ReadBus(0, $FFFF) and 1);
        if Address >= $FF80 then
          Exit;
        if Address >= $C000 then
          Offset := FBank * $4000 + (Address and $3FFF);
      end;
    TCVMapper.OpcodeOCM:
      begin
        if Address >= $E000 then
        begin
          if (FOCMState = OCMStatus) and (Address and $FFF = 0) then
            Exit($FF);
          if (FOCMBanks[2] = FBankCount - 1) and (FOCMReadClocks > 0) and
            (Address and $FFF < $200) then
            Exit(FSaveData[Address and $3FF]);
        end;
        // Window order: registers 3,0,1,2.
        var Window := ((Address shr 13) + 3) and 3;
        Offset := Integer(FOCMBanks[Window]) * $2000 + (Address and $1FFF);
      end;
  end;
  Result := ROM(Offset);
end;

procedure TCVCartridge.WriteOCM(Address: Word; Value: Byte);
begin
  if Address < $E000 then
    Exit;
  if Address >= $FFFC then
  begin
    var Index := Address and 3;
    FOCMBanks[Index] := Value mod FBankCount;
    if Index = 2 then
      if FOCMBanks[2] = FBankCount - 1 then
        FOCMReadClocks := OCMReadWindowClocks
      else
        FOCMReadClocks := 0;
    Exit;
  end;
  // AA/55/F0 are valid programmed bytes too.
  if FOCMState = OCMWriteByte then
  begin
    FSaveData[Address and $3FF] := Value;
    FOCMState := OCMNormal;
    FOCMCommand := 0;
    Exit;
  end;
  case FOCMCommand of
    0:
      if Value = $AA then
        FOCMCommand := 1;
    1:
      if Value = $55 then
        FOCMCommand := 2
      else
        FOCMCommand := 0;
    2:
      begin
        FOCMCommand := 0;
        case Value of
          $80:
            FOCMState := OCMInit;
          $30:
            if FOCMState = OCMInit then
              FOCMState := OCMStatus;
          $A0:
            FOCMState := OCMWriteByte;
          $F0:
            FOCMState := OCMNormal;
        end;
      end;
  end;
  if Value = $F0 then
    FOCMState := OCMNormal;
end;

procedure TCVCartridge.Write(Address: Word; Value: Byte);
begin
  if FMapper = TCVMapper.OpcodeSGC then
  begin
    if Address < $8000 then
      Exit;
    case Address of
      $FFFC..$FFFE:
        if Value < FBankCount then
          FOCMBanks[Address - $FFFB] := Value;
      $FFFF:
        FFlashA16 := Value and 1;
    else
      FFlash.Write((Integer(FFlashA16) shl 16) or
        (Integer(FOCMBanks[(Address shr 13) and 3]) * $2000 + (Address and $1FFF)), Value);
    end;
    Exit;
  end;
  if FMapper = TCVMapper.OpcodeOCM then
  begin
    WriteOCM(Address, Value);
    Exit;
  end;
  if (FMapper = TCVMapper.SRAM2K) and (Address >= $E000) then
    FSaveData[Address and $7FF] := Value;
  if (FMapper in [TCVMapper.Activision, TCVMapper.Activision24C02,
      TCVMapper.Activision24C256, TCVMapper.Activision24C08]) and
    (Address >= $FF90) and (Address <= $FFB0) and (Address and $F = 0) then
    FBank := ((Address shr 4) and 3) mod FBankCount;
  if FEEPROM <> nil then
  begin
    case Address of
      $FFC0:
        FEEPROMPins := FEEPROMPins and not 2;
      $FFD0:
        FEEPROMPins := FEEPROMPins or 2;
      $FFE0:
        FEEPROMPins := FEEPROMPins and not 1;
      $FFF0:
        FEEPROMPins := FEEPROMPins or 1;
    else
      Exit;
    end;
    FEEPROM.WriteBus(0, FEEPROMPins, False, True);
  end;
end;

procedure TCVCartridge.LoadRAM(const Data: TBytes);
begin
  if Length(Data) = 0 then
    Exit;
  if FFlash <> nil then
    FFlash.LoadImage(Data)
  else if FEEPROM <> nil then
    FEEPROM.LoadBattery(Data)
  else if Length(FSaveData) > 0 then
  begin
    if Length(Data) <> Length(FSaveData) then
      raise EReadError.Create('ColecoVision battery file has an invalid size');
    FSaveData := Copy(Data);
  end;
end;

function TCVCartridge.SaveRAM: TBytes;
begin
  if FFlash <> nil then
    Result := FFlash.Image
  else if FEEPROM <> nil then
    Result := FEEPROM.BatteryData
  else
    Result := Copy(FSaveData);
end;

procedure TCVCartridge.SerializeState(State: TStateArchive);
begin
  var Mapper := FMapper;
  State.Field(Mapper, SizeOf(Mapper));
  if State.Loading and (Mapper <> FMapper) then
    raise EReadError.Create('ColecoVision snapshot cartridge mapper differs');
  State.Field(FBank, SizeOf(FBank));
  if State.Loading and ((FBank < 0) or (FBank >= FBankCount)) then
    raise EReadError.Create('Invalid ColecoVision cartridge bank');
  if Length(FSaveData) > 0 then
    State.Field(FSaveData[0], Length(FSaveData));
  if FMapper in [TCVMapper.OpcodeOCM, TCVMapper.OpcodeSGC] then
  begin
    State.Field(FOCMBanks, SizeOf(FOCMBanks));
    State.Field(FOCMCommand, SizeOf(FOCMCommand));
    State.Field(FOCMState, SizeOf(FOCMState));
    State.Field(FOCMReadClocks, SizeOf(FOCMReadClocks));
    if State.Loading then
    begin
      for var Bank in FOCMBanks do
        if Bank >= FBankCount then
          raise EReadError.Create('Invalid OCM bank');
      if (FOCMCommand > 2) or (FOCMState > OCMWriteByte) or
        (FOCMReadClocks < 0) or (FOCMReadClocks > OCMReadWindowClocks) then
        raise EReadError.Create('Invalid OCM EEPROM state');
    end;
  end;
  if FFlash <> nil then
  begin
    State.Field(FFlashA16, SizeOf(FFlashA16));
    if FFlashA16 > 1 then
      raise EReadError.Create('Invalid SGC flash address latch');
    FFlash.SerializeState(State);
  end;
  if FEEPROM <> nil then
  begin
    State.Field(FEEPROMPins, SizeOf(FEEPROMPins));
    if State.Loading and (FEEPROMPins > 3) then
      raise EReadError.Create('Invalid EEPROM pins');
    FEEPROM.SerializeState(State);
  end;
end;

end.

