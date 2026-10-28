unit RM.Platforms.PCE.SettingsHandler;

interface

uses
  RM.Settings.Runtime;

type
  TPCESettingsHandler = class(TPlatformSettingsHandler)
  public
    class function HelpInfo(const Context: TSettingsRuntimeContext): TSettingsHelpInfo; override;
  end;

implementation

class function TPCESettingsHandler.HelpInfo(const Context: TSettingsRuntimeContext): TSettingsHelpInfo;
begin
  Result := inherited HelpInfo(Context);
  Result.Players := 1;
  if Context.State.Input.Ports.Multitap[0] then
    Result.Players := 5;
end;

end.
