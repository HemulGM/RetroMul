unit GB.MBC;

interface

uses
  Core.Snapshots, System.Classes, System.SysUtils, GB.ROM, GB.Cartridge;

{$SCOPEDENUMS ON}

type
  TMapperType = GB.Cartridge.TMapperType;

type
  TGBMBC = class
  private
    FROM: TGBROM;
    FRAMEnabled: Boolean;
    FHasRAM: Boolean;
    FIsROMMode: Boolean;
    FRAM: array of Integer;
    FBankLow, FBankHigh, FROMBankCount: Integer;
    FHasTimer, FRTCLatched: Boolean;
    FRTC, FRTCSnapshot: array[0..4] of Byte;
    FRTCLatchWrite: Byte;
    FRTCLastTime: Int64;
    FRTCClock: TFunc<Int64>;
    function RTCNow: Int64;
    procedure UpdateRTC;
    procedure UpdateBanks;
  public
    ROMBankSelected: Integer;
    RAMBankSelected: Integer;
    function MbcRead(Address: Integer): Integer;
    procedure MbcWrite(Address, Value: Integer);
    function IsCGBCartridge: Boolean;
    constructor Create(AROM: TGBROM; const RTCClock: TFunc<Int64> = nil); overload;
    function SaveMemory: TBytes;
    procedure LoadSaveMemory(const Data: TBytes);
    function RTCData: TBytes;
    procedure LoadRTCData(const Data: TBytes);
    function HasBattery: Boolean;
    property HasTimer: Boolean read FHasTimer;
    procedure SerializeState(State: TStateArchive);
  end;

implementation

uses System.DateUtils;

{ TGBMBC }

constructor TGBMBC.Create(AROM: TGBROM; const RTCClock: TFunc<Int64>);
begin
  inherited Create;
  if AROM = nil then
    raise EArgumentNilException.Create('ROM must not be nil');
  if not (AROM.GetCartridgeType.MapperType in
    [TMapperType.ROMOnly, TMapperType.MBC1, TMapperType.MBC2,
      TMapperType.MBC3, TMapperType.MBC5]) then
    raise ENotSupportedException.Create('Unsupported cartridge: ' + AROM.GetCartridgeType.Name);
  FROM := AROM;
  FRTCClock := RTCClock;
  FHasTimer := FROM.GetCartridgeType.HasTimer;
  FRTCLastTime := RTCNow;
  FROMBankCount := Length(FROM.ROMData) div $4000;
  if FROMBankCount = 0 then
    FROMBankCount := 1;
  FBankLow := 1;
  FBankHigh := 0;
  FRAMEnabled := False;
  FIsROMMode := True;
  FHasRAM := FROM.GetCartridgeType.HasRAM;
  if FROM.GetCartridgeType.MapperType = TMapperType.MBC2 then
    SetLength(FRAM, $200) // 512 four-bit internal RAM cells
  else if FHasRAM and Assigned(FROM.Cartridge) then
    // The header also permits 64 KiB (8-bank) and 128 KiB (16-bank) RAM.
    // Do not silently turn these cartridges into RAM-less ones.
    if FROM.Cartridge.RAMSizeBytes > 0 then
      SetLength(FRAM, FROM.Cartridge.RAMSizeBytes);
  FHasRAM := Length(FRAM) > 0;
  UpdateBanks;
end;

procedure TGBMBC.UpdateBanks;
begin
  if FROM.GetCartridgeType.MapperType = TMapperType.MBC3 then
  begin
    ROMBankSelected := (FBankLow and $7F) mod FROMBankCount;
    RAMBankSelected := FBankHigh and $0F;
  end
  else if FROM.GetCartridgeType.MapperType = TMapperType.MBC5 then
  begin
    // MBC5 uses a nine-bit ROM bank number and does not remap bank zero.
    ROMBankSelected := FBankLow mod FROMBankCount;
    RAMBankSelected := FBankHigh and $0F;
    if FROM.GetCartridgeType.HasRumble then
      RAMBankSelected := RAMBankSelected and 7;
  end
  else
  begin
    ROMBankSelected := ((FBankHigh shl 5) or FBankLow) mod FROMBankCount;
    if FIsROMMode then
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
  SetLength(Result, Length(FRAM));
  for var I := 0 to High(FRAM) do
    Result[I] := FRAM[I];
end;

procedure TGBMBC.LoadSaveMemory(const Data: TBytes);
begin
  if Length(Data) <> Length(FRAM) then
    raise EReadError.Create('Invalid Game Boy battery RAM size');
  for var I := 0 to High(FRAM) do
    if FROM.GetCartridgeType.MapperType = TMapperType.MBC2 then
      FRAM[I] := Data[I] and $0F
    else
      FRAM[I] := Data[I];
end;

function TGBMBC.RTCData: TBytes;
begin
  Result := nil;
  if not FHasTimer then
    Exit;
  UpdateRTC;
  SetLength(Result, 17);
  Result[0] := Ord('G'); Result[1] := Ord('B');
  Result[2] := Ord('R'); Result[3] := 1;
  Move(FRTC[0], Result[4], 5);
  Move(FRTCLastTime, Result[9], SizeOf(FRTCLastTime));
end;

procedure TGBMBC.LoadRTCData(const Data: TBytes);
begin
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
  if (FROM.GetCartridgeType.MapperType = TMapperType.MBC3) and
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
  case FROM.GetCartridgeType.MapperType of
    TMapperType.ROMOnly:
      if Address < $8000 then
      begin
        if Address < Length(FROM.ROMData) then
          Result := FROM.ROMData[Address];
      end
      else if (Address >= $A000) and FHasRAM then
        Result := FRAM[(Address - $A000) mod Length(FRAM)];
    TMapperType.MBC1:
      if Address < $8000 then
      begin
        var Bank: Integer;
        if Address < $4000 then
        begin
          Bank := 0;
          if not FIsROMMode then
            Bank := (FBankHigh shl 5) mod FROMBankCount;
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
    TMapperType.MBC3:
      if Address < $4000 then
        Result := FROM.ROMData[Address]
      else if Address < $8000 then
      begin
        var EffectiveAddress := ROMBankSelected * $4000 + (Address and $3FFF);
        if EffectiveAddress < Length(FROM.ROMData) then
          Result := FROM.ROMData[EffectiveAddress];
      end
      else if (Address >= $A000) and FRAMEnabled and FHasRAM and
        (RAMBankSelected <= 3) then
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
  if FROM.GetCartridgeType.MapperType = TMapperType.ROMOnly then
  begin
    // Plain ROM+RAM cartridges expose their RAM permanently at A000-BFFF.
    if (Address >= $A000) and FHasRAM then
      FRAM[(Address - $A000) mod Length(FRAM)] := Value and $FF;
  end
  else if FROM.GetCartridgeType.MapperType = TMapperType.MBC1 then
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
  else if FROM.GetCartridgeType.MapperType = TMapperType.MBC3 then
  begin
    if Address <= $1FFF then
      FRAMEnabled := (Value and $0F) = $0A
    else if Address <= $3FFF then
    begin
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
        8, 9: FRTC[RAMBankSelected - 8] := Value and $3F;
        10: FRTC[2] := Value and $1F;
        11: FRTC[3] := Value and $FF;
        12: FRTC[4] := Value and $C1;
      end;
    end
    else if (Address >= $A000) and FRAMEnabled and FHasRAM and
      (RAMBankSelected <= 3) then
    begin
      var EffectiveAddress := (RAMBankSelected * $2000 + Address - $A000) mod Length(FRAM);
      FRAM[EffectiveAddress] := Value and $FF;
    end;
  end
  else if FROM.GetCartridgeType.MapperType = TMapperType.MBC5 then
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
  else if FROM.GetCartridgeType.MapperType = TMapperType.MBC2 then
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

procedure TGBMBC.SerializeState(State: TStateArchive);
begin
  if not State.Loading then
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
  // Snapshot restores emulated clock values, not elapsed host time since capture.
  if State.Loading then
    FRTCLastTime := RTCNow;
end;

end.

