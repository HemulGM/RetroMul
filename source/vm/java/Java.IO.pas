unit Java.IO;

interface

uses
  System.SysUtils, JVM.Types, JVM.ClassFile, JVM.Runtime;

procedure InstallJavaIO(VM: TJVM);

function InvokeJavaIO(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>; const DefaultEncoding: string = 'UTF-8'): TJVMValue;

function NewJavaByteArrayInput(VM: TJVM; const Data: TBytes): Integer;

implementation

uses
  System.Math, Java.Classes, Java.Charsets;

{$Q-}{$R-}

const
  Input = 'java/io/InputStream';
  Output = 'java/io/OutputStream';
  ByteInput = 'java/io/ByteArrayInputStream';
  ByteOutput = 'java/io/ByteArrayOutputStream';
  DataInput = 'java/io/DataInputStream';
  DataOutput = 'java/io/DataOutputStream';
  InputAPI = 'java/io/DataInput';
  OutputAPI = 'java/io/DataOutput';

procedure InstallJavaIO(VM: TJVM);
var
  B: TJavaClassBuilder;
  InField, OutField, WriteOne: Word;

  procedure Done;
  begin
    VM.DefineClass(B.Detach);
    FreeAndNil(B);
  end;

  procedure Native(const Name, Desc: string; Flags: Word = JVM_ACC_PUBLIC);
  begin
    B.JavaClass.AddNative(Name, Desc).Access := Flags or JVM_ACC_NATIVE;
  end;

  procedure AbstractMethod(const Name, Desc: string);
  begin
    B.JavaClass.AddNative(Name, Desc).Access := JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT;
  end;

  procedure ParentConstructor(const Parent: string);
  begin
    B.Start;
    B.Emit([$2A]);
    B.Ref($B7, B.Member(Parent, '<init>', '()V'));
    B.Emit([$B1]);
    B.Finish('<init>', '()V', JVM_ACC_PROTECTED, 1, 1);
  end;

  procedure ThrowError(const Name: string);
  begin
    B.Ref($BB, B.ClassRef(Name));
    B.Emit([$59]);
    B.Ref($B7, B.Member(Name, '<init>', '()V'));
    B.Emit([$BF]);
  end;

  procedure ArrayBounds;
  begin
    // Locals 1=array, 2=offset, 3=count. Null check precedes range checks.
    B.Emit([$2B, $BE, $36, 4, $1C]);
    B.Jump($9B, 'bounds');
    B.Emit([$1D]);
    B.Jump($9B, 'bounds');
    B.Emit([$1C, $15, 4]);
    B.Jump($A3, 'bounds');
    B.Emit([$1D, $15, 4, $1C, $64]);
    B.Jump($A4, 'valid');
    B.Mark('bounds');
    ThrowError('java/lang/IndexOutOfBoundsException');
    B.Mark('valid');
  end;

  procedure ArrayReadShortcut(const Owner: string);
  begin
    B.Start;
    B.Emit([$2A, $2B, $03, $2B, $BE]);
    B.Ref($B6, B.Member(Owner, 'read', '([BII)I'));
    B.Emit([$AC]);
    B.Finish('read', '([B)I', JVM_ACC_PUBLIC, 5, 2);
  end;

  procedure ArrayWriteShortcut(const Owner: string);
  begin
    B.Start;
    B.Emit([$2A, $2B, $03, $2B, $BE]);
    B.Ref($B6, B.Member(Owner, 'write', '([BII)V'));
    B.Emit([$B1]);
    B.Finish('write', '([B)V', JVM_ACC_PUBLIC, 5, 2);
  end;

  procedure DataMethods(IsInterface, Reading: Boolean);
  var
    Desc, Name, Letter: string;
    Bytes, I: Integer;
    Flags: Word;
  begin
    if IsInterface then
      Flags := JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT
    else
      Flags := JVM_ACC_PUBLIC or JVM_ACC_FINAL;
    for Name in ['Boolean', 'Byte', 'Short', 'Char', 'Int', 'Long', 'Float', 'Double'] do
    begin
      Bytes := 4;
      Letter := 'I';
      if Name = 'Boolean' then
      begin
        Bytes := 1;
        Letter := 'Z';
      end;
      if Name = 'Byte' then
      begin
        Bytes := 1;
        Letter := 'B';
      end;
      if Name = 'Short' then
      begin
        Bytes := 2;
        Letter := 'S';
      end;
      if Name = 'Char' then
      begin
        Bytes := 2;
        Letter := 'C';
      end;
      if Name = 'Long' then
      begin
        Bytes := 8;
        Letter := 'J';
      end;
      if Name = 'Float' then
        Letter := 'F';
      if Name = 'Double' then
      begin
        Bytes := 8;
        Letter := 'D';
      end;
      if Reading then
        Desc := '()' + Letter
      else
      begin
        if Bytes <= 4 then
          Desc := '(I)V'
        else
          Desc := '(J)V';
        if Name = 'Boolean' then
          Desc := '(Z)V';
        if Name = 'Float' then
          Desc := '(F)V';
        if Name = 'Double' then
          Desc := '(D)V';
      end;
      if IsInterface then
      begin
        if Reading then
          AbstractMethod('read' + Name, Desc)
        else
          AbstractMethod('write' + Name, Desc);
        Continue;
      end;
      B.Start;
      if Reading then
      begin
        if Bytes = 8 then
          B.Emit([$09, $40])
        else
          B.Emit([$03, $3C]);
        for I := 1 to Bytes do
        begin
          if Bytes = 8 then
            B.Emit([$1F, $10, 8, $79])
          else
            B.Emit([$1B, $10, 8, $78]);
          B.Emit([$2A]);
          B.Ref($B6, B.Member(DataInput, 'readUnsignedByte', '()I'));
          if Bytes = 8 then
            B.Emit([$85, $81, $40])
          else
            B.Emit([$80, $3C]);
        end;
        if Bytes = 8 then
          B.Emit([$1F])
        else
          B.Emit([$1B]);
        if Name = 'Boolean' then
        begin
          B.Jump($99, 'zero');
          B.Emit([$04, $AC]);
          B.Mark('zero');
          B.Emit([$03]);
        end;
        if Name = 'Byte' then
          B.Emit([$91]);
        if Name = 'Short' then
          B.Emit([$93]);
        if Name = 'Float' then
          B.Ref($B8, B.Member('java/lang/Float', 'intBitsToFloat', '(I)F'));
        if Name = 'Double' then
          B.Ref($B8, B.Member('java/lang/Double', 'longBitsToDouble', '(J)D'));
        if Letter = 'J' then
          B.Emit([$AD])
        else if Letter = 'F' then
          B.Emit([$AE])
        else if Letter = 'D' then
          B.Emit([$AF])
        else
          B.Emit([$AC]);
        B.Finish('read' + Name, Desc, Flags, 4, 3);
      end
      else
      begin
        if Name = 'Float' then
        begin
          B.Emit([$23]);
          B.Ref($B8, B.Member('java/lang/Float', 'floatToIntBits', '(F)I'));
          B.Emit([$3C]);
        end;
        if Name = 'Double' then
        begin
          B.Emit([$27]);
          B.Ref($B8, B.Member('java/lang/Double', 'doubleToLongBits', '(D)J'));
          B.Emit([$40]);
        end;
        if Name = 'Boolean' then
        begin
          B.Emit([$1B]);
          B.Jump($99, 'zero');
          B.Emit([$04]);
          B.Jump($A7, 'value');
          B.Mark('zero');
          B.Emit([$03]);
          B.Mark('value');
          B.Emit([$3C]);
        end;
        for I := Bytes - 1 downto 0 do
        begin
          B.Emit([$2A]);
          B.Ref($B4, OutField);
          if Bytes = 8 then
            B.Emit([$1F])
          else
            B.Emit([$1B]);
          if I > 0 then
          begin
            B.Emit([$10, Byte(I * 8)]);
            if Bytes = 8 then
              B.Emit([$7D])
            else
              B.Emit([$7C]);
          end;
          if Bytes = 8 then
            B.Emit([$88]);
          B.Ref($B6, B.Member(Output, 'write', '(I)V'));
        end;
        B.Emit([$2A, $10, Byte(Bytes)]);
        B.Ref($B7, B.Member(DataOutput, '$count', '(I)V'));
        B.Emit([$B1]);
        B.Finish('write' + Name, Desc, Flags, 4, 3);
      end;
    end;
  end;

begin
  B := nil;
  try
    for var E in ['EOFException', 'UTFDataFormatException', 'UnsupportedEncodingException'] do
    begin
      B := TJavaClassBuilder.Create('java/io/' + E, 'java/io/IOException');
      Native('<init>', '()V');
      Native('<init>', '(Ljava/lang/String;)V');
      Done;
    end;
    B := TJavaClassBuilder.Create(Input, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT or $0020);
    ParentConstructor('java/lang/Object');
    AbstractMethod('read', '()I');
    ArrayReadShortcut(Input);
    B.Start;
    ArrayBounds;
    B.Emit([$1D]);
    B.Jump($9A, 'read');
    B.Emit([$03, $AC]);
    B.Mark('read');
    B.Emit([$2A]);
    B.Ref($B6, B.Member(Input, 'read', '()I'));
    B.Emit([$36, 5, $15, 5]);
    B.Jump($9C, 'first');
    B.Emit([$02, $AC]);
    B.Mark('first');
    B.Emit([$2B, $1C, $15, 5, $91, $54, $04, $36, 6]);
    B.Mark('loop');
    B.Emit([$15, 6, $1D]);
    B.Jump($A2, 'end');
    B.Mark('try');
    B.Emit([$2A]);
    B.Ref($B6, B.Member(Input, 'read', '()I'));
    B.Emit([$36, 5, $15, 5]);
    B.Jump($9B, 'end');
    B.Emit([$2B, $1C, $15, 6, $60, $15, 5, $91, $54, $84, 6, 1]);
    B.Jump($A7, 'loop');
    B.Mark('end');
    B.Emit([$15, 6, $AC]);
    B.Mark('catch');
    B.Emit([$57, $15, 6, $AC]);
    B.Finish('read', '([BII)I', JVM_ACC_PUBLIC, 4, 7);
    // InputStream suppresses IOExceptions after at least one byte was read.
    var M := B.JavaClass.Methods.Last;
    var H: TJVMExceptionHandler;
    H := Default(TJVMExceptionHandler);
    H.StartPC := B.Position('try');
    H.EndPC := B.Position('end');
    H.HandlerPC := B.Position('catch');
    H.CatchType := B.ClassRef('java/io/IOException');
    M.Handlers := [H];
    B.Start;
    B.Emit([$09, $42]);
    B.Mark('loop');
    B.Emit([$21, $1F, $94]);
    B.Jump($9C, 'end');
    B.Emit([$2A]);
    B.Ref($B6, B.Member(Input, 'read', '()I'));
    B.Emit([$02]);
    B.Jump($9F, 'end');
    B.Emit([$21, $0A, $61, $42]);
    B.Jump($A7, 'loop');
    B.Mark('end');
    B.Emit([$21, $AD]);
    B.Finish('skip', '(J)J', JVM_ACC_PUBLIC, 4, 5);
    B.Start;
    B.Emit([$03, $AC]);
    B.Finish('available', '()I', JVM_ACC_PUBLIC, 1, 1);
    B.Start;
    B.Emit([$B1]);
    B.Finish('close', '()V', JVM_ACC_PUBLIC, 0, 1);
    B.Start;
    B.Emit([$B1]);
    B.Finish('mark', '(I)V', JVM_ACC_PUBLIC or JVM_ACC_SYNCHRONIZED, 0, 2);
    B.Start;
    B.Emit([$03, $AC]);
    B.Finish('markSupported', '()Z', JVM_ACC_PUBLIC, 1, 1);
    B.Start;
    ThrowError('java/io/IOException');
    B.Finish('reset', '()V', JVM_ACC_PUBLIC or JVM_ACC_SYNCHRONIZED, 2, 1);
    Done;
    B := TJavaClassBuilder.Create(Output, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT or $0020);
    ParentConstructor('java/lang/Object');
    AbstractMethod('write', '(I)V');
    ArrayWriteShortcut(Output);
    B.Start;
    ArrayBounds;
    B.Emit([$03, $36, 5]);
    B.Mark('loop');
    B.Emit([$15, 5, $1D]);
    B.Jump($A2, 'end');
    B.Emit([$2A, $2B, $1C, $15, 5, $60, $33]);
    B.Ref($B6, B.Member(Output, 'write', '(I)V'));
    B.Emit([$84, 5, 1]);
    B.Jump($A7, 'loop');
    B.Mark('end');
    B.Emit([$B1]);
    B.Finish('write', '([BII)V', JVM_ACC_PUBLIC, 4, 6);
    for var N in ['flush', 'close'] do
    begin
      B.Start;
      B.Emit([$B1]);
      B.Finish(N, '()V', JVM_ACC_PUBLIC, 0, 1);
    end;
    Done;
    B := TJavaClassBuilder.Create(ByteInput, Input);
    B.Field('buf', '[B', JVM_ACC_PROTECTED);
    B.Field('pos', 'I', JVM_ACC_PROTECTED);
    B.Field('mark', 'I', JVM_ACC_PROTECTED);
    B.Field('count', 'I', JVM_ACC_PROTECTED);
    Native('<init>', '([B)V');
    Native('<init>', '([BII)V');
    Native('read', '()I', JVM_ACC_PUBLIC or JVM_ACC_SYNCHRONIZED);
    Native('read', '([BII)I', JVM_ACC_PUBLIC or JVM_ACC_SYNCHRONIZED);
    Native('skip', '(J)J', JVM_ACC_PUBLIC or JVM_ACC_SYNCHRONIZED);
    Native('available', '()I', JVM_ACC_PUBLIC or JVM_ACC_SYNCHRONIZED);
    Native('mark', '(I)V', JVM_ACC_PUBLIC or JVM_ACC_SYNCHRONIZED);
    Native('reset', '()V', JVM_ACC_PUBLIC or JVM_ACC_SYNCHRONIZED);
    B.Start;
    B.Emit([$04, $AC]);
    B.Finish('markSupported', '()Z', JVM_ACC_PUBLIC, 1, 1);
    Done;
    B := TJavaClassBuilder.Create(ByteOutput, Output);
    B.Field('buf', '[B', JVM_ACC_PROTECTED);
    B.Field('count', 'I', JVM_ACC_PROTECTED);
    for var D in ['()V', '(I)V'] do
      Native('<init>', D);
    Native('write', '(I)V', JVM_ACC_PUBLIC or JVM_ACC_SYNCHRONIZED);
    Native('write', '([BII)V', JVM_ACC_PUBLIC or JVM_ACC_SYNCHRONIZED);
    Native('toByteArray', '()[B', JVM_ACC_PUBLIC or JVM_ACC_SYNCHRONIZED);
    Native('size', '()I', JVM_ACC_PUBLIC or JVM_ACC_SYNCHRONIZED);
    Native('reset', '()V', JVM_ACC_PUBLIC or JVM_ACC_SYNCHRONIZED);
    // writeTo dispatches to the destination stream; a guest override remains observable.
    Native('toString', '()Ljava/lang/String;', JVM_ACC_PUBLIC or JVM_ACC_SYNCHRONIZED);
    Native('toString', '(Ljava/lang/String;)Ljava/lang/String;', JVM_ACC_PUBLIC or JVM_ACC_SYNCHRONIZED);
    B.Start;
    B.Emit([$2B, $2A]);
    B.Ref($B4, B.Member(ByteOutput, 'buf', '[B', 9));
    B.Emit([$03, $2A]);
    B.Ref($B4, B.Member(ByteOutput, 'count', 'I', 9));
    B.Ref($B6, B.Member(Output, 'write', '([BII)V'));
    B.Emit([$B1]);
    B.Finish('writeTo', '(Ljava/io/OutputStream;)V', JVM_ACC_PUBLIC or JVM_ACC_SYNCHRONIZED, 4, 2);
    Done;
    B := TJavaClassBuilder.Create(InputAPI, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT or $0200);
    DataMethods(True, True);
    AbstractMethod('readUnsignedByte', '()I');
    AbstractMethod('readUnsignedShort', '()I');
    AbstractMethod('readFully', '([B)V');
    AbstractMethod('readFully', '([BII)V');
    AbstractMethod('skipBytes', '(I)I');
    AbstractMethod('readUTF', '()Ljava/lang/String;');
    Done;
    B := TJavaClassBuilder.Create(OutputAPI, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_ABSTRACT or $0200);
    DataMethods(True, False);
    AbstractMethod('write', '(I)V');
    AbstractMethod('write', '([B)V');
    AbstractMethod('write', '([BII)V');
    AbstractMethod('writeChars', '(Ljava/lang/String;)V');
    AbstractMethod('writeBytes', '(Ljava/lang/String;)V');
    AbstractMethod('writeUTF', '(Ljava/lang/String;)V');
    Done;
    B := TJavaClassBuilder.Create(DataInput, Input);
    B.JavaClass.Interfaces := [InputAPI];
    InField := B.Field('in', 'Ljava/io/InputStream;', JVM_ACC_PROTECTED);
    B.Start;
    B.Emit([$2A]);
    B.Ref($B7, B.Member(Input, '<init>', '()V'));
    B.Emit([$2A, $2B]);
    B.Ref($B5, InField);
    B.Emit([$B1]);
    B.Finish('<init>', '(Ljava/io/InputStream;)V', JVM_ACC_PUBLIC, 2, 2);
    for var N in ['read', 'available', 'close', 'reset', 'markSupported'] do
    begin
      var D := '()I';
      if (N = 'close') or (N = 'reset') then
        D := '()V'
      else if N = 'markSupported' then
        D := '()Z';
      B.Start;
      B.Emit([$2A]);
      B.Ref($B4, InField);
      B.Ref($B6, B.Member(Input, N, D));
      if D = '()V' then
        B.Emit([$B1])
      else
        B.Emit([$AC]);
      B.Finish(N, D, JVM_ACC_PUBLIC, 1, 1);
    end;
    for var N in ['skip', 'mark'] do
    begin
      B.Start;
      B.Emit([$2A]);
      B.Ref($B4, InField);
      var D := '(J)J';
      if N = 'mark' then
      begin
        D := '(I)V';
        B.Emit([$1B]);
      end
      else
        B.Emit([$1F]);
      B.Ref($B6, B.Member(Input, N, D));
      if N = 'mark' then
        B.Emit([$B1])
      else
        B.Emit([$AD]);
      B.Finish(N, D, JVM_ACC_PUBLIC, 3, 3);
    end;
    ArrayReadShortcut(DataInput);
    B.Start;
    B.Emit([$2A]);
    B.Ref($B4, InField);
    B.Emit([$2B, $1C, $1D]);
    B.Ref($B6, B.Member(Input, 'read', '([BII)I'));
    B.Emit([$AC]);
    B.Finish('read', '([BII)I', JVM_ACC_PUBLIC or JVM_ACC_FINAL, 4, 4);
    B.Start;
    B.Emit([$2A]);
    B.Ref($B4, InField);
    B.Ref($B6, B.Member(Input, 'read', '()I'));
    B.Emit([$3C, $1B]);
    B.Jump($9C, 'ok');
    ThrowError('java/io/EOFException');
    B.Mark('ok');
    B.Emit([$1B, $AC]);
    B.Finish('readUnsignedByte', '()I', JVM_ACC_PUBLIC or JVM_ACC_FINAL, 2, 2);
    B.Start;
    B.Emit([$2A]);
    B.Ref($B6, B.Member(DataInput, 'readUnsignedByte', '()I'));
    B.Emit([$10, 8, $78, $2A]);
    B.Ref($B6, B.Member(DataInput, 'readUnsignedByte', '()I'));
    B.Emit([$80, $AC]);
    B.Finish('readUnsignedShort', '()I', JVM_ACC_PUBLIC or JVM_ACC_FINAL, 2, 1);
    DataMethods(False, True);
    B.Start;
    B.Emit([$2A, $2B, $03, $2B, $BE]);
    B.Ref($B6, B.Member(DataInput, 'readFully', '([BII)V'));
    B.Emit([$B1]);
    B.Finish('readFully', '([B)V', JVM_ACC_PUBLIC or JVM_ACC_FINAL, 5, 2);
    B.Start;
    ArrayBounds;
    B.Emit([$03, $36, 5]);
    B.Mark('loop');
    B.Emit([$15, 5, $1D]);
    B.Jump($A2, 'end');
    B.Emit([$2A, $2B, $1C, $15, 5, $60, $1D, $15, 5, $64]);
    B.Ref($B6, B.Member(DataInput, 'read', '([BII)I'));
    B.Emit([$36, 6, $15, 6]);
    B.Jump($9D, 'progress');
    ThrowError('java/io/EOFException');
    B.Mark('progress');
    B.Emit([$15, 5, $15, 6, $60, $36, 5]);
    B.Jump($A7, 'loop');
    B.Mark('end');
    B.Emit([$B1]);
    B.Finish('readFully', '([BII)V', JVM_ACC_PUBLIC or JVM_ACC_FINAL, 5, 7);
    B.Start;
    B.Emit([$03, $3D]);
    B.Mark('loop');
    B.Emit([$1C, $1B]);
    B.Jump($A2, 'end');
    B.Emit([$2A, $1B, $1C, $64, $85]);
    B.Ref($B6, B.Member(DataInput, 'skip', '(J)J'));
    B.Emit([$88, $3E, $1D]);
    B.Jump($9E, 'end');
    B.Emit([$1C, $1D, $60, $3D]);
    B.Jump($A7, 'loop');
    B.Mark('end');
    B.Emit([$1C, $AC]);
    B.Finish('skipBytes', '(I)I', JVM_ACC_PUBLIC or JVM_ACC_FINAL, 3, 4);
    B.Start;
    B.Emit([$2A]);
    B.Ref($B8, B.Member(DataInput, 'readUTF', '(Ljava/io/DataInput;)Ljava/lang/String;'));
    B.Emit([$B0]);
    B.Finish('readUTF', '()Ljava/lang/String;', JVM_ACC_PUBLIC or JVM_ACC_FINAL, 1, 1);
    B.Start;
    B.Emit([$2A]);
    B.Ref($B9, B.Member(InputAPI, 'readUnsignedShort', '()I', 11));
    B.Emit([$01, $00, $BC, 8, $4C, $2A, $2B]);
    B.Ref($B9, B.Member(InputAPI, 'readFully', '([B)V', 11));
    B.Emit([$02, $00, $2B]);
    B.Ref($B8, B.Member(DataInput, '$decodeUTF', '([B)Ljava/lang/String;'));
    B.Emit([$B0]);
    B.Finish('readUTF', '(Ljava/io/DataInput;)Ljava/lang/String;', JVM_ACC_PUBLIC or JVM_ACC_STATIC, 2, 2);
    Native('$decodeUTF', '([B)Ljava/lang/String;', JVM_ACC_PRIVATE or JVM_ACC_STATIC);
    Done;
    B := TJavaClassBuilder.Create(DataOutput, Output);
    B.JavaClass.Interfaces := [OutputAPI];
    OutField := B.Field('out', 'Ljava/io/OutputStream;', JVM_ACC_PROTECTED);
    B.Field('written', 'I', JVM_ACC_PROTECTED);
    B.Start;
    B.Emit([$2A]);
    B.Ref($B7, B.Member(Output, '<init>', '()V'));
    B.Emit([$2A, $2B]);
    B.Ref($B5, OutField);
    B.Emit([$B1]);
    B.Finish('<init>', '(Ljava/io/OutputStream;)V', JVM_ACC_PUBLIC, 2, 2);
    WriteOne := B.Member(Output, 'write', '(I)V');
    B.Start;
    B.Emit([$2A]);
    B.Ref($B4, OutField);
    B.Emit([$1B]);
    B.Ref($B6, WriteOne);
    B.Emit([$2A, $04]);
    B.Ref($B7, B.Member(DataOutput, '$count', '(I)V'));
    B.Emit([$B1]);
    B.Finish('write', '(I)V', JVM_ACC_PUBLIC or JVM_ACC_SYNCHRONIZED, 2, 2);
    B.Start;
    B.Emit([$2A]);
    B.Ref($B4, OutField);
    B.Emit([$2B, $1C, $1D]);
    B.Ref($B6, B.Member(Output, 'write', '([BII)V'));
    B.Emit([$2A, $1D]);
    B.Ref($B7, B.Member(DataOutput, '$count', '(I)V'));
    B.Emit([$B1]);
    B.Finish('write', '([BII)V', JVM_ACC_PUBLIC or JVM_ACC_SYNCHRONIZED, 4, 4);
    Native('$count', '(I)V', JVM_ACC_PRIVATE);
    B.Start;
    B.Emit([$2A]);
    B.Ref($B4, B.Member(DataOutput, 'written', 'I', 9));
    B.Emit([$AC]);
    B.Finish('size', '()I', JVM_ACC_PUBLIC or JVM_ACC_FINAL, 1, 1);
    for var N in ['flush', 'close'] do
    begin
      B.Start;
      if N = 'close' then
      begin
        B.Emit([$2A]);
        B.Ref($B6, B.Member(DataOutput, 'flush', '()V'));
      end;
      B.Emit([$2A]);
      B.Ref($B4, OutField);
      B.Ref($B6, B.Member(Output, N, '()V'));
      B.Emit([$B1]);
      B.Finish(N, '()V', JVM_ACC_PUBLIC, 1, 1);
    end;
    DataMethods(False, False);
    for var N in ['writeBytes', 'writeChars'] do
    begin
      B.Start;
      B.Emit([$03, $3D]);
      B.Mark('loop');
      B.Emit([$1C, $2B]);
      B.Ref($B6, B.Member('java/lang/String', 'length', '()I'));
      B.Jump($A2, 'end');
      B.Emit([$2B, $1C]);
      B.Ref($B6, B.Member('java/lang/String', 'charAt', '(I)C'));
      B.Emit([$3E]);
      if N = 'writeChars' then
      begin
        B.Emit([$2A]);
        B.Ref($B4, OutField);
        B.Emit([$1D, $10, 8, $7C]);
        B.Ref($B6, B.Member(Output, 'write', '(I)V'));
      end;
      B.Emit([$2A]);
      B.Ref($B4, OutField);
      B.Emit([$1D]);
      B.Ref($B6, B.Member(Output, 'write', '(I)V'));
      B.Emit([$84, 2, 1]);
      B.Jump($A7, 'loop');
      B.Mark('end');
      B.Emit([$2A, $1C]);
      if N = 'writeChars' then
        B.Emit([$05, $68]);
      B.Ref($B7, B.Member(DataOutput, '$count', '(I)V'));
      B.Emit([$B1]);
      B.Finish(N, '(Ljava/lang/String;)V', JVM_ACC_PUBLIC or JVM_ACC_FINAL, 3, 4);
    end;
    B.Start;
    B.Emit([$2A, $2B]);
    B.Ref($B8, B.Member(DataOutput, '$encodeUTF', '(Ljava/lang/String;)[B'));
    B.Ref($B6, B.Member(DataOutput, 'write', '([B)V'));
    B.Emit([$B1]);
    B.Finish('writeUTF', '(Ljava/lang/String;)V', JVM_ACC_PUBLIC or JVM_ACC_FINAL, 2, 2);
    Native('$encodeUTF', '(Ljava/lang/String;)[B', JVM_ACC_PRIVATE or JVM_ACC_STATIC);
    Done;
  finally
    B.Free;
  end;
end;

function NewJavaByteArrayInput(VM: TJVM; const Data: TBytes): Integer;
var
  O, A: TJVMObject;
  Ref: Integer;
begin
  if Length(Data) > VM.MaxArrayLength then
    VM.RaiseJava('java/lang/OutOfMemoryError', 'Resource stream array capacity');
  Ref := VM.NewArray('[B', Length(Data));
  A := VM.GetObject(Ref);
  for var I := 0 to High(Data) do
    A.Elements[I] := TJVMValue.Int(ShortInt(Data[I]));
  Result := VM.NewObject(ByteInput);
  O := VM.GetObject(Result);
  O.Fields[ByteInput + '.buf:[B'] := TJVMValue.Ref(Ref);
  O.Fields[ByteInput + '.count:I'] := TJVMValue.Int(Length(Data));
end;

function InvokeJavaIO(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>; const DefaultEncoding: string): TJVMValue;
var
  O, A, Dest: TJVMObject;
  C, N, Key, Text: string;
  Pos, Count, Offset, Len, Ref, I, P, Ch, B2, B3: Integer;
  Data: TBytes;
  Encoded: Int64;

  function ByteArray(Index: Integer): TJVMObject;
  begin
    Result := VM.GetObject(Args[Index].AsRef);
    if Result.ClassName <> '[B' then
      raise EJVMFormatError.Create('Expected byte array');
  end;

  procedure Bounds(Obj: TJVMObject; At, Size: Integer);
  begin
    if (At < 0) or (Size < 0) or (At > Length(Obj.Elements)) or (Size > Length(Obj.Elements) - At) then
      VM.RaiseJava('java/lang/IndexOutOfBoundsException');
  end;

  function ReadByte: Integer;
  begin
    if P >= Length(Data) then
      VM.RaiseJava('java/io/UTFDataFormatException', 'Truncated modified UTF-8');
    Result := Data[P];
    Inc(P);
  end;

begin
  C := Method.Owner.Name;
  N := Method.Name;
  Result := Default(TJVMValue);
  if N = '$count' then
  begin
    O := VM.GetObject(Args[0].AsRef);
    Key := DataOutput + '.written:I';
    O.Fields[Key] := TJVMValue.Int(Integer(Min(Int64(MaxInt), Int64(O.Fields[Key].AsInt) + Args[1].AsInt)));
    Exit;
  end;
  if N = '$decodeUTF' then
  begin
    A := ByteArray(0);
    SetLength(Data, Length(A.Elements));
    for I := 0 to High(Data) do
      Data[I] := Byte(A.Elements[I].AsInt);
    SetLength(Text, Length(Data));
    I := 0;
    P := 0;
    while P < Length(Data) do
    begin
      Ch := ReadByte;
      if Ch >= $C0 then
      begin
        if Ch < $E0 then
        begin
          B2 := ReadByte;
          if B2 and $C0 <> $80 then
            VM.RaiseJava('java/io/UTFDataFormatException');
          Ch := ((Ch and $1F) shl 6) or (B2 and $3F);
        end
        else if Ch < $F0 then
        begin
          B2 := ReadByte;
          B3 := ReadByte;
          if (B2 and $C0 <> $80) or (B3 and $C0 <> $80) then
            VM.RaiseJava('java/io/UTFDataFormatException');
          Ch := ((Ch and $0F) shl 12) or ((B2 and $3F) shl 6) or (B3 and $3F);
        end
        else
          VM.RaiseJava('java/io/UTFDataFormatException');
      end
      else if Ch >= $80 then
        VM.RaiseJava('java/io/UTFDataFormatException');
      Inc(I);
      Text[I] := Char(Ch);
    end;
    SetLength(Text, I);
    Exit(TJVMValue.Ref(VM.NewString(Text)));
  end;
  if N = '$encodeUTF' then
  begin
    Text := VM.GetObject(Args[0].AsRef).Text;
    Encoded := 0;
    for I := 1 to Length(Text) do
    begin
      Ch := Ord(Text[I]);
      if (Ch > 0) and (Ch <= $7F) then
        Inc(Encoded)
      else if Ch <= $7FF then
        Inc(Encoded, 2)
      else
        Inc(Encoded, 3);
    end;
    if Encoded > 65535 then
      VM.RaiseJava('java/io/UTFDataFormatException', 'Modified UTF-8 length exceeds 65535');
    Ref := VM.NewArray('[B', Integer(Encoded) + 2);
    A := VM.GetObject(Ref);
    P := 2;
    A.Elements[0] := TJVMValue.Int(ShortInt(Encoded shr 8));
    A.Elements[1] := TJVMValue.Int(ShortInt(Encoded));
    for I := 1 to Length(Text) do
    begin
      Ch := Ord(Text[I]);
      if (Ch > 0) and (Ch <= $7F) then
      begin
        A.Elements[P] := TJVMValue.Int(Ch);
        Inc(P);
      end
      else
      begin
        if Ch > $7FF then
        begin
          A.Elements[P] := TJVMValue.Int(ShortInt($E0 or (Ch shr 12)));
          Inc(P);
          A.Elements[P] := TJVMValue.Int(ShortInt($80 or ((Ch shr 6) and $3F)));
          Inc(P);
        end
        else
        begin
          A.Elements[P] := TJVMValue.Int(ShortInt($C0 or (Ch shr 6)));
          Inc(P);
        end;
        A.Elements[P] := TJVMValue.Int(ShortInt($80 or (Ch and $3F)));
        Inc(P);
      end;
    end;
    Exit(TJVMValue.Ref(Ref));
  end;
  O := VM.GetObject(Args[0].AsRef);
  Key := C + '.';
  if C = ByteInput then
  begin
    if N = '<init>' then
    begin
      A := ByteArray(1);
      Offset := 0;
      Count := Length(A.Elements);
      if Length(Args) = 4 then
      begin
        Offset := Args[2].AsInt;
        Count := Integer(Min(Int64(Offset) + Args[3].AsInt, Int64(Count)));
      end;
      O.Fields[Key + 'buf:[B'] := Args[1];
      O.Fields[Key + 'pos:I'] := TJVMValue.Int(Offset);
      O.Fields[Key + 'mark:I'] := TJVMValue.Int(Offset);
      O.Fields[Key + 'count:I'] := TJVMValue.Int(Count);
      Exit;
    end;
    A := VM.GetObject(O.Fields[Key + 'buf:[B'].AsRef);
    Pos := O.Fields[Key + 'pos:I'].AsInt;
    Count := O.Fields[Key + 'count:I'].AsInt;
    if N = 'available' then
      Exit(TJVMValue.Int(Count - Pos));
    if N = 'mark' then
    begin
      O.Fields[Key + 'mark:I'] := TJVMValue.Int(Pos);
      Exit;
    end;
    if N = 'reset' then
    begin
      O.Fields[Key + 'pos:I'] := O.Fields[Key + 'mark:I'];
      Exit;
    end;
    if N = 'skip' then
    begin
      Len := Integer(Max(Int64(0), Min(Args[1].AsLong, Int64(Count) - Pos)));
      Result := TJVMValue.Long(Len);
    end
    else if Length(Args) = 1 then
    begin
      if Pos >= Count then
        Exit(TJVMValue.Int(-1));
      Bounds(A, Pos, 1);
      Result := TJVMValue.Int(A.Elements[Pos].AsInt and 255);
      Len := 1;
    end
    else
    begin
      Dest := ByteArray(1);
      Offset := Args[2].AsInt;
      Len := Args[3].AsInt;
      Bounds(Dest, Offset, Len);
      if Pos >= Count then
        Exit(TJVMValue.Int(-1));
      Len := Min(Len, Count - Pos);
      Bounds(A, Pos, Len);
      // Temporary copy handles a destination aliased with the underlying buffer.
      var Values := Copy(A.Elements, Pos, Len);
      for I := 0 to Len - 1 do
        Dest.Elements[Offset + I] := Values[I];
      Result := TJVMValue.Int(Len);
    end;
    O.Fields[Key + 'pos:I'] := TJVMValue.Int(Pos + Len);
    Exit;
  end;
  if C = ByteOutput then
  begin
    if N = '<init>' then
    begin
      Len := 32;
      if Length(Args) > 1 then
        Len := Args[1].AsInt;
      if Len < 0 then
        VM.RaiseJava('java/lang/IllegalArgumentException');
      O.Fields[Key + 'buf:[B'] := TJVMValue.Ref(VM.NewArray('[B', Len));
      O.Fields[Key + 'count:I'] := TJVMValue.Int(0);
      Exit;
    end;
    Count := O.Fields[Key + 'count:I'].AsInt;
    A := VM.GetObject(O.Fields[Key + 'buf:[B'].AsRef);
    if N = 'toString' then
    begin
      Text := DefaultEncoding;
      if Length(Args) = 2 then
        Text := VM.GetObject(Args[1].AsRef).Text;
      var Charset := JavaCharset(VM, Text);
      Bounds(A, 0, Count);
      SetLength(Data, Count);
      for I := 0 to Count - 1 do
        Data[I] := Byte(A.Elements[I].AsInt);
      Exit(TJVMValue.Ref(VM.NewString(JavaDecode(VM, Data, Charset))));
    end;
    if N = 'size' then
      Exit(TJVMValue.Int(Count));
    if N = 'reset' then
    begin
      O.Fields[Key + 'count:I'] := TJVMValue.Int(0);
      Exit;
    end;
    if N = 'toByteArray' then
    begin
      Bounds(A, 0, Count);
      Ref := VM.NewArray('[B', Count);
      Dest := VM.GetObject(Ref);
      for I := 0 to Count - 1 do
        Dest.Elements[I] := A.Elements[I];
      Exit(TJVMValue.Ref(Ref));
    end;
    Len := 1;
    Offset := 0;
    Dest := nil;
    if Length(Args) = 4 then
    begin
      Dest := ByteArray(1);
      Offset := Args[2].AsInt;
      Len := Args[3].AsInt;
      Bounds(Dest, Offset, Len);
    end;
    if (Count < 0) or (Int64(Count) + Len > VM.MaxArrayLength) then
      VM.RaiseJava('java/lang/OutOfMemoryError', 'Byte stream limit');
    if Count + Len > Length(A.Elements) then
    begin
      Ref := VM.NewArray('[B', Integer(Min(Int64(VM.MaxArrayLength), Max(Int64(Count) + Len, Int64(Length(A.Elements)) * 2))));
      var NewBuffer := VM.GetObject(Ref);
      Bounds(A, 0, Count);
      for I := 0 to Count - 1 do
        NewBuffer.Elements[I] := A.Elements[I];
      A := NewBuffer;
      O.Fields[Key + 'buf:[B'] := TJVMValue.Ref(Ref);
    end;
    if Dest = nil then
      A.Elements[Count] := TJVMValue.Int(ShortInt(Args[1].AsInt))
    else
    begin
      var Values := Copy(Dest.Elements, Offset, Len);
      for I := 0 to Len - 1 do
        A.Elements[Count + I] := Values[I];
    end;
    O.Fields[Key + 'count:I'] := TJVMValue.Int(Count + Len);
    Exit;
  end;
  raise EJVMUnsupported.Create('Unimplemented IO native: ' + C + '.' + N);
end;

end.

