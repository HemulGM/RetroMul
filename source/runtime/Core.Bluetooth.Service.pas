unit Core.Bluetooth.Service;

interface

uses
  System.SysUtils, Core.Bluetooth.Types;

procedure BindBluetoothService(var Service: TBluetoothService; const Endpoint: TBluetoothEndpoint);

function EncodeBluetoothService(const Service: TBluetoothService): TBytes;

function DecodeBluetoothService(const Data: TBytes; const Device: TBluetoothAddress): TBluetoothService;

function BluetoothServiceMatches(const Service: TBluetoothService; const UUIDs: TArray<TBluetoothUUID>): Boolean;

function SelectBluetoothAttributes(const Service: TBluetoothService; const IDs: TArray<Word>): TBluetoothService;

function CopyBluetoothService(const Service: TBluetoothService): TBluetoothService;

implementation

uses
  System.Generics.Collections, Core.Bluetooth.SDP;

procedure BindBluetoothService(var Service: TBluetoothService; const Endpoint: TBluetoothEndpoint);

  procedure Put(ID: Word; E: TBluetoothSDPElement; Replace: Boolean = False);
  begin
    try
      for var I := 0 to High(Service.Attributes) do
        if Service.Attributes[I].ID = ID then
        begin
          if Replace then
            Service.Attributes[I].Data := EncodeBluetoothSDP(E);
          Exit;
        end;
      var A: TBluetoothAttribute;
      A.ID := ID;
      A.Data := EncodeBluetoothSDP(E);
      Service.Attributes := Service.Attributes + [A];
    finally
      E.Free;
    end;
  end;

  function Scalar(Kind: TBluetoothSDPKind; const Data: TBytes): TBluetoothSDPElement;
  begin
    Result := TBluetoothSDPElement.Create(Kind);
    Result.Data := Data;
  end;

begin
  Service := CopyBluetoothService(Service);
  Service.Endpoint := Endpoint;
  var Root := TBluetoothSDPElement.Create(TBluetoothSDPKind.Sequence);
  var U := Endpoint.Service.ToString;
  var Bytes: TBytes;
  SetLength(Bytes, 16);
  for var I := 0 to 15 do
    Bytes[I] := StrToInt('$' + Copy(U, I * 2 + 1, 2));
  Root.Children.Add(Scalar(TBluetoothSDPKind.UUID, Bytes));
  Put(1, Root);
  Root := TBluetoothSDPElement.Create(TBluetoothSDPKind.Sequence);
  var L := TBluetoothSDPElement.Create(TBluetoothSDPKind.Sequence);
  Root.Children.Add(L);
  L.Children.Add(Scalar(TBluetoothSDPKind.UUID, TBytes.Create(1, 0)));
  if Endpoint.Transport = TBluetoothTransport.RFCOMM then
  begin
    L := TBluetoothSDPElement.Create(TBluetoothSDPKind.Sequence);
    Root.Children.Add(L);
    L.Children.Add(Scalar(TBluetoothSDPKind.UUID, TBytes.Create(0, 3)));
    L.Children.Add(Scalar(TBluetoothSDPKind.UnsignedInteger, TBytes.Create(Byte(Endpoint.Channel))));
  end
  else
    L.Children.Add(Scalar(TBluetoothSDPKind.UnsignedInteger, TBytes.Create(Byte(Endpoint.Channel shr 8), Byte(Endpoint.Channel))));
  Put(4, Root, True);
  Root := TBluetoothSDPElement.Create(TBluetoothSDPKind.Sequence);
  Root.Children.Add(Scalar(TBluetoothSDPKind.UUID, TBytes.Create($10, 2)));
  Put(5, Root);
  if Service.Name <> '' then
    Put($100, Scalar(TBluetoothSDPKind.TextString, TEncoding.UTF8.GetBytes(Service.Name)));
end;

function CopyBluetoothService(const Service: TBluetoothService): TBluetoothService;
begin
  Result := Service;
  Result.UUIDs := Copy(Service.UUIDs);
  Result.Attributes := Copy(Service.Attributes);
  for var I := 0 to High(Result.Attributes) do
    Result.Attributes[I].Data := Copy(Service.Attributes[I].Data);
end;

function UUID(E: TBluetoothSDPElement): TBluetoothUUID;
begin
  if E.Kind <> TBluetoothSDPKind.UUID then
    raise EBluetoothSDP.Create('Expected service UUID');
  var S := '';
  for var B in E.Data do
    S := S + IntToHex(B, 2);
  if not TBluetoothUUID.TryParse(S, Result) then
    raise EBluetoothSDP.Create('Invalid service UUID');
end;

function Unsigned(E: TBluetoothSDPElement; MaxBytes: Integer): UInt32;
begin
  if (E.Kind <> TBluetoothSDPKind.UnsignedInteger) or (Length(E.Data) > MaxBytes) then
    raise EBluetoothSDP.Create('Invalid SDP integer');
  Result := 0;
  for var B in E.Data do
    Result := (Result shl 8) or B;
end;

function EncodeBluetoothService(const Service: TBluetoothService): TBytes;
begin
  if Length(Service.Attributes) > 256 then
    raise EBluetoothSDP.Create('Service attribute capacity');
  // Reject aggregate input before decoding/cloning individual attribute trees.
  var Total: Int64 := 0;
  for var A in Service.Attributes do
  begin
    Inc(Total, Length(A.Data));
    if Total > BLUETOOTH_SDP_MAX_BYTES then
      raise EBluetoothSDP.Create('Service record byte capacity');
  end;
  var Sorted := TList<TBluetoothAttribute>.Create;
  var Root := TBluetoothSDPElement.Create(TBluetoothSDPKind.Sequence);
  try
    for var A in Service.Attributes do
    begin
      var I := 0;
      while (I < Sorted.Count) and (Sorted[I].ID < A.ID) do
        Inc(I);
      if (I < Sorted.Count) and (Sorted[I].ID = A.ID) then
        raise EBluetoothSDP.Create('Duplicate service attribute');
      Sorted.Insert(I, A);
    end;
    for var A in Sorted do
    begin
      var ID := TBluetoothSDPElement.Create(TBluetoothSDPKind.UnsignedInteger);
      ID.Data := TBytes.Create(Byte(A.ID shr 8), Byte(A.ID));
      Root.Children.Add(ID);
      Root.Children.Add(DecodeBluetoothSDP(A.Data));
    end;
    Result := EncodeBluetoothSDP(Root);
  finally
    Root.Free;
    Sorted.Free;
  end;
end;

function DecodeBluetoothService(const Data: TBytes; const Device: TBluetoothAddress): TBluetoothService;
var
  Seen: TDictionary<string, Byte>;
  Root: TBluetoothSDPElement;

  procedure UUIDs(E: TBluetoothSDPElement);
  begin
    if E.Kind = TBluetoothSDPKind.UUID then
    begin
      var U := UUID(E);
      var Key := U.ToString;
      if not Seen.ContainsKey(Key) then
      begin
        Seen.Add(Key, 0);
        Result.UUIDs := Result.UUIDs + [U];
      end;
    end;
    for var C in E.Children do
      UUIDs(C);
  end;

begin
  Result := Default(TBluetoothService);
  Result.Endpoint.Device := Device;
  Root := DecodeBluetoothSDP(Data);
  Seen := TDictionary<string, Byte>.Create;
  try
    if (Root.Kind <> TBluetoothSDPKind.Sequence) or ((Root.Children.Count and 1) <> 0) or (Root.Children.Count > 512) then
      raise EBluetoothSDP.Create('Invalid service record sequence');
    var IDs := TDictionary<Word, Byte>.Create;
    try
      for var I := 0 to Root.Children.Count div 2 - 1 do
      begin
        var IDValue := Root.Children[I * 2];
        if (IDValue.Kind <> TBluetoothSDPKind.UnsignedInteger) or (Length(IDValue.Data) <> 2) then
          raise EBluetoothSDP.Create('Invalid attribute ID');
        var ID := Word(Unsigned(IDValue, 2));
        if IDs.ContainsKey(ID) then
          raise EBluetoothSDP.Create('Duplicate service attribute');
        IDs.Add(ID, 0);
        var Value := Root.Children[I * 2 + 1];
        var A: TBluetoothAttribute;
        A.ID := ID;
        A.Data := EncodeBluetoothSDP(Value);
        Result.Attributes := Result.Attributes + [A];
        UUIDs(Value);
        if (ID = $100) and (Value.Kind = TBluetoothSDPKind.TextString) then
          Result.Name := TEncoding.UTF8.GetString(Value.Data);
        if ID = 1 then
        begin
          if (Value.Kind <> TBluetoothSDPKind.Sequence) or (Value.Children.Count = 0) then
            raise EBluetoothSDP.Create('Invalid ServiceClassIDList');
          Result.Endpoint.Service := UUID(Value.Children[0]);
          for var C in Value.Children do
            UUID(C);
        end;
        if ID = 4 then
        begin
          if Value.Kind <> TBluetoothSDPKind.Sequence then
            raise EBluetoothSDP.Create('Invalid ProtocolDescriptorList');
          for var Protocol in Value.Children do
          begin
            if (Protocol.Kind <> TBluetoothSDPKind.Sequence) or (Protocol.Children.Count = 0) then
              raise EBluetoothSDP.Create('Invalid protocol descriptor');
            var U := UUID(Protocol.Children[0]).ToString;
            if (U = '0000010000001000800000805F9B34FB') and (Protocol.Children.Count > 1) then
            begin
              Result.Endpoint.Transport := TBluetoothTransport.L2CAP;
              Result.Endpoint.Channel := Unsigned(Protocol.Children[1], 2);
            end;
            if U = '0000000300001000800000805F9B34FB' then
            begin
              if Protocol.Children.Count < 2 then
                raise EBluetoothSDP.Create('Missing RFCOMM channel');
              Result.Endpoint.Transport := TBluetoothTransport.RFCOMM;
              Result.Endpoint.Channel := Unsigned(Protocol.Children[1], 1);
              if not (Result.Endpoint.Channel in [1..30]) then
                raise EBluetoothSDP.Create('Invalid RFCOMM channel');
            end;
          end;
        end;
      end;
    finally
      IDs.Free;
    end;
  finally
    Seen.Free;
    Root.Free;
  end;
end;

function BluetoothServiceMatches(const Service: TBluetoothService; const UUIDs: TArray<TBluetoothUUID>): Boolean;
begin
  for var U in UUIDs do
  begin
    var Found := False;
    for var Existing in Service.UUIDs do
      if Existing.ToString = U.ToString then
      begin
        Found := True;
        Break;
      end;
    if not Found then
      Exit(False);
  end;
  Result := True;
end;

function SelectBluetoothAttributes(const Service: TBluetoothService; const IDs: TArray<Word>): TBluetoothService;
begin
  Result := Service;
  Result.UUIDs := Copy(Service.UUIDs);
  Result.Attributes := nil;
  for var A in Service.Attributes do
    for var ID in IDs do
      if A.ID = ID then
      begin
        var B := A;
        B.Data := Copy(A.Data);
        Result.Attributes := Result.Attributes + [B];
        Break;
      end;
end;

end.

