unit J2ME.Resources;

interface

uses
  System.SysUtils, JVM.Types, JVM.ClassFile, JVM.Runtime;

// MIDP canonical names address only members of the current suite's JAR.
function J2MECanonicalResourceName(const Name: string; out Key: string): Boolean;

procedure InstallJ2MEResources(VM: TJVM);

function OpenJ2MEResource(VM: TJVM; const URL: string; Mode: Integer; Siemens: Boolean = False): Integer;

function HandlesJ2MEResources(const Owner: string): Boolean;

function InvokeJ2MEResources(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;

implementation

uses
  System.Math, Java.Bootstrap, Java.Classes;

const
  IO = 'javax/microedition/io/';
  ConnectionName = IO + 'Connector$Resource';
  InputName = IO + 'Connector$ResourceInput';
  ConnectionData = ConnectionName + '.$bytes:[B';
  ConnectionClosed = ConnectionName + '.$closed:Z';
  InputData = InputName + '.$bytes:[B';
  InputConnection = InputName + '.$connection:L' + ConnectionName + ';';
  InputClosed = InputName + '.$closed:Z';
  InputPosition = InputName + '.$position:I';
  InputMark = InputName + '.$mark:I';

function J2MECanonicalResourceName(const Name: string; out Key: string): Boolean;
begin
  Result := False;
  Key := '';
  var Path := Name;
  if Path.StartsWith('/') then
    Delete(Path, 1, 1);
  if (Path = '') or Path.StartsWith('/') or Path.Contains(#0) then
    Exit;
  var Parts := Path.Split(['/']);
  var Count := 0;
  for var I := 0 to High(Parts) do
  begin
    var Part := Parts[I];
    if Part = '.' then
    begin
      if I = High(Parts) then
        Exit;
      Continue;
    end;
    if Part = '..' then
    begin
      if (Count = 0) or (I = High(Parts)) then
        Exit;
      Dec(Count);
    end
    else
    begin
      Parts[Count] := Part;
      Inc(Count);
    end;
  end;
  if (Count = 0) or (Parts[Count - 1] = '') then
    Exit;
  SetLength(Parts, Count);
  Key := string.Join('/', Parts);
  // Empty leading components left by canonicalization cannot name JAR members.
  Result := (Key <> '') and not Key.StartsWith('/');
end;

procedure InstallJ2MEResources(VM: TJVM);
var
  B: TJavaClassBuilder;
begin
  B := TJavaClassBuilder.Create(ConnectionName, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_FINAL);
  try
    B.JavaClass.Interfaces := [IO + 'InputConnection'];
    B.Field('$bytes', '[B', JVM_ACC_PRIVATE);
    B.Field('$closed', 'Z', JVM_ACC_PRIVATE);
    B.JavaClass.AddNative('close', '()V').Access := JVM_ACC_PUBLIC or JVM_ACC_SYNCHRONIZED or JVM_ACC_NATIVE;
    B.JavaClass.AddNative('openInputStream', '()Ljava/io/InputStream;').Access := JVM_ACC_PUBLIC or JVM_ACC_SYNCHRONIZED or JVM_ACC_NATIVE;
    B.Start;
    B.Ref($BB, B.ClassRef('java/io/DataInputStream'));
    B.Emit([$59, $2A]);
    B.Ref($B6, B.Member(ConnectionName, 'openInputStream', '()Ljava/io/InputStream;'));
    B.Ref($B7, B.Member('java/io/DataInputStream', '<init>', '(Ljava/io/InputStream;)V'));
    B.Emit([$B0]);
    B.Finish('openDataInputStream', '()Ljava/io/DataInputStream;', JVM_ACC_PUBLIC, 3, 1);
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
  B := TJavaClassBuilder.Create(InputName, 'java/io/InputStream', JVM_ACC_PUBLIC or JVM_ACC_FINAL);
  try
    B.Field('$bytes', '[B', JVM_ACC_PRIVATE);
    B.Field('$connection', 'L' + ConnectionName + ';', JVM_ACC_PRIVATE);
    B.Field('$closed', 'Z', JVM_ACC_PRIVATE);
    B.Field('$position', 'I', JVM_ACC_PRIVATE);
    B.Field('$mark', 'I', JVM_ACC_PRIVATE);
    for var N in ['read', 'available'] do
      B.JavaClass.AddNative(N, '()I').Access := JVM_ACC_PUBLIC or JVM_ACC_SYNCHRONIZED or JVM_ACC_NATIVE;
    B.JavaClass.AddNative('markSupported', '()Z').Access := JVM_ACC_PUBLIC or JVM_ACC_NATIVE;
    for var N in ['close', 'reset'] do
      B.JavaClass.AddNative(N, '()V').Access := JVM_ACC_PUBLIC or JVM_ACC_SYNCHRONIZED or JVM_ACC_NATIVE;
    B.JavaClass.AddNative('read', '([BII)I').Access := JVM_ACC_PUBLIC or JVM_ACC_SYNCHRONIZED or JVM_ACC_NATIVE;
    B.JavaClass.AddNative('skip', '(J)J').Access := JVM_ACC_PUBLIC or JVM_ACC_SYNCHRONIZED or JVM_ACC_NATIVE;
    B.JavaClass.AddNative('mark', '(I)V').Access := JVM_ACC_PUBLIC or JVM_ACC_SYNCHRONIZED or JVM_ACC_NATIVE;
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
end;

function OpenJ2MEResource(VM: TJVM; const URL: string; Mode: Integer; Siemens: Boolean): Integer;
var
  Bytes: TBytes;
  Found: Boolean;
begin
  if not (Mode in [1, 3]) then
    VM.RaiseJava('java/lang/IllegalArgumentException', 'Resource connections are read-only');
  // The legacy Siemens spelling uses package\file separators. This translation
  // applies only to resource: URLs, never to ordinary Class resource names.
  var Name := Copy(URL, Pos(':', URL) + 1, MaxInt).Replace('\', '/');
  if Siemens and Name.StartsWith('//') then
    Delete(Name, 1, 2);
  Found := False;
  try
    Found := (VM.Host is TJavaHost) and TJavaHost(VM.Host).LoadResource(Name, Bytes);
  except
    on E: EJVMError do
      raise;
    on E: EAccessViolation do
      raise;
    on E: EOutOfMemory do
      VM.RaiseJava('java/lang/OutOfMemoryError');
    on E: Exception do
      VM.RaiseJava('java/io/IOException', E.Message);
  end;
  if not Found then
    VM.RaiseJava(IO + 'ConnectionNotFoundException', 'JAR resource not found: ' + Name);
  if Length(Bytes) > VM.MaxArrayLength then
    VM.RaiseJava('java/lang/OutOfMemoryError', 'JAR resource array capacity');
  var DataRef := VM.NewArray('[B', Length(Bytes));
  var Data := VM.GetObject(DataRef);
  for var I := 0 to High(Bytes) do
    Data.Elements[I] := TJVMValue.Int(ShortInt(Bytes[I]));
  Result := VM.NewObject(ConnectionName);
  VM.GetObject(Result).Fields[ConnectionData] := TJVMValue.Ref(DataRef);
end;

function HandlesJ2MEResources(const Owner: string): Boolean;
begin
  Result := (Owner = ConnectionName) or (Owner = InputName);
end;

function InvokeJ2MEResources(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
begin
  Result := Default(TJVMValue);
  var O := VM.GetObject(Args[0].AsRef);
  var N := Method.Name;
  if Method.Owner.Name = ConnectionName then
  begin
    if N = 'close' then
    begin
      O.Fields[ConnectionClosed] := TJVMValue.Int(1);
      O.Fields[ConnectionData] := TJVMValue.Ref(0);
      Exit;
    end;
    if O.Fields[ConnectionClosed].AsInt <> 0 then
      VM.RaiseJava('java/io/IOException', 'Resource connection closed');
    if N = 'openInputStream' then
    begin
      // Streams own their buffer and keep the connection alive. Closing the
      // connection drops only its buffer reference, without invalidating streams.
      var R := VM.NewObject(InputName);
      var Stream := VM.GetObject(R);
      Stream.Fields[InputData] := O.Fields[ConnectionData];
      Stream.Fields[InputConnection] := Args[0];
      Exit(TJVMValue.Ref(R));
    end;
  end
  else
  begin
    if N = 'markSupported' then
      Exit(TJVMValue.Int(1));
    if N = 'close' then
    begin
      O.Fields[InputClosed] := TJVMValue.Int(1);
      O.Fields[InputData] := TJVMValue.Ref(0);
      O.Fields[InputConnection] := TJVMValue.Ref(0);
      Exit;
    end;
    if O.Fields[InputClosed].AsInt <> 0 then
    begin
      if N = 'mark' then
        Exit;
      VM.RaiseJava('java/io/IOException', 'Resource stream closed');
    end;
    var Data := VM.GetObject(O.Fields[InputData].AsRef);
    var Position := O.Fields[InputPosition].AsInt;
    var Remaining := Length(Data.Elements) - Position;
    if N = 'available' then
      Exit(TJVMValue.Int(Remaining));
    if N = 'mark' then
    begin
      O.Fields[InputMark] := TJVMValue.Int(Position);
      Exit;
    end;
    if N = 'reset' then
    begin
      O.Fields[InputPosition] := O.Fields[InputMark];
      Exit;
    end;
    if N = 'skip' then
    begin
      var Count := Integer(Min(Int64(Remaining), Max(Int64(0), Args[1].AsLong)));
      O.Fields[InputPosition] := TJVMValue.Int(Position + Count);
      Exit(TJVMValue.Long(Count));
    end;
    if N = 'read' then
    begin
      if Length(Args) = 1 then
      begin
        if Remaining = 0 then
          Exit(TJVMValue.Int(-1));
        O.Fields[InputPosition] := TJVMValue.Int(Position + 1);
        Exit(TJVMValue.Int(Data.Elements[Position].AsInt and 255));
      end;
      var Target := VM.GetObject(Args[1].AsRef);
      var Offset := Args[2].AsInt;
      var Count := Args[3].AsInt;
      if (Offset < 0) or (Count < 0) or (Offset > Length(Target.Elements)) or (Count > Length(Target.Elements) - Offset) then
        VM.RaiseJava('java/lang/IndexOutOfBoundsException');
      if Count = 0 then
        Exit(TJVMValue.Int(0));
      if Remaining = 0 then
        Exit(TJVMValue.Int(-1));
      Count := Min(Count, Remaining);
      for var I := 0 to Count - 1 do
        Target.Elements[Offset + I] := Data.Elements[Position + I];
      O.Fields[InputPosition] := TJVMValue.Int(Position + Count);
      Exit(TJVMValue.Int(Count));
    end;
  end;
  raise EJVMUnsupported.Create(Method.Owner.Name + '.' + N);
end;

end.

