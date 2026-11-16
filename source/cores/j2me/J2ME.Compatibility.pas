unit J2ME.Compatibility;

interface

uses
  J2ME.Device, J2ME.Runtime;

// Exact JAR identities only. Names and image dimensions are not reliable hints.
function TryJ2MECompatibilityScreen(const JarHash: string; out Size: TJ2MEScreenSize): Boolean;

procedure MigrateJ2MECompatibilityScreen(const JarHash: string; Runtime: TJ2MERuntime); overload;

procedure MigrateJ2MECompatibilityScreen(const JarHash: string; Runtime: TJ2MERuntime; const Size: TJ2MEScreenSize); overload;

implementation

uses
  System.SysUtils, System.Classes, System.Math, JVM.Types, JVM.ClassFile;

const
  BiplanesHash = '356e01e2b47fb0fd8868e6729f928cad4c0ad79d43c57195f82e6be4a08ea72c';

function TryJ2MECompatibilityScreen(const JarHash: string; out Size: TJ2MEScreenSize): Boolean;
begin
  Size := Default(TJ2MEScreenSize);
  Result := SameText(JarHash, BiplanesHash);
  // This port has a 255x208 world and no sizeChanged handler. A taller phone
  // makes its camera limit negative and leaves rows outside its background.
  if Result then
    Size := TJ2MEScreenSize.Create(176, 208);
end;

procedure MigrateJ2MECompatibilityScreen(const JarHash: string; Runtime: TJ2MERuntime);
begin
  var Size: TJ2MEScreenSize;
  if TryJ2MECompatibilityScreen(JarHash, Size) then
    MigrateJ2MECompatibilityScreen(JarHash, Runtime, Size);
end;

procedure MigrateJ2MECompatibilityScreen(const JarHash: string; Runtime: TJ2MERuntime; const Size: TJ2MEScreenSize);
var
  C: TJVMClass;

  function Field(const Name, Descriptor: string): TJVMField;
  begin
    for var F in C.Fields do
      if (F.Name = Name) and (F.Descriptor = Descriptor) then
        Exit(F);
    raise EReadError.Create('Incompatible saved phone layout');
  end;

  procedure Put(const Name: string; Value: Integer);
  begin
    Field(Name, 'I').Value := TJVMValue.Int(Value);
  end;

begin
  var Known: TJ2MEScreenSize;
  if not TryJ2MECompatibilityScreen(JarHash, Known) then
    Exit;
  // A higher-priority descriptor can select another supported viewport. Do not
  // silently replace that decision with the database's preferred dimensions.
  if (Size.Width < 1) or (Size.Height < 1) or (Size.Width > 255) or (Size.Height > 208) then
    Exit;
  if (Runtime.ScreenWidth = Size.Width) and (Runtime.ScreenHeight = Size.Height) then
    Exit;
  C := Runtime.VM.LoadClass('b');
  // Only layout values cached from getWidth/getHeight by this exact port.
  // Gameplay, RMS, input, RNG and threads remain those of the saved moment.
  Put('r', Size.Width);
  Put('s', Size.Height);
  Put('ak', 255 - Size.Width);
  Put('al', 208 - Size.Height);
  Put('ai', EnsureRange(Field('ai', 'I').Value.AsInt, 0, 255 - Size.Width));
  Put('aj', EnsureRange(Field('aj', 'I').Value.AsInt, 0, 208 - Size.Height));
  Put('dt', Size.Width - 3);
  Put('ds', Size.Width - 5);
  Put('dq', Size.Width - 11);
  Put('dp', Size.Width - 13);
  var Ref := Field('d1', '[I').Value.AsRef;
  if Ref <> 0 then
  begin
    var A := Runtime.VM.GetObject(Ref);
    if Length(A.Elements) <> 2 then
      raise EReadError.Create('Incompatible saved phone layout');
    A.Elements[0] := TJVMValue.Int(Size.Height - 48);
    A.Elements[1] := TJVMValue.Int(Size.Height - 28);
  end;
  Runtime.ResizeCanvas(Size.Width, Size.Height);
end;

end.

