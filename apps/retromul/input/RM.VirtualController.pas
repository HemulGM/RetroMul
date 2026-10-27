unit RM.VirtualController;

interface

uses
  System.Classes, System.Types, System.UITypes, System.Generics.Collections,
  FMX.Types, FMX.Controls, FMX.Graphics;

const
  VirtualIconUp =
 'M4.20889,10.7327 C3.9232,11.0326 3.93475,11.5074 4.23467,11.7931 C4.5346,12.0788 5.00933,12.0672 ' +
    '5.29502,11.7673 L11.2495,5.516 L11.2495,20.25 C11.2495,20.6642 11.5853,21 11.9995,21 C12.4137,21 ' +
    '12.7495,20.6642 12.7495,20.25 L12.7495,5.51565 L18.7043,11.7673 C18.99,12.0672 19.4648,12.0788 19.7647,11.7931 ' +
    'C20.0646,11.5074 20.0762,11.0326 19.7905,10.7327 L12.7238,3.31379 C12.5627,3.14474 12.3573,3.04477 ' +
    '12.1438,3.01386 C12.0971,3.00477 12.0489,3 11.9995,3 C11.9498,3 11.9012,3.00483 11.8543,3.01406 ' +
    'C11.6412,3.04518 11.4363,3.14509 11.2756,3.31379 L4.20889,10.7327 Z';
  VirtualIconDown =
    'M19.7905,13.2673 C20.0762,12.9674 20.0646,12.4926 19.7647,12.2069 C19.4648,11.9212 18.99,11.9328 ' +
    '18.7043,12.2327 L12.7498,18.484 L12.7498,3.75 C12.7498,3.33579 12.4141,3 11.9998,3 C11.5856,3 11.2498,3.33579 ' +
    '11.2498,3.75 L11.2498,18.4844 L5.29502,12.2327 C5.00933,11.9328 4.5346,11.9212 4.23467,12.2069 C3.93475,12.4926 ' +
    '3.9232,12.9674 4.20889,13.2673 L11.2756,20.6862 C11.4366,20.8553 11.642,20.9552 11.8556,20.9861 ' +
    'C11.9023,20.9952 11.9505,21 11.9998,21 C12.0495,21 12.0981,20.9952 12.1451,20.9859 C12.3582,20.9548 ' +
    '12.5631,20.8549 12.7238,20.6862 L19.7905,13.2673 Z';
  VirtualIconLeft =
    'M10.7327,19.7905 C11.0326,20.0762 11.5074,20.0646 11.7931,19.7647 C12.0788,19.4648 12.0672,18.99 ' +
    '11.7673,18.7043 L5.51587,12.7497 L20.25,12.7497 C20.6642,12.7497 21,12.4139 21,11.9997 C21,11.5855 ' +
    '20.6642,11.2497 20.25,11.2497 L5.51577,11.2497 L11.7673,5.29502 C12.0672,5.00933 12.0787,4.5346 11.7931,4.23467 ' +
    'C11.5074,3.93475 11.0326,3.9232 10.7327,4.20889 L3.31379,11.2756 C3.14486,11.4365 3.04491,11.6417 ' +
    '3.01393,11.8551 C3.00479,11.9019 3,11.9503 3,11.9997 C3,12.0493 3.00481,12.0977 3.01398,12.1446 ' +
    'C3.04502,12.3579 3.14496,12.563 3.31379,12.7238 L10.7327,19.7905 Z';
  VirtualIconRight =
    'M13.2673,4.20889 C12.9674,3.9232 12.4926,3.93475 12.2069,4.23467 C11.9212,4.5346 11.9328,5.00933 ' +
    '12.2327,5.29502 L18.4841,11.2496 L3.75,11.2496 C3.33579,11.2496 3,11.5854 3,11.9996 C3,12.4138 3.33579,12.7496 ' +
    '3.75,12.7496 L18.4842,12.7496 L12.2327,18.7043 C11.9328,18.99 11.9212,19.4648 12.2069,19.7647 C12.4926,20.0646 ' +
    '12.9674,20.0762 13.2673,19.7905 L20.6862,12.7238 C20.8551,12.5629 20.9551,12.3576 20.9861,12.1443 ' +
    'C20.9952,12.0975 21,12.0491 21,11.9996 C21,11.9501 20.9952,11.9016 20.986,11.8547 C20.955,11.6415 ' +
    '20.855,11.4364 20.6862,11.2756 L13.2673,4.20889 Z';
  VirtualIconPause =
    'M6.25,3 C5.00736,3 4,4.00736 4,5.25 L4,18.75 C4,19.9926 5.00736,21 6.25,21 L8.75,21 C9.99264,21 11,19.9926 ' +
    '11,18.75 L11,5.25 C11,4.00736 9.99264,3 8.75,3 L6.25,3 Z M5.5,5.25 C5.5,4.83579 5.83579,4.5 6.25,4.5 L8.75,4.5 ' +
    'C9.16421,4.5 9.5,4.83579 9.5,5.25 L9.5,18.75 C9.5,19.1642 9.16421,19.5 8.75,19.5 L6.25,19.5 C5.83579,19.5 ' +
    '5.5,19.1642 5.5,18.75 L5.5,5.25 Z M15.25,3 C14.0074,3 13,4.00736 13,5.25 L13,18.75 C13,19.9926 14.0074,21 ' +
    '15.25,21 L17.75,21 C18.9926,21 20,19.9926 20,18.75 L20,5.25 C20,4.00736 18.9926,3 17.75,3 L15.25,3 Z M14.5,5.25 ' +
    'C14.5,4.83579 14.8358,4.5 15.25,4.5 L17.75,4.5 C18.1642,4.5 18.5,4.83579 18.5,5.25 L18.5,18.75 C18.5,19.1642 ' +
    '18.1642,19.5 17.75,19.5 L15.25,19.5 C14.8358,19.5 14.5,19.1642 14.5,18.75 L14.5,5.25 Z';
  VirtualIconTriangle =
    'M12 1 L24 23 L0 23 Z M12 5 L3.4 21 L20.6 21 Z';
  VirtualIconSquare =
    'M0 0 L24 0 L24 24 L0 24 Z M2 2 L2 22 L22 22 L22 2 Z';
  VirtualIconCircle =
    'M24 12 C24 18.627 18.627 24 12 24 C5.373 24 0 18.627 0 12 C0 5.373 5.373 0 12 0 C18.627 0 24 5.373 24 12 Z M22 12 C22 6.477 17.523 2 12 2 C6' +
    '.477 2 2 6.477 2 12 C2 17.523 6.477 22 12 22 C17.523 22 22 17.523 22 12 Z';
  VirtualIconCross =
    'M1.5 0 L12 10.5 L22.5 0 L24 1.5 L13.5 12 L24 22.5 L22.5 24 L12 13.5 L1.5 24 L0 22.5 L10.5 12 L0 1.5 Z';

type
  TVirtualSide = (Left, Right);

  TVirtualController = class;

  TVirtualElement = class;

  TVirtualInputEvent = procedure(Sender: TObject; Element: TVirtualElement; Part: Integer; Value: Single) of object;

  // Extend this class to introduce another input type. Geometry is in logical
  // side coordinates; PartBounds, HitParts and Paint share the same geometry.
  TVirtualElement = class abstract(TPersistent)
  private
    FController: TVirtualController;
    FId, FCaption: string;
    FIconPath, FPaintPath: TPathData;
    FSide: TVirtualSide;
    FBounds: TRectF;
    FValues, FFeedback: TArray<Single>;
    FPartEnabled: TArray<Boolean>;
    FCaptureGroup: string;
    FRetainOnSlide: Boolean;
    function GetIconData: string;
    procedure SetIconData(const Value: string);
    function GetPartEnabled(Part: Integer): Boolean;
    procedure SetPartEnabled(Part: Integer; Value: Boolean);
    function GetFeedback(Part: Integer): Single;
    procedure SetFeedback(Part: Integer; Value: Single);
    procedure SetBounds(const Value: TRectF);
    procedure SetSide(Value: TVirtualSide);
    procedure SetCaption(const Value: string);
  protected
    function LocalPartBounds(Part: Integer): TRectF; virtual;
    function HitParts(const P: TPointF): TArray<Integer>; virtual;
    function InputValue(const P: TPointF): Single; virtual;
    function PartInputValue(Part: Integer; const P: TPointF): Single; virtual;
    procedure Paint(Canvas: TCanvas; const Bounds: TRectF; Alpha: Single); virtual; abstract;
    procedure DrawIcon(Canvas: TCanvas; const R: TRectF; Path: TPathData; Alpha: Single);
    procedure DrawContent(Canvas: TCanvas; const R: TRectF; Alpha: Single);
    procedure DrawLabel(Canvas: TCanvas; const R: TRectF; const Text: string; Alpha: Single);
  public
    constructor Create(const AId, ACaption: string; ASide: TVirtualSide; const ABounds: TRectF; PartCount: Integer = 1); virtual;
    destructor Destroy; override;
    function Value(Part: Integer = 0): Single;
    function PartCount: Integer;
    function VisualValue(Part: Integer = 0): Single;
    function HasEnabledParts: Boolean;
    property PartEnabled[Part: Integer]: Boolean read GetPartEnabled write SetPartEnabled;
    property Feedback[Part: Integer]: Single read GetFeedback write SetFeedback;
    // Nonempty groups enable rolling between action buttons with one contact.
    property CaptureGroup: string read FCaptureGroup write FCaptureGroup;
    property RetainOnSlide: Boolean read FRetainOnSlide write FRetainOnSlide;
    property Id: string read FId;
    property Caption: string read FCaption write SetCaption;
    // Same path syntax as TPath.Data.Data; an empty path displays Caption.
    property IconData: string read GetIconData write SetIconData;
    property Side: TVirtualSide read FSide write SetSide;
    property Bounds: TRectF read FBounds write SetBounds;
    property Controller: TVirtualController read FController;
  end;

  TVirtualButton = class(TVirtualElement)
  protected
    function HitParts(const P: TPointF): TArray<Integer>; override;
    procedure Paint(Canvas: TCanvas; const Bounds: TRectF; Alpha: Single); override;
  end;

  TVirtualKey = class(TVirtualElement)
  protected
    procedure Paint(Canvas: TCanvas; const Bounds: TRectF; Alpha: Single); override;
  end;

  TVirtualDPad = class(TVirtualElement)
  private
    FDirectionPaths: array[0..3] of TPathData;
  public
    const
      Up = 0;
      Down = 1;
      Left = 2;
      Right = 3;
  protected
    function LocalPartBounds(Part: Integer): TRectF; override;
    function HitParts(const P: TPointF): TArray<Integer>; override;
    procedure Paint(Canvas: TCanvas; const Bounds: TRectF; Alpha: Single); override;
  public
    constructor Create(const AId, ACaption: string; ASide: TVirtualSide; const ABounds: TRectF; PartCount: Integer = 4); override;
    destructor Destroy; override;
  end;

  TVirtualStick = class(TVirtualElement)
  protected
    function HitParts(const P: TPointF): TArray<Integer>; override;
    function PartInputValue(Part: Integer; const P: TPointF): Single; override;
    procedure Paint(Canvas: TCanvas; const Bounds: TRectF; Alpha: Single); override;
  public
    constructor Create(const AId, ACaption: string; ASide: TVirtualSide; const ABounds: TRectF; PartCount: Integer = 4); override;
    function AxisX: Single;
    function AxisY: Single;
  end;

  TVirtualSwitch = class(TVirtualElement)
  private
    FLatched: Boolean;
  protected
    procedure Paint(Canvas: TCanvas; const Bounds: TRectF; Alpha: Single); override;
  end;

  TVirtualTrigger = class(TVirtualElement)
  protected
    function InputValue(const P: TPointF): Single; override;
    procedure Paint(Canvas: TCanvas; const Bounds: TRectF; Alpha: Single); override;
  end;

  TVirtualController = class(TControl)
  private
    type
      TContact = record
        Element: TVirtualElement;
        Point, Position: TPointF;
        HoldAnchor: Boolean;
      end;
  private
    FElements: TObjectList<TVirtualElement>;
    FContacts: TDictionary<NativeInt, TContact>;
    FScale, FInkOpacity: Single;
    FDesignSideSize: TSizeF;
    FOnInput: TVirtualInputEvent;
    FOnGeometryChanged: TNotifyEvent;
    function GetCount: Integer;
    function GetElement(Index: Integer): TVirtualElement;
    procedure SetScale(Value: Single);
    procedure SetDesignSideSize(const Value: TSizeF);
    procedure SetInkOpacity(Value: Single);
    procedure Recompute;
    function GroupBounds(Element: TVirtualElement): TRectF;
    function ToSide(const P: TPointF; Side: TVirtualSide): TPointF;
    function TransformRect(const R: TRectF; Side: TVirtualSide): TRectF;
  protected
    procedure InputChanged; virtual;
    procedure ButtonActivated; virtual;
    procedure Paint; override;
    procedure Resize; override;
    procedure EnabledChanged; override;
    procedure VisibleChanged; override;
    procedure AncestorVisibleChanged(const Visible: Boolean); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Single); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Single); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Single); override;
  public
    const
      SideWidth = 240;
      DesignHeight = 320;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    // Ownership transfers only after successful Add; IDs must be unique.
    function Add(Element: TVirtualElement): TVirtualElement;
    procedure Remove(Element: TVirtualElement);
    procedure Clear;
    procedure GeometryChanged;
    function Find(const Id: string): TVirtualElement;
    function EffectiveScale: Single;
    function SideBounds(Side: TVirtualSide): TRectF;
    function ElementBounds(Element: TVirtualElement): TRectF;
    function PartBounds(Element: TVirtualElement; Part: Integer): TRectF;
    function PartCenter(Element: TVirtualElement; Part: Integer): TPointF;
    // All input positions and returned bounds are relative to this control.
    // Forward platform contacts here; IDs allow simultaneous independent input.
    procedure PointerDown(Id: NativeInt; const P: TPointF);
    procedure PointerMove(Id: NativeInt; const P: TPointF);
    procedure PointerUp(Id: NativeInt);
    procedure ReleaseAll; virtual;
    property Count: Integer read GetCount;
    property Elements[Index: Integer]: TVirtualElement read GetElement; default;
    property DesignSideSize: TSizeF read FDesignSideSize write SetDesignSideSize;
    property LayoutScale: Single read FScale write SetScale;
    property InkOpacity: Single read FInkOpacity write SetInkOpacity;
    property OnInput: TVirtualInputEvent read FOnInput write FOnInput;
    property OnGeometryChanged: TNotifyEvent read FOnGeometryChanged write FOnGeometryChanged;
  end;

implementation

uses
  System.SysUtils, System.Math;

constructor TVirtualElement.Create(const AId, ACaption: string; ASide: TVirtualSide; const ABounds: TRectF; PartCount: Integer);
begin
  inherited Create;
  if (AId = '') or (PartCount < 1) then
    raise EArgumentException.Create('Element needs an ID and at least one part');

  FIconPath := TPathData.Create;
  FPaintPath := TPathData.Create;
  FRetainOnSlide := True;
  FId := AId;
  FCaption := ACaption;
  FSide := ASide;
  SetLength(FValues, PartCount);
  SetLength(FFeedback, PartCount);
  SetLength(FPartEnabled, PartCount);
  for var i := 0 to PartCount - 1 do
    FPartEnabled[i] := True;
  SetBounds(ABounds);
end;

destructor TVirtualElement.Destroy;
begin
  FPaintPath.Free;
  FIconPath.Free;
  inherited;
end;

function TVirtualElement.GetIconData: string;
begin
  Result := FIconPath.Data;
end;

procedure TVirtualElement.SetIconData(const Value: string);
begin
  FIconPath.Data := Value;
  if FController <> nil then
    FController.Repaint;
end;

procedure TVirtualElement.DrawIcon(Canvas: TCanvas; const R: TRectF; Path: TPathData; Alpha: Single);
begin
  if Path.IsEmpty then
    Exit;
  var Size := Min(R.Width, R.Height) * 0.44;
  var Center := R.CenterPoint;
  FPaintPath.Assign(Path);
  FPaintPath.FitToRect(RectF(Center.X - Size / 2, Center.Y - Size / 2,
      Center.X + Size / 2, Center.Y + Size / 2));
  Canvas.Fill.Color := TAlphaColors.White;
  Canvas.FillPath(FPaintPath, Alpha);
end;

procedure TVirtualElement.DrawContent(Canvas: TCanvas; const R: TRectF; Alpha: Single);
begin
  if FIconPath.IsEmpty then
    DrawLabel(Canvas, R, Caption, Alpha)
  else
    DrawIcon(Canvas, R, FIconPath, Alpha);
end;

procedure TVirtualElement.SetBounds(const Value: TRectF);
begin
  if IsNan(Value.Left) or IsNan(Value.Top) or IsNan(Value.Right) or IsNan(Value.Bottom) or
    IsInfinite(Value.Left) or IsInfinite(Value.Top) or IsInfinite(Value.Right) or IsInfinite(Value.Bottom) or
    (Value.Left < 0) or (Value.Top < 0) or (Value.Width < 1) or (Value.Height < 1) then
    raise EArgumentException.Create('Bounds must be finite, nonnegative and have positive size');

  if (FController <> nil) and ((Value.Right > FController.DesignSideSize.Width) or
    (Value.Bottom > FController.DesignSideSize.Height)) then
    raise EArgumentException.Create('Bounds must fit the logical side');

  FBounds := Value;
  if FController <> nil then
    FController.GeometryChanged;
end;

procedure TVirtualElement.SetSide(Value: TVirtualSide);
begin
  if FSide = Value then
    Exit;

  FSide := Value;
  if FController <> nil then
    FController.GeometryChanged;
end;

procedure TVirtualElement.SetCaption(const Value: string);
begin
  FCaption := Value;
  if FController <> nil then
    FController.Repaint;
end;

function TVirtualElement.LocalPartBounds(Part: Integer): TRectF;
begin
  Result := FBounds;
end;

function TVirtualElement.HitParts(const P: TPointF): TArray<Integer>;
begin
  Result := nil;
  if FBounds.Contains(P) then
    Result := [0];
end;

function TVirtualElement.InputValue(const P: TPointF): Single;
begin
  Result := 1;
end;

function TVirtualElement.PartInputValue(Part: Integer; const P: TPointF): Single;
begin
  Result := InputValue(P);
end;

constructor TVirtualStick.Create(const AId, ACaption: string; ASide: TVirtualSide; const ABounds: TRectF; PartCount: Integer);
begin
  inherited Create(AId, ACaption, ASide, ABounds, 4);
end;

function TVirtualStick.HitParts(const P: TPointF): TArray<Integer>;
begin
  Result := [0, 1, 2, 3];
end;

function TVirtualStick.PartInputValue(Part: Integer; const P: TPointF): Single;
begin
  var X := (P.X - Bounds.CenterPoint.X) / (Bounds.Width / 2);
  var Y := (P.Y - Bounds.CenterPoint.Y) / (Bounds.Height / 2);
  var Magnitude := Sqrt(Sqr(X) + Sqr(Y));
  if Magnitude <= 0.12 then
    Exit(0);

  var Amount := Min(1.0, (Magnitude - 0.12) / 0.88);
  X := X / Magnitude * Amount;
  Y := Y / Magnitude * Amount;
  case Part of
    0:
      Result := Max(0.0, -Y);
    1:
      Result := Max(0.0, Y);
    2:
      Result := Max(0.0, -X);
    3:
      Result := Max(0.0, X);
  else
    Result := 0;
  end;
end;

function TVirtualStick.AxisX: Single;
begin
  Result := Value(3) - Value(2);
end;

function TVirtualStick.AxisY: Single;
begin
  Result := Value(1) - Value(0);
end;

procedure TVirtualStick.Paint(Canvas: TCanvas; const Bounds: TRectF; Alpha: Single);
begin
  Canvas.Stroke.Color := TAlphaColors.White;
  Canvas.Stroke.Thickness := 1.5;
  Canvas.Fill.Color := TAlphaColors.White;
  Canvas.FillEllipse(Bounds, Alpha * 0.08);
  Canvas.DrawEllipse(Bounds, Alpha);
  var Center := Bounds.CenterPoint + PointF(AxisX * Bounds.Width * 0.28, AxisY * Bounds.Height * 0.28);
  var Radius := Min(Bounds.Width, Bounds.Height) * 0.2;
  var Knob := RectF(Center.X - Radius, Center.Y - Radius, Center.X + Radius, Center.Y + Radius);
  Canvas.FillEllipse(Knob, Alpha * 0.3);
  Canvas.DrawEllipse(Knob, Alpha);
end;

function TVirtualElement.Value(Part: Integer): Single;
begin
  if (Part < 0) or (Part >= Length(FValues)) then
    raise EArgumentOutOfRangeException.Create('Part');

  Result := FValues[Part];
end;

function TVirtualElement.PartCount: Integer;
begin
  Result := Length(FValues);
end;

function TVirtualElement.GetPartEnabled(Part: Integer): Boolean;
begin
  if (Part < 0) or (Part >= PartCount) then
    raise EArgumentOutOfRangeException.Create('Part');

  Result := FPartEnabled[Part];
end;

procedure TVirtualElement.SetPartEnabled(Part: Integer; Value: Boolean);
begin
  if (Part < 0) or (Part >= PartCount) then
    raise EArgumentOutOfRangeException.Create('Part');

  if FPartEnabled[Part] = Value then
    Exit;

  FPartEnabled[Part] := Value;
  if FController <> nil then
    FController.GeometryChanged;
end;

function TVirtualElement.HasEnabledParts: Boolean;
begin
  Result := False;
  for var Enabled in FPartEnabled do
    if Enabled then
      Exit(True);
end;

function TVirtualElement.GetFeedback(Part: Integer): Single;
begin
  if (Part < 0) or (Part >= PartCount) then
    raise EArgumentOutOfRangeException.Create('Part');

  Result := FFeedback[Part];
end;

procedure TVirtualElement.SetFeedback(Part: Integer; Value: Single);
begin
  if (Part < 0) or (Part >= PartCount) then
    raise EArgumentOutOfRangeException.Create('Part');

  if IsNan(Value) or IsInfinite(Value) then
    raise EArgumentException.Create('Invalid feedback');

  FFeedback[Part] := EnsureRange(Value, 0.0, 1.0);
  if FController <> nil then
    FController.Repaint;
end;

function TVirtualElement.VisualValue(Part: Integer): Single;
begin
  Result := Max(Value(Part), Feedback[Part]);
end;

procedure TVirtualKey.Paint(Canvas: TCanvas; const Bounds: TRectF; Alpha: Single);
begin
  Canvas.Fill.Color := TAlphaColors.White;
  Canvas.Stroke.Color := TAlphaColors.White;
  Canvas.Stroke.Thickness := 1.5;
  Canvas.FillRect(Bounds, 8, 8, AllCorners, Alpha * (0.16 + 0.54 * VisualValue));
  Canvas.DrawRect(Bounds, 8, 8, AllCorners, Alpha);
  DrawContent(Canvas, Bounds, Alpha);
end;

procedure TVirtualElement.DrawLabel(Canvas: TCanvas; const R: TRectF; const Text: string; Alpha: Single);
begin
  Canvas.Fill.Color := TAlphaColors.White;
  Canvas.Font.Size := Max(9, Min(R.Width, R.Height) * 0.3);
  Canvas.FillText(R, Text, False, Alpha, [], TTextAlign.Center, TTextAlign.Center);
end;

function TVirtualButton.HitParts(const P: TPointF): TArray<Integer>;
begin
  var X := (P.X - Bounds.CenterPoint.X) / (Bounds.Width / 2);
  var Y := (P.Y - Bounds.CenterPoint.Y) / (Bounds.Height / 2);
  Result := nil;
  if Sqr(X) + Sqr(Y) <= 1 then
    Result := [0];
end;

procedure TVirtualButton.Paint(Canvas: TCanvas; const Bounds: TRectF; Alpha: Single);
begin
  Canvas.Fill.Color := TAlphaColors.White;
  Canvas.Stroke.Color := TAlphaColors.White;
  Canvas.Stroke.Thickness := 1.5;
  Canvas.FillEllipse(Bounds, Alpha * (0.16 + 0.54 * VisualValue));
  Canvas.DrawEllipse(Bounds, Alpha);
  DrawContent(Canvas, Bounds, Alpha);
end;

constructor TVirtualDPad.Create(const AId, ACaption: string; ASide: TVirtualSide; const ABounds: TRectF; PartCount: Integer);
begin
  inherited Create(AId, ACaption, ASide, ABounds, 4);
  for var I := 0 to 3 do
    FDirectionPaths[I] := TPathData.Create;
  FDirectionPaths[Up].Data := VirtualIconUp;
  FDirectionPaths[Down].Data := VirtualIconDown;
  FDirectionPaths[Left].Data := VirtualIconLeft;
  FDirectionPaths[Right].Data := VirtualIconRight;
end;

destructor TVirtualDPad.Destroy;
begin
  for var Path in FDirectionPaths do
    Path.Free;
  inherited;
end;

function TVirtualDPad.LocalPartBounds(Part: Integer): TRectF;
begin
  var W := Bounds.Width / 3;
  var H := Bounds.Height / 3;
  case Part of
    Up:
      Result := RectF(Bounds.Left + W, Bounds.Top, Bounds.Right - W, Bounds.Top + H);
    Down:
      Result := RectF(Bounds.Left + W, Bounds.Bottom - H, Bounds.Right - W, Bounds.Bottom);
    Left:
      Result := RectF(Bounds.Left, Bounds.Top + H, Bounds.Left + W, Bounds.Bottom - H);
    Right:
      Result := RectF(Bounds.Right - W, Bounds.Top + H, Bounds.Right, Bounds.Bottom - H);
  else
    Result := TRectF.Empty;
  end;
end;

function TVirtualDPad.HitParts(const P: TPointF): TArray<Integer>;
begin
  Result := nil;

  // Captured contacts keep selecting directions outside the pad, like the stick.
  var X := (P.X - Bounds.CenterPoint.X) / (Bounds.Width / 2);
  var Y := (P.Y - Bounds.CenterPoint.Y) / (Bounds.Height / 2);

  // Rectangular dead zone; corners activate two directions.
  if Y < -0.33 then
    Result := Result + [Up];
  if Y > 0.33 then
    Result := Result + [Down];
  if X < -0.33 then
    Result := Result + [Left];
  if X > 0.33 then
    Result := Result + [Right];
end;

procedure TVirtualDPad.Paint(Canvas: TCanvas; const Bounds: TRectF; Alpha: Single);
begin
  Canvas.Fill.Color := TAlphaColors.White;
  Canvas.FillEllipse(Bounds, Alpha * 0.06);
  Canvas.Stroke.Color := TAlphaColors.White;
  Canvas.Stroke.Thickness := 1.5;
  for var i := 0 to 3 do
  begin
    if not PartEnabled[i] then
      Continue;

    var R := Controller.PartBounds(Self, i);
    Canvas.Fill.Color := TAlphaColors.White;
    Canvas.FillRect(R, 4, 4, AllCorners, Alpha * (0.16 + 0.54 * VisualValue(i)));
    Canvas.DrawRect(R, 4, 4, AllCorners, Alpha);
    DrawIcon(Canvas, R, FDirectionPaths[i], Alpha);
  end;
end;

procedure TVirtualSwitch.Paint(Canvas: TCanvas; const Bounds: TRectF; Alpha: Single);
begin
  Canvas.Stroke.Color := TAlphaColors.White;
  Canvas.Stroke.Thickness := 1.5;
  Canvas.Fill.Color := TAlphaColors.White;
  Canvas.FillRect(Bounds, Bounds.Height / 2, Bounds.Height / 2, AllCorners, Alpha * 0.12);
  Canvas.DrawRect(Bounds, Bounds.Height / 2, Bounds.Height / 2, AllCorners, Alpha);
  var D := Min(Bounds.Height - 8, Bounds.Width / 3);
  var R := RectF(Bounds.Left + 4, Bounds.CenterPoint.Y - D / 2, Bounds.Left + 4 + D, Bounds.CenterPoint.Y + D / 2);
  if VisualValue > 0 then
    R.Offset(Bounds.Width - D - 8, 0);
  Canvas.FillEllipse(R, Alpha * 0.8);
  DrawContent(Canvas, Bounds, Alpha);
end;

function TVirtualTrigger.InputValue(const P: TPointF): Single;
begin
  Result := EnsureRange((Bounds.Bottom - P.Y) / Bounds.Height, 0.0, 1.0);
end;

procedure TVirtualTrigger.Paint(Canvas: TCanvas; const Bounds: TRectF; Alpha: Single);
begin
  Canvas.Stroke.Color := TAlphaColors.White;
  Canvas.Stroke.Thickness := 1.5;
  Canvas.Fill.Color := TAlphaColors.White;
  Canvas.FillRect(Bounds, 8, 8, AllCorners, Alpha * 0.12);
  var R := Bounds;
  R.Top := R.Bottom - R.Height * VisualValue;
  Canvas.FillRect(R, 6, 6, AllCorners, Alpha * 0.6);
  Canvas.DrawRect(Bounds, 8, 8, AllCorners, Alpha);
  DrawContent(Canvas, Bounds, Alpha);
end;

constructor TVirtualController.Create(AOwner: TComponent);
begin
  inherited;
  FElements := TObjectList<TVirtualElement>.Create(True);
  FContacts := TDictionary<NativeInt, TContact>.Create;
  FScale := 1;
  FDesignSideSize := TSizeF.Create(SideWidth, DesignHeight);
  FInkOpacity := 0.65;
  AutoCapture := True;
  HitTest := True;
  SetBounds(0, 0, 960, 320);
end;

destructor TVirtualController.Destroy;
begin
  FOnInput := nil;
  FOnGeometryChanged := nil;
  FContacts.Free;
  FElements.Free;
  inherited;
end;

function TVirtualController.GetCount: Integer;
begin
  Result := FElements.Count;
end;

function TVirtualController.GetElement(Index: Integer): TVirtualElement;
begin
  Result := FElements[Index];
end;

function TVirtualController.Find(const Id: string): TVirtualElement;
begin
  for var E in FElements do
    if E.Id = Id then
      Exit(E);

  Result := nil;
end;

function TVirtualController.Add(Element: TVirtualElement): TVirtualElement;
begin
  if (Element = nil) or (Element.Controller <> nil) then
    raise EArgumentException.Create('Element is nil or already owned');

  if Find(Element.Id) <> nil then
    raise EArgumentException.Create('Duplicate element ID');

  if (Element.Bounds.Right > FDesignSideSize.Width) or (Element.Bounds.Bottom > FDesignSideSize.Height) then
    raise EArgumentException.Create('Element must fit the logical side');

  FElements.Add(Element);
  Element.FController := Self;
  GeometryChanged;
  Result := Element;
end;

procedure TVirtualController.Remove(Element: TVirtualElement);
begin
  if (Element = nil) or (Element.Controller <> Self) then
    Exit;

  ReleaseAll;
  FElements.Remove(Element);
  GeometryChanged;
end;

procedure TVirtualController.Clear;
begin
  ReleaseAll;
  FElements.Clear;
  GeometryChanged;
end;

function TVirtualController.EffectiveScale: Single;
begin
  Result := Max(0.001, Min(FScale, Min(Width / (2 * FDesignSideSize.Width), Height / FDesignSideSize.Height)));
end;

function TVirtualController.SideBounds(Side: TVirtualSide): TRectF;
begin
  var S := EffectiveScale;
  var X: Single := 0;
  if Side = TVirtualSide.Right then
    X := Width - FDesignSideSize.Width * S;
  var Y := Height - FDesignSideSize.Height * S;
  Result := RectF(X, Y, X + FDesignSideSize.Width * S, Height);
end;

function TVirtualController.ToSide(const P: TPointF; Side: TVirtualSide): TPointF;
begin
  var R := SideBounds(Side);
  var S := EffectiveScale;
  Result := PointF((P.X - R.Left) / S, (P.Y - R.Top) / S);
end;

function TVirtualController.TransformRect(const R: TRectF; Side: TVirtualSide): TRectF;
begin
  var B := SideBounds(Side);
  var S := EffectiveScale;
  Result := RectF(B.Left + R.Left * S, B.Top + R.Top * S,
    B.Left + R.Right * S, B.Top + R.Bottom * S);
end;

function TVirtualController.ElementBounds(Element: TVirtualElement): TRectF;
begin
  if (Element = nil) or (Element.Controller <> Self) then
    raise EArgumentException.Create('Foreign element');

  Result := TransformRect(Element.Bounds, Element.Side);
end;

function TVirtualController.PartBounds(Element: TVirtualElement; Part: Integer): TRectF;
begin
  if (Element = nil) or (Element.Controller <> Self) then
    raise EArgumentException.Create('Foreign element');

  if (Part < 0) or (Part >= Element.PartCount) then
    raise EArgumentOutOfRangeException.Create('Part');

  Result := TransformRect(Element.LocalPartBounds(Part), Element.Side);
end;

function TVirtualController.PartCenter(Element: TVirtualElement; Part: Integer): TPointF;
begin
  Result := PartBounds(Element, Part).CenterPoint;
end;

procedure TVirtualController.SetDesignSideSize(const Value: TSizeF);
begin
  if IsNan(Value.Width) or IsNan(Value.Height) or IsInfinite(Value.Width) or
    IsInfinite(Value.Height) or (Value.Width < 1) or (Value.Height < 1) then
    raise EArgumentException.Create('Invalid logical side size');

  for var E in FElements do
    if (E.Bounds.Right > Value.Width) or (E.Bounds.Bottom > Value.Height) then
      raise EArgumentException.Create('Existing elements must fit the logical side');

  FDesignSideSize := Value;
  GeometryChanged;
end;

procedure TVirtualController.SetScale(Value: Single);
begin
  if IsNan(Value) or IsInfinite(Value) or (Value <= 0) then
    raise EArgumentException.Create('Invalid scale');

  if FScale = Value then
    Exit;

  FScale := Value;
  GeometryChanged;
end;

procedure TVirtualController.SetInkOpacity(Value: Single);
begin
  if IsNan(Value) or IsInfinite(Value) then
    raise EArgumentException.Create('Invalid opacity');

  FInkOpacity := EnsureRange(Value, 0.0, 1.0);
  Repaint;
end;

procedure TVirtualController.GeometryChanged;
begin
  if FContacts = nil then
    Exit;

  ReleaseAll;
  Repaint;
  if Assigned(FOnGeometryChanged) then
    FOnGeometryChanged(Self);
end;

procedure TVirtualController.Resize;
begin
  inherited;
  GeometryChanged;
end;

procedure TVirtualController.EnabledChanged;
begin
  inherited;
  if not Enabled then
    ReleaseAll;
end;

procedure TVirtualController.VisibleChanged;
begin
  inherited;
  if not Visible then
    ReleaseAll;
end;

procedure TVirtualController.AncestorVisibleChanged(const Visible: Boolean);
begin
  inherited;
  if not Visible then
    ReleaseAll;
end;

procedure TVirtualController.InputChanged;
begin
end;

procedure TVirtualController.ButtonActivated;
begin
end;

function TVirtualController.GroupBounds(Element: TVirtualElement): TRectF;
begin
  Result := ElementBounds(Element);
  for var E in FElements do
    if E.HasEnabledParts and (E.CaptureGroup = Element.CaptureGroup) then
    begin
      var Bounds := ElementBounds(E);
      Result := RectF(Min(Result.Left, Bounds.Left), Min(Result.Top, Bounds.Top),
        Max(Result.Right, Bounds.Right), Max(Result.Bottom, Bounds.Bottom));
    end;
  Result.Inflate(6, 6);
end;

procedure TVirtualController.Recompute;
begin
  var Activated := False;
  for var E in FElements do
  begin
    var NewValues: TArray<Single> := nil;
    SetLength(NewValues, E.PartCount);
    if E is TVirtualSwitch then
      NewValues[0] := Ord(TVirtualSwitch(E).FLatched)
    else
      for var C in FContacts.Values do
        if (C.Element = E) or ((C.Element.CaptureGroup <> '') and (C.Element.CaptureGroup = E.CaptureGroup)) then
        begin
          var Point := ToSide(C.Position, E.Side);
          var V := E.InputValue(Point);
          if E is TVirtualTrigger then
            NewValues[0] := Max(NewValues[0], V)
          else
          begin
            if C.HoldAnchor and (C.Element = E) then
              NewValues[0] := 1;
            for var Part in E.HitParts(Point) do
              if (Part >= 0) and (Part < E.PartCount) then
                NewValues[Part] := Max(NewValues[Part], E.PartInputValue(Part, Point));
          end;
        end;

    for var i := 0 to E.PartCount - 1 do
    begin
      if not E.PartEnabled[i] then
        NewValues[i] := 0;
      if not SameValue(E.FValues[i], NewValues[i], 0.0001) then
      begin
        // One edge per digital activation, including sliding onto another key.
        // Stick motion is continuous and must not generate repeated impacts.
        if not (E is TVirtualStick) and (E.FValues[i] < 0.5) and (NewValues[i] >= 0.5) then
          Activated := True;
        E.FValues[i] := NewValues[i];
        if Assigned(FOnInput) then
          FOnInput(Self, E, i, NewValues[i]);
      end;
    end;
  end;

  // Subclasses read one complete state, without transient opposing directions.
  InputChanged;
  // Coalesce diagonal/multiple part changes from one touch into one impact.
  if Activated then
    ButtonActivated;
  Repaint;
end;

procedure TVirtualController.PointerDown(Id: NativeInt; const P: TPointF);
begin
  if not Enabled or not AbsoluteEnabled or not ParentedVisible or not LocalRect.Contains(P) then
    Exit;

  FContacts.Remove(Id);
  for var i := Count - 1 downto 0 do
  begin
    var C: TContact;
    C.Element := Elements[i];
    if not C.Element.HasEnabledParts then
      Continue;

    C.HoldAnchor := (C.Element.CaptureGroup <> '') and C.Element.RetainOnSlide;
    C.Position := P;
    C.Point := ToSide(P, C.Element.Side);
    if not C.Element.Bounds.Contains(C.Point) then
      Continue;

    if Length(C.Element.HitParts(C.Point)) = 0 then
      if not ((C.Element is TVirtualDPad) and C.Element.Bounds.Contains(C.Point)) then
        Continue;

    if C.Element is TVirtualSwitch then
      TVirtualSwitch(C.Element).FLatched := not TVirtualSwitch(C.Element).FLatched;
    FContacts.Add(Id, C);
    Break;
  end;
  Recompute;
end;

procedure TVirtualController.PointerMove(Id: NativeInt; const P: TPointF);
begin
  var C: TContact;
  if not FContacts.TryGetValue(Id, C) then
    Exit;

  if not AbsoluteEnabled or not ParentedVisible then
  begin
    ReleaseAll;
    Exit;
  end;

  C.Point := ToSide(P, C.Element.Side);
  C.Position := P;
  if (C.Element.CaptureGroup <> '') and (not LocalRect.Contains(P) or not GroupBounds(C.Element).Contains(P)) then
    C.HoldAnchor := False;
  FContacts[Id] := C;
  Recompute;
end;

procedure TVirtualController.PointerUp(Id: NativeInt);
begin
  if not FContacts.ContainsKey(Id) then
    Exit;

  FContacts.Remove(Id);
  Recompute;
end;

procedure TVirtualController.ReleaseAll;
begin
  if FContacts = nil then
    Exit;

  FContacts.Clear;
  for var E in FElements do
  begin
    if E is TVirtualSwitch then
      TVirtualSwitch(E).FLatched := False;
    for var i := 0 to E.PartCount - 1 do
      E.FFeedback[i] := 0;
  end;
  Recompute;
end;

procedure TVirtualController.Paint;
begin
  Canvas.Stroke.Kind := TBrushKind.Solid;
  Canvas.Fill.Kind := TBrushKind.Solid;

  // No background: this control can overlay a game view.
  for var E in FElements do
    if E.HasEnabledParts then
      E.Paint(Canvas, ElementBounds(E), FInkOpacity * AbsoluteOpacity);
end;

procedure TVirtualController.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  inherited;
  {$IF not Defined(ANDROID) and not Defined(IOS)}
  if Button = TMouseButton.mbLeft then
    PointerDown(-1, PointF(X, Y));
  {$ENDIF}
end;

procedure TVirtualController.MouseMove(Shift: TShiftState; X, Y: Single);
begin
  inherited;
  {$IF not Defined(ANDROID) and not Defined(IOS)}
  PointerMove(-1, PointF(X, Y));
  {$ENDIF}
end;

procedure TVirtualController.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  inherited;
  {$IF not Defined(ANDROID) and not Defined(IOS)}
  if Button = TMouseButton.mbLeft then
    PointerUp(-1);
  {$ENDIF}
end;

end.

