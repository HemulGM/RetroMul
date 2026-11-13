unit RM.Platforms.N64.Help;

interface

uses
  RM.ControlsHelp.Content;

type
  TN64ControlsHelp = class(TPlatformControlsHelp)
  public
    class function Assignments(const Context: TControlsHelpContext): TArray<TControlsHelpAssignment>; override;
  end;

implementation

uses
  RM.Platforms.N64.Input, RM.Input;

class function TN64ControlsHelp.Assignments(const Context: TControlsHelpContext): TArray<TControlsHelpAssignment>;
begin
  Result := inherited Assignments(Context);
  if Length(Result) > 0 then
  begin
    Result := Result + [TControlsHelpAssignment.Create('L', N64LAction + Context.Player)];
    for var Direction := Low(TN64StickDirection) to High(TN64StickDirection) do
      Result := Result + [TControlsHelpAssignment.Create(N64StickName(Direction), N64StickActionOf(Context.Player, Direction))];
  end;
end;

end.

