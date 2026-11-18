unit Core.Messaging.Types;

interface

uses
  System.SysUtils;

{$SCOPEDENUMS ON}

type
  TMessagingProtocol = (SMS, CBS, SiemensSMS);

  TMessagingPayload = (Text, Binary);

  TMessagingState = (Unavailable, Ready);

  TMessagingPermission = (SMSConnect, SMSSend, SMSReceive, CBSConnect, CBSReceive);

  TMessagingPermissions = set of TMessagingPermission;

  TMessagingError = (None, Unavailable, Denied, InvalidAddress, Busy, Closed, WouldBlock, Capacity, TooLarge, IOFailure);

  TMessageAddress = record
    Protocol: TMessagingProtocol;
    Phone: string;
    Port: Integer; // -1 means no application port; port0 is distinct.
    Server: Boolean;
    ApplicationID: UInt32; // The Siemens SMS application identifier is independent of the WMA port.
    class function TryParse(const URL: string; out Address: TMessageAddress): Boolean; static;
    function ToString: string;
  end;

  TWirelessMessage = record
    Kind: TMessagingPayload;
    // Address is the sender URI on receive; Send uses its Destination argument.
    // Timestamp is UTC epoch milliseconds when HasTimestamp is true.
    Address, Text: string;
    Data: TBytes;
    Timestamp: Int64;
    HasTimestamp: Boolean;
  end;

  TMessagingInfo = record
    State: TMessagingState;
    Permissions: TMessagingPermissions;
    PhoneNumber, ServiceCenter: string;
    // Transport limit, independent of SMSCountSegments' protocol calculation.
    MaxSMSSegments: Integer;
  end;

  IMessagingChannel = interface
    ['{F4D84832-2852-4A26-A632-2E4CDB55DC1A}']
    // All operations are nonblocking and thread-safe. Success on Send means
    // accepted once; WouldBlock means nothing was accepted and permits retry.
    // An accepted message owns a payload snapshot. Received mutable bytes are
    // owned by the caller and do not alias a provider or another recipient.
    function Send(const Destination: TMessageAddress; const Message: TWirelessMessage): TMessagingError;
    function Receive(out Message: TWirelessMessage): TMessagingError;
    // ArrivalSerial is monotonic per channel and counts arrivals, not reads.
    // Pending is the current unread count. Failed sends change neither value.
    function Status(out Pending: Integer; out ArrivalSerial: UInt64): TMessagingError;
    // Idempotent. Subsequent channel operations report Closed.
    procedure Close;
  end;

  IMessagingProvider = interface
    ['{AF23FB0F-6B48-4360-AFD1-F48CB5AF342C}']
    function Info: TMessagingInfo;
    // Mode: 1=read, 2=write, 3=read/write. Failed opens return a nil channel.
    function Open(const Address: TMessageAddress; Mode: Integer; out Channel: IMessagingChannel): TMessagingError;
  end;

  IEmulationMessaging = interface
    ['{B779C2C2-2B37-4818-A5B3-BAFA49947C7F}']
    procedure SetMessagingProvider(const Provider: IMessagingProvider); // while stopped
    function GetMessagingProvider: IMessagingProvider;
  end;

function SMSRestrictedPort(Port: Integer): Boolean;

function SMSGSMCost(C: Char): Integer; // 0=UCS2 required,1=default septet,2=extension.

function SMSCountSegments(const Text: string; BinaryBytes: Integer; Binary, HasPort: Boolean): Integer;

implementation

class function TMessageAddress.TryParse(const URL: string; out Address: TMessageAddress): Boolean;
begin
  Address := Default(TMessageAddress);
  Address.Port := -1;
  Result := False;
  if Length(URL) > 16384 then
    Exit;
  var Separator := Pos('://', URL);
  if Separator = 0 then
    Exit;
  var Scheme := Copy(URL, 1, Separator - 1);
  if SameText(Scheme, 'sms') then
    Address.Protocol := TMessagingProtocol.SMS
  else if SameText(Scheme, 'cbs') then
    Address.Protocol := TMessagingProtocol.CBS
  else if SameText(Scheme, 'siemens-sms') then
    Address.Protocol := TMessagingProtocol.SiemensSMS
  else
    Exit;
  var Tail := Copy(URL, Separator + 3, MaxInt);
  var Colon := Pos(':', Tail);
  var Phone := Tail;
  var PortText := '';
  if Colon <> 0 then
  begin
    Phone := Copy(Tail, 1, Colon - 1);
    PortText := Copy(Tail, Colon + 1, MaxInt);
    if PortText = '' then
      Exit;
  end;
  Address.Server := Phone = '';
  if Address.Server and (Colon = 0) then
    Exit;
  if Address.Protocol = TMessagingProtocol.CBS then
  begin
    if not Address.Server then
      Exit;
  end
  else if Phone <> '' then
  begin
    var Start := 1;
    if Phone[1] = '+' then
      Start := 2;
    if Start > Length(Phone) then
      Exit;
    for var I := Start to Length(Phone) do
      if not CharInSet(Phone[I], ['0'..'9']) then
        Exit;
  end;
  if Address.Protocol = TMessagingProtocol.SiemensSMS then
  begin
    if (Length(PortText) = 0) or (Length(PortText) > 10) then
      Exit;
    var ID: UInt64 := 0;
    for var C in PortText do
    begin
      if not CharInSet(C, ['0'..'9']) then
        Exit;
      ID := ID * 10 + Ord(C) - Ord('0');
    end;
    if ID > High(UInt32) then
      Exit;
    Address.ApplicationID := UInt32(ID);
    Address.Phone := Phone;
    Exit(True);
  end;
  if Colon <> 0 then
  begin
    var Port := 0;
    for var C in PortText do
    begin
      if not CharInSet(C, ['0'..'9']) then
        Exit;
      Port := Port * 10 + Ord(C) - 48;
      if Port > 65535 then
        Exit;
    end;
    Address.Port := Port;
  end;
  Address.Phone := Phone;
  Result := True;
end;

function TMessageAddress.ToString: string;
begin
  if Protocol = TMessagingProtocol.SiemensSMS then
    Exit('siemens-sms://' + Phone + ':' + UIntToStr(ApplicationID));
  Result := 'sms://';
  if Protocol = TMessagingProtocol.CBS then
    Result := 'cbs://';
  Result := Result + Phone;
  if Port >= 0 then
    Result := Result + ':' + IntToStr(Port);
end;

function SMSRestrictedPort(Port: Integer): Boolean;
begin
  case Port of
    2805, 2923, 2948, 2949, 5502, 5503, 5508, 5511, 5512, 9200, 9201, 9202, 9203, 9207, 49996, 49999:
      Result := True;
  else
    Result := False;
  end;
end;

function SMSGSMCost(C: Char): Integer;
begin
  Result := 1;
  if CharInSet(C, ['A'..'Z', 'a'..'z', '0'..'9', ' ', '!', '"', '#', '$', '%', '&', '''', '(', ')', '*', '+', ',', '-', '.', '/', ':', ';', '<', '=', '>', '?', '@', '_', #10, #13]) then
    Exit;
  case Ord(C) of
    163, 164, 165, 232, 233, 249, 236, 242, 199, 216, 248, 197, 229, 916, 934, 915, 923, 937, 928, 936, 931, 920, 926, 198, 230, 223, 201, 161, 196, 214, 209, 220, 167, 191, 228, 246, 241, 252, 224:
      Exit;
    12, 94, 123, 125, 92, 91, 126, 93, 124, 8364:
      Exit(2);
  end;
  Result := 0;
end;

function SMSCountSegments(const Text: string; BinaryBytes: Integer; Binary, HasPort: Boolean): Integer;
var
  Count: Int64;
  One, Many: Integer;
begin
  if Binary then
  begin
    Count := BinaryBytes;
    One := 140;
    Many := 133;
    if HasPort then
    begin
      One := 133;
      Many := 127;
    end;
  end
  else
  begin
    Count := 0;
    var UCS2 := False;
    for var C in Text do
    begin
      var Cost := SMSGSMCost(C);
      if Cost = 0 then
      begin
        UCS2 := True;
        Break;
      end;
      Inc(Count, Cost);
    end;
    if UCS2 then
    begin
      Count := Length(Text);
      One := 70;
      Many := 66;
      if HasPort then
      begin
        One := 66;
        Many := 63;
      end;
    end
    else
    begin
      One := 160;
      Many := 152;
      if HasPort then
      begin
        One := 152;
        Many := 145;
      end;
    end;
  end;
  if Count < 0 then
    Exit(0);
  if Count <= One then
    Exit(1);
  Result := Integer((Count + Many - 1) div Many);
  if Result > 255 then
    Result := 0;
end;

end.

