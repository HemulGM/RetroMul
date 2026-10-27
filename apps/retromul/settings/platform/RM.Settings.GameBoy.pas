unit RM.Settings.GameBoy;

interface

uses
  RM.Settings.GameBoy.Base;

type
  TGameBoySettings = class(TGameBoySettingsBase);

implementation

uses
  RM.Settings.Catalog;

initialization
  RegisterSettingsProfile('GameBoy', TGameBoySettings);

end.
