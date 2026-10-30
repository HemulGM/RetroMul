unit Core.Platforms.NDS.Display;

interface

uses
  System.Types, Core.Emulation.Types;

const
  NDS_SCREEN_GAP_MAX = 128;

type
  TNDSDisplayMode = (Stacked, SideBySide);

  // Presentation geometry only. The hardware frame remains 256 x 384.
  TNDSDisplayLayout = record
    Mode: TNDSDisplayMode;
    Gap: Integer;
    class function Create(Mode: TNDSDisplayMode; Gap: Integer): TNDSDisplayLayout; static;
    function Width: Integer;
    function Height: Integer;
    function Screens: TArray<TRect>;
    function SameAs(const Other: TNDSDisplayLayout): Boolean;
    function TouchPoint(X, Y: Integer; out TouchX, TouchY: Integer): Boolean;
    procedure Compose(const Source: TEmulatorFrame; out Frame: TEmulatorFrame);
  end;

implementation

uses
  System.SysUtils, System.Math, System.UITypes;

class function TNDSDisplayLayout.Create(Mode: TNDSDisplayMode; Gap: Integer): TNDSDisplayLayout;
begin
  Result.Mode := Mode;
  Result.Gap := EnsureRange(Gap, 0, NDS_SCREEN_GAP_MAX);
end;

function TNDSDisplayLayout.Width: Integer;
begin
  Result := 256;
  if Mode = TNDSDisplayMode.SideBySide then
    Result := 512 + Gap;
end;

function TNDSDisplayLayout.Height: Integer;
begin
  Result := 192;
  if Mode = TNDSDisplayMode.Stacked then
    Result := 384 + Gap;
end;

function TNDSDisplayLayout.Screens: TArray<TRect>;
begin
  SetLength(Result, 2);
  Result[0] := Rect(0, 0, 256, 192);
  if Mode = TNDSDisplayMode.SideBySide then
    Result[1] := Rect(256 + Gap, 0, 512 + Gap, 192)
  else
    Result[1] := Rect(0, 192 + Gap, 256, 384 + Gap);
end;

function TNDSDisplayLayout.SameAs(const Other: TNDSDisplayLayout): Boolean;
begin
  Result := (Mode = Other.Mode) and (Gap = Other.Gap);
end;

function TNDSDisplayLayout.TouchPoint(X, Y: Integer; out TouchX, TouchY: Integer): Boolean;
begin
  var Bounds := Screens[1];
  TouchX := X - Bounds.Left;
  TouchY := Y - Bounds.Top;
  Result := (TouchX >= 0) and (TouchX < 256) and (TouchY >= 0) and (TouchY < 192);
end;

procedure TNDSDisplayLayout.Compose(const Source: TEmulatorFrame; out Frame: TEmulatorFrame);
begin
  if (Source.Width <> 256) or (Source.Height <> 384) or (Length(Source.Pixels) <> 256 * 384) then
    raise EArgumentException.Create('Invalid Nintendo DS hardware frame');
  Frame := Source;
  Frame.Width := Width;
  Frame.Height := Height;
  if (Mode = TNDSDisplayMode.Stacked) and (Gap = 0) then
    Exit;
  Frame.Pixels := nil;
  SetLength(Frame.Pixels, Frame.Width * Frame.Height);
  for var I := 0 to High(Frame.Pixels) do
    Frame.Pixels[I] := TAlphaColors.Black;
  var Bounds := Screens;
  for var Screen := 0 to 1 do
    for var Y := 0 to 191 do
      Move(Source.Pixels[(Screen * 192 + Y) * 256],
        Frame.Pixels[(Bounds[Screen].Top + Y) * Frame.Width + Bounds[Screen].Left], 256 * SizeOf(TAlphaColor));
end;

end.

