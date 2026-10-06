unit NES.DataRecorder;

interface

uses
  System.Classes, System.Types, System.UITypes, FMX.Types, FMX.Controls,
  FMX.StdCtrls, NES.FamicomDataRecorder;

type
  TTapeActionEvent = procedure(Sender: TObject; Action: TTapeAction; const FileName: string) of object;

  TNesDataRecorder = class(TControl)
  private
    FProgress: TTapeProgress;
    FButtons: array[TTapeAction] of TButton;
    FOnAction: TTapeActionEvent;
    FOnChooseFile: TNotifyEvent;
    FOnSaveAs: TNotifyEvent;
    procedure ButtonClick(Sender: TObject);
    procedure SetProgress(const Value: TTapeProgress);
    procedure LayoutButtons;
    function GetStateText: string;
    function GetActivityText: string;
    function GetCounterText: string;
    function GetPositionText: string;
    function GetFileText: string;
  protected
    procedure Paint; override;
    procedure Resize; override;
  public
    constructor Create(AOwner: TComponent); override;
    class function PreferredHeight(AvailableWidth, AvailableHeight: Single): Single; static;
    procedure RequestAction(Action: TTapeAction; const FileName: string = '');
    function ActionButton(Action: TTapeAction): TButton;
    function MapBounds: TRectF;
    property Progress: TTapeProgress read FProgress write SetProgress;
    property StateText: string read GetStateText;
    property ActivityText: string read GetActivityText;
    property CounterText: string read GetCounterText;
    property PositionText: string read GetPositionText;
    property FileText: string read GetFileText;
  published
    property Align;
    property Anchors;
    property Enabled;
    property Margins;
    property Position;
    property Size;
    property Visible;
    property OnAction: TTapeActionEvent read FOnAction write FOnAction;
    property OnChooseFile: TNotifyEvent read FOnChooseFile write FOnChooseFile;
    property OnSaveAs: TNotifyEvent read FOnSaveAs write FOnSaveAs;
  end;

implementation

uses
  System.SysUtils, System.Math, FMX.Graphics;

type
  // Keep TButton click/capture/accessibility behavior while drawing mechanical keys.
  TRecorderButton = class(TButton)
  protected
    procedure ApplyStyle; override;
    procedure Paint; override;
    procedure SetIsPressed(const Value: Boolean); override;
  end;

procedure TRecorderButton.ApplyStyle;
begin
  inherited;
  if ResourceLink is TControl then
    TControl(ResourceLink).Visible := False;
end;

procedure TRecorderButton.SetIsPressed(const Value: Boolean);
begin
  inherited;
  Repaint;
end;

procedure TRecorderButton.Paint;
begin
  var Opacity := AbsoluteOpacity;
  if not AbsoluteEnabled then
    Opacity := Opacity * 0.45;
  var R := LocalRect;
  Canvas.Fill.Kind := TBrushKind.Solid;
  Canvas.Fill.Color := $FF776A54;
  Canvas.FillRect(R, 2, 2, AllCorners, Opacity);
  R.Inflate(-1, -1);
  if IsPressed then
    R.Top := R.Top + 2
  else
    R.Bottom := R.Bottom - 2;
  Canvas.Fill.Color := $FFE9E2CE;
  if Tag = Ord(TapeRecord) then
    Canvas.Fill.Color := $FF934037;
  Canvas.FillRect(R, 2, 2, AllCorners, Opacity);
  Canvas.Font.Family := 'Arial';
  Canvas.Font.Style := [TFontStyle.fsBold];
  Canvas.Font.Size := Max(8, Min(12, Height * 0.45));
  Canvas.Fill.Color := $FF41382E;
  if Tag = Ord(TapeRecord) then
    Canvas.Fill.Color := $FFFFEFCE;
  Canvas.FillText(R, Text, False, Opacity, [], TTextAlign.Center, TTextAlign.Center);
end;

constructor TNesDataRecorder.Create(AOwner: TComponent);
const
  Names: array[TTapeAction] of string = ('Play', 'Record', 'Stop', 'Rewind', 'Forward', 'ChooseFile', 'DefaultFile', 'SaveAs');
  Captions: array[TTapeAction] of string = ('Play', 'Record', 'Stop', '<<', '>>', 'Choose file...', 'ROM cassette', 'Save as...');
begin
  inherited;
  SetSize(480, 212);
  HitTest := False;
  for var Action := Low(TTapeAction) to High(TTapeAction) do
  begin
    FButtons[Action] := TRecorderButton.Create(Self);
    FButtons[Action].StyleLookup := 'buttonstyle';
    FButtons[Action].Name := 'Tape' + Names[Action];
    FButtons[Action].Parent := Self;
    FButtons[Action].Tag := Ord(Action);
    FButtons[Action].Text := Captions[Action];
    FButtons[Action].CanFocus := False;
    FButtons[Action].OnClick := ButtonClick;
  end;
  FButtons[TapeRewind].Hint := 'Rewind 5% of the cassette';
  FButtons[TapeForward].Hint := 'Advance 5% of the cassette';
  LayoutButtons;
end;

class function TNesDataRecorder.PreferredHeight(AvailableWidth, AvailableHeight: Single): Single;
begin
  Result := Min(212, Max(150, AvailableHeight * 0.4));
  if AvailableWidth < 360 then
    Result := Max(Result, 198);
end;

function TNesDataRecorder.ActionButton(Action: TTapeAction): TButton;
begin
  Result := FButtons[Action];
end;

procedure TNesDataRecorder.ButtonClick(Sender: TObject);
begin
  RequestAction(TTapeAction(TButton(Sender).Tag));
end;

procedure TNesDataRecorder.RequestAction(Action: TTapeAction; const FileName: string);
begin
  if not Enabled or not Visible then
    Exit;
  if (Action in [TapeRewind, TapeForward]) and ((FProgress.State = TapeRecording) or (FProgress.TapeBytes = 0)) then
    Exit;

  if (Action = TapeSelectFile) and (FileName = '') then
  begin
    if Assigned(FOnChooseFile) then
      FOnChooseFile(Self);
  end
  else if (Action = TapeSaveAs) and (FileName = '') then
  begin
    if Assigned(FOnSaveAs) then
      FOnSaveAs(Self);
  end
  else if Assigned(FOnAction) then
    FOnAction(Self, Action, FileName);
end;

procedure TNesDataRecorder.SetProgress(const Value: TTapeProgress);
begin
  FProgress := Value;
  FButtons[TapeRewind].Enabled := (Value.State <> TapeRecording) and (Value.TapeBytes > 0);
  FButtons[TapeForward].Enabled := FButtons[TapeRewind].Enabled;
  FButtons[TapeDefaultFile].Enabled := not Value.DefaultFile;
  Repaint;
end;

function TNesDataRecorder.GetStateText: string;
begin
  case FProgress.State of
    TapePlaying:
      Result := 'Data Recorder - playing';
    TapeRecording:
      Result := 'Data Recorder - recording';
  else
    Result := 'Data Recorder - stopped';
  end;
end;

function TNesDataRecorder.GetActivityText: string;
begin
  if FProgress.Reading then
    Result := 'Game is reading'
  else if FProgress.Writing then
    Result := 'Game is writing'
  else
    Result := 'Waiting for game';
  Result := Result + Format('  |  I/O: R %d / W %d', [FProgress.ReadAccesses, FProgress.WriteAccesses]);
end;

function TNesDataRecorder.GetCounterText: string;
begin
  Result := Format('READ %d B [$%s]   WRITE %d B [$%s]', [
      FProgress.ReadBytes, IntToHex(FProgress.LastReadByte, 2),
      FProgress.WrittenBytes, IntToHex(FProgress.LastWrittenByte, 2)]);
end;

function TNesDataRecorder.GetPositionText: string;
begin
  if FProgress.State = TapeRecording then
    Result := Format('Tape signal: %d bytes recorded', [FProgress.WrittenBytes])
  else if FProgress.TapeBytes = 0 then
    Result := 'Empty cassette'
  else
    Result := Format('Position: %d / %d B (%.1f%%)', [
        FProgress.PositionBytes, FProgress.TapeBytes,
        FProgress.PositionBytes * 100.0 / FProgress.TapeBytes]);
end;

function TNesDataRecorder.GetFileText: string;
begin
  if FProgress.DefaultFile then
    Result := 'ROM cassette: '
  else
    Result := 'Selected: ';
  Result := Result + ExtractFileName(FProgress.FileName);
end;

function TNesDataRecorder.MapBounds: TRectF;
begin
  Result := RectF(10, Height * 0.44, Max(10, Width - 10), Height * 0.53);
end;

procedure TNesDataRecorder.LayoutButtons;
begin
  if FButtons[TapePlay] = nil then
    Exit;

  var W := Max(1, (Width - 20 - 4 * 5) / 5);
  for var Action := TapePlay to TapeForward do
    FButtons[Action].SetBounds(10 + Ord(Action) * (W + 5), Height * 0.70, W, Height * 0.12);
  W := Max(1, (Width - 30) / 3);
  FButtons[TapeSelectFile].SetBounds(10, Height * 0.85, W, Height * 0.12);
  FButtons[TapeDefaultFile].SetBounds(15 + W, Height * 0.85, W, Height * 0.12);
  FButtons[TapeSaveAs].SetBounds(20 + W * 2, Height * 0.85, W, Height * 0.12);
end;

procedure TNesDataRecorder.Resize;
begin
  inherited;
  LayoutButtons;
end;

procedure TNesDataRecorder.Paint;

  procedure Text(const Value: string; Y: Single; Color: TAlphaColor; Bold: Boolean = False);
  begin
    Canvas.Fill.Color := Color;
    if Bold then
      Canvas.Font.Style := [TFontStyle.fsBold]
    else
      Canvas.Font.Style := [];
    var TextRight := Width * 0.55;
    if Width < 480 then
      TextRight := Width - 10;
    Canvas.FillText(RectF(10, Y, TextRight, Y + Height * 0.085), Value,
      False, AbsoluteOpacity, [], TTextAlign.Leading, TTextAlign.Center);
  end;

begin
  inherited;
  Canvas.Fill.Kind := TBrushKind.Solid;
  Canvas.Fill.Color := $FFDACCA8;
  Canvas.FillRect(LocalRect, 7, 7, AllCorners, AbsoluteOpacity);
  Canvas.Stroke.Kind := TBrushKind.Solid;
  Canvas.Stroke.Color := $FF8C7755;
  Canvas.Stroke.Thickness := 1;
  Canvas.DrawRect(LocalRect, 7, 7, AllCorners, AbsoluteOpacity);
  // Smoked cassette window and twin reels of the Famicom data recorder.
  var Window := RectF(Width * 0.59, Height * 0.04, Width - 10, Height * 0.37);
  if Width < 480 then
    Window := RectF(Width * 0.76, Height * 0.015, Width - 10, Height * 0.105);
  Canvas.Fill.Color := $FF413B32;
  Canvas.FillRect(Window, 4, 4, AllCorners, AbsoluteOpacity);
  Canvas.Fill.Color := $FFB7AA87;
  var ReelSize := Min(Window.Height * 0.64, Window.Width * 0.34);
  for var I := 0 to 1 do
  begin
    var CX := Window.Left + Window.Width * (0.28 + I * 0.44);
    var CY := Window.CenterPoint.Y;
    var Reel := RectF(CX - ReelSize / 2, CY - ReelSize / 2, CX + ReelSize / 2, CY + ReelSize / 2);
    Canvas.Fill.Color := $FFB7AA87;
    Canvas.FillEllipse(Reel, AbsoluteOpacity);
    Reel.Inflate(-ReelSize * 0.30, -ReelSize * 0.30);
    Canvas.Fill.Color := $FF413B32;
    Canvas.FillEllipse(Reel, AbsoluteOpacity);
  end;
  Canvas.Font.Family := 'sans-serif';
  Canvas.Font.Size := Max(10, Min(13, Width / 28));
  Text(StateText, Height * 0.025, $FF41382E, True);
  var Color: TAlphaColor := $FF75634D;
  if FProgress.Reading then
    Color := $FF47744E
  else if FProgress.Writing then
    Color := $FFA03932;
  Text(ActivityText, Height * 0.13, Color);
  Text(CounterText, Height * 0.23, $FF41382E);
  Text(PositionText, Height * 0.33, $FF75634D);
  var R := MapBounds;
  Canvas.Fill.Color := $FF352F28;
  Canvas.FillRect(R, 3, 3, [], AbsoluteOpacity);
  Canvas.Stroke.Kind := TBrushKind.Solid;
  Canvas.Stroke.Thickness := 3;
  Canvas.Stroke.Color := $FF47744E;
  if FProgress.State = TapeRecording then
    Canvas.Stroke.Color := $FFA03932;
  for var i := 0 to 255 do
    if FProgress.SignalMap[i] <> 0 then
      Canvas.DrawLine(PointF(R.Left + R.Width * i / 256, R.CenterPoint.Y),
        PointF(R.Left + R.Width * (i + 1) / 256, R.CenterPoint.Y), AbsoluteOpacity);
  if FProgress.TapeBytes > 0 then
  begin
    var X := R.Left + R.Width * Min(1.0, FProgress.PositionBytes / FProgress.TapeBytes);
    Canvas.Stroke.Color := $FF41382E;
    Canvas.Stroke.Thickness := 2;
    Canvas.DrawLine(PointF(X, R.Top), PointF(X, R.Bottom), AbsoluteOpacity);
  end;
  Canvas.Fill.Color := $FF75634D;
  Canvas.Font.Style := [];
  Canvas.FillText(RectF(10, Height * 0.57, Width - 10, Height * 0.655), FileText,
    False, AbsoluteOpacity, [], TTextAlign.Leading, TTextAlign.Center);
end;

end.

