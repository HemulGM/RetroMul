unit RM.ShaderCompiler;

interface

uses
  System.SysUtils, FMX.Types3D;

type
  EBitmapShaderCompileError = class(Exception);

// HLSL main(SV_Position): SV_Target, shader model 4.0. Includes are disabled.
function CompileBitmapShaderFile(const FileName: string): TBytes;
// Native text (.glsl/.frag/.metal/.sksl), Windows HLSL, or a .shader.json bundle.
function LoadBitmapShaderSources(const FileName: string): TArray<TContextShaderSource>;

implementation

uses
  System.Classes, System.IOUtils, System.JSON, RM.BitmapShaderSources
  {$IFDEF MSWINDOWS}, Winapi.Windows, Winapi.D3DCommon, Winapi.D3DCompiler{$ENDIF};

function CompileBitmapShaderFile(const FileName: string): TBytes;
{$IFDEF MSWINDOWS}
var
  Source: TBytes;
  Name: UTF8String;
  Code, Errors: ID3DBlob;
  HR: HRESULT;
  Message: string;
begin
  Source := TEncoding.UTF8.GetBytes(TFile.ReadAllText(FileName, TEncoding.UTF8));
  if Length(Source) = 0 then
    raise EBitmapShaderCompileError.Create('The shader file is empty.');
  Name := UTF8String(FileName);
  HR := D3DCompile(@Source[0], Length(Source), PAnsiChar(Name), nil, nil, 'main', 'ps_4_0',
    D3DCOMPILE_ENABLE_STRICTNESS or D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, Code, Errors);
  if Failed(HR) then
  begin
    Message := Format('D3DCompile failed: %.8x', [Cardinal(HR)]);
    if Errors <> nil then
    begin
      SetLength(Result, Errors.GetBufferSize);
      Move(Errors.GetBufferPointer^, Result[0], Length(Result));
      Message := TEncoding.UTF8.GetString(Result).Trim([#0, #10, #13, ' ']);
    end;
    raise EBitmapShaderCompileError.Create(Message);
  end;
  SetLength(Result, Code.GetBufferSize);
  Move(Code.GetBufferPointer^, Result[0], Length(Result));
end;
{$ELSE}
begin
  raise EBitmapShaderCompileError.Create('HLSL compilation requires Windows. Use GLSL, Metal, SkSL or a .shader.json bundle.');
end;
{$ENDIF}

function LoadBitmapShaderSources(const FileName: string): TArray<TContextShaderSource>;
var
  Extension, Text, Path: string;
  Root: TJSONValue;
  Pair: TJSONPair;
  Arch: TContextShaderArch;

  procedure AddSource(AArch: TContextShaderArch; const SourcePath: string);
  var
    Bytes: TBytes;
  begin
    if AArch = TContextShaderArch.DX10 then
      Bytes := CompileBitmapShaderFile(SourcePath)
    else
    begin
      Bytes := TEncoding.UTF8.GetBytes(TFile.ReadAllText(SourcePath, TEncoding.UTF8));
      if Length(Bytes) = 0 then
        raise EBitmapShaderCompileError.Create('The shader file is empty: ' + SourcePath);
    end;
    Result := Result + [BitmapShaderSource(AArch, Bytes)];
  end;

begin
  Result := nil;
  Extension := LowerCase(TPath.GetExtension(FileName));
  if Extension = '.json' then
  begin
    Text := TFile.ReadAllText(FileName, TEncoding.UTF8);
    Root := TJSONObject.ParseJSONValue(Text);
    try
      if not (Root is TJSONObject) then
        raise EBitmapShaderCompileError.Create('Shader bundle must contain hlsl, glsl, metal and/or sksl paths.');
      for Pair in TJSONObject(Root) do
      begin
        if not (Pair.JsonValue is TJSONString) then
          raise EBitmapShaderCompileError.Create('Shader bundle paths must be strings.');
        if SameText(Pair.JsonString.Value, 'hlsl') then
        begin
          {$IFNDEF MSWINDOWS}
          Continue;
          {$ENDIF}
          Arch := TContextShaderArch.DX10;
        end
        else if SameText(Pair.JsonString.Value, 'glsl') then
          Arch := TContextShaderArch.GLSL
        else if SameText(Pair.JsonString.Value, 'metal') then
          Arch := TContextShaderArch.Metal
        else if SameText(Pair.JsonString.Value, 'sksl') then
          Arch := TContextShaderArch.SKSL
        else
          raise EBitmapShaderCompileError.Create('Unknown shader bundle key: ' + Pair.JsonString.Value);
        Path := TPath.GetFullPath(TPath.Combine(ExtractFilePath(TPath.GetFullPath(FileName)), Pair.JsonValue.Value));
        AddSource(Arch, Path);
      end;
    finally
      Root.Free;
    end;
    if Length(Result) = 0 then
      raise EBitmapShaderCompileError.Create('No supported shader variants in the bundle.');
  end
  else if (Extension = '.hlsl') or (Extension = '.fx') then
    AddSource(TContextShaderArch.DX10, FileName)
  else if (Extension = '.glsl') or (Extension = '.frag') then
    AddSource(TContextShaderArch.GLSL, FileName)
  else if Extension = '.metal' then
    AddSource(TContextShaderArch.Metal, FileName)
  else if Extension = '.sksl' then
    AddSource(TContextShaderArch.SKSL, FileName)
  else
    raise EBitmapShaderCompileError.Create('Supported files: .shader.json, .hlsl, .fx, .glsl, .frag, .metal, .sksl.');
end;

end.
