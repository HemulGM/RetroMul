unit Java.Writers;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime;

procedure InstallJavaWriters(VM: TJVM);

function InvokeJavaWriters(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>; const DefaultEncoding: string): TJVMValue;

implementation

{$Q-}{$R-}

uses
  System.SysUtils, System.Math, Java.Classes, Java.Charsets;

const
  Writer = 'java/io/Writer';
  Output = 'java/io/OutputStreamWriter';
  Stream = 'java/io/OutputStream';
  StringWriter = 'java/io/StringWriter';
  Builder = 'java/lang/StringBuffer';
  LockKey = Writer + '.lock:Ljava/lang/Object;';
  BufferKey = Output + '.$bytes:[B';
  OutKey = Output + '.$out:Ljava/io/OutputStream;';

procedure InstallJavaWriters(VM: TJVM);
var
  B: TJavaClassBuilder;
  Lock, BufferField: Word;

  procedure Done;
  begin
    VM.DefineClass(B.Detach);
    FreeAndNil(B);
  end;

  procedure Native(const Name, Desc: string; Flags: Word = JVM_ACC_PRIVATE);
  begin
    B.JavaClass.AddNative(Name, Desc).Access := Flags or JVM_ACC_NATIVE;
  end;

  procedure Handler(const First, Last, Target: string; Append: Boolean = False);
  var
    H: TJVMExceptionHandler;
  begin
    H := Default(TJVMExceptionHandler);
    H.StartPC := B.Position(First);
    H.EndPC := B.Position(Last);
    H.HandlerPC := B.Position(Target);
    if Append then
      B.JavaClass.Methods.Last.Handlers := B.JavaClass.Methods.Last.Handlers + [H]
    else
      B.JavaClass.Methods.Last.Handlers := [H];
  end;

  procedure Locked(const Name, Desc, Leaf: string; const Loads: array of Byte; Locals: Byte);
  begin
    B.Start;
    B.Emit([$2A, $59, $3A, Locals, $C2]);
    B.Mark('locked');
    B.Emit([$2A]);
    B.Emit(Loads);
    B.Ref($B7, B.Member(Output, Leaf, Desc));
    B.Emit([$19, Locals, $C3]);
    B.Mark('unlocked');
    B.Emit([$B1]);
    B.Mark('failed');
    B.Emit([$3A, Byte(Locals + 1), $19, Locals, $C3, $19, Byte(Locals + 1), $BF]);
    B.Finish(Name, Desc, JVM_ACC_PUBLIC, 4, Locals + 2);
    Handler('locked', 'unlocked', 'failed');
  end;

begin
  B := nil;
  try
    B := TJavaClassBuilder.Create(Writer, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT or $20);
    Lock := B.Field('lock', 'Ljava/lang/Object;', JVM_ACC_PROTECTED);
    Native('<init>', '()V', JVM_ACC_PROTECTED);
    Native('<init>', '(Ljava/lang/Object;)V', JVM_ACC_PROTECTED);
    for var N in ['flush', 'close'] do
      B.JavaClass.AddNative(N, '()V').Access := JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT;
    B.JavaClass.AddNative('write', '([CII)V').Access := JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT;
    Native('$chars', '(Ljava/lang/String;II)[C');
    B.Start;
    B.Emit([$2A, $2B, $03, $2B, $BE]);
    B.Ref($B6, B.Member(Writer, 'write', '([CII)V'));
    B.Emit([$B1]);
    B.Finish('write', '([C)V', JVM_ACC_PUBLIC, 4, 2);
    B.Start;
    B.Emit([$2A, $2B, $03, $2B]);
    B.Ref($B6, B.Member('java/lang/String', 'length', '()I'));
    B.Ref($B6, B.Member(Writer, 'write', '(Ljava/lang/String;II)V'));
    B.Emit([$B1]);
    B.Finish('write', '(Ljava/lang/String;)V', JVM_ACC_PUBLIC, 4, 2);
    B.Start;
    B.Emit([$2A]);
    B.Ref($B4, Lock);
    B.Emit([$59, $4D, $C2]);
    B.Mark('locked');
    B.Emit([$04, $BC, 5, $4E, $2D, $03, $1B, $55, $2A, $2D, $03, $04]);
    B.Ref($B6, B.Member(Writer, 'write', '([CII)V'));
    B.Emit([$2C, $C3]);
    B.Mark('unlocked');
    B.Emit([$B1]);
    B.Mark('failed');
    B.Emit([$3A, 4, $2C, $C3, $19, 4, $BF]);
    B.Finish('write', '(I)V', JVM_ACC_PUBLIC, 4, 5);
    Handler('locked', 'unlocked', 'failed');
    B.Start;
    B.Emit([$2A]);
    B.Ref($B4, Lock);
    B.Emit([$59, $3A, 4, $C2]);
    B.Mark('locked');
    B.Emit([$2A, $2B, $1C, $1D]);
    B.Ref($B7, B.Member(Writer, '$chars', '(Ljava/lang/String;II)[C'));
    B.Emit([$3A, 5, $2A, $19, 5, $03, $1D]);
    B.Ref($B6, B.Member(Writer, 'write', '([CII)V'));
    B.Emit([$19, 4, $C3]);
    B.Mark('unlocked');
    B.Emit([$B1]);
    B.Mark('failed');
    B.Emit([$3A, 6, $19, 4, $C3, $19, 6, $BF]);
    B.Finish('write', '(Ljava/lang/String;II)V', JVM_ACC_PUBLIC, 4, 7);
    Handler('locked', 'unlocked', 'failed');
    Done;

    B := TJavaClassBuilder.Create(Output, Writer);
    B.Field('$out', 'Ljava/io/OutputStream;', JVM_ACC_PRIVATE);
    B.Field('$bytes', '[B', JVM_ACC_PRIVATE);
    for var N in ['$count', '$charset', '$started', '$high', '$closed', '$closing'] do
      B.Field(N, 'I', JVM_ACC_PRIVATE);
    Native('<init>', '(Ljava/io/OutputStream;)V', JVM_ACC_PUBLIC);
    Native('<init>', '(Ljava/io/OutputStream;Ljava/lang/String;)V', JVM_ACC_PUBLIC);
    for var D in ['(I)V', '([CII)V', '(Ljava/lang/String;II)V'] do
      Native('$write', D);
    for var N in ['$flush', '$end', '$downFlush', '$downClose', '$finishClose'] do
      Native(N, '()V');
    Native('$beginClose', '()Z');
    Native('getEncoding', '()Ljava/lang/String;', JVM_ACC_PUBLIC);
    Locked('write', '(I)V', '$write', [$1B], 2);
    Locked('write', '([CII)V', '$write', [$2B, $1C, $1D], 4);
    Locked('write', '(Ljava/lang/String;II)V', '$write', [$2B, $1C, $1D], 4);
    Locked('flush', '()V', '$flush', [], 1);
    // Finalization is guest bytecode: errors/yields in the underlying stream
    // keep ordinary unwinding and monitors, and detach the encoder buffer.
    B.Start;
    B.Emit([$2A, $59, $4C, $C2]);
    B.Mark('locked');
    B.Emit([$2A]);
    B.Ref($B7, B.Member(Output, '$beginClose', '()Z'));
    B.Jump($99, 'done');
    B.Mark('closing');
    B.Emit([$2A]);
    B.Ref($B7, B.Member(Output, '$end', '()V'));
    B.Emit([$01, $4D]);
    B.Mark('flush');
    B.Emit([$2A]);
    B.Ref($B7, B.Member(Output, '$downFlush', '()V'));
    B.Mark('flushed');
    B.Jump($A7, 'close');
    B.Mark('flushError');
    B.Emit([$4D]);
    B.Mark('close');
    B.Emit([$2A]);
    B.Ref($B7, B.Member(Output, '$downClose', '()V'));
    B.Mark('closed');
    B.Jump($A7, 'afterClose');
    B.Mark('closeError');
    B.Emit([$4D]);
    B.Mark('afterClose');
    B.Emit([$2C]);
    B.Jump($C6, 'finalize');
    B.Emit([$2C, $BF]);
    B.Mark('finalize');
    B.Emit([$2A]);
    B.Ref($B7, B.Member(Output, '$finishClose', '()V'));
    B.Mark('finalized');
    B.Jump($A7, 'done');
    B.Mark('closingError');
    B.Emit([$4D, $2A]);
    B.Ref($B7, B.Member(Output, '$finishClose', '()V'));
    B.Emit([$2C, $BF]);
    B.Mark('done');
    B.Emit([$2B, $C3]);
    B.Mark('unlocked');
    B.Emit([$B1]);
    B.Mark('unlockError');
    B.Emit([$4D, $2B, $C3, $2C, $BF]);
    B.Finish('close', '()V', JVM_ACC_PUBLIC, 2, 4);
    Handler('flush', 'flushed', 'flushError');
    Handler('close', 'closed', 'closeError', True);
    Handler('closing', 'finalized', 'closingError', True);
    Handler('locked', 'unlocked', 'unlockError', True);
    Done;

    B := TJavaClassBuilder.Create(StringWriter, Writer);
    BufferField := B.Field('$buffer', 'Ljava/lang/StringBuffer;', JVM_ACC_PRIVATE);
    Native('$check', '([CII)V');
    B.Start;
    B.Emit([$2A, $10, 16]);
    B.Ref($B7, B.Member(StringWriter, '<init>', '(I)V'));
    B.Emit([$B1]);
    B.Finish('<init>', '()V', JVM_ACC_PUBLIC, 2, 1);
    B.Start;
    B.Emit([$2A]);
    B.Ref($B7, B.Member(Writer, '<init>', '()V'));
    B.Emit([$1B]);
    B.Jump($9C, 'valid');
    B.Ref($BB, B.ClassRef('java/lang/IllegalArgumentException'));
    B.Emit([$59]);
    B.Ref($B7, B.Member('java/lang/IllegalArgumentException', '<init>', '()V'));
    B.Emit([$BF]);
    B.Mark('valid');
    B.Emit([$2A]);
    B.Ref($BB, B.ClassRef(Builder));
    B.Emit([$59, $1B]);
    B.Ref($B7, B.Member(Builder, '<init>', '(I)V'));
    B.Ref($B5, BufferField);
    B.Emit([$2A, $2A]);
    B.Ref($B4, BufferField);
    B.Ref($B5, B.Member(Writer, 'lock', 'Ljava/lang/Object;', 9));
    B.Emit([$B1]);
    B.Finish('<init>', '(I)V', JVM_ACC_PUBLIC, 4, 2);
    for var D in ['(I)V', '(Ljava/lang/String;)V', '([CII)V', '(Ljava/lang/String;II)V'] do
    begin
      B.Start;
      if D = '([CII)V' then
      begin
        B.Emit([$2A, $2B, $1C, $1D]);
        B.Ref($B7, B.Member(StringWriter, '$check', D));
      end;
      B.Emit([$2A]);
      B.Ref($B4, BufferField);
      var Append := '(Ljava/lang/String;)Ljava/lang/StringBuffer;';
      var Locals := 2;
      if D = '(I)V' then
      begin
        B.Emit([$1B, $92]);
        Append := '(C)Ljava/lang/StringBuffer;';
      end
      else if D = '([CII)V' then
      begin
        B.Emit([$2B, $1C, $1D]);
        Append := '([CII)Ljava/lang/StringBuffer;';
        Locals := 4;
      end
      else if D = '(Ljava/lang/String;II)V' then
      begin
        B.Emit([$2B, $1C, $1C, $1D, $60]);
        B.Ref($B6, B.Member('java/lang/String', 'substring', '(II)Ljava/lang/String;'));
        Locals := 4;
      end
      else
        B.Emit([$2B]);
      B.Ref($B6, B.Member(Builder, 'append', Append));
      B.Emit([$57, $B1]);
      B.Finish('write', D, JVM_ACC_PUBLIC, 5, Locals);
    end;
    B.Start;
    B.Emit([$2A]);
    B.Ref($B4, BufferField);
    B.Emit([$B0]);
    B.Finish('getBuffer', '()Ljava/lang/StringBuffer;', JVM_ACC_PUBLIC, 1, 1);
    B.Start;
    B.Emit([$2A]);
    B.Ref($B4, BufferField);
    B.Ref($B6, B.Member(Builder, 'toString', '()Ljava/lang/String;'));
    B.Emit([$B0]);
    B.Finish('toString', '()Ljava/lang/String;', JVM_ACC_PUBLIC, 1, 1);
    for var N in ['flush', 'close'] do
    begin
      B.Start;
      B.Emit([$B1]);
      B.Finish(N, '()V', JVM_ACC_PUBLIC, 0, 1);
    end;
    Done;
  finally
    B.Free;
  end;
end;

function InvokeJavaWriters(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>; const DefaultEncoding: string): TJVMValue;
var
  O, A, Bytes: TJVMObject;
  N, D, Text: string;
  Value: TJVMValue;
  Offset, Count, Cursor, Phase, Capacity, Used, HighChar, CP, Consume, ByteCount, Work: Integer;
  Charset: TJavaCharset;
  Encoded: array[0..3] of Byte;

  function Get(const Name: string): Integer;
  begin
    Result := O.Fields[Output + '.' + Name + ':I'].AsInt;
  end;

  procedure Put(const Name: string; V: Integer);
  begin
    O.Fields[Output + '.' + Name + ':I'] := TJVMValue.Int(V);
  end;

  procedure Open;
  begin
    if (Get('$closed') <> 0) or (Get('$closing') <> 0) then
      VM.RaiseJava('java/io/IOException', 'Writer closed');
  end;

  procedure Save(NextPhase: Integer);
  begin
    VM.SetNativeContinuation(TJVMValue.Long(Int64((UInt64(NextPhase) shl 32) or UInt32(Cursor))));
  end;

  procedure Send;
  begin
    var Old := O.Fields[BufferKey];
    var LengthOfBytes := Get('$count');
    var NewRef := VM.NewArray('[B', Length(VM.GetObject(Old.AsRef).Elements));
    O.Fields[BufferKey] := TJVMValue.Ref(NewRef);
    Put('$count', 0);
    Save(1);
    var Target := O.Fields[OutKey].AsRef;
    VM.InvokeGuestResult(VM.ResolveVirtualMethod(Target, VM.LoadClass(Stream).FindMethod('write', '([BII)V')),
      [TJVMValue.Ref(Target), Old, TJVMValue.Int(0), TJVMValue.Int(LengthOfBytes)]);
  end;

  procedure Scalar(Point: Integer; Malformed: Boolean);

    procedure Emit(B: Integer);
    begin
      Encoded[ByteCount] := Byte(B);
      Inc(ByteCount);
    end;

    procedure WordValue(W: Integer);
    begin
      if Charset = TJavaCharset.UTF16LE then
      begin
        Emit(W and 255);
        Emit(W shr 8);
      end
      else
      begin
        Emit(W shr 8);
        Emit(W and 255);
      end;
    end;

  begin
    ByteCount := 0;
    if Malformed then
    begin
      if Charset in [TJavaCharset.UTF16, TJavaCharset.UTF16BE, TJavaCharset.UTF16LE] then
        Point := $FFFD
      else
        Point := 63;
    end;
    case Charset of
      TJavaCharset.ASCII, TJavaCharset.Latin1:
        begin
          if (Point > 255) or ((Charset = TJavaCharset.ASCII) and (Point > 127)) then
            Point := 63;
          Emit(Point);
        end;
      TJavaCharset.UTF8:
        begin
          if Point < $80 then
            Emit(Point)
          else if Point < $800 then
          begin
            Emit($C0 or (Point shr 6));
            Emit($80 or (Point and 63));
          end
          else if Point < $10000 then
          begin
            Emit($E0 or (Point shr 12));
            Emit($80 or ((Point shr 6) and 63));
            Emit($80 or (Point and 63));
          end
          else
          begin
            Emit($F0 or (Point shr 18));
            Emit($80 or ((Point shr 12) and 63));
            Emit($80 or ((Point shr 6) and 63));
            Emit($80 or (Point and 63));
          end;
        end;
    else
      if Point > $FFFF then
      begin
        Dec(Point, $10000);
        WordValue($D800 or (Point shr 10));
        WordValue($DC00 or (Point and $3FF));
      end
      else
        WordValue(Point);
    end;
  end;

  function Character(Index: Integer): Integer;
  begin
    if D = '(I)V' then
      Exit(Args[1].AsInt and $FFFF);
    if D.StartsWith('([C') then
      Exit(A.Elements[Offset + Index].AsInt and $FFFF);
    Result := Ord(Text[Offset + Index + 1]);
  end;

begin
  Result := Default(TJVMValue);
  O := VM.GetObject(Args[0].AsRef);
  N := Method.Name;
  D := Method.Descriptor;
  if Method.Owner.Name = Writer then
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
    if N = '$chars' then
    begin
      Text := VM.GetObject(Args[1].AsRef).Text;
      Offset := Args[2].AsInt;
      Count := Args[3].AsInt;
      if (Offset < 0) or (Count < 0) or (Offset > Length(Text)) or (Count > Length(Text) - Offset) then
        VM.RaiseJava('java/lang/StringIndexOutOfBoundsException');
      var Ref := VM.NewArray('[C', Count);
      for var I := 0 to Count - 1 do
        VM.GetObject(Ref).Elements[I] := TJVMValue.Int(Ord(Text[Offset + I + 1]));
      Exit(TJVMValue.Ref(Ref));
    end;
  end;
  if Method.Owner.Name = StringWriter then
  begin
    A := VM.GetObject(Args[1].AsRef);
    Offset := Args[2].AsInt;
    Count := Args[3].AsInt;
    if (Offset < 0) or (Count < 0) or (Offset > Length(A.Elements)) or (Count > Length(A.Elements) - Offset) then
      VM.RaiseJava('java/lang/IndexOutOfBoundsException');
    Exit;
  end;
  if N = '<init>' then
  begin
    VM.GetObject(Args[1].AsRef);
    Text := DefaultEncoding;
    if Length(Args) = 3 then
      Text := VM.GetObject(Args[2].AsRef).Text;
    Charset := JavaCharset(VM, Text);
    Capacity := Min(4096, VM.MaxArrayLength);
    if Capacity < 4 then
      VM.RaiseJava('java/lang/OutOfMemoryError', 'Writer byte buffer limit');
    O.Fields[BufferKey] := TJVMValue.Ref(VM.NewArray('[B', Capacity));
    O.Fields[OutKey] := Args[1];
    O.Fields[LockKey] := Args[1];
    Put('$charset', Ord(Charset));
    Exit;
  end;
  if N = 'getEncoding' then
  begin
    if Get('$closed') <> 0 then
      Exit(TJVMValue.Ref(0));
    case TJavaCharset(Get('$charset')) of
      TJavaCharset.UTF8:
        Text := 'UTF8';
      TJavaCharset.Latin1:
        Text := 'ISO8859_1';
      TJavaCharset.ASCII:
        Text := 'ASCII';
      TJavaCharset.UTF16:
        Text := 'UTF-16';
      TJavaCharset.UTF16BE:
        Text := 'UnicodeBigUnmarked';
      TJavaCharset.UTF16LE:
        Text := 'UnicodeLittleUnmarked';
    end;
    Exit(TJVMValue.Ref(VM.InternString(Text)));
  end;
  if N = '$beginClose' then
  begin
    if (Get('$closed') <> 0) or (Get('$closing') <> 0) then
      Exit(TJVMValue.Int(0));
    Put('$closing', 1);
    Exit(TJVMValue.Int(1));
  end;
  if N = '$finishClose' then
  begin
    Put('$closed', 1);
    Put('$closing', 0);
    Put('$high', 0);
    Put('$count', 0);
    O.Fields[OutKey] := TJVMValue.Ref(0);
    O.Fields[BufferKey] := TJVMValue.Ref(0);
    Exit;
  end;
  if (N = '$downFlush') or (N = '$downClose') then
  begin
    if VM.TakeGuestResult(Value) then
      Exit;
    var Target := O.Fields[OutKey].AsRef;
    Text := 'flush';
    if N = '$downClose' then
      Text := 'close';
    VM.InvokeGuestResult(VM.ResolveVirtualMethod(Target, VM.LoadClass(Stream).FindMethod(Text, '()V')), [TJVMValue.Ref(Target)]);
    Exit;
  end;
  if N <> '$end' then
    Open;
  Cursor := 0;
  Phase := 0;
  Value := VM.NativeContinuation;
  if Value.Kind = TJVMKind.Long then
  begin
    Cursor := Integer(UInt32(Value.AsLong));
    Phase := Integer(UInt64(Value.AsLong) shr 32);
  end;
  if VM.TakeGuestResult(Value) then
  begin
    if Phase = 2 then
      Exit;
    Phase := 0;
  end;
  Offset := 0;
  Count := 0;
  A := nil;
  if N = '$write' then
  begin
    if D = '(I)V' then
      Count := 1
    else
    begin
      A := VM.GetObject(Args[1].AsRef);
      Offset := Args[2].AsInt;
      Count := Args[3].AsInt;
      var LengthOfInput := Length(A.Elements);
      if not D.StartsWith('([C') then
      begin
        Text := A.Text;
        LengthOfInput := Length(Text);
      end;
      if (Offset < 0) or (Count < 0) or (Offset > LengthOfInput) or (Count > LengthOfInput - Offset) then
        VM.RaiseJava('java/lang/IndexOutOfBoundsException');
    end;
  end
  else if (N <> '$flush') and (N <> '$end') then
    raise EJVMUnsupported.Create(Output + '.' + N);
  Charset := TJavaCharset(Get('$charset'));
  Work := 0;
  while (Cursor < Count) or ((N = '$end') and (Get('$high') <> 0)) do
  begin
    Bytes := VM.GetObject(O.Fields[BufferKey].AsRef);
    Capacity := Length(Bytes.Elements);
    Used := Get('$count');
    if (Charset = TJavaCharset.UTF16) and (Get('$started') = 0) then
    begin
      if Used + 2 > Capacity then
      begin
        Send;
        Exit;
      end;
      Bytes.Elements[Used] := TJVMValue.Int(-2);
      Bytes.Elements[Used + 1] := TJVMValue.Int(-1);
      Inc(Used, 2);
      Put('$count', Used);
      Put('$started', 1);
    end;
    HighChar := Get('$high');
    Consume := 0;
    if HighChar <> 0 then
    begin
      if Cursor < Count then
      begin
        CP := Character(Cursor);
        if (CP >= $DC00) and (CP <= $DFFF) then
        begin
          Scalar($10000 + ((HighChar - $D800) shl 10) + CP - $DC00, False);
          Consume := 1;
        end
        else
          Scalar(0, True);
      end
      else
        Scalar(0, True);
    end
    else
    begin
      CP := Character(Cursor);
      if (CP >= $D800) and (CP <= $DBFF) then
      begin
        Put('$high', CP);
        Inc(Cursor);
        Continue;
      end;
      Scalar(CP, (CP >= $DC00) and (CP <= $DFFF));
      Consume := 1;
    end;
    if Used + ByteCount > Capacity then
    begin
      Send;
      Exit;
    end;
    for var I := 0 to ByteCount - 1 do
      Bytes.Elements[Used + I] := TJVMValue.Int(ShortInt(Encoded[I]));
    Put('$count', Used + ByteCount);
    if HighChar <> 0 then
      Put('$high', 0);
    Inc(Cursor, Consume);
    Inc(Work);
    if Work = 512 then
    begin
      Save(0);
      VM.YieldCurrent;
      VM.RetryNative;
      Exit;
    end;
  end;
  if (N = '$flush') or (N = '$end') then
  begin
    if Get('$count') <> 0 then
    begin
      Send;
      Exit;
    end;
    if N = '$flush' then
    begin
      Save(2);
      var Target := O.Fields[OutKey].AsRef;
      VM.InvokeGuestResult(VM.ResolveVirtualMethod(Target, VM.LoadClass(Stream).FindMethod('flush', '()V')), [TJVMValue.Ref(Target)]);
    end;
  end;
end;

end.

