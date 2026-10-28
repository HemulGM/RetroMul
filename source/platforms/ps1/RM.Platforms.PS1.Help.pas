unit RM.Platforms.PS1.Help;

interface

uses
  RM.ControlsHelp.Content;

type
  TPS1ControlsHelp = class(TPlatformControlsHelp)
  public
    class function Assignments(const Context: TControlsHelpContext): TArray<TControlsHelpAssignment>; override;
  end;

implementation

uses
  RM.Platforms.PS1.Input, Core.Platforms.PS1.Adapter, RM.Input;

class function TPS1ControlsHelp.Assignments(const Context: TControlsHelpContext): TArray<TControlsHelpAssignment>;
begin
  Result := inherited Assignments(Context);
  if Length(Result) = 0 then
    Exit;
  for var Extra := Low(TPS1Extra) to High(TPS1Extra) do
    if (Extra = TPS1Extra.L2) or (Context.Ports.Devices[Context.Player] = 'pad-analog') then
      Result := Result + [TControlsHelpAssignment.Create(PS1ExtraName(Extra), PS1Action(Context.Player, Extra))];
end;

end.

