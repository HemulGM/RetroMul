unit MD.Mapper;

interface

uses
  System.SysUtils, System.Classes, MD.Cartridge, Core.Snapshots;

type
  TMDMapperKind = (Sega, ExtendedSSF, Realtec, Radica64, Radica128,
    SF001, SF002, SF004, SegaNet, Multi128, Multi256);

  TMDMapper = class
  private
    FCart: TMDCartridge;
    FKind: TMDMapperKind;
    FBanks: array[0..7] of Byte;
    FControl, FSelect, FMask, FPage: Byte;
    FLocked, FDirty: Boolean;
    FRAM, FDownload: TBytes;
    function RAMIndex(Address: Cardinal; out Index: Cardinal): Boolean;
    function ROMAddress(Address: Cardinal): Cardinal;
  public
    constructor Create(Cartridge: TMDCartridge);
    procedure Reset;
    function Read(Address: Cardinal; out Value: Word): Boolean;
    function Write(Address: Cardinal; Value: Word; HighByte, LowByte: Boolean): Boolean;
    function BatteryData: TBytes;
    procedure LoadBattery(const Data: TBytes);
    procedure SerializeState(Archive: TStateArchive);
    property Kind: TMDMapperKind read FKind;
    property Dirty: Boolean read FDirty write FDirty;
    function HasBattery: Boolean;
  end;

implementation

function Text(const Data: TBytes; Offset, Count: Integer): string;
begin
  Result := UpperCase(TEncoding.ASCII.GetString(Data, Offset, Count));
end;

constructor TMDMapper.Create(Cartridge: TMDCartridge);
begin
  inherited Create;
  FCart := Cartridge;
  var Data := FCart.Data;
  var Product := Text(Data, $180, 14);
  var Header := Text(Data, $100, 16);
  var Sum: Cardinal := 0;
  for var A := $100 to Length(Data) div 2 - 1 do
    Sum := (Sum + (Cardinal(Data[A * 2]) shl 8) + Data[A * 2 + 1]) and $FFFF;
  var Signature := (Cardinal(FCart.ReadWord($18E)) shl 16) or Sum;
  FKind := TMDMapperKind.Sega;
  if Header.StartsWith('SEGA SSF') then
    FKind := TMDMapperKind.ExtendedSSF;
  if Product.StartsWith('SF') then
  begin
    if Product.Contains('001') then
      FKind := TMDMapperKind.SF001;
    if Product.Contains('002') then
      FKind := TMDMapperKind.SF002;
    if Product.Contains('004') then
      FKind := TMDMapperKind.SF004;
  end;
  case Signature of
    $000006AB, $FFFFF863, $FFFF44FB, $0000C0CD:
      FKind := TMDMapperKind.Realtec;
    $00002326, $24F4FC84, $D95178D0, $00001F25, $1ADDA838, $104F32E9:
      FKind := TMDMapperKind.Radica64;
    $00001F7F:
      FKind := TMDMapperKind.Radica128;
    $0000F9D1:
      FKind := TMDMapperKind.SegaNet;
    $32962370:
      FKind := TMDMapperKind.Multi128;
    $E43C886F:
      FKind := TMDMapperKind.Multi256;
  end;
  if FKind in [TMDMapperKind.SF001, TMDMapperKind.SF004] then
    SetLength(FRAM, 32768);
  if FKind = TMDMapperKind.Radica128 then
    SetLength(FRAM, 8192);
  if FKind = TMDMapperKind.SegaNet then
    FDownload := Copy(Data);
  Reset;
end;

procedure TMDMapper.Reset;
begin
  for var I := 0 to 7 do
    FBanks[I] := I;
  FControl := 0;
  FSelect := 0;
  FMask := 0;
  FPage := 0;
  FLocked := False;
end;

function TMDMapper.RAMIndex(Address: Cardinal; out Index: Cardinal): Boolean;
begin
  Result := False;
  Index := 0;
  case FKind of
    TMDMapperKind.SF001:
      Result := (FControl and $C0 = $80) and (Address >= $3C0000) and (Address < $400000);
    TMDMapperKind.SF004:
      Result := (FSelect and $80 <> 0) and (Address >= $200000) and (Address < $300000);
    TMDMapperKind.Radica128:
      Result := (FControl <> 0) and (Address >= $200000) and (Address < $400000);
  end;
  if Result then
    Index := (Address div 2) and Cardinal(Length(FRAM) - 1);
end;

function TMDMapper.ROMAddress(Address: Cardinal): Cardinal;
begin
  Result := Cardinal(FBanks[Address shr 19]) * $80000 + (Address and $7FFFF);
  case FKind of
    TMDMapperKind.Realtec:
      if not FLocked then
        Result := $7E000 or (Address and $1FFF)
      else
        Result := ((((Address shr 16) and 7) and not Cardinal(FMask)) or (FSelect and FMask)) * $10000 + (Address and $FFFF);
    TMDMapperKind.Radica64, TMDMapperKind.Radica128:
      Result := ((Address shr 16) or FPage) * $10000 + (Address and $FFFF);
    TMDMapperKind.Multi128, TMDMapperKind.Multi256:
      Result := (Cardinal(FPage) * $20000 + Address) mod Cardinal(Length(FCart.Data));
    TMDMapperKind.SF001:
      begin
        Result := Address;
        if FControl and $40 <> 0 then
          Exit(High(Cardinal));
        if (FControl and $80 <> 0) and (Address < $40000) then
          Result := $380000 + Address;
      end;
    TMDMapperKind.SF002:
      begin
        Result := Address;
        if (FControl and $80 <> 0) and (Address >= $200000) and (Address < $3C0000) then
          Dec(Result, $200000);
      end;
    TMDMapperKind.SF004:
      begin
        if (Address >= $200000) or (FControl and $20 <> 0) or
          ((FControl and $40 <> 0) and (Address >= $140000)) then
          Exit(High(Cardinal));
        Result := Cardinal(FPage) * $40000;
        if FControl and $40 <> 0 then
          Result := (Result + Address) and $1FFFFF
        else
          Inc(Result, Address and $3FFFF);
      end;
  end;
end;

function TMDMapper.Read(Address: Cardinal; out Value: Word): Boolean;
begin
  Result := True;
  Value := $FFFF;
  if (Address >= $A13000) and (Address < $A13100) then
  begin
    case FKind of
      TMDMapperKind.Radica64, TMDMapperKind.Radica128:
        begin
          FPage := (Address shr 1) and $3F;
          if FKind = TMDMapperKind.Radica128 then
            FPage := FPage and $3E;
          FControl := 1;
        end;
      TMDMapperKind.Multi128:
        begin
          FPage := ((Address and 2) shl 2) or (Address and 4) or ((Address and $10) shr 3) or ((Address and $20) shr 5);
          Value := 3;
        end;
      TMDMapperKind.SF004:
        Value := FPage shl 4;
    else
      Exit(False);
    end;
    Exit;
  end;
  if Address >= $400000 then
    Exit(False);
  var Index: Cardinal;
  if RAMIndex(Address, Index) then
  begin
    Value := $FF00 or FRAM[Index];
    Exit;
  end;
  var A := ROMAddress(Address);
  if (FKind = TMDMapperKind.SegaNet) and (A + UInt64(1) < UInt64(Length(FDownload))) then
    Value := (Word(FDownload[A]) shl 8) or FDownload[A + 1]
  else if A <> High(Cardinal) then
    Value := FCart.ReadWord(A);
end;

function TMDMapper.Write(Address: Cardinal; Value: Word; HighByte, LowByte: Boolean): Boolean;
begin
  Result := True;
  var V := Value and $FF;
  if HighByte and not LowByte then
    V := Value shr 8;
  if (FKind = TMDMapperKind.Realtec) and (Address >= $400000) and (Address <= $404000) then
  begin
    if not FLocked then
      case Address of
        $400000:
          FLocked := V and 1 <> 0;
        $402000:
          FMask := (V and 3) shl 1;
        $404000:
          FSelect := (V and 3) shl 1;
      end;
    Exit;
  end;
  if (Address >= $A130F0) and (Address <= $A130FE) and LowByte then
  begin
    if (FKind = TMDMapperKind.SegaNet) and (Address = $A130F0) then
    begin
      FControl := Value and 1;
      Exit;
    end;
    if FKind = TMDMapperKind.ExtendedSSF then
    begin
      FBanks[(Address and 15) div 2] := Value and $7F;
      Exit;
    end;
    if FKind = TMDMapperKind.Sega then
      if Address <> $A130F0 then
      begin
        FBanks[(Address and 15) div 2] := Value and $3F;
        Exit;
      end;
  end;
  if (FKind = TMDMapperKind.Multi256) and (Address = $89000) then
  begin
    FPage := (((V and 1) shl 2) or ((V and $C0) shr 6)) shl 1;
    Exit;
  end;
  var Index: Cardinal;
  if RAMIndex(Address, Index) then
  begin
    if LowByte and (FRAM[Index] <> Value and $FF) then
    begin
      FRAM[Index] := Value and $FF;
      FDirty := True;
    end;
    Exit;
  end;
  if (Address < $10000) and not FLocked then
    case FKind of
      TMDMapperKind.SF001:
        if (Address shr 8) and 15 = 14 then
        begin
          FControl := V;
          FLocked := V and $20 <> 0;
          Exit;
        end;
      TMDMapperKind.SF002:
        begin
          FControl := V;
          Exit;
        end;
      TMDMapperKind.SF004:
        case (Address shr 8) and 15 of
          13:
            begin
              FSelect := V;
              Exit;
            end;
          14:
            begin
              FControl := V;
              FLocked := V and $80 = 0;
              Exit;
            end;
          15:
            begin
              FPage := (V shr 4) and 7;
              Exit;
            end;
        end;
    end;
  if (FKind = TMDMapperKind.SegaNet) and (FControl and 1 = 0) and (Address + UInt64(1) < UInt64(Length(FDownload))) then
  begin
    if HighByte then
      FDownload[Address] := Value shr 8;
    if LowByte then
      FDownload[Address + 1] := Value and $FF;
    Exit;
  end;
  Result := False;
end;

function TMDMapper.HasBattery: Boolean;
begin
  Result := Length(FRAM) > 0;
end;

function TMDMapper.BatteryData: TBytes;
begin
  Result := Copy(FRAM);
end;

procedure TMDMapper.LoadBattery(const Data: TBytes);
begin
  if Length(Data) <> Length(FRAM) then
    raise EReadError.Create('Invalid mapper backup RAM size');
  FRAM := Copy(Data);
  FDirty := False;
end;

procedure TMDMapper.SerializeState(Archive: TStateArchive);
begin
  Archive.Field(FBanks, SizeOf(FBanks));
  Archive.Field(FControl, 1);
  Archive.Field(FSelect, 1);
  Archive.Field(FMask, 1);
  Archive.Field(FPage, 1);
  Archive.Field(FLocked, SizeOf(FLocked));
  if Length(FRAM) > 0 then
    Archive.Field(FRAM[0], Length(FRAM));
  if Length(FDownload) > 0 then
    Archive.Field(FDownload[0], Length(FDownload));
end;

end.

