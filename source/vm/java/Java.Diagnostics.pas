unit Java.Diagnostics;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime;

procedure InstallJavaThrowable(VM: TJVM);

procedure InstallJavaSystem(VM: TJVM);

procedure InstallJavaPrintStreams(VM: TJVM);

function InvokeJavaDiagnostics(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>; const DefaultEncoding, LineSeparator: string): TJVMValue;

implementation

uses
  System.SysUtils, System.Math, Java.Classes, Java.Charsets;

{$Q-}{$R-}

const
  PrintName = 'java/io/PrintStream';
  ConsoleName = PrintName + '$ConsoleOutput';
  OutputName = 'java/io/OutputStream';
  OutKey = PrintName + '.$out:Ljava/io/OutputStream;';

function Key(const Name: string): string;
begin
  Result := PrintName + '.' + Name + ':I';
end;

function Get(O: TJVMObject; const Name: string): Integer;
begin
  Result := O.Fields[Key(Name)].AsInt;
end;

procedure Put(O: TJVMObject; const Name: string; Value: Integer);
begin
  O.Fields[Key(Name)] := TJVMValue.Int(Value);
end;

procedure InstallJavaThrowable(VM: TJVM);
var
  B: TJavaClassBuilder;
  H: TJVMExceptionHandler;
begin
  B := TJavaClassBuilder.Create('java/lang/Throwable', 'java/lang/Object');
  try
    for var Desc in ['()V', '(Ljava/lang/String;)V'] do
      B.JavaClass.AddNative('<init>', Desc);
    B.JavaClass.AddNative('getMessage', '()Ljava/lang/String;');
    B.JavaClass.AddNative('getCause', '()Ljava/lang/Throwable;');
    B.JavaClass.AddNative('$trace', '()Ljava/lang/String;').Access := JVM_ACC_PRIVATE or JVM_ACC_NATIVE;
    // getMessage remains virtual, including user-defined throwable subclasses.
    B.Start;
    B.Emit([$2A]);
    B.Ref($B6, B.Member('java/lang/Object', 'getClass', '()Ljava/lang/Class;'));
    B.Ref($B6, B.Member('java/lang/Class', 'getName', '()Ljava/lang/String;'));
    B.Emit([$4C, $2A]);
    B.Ref($B6, B.Member('java/lang/Throwable', 'getMessage', '()Ljava/lang/String;'));
    B.Emit([$4D, $2C]);
    B.Jump($C7, 'message');
    B.Emit([$2B, $B0]);
    B.Mark('message');
    B.Ref($BB, B.ClassRef('java/lang/StringBuffer'));
    B.Emit([$59]);
    B.Ref($B7, B.Member('java/lang/StringBuffer', '<init>', '()V'));
    B.Emit([$2B]);
    B.Ref($B6, B.Member('java/lang/StringBuffer', 'append', '(Ljava/lang/String;)Ljava/lang/StringBuffer;'));
    B.Ref($13, B.StringConstant(': '));
    B.Ref($B6, B.Member('java/lang/StringBuffer', 'append', '(Ljava/lang/String;)Ljava/lang/StringBuffer;'));
    B.Emit([$2C]);
    B.Ref($B6, B.Member('java/lang/StringBuffer', 'append', '(Ljava/lang/String;)Ljava/lang/StringBuffer;'));
    B.Ref($B6, B.Member('java/lang/StringBuffer', 'toString', '()Ljava/lang/String;'));
    B.Emit([$B0]);
    B.Finish('toString', '()Ljava/lang/String;', JVM_ACC_PUBLIC, 2, 3);
    B.Start;
    B.Ref($B2, B.Member('java/lang/System', 'err', 'Ljava/io/PrintStream;', 9));
    B.Emit([$59, $4C, $C2]);
    B.Mark('locked');
    B.Emit([$2B, $2A]);
    B.Ref($B6, B.Member('java/lang/Throwable', 'toString', '()Ljava/lang/String;'));
    B.Ref($B6, B.Member(PrintName, 'println', '(Ljava/lang/String;)V'));
    B.Emit([$2B, $2A]);
    B.Ref($B7, B.Member('java/lang/Throwable', '$trace', '()Ljava/lang/String;'));
    B.Ref($B6, B.Member(PrintName, 'print', '(Ljava/lang/String;)V'));
    B.Emit([$2B, $C3]);
    B.Mark('unlocked');
    B.Emit([$B1]);
    B.Mark('failed');
    B.Emit([$4D, $2B, $C3, $2C, $BF]);
    B.Finish('printStackTrace', '()V', JVM_ACC_PUBLIC, 2, 3);
    H := Default(TJVMExceptionHandler);
    H.StartPC := B.Position('locked');
    H.EndPC := B.Position('unlocked');
    H.HandlerPC := B.Position('failed');
    B.JavaClass.Methods.Last.Handlers := [H];
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
end;

procedure InstallJavaSystem(VM: TJVM);
var
  B: TJavaClassBuilder;
begin
  B := TJavaClassBuilder.Create('java/lang/System', 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_FINAL or $0020);
  try
    B.JavaClass.AddNative('getProperty', '(Ljava/lang/String;)Ljava/lang/String;', True);
    B.JavaClass.AddNative('currentTimeMillis', '()J', True);
    B.JavaClass.AddNative('gc', '()V', True);
    B.JavaClass.AddNative('arraycopy', '(Ljava/lang/Object;ILjava/lang/Object;II)V', True);
    for var Name in ['out', 'err'] do
      B.Field(Name, 'Ljava/io/PrintStream;', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
    B.Start;
    for var Channel := 0 to 1 do
    begin
      B.Ref($BB, B.ClassRef(PrintName));
      B.Emit([$59]);
      B.Ref($BB, B.ClassRef(ConsoleName));
      B.Emit([$59, Byte($03 + Channel)]);
      B.Ref($B7, B.Member(ConsoleName, '<init>', '(I)V'));
      B.Ref($B7, B.Member(PrintName, '<init>', '(Ljava/io/OutputStream;)V'));
      var Name := 'out';
      if Channel = 1 then
        Name := 'err';
      B.Ref($B3, B.Member('java/lang/System', Name, 'Ljava/io/PrintStream;', 9));
    end;
    B.Emit([$B1]);
    B.Finish('<clinit>', '()V', JVM_ACC_STATIC, 5, 0);
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
end;

procedure InstallJavaPrintStreams(VM: TJVM);
var
  B: TJavaClassBuilder;
  H: TJVMExceptionHandler;

  procedure Native(const Name, Desc: string; Flags: Word = JVM_ACC_PRIVATE);
  begin
    B.JavaClass.AddNative(Name, Desc).Access := Flags or JVM_ACC_NATIVE;
  end;

  procedure ErrorHandler;
  begin
    H := Default(TJVMExceptionHandler);
    H.StartPC := B.Position('try');
    H.EndPC := B.Position('end');
    H.HandlerPC := B.Position('io');
    H.CatchType := B.ClassRef('java/io/IOException');
    B.JavaClass.Methods.Last.Handlers := [H];
  end;

  procedure MarkError;
  begin
    B.Emit([$2A]);
    B.Ref($B7, B.Member(PrintName, '$error', '()V'));
  end;

  procedure IOCall(const Name, Desc: string; const LoadArgs: array of Byte; Locals: Word);
  begin
    B.Start;
    B.Mark('try');
    B.Emit([$2A]);
    B.Ref($B7, B.Member(PrintName, '$stream', '()Ljava/io/OutputStream;'));
    B.Emit(LoadArgs);
    B.Ref($B6, B.Member(OutputName, Name, Desc));
    B.Mark('end');
    B.Emit([$B1]);
    B.Mark('io');
    B.Emit([$57]);
    MarkError;
    B.Emit([$B1]);
    B.Finish(Name, Desc, JVM_ACC_PUBLIC or JVM_ACC_SYNCHRONIZED, 4, Locals);
    ErrorHandler;
  end;

begin
  B := TJavaClassBuilder.Create(ConsoleName, OutputName);
  try
    B.Field('$channel', 'I', JVM_ACC_PRIVATE);
    Native('<init>', '(I)V', JVM_ACC_PUBLIC);
    Native('write', '(I)V', JVM_ACC_PUBLIC);
    Native('write', '([BII)V', JVM_ACC_PUBLIC);
    for var Name in ['flush', 'close'] do
      Native(Name, '()V', JVM_ACC_PUBLIC);
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  B := TJavaClassBuilder.Create(PrintName, OutputName);
  try
    B.Field('$out', 'Ljava/io/OutputStream;', JVM_ACC_PRIVATE);
    for var Name in ['$closed', '$closing', '$error', '$charset', '$started', '$high'] do
      B.Field(Name, 'I', JVM_ACC_PRIVATE);
    Native('<init>', '(Ljava/io/OutputStream;)V', JVM_ACC_PUBLIC);
    Native('$stream', '()Ljava/io/OutputStream;');
    Native('$rawStream', '()Ljava/io/OutputStream;');
    Native('$error', '()V');
    Native('$hasError', '()Z');
    Native('$beginClose', '()Z');
    Native('$endClose', '()V');
    Native('$encode', '(Ljava/lang/String;Z)[B');
    Native('$newline', '()Ljava/lang/String;');
    Native('setError', '()V', JVM_ACC_PROTECTED or JVM_ACC_SYNCHRONIZED);
    IOCall('write', '(I)V', [$1B], 2);
    IOCall('write', '([BII)V', [$2B, $1C, $1D], 4);
    IOCall('flush', '()V', [], 1);
    // print(String) and line termination share the stateful character encoder.
    for var Name in ['print', 'println'] do
    begin
      var BufferLocal: Byte := 2;
      if Name = 'println' then
        BufferLocal := 1;
      B.Start;
      B.Mark('try');
      B.Emit([$2A]);
      B.Ref($B7, B.Member(PrintName, '$stream', '()Ljava/io/OutputStream;'));
      B.Emit([$57, $2A]);
      if Name = 'print' then
        B.Emit([$2B])
      else
      begin
        B.Emit([$2A]);
        B.Ref($B7, B.Member(PrintName, '$newline', '()Ljava/lang/String;'));
      end;
      B.Emit([$03]);
      B.Ref($B7, B.Member(PrintName, '$encode', '(Ljava/lang/String;Z)[B'));
      B.Emit([$3A, BufferLocal]);
      B.Emit([$2A, $19, BufferLocal, $03, $19, BufferLocal, $BE]);
      B.Ref($B6, B.Member(PrintName, 'write', '([BII)V'));
      B.Mark('end');
      B.Emit([$B1]);
      B.Mark('io');
      B.Emit([$57]);
      MarkError;
      B.Emit([$B1]);
      var Desc := '(Ljava/lang/String;)V';
      if Name = 'println' then
        Desc := '()V';
      B.Finish(Name, Desc, JVM_ACC_PUBLIC or JVM_ACC_SYNCHRONIZED, 4, BufferLocal + 1);
      ErrorHandler;
    end;
    for var Desc in ['Z', 'C', 'I', 'J', 'F', 'D', '[C', 'Ljava/lang/Object;', 'Ljava/lang/String;'] do
    begin
      var Load: Byte := $1B;
      if CharInSet(Desc[1], ['L', '[']) then
        Load := $2B;
      if Desc = 'J' then
        Load := $1F;
      if Desc = 'F' then
        Load := $23;
      if Desc = 'D' then
        Load := $27;
      var Locals := 2;
      if (Desc = 'J') or (Desc = 'D') then
        Locals := 3;
      if Desc <> 'Ljava/lang/String;' then
      begin
        B.Start;
        B.Emit([$2A]);
        if (Desc = 'F') or (Desc = 'D') then
        begin
          // Floating text currently uses the existing shared builder conversion.
          B.Ref($BB, B.ClassRef('java/lang/StringBuffer'));
          B.Emit([$59]);
          B.Ref($B7, B.Member('java/lang/StringBuffer', '<init>', '()V'));
          B.Emit([Load]);
          B.Ref($B6, B.Member('java/lang/StringBuffer', 'append', '(' + Desc + ')Ljava/lang/StringBuffer;'));
          B.Ref($B6, B.Member('java/lang/StringBuffer', 'toString', '()Ljava/lang/String;'));
        end
        else
        begin
          B.Emit([Load]);
          B.Ref($B8, B.Member('java/lang/String', 'valueOf', '(' + Desc + ')Ljava/lang/String;'));
          if Desc = 'Ljava/lang/Object;' then
          begin
            B.Emit([$59]);
            B.Ref($B6, B.Member('java/lang/String', 'length', '()I'));
            B.Emit([$57]);
          end;
        end;
        B.Ref($B6, B.Member(PrintName, 'print', '(Ljava/lang/String;)V'));
        B.Emit([$B1]);
        B.Finish('print', '(' + Desc + ')V', JVM_ACC_PUBLIC, 4, Locals);
      end;
      B.Start;
      B.Emit([$2A, Load]);
      B.Ref($B6, B.Member(PrintName, 'print', '(' + Desc + ')V'));
      B.Emit([$2A]);
      B.Ref($B6, B.Member(PrintName, 'println', '()V'));
      B.Emit([$B1]);
      B.Finish('println', '(' + Desc + ')V', JVM_ACC_PUBLIC or JVM_ACC_SYNCHRONIZED, 3, Locals);
    end;
    B.Start;
    B.Emit([$2A]);
    B.Ref($B7, B.Member(PrintName, '$rawStream', '()Ljava/io/OutputStream;'));
    B.Emit([$4C, $2B]);
    B.Jump($C6, 'own');
    B.Emit([$2A]);
    B.Ref($B6, B.Member(PrintName, 'flush', '()V'));
    B.Emit([$2B]);
    B.Ref($C1, B.ClassRef(PrintName));
    B.Jump($99, 'own');
    B.Emit([$2B]);
    B.Ref($C0, B.ClassRef(PrintName));
    B.Ref($B6, B.Member(PrintName, 'checkError', '()Z'));
    B.Emit([$AC]);
    B.Mark('own');
    B.Emit([$2A]);
    B.Ref($B7, B.Member(PrintName, '$hasError', '()Z'));
    B.Emit([$AC]);
    B.Finish('checkError', '()Z', JVM_ACC_PUBLIC, 1, 2);
    B.Start;
    B.Emit([$2A]);
    B.Ref($B7, B.Member(PrintName, '$beginClose', '()Z'));
    B.Jump($9A, 'try');
    B.Emit([$B1]);
    B.Mark('try');
    B.Emit([$2A]);
    B.Ref($13, B.StringConstant(''));
    B.Emit([$04]);
    B.Ref($B7, B.Member(PrintName, '$encode', '(Ljava/lang/String;Z)[B'));
    B.Emit([$4C, $2A, $2B, $03, $2B, $BE]);
    B.Ref($B6, B.Member(PrintName, 'write', '([BII)V'));
    B.Emit([$2A]);
    B.Ref($B6, B.Member(PrintName, 'flush', '()V'));
    B.Emit([$2A]);
    B.Ref($B7, B.Member(PrintName, '$stream', '()Ljava/io/OutputStream;'));
    B.Ref($B6, B.Member(OutputName, 'close', '()V'));
    B.Mark('end');
    B.Jump($A7, 'finish');
    B.Mark('io');
    B.Emit([$57]);
    MarkError;
    B.Mark('finish');
    B.Emit([$2A]);
    B.Ref($B7, B.Member(PrintName, '$endClose', '()V'));
    B.Emit([$B1]);
    B.Mark('failed');
    B.Emit([$4C, $2A]);
    B.Ref($B7, B.Member(PrintName, '$endClose', '()V'));
    B.Emit([$2B, $BF]);
    B.Finish('close', '()V', JVM_ACC_PUBLIC or JVM_ACC_SYNCHRONIZED, 4, 2);
    ErrorHandler;
    H := Default(TJVMExceptionHandler);
    H.StartPC := B.Position('try');
    H.EndPC := B.Position('finish');
    H.HandlerPC := B.Position('failed');
    B.JavaClass.Methods.Last.Handlers := B.JavaClass.Methods.Last.Handlers + [H];
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
end;

function InvokeJavaDiagnostics(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>; const DefaultEncoding, LineSeparator: string): TJVMValue;
var
  O: TJVMObject;
  N, Text: string;
  Bytes: TBytes;
begin
  Result := Default(TJVMValue);
  O := VM.GetObject(Args[0].AsRef);
  N := Method.Name;
  if Method.Owner.Name = ConsoleName then
  begin
    if N = '<init>' then
    begin
      O.Fields[ConsoleName + '.$channel:I'] := Args[1];
      Exit;
    end;
    if N <> 'write' then
      Exit;
    if Length(Args) = 2 then
      Bytes := TBytes.Create(Byte(Args[1].AsInt))
    else
    begin
      var A := VM.GetObject(Args[1].AsRef);
      var Offset := Args[2].AsInt;
      var Count := Args[3].AsInt;
      if (Offset < 0) or (Count < 0) or (Offset > Length(A.Elements)) or (Count > Length(A.Elements) - Offset) then
        VM.RaiseJava('java/lang/IndexOutOfBoundsException');
      var Done := 0;
      if VM.NativeContinuation.Kind = TJVMKind.Int then
        Done := VM.NativeContinuation.AsInt;
      var Chunk := Min(4096, Count - Done);
      SetLength(Bytes, Chunk);
      for var I := 0 to Chunk - 1 do
        Bytes[I] := Byte(A.Elements[Offset + Done + I].AsInt);
      Inc(Done, Chunk);
      if Done < Count then
      begin
        VM.SetNativeContinuation(TJVMValue.Int(Done));
        VM.RetryNative;
      end;
    end;
    VM.QueueOutput(Bytes, O.Fields[ConsoleName + '.$channel:I'].AsInt <> 0);
    Exit;
  end;
  if N = '<init>' then
  begin
    VM.GetObject(Args[1].AsRef);
    var Charset := JavaCharset(VM, DefaultEncoding);
    O.Fields[OutKey] := Args[1];
    Put(O, '$charset', Ord(Charset));
    Put(O, '$high', 0);
    Exit;
  end;
  if N = '$stream' then
  begin
    if Get(O, '$closed') <> 0 then
      VM.RaiseJava('java/io/IOException', 'PrintStream closed');
    Exit(O.Fields[OutKey]);
  end;
  if N = '$rawStream' then
    Exit(O.Fields[OutKey]);
  if (N = '$error') or (N = 'setError') then
  begin
    Put(O, '$error', 1);
    Exit;
  end;
  if N = '$hasError' then
    Exit(TJVMValue.Int(Get(O, '$error')));
  if N = '$beginClose' then
  begin
    if (Get(O, '$closed') <> 0) or (Get(O, '$closing') <> 0) then
      Exit(TJVMValue.Int(0));
    Put(O, '$closing', 1);
    Exit(TJVMValue.Int(1));
  end;
  if N = '$endClose' then
  begin
    Put(O, '$closed', 1);
    Put(O, '$closing', 0);
    Put(O, '$high', 0);
    O.Fields[OutKey] := TJVMValue.Ref(0);
    Exit;
  end;
  if N = '$newline' then
    Exit(TJVMValue.Ref(VM.InternString(LineSeparator)));
  if N = '$encode' then
  begin
    Text := 'null';
    if Args[1].AsRef <> 0 then
      Text := VM.GetObject(Args[1].AsRef).Text;
    var HighChar := Get(O, '$high');
    if HighChar <> 0 then
      Text := Char(HighChar) + Text;
    HighChar := 0;
    if (Args[2].AsInt = 0) and (Text <> '') and (Ord(Text[Length(Text)]) >= $D800) and (Ord(Text[Length(Text)]) <= $DBFF) then
    begin
      HighChar := Ord(Text[Length(Text)]);
      SetLength(Text, Length(Text) - 1);
    end;
    var Charset := TJavaCharset(Get(O, '$charset'));
    Bytes := JavaEncode(VM, Text, Charset);
    if (Charset = TJavaCharset.UTF16) and (Get(O, '$started') <> 0) and (Length(Bytes) >= 2) then
      Bytes := Copy(Bytes, 2, Length(Bytes) - 2);
    var Ref := VM.NewArray('[B', Length(Bytes));
    var A := VM.GetObject(Ref);
    for var I := 0 to High(Bytes) do
      A.Elements[I] := TJVMValue.Int(ShortInt(Bytes[I]));
    Put(O, '$high', HighChar);
    if Length(Bytes) > 0 then
      Put(O, '$started', 1);
    Exit(TJVMValue.Ref(Ref));
  end;
  raise EJVMUnsupported.Create('PrintStream method: ' + N);
end;

end.

