unit RM.ControlsHelp.Shortcut;

interface

uses
  System.Classes, FMX.Types, FMX.Controls, FMX.Forms, FMX.Layouts, FMX.StdCtrls,
  FMX.Objects, RM.ControlsHelp.Content, FMX.Controls.Presentation;

type
  TControlsHelpShortcutView = class(TFrame)
    LayoutShortcutRow: TLayout;
    LabelShortcutCaption, LabelShortcutKey: TLabel;
    RectangleShortcutKey: TRectangle;
  public
    procedure Configure(const Shortcut: TControlsHelpShortcut);
    procedure SetCaptionWidth(Width: Single);
  end;

implementation

uses
  RM.Styles;

{$R *.fmx}

procedure TControlsHelpShortcutView.Configure(const Shortcut: TControlsHelpShortcut);
begin
  TagString := Shortcut.Id;
  LabelShortcutCaption.Text := Translate(Shortcut.Caption);
  LabelShortcutKey.Text := Shortcut.Keys;
  LabelShortcutKey.Hint := Shortcut.Keys;
  if not Shortcut.Available then
    Opacity := 0.4;
end;

procedure TControlsHelpShortcutView.SetCaptionWidth(Width: Single);
begin
  LabelShortcutCaption.Width := Width;
end;

end.

