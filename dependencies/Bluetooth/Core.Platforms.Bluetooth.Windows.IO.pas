unit Core.Platforms.Bluetooth.Windows.IO;

interface

uses
  Core.Bluetooth.Types;

function AdoptOverlappedBluetoothSocket(Socket: NativeUInt; const Info: TBluetoothChannelInfo): IBluetoothChannel;

implementation

uses
  System.SysUtils
  {$IFDEF MSWINDOWS}
    , System.Classes, System.SyncObjs, System.Math, Winapi.Windows,
    Winapi.Winsock2
  {$ENDIF};

{$IFDEF MSWINDOWS}

type
  TRequest = class
    O: TWSAOverlapped;
    Data: TBytes;
    Pending: Boolean;
    Position, Count: Integer;
    constructor Create;
    destructor Destroy; override;
    procedure Reset;
  end;

  TSocketState = class;

  ISocketState = interface
    ['{1C871DD5-DC31-4C99-8EB3-76F1F6D871AF}']
    function Raw: TSocketState;
  end;

  TSocketState = class(TInterfacedObject, ISocketState)
    Socket: TSocket;
    Rx, Tx: TRequest;
    Problem: TBluetoothError;
    EOF, Started, Closing: Boolean;
    Lock: TCriticalSection;
    Wake: TEvent;
    constructor Create(S: TSocket);
    destructor Destroy; override;
    function Raw: TSocketState;
    procedure Fail(Code: Integer);
    function Poll(R: TRequest; Reading: Boolean): Boolean;
    function Post(R: TRequest; Reading: Boolean): Boolean;
    procedure ProgressTx;
    procedure Start;
    procedure Shutdown;
  end;

  TChannel = class(TInterfacedObject, IBluetoothChannel)
    Lock: TCriticalSection;
    State: ISocketState;
    Details: TBluetoothChannelInfo;
    constructor Create(S: TSocket; const Info: TBluetoothChannelInfo);
    destructor Destroy; override;
    function Info: TBluetoothChannelInfo;
    function Read(var Buffer: TBytes; Offset, Count: Integer): TBluetoothTransfer;
    function Write(const Buffer: TBytes; Offset, Count: Integer): TBluetoothTransfer;
    procedure Close;
  end;

constructor TRequest.Create;
begin
  inherited;
  O := Default(TWSAOverlapped);
  O.hEvent := WSACreateEvent;
  if O.hEvent = 0 then
    RaiseLastOSError;
end;

destructor TRequest.Destroy;
begin
  if O.hEvent <> 0 then
    WSACloseEvent(O.hEvent);
  inherited;
end;

procedure TRequest.Reset;
begin
  var Event := O.hEvent;
  O := Default(TWSAOverlapped);
  O.hEvent := Event;
  WSAResetEvent(Event);
  Position := 0;
  Count := 0;
end;

constructor TSocketState.Create(S: TSocket);
begin
  inherited Create;
  Socket := S;
  Lock := TCriticalSection.Create;
  Wake := TEvent.Create(nil, False, False, '');
  var Data: WSAData;
  Started := WSAStartup($0202, Data) = 0;
  if not Started then
    raise EOSError.Create('Winsock initialization failed');
  Rx := TRequest.Create;
  Tx := TRequest.Create;
end;

destructor TSocketState.Destroy;
begin
  if Socket <> INVALID_SOCKET then
    closesocket(Socket);
  Rx.Free;
  Tx.Free;
  Wake.Free;
  Lock.Free;
  if Started then
    WSACleanup;
  inherited;
end;

function TSocketState.Raw: TSocketState;
begin
  Result := Self;
end;

procedure TSocketState.Fail(Code: Integer);
begin
  Problem := Default(TBluetoothError);
  Problem.Code := TBluetoothErrorCode.IOFailure;
  Problem.NativeCode := Code;
  Problem.MessageText := 'Bluetooth overlapped I/O: ' + SysErrorMessage(Code);
end;

function TSocketState.Poll(R: TRequest; Reading: Boolean): Boolean;
begin
  if not R.Pending then
    Exit(True);
  var Count, Flags: DWORD;
  Count := 0;
  Flags := 0;
  if not WSAGetOverlappedResult(Socket, @R.O, Count, False, Flags) then
  begin
    var Code := WSAGetLastError;
    if Code = WSA_IO_INCOMPLETE then
      Exit(False);
    R.Pending := False;
    if Reading and (Code = WSAECONNRESET) then
    begin
      R.Count := 0;
      EOF := True;
    end
    else
      Fail(Code);
    Exit(True);
  end;
  R.Pending := False;
  R.Count := Count;
  if Reading then
    EOF := Count = 0
  else
  begin
    if (Count = 0) or (Count > DWORD(Length(R.Data) - R.Position)) then
      Fail(WSAECONNABORTED)
    else
      Inc(R.Position, Count);
  end;
  Result := True;
end;

function TSocketState.Post(R: TRequest; Reading: Boolean): Boolean;
begin
  var Position := R.Position;
  R.Reset;
  if not Reading then
    R.Position := Position;
  var Buffer: WSABUF;
  Buffer.len := Length(R.Data) - R.Position;
  Buffer.buf := PAnsiChar(@R.Data[R.Position]);
  var Count, Flags: DWORD;
  Count := 0;
  Flags := 0;
  var Code: Integer;
  if Reading then
    Code := WSARecv(Socket, @Buffer, 1, Count, Flags, @R.O, nil)
  else
    Code := WSASend(Socket, @Buffer, 1, Count, 0, @R.O, nil);
  if Code = 0 then
  begin
    R.Count := Count;
    if Reading then
      EOF := Count = 0
    else
    begin
      if (Count = 0) or (Count > DWORD(Length(R.Data) - R.Position)) then
        Fail(WSAECONNABORTED)
      else
        Inc(R.Position, Count);
    end;
    Exit(True);
  end;
  Code := WSAGetLastError;
  if Code = WSA_IO_PENDING then
  begin
    R.Pending := True;
    Exit(True);
  end;
  if Reading and (Code = WSAECONNRESET) then
  begin
    R.Count := 0;
    EOF := True;
    Exit(True);
  end;
  if Code <> WSAEWOULDBLOCK then
    Fail(Code);
  Result := False;
end;

procedure TSocketState.ProgressTx;
begin
  if (Problem.Code <> TBluetoothErrorCode.None) or not Poll(Tx, False) then
    Exit;
  if Tx.Position < Length(Tx.Data) then
    Post(Tx, False);
end;

procedure TSocketState.Start;
begin
  var Keep: ISocketState := Self;
  var Worker := TThread.CreateAnonymousThread(
    procedure
    begin
      var S := Keep.Raw;
      var ClosingAt: UInt64 := 0;
      repeat
        var Finish := False;
        S.Lock.Acquire;
        try
          S.ProgressTx;
          if S.Problem.Code <> TBluetoothErrorCode.None then
            S.Closing := True;
          if S.Closing then
          begin
            if ClosingAt = 0 then
              ClosingAt := GetTickCount64;
            Finish := (S.Problem.Code <> TBluetoothErrorCode.None) or ((not S.Tx.Pending) and (S.Tx.Position = Length(S.Tx.Data))) or (GetTickCount64 - ClosingAt >= 2000);
          end;
        finally
          S.Lock.Release;
        end;
        if Finish then
          Break;
        S.Wake.WaitFor(5);
      until False;
      S.Lock.Acquire;
      var Socket: TSocket;
      try
        Socket := S.Socket;
        S.Socket := INVALID_SOCKET;
      finally
        S.Lock.Release;
      end;
      if Socket <> INVALID_SOCKET then
      begin
        Winapi.Winsock2.shutdown(Socket, SD_SEND);
        closesocket(Socket);
      end;
    // Closing cancels outstanding I/O. The OVERLAPPED structures and payloads
    // stay alive until completion is signalled; they cannot be freed on Close.
      if S.Rx.Pending then
        WaitForSingleObject(S.Rx.O.hEvent, INFINITE);
      if S.Tx.Pending then
        WaitForSingleObject(S.Tx.O.hEvent, INFINITE);
      S.Lock.Acquire;
      try
        S.Rx.Pending := False;
        S.Tx.Pending := False;
      finally
        S.Lock.Release;
      end;
    end);
  Worker.Start;
end;

procedure TSocketState.Shutdown;
begin
  Lock.Acquire;
  try
    Closing := True;
    Wake.SetEvent;
  finally
    Lock.Release;
  end;
end;

constructor TChannel.Create(S: TSocket; const Info: TBluetoothChannelInfo);
begin
  inherited Create;
  Lock := TCriticalSection.Create;
  State := TSocketState.Create(S);
  State.Raw.Start;
  Details := Info;
end;

destructor TChannel.Destroy;
begin
  Close;
  Lock.Free;
  inherited;
end;

procedure TChannel.Close;
begin
  Lock.Acquire;
  try
    if State <> nil then
    begin
      State.Raw.Shutdown;
      State := nil;
    end;
  finally
    Lock.Release;
  end;
end;

function TChannel.Info: TBluetoothChannelInfo;
begin
  Result := Details;
end;

procedure Range(const B: TBytes; Offset, Count: Integer);
begin
  if (Offset < 0) or (Count < 0) or (Offset > Length(B)) or (Count > Length(B) - Offset) then
    raise EArgumentOutOfRangeException.Create('Bluetooth socket byte range');
end;

function TChannel.Read(var Buffer: TBytes; Offset, Count: Integer): TBluetoothTransfer;
begin
  Range(Buffer, Offset, Count);
  Result := Default(TBluetoothTransfer);
  Lock.Acquire;
  try
    if State = nil then
    begin
      Result.State := TBluetoothIOState.Closed;
      Exit;
    end;
    var S := State.Raw;
    S.Lock.Acquire;
    try
      if Count = 0 then
      begin
        Result.State := TBluetoothIOState.Ready;
        Exit;
      end;
      S.ProgressTx;
      var R := S.Rx;
      if S.Poll(R, True) and (R.Position = R.Count) and not S.EOF and (S.Problem.Code = TBluetoothErrorCode.None) then
      begin
        SetLength(R.Data, 16384);
        S.Post(R, True);
      end;
      if S.Problem.Code <> TBluetoothErrorCode.None then
      begin
        Result.State := TBluetoothIOState.Failed;
        Result.Error := S.Problem;
        Exit;
      end;
      if R.Pending then
      begin
        Result.State := TBluetoothIOState.WouldBlock;
        Exit;
      end;
      Result.Count := Min(Count, R.Count - R.Position);
      if Result.Count <> 0 then
      begin
        Move(R.Data[R.Position], Buffer[Offset], Result.Count);
        Inc(R.Position, Result.Count);
        Result.State := TBluetoothIOState.Ready;
      end
      else if S.EOF then
        Result.State := TBluetoothIOState.EndOfStream
      else
        Result.State := TBluetoothIOState.WouldBlock;
    finally
      S.Lock.Release;
    end;
  finally
    Lock.Release;
  end;
end;

function TChannel.Write(const Buffer: TBytes; Offset, Count: Integer): TBluetoothTransfer;
begin
  Range(Buffer, Offset, Count);
  Result := Default(TBluetoothTransfer);
  Lock.Acquire;
  try
    if State = nil then
    begin
      Result.State := TBluetoothIOState.Closed;
      Exit;
    end;
    var S := State.Raw;
    S.Lock.Acquire;
    try
      if Count = 0 then
      begin
        Result.State := TBluetoothIOState.Ready;
        Exit;
      end;
      S.ProgressTx;
      if S.Tx.Pending or (S.Tx.Position < Length(S.Tx.Data)) then
      begin
        Result.State := TBluetoothIOState.WouldBlock;
        Exit;
      end;
      if S.Problem.Code <> TBluetoothErrorCode.None then
      begin
        Result.State := TBluetoothIOState.Failed;
        Result.Error := S.Problem;
        Exit;
      end;
      var Accepted := Min(Count, 16384);
      S.Tx.Data := Copy(Buffer, Offset, Accepted);
      S.Tx.Position := 0;
      if S.Post(S.Tx, False) then
      begin
        if S.Problem.Code <> TBluetoothErrorCode.None then
        begin
          Result.State := TBluetoothIOState.Failed;
          Result.Error := S.Problem;
        end
        else
        begin
          Result.State := TBluetoothIOState.Ready;
          Result.Count := Accepted;
          S.Wake.SetEvent;
        end;
      end
      else if S.Problem.Code <> TBluetoothErrorCode.None then
      begin
        Result.State := TBluetoothIOState.Failed;
        Result.Error := S.Problem;
      end
      else
      begin
        S.Tx.Data := nil;
        Result.State := TBluetoothIOState.WouldBlock;
      end;
    finally
      S.Lock.Release;
    end;
  finally
    Lock.Release;
  end;
end;

function AdoptOverlappedBluetoothSocket(Socket: NativeUInt; const Info: TBluetoothChannelInfo): IBluetoothChannel;
begin
  Result := TChannel.Create(TSocket(Socket), Info);
end;
{$ELSE}

function AdoptOverlappedBluetoothSocket(Socket: NativeUInt; const Info: TBluetoothChannelInfo): IBluetoothChannel;
begin
  raise ENotSupportedException.Create('Windows overlapped Bluetooth sockets are unavailable');
end;
{$ENDIF}

end.

