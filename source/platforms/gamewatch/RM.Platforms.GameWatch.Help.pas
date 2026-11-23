unit RM.Platforms.GameWatch.Help;

interface

uses
  RM.ControlsHelp.Content;

type
  TGWControlsHelp = class(TPlatformControlsHelp)
  public
    class function Info(const Context: TControlsHelpContext): TControlsHelpInfo; override;
  end;

implementation

uses
  FMX.Types, Core.Platforms;

class function TGWControlsHelp.Info(const Context: TControlsHelpContext): TControlsHelpInfo;
begin
  Result := inherited Info(Context);
  var Info: TPlatformInfo;
  if TPlatformRegistry.Find(Context.SystemId, Info) then
    Result.ControllerTitle := Translate(Info.ShortName)
  else
    Result.ControllerTitle := Context.SystemId;
  Result.AssignmentColumns := 1;
  Result.AssignmentRowHeight := 32;
  Result.AssignmentCaptionWidth := 112;
end;

end.

