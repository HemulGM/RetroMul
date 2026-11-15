unit J2ME.Font;

interface

uses
  System.SysUtils, JVM.Types, JVM.ClassFile, JVM.Runtime;

type
  TJ2MEFontView = record
    Face, Style, Size, Height, Baseline: Integer;
  end;

  TJ2MEGlyph = record
    Width, Height: Integer;
    Mask: TBytes;
  end;

procedure InstallJ2MEFont(VM: TJVM);

function InvokeJ2MEFont(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;

function J2MEGetFont(VM: TJVM; Face: Integer = 0; Style: Integer = 0; Size: Integer = 0): Integer;

function J2MEFontView(VM: TJVM; Ref: Integer): TJ2MEFontView;

function J2MEFontAdvance(const Font: TJ2MEFontView; C: Char): Integer;

function J2MEFontGlyph(const Font: TJ2MEFontView; C: Char): TJ2MEGlyph;

function J2MEFontTextWidth(const Font: TJ2MEFontView; const Text: string): Integer;

implementation

uses
  System.Math, Java.Classes, Media.Font.Bitmap;

{$Q-}{$R-}

const
  FontClass = 'javax/microedition/lcdui/Font';
  FontDesc = 'Ljavax/microedition/lcdui/Font;';

function BitmapSize(Size: Integer): TBitmapFontSize;
begin
  case Size of
    8:
      Result := TBitmapFontSize.Small;
    16:
      Result := TBitmapFontSize.Large;
  else
    Result := TBitmapFontSize.Medium;
  end;
end;

function CacheName(Face, Style, Size: Integer): string;
begin
  Result := '$cache' + IntToStr(Face) + '_' + IntToStr(Style) + '_' + IntToStr(Size);
end;

procedure InstallJ2MEFont(VM: TJVM);
var
  B: TJavaClassBuilder;

  procedure Constant(const Name: string; Value: Integer);
  begin
    B.Field(Name, 'I', JVM_ACC_PUBLIC or JVM_ACC_STATIC or JVM_ACC_FINAL);
    B.JavaClass.Fields.Last.Value := TJVMValue.Int(Value);
  end;

begin
  B := TJavaClassBuilder.Create(FontClass, 'java/lang/Object', JVM_ACC_PUBLIC or JVM_ACC_FINAL or $0020);
  try
    Constant('FACE_SYSTEM', 0);
    Constant('FACE_MONOSPACE', 32);
    Constant('FACE_PROPORTIONAL', 64);
    Constant('STYLE_PLAIN', 0);
    Constant('STYLE_BOLD', 1);
    Constant('STYLE_ITALIC', 2);
    Constant('STYLE_UNDERLINED', 4);
    Constant('SIZE_MEDIUM', 0);
    Constant('SIZE_SMALL', 8);
    Constant('SIZE_LARGE', 16);
    Constant('FONT_STATIC_TEXT', 0);
    Constant('FONT_INPUT_TEXT', 1);
    B.Field('$face', 'I', JVM_ACC_PRIVATE);
    B.Field('$style', 'I', JVM_ACC_PRIVATE);
    B.Field('$size', 'I', JVM_ACC_PRIVATE);
    for var Face in [0, 32, 64] do
      for var Style := 0 to 7 do
        for var Size in [0, 8, 16] do
          B.Field(CacheName(Face, Style, Size), FontDesc, JVM_ACC_PRIVATE or JVM_ACC_STATIC);
    B.JavaClass.AddNative('getDefaultFont', '()' + FontDesc, True);
    B.JavaClass.AddNative('getFont', '(I)' + FontDesc, True);
    B.JavaClass.AddNative('getFont', '(III)' + FontDesc, True);
    for var N in ['getFace', 'getSize', 'getStyle', 'getHeight', 'getBaselinePosition'] do
      B.JavaClass.AddNative(N, '()I');
    for var N in ['isPlain', 'isBold', 'isItalic', 'isUnderlined'] do
      B.JavaClass.AddNative(N, '()Z');
    B.JavaClass.AddNative('charWidth', '(C)I');
    B.JavaClass.AddNative('charsWidth', '([CII)I');
    B.JavaClass.AddNative('stringWidth', '(Ljava/lang/String;)I');
    B.JavaClass.AddNative('substringWidth', '(Ljava/lang/String;II)I');
    VM.DefineClass(B.Detach);
  finally
    B.Free;
  end;
end;

function J2MEGetFont(VM: TJVM; Face, Style, Size: Integer): Integer;
var
  C: TJVMClass;
  Name: string;
  O: TJVMObject;
begin
  if not (Face in [0, 32, 64]) or (Style < 0) or (Style > 7) or not (Size in [0, 8, 16]) then
    VM.RaiseJava('java/lang/IllegalArgumentException', 'Font attributes');
  C := VM.LoadClass(FontClass);
  Name := CacheName(Face, Style, Size);
  for var F in C.Fields do
    if F.Name = Name then
    begin
      Result := F.Value.AsRef;
      if Result <> 0 then
        Exit;
      Result := VM.NewObject(FontClass);
      O := VM.GetObject(Result);
      O.Fields[FontClass + '.$face:I'] := TJVMValue.Int(Face);
      O.Fields[FontClass + '.$style:I'] := TJVMValue.Int(Style);
      O.Fields[FontClass + '.$size:I'] := TJVMValue.Int(Size);
      F.Value := TJVMValue.Ref(Result);
      Exit;
    end;
  raise EJVMError.Create('Missing font cache slot');
end;

function J2MEFontView(VM: TJVM; Ref: Integer): TJ2MEFontView;
var
  O: TJVMObject;
begin
  O := VM.GetObject(Ref);
  if O.ClassName <> FontClass then
    raise EJVMFormatError.Create('Expected Font');
  Result.Face := O.Fields[FontClass + '.$face:I'].AsInt;
  Result.Style := O.Fields[FontClass + '.$style:I'].AsInt;
  Result.Size := O.Fields[FontClass + '.$size:I'].AsInt;
  var Glyph := BitmapFontGlyph(BitmapSize(Result.Size), ' ');
  Result.Height := Glyph.Height;
  Result.Baseline := Glyph.Baseline;
end;

function J2MEFontAdvance(const Font: TJ2MEFontView; C: Char): Integer;
begin
  var Glyph := BitmapFontGlyph(BitmapSize(Font.Size), C);
  var Ink := Glyph.Right - Glyph.Left + 1;
  if Font.Face = 32 then
    Result := Glyph.Width
  else if Ink <= 0 then
    Result := Max(1, Glyph.Width div 2)
  else
    Result := Ink + 1;
  if (Font.Style and 1) <> 0 then
    Inc(Result);
  if (Font.Style and 2) <> 0 then
    Inc(Result, Max(1, Font.Height div 6));
end;

function J2MEFontGlyph(const Font: TJ2MEFontView; C: Char): TJ2MEGlyph;
var
  BaseWidth, Left, Shift: Integer;
begin
  var Source := BitmapFontGlyph(BitmapSize(Font.Size), C);
  Result.Width := J2MEFontAdvance(Font, C);
  Result.Height := Font.Height;
  Result.Mask := nil;
  SetLength(Result.Mask, Result.Width * Result.Height);
  Left := 0;
  BaseWidth := Source.Width;
  if Font.Face <> 32 then
  begin
    Left := Source.Left;
    BaseWidth := Max(0, Source.Right - Source.Left + 1);
  end;
  // Each logical font size has its own native bitmap. Never discard strokes by
  // sampling a larger font; Font metrics and painted advances use the same data.
  for var Y := 0 to Font.Height - 1 do
  begin
    Shift := 0;
    if (Font.Style and 2) <> 0 then
      Shift := Max(0, (Font.Baseline - Y) div 6);
    for var X := 0 to BaseWidth - 1 do
      if Source.Ink(X + Left, Y) then
      begin
        Result.Mask[Y * Result.Width + X + Shift] := 1;
        if ((Font.Style and 1) <> 0) and (X + Shift + 1 < Result.Width) then
          Result.Mask[Y * Result.Width + X + Shift + 1] := 1;
      end;
    if ((Font.Style and 4) <> 0) and (Y = Min(Font.Height - 1, Font.Baseline + 1)) then
      for var X := 0 to Result.Width - 1 do
        Result.Mask[Y * Result.Width + X] := 1;
  end;
end;

function J2MEFontTextWidth(const Font: TJ2MEFontView; const Text: string): Integer;
var
  Total: Int64;
begin
  Total := 0;
  for var C in Text do
    Inc(Total, J2MEFontAdvance(Font, C));
  Result := Integer(Min(Int64(MaxInt), Total));
end;

function InvokeJ2MEFont(VM: TJVM; Method: TJVMMethod; const Args: TArray<TJVMValue>): TJVMValue;
var
  N, Text: string;
  Font: TJ2MEFontView;
  Start, Count, I: Integer;
  ArrayObject: TJVMObject;
begin
  N := Method.Name;
  if N = 'getDefaultFont' then
    Exit(TJVMValue.Ref(J2MEGetFont(VM)));
  if N = 'getFont' then
  begin
    if Length(Args) = 3 then
      Exit(TJVMValue.Ref(J2MEGetFont(VM, Args[0].AsInt, Args[1].AsInt, Args[2].AsInt)));
    I := Args[0].AsInt;
    if not (I in [0, 1]) then
      VM.RaiseJava('java/lang/IllegalArgumentException');
    Exit(TJVMValue.Ref(J2MEGetFont(VM)));
  end;
  Font := J2MEFontView(VM, Args[0].AsRef);
  if N = 'getFace' then
    Exit(TJVMValue.Int(Font.Face));
  if N = 'getSize' then
    Exit(TJVMValue.Int(Font.Size));
  if N = 'getStyle' then
    Exit(TJVMValue.Int(Font.Style));
  if N = 'getHeight' then
    Exit(TJVMValue.Int(Font.Height));
  if N = 'getBaselinePosition' then
    Exit(TJVMValue.Int(Font.Baseline));
  if N = 'isPlain' then
    Exit(TJVMValue.Int(Ord(Font.Style = 0)));
  if N = 'isBold' then
    Exit(TJVMValue.Int(Ord((Font.Style and 1) <> 0)));
  if N = 'isItalic' then
    Exit(TJVMValue.Int(Ord((Font.Style and 2) <> 0)));
  if N = 'isUnderlined' then
    Exit(TJVMValue.Int(Ord((Font.Style and 4) <> 0)));
  if N = 'charWidth' then
    Exit(TJVMValue.Int(J2MEFontAdvance(Font, Char(Args[1].AsInt))));
  if N = 'charsWidth' then
  begin
    ArrayObject := VM.GetObject(Args[1].AsRef);
    Start := Args[2].AsInt;
    Count := Args[3].AsInt;
    if (Start < 0) or (Count < 0) or (Start > Length(ArrayObject.Elements)) or (Count > Length(ArrayObject.Elements) - Start) then
      VM.RaiseJava('java/lang/ArrayIndexOutOfBoundsException');
    SetLength(Text, Count);
    for I := 0 to Count - 1 do
      Text[I + 1] := Char(ArrayObject.Elements[Start + I].AsInt);
  end
  else
  begin
    Text := VM.GetObject(Args[1].AsRef).Text;
    if N = 'substringWidth' then
    begin
      Start := Args[2].AsInt;
      Count := Args[3].AsInt;
      if (Start < 0) or (Count < 0) or (Start > Length(Text)) or (Count > Length(Text) - Start) then
        VM.RaiseJava('java/lang/StringIndexOutOfBoundsException');
      Text := Copy(Text, Start + 1, Count);
    end;
  end;
  Result := TJVMValue.Int(J2MEFontTextWidth(Font, Text));
end;

end.

