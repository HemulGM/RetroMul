unit RM.Platforms.SNES.SettingsHandler;

interface

uses
  RM.Settings.Runtime;

type
  TSNESSettingsHandler = class(TPlatformSettingsHandler)
  public
    class function HelpInfo(const Context: TSettingsRuntimeContext): TSettingsHelpInfo; override;
  end;

implementation

class function TSNESSettingsHandler.HelpInfo(const Context: TSettingsRuntimeContext): TSettingsHelpInfo;
begin
  Result := inherited HelpInfo(Context);
  if Context.State.Input.Ports.Multitap[0] then
    Result.Players := 8
  else if Context.State.Input.Ports.Multitap[1] then
    Result.Players := 5;
end;

end.
