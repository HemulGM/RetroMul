unit J2ME.Item.Layout;

interface

uses
  JVM.Runtime, J2ME.Font;

type
  TJ2METextLine = record
    Text: string;
    Start, Count: Integer;
  end;

  TJ2MEItemMetrics = record
    MinimumWidth, PreferredWidth, MinimumHeight, PreferredHeight: Integer;
    LabelHeight, BodyHeight, FontRef, LabelFontRef: Integer;
    Lines, Labels: TArray<TJ2METextLine>;
  end;

function J2MEWrapText(const Text: string; const Font: TJ2MEFontView; Width: Integer): TArray<TJ2METextLine>;

function J2MECaretLine(const Lines: TArray<TJ2METextLine>; Caret: Integer): Integer;

function J2MEChoiceRowHeight(VM: TJVM; Row: Integer): Integer;

function J2MEItemMetrics(VM: TJVM; Item, AvailableWidth, ActualWidth: Integer): TJ2MEItemMetrics;

implementation

uses
  System.SysUtils, System.Math, System.Generics.Collections, J2ME.UI.Data,
  J2ME.Text, J2ME.Image, J2ME.DateField;

function J2MEWrapText(const Text: string; const Font: TJ2MEFontView; Width: Integer): TArray<TJ2METextLine>;
var
  Values: TList<TJ2METextLine>;
  Start, Cursor, LastSpace, Used: Integer;

  procedure Add(First, Count: Integer);
  var
    Line: TJ2METextLine;
  begin
    Line.Start := First - 1;
    Line.Count := Count;
    Line.Text := Copy(Text, First, Count);
    Values.Add(Line);
  end;

begin
  Values := TList<TJ2METextLine>.Create;
  try
    Width := Max(1, Width);
    Start := 1;
    if Text = '' then
      Add(1, 0);
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
        if (Used + Advance > Width) and (Cursor > Start) then
          Break;
        Inc(Used, Advance);
        if C = ' ' then
          LastSpace := Cursor;
        Inc(Cursor);
      end;
      if (Cursor <= Length(Text)) and not CharInSet(Text[Cursor], [#10, #13]) and (LastSpace > Start) then
      begin
        Add(Start, LastSpace - Start);
        Start := LastSpace + 1;
        while (Start <= Length(Text)) and (Text[Start] = ' ') do
          Inc(Start);
      end
      else
      begin
        Add(Start, Cursor - Start);
        Start := Cursor;
        if (Start <= Length(Text)) and CharInSet(Text[Start], [#10, #13]) then
        begin
          var CR := Text[Start] = #13;
          Inc(Start);
          if CR and (Start <= Length(Text)) and (Text[Start] = #10) then
            Inc(Start);
          if Start > Length(Text) then
            Add(Start, 0);
        end;
      end;
    end;
    Result := Values.ToArray;
  finally
    Values.Free;
  end;
end;

function J2MECaretLine(const Lines: TArray<TJ2METextLine>; Caret: Integer): Integer;
begin
  Result := 0;
  for var I := 0 to High(Lines) do
  begin
    if Lines[I].Start > Caret then
      Break;
    Result := I;
  end;
end;

function J2MEChoiceRowHeight(VM: TJVM; Row: Integer): Integer;
begin
  var O := VM.GetObject(Row);
  var Font := UIRef(O, 'font');
  if Font = 0 then
    Font := J2MEGetFont(VM, 0, 0, 8);
  Result := Max(24, J2MEFontView(VM, Font).Height + 8);
end;

function J2MEItemMetrics(VM: TJVM; Item, AvailableWidth, ActualWidth: Integer): TJ2MEItemMetrics;
begin
  Result := Default(TJ2MEItemMetrics);
  var O := VM.GetObject(Item);
  var Kind := UIInt(O, 'itemKind');
  AvailableWidth := Max(1, AvailableWidth);
  Result.FontRef := UIRef(O, 'font');
  if Result.FontRef = 0 then
    Result.FontRef := J2MEGetFont(VM, 0, 0, 8);
  Result.LabelFontRef := J2MEGetFont(VM, 0, 1, 8);
  var Font := J2MEFontView(VM, Result.FontRef);
  var LabelFont := J2MEFontView(VM, Result.LabelFontRef);
  var LabelText := UIString(VM, UIRef(O, 'label'));
  var Value := UIString(VM, UIRef(O, 'text'));
  if Kind = 5 then
    Value := J2METextDisplay(VM, O);
  if Kind = 7 then
    Value := J2MEDateFieldText(O);
  var Minimum := 0;
  var Preferred := 0;
  var BodyHeight := 0;
  case Kind of
    1:
      begin
        if Value <> '' then
        begin
          Minimum := J2MEFontAdvance(Font, 'W') + 4;
          for var Line in J2MEWrapText(Value, Font, MaxInt div 4) do
            Preferred := Max(Preferred, J2MEFontTextWidth(Font, Line.Text) + 4);
        end;
        if UIInt(O, 'appearance') <> 0 then
        begin
          Minimum := Max(Minimum, 24);
          Preferred := Max(Preferred, 32);
        end;
      end;
    2:
      begin
        var Image := UIRef(O, 'imageSnapshot');
        if Image <> 0 then
        begin
          Minimum := 1;
          Preferred := J2MEImageView(VM, Image).Width;
        end;
      end;
    3:
      begin
        Minimum := UIInt(O, 'minimumWidth');
        Preferred := Minimum;
      end;
    4, 5, 6, 7:
      begin
        Minimum := 24;
        Preferred := AvailableWidth;
      end;
  end;
  if LabelText <> '' then
  begin
    Minimum := Max(Minimum, J2MEFontAdvance(LabelFont, 'W') + 4);
    Preferred := AvailableWidth;
  end;
  Result.MinimumWidth := Minimum;
  Result.PreferredWidth := Max(Minimum, Preferred);
  var Locked := UIInt(O, 'preferredWidth', -1);
  if Locked >= 0 then
    Result.PreferredWidth := Max(Minimum, Locked);
  if ActualWidth < 0 then
    ActualWidth := Min(AvailableWidth, Result.PreferredWidth);
  ActualWidth := Max(1, ActualWidth);
  if LabelText <> '' then
  begin
    Result.Labels := J2MEWrapText(LabelText, LabelFont, Max(1, ActualWidth - 4));
    Result.LabelHeight := Length(Result.Labels) * (LabelFont.Height + 2) + 2;
  end;
  case Kind of
    1:
      begin
        if Value <> '' then
        begin
          Result.Lines := J2MEWrapText(Value, Font, Max(1, ActualWidth - 4));
          BodyHeight := Length(Result.Lines) * (Font.Height + 3);
        end;
        if UIInt(O, 'appearance') <> 0 then
          BodyHeight := Max(Font.Height + 8, BodyHeight + 6);
        Result.MinimumHeight := Result.LabelHeight;
        if BodyHeight > 0 then
          Inc(Result.MinimumHeight, Font.Height + 3);
      end;
    2:
      begin
        var Image := UIRef(O, 'imageSnapshot');
        if Image <> 0 then
          BodyHeight := J2MEImageView(VM, Image).Height;
        Result.MinimumHeight := Result.LabelHeight + Min(1, BodyHeight);
      end;
    3:
      begin
        BodyHeight := UIInt(O, 'minimumHeight');
        Result.MinimumHeight := BodyHeight;
      end;
    4:
      begin
        BodyHeight := 18;
        Result.MinimumHeight := Result.LabelHeight + BodyHeight;
      end;
    5, 7:
      begin
        Result.Lines := J2MEWrapText(Value, Font, Max(1, ActualWidth - 8));
        var Count := Max(1, Length(Result.Lines));
        if Kind = 5 then
          Count := Min(3, Count);
        BodyHeight := Count * (Font.Height + 3) + 8;
        Result.MinimumHeight := Result.LabelHeight + Font.Height + 11;
      end;
    6:
      begin
        var Rows := UIRef(O, 'rows');
        BodyHeight := 24;
        if (Rows <> 0) and (Length(VM.GetObject(Rows).Elements) > 0) then
        begin
          var Values := VM.GetObject(Rows);
          if (UIInt(O, 'choiceType') = 4) and (UIInt(O, 'expanded') = 0) then
          begin
            var Selected := 0;
            for var I := 0 to High(Values.Elements) do
              if UIInt(VM.GetObject(Values.Elements[I].AsRef), 'selected') <> 0 then
              begin
                Selected := I;
                Break;
              end;
            BodyHeight := J2MEChoiceRowHeight(VM, Values.Elements[Selected].AsRef);
          end
          else
          begin
            BodyHeight := 0;
            for var RowValue in Values.Elements do
              Inc(BodyHeight, J2MEChoiceRowHeight(VM, RowValue.AsRef));
          end;
        end;
        Result.MinimumHeight := Result.LabelHeight + Min(24, BodyHeight);
      end;
  end;
  Result.BodyHeight := BodyHeight;
  Result.PreferredHeight := Result.LabelHeight + BodyHeight;
  Locked := UIInt(O, 'preferredHeight', -1);
  if Locked >= 0 then
    Result.PreferredHeight := Max(Result.MinimumHeight, Locked);
end;

end.

