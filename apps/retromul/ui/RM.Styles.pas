unit RM.Styles;

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.Variants,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.Dialogs, Core.Storage;

type
  TFormStyles = class(TForm)
    StyleBookWinUI3: TStyleBook;
    Lang: TLang;
  private
    FCustomIndex: Integer;
    FSelectedLanguage: string;
  public
    function LoadTranslation(const Storage: IStorage; const FileName, Language: string): TStringList;
    procedure SaveTranslationTemplate(const Storage: IStorage; const FileName: string);
    procedure SetLanguage(const Language: string; const Translation: TStrings = nil);
    procedure RelocalizeUI(Root: TFmxObject; const PreviousLanguage: string);
    property SelectedLanguage: string read FSelectedLanguage;
  end;

var
  FormStyles: TFormStyles;

implementation

uses
  System.TypInfo, FMX.Edit, FMX.ListBox;

{$R *.fmx}

function NormalizeLanguage(const Language: string): string;
begin
  var Code := Language.Trim.ToLower.Replace('_', '-');
  if (Code = 'ru') or Code.StartsWith('ru-') then
    Code := 'ru'
  else if (Code = 'pt') or Code.StartsWith('pt-') then
    Code := 'pt'
  else
    Code := 'en';
  Result := Code;
end;

function TFormStyles.LoadTranslation(const Storage: IStorage; const FileName, Language: string): TStringList;
const
  MaxTranslationSize = 8 * 1024 * 1024;
var
  Data: TBytes;
  Offset: Integer;

  procedure InvalidFile;
  begin
    raise EConvertError.Create(Translate('Invalid translation file. Use UTF-8 text or a TLang .lng file.'));
  end;

  function ReadCardinal: Cardinal;
  begin
    if Length(Data) - Offset < SizeOf(Result) then
      InvalidFile;
    Move(Data[Offset], Result, SizeOf(Result));
    Inc(Offset, SizeOf(Result));
  end;

  function ReadString: string;
  begin
    var Count := ReadCardinal;
    if Count > Cardinal((Length(Data) - Offset) div SizeOf(Char)) then
      InvalidFile;
    SetLength(Result, Count);
    if Count > 0 then
      Move(Data[Offset], Result[1], Count * SizeOf(Char));
    Inc(Offset, Count * SizeOf(Char));
  end;

begin
  Result := nil;
  if FileName.Trim = '' then
    Exit;
  var Stream := Storage.OpenRead(FileName);
  try
    if (Stream.Size <= 0) or (Stream.Size > MaxTranslationSize) then
      InvalidFile;
    SetLength(Data, Stream.Size);
    Stream.ReadBuffer(Data[0], Length(Data));
  finally
    Stream.Free;
  end;
  var Lines := TStringList.Create;
  try
    try
      var Binary := SameText(ExtractFileExt(FileName), '.lng') or
        ((Length(Data) >= 8) and (Data[2] = 0) and (Data[3] = 0));
      if Binary then
      begin
        Offset := 0;
        ReadString; // Original keys precede the language dictionaries.
        var Count := ReadCardinal;
        if Count > Cardinal((Length(Data) - Offset) div 8) then
          InvalidFile;
        var Found := False;
        for var i := 1 to Count do
        begin
          var Code := ReadString;
          var Values := ReadString;
          if (Count = 1) or SameText(Code, NormalizeLanguage(Language)) then
          begin
            if Found then
              InvalidFile;
            Lines.Text := Values;
            Found := True;
          end;
        end;
        if Offset <> Length(Data) then
          InvalidFile;
        if not Found then
          raise EConvertError.Create(Translate('The translation file does not contain the selected language.'));
      end
      else
      begin
        Offset := 0;
        if (Length(Data) >= 3) and (Data[0] = $EF) and (Data[1] = $BB) and (Data[2] = $BF) then
          Offset := 3;
        var Text: string;
        try
          Text := TEncoding.UTF8.GetString(Data, Offset, Length(Data) - Offset);
        except
          on E: EEncodingError do
            InvalidFile;
        end;
        var Encoded := TEncoding.UTF8.GetBytes(Text);
        if (Length(Encoded) <> Length(Data) - Offset) or
          ((Length(Encoded) > 0) and not CompareMem(@Encoded[0], @Data[Offset], Length(Encoded))) then
          InvalidFile;
        Lines.Text := Text;
      end;
      Result := TStringList.Create;
      Result.CaseSensitive := True;
      for var Line in Lines do
      begin
        var Separator := Pos('=', Line);
        if Separator <= 1 then
          Continue;
        // Leading/trailing spaces can be part of an original key or translation.
        var Key := Copy(Line, 1, Separator - 1);
        var Value := Copy(Line, Separator + 1, MaxInt);
        if (Lang.Original.IndexOf(Key) >= 0) and (Value <> '') then
        begin
          if Result.IndexOfName(Key) >= 0 then
            InvalidFile;
          Result.Values[Key] := Value;
        end;
      end;
      if Result.Count = 0 then
        raise EConvertError.Create(Translate('The translation file contains no translations for this application.'));
    except
      FreeAndNil(Result);
      raise;
    end;
  finally
    Lines.Free;
  end;
end;

procedure TFormStyles.SaveTranslationTemplate(const Storage: IStorage; const FileName: string);
begin
  var Lines := TStringList.Create;
  var Content := TMemoryStream.Create;
  try
    Lines.WriteBOM := True;
    Lines.Add('# RetroMul translation template — UTF-8');
    Lines.Add('# Original English key=Your translation');
    Lines.Add('# Preserve spaces, format placeholders (%d, %s, %.1f, %%) and file filter patterns.');
    Lines.Add('# Empty values use the selected built-in language.');
    Lines.Add('');
    for var Key in Lang.Original do
      Lines.Add(Key + '=');
    Lines.SaveToStream(Content, TEncoding.UTF8);
    if FileName.StartsWith('content://') then
    begin
      var Output := Storage.OpenWrite(FileName);
      try
        Content.Position := 0;
        Output.CopyFrom(Content, Content.Size);
      finally
        Output.Free;
      end;
    end
    else
      Storage.WriteAtomic(FileName, Content);
  finally
    Content.Free;
    Lines.Free;
  end;
end;

procedure TFormStyles.SetLanguage(const Language: string; const Translation: TStrings);
begin
  var Code := NormalizeLanguage(Language);
  FSelectedLanguage := Code;
  if Translation <> nil then
  begin
    var Values := TStringList.Create;
    try
      Values.CaseSensitive := True;
      Values.Assign(Lang.LangStr[Code]);
      for var i := 0 to Translation.Count - 1 do
        Values.Values[Translation.Names[i]] := Translation.ValueFromIndex[i];
      if Lang.Lang.StartsWith('custom-') and (Lang.LangStr[Lang.Lang].Text = Values.Text) then
        Exit;
      // Keep the previous dictionary for reverse lookup during UI relocalization.
      FCustomIndex := 1 - FCustomIndex;
      Code := 'custom-' + IntToStr(FCustomIndex);
      Lang.AddLang(Code);
      Lang.LangStr[Code].Assign(Values);
    finally
      Values.Free;
    end;
  end;
  if Lang.Lang <> Code then
    Lang.Lang := Code;
end;

procedure TFormStyles.RelocalizeUI(Root: TFmxObject; const PreviousLanguage: string);

  function Localized(const Value: string): string;
  begin
    Result := Value;
    if Value = '' then
      Exit;
    if Lang.Original.IndexOf(Value) >= 0 then
      Exit(Translate(Value));
    var Old := Lang.LangStr[PreviousLanguage];
    if Old <> nil then
      for var i := 0 to Old.Count - 1 do
        if Old.ValueFromIndex[i] = Value then
          Exit(Translate(Old.Names[i]));
  end;

  procedure Visit(Obj: TFmxObject);
  begin
    // Editable text is user data. Translate prompts and UI captions only.
    for var Name in ['Text', 'TextPrompt', 'Hint'] do
    begin
      if (Name = 'Text') and (Obj is TCustomEdit) then
        Continue;

      var Prop := GetPropInfo(Obj.ClassInfo, Name);
      if (Prop <> nil) and (Prop.PropType^.Kind in [tkString, tkLString, tkWString, tkUString]) then
      begin
        var Value := GetStrProp(Obj, Prop);
        var NewValue := Localized(Value);
        if NewValue <> Value then
          SetStrProp(Obj, Prop, NewValue);
      end;
    end;
    if Obj is TComboBox then
    begin
      var Combo := TComboBox(Obj);
      var Selected := Combo.ItemIndex;
      for var i := 0 to Combo.Items.Count - 1 do
        Combo.Items[i] := Localized(Combo.Items[i]);
      Combo.ItemIndex := Selected;
    end;
    if Obj is TCustomEdit then
      Exit;

    if Obj.Children <> nil then
      for var Child in Obj.Children do
        Visit(Child);
  end;

begin
  if (Root <> nil) and (PreviousLanguage <> Lang.Lang) then
    Visit(Root);
end;

end.

