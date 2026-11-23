unit GB.MBC;

interface

uses
  Core.Snapshots, System.Classes, System.SysUtils, GB.ROM, GB.Cartridge,
  GB.Camera;

{$SCOPEDENUMS ON}

type
  TMapperType = GB.Cartridge.TMapperType;

type
  TGBMBC = class
  private
    FROM: TGBROM;
    // Immutable cartridge identity; do not copy the managed metadata per bus read.
    FMapperType: TMapperType;
    FRAMEnabled: Boolean;
    FHasRAM: Boolean;
    FIsROMMode: Boolean;
    FRAM: array of Integer;
    FBankLow, FBankHigh, FROMBankCount: Integer;
    FFixedROMBank: Integer;
    FMapLocked, FIRMode, FIROutput: Boolean;
    FMMMRegisters: array[0..3] of Byte;
    FMBC6ROMBanks, FMBC6RAMBanks: array[0..1] of Byte;
    FMBC6FlashBanks: array[0..1] of Boolean;
    FFlashEnabled, FFlashWriteEnabled, FFlashSector0Protected: Boolean;
    FFlash: TBytes;
    FFlashHidden: array[0..255] of Byte;
    FFlashBuffer: array[0..127] of Byte;
    FFlashMode, FFlashSequence, FFlashCommand, FFlashProgramming: Byte;
    FFlashProgramBase, FFlashProgramCount, FFlashLastAddress: Integer;
    FHasRumble: Boolean;
    FRumbleClocks, FRumbleOnClocks: UInt64;
    FHasTimer, FRTCLatched: Boolean;
    FRTC, FRTCSnapshot: array[0..4] of Byte;
    FRTCLatchWrite: Byte;
    FRTCLastTime: Int64;
    FRTCClock: TFunc<Int64>;
    // Peripheral cartridge state. EEPROM words use MSB-first serial transfers.
    FPeripheralMode, FPeripheralBank: Byte;
    FTiltX, FTiltY, FLatchedX, FLatchedY: Word;
    FTiltReset, FEEPROMWriteEnabled: Boolean;
    FEEPROMPins, FEEPROMMode, FEEPROMAddress: Byte;
    FEEPROMBits, FEEPROMShift, FEEPROMData, FEEPROMReadBit: Integer;
    FHuCMemory: array[0..255] of Byte;
    FHuCCommand, FHuCResponse, FHuCAddress: Byte;
    FHuCSeconds: Int64;
    FCameraRegisters, FCameraCaptureRegisters: array[0..$35] of Byte;
    FCameraClocks: Integer;
    FCamera: TGBCameraController;
    function GetRumbleOn: Boolean;
    function ExtendedROMBank(Address: Integer): Integer;
    function ReadExtended(Address: Integer): Integer;
    procedure WriteExtended(Address, Value: Integer);
    function ReadFlash(Address: Integer): Byte;
    procedure WriteFlash(Address: Integer; Value: Byte);
    procedure ResetFlashCommand;
    procedure WriteEEPROM(Value: Byte);
    function ReadEEPROM: Byte;
    procedure ExecuteHuCCommand;
    procedure CompleteCameraCapture;
    function ReadPeripheral(Address: Integer): Integer;
    procedure WritePeripheral(Address, Value: Integer);
    function RTCNow: Int64;
    procedure UpdateRTC;
    procedure UpdateBanks;
  public
    ROMBankSelected: Integer;
    RAMBankSelected: Integer;
    function MbcRead(Address: Integer): Integer;
    procedure MbcWrite(Address, Value: Integer);
    function IsCGBCartridge: Boolean;
    constructor Create(AROM: TGBROM; const RTCClock: TFunc<Int64> = nil; const CameraSource: IGBCameraFrameSource = nil); overload;
    destructor Destroy; override;
    property Camera: TGBCameraController read FCamera;
    function SaveMemory: TBytes;
    procedure LoadSaveMemory(const Data: TBytes);
    function RTCData: TBytes;
    procedure LoadRTCData(const Data: TBytes);
    function HasBattery: Boolean;
    property HasTimer: Boolean read FHasTimer;
    property HasRumble: Boolean read FHasRumble;
    property RumbleOn: Boolean read GetRumbleOn;
    function TakeRumbleLevel: Byte;
    procedure SerializeState(State: TStateArchive);
    procedure Step(Clocks: Integer);
    // Raw ADXL202 sensor values; callers can supply tilt without changing ROMs.
    procedure SetAccelerometer(X, Y: Word);
    // Screen-space acceleration in g: positive X points right, positive Y up.
    procedure SetAcceleration(X, Y: Double);
  end;

implementation

uses
  System.DateUtils, System.Math;

{ TGBMBC }

constructor TGBMBC.Create(AROM: TGBROM; const RTCClock: TFunc<Int64>; const CameraSource: IGBCameraFrameSource);
begin
  inherited Create;
  if AROM = nil then
    raise EArgumentNilException.Create('ROM must not be nil');

  FMapperType := AROM.GetCartridgeType.MapperType;
  if not (FMapperType in
    [TMapperType.ROMOnly, TMapperType.MBC1, TMapperType.MBC2,
      TMapperType.MBC3, TMapperType.MBC5, TMapperType.MBC7,
      TMapperType.PocketCamera, TMapperType.HuC3, TMapperType.HuC1,
      TMapperType.MBC1M, TMapperType.MBC30, TMapperType.MMM01,
      TMapperType.M161, TMapperType.WisdomTree, TMapperType.MBC6]) then
    raise ENotSupportedException.Create('Unsupported cartridge: ' + AROM.GetCartridgeType.Name);

  FROM := AROM;
  FHasRumble := (FMapperType = TMapperType.MBC5) and
    FROM.GetCartridgeType.HasRumble;
  if FMapperType = TMapperType.PocketCamera then
    FCamera := TGBCameraController.Create(CameraSource);
  FRTCClock := RTCClock;
  FHasTimer := FROM.GetCartridgeType.HasTimer;
  FRTCLastTime := RTCNow;
  FROMBankCount := Length(FROM.ROMData) div $4000;
  if FROMBankCount = 0 then
    FROMBankCount := 1;
  FBankLow := 1;
  FBankHigh := 0;
  if FMapperType in [TMapperType.M161, TMapperType.WisdomTree] then
    FBankLow := 0;
  FRAMEnabled := False;
  FIsROMMode := True;
  FHasRAM := FROM.GetCartridgeType.HasRAM;
  FTiltX := $81D0;
  FTiltY := $81D0;
  FLatchedX := $8000;
  FLatchedY := $8000;
  FEEPROMReadBit := -1;
  if FMapperType = TMapperType.MBC6 then
  begin
    SetLength(FFlash, $100000);
    FillChar(FFlash[0], Length(FFlash), $FF);
    FillChar(FFlashHidden, SizeOf(FFlashHidden), $FF);
    ResetFlashCommand;
  end;
  if FMapperType = TMapperType.MBC7 then
  begin
    SetLength(FRAM, 256);
    for var i := 0 to High(FRAM) do
      FRAM[i] := $FF;
  end
  else if FMapperType = TMapperType.MBC2 then
    SetLength(FRAM, $200) // 512 four-bit internal RAM cells
  else if FMapperType = TMapperType.MBC6 then
    SetLength(FRAM, $8000)
  else if FHasRAM and Assigned(FROM.Cartridge) then
    // The header also permits 64 KiB (8-bank) and 128 KiB (16-bank) RAM.
    // Do not silently turn these cartridges into RAM-less ones.
    if FROM.Cartridge.RAMSizeBytes > 0 then
      SetLength(FRAM, FROM.Cartridge.RAMSizeBytes);
  FHasRAM := Length(FRAM) > 0;
  UpdateBanks;
end;

destructor TGBMBC.Destroy;
begin
  FCamera.Free;
  inherited;
end;

procedure TGBMBC.UpdateBanks;
begin
  if FMapperType = TMapperType.MBC6 then
  begin
    // The public bank number describes the first 8 KiB switchable window.
    ROMBankSelected := FMBC6ROMBanks[0];
    RAMBankSelected := FMBC6RAMBanks[0];
    Exit;
  end;

  if FMapperType in [TMapperType.M161, TMapperType.WisdomTree, TMapperType.HuC1, TMapperType.MMM01] then
  begin
    FFixedROMBank := ExtendedROMBank(0);
    ROMBankSelected := ExtendedROMBank($4000);
    RAMBankSelected := FBankHigh;
    if FMapperType = TMapperType.MMM01 then
    begin
      RAMBankSelected := FMMMRegisters[2] and 3;
      if (FMMMRegisters[3] and $40) <> 0 then
        RAMBankSelected := (FMMMRegisters[1] shr 5) and 3
      else if (FMMMRegisters[3] and 1) = 0 then
        RAMBankSelected := RAMBankSelected and ((FMMMRegisters[0] shr 4) and 3);
      RAMBankSelected := RAMBankSelected or (((FMMMRegisters[2] shr 2) and 3) shl 2);
    end;
    Exit;
  end;

  if FMapperType in [TMapperType.MBC7, TMapperType.PocketCamera, TMapperType.HuC3] then
  begin
    ROMBankSelected := FBankLow mod FROMBankCount;
    RAMBankSelected := FPeripheralBank and $0F;
  end
  else if FMapperType in [TMapperType.MBC3, TMapperType.MBC30] then
  begin
    ROMBankSelected := FBankLow mod FROMBankCount;
    RAMBankSelected := FBankHigh and $0F;
  end
  else if FMapperType = TMapperType.MBC5 then
  begin
    // MBC5 uses a nine-bit ROM bank number and does not remap bank zero.
    ROMBankSelected := FBankLow mod FROMBankCount;
    RAMBankSelected := FBankHigh and $0F;
    if FROM.GetCartridgeType.HasRumble then
      RAMBankSelected := RAMBankSelected and 7;
  end
  else
  begin
    var Shift := 5;
    var Mask := $1F;
    if FMapperType = TMapperType.MBC1M then
    begin
      Shift := 4;
      Mask := $0F;
    end;
    ROMBankSelected := ((FBankHigh shl Shift) or (FBankLow and Mask)) mod FROMBankCount;
    FFixedROMBank := 0;
    if not FIsROMMode then
      FFixedROMBank := (FBankHigh shl Shift) mod FROMBankCount;
    if FIsROMMode or (Shift = 4) then
      RAMBankSelected := 0
    else
      RAMBankSelected := FBankHigh;
  end;
end;

function TGBMBC.RTCNow: Int64;
begin
  if Assigned(FRTCClock) then
    Result := FRTCClock()
  else
    Result := DateTimeToUnix(Now, False);
end;

procedure TGBMBC.UpdateRTC;
begin
  if not FHasTimer then
    Exit;

  var Current := RTCNow;
  var Elapsed := Current - FRTCLastTime;
  FRTCLastTime := Current;
  if (Elapsed <= 0) or ((FRTC[4] and $40) <> 0) then
    Exit;

  if FMapperType = TMapperType.HuC3 then
  begin
    FHuCSeconds := (FHuCSeconds + Elapsed) mod (Int64(4096) * 86400);
    for var i := 0 to 2 do
    begin
      FHuCMemory[$10 + i] := ((FHuCSeconds div 60 mod 1440) shr (i * 4)) and $0F;
      FHuCMemory[$13 + i] := ((FHuCSeconds div 86400) shr (i * 4)) and $0F;
    end;
    Exit;
  end;

  var Days := Integer(FRTC[3]) or ((Integer(FRTC[4]) and 1) shl 8);
  var Total := Int64(Days) * 86400 + Integer(FRTC[2]) * 3600 +
    Integer(FRTC[1]) * 60 + FRTC[0] + Elapsed;
  FRTC[0] := Total mod 60;
  FRTC[1] := (Total div 60) mod 60;
  FRTC[2] := (Total div 3600) mod 24;
  var TotalDays := Total div 86400;
  if TotalDays >= 512 then
    FRTC[4] := FRTC[4] or $80;
  FRTC[3] := TotalDays and $FF;
  FRTC[4] := (FRTC[4] and $C0) or ((TotalDays shr 8) and 1);
end;

function TGBMBC.HasBattery: Boolean;
begin
  Result := FROM.GetCartridgeType.HasBattery;
end;

function TGBMBC.SaveMemory: TBytes;
begin
  if FMapperType = TMapperType.MBC6 then
  begin
    SetLength(Result, 4 + Length(FRAM) + Length(FFlash) + SizeOf(FFlashHidden) + 1);
    Result[0] := Ord('M');
    Result[1] := Ord('B');
    Result[2] := Ord('6');
    Result[3] := 1;
    for var i := 0 to High(FRAM) do
      Result[4 + i] := FRAM[i];
    Move(FFlash[0], Result[4 + Length(FRAM)], Length(FFlash));
    Move(FFlashHidden, Result[4 + Length(FRAM) + Length(FFlash)], SizeOf(FFlashHidden));
    Result[High(Result)] := Ord(FFlashSector0Protected);
    Exit;
  end;

  SetLength(Result, Length(FRAM));
  for var i := 0 to High(FRAM) do
    Result[i] := FRAM[i];
end;

procedure TGBMBC.LoadSaveMemory(const Data: TBytes);
begin
  if FMapperType = TMapperType.MBC6 then
  begin
    if (Length(Data) <> 4 + Length(FRAM) + Length(FFlash) + SizeOf(FFlashHidden) + 1) or
      (Data[0] <> Ord('M')) or (Data[1] <> Ord('B')) or (Data[2] <> Ord('6')) or
      (Data[3] <> 1) or (Data[High(Data)] > 1) then
      raise EReadError.Create('Invalid MBC6 battery save');

    for var i := 0 to High(FRAM) do
      FRAM[i] := Data[4 + i];
    Move(Data[4 + Length(FRAM)], FFlash[0], Length(FFlash));
    Move(Data[4 + Length(FRAM) + Length(FFlash)], FFlashHidden, SizeOf(FFlashHidden));
    FFlashSector0Protected := Data[High(Data)] <> 0;
    Exit;
  end;

  if Length(Data) <> Length(FRAM) then
    raise EReadError.Create('Invalid Game Boy battery RAM size');

  for var i := 0 to High(FRAM) do
    if FMapperType = TMapperType.MBC2 then
      FRAM[i] := Data[i] and $0F
    else
      FRAM[i] := Data[i];
end;

function TGBMBC.RTCData: TBytes;
begin
  Result := nil;
  if not FHasTimer then
    Exit;

  UpdateRTC;
  if FMapperType = TMapperType.HuC3 then
  begin
    SetLength(Result, 276);
    Result[0] := Ord('H');
    Result[1] := Ord('U');
    Result[2] := Ord('C');
    Result[3] := 1;
    Move(FHuCSeconds, Result[4], 8);
    Move(FRTCLastTime, Result[12], 8);
    Move(FHuCMemory, Result[20], 256);
    Exit;
  end;

  SetLength(Result, 17);
  Result[0] := Ord('G');
  Result[1] := Ord('B');
  Result[2] := Ord('R');
  Result[3] := 1;
  Move(FRTC[0], Result[4], 5);
  Move(FRTCLastTime, Result[9], SizeOf(FRTCLastTime));
end;

procedure TGBMBC.LoadRTCData(const Data: TBytes);
begin
  if FMapperType = TMapperType.HuC3 then
  begin
    if (Length(Data) <> 276) then
      raise EReadError.Create('Invalid HuC3 RTC save size');

    if (Data[0] <> Ord('H')) or (Data[1] <> Ord('U')) or (Data[2] <> Ord('C')) or (Data[3] <> 1) then
      raise EReadError.Create('Invalid HuC3 RTC save');

    var Seconds, Stamp: Int64;
    Move(Data[4], Seconds, 8);
    Move(Data[12], Stamp, 8);
    if (Seconds < 0) or (Seconds >= Int64(4096) * 86400) or (Stamp < 0) or (Stamp > 253402300799) then
      raise EReadError.Create('Invalid HuC3 RTC time');

    for var i := 20 to High(Data) do
      if Data[i] > 15 then
        raise EReadError.Create('Invalid HuC3 RTC nybble');

    FHuCSeconds := Seconds;
    FRTCLastTime := Stamp;
    Move(Data[20], FHuCMemory, 256);
    UpdateRTC;
    Exit;
  end;

  if not FHasTimer or (Length(Data) <> 17) then
    raise EReadError.Create('Invalid Game Boy RTC save size');

  if (Data[0] <> Ord('G')) or (Data[1] <> Ord('B')) or
    (Data[2] <> Ord('R')) or (Data[3] <> 1) or
    (Data[4] > 63) or (Data[5] > 63) or (Data[6] > 31) or
    ((Data[8] and $3E) <> 0) then
    raise EReadError.Create('Invalid Game Boy RTC save');

  var SavedTime: Int64;
  Move(Data[9], SavedTime, SizeOf(SavedTime));
  if (SavedTime < 0) or (SavedTime > 253402300799) then
    raise EReadError.Create('Invalid Game Boy RTC timestamp');

  Move(Data[4], FRTC[0], 5);
  FRTCLastTime := SavedTime;
  UpdateRTC;
end;

function TGBMBC.IsCGBCartridge: Boolean;
begin
  Result := Assigned(FROM) and Assigned(FROM.Cartridge) and
    FROM.Cartridge.SupportsCGB;
end;

function TGBMBC.MbcRead(Address: Integer): Integer;
begin
  Result := $FF;
  if (Address < 0) or (Address > $BFFF) then
    Exit;

  if FMapperType in [TMapperType.MMM01, TMapperType.M161,
      TMapperType.WisdomTree, TMapperType.HuC1, TMapperType.MBC6] then
    Exit(ReadExtended(Address));

  if FMapperType in [TMapperType.MBC7, TMapperType.PocketCamera, TMapperType.HuC3] then
    Exit(ReadPeripheral(Address));

  if (FMapperType in [TMapperType.MBC3, TMapperType.MBC30]) and
    (Address >= $A000) and FRAMEnabled and FHasTimer and
    (RAMBankSelected >= 8) and (RAMBankSelected <= 12) then
  begin
    UpdateRTC;
    if FRTCLatched then
      Result := FRTCSnapshot[RAMBankSelected - 8]
    else
      Result := FRTC[RAMBankSelected - 8];
    Exit;
  end;

  case FMapperType of
    TMapperType.ROMOnly:
      if Address < $8000 then
      begin
        if Address < Length(FROM.ROMData) then
          Result := FROM.ROMData[Address];
      end
      else if (Address >= $A000) and FHasRAM then
        Result := FRAM[(Address - $A000) mod Length(FRAM)];
    TMapperType.MBC1, TMapperType.MBC1M:
      if Address < $8000 then
      begin
        var Bank: Integer;
        if Address < $4000 then
        begin
          Bank := FFixedROMBank;
        end
        else
          Bank := ROMBankSelected;
        var EffectiveAddress: Integer := Bank * $4000 + (Address and $3FFF);
        if EffectiveAddress < Length(FROM.ROMData) then
          Result := FROM.ROMData[EffectiveAddress];
      end
      else if (Address >= $A000) and FRAMEnabled and FHasRAM then
      begin
        var EffectiveAddress: Integer := (RAMBankSelected * $2000 + Address - $A000) mod Length(FRAM);
        Result := FRAM[EffectiveAddress];
      end;
    TMapperType.MBC2:
      if Address < $4000 then
        Result := FROM.ROMData[Address]
      else if Address < $8000 then
      begin
        var EffectiveAddress := ROMBankSelected * $4000 + (Address and $3FFF);
        if EffectiveAddress < Length(FROM.ROMData) then
          Result := FROM.ROMData[EffectiveAddress];
      end
      else if (Address >= $A000) and FRAMEnabled then
        Result := $F0 or FRAM[Address and $1FF];
    TMapperType.MBC3, TMapperType.MBC30:
      if Address < $4000 then
        Result := FROM.ROMData[Address]
      else if Address < $8000 then
      begin
        var EffectiveAddress := ROMBankSelected * $4000 + (Address and $3FFF);
        if EffectiveAddress < Length(FROM.ROMData) then
          Result := FROM.ROMData[EffectiveAddress];
      end
      else if (Address >= $A000) and FRAMEnabled and FHasRAM and
        ((RAMBankSelected <= 3) or ((FMapperType = TMapperType.MBC30) and (RAMBankSelected <= 7))) then
      begin
        var EffectiveAddress := (RAMBankSelected * $2000 + Address - $A000) mod Length(FRAM);
        Result := FRAM[EffectiveAddress];
      end;
    TMapperType.MBC5:
      if Address < $4000 then
        Result := FROM.ROMData[Address]
      else if Address < $8000 then
      begin
        var EffectiveAddress := ROMBankSelected * $4000 + (Address and $3FFF);
        if EffectiveAddress < Length(FROM.ROMData) then
          Result := FROM.ROMData[EffectiveAddress];
      end
      else if (Address >= $A000) and FRAMEnabled and FHasRAM then
      begin
        var EffectiveAddress := (RAMBankSelected * $2000 + Address - $A000) mod Length(FRAM);
        Result := FRAM[EffectiveAddress];
      end;
  end;
end;

procedure TGBMBC.MbcWrite(Address, Value: Integer);
begin
  if (Address < 0) or (Address > $BFFF) then
    Exit;

  if FMapperType in [TMapperType.MMM01, TMapperType.M161,
      TMapperType.WisdomTree, TMapperType.HuC1, TMapperType.MBC6] then
  begin
    WriteExtended(Address, Value and $FF);
    Exit;
  end;

  if FMapperType in [TMapperType.MBC7, TMapperType.PocketCamera, TMapperType.HuC3] then
  begin
    WritePeripheral(Address, Value and $FF);
    Exit;
  end;

  if FMapperType = TMapperType.ROMOnly then
  begin
    // Plain ROM+RAM cartridges expose their RAM permanently at A000-BFFF.
    if (Address >= $A000) and FHasRAM then
      FRAM[(Address - $A000) mod Length(FRAM)] := Value and $FF;
  end
  else if FMapperType in [TMapperType.MBC1, TMapperType.MBC1M] then
  begin
    if Address <= $1FFF then
      FRAMEnabled := (Value and $0F) = $0A
    else if Address <= $3FFF then
    begin
      FBankLow := Value and $1F;
      if FBankLow = 0 then
        FBankLow := 1;
      UpdateBanks;
    end
    else if Address <= $5FFF then
    begin
      FBankHigh := Value and 3;
      UpdateBanks;
    end
    else if Address <= $7FFF then
    begin
      FIsROMMode := (Value and 1) = 0;
      UpdateBanks;
    end
    else if (Address >= $A000) and FRAMEnabled and FHasRAM then
    begin
      var EffectiveAddress := (RAMBankSelected * $2000 + Address - $A000) mod Length(FRAM);
      FRAM[EffectiveAddress] := Value and $FF;
    end;
  end
  else if FMapperType in [TMapperType.MBC3, TMapperType.MBC30] then
  begin
    if Address <= $1FFF then
      FRAMEnabled := (Value and $0F) = $0A
    else if Address <= $3FFF then
    begin
      if FMapperType = TMapperType.MBC30 then
        FBankLow := Value and $FF
      else
        FBankLow := Value and $7F;
      if FBankLow = 0 then
        FBankLow := 1;
      UpdateBanks;
    end
    else if Address <= $5FFF then
    begin
      FBankHigh := Value and $0F;
      UpdateBanks;
    end
    else if Address <= $7FFF then
    begin
      if FHasTimer and (FRTCLatchWrite = 0) and (Value = 1) then
      begin
        UpdateRTC;
        FRTCSnapshot := FRTC;
        FRTCLatched := True;
      end;
      FRTCLatchWrite := Value and $FF;
    end
    else if (Address >= $A000) and FRAMEnabled and FHasTimer and
      (RAMBankSelected >= 8) and (RAMBankSelected <= 12) then
    begin
      UpdateRTC;
      case RAMBankSelected of
        8, 9:
          FRTC[RAMBankSelected - 8] := Value and $3F;
        10:
          FRTC[2] := Value and $1F;
        11:
          FRTC[3] := Value and $FF;
        12:
          FRTC[4] := Value and $C1;
      end;
    end
    else if (Address >= $A000) and FRAMEnabled and FHasRAM and
      ((RAMBankSelected <= 3) or ((FMapperType = TMapperType.MBC30) and (RAMBankSelected <= 7))) then
    begin
      var EffectiveAddress := (RAMBankSelected * $2000 + Address - $A000) mod Length(FRAM);
      FRAM[EffectiveAddress] := Value and $FF;
    end;
  end
  else if FMapperType = TMapperType.MBC5 then
  begin
    if Address <= $1FFF then
      FRAMEnabled := (Value and $0F) = $0A
    else if Address <= $2FFF then
    begin
      FBankLow := (FBankLow and $100) or Value;
      UpdateBanks;
    end
    else if Address <= $3FFF then
    begin
      FBankLow := (FBankLow and $FF) or ((Value and 1) shl 8);
      UpdateBanks;
    end
    else if Address <= $5FFF then
    begin
      FBankHigh := Value and $0F;
      UpdateBanks;
    end
    else if (Address >= $A000) and FRAMEnabled and FHasRAM then
    begin
      var EffectiveAddress := (RAMBankSelected * $2000 + Address - $A000) mod Length(FRAM);
      FRAM[EffectiveAddress] := Value and $FF;
    end;
  end
  else if FMapperType = TMapperType.MBC2 then
  begin
    if Address <= $3FFF then
    begin
      if (Address and $100) = 0 then
        FRAMEnabled := (Value and $0F) = $0A
      else
      begin
        FBankLow := Value and $0F;
        if FBankLow = 0 then
          FBankLow := 1;
        UpdateBanks;
      end;
    end
    else if (Address >= $A000) and FRAMEnabled then
      FRAM[Address and $1FF] := Value and $0F;
  end;
end;

function TGBMBC.ExtendedROMBank(Address: Integer): Integer;
begin
  Result := 0;
  case FMapperType of
    TMapperType.M161, TMapperType.WisdomTree:
      Result := FBankLow * 2 + Address div $4000;
    TMapperType.HuC1:
      if Address >= $4000 then
        Result := FBankLow;
    TMapperType.MMM01:
      begin
        if not FMapLocked then
          Result := FROMBankCount - 2 + Address div $4000
        else
        begin
          var Low := FMMMRegisters[1] and $1F;
          var Mask := (FMMMRegisters[3] shr 1) and $1E;
          var Mid := (FMMMRegisters[1] shr 5) and 3;
          var High := ((FMMMRegisters[2] shr 4) and 3) shl 7;
          if (FMMMRegisters[3] and $40) <> 0 then
          begin
            Mid := FMMMRegisters[2] and 3;
            if (Address < $4000) and ((FMMMRegisters[3] and 1) = 0) then
              Mid := Mid and ((FMMMRegisters[0] shr 4) and 3);
          end;
          if Address < $4000 then
            Low := Low and Mask
          else if (Low and ($1F xor Mask)) = 0 then
            Low := Low or 1;
          Result := High or (Mid shl 5) or Low;
        end;
      end;
  end;
  Result := Result mod FROMBankCount;
end;

function TGBMBC.ReadExtended(Address: Integer): Integer;
begin
  Result := $FF;
  var Kind := FMapperType;
  if Kind = TMapperType.MBC6 then
  begin
    if Address < $4000 then
      Exit(FROM.ROMData[Address]);

    if Address < $8000 then
    begin
      var Slot := (Address - $4000) div $2000;
      var Offset := FMBC6ROMBanks[Slot] * $2000 + (Address and $1FFF);
      if FMBC6FlashBanks[Slot] then
      begin
        if FFlashEnabled then
          Result := ReadFlash(Offset);
      end
      else
        Result := FROM.ROMData[Offset mod Length(FROM.ROMData)];
    end
    else if (Address >= $A000) and FRAMEnabled then
      Result := FRAM[FMBC6RAMBanks[(Address - $A000) div $1000] * $1000 + (Address and $FFF)];
    Exit;
  end;

  if Address < $8000 then
  begin
    var Bank := FFixedROMBank;
    if Address >= $4000 then
      Bank := ROMBankSelected;
    Result := FROM.ROMData[(Bank mod FROMBankCount) * $4000 + (Address and $3FFF)];
    Exit;
  end;

  if Address < $A000 then
    Exit;

  if (Kind = TMapperType.HuC1) and FIRMode then
    Exit($C0);

  if not FHasRAM or ((Kind <> TMapperType.HuC1) and not FRAMEnabled) then
    Exit;

  var Bank := RAMBankSelected;
  Result := FRAM[(Bank * $2000 + (Address and $1FFF)) mod Length(FRAM)];
end;

procedure TGBMBC.WriteExtended(Address, Value: Integer);
begin
  var Kind := FMapperType;
  if Kind = TMapperType.MBC6 then
  begin
    if Address < $4000 then
    begin
      case Address and $3C00 of
        $0000:
          FRAMEnabled := Value = $0A;
        $0400:
          FMBC6RAMBanks[0] := Value and 7;
        $0800:
          FMBC6RAMBanks[1] := Value and 7;
        $0C00:
          FFlashEnabled := (Value and 1) <> 0;
        $1000:
          FFlashWriteEnabled := (Value and 1) <> 0;
        $2000, $2400:
          FMBC6ROMBanks[0] := Value and $7F;
        $2800, $2C00:
          FMBC6FlashBanks[0] := Value = 8;
        $3000, $3400:
          FMBC6ROMBanks[1] := Value and $7F;
        $3800, $3C00:
          FMBC6FlashBanks[1] := Value = 8;
      end;
      UpdateBanks;
    end
    else if Address < $8000 then
    begin
      var Slot := (Address - $4000) div $2000;
      if FFlashEnabled and FMBC6FlashBanks[Slot] then
        WriteFlash(FMBC6ROMBanks[Slot] * $2000 + (Address and $1FFF), Value);
    end
    else if (Address >= $A000) and FRAMEnabled then
      FRAM[FMBC6RAMBanks[(Address - $A000) div $1000] * $1000 + (Address and $FFF)] := Value;
    Exit;
  end;

  if Address < $8000 then
  begin
    case Kind of
      TMapperType.M161:
        if not FMapLocked then
        begin
          FBankLow := Value and $0F;
          FMapLocked := True;
        end;
      TMapperType.WisdomTree:
        if Address < $4000 then
          FBankLow := Address and $3F;
      TMapperType.HuC1:
        case Address and $6000 of
          $0000:
            FIRMode := (Value and $0F) = $0E;
          $2000:
            FBankLow := Value and $3F;
          $4000:
            FBankHigh := Value and 3;
        end;
      TMapperType.MMM01:
        begin
          var RegisterIndex := Address div $2000;
          var Mask := 0;
          case RegisterIndex of
            0:
              begin
                FRAMEnabled := (Value and $0F) = $A;
                if not FMapLocked then
                  FMMMRegisters[0] := Value and $7F;
                FMapLocked := FMapLocked or ((Value and $40) <> 0);
              end;
            1:
              begin
                Mask := (FMMMRegisters[3] shr 1) and $1E;
                if FMapLocked then
                  Mask := Mask or $60;
                FMMMRegisters[1] := (FMMMRegisters[1] and Mask) or (Value and ($7F xor Mask));
              end;
            2:
              begin
                Mask := (FMMMRegisters[0] shr 4) and 3;
                if FMapLocked then
                  Mask := Mask or $7C;
                FMMMRegisters[2] := (FMMMRegisters[2] and Mask) or (Value and ($7F xor Mask));
              end;
            3:
              begin
                if FMapLocked then
                  Mask := $7E;
                if (FMMMRegisters[2] and $40) <> 0 then
                  Mask := Mask or 1;
                FMMMRegisters[3] := ((FMMMRegisters[3] and Mask) or (Value and ($7F xor Mask))) and $7D;
              end;
          end;
        end;
    end;
    UpdateBanks;
    Exit;
  end;

  if Address < $A000 then
    Exit;

  if (Kind = TMapperType.HuC1) and FIRMode then
  begin
    FIROutput := (Value and 1) <> 0;
    Exit;
  end;

  if not FHasRAM or ((Kind <> TMapperType.HuC1) and not FRAMEnabled) then
    Exit;

  var Bank := RAMBankSelected;
  FRAM[(Bank * $2000 + (Address and $1FFF)) mod Length(FRAM)] := Value;
end;

procedure TGBMBC.ResetFlashCommand;
begin
  FFlashMode := 0;
  FFlashSequence := 0;
  FFlashCommand := 0;
  FFlashProgramming := 0;
  FFlashProgramBase := -1;
  FFlashProgramCount := 0;
  FFlashLastAddress := -1;
end;

function TGBMBC.ReadFlash(Address: Integer): Byte;
begin
  case FFlashMode of
    1:
      case Address and $FF of
        0:
          Result := $C2;
        1:
          Result := $81;
        2:
          Result := Ord(FFlashSector0Protected);
      else
        Result := $FF;
      end;
    2:
      Result := FFlashHidden[Address and $FF];
    3:
      Result := $80 or (Ord(FFlashSector0Protected) shl 1);
  else
    Result := FFlash[Address];
  end;
end;

procedure TGBMBC.WriteFlash(Address: Integer; Value: Byte);
begin
  // MX29F008TC commands use chip addresses, independent of the CPU window.
  // Operations complete synchronously; status remains visible until F0.
  if Value = $F0 then
  begin
    ResetFlashCommand;
    Exit;
  end;

  if FFlashProgramming <> 0 then
  begin
    if FFlashProgramCount = 128 then
    begin
      if Address <> FFlashLastAddress then
        Exit;

      var Writable := FFlashWriteEnabled;
      if FFlashProgramming = 1 then
        Writable := (FFlashProgramBase >= $20000) or
          (FFlashWriteEnabled and not FFlashSector0Protected);
      if Writable then
        for var i := 0 to 127 do
          if FFlashProgramming = 2 then
            FFlashHidden[(FFlashProgramBase + i) and $FF] :=
              FFlashHidden[(FFlashProgramBase + i) and $FF] and FFlashBuffer[i]
          else
            FFlash[FFlashProgramBase + i] := FFlash[FFlashProgramBase + i] and FFlashBuffer[i];
      FFlashProgramming := 0;
      FFlashMode := 3;
      Exit;
    end;

    var Base := Address and $FFF80;
    if FFlashProgramBase < 0 then
    begin
      FFlashProgramBase := Base;
      FillChar(FFlashBuffer, SizeOf(FFlashBuffer), $FF);
    end;
    if Base <> FFlashProgramBase then
      Exit;

    FFlashBuffer[Address and $7F] := Value;
    FFlashLastAddress := Address;
    Inc(FFlashProgramCount);
    Exit;
  end;

  if FFlashMode <> 0 then
    Exit;

  case FFlashSequence of
    0:
      if (Address = $5555) and (Value = $AA) then
        FFlashSequence := 1;
    1:
      if (Address = $2AAA) and (Value = $55) then
        FFlashSequence := 2
      else
        FFlashSequence := 0;
    2:
      begin
        FFlashSequence := 0;
        if FFlashCommand <> 0 then
        begin
          case FFlashCommand of
            $80:
              if (Value = $10) and (Address = $5555) then
              begin
                var First := 0;
                if not FFlashWriteEnabled or FFlashSector0Protected then
                  First := $20000;
                FillChar(FFlash[First], Length(FFlash) - First, $FF);
                FFlashMode := 3;
              end
              else if Value = $30 then
              begin
                var First := Address and $E0000;
                if (First <> 0) or (FFlashWriteEnabled and not FFlashSector0Protected) then
                  FillChar(FFlash[First], $20000, $FF);
                FFlashMode := 3;
              end;
            $60:
              if (Address = $5555) and FFlashWriteEnabled then
                case Value of
                  $04:
                    begin
                      FillChar(FFlashHidden, SizeOf(FFlashHidden), $FF);
                      FFlashMode := 3;
                    end;
                  $20, $40:
                    begin
                      FFlashSector0Protected := Value = $20;
                      FFlashMode := 3;
                    end;
                  $E0:
                    FFlashProgramming := 2;
                end;
            $77:
              if (Address = $5555) and (Value = $77) then
                FFlashMode := 2;
          end;
          FFlashCommand := 0;
        end
        else if Address = $5555 then
          case Value of
            $90:
              FFlashMode := 1;
            $A0:
              FFlashProgramming := 1;
            $80, $60, $77:
              FFlashCommand := Value;
          end;
        if FFlashProgramming <> 0 then
        begin
          FFlashProgramBase := -1;
          FFlashProgramCount := 0;
        end;
      end;
  end;
end;

procedure TGBMBC.SetAcceleration(X, Y: Double);
begin
  if IsNan(X) or IsInfinite(X) then
    X := 0;
  if IsNan(Y) or IsInfinite(Y) then
    Y := 0;
  SetAccelerometer(Round(EnsureRange($81D0 - EnsureRange(X, -4.0, 4.0) * $70, 0.0, 65535.0)),
    Round(EnsureRange($81D0 + EnsureRange(Y, -4.0, 4.0) * $70, 0.0, 65535.0)));
end;

procedure TGBMBC.SetAccelerometer(X, Y: Word);
begin
  FTiltX := X;
  FTiltY := Y;
end;

function TGBMBC.ReadEEPROM: Byte;
begin
  Result := FEEPROMPins and $C2;
  if FEEPROMMode = 2 then
  begin
    if (FEEPROMReadBit >= 0) and ((FEEPROMData and (1 shl FEEPROMReadBit)) <> 0) then
      Result := Result or 1;
  end
  else if FEEPROMMode in [0, 5] then
    Result := Result or 1;
end;

procedure TGBMBC.WriteEEPROM(Value: Byte);
begin
  var Previous := FEEPROMPins;
  FEEPROMPins := Value and $C2;

  if (Value and $80) = 0 then
  begin
    FEEPROMMode := 0;
    FEEPROMBits := 0;
    Exit;
  end;

  if ((Value and $40) = 0) or ((Previous and $40) <> 0) then
    Exit;

  var BitIn := (Value shr 1) and 1;
  case FEEPROMMode of
    0:
      if BitIn <> 0 then
      begin
        FEEPROMMode := 1;
        FEEPROMBits := 0;
        FEEPROMShift := 0;
      end;
    1:
      begin
        FEEPROMShift := (FEEPROMShift shl 1) or BitIn;
        Inc(FEEPROMBits);
        if FEEPROMBits = 10 then
        begin
          FEEPROMAddress := FEEPROMShift and $7F;
          var Op := (FEEPROMShift shr 8) and 3;
          FEEPROMMode := 5;
          case Op of
            2:
              begin
                FEEPROMMode := 2;
                FEEPROMReadBit := -1; // Dummy zero before data.
                FEEPROMData := (FRAM[FEEPROMAddress * 2] shl 8) or FRAM[FEEPROMAddress * 2 + 1];
              end;
            1:
              begin
                FEEPROMMode := 3;
                FEEPROMBits := 0;
                FEEPROMData := 0;
              end;
            3:
              if FEEPROMWriteEnabled then
              begin
                FRAM[FEEPROMAddress * 2] := $FF;
                FRAM[FEEPROMAddress * 2 + 1] := $FF;
              end;
            0:
              case (FEEPROMShift shr 6) and 3 of
                0:
                  FEEPROMWriteEnabled := False;
                3:
                  FEEPROMWriteEnabled := True;
                2:
                  if FEEPROMWriteEnabled then
                    for var i := 0 to High(FRAM) do
                      FRAM[i] := $FF;
                1:
                  begin
                    FEEPROMMode := 4;
                    FEEPROMBits := 0;
                    FEEPROMData := 0;
                  end;
              end;
          end;
        end;
      end;
    2:
      begin
        if FEEPROMReadBit = -1 then
          FEEPROMReadBit := 15
        else if FEEPROMReadBit = 0 then
        begin
          FEEPROMAddress := (Integer(FEEPROMAddress) + 1) and $7F;
          FEEPROMData := (FRAM[FEEPROMAddress * 2] shl 8) or FRAM[FEEPROMAddress * 2 + 1];
          FEEPROMReadBit := 15;
        end
        else
          Dec(FEEPROMReadBit);
      end;
    3, 4:
      begin
        FEEPROMData := (FEEPROMData shl 1) or BitIn;
        Inc(FEEPROMBits);
        if FEEPROMBits = 16 then
        begin
          if FEEPROMWriteEnabled then
            if FEEPROMMode = 4 then
              for var i := 0 to 127 do
              begin
                FRAM[i * 2] := FEEPROMData shr 8;
                FRAM[i * 2 + 1] := FEEPROMData and $FF;
              end
            else
            begin
              FRAM[FEEPROMAddress * 2] := FEEPROMData shr 8;
              FRAM[FEEPROMAddress * 2 + 1] := FEEPROMData and $FF;
            end;
          FEEPROMMode := 5;
        end;
      end;
  end;
end;

procedure TGBMBC.ExecuteHuCCommand;
begin
  // Pan Docs HuC3 mailbox protocol: commands execute on semaphore bit 0 clear.
  var Arg := FHuCCommand and $0F;
  case (FHuCCommand shr 4) and 7 of
    1:
      begin
        UpdateRTC;
        FHuCResponse := FHuCMemory[FHuCAddress];
        FHuCAddress := (Integer(FHuCAddress) + 1) and $FF;
      end;
    3:
      begin
        FHuCMemory[FHuCAddress] := Arg;
        FHuCAddress := (Integer(FHuCAddress) + 1) and $FF;
      end;
    4:
      FHuCAddress := (FHuCAddress and $F0) or Arg;
    5:
      FHuCAddress := (FHuCAddress and $0F) or (Arg shl 4);
    6:
      case Arg of
        0:
          begin
            UpdateRTC;
            var Minutes := (FHuCSeconds div 60) mod 1440;
            var Days := FHuCSeconds div 86400;
            for var i := 0 to 2 do
            begin
              FHuCMemory[i] := (Minutes shr (i * 4)) and $0F;
              FHuCMemory[i + 3] := (Days shr (i * 4)) and $0F;
              FHuCMemory[i + $10] := FHuCMemory[i];
              FHuCMemory[i + $13] := FHuCMemory[i + 3];
            end;
            FHuCMemory[6] := 0;
          end;
        1:
          begin
            UpdateRTC;
            var Minutes := Integer(FHuCMemory[0]) or (Integer(FHuCMemory[1]) shl 4) or (Integer(FHuCMemory[2]) shl 8);
            var Days := Integer(FHuCMemory[3]) or (Integer(FHuCMemory[4]) shl 4) or (Integer(FHuCMemory[5]) shl 8);
            var OldMinutes := FHuCSeconds div 60;
            FHuCSeconds := Int64(Days) * 86400 + (Minutes mod 1440) * 60;
            for var i := 0 to 2 do
            begin
              FHuCMemory[$10 + i] := ((FHuCSeconds div 60 mod 1440) shr (i * 4)) and $0F;
              FHuCMemory[$13 + i] := ((FHuCSeconds div 86400) shr (i * 4)) and $0F;
            end;
          // Preserve the remaining delay for the event when setting the clock.
            var EventMinutes: Int64 := 0;
            for var i := 0 to 5 do
              EventMinutes := EventMinutes or (Int64(FHuCMemory[$58 + i]) shl (i * 4));
            var EventDay := (EventMinutes shr 12) and $FFF;
            EventMinutes := ((EventDay * 1440 + (EventMinutes and $FFF)) + FHuCSeconds div 60 - OldMinutes + Int64(4096) * 1440) mod (Int64(4096) * 1440);
            var PackedEvent := (EventMinutes mod 1440) or ((EventMinutes div 1440) shl 12);
            for var i := 0 to 5 do
              FHuCMemory[$58 + i] := (PackedEvent shr (i * 4)) and $0F;
          end;
        2:
          FHuCResponse := 1; // MCU ready status, required by Robopon startup.
      end;
  end;
end;

procedure TGBMBC.CompleteCameraCapture;
begin
  var Tiles := FCamera.BuildTiles(FCameraCaptureRegisters);
  if Length(FRAM) >= $100 + Length(Tiles) then
    for var i := 0 to High(Tiles) do
      FRAM[$100 + i] := Tiles[i];
  FCameraRegisters[0] := FCameraRegisters[0] and 6;
end;

function TGBMBC.GetRumbleOn: Boolean;
begin
  Result := FHasRumble and ((FBankHigh and 8) <> 0);
end;

function TGBMBC.TakeRumbleLevel: Byte;
begin
  if FRumbleClocks = 0 then
    Result := Ord(RumbleOn) * 255
  else
    Result := (FRumbleOnClocks * 255 + FRumbleClocks div 2) div FRumbleClocks;
  FRumbleClocks := 0;
  FRumbleOnClocks := 0;
end;

procedure TGBMBC.Step(Clocks: Integer);
begin
  if FHasRumble and (Clocks > 0) then
  begin
    Inc(FRumbleClocks, Clocks);
    if RumbleOn then
      Inc(FRumbleOnClocks, Clocks);
  end;
  // Clocks are CPU T-cycles: PHI doubles along with CGB CPU speed.
  if (FCameraClocks <= 0) or ((FCameraRegisters[0] and 1) = 0) then
    Exit;

  Dec(FCameraClocks, Clocks);
  if FCameraClocks <= 0 then
  begin
    FCameraClocks := 0;
    CompleteCameraCapture;
  end;
end;

function TGBMBC.ReadPeripheral(Address: Integer): Integer;
begin
  Result := $FF;
  if Address < $8000 then
  begin
    var Offset := Address;
    if Address >= $4000 then
      Offset := ROMBankSelected * $4000 + (Address and $3FFF);
    if Offset < Length(FROM.ROMData) then
      Result := FROM.ROMData[Offset];
    Exit;
  end;

  if Address < $A000 then
    Exit;

  case FMapperType of
    TMapperType.MBC7:
      if FRAMEnabled and (FPeripheralBank = $40) and (Address < $B000) then
        case Address and $F0 of
          $20:
            Result := FLatchedX and $FF;
          $30:
            Result := FLatchedX shr 8;
          $40:
            Result := FLatchedY and $FF;
          $50:
            Result := FLatchedY shr 8;
          $60:
            Result := 0;
          $80:
            Result := ReadEEPROM;
        end;
    TMapperType.PocketCamera:
      if (FPeripheralBank and $10) <> 0 then
      begin
        Result := 0;
        if (Address and $7F) = 0 then
          Result := FCameraRegisters[0];
      end
      else if (FCameraRegisters[0] and 1) <> 0 then
        Result := 0
      else if FHasRAM then
        Result := FRAM[(RAMBankSelected * $2000 + (Address and $1FFF)) mod Length(FRAM)];
    TMapperType.HuC3:
      case FPeripheralMode of
        0, $A:
          if FHasRAM then
            Result := FRAM[(RAMBankSelected * $2000 + (Address and $1FFF)) mod Length(FRAM)];
        $C:
          Result := $80 or (FHuCCommand and $70) or FHuCResponse;
        $D:
          Result := $FF; // Ready, MCU command is completed synchronously.
          $E:
          Result := $C0; // Disconnected infrared receiver.
      end;
  end;
end;

procedure TGBMBC.WritePeripheral(Address, Value: Integer);
begin
  if Address < $2000 then
  begin
    FPeripheralMode := Value and $0F;
    FRAMEnabled := FPeripheralMode = $A;
  end
  else if Address < $4000 then
  begin
    if FMapperType = TMapperType.PocketCamera then
      FBankLow := Value and $3F
    else
      FBankLow := Value and $7F;
    UpdateBanks;
  end
  else if Address < $6000 then
  begin
    FPeripheralBank := Value;
    if FMapperType = TMapperType.HuC3 then
      FPeripheralBank := Value and 3;
    UpdateBanks;
  end
  else if Address >= $A000 then
    case FMapperType of
      TMapperType.MBC7:
        if FRAMEnabled and (FPeripheralBank = $40) and (Address < $B000) then
          case Address and $F0 of
            0:
              if Value = $55 then
              begin
                FTiltReset := True;
                FLatchedX := $8000;
                FLatchedY := $8000;
              end;
            $10:
              if (Value = $AA) and FTiltReset then
              begin
                FTiltReset := False;
                FLatchedX := FTiltX;
                FLatchedY := FTiltY;
              end;
            $80:
              WriteEEPROM(Value);
          end;
      TMapperType.PocketCamera:
        if (FPeripheralBank and $10) <> 0 then
        begin
          var RegisterIndex := Address and $7F;
          if RegisterIndex <= High(FCameraRegisters) then
            if RegisterIndex = 0 then
            begin
              FCameraRegisters[0] := Value and 7;
              if ((Value and 1) <> 0) and (FCameraClocks = 0) then
              begin
                FCameraCaptureRegisters := FCameraRegisters;
                FCamera.BeginCapture;
                FCameraClocks := 4 * (32446 + (512 * Ord((FCameraRegisters[1] and $80) = 0)) +
                  16 * (Integer(FCameraRegisters[2]) * 256 + FCameraRegisters[3]));
              end;
            end
            else if (FCameraRegisters[0] and 1) = 0 then
              FCameraRegisters[RegisterIndex] := Value;
        end
        else if FRAMEnabled and FHasRAM and ((FCameraRegisters[0] and 1) = 0) then
          FRAM[(RAMBankSelected * $2000 + (Address and $1FFF)) mod Length(FRAM)] := Value;
      TMapperType.HuC3:
        case FPeripheralMode of
          $A:
            if FHasRAM then
              FRAM[(RAMBankSelected * $2000 + (Address and $1FFF)) mod Length(FRAM)] := Value;
          $B:
            FHuCCommand := Value and $7F;
          $D:
            if (Value and 1) = 0 then
              ExecuteHuCCommand;
        end;
    end;
end;

procedure TGBMBC.SerializeState(State: TStateArchive);
begin
  if State.Loading then
  begin
    // Transient host feedback is not part of the snapshot. Motor state is
    // already in FBankHigh; retain the existing MBC5 snapshot layout.
    FRumbleClocks := 0;
    FRumbleOnClocks := 0;
  end
  else
    UpdateRTC;
  State.Field(FRAMEnabled, SizeOf(FRAMEnabled));
  State.Field(FHasRAM, SizeOf(FHasRAM));
  State.Field(FIsROMMode, SizeOf(FIsROMMode));
  if Length(FRAM) > 0 then
    State.Field(FRAM[0], Length(FRAM) * SizeOf(FRAM[0]));
  State.Field(FBankLow, SizeOf(FBankLow));
  State.Field(FBankHigh, SizeOf(FBankHigh));
  State.Field(FROMBankCount, SizeOf(FROMBankCount));
  State.Field(ROMBankSelected, SizeOf(ROMBankSelected));
  State.Field(RAMBankSelected, SizeOf(RAMBankSelected));
  State.Field(FRTC, SizeOf(FRTC));
  State.Field(FRTCSnapshot, SizeOf(FRTCSnapshot));
  State.Field(FRTCLatched, SizeOf(FRTCLatched));
  State.Field(FRTCLatchWrite, SizeOf(FRTCLatchWrite));

  // These boards could not create snapshots before peripheral support.
  // Keep the existing layout for ROMOnly/MBC1/2/3/5 snapshots.
  if FMapperType in [TMapperType.MBC7, TMapperType.PocketCamera, TMapperType.HuC3] then
  begin
    State.Field(FPeripheralMode, SizeOf(FPeripheralMode));
    State.Field(FPeripheralBank, SizeOf(FPeripheralBank));
    State.Field(FTiltX, SizeOf(FTiltX));
    State.Field(FTiltY, SizeOf(FTiltY));
    State.Field(FLatchedX, SizeOf(FLatchedX));
    State.Field(FLatchedY, SizeOf(FLatchedY));
    State.Field(FTiltReset, SizeOf(FTiltReset));
    State.Field(FEEPROMWriteEnabled, SizeOf(FEEPROMWriteEnabled));
    State.Field(FEEPROMPins, SizeOf(FEEPROMPins));
    State.Field(FEEPROMMode, SizeOf(FEEPROMMode));
    State.Field(FEEPROMAddress, SizeOf(FEEPROMAddress));
    State.Field(FEEPROMBits, SizeOf(FEEPROMBits));
    State.Field(FEEPROMShift, SizeOf(FEEPROMShift));
    State.Field(FEEPROMData, SizeOf(FEEPROMData));
    State.Field(FEEPROMReadBit, SizeOf(FEEPROMReadBit));
    State.Field(FHuCMemory, SizeOf(FHuCMemory));
    State.Field(FHuCCommand, SizeOf(FHuCCommand));
    State.Field(FHuCResponse, SizeOf(FHuCResponse));
    State.Field(FHuCAddress, SizeOf(FHuCAddress));
    State.Field(FHuCSeconds, SizeOf(FHuCSeconds));
    State.Field(FCameraRegisters, SizeOf(FCameraRegisters));
    State.Field(FCameraCaptureRegisters, SizeOf(FCameraCaptureRegisters));
    State.Field(FCameraClocks, SizeOf(FCameraClocks));
    if FCamera <> nil then
      FCamera.SerializeState(State);
  end;

  if FMapperType in [TMapperType.MMM01, TMapperType.M161, TMapperType.WisdomTree, TMapperType.HuC1] then
  begin
    State.Field(FMapLocked, SizeOf(FMapLocked));
    State.Field(FIRMode, SizeOf(FIRMode));
    State.Field(FIROutput, SizeOf(FIROutput));
    State.Field(FMMMRegisters, SizeOf(FMMMRegisters));
  end;
  if FMapperType = TMapperType.MBC6 then
  begin
    State.Field(FMBC6ROMBanks, SizeOf(FMBC6ROMBanks));
    State.Field(FMBC6RAMBanks, SizeOf(FMBC6RAMBanks));
    State.Field(FMBC6FlashBanks, SizeOf(FMBC6FlashBanks));
    State.Field(FFlashEnabled, SizeOf(FFlashEnabled));
    State.Field(FFlashWriteEnabled, SizeOf(FFlashWriteEnabled));
    State.Field(FFlashSector0Protected, SizeOf(FFlashSector0Protected));
    State.Field(FFlash[0], Length(FFlash));
    State.Field(FFlashHidden, SizeOf(FFlashHidden));
    State.Field(FFlashBuffer, SizeOf(FFlashBuffer));
    State.Field(FFlashMode, SizeOf(FFlashMode));
    State.Field(FFlashSequence, SizeOf(FFlashSequence));
    State.Field(FFlashCommand, SizeOf(FFlashCommand));
    State.Field(FFlashProgramming, SizeOf(FFlashProgramming));
    State.Field(FFlashProgramBase, SizeOf(FFlashProgramBase));
    State.Field(FFlashProgramCount, SizeOf(FFlashProgramCount));
    State.Field(FFlashLastAddress, SizeOf(FFlashLastAddress));
  end;
  if State.Loading then
    UpdateBanks;
  // Snapshot restores emulated clock values, not elapsed host time since capture.
  if State.Loading then
    FRTCLastTime := RTCNow;
end;

end.

