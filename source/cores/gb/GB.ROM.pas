unit GB.ROM;

interface

uses
  System.Classes, System.SysUtils, GB.Cartridge;

type
  TCartridgeType = GB.Cartridge.TCartridgeType;

  TGBROM = class
  private
    FCartridge: TGBCartridge;
  public
    ROMData: TArray<Byte>;
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
  var DataSize: Int64 := Stream.Size;
  if (DataSize < $8000) or (DataSize > 8 * 1024 * 1024) or
    (DataSize mod $4000 <> 0) then
    raise EGBInvalidROM.CreateFmt('Invalid ROM length: %d bytes.', [DataSize]);
  Stream.Position := 0;
  var Data: TBytes;
  SetLength(Data, Integer(DataSize));
  Stream.ReadBuffer(Data[0], Length(Data));
  var ParsedCartridge: TGBCartridge := TGBCartridge.Create(Data);
  // Commit only after the whole stream and header have been read successfully.
  FCartridge.Free;
  FCartridge := ParsedCartridge;
  ROMData := Data;
end;

end.

