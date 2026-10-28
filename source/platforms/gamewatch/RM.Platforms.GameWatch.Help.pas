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
  RM.LibraryView;

class function TGWControlsHelp.Info(const Context: TControlsHelpContext): TControlsHelpInfo;
begin
  Result := inherited Info(Context);
  Result.ControllerTitle := LibrarySystemName(Context.SystemId);
  Result.AssignmentColumns := 1;
  Result.AssignmentRowHeight := 32;
  Result.AssignmentCaptionWidth := 112;
end;

end.

