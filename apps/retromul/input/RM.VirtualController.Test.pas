unit RM.VirtualController.Test;

interface

uses
  System.Classes, System.Types, System.UITypes, FMX.Types, FMX.Controls,
  FMX.Forms, FMX.Layouts, FMX.Objects, FMX.StdCtrls, FMX.ListBox, FMX.Edit,
  FMX.EditBox, FMX.NumberBox, FMX.Controls.Presentation, FMX.Graphics,
  RM.VirtualController;

type
  TVirtualControllerTestForm = class(TForm)
    RootLayout: TLayout;
    SettingsSurface: TRectangle;
    SettingsScroll: TVertScrollBox;
    SettingsLayout: TLayout;
    TitleLabel: TLabel;
    IntroLabel: TLabel;
    ElementLabel: TLabel;
    ElementBox: TComboBox;
    TypeLabel: TLabel;
    TypeBox: TComboBox;
    SideLabel: TLabel;
    SideBox: TComboBox;
    XLabel: TLabel;
    XBox: TNumberBox;
    YLabel: TLabel;
    YBox: TNumberBox;
    WidthLabel: TLabel;
    WidthBox: TNumberBox;
    HeightLabel: TLabel;
    HeightBox: TNumberBox;
    AddButton: TButton;
    RemoveButton: TButton;
    ResetButton: TButton;
    ScaleLabel: TLabel;
    ScaleBar: TTrackBar;
    OpacityLabel: TLabel;
    OpacityBar: TTrackBar;
    PresetLabel: TLabel;
    PresetBox: TComboBox;
    GuidesBox: TCheckBox;
    PreviewLayout: TLayout;
    HeaderLabel: TLabel;
    HintLabel: TLabel;
    StatusLabel: TLabel;
    PreviewSurface: TRectangle;
    ViewportLayout: TLayout;
    ControllerLayout: TLayout;
    GuidesPaint: TPaintBox;
    procedure FormCreate(Sender: TObject);
    procedure FormResize(Sender: TObject);
    procedure FormDeactivate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure ElementChanged(Sender: TObject);
    procedure GeometryEdited(Sender: TObject);
    procedure TypeChanged(Sender: TObject);
    procedure AppearanceChanged(Sender: TObject);
    procedure AddClicked(Sender: TObject);
    procedure RemoveClicked(Sender: TObject);
    procedure ResetClicked(Sender: TObject);
    procedure GuidesPaintPaint(Sender: TObject; Canvas: TCanvas);
    procedure FormTouch(Sender: TObject; const Touches: TTouches; const Action: TTouchAction);
  private
    FController: TVirtualController;
    FUpdating: Boolean;
    FNextId: Integer;
    FNewType: Integer;
    FNewSide: TVirtualSide;
    FNewBounds: TRectF;
    FNativeInput: TObject;
    function SelectedElement: TVirtualElement;
    function EditorBounds: TRectF;
    procedure SaveNewDraft;
    procedure RefreshElements(SelectIndex: Integer);
    procedure UpdateViewport;
    procedure InputChanged(Sender: TObject; Element: TVirtualElement; Part: Integer; Value: Single);
    procedure GeometryChanged(Sender: TObject);
    procedure ResetLayout;
  public
    property Controller: TVirtualController read FController;
  end;

var
  VirtualControllerTestForm: TVirtualControllerTestForm;

implementation

uses
  System.SysUtils, System.Math
  {$IFDEF ANDROID}, RM.TouchInput.Android{$ENDIF};

{$R *.fmx}

procedure TVirtualControllerTestForm.FormCreate(Sender: TObject);
begin
  FController := TVirtualController.Create(Self);
  FController.Parent := ControllerLayout;
  FController.Align := TAlignLayout.Client;
  FController.OnInput := InputChanged;
  FController.OnGeometryChanged := GeometryChanged;
  GuidesPaint.BringToFront;
  TypeBox.ItemIndex := 0;
  PresetBox.ItemIndex := 0;
  ResetLayout;
  {$IFDEF ANDROID}
  FNativeInput := TAndroidTouchInput.Create(FController, Self,
    FController.PointerDown, FController.PointerMove, FController.PointerUp,
    FController.ReleaseAll, True);
  {$ENDIF}
end;

procedure TVirtualControllerTestForm.FormDestroy(Sender: TObject);
begin
  FNativeInput.Free;
  FController.OnInput := nil;
  FController.OnGeometryChanged := nil;
end;

procedure TVirtualControllerTestForm.FormDeactivate(Sender: TObject);
begin
  if FController <> nil then
    FController.ReleaseAll;
end;

procedure TVirtualControllerTestForm.FormTouch(Sender: TObject; const Touches: TTouches; const Action: TTouchAction);
{$IF not Defined(ANDROID)}
var
  T: TTouch;
  P: TPointF;
{$ENDIF}
begin
  {$IF not Defined(ANDROID)}
  if FController = nil then
    Exit;
  if Action = TTouchAction.Cancel then
  begin
    FController.ReleaseAll;
    Exit;
  end;
  for T in Touches do
  begin
    P := FController.AbsoluteToLocal(T.Location);
    case T.Action of
      TTouchAction.Down:
        FController.PointerDown(T.Id, P);
      TTouchAction.Move:
        FController.PointerMove(T.Id, P);
      TTouchAction.Up:
        FController.PointerUp(T.Id);
      TTouchAction.Cancel:
        FController.ReleaseAll;
    end;
  end;
  {$ENDIF}
end;

procedure TVirtualControllerTestForm.ResetLayout;
begin
  FUpdating := True;
  try
    FController.Clear;
    FController.Add(TVirtualDPad.Create('pad', 'PAD', TVirtualSide.Left, RectF(28, 140, 172, 284)));
    FController.Add(TVirtualTrigger.Create('lt', 'LT', TVirtualSide.Left, RectF(28, 20, 88, 116)));
    FController.Add(TVirtualSwitch.Create('mode', 'MODE', TVirtualSide.Left, RectF(108, 42, 220, 82)));
    FController.Add(TVirtualButton.Create('select', 'SEL', TVirtualSide.Left, RectF(180, 234, 226, 280)));
    FController.Add(TVirtualButton.Create('a', 'A', TVirtualSide.Right, RectF(12, 220, 72, 280)));
    FController.Add(TVirtualButton.Create('b', 'B', TVirtualSide.Right, RectF(88, 220, 148, 280)));
    FController.Add(TVirtualButton.Create('c', 'C', TVirtualSide.Right, RectF(164, 220, 224, 280)));
    FController.Add(TVirtualButton.Create('x', 'X', TVirtualSide.Right, RectF(12, 148, 72, 208)));
    FController.Add(TVirtualButton.Create('y', 'Y', TVirtualSide.Right, RectF(88, 148, 148, 208)));
    FController.Add(TVirtualButton.Create('z', 'Z', TVirtualSide.Right, RectF(164, 148, 224, 208)));
    FController.Add(TVirtualTrigger.Create('rt', 'RT', TVirtualSide.Right, RectF(152, 8, 212, 98)));
    FController.Add(TVirtualButton.Create('start', 'START', TVirtualSide.Right, RectF(8, 48, 64, 104)));
    FNextId := 1;
    FNewType := 0;
    FNewSide := TVirtualSide.Left;
    FNewBounds := RectF(92, 120, 156, 184);
    ScaleBar.Value := 1;
    OpacityBar.Value := 0.65;
  finally
    FUpdating := False;
  end;
  RefreshElements(-1);
  AppearanceChanged(Self);
  StatusLabel.Text := 'Нажмите кнопку, удерживайте направление или потяните триггер вверх.';
end;

procedure TVirtualControllerTestForm.ResetClicked(Sender: TObject);
begin
  ResetLayout;
end;

function TVirtualControllerTestForm.SelectedElement: TVirtualElement;
begin
  Result := nil;
  if (FController <> nil) and (ElementBox.ItemIndex > 0) and
    (ElementBox.ItemIndex <= FController.Count) then
    Result := FController[ElementBox.ItemIndex - 1];
end;

procedure TVirtualControllerTestForm.RefreshElements(SelectIndex: Integer);
var
  I: Integer;
begin
  FUpdating := True;
  try
    ElementBox.Items.Clear;
    ElementBox.Items.Add('Новый элемент');
    for I := 0 to FController.Count - 1 do
      ElementBox.Items.Add(FController[I].Id + '  /  ' + FController[I].Caption);
    ElementBox.ItemIndex := EnsureRange(SelectIndex + 1, 0, FController.Count);
  finally
    FUpdating := False;
  end;
  ElementChanged(Self);
end;

procedure TVirtualControllerTestForm.ElementChanged(Sender: TObject);
var
  E: TVirtualElement;
begin
  if FUpdating then
    Exit;
  E := SelectedElement;
  FUpdating := True;
  try
    RemoveButton.Enabled := E <> nil;
    AddButton.Enabled := E = nil;
    TypeBox.Enabled := E = nil;
    if E = nil then
    begin
      TypeBox.ItemIndex := FNewType;
      SideBox.ItemIndex := Ord(FNewSide);
      XBox.Value := FNewBounds.Left;
      YBox.Value := FNewBounds.Top;
      WidthBox.Value := FNewBounds.Width;
      HeightBox.Value := FNewBounds.Height;
    end;
    if E <> nil then
    begin
      XBox.Value := E.Bounds.Left;
      YBox.Value := E.Bounds.Top;
      WidthBox.Value := E.Bounds.Width;
      HeightBox.Value := E.Bounds.Height;
      SideBox.ItemIndex := Ord(E.Side);
      if E is TVirtualDPad then
        TypeBox.ItemIndex := 1
      else if E is TVirtualSwitch then
        TypeBox.ItemIndex := 2
      else if E is TVirtualTrigger then
        TypeBox.ItemIndex := 3
      else
        TypeBox.ItemIndex := 0;
    end;
  finally
    FUpdating := False;
  end;
  GuidesPaint.Repaint;
end;

function TVirtualControllerTestForm.EditorBounds: TRectF;
var
  X, Y, W, H: Single;
begin
  X := EnsureRange(XBox.Value, 0.0, FController.DesignSideSize.Width - 1);
  Y := EnsureRange(YBox.Value, 0.0, FController.DesignSideSize.Height - 1);
  W := EnsureRange(WidthBox.Value, 1.0, FController.DesignSideSize.Width - X);
  H := EnsureRange(HeightBox.Value, 1.0, FController.DesignSideSize.Height - Y);
  Result := RectF(X, Y, X + W, Y + H);
end;

procedure TVirtualControllerTestForm.SaveNewDraft;
begin
  FNewType := Max(0, TypeBox.ItemIndex);
  FNewSide := TVirtualSide(Max(0, SideBox.ItemIndex));
  FNewBounds := EditorBounds;
end;

procedure TVirtualControllerTestForm.TypeChanged(Sender: TObject);
begin
  if FUpdating or (FController = nil) or (SelectedElement <> nil) then
    Exit;
  SaveNewDraft;
end;

procedure TVirtualControllerTestForm.GeometryEdited(Sender: TObject);
var
  E: TVirtualElement;
begin
  if FUpdating or (FController = nil) then
    Exit;
  E := SelectedElement;
  if E = nil then
    SaveNewDraft
  else
  begin
    E.Side := TVirtualSide(Max(0, SideBox.ItemIndex));
    E.Bounds := EditorBounds;
  end;
  // In creation mode reload the draft, never the selected existing element.
  ElementChanged(Self);
end;

procedure TVirtualControllerTestForm.AppearanceChanged(Sender: TObject);
begin
  if FUpdating or (FController = nil) then
    Exit;
  FController.LayoutScale := ScaleBar.Value;
  FController.InkOpacity := OpacityBar.Value;
  ScaleLabel.Text := Format('Масштаб: %.2f', [ScaleBar.Value]);
  OpacityLabel.Text := Format('Непрозрачность: %.0f%%', [OpacityBar.Value * 100]);
  UpdateViewport;
end;

procedure TVirtualControllerTestForm.AddClicked(Sender: TObject);
var
  E: TVirtualElement;
  Id: string;
begin
  if SelectedElement <> nil then
    Exit;
  SaveNewDraft;
  Id := 'custom' + IntToStr(FNextId);
  case FNewType of
    1:
      E := TVirtualDPad.Create(Id, 'PAD', FNewSide, FNewBounds);
    2:
      E := TVirtualSwitch.Create(Id, 'SW', FNewSide, FNewBounds);
    3:
      E := TVirtualTrigger.Create(Id, 'TR', FNewSide, FNewBounds);
  else
    E := TVirtualButton.Create(Id, IntToStr(FNextId), FNewSide, FNewBounds);
  end;
  try
    FController.Add(E);
  except
    E.Free;
    raise;
  end;
  Inc(FNextId);
  RefreshElements(FController.Count - 1);
end;

procedure TVirtualControllerTestForm.RemoveClicked(Sender: TObject);
var
  I: Integer;
begin
  I := ElementBox.ItemIndex - 1;
  FController.Remove(SelectedElement);
  RefreshElements(I - 1);
end;

procedure TVirtualControllerTestForm.UpdateViewport;
var
  W, H: Single;
begin
  if FController = nil then
    Exit;
  case PresetBox.ItemIndex of
    1:
      begin
        W := 960;
        H := 320;
      end;
    2:
      begin
        W := 1280;
        H := 400;
      end;
    3:
      begin
        W := 640;
        H := 360;
      end;
  else
    W := ViewportLayout.Width - 16;
    H := ViewportLayout.Height - 16;
  end;
  ControllerLayout.Width := Max(1, Min(W, ViewportLayout.Width - 16));
  ControllerLayout.Height := Max(1, Min(H, ViewportLayout.Height - 16));
  HintLabel.Text := Format('Область %.0f × %.0f  ·  масштаб %.2f  ·  две независимые стороны',
    [ControllerLayout.Width, ControllerLayout.Height, FController.EffectiveScale]);
  GuidesPaint.Repaint;
end;

procedure TVirtualControllerTestForm.FormResize(Sender: TObject);
begin
  UpdateViewport;
end;

procedure TVirtualControllerTestForm.GeometryChanged(Sender: TObject);
begin
  GuidesPaint.Repaint;
end;

procedure TVirtualControllerTestForm.InputChanged(Sender: TObject; Element: TVirtualElement; Part: Integer; Value: Single);
var
  I, J: Integer;
  E: TVirtualElement;
  S: string;
begin
  S := '';
  for I := 0 to FController.Count - 1 do
  begin
    E := FController[I];
    for J := 0 to E.PartCount - 1 do
      if E.Value(J) > 0 then
        S := S + Format('%s[%d]=%.2f   ', [E.Id, J, E.Value(J)]);
  end;
  if S = '' then
    S := 'Все элементы отпущены';
  StatusLabel.Text := S;
  GuidesPaint.Repaint;
end;

procedure TVirtualControllerTestForm.GuidesPaintPaint(Sender: TObject; Canvas: TCanvas);
var
  E: TVirtualElement;
  L, R, B, TextRect: TRectF;
  P, A: TPointF;
  I: Integer;
  S: string;
begin
  if FController = nil then
    Exit;
  Canvas.Stroke.Kind := TBrushKind.Solid;
  Canvas.Fill.Kind := TBrushKind.Solid;
  L := FController.SideBounds(TVirtualSide.Left);
  R := FController.SideBounds(TVirtualSide.Right);
  Canvas.Stroke.Color := $FF36414B;
  Canvas.Stroke.Thickness := 1;
  Canvas.DrawRect(GuidesPaint.LocalRect, 0, 0, AllCorners, 1);
  // This screen marker belongs to the demo only, never to the control.
  B := RectF(L.Right + 16, 58, R.Left - 16, GuidesPaint.Height - 20);
  if (B.Width > 80) and (B.Height > 80) then
  begin
    Canvas.DrawRect(B, 10, 10, AllCorners, 0.8);
    Canvas.Fill.Color := $FF66717A;
    Canvas.Font.Size := 16;
    Canvas.FillText(B, 'ЭКРАН', False, 1, [], TTextAlign.Center, TTextAlign.Center);
  end;
  if not GuidesBox.IsChecked then
    Exit;
  Canvas.Stroke.Color := $FF485661;
  Canvas.DrawLine(PointF(L.Right, 0), PointF(L.Right, GuidesPaint.Height), 0.6);
  Canvas.DrawLine(PointF(R.Left, 0), PointF(R.Left, GuidesPaint.Height), 0.6);
  E := SelectedElement;
  if E = nil then
    Exit;
  for I := 0 to E.PartCount - 1 do
  begin
    B := FController.PartBounds(E, I);
    P := FController.PartCenter(E, I);
    A := PointF(GuidesPaint.Width / 2, 22 + I * 28);
    Canvas.Stroke.Color := $FF66C8FF;
    Canvas.Fill.Color := $FF66C8FF;
    Canvas.DrawRect(B, 2, 2, AllCorners, 0.8);
    Canvas.DrawLine(A, P, 0.8);
    Canvas.FillEllipse(RectF(P.X - 3, P.Y - 3, P.X + 3, P.Y + 3), 1);
    S := Format('%s[%d]  (%.1f, %.1f)  %.1f × %.1f', [E.Id, I, B.Left, B.Top, B.Width, B.Height]);
    TextRect := RectF(A.X - 175, A.Y - 18, A.X + 175, A.Y);
    Canvas.Font.Size := 11;
    Canvas.FillText(TextRect, S, False, 1, [], TTextAlign.Center, TTextAlign.Center);
  end;
end;

end.

