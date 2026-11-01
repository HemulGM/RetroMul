unit Lynx.Cartridge;

interface

uses
  System.SysUtils, Core.Snapshots, HW.EEPROM93Cxx;

type
  TLynxCartridge = class
  private
    FBanks: array[0..1] of TBytes;
    FPageSizes: array[0..1] of Integer;
    FShift, FCounter: Integer;
    FStrobe, FData: Boolean;
    FRotation, FEEPROM: Byte;
    FBootData: TBytes;
    FLoadAddress: Word;
    FEEPROMChip: TSerialEEPROM93Cxx;
    FAudin: Boolean;
    procedure UpdateEEPROM;
  public
    constructor Create(const Image: TBytes);
    destructor Destroy; override;
    procedure Reset;
    procedure AddressData(Value: Boolean);
    procedure AddressStrobe(Value: Boolean);
    function Read(Bank: Integer): Byte;
    procedure Write(Bank: Integer; Value: Byte);
    procedure SetAudin(Value: Boolean);
    function Audin: Boolean;
    function Backup: TBytes;
    procedure LoadBackup(const Data: TBytes);
    function BackupDirty: Boolean;
    procedure SerializeState(State: TStateArchive);
    property Rotation: Byte read FRotation;
    property EEPROMType: Byte read FEEPROM;
    property BootData: TBytes read FBootData;
    property LoadAddress: Word read FLoadAddress;
  end;

implementation

uses
  System.Classes;

constructor TLynxCartridge.Create(const Image: TBytes);
var
  Offset, Size: Integer;
begin
  inherited Create;
  Offset := 0;
  if (Length(Image) >= 64) and (Image[0] = Ord('L')) and
    (Image[1] = Ord('Y')) and (Image[2] = Ord('N')) and (Image[3] = Ord('X')) then
  begin
    FPageSizes[0] := Integer(Image[4]) or (Integer(Image[5]) shl 8);
    FPageSizes[1] := Integer(Image[6]) or (Integer(Image[7]) shl 8);
    if (Image[8] <> 1) or (Image[9] <> 0) then
      raise EReadError.Create('Unsupported Lynx cartridge header version');
    FRotation := Image[58];
    FEEPROM := Image[60];
    Offset := 64;
  end
  else if (Length(Image) >= 10) and (Image[6] = Ord('B')) and
    (Image[7] = Ord('S')) and (Image[8] = Ord('9')) and (Image[9] = Ord('3')) then
  begin
    FLoadAddress := (Integer(Image[2]) shl 8) or Image[3];
    Size := (Integer(Image[4]) shl 8) or Image[5];
    if Size > Length(Image) then
      Size := Length(Image);
    if (Size < 10) or (FLoadAddress < 10) or (Integer(FLoadAddress) + Size - 10 > 65536) then
      raise EReadError.Create('Invalid Lynx RAM executable');
    Dec(FLoadAddress, 10);
    FBootData := Copy(Image, 0, Size);
    Exit;
  end
  else
  begin
    case Length(Image) of
      65536, 131072, 262144, 524288:
        FPageSizes[0] := Length(Image) div 256;
    else
      raise EReadError.Create('Invalid raw Lynx cartridge size');
    end;
  end;
  for var Bank := 0 to 1 do
  begin
    if (FPageSizes[Bank] <> 0) and (FPageSizes[Bank] <> 256) and (FPageSizes[Bank] <> 512) and (FPageSizes[Bank] <> 1024) and (FPageSizes[Bank] <> 2048) then
      raise EReadError.Create('Invalid Lynx cartridge page size');
    Size := FPageSizes[Bank] * 256;
    if Size > Length(Image) - Offset then
      raise EReadError.Create('Truncated Lynx cartridge');
    FBanks[Bank] := Copy(Image, Offset, Size);
    Inc(Offset, Size);
  end;
  if Length(FBanks[0]) = 0 then
    raise EReadError.Create('Lynx cartridge bank 0 is empty');
  if Offset <> Length(Image) then
    raise EReadError.Create('Unexpected trailing Lynx cartridge data');
  var Chip := FEEPROM and 7;
  if (Chip >= 1) and (Chip <= 5) and (FEEPROM and $40 = 0) then
    FEEPROMChip := TSerialEEPROM93Cxx.Create(64 shl Chip, 16 - 8 * Ord(FEEPROM and $80 <> 0));
end;

destructor TLynxCartridge.Destroy;
begin
  FEEPROMChip.Free;
  inherited;
end;

procedure TLynxCartridge.Reset;
begin
  FShift := 0;
  FCounter := 0;
  FStrobe := False;
  FData := False;
  FAudin := True;
  if FEEPROMChip <> nil then
    FEEPROMChip.Reset;
end;

procedure TLynxCartridge.AddressData(Value: Boolean);
begin
  FData := Value;
end;

procedure TLynxCartridge.AddressStrobe(Value: Boolean);
begin
  if Value and not FStrobe then
    FShift := ((FShift shl 1) or Ord(FData)) and 255;
  FStrobe := Value;
  if Value then
    FCounter := 0;
  UpdateEEPROM;
end;

function TLynxCartridge.Read(Bank: Integer): Byte;
begin
  Result := $FF;
  if Length(FBanks[Bank]) > 0 then
    Result := FBanks[Bank][FShift * FPageSizes[Bank] + (FCounter and (FPageSizes[Bank] - 1))];
  if not FStrobe then
    FCounter := (FCounter + 1) and $7FF;
  UpdateEEPROM;
end;

procedure TLynxCartridge.Write(Bank: Integer; Value: Byte);
begin
  // Both cartridge strobes clock the same physical address counter.
  if not FStrobe then
    FCounter := (FCounter + 1) and $7FF;
  UpdateEEPROM;
end;

procedure TLynxCartridge.UpdateEEPROM;
begin
  if FEEPROMChip <> nil then
    FEEPROMChip.Lines(FCounter and $80 <> 0, FCounter and 2 <> 0, FAudin);
end;

procedure TLynxCartridge.SetAudin(Value: Boolean);
begin
  FAudin := Value;
  UpdateEEPROM;
end;

function TLynxCartridge.Audin: Boolean;
begin
  Result := (FEEPROMChip = nil) or FEEPROMChip.Output;
end;

function TLynxCartridge.Backup: TBytes;
begin
  Result := nil;
  if FEEPROMChip <> nil then
    Result := FEEPROMChip.Battery;
end;

procedure TLynxCartridge.LoadBackup(const Data: TBytes);
begin
  if FEEPROMChip <> nil then
    FEEPROMChip.LoadBattery(Data);
end;

function TLynxCartridge.BackupDirty: Boolean;
begin
  Result := (FEEPROMChip <> nil) and FEEPROMChip.Dirty;
end;

procedure TLynxCartridge.SerializeState(State: TStateArchive);
begin
  State.Field(FShift, SizeOf(FShift));
  State.Field(FCounter, SizeOf(FCounter));
  State.Field(FStrobe, SizeOf(FStrobe));
  State.Field(FData, SizeOf(FData));
  State.Field(FAudin, SizeOf(FAudin));
  if FEEPROMChip <> nil then
    FEEPROMChip.SerializeState(State);
  if State.Loading and ((FShift < 0) or (FShift > 255) or (FCounter < 0) or (FCounter > $7FF)) then
    raise EReadError.Create('Invalid Lynx cartridge state');
end;

end.

