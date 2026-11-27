unit RA.Http;

interface

uses
  System.JSON, System.Net.HttpClient;

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
  end;

implementation

uses
  System.Classes, System.DateUtils, System.Math, System.Net.URLClient,
  System.SysUtils, RA.Protocol;

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

end.

