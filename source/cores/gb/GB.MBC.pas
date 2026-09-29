unit GB.MBC;

interface

uses
  System.SysUtils, GB.ROM;

{$SCOPEDENUMS ON}

type
  TMapperType = (ROMOnly, MBC1, MBC2, MBC3, MBC5, MBC07, MMM01, HuC1, HuC3);

type
  TGBMBC = class
  private
    FROM: TGBROM;
    FRAMEnabled: Boolean;
    FHasRAM: Boolean;
    FIsROMMode: Boolean;
    FRAM: array of Integer;
    FBankLow, FBankHigh, FROMBankCount: Integer;
    procedure UpdateBanks;
  public
    ROMBankSelected: Integer;
    RAMBankSelected: Integer;
    function MbcRead(Address: Integer): Integer;
    procedure MbcWrite(Address, Value: Integer);
    constructor Create(AROM: TGBROM); overload;
  end;

implementation

{ TGBMBC }

constructor TGBMBC.Create(AROM: TGBROM);
begin
  inherited Create;
  if AROM = nil then
    raise EArgumentNilException.Create('ROM must not be nil');
  if not (AROM.GetCartridgeType.ID in
    [$00, $01, $02, $03, $05, $06, $08, $09, $0F, $10, $11, $12, $13,
     $19, $1A, $1B, $1C, $1D, $1E]) then
    raise ENotSupportedException.Create('Unsupported cartridge: ' + AROM.GetCartridgeType.Name);
  FROM := AROM;
  FROMBankCount := Length(FROM.ROMData) div $4000;
  if FROMBankCount = 0 then
    FROMBankCount := 1;
  FBankLow := 1;
  FBankHigh := 0;
  FRAMEnabled := False;
  FIsROMMode := True;
  FHasRAM := FROM.GetCartridgeType.HasRAM;
  if FROM.GetCartridgeType.MapperType = 'MBC2' then
    SetLength(FRAM, $200) // 512 four-bit internal RAM cells
  else
  if FHasRAM and Assigned(FROM.Cartridge) then
    if FROM.Cartridge.RAMSizeBytes > 0 then
      SetLength(FRAM, FROM.Cartridge.RAMSizeBytes);
  FHasRAM := Length(FRAM) > 0;
  UpdateBanks;
end;

procedure TGBMBC.UpdateBanks;
begin
  if FROM.GetCartridgeType.MapperType = 'MBC3' then
  begin
    ROMBankSelected := (FBankLow and $7F) mod FROMBankCount;
    RAMBankSelected := FBankHigh and $0F;
  end
  else if FROM.GetCartridgeType.MapperType = 'MBC5' then
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

function TGBMBC.MbcRead(Address: Integer): Integer;
begin
  Result := $FF;
  if (Address < 0) or (Address > $BFFF) then
    Exit;
  case FROM.GetCartridgeType.ID of
    $00, $08, $09:
      if (Address < $8000) and (Address < Length(FROM.ROMData)) then
        Result := FROM.ROMData[Address]
      else if (Address >= $A000) and FHasRAM then
        Result := FRAM[(Address - $A000) mod Length(FRAM)];
    $01, $02, $03:
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
    $05, $06:
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
    $0F, $10, $11, $12, $13:
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
    $19, $1A, $1B, $1C, $1D, $1E:
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
  if FROM.GetCartridgeType.ID in [$08, $09] then
  begin
    if (Address >= $A000) and FHasRAM then
      FRAM[(Address - $A000) mod Length(FRAM)] := Value and $FF;
  end
  else if FROM.GetCartridgeType.MapperType = 'MBC1' then
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
  else if FROM.GetCartridgeType.MapperType = 'MBC3' then
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
    // $6000-$7FFF latches the RTC, which is not present on cartridge type $13.
    else if (Address >= $A000) and FRAMEnabled and FHasRAM and
      (RAMBankSelected <= 3) then
    begin
      var EffectiveAddress := (RAMBankSelected * $2000 + Address - $A000) mod Length(FRAM);
      FRAM[EffectiveAddress] := Value and $FF;
    end;
  end
  else if FROM.GetCartridgeType.MapperType = 'MBC5' then
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
  else if FROM.GetCartridgeType.MapperType = 'MBC2' then
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

end.

