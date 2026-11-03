unit RM.Platforms.WS.Help;

interface

uses
  RM.ControlsHelp.Content;

type
  TWSControlsHelp = class(TPlatformControlsHelp)
  public
    class function Info(const Context: TControlsHelpContext): TControlsHelpInfo; override;
  end;

implementation

uses
  FMX.Types;

class function TWSControlsHelp.Info(const Context: TControlsHelpContext): TControlsHelpInfo;
begin
  Result := inherited Info(Context);
  Result.ControllerTitle := 'WonderSwan';
  Result.Note := Translate('X1-X4 and Y1-Y4 are independent directional groups. Vertical games rotate both groups automatically.');
  Result.AssignmentCaptionWidth := 100;
end;

end.

