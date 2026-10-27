unit RM.Toolbar;

interface

uses
  System.Classes, FMX.StdCtrls;

type
  TToolbarSplitButton = class(TButton)
  private
    FArrow: TSpeedButton;
    procedure ArrowClick(Sender: TObject);
  protected
    procedure ApplyStyle; override;
    procedure Resize; override;
  public
    constructor Create(AOwner: TComponent); override;
  end;

implementation

uses
  System.Types, System.Math, FMX.Graphics, FMX.Types, FMX.Objects, RM.Icons,
  RM.Styles;

constructor TToolbarSplitButton.Create(AOwner: TComponent);
begin
  inherited;
  FArrow := TSpeedButton.Create(Self);
  FArrow.Parent := Self;
  FArrow.Name := 'MenuArrow';
  FArrow.Align := TAlignLayout.Right;
  FArrow.Width := 26;
  FArrow.StyleLookup := 'transparentbuttonstyle';
  FArrow.CanFocus := False;
  AddButtonIcon(FArrow, IconChevronDown, 12);
  FArrow.Hint := Translate('More actions');
  FArrow.ShowHint := True;
  FArrow.OnClick := ArrowClick;
  var Divider := TRectangle.Create(FArrow);
  Divider.Parent := FArrow;
  Divider.Align := TAlignLayout.Left;
  Divider.Width := 1;
  Divider.Margins.Top := 9;
  Divider.Margins.Bottom := 9;
  Divider.Fill.Color := $406C7485;
  Divider.Stroke.Kind := TBrushKind.None;
  Divider.HitTest := False;
  Resize;
end;

procedure TToolbarSplitButton.ApplyStyle;
begin
  inherited;
  StylesData['text.Margins.Right'] := 32;
end;

procedure TToolbarSplitButton.Resize;
begin
  inherited;
  if FArrow <> nil then
  begin
    FArrow.Width := 26;
    FArrow.Hint := Translate('More actions');
  end;
end;

procedure TToolbarSplitButton.ArrowClick(Sender: TObject);
begin
  if not Enabled or (PopupMenu = nil) then
    Exit;

  var Point := LocalToScreen(TPointF.Create(0, Height));
  PopupMenu.Popup(Point.X, Point.Y);
end;

end.

