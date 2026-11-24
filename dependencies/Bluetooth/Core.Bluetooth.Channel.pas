unit Core.Bluetooth.Channel;

interface

uses
  Core.Bluetooth.Types;

// Explicit in-process endpoints for virtual adapters and conformance tests.
// They never claim to be physical radio links or provide link encryption.
procedure CreateBluetoothChannelPair(Transport: TBluetoothTransport; Capacity, MTU: Integer; out First, Second: IBluetoothChannel);

implementation

uses
  System.SysUtils, System.SyncObjs, System.Math, System.Generics.Collections;

type
  IBluetoothPipe = interface
    ['{379DA778-7246-4EB5-92F1-B3FE48D23D7E}']
    function Info: TBluetoothChannelInfo;
    function Transfer(Side: Integer; Reading: Boolean; var Buffer: TBytes; Offset, Count: Integer): TBluetoothTransfer;
    procedure Close(Side: Integer);
  end;

  TBluetoothPipe = class(TInterfacedObject, IBluetoothPipe)
  private
    FLock: TCriticalSection;
    FTransport: TBluetoothTransport;
    FCapacity, FMTU: Integer;
    FClosed: array[0..1] of Boolean;
    FBytes: array[0..1] of TBytes;
    FHead, FCount: array[0..1] of Integer;
    FPackets: array[0..1] of TQueue<TBytes>;
  public
    constructor Create(Transport: TBluetoothTransport; Capacity, MTU: Integer);
    destructor Destroy; override;
    function Info: TBluetoothChannelInfo;
    function Transfer(Side: Integer; Reading: Boolean; var Buffer: TBytes; Offset, Count: Integer): TBluetoothTransfer;
    procedure Close(Side: Integer);
  end;

  TBluetoothChannel = class(TInterfacedObject, IBluetoothChannel)
  private
    FPipe: IBluetoothPipe;
    FSide: Integer;
  public
    constructor Create(const Pipe: IBluetoothPipe; Side: Integer);
    destructor Destroy; override;
    function Info: TBluetoothChannelInfo;
    function Read(var Buffer: TBytes; Offset, Count: Integer): TBluetoothTransfer;
    function Write(const Buffer: TBytes; Offset, Count: Integer): TBluetoothTransfer;
    procedure Close;
  end;

constructor TBluetoothPipe.Create(Transport: TBluetoothTransport; Capacity, MTU: Integer);
begin
  inherited Create;
  if (Capacity < 1) or (Capacity > 1024 * 1024) then
    raise EArgumentOutOfRangeException.Create('Bluetooth queue capacity');
  if (Transport = TBluetoothTransport.L2CAP) and ((MTU < 48) or (MTU > 65535) or (Capacity < MTU)) then
    raise EArgumentOutOfRangeException.Create('Bluetooth classic L2CAP MTU');
  FTransport := Transport;
  FCapacity := Capacity;
  if Transport = TBluetoothTransport.L2CAP then
    FMTU := MTU;
  FLock := TCriticalSection.Create;
  for var Side := 0 to 1 do
  begin
    if Transport = TBluetoothTransport.RFCOMM then
      SetLength(FBytes[Side], Capacity)
    else
      FPackets[Side] := TQueue<TBytes>.Create;
  end;
end;

destructor TBluetoothPipe.Destroy;
begin
  FPackets[0].Free;
  FPackets[1].Free;
  FLock.Free;
  inherited;
end;

function TBluetoothPipe.Info: TBluetoothChannelInfo;
begin
  Result := Default(TBluetoothChannelInfo);
  Result.Endpoint.Transport := FTransport;
  Result.ReceiveMTU := FMTU;
  Result.TransmitMTU := FMTU;
end;

function TBluetoothPipe.Transfer(Side: Integer; Reading: Boolean; var Buffer: TBytes; Offset, Count: Integer): TBluetoothTransfer;
begin
  if (Offset < 0) or (Count < 0) or (Offset > Length(Buffer)) or (Count > Length(Buffer) - Offset) then
    raise EArgumentOutOfRangeException.Create('Bluetooth buffer range');
  Result := Default(TBluetoothTransfer);
  Result.State := TBluetoothIOState.Ready;
  FLock.Acquire;
  try
    var Peer := 1 - Side;
    if FClosed[Side] or (not Reading and FClosed[Peer]) then
    begin
      Result.State := TBluetoothIOState.Closed;
      Exit;
    end;
    if Reading then
    begin
      if Count = 0 then
        Exit;
      var Empty := FCount[Side] = 0;
      if FTransport = TBluetoothTransport.L2CAP then
        Empty := FPackets[Side].Count = 0;
      if Empty then
      begin
        Result.State := TBluetoothIOState.WouldBlock;
        if FClosed[Peer] then
          Result.State := TBluetoothIOState.EndOfStream;
        Exit;
      end;
      if FTransport = TBluetoothTransport.RFCOMM then
      begin
        Result.Count := Min(Count, FCount[Side]);
        for var I := 0 to Result.Count - 1 do
          Buffer[Offset + I] := FBytes[Side][(FHead[Side] + I) mod FCapacity];
        FHead[Side] := (FHead[Side] + Result.Count) mod FCapacity;
        Dec(FCount[Side], Result.Count);
      end
      else
      begin
        var Packet := FPackets[Side].Dequeue;
        Result.PacketLength := Length(Packet);
        Result.Count := Min(Count, Length(Packet));
        if Result.Count > 0 then
          Move(Packet[0], Buffer[Offset], Result.Count);
        Dec(FCount[Side], Length(Packet));
      end;
    end
    else
    begin
      if FTransport = TBluetoothTransport.L2CAP then
      begin
        if Count > FMTU then
        begin
          Result.State := TBluetoothIOState.Failed;
          Result.Error.Code := TBluetoothErrorCode.InvalidArgument;
          Result.Error.MessageText := 'Packet exceeds negotiated MTU';
          Exit;
        end;
        if (Count > FCapacity - FCount[Peer]) or (FPackets[Peer].Count >= 64) then
        begin
          Result.State := TBluetoothIOState.WouldBlock;
          Exit;
        end;
        var Packet := Copy(Buffer, Offset, Count);
        FPackets[Peer].Enqueue(Packet);
        Inc(FCount[Peer], Count);
        Result.Count := Count;
        Result.PacketLength := Count;
      end
      else
      begin
        Result.Count := Min(Count, FCapacity - FCount[Peer]);
        if (Count > 0) and (Result.Count = 0) then
        begin
          Result.State := TBluetoothIOState.WouldBlock;
          Exit;
        end;
        for var I := 0 to Result.Count - 1 do
          FBytes[Peer][(FHead[Peer] + FCount[Peer] + I) mod FCapacity] := Buffer[Offset + I];
        Inc(FCount[Peer], Result.Count);
      end;
    end;
  finally
    FLock.Release;
  end;
end;

procedure TBluetoothPipe.Close(Side: Integer);
begin
  FLock.Acquire;
  try
    FClosed[Side] := True;
    FCount[Side] := 0;
    if FPackets[Side] <> nil then
      FPackets[Side].Clear;
  finally
    FLock.Release;
  end;
end;

constructor TBluetoothChannel.Create(const Pipe: IBluetoothPipe; Side: Integer);
begin
  inherited Create;
  FPipe := Pipe;
  FSide := Side;
end;

destructor TBluetoothChannel.Destroy;
begin
  if FPipe <> nil then
    Close;
  inherited;
end;

function TBluetoothChannel.Info: TBluetoothChannelInfo;
begin
  Result := FPipe.Info;
end;

function TBluetoothChannel.Read(var Buffer: TBytes; Offset, Count: Integer): TBluetoothTransfer;
begin
  Result := FPipe.Transfer(FSide, True, Buffer, Offset, Count);
end;

function TBluetoothChannel.Write(const Buffer: TBytes; Offset, Count: Integer): TBluetoothTransfer;
begin
  // Transfer never modifies a write buffer. This local reference allows the
  // common range/queue code to share one implementation without copying data.
  var Input := Buffer;
  Result := FPipe.Transfer(FSide, False, Input, Offset, Count);
end;

procedure TBluetoothChannel.Close;
begin
  FPipe.Close(FSide);
end;

procedure CreateBluetoothChannelPair(Transport: TBluetoothTransport; Capacity, MTU: Integer; out First, Second: IBluetoothChannel);
begin
  First := nil;
  Second := nil;
  var Pipe: IBluetoothPipe := TBluetoothPipe.Create(Transport, Capacity, MTU);
  var A: IBluetoothChannel := TBluetoothChannel.Create(Pipe, 0);
  var B: IBluetoothChannel := TBluetoothChannel.Create(Pipe, 1);
  First := A;
  Second := B;
end;

end.

