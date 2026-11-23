unit SWF.FLV.Script;

interface

uses
  System.SysUtils, System.Generics.Collections;

type
  TFLVScriptKind = (skUndefined, skNull, skNumber, skBoolean, skString, skObject, skArray, skDate, skReference);

  TFLVScriptValue = class
    Kind: TFLVScriptKind;
    Name, Text: string;
    Number: Double;
    Flag: Boolean;
    Children: TArray<TFLVScriptValue>;
    Reference: TFLVScriptValue;
  end;

  TFLVScriptData = class
  private
    FData: TBytes;
    FPosition: Integer;
    FValues: TObjectList<TFLVScriptValue>;
    FReferences: TList<TFLVScriptValue>;
    FEvents: TArray<TFLVScriptValue>;
    procedure Require(Count: Integer);
    function Unsigned(Count: Integer): UInt64;
    function ReadString(LengthBytes: Integer): string;
    function AtEndOfObject: Boolean;
    function ReadValue(Depth: Integer): TFLVScriptValue;
    function GetValueCount: Integer;
  public
    constructor Create(const Data: TBytes);
    destructor Destroy; override;
    property Events: TArray<TFLVScriptValue> read FEvents;
    property ValueCount: Integer read GetValueCount;

  end;

implementation

uses
  SWF.Reader;

const
  MaxScriptValues = 4096;
  MaxScriptDepth = 32;
  MaxScriptString = 1024 * 1024;

procedure TFLVScriptData.Require(Count: Integer);
begin
  if Count > Length(FData) - FPosition then
    raise ESWFError.Create('Truncated FLV script data');
end;

function TFLVScriptData.Unsigned(Count: Integer): UInt64;
var
  I: Integer;
begin
  Require(Count);
  Result := 0;
  for I := 1 to Count do
  begin
    Result := (Result shl 8) or FData[FPosition];
    Inc(FPosition);
  end;
end;

function TFLVScriptData.ReadString(LengthBytes: Integer): string;
var
  Count: UInt64;
begin
  Count := Unsigned(LengthBytes);
  if Count > MaxScriptString then
    raise ESWFError.Create('FLV script string limit');
  Require(Integer(Count));
  try
    if Count = 0 then
      Result := ''
    else
      Result := TEncoding.UTF8.GetString(FData, FPosition, Integer(Count));
  except
    on E: EEncodingError do
      raise ESWFError.Create('Invalid UTF-8 in FLV script data');
  end;
  Inc(FPosition, Integer(Count));
end;

function TFLVScriptData.AtEndOfObject: Boolean;
begin
  Require(3);
  Result := (FData[FPosition] = 0) and (FData[FPosition + 1] = 0) and (FData[FPosition + 2] = 9);
  if Result then
    Inc(FPosition, 3);
end;

function TFLVScriptData.ReadValue(Depth: Integer): TFLVScriptValue;
var
  Marker: Byte;
  Index, Count: UInt64;
  Children: TList<TFLVScriptValue>;
  Name: string;
  Child: TFLVScriptValue;

  procedure ReadNumber;
  var
    Bits: UInt64;
  begin
    Bits := Unsigned(8);
    Move(Bits, Result.Number, SizeOf(Bits));
  end;

begin
  if (Depth > MaxScriptDepth) or (FValues.Count >= MaxScriptValues) then
    raise ESWFError.Create('FLV script value limit');
  Marker := Byte(Unsigned(1));
  Result := TFLVScriptValue.Create;
  FValues.Add(Result);
  case Marker of
    0:
      begin
        Result.Kind := skNumber;
        ReadNumber;
      end;
    1:
      begin
        Result.Kind := skBoolean;
        Result.Flag := Unsigned(1) <> 0;
      end;
    2, 12:
      begin
        Result.Kind := skString;
        if Marker = 2 then
          Result.Text := ReadString(2)
        else
          Result.Text := ReadString(4);
      end;
    3, 8, 10:
      begin
        FReferences.Add(Result);
        if Marker = 10 then
        begin
          Result.Kind := skArray;
          Count := Unsigned(4);
          if Count > UInt64(MaxScriptValues - FValues.Count) then
            raise ESWFError.Create('FLV script array limit');
          SetLength(Result.Children, Integer(Count));
          for var I := 0 to High(Result.Children) do
            Result.Children[I] := ReadValue(Depth + 1);
        end
        else
        begin
          Result.Kind := skObject;
          if Marker = 8 then
            Unsigned(4);
          Children := TList<TFLVScriptValue>.Create;
          try
            while not AtEndOfObject do
            begin
              Name := ReadString(2);
              Child := ReadValue(Depth + 1);
              Child.Name := Name;
              Children.Add(Child);
            end;
            Result.Children := Children.ToArray;
          finally
            Children.Free;
          end;
        end;
      end;
    4:
      ReadString(2);
    5:
      Result.Kind := skNull;
    6:
      Result.Kind := skUndefined;
    7:
      begin
        Index := Unsigned(2);
        if Index >= UInt64(FReferences.Count) then
          raise ESWFError.Create('Invalid FLV script reference');
        Result.Kind := skReference;
        Result.Reference := FReferences[Integer(Index)];
      end;
    11:
      begin
        Result.Kind := skDate;
        ReadNumber;
        Unsigned(2);
      end;
  else
    raise ESWFError.CreateFmt('Unknown FLV script value %d', [Marker]);
  end;
end;

constructor TFLVScriptData.Create(const Data: TBytes);
var
  Items: TList<TFLVScriptValue>;
  Name: string;
  Value: TFLVScriptValue;
begin
  inherited Create;
  FData := Data;
  FValues := TObjectList<TFLVScriptValue>.Create(True);
  FReferences := TList<TFLVScriptValue>.Create;
  Items := TList<TFLVScriptValue>.Create;
  try
    while FPosition < Length(FData) do
    begin
      if AtEndOfObject then
        Break;
      if Items.Count >= 128 then
        raise ESWFError.Create('FLV script event limit');
      if Unsigned(1) <> 2 then
        raise ESWFError.Create('Invalid FLV script event name');
      Name := ReadString(2);
      Value := ReadValue(0);
      Value.Name := Name;
      Items.Add(Value);
    end;
    FEvents := Items.ToArray;
  finally
    Items.Free;
  end;
end;

function TFLVScriptData.GetValueCount: Integer;
begin
  Result := FValues.Count;
end;

destructor TFLVScriptData.Destroy;
begin
  FReferences.Free;
  FValues.Free;
  inherited;
end;

end.

