unit RM.Platforms.ZX.Help;

interface

uses
  RM.ControlsHelp.Content;

type
  TZXControlsHelp = class(TPlatformControlsHelp)
  public
    class function Info(const Context: TControlsHelpContext): TControlsHelpInfo; override;
    class function StandardShortcutAvailable(const Context: TControlsHelpContext; const Id: string): Boolean; override;
    class function Shortcuts(const Context: TControlsHelpContext): TArray<TControlsHelpShortcut>; override;
  end;

implementation

uses
  FMX.Types, RM.Styles;

class function TZXControlsHelp.Info(const Context: TControlsHelpContext): TControlsHelpInfo;
begin
  Result := inherited Info(Context);
  if Context.KeyboardPeripheral then
    Result.Note := Translate('ZX: F5/F6 save/load; F7 tape; F8 rewind; F9 NMI. P, R, Shift+R and Ctrl+O go to ZX. Use toolbar buttons for emulator actions.')
  else
    Result.Note := Translate('ZX: F5/F6 save/load; F7 tape; F8 rewind; F9 NMI.');
  Result.Note := Result.Note + ' ' + Translate('Hold F10 to fast-forward.');
end;

class function TZXControlsHelp.StandardShortcutAvailable(const Context: TControlsHelpContext; const Id: string): Boolean;
begin
  if (Id = 'save') or (Id = 'load') then
    Exit(True);
  if (Id = 'screenshot') or (Id = 'coin') then
    Exit(False);
  Result := inherited StandardShortcutAvailable(Context, Id);
end;

class function TZXControlsHelp.Shortcuts(const Context: TControlsHelpContext): TArray<TControlsHelpShortcut>;
begin
  Result := TArray<TControlsHelpShortcut>.Create(
    TControlsHelpShortcut.Create('tape-play', 'Play / pause tape', 'F7'),
    TControlsHelpShortcut.Create('tape-rewind', 'Rewind tape', 'F8'),
    TControlsHelpShortcut.Create('nmi', 'NMI / Magic button', 'F9'));
end;

end.

