unit J2ME.Forms;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime;

procedure InstallJ2MEForms(VM: TJVM);

function InvokeJ2MEForm(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>; Width, Height: Integer; out Changed: Boolean): TJVMValue;

function J2MEFormItems(VM: TJVM; Form: Integer): TJVMObject;

function J2MEItemFocusable(VM: TJVM; Item: Integer): Boolean;

function J2MEFormFocused(VM: TJVM; Form: Integer): Integer;

procedure J2MEFormFocus(VM: TJVM; Form, Item: Integer);

procedure J2MEFormMarkChanged(VM: TJVM; Form, Item: Integer);

implementation

uses
  System.SysUtils, System.Math, System.Generics.Collections, Java.Classes,
  J2ME.UI.Data, J2ME.Text, J2ME.Font, J2ME.Image;

{$Q-}{$R-}

const
  FormName = J2MEUI + 'Form';
  ItemName = J2MEUI + 'Item';
  StateName = J2MEUI + 'ItemStateListener';

function ItemArray(VM: TJVM; Count: Integer): Integer;
begin
  if Count > VM.MaxArrayLength then
    VM.RaiseJava('java/lang/OutOfMemoryError', 'Form array capacity');
  Result := VM.NewArray('[Ljavax/microedition/lcdui/Item;', Count);
end;

procedure InstallJ2MEForms(VM: TJVM);
var
  B: TJavaClassBuilder;

  procedure Native(const Name, Desc: string; Flags: Word = JVM_ACC_PUBLIC);
  begin
    B.JavaClass.AddNative(Name, Desc).Access := Flags or JVM_ACC_NATIVE;
  end;

begin
  B := TJavaClassBuilder.Create(StateName, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT or $0200);
  try
    B.JavaClass.AddNative('itemStateChanged', '(Ljavax/microedition/lcdui/Item;)V').Access := JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT;
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  B := TJavaClassBuilder.Create(FormName, J2MEUI + 'Screen');
  try
    Native('<init>', '(Ljava/lang/String;)V');
    Native('<init>', '(Ljava/lang/String;[Ljavax/microedition/lcdui/Item;)V');
    for var Desc in ['Ljavax/microedition/lcdui/Item;', 'Ljava/lang/String;', 'Ljavax/microedition/lcdui/Image;'] do
      Native('append', '(' + Desc + ')I');
    Native('insert', '(ILjavax/microedition/lcdui/Item;)V');
    Native('set', '(ILjavax/microedition/lcdui/Item;)V');
    Native('get', '(I)Ljavax/microedition/lcdui/Item;');
    Native('delete', '(I)V');
    Native('deleteAll', '()V');
    Native('size', '()I');
    Native('setItemStateListener', '(Ljavax/microedition/lcdui/ItemStateListener;)V');
    Native('getWidth', '()I');
    Native('getHeight', '()I');
    Native('$nextChanged', '()Ljavax/microedition/lcdui/Item;', JVM_ACC_PRIVATE);
    Native('$stateListener', '()Ljavax/microedition/lcdui/ItemStateListener;', JVM_ACC_PRIVATE);
    Native('$sendCommand', '(Ljavax/microedition/lcdui/Command;Ljavax/microedition/lcdui/Item;)V', JVM_ACC_PRIVATE);
    B.Start;
    B.Mark('loop');
    B.Emit([$2A]);
    B.Ref($B7, B.Member(FormName, '$nextChanged', '()Ljavax/microedition/lcdui/Item;'));
    B.Emit([$4C, $2B]);
    B.Jump($C6, 'end');
    B.Emit([$2A]);
    B.Ref($B7, B.Member(FormName, '$stateListener', '()Ljavax/microedition/lcdui/ItemStateListener;'));
    B.Emit([$4D, $2C]);
    B.Jump($C6, 'loop');
    B.Emit([$2C, $2B]);
    B.Ref($B9, B.Member(StateName, 'itemStateChanged', '(Ljavax/microedition/lcdui/Item;)V', 11));
    B.Emit([$02, $00]);
    B.Jump($A7, 'loop');
    B.Mark('end');
    B.Emit([$B1]);
    B.Finish('$drain', '()V', JVM_ACC_PRIVATE, 2, 3);
    B.Start;
    B.Emit([$2A]);
    B.Ref($B7, B.Member(FormName, '$drain', '()V'));
    B.Emit([$2A, $2B, $2C]);
    B.Ref($B7, B.Member(FormName, '$sendCommand', '(Ljavax/microedition/lcdui/Command;Ljavax/microedition/lcdui/Item;)V'));
    B.Emit([$B1]);
    B.Finish('$command', '(Ljavax/microedition/lcdui/Command;Ljavax/microedition/lcdui/Item;)V', JVM_ACC_PRIVATE, 3, 3);
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  B := TJavaClassBuilder.Create(J2MEUI + 'StringItem', ItemName);
  try
    Native('<init>', '(Ljava/lang/String;Ljava/lang/String;)V');
    Native('<init>', '(Ljava/lang/String;Ljava/lang/String;I)V');
    Native('getText', '()Ljava/lang/String;');
    Native('setText', '(Ljava/lang/String;)V');
    Native('getAppearanceMode', '()I');
    Native('getFont', '()Ljavax/microedition/lcdui/Font;');
    Native('setFont', '(Ljavax/microedition/lcdui/Font;)V');
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  B := TJavaClassBuilder.Create(J2MEUI + 'ImageItem', ItemName);
  try
    Native('<init>', '(Ljava/lang/String;Ljavax/microedition/lcdui/Image;ILjava/lang/String;)V');
    Native('<init>', '(Ljava/lang/String;Ljavax/microedition/lcdui/Image;ILjava/lang/String;I)V');
    Native('getImage', '()Ljavax/microedition/lcdui/Image;');
    Native('setImage', '(Ljavax/microedition/lcdui/Image;)V');
    Native('getAltText', '()Ljava/lang/String;');
    Native('setAltText', '(Ljava/lang/String;)V');
    Native('getAppearanceMode', '()I');
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  B := TJavaClassBuilder.Create(J2MEUI + 'Spacer', ItemName);
  try
    Native('<init>', '(II)V');
    Native('setMinimumSize', '(II)V');
    Native('setLabel', '(Ljava/lang/String;)V');
    Native('addCommand', '(Ljavax/microedition/lcdui/Command;)V');
    Native('setDefaultCommand', '(Ljavax/microedition/lcdui/Command;)V');
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
end;

function J2MEFormItems(VM: TJVM; Form: Integer): TJVMObject;
begin
  Result := VM.GetObject(UIRef(VM.GetObject(Form), 'items'));
end;

function J2MEItemFocusable(VM: TJVM; Item: Integer): Boolean;
begin
  Result := False;
  if Item = 0 then
    Exit;
  var O := VM.GetObject(Item);
  var Commands := UIRef(O, 'itemCommands');
  Result := (UIInt(O, 'itemKind') = J2MECustomItemKind) or VM.IsAssignable(O.ClassName, J2MEUI + 'DateField') or VM.IsAssignable(O.ClassName, J2MEUI + 'TextField') or VM.IsAssignable(O.ClassName, J2MEUI + 'ChoiceGroup') or
    (VM.IsAssignable(O.ClassName, J2MEUI + 'Gauge') and (UIInt(O, 'interactive') <> 0)) or
    ((Commands <> 0) and (Length(VM.GetObject(Commands).Elements) <> 0));
end;

procedure J2MEFormFocus(VM: TJVM; Form, Item: Integer);
begin
  var O := VM.GetObject(Form);
  var Values := J2MEFormItems(VM, Form);
  var Previous := UIInt(O, 'focus', -1);
  var Index := -1;
  for var I := 0 to High(Values.Elements) do
    if Values.Elements[I].AsRef = Item then
    begin
      Index := I;
      Break;
    end;
  if Index < 0 then
    VM.RaiseJava('java/lang/IllegalStateException', 'Item not in Form');
  if (Previous >= 0) and (Previous < Length(Values.Elements)) and (Previous <> Index) then
  begin
    var Old := VM.GetObject(Values.Elements[Previous].AsRef);
    if UIInt(Old, 'expanded') <> 0 then
    begin
      UIPut(Old, 'expanded', 0);
      UIInvalidateOwner(VM, Old);
    end;
    UIPut(Old, 'editing', 0);
    UIPut(Old, 'dateDigits', 0);
    UIPut(Old, 'tapKey', 0);
    UIPut(Old, 'negativePending', 0);
  end;
  if Index <> Previous then
  begin
    var Current := VM.GetObject(Item);
    if VM.IsAssignable(Current.ClassName, J2MEUI + 'TextField') then
      J2METextBegin(VM, Current);
  end;
  UIPut(O, 'focus', Index);
  UIPut(O, 'ensureFocus', 1);
end;

function J2MEFormFocused(VM: TJVM; Form: Integer): Integer;
begin
  var O := VM.GetObject(Form);
  var Values := J2MEFormItems(VM, Form);
  var Focus := UIInt(O, 'focus', -1);
  if (Focus >= 0) and (Focus < Length(Values.Elements)) then
  begin
    Result := Values.Elements[Focus].AsRef;
    if J2MEItemFocusable(VM, Result) then
      Exit;
  end;
  for var Value in Values.Elements do
    if J2MEItemFocusable(VM, Value.AsRef) then
    begin
      J2MEFormFocus(VM, Form, Value.AsRef);
      Exit(Value.AsRef);
    end;
  UIPut(O, 'focus', -1);
  Result := 0;
end;

procedure J2MEFormMarkChanged(VM: TJVM; Form, Item: Integer);
begin
  var O := VM.GetObject(Item);
  if UIRef(O, 'owner') <> Form then
    Exit;
  if UIInt(O, 'statePending') <> 0 then
    Exit;
  var Owner := VM.GetObject(Form);
  var Queue := UIRef(Owner, 'stateQueue');
  var Head := UIInt(Owner, 'stateHead');
  var Values: TArray<TJVMValue>;
  if Queue <> 0 then
  begin
    var Old := VM.GetObject(Queue);
    var Count := 0;
    SetLength(Values, Length(Old.Elements) - Head);
    for var I := Head to High(Old.Elements) do
      if Old.Elements[I].AsRef <> 0 then
      begin
        Values[Count] := Old.Elements[I];
        Inc(Count);
      end;
    SetLength(Values, Count);
  end;
  if Length(Values) >= 1024 then
    VM.RaiseJava('java/lang/OutOfMemoryError', 'Item event queue limit');
  var Count := Length(Values);
  SetLength(Values, Count + 1);
  Values[Count] := TJVMValue.Ref(Item);
  var Ref := ItemArray(VM, Length(Values));
  VM.GetObject(Ref).Elements := Values;
  UIPutRef(Owner, 'stateQueue', Ref);
  UIPut(Owner, 'stateHead', 0);
  UIPut(O, 'statePending', 1);
end;

function InvokeJ2MEForm(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>; Width, Height: Integer; out Changed: Boolean): TJVMValue;
var
  O, Items: TJVMObject;
  N, ClassName: string;
  Count, Index: Integer;

  procedure Appearance(Value: Integer);
  begin
    if (Value < 0) or (Value > 2) then
      VM.RaiseJava('java/lang/IllegalArgumentException', 'Item appearance');
    UIPut(O, 'appearance', Value);
  end;

  procedure SetImage(Ref: Integer);
  begin
    var Snapshot := UIImageSnapshot(VM, Ref);
    UIPutRef(O, 'itemImage', Ref);
    UIPutRef(O, 'imageSnapshot', Snapshot);
  end;

  procedure Bounds(Index: Integer; Inserting: Boolean = False);
  begin
    if (Index < 0) or (Index >= Count + Ord(Inserting)) then
      VM.RaiseJava('java/lang/IndexOutOfBoundsException');
  end;

  procedure Unowned(Ref: Integer);
  begin
    if UIRef(VM.GetObject(Ref), 'owner') <> 0 then
      VM.RaiseJava('java/lang/IllegalStateException', 'Item already owned');
  end;

  procedure Detach(Item: Integer);
  begin
    var Ref := UIRef(O, 'stateQueue');
    if Ref <> 0 then
      for var I := 0 to High(VM.GetObject(Ref).Elements) do
        if VM.GetObject(Ref).Elements[I].AsRef = Item then
          VM.GetObject(Ref).Elements[I] := TJVMValue.Ref(0);
    var Value := VM.GetObject(Item);
    UIPutRef(Value, 'owner', 0);
    UIPut(Value, 'statePending', 0);
    UIPut(Value, 'editing', 0);
    UIPut(Value, 'tapKey', 0);
    if UIRef(O, 'ensureItem') = Item then
      UIPutRef(O, 'ensureItem', 0);
  end;

  procedure ChangedForm;
  begin
    UIPut(O, 'version', UIInt(O, 'version') + 1);
    UIPut(O, 'ensureFocus', 1);
    Changed := True;
  end;

begin
  Result := Default(TJVMValue);
  Changed := False;
  O := VM.GetObject(Args[0].AsRef);
  N := Method.Name;
  ClassName := Method.Owner.Name;
  if ClassName <> FormName then
  begin
    if N = 'getAppearanceMode' then
      Exit(TJVMValue.Int(UIInt(O, 'appearance')));
    if ClassName = J2MEUI + 'Spacer' then
    begin
      if (N <> '<init>') and (N <> 'setMinimumSize') then
        VM.RaiseJava('java/lang/IllegalStateException', 'Spacer cannot have a label or commands');
      if (Args[1].AsInt < 0) or (Args[2].AsInt < 0) then
        VM.RaiseJava('java/lang/IllegalArgumentException', 'Spacer minimum');
      if N = '<init>' then
      begin
        UIInitItem(O, 0);
        UIPut(O, 'itemKind', 3);
      end;
      UIPut(O, 'minimumWidth', Min(1048576, Args[1].AsInt));
      UIPut(O, 'minimumHeight', Min(1048576, Args[2].AsInt));
      Changed := True;
      Exit;
    end;
    if N = '<init>' then
    begin
      var Mode := 0;
      if ClassName = J2MEUI + 'StringItem' then
      begin
        if Length(Args) = 4 then
          Mode := Args[3].AsInt;
      end
      else if Length(Args) = 6 then
        Mode := Args[5].AsInt;
      Appearance(Mode);
      UIInitItem(O, Args[1].AsRef);
      if ClassName = J2MEUI + 'StringItem' then
      begin
        UIPut(O, 'itemKind', 1);
        UIPutRef(O, 'text', Args[2].AsRef);
      end
      else
      begin
        if (Args[3].AsInt and not $7F33) <> 0 then
          VM.RaiseJava('java/lang/IllegalArgumentException', 'ImageItem layout');
        UIPut(O, 'itemKind', 2);
        SetImage(Args[2].AsRef);
        UIPut(O, 'layout', Args[3].AsInt);
        UIPutRef(O, 'altText', Args[4].AsRef);
      end;
      Exit;
    end;
    if N = 'getText' then
      Exit(TJVMValue.Ref(UIRef(O, 'text')));
    if N = 'getImage' then
      Exit(TJVMValue.Ref(UIRef(O, 'itemImage')));
    if N = 'getAltText' then
      Exit(TJVMValue.Ref(UIRef(O, 'altText')));
    if N = 'getFont' then
    begin
      var Ref := UIRef(O, 'font');
      if Ref = 0 then
        Ref := J2MEGetFont(VM, 0, 0, 8);
      Exit(TJVMValue.Ref(Ref));
    end;
    if N = 'setText' then
      UIPutRef(O, 'text', Args[1].AsRef)
    else if N = 'setImage' then
      SetImage(Args[1].AsRef)
    else if N = 'setAltText' then
      UIPutRef(O, 'altText', Args[1].AsRef)
    else if N = 'setFont' then
    begin
      if Args[1].AsRef <> 0 then
        J2MEFontView(VM, Args[1].AsRef);
      UIPutRef(O, 'font', Args[1].AsRef);
    end
    else
      raise EJVMUnsupported.Create('Form item method: ' + N);
    Changed := True;
    Exit;
  end;
  if N = '$stateListener' then
    Exit(TJVMValue.Ref(UIRef(O, 'stateListener')));
  if N = '$nextChanged' then
  begin
    var Queue := UIRef(O, 'stateQueue');
    if Queue = 0 then
      Exit(TJVMValue.Ref(0));
    var Values := VM.GetObject(Queue);
    var Head := UIInt(O, 'stateHead');
    while Head < Length(Values.Elements) do
    begin
      var Ref := Values.Elements[Head].AsRef;
      Values.Elements[Head] := TJVMValue.Ref(0);
      Inc(Head);
      UIPut(O, 'stateHead', Head);
      if Ref = 0 then
        Continue;
      var Item := VM.GetObject(Ref);
      if (UIRef(Item, 'owner') <> Args[0].AsRef) or (UIInt(Item, 'statePending') = 0) then
        Continue;
      UIPut(Item, 'statePending', 0);
      Exit(TJVMValue.Ref(Ref));
    end;
    UIPutRef(O, 'stateQueue', 0);
    UIPut(O, 'stateHead', 0);
    Exit(TJVMValue.Ref(0));
  end;
  if N = '<init>' then
  begin
    var Values: TArray<TJVMValue>;
    if (Length(Args) = 3) and (Args[2].AsRef <> 0) then
      Values := Copy(VM.GetObject(Args[2].AsRef).Elements);
    if Length(Values) > 65536 then
      VM.RaiseJava('java/lang/OutOfMemoryError', 'Form item limit');
    var Seen := TDictionary<Integer, Byte>.Create;
    try
      for var Value in Values do
      begin
        Unowned(Value.AsRef);
        if Seen.ContainsKey(Value.AsRef) then
          VM.RaiseJava('java/lang/IllegalStateException', 'Duplicate Form item');
        Seen.Add(Value.AsRef, 0);
      end;
      var Ref := ItemArray(VM, Length(Values));
      VM.GetObject(Ref).Elements := Values;
      UIPutRef(O, 'items', Ref);
      UIPutRef(O, 'title', Args[1].AsRef);
      UIPut(O, 'focus', -1);
      for var Value in Values do
        UIPutRef(VM.GetObject(Value.AsRef), 'owner', Args[0].AsRef);
    finally
      Seen.Free;
    end;
    Exit;
  end;
  if N = 'setItemStateListener' then
  begin
    UIPutRef(O, 'stateListener', Args[1].AsRef);
    Exit;
  end;
  if N = 'getWidth' then
    Exit(TJVMValue.Int(Max(1, Width - 12)));
  if N = 'getHeight' then
    Exit(TJVMValue.Int(Height));
  Items := J2MEFormItems(VM, Args[0].AsRef);
  Count := Length(Items.Elements);
  if N = 'size' then
    Exit(TJVMValue.Int(Count));
  if (N = 'deleteAll') and (Count = 0) then
    Exit;
  if N = 'get' then
  begin
    Bounds(Args[1].AsInt);
    Exit(Items.Elements[Args[1].AsInt]);
  end;
  var Values := Copy(Items.Elements);
  var OldFocus := 0;
  var Focus := UIInt(O, 'focus', -1);
  if (Focus >= 0) and (Focus < Count) then
    OldFocus := Values[Focus].AsRef;
  var Removed := 0;
  var Added := 0;
  if N = 'deleteAll' then
    Values := nil
  else if (N = 'delete') or (N = 'set') or (N = 'insert') then
  begin
    Index := Args[1].AsInt;
    Bounds(Index, N = 'insert');
    if N = 'delete' then
    begin
      Removed := Values[Index].AsRef;
      for var I := Index to Count - 2 do
        Values[I] := Values[I + 1];
      SetLength(Values, Count - 1);
    end
    else
    begin
      Added := Args[2].AsRef;
      Unowned(Added);
      if N = 'set' then
      begin
        Removed := Values[Index].AsRef;
        Values[Index] := TJVMValue.Ref(Added);
      end
      else
      begin
        if Count >= 65536 then
          VM.RaiseJava('java/lang/OutOfMemoryError', 'Form item limit');
        SetLength(Values, Count + 1);
        for var I := Count downto Index + 1 do
          Values[I] := Values[I - 1];
        Values[Index] := TJVMValue.Ref(Added);
      end;
    end;
  end
  else if N = 'append' then
  begin
    if Count >= 65536 then
      VM.RaiseJava('java/lang/OutOfMemoryError', 'Form item limit');
    var Ref := Args[1].AsRef;
    VM.GetObject(Ref);
    Added := Ref;
    if Method.Descriptor = '(Ljava/lang/String;)I' then
    begin
      Added := VM.NewObject(J2MEUI + 'StringItem');
      UIInitItem(VM.GetObject(Added), 0);
      UIPut(VM.GetObject(Added), 'itemKind', 1);
      UIPutRef(VM.GetObject(Added), 'text', Ref);
    end
    else if Method.Descriptor = '(Ljavax/microedition/lcdui/Image;)I' then
    begin
      var Snapshot := UIImageSnapshot(VM, Ref);
      Added := VM.NewObject(J2MEUI + 'ImageItem');
      UIInitItem(VM.GetObject(Added), 0);
      UIPut(VM.GetObject(Added), 'itemKind', 2);
      UIPutRef(VM.GetObject(Added), 'itemImage', Ref);
      UIPutRef(VM.GetObject(Added), 'imageSnapshot', Snapshot);
    end;
    Unowned(Added);
    SetLength(Values, Count + 1);
    Values[Count] := TJVMValue.Ref(Added);
    Result := TJVMValue.Int(Count);
  end
  else
    raise EJVMUnsupported.Create('Form method: ' + N);
  var Ref := ItemArray(VM, Length(Values));
  VM.GetObject(Ref).Elements := Values;
  // Commit only after validation and allocation, preserving old ownership on failure.
  if N = 'deleteAll' then
  begin
    UIPutRef(O, 'stateQueue', 0);
    UIPut(O, 'stateHead', 0);
    for var Value in Items.Elements do
      Detach(Value.AsRef);
  end;
  if Removed <> 0 then
    Detach(Removed);
  if Added <> 0 then
    UIPutRef(VM.GetObject(Added), 'owner', Args[0].AsRef);
  UIPutRef(O, 'items', Ref);
  var NewFocus := -1;
  for var I := 0 to High(Values) do
    if Values[I].AsRef = OldFocus then
      NewFocus := I;
  UIPut(O, 'focus', NewFocus);
  ChangedForm;
end;

end.

