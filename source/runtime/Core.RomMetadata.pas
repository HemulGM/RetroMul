unit Core.RomMetadata;

interface

uses
  System.JSON;

type
  // Shared by copied ROM records and cores. Published documents are immutable;
  // callers own the JSON returned by CloneJSON and may edit that copy freely.
  IRomMetadata = interface
    ['{D3AE8065-E474-482E-9D13-755F20F8DE65}']
    function ToJSON: string;
    function CloneJSON: TJSONObject;
    function GetString(const Section, Name: string; const Default: string = ''): string;
  end;

  TRomMetadata = class(TInterfacedObject, IRomMetadata)
  private
    FDocument: TJSONObject;
  public
    constructor Create(Document: TJSONObject);
    destructor Destroy; override;
    function ToJSON: string;
    function CloneJSON: TJSONObject;
    function GetString(const Section, Name: string; const Default: string = ''): string;
  end;

implementation

uses
  System.SysUtils;

constructor TRomMetadata.Create(Document: TJSONObject);
begin
  inherited Create;
  if Document = nil then
    raise EArgumentNilException.Create('ROM metadata');
  FDocument := Document.Clone as TJSONObject;
end;

destructor TRomMetadata.Destroy;
begin
  FDocument.Free;
  inherited;
end;

function TRomMetadata.ToJSON: string;
begin
  Result := FDocument.ToJSON;
end;

function TRomMetadata.CloneJSON: TJSONObject;
begin
  Result := FDocument.Clone as TJSONObject;
end;

function TRomMetadata.GetString(const Section, Name, Default: string): string;
begin
  Result := Default;
  var ObjectValue := FDocument;
  if Section <> '' then
  begin
    var Value := FDocument.GetValue(Section);
    if not (Value is TJSONObject) then
      Exit;
    ObjectValue := TJSONObject(Value);
  end;
  var Value := ObjectValue.GetValue(Name);
  if Value <> nil then
    Result := Value.Value;
end;

end.

