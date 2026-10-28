unit GB.ROM;

interface

uses
  System.Classes, System.SysUtils, GB.Cartridge, GB.RomFormat;

type
  TCartridgeType = GB.Cartridge.TCartridgeType;

  TGBROM = class
  private
    FCartridge: TGBCartridge;
  public
    ROMData: TArray<Byte>;
    // Preserve authoritative GBX metadata when the adapter recreates a worker.
    ImageData: TArray<Byte>;
    destructor Destroy; override;
    procedure ReadROM(Stream: TStream);
    function GetTitle: string;
    function GetRAMSize: string;
    function GetROMSize: string;
    function GetLocation: string;
    function GetCartridgeType: TCartridgeType;
    // Owned by this ROM; replaced after each successful ReadROM.
    property Cartridge: TGBCartridge read FCartridge;
  end;

implementation

uses
  Core.Storage;

function SizeDescription(Bytes: Integer): string;
begin
  case Bytes of
    -1:
      Result := 'Unknown';
    0:
      Result := 'None';
  else
    Result := IntToStr(Bytes div 1024) + 'KB';
  end;
end;

destructor TGBROM.Destroy;
begin
  FCartridge.Free;
  inherited;
end;

function TGBROM.GetCartridgeType: TCartridgeType;
begin
  if FCartridge <> nil then
    Result := FCartridge.CartridgeType
  else
  begin
    Result := Default(TCartridgeType);
    Result.ID := -1;
    Result.Name := 'Unknown';
    Result.MapperType := TMapperType.Unknown;
  end;
end;

function TGBROM.GetRAMSize: string;
begin
  Result := 'Unknown';
  if FCartridge <> nil then
    Result := SizeDescription(FCartridge.RAMSizeBytes);
end;

function TGBROM.GetROMSize: string;
begin
  Result := 'Unknown';
  if FCartridge <> nil then
    Result := SizeDescription(FCartridge.ROMSizeBytes);
end;

function TGBROM.GetTitle: string;
begin
  Result := '';
  if FCartridge <> nil then
    Result := FCartridge.Title;
end;

function TGBROM.GetLocation: string;
begin
  Result := 'Unknown';
  if FCartridge <> nil then
    case FCartridge.Destination of
      TCartridgeRegion.Japanese:
        Result := 'Japan';
      TCartridgeRegion.World:
        Result := 'World';
    end;
end;

procedure TGBROM.ReadROM(Stream: TStream);
begin
  if Stream = nil then
    raise EArgumentNilException.Create('ROM stream must not be nil.');

  var Image := ReadRomData(Stream);
  var Footer := ReadGBXFooter(Image);
  var Data := Image;
  if Footer.Present then
    Data := Copy(Image, 0, Footer.ROMSize);
  var DataSize: Int64 := Length(Data);
  var MinimumSize := GB_ROM_MIN_SIZE;
  if Footer.Present then
    MinimumSize := GB_ROM_BANK_SIZE;
  if (DataSize < MinimumSize) or (DataSize > GB_ROM_MAX_SIZE) or (DataSize mod GB_ROM_BANK_SIZE <> 0) then
    raise EGBInvalidROM.CreateFmt('Invalid ROM length: %d bytes.', [DataSize]);

  var HeaderOffset := 0;
  var MenuOffset := Length(Data) - $8000;

  // Native MMM01 dumps boot from the last two banks. Older dumpers put the
  // menu first; rotate those dumps once, before creating the cartridge.
  if (MenuOffset >= 0) and ((not Footer.Present and (Data[MenuOffset + $147] in [$0B..$0D])) or
    (Footer.Present and (Footer.Mapper = 'MMM1'))) and
    CompareMem(@Data[MenuOffset + $104], @GB_ROM_LOGO[0], SizeOf(GB_ROM_LOGO)) then
    HeaderOffset := MenuOffset
  else if (MenuOffset >= 0) and (Data[$147] in [$0B..$0D]) and (not Footer.Present or (Footer.Mapper = 'MMM1')) then
  begin
    var Menu := Copy(Data, 0, $8000);
    if MenuOffset > 0 then
      Move(Data[$8000], Data[0], MenuOffset);
    Move(Menu[0], Data[MenuOffset], $8000);
    HeaderOffset := MenuOffset;
  end;

  if Footer.Present and (Footer.Mapper = 'MMM1') then
    HeaderOffset := MenuOffset;

  var ParsedCartridge: TGBCartridge := TGBCartridge.Create(Data, HeaderOffset);
  try
    ParsedCartridge.ApplyGBX(Footer);
  except
    ParsedCartridge.Free;
    raise;
  end;

  // Commit only after the whole stream and header have been read successfully.
  FCartridge.Free;
  FCartridge := ParsedCartridge;
  ROMData := Data;
  ImageData := Data;
  if Footer.Present then
  begin
    ImageData := Copy(Image);
    Move(Data[0], ImageData[0], Length(Data));
  end;
end;

end.

