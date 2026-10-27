unit RM.BitmapShaderSources;

interface

uses
  System.SysUtils, FMX.Types3D;

function BitmapShaderSource(Arch: TContextShaderArch; const Code: array of Byte): TContextShaderSource;

function BuiltinBitmapShaderSources: TArray<TContextShaderSource>;

function BuiltinBitmapShaderText(Arch: TContextShaderArch): string;

implementation

uses
  System.RegularExpressions;

{$IFDEF MSWINDOWS}
{$I RM.BitmapShaders.DX.inc}
{$ENDIF}
{$I RM.BitmapShaders.Native.inc}

function BitmapShaderSource(Arch: TContextShaderArch; const Code: array of Byte): TContextShaderSource;
const
  Names: array[0..5] of string = ('SourceSize', 'OutputSize', 'Controls',
    'ModeState', 'LCDControls', 'ColorControls');
var
  Variables: TArray<TContextShaderVariable>;
  I, Index, Size: Integer;
  Text: string;
  Encoded: UTF8String;

  function HasUniform(const Kind, Name: string): Boolean;
  begin
    Result := TRegEx.IsMatch(Text, '\buniform\s+' + Kind + '\s+' + Name + '\s*;');
  end;

begin
  if Arch = TContextShaderArch.SKSL then
  begin
    if Length(Code) = 0 then
      raise EArgumentException.Create('Empty SkSL shader.');
    SetString(Encoded, PAnsiChar(@Code[0]), Length(Code));
    Text := string(Encoded);
    Text := TRegEx.Replace(Text, '(?s)/\*.*?\*/|//[^\r\n]*', '');
  end;
  Variables := nil;
  if (Arch <> TContextShaderArch.SKSL) or HasUniform('shader', 'Input') then
    Variables := Variables + [TContextShaderVariable.Create('Input', TContextShaderVariableKind.Texture, 0, 0)];
  if (Arch <> TContextShaderArch.SKSL) or HasUniform('shader', 'Target') then
    Variables := Variables + [TContextShaderVariable.Create('Target', TContextShaderVariableKind.Texture, Length(Variables), 0)];
  for I := 0 to High(Names) do
  begin
    Index := I;
    Size := 1;
    if Arch in [TContextShaderArch.DX10, TContextShaderArch.DX11, TContextShaderArch.DX11_level_9] then
    begin
      Index := I * 16;
      Size := 16;
    end;
    if (Arch <> TContextShaderArch.SKSL) or HasUniform('float4', Names[I]) then
      Variables := Variables + [TContextShaderVariable.Create(Names[I], TContextShaderVariableKind.Vector, Index, Size)];
  end;
  Result := TContextShaderSource.Create(Arch, Code, Variables);
end;

function BuiltinBitmapShaderSources: TArray<TContextShaderSource>;
begin
  {$IFDEF MSWINDOWS}
  Result := [BitmapShaderSource(TContextShaderArch.DX10, BitmapShaderDX)];
  {$ELSE}
  Result := [];
  {$ENDIF}
  Result := Result + [
      BitmapShaderSource(TContextShaderArch.GLSL, TEncoding.UTF8.GetBytes(BitmapShaderGLSL)),
      BitmapShaderSource(TContextShaderArch.Metal, TEncoding.UTF8.GetBytes(BitmapShaderMetal)),
      BitmapShaderSource(TContextShaderArch.SKSL, TEncoding.UTF8.GetBytes(BitmapShaderSkSL))];
end;

function BuiltinBitmapShaderText(Arch: TContextShaderArch): string;
begin
  case Arch of
    TContextShaderArch.GLSL:
      Result := BitmapShaderGLSL;
    TContextShaderArch.Metal:
      Result := BitmapShaderMetal;
    TContextShaderArch.SKSL:
      Result := BitmapShaderSkSL;
  else
    raise EArgumentException.Create('Text source is available for GLSL, Metal and SkSL only.');
  end;
end;

end.

