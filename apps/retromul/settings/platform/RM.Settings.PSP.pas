unit RM.Settings.PSP;

interface

implementation

uses
  RM.Settings.Platform, RM.Settings.Catalog;

initialization
  RegisterSettingsPlatform('psp', TSettingsPlatform);

end.
