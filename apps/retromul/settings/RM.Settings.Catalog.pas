unit RM.Settings.Catalog;

interface

uses
  RM.Settings.Platform;

var
  SettingsPlatforms: TSettingsPlatformRegistry;

// Called by platform classes through RegisterPlatform. Registrations wait for
// metadata and presentation; an unregistered platform contributes no settings pages.
procedure RegisterSettingsPlatform(const Id: string; PageClass: TSettingsPlatformClass);

procedure RegisterSettingsProfile(const Profile: string; PageClass: TSettingsPlatformClass);

implementation

uses
  Core.Platforms, RM.Platforms.Presentation, System.SysUtils, System.Generics.Collections;

type
  TSettingsRegistration = class
    Selector: string;
    ByProfile: Boolean;
    PageClass: TSettingsPlatformClass;
    AppliedIds: TArray<string>;
    procedure Apply(const Info: TPlatformInfo);
  end;

var
  Registrations: TObjectList<TSettingsRegistration>;
  PlatformListener, PresentationListener: Integer;

procedure TSettingsRegistration.Apply(const Info: TPlatformInfo);
begin
  if ByProfile then
  begin
    if not SameText(Info.SettingsProfile, Selector) or not SameText(Info.Id, Info.SettingsCoreId) then Exit;
  end
  else
  begin
    var Target: TPlatformInfo;
    if not TPlatformRegistry.Find(Selector, Target) or not SameText(Target.Id, Info.Id) then Exit;
  end;
  for var Id in AppliedIds do
    if SameText(Id, Info.Id) then Exit;
  if not SameText(Info.Id, Info.SettingsCoreId) then
    raise EArgumentException.Create('Register the canonical settings platform: ' + Info.SettingsCoreId);
  var Presentation: TPlatformPresentation;
  if not TryPlatformPresentation(Info.Id, Presentation) then Exit;
  SettingsPlatforms.Add(PageClass.Create(Info));
  AppliedIds := AppliedIds + [Info.Id];
end;

procedure QueueRegistration(const Selector: string; ByProfile: Boolean; PageClass: TSettingsPlatformClass);
begin
  var Registration := TSettingsRegistration.Create;
  try
    Registration.Selector := Selector;
    Registration.ByProfile := ByProfile;
    Registration.PageClass := PageClass;
    for var Info in TPlatformRegistry.All do Registration.Apply(Info);
    Registrations.Add(Registration);
  except
    Registration.Free;
    raise;
  end;
end;

procedure RegisterSettingsPlatform(const Id: string; PageClass: TSettingsPlatformClass);
begin
  if (Id = '') or (PageClass = nil) then
    raise EArgumentException.Create('Settings page class and platform ID are required: ' + Id);
  QueueRegistration(Id, False, PageClass);
end;

procedure RegisterSettingsProfile(const Profile: string; PageClass: TSettingsPlatformClass);
begin
  if (Profile = '') or (PageClass = nil) then
    raise EArgumentException.Create('Settings profile and page class are required');
  QueueRegistration(Profile, True, PageClass);
end;

procedure PlatformRegistered(const Info: TPlatformInfo);
begin
  for var Registration in Registrations do Registration.Apply(Info);
end;

procedure PresentationRegistered(const Id: string);
begin
  var Info: TPlatformInfo;
  if TPlatformRegistry.Find(Id, Info) then PlatformRegistered(Info);
end;

initialization
  SettingsPlatforms := TSettingsPlatformRegistry.Create;
  Registrations := TObjectList<TSettingsRegistration>.Create(True);
  PlatformListener := TPlatformRegistry.AddRegistrationListener(PlatformRegistered);
  PresentationListener := AddPresentationRegistrationListener(PresentationRegistered);

finalization
  RemovePresentationRegistrationListener(PresentationListener);
  TPlatformRegistry.RemoveRegistrationListener(PlatformListener);
  Registrations.Free;
  SettingsPlatforms.Free;

end.
