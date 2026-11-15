unit J2ME.GameCanvas;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime;

procedure InstallJ2MEGameCanvas(VM: TJVM; SiemensColor: Boolean = False);

function J2MEGameCanvasHandles(const ClassName: string): Boolean;

function J2MEIsGameCanvas(VM: TJVM; Screen: Integer): Boolean;

function J2MEGameAction(Code: Integer): Integer;

procedure J2MEClearGameKeys(ObjectValue: TJVMObject);

function J2MEGameKeyEvent(ObjectValue: TJVMObject; Code: Integer; Pressed, FreshPress: Boolean): Boolean;

function InvokeJ2MEGameCanvas(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>; Shown: Boolean; var Pixels: TArray<UInt32>; Width, Height: Integer; out Flushed: Boolean): TJVMValue;

implementation

uses
  System.SysUtils, System.Math, Java.Classes, J2ME.Image, J2ME.Graphics;

const
  GameCanvasClass = 'javax/microedition/lcdui/game/GameCanvas';
  SiemensGameCanvasClass = 'com/siemens/mp/color_game/GameCanvas';

function J2MEGameCanvasHandles(const ClassName: string): Boolean;
begin
  Result := (ClassName = GameCanvasClass) or (ClassName = SiemensGameCanvasClass);
end;

function J2MEIsGameCanvas(VM: TJVM; Screen: Integer): Boolean;
begin
  Result := (Screen <> 0) and (VM.IsAssignable(VM.GetObject(Screen).ClassName, GameCanvasClass) or
    VM.IsAssignable(VM.GetObject(Screen).ClassName, SiemensGameCanvasClass));
end;

function J2MEGameAction(Code: Integer): Integer;
begin
  case Code of
    -1, 50:
      Result := 1;
    -2, 56:
      Result := 6;
    -3, 52:
      Result := 2;
    -4, 54:
      Result := 5;
    -5, 53:
      Result := 8;
    49:
      Result := 9;
    51:
      Result := 10;
    55:
      Result := 11;
    57:
      Result := 12;
  else
    Result := 0;
  end;
end;

procedure InstallJ2MEGameCanvas(VM: TJVM; SiemensColor: Boolean);
var
  B: TJavaClassBuilder;
  ClassName: string;

  procedure Mask(const Name: string; Action: Integer);
  begin
    B.Field(Name + '_PRESSED', 'I', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
    B.JavaClass.Fields.Last.Value := TJVMValue.Int(1 shl Action);
  end;

begin
  ClassName := GameCanvasClass;
  if SiemensColor then
    ClassName := SiemensGameCanvasClass;
  B := TJavaClassBuilder.Create(ClassName, 'javax/microedition/lcdui/Canvas', JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT or $0020);
  try
    Mask('UP', 1);
    Mask('DOWN', 6);
    Mask('LEFT', 2);
    Mask('RIGHT', 5);
    Mask('FIRE', 8);
    Mask('GAME_A', 9);
    Mask('GAME_B', 10);
    Mask('GAME_C', 11);
    Mask('GAME_D', 12);
    B.JavaClass.AddNative('<init>', '(Z)V').Access := JVM_ACC_PROTECTED or JVM_ACC_NATIVE;
    B.JavaClass.AddNative('getGraphics', '()Ljavax/microedition/lcdui/Graphics;').Access := JVM_ACC_PROTECTED or JVM_ACC_NATIVE;
    B.JavaClass.AddNative('getKeyStates', '()I');
    B.JavaClass.AddNative('paint', '(Ljavax/microedition/lcdui/Graphics;)V');
    B.JavaClass.AddNative('flushGraphics', '()V');
    B.JavaClass.AddNative('flushGraphics', '(IIII)V');
    if SiemensColor then
    begin
      B.JavaClass.AddNative('keyPressed', '(I)V').Access := JVM_ACC_PROTECTED or JVM_ACC_NATIVE;
      B.JavaClass.AddNative('keyRepeated', '(I)V').Access := JVM_ACC_PROTECTED or JVM_ACC_NATIVE;
    end;
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
end;

procedure J2MEClearGameKeys(ObjectValue: TJVMObject);
begin
  for var Name in ObjectValue.Fields.Keys.ToArray do
    if Name.StartsWith('$gc.key.') then
      ObjectValue.Fields.Remove(Name);
  ObjectValue.Fields.AddOrSetValue('$gc.held', TJVMValue.Int(0));
  ObjectValue.Fields.AddOrSetValue('$gc.latch', TJVMValue.Int(0));
end;

function J2MEGameKeyEvent(ObjectValue: TJVMObject; Code: Integer; Pressed, FreshPress: Boolean): Boolean;
var
  Action, Mask, Held: Integer;
begin
  Action := J2MEGameAction(Code);
  Result := False;
  if Action = 0 then
    Exit;
  Mask := 1 shl Action;
  if Pressed then
  begin
    if FreshPress then
    begin
      ObjectValue.Fields.AddOrSetValue('$gc.key.' + IntToStr(Code), TJVMValue.Int(Mask));
      ObjectValue.Fields['$gc.latch'] := TJVMValue.Int(ObjectValue.Fields['$gc.latch'].AsInt or Mask);
    end;
  end
  else
    ObjectValue.Fields.Remove('$gc.key.' + IntToStr(Code));
  Held := 0;
  for var Pair in ObjectValue.Fields do
    if Pair.Key.StartsWith('$gc.key.') then
      Held := Held or Pair.Value.AsInt;
  ObjectValue.Fields['$gc.held'] := TJVMValue.Int(Held);
  Result := ObjectValue.Fields['$gc.suppress'].AsInt <> 0;
end;

function InvokeJ2MEGameCanvas(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>; Shown: Boolean; var Pixels: TArray<UInt32>; Width, Height: Integer; out Flushed: Boolean): TJVMValue;
var
  O: TJVMObject;
  View: TJ2MEImageView;
  Ref, I, L, T, R, B, Row, Col: Integer;
  V: TJVMValue;
begin
  O := VM.GetObject(Args[0].AsRef);
  Flushed := False;
  Result := Default(TJVMValue);
  if Method.Name = '<init>' then
  begin
    O.Fields.AddOrSetValue('$gc.buffer', TJVMValue.Ref(J2MENewMutableImage(VM, Width, Height)));
    O.Fields.AddOrSetValue('$gc.suppress', Args[1]);
    J2MEClearGameKeys(O);
    Exit;
  end;
  if (Method.Name = 'keyPressed') or (Method.Name = 'keyRepeated') then
    Exit;
  if Method.Name = 'getKeyStates' then
  begin
    I := 0;
    if Shown then
      I := O.Fields['$gc.held'].AsInt or O.Fields['$gc.latch'].AsInt;
    O.Fields['$gc.latch'] := TJVMValue.Int(0);
    Exit(TJVMValue.Int(I));
  end;
  Ref := O.Fields['$gc.buffer'].AsRef;
  if Method.Name = 'getGraphics' then
  begin
    I := VM.NewObject('javax/microedition/lcdui/Graphics');
    VM.GetObject(I).Fields.Add('$target', TJVMValue.Ref(Ref));
    Exit(TJVMValue.Ref(I));
  end;
  if Method.Name = 'paint' then
  begin
    InvokeJ2MEGraphics(VM, VM.LoadClass('javax/microedition/lcdui/Graphics').FindMethod('drawImage', '(Ljavax/microedition/lcdui/Image;III)V'),
      [Args[1], TJVMValue.Ref(Ref), TJVMValue.Int(0), TJVMValue.Int(0), TJVMValue.Int(0)], Pixels, Width, Height);
    Exit;
  end;
  if Method.Name = 'flushGraphics' then
  begin
    if not Shown then
      Exit;
    L := 0;
    T := 0;
    R := Width;
    B := Height;
    if Length(Args) = 5 then
    begin
      if (Args[3].AsInt <= 0) or (Args[4].AsInt <= 0) then
        Exit;
      L := Integer(EnsureRange(Int64(Args[1].AsInt), Int64(0), Int64(Width)));
      T := Integer(EnsureRange(Int64(Args[2].AsInt), Int64(0), Int64(Height)));
      R := Integer(EnsureRange(Int64(Args[1].AsInt) + Args[3].AsInt, Int64(0), Int64(Width)));
      B := Integer(EnsureRange(Int64(Args[2].AsInt) + Args[4].AsInt, Int64(0), Int64(Height)));
    end;
    if (L >= R) or (T >= B) then
      Exit;
    View := J2MEImageView(VM, Ref);
    for Row := T to B - 1 do
      for Col := L to R - 1 do
      begin
        V := View.Pixels.Elements[Row * View.Width + Col];
        Pixels[Row * Width + Col] := UInt32(V.AsInt);
      end;
    Flushed := True;
    Exit;
  end;
  raise EJVMUnsupported.Create('GameCanvas native not implemented: ' + Method.Name);
end;

end.

