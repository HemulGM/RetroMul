unit RM.Styles;

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.Variants,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.Dialogs;

type
  TFormStyles = class(TForm)
    StyleBookWinUI3: TStyleBook;
    Lang: TLang;
  public
    procedure SetLanguage(const Language: string);
    procedure RelocalizeUI(Root: TFmxObject; const PreviousLanguage: string);
  end;

var
  FormStyles: TFormStyles;

implementation

uses
  System.TypInfo, FMX.Edit, FMX.ListBox;

{$R *.fmx}

procedure TFormStyles.SetLanguage(const Language: string);
begin
  var Code := Language.Trim.ToLower.Replace('_', '-');
  if (Code = 'ru') or Code.StartsWith('ru-') then Code := 'ru'
  else if (Code = 'pt') or Code.StartsWith('pt-') then Code := 'pt'
  else Code := 'en';
  if Lang.Lang <> Code then Lang.Lang := Code;
end;

procedure TFormStyles.RelocalizeUI(Root: TFmxObject; const PreviousLanguage: string);

  function Localized(const Value: string): string;
  begin
    Result := Value;
    if Value = '' then Exit;
    if Lang.Original.IndexOf(Value) >= 0 then Exit(Translate(Value));
    var Old := Lang.LangStr[PreviousLanguage];
    if Old <> nil then
      for var I := 0 to Old.Count - 1 do
        if Old.ValueFromIndex[I] = Value then Exit(Translate(Old.Names[I]));
  end;

  procedure Visit(Obj: TFmxObject);
  begin
    // Editable text is user data. Translate prompts and UI captions only.
    for var Name in ['Text', 'TextPrompt', 'Hint'] do
    begin
      if (Name = 'Text') and (Obj is TCustomEdit) then Continue;
      var Prop := GetPropInfo(Obj.ClassInfo, Name);
      if (Prop <> nil) and (Prop.PropType^.Kind in [tkString, tkLString, tkWString, tkUString]) then
      begin
        var Value := GetStrProp(Obj, Prop);
        var NewValue := Localized(Value);
        if NewValue <> Value then SetStrProp(Obj, Prop, NewValue);
      end;
    end;
    if Obj is TComboBox then
    begin
      var Combo := TComboBox(Obj);
      var Selected := Combo.ItemIndex;
      for var I := 0 to Combo.Items.Count - 1 do Combo.Items[I] := Localized(Combo.Items[I]);
      Combo.ItemIndex := Selected;
    end;
    if Obj is TCustomEdit then Exit;
    if Obj.Children <> nil then
      for var Child in Obj.Children do Visit(Child);
  end;

begin
  if (Root <> nil) and (PreviousLanguage <> Lang.Lang) then Visit(Root);
end;

end.
