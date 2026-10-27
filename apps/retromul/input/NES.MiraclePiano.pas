unit NES.MiraclePiano;

interface

uses
  System.Classes, System.Types, System.UITypes, System.Generics.Collections,
  FMX.Types, FMX.Controls, FMX.Forms, NES.MiraclePianoDevice, NES.Controller;

type
  TNesMiraclePiano = class(TControl)
  private
    type
      TVisualKey = record
        Key: Integer;
        Bounds: TRectF;
        Caption: string;
        Black: Boolean;
      end;
  private
    FContacts: TDictionary<NativeInt, Integer>;
    FVisualKeys: TArray<TVisualKey>;
    FKeys, FCoreKeys: TMiracleKeys;
    FButtons: TNesButtons;
    FOctave: Integer;
    FOnChange: TNotifyEvent;
    FNativeInput: TObject;
    procedure LayoutKeys;
    procedure AddKey(Key: Integer; const Bounds: TRectF; const Caption: string; Black: Boolean = False);
    function KeyAt(const Point: TPointF): Integer;
    procedure UpdateKeys;
    procedure SetCoreKeys(const Value: TMiracleKeys);
  protected
    procedure Paint; override;
    procedure Resize; override;
    procedure EnabledChanged; override;
    procedure VisibleChanged; override;
    procedure AncestorVisibleChanged(const Visible: Boolean); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Single); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Single); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Single); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    class function PreferredHeight(AvailableWidth, AvailableHeight: Single): Single; static;
    procedure AttachToForm(Form: TCommonCustomForm);
    procedure PointerDown(Id: NativeInt; const Point: TPointF);
    procedure PointerMove(Id: NativeInt; const Point: TPointF);
    procedure PointerUp(Id: NativeInt);
    procedure ReleaseAll;
    function ButtonBounds(Key: Integer): TRectF;
    property Keys: TMiracleKeys read FKeys;
    property Buttons: TNesButtons read FButtons;
    property CoreKeys: TMiracleKeys read FCoreKeys write SetCoreKeys;
  published
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

implementation

uses
  System.SysUtils, System.Math, FMX.Graphics
  {$IFDEF ANDROID}, RM.TouchInput.Android{$ENDIF};

const
  MENU_BASE = 58;
  OCTAVE_DOWN = 66;
  OCTAVE_UP = 67;

constructor TNesMiraclePiano.Create(AOwner: TComponent);
begin
  inherited;
  FContacts := TDictionary<NativeInt, Integer>.Create;
  FOctave := 1;
  HitTest := True;
  AutoCapture := True;
  CanFocus := False;
  SetBounds(0, 0, 850, 230);
  LayoutKeys;
end;

destructor TNesMiraclePiano.Destroy;
begin
  FreeAndNil(FNativeInput);
  FOnChange := nil;
  FreeAndNil(FContacts);
  inherited;
end;

class function TNesMiraclePiano.PreferredHeight(AvailableWidth, AvailableHeight: Single): Single;
begin
  Result := Max(0, Min(AvailableWidth * 0.30, AvailableHeight * 0.45));
end;

procedure TNesMiraclePiano.AttachToForm(Form: TCommonCustomForm);
begin
  ReleaseAll;
  FreeAndNil(FNativeInput);
  {$IFDEF ANDROID}
  if Form <> nil then
    FNativeInput := TAndroidTouchInput.Create(Self, Form, PointerDown, PointerMove, PointerUp, ReleaseAll);
  {$ENDIF}
end;

procedure TNesMiraclePiano.AddKey(Key: Integer; const Bounds: TRectF; const Caption: string; Black: Boolean);
begin
  var I := Length(FVisualKeys);
  SetLength(FVisualKeys, I + 1);
  FVisualKeys[I].Key := Key;
  FVisualKeys[I].Bounds := Bounds;
  FVisualKeys[I].Caption := Caption;
  FVisualKeys[I].Black := Black;
end;

procedure TNesMiraclePiano.LayoutKeys;
const
  Names: array[0..8] of string = ('Piano', 'Harpsi.', 'Organ', 'Vibes', 'E.Piano', 'Synth', 'Vol +', 'Vol -', 'Pedal');
  PanelKeys: array[0..8] of Integer = (52, 53, 54, 55, 56, 57, 50, 51, 49);
  MenuKeys: array[0..9] of Integer = (OCTAVE_DOWN, OCTAVE_UP, MENU_BASE + 6,
    MENU_BASE + 4, MENU_BASE + 5, MENU_BASE + 7, MENU_BASE + 3, MENU_BASE,
    MENU_BASE + 2, MENU_BASE + 1);
  MenuNames: array[0..9] of string = ('Oct -', 'Oct +', 'Left', 'Up', 'Down', 'Right', 'Start', 'A / Next', 'Select', 'Back');
  NoteNames: array[0..11] of string = ('C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B');
begin
  SetLength(FVisualKeys, 0);
  var RowHeight := Height * 0.18;
  var W := Width / 9;
  for var I := 0 to 8 do
  begin
    AddKey(PanelKeys[I], RectF(I * W + 2, 2, (I + 1) * W - 2, RowHeight - 2), Names[I]);
  end;
  W := Width / 10;
  for var I := 0 to 9 do
    AddKey(MenuKeys[I], RectF(I * W + 2, RowHeight + 2, (I + 1) * W - 2, RowHeight * 2 - 2), MenuNames[I]);
  var Top := RowHeight * 2 + 4;
  var Bottom := Height - 15;
  var WhiteWidth := Width / 15;
  var WhiteIndex := 0;
  for var K := FOctave * 12 to FOctave * 12 + 24 do
    if not ((K mod 12) in [1, 3, 6, 8, 10]) then
    begin
      AddKey(K, RectF(WhiteIndex * WhiteWidth + 1, Top, (WhiteIndex + 1) * WhiteWidth - 1, Bottom),
        NoteNames[K mod 12] + IntToStr(2 + K div 12));
      Inc(WhiteIndex);
    end;
  WhiteIndex := 0;
  for var K := FOctave * 12 to FOctave * 12 + 24 do
    if (K mod 12) in [1, 3, 6, 8, 10] then
      AddKey(K, RectF(WhiteIndex * WhiteWidth - WhiteWidth * 0.30, Top,
          WhiteIndex * WhiteWidth + WhiteWidth * 0.30, Top + (Bottom - Top) * 0.62), '', True)
    else
      Inc(WhiteIndex);
end;

function TNesMiraclePiano.KeyAt(const Point: TPointF): Integer;
begin
  Result := -1;
  if not LocalRect.Contains(Point) then
    Exit;
  // Black keys paint over white keys and take priority for hit testing.
  for var I := High(FVisualKeys) downto 0 do
    if FVisualKeys[I].Bounds.Contains(Point) then
      Exit(FVisualKeys[I].Key);
end;

function TNesMiraclePiano.ButtonBounds(Key: Integer): TRectF;
begin
  Result := TRectF.Empty;
  for var K in FVisualKeys do
    if K.Key = Key then
      Exit(K.Bounds);
end;

procedure TNesMiraclePiano.UpdateKeys;
begin
  var Keys: TMiracleKeys := [];
  var Buttons: TNesButtons := [];
  for var Key in FContacts.Values do
    if (Key >= 0) and (Key <= 57) then
      Include(Keys, TMiracleKey(Key))
    else if (Key >= MENU_BASE) and (Key < OCTAVE_DOWN) then
      Include(Buttons, TNesButton(Key - MENU_BASE));
  if (Keys = FKeys) and (Buttons = FButtons) then
    Exit;
  FKeys := Keys;
  FButtons := Buttons;
  Repaint;
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

procedure TNesMiraclePiano.SetCoreKeys(const Value: TMiracleKeys);
begin
  if Value = FCoreKeys then
    Exit;
  FCoreKeys := Value;
  Repaint;
end;

procedure TNesMiraclePiano.PointerDown(Id: NativeInt; const Point: TPointF);
begin
  if not AbsoluteEnabled or not ParentedVisible then
    Exit;
  var K := KeyAt(Point);
  if K in [OCTAVE_DOWN, OCTAVE_UP] then
  begin
    ReleaseAll;
    if K = OCTAVE_DOWN then
      FOctave := Max(0, FOctave - 1)
    else
      FOctave := Min(2, FOctave + 1);
    LayoutKeys;
    Repaint;
    Exit;
  end;
  FContacts.AddOrSetValue(Id, K);
  UpdateKeys;
end;

procedure TNesMiraclePiano.PointerMove(Id: NativeInt; const Point: TPointF);
begin
  if not AbsoluteEnabled or not ParentedVisible then
  begin
    ReleaseAll;
    Exit;
  end;
  if not FContacts.ContainsKey(Id) then
    Exit;
  var K := KeyAt(Point);
  if K >= OCTAVE_DOWN then
    K := -1;
  FContacts.AddOrSetValue(Id, K);
  UpdateKeys;
end;

procedure TNesMiraclePiano.PointerUp(Id: NativeInt);
begin
  FContacts.Remove(Id);
  UpdateKeys;
end;

procedure TNesMiraclePiano.ReleaseAll;
begin
  if FContacts = nil then
    Exit;
  FContacts.Clear;
  FCoreKeys := [];
  UpdateKeys;
  Repaint;
end;

procedure TNesMiraclePiano.Resize;
begin
  inherited;
  ReleaseAll;
  LayoutKeys;
  Repaint;
end;

procedure TNesMiraclePiano.EnabledChanged;
begin
  inherited;
  if not Enabled then
    ReleaseAll;
end;

procedure TNesMiraclePiano.VisibleChanged;
begin
  inherited;
  if not Visible then
    ReleaseAll;
end;

procedure TNesMiraclePiano.AncestorVisibleChanged(const Visible: Boolean);
begin
  inherited;
  if not Visible then
    ReleaseAll;
end;

procedure TNesMiraclePiano.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  inherited;
  if Button = TMouseButton.mbLeft then
    PointerDown(-1, PointF(X, Y));
end;

procedure TNesMiraclePiano.MouseMove(Shift: TShiftState; X, Y: Single);
begin
  inherited;
  if ssLeft in Shift then
    PointerMove(-1, PointF(X, Y));
end;

procedure TNesMiraclePiano.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  inherited;
  if Button = TMouseButton.mbLeft then
    PointerUp(-1);
end;

procedure TNesMiraclePiano.Paint;
begin
  inherited;
  Canvas.Fill.Kind := TBrushKind.Solid;
  Canvas.Fill.Color := $FF252C35;
  Canvas.FillRect(LocalRect, 0, 0, [], AbsoluteOpacity);
  Canvas.Font.Family := 'sans-serif';
  Canvas.Font.Style := [];
  for var K in FVisualKeys do
  begin
    var Down := False;
    if K.Key <= 57 then
      Down := TMiracleKey(K.Key) in (FKeys + FCoreKeys)
    else if K.Key < OCTAVE_DOWN then
      Down := TNesButton(K.Key - MENU_BASE) in FButtons;
    if Down then
      Canvas.Fill.Color := $FFEDBB58
    else if K.Black then
      Canvas.Fill.Color := $FF11151C
    else if K.Key >= 49 then
      Canvas.Fill.Color := $FF455466
    else
      Canvas.Fill.Color := $FFF4F0E6;
    Canvas.FillRect(K.Bounds, 2, 2, AllCorners, AbsoluteOpacity);
    Canvas.Font.Size := Max(7, Min(K.Bounds.Height * 0.28, K.Bounds.Width * 0.15));
    if (K.Key < 49) or Down then
      Canvas.Fill.Color := $FF20252C
    else
      Canvas.Fill.Color := $FFF4F0E6;
    var R := K.Bounds;
    if K.Key < 49 then
      R.Top := R.Bottom - 22;
    Canvas.FillText(R, K.Caption, False, AbsoluteOpacity, [], TTextAlign.Center, TTextAlign.Center);
  end;
  Canvas.Fill.Color := $FFBBC8D8;
  Canvas.Font.Size := 10;
  Canvas.FillText(RectF(0, Height - 14, Width, Height),
    'C3: Z S X D C V G B H N J M   |   C4: Q 2 W 3 E R 5 T 6 Y 7 U   |   Pedal: Space',
    False, AbsoluteOpacity, [], TTextAlign.Center, TTextAlign.Center);
end;

end.

