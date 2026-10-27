unit ZX.DivStorage;

interface

uses
  System.SysUtils, System.Classes, Core.Snapshots, ZX.BlockImage, ZX.Machine,
  ZX.SDCard;

type
  TZXDivState = record
    Control, Select, SPIByte: Byte;
    AutoMap, PendingMap, MapPending: Boolean;
    ATA: array[0..7] of Byte;
    ATACommand, ATAHigh, ATALow: Byte;
    ATAOdd: Boolean;
    ATAPosition, ATARemaining: Integer;
    ATALBA: Cardinal;
    ATABuffer: array[0..511] of Byte;
    RAM: array[0..63, 0..8191] of Byte;
  end;

  TZXDivStorage = class
  private
    FKind: TZXDivType;
    FBanks: Integer;
    FROM: array[0..8191] of Byte;
    FState: TZXDivState;
    FDisk: TZXBlockImage;
    FSD: TZXSDCard;
    function MemoryBank(Address: Word): Integer;
    procedure ATACommand(Value: Byte);
    procedure ATAError(Code: Byte);
    procedure ATASector;
    procedure ATANext;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Configure(Kind: TZXDivType; RAMKB: Integer = 128; const Firmware: TBytes = nil);
    procedure Mount(Source: TStream; const KnownHash: TBytes = nil);
    procedure Reset(PowerOn: Boolean);
    function Mapped: Boolean;
    procedure BeforeFetch(Address: Word);
    procedure AfterFetch(Address: Word);
    procedure Refresh;
    function ReadMemory(Address: Word): Byte;
    procedure WriteMemory(Address: Word; Value: Byte);
    function ReadPort(Address: Word; out Value: Byte): Boolean;
    procedure WritePort(Address: Word; Value: Byte);
    procedure SerializeState(State: TStateArchive);
    property Kind: TZXDivType read FKind;
    property Banks: Integer read FBanks;
    property Disk: TZXBlockImage read FDisk;
  end;

implementation

uses
  System.Math;

constructor TZXDivStorage.Create;
begin
  inherited;
  FBanks := 4;
  FSD := TZXSDCard.Create;
  Reset(True);
end;

destructor TZXDivStorage.Destroy;
begin
  FSD.Free;
  FDisk.Free;
  inherited;
end;

procedure TZXDivStorage.Configure(Kind: TZXDivType; RAMKB: Integer; const Firmware: TBytes);
begin
  if not ((RAMKB = 0) or (RAMKB = 128) or (RAMKB = 512)) then
    raise EArgumentException.Create('DivMMC RAM must be 128 or 512 KiB');
  FKind := Kind;
  FBanks := 4;
  if Kind = zdMMC then
  begin
    FBanks := 16;
    if RAMKB = 512 then
      FBanks := 64;
  end;
  if Kind <> zdNone then
  begin
    var Data := Firmware;
    if Length(Data) = 0 then
    begin
      var Name := 'ZX_ESXIDE';
      if Kind = zdMMC then
        Name := 'ZX_ESXMMC';
      var S := TResourceStream.Create(HInstance, Name, PChar(10));
      try
        SetLength(Data, S.Size);
        if S.Size > 0 then
          S.ReadBuffer(Data[0], Length(Data));
      finally
        S.Free;
      end;
    end;
    if Length(Data) <> 8192 then
      raise EReadError.Create('DivIDE/DivMMC firmware must be exactly 8 KiB');
    Move(Data[0], FROM[0], 8192);
  end;
  Reset(True);
end;

procedure TZXDivStorage.Mount(Source: TStream; const KnownHash: TBytes);
begin
  var Disk := TZXBlockImage.Create(Source, KnownHash);
  FDisk.Free;
  FDisk := Disk;
  FSD.Disk := Disk;
end;

procedure TZXDivStorage.Reset(PowerOn: Boolean);
begin
  if PowerOn then
    FillChar(FState, SizeOf(FState), 0)
  else
  begin
    FState.Control := FState.Control and $40;
    FState.AutoMap := False;
    FState.MapPending := False;
  end;
  FState.Select := 3;
  FState.SPIByte := $FF;
  FillChar(FState.ATA, SizeOf(FState.ATA), 0);
  FState.ATA[2] := 1;
  FState.ATA[3] := 1;
  FState.ATA[7] := $50;
  FState.ATAOdd := False;
  FState.ATACommand := 0;
  FState.ATAPosition := 0;
  FState.ATARemaining := 0;
  FSD.Reset;
end;

function TZXDivStorage.Mapped: Boolean;
begin
  Result := (FKind <> zdNone) and (FState.AutoMap or ((FState.Control and $80) <> 0));
end;

procedure TZXDivStorage.BeforeFetch(Address: Word);
begin
  if (FKind <> zdNone) and ((Address and $FF00) = $3D00) then
    FState.AutoMap := True;
end;

procedure TZXDivStorage.AfterFetch(Address: Word);
begin
  if FKind = zdNone then
    Exit;
  if (Address = $0000) or (Address = $0008) or (Address = $0038) or (Address = $0066) or
    (Address = $04C6) or (Address = $0562) then
  begin
    FState.PendingMap := True;
    FState.MapPending := True;
  end
  else if (Address and $FFF8) = $1FF8 then
  begin
    FState.PendingMap := False;
    FState.MapPending := True;
  end;
end;

procedure TZXDivStorage.Refresh;
begin
  if FState.MapPending then
  begin
    FState.AutoMap := FState.PendingMap;
    FState.MapPending := False;
  end;
end;

function TZXDivStorage.MemoryBank(Address: Word): Integer;
begin
  if Address < $2000 then
  begin
    if (FState.Control and $C0) = $40 then
      Result := 3
    else
      Result := -1;
  end
  else
    Result := FState.Control and (FBanks - 1);
end;

function TZXDivStorage.ReadMemory(Address: Word): Byte;
begin
  var B := MemoryBank(Address);
  if B < 0 then
    Result := FROM[Address and $1FFF]
  else
    Result := FState.RAM[B, Address and $1FFF];
end;

procedure TZXDivStorage.WriteMemory(Address: Word; Value: Byte);
begin
  var B := MemoryBank(Address);
  if (Address >= $2000) and ((FState.Control and $C0) <> $40) then
    FState.RAM[B, Address and $1FFF] := Value
  else if (Address >= $2000) and (B <> 3) then
    FState.RAM[B, Address and $1FFF] := Value;
end;

procedure TZXDivStorage.ATAError(Code: Byte);
begin
  FState.ATA[1] := Code;
  FState.ATA[7] := $51;
  FState.ATACommand := 0;
end;

procedure TZXDivStorage.ATASector;
begin
  FState.ATAPosition := 0;
  if (FDisk = nil) or (FState.ATALBA >= FDisk.Sectors) then
  begin
    ATAError($10);
    Exit;
  end;
  var Data: TBytes;
  if not FDisk.ReadSector(FState.ATALBA, Data) then
  begin
    ATAError($10);
    Exit;
  end;
  Move(Data[0], FState.ATABuffer[0], 512);
  FState.ATA[7] := $58;
end;

procedure TZXDivStorage.ATANext;
begin
  Dec(FState.ATARemaining);
  Inc(FState.ATALBA);
  FState.ATA[2] := FState.ATARemaining and 255;
  if (FState.ATA[6] and $40) <> 0 then
  begin
    FState.ATA[3] := FState.ATALBA and 255;
    FState.ATA[4] := (FState.ATALBA shr 8) and 255;
    FState.ATA[5] := (FState.ATALBA shr 16) and 255;
    FState.ATA[6] := (FState.ATA[6] and $F0) or ((FState.ATALBA shr 24) and 15);
  end
  else
  begin
    FState.ATA[3] := FState.ATALBA mod 63 + 1;
    FState.ATA[6] := (FState.ATA[6] and $F0) or ((FState.ATALBA div 63) mod 16);
    var Cylinder := FState.ATALBA div 1008;
    FState.ATA[4] := Cylinder and 255;
    FState.ATA[5] := (Cylinder shr 8) and 255;
  end;
  if FState.ATARemaining > 0 then
    ATASector
  else
  begin
    FState.ATA[7] := $50;
    FState.ATACommand := 0;
  end;
end;

procedure TZXDivStorage.ATACommand(Value: Byte);
begin
  FState.ATACommand := Value;
  FState.ATAOdd := False;
  FState.ATA[1] := 0;
  if (FDisk = nil) or ((FState.ATA[6] and $10) <> 0) then
  begin
    ATAError(4);
    Exit;
  end;
  FState.ATARemaining := FState.ATA[2];
  if FState.ATARemaining = 0 then
    FState.ATARemaining := 256;
  if (FState.ATA[6] and $40) <> 0 then
    FState.ATALBA := Cardinal(FState.ATA[3]) or (Cardinal(FState.ATA[4]) shl 8) or
      (Cardinal(FState.ATA[5]) shl 16) or (Cardinal(FState.ATA[6] and 15) shl 24)
  else
  begin
    if not (FState.ATA[3] in [1..63]) then
    begin
      ATAError($10);
      Exit;
    end;
    FState.ATALBA := ((Cardinal(FState.ATA[4]) or (Cardinal(FState.ATA[5]) shl 8)) * 16 +
      (FState.ATA[6] and 15)) * 63 + FState.ATA[3] - 1;
  end;
  case Value of
    $20, $21:
      ATASector;
    $30, $31:
      if FDisk.WriteProtected then
        ATAError(4)
      else
        ATASector;
    $EC:
      begin
        FillChar(FState.ATABuffer, 512, 0);
        FState.ATAPosition := 0;
        FState.ATABuffer[0] := $40;
        FState.ATABuffer[2] := $FF;
        FState.ATABuffer[3] := $3F;
        FState.ATABuffer[6] := 16;
        FState.ATABuffer[12] := 63;
        FState.ATABuffer[99] := 2;
        FState.ATABuffer[106] := 1;
        FState.ATABuffer[120] := FDisk.Sectors and 255;
        FState.ATABuffer[121] := (FDisk.Sectors shr 8) and 255;
        FState.ATABuffer[122] := (FDisk.Sectors shr 16) and 255;
        FState.ATABuffer[123] := FDisk.Sectors shr 24;
        var Model: AnsiString := 'RETROMUL NATIVE CF                      ';
        for var i := 0 to 39 do
          FState.ATABuffer[54 + (i xor 1)] := Ord(Model[i + 1]);
        FState.ATA[7] := $58;
      end;
    $E7, $EF, $91, $10..$1F:
      begin
        FState.ATACommand := 0;
        FState.ATA[7] := $50;
      end;
  else
    ATAError(4);
  end;
end;

function TZXDivStorage.ReadPort(Address: Word; out Value: Byte): Boolean;
begin
  Result := False;
  Value := $FF;
  if FKind = zdNone then
    Exit;
  var P := Byte(Address and 255);
  if P = $E3 then
  begin
    FState.ATAOdd := False;
    Exit;
  end;
  if FKind = zdMMC then
  begin
    Result := P = $EB;
    if Result then
    begin
      Value := FState.SPIByte;
      FState.SPIByte := FSD.SPI($FF);
    end;
    Exit;
  end;
  Result := (P and $E3) = $A3;
  if not Result then
    Exit;
  var R := (P shr 2) and 7;
  if R <> 0 then
  begin
    FState.ATAOdd := False;
    Value := FState.ATA[R];
    if (FState.ATA[6] and $10) <> 0 then
      Value := 0;
  end
  else if FState.ATAOdd then
  begin
    Value := FState.ATAHigh;
    FState.ATAOdd := False;
  end
  else if (FState.ATA[7] and 8) <> 0 then
  begin
    Value := FState.ATABuffer[FState.ATAPosition];
    FState.ATAHigh := FState.ATABuffer[FState.ATAPosition + 1];
    Inc(FState.ATAPosition, 2);
    FState.ATAOdd := True;
    if FState.ATAPosition = 512 then
      if FState.ATACommand = $EC then
      begin
        FState.ATA[7] := $50;
        FState.ATACommand := 0;
      end
      else
        ATANext;
  end;
end;

procedure TZXDivStorage.WritePort(Address: Word; Value: Byte);
begin
  if FKind = zdNone then
    Exit;
  var P := Byte(Address and 255);
  if P = $E3 then
  begin
    FState.Control := Value or (FState.Control and $40);
    FState.ATAOdd := False;
    Exit;
  end;
  if FKind = zdMMC then
  begin
    if P = $E7 then
    begin
      FState.Select := Value and 3;
      FSD.Select(FState.Select = 2);
      if FState.Select <> 2 then
        FState.SPIByte := $FF;
    end;
    if P = $EB then
      FState.SPIByte := FSD.SPI(Value);
    Exit;
  end;
  if (P and $E3) <> $A3 then
    Exit;
  var R := (P shr 2) and 7;
  if R <> 0 then
  begin
    FState.ATAOdd := False;
    if R = 7 then
      ATACommand(Value)
    else
      FState.ATA[R] := Value;
  end
  else if (FState.ATA[7] and 8) <> 0 then
  begin
    if not FState.ATAOdd then
    begin
      FState.ATALow := Value;
      FState.ATAOdd := True;
    end
    else
    begin
      FState.ATAOdd := False;
      if not (FState.ATACommand in [$30, $31]) then
        Exit;
      FState.ATABuffer[FState.ATAPosition] := FState.ATALow;
      FState.ATABuffer[FState.ATAPosition + 1] := Value;
      Inc(FState.ATAPosition, 2);
      if FState.ATAPosition = 512 then
      begin
        var Data: TBytes;
        SetLength(Data, 512);
        Move(FState.ATABuffer[0], Data[0], 512);
        if not FDisk.WriteSector(FState.ATALBA, Data) then
          ATAError(4)
        else
          ATANext;
      end;
    end;
  end;
end;

procedure TZXDivStorage.SerializeState(State: TStateArchive);
begin
  var Kind: Integer := Ord(FKind);
  var Banks := FBanks;
  State.Field(Kind, 4);
  State.Field(Banks, 4);
  if (Kind < 0) or (Kind > Ord(High(TZXDivType))) or not (Banks in [4, 16, 64]) or
    ((Kind = Ord(zdMMC)) and (Banks = 4)) or ((Kind <> Ord(zdMMC)) and (Banks <> 4)) then
    raise EReadError.Create('Invalid DivIDE/DivMMC hardware state');
  if State.Loading then
  begin
    FKind := TZXDivType(Kind);
    FBanks := Banks;
  end;
  State.Field(FROM, SizeOf(FROM));
  State.Field(FState, SizeOf(FState));
  FSD.SerializeState(State);
  var HasDisk := FDisk <> nil;
  State.Field(HasDisk, SizeOf(HasDisk));
  if State.Loading and (HasDisk <> (FDisk <> nil)) then
    raise EReadError.Create('CF/SD source image must be mounted before loading state');
  if HasDisk then
    FDisk.SerializeState(State);
  if State.Loading and ((FState.ATAPosition < 0) or (FState.ATAPosition > 512) or (FState.ATAPosition mod 2 <> 0) or
    ((FState.ATA[7] and 8 <> 0) and (FState.ATAPosition = 512)) or
    (FState.ATARemaining < 0) or (FState.ATARemaining > 256)) then
    raise EReadError.Create('Invalid DivIDE/DivMMC transfer state');
end;

end.

