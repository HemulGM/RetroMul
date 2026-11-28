unit SMS.Cartridge;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots, SG1000.Cartridge;

{$SCOPEDENUMS ON}

type
  TSMSMapper = (Sega, Codemasters, Korean, Zemina, Nemesis, Janggun, HiCom, FourPak,
    Korean188, Fixed48K, Seojin, EEPROM93C46);

  TSMSCartridge = class
  private
    FData: TBytes;
    FROMMask: Integer;
    FRAM: array[0..$7FFF] of Byte;
    FBanks: array[0..5] of Byte;
    FRegisters: array[0..3] of Byte;
    FMapper: TSMSMapper;
    FControl, FGame: Byte;
    FDirty: Boolean;
    FEEPROMWriteEnabled, FEEPROMOutput: Boolean;
    FEEPROMLines: Byte;
    FEEPROMMode, FEEPROMBits, FEEPROMCommand, FEEPROMValue, FEEPROMAddress: Integer;
    procedure ResetEEPROM;
    procedure WriteEEPROMLines(Value: Byte);
    procedure StoreEEPROM(Address, Value: Integer);
    function GetExpandedRAM: Boolean;
    function ROM(Bank, Offset, Size: Integer): Byte; inline;
  public
    function ReadAchievementRAM(Address: Cardinal; Buffer: PByte; Count: Cardinal): Cardinal;
    constructor Create(const Data: TBytes; MapperHint: Integer = -1);
    procedure Reset;
    function Read(Address: Word): Byte;
    procedure Write(Address: Word; Value: Byte);
    function SaveRAM: TBytes;
    procedure LoadRAM(const Data: TBytes);
    procedure SerializeState(State: TStateArchive);
    property Mapper: TSMSMapper read FMapper;
    property ExpandedRAM: Boolean read GetExpandedRAM;
    property Dirty: Boolean read FDirty write FDirty;
  end;

// SMS headers identify Japan/Export, but contain no PAL/NTSC flag.
// Unknown dumps use region tags from the basename, then NTSC.
function SMSAutoPAL(const Data: TBytes; const RomName: string): Boolean;

implementation

uses
  Core.Emulation.Types;

type
  TSMSRegionEntry = record
    CRC: Cardinal;
    Size: Integer;
    PAL: Boolean;
  end;

{$I SMS.Region.inc}

function SMSAutoPAL(const Data: TBytes; const RomName: string): Boolean;
begin
  var ROM := Data;
  if Length(ROM) mod $4000 = 512 then
    ROM := Copy(ROM, 512, Length(ROM) - 512);
  var CRC := SGCRC32(ROM);
  var L := Low(SMSRegionEntries);
  var H := High(SMSRegionEntries);
  while L <= H do
  begin
    var M := L + (H - L) div 2;
    if (CRC = SMSRegionEntries[M].CRC) and (Length(ROM) = SMSRegionEntries[M].Size) then
      Exit(SMSRegionEntries[M].PAL);
    if (CRC < SMSRegionEntries[M].CRC) or
      ((CRC = SMSRegionEntries[M].CRC) and (Length(ROM) < SMSRegionEntries[M].Size)) then
      H := M - 1
    else
      L := M + 1;
  end;

  // Japan implies 60 Hz. Export alone cannot distinguish 50 from 60 Hz.
  for var Offset in [$7FF0, $3FF0, $1FF0] do
    if (Length(ROM) >= Offset + 16) and
      CompareMem(@ROM[Offset], PAnsiChar(AnsiString('TMR SEGA')), 8) then
    begin
      if ROM[Offset + 15] shr 4 = 3 then
        Exit(False);
      Break;
    end;

  var PALTag := False;
  var NTSCTag := False;
  var Name := ExtractFileName(RomName).ToUpper;
  // Restrict matching to parenthesized/bracketed metadata, not title words
  // or directory names. Support both No-Intro and old GoodSMS region tags.
  var Opening := #0;
  var Start := 0;
  for var I := 1 to Length(Name) do
    if CharInSet(Name[I], ['(', '[']) then
    begin
      Opening := Name[I];
      Start := I + 1;
    end
    else if ((Opening = '(') and (Name[I] = ')')) or
      ((Opening = '[') and (Name[I] = ']')) then
    begin
      var Tag := Copy(Name, Start, I - Start).Trim;
      if (Tag <> '') and (Length(Tag) <= 4) then
      begin
        var RegionCode := True;
        for var C in Tag do
          if not CharInSet(C, ['U', 'E', 'J', 'B', 'K', 'W']) then
            RegionCode := False;
        if RegionCode then
        begin
          PALTag := PALTag or Tag.Contains('E');
          NTSCTag := NTSCTag or Tag.Contains('U') or Tag.Contains('J') or
            Tag.Contains('W');
        end;
      end;
      for var Country in Tag.Split([',', '/', ' '], TStringSplitOptions.ExcludeEmpty) do
      begin
        if (Country = 'EUROPE') or (Country = 'AUSTRALIA') or (Country = 'UK') or
          (Country = 'FRANCE') or (Country = 'GERMANY') or (Country = 'SPAIN') or
          (Country = 'ITALY') or (Country = 'PORTUGAL') or (Country = 'PAL') then
          PALTag := True;
        if (Country = 'USA') or (Country = 'JAPAN') or (Country = 'WORLD') or
          (Country = 'NTSC') then
          NTSCTag := True;
      end;
      Opening := #0;
    end;
  Result := PALTag and not NTSCTag;
end;

constructor TSMSCartridge.Create(const Data: TBytes; MapperHint: Integer);
begin
  inherited Create;
  if (Length(Data) = 0) or (Length(Data) > 4 * 1024 * 1024 + 512) then
    raise EReadError.Create('SMS cartridge must contain 1..4194304 bytes');

  var Start := 0;
  if Length(Data) mod $4000 = 512 then
    Start := 512;
  FData := Copy(Data, Start, Length(Data) - Start);
  FMapper := TSMSMapper.Sega;

  // Cartridge wiring from MAME's CC0 hash/sms.xml and hash/gamegear.xml.
  // A user-selected mapper remains available for unlisted cartridges.
  case SGCRC32(FData) of
    $BD610939:
      if Length(FData) = $8000 then
      begin
        // Castle of Illusion rolling demo: the old 32 KiB dump omits
        // 96 KiB of $FF from the physical 128 KiB EPROM. Restore those
        // bytes so bank reads and the export BIOS checksum match hardware.
        // https://www.smspower.org/forums/13480-RollingDemosOfCastleOfIllusionAndGhoulsnGhostsROMSize
        SetLength(FData, $20000);
        FillChar(FData[$8000], $18000, $FF);
      end;
    $47FA618D:
      raise EReadError.Create('Mode 5 Example Program requires a Genesis/Mega Drive VDP; it cannot run on Master System hardware.');
    $29822980, $8813514B, $A577CE46, $B9664AE1, $EA5C3A6F, $01A2D595, $152F0DCC, $2306AAF4, $3ACE6335, $5E53C7F7, $6CAA625B, $72981057, $76C5BDFB, $9FA727A0, $AA140C9C, $C1756BEE, $C21E6CD0, $C888222B, $D9A7F170, $DBE8895C, $F7C524F6:
      FMapper := TSMSMapper.Codemasters;
    $0918FBA0, $17AB6883, $565C799F, $61E8806F, $6D309AC5:
      FMapper := TSMSMapper.Fixed48K;
    $A67F2A5C:
      FMapper := TSMSMapper.FourPak;
    $00E9809F, $4088EEB4, $6EBFE1C3, $81A36A4F, $82C09B57, $8333C86E, $8D2D695D, $98AF0236, $FBA94148:
      FMapper := TSMSMapper.HiCom;
    $192949D5:
      FMapper := TSMSMapper.Janggun;
    $18FB98A3, $8040B2FA, $89B79E77, $929222C4, $97D03541, $BF5A994A:
      FMapper := TSMSMapper.Korean;
    $380D7400:
      FMapper := TSMSMapper.Korean188;
    $E316C06D:
      FMapper := TSMSMapper.Nemesis;
    $2DA8E943, $36EBCD6D, $3D8D0DD6, $4ED45BDA, $578A8A38, $A1A19135, $BB38CFD7:
      FMapper := TSMSMapper.EEPROM93C46;
    $CDBFE86E:
      FMapper := TSMSMapper.Seojin;
    $06965ED9, $0A77FA5E, $445525E2, $77EFE84A, $83F0EEDE, $9195C34C, $A05258F5, $F89AF3CC:
      FMapper := TSMSMapper.Zemina;
  end;

  if (MapperHint >= 0) and (MapperHint <= Ord(High(TSMSMapper))) then
    FMapper := TSMSMapper(MapperHint);
  if FMapper = TSMSMapper.EEPROM93C46 then
    FillChar(FRAM, 128, $FF);
  var Size := Length(FData);
  SetLength(FData, ((Size + $3FFF) div $4000) * $4000);
  for var i := Size to High(FData) do
    FData[i] := $FF;
  FROMMask := -1;
  if Length(FData) and (Length(FData) - 1) = 0 then
    FROMMask := Length(FData) - 1;
  Reset;
end;

function TSMSCartridge.GetExpandedRAM: Boolean;
begin
  Result := FMapper = TSMSMapper.Seojin;
end;

procedure TSMSCartridge.Reset;
begin
  for var i := 0 to 5 do
    FBanks[i] := i;
  if FMapper = TSMSMapper.Sega then
  begin
    FBanks[1] := 1;
    FBanks[2] := 2;
  end;
  if FMapper = TSMSMapper.Codemasters then
    FBanks[2] := 0;
  if FMapper = TSMSMapper.Nemesis then
    FBanks[0] := $0F;
  FillChar(FRegisters, SizeOf(FRegisters), 0);
  FControl := 0;
  ResetEEPROM;
  FGame := 0;
  // Battery RAM survives resets; loading a new object initializes it to zero.
end;

function TSMSCartridge.ROM(Bank, Offset, Size: Integer): Byte;
begin
  var Address := Bank * Size + Offset;
  if FROMMask >= 0 then
    Address := Address and FROMMask
  else
    Address := Address mod Length(FData);
  Result := FData[Address];
end;

procedure TSMSCartridge.ResetEEPROM;
begin
  FEEPROMWriteEnabled := False;
  FEEPROMOutput := True;
  FEEPROMLines := 0;
  FEEPROMMode := 0;
  FEEPROMBits := 0;
  FEEPROMCommand := 0;
  FEEPROMValue := 0;
  FEEPROMAddress := 0;
end;

procedure TSMSCartridge.StoreEEPROM(Address, Value: Integer);
begin
  FRAM[Address * 2] := Value and $FF;
  FRAM[Address * 2 + 1] := (Value shr 8) and $FF;
  FDirty := True;
end;

procedure TSMSCartridge.WriteEEPROMLines(Value: Byte);
begin
  // 93C46 in x16 organization: DI=bit 0, CLK=bit 1, CS=bit 2.
  // Commands and word data are shifted MSB first on rising CLK edges.
  var Previous := FEEPROMLines;
  FEEPROMLines := Value and 7;
  if Value and 4 = 0 then
  begin
    FEEPROMMode := 0;
    FEEPROMBits := 0;
    FEEPROMCommand := 0;
    FEEPROMOutput := True;
    Exit;
  end;

  if (Value and 2 = 0) or (Previous and 2 <> 0) then
    Exit;

  case FEEPROMMode of
    0:
      if Value and 1 <> 0 then
      begin
        FEEPROMMode := 1;
        FEEPROMBits := 0;
        FEEPROMCommand := 0;
      end;
    1:
      begin
        FEEPROMCommand := (FEEPROMCommand shl 1) or (Value and 1);
        Inc(FEEPROMBits);
        if FEEPROMBits <> 8 then
          Exit;

        FEEPROMAddress := FEEPROMCommand and 63;
        FEEPROMBits := 0;
        FEEPROMValue := 0;
        FEEPROMMode := 5;
        case FEEPROMCommand shr 6 of
          0:
            case FEEPROMAddress shr 4 of
              0:
                FEEPROMWriteEnabled := False;
              1:
                FEEPROMMode := 4; // WRAL
                2:
                if FEEPROMWriteEnabled then
                  for var i := 0 to 63 do
                    StoreEEPROM(i, $FFFF);
              3:
                FEEPROMWriteEnabled := True;
            end;
          1:
            FEEPROMMode := 3; // WRITE
            2:
            begin
              FEEPROMMode := 2;
              FEEPROMOutput := False; // Dummy zero before the first read word.
            end;
          3:
            if FEEPROMWriteEnabled then
              StoreEEPROM(FEEPROMAddress, $FFFF);
        end;
      end;
    2:
      begin
        var WordValue := Integer(FRAM[FEEPROMAddress * 2]) or
          (Integer(FRAM[FEEPROMAddress * 2 + 1]) shl 8);
        FEEPROMOutput := WordValue and (1 shl (15 - FEEPROMBits)) <> 0;
        Inc(FEEPROMBits);
        if FEEPROMBits = 16 then
        begin
          FEEPROMBits := 0;
          FEEPROMAddress := (FEEPROMAddress + 1) and 63;
        end;
      end;
    3, 4:
      begin
        FEEPROMValue := (FEEPROMValue shl 1) or (Value and 1);
        Inc(FEEPROMBits);
        if FEEPROMBits <> 16 then
          Exit;

        if FEEPROMWriteEnabled then
          if FEEPROMMode = 3 then
            StoreEEPROM(FEEPROMAddress, FEEPROMValue)
          else
            for var i := 0 to 63 do
              StoreEEPROM(i, FEEPROMValue);
        FEEPROMMode := 5;
        FEEPROMOutput := True;
      end;
  end;
end;

function TSMSCartridge.Read(Address: Word): Byte;
begin
  var Slot := Address div $4000;
  var Half := Address div $2000;
  if Address >= $C000 then
  begin
    if FMapper = TSMSMapper.Seojin then
      Exit(FRAM[Address and $3FFF]);

    Exit($FF);
  end;

  case FMapper of
    TSMSMapper.EEPROM93C46:
      begin
        if FControl and 8 <> 0 then
        begin
          if Address = $8000 then
            Exit((FEEPROMLines and 4) or 2 or Byte(Ord(FEEPROMOutput)));

          if (Address >= $8008) and (Address < $8088) then
            Exit(FRAM[Address - $8008]);
        end;
        Exit(ROM(FBanks[Slot], Address and $3FFF, $4000));
      end;
    TSMSMapper.Fixed48K:
      Exit(FData[Integer(Address) mod Length(FData)]);
    TSMSMapper.Seojin:
      begin
        if Address < $400 then
          Exit(ROM((FGame and $0F) * 2, Address, $4000) xor $80);

        Exit(ROM(((FGame and $0F) * 2) or FBanks[Slot], Address and $3FFF, $4000) xor $80);
      end;
    TSMSMapper.Sega, TSMSMapper.Korean:
      begin
        if (Address >= $8000) and (FControl and 8 <> 0) then
          Exit(FRAM[(Address and $3FFF) + ((FControl and 4) * $1000)]);

        if Address < $400 then
          Exit(FData[Address]);

        var Bank := Integer(FBanks[Slot]);
        if FControl and 3 <> 0 then
          Inc(Bank, (4 - (FControl and 3)) * 8);
        Exit(ROM(Bank, Address and $3FFF, $4000));
      end;
    TSMSMapper.Codemasters:
      begin
        if (Address >= $A000) and (FControl and $80 <> 0) then
          Exit(FRAM[Address and $1FFF]);

        Exit(ROM(FBanks[Slot], Address and $3FFF, $4000));
      end;
    TSMSMapper.HiCom:
      begin
        if Address >= $8000 then
          Exit(ROM(0, Address and $3FFF, $4000));

        Exit(ROM(FGame, Address, $8000));
      end;
    TSMSMapper.FourPak:
      begin
        var Bank := Integer(FRegisters[Slot]);
        if Slot = 2 then
          Inc(Bank, FRegisters[0] and $30);
        Exit(ROM(Bank, Address and $3FFF, $4000));
      end;
    TSMSMapper.Korean188:
      begin
        if Address < $4000 then
          Exit(FData[Address]);

        Exit(ROM((FGame xor $1F) + (Half - 2), Address and $1FFF, $2000));
      end;
    TSMSMapper.Janggun:
      begin
        var Value := ROM(FBanks[Half] and $3F, Address and $1FFF, $2000);
        if FBanks[Half] and $80 <> 0 then
        begin
          var Flipped := 0;
          for var i := 0 to 7 do
            Flipped := Flipped or (((Value shr i) and 1) shl (7 - i));
          Value := Flipped;
        end;
        Exit(Value);
      end;
  else
    Exit(ROM(FBanks[Half], Address and $1FFF, $2000));
  end;
end;

procedure TSMSCartridge.Write(Address: Word; Value: Byte);
begin
  case FMapper of
    TSMSMapper.EEPROM93C46:
      begin
        if Address = $FFFC then
        begin
          FControl := Value;
          if Value and $80 <> 0 then
          begin
            ResetEEPROM;
            FControl := 0;
          end;
        end;
        if Address >= $FFFD then
          FBanks[Address - $FFFD] := Value;
        if FControl and 8 <> 0 then
        begin
          if Address = $8000 then
            WriteEEPROMLines(Value);
          if (Address >= $8008) and (Address < $8088) then
          begin
            FRAM[Address - $8008] := Value;
            FDirty := True;
          end;
        end;
      end;
    TSMSMapper.Sega, TSMSMapper.Korean:
      begin
        if (Address >= $8000) and (Address < $C000) and (FControl and 8 <> 0) then
        begin
          FRAM[(Address and $3FFF) + ((FControl and 4) * $1000)] := Value;
          FDirty := True;
        end;
        if Address = $FFFC then
          FControl := Value;
        if Address >= $FFFD then
          FBanks[Address - $FFFD] := Value;
        if (FMapper = TSMSMapper.Korean) and (Address = $A000) then
          FBanks[2] := Value;
      end;
    TSMSMapper.Codemasters:
      begin
        if Address = 0 then
          FBanks[0] := Value;
        if Address = $4000 then
        begin
          FControl := Value;
          FBanks[1] := Value and $7F;
        end;
        if Address = $8000 then
          FBanks[2] := Value;
        if (Address >= $A000) and (Address < $C000) and (FControl and $80 <> 0) then
        begin
          FRAM[Address and $1FFF] := Value;
          FDirty := True;
        end;
      end;
    TSMSMapper.Zemina, TSMSMapper.Nemesis:
      case Address of
        0:
          FBanks[4] := Value;
        1:
          FBanks[5] := Value;
        2:
          FBanks[2] := Value;
        3:
          FBanks[3] := Value;
      end;
    TSMSMapper.Janggun:
      case Address of
        $FFFD, $FFFE, $FFFF:
          begin
            var Slot := (Address - $FFFD) * 2;
            var Bank := (Integer(Value) mod (Length(FData) div $4000)) * 2;
            // Bank latches are bytes even when a manually selected mapper is
            // applied to a larger ROM. Narrow explicitly with Q+/R+ enabled.
            FBanks[Slot] := Bank and $FF;
            FBanks[Slot + 1] := (Bank + 1) and $FF;
          end;
        $4000:
          FBanks[2] := Value;
        $6000:
          FBanks[3] := Value;
        $8000:
          FBanks[4] := Value;
        $A000:
          FBanks[5] := Value;
      end;
    TSMSMapper.HiCom:
      if Address = $FFFF then
        FGame := Value;
    TSMSMapper.FourPak:
      case Address of
        $3FFE:
          FRegisters[0] := Value;
        $7FFF:
          FRegisters[1] := Value;
        $BFFF:
          FRegisters[2] := Value;
      end;
    TSMSMapper.Korean188:
      if Address and $6000 = $2000 then
        FGame := Value;
    TSMSMapper.Seojin:
      begin
        if Address >= $C000 then
        begin
          FRAM[Address and $3FFF] := Value;
          FDirty := True;
        end;
        if Address = $FFF0 then
          FGame := Value;
        if Address >= $FFFD then
          FBanks[Address - $FFFD] := Value;
      end;
  end;
end;

function TSMSCartridge.SaveRAM: TBytes;
begin
  var Size := SizeOf(FRAM);
  if FMapper = TSMSMapper.EEPROM93C46 then
    Size := 128;
  SetLength(Result, Size);
  for var i := 0 to High(Result) do
    Result[i] := FRAM[i];
end;

procedure TSMSCartridge.LoadRAM(const Data: TBytes);
begin
  var Size := SizeOf(FRAM);
  if FMapper = TSMSMapper.EEPROM93C46 then
    Size := 128;
  if Length(Data) <> Size then
    raise EReadError.CreateFmt('Sega cartridge save must contain %d bytes', [Size]);

  for var i := 0 to High(Data) do
    FRAM[i] := Data[i];
  FDirty := False;
end;

procedure TSMSCartridge.SerializeState(State: TStateArchive);
begin
  if FMapper = TSMSMapper.EEPROM93C46 then
  begin
    State.Field(FEEPROMWriteEnabled, SizeOf(FEEPROMWriteEnabled));
    State.Field(FEEPROMOutput, SizeOf(FEEPROMOutput));
    State.Field(FEEPROMLines, SizeOf(FEEPROMLines));
    State.Field(FEEPROMMode, SizeOf(FEEPROMMode));
    State.Field(FEEPROMBits, SizeOf(FEEPROMBits));
    State.Field(FEEPROMCommand, SizeOf(FEEPROMCommand));
    State.Field(FEEPROMValue, SizeOf(FEEPROMValue));
    State.Field(FEEPROMAddress, SizeOf(FEEPROMAddress));
    if State.Loading and ((FEEPROMMode < 0) or (FEEPROMMode > 5) or
      (FEEPROMBits < 0) or (FEEPROMBits > 16) or (FEEPROMAddress < 0) or
      (FEEPROMAddress > 63) or (FEEPROMCommand < 0) or (FEEPROMCommand > 255) or
      (FEEPROMValue < 0) or (FEEPROMValue > 65535)) then
      raise EReadError.Create('Invalid 93C46 snapshot');
  end;

  State.Field(FRAM, SizeOf(FRAM));
  State.Field(FBanks, SizeOf(FBanks));
  State.Field(FRegisters, SizeOf(FRegisters));
  State.Field(FControl, SizeOf(FControl));
  State.Field(FGame, SizeOf(FGame));
  State.Field(FDirty, SizeOf(FDirty));
end;

function TSMSCartridge.ReadAchievementRAM(Address: Cardinal; Buffer: PByte; Count: Cardinal): Cardinal;
begin
  Result := ReadAchievementMemoryBlock(Address, Buffer, Count, @FRAM, SizeOf(FRAM));
end;

end.

