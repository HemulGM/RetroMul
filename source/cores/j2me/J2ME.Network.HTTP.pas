unit J2ME.Network.HTTP;

interface

uses
  System.Classes, System.SysUtils, System.SyncObjs, System.Net.URLClient,
  System.Net.HttpClient;

type
  // This worker owns all transport objects. It never accesses the guest VM.
  // Results are immutable after Done, published with an interlocked barrier.
  TJ2MEHTTPJob = class(TThread)
  private
    FURL, FMethod: string;
    FBody: TBytes;
    FHeaders: TNetHeaders;
    FRequest: IHTTPRequest;
    FLock: TObject;
    FDone, FCancelled: Integer;
    FLimit: Integer;
    procedure CaptureServerCertificate(const Sender: TObject; const ARequest: TURLRequest; const Certificate: TCertificate; var Accepted: Boolean);
  protected
    procedure Execute; override;
  public
    Code: Integer;
    MessageText, StatusLine, ErrorText: string;
    ResponseHeaders: TNetHeaders;
    ServerCertificate: TCertificate;
    CertificateFailures: THTTPSecureFailureReasons;
    CertificateRejected: Boolean;
    Data: TBytes;
    constructor Create(const URL, Method: string; const Body: TBytes; const Headers: TNetHeaders; Limit: Integer);
    destructor Destroy; override;
    procedure Cancel;
    function Done: Boolean;
  end;

implementation

type
  TBoundedResponse = class(TMemoryStream)
  private
    FLimit: Integer;
  public
    constructor Create(Limit: Integer);
    function Write(const Buffer; Count: Longint): Longint; override;
{$IF SizeOf(Longint) <> SizeOf(NativeInt)}
    function Write(const Buffer; Count: NativeInt): NativeInt; override;
{$ENDIF}
  end;

constructor TBoundedResponse.Create(Limit: Integer);
begin
  inherited Create;
  FLimit := Limit;
end;

function TBoundedResponse.Write(const Buffer; Count: Longint): Longint;
begin
  if (Count < 0) or (Position > FLimit) or (Count > FLimit - Position) then
    raise EStreamError.Create('HTTP response exceeds implementation capacity');
  Result := inherited Write(Buffer, Count);
end;
{$IF SizeOf(Longint) <> SizeOf(NativeInt)}

function TBoundedResponse.Write(const Buffer; Count: NativeInt): NativeInt;
begin
  if (Count < 0) or (Position > FLimit) or (Count > FLimit - Position) then
    raise EStreamError.Create('HTTP response exceeds implementation capacity');
  Result := inherited Write(Buffer, Count);
end;
{$ENDIF}

constructor TJ2MEHTTPJob.Create(const URL, Method: string; const Body: TBytes; const Headers: TNetHeaders; Limit: Integer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FLock := TObject.Create;
  FURL := URL;
  FMethod := Method;
  FBody := Copy(Body);
  FHeaders := Copy(Headers);
  FLimit := Limit;
end;

procedure TJ2MEHTTPJob.Cancel;
var
  Request: IHTTPRequest;
begin
  TInterlocked.Exchange(FCancelled, 1);
  TMonitor.Enter(FLock);
  try
    Request := FRequest;
  finally
    TMonitor.Exit(FLock);
  end;
  if Request <> nil then
    Request.Cancel;
end;

destructor TJ2MEHTTPJob.Destroy;
begin
  if FLock <> nil then
    Cancel;
  // TThread handles a failed/suspended construction as well as a running job.
  inherited;
  FRequest := nil;
  FLock.Free;
end;

function TJ2MEHTTPJob.Done: Boolean;
begin
  Result := TInterlocked.CompareExchange(FDone, 0, 0) <> 0;
end;

procedure TJ2MEHTTPJob.CaptureServerCertificate(const Sender: TObject; const ARequest: TURLRequest; const Certificate: TCertificate; var Accepted: Boolean);
begin
  // The platform is responsible for chain and host-name validation.
  ServerCertificate := Certificate;
  if not Accepted then
  begin
    CertificateRejected := True;
    CertificateFailures := THTTPClient(Sender).SecureFailureReasons;
  end;
end;

procedure TJ2MEHTTPJob.Execute;
var
  Client: THTTPClient;
  Body: TBytesStream;
  Response: TBoundedResponse;
  Request: IHTTPRequest;
  Reply: IHTTPResponse;
begin
  Client := nil;
  Body := nil;
  Response := nil;
  try
    try
      if TInterlocked.CompareExchange(FCancelled, 0, 0) <> 0 then
        raise EAbort.Create('HTTP request cancelled');
      Client := THTTPClient.Create;
      Client.HandleRedirects := False;
      if FURL.StartsWith('https://') then
        Client.OnValidateServerCertificate := CaptureServerCertificate;
      Client.AllowCookies := False;
      Client.AutomaticDecompression := [];
      Client.ConnectionTimeout := 10000;
      Client.ResponseTimeout := 10000;
      Client.SendTimeout := 10000;
      Request := Client.GetRequest(FMethod, FURL);
      Body := TBytesStream.Create(FBody);
      Response := TBoundedResponse.Create(FLimit);
      if (Length(FBody) > 0) or (FMethod = 'POST') then
        Request.SourceStream := Body;
      TMonitor.Enter(FLock);
      try
        FRequest := Request;
        if TInterlocked.CompareExchange(FCancelled, 0, 0) <> 0 then
          raise EAbort.Create('HTTP request cancelled');
      finally
        TMonitor.Exit(FLock);
      end;
      Reply := Client.Execute(Request, Response, FHeaders);
      Code := Reply.StatusCode;
      MessageText := Reply.StatusText;
      var Version := 'HTTP/1.1';
      if Reply.Version = THTTPProtocolVersion.HTTP_1_0 then
        Version := 'HTTP/1.0';
      StatusLine := Version + ' ' + IntToStr(Code) + ' ' + MessageText;
      ResponseHeaders := Copy(Reply.Headers);
      SetLength(Data, Response.Size);
      if Length(Data) > 0 then
        Move(Response.Memory^, Data[0], Length(Data));
    except
      on E: Exception do
      begin
        ErrorText := E.Message;
        if (Client <> nil) and FURL.StartsWith('https://') then
        begin
          CertificateFailures := CertificateFailures + Client.SecureFailureReasons -
            [THTTPSecureFailureReason.SecurityChannelError];
          CertificateRejected := CertificateRejected or (CertificateFailures <> []);
        end;
        Data := nil;
      end;
    end;
  finally
    TMonitor.Enter(FLock);
    try
      FRequest := nil;
    finally
      TMonitor.Exit(FLock);
    end;
    Reply := nil;
    Request := nil;
    Client.Free;
    Response.Free;
    Body.Free;
    FBody := nil;
    FHeaders := nil;
    TInterlocked.Exchange(FDone, 1);
  end;
end;

end.

