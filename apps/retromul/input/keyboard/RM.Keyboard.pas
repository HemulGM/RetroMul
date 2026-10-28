unit RM.Keyboard;

interface

uses
  System.Classes, System.Types, System.UITypes, System.Generics.Collections, FMX.Types, FMX.Controls,
  FMX.Forms, Core.Input.Keyboard;

type
  // Touch attachment is shared by host-code and hardware-matrix keyboards.
  TKeyboardControl = class(TControl)
  protected
    FNativeInput: TObject;
    procedure DetachNativeInput;
  public
    destructor Destroy; override;
    procedure AttachToForm(Form: TCommonCustomForm);
    procedure PointerDown(Id: NativeInt; const Point: TPointF); virtual; abstract;
    procedure PointerMove(Id: NativeInt; const Point: TPointF); virtual; abstract;
    procedure PointerUp(Id: NativeInt); virtual; abstract;
    procedure ReleaseAll; virtual; abstract;
  end;

  TScreenKeyboard = class(TKeyboardControl)
  private
    type
      TVisualKey = record
        Code: Byte;
        Caption: string;
        Sticky: Boolean;
        Bounds: TRectF;
      end;
    var
      FVisualKeys: TArray<TVisualKey>;
      FContacts: TDictionary<NativeInt, Byte>;
      FKeys, FSticky: THostKeyboardKeys;
      FOnChange: TNotifyEvent;
    procedure LayoutKeys;
    function IsStickyKey(Code: Byte): Boolean;
    function KeyAt(const Point: TPointF): Byte;
    procedure UpdateKeys;
  protected
    function RowCount: Integer; virtual;
    function ColumnCount: Integer; virtual;
    procedure BuildLayout; virtual; abstract;
    procedure AddKey(Code: Byte; const Caption: string; Row: Integer; Column, Span: Single; Sticky: Boolean = False);
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
    procedure PointerDown(Id: NativeInt; const Point: TPointF); override;
    procedure PointerMove(Id: NativeInt; const Point: TPointF); override;
    procedure PointerUp(Id: NativeInt); override;
    procedure ReleaseAll; override;
    property Keys: THostKeyboardKeys read FKeys;
    function KeyBounds(Code: Byte): TRectF;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

  TScreenKeyboardClass = class of TScreenKeyboard;

implementation

uses
  System.SysUtils, System.Math, FMX.Graphics
  {$IFDEF ANDROID}, RM.TouchInput.Android{$ENDIF};

constructor TScreenKeyboard.Create(AOwner: TComponent);
begin
  inherited;
  FContacts := TDictionary<NativeInt, Byte>.Create;
  HitTest := True;
  AutoCapture := True;
  CanFocus := False;
  SetBounds(0, 0, 720, 240);
  LayoutKeys;
end;

destructor TScreenKeyboard.Destroy;
begin
  FOnChange := nil;
  DetachNativeInput;
  FContacts.Free;
  inherited;
end;

class function TScreenKeyboard.PreferredHeight(AvailableWidth, AvailableHeight: Single): Single;
begin
  Result := Max(130.0, Min(260.0, Min(AvailableWidth * 0.34, AvailableHeight * 0.44)));
end;

procedure TKeyboardControl.AttachToForm(Form: TCommonCustomForm);
begin
  ReleaseAll;
  DetachNativeInput;

  {$IFDEF ANDROID}
  if Form <> nil then
    FNativeInput := TAndroidTouchInput.Create(Self, Form, PointerDown, PointerMove, PointerUp, ReleaseAll);
  {$ENDIF}
end;

procedure TScreenKeyboard.AddKey(Code: Byte; const Caption: string; Row: Integer; Column, Span: Single; Sticky: Boolean);
begin
  var i := Length(FVisualKeys);
  SetLength(FVisualKeys, i + 1);
  FVisualKeys[i].Code := Code;
  FVisualKeys[i].Caption := Caption;
  FVisualKeys[i].Sticky := Sticky;
  var U := Width / ColumnCount;
  var H := Height / RowCount;
  FVisualKeys[i].Bounds := RectF(Column * U + 2, Row * H + 2, (Column + Span) * U - 2, (Row + 1) * H - 2);
end;

procedure TScreenKeyboard.LayoutKeys;
begin
  FVisualKeys := nil;
  BuildLayout;
end;

function TScreenKeyboard.RowCount: Integer;
begin
  Result := 5;
end;

function TScreenKeyboard.ColumnCount: Integer;
begin
  Result := 16;
end;

function TScreenKeyboard.KeyBounds(Code: Byte): TRectF;
begin
  Result := TRectF.Empty;
  for var Key in FVisualKeys do
    if Key.Code = Code then Exit(Key.Bounds);
end;

function TScreenKeyboard.IsStickyKey(Code: Byte): Boolean;
begin
  Result := False;
  for var Key in FVisualKeys do
    if Key.Code = Code then Exit(Key.Sticky);
end;

function TScreenKeyboard.KeyAt(const Point: TPointF): Byte;
begin
  Result := 0;
  for var K in FVisualKeys do
    if K.Bounds.Contains(Point) then
      Exit(K.Code);
end;

procedure TScreenKeyboard.UpdateKeys;
begin
  if FContacts = nil then
    Exit;

  FKeys := FSticky;
  for var Code in FContacts.Values do
    FKeys[Code] := True;
  Repaint;
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

procedure TScreenKeyboard.PointerDown(Id: NativeInt; const Point: TPointF);
begin
  if not Enabled or not Visible then
    Exit;

  var Code := KeyAt(Point);
  if Code = 0 then
    Exit;

  if IsStickyKey(Code) then
    FSticky[Code] := not FSticky[Code]
  else
    FContacts.AddOrSetValue(Id, Code);
  UpdateKeys;
end;

procedure TScreenKeyboard.PointerMove(Id: NativeInt; const Point: TPointF);
begin
  if not FContacts.ContainsKey(Id) then
    Exit;

  var Code := KeyAt(Point);
  if (Code = 0) or (IsStickyKey(Code)) then
    FContacts.Remove(Id)
  else
    FContacts.AddOrSetValue(Id, Code);
  UpdateKeys;
end;

procedure TScreenKeyboard.PointerUp(Id: NativeInt);
begin
  FContacts.Remove(Id);
  UpdateKeys;
end;

procedure TScreenKeyboard.ReleaseAll;
begin
  if FContacts = nil then
    Exit;

  FContacts.Clear;
  FillChar(FSticky, SizeOf(FSticky), 0);
  UpdateKeys;
end;

procedure TScreenKeyboard.Resize;
begin
  inherited;
  ReleaseAll;
  LayoutKeys;
end;

procedure TScreenKeyboard.EnabledChanged;
begin
  inherited;
  if not Enabled then
    ReleaseAll;
end;

procedure TScreenKeyboard.VisibleChanged;
begin
  inherited;
  if not Visible then
    ReleaseAll;
end;

procedure TScreenKeyboard.AncestorVisibleChanged(const Visible: Boolean);
begin
  inherited;
  if not Visible then
    ReleaseAll;
end;

procedure TScreenKeyboard.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  inherited;
  if Button = TMouseButton.mbLeft then
    PointerDown(-1, PointF(X, Y));
end;

procedure TScreenKeyboard.MouseMove(Shift: TShiftState; X, Y: Single);
begin
  inherited;
  PointerMove(-1, PointF(X, Y));
end;

procedure TScreenKeyboard.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  inherited;
  if Button = TMouseButton.mbLeft then
    PointerUp(-1);
end;

procedure TScreenKeyboard.Paint;
begin
  Canvas.Fill.Color := $FF20242C;
  Canvas.FillRect(LocalRect, 0, 0, [], AbsoluteOpacity);
  Canvas.Font.Size := Max(9.0, Min(15.0, Width / 65));
  for var K in FVisualKeys do
  begin
    if FKeys[K.Code] then
      Canvas.Fill.Color := $FF467DB8
    else
      Canvas.Fill.Color := $FF3C424D;
    Canvas.FillRect(K.Bounds, 4, 4, AllCorners, AbsoluteOpacity);
    Canvas.Fill.Color := $FFF0F0F0;
    Canvas.FillText(K.Bounds, K.Caption, False, AbsoluteOpacity, [], TTextAlign.Center, TTextAlign.Center);
  end;
end;

procedure TKeyboardControl.DetachNativeInput;
begin
  FreeAndNil(FNativeInput);
end;

destructor TKeyboardControl.Destroy;
begin
  DetachNativeInput;
  inherited;
end;

end.

