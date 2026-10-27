unit RM.Settings.Catalog;

interface

uses
  RM.Settings.Platform;

var
  SettingsPlatforms: TSettingsPlatformRegistry;
  // Sparse compatibility tables, updated by each registration. Zero is Main.
  SettingsCoreIds, SettingsPageNames: TArray<string>;
  SettingsCoreOrder: TArray<Integer>;

// Called by platform units during initialization. There is no implicit fallback
// for metadata whose settings provider has not been linked into this build.
procedure RegisterSettingsPlatform(const Id: string; PageClass: TSettingsPlatformClass);

procedure RegisterSettingsProfile(const Profile: string; PageClass: TSettingsPlatformClass);

implementation

uses
  Core.Platforms, System.SysUtils;

procedure UpdateCompatibilityTables;
begin
  SettingsCoreIds := nil;
  SettingsPageNames := nil;
  SetLength(SettingsCoreIds, SettingsPlatforms.MaxPageId + 1);
  SetLength(SettingsPageNames, Length(SettingsCoreIds));
  SettingsPageNames[0] := 'Main';
  var Ordered := SettingsPlatforms.Matching('');
  SetLength(SettingsCoreOrder, Length(Ordered));
  for var I := 0 to High(Ordered) do
  begin
    var platform := Ordered[I];
    SettingsCoreOrder[I] := platform.PageId;
    SettingsCoreIds[platform.PageId] := platform.CoreId;
    SettingsPageNames[platform.PageId] := platform.Name;
  end;
end;

procedure RegisterSettingsPlatform(const Id: string; PageClass: TSettingsPlatformClass);
begin
  if PageClass = nil then
    raise EArgumentException.Create('Settings page class is required: ' + Id);
  var Info := TPlatformRegistry.Require(Id);
  if not SameText(Info.Id, Info.SettingsCoreId) then
    raise EArgumentException.Create('Register the canonical settings platform: ' + Info.SettingsCoreId);
  SettingsPlatforms.Add(PageClass.Create(Info));
  UpdateCompatibilityTables;
end;

procedure RegisterSettingsProfile(const Profile: string; PageClass: TSettingsPlatformClass);
begin
  if (Profile = '') or (PageClass = nil) then
    raise EArgumentException.Create('Settings profile and page class are required');
  var Found := False;
  for var Info in TPlatformRegistry.All do
    if SameText(Info.SettingsProfile, Profile) and SameText(Info.Id, Info.SettingsCoreId) then
    begin
      RegisterSettingsPlatform(Info.Id, PageClass);
      Found := True;
    end;
  if not Found then
    raise EArgumentException.Create('Unknown settings profile: ' + Profile);
end;

initialization
  SettingsPlatforms := TSettingsPlatformRegistry.Create;
  UpdateCompatibilityTables;

finalization
  SettingsPlatforms.Free;

end.

