unit RM.Platforms.NES.Help;

interface

uses
  System.Classes, FMX.Controls, RM.ControlsHelp.Content;

type
  TNESControlsHelp = class(TPlatformControlsHelp)
  public
    class function Assignments(const Context: TControlsHelpContext): TArray<TControlsHelpAssignment>; override;
    class function CreateDiagram(const Context: TControlsHelpContext; Owner: TComponent): TControl; override;
  end;

implementation

uses
  RM.Platforms.NES.Input, System.SysUtils, RM.Platforms.NES.Controls.PowerPad,
  RM.Input;

class function TNESControlsHelp.Assignments(const Context: TControlsHelpContext): TArray<TControlsHelpAssignment>;
begin
  Result := inherited Assignments(Context);
  if Context.Ports.Devices[Context.Player] = 'powerpad' then
    for var Button := 1 to 12 do
      Result := Result + [TControlsHelpAssignment.Create(IntToStr(Button), PowerPadAction + Button - 1)];
end;

class function TNESControlsHelp.CreateDiagram(const Context: TControlsHelpContext; Owner: TComponent): TControl;
begin
  if Context.Ports.Devices[Context.Player] = 'powerpad' then
    Result := DescribeDevice(Context, TGamepadNESPowerPad.Create(Owner), Owner)
  else
    Result := inherited CreateDiagram(Context, Owner);
end;

end.

