unit J2ME.Device;

interface

type
  // Geometry of the virtual phone, independent of VM, renderer and frontend.
  // A size is not a claim to emulate a particular handset's other capabilities.
  TJ2MEScreenSize = record
    Width, Height: Integer;
    class function Create(Width, Height: Integer): TJ2MEScreenSize; static;
    class function TryParse(const Value: string; out Size: TJ2MEScreenSize): Boolean; static;
    class function Presets: TArray<TJ2MEScreenSize>; static;
    function ToString: string;
  end;

  // Evidence from repeated, unclipped screen viewport requests, never assets
  // or title identities. A candidate must recur in eight completed frames.
  TJ2MEViewportEvidence = record
  private
    FWidth, FHeight, FFrames, FPendingWidth, FPendingHeight: Integer;
    FConflict: Boolean;
  public
    procedure Observe(Width, Height, CanvasWidth, CanvasHeight: Integer);
    procedure CompleteFrame;
    function Recommendation(out Size: TJ2MEScreenSize): Boolean;
  end;

  IJ2MEResolutionAdvice = interface
    ['{15AAAE94-3A74-46DB-9795-BE7FA0FE4E09}']
    function TakeResolutionAdvice(out Current, Recommended: TJ2MEScreenSize): Boolean;
  end;

implementation

uses
  System.SysUtils;

procedure TJ2MEViewportEvidence.Observe(Width, Height, CanvasWidth, CanvasHeight: Integer);
begin
  // Oversized images, translated clips, and subregions are not a viewport.
  // The caller supplies only origin-aligned setClip on the display Graphics.
  if (Width < CanvasWidth) or (Height < CanvasHeight) or
    (Width > 1024) or (Height > 1024) or
    ((Width = CanvasWidth) = (Height = CanvasHeight)) then
    Exit;
  if (FPendingWidth <> 0) and
    ((FPendingWidth <> Width) or (FPendingHeight <> Height)) then
    FConflict := True;
  FPendingWidth := Width;
  FPendingHeight := Height;
end;

procedure TJ2MEViewportEvidence.CompleteFrame;
begin
  if FConflict or (FPendingWidth = 0) then
    FFrames := 0
  else
  begin
    if (FWidth <> FPendingWidth) or (FHeight <> FPendingHeight) then
      FFrames := 0;
    FWidth := FPendingWidth;
    FHeight := FPendingHeight;
    if FFrames < 8 then
      Inc(FFrames);
  end;
  FPendingWidth := 0;
  FPendingHeight := 0;
  FConflict := False;
end;

function TJ2MEViewportEvidence.Recommendation(out Size: TJ2MEScreenSize): Boolean;
begin
  Size := Default(TJ2MEScreenSize);
  Result := FFrames >= 8;
  if Result then
    Size := TJ2MEScreenSize.Create(FWidth, FHeight);
end;

class function TJ2MEScreenSize.Create(Width, Height: Integer): TJ2MEScreenSize;
begin
  if (Width < 1) or (Width > 1024) or (Height < 1) or (Height > 1024) then
    raise EArgumentOutOfRangeException.Create('Java ME screen dimensions');
  Result.Width := Width;
  Result.Height := Height;
end;

class function TJ2MEScreenSize.TryParse(const Value: string; out Size: TJ2MEScreenSize): Boolean;
begin
  Result := False;
  Size := Default(TJ2MEScreenSize);
  var Text := Trim(Value);
  var Separator := 0;
  for var I := 1 to Length(Text) do
    if (Text[I] = 'x') or (Text[I] = 'X') then
    begin
      if Separator <> 0 then
        Exit;
      Separator := I;
    end
    else if not CharInSet(Text[I], ['0'..'9']) then
      Exit;
  if (Separator < 2) or (Separator = Length(Text)) then
    Exit;
  var W, H: Integer;
  if not TryStrToInt(Copy(Text, 1, Separator - 1), W) or not TryStrToInt(Copy(Text, Separator + 1, MaxInt), H) then
    Exit;
  if (W < 1) or (W > 1024) or (H < 1) or (H > 1024) then
    Exit;
  Size.Width := W;
  Size.Height := H;
  Result := True;
end;

class function TJ2MEScreenSize.Presets: TArray<TJ2MEScreenSize>;
begin
  Result := [Create(96, 65), Create(101, 80), Create(128, 128), Create(128, 160), Create(176, 208), Create(176, 220),
      Create(208, 208), Create(240, 320), Create(240, 400), Create(320, 240), Create(352, 416), Create(360, 640), Create(480, 800)];
end;

function TJ2MEScreenSize.ToString: string;
begin
  Result := IntToStr(Width) + 'x' + IntToStr(Height);
end;

end.

