unit J2ME.Alert.Layout;

interface

uses
  JVM.Runtime;

type
  TJ2MEAlertLayout = class
  private
    FVM: TJVM;
    FScreen, FWidth, FText, FImage, FIndicator: Integer;
  public
    Lines: TArray<string>;
    Image, Indicator, LineHeight, TextY, IndicatorY, TotalHeight, BodyHeight: Integer;
    constructor Create(VM: TJVM);
    procedure Clear;
    procedure Update(Screen, Width, Height: Integer);
  end;

implementation

uses
  System.SysUtils, System.Math, System.Generics.Collections, JVM.Types,
  J2ME.Font, J2ME.Image;

function Ref(O: TJVMObject; const Name: string): Integer;
var
  V: TJVMValue;
begin
  if O.Fields.TryGetValue('$ui.' + Name, V) then
    Result := V.AsRef
  else
    Result := 0;
end;

constructor TJ2MEAlertLayout.Create(VM: TJVM);
begin
  inherited Create;
  FVM := VM;
end;

procedure TJ2MEAlertLayout.Clear;
begin
  FScreen := 0;
  Lines := nil;
  Image := 0;
  Indicator := 0;
end;

procedure TJ2MEAlertLayout.Update(Screen, Width, Height: Integer);
var
  Values: TList<string>;
  Text: string;
  Font: TJ2MEFontView;
  Start, Cursor, LastSpace, Used, Available: Integer;
begin
  BodyHeight := Height;
  var O := FVM.GetObject(Screen);
  var TextRef := Ref(O, 'alertText');
  var ImageRef := Ref(O, 'alertSnapshot');
  var IndicatorRef := Ref(O, 'indicator');
  if (FScreen = Screen) and (FWidth = Width) and (FText = TextRef) and (FImage = ImageRef) and (FIndicator = IndicatorRef) then
    Exit;
  FScreen := 0;
  Values := TList<string>.Create;
  try
    Text := '';
    if TextRef <> 0 then
      Text := FVM.GetObject(TextRef).Text.Replace(#9, '    ');
    Font := J2MEFontView(FVM, J2MEGetFont(FVM, 0, 0, 8));
    LineHeight := Font.Height + 3;
    Available := Max(1, Width - 16);
    Start := 1;
    while Start <= Length(Text) do
    begin
      Cursor := Start;
      LastSpace := 0;
      Used := 0;
      while Cursor <= Length(Text) do
      begin
        var C := Text[Cursor];
        if CharInSet(C, [#10, #13]) then
          Break;
        var Advance := J2MEFontAdvance(Font, C);
        if (Used + Advance > Available) and (Cursor > Start) then
          Break;
        Inc(Used, Advance);
        if C = ' ' then
          LastSpace := Cursor;
        Inc(Cursor);
      end;
      if (Cursor <= Length(Text)) and not CharInSet(Text[Cursor], [#10, #13]) and (LastSpace > Start) then
      begin
        Values.Add(Copy(Text, Start, LastSpace - Start));
        Start := LastSpace + 1;
        while (Start <= Length(Text)) and (Text[Start] = ' ') do
          Inc(Start);
      end
      else
      begin
        Values.Add(Copy(Text, Start, Cursor - Start));
        Start := Cursor;
        if (Start <= Length(Text)) and CharInSet(Text[Start], [#10, #13]) then
        begin
          var CR := Text[Start] = #13;
          Inc(Start);
          if CR and (Start <= Length(Text)) and (Text[Start] = #10) then
            Inc(Start);
          if Start > Length(Text) then
            Values.Add('');
        end;
      end;
    end;
    Lines := Values.ToArray;
    Image := ImageRef;
    Indicator := IndicatorRef;
    var Y := Int64(8);
    if Image <> 0 then
      Inc(Y, Int64(J2MEImageView(FVM, Image).Height) + 8);
    TextY := Integer(Min(Int64(MaxInt), Y));
    Inc(Y, Int64(Length(Lines)) * LineHeight);
    if Length(Lines) > 0 then
      Inc(Y, 8);
    IndicatorY := Integer(Min(Int64(MaxInt), Y));
    if Indicator <> 0 then
      Inc(Y, 18);
    Inc(Y, 8);
    TotalHeight := Integer(Min(Int64(MaxInt), Y));
    FScreen := Screen;
    FWidth := Width;
    FText := TextRef;
    FImage := ImageRef;
    FIndicator := IndicatorRef;
  finally
    Values.Free;
  end;
end;

end.

