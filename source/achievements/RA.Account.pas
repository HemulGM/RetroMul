unit RA.Account;

interface

{$SCOPEDENUMS ON}

uses
  System.IniFiles, RA.Protocol;

const
  RAAchievementsSection = 'RetroAchievements';
  RAScanLibraryROMsKey = 'ScanLibraryROMs';
  RAScanLibraryROMsDefault = True;
  RARetroMulUserAgent = 'RetroMul/1.0.0.0 ' + RAUserAgentClause;
  RANotificationDefaultDuration = 4500;
  RANotificationMinDuration = 1000;
  RANotificationMaxDuration = 30000;
  RANotificationCornerKey = 'NotificationCorner';
  RANotificationDurationKey = 'NotificationDurationMs';

type
  TRAAchievementCorner = (TopRight, TopLeft, BottomRight, BottomLeft);

const
  RANotificationCornerValues: array[TRAAchievementCorner] of string =
    ('top-right', 'top-left', 'bottom-right', 'bottom-left');

type
  TRAAccountSettings = record
    UserName: string;
    Enabled, Remember, RichPresence, Notifications: Boolean;
    NotificationCorner: TRAAchievementCorner;
    NotificationDuration: Integer;
    class function Read(Ini: TCustomIniFile): TRAAccountSettings; static;
    procedure Write(Ini: TCustomIniFile);
  end;

  IRAAccount = interface
    ['{3B1A5C25-72F2-4B52-9D2D-9F52F2718277}']
    function GetCredentials: TRACredentials;
    procedure SetCredentials(const Value: TRACredentials);
    property Credentials: TRACredentials read GetCredentials write SetCredentials;
  end;

function CreateRAAccount: IRAAccount;

function CanRememberRAAccount: Boolean;

function ReadRAStoredCredentials(Ini: TCustomIniFile): TRACredentials;

procedure WriteRAStoredCredentials(Ini: TCustomIniFile; const Settings: TRAAccountSettings; const Credentials: TRACredentials);

implementation

uses
  System.SysUtils, System.Math, System.NetEncoding
  {$IFDEF MSWINDOWS}, Winapi.Windows{$ENDIF};

const
  ProtectedTokenKey = 'ProtectedToken';

type
  TRAAccount = class(TInterfacedObject, IRAAccount)
  private
    FCredentials: TRACredentials;
  public
    function GetCredentials: TRACredentials;
    procedure SetCredentials(const Value: TRACredentials);
  end;

{$IFDEF MSWINDOWS}
type
  TDataBlob = record
    Size: DWORD;
    Data: PByte;
  end;

function CryptProtectData(var Input: TDataBlob; Description: PWideChar; Entropy, Reserved, Prompt: Pointer; Flags: DWORD; out Output: TDataBlob): BOOL; stdcall; external 'crypt32.dll';

function CryptUnprotectData(var Input: TDataBlob; Description, Entropy, Reserved, Prompt: Pointer; Flags: DWORD; out Output: TDataBlob): BOOL; stdcall; external 'crypt32.dll';

function ProtectToken(const UserName, Token: string): string;
var
  Bytes: TBytes;
  Input, Output: TDataBlob;
begin
  // Bind the credential to both the OS account and the configured RA username.
  Bytes := TEncoding.UTF8.GetBytes(UserName.ToLower + #0 + Token);
  Input.Size := Length(Bytes);
  Input.Data := Pointer(Bytes);
  if not CryptProtectData(Input, nil, nil, nil, nil, 1 {CRYPTPROTECT_UI_FORBIDDEN}, Output) then
    RaiseLastOSError;
  try
    SetLength(Bytes, Output.Size);
    Move(Output.Data^, Bytes[0], Output.Size);
    Result := TNetEncoding.Base64String.EncodeBytesToString(Bytes);
  finally
    LocalFree(HLOCAL(Output.Data));
  end;
end;

function UnprotectToken(const UserName, protected: string): string;
var
  Bytes: TBytes;
  Input, Output: TDataBlob;
  Decoded, Prefix: string;
begin
  Result := '';
  Bytes := TNetEncoding.Base64String.DecodeStringToBytes(protected);
  if Length(Bytes) = 0 then
    Exit;
  Input.Size := Length(Bytes);
  Input.Data := Pointer(Bytes);
  if not CryptUnprotectData(Input, nil, nil, nil, nil, 1 {CRYPTPROTECT_UI_FORBIDDEN}, Output) then
    Exit;
  try
    SetLength(Bytes, Output.Size);
    if Output.Size = 0 then
      Exit;
    Move(Output.Data^, Bytes[0], Output.Size);
    Decoded := TEncoding.UTF8.GetString(Bytes);
    Prefix := UserName.ToLower + #0;
    if Decoded.StartsWith(Prefix) then
      Result := Decoded.Substring(Prefix.Length);
  finally
    LocalFree(HLOCAL(Output.Data));
  end;
end;
{$ENDIF}

class function TRAAccountSettings.Read(Ini: TCustomIniFile): TRAAccountSettings;
begin
  Result.UserName := Ini.ReadString(RAAchievementsSection, 'UserName', '').Trim;
  Result.Enabled := Ini.ReadBool(RAAchievementsSection, 'Enabled', False);
  Result.Remember := CanRememberRAAccount and Ini.ReadBool(RAAchievementsSection, 'Remember', False);
  Result.RichPresence := Ini.ReadBool(RAAchievementsSection, 'RichPresence', True);
  Result.Notifications := Ini.ReadBool(RAAchievementsSection, 'Notifications', True);
  Result.NotificationCorner := TRAAchievementCorner.TopRight;
  var CornerValue := Ini.ReadString(RAAchievementsSection, RANotificationCornerKey, '');
  for var Corner := Low(TRAAchievementCorner) to High(TRAAchievementCorner) do
    if SameText(RANotificationCornerValues[Corner], CornerValue) then
    begin
      Result.NotificationCorner := Corner;
      Break;
    end;
  Result.NotificationDuration := EnsureRange(
    Ini.ReadInteger(RAAchievementsSection, RANotificationDurationKey, RANotificationDefaultDuration),
    RANotificationMinDuration, RANotificationMaxDuration);
end;

procedure TRAAccountSettings.Write(Ini: TCustomIniFile);
begin
  Ini.WriteString(RAAchievementsSection, 'UserName', UserName.Trim);
  Ini.WriteBool(RAAchievementsSection, 'Enabled', Enabled);
  Ini.WriteBool(RAAchievementsSection, 'Remember', Remember);
  Ini.WriteBool(RAAchievementsSection, 'RichPresence', RichPresence);
  Ini.WriteBool(RAAchievementsSection, 'Notifications', Notifications);
  Ini.WriteString(RAAchievementsSection, RANotificationCornerKey, RANotificationCornerValues[NotificationCorner]);
  Ini.WriteInteger(RAAchievementsSection, RANotificationDurationKey,
    EnsureRange(NotificationDuration, RANotificationMinDuration, RANotificationMaxDuration));
end;

function CreateRAAccount: IRAAccount;
begin
  Result := TRAAccount.Create;
end;

function TRAAccount.GetCredentials: TRACredentials;
begin
  Result := FCredentials;
end;

procedure TRAAccount.SetCredentials(const Value: TRACredentials);
begin
  FCredentials := Value;
end;

function CanRememberRAAccount: Boolean;
begin
  {$IFDEF MSWINDOWS}
  Result := True;
  {$ELSE}
  Result := False;
  {$ENDIF}
end;

function ReadRAStoredCredentials(Ini: TCustomIniFile): TRACredentials;
begin
  Result := Default(TRACredentials);
  {$IFDEF MSWINDOWS}
  var Settings := TRAAccountSettings.Read(Ini);
  if Settings.Remember and (Settings.UserName <> '') then
  begin
    try
      Result.Token := UnprotectToken(Settings.UserName, Ini.ReadString(RAAchievementsSection, ProtectedTokenKey, ''));
      if Result.Token <> '' then
        Result.UserName := Settings.UserName;
    except
      on E: EConvertError do
        Result := Default(TRACredentials);
    end;
  end;
  {$ENDIF}
end;

procedure WriteRAStoredCredentials(Ini: TCustomIniFile; const Settings: TRAAccountSettings; const Credentials: TRACredentials);
begin
  {$IFDEF MSWINDOWS}
  if Settings.Remember and (Settings.UserName <> '') and SameText(Settings.UserName, Credentials.UserName) and
    (Credentials.Token <> '') then
  begin
    Ini.WriteString(RAAchievementsSection, ProtectedTokenKey, ProtectToken(Settings.UserName, Credentials.Token));
    Exit;
  end;
  {$ENDIF}
  Ini.DeleteKey(RAAchievementsSection, ProtectedTokenKey);
end;

end.

