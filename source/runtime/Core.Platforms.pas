unit Core.Platforms;

interface

uses
  Core.Emulation.Types, System.SysUtils, System.Generics.Collections;

type
  // Stable system IDs and settings keys preserve existing collections and INI files.
  TPlatformInfo = record
    Id, CoreId, Name, ShortName, Manufacturer, SearchTerms, Folder: string;
    ScanFolders, Extensions: TArray<string>;
    SettingsProfile, SettingsCoreId: string;
    Ports: Integer;
    function CopyInfo: TPlatformInfo;
  end;

  TPlatformRegistrationListener = reference to procedure(const Info: TPlatformInfo);

  TPlatformRegistry = class sealed
  strict private
    class var
      FItems: TList<TPlatformInfo>;
      FIdAliases: TDictionary<string, string>;
      FListeners: TDictionary<Integer, TPlatformRegistrationListener>;
      FNextListener: Integer;
    class procedure NotifyRegistered(const Info: TPlatformInfo); static;
  public
    class constructor Create;
    class destructor Destroy;
    // Each core module supplies its complete extension list and platform data.
    class procedure RegisterPlatform(const Id, Name, ShortName, Manufacturer, SearchTerms, Folder: string; const ScanFolders, Extensions: array of string; const SettingsProfile, SettingsCoreId: string; Ports: Integer); static;
    class procedure RegisterAlias(const Alias, PlatformId: string); static;
    // Listeners run synchronously for subsequent registrations and aliases.
    class function AddRegistrationListener(const Listener: TPlatformRegistrationListener): Integer; static;
    class procedure RemoveRegistrationListener(Token: Integer); static;
    class function All: TArray<TPlatformInfo>; static;
    class function Find(const Id: string; out Info: TPlatformInfo): Boolean; static;
    class function CanonicalId(const Id: string): string; static;
    class function Require(const Id: string): TPlatformInfo; static;
    class function FileFilter: string; static;
  end;

implementation

uses
  System.Generics.Defaults;

function TPlatformInfo.CopyInfo: TPlatformInfo;
begin
  Result := Self;
  Result.ScanFolders := Copy(ScanFolders);
  Result.Extensions := Copy(Extensions);
end;

class constructor TPlatformRegistry.Create;
begin
  FItems := TList<TPlatformInfo>.Create;
  FIdAliases := TDictionary<string, string>.Create(TIStringComparer.Ordinal);
  FListeners := TDictionary<Integer, TPlatformRegistrationListener>.Create;
end;

class destructor TPlatformRegistry.Destroy;
begin
  FListeners.Free;
  FIdAliases.Free;
  FItems.Free;
end;

class procedure TPlatformRegistry.NotifyRegistered(const Info: TPlatformInfo);
begin
  // Snapshot permits listeners to unsubscribe without invalidating enumeration.
  for var Listener in FListeners.Values.ToArray do
    Listener(Info.CopyInfo);
end;

class function TPlatformRegistry.AddRegistrationListener(const Listener: TPlatformRegistrationListener): Integer;
begin
  if not Assigned(Listener) then
    raise EArgumentNilException.Create('Listener');
  Inc(FNextListener);
  Result := FNextListener;
  FListeners.Add(Result, Listener);
end;

class procedure TPlatformRegistry.RemoveRegistrationListener(Token: Integer);
begin
  FListeners.Remove(Token);
end;

class procedure TPlatformRegistry.RegisterAlias(const Alias, PlatformId: string);
begin
  if Alias.Trim = '' then
    raise EArgumentException.Create('Empty platform alias');
  var Info := Require(PlatformId);
  for var Existing in FItems do
    if SameText(Existing.Id, Alias.Trim) or SameText(Existing.Folder, Alias.Trim) then
      raise EArgumentException.Create('Duplicate platform alias: ' + Alias);
  FIdAliases.Add(Alias.Trim.ToLower, Info.Id);
  NotifyRegistered(Info);
end;

class procedure TPlatformRegistry.RegisterPlatform(const Id, Name, ShortName, Manufacturer, SearchTerms, Folder: string; const ScanFolders, Extensions: array of string; const SettingsProfile, SettingsCoreId: string; Ports: Integer);
begin
  if (Id.Trim = '') or (Name = '') or
    (Manufacturer = '') or (Folder = '') or (Length(ScanFolders) = 0) or
    (Length(Extensions) = 0) or (Ports < 1) or (Ports > EmulatorMaxPlayers) or
    (SettingsCoreId = '') then
    raise EArgumentException.Create('Invalid platform: ' + Id);

  for var Existing in FItems do
    if SameText(Existing.Id, Id.Trim) or SameText(Existing.Folder, Id.Trim) or
      SameText(Existing.Id, Folder) then
      raise EArgumentException.Create('Duplicate platform: ' + Id);

  if FIdAliases.ContainsKey(Id.Trim) or FIdAliases.ContainsKey(Folder) then
    raise EArgumentException.Create('Duplicate platform: ' + Id);

  var Item: TPlatformInfo;
  Item.Id := Id.Trim.ToLower;
  Item.CoreId := SettingsCoreId.ToUpper;
  Item.Name := Name;
  Item.ShortName := ShortName;
  Item.Manufacturer := Manufacturer;
  Item.SearchTerms := SearchTerms;
  Item.Folder := Folder;
  SetLength(Item.ScanFolders, Length(ScanFolders));
  for var i := 0 to High(ScanFolders) do
    Item.ScanFolders[i] := ScanFolders[i];
  SetLength(Item.Extensions, Length(Extensions));
  for var i := 0 to High(Extensions) do
    Item.Extensions[i] := Extensions[i];
  Item.SettingsProfile := SettingsProfile;
  Item.SettingsCoreId := SettingsCoreId;
  Item.Ports := Ports;
  FItems.Add(Item);
  FItems.Sort(TComparer<TPlatformInfo>.Construct(
    function(const A, B: TPlatformInfo): Integer
    begin
      Result := CompareText(A.Manufacturer, B.Manufacturer);
      if Result = 0 then
        Result := CompareText(A.Name, B.Name);
      if Result = 0 then
        Result := CompareText(A.Id, B.Id);
    end));
  NotifyRegistered(Item);
end;

class function TPlatformRegistry.All: TArray<TPlatformInfo>;
begin
  SetLength(Result, FItems.Count);
  for var i := 0 to FItems.Count - 1 do
    Result[i] := FItems[i].CopyInfo;
end;

class function TPlatformRegistry.Find(const Id: string; out Info: TPlatformInfo): Boolean;
begin
  var CanonicalId: string;
  if FIdAliases.TryGetValue(Id.Trim, CanonicalId) then
    Exit(Find(CanonicalId, Info));

  for var Item in FItems do
    if SameText(Item.Id, Id.Trim) or SameText(Item.Folder, Id.Trim) then
    begin
      Info := Item.CopyInfo;
      Exit(True);
    end;

  Info := Default(TPlatformInfo);
  Result := False;
end;

class function TPlatformRegistry.CanonicalId(const Id: string): string;
begin
  var Info: TPlatformInfo;
  if Find(Id, Info) then
    Result := Info.Id
  else
    Result := Id.Trim.ToLower;
end;

class function TPlatformRegistry.Require(const Id: string): TPlatformInfo;
begin
  if not Find(Id, Result) then
    raise EArgumentException.Create('Unknown platform: ' + Id);
end;

class function TPlatformRegistry.FileFilter: string;
begin
  var Extensions := TList<string>.Create;
  try
    Result := '';
    for var Item in All do
    begin
      var Masks := '';
      for var Ext in Item.Extensions do
      begin
        if not Extensions.Contains(Ext) then
          Extensions.Add(Ext);
        if Masks <> '' then
          Masks := Masks + ';';
        Masks := Masks + '*' + Ext;
      end;
      Result := Result + '|' + Item.Name + '|' + Masks;
    end;
    var Masks := '';
    for var Ext in Extensions do
    begin
      if Masks <> '' then
        Masks := Masks + ';';
      Masks := Masks + '*' + Ext;
    end;
    Result := 'ROM|' + Masks + Result;
  finally
    Extensions.Free;
  end;
end;

end.

