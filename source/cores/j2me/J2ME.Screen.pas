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
  System.SysUtils, J2ME.Compatibility, J2ME.Screen.Code;

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
    for var Prefix in ['LGE-MIDlet-', 'MIDlet-Screen-'] do
    begin
      var W := Suite.GetProperty(Prefix + 'Width');
      var H := Suite.GetProperty(Prefix + 'Height');
      var FromJAD := (Suite.PropertySource(Prefix + 'Width') = 'jad') or (Suite.PropertySource(Prefix + 'Height') = 'jad');
      if FromJAD <> (Source = 'jad') then
        Continue;
      if (W <> '') and (H <> '') and AttributeSize(W + 'x' + H, Result.Size) then
      begin
        Result.Source := Source;
        Result.Evidence := [Prefix + 'Width=' + W, Prefix + 'Height=' + H];
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
  if TryJ2MECodeScreen(Suite, MIDletIndex, Result.Size, Result.Evidence) then
  begin
    Result.Source := 'code';
    Exit;
  end;
  Result.Size := Fallback;
  Result.Source := 'fallback';
end;

end.

