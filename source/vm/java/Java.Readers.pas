unit Java.Readers;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime;

procedure InstallJavaReaders(VM: TJVM);

function InvokeJavaReaders(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>; const DefaultEncoding: string): TJVMValue;

implementation

uses
  System.SysUtils, System.Math, Java.Classes, Java.Charsets;

{$Q-}{$R-}

const
  ReaderName = 'java/io/Reader';
  InputName = 'java/io/InputStreamReader';
  StreamName = 'java/io/InputStream';
  LockKey = ReaderName + '.lock:Ljava/lang/Object;';
  InKey = InputName + '.$in:Ljava/io/InputStream;';
  BytesKey = InputName + '.$bytes:[B';

procedure InstallJavaReaders(VM: TJVM);
var
  B: TJavaClassBuilder;
  Lock: Word;

  procedure Done;
  begin
    VM.DefineClass(B.Detach);
    FreeAndNil(B);
  end;

  procedure Native(const Name, Desc: string; Access: Word = JVM_ACC_PUBLIC);
  begin
    B.JavaClass.AddNative(Name, Desc).Access := Access or JVM_ACC_NATIVE;
  end;

  procedure Throw(const Name: string);
  begin
    B.Ref($BB, B.ClassRef(Name));
    B.Emit([$59]);
    B.Ref($B7, B.Member(Name, '<init>', '()V'));
    B.Emit([$BF]);
  end;

  procedure Handler(const First, Last, Target: string);
  var
    H: TJVMExceptionHandler;
  begin
    H := Default(TJVMExceptionHandler);
    H.StartPC := B.Position(First);
    H.EndPC := B.Position(Last);
    H.HandlerPC := B.Position(Target);
    B.JavaClass.Methods.Last.Handlers := [H];
  end;

  procedure Locked(const Name, Desc, Leaf: string; const LoadArgs: array of Byte; Locals: Byte; IsVoid: Boolean);
  begin
    B.Start;
    B.Emit([$2A]);
    B.Ref($B4, B.Member(ReaderName, 'lock', 'Ljava/lang/Object;', 9));
    B.Emit([$59, $3A, Locals, $C2]);
    B.Mark('locked');
    B.Emit([$2A]);
    B.Emit(LoadArgs);
    B.Ref($B7, B.Member(InputName, Leaf, Desc));
    if not IsVoid then
      B.Emit([$36, Byte(Locals + 1)]);
    B.Emit([$19, Locals, $C3]);
    B.Mark('unlocked');
    if IsVoid then
      B.Emit([$B1])
    else
      B.Emit([$15, Byte(Locals + 1), $AC]);
    B.Mark('failed');
    B.Emit([$3A, Byte(Locals + 2), $19, Locals, $C3, $19, Byte(Locals + 2), $BF]);
    B.Finish(Name, Desc, JVM_ACC_PUBLIC, 4, Locals + 3);
    Handler('locked', 'unlocked', 'failed');
  end;

begin
  B := nil;
  try
    B := TJavaClassBuilder.Create(ReaderName, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT or $0020);
    Lock := B.Field('lock', 'Ljava/lang/Object;', JVM_ACC_PROTECTED);
    Native('<init>', '()V', JVM_ACC_PROTECTED);
    Native('<init>', '(Ljava/lang/Object;)V', JVM_ACC_PROTECTED);
    B.JavaClass.AddNative('read', '([CII)I').Access := JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT;
    B.JavaClass.AddNative('close', '()V').Access := JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT;
    B.Start;
    B.Emit([$04, $BC, 5, $4C, $2A, $2B, $03, $04]);
    B.Ref($B6, B.Member(ReaderName, 'read', '([CII)I'));
    B.Emit([$02]);
    B.Jump($A0, 'char');
    B.Emit([$02, $AC]);
    B.Mark('char');
    B.Emit([$2B, $03, $34, $AC]);
    B.Finish('read', '()I', JVM_ACC_PUBLIC, 4, 2);
    B.Start;
    B.Emit([$2A, $2B, $03, $2B, $BE]);
    B.Ref($B6, B.Member(ReaderName, 'read', '([CII)I'));
    B.Emit([$AC]);
    B.Finish('read', '([C)I', JVM_ACC_PUBLIC, 4, 2);
    for var Name in ['ready', 'markSupported'] do
    begin
      B.Start;
      B.Emit([$03, $AC]);
      B.Finish(Name, '()Z', JVM_ACC_PUBLIC, 1, 1);
    end;
    Native('mark', '(I)V');
    Native('reset', '()V');
    Native('$skipBuffer', '(J)[C', JVM_ACC_PRIVATE);
    B.Start;
    B.Emit([$1F, $09, $94]);
    B.Jump($9C, 'nonnegative');
    Throw('java/lang/IllegalArgumentException');
    B.Mark('nonnegative');
    B.Emit([$1F, $09, $94]);
    B.Jump($9A, 'start');
    B.Emit([$09, $AD]);
    B.Mark('start');
    B.Emit([$2A]);
    B.Ref($B4, Lock);
    B.Emit([$59, $4E, $C2]);
    B.Mark('locked');
    B.Emit([$2A, $1F]);
    B.Ref($B7, B.Member(ReaderName, '$skipBuffer', '(J)[C'));
    B.Emit([$3A, 4, $1F, $37, 5]);
    B.Mark('loop');
    B.Emit([$16, 5, $09, $94]);
    B.Jump($9E, 'end');
    B.Emit([$2A, $19, 4, $03, $16, 5, $19, 4, $BE, $85, $94]);
    B.Jump($9C, 'full');
    B.Emit([$16, 5, $88]);
    B.Jump($A7, 'read');
    B.Mark('full');
    B.Emit([$19, 4, $BE]);
    B.Mark('read');
    B.Ref($B6, B.Member(ReaderName, 'read', '([CII)I'));
    B.Emit([$36, 7, $15, 7]);
    B.Jump($9B, 'end');
    B.Emit([$15, 7]);
    B.Jump($9A, 'progress');
    Throw('java/io/IOException');
    B.Mark('progress');
    B.Emit([$16, 5, $15, 7, $85, $65, $37, 5]);
    B.Jump($A7, 'loop');
    B.Mark('end');
    B.Emit([$2D, $C3]);
    B.Mark('unlocked');
    B.Emit([$1F, $16, 5, $65, $AD]);
    B.Mark('failed');
    B.Emit([$3A, 8, $2D, $C3, $19, 8, $BF]);
    B.Finish('skip', '(J)J', JVM_ACC_PUBLIC, 7, 9);
    Handler('locked', 'unlocked', 'failed');
    Done;

    B := TJavaClassBuilder.Create(InputName, ReaderName);
    B.Field('$in', 'Ljava/io/InputStream;', JVM_ACC_PRIVATE);
    B.Field('$bytes', '[B', JVM_ACC_PRIVATE);
    for var Name in ['$pos', '$limit', '$pending', '$eof', '$closed', '$charset', '$started', '$little'] do
      B.Field(Name, 'I', JVM_ACC_PRIVATE);
    Native('<init>', '(Ljava/io/InputStream;)V');
    Native('<init>', '(Ljava/io/InputStream;Ljava/lang/String;)V');
    Native('$read', '([CII)I', JVM_ACC_PRIVATE);
    Native('$ready', '()Z', JVM_ACC_PRIVATE);
    Native('$close', '()V', JVM_ACC_PRIVATE);
    Locked('read', '([CII)I', '$read', [$2B, $1C, $1D], 4, False);
    Locked('ready', '()Z', '$ready', [], 1, False);
    Locked('close', '()V', '$close', [], 1, True);
    Done;
  finally
    B.Free;
  end;
end;

function Key(const Name: string): string;
begin
  Result := InputName + '.' + Name + ':I';
end;

function Int(O: TJVMObject; const Name: string): Integer;
begin
  Result := O.Fields[Key(Name)].AsInt;
end;

procedure Put(O: TJVMObject; const Name: string; Value: Integer);
begin
  O.Fields[Key(Name)] := TJVMValue.Int(Value);
end;

function InvokeJavaReaders(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>; const DefaultEncoding: string): TJVMValue;
var
  O, Raw, Target: TJVMObject;
  N: string;
  State: TJavaDecoder;
  Data: TBytes;
  Position, Limit, Pending, Offset, Count, Produced, Ch: Integer;
  Value: TJVMValue;

  procedure Open;
  begin
    if Int(O, '$closed') <> 0 then
      VM.RaiseJava('java/io/IOException', 'Reader closed');
  end;

  procedure Load;
  begin
    Raw := VM.GetObject(O.Fields[BytesKey].AsRef);
    Position := Int(O, '$pos');
    Limit := Int(O, '$limit');
    SetLength(Data, Limit);
    for var I := 0 to Limit - 1 do
      Data[I] := Byte(Raw.Elements[I].AsInt);
    State.Init(TJavaCharset(Int(O, '$charset')));
    State.Started := Int(O, '$started') <> 0;
    State.Little := Int(O, '$little') <> 0;
  end;

  procedure Save;
  begin
    Put(O, '$pos', Position);
    Put(O, '$started', Ord(State.Started));
    Put(O, '$little', Ord(State.Little));
  end;

  procedure Compact;
  begin
    var Left := Limit - Position;
    for var I := 0 to Left - 1 do
      Raw.Elements[I] := Raw.Elements[Position + I];
    Position := 0;
    Limit := Left;
    Put(O, '$pos', 0);
    Put(O, '$limit', Limit);
  end;

  procedure Fetch(Phase, Maximum: Integer);
  begin
    Compact;
    var Requested := Min(Maximum, Length(Raw.Elements) - Limit);
    if Requested <= 0 then
      VM.RaiseJava('java/io/IOException', 'Reader decoder buffer');
    VM.SetNativeContinuation(TJVMValue.Int(Phase or (Limit shl 3) or (Requested shl 16)));
    var Stream := O.Fields[InKey].AsRef;
    VM.InvokeGuestResult(VM.ResolveVirtualMethod(Stream, VM.LoadClass(StreamName).FindMethod('read', '([BII)I')),
      [TJVMValue.Ref(Stream), O.Fields[BytesKey], TJVMValue.Int(Limit), TJVMValue.Int(Requested)]);
  end;

begin
  Result := Default(TJVMValue);
  O := VM.GetObject(Args[0].AsRef);
  N := Method.Name;
  if Method.Owner.Name = ReaderName then
  begin
    if N = '<init>' then
    begin
      var Ref := Args[0].AsRef;
      if Length(Args) > 1 then
        Ref := Args[1].AsRef;
      VM.GetObject(Ref);
      O.Fields[LockKey] := TJVMValue.Ref(Ref);
      Exit;
    end;
    if N = '$skipBuffer' then
    begin
      var Capacity := Integer(Min(Int64(512), Args[1].AsLong));
      Capacity := Min(Capacity, VM.MaxArrayLength);
      if Capacity <= 0 then
        VM.RaiseJava('java/lang/OutOfMemoryError', 'Reader skip buffer limit');
      Exit(TJVMValue.Ref(VM.NewArray('[C', Capacity)));
    end;
    if (N = 'mark') or (N = 'reset') then
      VM.RaiseJava('java/io/IOException', 'Reader mark/reset unsupported');
    raise EJVMUnsupported.Create('Reader method: ' + N);
  end;
  if N = '<init>' then
  begin
    VM.GetObject(Args[1].AsRef);
    var Encoding := DefaultEncoding;
    if Length(Args) = 3 then
      Encoding := VM.GetObject(Args[2].AsRef).Text;
    var Charset := JavaCharset(VM, Encoding);
    var Capacity := Min(4096, VM.MaxArrayLength);
    if Capacity < 4 then
      VM.RaiseJava('java/lang/OutOfMemoryError', 'Reader byte buffer limit');
    var Ref := VM.NewArray('[B', Capacity);
    O.Fields[BytesKey] := TJVMValue.Ref(Ref);
    O.Fields[InKey] := Args[1];
    O.Fields[LockKey] := Args[0];
    Put(O, '$pending', -1);
    Put(O, '$charset', Ord(Charset));
    Put(O, '$little', Ord(Charset = TJavaCharset.UTF16LE));
    Exit;
  end;
  if N = '$close' then
  begin
    if VM.TakeGuestResult(Value) then
      Exit;
    if Int(O, '$closed') <> 0 then
      Exit;
    var Stream := O.Fields[InKey].AsRef;
    Put(O, '$closed', 1);
    Put(O, '$pending', -1);
    O.Fields[BytesKey] := TJVMValue.Ref(0);
    O.Fields[InKey] := TJVMValue.Ref(0);
    VM.InvokeGuestResult(VM.ResolveVirtualMethod(Stream, VM.LoadClass(StreamName).FindMethod('close', '()V')), [TJVMValue.Ref(Stream)]);
    Exit;
  end;
  Open;
  if (N <> '$read') and (N <> '$ready') then
    raise EJVMUnsupported.Create('InputStreamReader method: ' + N);
  if VM.TakeGuestResult(Value) then
  begin
    var Work := VM.NativeContinuation.AsInt;
    var Phase := Work and 7;
    VM.SetNativeContinuation(Default(TJVMValue));
    if Phase = 1 then
    begin
      if Value.AsInt <= 0 then
        Exit(TJVMValue.Int(0));
      Load;
      Fetch(2, Value.AsInt);
      Exit;
    end;
    Raw := VM.GetObject(O.Fields[BytesKey].AsRef);
    var Prefix := (Work shr 3) and $1FFF;
    var Requested := Work shr 16;
    var ReadCount := Value.AsInt;
    if (ReadCount < -1) or (ReadCount > Requested) or (Prefix + Max(0, ReadCount) > Length(Raw.Elements)) then
      VM.RaiseJava('java/io/IOException', 'Invalid InputStream read count');
    if ReadCount = 0 then
      VM.RaiseJava('java/io/IOException', 'InputStream returned zero bytes');
    if ReadCount < 0 then
      Put(O, '$eof', 1)
    else
      Put(O, '$limit', Prefix + ReadCount);
  end;
  Pending := Int(O, '$pending');
  if N = '$ready' then
  begin
    if Pending >= 0 then
      Exit(TJVMValue.Int(1));
    Load;
    var Probe := Position;
    var Decoder := State;
    if JavaDecodeNext(Data, Probe, Limit, Decoder, Int(O, '$eof') <> 0, Ch) then
      Exit(TJVMValue.Int(1));
    Position := Probe;
    State := Decoder;
    Save;
    if Int(O, '$eof') <> 0 then
      Exit(TJVMValue.Int(0));
    Compact;
    VM.SetNativeContinuation(TJVMValue.Int(1));
    var Stream := O.Fields[InKey].AsRef;
    VM.InvokeGuestResult(VM.ResolveVirtualMethod(Stream, VM.LoadClass(StreamName).FindMethod('available', '()I')), [TJVMValue.Ref(Stream)]);
    Exit;
  end;
  Target := VM.GetObject(Args[1].AsRef);
  Offset := Args[2].AsInt;
  Count := Args[3].AsInt;
  if (Offset < 0) or (Count < 0) or (Offset > Length(Target.Elements)) or (Count > Length(Target.Elements) - Offset) then
    VM.RaiseJava('java/lang/IndexOutOfBoundsException');
  if Count = 0 then
    Exit(TJVMValue.Int(0));
  Produced := 0;
  Load;
  if Pending >= 0 then
  begin
    Target.Elements[Offset] := TJVMValue.Int(Pending);
    Put(O, '$pending', -1);
    Inc(Produced);
  end;
  while Produced < Count do
  begin
    if not JavaDecodeNext(Data, Position, Limit, State, Int(O, '$eof') <> 0, Ch) then
      Break;
    if Ch > $FFFF then
    begin
      Dec(Ch, $10000);
      Target.Elements[Offset + Produced] := TJVMValue.Int($D800 or (Ch shr 10));
      Inc(Produced);
      Ch := $DC00 or (Ch and $3FF);
      if Produced = Count then
      begin
        Put(O, '$pending', Ch);
        Break;
      end;
    end;
    Target.Elements[Offset + Produced] := TJVMValue.Int(Ch);
    Inc(Produced);
  end;
  Save;
  if Produced > 0 then
    Exit(TJVMValue.Int(Produced));
  if Int(O, '$eof') <> 0 then
    Exit(TJVMValue.Int(-1));
  Fetch(3, MaxInt);
end;

end.

