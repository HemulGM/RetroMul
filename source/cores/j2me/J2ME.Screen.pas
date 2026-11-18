unit J2ME.Screen;

interface

uses
  System.JSON, J2ME.Suite, J2ME.Device;

type
  TJ2MEScreenDecision = record
    Size: TJ2MEScreenSize;
    Source: string;
    Evidence: TArray<string>;
    function ToJSON: TJSONObject;
  end;

function DetectJ2MEScreen(Suite: TJ2MESuite; const JarHash: string; MIDletIndex: Integer; const Fallback: TJ2MEScreenSize): TJ2MEScreenDecision;

implementation

uses
  System.SysUtils, System.Math, J2ME.Compatibility, J2ME.Screen.Code;

function TJ2MEScreenDecision.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('width', TJSONNumber.Create(Size.Width));
  Result.AddPair('height', TJSONNumber.Create(Size.Height));
  Result.AddPair('source', Source);
  var A := TJSONArray.Create;
  for var Line in Evidence do
    A.Add(Line);
  Result.AddPair('evidence', A);
end;

function AttributeSize(const Text: string; out Size: TJ2MEScreenSize): Boolean;
begin
  var S := Text.Trim.Replace(',', 'x').Replace(Char($00D7), 'x').Replace('X', 'x');
  var Parts := S.Split(['x']);
  Result := (Length(Parts) = 2) and TJ2MEScreenSize.TryParse(Parts[0].Trim + 'x' + Parts[1].Trim, Size);
end;

function TryGluPhoneScreen(Suite: TJ2MESuite; out Size: TJ2MEScreenSize; out Evidence: TArray<string>): Boolean;
begin
  var Build := Suite.GetProperty('Glu-Build');
  if SameText(Build, 'nokia_e61-multi-ports') then
    Size := TJ2MEScreenSize.Create(320, 240)
  else if SameText(Build, 'nokia_5800-multi-ports') then
    Size := TJ2MEScreenSize.Create(360, 640)
  else
    Exit(False);
  Evidence := ['Glu-Build=' + Build];
  var Orientation := Suite.GetProperty('Glu-Force-Orientation');
  if SameText(Orientation, 'landscape') then
  begin
    Size := TJ2MEScreenSize.Create(Max(Size.Width, Size.Height), Min(Size.Width, Size.Height));
    Evidence := Evidence + ['Glu-Force-Orientation=' + Orientation];
  end
  else if SameText(Orientation, 'portrait') then
  begin
    Size := TJ2MEScreenSize.Create(Min(Size.Width, Size.Height), Max(Size.Width, Size.Height));
    Evidence := Evidence + ['Glu-Force-Orientation=' + Orientation];
  end;
  Result := True;
end;

function DetectJ2MEScreen(Suite: TJ2MESuite; const JarHash: string; MIDletIndex: Integer; const Fallback: TJ2MEScreenSize): TJ2MEScreenDecision;

  function Attribute(const Source, Name: string): string;
  begin
    Result := '';
    if Suite.PropertySource(Name) <> Source then
      Exit;
    Result := Suite.GetProperty(Name);
  end;

begin
  Result := Default(TJ2MEScreenDecision);
  Result.Size := Fallback;
  // A JAD replaces same-named manifest attributes, including empty/invalid ones.
  // Target-display/LCD sizes describe scaling destinations, not the app canvas.
  for var Source in ['jad', 'manifest'] do
  begin
    for var Key in ['RetroMul-Screen-Size', 'Nokia-MIDlet-Original-Display-Size', 'SEMC-Screen-Size', 'MIDxlet-Application-Resolution', 'MIDlet-Screen-Size'] do
      if AttributeSize(Attribute(Source, Key), Result.Size) then
      begin
        Result.Source := Source;
        Result.Evidence := [Key + '=' + Suite.GetProperty(Key)];
        Exit;
      end;
    for var Prefix in ['LGE-MIDlet-', 'MIDlet-Screen-', 'Glu-HardCode-', 'Gamelet-'] do
    begin
      var WidthKey := Prefix + 'Width';
      var HeightKey := Prefix + 'Height';
      var W := Suite.GetProperty(WidthKey);
      var H := Suite.GetProperty(HeightKey);
      var FromJAD := (Suite.PropertySource(WidthKey) = 'jad') or (Suite.PropertySource(HeightKey) = 'jad');
      if FromJAD <> (Source = 'jad') then
        Continue;
      if (W <> '') and (H <> '') and AttributeSize(W + 'x' + H, Result.Size) then
      begin
        Result.Source := Source;
        Result.Evidence := [WidthKey + '=' + W, HeightKey + '=' + H];
        Exit;
      end;
    end;
  end;
  if TryJ2MECompatibilityScreen(JarHash, Result.Size) then
  begin
    Result.Source := 'profile';
    Result.Evidence := ['sha256:' + JarHash.ToLower];
    Exit;
  end;
  if TryGluPhoneScreen(Suite, Result.Size, Result.Evidence) then
  begin
    Result.Source := 'profile';
    Exit;
  end;
  if TryJ2MECodeScreen(Suite, MIDletIndex, Result.Size, Result.Evidence) then
  begin
    Result.Source := 'code';
    Exit;
  end;
  Result.Size := Fallback;
  Result.Source := 'fallback';
end;

end.

