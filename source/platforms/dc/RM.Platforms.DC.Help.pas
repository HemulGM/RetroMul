unit RM.Platforms.DC.Help;

interface

uses
  RM.ControlsHelp.Content;

type
  TDCControlsHelp = class(TPlatformControlsHelp)
  public
    class function Assignments(const Context: TControlsHelpContext): TArray<TControlsHelpAssignment>; override;
  end;

implementation

uses
  RM.Platforms.DC.Runtime, Core.Platforms.DC.Adapter, RM.Input;

class function TDCControlsHelp.Assignments(const Context: TControlsHelpContext): TArray<TControlsHelpAssignment>;
begin
  Result := inherited Assignments(Context);
  if Length(Result) = 0 then
    Exit;
  for var Extra := Low(TDCExtra) to High(TDCExtra) do
    Result := Result + [TControlsHelpAssignment.Create(DCExtraName(Extra), DCAction(Context.Player, Extra))];
end;

end.

