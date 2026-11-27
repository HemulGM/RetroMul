unit RA.Http;

interface

uses
  System.SysUtils, System.JSON, System.Net.HttpClient;

const
  RAMaxBadgeBytes = 256 * 1024;

function IsRABadgePNG(const Data: TBytes): Boolean;

type
  TRAHttpClient = class
  private
    FClient: THTTPClient;
  public
    constructor Create(const UserAgent: string);
    destructor Destroy; override;
    // Call on a network worker. The caller owns the returned JSON object.
    function Post(const Form: string): TJSONObject;
    function PostTo(const URL, Form: string): TJSONObject;
    function GetBadgePNG(const URL: string): TBytes;
  end;

implementation

uses
  System.Classes, System.DateUtils, System.Math, System.Net.URLClient,
  RA.Protocol;

constructor TRAHttpClient.Create(const UserAgent: string);
begin
  inherited Create;
  if UserAgent.Trim.IsEmpty then
    raise EArgumentException.Create('RetroAchievements requires a client User-Agent');
  FClient := THTTPClient.Create;
  FClient.UserAgent := UserAgent;
  FClient.ConnectionTimeout := 10000;
  FClient.ResponseTimeout := 15000;
  FClient.HandleRedirects := False;
  FClient.AllowCookies := False;
end;

destructor TRAHttpClient.Destroy;
begin
  FClient.Free;
  inherited;
end;

function ReadRetryAfter(const Header: string): Cardinal;
var
  RetryDate, CurrentDate: TDateTime;
begin
  Result := 0;
  if Header = '' then
    Exit;
  if CharInSet(Header[1], ['0'..'9']) then
  begin
    for var Ch in Header do
      if not CharInSet(Ch, ['0'..'9']) then
        Exit;
    if not TryStrToUInt(Header, Result) then
      Result := 0;
    Exit;
  end;
  if not TryRFC822ToDate(Header, RetryDate) then
    Exit;
  CurrentDate := TTimeZone.local.ToUniversalTime(Now);
  if RetryDate > CurrentDate then
    Result := Cardinal(Min((MilliSecondsBetween(RetryDate, CurrentDate) + 999) div 1000,
        Int64(High(Cardinal))));
end;

function TRAHttpClient.Post(const Form: string): TJSONObject;
begin
  Result := PostTo(GetRADefaultRequestURL, Form);
end;

function TRAHttpClient.PostTo(const URL, Form: string): TJSONObject;
var
  Body: TBytesStream;
  Response: IHTTPResponse;
  RetryAfter: Cardinal;
begin
  Body := TBytesStream.Create(TEncoding.UTF8.GetBytes(Form));
  try
    Response := FClient.Post(URL, Body, nil,
      [TNameValuePair.Create('Content-Type', RAFormContentType),
        TNameValuePair.Create('Accept', 'application/json')]);
    RetryAfter := ReadRetryAfter(Response.HeaderValue['Retry-After'].Trim);
    Result := ParseRAResponse(Response.ContentAsString(TEncoding.UTF8), Response.StatusCode,
      Form, RetryAfter);
  finally
    Body.Free;
  end;
end;

function IsRABadgePNG(const Data: TBytes): Boolean;
const
  MaxBadgeSide = 512;
  PNGHeader: array[0..15] of Byte =
    ($89, $50, $4E, $47, $0D, $0A, $1A, $0A, 0, 0, 0, 13, $49, $48, $44, $52);
  PNGEnd: array[0..11] of Byte = (0, 0, 0, 0, $49, $45, $4E, $44, $AE, $42, $60, $82);

  function ReadDimension(Offset: Integer): Cardinal;
  begin
    Result := (Cardinal(Data[Offset]) shl 24) or (Cardinal(Data[Offset + 1]) shl 16) or
      (Cardinal(Data[Offset + 2]) shl 8) or Data[Offset + 3];
  end;

begin
  if (Length(Data) < 45) or (Length(Data) > RAMaxBadgeBytes) or
    not CompareMem(@Data[0], @PNGHeader[0], SizeOf(PNGHeader)) or
    not CompareMem(@Data[Length(Data) - SizeOf(PNGEnd)], @PNGEnd[0], SizeOf(PNGEnd)) then
    Exit(False);
  var Width := ReadDimension(16);
  var Height := ReadDimension(20);
  Result := (Width > 0) and (Width <= MaxBadgeSide) and (Height > 0) and (Height <= MaxBadgeSide);
end;

function TRAHttpClient.GetBadgePNG(const URL: string): TBytes;
begin
  Result := nil;
  if not URL.StartsWith('https://', True) and not URL.StartsWith('http://', True) then
    Exit;
  var Body := TMemoryStream.Create;
  try
    FClient.ReceiveDataCallback :=
      procedure(const Sender: TObject; ContentLength, ReadCount: Int64; var Abort: Boolean)
      begin
        Abort := (ContentLength > RAMaxBadgeBytes) or (ReadCount > RAMaxBadgeBytes);
      end;
    try
      var Response := FClient.Get(URL, Body, [TNameValuePair.Create('Accept', 'image/png')]);
      if (Response.StatusCode <> 200) or (Body.Size < 45) or (Body.Size > RAMaxBadgeBytes) then
        Exit;
    finally
      FClient.ReceiveDataCallback := nil;
    end;
    var Data: TBytes;
    SetLength(Data, Body.Size);
    Body.Position := 0;
    Body.ReadBuffer(Data[0], Length(Data));
    if IsRABadgePNG(Data) then
      Result := Data;
  finally
    Body.Free;
  end;
end;

end.

