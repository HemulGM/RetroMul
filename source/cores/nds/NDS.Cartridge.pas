unit NDS.Cartridge;

interface

uses
  System.SysUtils, System.Classes, System.Math, Core.Snapshots;

const
  NDS_ROM_MAX_SIZE = 512 * 1024 * 1024;

type
  TNDSExecutable = record
    Offset, Entry, Address, Size: Cardinal;
  end;

  TNDSHeader = record
    Title, GameCode: string;
    ARM9, ARM7: TNDSExecutable;
  end;

  TNDSCartridge = class
  private
    FData: TBytes;
    FHeader: TNDSHeader;
    FSave: TBytes;
    FCommand, FStatus: Byte;
    FPosition, FAddress, FAddressBytes: Integer;
    FWriting, FDirty: Boolean;
  public
    constructor Create(const Data: TBytes; SaveSize: Integer = 0);
    function ReadROM(Address: Cardinal): Byte;
    procedure ResetSPI;
    procedure SerializeState(State: TStateArchive);
    procedure MarkBatteryDirty;
    function Transfer(Value: Byte): Byte;
    procedure LoadBattery(const Data: TBytes);
    function BatteryData: TBytes;
    property Header: TNDSHeader read FHeader;
    property Data: TBytes read FData;
    property Dirty: Boolean read FDirty;
  end;

function NDSDefaultSaveSize(GameCode: Cardinal): Integer;

function IsNDSROM(const Data: TBytes): Boolean;

function NDSRead32(const Data: TBytes; Offset: Integer): Cardinal;

implementation

function NDSDefaultSaveSize(GameCode: Cardinal): Integer;
begin
  // Cartridge capacities are hardware metadata, not encoded in ROM headers.
  // Facts checked against melonDS ROMList and SkyEmu nds_rom_database.
  // Unlisted cartridges retain the user-selectable 64 KiB fallback.
  case GameCode of
    $45425159, $45444441, $45454C59, $454A4E43, // YQBE ADDE YLEE CNJE
    $45534E41, $45544359, $45584E41, $45594543, // ANSE YCTE ANXE CEYE
    $50425159, $50474542, $50584F41: // YQBP BEGP AOXP
      Result := 512;
    $45364D43, $45395259, $45435341, $45443241, // CM6E YR9E ASCE A2DE
    $45444356, $45463541, $45484241, $45495643, // VCDE A5FE ABHE CVIE
    $454A4C43, $454B5441, $454B5959, $454D5241, // CLJE ATKE YYKE ARME
    $454D5341, $454E4843, $454F4F42, $454F4F43, // ASME CHNE BOOE COOE
    $45503743, $45514441, $45525441, $45544742, // C7PE ADQE ATRE BGTE
    $45544C59, $45544D41, $45564341, $45564459, // YLTE AMTE ACVE YDVE
    $45574B41, $45575A41, $45584359, $45584759, // AKWE AZWE YCXE YGXE
    $455A4C59, $4A445941: // YLZE AYDJ
      Result := 8192;
    $45324842, $45334759, $45344659, $45355659, // BH2E YG3E YF4E YV5E
    $45424341, $45463641, $45464641, $45464C42, // ACBE A6FE AFFE BLFE
    $45465241, $45465242, $45473241, $45474B59, // ARFE BRFE A2GE YKGE
    $45474E59, $45474F59, $45495659, $454A3343, // YNGE YOGE YVIE C3JE
    $454A5242, $454B4A43, $454B5342, $454C5342, // BRJE CJKE BSKE BSLE
    $454C5741, $454E3641, $45505341, $45514459, // AWLE A6NE ASPE YDQE
    $45524A43, $45544D42, $45555159, $45564454, // CJRE BMTE YQUE TDVE
    $45564959, $45574B59, $45593341: // YIVE YKWE A3YE
      Result := 65536;
    $45533243: // C2SE
      Result := 131072;
    $45325759, $45354F42, $45365941, $45394841, // YW2E BO5E AY6E AH9E
    $45434D41, $45444154, $45454659, $45484D41, // AMCE TADE YFEE AMHE
    $45485041, $45495741, $454D4441, $454E3841, // APHE AWIE ADME A8NE
    $45505841, $45514D41, $45524A41, $45525741, // AXPE AMQE AJRE AWRE
    $45534F41, $45544659, $45594659, $45594741, // AOSE YFTE YFYE AGYE
    $4A505841, $4B505841, $50505841, $50554C59: // AXPJ AXPK AXPP YLUP
      Result := 262144;
    $45414441, $45415041, $45455A41, $45473256, // ADAE APAE AZEE V2GE
    $45475049, $454B5049, $45555043, $4F415249, // IPGE IPKE CPUE IRAO
    $4F425249, $4F445249, $4F455249: // IRBO IRDO IREO
      Result := 524288;
    $45494B42: // BKIE
      Result := 1048576;
  else
    Result := 65536;
  end;
end;

function NDSRead32(const Data: TBytes; Offset: Integer): Cardinal;
begin
  if (Offset < 0) or (Offset > Length(Data) - 4) then
    raise EReadError.Create('Truncated NDS header');
  Result := Cardinal(Data[Offset]) or (Cardinal(Data[Offset + 1]) shl 8) or
    (Cardinal(Data[Offset + 2]) shl 16) or (Cardinal(Data[Offset + 3]) shl 24);
end;

function Executable(const Data: TBytes; Offset: Integer): TNDSExecutable;
begin
  Result.Offset := NDSRead32(Data, Offset);
  Result.Entry := NDSRead32(Data, Offset + 4);
  Result.Address := NDSRead32(Data, Offset + 8);
  Result.Size := NDSRead32(Data, Offset + 12);
end;

function ValidExecutable(const E: TNDSExecutable; ARM7: Boolean; Length: Integer): Boolean;
begin
  Result := (E.Offset >= $200) and (E.Size > 0) and
    (UInt64(E.Offset) + E.Size <= UInt64(Length)) and
    (E.Offset and 3 = 0) and (E.Address and 3 = 0);
  if not Result then
    Exit;
  var Last := UInt64(E.Address) + E.Size;
  Result := ((E.Address >= $02000000) and (Last <= $02400000)) or
    (ARM7 and (E.Address >= $037F8000) and (Last <= $03810000)) or
    (not ARM7 and (E.Address >= $01000000) and (Last <= $01008000));
end;

function IsNDSROM(const Data: TBytes): Boolean;
begin
  Result := (Length(Data) >= $200) and (Length(Data) <= NDS_ROM_MAX_SIZE);
  if not Result then
    Exit;
  Result := (Data[$12] in [0, 2]) and
    ValidExecutable(Executable(Data, $20), False, Length(Data)) and
    ValidExecutable(Executable(Data, $30), True, Length(Data));
end;

constructor TNDSCartridge.Create(const Data: TBytes; SaveSize: Integer);

  function TextAt(Offset, Count: Integer): string;
  begin
    Result := '';
    for var i := Offset to Offset + Count - 1 do
    begin
      if Data[i] = 0 then
        Break;
      Result := Result + Char(Data[i]);
    end;
    Result := Result.Trim;
  end;

begin
  inherited Create;
  if not IsNDSROM(Data) then
    raise EReadError.Create('Invalid or truncated Nintendo DS cartridge');
  if SaveSize = 0 then
    SaveSize := NDSDefaultSaveSize(NDSRead32(Data, 12));
  case SaveSize of
    512, 8192, 65536, 131072, 262144, 524288, 1048576, 8388608:
      ;
  else
    raise EArgumentException.Create('Unsupported NDS backup size');
  end;
  FData := Copy(Data);
  FHeader.Title := TextAt(0, 12);
  FHeader.GameCode := TextAt(12, 4);
  FHeader.ARM9 := Executable(Data, $20);
  FHeader.ARM7 := Executable(Data, $30);
  SetLength(FSave, SaveSize);
  FillChar(FSave[0], SaveSize, $FF);
  FAddressBytes := 2;
  if SaveSize = 512 then
    FAddressBytes := 1;
  if SaveSize > 65536 then
    FAddressBytes := 3;
end;

function TNDSCartridge.ReadROM(Address: Cardinal): Byte;
begin
  if Address < Cardinal(Length(FData)) then
    Result := FData[Address]
  else
    Result := $FF;
end;

procedure TNDSCartridge.ResetSPI;
begin
  if FWriting then
    FStatus := FStatus and not Byte(2);
  FWriting := False;
  FPosition := 0;
  FAddress := 0;
  FCommand := 0;
end;

function TNDSCartridge.Transfer(Value: Byte): Byte;
begin
  Result := $FF;
  // IR cartridges multiplex savedata behind a 00h prefix on the same SPI bus.
  // Reuse command/position for the pending prefix so mid-transfer snapshots
  // retain it. FE/FF denote the IR version query/idle receiver, not flash ops.
  if (Length(FHeader.GameCode) = 4) and (FHeader.GameCode[1] = 'I') then
  begin
    if FPosition = 0 then
    begin
      FCommand := $FF;
      if Value = 0 then
        FCommand := 0
      else if Value = 8 then
        FCommand := $FE;
      FPosition := 1;
      Exit;
    end;
    if FCommand = $FE then
    begin
      Inc(FPosition);
      Exit($AA);
    end;
    if FCommand = $FF then
    begin
      Inc(FPosition);
      Exit(0);
    end;
    if FCommand = 0 then
      FPosition := 0;
  end;
  if FPosition = 0 then
  begin
    FCommand := Value;
    if Value = 6 then
      FStatus := FStatus or 2;
    if Value = 4 then
      FStatus := FStatus and not Byte(2);
    if (Value = $C7) and (FStatus and 2 <> 0) then
    begin
      FillChar(FSave[0], Length(FSave), $FF);
      FDirty := True;
      FWriting := True;
    end;
    if (Length(FSave) = 512) and (Value and 8 <> 0) then
      FAddress := 256;
  end
  else if FCommand = 5 then
  begin
    Result := FStatus;
    if Length(FSave) = 512 then
      Result := Result or $F0;
  end
  else if FCommand = $9F then
  begin
    // EEPROM has no JEDEC identifier; reporting a flash ID changes the SDK's
    // detected bus protocol (notably for Super Mario 64 DS and Mario Bros.).
    if Length(FSave) >= 262144 then
    begin
      case FPosition of
        1:
          Result := $20;
        2:
          Result := $40;
      else
        var Capacity := Length(FSave);
        Result := 0;
        while Capacity > 1 do
        begin
          Inc(Result);
          Capacity := Capacity shr 1;
        end;
      end;
    end;
  end
  else if FCommand = 1 then
  begin
    if FStatus and 2 <> 0 then
    begin
      var Mask: Byte := $8C;
      if Length(FSave) = 512 then
        Mask := $0C;
      FStatus := (FStatus and 3) or (Value and Mask);
      FWriting := True;
    end;
  end
  else if (FCommand in [2, 3, $0A, $D8, $DB, $20]) or
    ((Length(FSave) = 512) and (FCommand in [$0A, $0B])) then
  begin
    if FPosition <= FAddressBytes then
    begin
      if Length(FSave) = 512 then
        FAddress := (FAddress and 256) or Value
      else
        FAddress := ((FAddress shl 8) or Value) and (Length(FSave) - 1);
      if (FPosition = FAddressBytes) and (FCommand in [$D8, $DB, $20]) and (FStatus and 2 <> 0) then
      begin
        var Count := 256;
        if FCommand = $D8 then
          Count := 65536
        else if FCommand = $20 then
          Count := 4096;
        Count := Min(Count, Length(FSave));
        FillChar(FSave[FAddress and not (Count - 1)], Count, $FF);
        FDirty := True;
        FWriting := True;
      end;
    end
    else
    begin
      if FCommand in [3, $0B] then
        Result := FSave[FAddress]
      else if (FCommand in [2, $0A]) and (FStatus and 2 <> 0) then
      begin
        if (Length(FSave) >= 262144) and (FCommand = 2) then
          FSave[FAddress] := FSave[FAddress] and Value
        else
          FSave[FAddress] := Value;
        FDirty := True;
        FWriting := True;
      end;
      FAddress := (FAddress + 1) and (Length(FSave) - 1);
    end;
  end;
  Inc(FPosition);
end;

procedure TNDSCartridge.LoadBattery(const Data: TBytes);
begin
  if (Length(Data) <> 512) and (Length(Data) <> 8192) and (Length(Data) <> 65536) and
    (Length(Data) <> 131072) and (Length(Data) <> 262144) and (Length(Data) <> 524288) and
    (Length(Data) <> 1048576) and (Length(Data) <> 8388608) then
    raise EReadError.Create('Invalid NDS backup size');
  FSave := Copy(Data);
  FAddressBytes := 2;
  if Length(FSave) = 512 then
    FAddressBytes := 1;
  if Length(FSave) > 65536 then
    FAddressBytes := 3;
  FDirty := False;
  ResetSPI;
end;

function TNDSCartridge.BatteryData: TBytes;
begin
  Result := Copy(FSave);
end;

procedure TNDSCartridge.MarkBatteryDirty;
begin
  FDirty := True;
end;

procedure TNDSCartridge.SerializeState(State: TStateArchive);
begin
  var Count: Integer := Length(FSave);
  State.Field(Count, SizeOf(Count));
  case Count of
    512, 8192, 65536, 131072, 262144, 524288, 1048576, 8388608:
      ;
  else
    raise EReadError.Create('Invalid NDS snapshot backup size');
  end;
  if State.Loading then
    SetLength(FSave, Count);
  State.Field(FSave[0], Count);
  State.Field(FCommand, SizeOf(FCommand));
  State.Field(FStatus, SizeOf(FStatus));
  State.Field(FPosition, SizeOf(FPosition));
  State.Field(FAddress, SizeOf(FAddress));
  State.Field(FAddressBytes, SizeOf(FAddressBytes));
  State.Field(FWriting, SizeOf(FWriting));
  State.Field(FDirty, SizeOf(FDirty));
  if State.Loading then
  begin
    var Expected := 2;
    if Count = 512 then
      Expected := 1
    else if Count > 65536 then
      Expected := 3;
    if (FAddressBytes <> Expected) or (FPosition < 0) or (FPosition > $1000000) or
      (FAddress < 0) or (FAddress >= Count) then
      raise EReadError.Create('Invalid NDS snapshot SPI state');
  end;
end;

end.

