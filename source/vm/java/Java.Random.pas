unit Java.Random;

interface

uses
  JVM.Types, JVM.ClassFile, JVM.Runtime;

procedure InstallJavaRandom(VM: TJVM);

function InvokeJavaRandom(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;

implementation

uses
  System.SysUtils, Java.Classes;

{$Q-}{$R-}

procedure InstallJavaRandom(VM: TJVM);
const
  Name = 'java/util/Random';
var
  B: TJavaClassBuilder;
  Next: Word;
begin
  B := TJavaClassBuilder.Create(Name, 'java/lang/Object');
  try
    B.Field('$seed', 'J', JVM_ACC_PRIVATE);
    B.JavaClass.AddNative('setSeed', '(J)V').Access := JVM_ACC_PUBLIC or JVM_ACC_NATIVE or JVM_ACC_SYNCHRONIZED;
    B.JavaClass.AddNative('next', '(I)I').Access := JVM_ACC_PROTECTED or JVM_ACC_NATIVE or JVM_ACC_SYNCHRONIZED;
    B.Start;
    B.Emit([$2A]);
    B.Ref($B7, B.Member('java/lang/Object', '<init>', '()V'));
    B.Emit([$2A, $1F]);
    B.Ref($B6, B.Member(Name, 'setSeed', '(J)V'));
    B.Emit([$B1]);
    B.Finish('<init>', '(J)V', JVM_ACC_PUBLIC, 3, 3);
    B.Start;
    B.Emit([$2A]);
    B.Ref($B8, B.Member('java/lang/System', 'currentTimeMillis', '()J'));
    B.Ref($B7, B.Member(Name, '<init>', '(J)V'));
    B.Emit([$B1]);
    B.Finish('<init>', '()V', JVM_ACC_PUBLIC, 3, 1);
    Next := B.Member(Name, 'next', '(I)I');
    B.Start;
    B.Emit([$2A, $10, 32]);
    B.Ref($B6, Next);
    B.Emit([$AC]);
    B.Finish('nextInt', '()I', JVM_ACC_PUBLIC, 2, 1);
    B.Start;
    B.Emit([$1B]);
    B.Jump($9D, 'positive');
    B.Ref($BB, B.ClassRef('java/lang/IllegalArgumentException'));
    B.Emit([$59]);
    B.Ref($B7, B.Member('java/lang/IllegalArgumentException', '<init>', '()V'));
    B.Emit([$BF]);
    B.Mark('positive');
    B.Emit([$1B, $1B, $74, $7E, $1B]);
    B.Jump($A0, 'loop'); // n & -n == n
    B.Emit([$1B, $85, $2A, $10, 31]);
    B.Ref($B6, Next);
    B.Emit([$85, $69, $10, 31, $7B, $88, $AC]);
    B.Mark('loop');
    B.Emit([$2A, $10, 31]);
    B.Ref($B6, Next);
    B.Emit([$3D, $1C, $1B, $70, $3E, $1C, $1D, $64, $1B, $04, $64, $60]);
    B.Jump($9B, 'loop');
    B.Emit([$1D, $AC]);
    B.Finish('nextInt', '(I)I', JVM_ACC_PUBLIC, 5, 4);
    B.Start;
    B.Emit([$2A, $10, 32]);
    B.Ref($B6, Next);
    B.Emit([$85, $10, 32, $79, $2A, $10, 32]);
    B.Ref($B6, Next);
    B.Emit([$85, $61, $AD]);
    B.Finish('nextLong', '()J', JVM_ACC_PUBLIC, 4, 1);
    B.Start;
    B.Emit([$2A, $10, 24]);
    B.Ref($B6, Next);
    B.Emit([$86]);
    B.Ref($13, B.IntConstant($4B800000)); // float divisor via intBitsToFloat
    B.Ref($B8, B.Member('java/lang/Float', 'intBitsToFloat', '(I)F'));
    B.Emit([$6E, $AE]);
    B.Finish('nextFloat', '()F', JVM_ACC_PUBLIC, 2, 1);
    B.Start;
    B.Emit([$2A, $10, 26]);
    B.Ref($B6, Next);
    B.Emit([$85, $10, 27, $79, $2A, $10, 27]);
    B.Ref($B6, Next);
    B.Emit([$85, $61, $8A]);
    B.Ref($14, B.LongConstant(Int64($4340000000000000)));
    B.Ref($B8, B.Member('java/lang/Double', 'longBitsToDouble', '(J)D'));
    B.Emit([$6F, $AF]);
    B.Finish('nextDouble', '()D', JVM_ACC_PUBLIC, 4, 1);
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
end;

function InvokeJavaRandom(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
const
  Multiplier: Int64 = $5DEECE66D;
  Mask: Int64 = $FFFFFFFFFFFF;
var
  O: TJVMObject;
  Seed: Int64;
  Bits: Integer;
begin
  O := VM.GetObject(Args[0].AsRef);
  Result := Default(TJVMValue);
  if Method.Name = 'setSeed' then
    Seed := (Args[1].AsLong xor Multiplier) and Mask
  else
  begin
    Bits := Args[1].AsInt;
    if (Bits < 1) or (Bits > 32) then
      raise EJVMUnsupported.Create('Random.next bits outside its protected contract');
    Seed := (O.Fields['java/util/Random.$seed:J'].AsLong * Multiplier + 11) and Mask;
    Result := TJVMValue.Int(Integer(UInt64(Seed) shr (48 - Bits)));
  end;
  O.Fields['java/util/Random.$seed:J'] := TJVMValue.Long(Seed);
end;

end.

