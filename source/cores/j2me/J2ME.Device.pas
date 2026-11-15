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

implementation

uses
  System.SysUtils;

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
      Create(208, 208), Create(240, 320), Create(320, 240), Create(352, 416), Create(360, 640), Create(480, 800)];
end;

function TJ2MEScreenSize.ToString: string;
begin
  Result := IntToStr(Width) + 'x' + IntToStr(Height);
end;

end.

