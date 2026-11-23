unit Flash.Text;

interface

uses
  System.SysUtils, System.Generics.Collections, AVM1.Runtime;

type
  TFlashTextSpan = class
  public
    First, Last: Integer;
    Format: TAVMTextFormatData;
    constructor Create(AFirst, ALast: Integer; Data: TAVMTextFormatData);
    destructor Destroy; override;
  end;

  TFlashTextDocument = class
  private
    FText, FMarkup: string;
    FSpans: TObjectList<TFlashTextSpan>;
    FDefault: TAVMTextFormatData;
    FForceUpdate, FMarkupDirty: Boolean;
    procedure SplitAt(Index: Integer);
    procedure Append(const Value: string; Format: TAVMTextFormatData);
  public
    HTML, Multiline: Boolean;
    Version: Byte;
    constructor Create(Data: TAVMTextFormatData);
    destructor Destroy; override;
    procedure AssignText(const Value: string);
    procedure AssignHTML(const Value: string);
    function HTMLText: string;
    procedure SetDefault(Data: TAVMTextFormatData; ForceUpdate: Boolean = True);
    function GetFormat(First, Last: Integer): TAVMTextFormatData;
    procedure SetFormat(First, Last: Integer; Data: TAVMTextFormatData);
    function FormatAt(Index: Integer): TAVMTextFormatData;
    property Text: string read FText;
    property DefaultFormat: TAVMTextFormatData read FDefault;
  end;

implementation

uses
  System.Math, System.StrUtils, AVM1.TextFormat, AVM1.Coercion, SWF.Reader;

constructor TFlashTextSpan.Create(AFirst, ALast: Integer; Data: TAVMTextFormatData);
begin
  inherited Create;
  First := AFirst;
  Last := ALast;
  Format := Data.Clone;
  if (Format.Values[0].Kind <> avString) or (Format.Values[0].Text = '') then
    Format.Values[0] := TAVMValue.Str('Times New Roman');
end;

destructor TFlashTextSpan.Destroy;
begin
  Format.Free;
  inherited;
end;

constructor TFlashTextDocument.Create(Data: TAVMTextFormatData);
begin
  inherited Create;
  FDefault := Data.Clone;
  FSpans := TObjectList<TFlashTextSpan>.Create;
  Version := 8;
end;

destructor TFlashTextDocument.Destroy;
begin
  FSpans.Free;
  FDefault.Free;
  inherited;
end;

procedure TFlashTextDocument.AssignText(const Value: string);
var
  Force: Boolean;
begin
  Force := FForceUpdate;
  FForceUpdate := False;
  if Length(Value) > 1048576 then
    raise ESWFError.Create('Flash text length limit');
  if (FText = Value) and not Force then
    Exit;
  FText := Value;
  FMarkup := Value;
  FMarkupDirty := False;
  FSpans.Clear;
  if Value <> '' then
    FSpans.Add(TFlashTextSpan.Create(0, Length(Value), FDefault));
end;

procedure TFlashTextDocument.Append(const Value: string; Format: TAVMTextFormatData);
var
  Start: Integer;
begin
  if Value = '' then
    Exit;
  if Length(FText) + Length(Value) > 1048576 then
    raise ESWFError.Create('Flash text length limit');
  if FSpans.Count >= 65536 then
    raise ESWFError.Create('Flash text span limit');
  Start := Length(FText);
  FText := FText + Value;
  FSpans.Add(TFlashTextSpan.Create(Start, Length(FText), Format));
end;

function DecodeEntities(const Value: string): string;
var
  I, J, Code: Integer;
  Entity: string;
begin
  Result := '';
  I := 1;
  while I <= Length(Value) do
  begin
    if Value[I] = '&' then
    begin
      J := I + 1;
      while (J <= Length(Value)) and (J - I < 32) and (Value[J] <> ';') do
        Inc(J);
      if (J <= Length(Value)) and (Value[J] = ';') then
      begin
        Entity := LowerCase(Copy(Value, I + 1, J - I - 1));
        Code := -1;
        if Entity = 'amp' then
          Code := 38
        else if Entity = 'lt' then
          Code := 60
        else if Entity = 'gt' then
          Code := 62
        else if Entity = 'quot' then
          Code := 34
        else if Entity = 'apos' then
          Code := 39
        else if Entity = 'nbsp' then
          Code := 160
        else if Entity.StartsWith('#x') then
          TryStrToInt('$' + Copy(Entity, 3, MaxInt), Code)
        else if Entity.StartsWith('#') then
          TryStrToInt(Copy(Entity, 2, MaxInt), Code);
        if Code >= 0 then
        begin
          Result := Result + Char(Code and $FFFF);
          I := J + 1;
          Continue;
        end;
      end;
    end;
    Result := Result + Value[I];
    Inc(I);
  end;
end;

procedure TFlashTextDocument.AssignHTML(const Value: string);
var
  Stack: TObjectList<TAVMTextFormatData>;
  Names: TList<string>;
  Attributes: TDictionary<string, string>;
  I, J, K, Start, Field, ClosingAt: Integer;
  Tag, Name, AttributeName, AttributeValue, TextValue: string;
  Closing, EmptyTag, Force: Boolean;
  Current, Next, LastClosedFont: TAVMTextFormatData;
  Number: Double;
  Color: Integer;
  Quote, Prefix: Char;

  procedure NumberAttribute(const Name: string; Index: Integer);
  begin
    if Attributes.TryGetValue(Name, AttributeValue) and
      TryStrToFloat(AttributeValue, Number, TFormatSettings.Invariant) then
      Next.Values[Index] := TAVMValue.Num(Number);
  end;

begin
  if Length(Value) > 1048576 then
    raise ESWFError.Create('Flash HTML length limit');
  if not HTML then
  begin
    AssignText(Value);
    Exit;
  end;
  Force := FForceUpdate;
  FForceUpdate := False;
  if (FMarkup = Value) and not FMarkupDirty and not Force then
    Exit;
  FText := '';
  FSpans.Clear;
  FMarkup := Value;
  FMarkupDirty := False;
  Stack := TObjectList<TAVMTextFormatData>.Create;
  Names := TList<string>.Create;
  Attributes := TDictionary<string, string>.Create;
  LastClosedFont := nil;
  try
    Stack.Add(FDefault.Clone);
    Names.Add('');
    if Version < 8 then
      Stack[0].Values[8] := TAVMValue.Str('left');
    I := 1;
    while I <= Length(Value) do
    begin
      if Value[I] <> '<' then
      begin
        Start := I;
        while (I <= Length(Value)) and (Value[I] <> '<') do
          Inc(I);
        TextValue := DecodeEntities(Copy(Value, Start, I - Start));
        TextValue := StringReplace(TextValue, #13#10, #13, [rfReplaceAll]);
        TextValue := StringReplace(TextValue, #10, #13, [rfReplaceAll]);
        if not ((Version <= 7) and (Trim(TextValue) = '')) then
          Append(TextValue, Stack.Last);
        Continue;
      end;
      J := I + 1;
      Quote := #0;
      while J <= Length(Value) do
      begin
        if Quote <> #0 then
        begin
          if Value[J] = Quote then
            Quote := #0;
        end
        else if CharInSet(Value[J], ['"', #39]) then
          Quote := Value[J]
        else if Value[J] = '>' then
          Break;
        Inc(J);
      end;
      if J > Length(Value) then
        Break;
      Tag := Trim(Copy(Value, I + 1, J - I - 1));
      I := J + 1;
      if Tag = '' then
        Continue;
      Closing := Tag[1] = '/';
      if Closing then
        Delete(Tag, 1, 1);
      EmptyTag := Tag.EndsWith('/');
      if EmptyTag then
        Delete(Tag, Length(Tag), 1);
      K := 1;
      while (K <= Length(Tag)) and not CharInSet(Tag[K], [' ', #9, #10, #13]) do
        Inc(K);
      Name := LowerCase(Copy(Tag, 1, K - 1));
      if Closing then
      begin
        if (Names.Count <= 1) or (Names.Last <> Name) then
          Continue;
        if Name = 'font' then
        begin
          LastClosedFont.Free;
          LastClosedFont := Stack.Last.Clone;
        end;
        if (Name = 'p') and (Multiline or (Version <= 6)) then
        begin
          Next := Stack.Last.Clone;
          try
            for Field in [5, 6, 7] do
              Next.Values[Field] := TAVMValue.Bool(False);
            Next.Values[3] := TAVMValue.Str('');
            Next.Values[4] := TAVMValue.Str('');
            Current := LastClosedFont;
            if Current = nil then
              Current := FDefault;
            for Field in [0, 1, 2, 17, 18] do
              Next.Values[Field] := Current.Values[Field];
            Append(#13, Next);
          finally
            Next.Free;
          end;
        end;
        Names.Delete(Names.Count - 1);
        Stack.Delete(Stack.Count - 1);
        Continue;
      end;
      if (Name = 'br') or (Name = 'sbr') then
      begin
        if Multiline or (Version <= 6) then
          Append(#13, Stack.Last);
        Continue;
      end;
      if (Name = '!') or Name.StartsWith('!--') or Name.StartsWith('?') then
        Continue;
      Attributes.Clear;
      while K <= Length(Tag) do
      begin
        while (K <= Length(Tag)) and CharInSet(Tag[K], [' ', #9, #10, #13]) do
          Inc(K);
        Start := K;
        while (K <= Length(Tag)) and not CharInSet(Tag[K], ['=', ' ', #9, #10, #13]) do
          Inc(K);
        AttributeName := LowerCase(Copy(Tag, Start, K - Start));
        while (K <= Length(Tag)) and CharInSet(Tag[K], [' ', #9, #10, #13]) do
          Inc(K);
        AttributeValue := '';
        if (K <= Length(Tag)) and (Tag[K] = '=') then
        begin
          Inc(K);
          while (K <= Length(Tag)) and CharInSet(Tag[K], [' ', #9, #10, #13]) do
            Inc(K);
          Quote := #0;
          if (K <= Length(Tag)) and CharInSet(Tag[K], ['"', #39]) then
          begin
            Quote := Tag[K];
            Inc(K);
          end;
          Start := K;
          while (K <= Length(Tag)) and (((Quote <> #0) and (Tag[K] <> Quote)) or
            ((Quote = #0) and not CharInSet(Tag[K], [' ', #9, #10, #13]))) do
            Inc(K);
          AttributeValue := DecodeEntities(Copy(Tag, Start, K - Start));
          if Quote <> #0 then
            Inc(K);
        end;
        if AttributeName <> '' then
          Attributes.AddOrSetValue(AttributeName, AttributeValue)
        else
          Inc(K);
      end;
      Current := Stack.Last;
      Next := Current.Clone;
      if Name = 'b' then
        Next.Values[5] := TAVMValue.Bool(True)
      else if Name = 'i' then
        Next.Values[6] := TAVMValue.Bool(True)
      else if Name = 'u' then
        Next.Values[7] := TAVMValue.Bool(True)
      else if Name = 'font' then
      begin
        if Attributes.TryGetValue('face', AttributeValue) then
          Next.Values[0] := TAVMValue.Str(AttributeValue);
        if Attributes.TryGetValue('size', AttributeValue) then
        begin
          Prefix := #0;
          if (AttributeValue <> '') and CharInSet(AttributeValue[1], ['+', '-']) then
          begin
            Prefix := AttributeValue[1];
            Delete(AttributeValue, 1, 1);
          end;
          ClosingAt := 1;
          while (ClosingAt <= Length(AttributeValue)) and CharInSet(AttributeValue[ClosingAt], ['0'..'9']) do
            Inc(ClosingAt);
          if TryStrToFloat(Copy(AttributeValue, 1, ClosingAt - 1), Number, TFormatSettings.Invariant) then
          begin
            if Prefix = '+' then
              Number := Current.Values[1].Number + Number
            else if Prefix = '-' then
              Number := Current.Values[1].Number - Number;
            Number := Max(1.0, Number);
            if Version < 13 then
              Number := Min(127.0, Number);
            Next.Values[1] := TAVMValue.Num(Number);
          end;
        end;
        if Attributes.TryGetValue('color', AttributeValue) then
        begin
          if AttributeValue.StartsWith('#') then
            Delete(AttributeValue, 1, 1);
          if TryStrToInt('$' + AttributeValue, Color) then
            Next.Values[2] := TAVMValue.Num(Color and $FFFFFF);
        end;
        NumberAttribute('letterspacing', 18);
        if Attributes.TryGetValue('kerning', AttributeValue) then
          Next.Values[17] := TAVMValue.Bool(AttributeValue = '1');
      end
      else if Name = 'textformat' then
      begin
        NumberAttribute('leftmargin', 9);
        NumberAttribute('rightmargin', 10);
        NumberAttribute('indent', 11);
        NumberAttribute('leading', 12);
        NumberAttribute('blockindent', 13);
      end
      else if Name = 'p' then
      begin
        if Attributes.TryGetValue('align', AttributeValue) then
          Next.Values[8] := TAVMValue.Str(LowerCase(AttributeValue));
      end
      else if Name = 'a' then
      begin
        if Attributes.TryGetValue('href', AttributeValue) then
          Next.Values[3] := TAVMValue.Str(AttributeValue);
        if Attributes.TryGetValue('target', AttributeValue) then
          Next.Values[4] := TAVMValue.Str(AttributeValue);
      end;
      if EmptyTag then
        Next.Free
      else
      begin
        if Stack.Count >= 128 then
        begin
          Next.Free;
          raise ESWFError.Create('Flash HTML nesting limit');
        end;
        Stack.Add(Next);
        Names.Add(Name);
      end;
    end;
  finally
    LastClosedFont.Free;
    Attributes.Free;
    Names.Free;
    Stack.Free;
  end;
end;

function TFlashTextDocument.HTMLText: string;
begin
  if HTML then
    Result := FMarkup
  else
    Result := FText;
end;

procedure TFlashTextDocument.SetDefault(Data: TAVMTextFormatData; ForceUpdate: Boolean);
begin
  AVMMixTextFormat(FDefault, Data);
  FForceUpdate := FForceUpdate or ForceUpdate;
end;

function TFlashTextDocument.GetFormat(First, Last: Integer): TAVMTextFormatData;
var
  Span: TFlashTextSpan;
begin
  Result := nil;
  First := EnsureRange(First, 0, Length(FText));
  Last := EnsureRange(Last, 0, Length(FText));
  if First < Last then
    for Span in FSpans do
      if (Span.First < Last) and (Span.Last > First) then
      begin
        if Result = nil then
          Result := Span.Format.Clone
        else
          AVMIntersectTextFormat(Result, Span.Format);
      end;
  if Result = nil then
    Result := TAVMTextFormatData.Create;
end;

procedure TFlashTextDocument.SplitAt(Index: Integer);
var
  I: Integer;
  Span, Right: TFlashTextSpan;
begin
  for I := 0 to FSpans.Count - 1 do
  begin
    Span := FSpans[I];
    if (Span.First < Index) and (Span.Last > Index) then
    begin
      if FSpans.Count >= 65536 then
        raise ESWFError.Create('Flash text span limit');
      Right := TFlashTextSpan.Create(Index, Span.Last, Span.Format);
      Span.Last := Index;
      FSpans.Insert(I + 1, Right);
      Exit;
    end;
  end;
end;

procedure TFlashTextDocument.SetFormat(First, Last: Integer; Data: TAVMTextFormatData);
var
  Span: TFlashTextSpan;
  Effective: TAVMTextFormatData;
  I: Integer;
begin
  Last := Min(Last, Length(FText));
  if First >= Last then
    Exit;
  SplitAt(First);
  SplitAt(Last);
  Effective := Data.Clone;
  try
    if (Effective.Values[0].Kind = avString) and (Effective.Values[0].Text = '') then
      Effective.Values[0] := TAVMValue.Ref(nil);
    for Span in FSpans do
      if (Span.First >= First) and (Span.Last <= Last) then
        AVMMixTextFormat(Span.Format, Effective);
  finally
    Effective.Free;
  end;
  I := 0;
  while I < FSpans.Count - 1 do
  begin
    if FSpans[I].Format.Matches(FSpans[I + 1].Format) then
    begin
      FSpans[I].Last := FSpans[I + 1].Last;
      FSpans.Delete(I + 1);
    end
    else
      Inc(I);
  end;
  FMarkupDirty := True;
end;

function TFlashTextDocument.FormatAt(Index: Integer): TAVMTextFormatData;
var
  Span: TFlashTextSpan;
  LowIndex, HighIndex, Middle: Integer;
begin
  LowIndex := 0;
  HighIndex := FSpans.Count - 1;
  while LowIndex <= HighIndex do
  begin
    Middle := LowIndex + (HighIndex - LowIndex) div 2;
    Span := FSpans[Middle];
    if Index < Span.First then
      HighIndex := Middle - 1
    else if Index >= Span.Last then
      LowIndex := Middle + 1
    else
      Exit(Span.Format);
  end;
  Result := FDefault;
end;

end.

