unit Core.Input.Touch;

interface

uses
  Core.Emulation.Types;

type
  // Host-neutral primary contact lifecycle. No VM, window or device dependency.
  TEmulationTouchTracker = record
  private
    FDown: Boolean;
    FX, FY: Integer;
  public
    function Update(Phase: TEmulationTouchPhase; X, Y: Integer; Valid: Boolean; out Event: TEmulationTouchEvent): Boolean;
    property Down: Boolean read FDown;
  end;

// Undo presentation rotation and optional aspect-preserving display fitting.
// Black bars and pixels outside the picture never become guest touches.
function MapEmulationTouch(X, Y, DisplayWidth, DisplayHeight, QuarterTurns, CanvasWidth, CanvasHeight: Integer; Fit: Boolean; out CanvasX, CanvasY: Integer): Boolean;

implementation

uses
  System.Math;

function TEmulationTouchTracker.Update(Phase: TEmulationTouchPhase; X, Y: Integer; Valid: Boolean; out Event: TEmulationTouchEvent): Boolean;
begin
  Result := False;
  Event := Default(TEmulationTouchEvent);
  if Phase = TEmulationTouchPhase.Down then
  begin
    if FDown or not Valid then
      Exit;
    FDown := True;
  end
  else
  begin
    if not FDown then
      Exit;
    if (Phase = TEmulationTouchPhase.Cancel) or not Valid then
    begin
      Phase := TEmulationTouchPhase.Cancel;
      X := FX;
      Y := FY;
    end;
    if (Phase = TEmulationTouchPhase.Move) and (X = FX) and (Y = FY) then
      Exit;
    if Phase in [TEmulationTouchPhase.Up, TEmulationTouchPhase.Cancel] then
      FDown := False;
  end;
  FX := X;
  FY := Y;
  Event.Phase := Phase;
  Event.X := X;
  Event.Y := Y;
  Result := True;
end;

function MapEmulationTouch(X, Y, DisplayWidth, DisplayHeight, QuarterTurns, CanvasWidth, CanvasHeight: Integer; Fit: Boolean; out CanvasX, CanvasY: Integer): Boolean;
begin
  Result := False;
  CanvasX := 0;
  CanvasY := 0;
  if (DisplayWidth < 1) or (DisplayHeight < 1) or (CanvasWidth < 1) or (CanvasHeight < 1) then
    Exit;
  QuarterTurns := ((QuarterTurns mod 4) + 4) mod 4;
  var W := DisplayWidth;
  var H := DisplayHeight;
  if Odd(QuarterTurns) then
  begin
    W := DisplayHeight;
    H := DisplayWidth;
  end;
  if (X < 0) or (Y < 0) or (X >= W) or (Y >= H) then
    Exit;
  case QuarterTurns of
    0:
      begin
        CanvasX := X;
        CanvasY := Y;
      end;
    1:
      begin
        CanvasX := Y;
        CanvasY := DisplayHeight - 1 - X;
      end;
    2:
      begin
        CanvasX := DisplayWidth - 1 - X;
        CanvasY := DisplayHeight - 1 - Y;
      end;
    3:
      begin
        CanvasX := DisplayWidth - 1 - Y;
        CanvasY := X;
      end;
  end;
  if Fit then
  begin
    W := DisplayWidth;
    H := DisplayHeight;
    if Int64(W) * CanvasHeight <= Int64(H) * CanvasWidth then
      H := Max(1, Integer(Int64(CanvasHeight) * W div CanvasWidth))
    else
      W := Max(1, Integer(Int64(CanvasWidth) * H div CanvasHeight));
    var Left := (DisplayWidth - W) div 2;
    var Top := (DisplayHeight - H) div 2;
    if (CanvasX < Left) or (CanvasY < Top) or (CanvasX >= Left + W) or (CanvasY >= Top + H) then
      Exit;
    CanvasX := Min(CanvasWidth - 1, Integer(Int64(CanvasX - Left) * CanvasWidth div W));
    CanvasY := Min(CanvasHeight - 1, Integer(Int64(CanvasY - Top) * CanvasHeight div H));
  end;
  Result := (CanvasX >= 0) and (CanvasY >= 0) and (CanvasX < CanvasWidth) and (CanvasY < CanvasHeight);
end;

end.

