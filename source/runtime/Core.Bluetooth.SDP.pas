unit Core.Bluetooth.SDP;

interface

uses
  System.SysUtils, System.Generics.Collections;

type
  EBluetoothSDP = class(EArgumentException);

  TBluetoothSDPKind = (NilValue, UnsignedInteger, SignedInteger, UUID, TextString, BooleanValue, Sequence, Alternative, URL);

  TBluetoothSDPElement = class
  public
    Kind: TBluetoothSDPKind;
    Data: TBytes; // Big-endian scalar or UTF-8/text bytes, exactly as transmitted.
    Children: TObjectList<TBluetoothSDPElement>; // Exclusive ownership, no cycles.
    constructor Create(Kind: TBluetoothSDPKind);
    destructor Destroy; override;
  end;

function DecodeBluetoothSDP(const Data: TBytes): TBluetoothSDPElement;

function EncodeBluetoothSDP(Element: TBluetoothSDPElement): TBytes;

const
  BLUETOOTH_SDP_MAX_BYTES = 1024 * 1024;
  BLUETOOTH_SDP_MAX_DEPTH = 32;
  BLUETOOTH_SDP_MAX_NODES = 65536;

implementation

uses
  System.Classes;

constructor TBluetoothSDPElement.Create(Kind: TBluetoothSDPKind);
begin
  inherited Create;
  Self.Kind := Kind;
  Children := TObjectList<TBluetoothSDPElement>.Create(True);
end;

destructor TBluetoothSDPElement.Destroy;
begin
  Children.Free;
  inherited;
end;

procedure Invalid;
begin
  raise EBluetoothSDP.Create('Invalid or excessive Bluetooth SDP data element');
end;

function DecodeBluetoothSDP(const Data: TBytes): TBluetoothSDPElement;
var
  Position, Nodes: Integer;

  function Read(EndPosition: Integer): Byte;
  begin
    if Position >= EndPosition then
      Invalid;
    Result := Data[Position];
    Inc(Position);
  end;

  function Parse(EndPosition, Depth: Integer): TBluetoothSDPElement;
  var
    Size: UInt64;
    Index, Kind, SizeIndex: Integer;
  begin
    if (Depth > BLUETOOTH_SDP_MAX_DEPTH) or (Nodes >= BLUETOOTH_SDP_MAX_NODES) then
      Invalid;
    Inc(Nodes);
    var Header := Read(EndPosition);
    Kind := Header shr 3;
    SizeIndex := Header and 7;
    if Kind > 8 then
      Invalid;
    if SizeIndex <= 4 then
      Size := UInt64(1) shl SizeIndex
    else
    begin
      Size := 0;
      for var I := 1 to (1 shl (SizeIndex - 5)) do
        Size := (Size shl 8) or Read(EndPosition);
    end;
    case Kind of
      0:
        begin
          if SizeIndex <> 0 then
            Invalid;
          Size := 0;
        end;
      1, 2:
        if SizeIndex > 4 then
          Invalid;
      3:
        if not (SizeIndex in [1, 2, 4]) then
          Invalid;
      5:
        if SizeIndex <> 0 then
          Invalid;
      4, 6, 7, 8:
        if SizeIndex < 5 then
          Invalid;
    end;
    if Size > UInt64(EndPosition - Position) then
      Invalid;
    Index := Position + Integer(Size);
    Result := TBluetoothSDPElement.Create(TBluetoothSDPKind(Kind));
    try
      if Kind in [6, 7] then
        while Position < Index do
          Result.Children.Add(Parse(Index, Depth + 1))
      else
      begin
        Result.Data := Copy(Data, Position, Integer(Size));
        Position := Index;
      end;
      if (Kind = 5) and (Result.Data[0] > 1) then
        Invalid;
    except
      Result.Free;
      raise;
    end;
  end;

begin
  if Length(Data) > BLUETOOTH_SDP_MAX_BYTES then
    Invalid;
  Position := 0;
  Nodes := 0;
  Result := Parse(Length(Data), 0);
  if Position <> Length(Data) then
  begin
    Result.Free;
    Invalid;
  end;
end;

function EncodeBluetoothSDP(Element: TBluetoothSDPElement): TBytes;
var
  Output: TMemoryStream;
  Active: TDictionary<TBluetoothSDPElement, Byte>;
  Nodes: Integer;

  procedure ByteValue(Value: Byte);
  begin
    if Output.Size >= BLUETOOTH_SDP_MAX_BYTES then
      Invalid;
    Output.WriteBuffer(Value, 1);
  end;

  procedure Emit(E: TBluetoothSDPElement; Depth: Integer);
  var
    Size, SizeIndex, Header, LengthBytes: Integer;
    Start, Finish: Int64;
  begin
    if (E = nil) or (Depth > BLUETOOTH_SDP_MAX_DEPTH) or (Nodes >= BLUETOOTH_SDP_MAX_NODES) or Active.ContainsKey(E) then
      Invalid;
    Inc(Nodes);
    Active.Add(E, 0);
    try
      Size := Length(E.Data);
      Header := Ord(E.Kind) shl 3;
      SizeIndex := -1;
      if E.Kind in [TBluetoothSDPKind.Sequence, TBluetoothSDPKind.Alternative] then
      begin
        if Size <> 0 then
          Invalid;
        // Reserve a 32-bit length. Sequences use a legal canonical size encoding
        // independent of the original input's 8/16/32-bit length choice.
        ByteValue(Header or 7);
        for var I := 1 to 4 do
          ByteValue(0);
        Start := Output.Position;
        for var Child in E.Children do
          Emit(Child, Depth + 1);
        Finish := Output.Position;
        Size := Integer(Finish - Start);
        Output.Position := Start - 4;
        for var I := 3 downto 0 do
        begin
          var B := Byte(UInt32(Size) shr (I * 8));
          Output.WriteBuffer(B, 1);
        end;
        Output.Position := Finish;
        Exit;
      end;
      if E.Children.Count <> 0 then
        Invalid;
      case E.Kind of
        TBluetoothSDPKind.NilValue:
          begin
            if Size <> 0 then
              Invalid;
            SizeIndex := 0;
          end;
        TBluetoothSDPKind.UnsignedInteger, TBluetoothSDPKind.SignedInteger:
          begin
            case Size of
              1:
                SizeIndex := 0;
              2:
                SizeIndex := 1;
              4:
                SizeIndex := 2;
              8:
                SizeIndex := 3;
              16:
                SizeIndex := 4;
            else
              Invalid;
            end;
          end;
        TBluetoothSDPKind.UUID:
          begin
            case Size of
              2:
                SizeIndex := 1;
              4:
                SizeIndex := 2;
              16:
                SizeIndex := 4;
            else
              Invalid;
            end;
          end;
        TBluetoothSDPKind.BooleanValue:
          begin
            if (Size <> 1) or (E.Data[0] > 1) then
              Invalid;
            SizeIndex := 0;
          end;
        TBluetoothSDPKind.TextString, TBluetoothSDPKind.URL:
          begin
            LengthBytes := 1;
            SizeIndex := 5;
            if Size > 255 then
            begin
              LengthBytes := 2;
              SizeIndex := 6;
            end;
            if Size > 65535 then
            begin
              LengthBytes := 4;
              SizeIndex := 7;
            end;
            ByteValue(Header or SizeIndex);
            for var I := LengthBytes - 1 downto 0 do
              ByteValue(Byte(UInt32(Size) shr (I * 8)));
            SizeIndex := -1;
          end;
      else
        Invalid;
      end;
      if SizeIndex >= 0 then
        ByteValue(Header or SizeIndex);
      if Size > BLUETOOTH_SDP_MAX_BYTES - Output.Size then
        Invalid;
      if Size > 0 then
        Output.WriteBuffer(E.Data[0], Size);
    finally
      Active.Remove(E);
    end;
  end;

begin
  Output := TMemoryStream.Create;
  Active := TDictionary<TBluetoothSDPElement, Byte>.Create;
  try
    Nodes := 0;
    Emit(Element, 0);
    SetLength(Result, Output.Size);
    if Length(Result) > 0 then
      Move(Output.Memory^, Result[0], Length(Result));
  finally
    Active.Free;
    Output.Free;
  end;
end;

end.

