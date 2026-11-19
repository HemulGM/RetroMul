unit J2ME.Items;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime;

procedure InstallJ2MEItems(VM: TJVM);

function InvokeJ2MEItem(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>; Width: Integer; out Changed: Boolean): TJVMValue;

implementation

uses
  System.SysUtils, System.Math, Java.Classes, J2ME.Item.Layout, J2ME.UI.Data;

{$Q-}{$R-}

const
  UI = 'javax/microedition/lcdui/';
  ItemName = UI + 'Item';
  GaugeName = UI + 'Gauge';

function Int(O: TJVMObject; const Name: string; Default: Integer = 0): Integer;
var
  V: TJVMValue;
begin
  if O.Fields.TryGetValue('$ui.' + Name, V) then
    Result := V.AsInt
  else
    Result := Default;
end;

function Ref(O: TJVMObject; const Name: string): Integer;
var
  V: TJVMValue;
begin
  if O.Fields.TryGetValue('$ui.' + Name, V) then
    Result := V.AsRef
  else
    Result := 0;
end;

procedure Put(O: TJVMObject; const Name: string; Value: Integer);
begin
  O.Fields.AddOrSetValue('$ui.' + Name, TJVMValue.Int(Value));
end;

procedure PutRef(O: TJVMObject; const Name: string; Value: Integer);
begin
  O.Fields.AddOrSetValue('$ui.' + Name, TJVMValue.Ref(Value));
end;

procedure InstallJ2MEItems(VM: TJVM);
const
  GraphicsDesc = 'Ljavax/microedition/lcdui/Graphics;';
var
  B: TJavaClassBuilder;

  procedure Native(const Name, Desc: string; Flags: Word = JVM_ACC_PUBLIC);
  begin
    B.JavaClass.AddNative(Name, Desc).Access := Flags or JVM_ACC_NATIVE;
  end;

  procedure Constant(const Name: string; Value: Integer; Visibility: Word = JVM_ACC_PUBLIC);
  begin
    B.Field(Name, 'I', Visibility or JVM_ACC_STATIC or JVM_ACC_FINAL);
    B.JavaClass.Fields.Last.Value := TJVMValue.Int(Value);
  end;

  procedure CustomMeasurement(const Name, Completion: string; WithHeightHint: Boolean);
  begin
    var Query := Name = '$querySize';
    B.Start;
    if Query then
    begin
      B.Emit([$2A]);
      B.Ref($B6, B.Member(J2MECustomItemClass, 'getMinContentWidth', '()I'));
      B.Emit([$36, 4, $2A, $1B, $15, 4]); // istore_4, receiver, requested width, minimum width
      B.Ref($B7, B.Member(J2MECustomItemClass, '$queryWidth', '(II)I'));
      B.Emit([$3C]); // istore_1
    end;
    B.Emit([$2A, $1B, $1C]); // receiver, width hint, generation
    if Query then
      B.Emit([$15, 4])
    else
    begin
      B.Emit([$2A]);
      B.Ref($B6, B.Member(J2MECustomItemClass, 'getMinContentWidth', '()I'));
    end;
    B.Emit([$2A]);
    B.Ref($B6, B.Member(J2MECustomItemClass, 'getMinContentHeight', '()I'));
    B.Emit([$2A]);
    if WithHeightHint then
      B.Emit([$1D]) // iload_3
    else
      B.Emit([$02]); // iconst_m1
    B.Ref($B6, B.Member(J2MECustomItemClass, 'getPrefContentWidth', '(I)I'));
    B.Emit([$2A, $1B]);
    B.Ref($B6, B.Member(J2MECustomItemClass, 'getPrefContentHeight', '(I)I'));
    B.Ref($B7, B.Member(J2MECustomItemClass, Completion, '(IIIIII)V'));
    B.Emit([$B1]);
    if WithHeightHint then
      B.Finish(Name, '(III)V', JVM_ACC_PRIVATE, 8, 4 + Ord(Query))
    else
      B.Finish(Name, '(II)V', JVM_ACC_PRIVATE, 8, 3);
  end;

begin
  B := TJavaClassBuilder.Create(ItemName, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT or $0020);
  try
    Constant('LAYOUT_DEFAULT', 0);
    Constant('LAYOUT_LEFT', 1);
    Constant('LAYOUT_RIGHT', 2);
    Constant('LAYOUT_CENTER', 3);
    Constant('LAYOUT_TOP', $10);
    Constant('LAYOUT_BOTTOM', $20);
    Constant('LAYOUT_VCENTER', $30);
    Constant('LAYOUT_NEWLINE_BEFORE', $100);
    Constant('LAYOUT_NEWLINE_AFTER', $200);
    Constant('LAYOUT_SHRINK', $400);
    Constant('LAYOUT_EXPAND', $800);
    Constant('LAYOUT_VSHRINK', $1000);
    Constant('LAYOUT_VEXPAND', $2000);
    Constant('LAYOUT_2', $4000);
    Constant('PLAIN', 0);
    Constant('HYPERLINK', 1);
    Constant('BUTTON', 2);
    Native('<init>', '(Ljava/lang/String;)V', JVM_ACC_PROTECTED);
    Native('setLabel', '(Ljava/lang/String;)V');
    Native('getLabel', '()Ljava/lang/String;');
    Native('setLayout', '(I)V');
    Native('getLayout', '()I');
    Native('addCommand', '(Ljavax/microedition/lcdui/Command;)V');
    Native('removeCommand', '(Ljavax/microedition/lcdui/Command;)V');
    Native('setDefaultCommand', '(Ljavax/microedition/lcdui/Command;)V');
    Native('setItemCommandListener', '(Ljavax/microedition/lcdui/ItemCommandListener;)V');
    Native('setPreferredSize', '(II)V');
    for var Name in ['getMinimumWidth', 'getMinimumHeight', 'getPreferredWidth', 'getPreferredHeight'] do
      Native(Name, '()I');
    Native('notifyStateChanged', '()V', JVM_ACC_PROTECTED);
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  B := TJavaClassBuilder.Create(J2MECustomItemClass, ItemName, JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT or $0020);
  try
    Constant('NONE', 0, JVM_ACC_PROTECTED);
    Constant('TRAVERSE_HORIZONTAL', 1, JVM_ACC_PROTECTED);
    Constant('TRAVERSE_VERTICAL', 2, JVM_ACC_PROTECTED);
    Constant('KEY_PRESS', 4, JVM_ACC_PROTECTED);
    Constant('KEY_RELEASE', 8, JVM_ACC_PROTECTED);
    Constant('KEY_REPEAT', 16, JVM_ACC_PROTECTED);
    Constant('POINTER_PRESS', 32, JVM_ACC_PROTECTED);
    Constant('POINTER_RELEASE', 64, JVM_ACC_PROTECTED);
    Constant('POINTER_DRAG', 128, JVM_ACC_PROTECTED);
    Native('<init>', '(Ljava/lang/String;)V', JVM_ACC_PROTECTED);
    Native('getGameAction', '(I)I');
    Native('getInteractionModes', '()I', JVM_ACC_PROTECTED or JVM_ACC_FINAL);
    Native('invalidate', '()V', JVM_ACC_PROTECTED or JVM_ACC_FINAL);
    Native('repaint', '()V', JVM_ACC_PROTECTED or JVM_ACC_FINAL);
    Native('repaint', '(IIII)V', JVM_ACC_PROTECTED or JVM_ACC_FINAL);
    for var Name in ['getMinContentWidth', 'getMinContentHeight'] do
      B.JavaClass.AddNative(Name, '()I').Access := JVM_ACC_PROTECTED or JVM_ACC_ABSTRACT;
    for var Name in ['getPrefContentWidth', 'getPrefContentHeight'] do
      B.JavaClass.AddNative(Name, '(I)I').Access := JVM_ACC_PROTECTED or JVM_ACC_ABSTRACT;
    B.JavaClass.AddNative('paint', '(' + GraphicsDesc + 'II)V').Access := JVM_ACC_PROTECTED or JVM_ACC_ABSTRACT;
    for var Name in ['showNotify', 'hideNotify', 'traverseOut'] do
    begin
      B.Start;
      B.Emit([$B1]);
      B.Finish(Name, '()V', JVM_ACC_PROTECTED, 0, 1);
    end;
    for var Name in ['keyPressed', 'keyReleased', 'keyRepeated'] do
    begin
      B.Start;
      B.Emit([$B1]);
      B.Finish(Name, '(I)V', JVM_ACC_PROTECTED, 0, 2);
    end;
    for var Name in ['pointerPressed', 'pointerReleased', 'pointerDragged', 'sizeChanged'] do
    begin
      B.Start;
      B.Emit([$B1]);
      B.Finish(Name, '(II)V', JVM_ACC_PROTECTED, 0, 3);
    end;
    B.Start;
    B.Emit([$03, $AC]); // iconst_0, ireturn
    B.Finish('traverse', '(III[I)Z', JVM_ACC_PROTECTED, 1, 5);

    Native('$dimensions', '(IIIIII)V', JVM_ACC_PRIVATE);
    Native('$queriedDimensions', '(IIIIII)V', JVM_ACC_PRIVATE);
    Native('$queryWidth', '(II)I', JVM_ACC_PRIVATE);
    Native('$beginDraw', '(II)' + GraphicsDesc, JVM_ACC_PRIVATE);
    Native('$endDraw', '(' + GraphicsDesc + ')V', JVM_ACC_PRIVATE);
    Native('$resize', '(II)Z', JVM_ACC_PRIVATE);
    Native('$showNeeded', '()Z', JVM_ACC_PRIVATE);
    Native('$paintAllowed', '()Z', JVM_ACC_PRIVATE);
    Native('$hideNeeded', '()Z', JVM_ACC_PRIVATE);
    Native('$pointer', '(Ljavax/microedition/lcdui/Form;III)V', JVM_ACC_PRIVATE);
    Native('$repeatKey', '(I)V', JVM_ACC_PRIVATE);
    Native('$traverseFocus', '(Ljavax/microedition/lcdui/Form;)V', JVM_ACC_PRIVATE);
    Native('$leaveTraversal', '()V', JVM_ACC_PRIVATE);

    // Retain the original bytecode entry point for queued and running saves.
    CustomMeasurement('$measure', '$dimensions', False);
    CustomMeasurement('$measureForLayout', '$dimensions', True);
    CustomMeasurement('$querySize', '$queriedDimensions', True);

    B.Start;
    B.Emit([$2A, $1B, $1C]);
    B.Ref($B7, B.Member(J2MECustomItemClass, '$beginDraw', '(II)' + GraphicsDesc));
    B.Emit([$4E, $2D]); // astore_3, aload_3
    B.Jump($C6, 'done');
    B.Emit([$2A, $1B, $1C]);
    B.Ref($B7, B.Member(J2MECustomItemClass, '$resize', '(II)Z'));
    B.Jump($99, 'show');
    B.Emit([$2A, $1B, $1C]);
    B.Ref($B6, B.Member(J2MECustomItemClass, 'sizeChanged', '(II)V'));
    B.Mark('show');
    B.Emit([$2A]);
    B.Ref($B7, B.Member(J2MECustomItemClass, '$paintAllowed', '()Z'));
    B.Jump($99, 'done');
    B.Emit([$2A]);
    B.Ref($B7, B.Member(J2MECustomItemClass, '$showNeeded', '()Z'));
    B.Jump($99, 'paint');
    B.Emit([$2A]);
    B.Ref($B6, B.Member(J2MECustomItemClass, 'showNotify', '()V'));
    B.Mark('paint');
    B.Emit([$2A]);
    B.Ref($B7, B.Member(J2MECustomItemClass, '$paintAllowed', '()Z'));
    B.Jump($99, 'done');
    B.Emit([$2A, $2D, $1B, $1C]);
    B.Ref($B6, B.Member(J2MECustomItemClass, 'paint', '(' + GraphicsDesc + 'II)V'));
    B.Emit([$2A, $2D]);
    B.Ref($B7, B.Member(J2MECustomItemClass, '$endDraw', '(' + GraphicsDesc + ')V'));
    B.Mark('done');
    B.Emit([$B1]);
    B.Finish('$draw', '(II)V', JVM_ACC_PRIVATE, 4, 4);

    B.Start;
    B.Emit([$2A]);
    B.Ref($B7, B.Member(J2MECustomItemClass, '$hideNeeded', '()Z'));
    B.Jump($99, 'done');
    B.Emit([$2A]);
    B.Ref($B6, B.Member(J2MECustomItemClass, 'hideNotify', '()V'));
    B.Mark('done');
    B.Emit([$B1]);
    B.Finish('$hide', '()V', JVM_ACC_PRIVATE, 1, 1);
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  B := TJavaClassBuilder.Create(UI + 'ItemCommandListener', 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT or $0200);
  try
    B.JavaClass.AddNative('commandAction', '(Ljavax/microedition/lcdui/Command;Ljavax/microedition/lcdui/Item;)V').Access := JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT;
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  B := TJavaClassBuilder.Create(GaugeName, ItemName);
  try
    Constant('INDEFINITE', -1);
    Constant('CONTINUOUS_IDLE', 0);
    Constant('INCREMENTAL_IDLE', 1);
    Constant('CONTINUOUS_RUNNING', 2);
    Constant('INCREMENTAL_UPDATING', 3);
    Native('<init>', '(Ljava/lang/String;ZII)V');
    Native('setValue', '(I)V');
    Native('getValue', '()I');
    Native('setMaxValue', '(I)V');
    Native('getMaxValue', '()I');
    Native('isInteractive', '()Z');
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
end;

function InvokeJ2MEItem(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>; Width: Integer; out Changed: Boolean): TJVMValue;
var
  O: TJVMObject;
  N: string;

  procedure CheckMutable;
  begin
    var Owner := Ref(O, 'owner');
    if (Owner <> 0) and VM.IsAssignable(VM.GetObject(Owner).ClassName, UI + 'Alert') then
      VM.RaiseJava('java/lang/IllegalStateException', 'Item is an Alert indicator');
  end;

  procedure MaxValue(Value: Integer);
  begin
    if (Value <= 0) and ((Value <> -1) or (Int(O, 'interactive') <> 0)) then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'Gauge maximum');
  end;

  procedure SetValue(Value: Integer);
  begin
    var Maximum := Int(O, 'maximum');
    if Maximum = -1 then
    begin
      if (Value < 0) or (Value > 3) then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'Indefinite gauge value');
      if Value = 3 then
        Put(O, 'pulse', Int(O, 'pulse') + 1);
    end
    else
      Value := EnsureRange(Value, 0, Maximum);
    Put(O, 'value', Value);
    Changed := True;
  end;

  procedure Command(Cmd: Integer; Adding: Boolean);
  begin
    if Cmd = 0 then
    begin
      if Adding then
        VM.GetObject(0);
      Exit;
    end;
    var Values: TArray<TJVMValue>;
    var Old := Ref(O, 'itemCommands');
    if Old <> 0 then
      Values := Copy(VM.GetObject(Old).Elements);
    var Found := -1;
    for var I := 0 to High(Values) do
      if Values[I].AsRef = Cmd then
        Found := I;
    if Adding then
    begin
      if Found >= 0 then
        Exit;
      if Length(Values) >= 1024 then
        VM.RaiseJava('java/lang/OutOfMemoryError', 'Item command limit');
      var I := Length(Values);
      SetLength(Values, I + 1);
      Values[I] := TJVMValue.Ref(Cmd);
    end
    else
    begin
      if Found < 0 then
        Exit;
      for var I := Found to High(Values) - 1 do
        Values[I] := Values[I + 1];
      SetLength(Values, Length(Values) - 1);
    end;
    var New := VM.NewArray('[Ljavax/microedition/lcdui/Command;', Length(Values));
    VM.GetObject(New).Elements := Values;
    PutRef(O, 'itemCommands', New);
    if not Adding and (Ref(O, 'itemDefault') = Cmd) then
      PutRef(O, 'itemDefault', 0);
    Changed := True;
  end;

begin
  Changed := False;
  Result := Default(TJVMValue);
  O := VM.GetObject(Args[0].AsRef);
  N := Method.Name;
  if N = '<init>' then
  begin
    if Method.Owner.Name = GaugeName then
    begin
      Put(O, 'itemKind', 4);
      Put(O, 'interactive', Args[2].AsInt);
      MaxValue(Args[3].AsInt);
      Put(O, 'maximum', Args[3].AsInt);
      SetValue(Args[4].AsInt);
    end;
    PutRef(O, 'label', Args[1].AsRef);
    Put(O, 'preferredWidth', -1);
    Put(O, 'preferredHeight', -1);
    Exit;
  end;
  if N = 'getLabel' then
    Exit(TJVMValue.Ref(Ref(O, 'label')));
  if N = 'getLayout' then
    Exit(TJVMValue.Int(Int(O, 'layout')));
  if N = 'getValue' then
    Exit(TJVMValue.Int(Int(O, 'value')));
  if N = 'getMaxValue' then
    Exit(TJVMValue.Int(Int(O, 'maximum')));
  if N = 'isInteractive' then
    Exit(TJVMValue.Int(Int(O, 'interactive')));
  if N = 'setValue' then
  begin
    SetValue(Args[1].AsInt);
    Exit;
  end;
  if N = 'setMaxValue' then
  begin
    var Value := Args[1].AsInt;
    MaxValue(Value);
    var Previous := Int(O, 'maximum');
    if Previous = Value then
      Exit;
    Put(O, 'maximum', Value);
    if ((Previous = -1) <> (Value = -1)) then
      SetValue(0)
    else
      SetValue(Int(O, 'value'));
    Exit;
  end;
  if N.StartsWith('getMinimum') or N.StartsWith('getPreferred') then
  begin
    var WidthLimit := Max(1, Width - 12);
    var IsCustom := UIInt(O, 'itemKind') = J2MECustomItemKind;
    var Metrics := J2MEItemMetrics(VM, Args[0].AsRef, WidthLimit, -1, IsCustom);
    if IsCustom then
    begin
      var Completed: TJVMValue;
      var Attempts := 0;
      if VM.TakeGuestResult(Completed) then
        Attempts := VM.NativeContinuation.AsInt;
      var Generation := UIInt(O, 'customGeneration');
      var WidthHint := WidthLimit;
      if UIInt(O, 'preferredWidth', -1) >= 0 then
        WidthHint := Max(1, Metrics.PreferredWidth);
      if (Attempts < 2) and ((UIInt(O, 'customQueryMeasuredWidth', -1) <> WidthHint) or
        (UIInt(O, 'customQueryMeasuredGeneration') <> Generation)) then
      begin
        var C := VM.LoadClass(J2MECustomItemClass);
        var Query := C.FindMethod('$querySize', '(III)V');
        var Ref := Args[0].AsRef;
        // A dimension callback may itself query the Item. It can use the
        // last completed dimensions without entering its own callback again.
        if not VM.IsCurrentInstanceCall(Query, Ref) and
          not VM.IsCurrentInstanceCall(C.FindMethod('$measureForLayout', '(III)V'), Ref) and
          not VM.IsCurrentInstanceCall(C.FindMethod('$measure', '(II)V'), Ref) then
        begin
          var HeightHint := UIInt(O, 'preferredHeight', -1);
          if HeightHint >= 0 then
            HeightHint := EnsureRange(HeightHint - Metrics.LabelHeight, 0, J2MECustomItemExtent);
          VM.SetNativeContinuation(TJVMValue.Int(Attempts + 1));
          VM.InvokeGuestResult(Query, [Args[0], TJVMValue.Int(WidthHint), TJVMValue.Int(Generation), TJVMValue.Int(HeightHint)]);
          Exit;
        end;
      end;
    end;
    var Value := Metrics.PreferredWidth;
    if N.EndsWith('Height') then
    begin
      Value := Metrics.PreferredHeight;
      if N.StartsWith('getMinimum') then
        Value := Metrics.MinimumHeight;
    end
    else if N.StartsWith('getMinimum') then
      Value := Metrics.MinimumWidth;
    Exit(TJVMValue.Int(Value));
  end;
  CheckMutable;
  if N = 'notifyStateChanged' then
    VM.RaiseJava('java/lang/IllegalStateException', 'Item is not in a Form');
  if N = 'setLabel' then
    PutRef(O, 'label', Args[1].AsRef)
  else if N = 'setLayout' then
  begin
    var Value := Args[1].AsInt;
    if (Value and not $7F33) <> 0 then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'Item layout');
    Put(O, 'layout', Value);
  end
  else if N = 'setPreferredSize' then
  begin
    if (Args[1].AsInt < -1) or (Args[2].AsInt < -1) then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'Item preferred size');
    Put(O, 'preferredWidth', Args[1].AsInt);
    Put(O, 'preferredHeight', Args[2].AsInt);
  end
  else if N = 'setItemCommandListener' then
    PutRef(O, 'itemListener', Args[1].AsRef)
  else if (N = 'addCommand') or (N = 'removeCommand') then
    Command(Args[1].AsRef, N = 'addCommand')
  else if N = 'setDefaultCommand' then
  begin
    Command(Args[1].AsRef, Args[1].AsRef <> 0);
    PutRef(O, 'itemDefault', Args[1].AsRef);
  end
  else
    raise EJVMUnsupported.Create('Item method: ' + N);
  if (UIInt(O, 'itemKind') = J2MECustomItemKind) and ((N = 'setPreferredSize') or (N = 'setLabel')) then
    UIPut(O, 'customGeneration', UIInt(O, 'customGeneration') + 1);
  Changed := True;
end;

end.

