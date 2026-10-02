unit RM.TouchInput.Android;

interface

{$IFDEF ANDROID}
uses
  System.Types, FMX.Controls, FMX.Forms, Androidapi.JNIBridge,
  Androidapi.JNI.GraphicsContentViewText;

type
  TPointerPositionEvent = procedure(Id: NativeInt; const Point: TPointF) of object;
  TPointerReleaseEvent = procedure(Id: NativeInt) of object;
  TPointerCancelEvent = procedure of object;

  // Own this hook for as long as the control is attached to the form.
  // Callbacks must belong to the control, which detaches before destruction.
  TAndroidTouchInput = class(TJavaLocal, JView_OnTouchListener)
  private
    FControl: TControl;
    FView: JView;
    FScale: Single;
    FDown, FMove: TPointerPositionEvent;
    FUp: TPointerReleaseEvent;
    FCancel: TPointerCancelEvent;
    FResetOnDown: Boolean;
  public
    constructor Create(Control: TControl; Form: TCommonCustomForm;
      Down, Move: TPointerPositionEvent; Up: TPointerReleaseEvent;
      Cancel: TPointerCancelEvent; ResetOnDown: Boolean = False);
    destructor Destroy; override;
    function onTouch(v: JView; event: JMotionEvent): Boolean; cdecl;
  end;
{$ENDIF}

implementation

{$IFDEF ANDROID}
uses FMX.Platform.Android;

constructor TAndroidTouchInput.Create(Control: TControl; Form: TCommonCustomForm;
  Down, Move: TPointerPositionEvent; Up: TPointerReleaseEvent;
  Cancel: TPointerCancelEvent; ResetOnDown: Boolean);
begin
  inherited Create;
  FControl := Control;
  FDown := Down;
  FMove := Move;
  FUp := Up;
  FCancel := Cancel;
  FResetOnDown := ResetOnDown;
  var Handle := WindowHandleToPlatform(Form.Handle);
  FScale := Handle.Scale;
  FView := Handle.View;
  FView.setOnTouchListener(Self);
end;

destructor TAndroidTouchInput.Destroy;
begin
  if FView <> nil then FView.setOnTouchListener(nil);
  FControl := nil;
  FView := nil;
  FDown := nil;
  FMove := nil;
  FUp := nil;
  FCancel := nil;
  inherited;
end;

function TAndroidTouchInput.onTouch(v: JView; event: JMotionEvent): Boolean;
begin
  // Keep FMX delivery to ordinary buttons and the rest of the form.
  // Device controls ignore synthesized mouse input on Android.
  Result := False;
  if FControl = nil then Exit;
  var Action := event.getActionMasked;
  if FResetOnDown and (Action = TJMotionEvent.JavaClass.ACTION_DOWN) then
    FCancel; // A fresh gesture cannot inherit a lost pointer-up.
  if Action = TJMotionEvent.JavaClass.ACTION_CANCEL then
  begin
    FCancel;
    Exit;
  end;
  var ChangedIndex := event.getActionIndex;
  for var I := 0 to event.getPointerCount - 1 do
  begin
    var Id := event.getPointerId(I);
    var Point := FControl.AbsoluteToLocal(PointF(event.getX(I) / FScale,
      event.getY(I) / FScale));
    if (I = ChangedIndex) and ((Action = TJMotionEvent.JavaClass.ACTION_UP) or
      (Action = TJMotionEvent.JavaClass.ACTION_POINTER_UP)) then FUp(Id)
    else if (I = ChangedIndex) and ((Action = TJMotionEvent.JavaClass.ACTION_DOWN) or
      (Action = TJMotionEvent.JavaClass.ACTION_POINTER_DOWN)) then FDown(Id, Point)
    else FMove(Id, Point);
  end;
end;
{$ENDIF}

end.
